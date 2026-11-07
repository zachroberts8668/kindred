-- Kindred: presence and location.
--
-- Sources, strongest first:
--   bnet    Forever Title Friends (Blizzard's own presence data)
--   addon   hidden addon whispers to friends who also run Kindred,
--           and the server's "No player named X is currently playing" reply
--           for friends who are offline (that line is hidden from chat)
--   group   party/raid roster
--   guild   guild roster
--   seen    target/mouseover, /who results
--   timeout no reply and no error: online without the addon (needs 2 in a row)
--
-- Protocol (prefix KindredFvr1, fields joined with "~"):
--   P~v~level~class~zone~flags~map~x~y   presence + please reply (sender lists you)
--   R~v~level~class~zone~flags~map~x~y   reply, sender lists you too
--   N~v                                  reply, online but sender does not list you
--   U~v~level~class~zone~flags~map~x~y   unsolicited update (zone change, AFK...)
-- flags: A = AFK, D = DND. map/x/y are empty unless the sender shares position.

local _, ns = ...
local Names = ns.Names

local Presence = {}
ns.Presence = Presence

local PREFIX = "KindredFvr1"
local PROTOCOL = 1
local SEND_INTERVAL = 0.35   -- ~3 messages/second; ~4/s is the observed ceiling
local REPLY_TIMEOUT = 8      -- seconds to wait for a reply or a not-found error
local ERROR_WINDOW = 6       -- seconds a send's not-found line counts as "ours"
local REPLY_COOLDOWN = 20    -- min seconds between replies to the same sender
local STRONG_WINDOW = 45     -- seconds a strong source's verdict beats weaker ones
local ALERT_DEBOUNCE = 30
local MAX_LEVEL = 100

-- Sentinel: Update(key, { field = CLEAR }) removes a field.
local CLEAR = {}
Presence.CLEAR = CLEAR

local SOURCE_RANK = { bnet = 5, addon = 4, group = 3, guild = 2, seen = 1, who = 1, timeout = 0 }

local state = {}        -- key -> presence table (see Update)
local pending = {}      -- key -> ping serial awaiting reply
local lastSent = {}     -- key -> GetTime() of last addon message sent to them
local hideUntil = {}    -- key -> GetTime() until which their not-found line is hidden
local lastReply = {}    -- sender key -> GetTime() of our last reply to them
local lastAlert = {}    -- key -> GetTime() of last alert
local theyPinged = {}   -- key -> GetTime() of their last P to us
local queuedPing = {}   -- key -> true while a ping is waiting in the queue
local prompted = {}     -- key -> true once we offered "add back" this session
local loginSettled = false
local lastSweep, sweepCount, serial = 0, 0, 0
local wasInInstance = false

local function Interval()
	return math.max(30, ns.db.settings.pingInterval or 60)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function IsStale(s)
	return s.time and (GetTime() - s.time) > Interval() * 3 + 30
end

-- Current presence, or nil when unknown or too old to trust.
function Presence.Get(key)
	local s = state[key]
	if not s or s.online == nil or IsStale(s) then return nil end
	return s
end

function Presence.IsOnline(key)
	local s = Presence.Get(key)
	return s ~= nil and s.online == true
end

function Presence.Forget(key)
	state[key], pending[key], lastSent[key], theyPinged[key] = nil, nil, nil, nil
end

local function FriendLink(f)
	return Names.Link(f.first, f.last)
end

local function Alert(key, online)
	if not loginSettled or not ns.db.settings.alerts then return end
	local f = ns.GetFriend(key)
	if not f or f.muted then return end
	local now = GetTime()
	if lastAlert[key] and now - lastAlert[key] < ALERT_DEBOUNCE then return end
	lastAlert[key] = now
	if online then
		ns.SystemMessage(FriendLink(f) .. " has come online.")
		if ns.db.settings.alertSound and SOUNDKIT then
			PlaySound(SOUNDKIT.UI_BNET_TOAST or SOUNDKIT.TELL_MESSAGE)
		end
	else
		ns.SystemMessage(Names.Display(f.first, f.last) .. " has gone offline.")
	end
end

local function LevelAlert(key, level)
	if not loginSettled or not ns.db.settings.levelAlerts then return end
	local f = ns.GetFriend(key)
	if not f or f.muted then return end
	ns.SystemMessage(FriendLink(f) .. " has reached level " .. level .. "!")
end

-- Merge new presence info for a friend. Only non-nil fields overwrite;
-- CLEAR removes a field. A weaker source can't flip online/offline shortly
-- after a stronger one decided.
local function Update(key, info)
	local f = ns.GetFriend(key)
	if not f then return end
	local now = GetTime()
	local s = state[key]
	if not s then
		s = {}
		state[key] = s
	end
	local wasKnown = s.online ~= nil and not IsStale(s)
	local wasOnline = s.online == true
	local rank = SOURCE_RANK[info.source] or 0

	if info.online ~= nil and wasKnown and info.online ~= wasOnline
		and s.rank and rank < s.rank and now - (s.rankTime or 0) < STRONG_WINDOW
	then
		return -- a stronger source said otherwise moments ago
	end

	local oldLevel = s.level
	for k, v in pairs(info) do
		if v == CLEAR then s[k] = nil else s[k] = v end
	end
	s.time = now
	if info.online ~= nil then
		s.rank, s.rankTime = rank, now
	end

	if s.online then
		f.lastSeen = f.lastSeen or {}
		f.lastSeen.time = time()
		if type(info.zone) == "string" then f.lastSeen.zone = info.zone end
		if info.level then f.lastSeen.level = info.level end
		if info.class then f.lastSeen.class = info.class end
	end

	if wasKnown and wasOnline ~= (s.online == true) then
		Alert(key, s.online == true)
	end
	if oldLevel and info.level and info.level > oldLevel and s.online then
		LevelAlert(key, info.level)
	end
	ns.RequestRefresh()
end
Presence.Update = Update

local function MarkOffline(key)
	pending[key] = nil
	Update(key, { online = false, afk = false, dnd = false, unreachable = false,
		misses = 0, map = CLEAR, source = "addon" })
end

---------------------------------------------------------------------------
-- Outgoing queue: 1 = replies, 2 = updates and priority pings, 3 = sweep pings
---------------------------------------------------------------------------

local queue = { {}, {}, {} }
local pumpTicker
local backoffUntil = 0

local RESULT = Enum and Enum.SendAddonMessageResult
local SUCCESS = RESULT and RESULT.Success or 0
local THROTTLED = RESULT and RESULT.AddonMessageThrottle or 3

local function SendRaw(msg, target)
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return "fail" end
	local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "WHISPER", target)
	if not ok then return "fail" end
	if res == nil or res == true or res == SUCCESS then return "ok" end
	if res == THROTTLED then return "throttled" end
	return "fail"
end

local function NextItem()
	for p = 1, 3 do
		local q = queue[p]
		while #q > 0 do
			local item = table.remove(q, 1)
			if not item.valid or item.valid() then
				return item, p
			end
		end
	end
end

local function Pump()
	if GetTime() < backoffUntil then return end
	local item, p = NextItem()
	if not item then
		pumpTicker:Cancel()
		pumpTicker = nil
		return
	end
	local msg = type(item.msg) == "function" and item.msg() or item.msg
	local result = SendRaw(msg, item.target)
	if result == "throttled" then
		table.insert(queue[p], 1, item)
		backoffUntil = GetTime() + 1.5
		return
	end
	if item.key and result == "ok" then
		lastSent[item.key] = GetTime()
	end
	if item.onSent then item.onSent(result == "ok") end
end

local function Enqueue(priority, item)
	table.insert(queue[priority], item)
	if not pumpTicker then
		pumpTicker = C_Timer.NewTicker(SEND_INTERVAL, Pump)
	end
end

local function InLockdown()
	local api = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	if type(api) ~= "function" then return false end
	local ok, locked = pcall(api)
	if not ok or not Names.IsSafeValue(locked) then return true end
	return locked == true
end

-- Addon messages to other players are blocked inside instances on Forever,
-- and during chat-messaging lockdown (encounters).
local function CanMessage()
	return not IsInInstance() and not InLockdown()
end

---------------------------------------------------------------------------
-- Payloads
---------------------------------------------------------------------------

local function Clean(s)
	if not Names.IsSafe(s) then return "" end
	return (s:gsub("[~|]", ""))
end

local function MyPosition()
	if not ns.db.settings.shareMapPosition or not C_Map or not C_Map.GetBestMapForUnit then return "", "", "" end
	local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
	if not ok or not Names.IsSafeValue(mapID) or type(mapID) ~= "number" then return "", "", "" end
	local okP, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not okP or not pos or Names.IsSecret(pos) then return "", "", "" end
	local okXY, x, y = pcall(pos.GetXY, pos)
	if not okXY or not Names.IsSafeValue(x) or not Names.IsSafeValue(y) or type(x) ~= "number" then
		return "", "", ""
	end
	return tostring(mapID), tostring(math.floor(x * 1000 + 0.5)), tostring(math.floor(y * 1000 + 0.5))
end

local function MyPayload()
	local level = UnitLevel("player") or 0
	local _, class = UnitClass("player")
	local zone = (GetRealZoneText and GetRealZoneText()) or GetZoneText() or ""
	local flags = ""
	if UnitIsAFK("player") then flags = flags .. "A" end
	if UnitIsDND("player") then flags = flags .. "D" end
	local mapID, x, y = MyPosition()
	return table.concat({ tostring(PROTOCOL), tostring(level), Clean(class), Clean(zone), flags, mapID, x, y }, "~")
end

local function ValidClass(c)
	if not c or not c:match("^[A-Z]+$") then return nil end
	if (RAID_CLASS_COLORS and RAID_CLASS_COLORS[c]) or (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c]) then
		return c
	end
end

-- Everything here came from another player: validate and strip escapes.
local function ParsePayload(fields)
	local level = tonumber(fields[3])
	if level then
		level = math.floor(level)
		if level < 1 or level > MAX_LEVEL then level = nil end
	end
	local zone = Names.StripEscapes(fields[5] or "")
	zone = zone and Names.Truncate(zone, 64) or nil
	if zone == "" then zone = nil end
	local flags = fields[6] or ""
	local info = {
		online = true,
		addon = true,
		mutual = true,
		unreachable = false,
		misses = 0,
		level = level,
		class = ValidClass(fields[4]),
		zone = zone or CLEAR,
		afk = flags:find("A", 1, true) ~= nil,
		dnd = flags:find("D", 1, true) ~= nil,
		source = "addon",
		map = CLEAR,
	}
	local mapID, x, y = tonumber(fields[7]), tonumber(fields[8]), tonumber(fields[9])
	if mapID and x and y and mapID > 0 and mapID == math.floor(mapID)
		and x >= 0 and x <= 1000 and y >= 0 and y <= 1000
	then
		info.map = { id = mapID, x = x / 1000, y = y / 1000 }
	end
	return info
end

---------------------------------------------------------------------------
-- Pinging
---------------------------------------------------------------------------

local OnTimeout

local function StartPending(key)
	serial = serial + 1
	local mine = serial
	pending[key] = mine
	C_Timer.After(REPLY_TIMEOUT, function()
		if pending[key] ~= mine then return end
		pending[key] = nil
		OnTimeout(key)
	end)
end

-- Ping one friend: sends our presence and asks for theirs.
function Presence.Ping(key, priority)
	local f = ns.GetFriend(key)
	if not f or ns.IsMyKey(key) or queuedPing[key] or pending[key] then return end
	queuedPing[key] = true
	Enqueue(priority and 2 or 3, {
		key = key,
		target = Names.Target(f.first, f.last),
		msg = function() return "P~" .. MyPayload() end,
		valid = function()
			queuedPing[key] = nil
			return ns.GetFriend(key) ~= nil and CanMessage()
		end,
		onSent = function(ok) if ok then StartPending(key) end end,
	})
end

-- No reply and no "not found" error within the timeout.
function OnTimeout(key)
	local s = state[key]
	local misses = ((s and s.misses) or 0) + 1
	if s and s.online and s.addon then
		if misses <= 2 then
			-- Ran the addon a moment ago: probably an instance or lockdown.
			Update(key, { online = true, unreachable = true, misses = misses, source = "timeout" })
		else
			Update(key, { online = true, addon = false, mutual = CLEAR, unreachable = false,
				map = CLEAR, misses = misses, source = "timeout" })
		end
	elseif s and s.online then
		Update(key, { misses = misses })
	elseif not s or s.online == nil or IsStale(s) then
		-- First thing we learn about them this session.
		Update(key, { online = true, addon = false, unreachable = false, misses = misses, source = "timeout" })
	elseif misses >= 2 then
		Update(key, { online = true, addon = false, unreachable = false, misses = misses, source = "timeout" })
	else
		-- Offline before; one silent ping isn't enough. Check again soon.
		s.misses = misses
		C_Timer.After(15, function() Presence.Ping(key, true) end)
	end
end

-- Ping every friend through the queue.
function Presence.PingAll(force)
	local now = GetTime()
	if not force and now - lastSweep < 15 then return end
	if #queue[3] > 0 then return end -- previous sweep still sending
	if not CanMessage() then return end
	lastSweep = now
	sweepCount = sweepCount + 1
	local interval = Interval()
	for key in pairs(ns.db.friends) do
		local s = state[key]
		local skip = ns.IsMyKey(key)
		-- Their P already told us they're online; our R answered it.
		if theyPinged[key] and now - theyPinged[key] < interval then skip = true end
		-- Blizzard is already telling us about Title Friends.
		if s and s.bnet and s.time and now - s.time < interval * 2 then skip = true end
		-- Known-offline friends are checked every other sweep.
		if not force and s and s.online == false and not IsStale(s) and sweepCount % 2 == 1 then skip = true end
		if not skip then Presence.Ping(key) end
	end
end

local function Reply(kind, sender, senderKey)
	local now = GetTime()
	if lastReply[senderKey] and now - lastReply[senderKey] < REPLY_COOLDOWN then return end
	lastReply[senderKey] = now
	local friendKey = ns.GetFriend(senderKey) and senderKey or nil
	Enqueue(1, {
		key = friendKey,
		target = sender,
		msg = kind == "R" and function() return "R~" .. MyPayload() end or ("N~" .. PROTOCOL),
		valid = CanMessage,
	})
end

-- Tell friends we know are running the addon about a zone/AFK/level change.
local updateQueued = false
local function BroadcastUpdate()
	if updateQueued then return end
	updateQueued = true
	C_Timer.After(2, function()
		updateQueued = false
		if not CanMessage() then return end
		for key, s in pairs(state) do
			local f = ns.GetFriend(key)
			if f and s.online and s.addon and s.mutual and not IsStale(s) then
				Enqueue(2, {
					key = key,
					target = Names.Target(f.first, f.last),
					msg = function() return "U~" .. MyPayload() end,
					valid = function() return ns.GetFriend(key) ~= nil and CanMessage() end,
				})
			end
		end
	end)
end

local function OnAddonMessage(prefix, msg, channel, sender)
	-- Fields can be secret during lockdown; never compare before checking.
	if Names.IsSecret(prefix) or Names.IsSecret(msg) or Names.IsSecret(channel) or Names.IsSecret(sender) then
		return
	end
	if prefix ~= PREFIX or channel ~= "WHISPER" then return end
	if not Names.IsSafe(msg) or not Names.IsSafe(sender) or #msg > 255 then return end
	local first, last = Names.Split(sender)
	if not first or ns.IsMe(first, last) then return end

	local fields = { strsplit("~", msg) }
	local kind = fields[1]
	local version = tonumber(fields[2])
	if not version or version < 1 then return end
	local key = ns.FindFriend(first, last)
	local senderKey = key or Names.Key(first, last)

	if kind == "P" then
		if key then
			pending[key] = nil
			theyPinged[key] = GetTime()
			ns.AdoptSpelling(key, first, last)
			Update(key, ParsePayload(fields))
			Reply("R", sender, senderKey)
		else
			-- They list us, we don't list them: say we're online, share nothing.
			Reply("N", sender, senderKey)
			if ns.db.settings.addBackPrompt and last and not ns.db.declined[senderKey]
				and not prompted[senderKey] and ns.Social
			then
				prompted[senderKey] = true
				ns.Social.OfferAddBack(first, last)
			end
		end
	elseif not key then
		return
	elseif kind == "R" or kind == "U" then
		pending[key] = nil
		ns.AdoptSpelling(key, first, last)
		Update(key, ParsePayload(fields))
	elseif kind == "N" then
		pending[key] = nil
		ns.AdoptSpelling(key, first, last)
		Update(key, { online = true, addon = true, mutual = false, unreachable = false, misses = 0,
			zone = CLEAR, map = CLEAR, source = "addon" })
	end
end

---------------------------------------------------------------------------
-- "No player named X is currently playing"
---------------------------------------------------------------------------

local notFoundPattern
local function BuildNotFoundPattern()
	local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S
	if type(fmt) ~= "string" then return nil end
	local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	-- "%s" became "%%s" above; turn it into a capture.
	return "^" .. escaped:gsub("%%%%s", "(.+)") .. "$"
end

local function NotFoundKey(msg)
	if not notFoundPattern or not Names.IsSafe(msg) then return nil end
	local name = msg:match(notFoundPattern)
	if not name then return nil end
	return (ns.FindFriendByText(name))
end

-- The server says they're not online: authoritative whoever caused it.
local function OnSystemMessage(msg)
	local key = NotFoundKey(msg)
	if key then MarkOffline(key) end
end

-- Hide the line only when our own addon message caused it. Each chat frame
-- runs the filter, so remember the decision briefly for the other frames.
local function SystemFilter(_, _, msg)
	local key = NotFoundKey(msg)
	if not key then return false end
	local now = GetTime()
	if hideUntil[key] and now <= hideUntil[key] then return true end
	if lastSent[key] and now - lastSent[key] < ERROR_WINDOW then
		lastSent[key] = nil
		hideUntil[key] = now + 0.5
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Passive sightings
---------------------------------------------------------------------------

local function Sighting(first, last, info)
	if not first then return end
	local key = ns.FindFriend(first, last)
	if not key or ns.IsMyKey(key) then return end
	local s = state[key]
	if info.online then
		info.unreachable = false
		if s and s.addon and s.online then
			info.addon, info.mutual = nil, nil -- keep the richer addon data
		end
	else
		pending[key] = nil
		info.map = CLEAR
	end
	Update(key, info)
end
Presence.Sighting = Sighting

local function SafeNumber(v)
	if not Names.IsSafeValue(v) or type(v) ~= "number" then return nil end
	return v > 0 and v or nil
end

local function SafeString(v)
	return Names.IsSafe(v) and v or nil
end

local function ScanGuild()
	if next(ns.db.friends) == nil or not IsInGuild() or not GetNumGuildMembers then return end
	local n = GetNumGuildMembers() or 0
	for i = 1, n do
		local name, _, _, level, _, zone, _, _, online, _, classFile = GetGuildRosterInfo(i)
		if Names.IsSafe(name) then
			local first, last = Names.Split(name)
			local isOnline = Names.IsSafeValue(online) and online and true or false
			Sighting(first, last, {
				online = isOnline,
				level = SafeNumber(level),
				class = ValidClass(SafeString(classFile)),
				zone = isOnline and SafeString(zone) or nil,
				source = "guild",
			})
		end
	end
end

local function ScanUnit(unit, zone, source)
	local first, last = Names.FromUnit(unit)
	if not first then return end
	local okC, connected = pcall(UnitIsConnected, unit)
	local isOnline = not okC or not Names.IsSafeValue(connected) or connected and true or false
	local okL, level = pcall(UnitLevel, unit)
	local okK, _, classFile = pcall(UnitClass, unit)
	Sighting(first, last, {
		online = isOnline,
		level = okL and SafeNumber(level) or nil,
		class = okK and ValidClass(SafeString(classFile)) or nil,
		zone = isOnline and zone or nil,
		source = source,
	})
end

local function ScanGroup()
	if next(ns.db.friends) == nil then return end
	if IsInRaid() then
		for i = 1, (GetNumGroupMembers() or 0) do
			local _, _, _, _, _, _, zone = GetRaidRosterInfo(i)
			ScanUnit("raid" .. i, SafeString(zone), "group")
		end
	elseif IsInGroup() then
		for i = 1, 4 do
			if UnitExists("party" .. i) then ScanUnit("party" .. i, nil, "group") end
		end
	end
end

local function ScanWho()
	if not (C_FriendList and C_FriendList.GetNumWhoResults) then return end
	local n = C_FriendList.GetNumWhoResults() or 0
	for i = 1, n do
		local info = C_FriendList.GetWhoInfo(i)
		if info and Names.IsSafe(info.fullName) then
			local first, last = Names.Split(info.fullName)
			Sighting(first, last, {
				online = true,
				level = SafeNumber(info.level),
				class = ValidClass(SafeString(info.filename)),
				zone = SafeString(info.area),
				source = "who",
			})
		end
	end
	if ns.Social then ns.Social.OnWhoResults() end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function Presence.Init()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	end
	notFoundPattern = BuildNotFoundPattern()

	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		addFilter("CHAT_MSG_SYSTEM", SystemFilter)
	end

	ns.On("CHAT_MSG_ADDON", OnAddonMessage)
	ns.On("CHAT_MSG_SYSTEM", OnSystemMessage)
	ns.On("GUILD_ROSTER_UPDATE", ScanGuild)
	ns.On("GROUP_ROSTER_UPDATE", ScanGroup)
	ns.On("WHO_LIST_UPDATE", ScanWho)
	ns.On("PLAYER_TARGET_CHANGED", function() ScanUnit("target", GetZoneText(), "seen") end)
	ns.On("UPDATE_MOUSEOVER_UNIT", function() ScanUnit("mouseover", GetZoneText(), "seen") end)
	ns.On("ZONE_CHANGED_NEW_AREA", BroadcastUpdate)
	ns.On("PLAYER_LEVEL_UP", BroadcastUpdate)
	ns.On("PLAYER_FLAGS_CHANGED", function(unit)
		if unit == "player" then BroadcastUpdate() end
	end)
	-- Coming back out of a dungeon: refresh right away instead of waiting.
	ns.On("PLAYER_ENTERING_WORLD", function()
		local inInstance = IsInInstance() and true or false
		if wasInInstance and not inInstance then
			C_Timer.After(3, function() Presence.PingAll(true) end)
		end
		wasInInstance = inInstance
	end)

	-- First sweep a few seconds after login; alerts start after it settles so
	-- logging in doesn't spam "has come online" for everyone.
	C_Timer.After(5, function()
		Presence.PingAll(true)
		if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
		ScanGroup()
		C_Timer.After(REPLY_TIMEOUT + 10, function() loginSettled = true end)
	end)

	C_Timer.NewTicker(Interval(), function()
		Presence.PingAll()
		if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
			C_GuildInfo.GuildRoster()
		end
		ns.RequestRefresh() -- lets stale entries fall back to "last seen"
	end)
end

function Presence.DebugDump()
	local count = 0
	for key, s in pairs(state) do
		count = count + 1
		ns.Print(string.format("  %s: online=%s addon=%s mutual=%s zone=%s src=%s misses=%s",
			key, tostring(s.online), tostring(s.addon), tostring(s.mutual),
			tostring(s.zone), tostring(s.source), tostring(s.misses)))
	end
	local q = #queue[1] + #queue[2] + #queue[3]
	ns.Print("  " .. count .. " friends with presence data; " .. q .. " queued; prefix " .. PREFIX)
end
