-- Kindred: saved data, friend/group management, events and slash commands.

local ADDON_NAME, ns = ...
local Names = ns.Names

ns.VERSION = "1.1.0"
ns.DEFAULT_GROUP = "Friends"

local CHAT_PREFIX = "|cffffd100Kindred:|r "

function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(msg))
end

-- System-yellow message, used for the classic "has come online" alerts.
function ns.SystemMessage(msg)
	local info = ChatTypeInfo and ChatTypeInfo.SYSTEM
	local r, g, b = 1, 1, 0
	if info then r, g, b = info.r, info.g, info.b end
	DEFAULT_CHAT_FRAME:AddMessage(msg, r, g, b)
end

---------------------------------------------------------------------------
-- Event dispatch
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

local function SafeCall(fn, ...)
	if securecallfunction then
		return securecallfunction(fn, ...)
	end
	local ok, err = pcall(fn, ...)
	if not ok then geterrorhandler()(err) end
end

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		SafeCall(list[i], ...)
	end
end)

-- Coalesce UI refreshes triggered by bursts of presence updates.
local refreshQueued = false
function ns.RequestRefresh()
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0.1, function()
		refreshQueued = false
		if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
		if ns.Minimap and ns.Minimap.Refresh then ns.Minimap.Refresh() end
		if ns.MapPins and ns.MapPins.Refresh then ns.MapPins.Refresh() end
	end)
end

---------------------------------------------------------------------------
-- Saved variables (account-wide)
---------------------------------------------------------------------------

local DEFAULT_SETTINGS = {
	alerts = true,
	alertSound = true,
	levelAlerts = true,
	addBackPrompt = true,
	shareMapPosition = true,
	showMapPins = true,
	hideOffline = false,
	sortBy = "status",
	pingInterval = 60,
	minimap = { angle = 210, hide = false },
}

-- Fill in missing settings and replace values of the wrong type.
local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(dst[k]) ~= type(v) then
			if type(v) == "table" then
				dst[k] = {}
				ApplyDefaults(dst[k], v)
			else
				dst[k] = v
			end
		elseif type(v) == "table" then
			ApplyDefaults(dst[k], v)
		end
	end
end

local function InitDB()
	if type(KindredForeverDB) ~= "table" then KindredForeverDB = {} end
	local db = KindredForeverDB
	ns.db = db -- set first: the repair helpers below read ns.db
	db.version = 1
	if type(db.friends) ~= "table" then db.friends = {} end
	if type(db.groups) ~= "table" then db.groups = {} end
	if type(db.collapsed) ~= "table" then db.collapsed = {} end
	if type(db.declined) ~= "table" then db.declined = {} end
	if type(db.settings) ~= "table" then db.settings = {} end
	ApplyDefaults(db.settings, DEFAULT_SETTINGS)
	if type(db.settings.window) ~= "table" then db.settings.window = nil end

	for i = #db.groups, 1, -1 do
		if type(db.groups[i]) ~= "string" then table.remove(db.groups, i) end
	end
	if #db.groups == 0 then
		table.insert(db.groups, ns.DEFAULT_GROUP)
	end

	-- Drop broken entries and re-key everything with the current folding
	-- (older versions only lowercased ASCII).
	local repaired = {}
	for _, f in pairs(db.friends) do
		if type(f) == "table" and type(f.first) == "string" and f.first ~= "" then
			if type(f.last) ~= "string" or f.last == "" then f.last = nil end
			if type(f.note) ~= "string" then f.note = "" end
			if not ns.GroupExists(f.group) then f.group = db.groups[1] end
			if type(f.lastSeen) ~= "table" then f.lastSeen = nil end
			repaired[Names.Key(f.first, f.last)] = f
		end
	end
	db.friends = repaired
end

---------------------------------------------------------------------------
-- Friends
---------------------------------------------------------------------------

function ns.GetFriend(key)
	return key and ns.db.friends[key]
end

-- Find a friend from a parsed name. Falls back to a unique first-name match
-- when there is no surname (e.g. a source that only gives first names).
function ns.FindFriend(first, last)
	if not first then return nil end
	local key = Names.Key(first, last)
	if ns.db.friends[key] then
		return key, ns.db.friends[key]
	end
	if last then return nil end
	local lowered = Names.Lower(first)
	local foundKey, found
	for k, f in pairs(ns.db.friends) do
		if Names.Lower(f.first) == lowered then
			if foundKey then return nil end -- ambiguous
			foundKey, found = k, f
		end
	end
	return foundKey, found
end

function ns.FindFriendByText(text)
	return ns.FindFriend(Names.Split(text))
end

function ns.IsMe(first, last)
	return ns.myKey ~= nil and Names.Key(first, last) == ns.myKey
end

-- The account-wide list can contain the character you're logged in as
-- (e.g. an alt a friend plays with). Keep the entry, just hide it here.
function ns.IsMyKey(key)
	return key ~= nil and key == ns.myKey
end

-- Adopt the server's exact spelling the first time we hear from a friend.
function ns.AdoptSpelling(key, first, last)
	local f = ns.db.friends[key]
	if f and first and Names.Key(first, last) == key then
		f.first, f.last = first, last or f.last
	end
end

function ns.CountFriends()
	local total, online = 0, 0
	for key in pairs(ns.db.friends) do
		if not ns.IsMyKey(key) then
			total = total + 1
			if ns.Presence and ns.Presence.IsOnline(key) then
				online = online + 1
			end
		end
	end
	return online, total
end

function ns.AddFriend(text, group)
	local first, last = Names.Split(text)
	if not first then
		ns.Print("Enter a character name, e.g. |cffffffffAna Forever|r.")
		return
	end
	if not last and Names.RegionalNamesEnabled() then
		ns.Print("Please include the surname, e.g. |cffffffff" .. first .. " Forever|r.")
		return
	end
	if ns.IsMe(first, last) then
		ns.Print("You can't add yourself.")
		return
	end
	local key = Names.Key(first, last)
	local display = Names.Display(first, last)
	if ns.db.friends[key] then
		ns.Print(display .. " is already on your list.")
		return
	end
	if not ns.GroupExists(group) then group = ns.db.groups[1] end
	ns.db.friends[key] = {
		first = first,
		last = last,
		note = "",
		group = group,
		added = time(),
	}
	ns.db.declined[key] = nil
	ns.Print(display .. " added to " .. group .. ".")
	ns.RequestRefresh()
	if ns.Presence then ns.Presence.Ping(key, true) end
	return key
end

function ns.AddFromUnit(unit, group)
	local first, last = Names.FromUnit(unit)
	if not first then
		ns.Print("Target a player first.")
		return
	end
	return ns.AddFriend(Names.Display(first, last), group)
end

function ns.RemoveFriend(key)
	local f = ns.db.friends[key]
	if not f then return end
	ns.db.friends[key] = nil
	if ns.Presence then ns.Presence.Forget(key) end
	ns.Print(Names.Display(f.first, f.last) .. " removed.")
	ns.RequestRefresh()
end

function ns.SetNote(key, note)
	local f = ns.db.friends[key]
	if not f then return end
	note = Names.StripEscapes(note or "") or ""
	note = note:gsub("^%s+", ""):gsub("%s+$", "")
	f.note = Names.Truncate(note, 120)
	ns.RequestRefresh()
end

function ns.MoveFriend(key, group)
	local f = ns.db.friends[key]
	if f and ns.GroupExists(group) then
		f.group = group
		ns.RequestRefresh()
	end
end

function ns.ToggleFriendAlerts(key)
	local f = ns.db.friends[key]
	if f then f.muted = not f.muted or nil end
end

---------------------------------------------------------------------------
-- Groups
---------------------------------------------------------------------------

local function CleanGroupName(name)
	if type(name) ~= "string" then return nil end
	name = name:gsub("[|~]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return nil end
	return Names.Truncate(name, 24)
end

function ns.GroupExists(name)
	if not name then return false end
	for _, g in ipairs(ns.db.groups) do
		if g == name then return true end
	end
	return false
end

local function GroupNameTaken(name, except)
	local lowered = Names.Lower(name)
	for _, g in ipairs(ns.db.groups) do
		if g ~= except and Names.Lower(g) == lowered then return true end
	end
	return false
end

function ns.CreateGroup(name)
	name = CleanGroupName(name)
	if not name then return nil end
	if GroupNameTaken(name) then
		ns.Print("A group named " .. name .. " already exists.")
		return nil
	end
	table.insert(ns.db.groups, name)
	ns.RequestRefresh()
	return name
end

function ns.RenameGroup(old, new)
	new = CleanGroupName(new)
	if not new or not ns.GroupExists(old) or new == old then return end
	if GroupNameTaken(new, old) then
		ns.Print("A group named " .. new .. " already exists.")
		return
	end
	for i, g in ipairs(ns.db.groups) do
		if g == old then ns.db.groups[i] = new end
	end
	for _, f in pairs(ns.db.friends) do
		if f.group == old then f.group = new end
	end
	ns.db.collapsed[new] = ns.db.collapsed[old]
	ns.db.collapsed[old] = nil
	ns.RequestRefresh()
end

function ns.DeleteGroup(name)
	if #ns.db.groups <= 1 then
		ns.Print("You need at least one group.")
		return
	end
	local index
	for i, g in ipairs(ns.db.groups) do
		if g == name then index = i end
	end
	if not index then return end
	table.remove(ns.db.groups, index)
	local fallback = ns.db.groups[1]
	for _, f in pairs(ns.db.friends) do
		if f.group == name then f.group = fallback end
	end
	ns.db.collapsed[name] = nil
	ns.RequestRefresh()
end

function ns.MoveGroup(name, delta)
	local groups = ns.db.groups
	for i, g in ipairs(groups) do
		if g == name then
			local j = i + delta
			if j >= 1 and j <= #groups then
				groups[i], groups[j] = groups[j], groups[i]
				ns.RequestRefresh()
			end
			return
		end
	end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function WhisperRestricted()
	local api = C_SocialRestrictions and C_SocialRestrictions.IsAgeVerificationRestricted
	if type(api) ~= "function" then return false end
	local ok, restricted = pcall(api)
	-- If the state can't be read, assume chat is restricted.
	if not ok or not Names.IsSafeValue(restricted) then return true end
	return restricted == true
end

local function ShowError(msg)
	if UIErrorsFrame and UIErrorsFrame.AddExternalErrorMessage then
		UIErrorsFrame:AddExternalErrorMessage(msg)
	else
		ns.Print(msg)
	end
end

-- Open a whisper to a target name string. Routed through securecallfunction:
-- calling chat APIs straight from addon code taints the chat edit box.
function ns.WhisperName(target)
	if not Names.IsSafe(target) then return end
	if WhisperRestricted() then
		ShowError(CHAT_DISABLED or "Chat is disabled for this account.")
		return
	end
	local sendTell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
	if not sendTell then return end
	if securecallfunction then
		securecallfunction(sendTell, target)
	else
		sendTell(target)
	end
end

function ns.Whisper(key)
	local f = ns.GetFriend(key)
	if f then ns.WhisperName(Names.Target(f.first, f.last)) end
end

function ns.Invite(key)
	local f = ns.GetFriend(key)
	if not f then return end
	local target = Names.Target(f.first, f.last)
	if C_PartyInfo and C_PartyInfo.InviteUnit then
		C_PartyInfo.InviteUnit(target)
	elseif InviteUnit then
		InviteUnit(target)
	end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON_NAME then return end
	InitDB()
end)

ns.On("PLAYER_LOGIN", function()
	local first, last = Names.FromUnit("player")
	if first then
		ns.myKey = Names.Key(first, last)
	end
	if ns.UI then ns.UI.Init() end
	if ns.Minimap then ns.Minimap.Init() end
	if ns.Presence then ns.Presence.Init() end
	if ns.Social then ns.Social.Init() end
	if ns.MapPins then ns.MapPins.Init() end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Debug()
	local p = ns.Print
	local okA, first, second = pcall(UnitNameUnmodified or UnitName, "player")
	p("Debug info (v" .. ns.VERSION .. "):")
	p("  WOW_PROJECT_ID = " .. tostring(WOW_PROJECT_ID) .. ", interface = " .. tostring(select(4, GetBuildInfo())))
	p("  RegionalUniqueNamesEnabled = " .. tostring(Names.RegionalNamesEnabled()))
	p("  Surname separator = [" .. Names.Separator() .. "]")
	p("  UnitNameUnmodified(player) = " .. tostring(okA and first) .. " / " .. tostring(okA and second))
	local okG, full = pcall(GetUnitName, "player", true)
	p("  GetUnitName(player, true) = " .. tostring(okG and full))
	local f, l = Names.FromUnit("player")
	p("  Parsed = " .. tostring(f) .. " / " .. tostring(l) .. "  -> target [" .. tostring(f and Names.Target(f, l)) .. "]")
	p("  NameUtil.GetFullNameWithoutRealm = " .. tostring(NameUtil and NameUtil.GetFullNameWithoutRealm ~= nil))
	p("  MenuUtil = " .. tostring(MenuUtil ~= nil) .. ", Menu.ModifyMenu = " .. tostring(Menu and Menu.ModifyMenu ~= nil))
	p("  Title friends enabled = " .. tostring(ns.Social and ns.Social.TitleFriendsEnabled()))
	p("  Not-found string = " .. tostring(ERR_CHAT_PLAYER_NOT_FOUND_S))
	if ns.Presence then ns.Presence.DebugDump() end
end

local function Help()
	ns.Print("Commands:")
	ns.Print("  /ff - toggle the window")
	ns.Print("  /ff add First Last - add a friend (no name: your target)")
	ns.Print("  /ff remove First Last - remove a friend")
	ns.Print("  /ff alerts - toggle online/offline alerts")
	ns.Print("  /ff minimap - toggle the minimap button")
	ns.Print("  /ff refresh - check who is online now")
	ns.Print("  /ff debug - print name/API info for troubleshooting")
end

SLASH_KINDREDFOREVER1 = "/kindredforever"
SLASH_KINDREDFOREVER2 = "/ff"
SLASH_KINDREDFOREVER3 = "/kin"
SlashCmdList.KINDREDFOREVER = function(input)
	input = input or ""
	local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" then
		ns.UI.Toggle()
	elseif cmd == "add" then
		if rest == "" then ns.AddFromUnit("target") else ns.AddFriend(rest) end
	elseif cmd == "remove" or cmd == "del" then
		local key = ns.FindFriendByText(rest)
		if key then ns.RemoveFriend(key) else ns.Print("No friend named " .. rest .. ".") end
	elseif cmd == "alerts" then
		ns.db.settings.alerts = not ns.db.settings.alerts
		ns.Print("Online alerts " .. (ns.db.settings.alerts and "enabled." or "disabled."))
	elseif cmd == "minimap" then
		ns.db.settings.minimap.hide = not ns.db.settings.minimap.hide
		ns.Minimap.Refresh()
	elseif cmd == "refresh" or cmd == "ping" then
		ns.Presence.PingAll(true)
		ns.Print("Checking your friends...")
	elseif cmd == "debug" then
		Debug()
	else
		Help()
	end
end
