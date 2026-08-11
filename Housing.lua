-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Housing.lua — a "Dye Needed" input in the house dye customization panel.
--
-- When you're customizing a piece of decor and have a dye selected, this drops a
-- small goal editbox just above the panel's "Cost" line. Typing a number there sets
-- that color's goal (ns.SetGoal), so it flows straight into the main window's "Dye
-- Needed" column — set a target while you're looking at the house.
--
-- 12.1 REBUILT THIS PANEL AND THIS FILE STOPPED WORKING. The shape below was
-- verified by probe on 2026-07-21 and every path in it now resolves to nil on the
-- PTR, so the box simply never appeared:
--   HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane
--     .currentChannel               -> number
--     .dyeSlotFramesByChannel[ch]   -> slot frame
--       .CurrentSwatch.dyeColorInfo -> { itemID, numOwned, name, ID(dyeColorID) }
--     .DyeCostContainer             -> the "Cost" frame (our anchor)
--
-- Rather than guess at the new one, this file now does three things:
--   * It tries a LIST of candidate paths instead of one hardcoded chain, so the old
--     shape still works on a client that still has it and a renamed one can be
--     added as a single line once `/dye probe panel` says what it's called.
--   * It resolves the selected dye by SHADE NAME as well as by item ID. The panel
--     shows a color name ("Midnight Blue"), and ns.SHADES already maps that to its
--     family — so the box can work out which of the nine to set a goal on even
--     while Data.lua's item IDs are still nil.
--   * It fails quietly and completely. No anchor, no box; nothing errors, nothing
--     is left half-drawn on someone's screen.
--
-- These frames are NOT forbidden (Plumber decorates them too), so a plain child
-- editbox is safe — we never touch a protected/secure action.
--------------------------------------------------------------------------------

local box            -- our editbox container, created once against the pane
local THROTTLE = 0.2 -- seconds between panel polls (cheap; bails instantly off-house)

-- Where the decor customize pane has been known to live. First hit wins. Add to
-- this rather than editing it: a client on the old build should keep working.
local PANE_PATHS = {
	{ "HouseEditorFrame", "CustomizeModeFrame", "DecorCustomizationsPane" },
	{ "HouseEditorFrame", "CustomizeModeFrame", "DyeCustomizationsPane" },
	{ "HouseEditorFrame", "DecorCustomizationsPane" },
	{ "HousingDyeFrame" },
}

-- Names the "Cost" line has gone by; the box anchors above whichever exists. Not
-- finding one is survivable — the pane itself is the fallback anchor.
local COST_FIELDS = { "DyeCostContainer", "CostContainer", "Cost", "DyeCost" }

local function Follow(path)
	local node = _G
	for _, part in ipairs(path) do
		local ok, nxt = pcall(function() return node[part] end)
		if not ok or nxt == nil then return nil end
		node = nxt
	end
	return node
end

-- The decor customize pane, or nil if the house editor isn't in decor mode.
local function GetPane()
	for _, path in ipairs(PANE_PATHS) do
		local pane = Follow(path)
		if pane then return pane end
	end
	return nil
end

-- The dye currently selected in the active slot: item id, owned count, name.
--
-- The shapes differ between builds, so this reads whichever of them answers rather
-- than insisting on one. Anything missing comes back nil and the caller copes.
local function CurrentDye(pane)
	local ok, itemID, numOwned, name = pcall(function()
		local ch = pane.currentChannel or pane.currentDyeSlot or 1
		local slots = pane.dyeSlotFramesByChannel or pane.dyeSlotFrames
		local slot = (ch and slots and slots[ch]) or pane.SelectedDyeSlot
		local swatch = slot and (slot.CurrentSwatch or slot.Swatch)
		local info = (swatch and (swatch.dyeColorInfo or swatch.colorInfo))
			or pane.selectedDyeColorInfo
		if not info then return nil end
		return info.itemID, info.numOwned, info.name or info.colorName
	end)
	if not ok then return nil end
	return itemID, numOwned, name
end

-- Which of the nine colors the panel is showing, from whatever it gave us.
--
-- By item ID first, because that's read straight off the item and can't be wrong.
-- Failing that, by name — and the name is now a SHADE ("Midnight Blue"), not an
-- item, so it goes through ns.SHADES to reach the family. That fallback is what
-- keeps this working before anyone has filled in Data.lua's item IDs, and it's why
-- ns.SHADES carries every one of the 77 names rather than just the interesting ones.
local function ColorFor(itemID, name)
	local entry = itemID and ns.byID and ns.byID[itemID]
	if entry and entry.kind == "dye" then return entry.color end

	if type(name) == "string" then
		local lower = name:lower()
		-- An exact item name ("Blue Housing Dye") resolves directly.
		local byName = ns.byName and ns.byName[lower]
		if byName and byName.kind == "dye" then return byName.color end
		-- Otherwise it's a shade name.
		for _, shade in ipairs(ns.SHADES or {}) do
			if shade.name:lower() == lower then return shade.color end
		end
	end
	return nil
end

local function Commit()
	if not (box and box.target) then return end
	local n = tonumber(box.edit:GetText()) or 0
	ns.SetGoal(box.target, n)
	box.edit:ClearFocus()
	if ns.Refresh then ns.Refresh() end
end

local function EnsureBox(pane)
	if box then return box end
	box = CreateFrame("Frame", nil, pane)
	box:SetSize(170, 40)

	box.name = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	box.name:SetPoint("TOPLEFT", 0, 0)
	box.name:SetWidth(170)
	box.name:SetJustifyH("LEFT")
	box.name:SetWordWrap(false)

	box.label = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	box.label:SetPoint("TOPLEFT", 0, -16)
	box.label:SetText("Dye Needed")

	box.edit = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
	box.edit:SetSize(46, 20)
	box.edit:SetPoint("LEFT", box.label, "RIGHT", 10, 0)
	box.edit:SetAutoFocus(false)
	box.edit:SetNumeric(true)
	box.edit:SetMaxLetters(5)
	box.edit:SetJustifyH("CENTER")
	box.edit:SetScript("OnEnterPressed", Commit)
	box.edit:SetScript("OnEditFocusLost", Commit)
	box.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- Anchor the box just above the Cost line. Anchored TO the cost frame, so it
	-- rides along if the panel relays out. The field has had several names across
	-- builds; the pane itself is the fallback, which puts the box somewhere visible
	-- rather than nowhere at all.
	box:ClearAllPoints()
	local anchor = pane
	for _, field in ipairs(COST_FIELDS) do
		local ok, candidate = pcall(function() return pane[field] end)
		if ok and candidate then anchor = candidate; break end
	end
	box:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 4, 8)
	return box
end

local function UpdatePanel()
	if not DyeingDownTheHouseDB.ui.housingGoalInput then if box then box:Hide() end return end
	local pane = GetPane()
	if not pane then if box then box:Hide() end return end
	local shownOk, shown = pcall(pane.IsShown, pane)
	if not (shownOk and shown) then if box then box:Hide() end return end

	local itemID, numOwned, dyeName = CurrentDye(pane)
	local color = ColorFor(itemID, dyeName)
	-- Only colors we actually track can carry a goal; anything else, stay hidden.
	if not color then if box then box:Hide() end return end

	EnsureBox(pane)
	box.target = color

	-- The panel names a SHADE and the goal is on its FAMILY, so say both. Without
	-- the family the box would read "Midnight Blue — Dye Needed" over a number that
	-- silently counts every blue dye, which is the sort of quiet mismatch that makes
	-- someone think the addon is miscounting.
	local family = color:gsub("^%l", string.upper)
	local label = dyeName and (dyeName ~= family) and ("%s  (%s)"):format(dyeName, family)
		or family
	local owned = tonumber(numOwned)
	box.name:SetText(owned and ("%s  —  own %d"):format(label, owned) or label)

	-- Don't stomp what the player is typing.
	if not box.edit:HasFocus() then
		local g = ns.GetGoal(box.target) or 0
		box.edit:SetText(g > 0 and tostring(g) or "")
	end
	box:Show()
end

-- One throttled ticker. The first line bails almost for free whenever the house
-- editor isn't even loaded, so leaving it running costs nothing off-house.
local driver = CreateFrame("Frame")
local acc = 0
local function Tick(_, elapsed)
	if not _G.HouseEditorFrame then return end
	acc = acc + elapsed
	if acc < THROTTLE then return end
	acc = 0
	pcall(UpdatePanel)
end

-- Don't spin the ticker until housing is actually in play. Enable it the first
-- time a housing addon loads, or on entering the world with the editor present.
local function EnableTicker()
	driver:SetScript("OnUpdate", Tick)
end

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" then
		if type(name) == "string" and name:lower():find("housing", 1, true) then
			EnableTicker()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if _G.HouseEditorFrame then EnableTicker() end
	end
end)

-- Editor already loaded (e.g. /reload with the panel open)? Start now.
if _G.HouseEditorFrame then EnableTicker() end
