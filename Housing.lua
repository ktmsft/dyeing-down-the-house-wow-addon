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

-- Where the dye pane has been known to live. First hit wins. Add to this rather
-- than editing it: a client on an older build should keep working.
--
-- 12.1 did not move DecorCustomizationsPane — it pushed a CustomizeComponentContainer
-- underneath it and moved every dye field down into a DyePane inside that. So the
-- old path still resolves and its contents are all gone, which is exactly the shape
-- of failure that reads as "the addon broke" rather than "Blizzard moved a frame".
--
-- `activeModeFrame` is tried first: it's whichever mode frame is currently up, so
-- it keeps working if the dye panel ever appears in another mode. CustomizeModeFrame
-- is the same object today and is kept as the named fallback.
local PANE_PATHS = {
	{ "HouseEditorFrame", "activeModeFrame", "DecorCustomizationsPane",
		"CustomizeComponentContainer", "DyePane" },
	{ "HouseEditorFrame", "CustomizeModeFrame", "DecorCustomizationsPane",
		"CustomizeComponentContainer", "DyePane" },
	-- pre-12.1: the pane itself carried the dye fields
	{ "HouseEditorFrame", "CustomizeModeFrame", "DecorCustomizationsPane" },
	{ "HouseEditorFrame", "DecorCustomizationsPane" },
}

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

-- Fields an info table might carry the dye's identity under, in the order they're
-- worth trusting. Item ID first: it's read off the item and can't be misspelled.
local ID_FIELDS   = { "itemID", "itemId", "dyeItemID" }
local NAME_FIELDS = { "name", "colorName", "dyeName", "dyeColorName" }
local OWNED_FIELDS = { "numOwned", "owned", "quantity", "count" }

local function FirstField(info, fields)
	for _, field in ipairs(fields) do
		local ok, value = pcall(function() return info[field] end)
		if ok and value ~= nil then return value end
	end
	return nil
end

-- Pull identity out of one info table, whatever it happens to be called.
--
-- `dyeColorID` is read as a third route to the answer. An unpainted slot reports
-- it as 0 and carries no name at all — 12.1's dyeSlotInfo is IDs and nothing else
-- ({ ID, channel, dyeColorCategoryID, dyeColorID, orderIndex }) — so a slot only
-- becomes readable by name once a dye is actually on it. The ID works either way,
-- once ns.SHADE_BY_COLORID knows what the numbers mean.
--
-- dyeColorCategoryID is deliberately NOT read here. It is not known to be one of
-- the nine families: a rug reports category 3 on slot 1 while the swatch grid
-- offers that slot every colour in the game, so it is much more likely to be a
-- material category. Wiring goals to it on a guess would put every count in the
-- addon against the wrong colour.
local function ReadInfo(info)
	if type(info) ~= "table" then return nil end
	local itemID = FirstField(info, ID_FIELDS)
	local name = FirstField(info, NAME_FIELDS)
	local colorID = FirstField(info, { "dyeColorID" })
	if colorID == 0 then colorID = nil end -- 0 means "nothing applied"
	if itemID == nil and name == nil and colorID == nil then return nil end
	return itemID, FirstField(info, OWNED_FIELDS), name, colorID
end

-- The dye currently selected: item id, owned count, name.
--
-- `currentChannel` is gone in 12.1 with nothing obviously in its place, so rather
-- than guess at a replacement this walks every dye slot and takes the first that
-- actually holds a dye. A decor has two slots and a goal is per-COLOR now, so
-- picking the wrong one of two slots that both hold blue costs nothing — where
-- guessing a field name that doesn't exist costs the whole feature, which is what
-- 12.1 just did to it.
--
-- The slot frames are reachable two ways (a keyed table and a container's children)
-- and both are tried, because the keyed one is the field most likely to be renamed
-- next and the children are structural.
local function CurrentDye(pane)
	local ok, itemID, numOwned, name, colorID = pcall(function()
		local slots = {}

		local byChannel = pane.dyeSlotFramesByChannel or pane.dyeSlotFrames
		if type(byChannel) == "table" then
			for _, slot in pairs(byChannel) do slots[#slots + 1] = slot end
		end
		local container = pane.DyeSlotContainer
		if container and type(container.GetChildren) == "function" then
			for _, child in ipairs({ container:GetChildren() }) do
				slots[#slots + 1] = child
			end
		end

		for _, slot in ipairs(slots) do
			-- The slot's own info, then its swatch's. Either can carry the identity
			-- depending on whether the slot has been painted yet.
			local swatch = slot.CurrentSwatch or slot.Swatch
			for _, info in ipairs({
				swatch and swatch.dyeColorInfo,
				swatch and swatch.colorInfo,
				slot.dyeSlotInfo,
				swatch and swatch.dyeSlotInfo,
			}) do
				local id, owned, nm, cid = ReadInfo(info)
				if id ~= nil or nm ~= nil or cid ~= nil then return id, owned, nm, cid end
			end
		end

		-- A getter beats any of it when it's there: GetPreviewDyeInfos returns what
		-- the panel is actually about to apply.
		if type(pane.GetPreviewDyeInfos) == "function" then
			local infos = pane:GetPreviewDyeInfos()
			if type(infos) == "table" then
				for _, info in pairs(infos) do
					local id, owned, nm, cid = ReadInfo(info)
					if id ~= nil or nm ~= nil or cid ~= nil then return id, owned, nm, cid end
				end
			end
		end

		return nil
	end)
	if not ok then return nil end
	return itemID, numOwned, name, colorID
end

-- Which of the nine colors the panel is showing, from whatever it gave us.
--
-- By item ID first, because that's read straight off the item and can't be wrong.
-- Failing that, by name — and the name is now a SHADE ("Midnight Blue"), not an
-- item, so it goes through ns.SHADES to reach the family. That fallback is what
-- keeps this working before anyone has filled in Data.lua's item IDs, and it's why
-- ns.SHADES carries every one of the 77 names rather than just the interesting ones.
local function ColorFor(itemID, name, colorID)
	local entry = itemID and ns.byID and ns.byID[itemID]
	if entry and entry.kind == "dye" then return entry.color end

	-- By the game's own shade record ID, once we know what the numbers mean. This
	-- is the only route that works on a slot the panel hasn't named for us, which
	-- 12.1's all-IDs dyeSlotInfo makes the common case.
	if colorID and ns.SHADE_BY_COLORID then
		local shade = ns.SHADE_BY_COLORID[colorID]
		if shade and shade.color then return shade.color end
	end

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

local function FollowFrom(root, path)
	local node = root
	for _, part in ipairs(path) do
		local ok, nxt = pcall(function() return node[part] end)
		if not ok or nxt == nil then return nil end
		node = nxt
	end
	return node
end

--------------------------------------------------------------------------------
-- Borrowing Blizzard's panel art
--
-- The box sits in its own little panel below the customize pane, and it has to
-- look like it belongs there. The way to guarantee that is not to find out what
-- the housing panel's atlas is called and hardcode it — that's a name to guess
-- wrong now and a name to break later. It's to READ the art off the live panel
-- and apply the same values to ours. Blizzard can rename, restyle or reskin the
-- whole thing and we follow along for free, because we never knew the name.
--
-- Everything here is feature-detected and pcall'd, and every one of them can fail
-- independently: no atlas is survivable (we fall back to a plain dark backdrop),
-- no header is survivable (the panel just has no title strip).
--------------------------------------------------------------------------------

-- Copy one texture's appearance onto another. Atlas first, because that's how the
-- modern UI is built and it carries its own sizing; a plain file path with tex
-- coords is the older shape and still worth handling.
local function CopyArt(dest, source)
	if not (dest and source) then return false end
	local atlas = nil
	pcall(function() atlas = source.GetAtlas and source:GetAtlas() end)
	if atlas then
		local ok = pcall(function() dest:SetAtlas(atlas, true) end)
		if ok then return true end
	end
	local file = nil
	pcall(function() file = source.GetTexture and source:GetTexture() end)
	if file then
		local ok = pcall(function()
			dest:SetTexture(file)
			dest:SetTexCoord(source:GetTexCoord())
		end)
		if ok then return true end
	end
	return false
end

-- How far a Blizzard panel's background texture overhangs its frame, so ours can
-- overhang by the same amount and the borders line up. Read rather than assumed:
-- the customize pane is a 269x280 frame under a 289x300 texture, which is a 10px
-- bleed on every side, and that number is theirs to change.
local function ArtBleed(texture, frame)
	local bx, by = 0, 0
	pcall(function()
		bx = math.max(0, (texture:GetWidth() - frame:GetWidth()) / 2)
		by = math.max(0, (texture:GetHeight() - frame:GetHeight()) / 2)
	end)
	return bx, by
end

local PANEL_H = 74

local function EnsureBox(pane)
	if box then return box end

	-- Parent to the outer customize pane, not the DyePane: ours is a sibling panel
	-- hanging off the bottom of the whole thing, and parenting it there means it
	-- inherits show/hide from the panel it belongs to for free.
	local outer = FollowFrom(pane, { "customizePane" }) or pane

	box = CreateFrame("Frame", nil, outer)
	box:SetHeight(PANEL_H)
	box:SetPoint("TOPLEFT", outer, "BOTTOMLEFT", 0, -2)
	box:SetPoint("TOPRIGHT", outer, "BOTTOMRIGHT", 0, -2)

	-- Background, borrowed from the pane above it.
	local srcBG = FollowFrom(outer, { "Background" })
	box.bg = box:CreateTexture(nil, "BACKGROUND")
	if srcBG and CopyArt(box.bg, srcBG) then
		local bx, by = ArtBleed(srcBG, outer)
		box.bg:SetPoint("TOPLEFT", -bx, by)
		box.bg:SetPoint("BOTTOMRIGHT", bx, -by)
	else
		-- No art to borrow. A plain dark fill still reads as a panel rather than as
		-- floating text over the world, which is the thing actually worth avoiding.
		box.bg:SetAllPoints()
		box.bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)
	end

	-- Header strip, same trick.
	local srcHeader = FollowFrom(outer, { "WoodHeader" })
	if srcHeader then
		box.header = box:CreateTexture(nil, "BORDER")
		if CopyArt(box.header, srcHeader) then
			local hx = ArtBleed(srcHeader, outer)
			local h = 26
			pcall(function() h = math.min(30, srcHeader:GetHeight() or 30) end)
			box.header:SetPoint("TOPLEFT", -hx, 0)
			box.header:SetPoint("TOPRIGHT", hx, 0)
			box.header:SetHeight(h)
		else
			box.header:Hide()
			box.header = nil
		end
	end

	-- Title, styled off the pane's own decor-name label so the font follows theirs.
	box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	box.title:SetPoint("TOP", 0, -8)
	box.title:SetText("Dye Needed")
	local srcTitle = FollowFrom(outer, { "DecorName" })
	if srcTitle then
		pcall(function()
			local font, size, flags = srcTitle:GetFont()
			if font then box.title:SetFont(font, size, flags) end
			box.title:SetTextColor(srcTitle:GetTextColor())
		end)
	end

	box.name = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	box.name:SetPoint("TOPLEFT", 14, -32)
	box.name:SetPoint("TOPRIGHT", -14, -32)
	box.name:SetJustifyH("LEFT")
	box.name:SetWordWrap(false)

	box.edit = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
	box.edit:SetSize(52, 18)
	box.edit:SetPoint("TOPLEFT", 18, -48)
	box.edit:SetAutoFocus(false)
	box.edit:SetNumeric(true)
	box.edit:SetMaxLetters(5)
	box.edit:SetJustifyH("CENTER")
	box.edit:SetScript("OnEnterPressed", Commit)
	box.edit:SetScript("OnEditFocusLost", Commit)
	box.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	box.hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	box.hint:SetPoint("LEFT", box.edit, "RIGHT", 10, 0)
	box.hint:SetPoint("RIGHT", box, "RIGHT", -14, 0)
	box.hint:SetJustifyH("LEFT")
	box.hint:SetWordWrap(false)

	return box
end

local function UpdatePanel()
	if not DyeingDownTheHouseDB.ui.housingGoalInput then if box then box:Hide() end return end
	local pane = GetPane()
	if not pane then if box then box:Hide() end return end
	local shownOk, shown = pcall(pane.IsShown, pane)
	if not (shownOk and shown) then if box then box:Hide() end return end

	local itemID, numOwned, dyeName, colorID = CurrentDye(pane)
	local color = ColorFor(itemID, dyeName, colorID)
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

	-- The count shown is OURS, not the panel's `numOwned`. Blizzard's is what this
	-- character can reach; ours is every character, both banks and the Warband bank,
	-- which is the number the goal beside it is measured against. Showing the
	-- panel's here would put two different figures for one colour on one line and
	-- make the goal look wrong.
	local have = ns.GetTotal and ns.GetTotal(color) or tonumber(numOwned)
	box.name:SetText(have and ("%s  —  have %d"):format(label, have) or label)

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
