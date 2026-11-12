-- Kindred: friend names in the mailbox.
--
-- * Typing in the Send Mail "To:" box completes a Kindred friend's name
--   inline (the rest is highlighted; keep typing to narrow, Tab/Enter accepts).
-- * A small button beside the box lists your friends to pick from.
-- * "Send Mail" in the Kindred friend menu fills the recipient.

local _, ns = ...
local Names = ns.Names

local Mail = {}
ns.Mail = Mail

local installed = false
local pickButton

local function NameBox()
	return SendMailNameEditBox
end

-- Friends as { key, f, target, lower, online }, online first, then by name.
local function Candidates()
	local out = {}
	for key, f in pairs(ns.db.friends) do
		if not ns.IsMyKey(key) then
			local target = Names.Target(f.first, f.last)
			out[#out + 1] = {
				key = key,
				f = f,
				target = target,
				lowerTarget = Names.Lower(target),
				lowerDisplay = Names.Lower(Names.Display(f.first, f.last)),
				online = ns.Presence and ns.Presence.IsOnline(key) or false,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.lowerDisplay < b.lowerDisplay
	end)
	return out
end

-- Best friend whose name starts with the typed text.
local function Match(typed)
	local lowered = Names.Lower(typed)
	for _, c in ipairs(Candidates()) do
		if #c.target > #typed then
			if c.lowerTarget:sub(1, #lowered) == lowered then
				return c.target
			end
			-- Typed with a space while the client joins names differently.
			if c.lowerDisplay:sub(1, #lowered) == lowered then
				return Names.Display(c.f.first, c.f.last)
			end
		end
	end
end

local function OnChar(eb)
	if not ns.db.settings.mailAutocomplete then return end
	local text = eb:GetText() or ""
	if text == "" then return end
	-- Only complete while typing at the end, and not on top of a
	-- completion the game already made.
	local cursor = eb:GetCursorPosition()
	if cursor ~= #text then return end
	local full = Match(text)
	if not full then return end
	eb:SetText(full)
	eb:HighlightText(#text, #full)
	eb:SetCursorPosition(#text)
end

function Mail.SetRecipient(target)
	local eb = NameBox()
	if not eb or not (MailFrame and MailFrame:IsShown()) then return false end
	if SendMailFrame and not SendMailFrame:IsShown() and MailFrameTab2 then
		MailFrameTab2:Click()
	end
	eb:SetText(target)
	eb:SetCursorPosition(#target)
	if SendMailSubjectEditBox then
		SendMailSubjectEditBox:SetFocus()
	end
	return true
end

function Mail.IsOpen()
	return MailFrame ~= nil and MailFrame:IsShown()
end

function Mail.SendTo(key)
	local f = ns.GetFriend(key)
	if f then Mail.SetRecipient(Names.Target(f.first, f.last)) end
end

local function PickMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	local candidates = Candidates()
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Mail a Kindred friend")
		if #candidates == 0 then
			root:CreateTitle("|cff888888No friends yet|r")
			return
		end
		local byGroup = {}
		for _, c in ipairs(candidates) do
			local g = c.f.group
			byGroup[g] = byGroup[g] or {}
			table.insert(byGroup[g], c)
		end
		local multiple = #ns.db.groups > 1
		for _, g in ipairs(ns.db.groups) do
			local entries = byGroup[g]
			if entries then
				local parent = root
				if multiple then parent = root:CreateButton(g) end
				for _, c in ipairs(entries) do
					local label = Names.Display(c.f.first, c.f.last)
					if not c.online then label = "|cff888888" .. label .. "|r" end
					parent:CreateButton(label, function() Mail.SetRecipient(c.target) end)
				end
			end
		end
	end)
end

local function CreatePickButton(eb)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	local b = CreateFrame("Button", nil, eb)
	b:SetSize(20, 20)
	b:SetPoint("LEFT", eb, "RIGHT", 2, 0)
	b:SetNormalTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
	b:SetPushedTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
	b:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function(self) PickMenu(self) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Kindred Friends", 1, 0.82, 0)
		GameTooltip:AddLine("Pick a friend to send mail to.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function Install()
	local eb = NameBox()
	if installed or not eb then return end
	installed = true
	-- HookScript: run after the game's own autocomplete, never replace it.
	eb:HookScript("OnChar", OnChar)
	pickButton = CreatePickButton(eb)
	Mail.Refresh()
end

function Mail.Refresh()
	if pickButton then pickButton:SetShown(ns.db.settings.mailAutocomplete) end
end

function Mail.Init()
	Install()
	-- The mail UI can load late; try again whenever the mailbox opens.
	ns.On("MAIL_SHOW", Install)
	ns.On("ADDON_LOADED", function(name)
		if name == "Blizzard_MailFrame" then Install() end
	end)
end
