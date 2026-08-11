-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Discover.lua — ask the game what the dyes are.
--
-- 12.1 ships C_DyeColor, and it answers in one call the three questions this
-- addon had been reduced to inferring:
--
--   C_DyeColor.GetAllDyeColors()        -> every shade's dyeColorID
--   C_DyeColor.GetDyeColorInfo(colorID) -> { ID, name, itemID, numOwned, ... }
--
-- A shade's `itemID` is the dye item it costs. Group the shades by that item and
-- you have the nine families, each family's item ID, and which shade belongs to
-- which — read from the client rather than worked out from the colour's name.
--
-- WHAT THIS REPLACES. Data.lua shipped with nine `id = nil` dyes and nine shades
-- flagged `guess = true`, because none of it was published and this file's rule is
-- that an ID is read from the game or it doesn't ship. All of that is now filled in
-- at login, from the source of truth, and the guess flags clear themselves.
--
-- Data.lua is still the fallback and is still worth having: it's what the addon
-- knows before the API answers (item names are not always cached at login), what
-- the tests run against, and what keeps the window populated on a client where
-- C_DyeColor is missing or has been renamed. Discovery only ever ADDS certainty —
-- it never blanks a known value on the strength of an empty answer.
--
-- Every call is feature-detected and pcall-wrapped. C_DyeColor is new in 12.1 and
-- may well change shape again before it ships.
--------------------------------------------------------------------------------

local MAX_RETRIES = 8      -- GET_ITEM_INFO_RECEIVED passes before giving up
local retries = 0

ns.discovery = { ran = false, shades = 0, items = 0, colors = 0, pending = 0 }

local function Ready()
	return type(C_DyeColor) == "table"
		and type(C_DyeColor.GetAllDyeColors) == "function"
		and type(C_DyeColor.GetDyeColorInfo) == "function"
end

--------------------------------------------------------------------------------
-- Which of the nine a dye item is
--------------------------------------------------------------------------------

-- From the item's own name: "Brown Housing Dye" -> "brown". The authoritative
-- route, and the reason ns.COLORS is checked rather than trusted — a colour the
-- addon doesn't model (Blizzard adding a tenth) must not be invented into being.
local function ColorFromItemName(itemID)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name = pcall(C_Item.GetItemInfo, itemID)
	if not ok or type(name) ~= "string" then return nil end
	local word = name:match("^(%a+)%s+Housing%s+Dye$")
	if not word then return nil end
	local key = word:lower()
	local entry = ns.byKey and ns.byKey[key]
	if entry and entry.kind == "dye" then return key end
	return nil
end

-- Failing that, from the shades themselves: if Data.lua already places most of
-- this item's shades in one family, that's the family. A majority rather than the
-- first hit, so one shade whose family was guessed wrong can't drag the item with
-- it — and only when the winner is unambiguous, because a tie is not an answer.
local function ColorFromShades(infos)
	local votes, best, bestCount, tied = {}, nil, 0, false
	for _, info in ipairs(infos) do
		local shade = ns.shadeByName and ns.shadeByName[info.name:lower()]
		local color = shade and shade.color
		if color then
			votes[color] = (votes[color] or 0) + 1
			if votes[color] > bestCount then
				best, bestCount, tied = color, votes[color], false
			elseif votes[color] == bestCount and color ~= best then
				tied = true
			end
		end
	end
	if tied then return nil end
	return best
end

--------------------------------------------------------------------------------
-- The pass itself
--------------------------------------------------------------------------------

-- Name -> shade entry, rebuilt each pass so newly added shades are findable.
local function IndexShades()
	ns.shadeByName = {}
	for _, shade in ipairs(ns.SHADES or {}) do
		ns.shadeByName[shade.name:lower()] = shade
	end
end

-- Read everything C_DyeColor knows and fold it into ns.DYES / ns.SHADES.
--
-- Returns ok, plus a table of counts. `pending` is how many dye items couldn't be
-- named yet — the client caches item names lazily, so at login this is normally
-- everything, and the retry below fills them in a moment later.
function ns.DiscoverDyes()
	if not Ready() then return false, "C_DyeColor unavailable" end

	local ok, ids = pcall(C_DyeColor.GetAllDyeColors)
	if not ok or type(ids) ~= "table" then return false, "no dye colors returned" end

	IndexShades()

	-- Gather, grouped by the item each shade costs.
	local byItem, order, seenShades = {}, {}, 0
	for _, colorID in pairs(ids) do
		local got, info = pcall(C_DyeColor.GetDyeColorInfo, colorID)
		if got and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
			seenShades = seenShades + 1
			local itemID = tonumber(info.itemID)
			if itemID and itemID > 0 then
				local group = byItem[itemID]
				if not group then
					group = {}
					byItem[itemID] = group
					order[#order + 1] = itemID
				end
				group[#group + 1] = { ID = tonumber(info.ID) or colorID, name = info.name }
			end
		end
	end

	local resolved, pending = 0, 0
	ns.SHADE_BY_COLORID = ns.SHADE_BY_COLORID or {}

	for _, itemID in ipairs(order) do
		local infos = byItem[itemID]
		local color = ColorFromItemName(itemID) or ColorFromShades(infos)

		if not color then
			-- The item hasn't been named yet and Data.lua can't place its shades.
			-- Ask the client to load it and try again on the next pass; guessing here
			-- would file a whole family under the wrong colour.
			pending = pending + 1
			if C_Item and C_Item.RequestLoadItemDataByID then
				pcall(C_Item.RequestLoadItemDataByID, itemID)
			end
		else
			resolved = resolved + 1
			local dye = ns.byKey and ns.byKey[color]
			if dye and dye.kind == "dye" then
				dye.id = itemID
				if ns.byID then ns.byID[itemID] = dye end
			end

			for _, info in ipairs(infos) do
				local shade = ns.shadeByName[info.name:lower()]
				if shade then
					-- Read from the game, so it is no longer a guess whatever it was.
					shade.color = color
					shade.guess = nil
					shade.dyeColorID = info.ID
				else
					-- A shade Data.lua has never heard of. Blizzard adding colours
					-- mid-patch is exactly the case this whole file exists to absorb.
					-- `key` is set here as well as by RebuildLookups: a shade added
					-- mid-pass is reachable through ns.SHADE_BY_COLORID immediately, and
					-- anything reading its goal before the rebuild would look one up
					-- under a nil key and quietly get nothing.
					shade = {
						name = info.name, key = info.name:lower(),
						color = color, dyeColorID = info.ID,
					}
					ns.SHADES[#ns.SHADES + 1] = shade
					ns.shadeByName[info.name:lower()] = shade
				end
				ns.SHADE_BY_COLORID[info.ID] = shade
			end
		end
	end

	-- Rebuild so shadesByColor, byID and the rest see the new placements.
	if ns.RebuildLookups then ns.RebuildLookups() end
	IndexShades()

	ns.discovery = {
		ran = true,
		shades = seenShades,
		items = #order,
		colors = resolved,
		pending = pending,
	}
	return true, ns.discovery
end

--------------------------------------------------------------------------------
-- Driving it
--
-- Item names are cached lazily, so the first pass at login usually resolves the
-- shades and none of the items. GET_ITEM_INFO_RECEIVED fires as each one arrives;
-- re-running then is cheap and settles within a second or two. Bounded, because a
-- name that never arrives must not leave us re-scanning forever.
--------------------------------------------------------------------------------

local driver = CreateFrame("Frame")

local function Attempt()
	local ok, result = ns.DiscoverDyes()
	if not ok then return end
	if type(result) == "table" and (result.pending or 0) == 0 then
		driver:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
	end
	if ns.Refresh then ns.Refresh() end
end

driver:RegisterEvent("PLAYER_LOGIN")
pcall(driver.RegisterEvent, driver, "GET_ITEM_INFO_RECEIVED")
driver:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		pcall(Attempt)
	else
		retries = retries + 1
		if retries > MAX_RETRIES then
			driver:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
			return
		end
		pcall(Attempt)
	end
end)
