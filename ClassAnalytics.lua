-- Class Analytics: your procs per second, live. Every hit the game credits to a talent, an armor
-- set, an amulet, an item or a jewel is grouped by that source: how many procs and hits it gives a
-- second, and its share of your damage. Your priest's Shadowy Apparitions also gets a bar toward
-- its limit of 2 a second, with your Shadow Word: Pain ticks beside it.
-- Written for Lua 5.0 (WoW 1.12): no #, no %, no string.match, no select.

local VERSION = "0.2.1";
local KEEP = 60;        -- seconds of history kept for the windows
local POLL = 0.1;       -- how often the feed is read, in real seconds
local MERGE = 0.1;      -- one source's hits closer than this are one proc
-- sources whose procs are spaced out: hits closer than this are still the same proc
local MERGES = { ["talent:shadowyapparitions"] = 0.3, ["meter:shadowyapparitions"] = 0.3 };
local APPARITIONS = "talent:shadowyapparitions";
local APPARITIONS_CAP = 2;   -- Shadowy Apparitions can't go past 2 a second
local ROW_H = 13;

local DEFAULTS = { window = 10, rows = 8, own = false, locked = false, hidden = false,
	point = "CENTER", x = 0, y = -160 };

local db;
local state = {
	src = {}, list = {},  -- sources by id, and in the order they were first seen
	pain = {},            -- { time, count } of Shadow Word: Pain ticks
	painBatch = 0,
	procLines = {},       -- the damage meter's lines with the proc tag, by name
	startedAt = nil, run = nil,
	cursor = nil, primed = false, nextPoll = 0, status = "waiting for the feed",
	keys = {},            -- for /ca debug: how recent hits were credited
};

-- "Shadowy Apparitions", "shadowy_apparitions" and "ShadowyApparitions" all give
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
	DEFAULT_CHAT_FRAME:AddMessage("|cff9a7cffClass Analytics:|r " .. msg);
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

-- What a hit's meter key says about where it came from: "talent:shadowy_apparitions:r1",
-- "set:priest.1.empowered", "amulet:fire_lord:r2", "item:...", "jewel:...". Anything else is
-- your own spell.
local function Parse(key)
	if ( type(key) ~= "string" ) then
		return "own", nil;
	end
	local _, _, kind, rest = string.find(key, "^([a-z]+):(.*)$");
	if ( kind == "run" ) then
		local _, _, k2, r2 = string.find(rest, "^([a-z]+):(.*)$");
		if ( k2 ) then
			kind, rest = k2, r2;
		end
	end
	if ( kind == "talent" or kind == "amulet" or kind == "item" or kind == "jewel" or kind == "set" ) then
		local cut = string.find(rest, ":", 1, true);
		if ( cut ) then
			rest = string.sub(rest, 1, cut - 1);
		end
		cut = string.find(rest, ".empowered", 1, true);
		if ( cut ) then
			rest = string.sub(rest, 1, cut - 1);
		end
		return kind, rest;
	end
	return "own", key;
end

local function Reset(now)
	state.src, state.list, state.pain = {}, {}, {};
	state.startedAt = now;
end

-- The meter's description of each source: its name, the talent or item behind it, and where a
-- free cast came from (originSourceKeys: a free Mind Blast's is Shadowy Apparitions). Its own
-- copy is read when it has one; while it doesn't, it is asked for one at most every 5 seconds.
local meter = { at = -100, asks = 0 };

local function Sources(real)
	local st = AZS_ML and AZS_ML.st;
	if ( type(st) == "table" and type(st.sources) == "table" ) then
		meter.how = "its copy";
		return st.sources;
	end
	if ( real - meter.at >= 5 and type(AZS_GetMeterContext) == "function" and type(AZS_GetMeterLoadout) == "function" ) then
		meter.at, meter.asks = real, meter.asks + 1;
		local ok, ctx = pcall(AZS_GetMeterContext);
		if ( ok and type(ctx) == "table" and ctx.runId ) then
			local ok2, l = pcall(AZS_GetMeterLoadout, { apiVersion = 1, runId = ctx.runId });
			if ( ok2 and type(l) == "table" and type(l.sources) == "table" ) then
				meter.sources, meter.how = l.sources, "asking it";
			end
		end
	end
	return meter.sources;
end

-- The first talent, set, amulet, item or jewel in a list of source keys (or in one key).
local function FirstOrigin(list, sources)
	if ( type(list) == "string" ) then
		list = { list };
	end
	if ( type(list) ~= "table" ) then
		return nil;
	end
	for i = 1, table.getn(list) do
		local k2, b2 = Parse(list[i]);
		if ( k2 ~= "own" ) then
			local od = type(sources) == "table" and sources[list[i]];
			return k2, b2, type(od) == "table" and od.name or nil;
		end
	end
	return nil;
end

local ORIGIN_FIELDS = { "originSourceKeys", "meterOriginKeys", "meterOrigins", "originKeys", "origins" };

-- What a hit's source resolves to: its own kind and base, or, for a spell cast by a talent, set
-- or item (an origin, carried on the hit or in the meter's descriptor), that origin's. The last
-- value back is the descriptor, for /ca debug.
local function Resolve(ev, sources)
	local key = ev.meterSourceKey;
	local kind, base = Parse(key);
	local d = type(sources) == "table" and type(key) == "string" and sources[key];
	if ( kind ~= "own" ) then
		return kind, base, nil, d;
	end
	for i = 1, table.getn(ORIGIN_FIELDS) do
		local k2, b2, n2 = FirstOrigin(ev[ORIGIN_FIELDS[i]], sources);
		if ( k2 ) then
			return k2, b2, n2, d;
		end
	end
	if ( type(d) ~= "table" ) then
		return kind, base, nil, d;
	end
	local k3, b3, n3 = FirstOrigin(d.originSourceKeys, sources);
	if ( k3 ) then
		return k3, b3, n3, d;
	end
	-- a source that is a talent's and not one of your spells
	if ( d.talentKey and d.talentKey ~= "" and not ( d.abilityKey and d.abilityKey ~= "" ) ) then
		return "talent", d.talentKey, d.name, d;
	end
	return "own", key, nil, d;
end

-- Resolve, then: a hit the damage meter credits to one of its proc lines ("Shadowy Apparitions"
-- with its proc tag) is that proc's, whatever its key looks like.
local function ResolveAll(ev, sources)
	local kind, base, name, d = Resolve(ev, sources);
	local line = ev.meterSource;
	if ( kind == "own" and type(line) == "string" and state.procLines[Norm(line)] ) then
		return "meter", line, line, d;
	end
	return kind, base, name, d;
end

-- one hit's fields, for /ca debug
local function Fields(t)
	local parts = {};
	for k, v in pairs(t) do
		if ( type(v) == "table" ) then
			local inner = {};
			for i = 1, math.min(table.getn(v), 4) do
				table.insert(inner, tostring(v[i]));
			end
			table.insert(parts, tostring(k) .. "={" .. table.concat(inner, ",") .. "}");
		elseif ( type(v) ~= "function" ) then
			table.insert(parts, tostring(k) .. "=" .. tostring(v));
		end
	end
	table.sort(parts);
	return table.concat(parts, " ");
end

local function Source(id, name, kind)
	local s = state.src[id];
	if ( not s ) then
		s = { id = id, name = name, kind = kind, procs = {}, hits = {}, ticks = {},
			nProcs = 0, nHits = 0, nTicks = 0, last = -100, batchHits = 0, batchTicks = 0 };
		state.src[id] = s;
		table.insert(state.list, s);
	end
	return s;
end

-- the recent hits' sources for /ca debug, one entry per source key: how it was read, the meter's
-- descriptor of it and one hit's own fields
local function NoteKey(key, line, ev, d)
	local keys = state.keys;
	for i = 1, table.getn(keys) do
		if ( keys[i].key == key ) then
			keys[i].line = line;
			return;
		end
	end
	if ( table.getn(keys) >= 10 ) then
		table.remove(keys, 1);
	end
	table.insert(keys, { key = key, line = line, ev = Fields(ev), d = type(d) == "table" and Fields(d) or "none" });
end

-- One event from the feed, at run time `t`; `sources` the meter's descriptors.
local function Take(ev, t, sources)
	if ( type(ev) ~= "table" or ev.kind == "miss" ) then
		return;
	end
	local ability = Norm(ev.abilityName);
	local periodic = Truthy(ev.periodic);
	if ( periodic and Has(ability, "shadowwordpain") ) then
		state.painBatch = state.painBatch + 1;
	end
	local kind, base, originName, d = ResolveAll(ev, sources);
	NoteKey(tostring(ev.meterSourceKey), kind .. ":" .. tostring(base) .. " | " .. tostring(ev.meterSource) .. " | "
		.. tostring(ev.abilityName) .. (periodic and " | tick" or ""), ev, d);
	local id, name;
	if ( kind == "own" ) then
		if ( not db.own ) then
			return;
		end
		id, name = "own:" .. ability, ev.abilityName;
	else
		id = kind .. ":" .. Norm(base);
		-- a free cast is named for what cast it (Shadowy Apparitions), not for the spell (Mind Blast)
		name = originName or ev.meterSource;
		if ( type(name) ~= "string" or name == "" ) then
			name = string.gsub(tostring(base), "_", " ");
		end
	end
	local s = Source(id, tostring(name), kind);
	if ( periodic ) then
		s.batchTicks = s.batchTicks + 1;
		s.nTicks = s.nTicks + 1;
		return;
	end
	s.batchHits = s.batchHits + 1;
	s.nHits = s.nHits + 1;
	if ( t - s.last >= (MERGES[id] or MERGE) ) then
		table.insert(s.procs, t);
		s.nProcs = s.nProcs + 1;
	end
	s.last = t;
end

local function Trim(list, cut, paired)
	while ( list[1] and (paired and list[1][1] or list[1]) < cut ) do
		table.remove(list, 1);
	end
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
	state.painBatch = 0;
	local sources = Sources(real);
	-- the meter's proc lines, by name
	state.procLines = {};
	if ( type(AZS_METER) == "table" ) then
		for i = 1, table.getn(AZS_METER) do
			local line = AZS_METER[i];
			if ( type(line) == "table" and line.name and ( Truthy(line.proc) or line.proc == "1" ) ) then
				state.procLines[Norm(line.name)] = true;
			end
		end
	end
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
				Take(ev, t, sources);
			end
		end
		if ( n < 256 ) then
			break;
		end
	end
	local cut = now - KEEP;
	if ( state.painBatch > 0 ) then
		table.insert(state.pain, { now, state.painBatch });
	end
	Trim(state.pain, cut, true);
	for i = 1, table.getn(state.list) do
		local s = state.list[i];
		if ( s.batchHits > 0 ) then
			table.insert(s.hits, { now, s.batchHits });
			s.batchHits = 0;
		end
		if ( s.batchTicks > 0 ) then
			table.insert(s.ticks, { now, s.batchTicks });
			s.batchTicks = 0;
		end
		Trim(s.procs, cut);
		Trim(s.hits, cut, true);
		Trim(s.ticks, cut, true);
	end
end

-- Per second over the last `w` seconds (or since counting began, if that's shorter).
local function Rate(list, now, w, paired)
	local span = w;
	if ( state.startedAt and now - state.startedAt < span ) then
		span = now - state.startedAt;
	end
	if ( span < 1 ) then
		return nil;
	end
	local n = 0;
	for i = table.getn(list), 1, -1 do
		local e = list[i];
		if ( (paired and e[1] or e) <= now - w ) then
			break;
		end
		n = n + (paired and e[2] or 1);
	end
	return n / span;
end

-- The window ---------------------------------------------------------------------------------

local ui = {};
local frame = CreateFrame("Frame", "ClassAnalyticsFrame", UIParent);
ui.frame = frame;
frame:SetWidth(300);
frame:SetHeight(120);
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

local function Text(font, r, g, b)
	local fs = frame:CreateFontString(nil, "OVERLAY", font);
	if ( r ) then
		fs:SetTextColor(r, g, b);
	end
	return fs;
end

local function Put(fs, point, x, y)
	fs:ClearAllPoints();
	fs:SetPoint(point, frame, "TOPLEFT", x, y);
end

ui.title = Text("GameFontNormalSmall");
ui.title:SetText("Class Analytics");
Put(ui.title, "TOPLEFT", 8, -7);
ui.span = Text("GameFontHighlightSmall", 0.65, 0.65, 0.7);
Put(ui.span, "TOPRIGHT", 292, -7);

-- the Shadowy Apparitions block: a bar toward 2 a second
ui.focus = Text("GameFontHighlightSmall");
ui.focusRate = Text("GameFontNormal", 1, 1, 1);
ui.barBack = frame:CreateTexture(nil, "ARTWORK");
ui.barBack:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background");
ui.barBack:SetVertexColor(0.2, 0.2, 0.25, 0.9);
ui.barBack:SetWidth(284);
ui.barBack:SetHeight(8);
ui.bar = frame:CreateTexture(nil, "OVERLAY");
ui.bar:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background");
ui.bar:SetVertexColor(0.6, 0.4, 1, 1);
ui.bar:SetHeight(8);
ui.bar:SetWidth(1);
ui.pain = Text("GameFontHighlightSmall", 0.65, 0.65, 0.7);

-- the table: source, procs a second, hits a second, share of your damage
ui.head = { Text("GameFontNormalSmall"), Text("GameFontNormalSmall"), Text("GameFontNormalSmall"),
	Text("GameFontNormalSmall") };
ui.head[1]:SetText("Source");
ui.head[2]:SetText("procs/s");
ui.head[3]:SetText("hits/s");
ui.head[4]:SetText("dmg");
ui.rows = {};
ui.foot = Text("GameFontHighlightSmall", 0.65, 0.65, 0.7);

local COLS = { 8, 206, 252, 292 };   -- the name's left edge, then the numbers' right edges

local function Row(i)
	local r = ui.rows[i];
	if ( not r ) then
		r = { Text("GameFontHighlightSmall"), Text("GameFontHighlightSmall"), Text("GameFontHighlightSmall"),
			Text("GameFontHighlightSmall", 0.75, 0.75, 0.8) };
		ui.rows[i] = r;
	end
	return r;
end

local function Fmt(r)
	if ( not r ) then
		return "n/a";
	end
	return string.format("%.2f", r);
end

-- a name short enough for its column (names past ASCII are left whole, not cut mid-letter)
local function Short(name)
	if ( string.len(name) > 26 and not string.find(name, "[\128-\255]") ) then
		return string.sub(name, 1, 25) .. ".";
	end
	return name;
end

-- each meter line's share of your damage, by its name
local function MeterShares()
	local out = {};
	if ( type(AZS_METER) == "table" ) then
		for i = 1, table.getn(AZS_METER) do
			local line = AZS_METER[i];
			if ( type(line) == "table" and line.name ) then
				out[Norm(line.name)] = tonumber(line.share);
			end
		end
	end
	return out;
end

local function ShareText(share)
	if ( not share ) then
		return "";
	end
	if ( share <= 1.0001 ) then
		share = share * 100;
	end
	return string.format("%.0f", share) .. "%";
end

local function PlayerClass()
	if ( UnitClass ) then
		local _, c = UnitClass("player");
		return c;
	end
	return nil;
end

-- the Shadowy Apparitions block, from height `y`; returns the height below it
local function DrawFocus(now, w, y)
	local app = state.src[APPARITIONS] or state.src["meter:shadowyapparitions"];
	if ( not app and PlayerClass() ~= "PRIEST" ) then
		ui.focus:Hide(); ui.focusRate:Hide(); ui.barBack:Hide(); ui.bar:Hide(); ui.pain:Hide();
		return y;
	end
	local r = app and Rate(app.procs, now, w);
	ui.focus:SetText("Shadowy Apparitions");
	ui.focusRate:SetText(Fmt(r) .. " /s of " .. APPARITIONS_CAP);
	Put(ui.focus, "TOPLEFT", 8, y);
	Put(ui.focusRate, "TOPRIGHT", 292, y + 2);
	ui.barBack:ClearAllPoints();
	ui.barBack:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, y - 14);
	ui.bar:ClearAllPoints();
	ui.bar:SetPoint("TOPLEFT", ui.barBack, "TOPLEFT", 0, 0);
	local fill = (r or 0) / APPARITIONS_CAP;
	if ( fill > 1 ) then
		fill = 1;
	end
	ui.bar:SetWidth(math.max(1, 284 * fill));
	local pr = Rate(state.pain, now, w, true);
	ui.pain:SetText("Shadow Word: Pain ticks: " .. (pr and string.format("%.0f", pr) or "n/a") .. " /s");
	Put(ui.pain, "TOPLEFT", 8, y - 26);
	ui.focus:Show(); ui.focusRate:Show(); ui.barBack:Show(); ui.bar:Show(); ui.pain:Show();
	return y - 44;
end

-- every source with something this window, the most procs first
local function Sorted(now, w)
	local rows = {};
	for i = 1, table.getn(state.list) do
		local s = state.list[i];
		local pr = Rate(s.procs, now, w) or 0;
		local hr = Rate(s.hits, now, w, true) or 0;
		local tr = Rate(s.ticks, now, w, true) or 0;
		table.insert(rows, { s = s, pr = pr, hr = hr, tr = tr });
	end
	table.sort(rows, function(a, b)
		if ( a.pr ~= b.pr ) then
			return a.pr > b.pr;
		end
		return (a.hr + a.tr) > (b.hr + b.tr);
	end);
	return rows;
end

local function DrawRows(now, w, y)
	Put(ui.head[1], "TOPLEFT", COLS[1], y);
	for c = 2, 4 do
		Put(ui.head[c], "TOPRIGHT", COLS[c], y);
	end
	y = y - ROW_H - 2;
	local rows = Sorted(now, w);
	local shares = MeterShares();
	local shown = math.min(table.getn(rows), db.rows);
	for i = 1, shown do
		local e, r = rows[i], Row(i);
		r[1]:SetText(Short(e.s.name));
		if ( e.s.nHits > 0 ) then
			r[2]:SetText(string.format("%.2f", e.pr));
			r[3]:SetText(string.format("%.1f", e.hr + e.tr));
		else
			-- only ticks (a burn or a bleed): no procs to count, just its ticks
			r[2]:SetText("ticks");
			r[3]:SetText(string.format("%.1f", e.tr));
		end
		r[4]:SetText(ShareText(shares[Norm(e.s.name)]));
		Put(r[1], "TOPLEFT", COLS[1], y);
		for c = 2, 4 do
			Put(r[c], "TOPRIGHT", COLS[c], y);
		end
		for c = 1, 4 do
			r[c]:Show();
		end
		y = y - ROW_H;
	end
	for i = shown + 1, table.getn(ui.rows) do
		for c = 1, 4 do
			ui.rows[i][c]:Hide();
		end
	end
	return y, shown;
end

local function Draw(now)
	local w = db.window;
	ui.span:SetText("last " .. w .. " s");
	local y, shown = DrawRows(now, w, DrawFocus(now, w, -24));
	if ( shown == 0 ) then
		ui.foot:SetText(state.status == "listening" and "no procs seen yet this run" or state.status);
	else
		local total, t = 0, now - (state.startedAt or now);
		for i = 1, table.getn(state.list) do
			if ( state.list[i].kind ~= "own" ) then
				total = total + state.list[i].nProcs;
			end
		end
		ui.foot:SetText("this run: " .. total .. " procs in " .. math.floor(t / 60) .. ":"
			.. string.format("%02d", math.floor(t - 60 * math.floor(t / 60))));
	end
	Put(ui.foot, "TOPLEFT", 8, y - 3);
	frame:SetHeight(-(y - 3) + 18);
end

local function Place()
	frame:ClearAllPoints();
	frame:SetPoint(db.point, UIParent, db.point, db.x, db.y);
end

local function ShouldShow()
	if ( db.hidden ) then
		return false;
	end
	return table.getn(state.list) > 0 or PlayerClass() == "PRIEST";
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
	Poll(GetTime());
	acc = acc + (arg1 or 0);
	if ( acc < 0.25 ) then
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
	if ( type(ClassAnalyticsDB) ~= "table" ) then
		ClassAnalyticsDB = {};
	end
	db = ClassAnalyticsDB;
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
	if ( event == "VARIABLES_LOADED" or ( event == "ADDON_LOADED" and arg1 == "ClassAnalytics" ) ) then
		Load();
	end
end);

-- /ca ----------------------------------------------------------------------------------------

local function Number(text, lo, hi)
	local n = tonumber(text);
	if ( n and n >= lo and n <= hi ) then
		return math.floor(n);
	end
	return nil;
end

SLASH_CLASSANALYTICS1 = "/ca";
SLASH_CLASSANALYTICS2 = "/classanalytics";
SlashCmdList["CLASSANALYTICS"] = function(msg)
	Load();
	local _, _, cmd, rest = string.find(msg or "", "^ *([^ ]*) *(.-) *$");
	cmd = cmd or "";
	if ( cmd == "show" ) then
		db.hidden = false;
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
		local w = Number(rest, 2, KEEP);
		if ( w ) then
			db.window = w;
			Print("rates over the last " .. w .. " sec.");
		else
			Print("usage: /ca window <2-60>");
		end
	elseif ( cmd == "rows" ) then
		local n = Number(rest, 1, 20);
		if ( n ) then
			db.rows = n;
		else
			Print("usage: /ca rows <1-20>");
		end
	elseif ( cmd == "own" ) then
		db.own = not db.own;
		Print(db.own and "your own spells are listed too (from now on)." or "only procs are listed.");
	elseif ( cmd == "center" ) then
		db.point, db.x, db.y = "CENTER", 0, -160;
		Place();
	elseif ( cmd == "debug" ) then
		Print("version " .. VERSION .. ", " .. state.status .. ", run " .. tostring(state.run)
			.. ", sources " .. table.getn(state.list) .. ", meter " .. tostring(meter.how or "not read")
			.. " (asked " .. meter.asks .. "x).");
		if ( table.getn(state.keys) == 0 ) then
			Print("no hits seen yet.");
		else
			Print("recent hits: key -> read as | meter line | ability, then the meter's entry and one hit's fields:");
			for i = 1, table.getn(state.keys) do
				local e = state.keys[i];
				DEFAULT_CHAT_FRAME:AddMessage("|cffffd100" .. e.key .. "|r -> " .. e.line);
				DEFAULT_CHAT_FRAME:AddMessage("   meter: " .. e.d);
				DEFAULT_CHAT_FRAME:AddMessage("   hit: " .. e.ev);
			end
		end
	else
		Print("/ca show | hide | lock | unlock | center | reset | window <sec> | rows <n> | own | debug");
	end
end;
