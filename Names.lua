-- Kindred: character name helpers.
--
-- WoW Forever names are "First Surname" and unique per region (no realms).
-- The tuple APIs (UnitName, UnitNameUnmodified) return (first, surname), and
-- the client joins the two with CHARACTERNAME_SURNAME_SEPARATOR when it needs
-- a single target string (whispers, invites, addon messages). We never assume
-- that separator: everything is parsed from letter runs and re-joined using
-- the client's own helpers.

local _, ns = ...

local Names = {}
ns.Names = Names

-- Names may only contain letters; UTF-8 bytes (accents) are >= 128.
local LETTERS = "[%a\128-\255]+"

local function IsSecret(v)
	if v == nil or not issecretvalue then return false end
	local ok, secret = pcall(issecretvalue, v)
	return not ok or secret == true
end
Names.IsSecret = IsSecret

local function IsSafe(v)
	return v ~= nil and not IsSecret(v) and type(v) == "string" and v ~= ""
end
Names.IsSafe = IsSafe

local function IsSafeValue(v)
	return v ~= nil and not IsSecret(v)
end
Names.IsSafeValue = IsSafeValue

-- Case folding that also covers Latin-1 accents (À-Þ) and Cyrillic, which
-- string.lower leaves alone. Same approach as RoadToSixty's Friends.lua.
function Names.Lower(s)
	return (s:lower():gsub("\195([\128-\158])", function(c)
		if c ~= "\151" then return "\195" .. string.char(c:byte() + 32) end -- skip ×
	end):gsub("\208([\128-\175])", function(c)
		local b = c:byte()
		if b >= 144 and b < 160 then return "\208" .. string.char(b + 32) end
		return "\209" .. string.char(b < 144 and b + 16 or b - 32)
	end))
end

-- Uppercase the first character (ASCII or Latin-1 accent), fold the rest.
local function Cap(s)
	s = Names.Lower(s)
	local b1, b2 = s:byte(1, 2)
	if b1 == 195 and b2 and b2 >= 160 and b2 <= 190 and b2 ~= 183 then
		return "\195" .. string.char(b2 - 32) .. s:sub(3)
	end
	return s:sub(1, 1):upper() .. s:sub(2)
end

function Names.RegionalNamesEnabled()
	if type(RegionalUniqueNamesEnabled) ~= "function" then
		return false
	end
	local ok, enabled = pcall(RegionalUniqueNamesEnabled)
	return ok and IsSafeValue(enabled) and enabled == true
end

function Names.Separator()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	local sep = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
	if IsSafe(sep) then
		return sep
	end
	return "-"
end

-- Parse any name text ("ana forever", "Ana-Forever", "Ana Forever") into
-- (First, Last). Last can be nil when only one part is present.
function Names.Split(text)
	if not IsSafe(text) then return nil end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	local first, last
	for word in text:gmatch(LETTERS) do
		if not first then
			first = word
		elseif not last then
			last = word
		else
			break
		end
	end
	if not first then return nil end
	return Cap(first), last and Cap(last) or nil
end

function Names.Key(first, last)
	if not first then return nil end
	return Names.Lower(first) .. " " .. (last and Names.Lower(last) or "")
end

function Names.KeyFromText(text)
	local first, last = Names.Split(text)
	return Names.Key(first, last), first, last
end

function Names.Display(first, last)
	if last then
		return first .. " " .. last
	end
	return first
end

-- The string the client wants for whispers, invites and addon messages.
function Names.Target(first, last)
	if not last then return first end
	if NameUtil and type(NameUtil.GetFullNameWithoutRealm) == "function" then
		local ok, full = pcall(NameUtil.GetFullNameWithoutRealm, first, last)
		if ok and IsSafe(full) and full ~= first then
			return full
		end
	end
	return first .. Names.Separator() .. last
end

-- Player hyperlink for chat output.
function Names.Link(first, last)
	local target = Names.Target(first, last)
	if C_NameUtil and type(C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator) == "function" then
		local ok, converted = pcall(C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, target)
		if ok and IsSafe(converted) then
			target = converted
		end
	end
	return "|Hplayer:" .. target .. "|h[" .. Names.Display(first, last) .. "]|h"
end

-- Join a (name, realmOrSurname) pair the way the client hands them out.
function Names.FromParts(name, second)
	if not IsSafe(name) then return nil end
	if IsSafe(second) and Names.RegionalNamesEnabled() then
		local first, last = Names.Split(name)
		if first and not last then
			return Names.Split(name .. " " .. second)
		end
		return first, last
	end
	-- Some name fields come back already joined ("First-Last").
	return Names.Split(name)
end

-- (First, Last) for a player unit, or nil.
function Names.FromUnit(unit)
	local okP, isPlayer = pcall(UnitIsPlayer, unit)
	if not okP or not IsSafeValue(isPlayer) or not isPlayer then
		return nil
	end
	local fn = UnitNameUnmodified or UnitName
	local ok, name, second = pcall(fn, unit)
	if not ok then return nil end
	return Names.FromParts(name, second)
end

-- Trim to at most maxBytes without cutting a UTF-8 character in half.
function Names.Truncate(s, maxBytes)
	if #s <= maxBytes then return s end
	local out, n = {}, 0
	for ch in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
		if n + #ch > maxBytes then break end
		out[#out + 1] = ch
		n = n + #ch
	end
	return table.concat(out)
end

-- Remove WoW escape codes (|T textures, |H links, colors) from text that
-- came from another player.
function Names.StripEscapes(s)
	if not IsSafe(s) then return nil end
	s = s:gsub("|", "")
	return s
end
