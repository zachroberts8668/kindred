-- Kindred: classic round minimap button (drag to move around the rim).

local _, ns = ...

local MinimapButton = {}
ns.Minimap = MinimapButton

local button

local function UpdatePosition()
	local angle = math.rad(ns.db.settings.minimap.angle or 210)
	local radius = (Minimap:GetWidth() / 2) + 10
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local cx, cy = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	cx, cy = cx / scale, cy / scale
	ns.db.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
	UpdatePosition()
end

local function ShowTooltip(self)
	local online, total = ns.CountFriends()
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("Kindred")
	GameTooltip:AddLine(string.format("Online: |cffffffff%d|r / %d", online, total), 1, 0.82, 0)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: open friends list", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: toggle online alerts", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

function MinimapButton.Init()
	if button then return end
	button = CreateFrame("Button", "KindredForeverMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("TOPLEFT", 7, -6)
	button.icon = icon

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			ns.db.settings.alerts = not ns.db.settings.alerts
			ns.Print("Online alerts " .. (ns.db.settings.alerts and "enabled." or "disabled."))
		else
			ns.UI.Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	UpdatePosition()
	MinimapButton.Refresh()
end

function MinimapButton.Refresh()
	if not button then return end
	button:SetShown(not ns.db.settings.minimap.hide)
end
