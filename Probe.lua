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
--   deep     the dye tables dumped in FULL, every key. The scored search finds the
--            frames; this reads what's inside them. Use it when a section above
--            says it found the frame but not the field -- a filtered dump can only
--            show you the names you already guessed.
--   station  the Dye Station's crafting window: the paths Crafting.lua hooks, the
--            shape of a recipe row, and the schematic panel. Open the station
--            first.
--   api      the Enums and C_ namespaces behind the dye system. THIS IS THE ONE TO
--            REACH FOR FIRST. Frame-scraping was only ever a way in because I
--            didn't know a dyeColorCategoryID existed; now that categories are
--            known to be a game concept, the API that serves them beats reading
--            somebody's layout on every axis, and it needs no window open.
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
-- The pre-12.1 chain is kept in full, because "the pane is fine and its contents
-- are gone" is a much more useful report than "not found" -- that is exactly what
-- 12.1 did, and it's what made this read as an addon bug rather than a moved frame.
local EXPECTED = {
	"HouseEditorFrame",
	"HouseEditorFrame.CustomizeModeFrame",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.currentChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.dyeSlotFramesByChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.DyeCostContainer",
	-- where 12.1 actually put them
	"HouseEditorFrame.activeModeFrame",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane.DyeCostContainer",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane.dyeSlotFramesByChannel",
	"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane.DyeSlotContainer",
	"DyeSelectionPopout",
	"DyeSelectionPopout.DyeSlotScrollBox",
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
--
-- `ID` is deliberately NOT read as an item ID. The first run of this reported
-- itemID=1273 and 1274 off the swatch tables, and GetItemInfo had nothing for
-- either — they're dye colour record IDs, and a plain `ID` field means whatever the
-- table it sits on decides it means. Guessing it was an item ID would have put two
-- fabricated IDs into Data.lua, which is the precise failure this whole file exists
-- to prevent.
local function ItemIDFrom(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value:match("item:(%d+)")) end
	if type(value) == "table" then
		for _, field in ipairs({ "itemID", "itemId", "dyeItemID" }) do
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

-- An item ID is only reportable once the client agrees it names an item. Anything
-- else is a number that happened to be lying nearby. Declared after NameForID
-- rather than beside ItemIDFrom, because a local called above its declaration
-- silently compiles to a global lookup (see tools/check_order.lua).
local function ConfirmedItem(itemID)
	if not itemID then return nil end
	local name = NameForID(itemID)
	if type(name) == "string" and name ~= "" then return name end
	return nil
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
		W("  no swatch data found. If the grid was on screen, send the 'deep'")
		W("  output instead -- it dumps the tables in full, field names and all.")
	else
		table.sort(rows, function(a, b) return a.name < b.name end)
		W("  %-30s %-12s %-10s %s", "shade", "dyeColorID", "itemID", "item name")
		for _, row in ipairs(rows) do
			local confirmed = ConfirmedItem(row.itemID)
			W("  %-30s %-12s %-10s %s", row.name, row.colorID,
				confirmed and tostring(row.itemID) or "-",
				confirmed or (row.itemID and "(not an item: " .. row.itemID .. ")" or ""))
		end
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: deep — dump the dye tables in full, field names and all
--
-- The scored search finds the frames; this reads what's actually inside them. It
-- prints EVERY key rather than a filtered selection, because the whole problem is
-- not knowing what the fields are called any more — a filter can only show you the
-- names you already guessed.
--------------------------------------------------------------------------------

local MAX_KEYS = 60

local function DumpValue(label, value, indent, depth)
	local pad = ("  "):rep(indent)
	local tv = type(value)

	if tv ~= "table" then
		W("%s%s = %s", pad, label, tostring(value))
		return
	end
	if IsFrame(value) then
		W("%s%s = <%s %s>", pad, label, TypeOf(value), NameOf(value) or "anon")
		return
	end
	if depth <= 0 then
		W("%s%s = {...}", pad, label)
		return
	end

	local keys = {}
	pcall(function()
		for k in pairs(value) do keys[#keys + 1] = k end
	end)
	if #keys == 0 then
		W("%s%s = {}", pad, label)
		return
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	W("%s%s = {", pad, label)
	for i, k in ipairs(keys) do
		if i > MAX_KEYS then W("%s  ...and %d more", pad, #keys - MAX_KEYS); break end
		local v = Get(value, k)
		if type(v) ~= "function" then
			DumpValue(tostring(k), v, indent + 1, depth - 1)
		end
	end
	W("%s}", pad)
end

-- The DyePane, found the same way Housing.lua finds it.
local function FindDyePane()
	local paths = {
		"HouseEditorFrame.activeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane",
		"HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.CustomizeComponentContainer.DyePane",
	}
	for _, path in ipairs(paths) do
		local pane = Resolve(path)
		if pane then return pane, path end
	end
	return nil
end

local function ProbeDeep()
	W("== deep ==")
	W("Full contents of the dye tables. Open a decor's dye panel, pick a color in")
	W("slot 1, THEN run this -- an unpainted slot has nothing in it to read.")
	W("")

	local pane, path = FindDyePane()
	if not pane then
		W("  DyePane not found. Run `/dye probe panel` first.")
		W("")
		return
	end
	W("  found at %s", path)
	W("")

	W("-- dye slots --")
	local slots, seen = {}, {}
	local byChannel = Get(pane, "dyeSlotFramesByChannel")
	if type(byChannel) == "table" then
		pcall(function()
			for k, slot in pairs(byChannel) do
				if not seen[slot] then seen[slot] = true; slots[#slots + 1] = { key = k, frame = slot } end
			end
		end)
	end
	local container = Get(pane, "DyeSlotContainer")
	if container then
		for i, child in ipairs({ Try(function() return container:GetChildren() end) }) do
			if child and not seen[child] then
				seen[child] = true
				slots[#slots + 1] = { key = "child[" .. i .. "]", frame = child }
			end
		end
	end

	if #slots == 0 then
		W("  none found")
	end
	for _, entry in ipairs(slots) do
		W("  slot %s:", tostring(entry.key))
		DumpValue("dyeSlotInfo", Get(entry.frame, "dyeSlotInfo"), 2, 3)
		local swatch = Get(entry.frame, "CurrentSwatch") or Get(entry.frame, "Swatch")
		if swatch then
			for _, field in ipairs({ "dyeColorInfo", "colorInfo", "dyeSlotInfo", "dyeColorID" }) do
				local v = Get(swatch, field)
				if v ~= nil then DumpValue("CurrentSwatch." .. field, v, 2, 3) end
			end
			-- Anything else on the swatch that isn't a frame or a function.
			local extras = {}
			pcall(function()
				for k, v in pairs(swatch) do
					if type(k) == "string" and type(v) ~= "function" and not IsFrame(v) then
						extras[#extras + 1] = k
					end
				end
			end)
			table.sort(extras)
			W("    CurrentSwatch other fields: %s",
				#extras > 0 and table.concat(extras, ", ") or "(none)")
		end
	end
	W("")

	W("-- GetPreviewDyeInfos() --")
	if type(Get(pane, "GetPreviewDyeInfos")) == "function" then
		local infos = Try(function() return pane:GetPreviewDyeInfos() end)
		if infos == nil then
			W("  returned nil (nothing previewed yet?)")
		else
			DumpValue("infos", infos, 1, 4)
		end
	else
		W("  not present")
	end
	W("")

	W("-- dyeCostIcons --")
	DumpValue("dyeCostIcons", Get(pane, "dyeCostIcons"), 1, 3)
	W("")

	W("-- DyeSelectionPopout (the swatch grid) --")
	local popout = Resolve("DyeSelectionPopout")
	if not popout then
		W("  not found. It's a global, so it should be there once the grid has opened")
		W("  at least once this session -- click a dye slot, then run this again.")
	else
		W("  shown: %s", tostring(Try(function() return popout:IsShown() end)))
		local scroll = Get(popout, "DyeSlotScrollBox")
		if not scroll then
			W("  DyeSlotScrollBox missing")
		else
			-- The data provider holds every shade, not just the visible ones.
			local provider = Try(function() return scroll:GetDataProvider() end)
			local size = provider and Try(function() return provider:GetSize() end)
			W("  data provider size: %s", tostring(size))
			if provider and type(size) == "number" then
				for i = 1, math.min(size, 8) do
					local element = Try(function() return provider:Find(i) end)
					DumpValue("element[" .. i .. "]", element, 2, 3)
				end
				if size > 8 then W("    ...%d more elements", size - 8) end
			end
			-- Failing that, the visible buttons carry their own element data.
			local frames = Try(function() return scroll:GetFrames() end)
			if type(frames) == "table" and #frames > 0 then
				W("  visible swatch buttons: %d", #frames)
				for i = 1, math.min(#frames, 4) do
					local ed = Try(function() return frames[i]:GetElementData() end)
					DumpValue("button[" .. i .. "].elementData", ed, 2, 3)
				end
			end
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
-- Section: api — the Enums and C_ namespaces behind the dye system
--
-- This should have been the FIRST section, and the frame-scraping the fallback.
--
-- `dyeSlotInfo` turned out to be all IDs and no names — { ID, channel,
-- dyeColorCategoryID, dyeColorID, orderIndex }. IDs mean records, records mean an
-- API serves them, and an API means none of this has to be scraped off somebody's
-- layout with a window open.
--
-- A note against over-reading `dyeColorCategoryID`: it is NOT known to be one of
-- the nine dye families. On a Rectangular Elven Floor Rug, slot 1 reports category
-- 3 and slot 2 category 1, while the swatch grid offers slot 1 the full rainbow —
-- so it can't be constraining that slot to a colour family. Best guess is a
-- material category (which part of the decor the slot tints). Worth settling here
-- rather than assuming, because assuming it was the family would have wired every
-- goal in the addon to the wrong number.
--
-- Enums are pure data and are dumped whole. Functions are only CALLED when their
-- name begins with Get/Is/Are/Can/Has — Blizzard's own convention for a read — and
-- every call is pcall'd with no arguments first, then with a small integer. A
-- probe that fired setters would be worse than no probe.
--------------------------------------------------------------------------------

local READ_PREFIXES = { "^Get", "^Is", "^Are", "^Can", "^Has" }

local function LooksLikeRead(name)
	for _, pattern in ipairs(READ_PREFIXES) do
		if name:find(pattern) then return true end
	end
	return false
end

local function Relevant(name)
	local lower = name:lower()
	return lower:find("dye", 1, true) or lower:find("hous", 1, true)
		or lower:find("decor", 1, true)
end

local function ProbeApi()
	W("== api ==")
	W("The Enums and C_ namespaces behind the dye system. Needs no window open.")
	W("")

	-- Enums first: pure data, and the likeliest place the nine categories are named.
	W("-- Enum tables mentioning dye, housing or decor --")
	local enums = {}
	pcall(function()
		for name, tbl in pairs(_G.Enum or {}) do
			if type(name) == "string" and type(tbl) == "table" and Relevant(name) then
				enums[#enums + 1] = name
			end
		end
	end)
	table.sort(enums)
	if #enums == 0 then
		W("  none found")
	end
	for _, name in ipairs(enums) do
		DumpValue("Enum." .. name, Get(_G.Enum, name), 1, 2)
	end
	W("")

	-- Constants tables sometimes carry the same thing under another roof.
	W("-- Constants tables mentioning dye or housing --")
	local consts = {}
	pcall(function()
		for name, tbl in pairs(_G.Constants or {}) do
			if type(name) == "string" and type(tbl) == "table" and Relevant(name) then
				consts[#consts + 1] = name
			end
		end
	end)
	table.sort(consts)
	if #consts == 0 then W("  none found") end
	for _, name in ipairs(consts) do
		DumpValue("Constants." .. name, Get(_G.Constants, name), 1, 2)
	end
	W("")

	-- Then the namespaces. Names are listed in full; only reads are called.
	W("-- C_ namespaces mentioning dye, housing or decor --")
	local spaces = {}
	pcall(function()
		for name, tbl in pairs(_G) do
			if type(name) == "string" and name:find("^C_") and type(tbl) == "table"
				and Relevant(name) then
				spaces[#spaces + 1] = name
			end
		end
	end)
	table.sort(spaces)
	if #spaces == 0 then
		W("  none found")
		W("")
		return
	end

	for _, space in ipairs(spaces) do
		local tbl = Get(_G, space)
		local fns = {}
		pcall(function()
			for k, v in pairs(tbl) do
				if type(k) == "string" and type(v) == "function" then fns[#fns + 1] = k end
			end
		end)
		table.sort(fns)
		W("")
		W("  %s  (%d functions)", space, #fns)
		for _, fn in ipairs(fns) do W("    %s", fn) end

		-- Call the readers. No args, then 1, then 2 and 3 — enough to walk a small
		-- category list without hammering anything.
		local called = false
		for _, fn in ipairs(fns) do
			if LooksLikeRead(fn) and Relevant(fn) then
				local target = Get(tbl, fn)
				for _, args in ipairs({ {}, { 1 }, { 2 }, { 3 } }) do
					local ok, result = pcall(target, unpack(args))
					if ok and result ~= nil then
						if not called then W(""); W("    -- read-only calls --"); called = true end
						local label = ("%s(%s)"):format(fn, table.concat(args, ", "))
						DumpValue(label, result, 3, 3)
						break -- first shape that answers is enough
					end
				end
			end
		end
	end
	W("")
end

--------------------------------------------------------------------------------
-- Section: station — the Dye Station's crafting window
--
-- The station opens an ordinary Professions-style window titled "Dye Crafting"
-- with the nine dyes in it. Crafting.lua hooks the shapes it has always hooked, on
-- the reading that this IS the Professions frame; this section is how that reading
-- gets checked rather than assumed, because assuming it is exactly what cost this
-- addon its housing panel earlier in the same release.
--------------------------------------------------------------------------------

local STATION_PATHS = {
	"ProfessionsFrame",
	"ProfessionsFrame.CraftingPage",
	"ProfessionsFrame.CraftingPage.RecipeList",
	"ProfessionsFrame.CraftingPage.RecipeList.ScrollBox",
	"ProfessionsFrame.CraftingPage.SchematicForm",
	"ProfessionsFrame.CraftingPage.SchematicForm.OutputText",
	"ProfessionsFrame.CraftingPage.CreateButton",
	"OpenProfessionsItemFlyout",
}

local function ProbeStation()
	W("== station ==")
	W("Open a Dye Station's crafting window first, then run this.")
	W("")

	W("-- paths Crafting.lua depends on --")
	for _, path in ipairs(STATION_PATHS) do
		local value, missing = Resolve(path)
		if value ~= nil then
			W("  OK    %s  (%s)", path,
				type(value) == "table" and TypeOf(value) or type(value))
		else
			W("  GONE  %s  (stops at '%s')", path, tostring(missing))
		end
	end
	W("")

	W("-- did Crafting.lua manage to attach? --")
	W("  ns.craftingHooked: %s", tostring(ns.craftingHooked))
	W("  (false with the window open means the paths above are wrong; true with")
	W("   nothing on screen means there is simply nothing to mark -- a recipe is")
	W("   only flagged when you have set a GOAL for that colour and hold fewer,")
	W("   and the reagent checks need flower prices, so run a scan first.)")
	W("")

	W("-- is Blizzard_Professions even loaded? --")
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		W("  Blizzard_Professions: %s",
			tostring(Try(C_AddOns.IsAddOnLoaded, "Blizzard_Professions")))
	else
		W("  C_AddOns unavailable")
	end
	W("")

	W("-- recipe rows, and what each one carries --")
	local sb = Resolve("ProfessionsFrame.CraftingPage.RecipeList.ScrollBox")
	if not sb then
		W("  no recipe list found. If the window is open, this is NOT the Professions")
		W("  frame and Crafting.lua is hooking the wrong thing -- send the shape search")
		W("  below.")
	else
		local frames = Try(function() return sb:GetFrames() end)
		if type(frames) ~= "table" or #frames == 0 then
			W("  the list exists but has no rows right now")
		else
			W("  %d rows", #frames)
			for i = 1, math.min(#frames, 4) do
				local ed = Try(function() return frames[i]:GetElementData() end)
				DumpValue(("row[%d].elementData"):format(i), ed, 2, 4)
			end
		end
	end
	W("")

	W("-- the schematic panel --")
	local sf = Resolve("ProfessionsFrame.CraftingPage.SchematicForm")
	if not sf then
		W("  not found")
	else
		local ri = Try(function() return sf:GetRecipeInfo() end)
		DumpValue("GetRecipeInfo()", ri, 1, 3)
		-- Where our have/need line anchors, and where the reagent rows live.
		for _, field in ipairs({ "OutputText", "Reagents", "reagentSlots", "Description" }) do
			local v = Get(sf, field)
			W("  %-14s %s", field, v ~= nil and (IsFrame(v) and TypeOf(v) or type(v)) or "absent")
		end
	end
	W("")

	W("-- anything that LOOKS like a crafting window, by shape --")
	-- Same trick as the panel section: if the paths above are gone, this says what
	-- replaced them without needing to know its name.
	local hits, scanned = FindByShape()
	W("   (scanned %d frames)", scanned or 0)
	local shown = 0
	for _, hit in ipairs(hits) do
		local path = PathTo(hit.frame)
		if path:lower():find("craft") or path:lower():find("recipe")
			or path:lower():find("profession") or path:lower():find("schematic") then
			shown = shown + 1
			if shown <= 8 then W("  [%d] %s", hit.score, path) end
		end
	end
	if shown == 0 then W("   nothing crafting-shaped scored above the threshold") end
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
	if section == "" or section == "deep"     then ProbeDeep();     ran = true end
	if section == "" or section == "api"      then ProbeApi();      ran = true end
	if section == "" or section == "station"  then ProbeStation();  ran = true end
	if not ran then
		W("unknown section '%s'. Try: api, addons, items, panel, swatches, deep, station, or nothing for all.", section)
	end

	ShowOutput(table.concat(out, "\n"))
	if ns.Print then ns.Print("probe done — the window has the output, Ctrl+A then Ctrl+C.") end
end
