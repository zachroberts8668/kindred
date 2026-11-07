-- Forever Friends: friend dots on the world map.
-- Positions come from friends who run the addon, list you, and share their
-- map position (Options). They update with each ping (about once a minute),
-- and are never available inside instances.

local _, ns = ...
local Names = ns.Names

local MapPins = {}
ns.MapPins = MapPins

local pins = {}
local hooked = false

local function ClassColor(classFile)
	if not classFile then return 1, 0.82, 0 end
	if C_ClassColor and C_ClassColor.GetClassColor then
		local c = C_ClassColor.GetClassColor(classFile)
		if c then return c.r, c.g, c.b end
	end
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if c then return c.r, c.g, c.b end
	return 1, 0.82, 0
end

local function GetCanvas()
	if WorldMapFrame.GetCanvas then
		local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
		if ok and canvas then return canvas end
	end
	return WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function CanvasScale()
	local sc = WorldMapFrame.ScrollContainer
	if sc and sc.GetCanvasScale then
		local ok, scale = pcall(sc.GetCanvasScale, sc)
		if ok and type(scale) == "number" and scale > 0 then return scale end
	end
	return 1
end

-- Translate a friend's (mapID, x, y) onto the map currently shown, so a
-- friend in Elwynn Forest also appears on the Eastern Kingdoms map.
local function Translate(m, shownMap)
	if m.id == shownMap then return m.x, m.y end
	if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
	local ok, continent, worldPos = pcall(C_Map.GetWorldPosFromMapPos, m.id, CreateVector2D(m.x, m.y))
	if not ok or not continent or not worldPos then return nil end
	local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, worldPos, shownMap)
	if not ok2 or not pos then return nil end
	local x, y = pos:GetXY()
	if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
	return nil
end

local function ShowPinTooltip(pin)
	local f = ns.GetFriend(pin.key)
	local s = ns.Presence.Get(pin.key)
	if not f or not s then return end
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	GameTooltip:AddLine(Names.Display(f.first, f.last), ClassColor(s.class))
	local parts = {}
	if s.level then table.insert(parts, "Level " .. s.level) end
	if s.class and LOCALIZED_CLASS_NAMES_MALE then table.insert(parts, LOCALIZED_CLASS_NAMES_MALE[s.class] or s.class) end
	if #parts > 0 then GameTooltip:AddLine(table.concat(parts, " "), 1, 1, 1) end
	if type(s.zone) == "string" then GameTooltip:AddLine(s.zone, 0.8, 0.8, 0.8) end
	GameTooltip:AddLine("Forever Friends - position updates about once a minute", 0.5, 0.5, 0.5, true)
	GameTooltip:Show()
end

local function AcquirePin(i, canvas)
	local pin = pins[i]
	if not pin then
		pin = CreateFrame("Frame", nil, canvas)
		pin.dot = pin:CreateTexture(nil, "OVERLAY")
		pin.dot:SetAllPoints()
		pin.dot:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
		pin:EnableMouse(true)
		pin:SetScript("OnEnter", ShowPinTooltip)
		pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
		pins[i] = pin
	end
	if pin:GetParent() ~= canvas then pin:SetParent(canvas) end
	return pin
end

function MapPins.Refresh()
	for _, pin in ipairs(pins) do pin:Hide() end
	if not hooked or not WorldMapFrame:IsShown() or not ns.db.settings.showMapPins then return end
	local okM, shownMap = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
	local canvas = GetCanvas()
	if not okM or not shownMap or not canvas then return end
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	local size = 16 / CanvasScale()
	local n = 0
	for key in pairs(ns.db.friends) do
		local s = ns.Presence.Get(key)
		if s and s.online and type(s.map) == "table" and not s.unreachable and not ns.IsMyKey(key) then
			local x, y = Translate(s.map, shownMap)
			if x then
				n = n + 1
				local pin = AcquirePin(n, canvas)
				pin.key = key
				pin:SetSize(size, size)
				pin:SetFrameLevel(canvas:GetFrameLevel() + 2000)
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
				pin.dot:SetVertexColor(ClassColor(s.class))
				pin:Show()
			end
		end
	end
end

local function Hook()
	if hooked or not WorldMapFrame then return end
	hooked = true
	WorldMapFrame:HookScript("OnShow", MapPins.Refresh)
	if type(WorldMapFrame.OnMapChanged) == "function" then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", MapPins.Refresh)
	end
	-- Keep pins sized/placed while zooming and as positions arrive.
	C_Timer.NewTicker(1, function()
		if WorldMapFrame:IsShown() then MapPins.Refresh() end
	end)
end

function MapPins.Init()
	if WorldMapFrame then
		Hook()
	else
		ns.On("ADDON_LOADED", function(name)
			if name == "Blizzard_WorldMap" then Hook() end
		end)
	end
end
