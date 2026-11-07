-- Forever Friends: the main window, styled after the classic dialog frames.

local _, ns = ...
local Names = ns.Names

local UI = {}
ns.UI = UI

local FRAME_W, FRAME_H = 350, 500
local LIST_TOP, LIST_BOTTOM = -84, 76
local FRIEND_H, HEADER_H = 34, 20

local frame, list, scrollBar, summaryText, searchBox, sortButton
local buttons = {}
local friendRows, headerRows = {}, {}
local items = {}
local offset = 0
local selectedKey
local searchText = ""

local STATUS_ICONS = {
	online = "Interface\\FriendsFrame\\StatusIcon-Online",
	away = "Interface\\FriendsFrame\\StatusIcon-Away",
	busy = "Interface\\FriendsFrame\\StatusIcon-DnD",
	offline = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

local SORTS = { "status", "name", "level", "zone" }
local SORT_LABELS = { status = "Status", name = "Name", level = "Level", zone = "Zone" }

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------

local function ClassColor(classFile)
	if not classFile then return nil end
	if C_ClassColor and C_ClassColor.GetClassColor then
		local c = C_ClassColor.GetClassColor(classFile)
		if c then return c.r, c.g, c.b end
	end
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if c then return c.r, c.g, c.b end
end

local function ClassName(classFile)
	if not classFile then return nil end
	return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]) or classFile
end

local function Ago(t)
	if not t then return nil end
	local d = time() - t
	if d < 120 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. " min ago" end
	if d < 86400 then
		local h = math.floor(d / 3600)
		return h .. (h == 1 and " hour ago" or " hours ago")
	end
	local days = math.floor(d / 86400)
	return days .. (days == 1 and " day ago" or " days ago")
end

-- Returns status ("online"/"away"/"busy"/"offline"/"unknown"), info line.
local function Describe(key, f)
	local s = ns.Presence.Get(key)
	local seen = f.lastSeen

	if s and s.online then
		local status = s.dnd and "busy" or (s.afk and "away" or "online")
		local parts = {}
		local level = s.level or (seen and seen.level)
		local class = s.class or (seen and seen.class)
		if level then table.insert(parts, "Level " .. level) end
		if class then table.insert(parts, ClassName(class)) end
		local who = table.concat(parts, " ")
		local zone = type(s.zone) == "string" and s.zone or nil
		local where
		if s.mutual == false and not s.bnet then
			where = "hasn't added you"
		elseif s.unreachable then
			where = "in an instance?" .. (zone and (" (last: " .. zone .. ")") or "")
		elseif zone then
			where = zone
		elseif s.addon == false and not s.bnet then
			where = "no addon"
		end
		local line
		if who ~= "" and where then
			line = who .. " - " .. where
		else
			line = (who ~= "" and who) or ("Online" .. (where and (" - " .. where) or ""))
		end
		return status, line
	end

	if s and s.online == false then
		local line = "Offline"
		if seen and seen.time then
			line = line .. " - seen " .. Ago(seen.time)
			if seen.zone then line = line .. " in " .. seen.zone end
		end
		return "offline", line
	end

	local line = "Checking..."
	if seen and seen.time then
		line = "Last seen " .. Ago(seen.time) .. (seen.zone and (" in " .. seen.zone) or "")
	end
	return "unknown", line
end

---------------------------------------------------------------------------
-- Dialogs
---------------------------------------------------------------------------

local function EditBoxOf(dialog)
	if dialog.GetEditBox then return dialog:GetEditBox() end
	return dialog.editBox or dialog.EditBox
end

-- Blizzard passes (editBox, data) to EditBoxOnEnterPressed.
local function EnterAccepts(editBox, data)
	local dialog = editBox:GetParent()
	local info = StaticPopupDialogs[dialog.which]
	if info and info.OnAccept then info.OnAccept(dialog, data ~= nil and data or dialog.data) end
	dialog:Hide()
end

local EscapeHides = StaticPopup_StandardEditBoxOnEscapePressed or function(editBox)
	editBox:GetParent():Hide()
end

local function EditPopup(t)
	t.button1 = t.button1 or ACCEPT or "Accept"
	t.button2 = t.button2 or CANCEL or "Cancel"
	t.hasEditBox = true
	t.EditBoxOnEnterPressed = EnterAccepts
	t.EditBoxOnEscapePressed = EscapeHides
	t.timeout, t.whileDead, t.hideOnEscape, t.preferredIndex = 0, true, true, 3
	return t
end

StaticPopupDialogs.FOREVERFRIENDS_ADD = EditPopup({
	text = "Enter your friend's first and last name:",
	maxLetters = 32,
	OnShow = function(self)
		local eb = EditBoxOf(self)
		eb:SetText("")
		eb:SetFocus()
	end,
	OnAccept = function(self, group)
		ns.AddFriend(EditBoxOf(self):GetText(), group)
	end,
})

StaticPopupDialogs.FOREVERFRIENDS_NOTE = EditPopup({
	text = "Set a note for %s:",
	maxLetters = 120,
	OnShow = function(self, key)
		local f = ns.GetFriend(key)
		local eb = EditBoxOf(self)
		eb:SetText(f and f.note or "")
		eb:SetFocus()
		eb:HighlightText()
	end,
	OnAccept = function(self, key)
		ns.SetNote(key, EditBoxOf(self):GetText())
	end,
})

-- data = friend key to move into the new group (optional)
StaticPopupDialogs.FOREVERFRIENDS_NEW_GROUP = EditPopup({
	text = "Name of the new group:",
	maxLetters = 24,
	OnShow = function(self)
		local eb = EditBoxOf(self)
		eb:SetText("")
		eb:SetFocus()
	end,
	OnAccept = function(self, key)
		local name = ns.CreateGroup(EditBoxOf(self):GetText())
		if name and key then ns.MoveFriend(key, name) end
	end,
})

StaticPopupDialogs.FOREVERFRIENDS_RENAME_GROUP = EditPopup({
	text = "Rename group %s:",
	maxLetters = 24,
	OnShow = function(self, group)
		local eb = EditBoxOf(self)
		eb:SetText(group or "")
		eb:SetFocus()
		eb:HighlightText()
	end,
	OnAccept = function(self, group)
		ns.RenameGroup(group, EditBoxOf(self):GetText())
	end,
})

StaticPopupDialogs.FOREVERFRIENDS_REMOVE = {
	text = "Remove %s from your Forever Friends?",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(_, key)
		if key == selectedKey then selectedKey = nil end
		ns.RemoveFriend(key)
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

StaticPopupDialogs.FOREVERFRIENDS_DELETE_GROUP = {
	text = "Delete the group %s? Its friends move to the first group.",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(_, group) ns.DeleteGroup(group) end,
	timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

local function DisplayOf(key)
	local f = ns.GetFriend(key)
	return f and Names.Display(f.first, f.last) or "?"
end

function UI.PromptAdd(group)
	StaticPopup_Show("FOREVERFRIENDS_ADD", nil, nil, group)
end

function UI.PromptNote(key)
	StaticPopup_Show("FOREVERFRIENDS_NOTE", DisplayOf(key), nil, key)
end

function UI.PromptRemove(key)
	StaticPopup_Show("FOREVERFRIENDS_REMOVE", DisplayOf(key), nil, key)
end

function UI.PromptNewGroup(moveKey)
	StaticPopup_Show("FOREVERFRIENDS_NEW_GROUP", nil, nil, moveKey)
end

---------------------------------------------------------------------------
-- Context menus
---------------------------------------------------------------------------

local function FriendMenu(owner, key)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	local f = ns.GetFriend(key)
	if not f then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(Names.Display(f.first, f.last))
		root:CreateButton(WHISPER or "Whisper", function() ns.Whisper(key) end)
		root:CreateButton(INVITE or "Invite", function() ns.Invite(key) end)
		if ns.Social.CanWho() then
			root:CreateButton("Who (look up zone)", function() ns.Social.Who(key) end)
		end
		if ns.Social.TitleFriendsEnabled() then
			root:CreateButton("Send Title Friend Request", function() ns.Social.SendTitleFriendRequest(key) end)
		end
		root:CreateDivider()
		root:CreateButton("Set Note", function() UI.PromptNote(key) end)
		local move = root:CreateButton("Move to Group")
		for _, g in ipairs(ns.db.groups) do
			move:CreateRadio(g,
				function() return f.group == g end,
				function() ns.MoveFriend(key, g) end)
		end
		move:CreateDivider()
		move:CreateButton("New Group...", function() UI.PromptNewGroup(key) end)
		root:CreateCheckbox("Online Alerts",
			function() return not f.muted end,
			function() ns.ToggleFriendAlerts(key) end)
		root:CreateDivider()
		root:CreateButton("|cffff3030Remove Friend|r", function() UI.PromptRemove(key) end)
	end)
end

local function GroupMenu(owner, group)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(group)
		root:CreateButton("Add Friend to Group", function() UI.PromptAdd(group) end)
		root:CreateButton("New Group...", function() UI.PromptNewGroup() end)
		root:CreateButton("Rename Group", function()
			StaticPopup_Show("FOREVERFRIENDS_RENAME_GROUP", group, nil, group)
		end)
		root:CreateButton("Move Up", function() ns.MoveGroup(group, -1) end)
		root:CreateButton("Move Down", function() ns.MoveGroup(group, 1) end)
		if #ns.db.groups > 1 then
			root:CreateDivider()
			root:CreateButton("|cffff3030Delete Group|r", function()
				StaticPopup_Show("FOREVERFRIENDS_DELETE_GROUP", group, nil, group)
			end)
		end
	end)
end

local function Setting(root, label, field, onChange)
	root:CreateCheckbox(label,
		function() return ns.db.settings[field] end,
		function()
			ns.db.settings[field] = not ns.db.settings[field]
			if onChange then onChange() end
			ns.RequestRefresh()
		end)
end

local function OptionsMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Forever Friends")
		Setting(root, "Hide offline friends", "hideOffline")
		root:CreateDivider()
		root:CreateTitle("Alerts")
		Setting(root, "Online / offline alerts", "alerts")
		Setting(root, "Play a sound", "alertSound")
		Setting(root, "Level-up alerts", "levelAlerts")
		Setting(root, "Ask to add back people who add me", "addBackPrompt")
		root:CreateDivider()
		root:CreateTitle("Map")
		Setting(root, "Share my map position with my list", "shareMapPosition")
		Setting(root, "Show friends on the world map", "showMapPins")
		root:CreateDivider()
		root:CreateCheckbox("Minimap button",
			function() return not ns.db.settings.minimap.hide end,
			function()
				ns.db.settings.minimap.hide = not ns.db.settings.minimap.hide
				ns.Minimap.Refresh()
			end)
	end)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function ShowFriendTooltip(row)
	local key = row.key
	local f = ns.GetFriend(key)
	if not f then return end
	local s = ns.Presence.Get(key)
	local seen = f.lastSeen
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	local r, g, b = ClassColor((s and s.class) or (seen and seen.class))
	GameTooltip:AddLine(Names.Display(f.first, f.last), r or 1, g or 0.82, b or 0)
	local _, line = Describe(key, f)
	GameTooltip:AddLine(line, 1, 1, 1, true)
	if s and s.bnet then
		GameTooltip:AddLine("Title Friend - status from Battle.net.", 0.6, 0.6, 0.6, true)
	elseif s and s.online and s.addon == false then
		GameTooltip:AddLine("They don't run Forever Friends, so their zone is unknown. Right-click > Who to look it up.", 0.6, 0.6, 0.6, true)
	elseif s and s.mutual == false then
		GameTooltip:AddLine("Online, but they haven't added you, so their zone stays private.", 0.6, 0.6, 0.6, true)
	elseif s and s.unreachable then
		GameTooltip:AddLine("They run the addon but aren't answering - usually a dungeon or raid.", 0.6, 0.6, 0.6, true)
	end
	if f.note ~= "" then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Note: |cffffffff" .. f.note .. "|r", 1, 0.82, 0, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Group: " .. f.group .. (f.muted and " (alerts off)" or ""), 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Double-click to whisper, right-click for options", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function CreateFriendRow()
	local row = CreateFrame("Button", nil, list)
	row:SetHeight(FRIEND_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	row.selected:SetBlendMode("ADD")
	row.selected:SetAllPoints()
	row.selected:SetVertexColor(1, 0.82, 0, 0.6)
	row.selected:Hide()

	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("TOPLEFT", 8, -4)

	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", 28, -4)
	row.name:SetPoint("RIGHT", -24, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.info = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.info:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
	row.info:SetPoint("RIGHT", -8, 0)
	row.info:SetJustifyH("LEFT")
	row.info:SetWordWrap(false)

	row.note = row:CreateTexture(nil, "ARTWORK")
	row.note:SetSize(14, 14)
	row.note:SetPoint("TOPRIGHT", -6, -4)
	row.note:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")

	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			selectedKey = self.key
			UI.Refresh()
			FriendMenu(self, self.key)
		else
			selectedKey = (selectedKey == self.key) and nil or self.key
			UI.Refresh()
		end
	end)
	row:SetScript("OnDoubleClick", function(self) ns.Whisper(self.key) end)
	row:SetScript("OnEnter", ShowFriendTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

local function CreateHeaderRow()
	local row = CreateFrame("Button", nil, list)
	row:SetHeight(HEADER_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.toggle = row:CreateTexture(nil, "ARTWORK")
	row.toggle:SetSize(14, 14)
	row.toggle:SetPoint("LEFT", 6, 0)

	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.text:SetPoint("LEFT", row.toggle, "RIGHT", 6, 0)
	row.text:SetPoint("RIGHT", -8, 0)
	row.text:SetJustifyH("LEFT")

	row.line = row:CreateTexture(nil, "BACKGROUND")
	row.line:SetColorTexture(1, 0.82, 0, 0.15)
	row.line:SetPoint("BOTTOMLEFT", 4, 0)
	row.line:SetPoint("BOTTOMRIGHT", -4, 0)
	row.line:SetHeight(1)

	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			GroupMenu(self, self.group)
		else
			ns.db.collapsed[self.group] = not ns.db.collapsed[self.group] or nil
			UI.Refresh()
		end
	end)
	return row
end

---------------------------------------------------------------------------
-- List building
---------------------------------------------------------------------------

local STATUS_ORDER = { online = 1, away = 1, busy = 1, unknown = 2, offline = 3 }

local function Matches(e)
	if searchText == "" then return true end
	local f = e.f
	local hay = Names.Lower(Names.Display(f.first, f.last) .. " " .. f.note .. " " .. e.line)
	return hay:find(searchText, 1, true) ~= nil
end

local COMPARE = {
	status = function(a, b)
		local oa, ob = STATUS_ORDER[a.status], STATUS_ORDER[b.status]
		if oa ~= ob then return oa < ob end
		return a.sortName < b.sortName
	end,
	name = function(a, b) return a.sortName < b.sortName end,
	level = function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		return a.sortName < b.sortName
	end,
	zone = function(a, b)
		if a.zone ~= b.zone then
			if a.zone == "" then return false end
			if b.zone == "" then return true end
			return a.zone < b.zone
		end
		return a.sortName < b.sortName
	end,
}

local function BuildItems()
	wipe(items)
	local byGroup = {}
	for _, g in ipairs(ns.db.groups) do byGroup[g] = {} end
	for key, f in pairs(ns.db.friends) do
		if not ns.IsMyKey(key) then
			local status, line = Describe(key, f)
			local s = ns.Presence.Get(key)
			local online = STATUS_ORDER[status] == 1
			local zone = online and s and type(s.zone) == "string" and Names.Lower(s.zone) or ""
			local level = (s and s.level) or (f.lastSeen and f.lastSeen.level) or 0
			local bucket = byGroup[f.group] or byGroup[ns.db.groups[1]]
			table.insert(bucket, { key = key, f = f, status = status, line = line,
				sortName = Names.Lower(Names.Display(f.first, f.last)), zone = zone, level = level })
		end
	end
	local hideOffline = ns.db.settings.hideOffline
	local compare = COMPARE[ns.db.settings.sortBy] or COMPARE.status
	local searching = searchText ~= ""
	for _, g in ipairs(ns.db.groups) do
		local entries = byGroup[g]
		table.sort(entries, compare)
		local online, shown = 0, {}
		for _, e in ipairs(entries) do
			if STATUS_ORDER[e.status] == 1 then online = online + 1 end
			if Matches(e) and not (hideOffline and e.status == "offline") then
				table.insert(shown, e)
			end
		end
		if not searching or #shown > 0 then
			table.insert(items, { header = true, group = g, online = online, total = #entries })
			if searching or not ns.db.collapsed[g] then
				for _, e in ipairs(shown) do table.insert(items, e) end
			end
		end
	end
end

local function ListHeight()
	return list:GetHeight() - 8
end

-- Largest offset that still fills the list from the bottom.
local function MaxOffset()
	local h, avail = 0, ListHeight()
	for i = #items, 1, -1 do
		h = h + (items[i].header and HEADER_H or FRIEND_H)
		if h > avail then return i end
	end
	return 0
end

local function Layout()
	for _, r in ipairs(friendRows) do r:Hide() end
	for _, r in ipairs(headerRows) do r:Hide() end

	local maxOffset = MaxOffset()
	if offset > maxOffset then offset = maxOffset end
	if offset < 0 then offset = 0 end

	local y, avail = -4, ListHeight()
	local nf, nh = 0, 0
	local width = list:GetWidth() - 26
	for i = offset + 1, #items do
		local item = items[i]
		local h = item.header and HEADER_H or FRIEND_H
		if -y + h > avail + 4 then break end
		local row
		if item.header then
			nh = nh + 1
			row = headerRows[nh] or CreateHeaderRow()
			headerRows[nh] = row
			row.group = item.group
			local collapsed = ns.db.collapsed[item.group] and searchText == ""
			row.toggle:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
			row.text:SetText(string.format("%s |cffaaaaaa(%d/%d)|r", item.group, item.online, item.total))
		else
			nf = nf + 1
			row = friendRows[nf] or CreateFriendRow()
			friendRows[nf] = row
			local f, status = item.f, item.status
			row.key = item.key
			row.icon:SetTexture(STATUS_ICONS[status] or STATUS_ICONS.offline)
			row.icon:SetAlpha(status == "unknown" and 0.4 or 1)
			row.name:SetText(Names.Display(f.first, f.last))
			local s = ns.Presence.Get(item.key)
			if STATUS_ORDER[status] == 1 then
				local r, g, b = ClassColor((s and s.class) or (f.lastSeen and f.lastSeen.class))
				row.name:SetTextColor(r or 1, g or 0.82, b or 0)
				row.info:SetTextColor(0.9, 0.9, 0.9)
			else
				row.name:SetTextColor(0.55, 0.55, 0.55)
				row.info:SetTextColor(0.45, 0.45, 0.45)
			end
			row.info:SetText(item.line)
			row.note:SetShown(f.note ~= "")
			row.selected:SetShown(item.key == selectedKey)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, y)
		row:SetWidth(width)
		row:Show()
		y = y - h
	end

	scrollBar:SetMinMaxValues(0, maxOffset)
	scrollBar.updating = true
	scrollBar:SetValue(offset)
	scrollBar.updating = false
	local scrollable = maxOffset > 0
	scrollBar:SetShown(scrollable)
	scrollBar.up:SetShown(scrollable)
	scrollBar.down:SetShown(scrollable)
	scrollBar.up:SetEnabled(offset > 0)
	scrollBar.down:SetEnabled(offset < maxOffset)

	-- Rows may now show a different friend: refresh an open row tooltip.
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	for _, row in ipairs(friendRows) do
		if row == owner then
			if row:IsShown() and row:IsMouseOver() then ShowFriendTooltip(row) else GameTooltip:Hide() end
		end
	end
end

local function UpdateButtons()
	if not frame or not frame:IsShown() then return end
	local has = selectedKey ~= nil and ns.GetFriend(selectedKey) ~= nil
	if not has then selectedKey = nil end
	buttons.whisper:SetEnabled(has)
	buttons.invite:SetEnabled(has)
	buttons.remove:SetEnabled(has)
	local okP, isPlayer = pcall(UnitIsPlayer, "target")
	buttons.target:SetEnabled(okP and Names.IsSafeValue(isPlayer) and isPlayer or false)
end

function UI.Refresh()
	if not frame or not frame:IsShown() then return end
	BuildItems()
	Layout()
	UpdateButtons()
	local online, total = ns.CountFriends()
	summaryText:SetText(string.format("Online: |cffffffff%d|r / %d", online, total))
	sortButton:SetText("Sort: " .. (SORT_LABELS[ns.db.settings.sortBy] or "Status"))
	if total == 0 then
		frame.empty:SetText("No friends yet.\nClick Add Friend, or target a player and click Add Target.")
		frame.empty:Show()
	elseif #items == 0 or (searchText ~= "" and #items == 0) then
		frame.empty:SetText("No friends match your search.")
		frame.empty:Show()
	else
		frame.empty:Hide()
	end
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------

local function MakeButton(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function ArrowButton(parent, dir)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(18, 18)
	local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. dir .. "Button-"
	b:SetNormalTexture(base .. "Up")
	b:SetPushedTexture(base .. "Down")
	b:SetDisabledTexture(base .. "Disabled")
	b:SetHighlightTexture(base .. "Highlight", "ADD")
	return b
end

local function SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	ns.db.settings.window = { point = point, relPoint = relPoint, x = x, y = y }
end

-- Close on Escape without joining UISpecialFrames: on Forever an addon frame
-- in that list taints the Group Finder bootstrap (see BetterFriendlist).
-- Keyboard propagation can't change in combat; there we just hide.
local function InstallEscape(f)
	f:EnableKeyboard(true)
	if not InCombatLockdown() then f:SetPropagateKeyboardInput(true) end
	f:SetScript("OnKeyDown", function(self, key)
		if key ~= "ESCAPE" then return end
		if InCombatLockdown() then
			self:Hide()
			return
		end
		self:SetPropagateKeyboardInput(false)
		self:Hide()
		C_Timer.After(0, function()
			if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
		end)
	end)
	f:HookScript("OnShow", function(self)
		if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
	end)
end

local function Build()
	frame = CreateFrame("Frame", "ForeverFriendsFrame", UIParent, "BackdropTemplate")
	frame:SetSize(FRAME_W, FRAME_H)
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:Hide()

	local pos = ns.db.settings.window
	if pos and pos.point then
		frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
	else
		frame:SetPoint("LEFT", UIParent, "LEFT", 60, 40)
	end

	-- Classic gold header plate.
	local header = frame:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetSize(300, 64)
	header:SetPoint("TOP", 0, 12)
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", header, "TOP", 0, -14)
	title:SetText("Forever Friends")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	-- Row 1: online count + options.
	summaryText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	summaryText:SetPoint("TOPLEFT", 22, -36)

	local options = MakeButton(frame, "Options", 80, function(self) OptionsMenu(self) end)
	options:SetPoint("TOPRIGHT", -18, -30)

	-- Row 2: search + sort.
	searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	searchBox:SetSize(190, 20)
	searchBox:SetPoint("TOPLEFT", 26, -56)
	searchBox:SetAutoFocus(false)
	searchBox:SetMaxLetters(40)
	local hint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("Search names, notes, zones")
	searchBox:SetScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		hint:SetShown(text == "" and not self:HasFocus())
		searchText = Names.Lower(text:gsub("^%s+", ""):gsub("%s+$", ""))
		offset = 0
		UI.Refresh()
	end)
	searchBox:SetScript("OnEditFocusGained", function() hint:Hide() end)
	searchBox:SetScript("OnEditFocusLost", function(self) hint:SetShown((self:GetText() or "") == "") end)
	searchBox:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	sortButton = MakeButton(frame, "Sort: Status", 100, function()
		local current = ns.db.settings.sortBy
		local nextSort = SORTS[1]
		for i, s in ipairs(SORTS) do
			if s == current then nextSort = SORTS[i % #SORTS + 1] end
		end
		ns.db.settings.sortBy = nextSort
		UI.Refresh()
	end)
	sortButton:SetPoint("TOPRIGHT", -18, -55)

	-- Inset list area with a tooltip-style border.
	list = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	list:SetPoint("TOPLEFT", 16, LIST_TOP)
	list:SetPoint("BOTTOMRIGHT", -16, LIST_BOTTOM)
	list:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	list:SetBackdropColor(0, 0, 0, 0.6)
	list:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta
		Layout()
	end)

	frame.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	frame.empty:SetPoint("CENTER")
	frame.empty:SetWidth(240)

	-- Classic scroll bar: arrows + knob.
	scrollBar = CreateFrame("Slider", nil, list)
	scrollBar:SetOrientation("VERTICAL")
	scrollBar:SetWidth(16)
	scrollBar:SetPoint("TOPRIGHT", -4, -22)
	scrollBar:SetPoint("BOTTOMRIGHT", -4, 22)
	scrollBar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	scrollBar:GetThumbTexture():SetSize(18, 24)
	scrollBar:SetValueStep(1)
	scrollBar:SetObeyStepOnDrag(true)
	scrollBar:SetScript("OnValueChanged", function(self, value)
		if self.updating then return end
		offset = math.floor(value + 0.5)
		Layout()
	end)
	scrollBar.up = ArrowButton(list, "Up")
	scrollBar.up:SetPoint("BOTTOM", scrollBar, "TOP", 0, 2)
	scrollBar.up:SetScript("OnClick", function() offset = offset - 1; Layout() end)
	scrollBar.down = ArrowButton(list, "Down")
	scrollBar.down:SetPoint("TOP", scrollBar, "BOTTOM", 0, -2)
	scrollBar.down:SetScript("OnClick", function() offset = offset + 1; Layout() end)

	-- Bottom buttons, two rows of three like the classic Social frame.
	local bw = 102
	buttons.add = MakeButton(frame, "Add Friend", bw, function() UI.PromptAdd() end)
	buttons.add:SetPoint("BOTTOMLEFT", 18, 44)
	buttons.target = MakeButton(frame, "Add Target", bw, function() ns.AddFromUnit("target") end)
	buttons.target:SetPoint("LEFT", buttons.add, "RIGHT", 4, 0)
	buttons.group = MakeButton(frame, "New Group", bw, function() UI.PromptNewGroup() end)
	buttons.group:SetPoint("LEFT", buttons.target, "RIGHT", 4, 0)

	buttons.whisper = MakeButton(frame, WHISPER or "Whisper", bw, function()
		if selectedKey then ns.Whisper(selectedKey) end
	end)
	buttons.whisper:SetPoint("BOTTOMLEFT", 18, 18)
	buttons.invite = MakeButton(frame, INVITE or "Invite", bw, function()
		if selectedKey then ns.Invite(selectedKey) end
	end)
	buttons.invite:SetPoint("LEFT", buttons.whisper, "RIGHT", 4, 0)
	buttons.remove = MakeButton(frame, REMOVE or "Remove", bw, function()
		if selectedKey then UI.PromptRemove(selectedKey) end
	end)
	buttons.remove:SetPoint("LEFT", buttons.invite, "RIGHT", 4, 0)

	frame:SetScript("OnShow", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		ns.Presence.PingAll()
		UI.Refresh()
	end)
	frame:SetScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
		if searchBox:HasFocus() then searchBox:ClearFocus() end
	end)
	InstallEscape(frame)

	ns.On("PLAYER_TARGET_CHANGED", UpdateButtons)
	-- Refresh "x min ago" text while open.
	C_Timer.NewTicker(30, function() if frame:IsShown() then ns.RequestRefresh() end end)
end

function UI.Init()
	if not frame then Build() end
end

function UI.Toggle()
	if not frame then Build() end
	frame:SetShown(not frame:IsShown())
end
