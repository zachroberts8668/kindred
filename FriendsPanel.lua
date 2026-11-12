-- Kindred: a "Kindred" tab on the built-in social panel that opens the
-- Kindred window docked beside it.
--
-- Forever replaces the classic FriendsFrame with SocialUIFrame
-- (Blizzard_SocialUI). Its tabs run down the right edge, built from
-- LargeSideTabButtonTemplate and laid out in SocialUIFrameMixin:RefreshTabs
-- as a chain: the first at TOPLEFT/TOPRIGHT 0,-122, each next one 3px below
-- the previous. We build our tab from the same template and hang it under
-- the last one. (Reference: Gethe/wow-ui-source, branch "forever".)
--
-- Our tab is parented to the panel but never enters its tab pool or tab
-- data: touching those from addon code would taint the panel.

local _, ns = ...

local FriendsPanel = {}
ns.FriendsPanel = FriendsPanel

local TAB_NAME = "KindredForeverFriendsTab"
local ICON = "Interface\\Icons\\INV_Misc_GroupNeedMore"
local TAB_GAP = 3
local tab, panel

-- The Blizzard tab no other tab is anchored to: the bottom of the chain.
local function LastSocialTab()
	local pool = panel and panel.socialTabPool
	if not pool or not pool.EnumerateActive then return nil end
	local active, anchoredTo = {}, {}
	for t in pool:EnumerateActive() do
		if t:IsShown() then
			table.insert(active, t)
			local _, rel = t:GetPoint(1)
			if rel then anchoredTo[rel] = true end
		end
	end
	for _, t in ipairs(active) do
		if not anchoredTo[t] then return t end
	end
end

local function PlaceTab()
	if not tab then return end
	tab:ClearAllPoints()
	if tab.isSideTab then
		local last = LastSocialTab()
		if last then
			tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -TAB_GAP)
		else
			tab:SetPoint("TOPLEFT", panel, "TOPRIGHT", 0, -122)
		end
	else
		tab:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 12, -2)
	end
end

local function ShowTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT", -4, -4)
	GameTooltip:AddLine("Kindred", 1, 1, 1)
	GameTooltip:AddLine("Your character friends list. Opens beside this panel.", 1, 0.82, 0, true)
	GameTooltip:Show()
end

local function OnClick(self)
	-- Open to the right of the tab column so the tabs stay clickable.
	local x = 0
	local right, panelRight = self:GetRight(), panel:GetRight()
	if self.isSideTab and right and panelRight then x = right - panelRight end
	ns.UI.ToggleDocked(panel, x)
end

local function BuildSideTab()
	local b = CreateFrame("Button", TAB_NAME, panel, "LargeSideTabButtonTemplate")
	b.isSideTab = true
	b.Icon:SetTexture(ICON)
	-- Fill the tab's masked interior, the way Blizzard shows texture icons.
	b:SetFillToInterior(true, 50)
	b:SetChecked(false)
	return b
end

local function BuildBottomButton()
	local b = CreateFrame("Button", TAB_NAME, panel, "UIPanelButtonTemplate")
	b:SetSize(90, 22)
	b:SetText("Kindred")
	return b
end

local function EnsureTab()
	if tab then return end
	local ok, result = pcall(function()
		if panel == SocialUIFrame then
			local okT, b = pcall(BuildSideTab)
			if okT then return b end
			FriendsPanel.lastError = b
		end
		return BuildBottomButton()
	end)
	if not ok then
		FriendsPanel.lastError = result
		return
	end
	tab = result
	tab:SetScript("OnClick", OnClick)
	tab:SetScript("OnEnter", ShowTooltip)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
	FriendsPanel.Refresh()
end

-- Selected look while Kindred is open beside the panel.
function FriendsPanel.UpdateChecked()
	if tab and tab.isSideTab then
		tab:SetChecked(ns.UI.IsDockedTo(panel))
	end
end

local function Install()
	if panel then return end
	panel = SocialUIFrame or (WOW_PROJECT_ID ~= 18 and FriendsFrame) or nil
	if not panel then return end
	FriendsPanel.panelName = panel:GetName()
	EnsureTab()
	PlaceTab()
	-- The panel rebuilds its tabs on show; re-hang ours under the new last one.
	if panel.RefreshTabs then hooksecurefunc(panel, "RefreshTabs", PlaceTab) end
	panel:HookScript("OnShow", function() C_Timer.After(0, PlaceTab) end)
	-- A docked Kindred window closes along with the panel.
	panel:HookScript("OnHide", function() ns.UI.HideIfDocked(panel) end)
end

function FriendsPanel.Refresh()
	if tab then tab:SetShown(ns.db.settings.friendsTab) end
	if panel and not ns.db.settings.friendsTab then
		ns.UI.HideIfDocked(panel)
	end
end

function FriendsPanel.Init()
	Install()
	if panel then return end
	-- Blizzard_SocialUI may load on demand.
	ns.On("ADDON_LOADED", function()
		if not panel then Install() end
	end)
end

function FriendsPanel.Dump(p)
	p("  Social panel = " .. tostring(FriendsPanel.panelName)
		.. ", Kindred tab = " .. (tab and (tab.isSideTab and "side tab" or "button") or "none"))
	if FriendsPanel.lastError then p("  Tab error: " .. tostring(FriendsPanel.lastError)) end
	local last = LastSocialTab()
	if last then
		p(string.format("  Last Blizzard tab: %dx%d", last:GetWidth(), last:GetHeight()))
	end
end
