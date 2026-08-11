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
-- The herb -> colour map, read off the Dye Station's own recipes
--
-- This was the last thing in the addon still carried over rather than read. The
-- 96 herb -> colour groupings came from the pigment each herb milled into before
-- 12.1, on the reasoning that removing the middle step doesn't change which herbs
-- are which colour. Reasonable — and still only a reading.
--
-- It matters more than a reference list. Makeable, Cost and "flowers still short"
-- are all summed over a colour's herb list, so a herb 12.1 quietly dropped from a
-- colour makes the window claim dyes you cannot actually make. That is a wrong
-- NUMBER, not a mislabelled row.
--
-- 12.1 answers it outright. The recipes moved into the Dye Station, and a recipe
-- schematic lists its own reagents:
--
--   C_TradeSkillUI.GetAllRecipeIDs()      -> the station's recipes
--   C_TradeSkillUI.GetRecipeSchematic(id) -> { outputItemID, reagentSlotSchematics }
--
-- The output item is one of the nine (the dye pass above has usually learned all
-- nine IDs by now), and the basic reagents are that colour's flowers. Read them
-- and the map is the game's rather than mine.
--
-- WHAT THIS IS ALLOWED TO DO. Replace a colour's herb list outright — REMOVALS
-- included, which the dye pass never does — but only for a colour whose recipe was
-- actually read and came back with reagents in it. A missing or empty answer
-- leaves Data.lua's fallback exactly where it stood. The asymmetry is the point:
-- the station is the authority when it speaks, and silence is not it speaking.
--
-- ONLY AT THE STATION. The recipes are readable only while its window is open, and
-- Makeable is needed everywhere, so what's learned is cached to saved variables
-- and re-applied at login. The cache accumulates per colour, so a visit that reads
-- three of the nine improves those three and leaves the other six alone.
--------------------------------------------------------------------------------

local MAX_STATION_TRIES = 8   -- reads per station visit before giving up
local stationTries = 0
local stationRead = false

ns.herbDiscovery = {
	ran = false, recipes = 0, colors = 0,
	added = 0, removed = 0, learned = 0,
	perDye = nil, disagreed = false,
}

local function StationReady()
	return type(C_TradeSkillUI) == "table"
		and type(C_TradeSkillUI.GetAllRecipeIDs) == "function"
		and type(C_TradeSkillUI.GetRecipeSchematic) == "function"
end

-- Blizzard's value for a required reagent, spelled out so a client whose Enum has
-- moved still filters rather than swallowing optional and finishing reagents.
local BASIC_REAGENT = 1

local function IsBasicSlot(slot)
	local kind = slot.reagentType
	if kind == nil then return true end
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	return kind == (basic or BASIC_REAGENT)
end

-- Which of the nine a schematic makes. The output item ID first, because it is the
-- fact; then the recipe's name, which is exactly "<Colour> Housing Dye" and covers
-- the window in the moments before the dye pass has landed the IDs.
local function ColorFromSchematic(sch)
	local itemID = tonumber(sch.outputItemID)
	local entry = itemID and ns.byID and ns.byID[itemID]
	if entry and entry.kind == "dye" then return entry.color end
	if type(sch.name) == "string" then
		local byName = ns.byName and ns.byName[sch.name:lower()]
		if byName and byName.kind == "dye" then return byName.color end
	end
	return nil
end

-- Every basic reagent on a schematic, how many of one it wants, and how many slots
-- it wanted them in.
--
-- A slot's `reagents` list is a set of INTERCHANGEABLE items — the quality tiers of
-- a flower — so every one of them is a way to make this dye and every one is
-- collected. Data.lua already carries the tiers as separate entries for the same
-- reason: they are separate items that stack and count separately.
local function ReagentsOf(sch)
	local ids, quantity, slots = {}, nil, 0
	for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
		if IsBasicSlot(slot) then
			slots = slots + 1
			for _, reagent in ipairs(slot.reagents or {}) do
				local id = tonumber(reagent.itemID)
				if id and id > 0 then ids[#ids + 1] = id end
			end
			local q = tonumber(slot.quantityRequired)
			if q and q > 0 and not quantity then quantity = q end
		end
	end

	-- A salvage recipe has no BASIC slot to read a quantity off, so try any slot.
	if not quantity then
		for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
			local q = tonumber(slot.quantityRequired)
			if q and q > 0 then quantity = q; break end
		end
	end

	-- 12.1's dye recipes have NO reagent slots at all, so neither of the above finds
	-- anything. The count lives on the schematic itself, as quantityMin/quantityMax.
	--
	-- READ THIS BEFORE "FIXING" IT. Those two fields sound like they describe the
	-- OUTPUT, and on an ordinary craft they do. On these they read 10/10, and ten is
	-- not how many dyes a craft makes — it is how many flowers it eats. Three things
	-- say so: the recipe's own description is "Create ONE Purple Housing Dye", the
	-- station's reagent line reads "24/10 Silverleaf", and 10 is exactly the input
	-- requirement counted by hand at a station on 10 August 2026.
	--
	-- The first version of the probe read them as the output and announced that
	-- Makeable was understating tenfold. Acting on that would have multiplied every
	-- Makeable, Cost and short figure in the addon by ten -- a far worse number than
	-- the overcount this whole exercise set out to fix. A salvage recipe consumes a
	-- quantity and produces loot; that is the shape being described.
	--
	-- Taken only when the recipe IS a salvage one and offered no slots, so an
	-- ordinary craft can never have its output read as an input.
	if not quantity and sch.isSalvageRecipe
		and #(sch.reagentSlotSchematics or {}) == 0 then
		local q = tonumber(sch.quantityMin) or tonumber(sch.quantityMax)
		if q and q > 0 then quantity = q end
	end

	return ids, quantity, slots
end

-- ...and the OTHER shape, which is the one 12.1 actually uses.
--
-- The dye recipes report `isSalvageRecipe = true`: they are built like Milling and
-- Prospecting, not like an ordinary craft. That is a much better fit for what a dye
-- actually is — one slot that will take any of fifteen different flowers, ten at a
-- time — but it means the flower list is NOT in the schematic's reagents. A salvage
-- recipe's schematic carries an empty reagent list and the accepted items are
-- served separately:
--
--   C_TradeSkillUI.GetSalvagableItemIDs(recipeID) -> { itemID, ... }
--
-- Which, for a dye recipe, IS that colour's flower list, straight from the game.
--
-- Blizzard's spelling is "Salvagable". Both spellings are tried rather than picking
-- the one that looks right, because a typo here fails exactly the way the reagent
-- path just did: silently, with an empty list that reads as "the station said
-- nothing" instead of "I called the wrong function".
local function SalvageItemIDs(recipeID)
	if type(C_TradeSkillUI) ~= "table" then return nil end
	local fn = C_TradeSkillUI.GetSalvagableItemIDs or C_TradeSkillUI.GetSalvageableItemIDs
	if type(fn) ~= "function" then return nil end
	local ok, ids = pcall(fn, recipeID)
	if not ok or type(ids) ~= "table" then return nil end

	local out = {}
	for _, raw in pairs(ids) do
		-- Tolerate both a flat list of IDs and a list of tables carrying one.
		local id = tonumber(raw)
		if not id and type(raw) == "table" then id = tonumber(raw.itemID or raw.ID) end
		if id and id > 0 then out[#out + 1] = id end
	end
	return out
end

-- Fold a { [color] = { itemID, ... } } map into ns.HERBS.
--
-- A herb left with no colours at all is KEPT. It is still a real item sitting in
-- someone's bags, it still counts, and it simply stops appearing under any
-- colour's flowers — whereas deleting it would throw away its price and its place
-- in the hide list for the sake of tidiness.
function ns.ApplyHerbMap(map)
	local stats = { colors = 0, added = 0, removed = 0, learned = 0 }
	if type(map) ~= "table" then return stats end

	ns.HERBS = ns.HERBS or {}
	local fresh = {} -- itemID -> herb created this pass, before the rebuild indexes it

	for _, color in ipairs(ns.COLORS or {}) do
		local ids = map[color]
		if type(ids) == "table" and #ids > 0 then
			stats.colors = stats.colors + 1

			local want = {}
			for _, raw in ipairs(ids) do
				local id = tonumber(raw)
				if id then want[id] = true end
			end

			-- Drop the colour from every herb the station did NOT list under it. This
			-- is the half that fixes an overcount, and the half nothing else can do.
			for _, herb in ipairs(ns.HERBS) do
				local colors = herb.colors
				if type(colors) == "table" then
					for i = #colors, 1, -1 do
						if colors[i] == color and not (herb.id and want[herb.id]) then
							table.remove(colors, i)
							stats.removed = stats.removed + 1
						end
					end
				end
			end

			-- Add it to every herb it did list.
			for _, raw in ipairs(ids) do
				local id = tonumber(raw)
				local herb = id and ((ns.byID and ns.byID[id]) or fresh[id])
				if herb and herb.kind ~= "dye" then
					herb.colors = herb.colors or {}
					local has = false
					for _, c in ipairs(herb.colors) do
						if c == color then has = true; break end
					end
					if not has then
						herb.colors[#herb.colors + 1] = color
						stats.added = stats.added + 1
					end
				elseif id and not herb then
					-- A flower Data.lua has never heard of: exactly the case the shade
					-- pass absorbs above, and worth absorbing for the same reason.
					local name
					if C_Item and C_Item.GetItemInfo then
						local ok, got = pcall(C_Item.GetItemInfo, id)
						if ok and type(got) == "string" and got ~= "" then name = got end
					end
					local added = { key = "herb_" .. id, name = name, id = id, colors = { color } }
					ns.HERBS[#ns.HERBS + 1] = added
					fresh[id] = added
					stats.learned = stats.learned + 1
				end
			end
		end
	end

	if ns.RebuildLookups then ns.RebuildLookups() end
	return stats
end

-- Write what was read into the profile, MERGED per colour: a visit that only
-- managed three colours must not blank the six a previous visit got right.
function ns.SaveLearnedHerbs(map)
	if type(DyeingDownTheHouseDB) ~= "table" or type(map) ~= "table" then return end
	local db = DyeingDownTheHouseDB
	db.learnedHerbs = db.learnedHerbs or {}
	local stamp = (type(time) == "function") and time() or nil
	for color, ids in pairs(map) do
		if type(ids) == "table" and #ids > 0 then
			local copy = {}
			for i, id in ipairs(ids) do copy[i] = id end
			db.learnedHerbs[color] = { seen = stamp, ids = copy }
		end
	end
	db.learnedHerbsPerDye = ns.HERBS_PER_DYE
end

-- Re-apply what an earlier station visit learned. Called at login, before anything
-- counts, so Makeable is right when you are nowhere near a station.
function ns.ApplyLearnedHerbs()
	if type(DyeingDownTheHouseDB) ~= "table" then return nil end

	local perDye = tonumber(DyeingDownTheHouseDB.learnedHerbsPerDye)
	if perDye and perDye > 0 then ns.HERBS_PER_DYE = perDye end

	local stored = DyeingDownTheHouseDB.learnedHerbs
	if type(stored) ~= "table" then return nil end

	local map, any = {}, false
	for color, row in pairs(stored) do
		if type(row) == "table" and type(row.ids) == "table" and #row.ids > 0 then
			map[color] = row.ids
			any = true
		end
	end
	if not any then return nil end
	return ns.ApplyHerbMap(map)
end

-- What Data.lua shipped, snapshotted before anything has had a chance to correct
-- it. `/dye probe herbs` diffs the station against THIS rather than against the
-- live tables — by the time anyone runs the probe, discovery has already folded
-- the game's answer in, and a diff against a table that has just been corrected
-- reports "no differences" no matter how wrong the fallback was.
ns.HERB_MAP_SHIPPED = {}
for _, herb in ipairs(ns.HERBS or {}) do
	for _, color in ipairs(herb.colors or {}) do
		local list = ns.HERB_MAP_SHIPPED[color]
		if not list then list = {}; ns.HERB_MAP_SHIPPED[color] = list end
		if herb.id then list[#list + 1] = herb.id end
	end
end

-- The same snapshot for shades, and for the same reason.
--
-- Nine of them ship with `guess = true`, and four of those four ex-teal ones were
-- placed by the very reasoning the herb map just disproved — that teal became blue.
-- The dye pass clears the flag and rewrites the colour the moment C_DyeColor
-- answers, so by the time anyone looks, the file's placement is unrecoverable
-- without this. `/dye probe shades` diffs against it.
ns.SHADE_MAP_SHIPPED = {}
for _, shade in ipairs(ns.SHADES or {}) do
	ns.SHADE_MAP_SHIPPED[shade.name:lower()] = {
		name = shade.name, color = shade.color, guess = shade.guess or false,
	}
end

-- Read the station without touching anything. Returns ok, then either a reason or
-- the map plus what was noticed while reading it.
--
-- Split out from the apply below so the probe can report what the game says
-- side by side with what shipped, which is a diagnostic and must not be a write.
function ns.ReadStationHerbMap()
	if not StationReady() then return false, "C_TradeSkillUI unavailable" end

	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or type(ids) ~= "table" then return false, "no recipes returned" end

	local map, recipes, quantities, multiSlot = {}, 0, {}, false
	local seenRecipes = {}
	for _, recipeID in pairs(ids) do
		local got, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if got and type(sch) == "table" then
			local color = ColorFromSchematic(sch)
			if color then
				local reagents, quantity, slots = ReagentsOf(sch)

				-- The salvage shape, which is what 12.1 ships. Only consulted when the
				-- reagent slots came back empty, so an ordinary craft is still read the
				-- ordinary way and this stays a fallback rather than a replacement.
				local salvage
				if #reagents == 0 then
					salvage = SalvageItemIDs(recipeID)
					if salvage and #salvage > 0 then reagents = salvage end
				end

				seenRecipes[#seenRecipes + 1] = {
					recipeID = recipeID, color = color, name = sch.name,
					reagents = #reagents, quantity = quantity, slots = slots,
					viaSalvage = (salvage ~= nil and #salvage > 0) or false,
					-- How many dyes ONE craft makes. Captured because these recipes
					-- report hasSingleItemOutput = false and canCreateMultiple = true,
					-- and if a craft yields more than one dye then Makeable — which
					-- divides flowers by ten and stops there — is understating.
					outputMin = tonumber(sch.quantityMin),
					outputMax = tonumber(sch.quantityMax),
				}

				if #reagents > 0 then
					recipes = recipes + 1
					local list = map[color] or {}
					map[color] = list
					local seen = {}
					for _, id in ipairs(list) do seen[id] = true end
					for _, id in ipairs(reagents) do
						if not seen[id] then seen[id] = true; list[#list + 1] = id end
					end
					if quantity then quantities[quantity] = (quantities[quantity] or 0) + 1 end
					if slots > 1 then multiSlot = true end
				end
			end
		end
	end

	-- How many flowers one dye costs, from the recipe rather than from the reading
	-- that got us here. Trusted only when every recipe agrees AND none wanted more
	-- than one slot: two basic slots means ten of EACH, which is a different shape of
	-- recipe entirely and not something to quietly average into one number.
	local only, distinct = nil, 0
	for quantity in pairs(quantities) do distinct = distinct + 1; only = quantity end
	local trustworthy = (distinct == 1) and not multiSlot

	-- Note the shape of the return: ok means "the API answered", NOT "there were
	-- dyes in it". Standing at an ordinary profession window is a perfectly good
	-- answer of zero, and the probe needs to see the recipes it found and rejected —
	-- which is the whole reason the first version of this file read nothing and
	-- could not say why.
	return true, map, {
		recipes = recipes,
		found = #seenRecipes,
		seen = seenRecipes,
		perDye = trustworthy and only or nil,
		-- "Nobody told me" and "they told me different things" are different answers
		-- and want different fixes. Reporting a silent API as a disagreement sent me
		-- looking for a conflict that was not there.
		quantityRead = distinct > 0,
		disagreed = (distinct > 1) or multiSlot,
	}
end

-- Read the station and fold what it says into the tables. Returns ok, plus either
-- a reason or a table of counts.
function ns.LearnHerbsFromStation()
	local ok, map, meta = ns.ReadStationHerbMap()
	if not ok then return false, map end

	-- Nothing recognisable in this window. Almost always the right answer — it is an
	-- ordinary profession window and not the Dye Station — and never a reason to
	-- touch the map.
	if meta.recipes == 0 then return false, "no dye recipes in this window" end

	if meta.perDye and meta.perDye > 0 then ns.HERBS_PER_DYE = meta.perDye end

	local stats = ns.ApplyHerbMap(map)
	stats.ran = true
	stats.recipes = meta.recipes
	stats.perDye = meta.perDye
	stats.disagreed = meta.disagreed
	ns.herbDiscovery = stats

	ns.SaveLearnedHerbs(map)
	return true, stats
end

-- Called by Crafting.lua the moment the station's recipe list lays itself out, and
-- by the events below. Bounded per visit: the window updates its list constantly
-- while you scroll and filter, and re-reading nine schematics on each of those
-- would be work for nothing.
function ns.TryLearnHerbs()
	if stationRead or stationTries >= MAX_STATION_TRIES then return end
	stationTries = stationTries + 1
	local ok = ns.LearnHerbsFromStation()
	if ok then
		stationRead = true
		if ns.Refresh then ns.Refresh() end
	end
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
		-- Before the dye pass, and before anything counts: the herb map decides every
		-- Makeable and Cost figure in the window, and saved variables are ready by now
		-- (ADDON_LOADED always lands first).
		pcall(ns.ApplyLearnedHerbs)
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

-- The station, on its own frame.
--
-- Its window fires the ordinary trade-skill events, and Crafting.lua also calls
-- ns.TryLearnHerbs when it decorates the recipe list — belt and braces, because
-- this is a station Blizzard built this patch and I would rather two routes in
-- than discover next patch that the one I picked was the wrong one. Both funnel
-- through the same per-visit guard, so the extra route costs nothing.
--
-- Closing the window clears the guard: the next visit reads again, which is how a
-- recipe change mid-session gets picked up.
local station = CreateFrame("Frame")

-- Named rather than "anything that isn't the close event". RegisterEvent should
-- make that equivalent, but a handler that acts on an event it never asked for is
-- one shared frame away from reading the station on a bag update -- and this one
-- REPLACES the herb map, so a stray read against whatever profession window
-- happens to be open is not a harmless no-op.
local STATION_EVENTS = {
	TRADE_SKILL_SHOW = true,
	TRADE_SKILL_LIST_UPDATE = true,
	TRADE_SKILL_DATA_SOURCE_CHANGED = true,
}

for event in pairs(STATION_EVENTS) do
	pcall(station.RegisterEvent, station, event)
end
pcall(station.RegisterEvent, station, "TRADE_SKILL_CLOSE")

station:SetScript("OnEvent", function(_, event)
	if event == "TRADE_SKILL_CLOSE" then
		stationRead, stationTries = false, 0
	elseif STATION_EVENTS[event] then
		pcall(ns.TryLearnHerbs)
	end
end)
