-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Probe.lua — read the game's own shape instead of guessing at it.
--
-- 12.1 rebuilt the house dye panel. The frame paths Housing.lua was verified
-- against in July resolve to nothing now, which is why the "Dye Needed" box stopped
-- appearing, and the nine new dye items have IDs that aren't published anywhere.
-- Both are questions only the client can answer, so this asks it.
--
-- `/dye probe` runs every section and drops the result in a window you can select
-- and copy out of. `/dye probe <section>` runs one:
--
--   items    every "… Housing Dye" the account can see, with its item ID. This is
--            the one that matters — it's how Data.lua's nil IDs get filled in, and
--            it needs no frames at all, just the items somewhere you can reach.
--   panel    the house dye panel's live frame tree, plus a verdict on each path
--            Housing.lua depends on, so a broken anchor names itself.
--   swatches the color swatch grid: every shade the panel offers and, where the
--            grid carries one, the dye item it costs. That's the shade -> family
--            map, read from the game rather than inferred from the color's name.
--
-- Rules this file lives by, because it pokes at internals that are not ours:
--   * It reads. It never writes a field, never calls a setter, never touches
--     anything protected. A probe that changed state would be a taint bug wearing
--     a diagnostic's hat.
--   * Every single access is pcall-wrapped and every traversal is depth- and
--     count-bounded. This walks frames that may not exist, in a patch that is
--     still moving; it has to be impossible for it to error or to hang.
--   * It prints what it FOUND and what it LOOKED FOR AND MISSED. A probe that only
--     reports hits can't tell "the field moved" from "the field is empty".
--------------------------------------------------------------------------------

local MAX_DEPTH    = 6      -- frame-tree levels to descend
local MAX_NODES    = 400    -- total frames reported, a hard stop
local MAX_FIELDS   = 24     -- interesting fields listed per frame
local MAX_FRAMES   = 15000  -- EnumerateFrames guard

-- Field names worth printing when they're found on a frame. Anything else is
-- noise: a frame carries hundreds of fields and almost none of them identify it.
local INTERESTING = {
	itemID = true, itemLink = true, numOwned = true, quantity = true, count = true,
	dyeColorID = true, dyeSlot = true, dyeChannel = true, currentChannel = true,
	channel = true, colorID = true, ID = true, id = true, index = true,
	name = true, dyeName = true, colorName = true, displayName = true,
	isAvailable = true, available = true, owned = true, cost = true,
}

-- The paths Housing.lua needs. Each is checked and reported hit or miss, so the
-- output says which link in the chain broke rather than just "nothing found".
local EXPECTED = {
	"HouseEditorFrame",
	"HouseEditorFrame.CustomizeModeFrame",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.currentChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.dyeSlotFramesByChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.DyeCostContainer",
}

-- Globals that might be the 12.1 panel. Blizzard renames these between patches, so
-- the probe tries the known names and then falls back to enumerating every frame.
local CANDIDATE_GLOBALS = {
	"HouseEditorFrame", "HousingDyeFrame", "HouseDyeFrame", "DyeUIFrame",
	"HousingDecorDyeFrame", "HouseCustomizeFrame", "DecorCustomizationsFrame",
}

local out = {}
local function W(fmt, ...)
	local ok, line = pcall(string.format, fmt, ...)
	out[#out + 1] = ok and line or tostring(fmt)
end

--------------------------------------------------------------------------------
-- Safe access helpers
--------------------------------------------------------------------------------

local function Try(fn, ...)
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
	return nil
end

-- Read `root.a.b.c` without ever erroring on a nil or a protected link.
local function Resolve(path)
	local node = _G
	for part in path:gmatch("[^%.]+") do
		local ok, nxt = pcall(function() return node[part] end)
		if not ok or nxt == nil then return nil, part end
		node = nxt
	end
	return node
end

local function TypeOf(frame)
	local t = Try(function() return frame:GetObjectType() end)
	return t or type(frame)
end

local function NameOf(frame)
	local n = Try(function() return frame:GetName() end)
	return n or "<anon>"
end

-- Item ID out of anything that might carry one: a number, a link, an info table.
local function ItemIDFrom(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value:match("item:(%d+)")) end
	if type(value) == "table" then
		for _, field in ipairs({ "itemID", "itemId", "ID" }) do
			local ok, v = pcall(function() return value[field] end)
			if ok and type(v) == "number" then return v end
		end
		local ok, link = pcall(function() return value.itemLink or value.link or value.hyperlink end)
		if ok and type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Section: items — find the nine Housing Dyes and their IDs
--
-- The most useful thing in this file and the least clever. Every container the
-- character can read, every mail attachment, and the dye panel's own cost line, and
-- report anything whose name looks like a housing dye. No frame paths involved, so
-- it keeps working however Blizzard rearranges the UI.
--------------------------------------------------------------------------------

local function LooksLikeDye(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	return lower:find("housing dye", 1, true) ~= nil
		or (lower:find("dye", 1, true) ~= nil and lower:find("pigment", 1, true) == nil)
end

local function NameForID(itemID)
	local name = Try(C_Item.GetItemInfo, itemID)
	return name
end

local function ProbeItems()
	W("== items ==")
	W("Every '<Color> Housing Dye' this character can see, with its item ID.")
	W("Paste these into Data.lua's ns.DYES. Anything missing just means you don't")
	W("hold one yet -- collect Hestia's mail, or check a character who does.")
	W("")

	local found, order = {}, {}
	local function Record(itemID, source)
		if not itemID or found[itemID] then return end
		local name = NameForID(itemID)
		if not LooksLikeDye(name) then return end
		found[itemID] = { name = name, source = source }
		order[#order + 1] = itemID
	end

	-- Bags, bank, Warband bank — whatever is readable right now.
	if type(C_Container) == "table" and Enum and Enum.BagIndex then
		for _, bag in pairs(Enum.BagIndex) do
			if type(bag) == "number" then
				local slots = Try(C_Container.GetContainerNumSlots, bag) or 0
				for slot = 1, slots do
					local info = Try(C_Container.GetContainerItemInfo, bag, slot)
					if info then Record(ItemIDFrom(info), "bag " .. bag) end
				end
			end
		end
	end

	-- The mail, because that is literally where Blizzard is putting them. Guarded
	-- hard: these are old globals and a client that has renamed them must not take
	-- the rest of the probe down.
	if type(_G.GetInboxNumItems) == "function" then
		local n = Try(_G.GetInboxNumItems) or 0
		for i = 1, math.min(n, 50) do
			for att = 1, 12 do
				local link = Try(_G.GetInboxItemLink, i, att)
				if link then Record(ItemIDFrom(link), "mail " .. i) end
			end
		end
	end

	if #order == 0 then
		W("nothing found. Open your bags or your mail and run it again.")
	else
		table.sort(order, function(a, b)
			return (found[a].name or "") < (found[b].name or "")
		end)
		for _, itemID in ipairs(order) do
			W('  { name = "%s", id = %d },   -- seen in %s', found[itemID].name, itemID, found[itemID].source)
		end
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: panel — what the dye panel actually looks like now
--------------------------------------------------------------------------------

-- The fields on `frame` worth naming, as a short "k=v" list.
local function DescribeFields(frame)
	local bits, n = {}, 0
	local ok = pcall(function()
		for k, v in pairs(frame) do
			if n >= MAX_FIELDS then return end
			local tv = type(v)
			if INTERESTING[k] and (tv == "number" or tv == "string" or tv == "boolean") then
				n = n + 1
				bits[#bits + 1] = ("%s=%s"):format(k, tostring(v))
			elseif tv == "table" and (k:lower():find("dye") or k:lower():find("swatch")
				or k:lower():find("color") or k:lower():find("cost")) then
				n = n + 1
				bits[#bits + 1] = k .. "={table}"
			end
		end
	end)
	if not ok then return "<fields unreadable>" end
	return #bits > 0 and table.concat(bits, " ") or ""
end

local nodes = 0

local function Walk(frame, depth, label)
	if nodes >= MAX_NODES or depth > MAX_DEPTH then return end
	nodes = nodes + 1

	local shown = Try(function() return frame:IsShown() end)
	local w = Try(function() return math.floor(frame:GetWidth() or 0) end) or 0
	local h = Try(function() return math.floor(frame:GetHeight() or 0) end) or 0
	local fields = DescribeFields(frame)

	W("%s%s  [%s]  %s %dx%d  %s",
		("  "):rep(depth), label, TypeOf(frame), NameOf(frame),
		w, h, (shown and "" or "(hidden) ") .. fields)

	-- Named child tables first (this is where Blizzard puts the interesting ones),
	-- then anonymous children by index.
	local named = {}
	pcall(function()
		for k, v in pairs(frame) do
			if type(k) == "string" and type(v) == "table" and Try(function() return v.GetObjectType end) then
				named[#named + 1] = k
			end
		end
	end)
	table.sort(named)
	for _, k in ipairs(named) do
		local child = Try(function() return frame[k] end)
		if child then Walk(child, depth + 1, "." .. k) end
	end

	local kids = { Try(function() return frame:GetChildren() end) }
	for i, child in ipairs(kids) do
		if i > 12 then break end
		if child then Walk(child, depth + 1, ("child[%d]"):format(i)) end
	end
end

-- Any visible frame whose name mentions dye or housing — the net for a panel that
-- has been renamed out from under the candidate list.
local function FindByName()
	local hits = {}
	if type(_G.EnumerateFrames) ~= "function" then return hits end
	local frame, guard = _G.EnumerateFrames(), 0
	while frame and guard < MAX_FRAMES do
		guard = guard + 1
		local name = Try(function() return frame:GetName() end)
		if type(name) == "string" then
			local lower = name:lower()
			if lower:find("dye") or lower:find("housing") or lower:find("houseeditor") then
				hits[#hits + 1] = { name = name, shown = Try(function() return frame:IsShown() end) }
			end
		end
		frame = _G.EnumerateFrames(frame)
	end
	return hits
end

local function ProbePanel()
	W("== panel ==")
	W("Open a decor's dye panel first, then run this.")
	W("")

	W("-- paths Housing.lua depends on --")
	for _, path in ipairs(EXPECTED) do
		local value, missing = Resolve(path)
		if value ~= nil then
			W("  OK    %s  (%s)", path, type(value) == "table" and TypeOf(value) or type(value))
		else
			W("  GONE  %s  (stops at '%s')", path, tostring(missing))
		end
	end
	W("")

	W("-- frames named for dye or housing --")
	local hits = FindByName()
	if #hits == 0 then
		W("  none")
	else
		for i, hit in ipairs(hits) do
			if i > 40 then W("  ...and %d more", #hits - 40); break end
			W("  %s%s", hit.name, hit.shown and "" or "  (hidden)")
		end
	end
	W("")

	W("-- frame tree --")
	local root
	for _, name in ipairs(CANDIDATE_GLOBALS) do
		local value = Resolve(name)
		if value then root = root or value; W("  root candidate: %s = present", name) end
	end
	W("")
	if root then
		nodes = 0
		Walk(root, 0, "root")
	else
		W("  no root frame found. Is the house editor open?")
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: swatches — the shade list, and which dye each shade costs
--
-- If the grid carries an item ID per swatch, this answers the question Data.lua
-- currently guesses at: which family does Petal Pink belong to? Read, don't infer.
--------------------------------------------------------------------------------

local function ProbeSwatches()
	W("== swatches ==")
	W("Open a decor's dye panel with the color grid showing, then run this.")
	W("")

	-- Anything that looks like a swatch pool or grid, wherever it lives.
	local seen, rows = {}, {}
	local function Collect(frame, depth)
		if depth > MAX_DEPTH or #rows >= 200 then return end
		pcall(function()
			for k, v in pairs(frame) do
				if type(v) == "table" and not seen[v] then
					seen[v] = true
					local key = type(k) == "string" and k:lower() or ""
					local info = (key:find("dyecolor") or key:find("swatch") or key:find("colorinfo"))
						and v or nil
					if info then
						local itemID = ItemIDFrom(info)
						local nm = Try(function() return info.name or info.colorName end)
						local cid = Try(function() return info.ID or info.dyeColorID or info.colorID end)
						if nm or itemID or cid then
							rows[#rows + 1] = ("  %-28s dyeColorID=%-6s itemID=%-8s (%s)")
								:format(tostring(nm), tostring(cid), tostring(itemID),
									itemID and (NameForID(itemID) or "?") or "no item")
						end
					end
					if Try(function() return v.GetObjectType end) or type(k) == "string" then
						Collect(v, depth + 1)
					end
				end
			end
		end)
	end

	local root
	for _, name in ipairs(CANDIDATE_GLOBALS) do
		root = root or Resolve(name)
	end
	if not root then
		W("  no root frame found. Is the house editor open?")
	else
		Collect(root, 0)
		if #rows == 0 then
			W("  no swatch data found. If the grid is on screen, the fields are named")
			W("  something the probe doesn't recognise -- send the 'panel' output instead.")
		else
			table.sort(rows)
			for _, row in ipairs(rows) do W("%s", row) end
		end
	end
	W("")
end

--------------------------------------------------------------------------------
-- Output window — a plain selectable editbox, because chat can't be copied out of
--------------------------------------------------------------------------------

local window

local function ShowOutput(text)
	if not window then
		window = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		window:SetSize(720, 500)
		window:SetPoint("CENTER")
		window:SetFrameStrata("DIALOG")
		window:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		window:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
		window:SetMovable(true)
		window:EnableMouse(true)
		window:RegisterForDrag("LeftButton")
		window:SetScript("OnDragStart", window.StartMoving)
		window:SetScript("OnDragStop", window.StopMovingOrSizing)

		local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", 14, -12)
		title:SetText("Dye probe — Ctrl+A, Ctrl+C")

		local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 0, -4)

		local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -34)
		scroll:SetPoint("BOTTOMRIGHT", -32, 12)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("GameFontHighlightSmall")
		edit:SetWidth(660)
		edit:SetScript("OnEscapePressed", function() window:Hide() end)
		scroll:SetScrollChild(edit)
		window.edit = edit
	end

	window.edit:SetText(text)
	window.edit:HighlightText()
	window:Show()
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

function ns.RunProbe(section)
	out = {}
	section = (section or ""):lower():gsub("%s", "")

	W("Dyeing Down The House — probe")
	W("client build: %s", tostring(Try(GetBuildInfo)))
	W("")

	local ran = false
	if section == "" or section == "items" then ProbeItems(); ran = true end
	if section == "" or section == "panel" then ProbePanel(); ran = true end
	if section == "" or section == "swatches" then ProbeSwatches(); ran = true end
	if not ran then
		W("unknown section '%s'. Try: items, panel, swatches, or nothing for all.", section)
	end

	ShowOutput(table.concat(out, "\n"))
	if ns.Print then ns.Print("probe done — the window has the output, Ctrl+A then Ctrl+C.") end
end
