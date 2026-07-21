local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Housing.lua — a "Dye Needed" input in the house dye customization panel.
--
-- When you're customizing a piece of decor and have a dye selected, this drops a
-- small goal editbox just above the panel's "Cost" line. Typing a number there
-- sets that dye's goal (ns.SetGoal), so it flows straight into the main window's
-- "Dye Needed" column and the Dye Crafting markers — set a target while you're
-- looking at the house.
--
-- The house editor frames are internal and load on demand, so every access is
-- feature-detected and pcall-wrapped. Verified frame shape (2026-07-21, probe):
--   HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane
--     .currentChannel               -> number
--     .dyeSlotFramesByChannel[ch]   -> slot frame
--       .CurrentSwatch.dyeColorInfo -> { itemID, numOwned, name, ID(dyeColorID) }
--     .DyeCostContainer             -> the "Cost" frame (our anchor)
-- Those frames are NOT forbidden (Plumber decorates them too), so a plain child
-- editbox is safe — we never touch a protected/secure action.
--------------------------------------------------------------------------------

local box            -- our editbox container, created once against the pane
local THROTTLE = 0.2 -- seconds between panel polls (cheap; bails instantly off-house)

-- The decor customize pane, or nil if the house editor isn't in decor mode.
local function GetPane()
	local hef = _G.HouseEditorFrame
	local cmf = hef and hef.CustomizeModeFrame
	return cmf and cmf.DecorCustomizationsPane or nil
end

-- The dye currently selected in the active slot: item id, owned count, name.
local function CurrentDye(pane)
	local ok, itemID, numOwned, name = pcall(function()
		local ch = pane.currentChannel
		local slots = pane.dyeSlotFramesByChannel
		local slot = ch and slots and slots[ch]
		local swatch = slot and slot.CurrentSwatch
		local info = swatch and swatch.dyeColorInfo
		if not info then return nil end
		return info.itemID, info.numOwned, info.name
	end)
	if not ok then return nil end
	return itemID, numOwned, name
end

local function Commit()
	if not (box and box.target) then return end
	local n = tonumber(box.edit:GetText()) or 0
	ns.SetGoal(box.target, n)
	box.edit:ClearFocus()
	if ns.Refresh then ns.Refresh() end
	if ns.RefreshCraftingMarkers then ns.RefreshCraftingMarkers() end
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
	-- rides along if the panel relays out.
	box:ClearAllPoints()
	local anchor = pane.DyeCostContainer or pane
	box:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 4, 8)
	return box
end

local function UpdatePanel()
	if not DyingDownTheHouseDB.ui.housingGoalInput then if box then box:Hide() end return end
	local pane = GetPane()
	if not pane then if box then box:Hide() end return end
	local shownOk, shown = pcall(pane.IsShown, pane)
	if not (shownOk and shown) then if box then box:Hide() end return end

	local itemID, numOwned, dyeName = CurrentDye(pane)
	local entry = itemID and ns.byID and ns.byID[itemID]
	-- Only dyes we actually track can carry a goal; anything else, stay hidden.
	if not (entry and entry.key) then if box then box:Hide() end return end

	EnsureBox(pane)
	box.target = entry.key

	local owned = tonumber(numOwned)
	box.name:SetText(owned and ("%s  —  own %d"):format(dyeName or entry.name, owned)
		or (dyeName or entry.name))

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
