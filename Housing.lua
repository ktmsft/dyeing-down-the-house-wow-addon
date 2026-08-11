-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Housing.lua — a "Dye Needed" panel under the house dye customization window.
--
-- When you're customizing a piece of decor, this hangs a small panel off the
-- bottom of Blizzard's, with a row per COLOR the decor is currently wearing: the
-- shade's name, which of the nine families it costs, how many of those you hold
-- across the account, what your flowers would make, and a box to set the goal.
-- Typing a number there flows straight into the main window's Dye Needed column.
--
-- Three things it deliberately does:
--
--   * IT ASKS THE API, NOT THE FRAMES. C_HousingCustomizeMode reports the selected
--     decor's dye slots outright, applied and previewed, so none of this depends on
--     Blizzard's layout. The frame walk is still here behind it, because 12.1 is
--     moving and an API this new can be renamed as easily as a frame was.
--   * ONE ROW PER COLOUR, NOT PER SLOT. The goal is per-colour, so two slots
--     wearing two blues are one goal — two edit boxes writing the same value would
--     fight, and show the player two answers to one question. A colour used twice
--     says so ("x2"), because that's genuinely how many dyes the decor will spend.
--   * IT BORROWS BLIZZARD'S ART. The background and header are read off the panel
--     above at runtime rather than hardcoded to an atlas name, so a reskin carries
--     over for free and there's no name to guess wrong.
--
-- 12.1 REBUILT THE PANEL AND THIS FILE STOPPED WORKING. Worth recording how,
-- because the failure was invisible: DecorCustomizationsPane never moved, so the
-- old path resolved perfectly — Blizzard pushed a CustomizeComponentContainer
-- underneath it and moved every dye field down into a DyePane inside that. The
-- chain looked fine and everything on the end of it was gone. `currentChannel`
-- has no successor at all, which is why nothing here asks which slot is active.
--
-- These frames are NOT forbidden (Plumber decorates them too), so a plain child
-- frame is safe — we never touch a protected/secure action.
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

-- Names a slot's shade might be carried under. The names differ between the API
-- and the frames, and between builds, so ask for all of them.
--
-- The dye's ITEM id isn't read here any more. A slot names a shade; which of the
-- nine that costs is Discover.lua's answer, from C_DyeColor. Reading an item ID
-- off the panel as well would be a second route to the same fact that could
-- disagree with the first.
local NAME_FIELDS = { "name", "colorName", "dyeName", "dyeColorName" }

local function FirstField(info, fields)
	for _, field in ipairs(fields) do
		local ok, value = pcall(function() return info[field] end)
		if ok and value ~= nil then return value end
	end
	return nil
end

-- Pull identity out of one info table, whatever it happens to be called.
local function ReadInfo(info)
	if type(info) ~= "table" then return nil end
	local name = FirstField(info, NAME_FIELDS)
	local colorID = FirstField(info, { "dyeColorID" })
	if colorID == 0 then colorID = nil end -- 0 means "nothing applied"
	if name == nil and colorID == nil then return nil end
	return name, colorID
end

--------------------------------------------------------------------------------
-- What the decor is currently wearing
--
-- Every dye slot, not just the first. A decor can have two or three, the panel
-- charges one dye per slot, and answering for one of them was only ever a
-- stop-gap from when the frame layout was the only way in.
--
-- The API is the route now. C_HousingCustomizeMode hands over the selected
-- decor's slots directly, with the shade's ID and name on each, so this needs no
-- window open and cannot be broken by Blizzard moving a frame:
--
--   GetSelectedDecorInfo().dyeSlots        -> what is APPLIED
--   GetPreviewDyesOnSelectedDecor()        -> what you have PICKED but not applied
--
-- Both matter, and the preview wins where they disagree — the panel is showing you
-- the preview, so that's the colour you're deciding about. The frame walk is kept
-- behind them for a client where the API is missing or renamed.
--------------------------------------------------------------------------------

local function SlotsFromAPI()
	local slots = {}
	local cm = _G.C_HousingCustomizeMode
	if type(cm) ~= "table" then return nil end

	-- Applied first, keyed by the slot's own ID so the preview can override it.
	local bySlot, order = {}, {}
	local ok, info = pcall(function() return cm.GetSelectedDecorInfo and cm.GetSelectedDecorInfo() end)
	if ok and type(info) == "table" and type(info.dyeSlots) == "table" then
		for _, slot in pairs(info.dyeSlots) do
			local id = tonumber(slot.ID) or tonumber(slot.channel) or (#order + 1)
			if not bySlot[id] then order[#order + 1] = id end
			local name, colorID = ReadInfo(slot)
			bySlot[id] = { name = name, colorID = colorID, orderIndex = tonumber(slot.orderIndex) or 0 }
		end
	end

	-- Then the preview, which is what's actually on screen.
	local pok, previews = pcall(function()
		return cm.GetPreviewDyesOnSelectedDecor and cm.GetPreviewDyesOnSelectedDecor()
	end)
	if pok and type(previews) == "table" then
		for _, preview in pairs(previews) do
			local id = tonumber(preview.dyeSlotID) or tonumber(preview.ID)
			local colorID = tonumber(preview.dyeColorID)
			if colorID == 0 then colorID = nil end
			if id then
				if not bySlot[id] then order[#order + 1] = id end
				local existing = bySlot[id] or {}
				bySlot[id] = {
					name = preview.dyeColorName or existing.name,
					colorID = colorID or existing.colorID,
					orderIndex = existing.orderIndex or 0,
				}
			end
		end
	end

	if #order == 0 then return nil end
	table.sort(order, function(a, b)
		local sa, sb = bySlot[a], bySlot[b]
		if sa.orderIndex ~= sb.orderIndex then return sa.orderIndex < sb.orderIndex end
		return a < b
	end)
	for _, id in ipairs(order) do slots[#slots + 1] = bySlot[id] end
	return slots
end

-- Fallback: walk the panel's slot frames, as before but across all of them.
local function SlotsFromFrames(pane)
	local slots = {}
	pcall(function()
		local seen = {}
		local list = {}
		local byChannel = pane.dyeSlotFramesByChannel or pane.dyeSlotFrames
		if type(byChannel) == "table" then
			for _, slot in pairs(byChannel) do
				if not seen[slot] then seen[slot] = true; list[#list + 1] = slot end
			end
		end
		local container = pane.DyeSlotContainer
		if container and type(container.GetChildren) == "function" then
			for _, child in ipairs({ container:GetChildren() }) do
				if child and not seen[child] then seen[child] = true; list[#list + 1] = child end
			end
		end

		for _, slot in ipairs(list) do
			local swatch = slot.CurrentSwatch or slot.Swatch
			for _, info in ipairs({
				swatch and swatch.dyeColorInfo,
				swatch and swatch.colorInfo,
				slot.dyeSlotInfo,
			}) do
				local name, colorID = ReadInfo(info)
				if name or colorID then
					slots[#slots + 1] = { name = name, colorID = colorID }
					break
				end
			end
		end
	end)
	return slots
end

-- Which of the nine a slot's dye belongs to, from whatever the slot gave us.
--
-- By the game's own shade record ID first, since Discover.lua fills that index in
-- from C_DyeColor and it can't be misspelled. Failing that, by the shade's NAME
-- through ns.SHADES, which is what carries a client where the API is absent.
local function ColorFor(name, colorID)
	if colorID and ns.SHADE_BY_COLORID then
		local shade = ns.SHADE_BY_COLORID[colorID]
		if shade and shade.color then return shade.color end
	end
	if type(name) == "string" then
		local lower = name:lower()
		local byName = ns.byName and ns.byName[lower]
		if byName and byName.kind == "dye" then return byName.color end
		for _, shade in ipairs(ns.SHADES or {}) do
			if shade.name:lower() == lower then return shade.color end
		end
	end
	return nil
end

-- One entry per COLOR, not per slot.
--
-- The goal is per-colour, so two slots wearing two blues are one goal and must be
-- one row — two edit boxes writing the same value would fight each other and show
-- the player two answers. Where a colour is used more than once the count comes
-- with it, because that's genuinely how many dyes this decor will spend.
local function CurrentColors(pane)
	local slots = SlotsFromAPI() or SlotsFromFrames(pane)
	local byColor, order = {}, {}
	for _, slot in ipairs(slots or {}) do
		local color = ColorFor(slot.name, slot.colorID)
		if color then
			local row = byColor[color]
			if not row then
				row = { color = color, slots = 0, names = {} }
				byColor[color] = row
				order[#order + 1] = row
			end
			row.slots = row.slots + 1
			if slot.name then
				local dup = false
				for _, n in ipairs(row.names) do if n == slot.name then dup = true end end
				if not dup then row.names[#row.names + 1] = slot.name end
			end
		end
	end
	return order
end

--------------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------------

local HEADER_H  = 28   -- the wood strip
local TOP_PAD   = 12   -- breathing room under it, before the first row
local ROW_H     = 32
local BOTTOM_PAD = 12

--------------------------------------------------------------------------------
-- Borrowing Blizzard's panel art
--
-- The panel has to look like it belongs under theirs. The way to guarantee that is
-- not to find out what the housing atlas is called and hardcode it — that's a name
-- to guess wrong now and a name to break later. It's to READ the art off the live
-- panel and apply the same values to ours, so a reskin carries over for free.
--
-- Everything here is feature-detected and pcall'd, and each can fail on its own:
-- no atlas is survivable (a plain dark fill still reads as a panel), no header is
-- survivable (the panel just has no title strip).
--------------------------------------------------------------------------------

-- Read `root.a.b.c`, relative to a frame rather than to _G.
local function FollowFrom(root, path)
	local node = root
	for _, part in ipairs(path) do
		local ok, nxt = pcall(function() return node[part] end)
		if not ok or nxt == nil then return nil end
		node = nxt
	end
	return node
end

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

local function CommitRow(row)
	if not (row and row.target) then return end
	ns.SetGoal(row.target, tonumber(row.edit:GetText()) or 0)
	row.edit:ClearFocus()
	if ns.Refresh then ns.Refresh() end
end

local function EnsureRow(index)
	local row = box.rows[index]
	if row then return row end

	row = CreateFrame("Frame", nil, box)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", box, "TOPLEFT", 14, -(HEADER_H + TOP_PAD + (index - 1) * ROW_H))
	row:SetPoint("TOPRIGHT", box, "TOPRIGHT", -14, -(HEADER_H + TOP_PAD + (index - 1) * ROW_H))

	row.swatch = row:CreateTexture(nil, "ARTWORK")
	row.swatch:SetSize(10, 10)
	row.swatch:SetPoint("TOPLEFT", 0, -2)

	row.edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.edit:SetSize(50, 18)
	row.edit:SetPoint("TOPRIGHT", -6, -1)
	row.edit:SetAutoFocus(false)
	row.edit:SetNumeric(true)
	row.edit:SetMaxLetters(5)
	row.edit:SetJustifyH("CENTER")
	row.edit:SetScript("OnEnterPressed", function() CommitRow(row) end)
	row.edit:SetScript("OnEditFocusLost", function() CommitRow(row) end)
	row.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("TOPLEFT", row.swatch, "TOPRIGHT", 6, 2)
	row.name:SetPoint("RIGHT", row.edit, "LEFT", -8, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
	row.detail:SetPoint("RIGHT", row.edit, "LEFT", -8, 0)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)

	box.rows[index] = row
	return row
end

local function EnsureBox(pane)
	if box then return box end

	-- Parent to the outer customize pane, not the DyePane: ours is a sibling panel
	-- hanging off the bottom of the whole thing, and parenting it there means it
	-- inherits show/hide from the panel it belongs to for free.
	local outer = FollowFrom(pane, { "customizePane" }) or pane

	box = CreateFrame("Frame", nil, outer)
	box.rows = {}
	box:SetHeight(HEADER_H + TOP_PAD + ROW_H + BOTTOM_PAD)
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
			box.header:SetPoint("TOPLEFT", -hx, 0)
			box.header:SetPoint("TOPRIGHT", hx, 0)
			box.header:SetHeight(HEADER_H)
		else
			box.header:Hide()
			box.header = nil
		end
	end

	-- Title, styled off the pane's own decor-name label so the font follows theirs.
	box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	box.title:SetPoint("TOP", 0, -9)
	box.title:SetText("Dye Needed")
	local srcTitle = FollowFrom(outer, { "DecorName" })
	if srcTitle then
		pcall(function()
			local font, size, flags = srcTitle:GetFont()
			if font then box.title:SetFont(font, size, flags) end
			box.title:SetTextColor(srcTitle:GetTextColor())
		end)
	end

	return box
end

--------------------------------------------------------------------------------
-- Drawing it
--------------------------------------------------------------------------------

local function UpdatePanel()
	if not DyeingDownTheHouseDB.ui.housingGoalInput then if box then box:Hide() end return end
	local pane = GetPane()
	if not pane then if box then box:Hide() end return end
	local shownOk, shown = pcall(pane.IsShown, pane)
	if not (shownOk and shown) then if box then box:Hide() end return end

	local colors = CurrentColors(pane)
	if not colors or #colors == 0 then if box then box:Hide() end return end

	EnsureBox(pane)

	for index, entry in ipairs(colors) do
		local row = EnsureRow(index)
		row.target = entry.color

		local sw = (ns.SWATCH and ns.SWATCH[entry.color]) or { 0.6, 0.6, 0.6 }
		row.swatch:SetColorTexture(sw[1], sw[2], sw[3])

		-- The panel names a SHADE and the goal is on its FAMILY, so say both. Without
		-- the family the row would read "Midnight Blue" over a number that silently
		-- counts every blue dye, which is the sort of quiet mismatch that makes
		-- someone think the addon is miscounting.
		local family = entry.color:gsub("^%l", string.upper)
		local shades = table.concat(entry.names, ", ")
		local label = (shades ~= "" and shades ~= family)
			and ("%s  (%s)"):format(shades, family) or family
		-- More than one slot wearing this colour means more than one dye spent.
		if entry.slots > 1 then label = ("%s  x%d"):format(label, entry.slots) end
		row.name:SetText(label)

		-- The counts are OURS, not the panel's. Blizzard's numOwned is what this
		-- character can reach; ours is every character, both banks and the Warband
		-- bank, which is what the goal beside it is measured against.
		local rc = ns.GetRecipeStatus and ns.GetRecipeStatus(entry.color)
		local have = ns.GetTotal and ns.GetTotal(entry.color) or 0
		local detail = ("have %d"):format(have)
		if rc then
			if rc.ownedHerbs > 0 then
				detail = ("%s  ·  %d flowers make %d more"):format(detail, rc.ownedHerbs, rc.craftableNow)
			else
				detail = detail .. "  ·  no flowers for it"
			end
		end
		row.detail:SetText(detail)

		-- Don't stomp what the player is typing.
		if not row.edit:HasFocus() then
			local goal = ns.GetGoal(entry.color) or 0
			row.edit:SetText(goal > 0 and tostring(goal) or "")
		end
		row:Show()
	end

	-- Hide any rows left over from a decor with more slots than this one.
	for index = #colors + 1, #box.rows do box.rows[index]:Hide() end

	box:SetHeight(HEADER_H + TOP_PAD + #colors * ROW_H + BOTTOM_PAD)
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
