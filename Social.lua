-- Kindred: Blizzard social integration.
--   * Forever Title Friends: read presence/zone from Battle.net game-account
--     info (works inside instances, costs no messages) and send requests.
--   * One-click /who for a friend (needs a click: /who is hardware-gated).
--   * "X added you - add them back?" prompt.
--   * "Add to Kindred" in Blizzard's player right-click menus.

local _, ns = ...
local Names = ns.Names

local Social = {}
ns.Social = Social

local function SafeField(t, k)
	if t == nil or Names.IsSecret(t) then return nil end
	local ok, v = pcall(function() return t[k] end)
	if not ok or Names.IsSecret(v) then return nil end
	return v
end

---------------------------------------------------------------------------
-- Title Friends
---------------------------------------------------------------------------

function Social.TitleFriendsEnabled()
	local api = C_BattleNet and C_BattleNet.AreTitleFriendsEnabled
	if type(api) ~= "function" then return false end
	local ok, enabled = pcall(api)
	return ok and Names.IsSafeValue(enabled) and enabled == true
end

local classByName
local function ClassFileFromName(name)
	if not Names.IsSafe(name) then return nil end
	if not classByName then
		classByName = {}
		for file, loc in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do classByName[loc] = file end
		for file, loc in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do classByName[loc] = file end
	end
	return classByName[name]
end

local bnetSeen = {}

local function ScanBNet()
	if not (C_BattleNet and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo) then return end
	if not BNGetNumFriends or next(ns.db.friends) == nil then return end
	local okN, numFriends = pcall(BNGetNumFriends)
	if not okN or not Names.IsSafeValue(numFriends) or type(numFriends) ~= "number" then return end

	local seenNow = {}
	local wowClient = BNET_CLIENT_WOW or "WoW"
	for i = 1, numFriends do
		local okG, numGA = pcall(C_BattleNet.GetFriendNumGameAccounts, i)
		if okG and Names.IsSafeValue(numGA) and type(numGA) == "number" then
			for j = 1, numGA do
				local okI, g = pcall(C_BattleNet.GetFriendGameAccountInfo, i, j)
				if okI and g and SafeField(g, "clientProgram") == wowClient and SafeField(g, "isOnline") then
					local project = SafeField(g, "wowProjectID")
					if project == nil or project == WOW_PROJECT_ID then
						local first, last = Names.Split(SafeField(g, "characterName"))
						local key = first and ns.FindFriend(first, last)
						if key and not ns.IsMyKey(key) then
							seenNow[key] = true
							local level = SafeField(g, "characterLevel")
							ns.Presence.Update(key, {
								online = true,
								bnet = true,
								unreachable = false,
								misses = 0,
								level = type(level) == "number" and level > 0 and level or nil,
								class = ClassFileFromName(SafeField(g, "className")),
								zone = Names.IsSafe(SafeField(g, "areaName")) and SafeField(g, "areaName") or nil,
								afk = SafeField(g, "isGameAFK") == true,
								dnd = SafeField(g, "isGameBusy") == true,
								source = "bnet",
							})
						end
					end
				end
			end
		end
	end
	-- Title friends who stopped playing this character: let pings take over.
	for key in pairs(bnetSeen) do
		if not seenNow[key] then
			ns.Presence.Update(key, { bnet = ns.Presence.CLEAR })
			ns.Presence.Ping(key, true)
		end
	end
	bnetSeen = seenNow
end

local scanQueued = false
local function QueueBNetScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(1, function()
		scanQueued = false
		ScanBNet()
	end)
end

local function LoadBlizzardAddOn(name)
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if isLoaded then
		local ok, loaded = pcall(isLoaded, name)
		if ok and loaded then return true end
	end
	local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
	if load then pcall(load, name) end
	return true
end

-- Opens Blizzard's own confirmation, which then sends the request. The
-- title-friend API only accepts untainted input, so the native dialog is
-- preferred (same approach as BetterFriendlist). Call from a click.
function Social.SendTitleFriendRequest(key)
	local f = ns.GetFriend(key)
	if not f then return end
	if not Social.TitleFriendsEnabled() then
		ns.Print("Title Friends aren't available on this client.")
		return
	end
	local name = Names.Target(f.first, f.last)
	LoadBlizzardAddOn("Blizzard_AddFriend")
	if EventRegistry and EventRegistry.TriggerEvent and BattleNetInviteFrame
		and BattleNetInviteFrame.OnTitleFriendInviteByNameRequested
	then
		local ok = pcall(EventRegistry.TriggerEvent, EventRegistry,
			"BattleNetInviteFrame.TitleFriendInviteByNameRequested", name)
		if ok then return end
	end
	if C_BattleNet and C_BattleNet.SendTitleFriendInviteByName then
		local ok = pcall(C_BattleNet.SendTitleFriendInviteByName, name)
		if ok then
			ns.Print("Title Friend request sent to " .. Names.Display(f.first, f.last) .. ".")
			return
		end
	end
	ns.Print("Couldn't send a Title Friend request.")
end

---------------------------------------------------------------------------
-- /who lookup
---------------------------------------------------------------------------

local whoKey, whoTime

function Social.CanWho()
	return C_FriendList ~= nil and type(C_FriendList.SendWho) == "function"
end

-- Must run from a click or key press.
function Social.Who(key)
	local f = ns.GetFriend(key)
	if not f or not Social.CanWho() then return end
	whoKey, whoTime = key, GetTime()
	local query = 'n-"' .. Names.Display(f.first, f.last) .. '"'
	local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social
	if origin then
		C_FriendList.SendWho(query, origin)
	else
		C_FriendList.SendWho(query)
	end
end

-- Called after Presence scanned WHO_LIST_UPDATE results.
function Social.OnWhoResults()
	if not whoKey or GetTime() - whoTime > 10 then whoKey = nil return end
	local key = whoKey
	whoKey = nil
	local f = ns.GetFriend(key)
	if not f then return end
	local n = C_FriendList.GetNumWhoResults() or 0
	for i = 1, n do
		local info = C_FriendList.GetWhoInfo(i)
		if info and Names.IsSafe(info.fullName) then
			local first, last = Names.Split(info.fullName)
			if Names.Key(first, last) == key then return end -- Presence already updated them
		end
	end
	ns.Presence.Update(key, { online = false, source = "who", map = ns.Presence.CLEAR })
	ns.Print(Names.Display(f.first, f.last) .. " isn't online (or can't be seen with /who).")
end

---------------------------------------------------------------------------
-- "Add them back?" prompt
---------------------------------------------------------------------------

local offers = {}
local showingOffer = false

StaticPopupDialogs.KINDRED_ADD_BACK = {
	text = "%s has added you to their Kindred list.\nAdd them back?",
	button1 = "Add",
	button2 = "Not Now",
	button3 = "Never",
	OnAccept = function(_, data) ns.AddFriend(data) end,
	OnAlt = function(_, data)
		local key = Names.KeyFromText(data)
		if key then ns.db.declined[key] = true end
	end,
	OnHide = function()
		showingOffer = false
		C_Timer.After(1, function() Social.ShowNextOffer() end)
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function Social.ShowNextOffer()
	if showingOffer or #offers == 0 or InCombatLockdown() then return end
	local display = table.remove(offers, 1)
	if ns.FindFriendByText(display) then return Social.ShowNextOffer() end
	showingOffer = true
	StaticPopup_Show("KINDRED_ADD_BACK", display, nil, display)
end

function Social.OfferAddBack(first, last)
	table.insert(offers, Names.Display(first, last))
	Social.ShowNextOffer()
end

---------------------------------------------------------------------------
-- Blizzard unit menus
---------------------------------------------------------------------------

local MENU_TAGS = {
	"MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
	"MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
	"MENU_UNIT_FRIEND", "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_WHO",
}

-- Context data can be secret-backed on 12.x clients: read fields safely.
local function ResolveContext(contextData)
	local unit = SafeField(contextData, "unit")
	if Names.IsSafe(unit) then
		local first, last = Names.FromUnit(unit)
		if first then return first, last end
	end
	return Names.FromParts(SafeField(contextData, "name"), SafeField(contextData, "server"))
end

local function ModifyUnitMenu(_, root, contextData)
	local first, last = ResolveContext(contextData)
	if not first or ns.IsMe(first, last) then return end
	if not last and Names.RegionalNamesEnabled() then return end
	local key = Names.Key(first, last)
	root:CreateDivider()
	if ns.db.friends[key] then
		root:CreateTitle("|cffffd100In your Kindred list|r")
	else
		root:CreateButton("Add to Kindred", function()
			ns.AddFriend(Names.Display(first, last))
		end)
	end
end

local function HookMenus()
	if not (Menu and Menu.ModifyMenu) then return end
	for _, tag in ipairs(MENU_TAGS) do
		pcall(Menu.ModifyMenu, tag, ModifyUnitMenu)
	end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function Social.Init()
	HookMenus()
	ns.On("BN_FRIEND_INFO_CHANGED", QueueBNetScan)
	ns.On("BN_FRIEND_ACCOUNT_ONLINE", QueueBNetScan)
	ns.On("BN_FRIEND_ACCOUNT_OFFLINE", QueueBNetScan)
	ns.On("BN_FRIEND_LIST_SIZE_CHANGED", QueueBNetScan)
	ns.On("PLAYER_REGEN_ENABLED", Social.ShowNextOffer)
	C_Timer.After(3, ScanBNet)
	C_Timer.NewTicker(60, ScanBNet)
end
