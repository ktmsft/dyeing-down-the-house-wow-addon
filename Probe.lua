-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Probe.lua — read the game's own shape instead of guessing at it.
--
-- 12.1 rebuilt the house dye panel. The frame paths Housing.lua was verified
-- against in July resolve to nothing now, which is why the "Dye Needed" box
-- stopped appearing, and the nine new dye items have IDs that aren't published
-- anywhere. Both are questions only the client can answer, so this asks it.
--
-- THE FIRST VERSION OF THIS FILE SEARCHED BY NAME AND FOUND NOTHING. That result
-- was the useful one: `HouseEditorFrame` is not a global any more, and neither is
-- anything else that looks like a dye panel, while `HousingControlsFrame` and
-- `HousingTopBannerFrame` are. A frame with no global name is invisible to a name
-- search, so this now looks for the panel by SHAPE — any frame carrying the fields
-- a dye panel has to carry — and then works out how to reach it by walking up to
-- the nearest named ancestor. Names are a convenience Blizzard can withdraw;
-- fields are what the code actually needs.
--
-- `/dye probe` runs every section. `/dye probe <section>` runs one:
--
--   items    every dye the account can see, with its item ID. This is the one that
--            matters — it's how Data.lua's nil IDs get filled in. It reads bags,
--            bank, mail AND anything the dye panel itself is holding, because the
--            panel knows the item even when you own none of it.
--   addons   which housing addons are loaded, and which exist but haven't loaded.
--            The panel is almost certainly load-on-demand; this says what to open.
--   panel    finds the dye panel by shape and prints how to reach it, plus a
--            verdict on each path Housing.lua depends on.
--   swatches the color swatch grid: every shade the panel offers and, where the
--            grid carries one, the dye item it costs. That's the shade -> family
--            map, read from the game rather than inferred from the color's name.
--
-- OPEN A DECOR'S DYE PANEL BEFORE RUNNING panel OR swatches. A load-on-demand
-- frame that hasn't loaded doesn't exist to be found, and the probe cannot tell
-- that apart from "Blizzard deleted it" — so it says which it thinks it is.
--
-- Rules this file lives by, because it pokes at internals that are not ours:
--   * It reads. It never writes a field, never calls a setter, never touches
--     anything protected. A probe that changed state would be a taint bug wearing
--     a diagnostic's hat.
--   * Forbidden frames are skipped outright, and every access is pcall-wrapped.
--   * Every traversal is depth- and count-bounded. This walks frames that may not
--     exist, in a patch that is still moving; it has to be impossible for it to
--     error or to hang.
--   * It prints what it FOUND and what it LOOKED FOR AND MISSED. A probe that only
--     reports hits can't tell "the field moved" from "the field is empty".
--------------------------------------------------------------------------------

local MAX_DEPTH   = 8      -- frame-tree levels to descend
local MAX_NODES   = 300    -- frames printed in a tree, a hard stop
local MAX_FIELDS  = 24     -- interesting fields listed per frame
local MAX_FRAMES  = 20000  -- EnumerateFrames guard
local MAX_HITS    = 12     -- candidate panels reported

-- Field names worth printing when they're found on a frame. Anything else is
-- noise: a frame carries hundreds of fields and almost none of them identify it.
local INTERESTING = {
	itemID = true, itemLink = true, numOwned = true, quantity = true, count = true,
	dyeColorID = true, dyeSlot = true, dyeChannel = true, currentChannel = true,
	channel = true, colorID = true, ID = true, id = true, index = true,
	name = true, dyeName = true, colorName = true, displayName = true,
	isAvailable = true, available = true, owned = true, cost = true,
}

-- What makes a frame look like part of the dye UI. Substrings, lowercased, matched
-- against the frame's own field NAMES — which is the part Blizzard is least likely
-- to change, because their own code reads them.
local SHAPE_WORDS = {
	"dyecolor", "dyeslot", "dyecost", "dyechannel", "swatch", "colorinfo",
	"dyeid", "dyename",
}

-- Weaker signals: worth a point, but not on their own. "cost" and "color" appear
-- all over the UI, so a frame needs several before it's interesting.
local WEAK_WORDS = { "dye", "colorpicker", "colorgrid", "hideunavailable" }

-- The paths Housing.lua depends on. Each is checked and reported hit or miss, so
-- the output says which link in the chain broke rather than just "nothing found".
local EXPECTED = {
	"HouseEditorFrame",
	"HouseEditorFrame.CustomizeModeFrame",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.currentChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.dyeSlotFramesByChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.DyeCostContainer",
}

-- Globals still worth trying by name first: it costs nothing, and if one of them
-- ever comes back the answer is immediate. HousingControlsFrame and
-- HousingTopBannerFrame are here because the probe confirmed they exist on 12.1.
local CANDIDATE_GLOBALS = {
	"HouseEditorFrame", "HousingControlsFrame", "HousingTopBannerFrame",
	"HousingDyeFrame", "HouseDyeFrame", "DyeUIFrame",
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

local function Get(tbl, key)
	local ok, value = pcall(function() return tbl[key] end)
	if ok then return value end
	return nil
end

-- Touching a forbidden frame raises. Skip them entirely rather than pcall-ing our
-- way through hundreds of failures.
local function Forbidden(frame)
	local ok, forbidden = pcall(function()
		return frame.IsForbidden and frame:IsForbidden()
	end)
	return (not ok) or forbidden == true
end

-- Read `root.a.b.c` without ever erroring on a nil or a protected link.
local function Resolve(path)
	local node = _G
	for part in path:gmatch("[^%.]+") do
		local nxt = Get(node, part)
		if nxt == nil then return nil, part end
		node = nxt
	end
	return node
end

local function IsFrame(value)
	return type(value) == "table" and Get(value, "GetObjectType") ~= nil
end

local function TypeOf(frame)
	return Try(function() return frame:GetObjectType() end) or type(frame)
end

local function NameOf(frame)
	return Try(function() return frame:GetName() end)
end

-- Item ID out of anything that might carry one: a number, a link, an info table.
local function ItemIDFrom(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value:match("item:(%d+)")) end
	if type(value) == "table" then
		for _, field in ipairs({ "itemID", "itemId", "ID" }) do
			local v = Get(value, field)
			if type(v) == "number" then return v end
		end
		local link = Get(value, "itemLink") or Get(value, "link") or Get(value, "hyperlink")
		if type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
	end
	return nil
end

local function NameForID(itemID)
	return Try(C_Item.GetItemInfo, itemID)
end

--------------------------------------------------------------------------------
-- How do I reach this frame?
--
-- An anonymous frame is only useful if there's a route to it, so walk up parents
-- until something has a global name, recording the field each child is stored
-- under. That turns an unnamed frame into "HousingControlsFrame.DyePanel.Grid",
-- which is a line Housing.lua can actually use.
--------------------------------------------------------------------------------

-- The field name `child` is stored under on `parent`, if any.
local function FieldNameOn(parent, child)
	local found
	pcall(function()
		for k, v in pairs(parent) do
			if v == child and type(k) == "string" then found = k; return end
		end
	end)
	return found
end

local function PathTo(frame)
	local parts, node, guard = {}, frame, 0
	while node and guard < MAX_DEPTH + 4 do
		guard = guard + 1
		local name = NameOf(node)
		if name then
			table.insert(parts, 1, name)
			return table.concat(parts, "."), true
		end
		local parent = Try(function() return node:GetParent() end)
		if not parent then
			table.insert(parts, 1, "<no named ancestor>")
			return table.concat(parts, "."), false
		end
		local field = FieldNameOn(parent, node)
		table.insert(parts, 1, field or ("<anonymous " .. TypeOf(node) .. ">"))
		node = parent
	end
	return table.concat(parts, "."), false
end

--------------------------------------------------------------------------------
-- Shape scoring
--------------------------------------------------------------------------------

-- How dye-panel-ish is this frame? Returns a score and the field names that earned
-- it, so the report can show its working rather than just a number.
local function ScoreFrame(frame)
	local score, why = 0, {}
	local ok = pcall(function()
		local n = 0
		for k in pairs(frame) do
			n = n + 1
			if n > 400 then return end
			if type(k) == "string" then
				local lower = k:lower()
				for _, word in ipairs(SHAPE_WORDS) do
					if lower:find(word, 1, true) then
						score = score + 3
						if #why < 8 then why[#why + 1] = k end
						break
					end
				end
				for _, word in ipairs(WEAK_WORDS) do
					if lower:find(word, 1, true) then
						score = score + 1
						if #why < 8 then why[#why + 1] = k end
						break
					end
				end
			end
		end
	end)
	if not ok then return 0, {} end
	return score, why
end

-- Every frame in the client, scored. Anonymous ones included — that's the point.
local function FindByShape()
	local hits = {}
	if type(_G.EnumerateFrames) ~= "function" then return hits end
	local frame, guard = _G.EnumerateFrames(), 0
	while frame and guard < MAX_FRAMES do
		guard = guard + 1
		if not Forbidden(frame) then
			local score, why = ScoreFrame(frame)
			if score >= 3 then
				hits[#hits + 1] = {
					frame = frame,
					score = score,
					why = why,
					shown = Try(function() return frame:IsShown() end),
				}
			end
		end
		frame = _G.EnumerateFrames(frame)
	end
	table.sort(hits, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return (a.shown and 1 or 0) > (b.shown and 1 or 0)
	end)
	return hits, guard
end

--------------------------------------------------------------------------------
-- Section: addons — what's loaded, and what's waiting to be
--------------------------------------------------------------------------------

local function ProbeAddons()
	W("== addons ==")
	W("The dye panel is almost certainly load-on-demand. If it shows as NOT LOADED")
	W("here, open a decor's dye panel and run the probe again -- a frame that hasn't")
	W("been created yet cannot be found by any means.")
	W("")

	local api = C_AddOns
	if not (api and api.GetNumAddOns and api.GetAddOnInfo) then
		W("  C_AddOns is unavailable on this client.")
		W("")
		return
	end

	local n = Try(api.GetNumAddOns) or 0
	local any = false
	for i = 1, n do
		local name = Try(api.GetAddOnInfo, i)
		if type(name) == "string" then
			local lower = name:lower()
			if lower:find("hous", 1, true) or lower:find("dye", 1, true)
				or lower:find("decor", 1, true) then
				local loaded = api.IsAddOnLoaded and Try(api.IsAddOnLoaded, name)
				W("  %-44s %s", name, loaded and "loaded" or "NOT LOADED")
				any = true
			end
		end
	end
	if not any then W("  nothing matching housing, dye or decor.") end
	W("")
end

--------------------------------------------------------------------------------
-- Section: panel — find it by shape, then say how to reach it
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
			elseif tv == "table" and type(k) == "string" then
				local lower = k:lower()
				if lower:find("dye") or lower:find("swatch") or lower:find("color")
					or lower:find("cost") then
					n = n + 1
					bits[#bits + 1] = k .. "={table}"
				end
			end
		end
	end)
	if not ok then return "<fields unreadable>" end
	return #bits > 0 and table.concat(bits, " ") or ""
end

local nodes = 0

local function Walk(frame, depth, label)
	if nodes >= MAX_NODES or depth > MAX_DEPTH then return end
	if Forbidden(frame) then return end
	nodes = nodes + 1

	local shown = Try(function() return frame:IsShown() end)
	local w = Try(function() return math.floor(frame:GetWidth() or 0) end) or 0
	local h = Try(function() return math.floor(frame:GetHeight() or 0) end) or 0

	W("%s%s  [%s]  %s %dx%d  %s",
		("  "):rep(depth), label, TypeOf(frame), NameOf(frame) or "<anon>",
		w, h, (shown and "" or "(hidden) ") .. DescribeFields(frame))

	-- Named child tables first (this is where Blizzard puts the interesting ones),
	-- then anonymous children by index.
	local named = {}
	pcall(function()
		for k, v in pairs(frame) do
			if type(k) == "string" and IsFrame(v) then named[#named + 1] = k end
		end
	end)
	table.sort(named)
	for _, k in ipairs(named) do
		local child = Get(frame, k)
		if child then Walk(child, depth + 1, "." .. k) end
	end

	local kids = { Try(function() return frame:GetChildren() end) }
	for i, child in ipairs(kids) do
		if i > 12 then break end
		if child then Walk(child, depth + 1, ("child[%d]"):format(i)) end
	end
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

	W("-- named globals that DO exist --")
	local anyGlobal = false
	for _, name in ipairs(CANDIDATE_GLOBALS) do
		if Resolve(name) then W("  %s", name); anyGlobal = true end
	end
	if not anyGlobal then W("  none of the candidates") end
	W("")

	W("-- frames that LOOK like a dye panel (scored by their fields) --")
	W("   Anonymous frames included: the 12.1 panel has no global name, which is why")
	W("   searching by name found nothing at all.")
	W("")
	local hits, scanned = FindByShape()
	W("   (scanned %d frames)", scanned or 0)
	if #hits == 0 then
		W("   NOTHING FOUND.")
		W("   If the dye panel was open on screen when you ran this, that's a real")
		W("   result and worth telling me. If it wasn't, open it and run again.")
	else
		for i, hit in ipairs(hits) do
			if i > MAX_HITS then W("   ...and %d more", #hits - MAX_HITS); break end
			local path, named = PathTo(hit.frame)
			W("  [%d] %s%s", hit.score, path, named and "" or "   (no named ancestor)")
			W("      %s%s", hit.shown and "shown" or "hidden",
				#hit.why > 0 and ("  fields: " .. table.concat(hit.why, ", ")) or "")
		end
	end
	W("")

	W("-- frame tree under the best candidate --")
	local best = hits[1] and hits[1].frame
	if not best then
		for _, name in ipairs(CANDIDATE_GLOBALS) do
			best = best or Resolve(name)
		end
	end
	if best then
		nodes = 0
		Walk(best, 0, "root")
	else
		W("  nothing to walk.")
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: swatches — the shade list, and which dye each shade costs
--
-- If the grid carries an item ID per swatch, this answers the question Data.lua
-- currently guesses at: which family does Petal Pink belong to? Read, don't infer.
--------------------------------------------------------------------------------

-- Every dye-ish info table reachable from `root`, as { name, colorID, itemID }.
local function CollectColorInfo(root, rows, seen, depth)
	if depth > MAX_DEPTH or #rows >= 300 then return end
	pcall(function()
		for k, v in pairs(root) do
			if type(v) == "table" and not seen[v] then
				seen[v] = true
				local key = type(k) == "string" and k:lower() or ""
				local looksInfo = key:find("dyecolor") or key:find("swatch")
					or key:find("colorinfo") or key:find("dyeinfo")
				if looksInfo or Get(v, "dyeColorID") ~= nil then
					local nm = Get(v, "name") or Get(v, "colorName") or Get(v, "dyeName")
					local cid = Get(v, "dyeColorID") or Get(v, "ID") or Get(v, "colorID")
					local itemID = ItemIDFrom(v)
					if nm or itemID or cid then
						rows[#rows + 1] = {
							name = tostring(nm), colorID = tostring(cid), itemID = itemID,
						}
					end
				end
				if not Forbidden(v) then
					CollectColorInfo(v, rows, seen, depth + 1)
				end
			end
		end
	end)
end

-- Shared with the items section: everything the UI can tell us about dye items.
local function SwatchRows()
	local rows, seen = {}, {}
	local hits = FindByShape()
	for i, hit in ipairs(hits) do
		if i > 4 then break end
		CollectColorInfo(hit.frame, rows, seen, 0)
	end
	for _, name in ipairs(CANDIDATE_GLOBALS) do
		local frame = Resolve(name)
		if frame then CollectColorInfo(frame, rows, seen, 0) end
	end
	return rows
end

local function ProbeSwatches()
	W("== swatches ==")
	W("Open a decor's dye panel with the color grid showing, then run this.")
	W("")

	local rows = SwatchRows()
	if #rows == 0 then
		W("  no swatch data found. If the grid was on screen, send the 'panel'")
		W("  output instead -- the field names will be in the tree.")
	else
		table.sort(rows, function(a, b) return a.name < b.name end)
		W("  %-30s %-12s %-10s %s", "shade", "dyeColorID", "itemID", "item name")
		for _, row in ipairs(rows) do
			W("  %-30s %-12s %-10s %s", row.name, row.colorID,
				tostring(row.itemID), row.itemID and (NameForID(row.itemID) or "?") or "")
		end
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: items — find the nine Housing Dyes and their IDs
--
-- Reads containers, the mail, AND the dye panel. The panel matters most: it knows
-- the item a color costs even when you own none of it, so this can answer the
-- question before Hestia's mail has been collected.
--------------------------------------------------------------------------------

local function LooksLikeDye(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	return lower:find("housing dye", 1, true) ~= nil
		or (lower:find("dye", 1, true) ~= nil and lower:find("pigment", 1, true) == nil)
end

local function ProbeItems()
	W("== items ==")
	W("Every dye this character can see, with its item ID. Paste these into")
	W("Data.lua's ns.DYES.")
	W("")

	local found, order = {}, {}
	local function Record(itemID, source)
		if not itemID or found[itemID] then return end
		local name = NameForID(itemID)
		if not LooksLikeDye(name) then return end
		found[itemID] = { name = name, source = source }
		order[#order + 1] = itemID
	end

	-- Bags, bank, Warband bank — whatever is readable right now. The bank containers
	-- report zero slots unless a bank frame is open, so say how much was actually
	-- looked at: "nothing found" and "couldn't look" are very different answers.
	local scanned, withSlots = 0, 0
	if type(C_Container) == "table" and Enum and Enum.BagIndex then
		for _, bag in pairs(Enum.BagIndex) do
			if type(bag) == "number" then
				scanned = scanned + 1
				local slots = Try(C_Container.GetContainerNumSlots, bag) or 0
				if slots > 0 then withSlots = withSlots + 1 end
				for slot = 1, slots do
					local info = Try(C_Container.GetContainerItemInfo, bag, slot)
					if info then Record(ItemIDFrom(info), "bag " .. bag) end
				end
			end
		end
	end
	W("  containers: %d checked, %d had readable slots", scanned, withSlots)
	W("  (bank and Warband tabs read as empty unless a bank frame is open)")

	-- The mail, because that is literally where Blizzard is putting them.
	local mailCount = 0
	if type(_G.GetInboxNumItems) == "function" then
		mailCount = Try(_G.GetInboxNumItems) or 0
		for i = 1, math.min(mailCount, 50) do
			for att = 1, 12 do
				local link = Try(_G.GetInboxItemLink, i, att)
				if link then Record(ItemIDFrom(link), "mail " .. i) end
			end
		end
	end
	W("  mail: %d messages readable (0 away from a mailbox)", mailCount)

	-- The dye panel itself. This is the one that works when you own nothing.
	local fromUI = 0
	for _, row in ipairs(SwatchRows()) do
		if row.itemID then
			local before = order[#order]
			Record(row.itemID, "dye panel (" .. row.name .. ")")
			if order[#order] ~= before then fromUI = fromUI + 1 end
		end
	end
	W("  dye panel: %d dye items read off the swatches", fromUI)
	W("")

	if #order == 0 then
		W("  NOTHING FOUND.")
		W("")
		W("  In order of what's most likely to work:")
		W("   1. Open a decor's dye panel and run `/dye probe items` again. The panel")
		W("      knows the item even when you hold none.")
		W("   2. Stand at a mailbox with Hestia's mail uncollected.")
		W("   3. Open your bank so the bank and Warband tabs become readable.")
	else
		table.sort(order, function(a, b)
			return (found[a].name or "") < (found[b].name or "")
		end)
		for _, itemID in ipairs(order) do
			W('  { name = "%s", id = %d },   -- seen in %s',
				found[itemID].name, itemID, found[itemID].source)
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
		window:SetSize(760, 520)
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
		title:SetText("Dye probe — click the text, Ctrl+A, Ctrl+C")

		local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 0, -4)

		local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -34)
		scroll:SetPoint("BOTTOMRIGHT", -32, 12)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("GameFontHighlightSmall")
		edit:SetWidth(700)
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
	if section == "" or section == "addons"   then ProbeAddons();   ran = true end
	if section == "" or section == "items"    then ProbeItems();    ran = true end
	if section == "" or section == "panel"    then ProbePanel();    ran = true end
	if section == "" or section == "swatches" then ProbeSwatches(); ran = true end
	if not ran then
		W("unknown section '%s'. Try: addons, items, panel, swatches, or nothing for all.", section)
	end

	ShowOutput(table.concat(out, "\n"))
	if ns.Print then ns.Print("probe done — the window has the output, Ctrl+A then Ctrl+C.") end
end
