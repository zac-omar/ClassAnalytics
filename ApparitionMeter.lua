-- Apparition Meter: counts Shadowy Apparitions procs (the free Mind Blasts) and shows them per
-- second, live. Written for Lua 5.0 (WoW 1.12): no #, no %, no string.match, no select.
--
-- A proc is a hit the game credits to Shadowy Apparitions. Hits less than 0.3 sec apart are one
-- proc: one Mind Blast can hit more than one enemy, and two procs are always at least 0.5 sec
-- apart. Times are the run's clock, so paused time (level-up cards, menus) doesn't count.

local VERSION = "0.1.0";
local MERGE = 0.3;      -- hits closer than this belong to one proc
local KEEP = 60;        -- seconds of history kept for the windows
local CAP = 2;          -- procs per second can't go past this
local POLL = 0.1;       -- how often the feed is read, in real seconds

local DEFAULTS = { window = 10, locked = false, hidden = false, point = "CENTER", x = 0, y = -180 };

local db;
local state = {
	procs = {},         -- times of the procs in the last KEEP seconds
	total = 0,          -- procs this run
	lastProc = -100,
	ticks = {},         -- { time, count } of Shadow Word: Pain ticks in the last KEEP seconds
	startedAt = nil,    -- run time when counting began
	run = nil,
	cursor = nil, primed = false, nextPoll = 0, status = "waiting for the feed",
	seen = false,
	mindBlastKeys = {}, -- for /apm debug: how Mind Blast hits are credited
};

-- "Shadowy Apparitions", "shadowy_apparitions" and "talent:shadowy_apparitions:r1" all hold
-- "shadowyapparitions". Only ASCII is lowered: string.lower follows the system's code page,
-- which would change UTF-8 bytes in other languages' names.
local function Norm(k)
	local s = string.gsub(tostring(k or ""), "[\1-\32\127!\"#$%%&'()*+,%-./:;<=>?@%[\\%]%^_`{|}~]", "");
	return (string.gsub(s, "[A-Z]", function(c) return string.char(string.byte(c) + 32); end));
end

local function Has(s, part)
	return string.find(s, part, 1, true) ~= nil;
end

local function Truthy(v)
	return v == true or v == 1 or v == "true";
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff9a7cffApparition Meter:|r " .. msg);
end

-- The run's clock: it stands still while the game is paused.
local function Now()
	if ( type(AZS_GetRunTime) == "function" ) then
		local t = AZS_GetRunTime();
		if ( type(t) == "number" ) then
			return t;
		end
	end
	return GetTime();
end

local function Reset(now)
	state.procs, state.ticks = {}, {};
	state.total, state.lastProc = 0, -100;
	state.startedAt = now;
end

local function Trim(now)
	local cut = now - KEEP;
	while ( state.procs[1] and state.procs[1] < cut ) do
		table.remove(state.procs, 1);
	end
	while ( state.ticks[1] and state.ticks[1][1] < cut ) do
		table.remove(state.ticks, 1);
	end
end

-- Procs per second over the last `w` seconds (or since counting began, if that's shorter).
local function Rate(now, w)
	local span = w;
	if ( state.startedAt and now - state.startedAt < span ) then
		span = now - state.startedAt;
	end
	if ( span < 1 ) then
		return nil;
	end
	local n = 0;
	for i = table.getn(state.procs), 1, -1 do
		if ( state.procs[i] <= now - w ) then
			break;
		end
		n = n + 1;
	end
	return n / span;
end

local function TickRate(now, w)
	local span = w;
	if ( state.startedAt and now - state.startedAt < span ) then
		span = now - state.startedAt;
	end
	if ( span < 1 ) then
		return nil;
	end
	local n = 0;
	for i = table.getn(state.ticks), 1, -1 do
		local e = state.ticks[i];
		if ( e[1] <= now - w ) then
			break;
		end
		n = n + e[2];
	end
	return n / span;
end

local function NoteMindBlast(ev)
	local line = tostring(ev.abilityName) .. " | " .. tostring(ev.meterSource) .. " | " .. tostring(ev.meterSourceKey);
	local keys = state.mindBlastKeys;
	for i = 1, table.getn(keys) do
		if ( keys[i] == line ) then
			return;
		end
	end
	if ( table.getn(keys) >= 8 ) then
		table.remove(keys, 1);
	end
	table.insert(keys, line);
end

-- One event from the feed, at run time `t`.
local function Take(ev, t)
	if ( type(ev) ~= "table" or ev.kind == "miss" ) then
		return 0;
	end
	local key, source, ability = Norm(ev.meterSourceKey), Norm(ev.meterSource), Norm(ev.abilityName);
	if ( Has(ability, "mindblast") ) then
		NoteMindBlast(ev);
	end
	if ( Has(key, "shadowyapparition") or Has(source, "shadowyapparition") ) then
		state.seen = true;
		if ( t - state.lastProc >= MERGE ) then
			table.insert(state.procs, t);
			state.total = state.total + 1;
		end
		state.lastProc = t;
		return 0;
	end
	if ( Truthy(ev.periodic) and ( Has(ability, "shadowwordpain") or Has(key, "swpain") ) ) then
		return 1;
	end
	return 0;
end

local function Poll(real)
	if ( real < state.nextPoll or type(AZS_GetCombatTextEvents) ~= "function" ) then
		return;
	end
	state.nextPoll = real + POLL;
	local now = Now();
	-- a new run starts the count again
	local run = AZS_ZONE and AZS_ZONE.run;
	if ( run ~= state.run or not state.startedAt ) then
		state.run = run;
		Reset(now);
	end
	local ticks = 0;
	-- the feed hands out at most 256 at a time: read until it has nothing more
	for pass = 1, 20 do
		local res, err = AZS_GetCombatTextEvents(state.cursor, 256);
		if ( not res ) then
			state.status = "feed: " .. (type(err) == "table" and tostring(err.code) or tostring(err));
			if ( type(err) == "table" and ( err.code == "STREAM_CHANGED" or err.code == "INVALID_ARGUMENT" ) ) then
				state.cursor, state.primed = nil, false;
			end
			break;
		end
		state.cursor = res.nextCursor or res.cursor or state.cursor;
		local events = (type(res.events) == "table" and res.events) or {};
		local n = table.getn(events);
		if ( not state.primed ) then
			-- the feed keeps the last 5 sec: those came before we looked
			if ( n < 256 ) then
				state.primed, state.status = true, "listening";
			end
		else
			state.status = "listening";
			local clock = tonumber(res.clockSeconds);
			for i = 1, n do
				local ev = events[i];
				local t = now;
				local shown = type(ev) == "table" and tonumber(ev.presentedAt);
				if ( shown and clock and clock - shown >= 0 and clock - shown < 5 ) then
					t = now - (clock - shown);
				end
				ticks = ticks + Take(ev, t);
			end
		end
		if ( n < 256 ) then
			break;
		end
	end
	if ( ticks > 0 ) then
		table.insert(state.ticks, { now, ticks });
	end
	Trim(now);
end

-- The window ---------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ApparitionMeterFrame", UIParent);
frame:SetWidth(190);
frame:SetHeight(92);
frame:SetFrameStrata("MEDIUM");
frame:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 8, edgeSize = 10,
	insets = { left = 2, right = 2, top = 2, bottom = 2 },
});
frame:SetBackdropColor(0.06, 0.04, 0.1, 0.85);
frame:SetBackdropBorderColor(0.55, 0.45, 0.85, 1);
frame:SetMovable(true);
frame:EnableMouse(true);
frame:RegisterForDrag("LeftButton");
frame:Hide();

local function Text(font, point, x, y)
	local fs = frame:CreateFontString(nil, "OVERLAY", font);
	fs:SetPoint(point, frame, point, x, y);
	return fs;
end

local title = Text("GameFontNormalSmall", "TOPLEFT", 8, -7);
title:SetText("Shadowy Apparitions");
local big = Text("GameFontNormalLarge", "TOPRIGHT", -8, -5);
big:SetTextColor(1, 1, 1);
local line1 = Text("GameFontHighlightSmall", "TOPLEFT", 8, -42);
local line2 = Text("GameFontHighlightSmall", "TOPLEFT", 8, -56);
local line3 = Text("GameFontHighlightSmall", "TOPLEFT", 8, -70);
line3:SetTextColor(0.65, 0.65, 0.7);

-- a bar for the last window's rate, full at 2 a second
local barBack = frame:CreateTexture(nil, "ARTWORK");
barBack:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background");
barBack:SetVertexColor(0.2, 0.2, 0.25, 0.9);
barBack:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -25);
barBack:SetWidth(174);
barBack:SetHeight(10);
local bar = frame:CreateTexture(nil, "OVERLAY");
bar:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background");
bar:SetVertexColor(0.6, 0.4, 1, 1);
bar:SetPoint("TOPLEFT", barBack, "TOPLEFT", 0, 0);
bar:SetHeight(10);
bar:SetWidth(1);

local function Fmt(r)
	if ( not r ) then
		return "n/a";
	end
	return string.format("%.2f", r);
end

local function Draw(now)
	local w = db.window;
	local r = Rate(now, w);
	big:SetText(Fmt(r) .. " /s");
	local fill = (r or 0) / CAP;
	if ( fill > 1 ) then
		fill = 1;
	end
	bar:SetWidth(math.max(1, 174 * fill));
	line1:SetText("last " .. w .. " s: " .. Fmt(r) .. " /s    60 s: " .. Fmt(Rate(now, KEEP)) .. " /s");
	local avg;
	if ( state.startedAt and now - state.startedAt >= 1 ) then
		avg = state.total / (now - state.startedAt);
	end
	line2:SetText("this run: " .. state.total .. " procs, " .. Fmt(avg) .. " /s");
	local tr = TickRate(now, w);
	if ( state.status ~= "listening" ) then
		line3:SetText(state.status);
	elseif ( tr ) then
		line3:SetText("Shadow Word: Pain ticks: " .. string.format("%.0f", tr) .. " /s");
	else
		line3:SetText("cap: 2 procs a second");
	end
end

local function Place()
	frame:ClearAllPoints();
	frame:SetPoint(db.point, UIParent, db.point, db.x, db.y);
end

local function ShouldShow()
	if ( db.hidden ) then
		return false;
	end
	local class;
	if ( UnitClass ) then
		local _, c = UnitClass("player");
		class = c;
	end
	return class == "PRIEST" or state.seen;
end

frame:SetScript("OnDragStart", function()
	if ( not db.locked ) then
		this:StartMoving();
	end
end);
frame:SetScript("OnDragStop", function()
	this:StopMovingOrSizing();
	local point, _, _, x, y = this:GetPoint();
	db.point, db.x, db.y = point, x, y;
end);

local acc = 0;
local driver = CreateFrame("Frame");
driver:SetScript("OnUpdate", function()
	if ( not db ) then
		return;
	end
	local real = GetTime();
	Poll(real);
	acc = acc + (arg1 or 0);
	if ( acc < 0.2 ) then
		return;
	end
	acc = 0;
	if ( ShouldShow() ) then
		if ( not frame:IsShown() ) then
			frame:Show();
		end
		Draw(Now());
	elseif ( frame:IsShown() ) then
		frame:Hide();
	end
end);

local function Load()
	if ( db ) then
		return;
	end
	if ( type(ApparitionMeterDB) ~= "table" ) then
		ApparitionMeterDB = {};
	end
	db = ApparitionMeterDB;
	for k, v in pairs(DEFAULTS) do
		if ( db[k] == nil ) then
			db[k] = v;
		end
	end
	Place();
end

driver:RegisterEvent("ADDON_LOADED");
driver:RegisterEvent("VARIABLES_LOADED");
driver:SetScript("OnEvent", function()
	if ( event == "VARIABLES_LOADED" or ( event == "ADDON_LOADED" and arg1 == "ApparitionMeter" ) ) then
		Load();
	end
end);

-- /apm ---------------------------------------------------------------------------------------

SLASH_APPARITIONMETER1 = "/apm";
SLASH_APPARITIONMETER2 = "/apparitions";
SlashCmdList["APPARITIONMETER"] = function(msg)
	Load();
	local _, _, cmd, rest = string.find(msg or "", "^ *([^ ]*) *(.-) *$");
	cmd = cmd or "";
	if ( cmd == "show" ) then
		db.hidden = false;
		state.seen = true;
	elseif ( cmd == "hide" ) then
		db.hidden = true;
	elseif ( cmd == "lock" ) then
		db.locked = true;
		Print("locked.");
	elseif ( cmd == "unlock" ) then
		db.locked = false;
		Print("unlocked: drag it to move it.");
	elseif ( cmd == "reset" ) then
		Reset(Now());
		Print("count started again.");
	elseif ( cmd == "window" ) then
		local w = tonumber(rest);
		if ( w and w >= 2 and w <= KEEP ) then
			db.window = math.floor(w);
			Print("main window: last " .. db.window .. " sec.");
		else
			Print("usage: /apm window <2-60>");
		end
	elseif ( cmd == "center" ) then
		db.point, db.x, db.y = "CENTER", 0, -180;
		Place();
	elseif ( cmd == "debug" ) then
		Print("version " .. VERSION .. ", " .. state.status .. ", run " .. tostring(state.run)
			.. ", procs " .. state.total .. ".");
		local keys = state.mindBlastKeys;
		if ( table.getn(keys) == 0 ) then
			Print("no Mind Blast hits seen yet.");
		else
			Print("Mind Blast hits seen (name | meter line | source key):");
			for i = 1, table.getn(keys) do
				DEFAULT_CHAT_FRAME:AddMessage("  " .. keys[i]);
			end
		end
	else
		Print("/apm show | hide | lock | unlock | reset | window <sec> | center | debug");
	end
end;
