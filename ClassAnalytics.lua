-- Class Analytics: your procs per second, live. Every hit the game credits to a talent, an armor
-- set, an amulet, an item or a jewel is grouped by that source: how many procs and hits it gives a
-- second, and its share of your damage. On top, a block for your class: its key proc with a bar
-- toward the most it can go off a second, and your main damage-over-time spell's ticks.
-- Written for Lua 5.0 (WoW 1.12): no #, no %, no string.match, no select.

local VERSION = "0.3.0";
local KEEP = 60;        -- seconds of history kept for the windows
local POLL = 0.1;       -- how often the feed is read, in real seconds
local MERGE = 0.1;      -- one source's hits closer than this are one proc
local ROW_H = 13;

-- Each class's block. proc: a talent that goes off at most `cap` times a second (its hits closer
-- than 0.3 sec are one proc), with its bar's color (r, g, b); dot: the damage-over-time spell
-- whose ticks are shown. A class without a capped proc shows its busiest proc instead.
local FOCUS = {
	priest = { proc = "shadowy_apparitions", name = "Shadowy Apparitions", cap = 2, dot = "Shadow Word: Pain",
		color = { 0.6, 0.4, 1 } },        -- shadow violet
	warlock = { proc = "nightfall", name = "Nightfall", cap = 2, dot = "Corruption",
		color = { 0.8, 0.38, 0.9 } },     -- warlock magenta-violet
	paladin = { proc = "art_of_war", name = "The Art of War", cap = 1,
		color = { 1, 0.8, 0.3 } },        -- holy gold
	hunter = { proc = "rapid_fire", name = "Rapid Fire", cap = 2, dot = "Serpent Sting",
		color = { 0.67, 0.83, 0.45 } },   -- hunter green
	mage = { proc = "hot_streak", name = "Hot Streak", cap = 2, dot = "Ignite",
		color = { 1, 0.5, 0.12 } },       -- fire orange
	warrior = { dot = "Rend" },
	rogue = { dot = "Rupture" },
	shaman = { dot = "Flame Shock" },
	druid = { dot = "Moonfire" },
};
local CLASS_IDS = { [1] = "warrior", [2] = "paladin", [3] = "hunter", [4] = "rogue", [5] = "priest",
	[7] = "shaman", [8] = "mage", [9] = "warlock", [11] = "druid" };

local DEFAULTS = { window = 10, rows = 8, own = false, locked = false, hidden = false,
	focus = true, alpha = 0.85, minimapHidden = false,
	point = "CENTER", x = 0, y = -160 };

local db;
local state = {
	src = {}, list = {},  -- sources by id, and in the order they were first seen
	dot = {},             -- { time, count } of your class's damage-over-time ticks
	dotBatch = 0,
	class = nil,          -- "priest", "hunter"... from the run's line
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

-- Your class, from the run's line (the hero's class in this game, which the client's own
-- UnitClass doesn't give), or else UnitClass's.
local function ClassNow()
	local c = type(AZS_ZONE) == "table" and AZS_ZONE.class;
	if ( type(c) == "number" ) then
		c = CLASS_IDS[c] or AZS_ZONE.cname;
	end
	if ( type(c) == "string" and c ~= "" ) then
		state.runClass = Norm(c);
	end
	if ( state.runClass ) then
		return state.runClass;
	end
	if ( UnitClass ) then
		local _, t = UnitClass("player");
		if ( type(t) == "string" and t ~= "" ) then
			return Norm(t);
		end
	end
	return nil;
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
	state.src, state.list, state.dot = {}, {}, {};
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
	local focus = FOCUS[state.class or ""];
	if ( periodic and focus and focus.dot and Has(ability, Norm(focus.dot)) ) then
		state.dotBatch = state.dotBatch + 1;
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
	-- a class's capped proc can't come again within 1/cap sec: hits closer than 0.3 sec are one
	local merge = MERGE;
	if ( focus and focus.proc and ( id == "talent:" .. Norm(focus.proc) or id == "meter:" .. Norm(focus.name) ) ) then
		merge = 0.3;
	end
	if ( t - s.last >= merge ) then
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
		state.runClass = nil;
		Reset(now);
	end
	state.class = ClassNow();
	state.dotBatch = 0;
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
	if ( state.dotBatch > 0 ) then
		table.insert(state.dot, { now, state.dotBatch });
	end
	Trim(state.dot, cut, true);
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

-- built-in textures only: the browser version doesn't load an addon's own
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 8, edgeSize = 10,
	insets = { left = 2, right = 2, top = 2, bottom = 2 },
};

local ui = {};
local frame = CreateFrame("Frame", "ClassAnalyticsFrame", UIParent);
ui.frame = frame;
frame:SetWidth(300);
frame:SetHeight(120);
frame:SetFrameStrata("MEDIUM");
frame:SetBackdrop(BACKDROP);
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
ui.dot = Text("GameFontHighlightSmall", 0.65, 0.65, 0.7);

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

-- Do you have talent `key`? From the meter's list of your talents, if it has one.
local function HasTalent(key)
	local st = AZS_ML and AZS_ML.st;
	local l = type(st) == "table" and type(st.loadouts) == "table" and st.loadouts[st.owner];
	local talents = type(l) == "table" and l.talents;
	if ( type(talents) ~= "table" ) then
		return false;
	end
	local want = Norm(key);
	for i = 1, table.getn(talents) do
		local t = talents[i];
		local s = type(t) == "table" and type(st.sources) == "table" and st.sources[t.sourceKey];
		if ( type(s) == "table" and ( Norm(s.talentKey) == want or Norm(t.sourceKey) == want ) ) then
			return true;
		end
		if ( type(t) == "table" and ( Norm(t.talentKey) == want or Norm(t.key) == want ) ) then
			return true;
		end
	end
	return false;
end

-- your busiest proc this window, for a class without a capped one
local function TopProc(now, w)
	local best, bestRate;
	for i = 1, table.getn(state.list) do
		local s = state.list[i];
		if ( s.kind ~= "own" ) then
			local r = Rate(s.procs, now, w) or 0;
			if ( r > 0 and ( not bestRate or r > bestRate ) ) then
				best, bestRate = s, r;
			end
		end
	end
	return best, bestRate;
end

local function HideFocus()
	ui.focus:Hide(); ui.focusRate:Hide(); ui.barBack:Hide(); ui.bar:Hide();
end

-- your class's block, from height `y`; returns the height below it
local function DrawFocus(now, w, y)
	local focus = db.focus ~= false and FOCUS[state.class or ""];
	if ( not focus ) then
		HideFocus();
		ui.dot:Hide();
		return y;
	end
	local src = focus.proc and ( state.src["talent:" .. Norm(focus.proc)] or state.src["meter:" .. Norm(focus.name)] );
	if ( focus.proc and ( src or HasTalent(focus.proc) ) ) then
		-- the capped proc, with a bar toward its cap
		local r = src and Rate(src.procs, now, w);
		ui.focus:SetText(focus.name);
		ui.focusRate:SetText(Fmt(r) .. " /s of " .. focus.cap);
		Put(ui.focus, "TOPLEFT", 8, y);
		Put(ui.focusRate, "TOPRIGHT", 292, y + 2);
		ui.barBack:ClearAllPoints();
		ui.barBack:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, y - 14);
		ui.bar:ClearAllPoints();
		ui.bar:SetPoint("TOPLEFT", ui.barBack, "TOPLEFT", 0, 0);
		local fill = (r or 0) / focus.cap;
		if ( fill > 1 ) then
			fill = 1;
		end
		ui.bar:SetWidth(math.max(1, 284 * fill));
		-- the proc's own color, and a dim shade of it for the empty part
		local c = focus.color;
		if ( c ) then
			ui.bar:SetVertexColor(c[1], c[2], c[3], 1);
			ui.barBack:SetVertexColor(c[1] * 0.3, c[2] * 0.3, c[3] * 0.3, 0.9);
		end
		ui.focus:Show(); ui.focusRate:Show(); ui.barBack:Show(); ui.bar:Show();
		y = y - 26;
	else
		-- no capped proc (or not taken): your busiest one, without a bar
		local best, rate = TopProc(now, w);
		HideFocus();
		if ( best ) then
			ui.focus:SetText("Top proc: " .. Short(best.name));
			ui.focusRate:SetText(Fmt(rate) .. " /s");
			Put(ui.focus, "TOPLEFT", 8, y);
			Put(ui.focusRate, "TOPRIGHT", 292, y + 2);
			ui.focus:Show(); ui.focusRate:Show();
			y = y - 16;
		end
	end
	-- your main damage-over-time spell's ticks, once it has ticked
	local dr = focus.dot and Rate(state.dot, now, w, true);
	if ( dr and dr > 0 ) then
		ui.dot:SetText(focus.dot .. " ticks: " .. string.format("%.0f", dr) .. " /s");
		Put(ui.dot, "TOPLEFT", 8, y);
		ui.dot:Show();
		y = y - 14;
	else
		ui.dot:Hide();
	end
	return y - 4;
end

-- every source with something this window, the most procs first. Your own spells only while
-- they're switched on: ones counted before you switched them off leave the list at once.
local function Sorted(now, w)
	local rows = {};
	for i = 1, table.getn(state.list) do
		local s = state.list[i];
		if ( db.own or s.kind ~= "own" ) then
			local pr = Rate(s.procs, now, w) or 0;
			local hr = Rate(s.hits, now, w, true) or 0;
			local tr = Rate(s.ticks, now, w, true) or 0;
			table.insert(rows, { s = s, pr = pr, hr = hr, tr = tr });
		end
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
	return table.getn(state.list) > 0 or FOCUS[state.class or ""] ~= nil;
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

-- The settings window and the minimap button --------------------------------------------------

local PI = 3.14159265;
local opt = { checks = {}, steppers = {} };   -- the settings window's pieces, and opt.mini the button

local function ApplyLook()
	frame:SetBackdropColor(0.06, 0.04, 0.1, db.alpha);
end

local function FlatButton(parent, text, w, h, onClick)
	local b = CreateFrame("Button", nil, parent);
	b:SetWidth(w);
	b:SetHeight(h);
	b:SetBackdrop(BACKDROP);
	b:SetBackdropColor(0.12, 0.12, 0.16, 0.95);
	b:SetBackdropBorderColor(0.4, 0.4, 0.5, 1);
	b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	b.text:SetPoint("CENTER", b, "CENTER", 0, 0);
	b.text:SetText(text);
	b:SetScript("OnClick", onClick);
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(1, 0.82, 0, 1); end);
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(0.4, 0.4, 0.5, 1); end);
	return b;
end

local function OptionsRefresh()
	if ( not opt.frame ) then
		return;
	end
	for i = 1, table.getn(opt.checks) do
		local c = opt.checks[i];
		if ( c.get() ) then
			c.mark:Show();
		else
			c.mark:Hide();
		end
	end
	for i = 1, table.getn(opt.steppers) do
		local s = opt.steppers[i];
		s.value:SetText(s.fmt(s.get()));
	end
end

local function OptLabel(y, text)
	local fs = opt.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	fs:SetTextColor(0.8, 0.8, 0.85);
	fs:SetPoint("TOPLEFT", opt.frame, "TOPLEFT", 14, y);
	fs:SetText(text);
	return fs;
end

-- a box to tick on the right of its label
local function OptCheck(y, label, get, set)
	OptLabel(y - 2, label);
	local b = FlatButton(opt.frame, "", 16, 16, function()
		set(not get());
		OptionsRefresh();
	end);
	b:SetPoint("TOPRIGHT", opt.frame, "TOPRIGHT", -14, y);
	local mark = b:CreateTexture(nil, "OVERLAY");
	mark:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background");
	mark:SetVertexColor(0.75, 0.55, 1, 1);
	mark:SetWidth(8);
	mark:SetHeight(8);
	mark:SetPoint("CENTER", b, "CENTER", 0, 0);
	table.insert(opt.checks, { get = get, mark = mark });
end

-- a number with - and + (shift: five steps)
local function OptStepper(y, label, get, set, step, lo, hi, fmt)
	OptLabel(y - 3, label);
	local function Nudge(n)
		if ( IsShiftKeyDown and IsShiftKeyDown() ) then
			n = n * 5;
		end
		local v = math.floor((get() + n * step) / step + 0.5) * step;
		set(math.max(lo, math.min(hi, v)));
		OptionsRefresh();
	end
	local plus = FlatButton(opt.frame, "+", 20, 18, function() Nudge(1); end);
	plus:SetPoint("TOPRIGHT", opt.frame, "TOPRIGHT", -14, y);
	local minus = FlatButton(opt.frame, "-", 20, 18, function() Nudge(-1); end);
	minus:SetPoint("TOPRIGHT", opt.frame, "TOPRIGHT", -96, y);
	local value = opt.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	value:SetPoint("TOP", opt.frame, "TOPRIGHT", -65, y - 3);
	table.insert(opt.steppers, { get = get, value = value, fmt = fmt });
end

local function ShowMinimapButton(show)
	db.minimapHidden = not show;
	if ( opt.mini and show ) then
		opt.mini:Show();
	elseif ( opt.mini ) then
		opt.mini:Hide();
	end
end

local function MakeOptions()
	if ( opt.frame ) then
		return opt.frame;
	end
	local f = CreateFrame("Frame", "ClassAnalyticsOptions", UIParent);
	opt.frame = f;
	f:SetWidth(280);
	f:SetFrameStrata("DIALOG");
	f:SetBackdrop(BACKDROP);
	f:SetBackdropColor(0.06, 0.04, 0.1, 0.95);
	f:SetBackdropBorderColor(0.55, 0.45, 0.85, 1);
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 80);
	f:SetMovable(true);
	f:EnableMouse(true);
	f:RegisterForDrag("LeftButton");
	f:SetScript("OnDragStart", function() this:StartMoving(); end);
	f:SetScript("OnDragStop", function() this:StopMovingOrSizing(); end);
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal");
	title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12);
	title:SetText("Class Analytics " .. VERSION);
	local close = FlatButton(f, "x", 18, 18, function() f:Hide(); end);
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10);
	local y = -42;
	OptCheck(y, "Show the window", function() return not db.hidden; end, function(v) db.hidden = not v; end);
	y = y - 24;
	OptCheck(y, "Lock its position", function() return db.locked; end, function(v) db.locked = v; end);
	y = y - 24;
	OptCheck(y, "Show your class's block", function() return db.focus; end, function(v) db.focus = v; end);
	y = y - 24;
	OptCheck(y, "List your own spells too", function() return db.own; end, function(v) db.own = v; end);
	y = y - 24;
	OptCheck(y, "Minimap button", function() return not db.minimapHidden; end, ShowMinimapButton);
	y = y - 32;
	OptStepper(y, "Rates over the last", function() return db.window; end, function(v) db.window = v; end,
		1, 2, KEEP, function(v) return v .. " sec"; end);
	y = y - 26;
	OptStepper(y, "Sources shown", function() return db.rows; end, function(v) db.rows = v; end,
		1, 1, 20, function(v) return tostring(v); end);
	y = y - 26;
	OptStepper(y, "Background", function() return math.floor(db.alpha * 100 + 0.5); end,
		function(v) db.alpha = v / 100; ApplyLook(); end, 5, 0, 100, function(v) return v .. "%"; end);
	y = y - 34;
	local reset = FlatButton(f, "Reset the count", 120, 20, function()
		Reset(Now());
		Print("count started again.");
	end);
	reset:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y);
	local center = FlatButton(f, "Center the window", 120, 20, function()
		db.point, db.x, db.y = "CENTER", 0, -160;
		Place();
	end);
	center:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, y);
	y = y - 30;
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	hint:SetTextColor(0.55, 0.55, 0.6);
	hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y);
	hint:SetText("Shift-click - or + for five steps.");
	f:SetHeight(-y + 26);
	-- over the level-up and jewelry cards while it's open
	f:SetScript("OnShow", function()
		if ( type(AZS_SetOnTopOfScreens) == "function" ) then
			pcall(AZS_SetOnTopOfScreens, f, true);
		end
	end);
	f:SetScript("OnHide", function()
		if ( type(AZS_SetOnTopOfScreens) == "function" ) then
			pcall(AZS_SetOnTopOfScreens, f, false);
		end
	end);
	f:Hide();
	return f;
end

local function ToggleOptions()
	local f = MakeOptions();
	if ( f:IsShown() ) then
		f:Hide();
	else
		OptionsRefresh();
		f:Show();
	end
end

-- right-click the window for its settings
frame:SetScript("OnMouseUp", function()
	if ( arg1 == "RightButton" ) then
		ToggleOptions();
	end
end);

-- Spots on the rim the game itself uses: its damage-meter button (about 205 degrees, left and a
-- little below the middle) and the clock under the minimap (about 262). They aren't addon frames,
-- so the search below can't see them: they are counted as taken from the start.
local GAME_SPOTS = { 205, 262 };
local FIRST_ANGLE = 160;    -- where the search for a free spot starts: the upper left

-- the button sits on the minimap's rim, `minimapAngle` degrees round it
local function PlaceMini()
	local a = (db.minimapAngle or FIRST_ANGLE) * PI / 180;
	opt.mini:ClearAllPoints();
	opt.mini:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a));
end

-- A spot on the rim clear of the buttons already there (the game's, and every addon's) and on
-- the screen: the free one nearest the upper left.
local function FreeAngle()
	local cx, cy = Minimap:GetCenter();
	local ms = Minimap:GetEffectiveScale() or 1;
	local taken = { GAME_SPOTS[1], GAME_SPOTS[2] };
	local parents = { Minimap, MinimapCluster };
	for p = 1, 2 do
		local kids = parents[p] and parents[p].GetChildren and { parents[p]:GetChildren() } or {};
		for i = 1, table.getn(kids) do
			local k = kids[i];
			local x, y;
			if ( k ~= opt.mini and k.IsShown and k:IsShown() and k.GetCenter ) then
				x, y = k:GetCenter();
			end
			if ( x and y and cx and cy ) then
				local s = (k:GetEffectiveScale() or 1) / ms;
				local dx, dy = x * s - cx, y * s - cy;
				local d = math.sqrt(dx * dx + dy * dy);
				if ( d > 50 and d < 115 ) then
					table.insert(taken, math.atan2(dy, dx) * 180 / PI);
				end
			end
		end
	end
	local w, h = UIParent:GetWidth(), UIParent:GetHeight();
	local us = UIParent:GetEffectiveScale() or 1;
	for n = 0, 24 do
		-- 160, 175, 145, 190, 130...: outward from the upper left
		local a = FIRST_ANGLE + 15 * math.floor((n + 1) / 2) * ((math.floor(n / 2) * 2 == n) and -1 or 1);
		a = a - 360 * math.floor(a / 360);
		local gap = 180;
		for i = 1, table.getn(taken) do
			local d = math.abs(a - taken[i]);
			d = d - 360 * math.floor(d / 360);
			if ( d > 180 ) then
				d = 360 - d;
			end
			gap = math.min(gap, d);
		end
		local onScreen = true;
		if ( w and h and cx and cy ) then
			local px = (cx + 80 * math.cos(a * PI / 180)) * ms / us;
			local py = (cy + 80 * math.sin(a * PI / 180)) * ms / us;
			onScreen = px > 16 and px < w - 16 and py > 16 and py < h - 16;
		end
		if ( onScreen and gap >= 30 ) then
			return a;
		end
	end
	return FIRST_ANGLE;
end

-- Left-click: the settings. Right-click: show or hide the window. Drag: round the minimap's rim.
local function MakeMinimapButton()
	if ( not Minimap or opt.mini ) then
		return;
	end
	local b = CreateFrame("Button", "ClassAnalyticsMinimapButton", Minimap);
	opt.mini = b;
	b:SetWidth(31);
	b:SetHeight(31);
	b:SetFrameStrata("MEDIUM");
	b:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 10);
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight");
	local icon = b:CreateTexture(nil, "BACKGROUND");
	icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02");
	icon:SetWidth(20);
	icon:SetHeight(20);
	icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -5);
	local border = b:CreateTexture(nil, "OVERLAY");
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder");
	border:SetWidth(53);
	border:SetHeight(53);
	border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0);
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp");
	b:RegisterForDrag("LeftButton");
	b:SetScript("OnClick", function()
		if ( arg1 == "RightButton" ) then
			db.hidden = not db.hidden;
			OptionsRefresh();
		else
			ToggleOptions();
		end
	end);
	b:SetScript("OnDragStart", function()
		b:SetScript("OnUpdate", function()
			local x, y = GetCursorPosition();
			local s = Minimap:GetEffectiveScale();
			local cx, cy = Minimap:GetCenter();
			db.minimapAngle = math.atan2(y / s - cy, x / s - cx) * 180 / PI;
			PlaceMini();
		end);
	end);
	b:SetScript("OnDragStop", function()
		b:SetScript("OnUpdate", nil);
		-- yours from now on: it isn't moved to a free spot again
		db.minimapDragged = true;
	end);
	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(b, "ANCHOR_LEFT");
		GameTooltip:SetText("Class Analytics");
		GameTooltip:AddLine("Left-click: settings", 1, 1, 1);
		GameTooltip:AddLine("Right-click: show or hide the window", 1, 1, 1);
		GameTooltip:AddLine("Drag: move round the minimap", 1, 1, 1);
		GameTooltip:Show();
	end);
	b:SetScript("OnLeave", function()
		GameTooltip:Hide();
	end);
	-- a spot you didn't drag it to is looked for again each time, so the button moves out of the
	-- way of a button that came later (or one this addon didn't know about before)
	if ( not db.minimapDragged ) then
		db.minimapAngle = nil;
	end
	PlaceMini();
	if ( not db.minimapAngle ) then
		-- its first spot, once the game and the other addons have put their buttons up; a drag
		-- before then wins
		local wait = 2;
		b:SetScript("OnUpdate", function()
			wait = wait - (arg1 or 0);
			if ( wait <= 0 ) then
				b:SetScript("OnUpdate", nil);
				db.minimapAngle = db.minimapAngle or FreeAngle();
				PlaceMini();
			end
		end);
	end
	if ( db.minimapHidden ) then
		b:Hide();
	end
end

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
	ApplyLook();
	MakeMinimapButton();
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
	if ( cmd == "" or cmd == "options" or cmd == "settings" ) then
		ToggleOptions();
	elseif ( cmd == "minimap" ) then
		ShowMinimapButton(db.minimapHidden);
		Print(db.minimapHidden and "minimap button hidden (/ca minimap brings it back)." or "minimap button shown.");
	elseif ( cmd == "show" ) then
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
		Print("/ca (settings) | show | hide | lock | unlock | center | reset | window <sec> | rows <n> | own | minimap | debug");
	end
end;
