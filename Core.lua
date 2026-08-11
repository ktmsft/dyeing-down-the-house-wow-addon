-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Lookups
--
-- The crafting chain is: HERBS -> DYE, and everything is grouped by COLOR. Each
-- color has exactly one dye item, and every herb of that color turns into it at a
-- Dye Station. Both are real items that live in bags, bank and the Warband bank,
-- so the scanning and counting machinery works over the UNION of them (ns.ITEMS).
-- The per-kind views stay available as ns.DYES / ns.HERBS, and the color grouping
-- as ns.herbsByColor for the recipe engine.
--
-- 12.1 removed the pigment step and collapsed 62 dye items into nine, so a dye's
-- key IS its color key — the two used to be different things and are now the same
-- thing, which is why so much of what follows got shorter. The color NAMES live on
-- in ns.SHADES, but they aren't items and nothing here counts them.
--------------------------------------------------------------------------------

-- How many herbs one dye costs. Lives in Data.lua next to the note about it being
-- unconfirmed for 12.1; aliased here so the recipe engine reads clearly and so a
-- balance change stays a one-line edit.
ns.HERBS_PER_DYE = ns.HERBS_PER_DYE or 10

-- Dyes went Warband-bound in the 4 Aug 2026 patch, ahead of 12.1: they can no
-- longer be traded or listed, so a dye has no buy price at all any more. Flowers
-- are unchanged and still sell normally.
--
-- One flag rather than a dozen scattered `kind == "dye"` checks, because everything
-- downstream has to agree with it: the scan queue, the price import, the Cost
-- column, and the station marks. If Blizzard ever reverses this, flipping it back
-- to true restores the old craft-vs-buy behaviour everywhere at once.
ns.DYES_TRADEABLE = false

-- Can this item be bought or sold at all? Takes an entry or an item key.
function ns.IsTradeable(entry)
	if type(entry) == "string" then entry = ns.byKey[entry] end
	if not entry then return false end
	if entry.kind == "dye" then return ns.DYES_TRADEABLE end
	return true
end

ns.byID = {}
ns.byName = {}
ns.byKey = {}
ns.ITEMS = {}
ns.herbsByColor = {}
ns.shadesByColor = {}

-- Rebuilt from ns.DYES / ns.HERBS / ns.SHADES. Exposed so the test harness can
-- swap in a fixture dataset and rebuild, the same way the real Data.lua drives it
-- at load.
function ns.RebuildLookups()
	ns.byID, ns.byName, ns.byKey, ns.ITEMS = {}, {}, {}, {}
	ns.herbsByColor, ns.shadesByColor = {}, {}

	local function add(entry, kind)
		entry.kind = kind
		ns.ITEMS[#ns.ITEMS + 1] = entry
		entry.index = #ns.ITEMS
		ns.byKey[entry.key] = entry
		-- Name may be pending for a herb whose item the client hasn't cached yet;
		-- it still counts by ID, and its name gets filled in later.
		if entry.name then ns.byName[entry.name:lower()] = entry end
		if entry.id then ns.byID[entry.id] = entry end
	end

	for _, dye in ipairs(ns.DYES or {}) do add(dye, "dye") end
	for _, herb in ipairs(ns.HERBS or {}) do
		add(herb, "herb")
		-- A herb can turn into more than one color's dye, so it may appear in several
		-- color buckets. `colors` is the list; `color` is accepted as a one-color
		-- shorthand.
		herb.colors = herb.colors or (herb.color and { herb.color }) or {}
		for _, color in ipairs(herb.colors) do
			local list = ns.herbsByColor[color]
			if not list then list = {}; ns.herbsByColor[color] = list end
			list[#list + 1] = herb
		end
	end

	-- Shades are NOT items and deliberately never reach `add`: nothing counts them,
	-- prices them or scans for them. They're grouped by family, they carry goals,
	-- and they answer the search.
	--
	-- A shade's key is its lowercased NAME. It has nothing else stable — no item ID,
	-- and the game's dyeColorID isn't known until Discover.lua has run, which is
	-- after saved variables are read. The name is what the player typed a goal
	-- against, so the name is what the goal is filed under.
	ns.shadeByKey = {}
	for _, shade in ipairs(ns.SHADES or {}) do
		shade.key = shade.name:lower()
		ns.shadeByKey[shade.key] = shade
		if shade.color then
			local list = ns.shadesByColor[shade.color]
			if not list then list = {}; ns.shadesByColor[shade.color] = list end
			list[#list + 1] = shade
		end
	end
end

ns.RebuildLookups()

--------------------------------------------------------------------------------
-- UI hooks — safe no-op defaults
--
-- UI.lua and Options.lua (loaded AFTER Core in the TOC) provide the real versions.
-- Default them to no-ops here so Core's counting engine runs even if the UI layer
-- is absent or fails to load — otherwise a bag event fires the refresh timer
-- straight into a nil call. Assigned with `or` so a real implementation loaded
-- afterwards always wins.
--------------------------------------------------------------------------------

ns.Refresh         = ns.Refresh         or function() end
ns.BuildUI         = ns.BuildUI         or function() end
ns.Show            = ns.Show            or function() end
ns.Toggle          = ns.Toggle          or function() end
ns.RestorePosition = ns.RestorePosition or function() end
ns.OpenOptions     = ns.OpenOptions     or function() end

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

-- 2: dyes went Warband-bound, so every stored dye price is now junk (see Migrate).
--------------------------------------------------------------------------------
-- Is this client new enough?
--
-- 2.0 is built for Curse of Ula'tek. Its migration rewrites a profile one way:
-- pre-12.1 dye and pigment counts are dropped, goals are rekeyed onto colors and
-- then onto shades. On a 12.1 client that is exactly right. On a 12.0.7 one it is
-- a profile shredded for no reason — the items it deletes still exist there, and
-- going back to 1.3.0 afterwards would find its data gone.
--
-- So the version is CHECKED rather than assumed, and on an old client the addon
-- touches nothing: no migration, no counting, and the window says why instead of
-- showing nine colors the client has never heard of and zero of each. An addon
-- that quietly reports zeros is indistinguishable from one that is broken.
--
-- An unknown version counts as supported. GetBuildInfo is absent in the test
-- harness and could be absent on some client this was never tried on; refusing to
-- run because a version could not be READ would be worse than the thing being
-- guarded against.
--------------------------------------------------------------------------------

ns.MIN_TOC = 120100 -- Curse of Ula'tek

function ns.ClientTOC()
	if type(GetBuildInfo) ~= "function" then return nil end
	local ok, toc = pcall(function() return select(4, GetBuildInfo()) end)
	return (ok and tonumber(toc)) or nil
end

function ns.ClientSupported()
	local toc = ns.ClientTOC()
	return (toc == nil) or (toc >= ns.MIN_TOC)
end

-- 3: 12.1 replaced 62 dye items and 10 pigments with nine, so every key that named
--    one of them has to be rewritten to its color (see Migrate).
-- 4: goals moved from the nine families onto the 77 shade names, so the old
--    family goals become "unassigned" entries rather than being lost.
local DB_VERSION = 4

local defaults = {
	version = DB_VERSION,

	-- Everything the addon *counts* is account-wide: each character contributes
	-- its bags and bank as it logs in, and the totals shown are the sum across the
	-- whole roster. Only presentation lives in `ui`.
	warband = {},       -- [key] = count, cached from the last bank visit by anyone
	warbandSeen = nil,  -- timestamp of that visit
	warbandSeenBy = nil,-- which character made it
	chars = {},         -- [charKey] = { bags, bank, bagsSeen, bankSeen, name, realm, class }
	-- [shadeKey] = number. Goals are set against SHADE names — "5 Alliance Blue" —
	-- because that's how people decorate: you want a specific colour on a specific
	-- wall. What that COSTS is a family dye, so a family's requirement is the sum of
	-- its shades' goals. One editable place, one derived total, and they can't drift.
	goals = {},
	-- [color] = number, a family goal not attached to any shade. Only the v4
	-- migration creates these, from the per-family goals that were the whole model
	-- before shades could carry one. Editable and self-clearing: set it to 0 and the
	-- row disappears.
	unassigned = {},
	learned = {},       -- [key] = itemID discovered by name match
	-- [color] = { seen = ts, ids = { itemID, ... } } — which flowers make that
	-- colour, read off the Dye Station's own recipe. Cached because the recipes are
	-- only readable with the station's window open, while Makeable and Cost are
	-- needed everywhere. Merged per colour, never wholesale. See Discover.lua.
	learnedHerbs = {},
	-- Flowers per dye, likewise read off the recipe rather than assumed. Absent
	-- until a station has been visited; Data.lua's 10 stands in until then.
	learnedHerbsPerDye = nil,
	prices = {},        -- [key] = { copper = n, seen = ts, source = "ah" }
	-- Where prices come from. "auto" takes the best source installed; naming one
	-- pins it. See Prices.lua.
	priceSource = "auto",     -- "auto" | "blizzard" | "auctionator" | "tsm"
	tsmPriceKey = "DBMarket", -- TSM custom price string, when TSM is the source
	-- Set by the v2 migration on a profile that predates dyes going Warband-bound;
	-- the next login says so once and clears it. Default false, so a profile created
	-- after the patch never announces a change it never lived through.
	warbandNoticePending = false,
	ui = {
		point = "CENTER",
		relPoint = "CENTER",
		x = 0,
		y = 0,
		shown = true,
		locked = false,
		scale = 1.0,
		hideZero = false,
		-- Window opacity. 1.0 is the look everyone has had until now and stays the
		-- default; the floor is 0.2 rather than 0 so the window can never be made
		-- invisible and then impossible to find in order to turn it back up.
		opacity = 1.0,
		search = "",       -- name filter
		sort = "alpha",    -- see VALID_SORT
		sortDir = "asc",   -- "asc" | "desc"
		-- Two tabs, for two questions that genuinely differ again now that goals live
		-- on shades: "which colour am I short of" (the nine families, rolled up) and
		-- "how many of this exact shade did I want" (the 77 names, where the numbers
		-- are actually typed).
		tab = "color",   -- "color" | "dye"
		-- Optional columns. Color + Have are always shown.
		cols = { flowers = true, makeable = true, value = true, goal = true },
		expanded = {},   -- [color] = true, color rows opened to show flowers and shades
		hideCostlyFlowers = false, -- in the expand view, show only the cheapest flower(s) of a color
		hiddenDyes = {}, -- [color] = true, families the player unchecked (hidden from the list)
		hiddenHerbs = {}, -- [herbNameLower] = true, flowers hidden from the expand view
		rainbowTitle = true, -- flashy rainbow name (off = plain)
		housingGoalInput = true, -- show the "Dye Needed" box in the house dye panel
		-- Off by default. Opening a row is nearly always about the flowers, and the
		-- shades ran straight on after them with no separation -- which read as more
		-- flower rows that had lost their numbers rather than as a different kind of
		-- thing. The names are still searchable and still in the row tooltip; this
		-- only controls whether they get rows of their own.
		--
		-- Renamed from `showShades` rather than flipped in place: that key never
		-- shipped, but it IS saved in dev profiles, and ApplyDefaults will not
		-- overwrite a stored value -- so changing the default alone would have left
		-- it on for exactly the profile that asked for it to be off.
		listShades = true,
		markHerbs = true, -- green check / red X on flowers in the station's reagent
		                  -- picker (check = cheapest flower for that color)
	},
}

local function ApplyDefaults(target, source)
	for k, v in pairs(source) do
		if type(v) == "table" then
			if type(target[k]) ~= "table" then target[k] = {} end
			ApplyDefaults(target[k], v)
		elseif target[k] == nil then
			target[k] = v
		end
	end
end

-- Every pre-12.1 dye key, and the color it becomes.
--
-- This and its pigment twin below are the ONLY place the old 62 dyes and 10
-- pigments still exist, and they are migration data rather than game data — which
-- is why they're here and not in Data.lua. Nothing reads them after the upgrade
-- has run once.
--
-- The four ex-teal shades follow Data.lua's reading of the split (Un'Goro Green to
-- green, the rest to blue). Getting one of those four wrong moves a goal between
-- two families, which is worth far less than losing it.
local LEGACY_DYE_COLOR = {
	darkiron = "black", darkwood = "black", ironclaw = "black",
	obsidiumblack = "black", stormheimgrey = "black", stormsteel = "black",
	allianceblue = "blue", dusklilygrey = "blue", midnightblue = "blue",
	nazjatarnavy = "blue", zephrasblue = "blue",
	darkgold = "brown", earthenbrown = "brown", heartwood = "brown",
	kalimdorsand = "brown", mesquitebrown = "brown", paleumber = "brown",
	timbermawbrown = "brown", volduntaupe = "brown", warmteak = "brown",
	dustwallowgreen = "green", earthroot = "green", emeralddreaming = "green",
	gravemossgreen = "green", grizzlyhillsgreen = "green", lushgreen = "green",
	silversagegreen = "green",
	bronze = "orange", copper = "orange", elwynnpumpkin = "orange",
	kodohidebrown = "orange",
	arcwine = "purple", forsakenplum = "purple", kirintorviolet = "purple",
	moonberryamethyst = "purple", netherstormfuchsia = "purple",
	nightsonglilac = "purple", voidviolet = "purple",
	deepmageroyalred = "red", firebloomred = "red", gilneanrose = "red",
	hinterlandshickory = "red", hordered = "red", mahogany = "red",
	rainpoppyred = "red", ratchetrust = "red",
	basicbirch = "white", bonewhite = "white", highbornemarble = "white",
	highlandbirch = "white",
	brass = "yellow", gold = "yellow", holyoaktan = "yellow", pinewood = "yellow",
	sandfuryyellow = "yellow", savannahgold = "yellow", sungrassyellow = "yellow",
	zandalarigold = "yellow",
	-- the retired teal family
	kultiransteel = "blue", tidesageteal = "blue", vortexteal = "blue",
	ungorogreen = "green",
}

-- The ten pigments, kept SEPARATE from the dyes above.
--
-- Most of the migration treats the two the same — a stored count or price keyed by
-- either is equally dead. The hide list is the exception, and it's the reason for
-- the split: hiding was a per-dye choice, so a pigment key was never in hiddenDyes.
-- Folded in with the dyes it would count as "this family had a visible member" for
-- every family, and the AND-fold below would quietly throw the player's whole hide
-- list away.
--
-- Teal pigment goes to blue because Blizzard said so outright: it converts to Blue
-- Housing Dye.
local LEGACY_PIGMENT_COLOR = {
	black_pigment = "black", blue_pigment = "blue", brown_pigment = "brown",
	green_pigment = "green", orange_pigment = "orange", purple_pigment = "purple",
	red_pigment = "red", white_pigment = "white", yellow_pigment = "yellow",
	teal_pigment = "blue",
}

-- Either kind, for everything that doesn't care which it was.
local LEGACY_KEY_COLOR = {}
for key, color in pairs(LEGACY_DYE_COLOR) do LEGACY_KEY_COLOR[key] = color end
for key, color in pairs(LEGACY_PIGMENT_COLOR) do LEGACY_KEY_COLOR[key] = color end

-- Bring an older saved profile up to date. Runs after ApplyDefaults, so anything
-- new already exists; this is only for values that are now WRONG rather than
-- missing. Each step is guarded by the version it upgrades from, so it runs once.
local function Migrate(db)
	local from = tonumber(db.version) or 1

	-- v1 -> v2: dyes are Warband-bound and can't be listed, so every dye price on
	-- file is a pre-patch relic. Left alone they'd quietly outlive the market that
	-- made them and keep answering "what's it worth" with a number that no longer
	-- exists. Flower prices are untouched — flowers still trade.
	if from < 2 then
		for key in pairs(db.prices or {}) do
			local entry = ns.byKey[key]
			if entry and entry.kind == "dye" then db.prices[key] = nil end
		end
		-- This profile watched its dye prices vanish, so it gets told why.
		db.warbandNoticePending = true
	end

	-- v2 -> v3: 12.1 replaced 62 dye items and 10 pigments with nine dyes, one per
	-- color. Every key naming one of them now names nothing, so each has to be
	-- rewritten to its color or dropped. What happens to each kind of value differs,
	-- and the difference is the whole point of doing this by hand:
	--
	--   GOALS are the player's intent and are FOLDED, by adding them up. Wanting 5
	--   Alliance Blue and 3 Midnight Blue is wanting 8 Blue Housing Dye, which is
	--   also exactly what Hestia's mail does to the items themselves. Losing
	--   someone's goals to a schema change is the one outcome worth real effort to
	--   avoid.
	--
	--   COUNTS are DROPPED, not folded. The old items no longer exist and the new
	--   ones arrive by mail the player has to collect, so a folded count claims dyes
	--   that aren't in the bags yet. Bags rescan on login and the bank on its next
	--   visit; until then this reads low. That's the house rule from ReconcileLive —
	--   briefly under-reporting beats inflating from a partial view.
	--
	--   PRICES are dropped outright. Dye prices went in v2; pigments no longer exist
	--   to have one.
	--
	--   HIDDEN families are folded with AND, not OR: a family disappears only if
	--   every single one of its old shades was unticked. Otherwise unticking one
	--   shade of black would have silently hidden all of black.
	if from < 3 then
		local goals, hidden = {}, {}
		local hiddenSeen, shownSeen = {}, {}

		for key, value in pairs(db.goals or {}) do
			local color = LEGACY_KEY_COLOR[key] or (ns.byKey[key] and ns.byKey[key].color)
			if color then goals[color] = (goals[color] or 0) + (tonumber(value) or 0) end
		end
		db.goals = goals

		-- Dye keys only. See LEGACY_PIGMENT_COLOR for why mixing them in here would
		-- wipe the hide list rather than migrate it.
		local ui = db.ui or {}
		for key, color in pairs(LEGACY_DYE_COLOR) do
			if (ui.hiddenDyes or {})[key] then hiddenSeen[color] = true
			else shownSeen[color] = true end
		end
		for color in pairs(hiddenSeen) do
			if not shownSeen[color] then hidden[color] = true end
		end
		ui.hiddenDyes = hidden

		-- Rows opened, and the old family tab's separately-tracked open colors, are one
		-- table now. Teal folds into blue with everything else.
		local expanded = {}
		for key in pairs(ui.expanded or {}) do
			local color = LEGACY_KEY_COLOR[key]
			if color then expanded[color] = true end
		end
		for color in pairs(ui.expandedColors or {}) do
			expanded[LEGACY_KEY_COLOR[color .. "_pigment"] or color] = true
		end
		ui.expanded, ui.expandedColors = expanded, nil

		-- Tabs and the pigment column are gone; leaving them behind would quietly
		-- re-apply a layout that no longer exists.
		ui.tab, ui.groupSort, ui.groupSortDir = nil, nil, nil
		if type(ui.cols) == "table" then ui.cols.pigment = nil end

		for key in pairs(db.prices or {}) do
			if LEGACY_KEY_COLOR[key] then db.prices[key] = nil end
		end

		local function StripCounts(t)
			if type(t) ~= "table" then return end
			for key in pairs(t) do
				if LEGACY_KEY_COLOR[key] then t[key] = nil end
			end
		end
		StripCounts(db.warband)
		for _, char in pairs(db.chars or {}) do
			StripCounts(char.bags)
			StripCounts(char.bank)
		end

		-- IDs learned by name-matching pointed at items that have been deleted.
		for key in pairs(db.learned or {}) do
			if LEGACY_KEY_COLOR[key] then db.learned[key] = nil end
		end
	end

	-- v3 -> v4: goals used to live on the nine families and now live on the 77 shade
	-- names, with the family total derived from them. A family goal cannot be split
	-- across shades — the addon has no idea which shades the player meant — so each
	-- one moves to `unassigned`, where it still counts toward the family's total and
	-- can be edited or cleared. Silently dropping hand-entered numbers is the one
	-- outcome worth real effort to avoid; carrying them as "some blue, unattributed"
	-- is honest about what is actually known.
	if from < 4 then
		local moved = {}
		for key, value in pairs(db.goals or {}) do
			local entry = ns.byKey[key]
			if entry and entry.kind == "dye" then
				moved[entry.color] = (moved[entry.color] or 0) + (tonumber(value) or 0)
			end
		end
		db.unassigned = db.unassigned or {}
		for color, value in pairs(moved) do
			if value > 0 then
				db.unassigned[color] = (db.unassigned[color] or 0) + value
			end
		end
		-- Goals is a shade-keyed table from here on. Anything left in it was keyed by
		-- a colour, which is now a different namespace entirely.
		db.goals = {}
	end

	-- Keys that never shipped, cleared on every load rather than at a version gate.
	-- A version-gated step cannot help a profile that is ALREADY at the current
	-- version, which is every dev profile that has run 2.0 -- and `showShades` is
	-- only in those. Delete this block once 2.0 is out and no such profile is left.
	local ui = db.ui
	if ui then ui.showShades = nil end

	db.version = DB_VERSION
end

local charKey

--------------------------------------------------------------------------------
-- Bag groups
--
-- Bag index numbering has shifted across expansions (the 11.2 bank rework renamed
-- the character bank containers), so derive the groups from Enum.BagIndex by name
-- instead of hardcoding IDs.
--------------------------------------------------------------------------------

local bagGroups

local function BuildBagGroups()
	local bags, bank, warband = {}, {}, {}

	for name, id in pairs(Enum.BagIndex) do
		if name == "Backpack" or name == "ReagentBag" or name:find("^Bag_%d") then
			bags[#bags + 1] = id
		elseif name:find("^AccountBankTab") then
			warband[#warband + 1] = id
		elseif name:find("^CharacterBankTab") or name:find("^BankBag_%d")
			or name == "Bank" or name == "Reagentbank" then
			bank[#bank + 1] = id
		end
	end

	table.sort(bags)
	table.sort(bank)
	table.sort(warband)

	return { bags = bags, bank = bank, warband = warband }
end

--------------------------------------------------------------------------------
-- Scanning
--
-- Bank and Warband containers only report their contents while a bank frame is
-- open. Everywhere else they read as zero slots, so we scan them on visit and
-- serve cached numbers the rest of the time.
--------------------------------------------------------------------------------

local bankOpen = false

local function ResolveEntry(info)
	if not info then return nil end

	local entry = info.itemID and ns.byID[info.itemID]
	if entry then return entry end

	-- Fall back to matching on name, and remember the ID once we see it, so the
	-- addon still works if an ID in Data.lua is wrong or Blizzard adds an item in a
	-- later patch.
	--
	-- Only entries with no known ID are eligible. Name matching against an entry we
	-- already have an ID for would be actively wrong: two different items can share
	-- a name across expansions, and that would both mis-count and overwrite the
	-- real ID. (LumberOne hit exactly this with "Coldwind Lumber".)
	if info.hyperlink and info.itemID then
		local itemName = C_Item.GetItemInfo(info.hyperlink)
		if itemName then
			entry = ns.byName[itemName:lower()]
			if entry and not entry.id then
				entry.id = info.itemID
				ns.byID[info.itemID] = entry
				DyeingDownTheHouseDB.learned[entry.key] = info.itemID
				return entry
			end
		end
	end

	return nil
end

local function ScanGroup(ids)
	local counts = {}
	for _, bag in ipairs(ids) do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local entry = ResolveEntry(info)
			if entry then
				counts[entry.key] = (counts[entry.key] or 0) + (info.stackCount or 1)
			end
		end
	end
	return counts
end

local function ScanBags()
	local char = DyeingDownTheHouseDB.chars[charKey]
	char.bags = ScanGroup(bagGroups.bags)
	char.bagsSeen = time()
end

local function ScanBank()
	if not bankOpen then return end
	local char = DyeingDownTheHouseDB.chars[charKey]
	char.bank = ScanGroup(bagGroups.bank)
	char.bankSeen = time()

	-- The Warband bank is one shared inventory, so the newest scan by any character
	-- replaces it wholesale rather than adding to it.
	DyeingDownTheHouseDB.warband = ScanGroup(bagGroups.warband)
	DyeingDownTheHouseDB.warbandSeen = time()
	DyeingDownTheHouseDB.warbandSeenBy = charKey
end

--------------------------------------------------------------------------------
-- Reconciling against live counts
--
-- Bank and Warband figures are snapshots from the last bank visit, because the
-- container APIs only report those slots while a bank frame is open. Crafting and
-- selling break that: a work order pulls reagents straight out of the Warband
-- bank, and an auction-house sale can move a stack the addon never saw leave —
-- nothing in bags changes, no event we watch fires, and the snapshot keeps
-- insisting the items are still there.
--
-- C_Item.GetItemCount DOES report bank and account-bank contents away from a
-- bank, so it can notice the shortfall. It only says how much the CURRENT
-- character can reach (bags + own bank + Warband), enough to tell that something
-- was spent, though not from which of the two.
--
-- So this only ever REDUCES. Inflating totals from a partial view would be much
-- worse than briefly under-reporting, and the next bank visit restores exact
-- figures anyway.
--------------------------------------------------------------------------------

local function LiveReachableCount(itemID)
	if not (C_Item and C_Item.GetItemCount) then return nil end

	for _, args in ipairs({
		{ itemID, true, false, true, true },  -- ..., includeReagentBank, includeAccountBank
		{ itemID, true, false, true },
		{ itemID, true },
	}) do
		local ok, count = pcall(C_Item.GetItemCount, unpack(args))
		if ok and type(count) == "number" then return count end
	end

	return nil
end

local function ReconcileLive()
	if not (DyeingDownTheHouseDB and charKey) then return end
	local char = DyeingDownTheHouseDB.chars[charKey]
	if not char then return end

	local changed = false

	for _, entry in ipairs(ns.ITEMS) do
		if entry.id then
			local live = LiveReachableCount(entry.id)
			if live then
				local bags = (char.bags and char.bags[entry.key]) or 0
				local bank = (char.bank and char.bank[entry.key]) or 0
				local warband = DyeingDownTheHouseDB.warband[entry.key] or 0
				local deficit = (bags + bank + warband) - live

				if deficit > 0 then
					-- Bags were just rescanned and are accurate, so the shortfall is in
					-- the cached figures. Take it from this character's own bank before
					-- the shared Warband bank: getting the shared number wrong affects
					-- every character, so it's the more cautious order.
					local fromBank = math.min(bank, deficit)
					if fromBank > 0 then
						char.bank[entry.key] = bank - fromBank
						deficit = deficit - fromBank
						changed = true
					end
					if deficit > 0 and warband > 0 then
						DyeingDownTheHouseDB.warband[entry.key] = math.max(0, warband - deficit)
						changed = true
					end
				end
			end
		end
	end

	return changed
end

--------------------------------------------------------------------------------
-- DataStore (optional)
--
-- If the player happens to have DataStore installed, it already knows about
-- characters this addon has never seen — alts that haven't logged in since it was
-- installed. Borrowing that fills in the one real gap in the design.
--
-- Rules, in order of importance:
--   * Absolutely nothing happens if DataStore isn't there. It's an OptionalDep,
--     never a Dependency, so the addon loads fine either way.
--   * Our own scan always wins. DataStore only supplies characters missing from
--     our chars table, so a logged-in alt is never counted twice.
--   * The Warband bank is never taken from DataStore. It's shared account-wide and
--     we store it once; adding a per-character figure on top would multiply it by
--     the roster size.
--
-- Every call is feature-detected and wrapped, because an addon we don't ship can
-- change shape underneath us at any time.
--------------------------------------------------------------------------------

local function DataStoreReady()
	return type(DataStore) == "table"
		and type(DataStore.IterateCharacters) == "function"
		and type(DataStore.GetContainerItemCount) == "function"
end

-- [charKey] = { bags = {[key]=n}, bank = {...}, name, realm } for characters we
-- have no scan of. Rebuilt on login rather than saved, so it can never go stale or
-- outlive DataStore being uninstalled.
local borrowed = {}

local function RefreshBorrowed()
	borrowed = {}
	if not DataStoreReady() then return end

	local ok = pcall(function()
		DataStore:IterateCharacters(function(key, id)
			-- Keys look like "Account.Realm.Name"; ours are "Name-Realm".
			local _, realm, name = strsplit(".", key)
			if not (realm and name) then return end

			local ourKey = name .. "-" .. realm
			if DyeingDownTheHouseDB.chars[ourKey] then return end -- we have our own scan

			local bags, bank
			for _, entry in ipairs(ns.ITEMS) do
				if entry.id then
					-- Returns bags, bank and reagent bag separately, counting only this
					-- character's own containers.
					local got, bagCount, bankCount, reagentCount =
						pcall(DataStore.GetContainerItemCount, DataStore, id or key, entry.id)

					if got then
						local inBags = (bagCount or 0) + (reagentCount or 0)
						local inBank = bankCount or 0
						if inBags > 0 then
							bags = bags or {}
							bags[entry.key] = inBags
						end
						if inBank > 0 then
							bank = bank or {}
							bank[entry.key] = inBank
						end
					end
				end
			end

			if bags or bank then
				borrowed[ourKey] = {
					bags = bags or {},
					bank = bank or {},
					name = name,
					realm = realm,
					fromDataStore = true,
				}
			end
		end)
	end)

	if not ok then borrowed = {} end
end

-- Every character contributing to the totals: ours first, then anything DataStore
-- knows that we don't. Callers must not care which is which.
local function EachCharacter(callback)
	for ck, char in pairs(DyeingDownTheHouseDB.chars) do
		callback(ck, char, false)
	end
	for ck, char in pairs(borrowed) do
		if not DyeingDownTheHouseDB.chars[ck] then
			callback(ck, char, true)
		end
	end
end

function ns.HasDataStore()
	return DataStoreReady()
end

function ns.GetBorrowedCount()
	local n = 0
	for _ in pairs(borrowed) do n = n + 1 end
	return n
end

--------------------------------------------------------------------------------
-- Public API — counting
--------------------------------------------------------------------------------

function ns.GetCharKey()
	return charKey
end

-- The account-wide total for any item key (dye OR flower): every character's bags
-- and bank, plus the shared Warband bank counted exactly once. The Warband figure
-- is added once, outside the character loop, and is always our own — never
-- DataStore's — which keeps it from being multiplied by the roster size.
function ns.GetTotal(key)
	local total = (DyeingDownTheHouseDB.warband[key]) or 0
	EachCharacter(function(_, char)
		total = total + ((char.bags and char.bags[key]) or 0)
		              + ((char.bank and char.bank[key]) or 0)
	end)
	return total
end

-- Per-character detail for the tooltip. Characters holding none of this item are
-- omitted; the current character sorts first, then by holdings descending.
function ns.GetBreakdown(key)
	local result = {
		chars = {},
		warband = DyeingDownTheHouseDB.warband[key] or 0,
		total = 0,
	}

	EachCharacter(function(ck, char, fromDataStore)
		local bags = (char.bags and char.bags[key]) or 0
		local bank = (char.bank and char.bank[key]) or 0
		if bags + bank > 0 then
			result.chars[#result.chars + 1] = {
				key = ck,
				name = char.name or ck,
				realm = char.realm,
				class = char.class,
				bags = bags,
				bank = bank,
				total = bags + bank,
				isCurrent = (ck == charKey),
				fromDataStore = fromDataStore,
			}
		end
		result.total = result.total + bags + bank
	end)

	result.total = result.total + result.warband

	table.sort(result.chars, function(a, b)
		if a.isCurrent ~= b.isCurrent then return a.isCurrent end
		if a.total ~= b.total then return a.total > b.total end
		return a.name < b.name
	end)

	return result
end

-- Roster scan freshness, newest bank visit first, for the header tooltip.
function ns.GetScanInfo()
	local info = {
		warbandSeen = DyeingDownTheHouseDB.warbandSeen,
		warbandSeenBy = DyeingDownTheHouseDB.warbandSeenBy,
		chars = {},
	}

	for ck, char in pairs(DyeingDownTheHouseDB.chars) do
		info.chars[#info.chars + 1] = {
			key = ck,
			name = char.name or ck,
			realm = char.realm,
			class = char.class,
			bagsSeen = char.bagsSeen,
			bankSeen = char.bankSeen,
			isCurrent = (ck == charKey),
		}
	end

	table.sort(info.chars, function(a, b)
		if a.isCurrent ~= b.isCurrent then return a.isCurrent end
		return (a.bankSeen or 0) > (b.bankSeen or 0)
	end)

	return info
end

-- "3 minutes ago" etc, plus a color that fades as the data goes stale.
function ns.FormatAge(timestamp)
	if not timestamp then
		return "never", 1, 0.4, 0.4
	end

	local delta = time() - timestamp
	local text

	if delta < 60 then
		text = "just now"
	elseif delta < 3600 then
		local n = math.floor(delta / 60)
		text = ("%d minute%s ago"):format(n, n == 1 and "" or "s")
	elseif delta < 86400 then
		local n = math.floor(delta / 3600)
		text = ("%d hour%s ago"):format(n, n == 1 and "" or "s")
	else
		local n = math.floor(delta / 86400)
		text = ("%d day%s ago"):format(n, n == 1 and "" or "s")
	end

	if delta < 3600 then
		return text, 0.4, 1, 0.4
	elseif delta < 86400 then
		return text, 1, 1, 1
	else
		return text, 1, 0.6, 0.2
	end
end

--------------------------------------------------------------------------------
-- Goals
--
-- Set against SHADES, read against FAMILIES. You decide you want five Alliance
-- Blue; what that costs is five Blue Housing Dye, and the Blue row adds that to
-- everything else blue you've asked for. The number is typed in one place and
-- derived everywhere else, so the two can never disagree.
--
-- `unassigned` is the one exception, and it exists only for history: goals used to
-- be per-family, and a family goal can't be split across shades because the addon
-- doesn't know which shades were meant. Those carry forward as an unattributed
-- amount that still counts and can still be cleared.
--------------------------------------------------------------------------------

local function ShadeKey(name)
	if type(name) ~= "string" then return nil end
	return name:lower()
end

function ns.GetShadeGoal(name)
	local key = ShadeKey(name)
	return key and DyeingDownTheHouseDB.goals[key] or 0
end

function ns.SetShadeGoal(name, value)
	local key = ShadeKey(name)
	if not key then return end
	value = tonumber(value)
	if not value or value <= 0 then
		DyeingDownTheHouseDB.goals[key] = nil
	else
		DyeingDownTheHouseDB.goals[key] = math.floor(value)
	end
	ns.Refresh()
end

-- The part of a family's goal not attached to any shade.
function ns.GetUnassignedGoal(color)
	return DyeingDownTheHouseDB.unassigned[color] or 0
end

function ns.SetUnassignedGoal(color, value)
	value = tonumber(value)
	if not value or value <= 0 then
		DyeingDownTheHouseDB.unassigned[color] = nil
	else
		DyeingDownTheHouseDB.unassigned[color] = math.floor(value)
	end
	ns.Refresh()
end

-- How many dyes of `color` are wanted in total: every shade goal in the family,
-- plus anything unattributed. This is what the window, the station and the recipe
-- maths all read, so there is exactly one definition of "needed".
function ns.GetGoal(color)
	local total = DyeingDownTheHouseDB.unassigned[color] or 0
	for _, shade in ipairs(ns.shadesByColor[color] or {}) do
		total = total + (DyeingDownTheHouseDB.goals[shade.key] or 0)
	end
	return total
end

-- Kept so a family goal can still be set directly — the housing panel used to, and
-- the slash commands and tests do. It writes the unattributed bucket, which is the
-- only family-level number there is now.
function ns.SetGoal(color, value)
	ns.SetUnassignedGoal(color, value)
end

-- The shades of a family that carry a goal, biggest first, for the family tooltip.
function ns.GetGoalBreakdown(color)
	local out = {}
	for _, shade in ipairs(ns.shadesByColor[color] or {}) do
		local goal = DyeingDownTheHouseDB.goals[shade.key] or 0
		if goal > 0 then out[#out + 1] = { name = shade.name, goal = goal } end
	end
	table.sort(out, function(a, b)
		if a.goal ~= b.goal then return a.goal > b.goal end
		return a.name < b.name
	end)
	return out
end

-- True once any character on the account has visited a bank, so the UI can say
-- "never scanned" instead of silently showing 0.
function ns.HasBankData()
	return DyeingDownTheHouseDB.warbandSeen ~= nil
end

function ns.IsBankOpen()
	return bankOpen
end

--------------------------------------------------------------------------------
-- Prices (populated by the AH scanner — storage and readers only for now)
--
-- Stored per item key in copper, with the timestamp of the scan and its source.
-- The AH scan that fills this in is a separate step; these are the pure readers
-- and writers the cost display and the sort are built on.
--
-- In practice this now only ever holds FLOWER prices: Warband-bound dyes aren't
-- traded, so nothing writes one and Migrate() cleared the pre-patch leftovers. The
-- store stays kind-agnostic rather than rejecting dyes outright — it's a dumb
-- key/value cache, and the rule about what's worth pricing belongs with the
-- scanner (BuildScanQueue) and the importer (ShouldPriceEntry), which is where a
-- reader can find it stated once.
--------------------------------------------------------------------------------

function ns.SetPrice(key, copper, source)
	copper = tonumber(copper)
	if not copper or copper < 0 then
		DyeingDownTheHouseDB.prices[key] = nil
	else
		DyeingDownTheHouseDB.prices[key] = {
			copper = math.floor(copper),
			seen = time(),
			source = source or "ah",
		}
	end
end

-- The stored unit price in copper, or nil if we've never scanned one.
function ns.GetPrice(key)
	local p = DyeingDownTheHouseDB.prices[key]
	return p and p.copper or nil
end

function ns.GetPriceInfo(key)
	return DyeingDownTheHouseDB.prices[key]
end

-- The gold value of everything the account holds of this item: total × unit price.
-- nil when there's no price to value it against (never guess it as zero — the UI
-- shows "—" instead).
function ns.GetValue(key)
	local price = ns.GetPrice(key)
	if not price then return nil end
	return ns.GetTotal(key) * price
end

-- Declared up here because the scanner reports on itself (skipped items, price
-- imports) long before the slash-command block below would have defined it.
local function Print(msg)
	print("|cffb388ffDyeing Down The House|r: " .. msg)
end
ns.Print = Print -- Prices.lua reports through the same prefix

--------------------------------------------------------------------------------
-- Auction House scanning
--
-- Since dyes went Warband-bound, a scan prices FLOWERS and nothing else — they're
-- the only half of the recipe still on the auction house. See BuildScanQueue.
--
-- Value is the volume-weighted average unit price of the cheapest ~N units on the
-- AH — what you'd realistically pay/get, not the single lowest listing (which can
-- be a tiny spiteful stack). Verified against C_AuctionHouse: flowers are
-- commodities, a commodity search returns its whole listing set in one
-- COMMODITY_SEARCH_RESULTS_UPDATED, each listing carrying unitPrice (copper) and
-- quantity.
--
-- ComputeMarketPrice is pure and unit-tested; the scan orchestration below drives
-- one throttled query per item while the player is at the AH.
--------------------------------------------------------------------------------

-- How many units of depth a price must have behind it to count. This skips a tiny
-- spiteful stack priced under the real market: we take the lowest price at which
-- at least this many units are available (cheapest-first), i.e. the price of the
-- Nth-cheapest unit.
ns.PRICE_MIN_DEPTH = ns.PRICE_MIN_DEPTH or 200

-- The market unit price: the lowest price backed by at least `minDepth` units.
-- Sort cheapest first, accumulate quantity, and return the price of the listing
-- where the running total reaches minDepth. If the whole market is thinner than
-- that, return the dearest listing (what it'd cost to clear it all). Returns the
-- copper price and the units counted; nil if there are no listings.
function ns.ComputeMarketPrice(listings, minDepth)
	minDepth = minDepth or ns.PRICE_MIN_DEPTH

	local sorted = {}
	for i = 1, #listings do sorted[i] = listings[i] end
	table.sort(sorted, function(a, b) return a.unitPrice < b.unitPrice end)

	local cumulative, lastPrice = 0, nil
	for _, l in ipairs(sorted) do
		lastPrice = l.unitPrice
		cumulative = cumulative + (l.quantity or 0)
		if cumulative >= minDepth then return l.unitPrice, cumulative end
	end

	if not lastPrice then return nil, 0 end
	return lastPrice, cumulative -- fewer than minDepth on the market
end

-- Pacing and recovery.
--
-- Blizzard's auction API is rate limited, and when you exceed it the server simply
-- DROPS the query: no results, no error event, nothing at all. The original scanner
-- was a pure event chain — send a query, wait for its reply, send the next — so one
-- dropped query stranded the entire run with no way out but closing the AH. That is
-- the "scan stops after 8-12 items" bug; that count is roughly one burst allowance
-- before the limiter bites.
--
-- Three defenses, since the limiter's state isn't directly observable:
--   * PACING — a floor on the gap between queries, on top of Blizzard's own
--     IsThrottledMessageSystemReady check.
--   * A WATCHDOG — if a reply doesn't arrive in time, retry the item; once the
--     retries are spent, count it skipped and move on. One bad item can no longer
--     strand the run.
--   * VERIFICATION — replies are matched against the item actually asked for, so a
--     late answer to an abandoned query can't be filed as another item's price.
ns.SCAN_INTERVAL = ns.SCAN_INTERVAL or 0.35 -- seconds between queries
ns.SCAN_TIMEOUT  = ns.SCAN_TIMEOUT  or 6    -- seconds to wait for a reply
ns.SCAN_RETRIES  = ns.SCAN_RETRIES  or 2    -- extra attempts before skipping an item
ns.SCAN_MAX_WAIT = ns.SCAN_MAX_WAIT or 40   -- throttle polls (0.5s each) before giving up

local scan = {
	active = false,
	queue = {},
	index = 0,
	itemID = nil,
	awaitingNext = false,
	token = 0,  -- bumped on every dispatch; a watchdog acts only if it still matches
	tries = 0,  -- attempts spent on the current item
	waits = 0,  -- consecutive throttle polls on the current item
	failed = 0, -- items given up on during this run
}
local ahOpen = false

function ns.IsAHOpen() return ahOpen end
function ns.IsScanning() return scan.active end

-- active, done, total, skipped
function ns.GetScanProgress()
	return scan.active, scan.index, #scan.queue, scan.failed
end

local function ReadCommodityListings(itemID)
	local listings = {}
	if type(C_AuctionHouse.GetNumCommoditySearchResults) ~= "function"
		or type(C_AuctionHouse.GetCommoditySearchResultInfo) ~= "function" then
		return listings
	end
	local ok, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
	n = (ok and tonumber(n)) or 0
	for i = 1, n do
		local ok, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
		if ok and type(r) == "table" and r.unitPrice and r.quantity then
			listings[#listings + 1] = { unitPrice = r.unitPrice, quantity = r.quantity }
		end
	end
	return listings
end

local function StoreScannedPrice(itemID)
	local entry = ns.byID[itemID]
	if not entry then return end
	local avg = ns.ComputeMarketPrice(ReadCommodityListings(itemID))
	if avg then ns.SetPrice(entry.key, avg, "ah") end
	-- No auctions at all -> leave any previous price alone rather than wipe it.
end

local scanFrame

-- These three call each other: a watchdog timeout advances the scan, which waits
-- for a clear throttle, which sends a query, which arms another watchdog. Declared
-- as plain locals first so none of them is a forward reference (see
-- tools/check_order.lua for why that matters in WoW's Lua).
local SendCurrentQuery, AdvanceScan, TryDispatch

-- Abandon whatever query is in flight, so no late reply and no armed watchdog can
-- act on it. Every state change that makes the in-flight query irrelevant calls this.
local function InvalidateInFlight()
	scan.token = scan.token + 1
end

local function FinishScan()
	InvalidateInFlight()
	scan.active = false
	scan.itemID = nil
	scan.awaitingNext = false
	DyeingDownTheHouseDB.lastScan = time() -- for the "scanned Xm ago" stamp
	-- Progress rode the floating overlay, so success stays silent. A partial scan
	-- does NOT: quietly pricing 40 of 60 flowers would leave cheapest-flower verdicts
	-- confidently wrong with nothing on screen to say so.
	if scan.failed > 0 then
		Print(("scan finished, but %d item%s never answered and %s skipped. Run it again to fill the gaps.")
			:format(scan.failed, scan.failed == 1 and "" or "s", scan.failed == 1 and "was" or "were"))
	end
	ns.Refresh()
end

-- Arm the watchdog for the query about to be sent. If no reply lands in time, retry
-- the same item; once its retries are spent, count it skipped and move on.
local function ArmWatchdog()
	local token = scan.token
	C_Timer.After(ns.SCAN_TIMEOUT, function()
		-- Answered already, or the scan moved on / stopped: nothing to do.
		if not scan.active or scan.token ~= token then return end
		if scan.tries <= ns.SCAN_RETRIES then
			SendCurrentQuery(true)
		else
			scan.failed = scan.failed + 1
			AdvanceScan()
		end
	end)
end

function SendCurrentQuery(isRetry)
	if not scan.active then return end
	local itemID = scan.queue[scan.index]
	if not itemID then FinishScan() return end

	scan.itemID = itemID
	scan.tries = isRetry and (scan.tries + 1) or 1
	InvalidateInFlight() -- any watchdog from a previous attempt is now stale

	local sorts
	if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
		sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	end

	local ok, itemKey = pcall(C_AuctionHouse.MakeItemKey, itemID)
	local sent = false
	if ok and itemKey then
		sent = pcall(C_AuctionHouse.SendSearchQuery, itemKey, sorts or {}, false)
	end

	if not sent then
		-- Couldn't even form or send the query; retrying won't help this one.
		scan.failed = scan.failed + 1
		AdvanceScan()
		return
	end

	ArmWatchdog()
	ns.Refresh()
end

-- Send the current item's query as soon as the throttle allows. Blizzard usually
-- wakes us with AUCTION_HOUSE_THROTTLED_SYSTEM_READY, but that event is not
-- guaranteed to arrive, so this also polls itself as a backstop.
function TryDispatch()
	if not (scan.active and scan.awaitingNext) then return end

	local ready = true
	if type(C_AuctionHouse.IsThrottledMessageSystemReady) == "function" then
		local ok, r = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
		ready = (not ok) or (r and true or false) -- an erroring check shouldn't block us
	end

	if ready then
		scan.awaitingNext = false
		SendCurrentQuery(false)
		return
	end

	scan.waits = scan.waits + 1
	if scan.waits > ns.SCAN_MAX_WAIT then
		-- Throttled for ~20s with no let-up. Skip rather than hang forever.
		scan.awaitingNext = false
		scan.failed = scan.failed + 1
		AdvanceScan()
		return
	end
	C_Timer.After(0.5, TryDispatch)
end

function AdvanceScan()
	if not scan.active then return end
	InvalidateInFlight()

	scan.index = scan.index + 1
	if scan.index > #scan.queue then FinishScan() return end

	scan.awaitingNext = true
	scan.waits = 0
	C_Timer.After(ns.SCAN_INTERVAL, TryDispatch)
	ns.Refresh()
end

-- The list of item IDs a scan will price, in order. Pure, so it's testable.
--   * FLOWERS only. Dyes are Warband-bound and can't be listed (ns.DYES_TRADEABLE),
--     so querying one is a guaranteed empty result — and on a rate-limited API,
--     spending half the run's queries on items that cannot have a price is worse
--     than useless: it's what pushes the flowers we DO need past the limiter.
--     (Pigments used to be skipped here too, as an intermediate nobody trades to
--     decide. 12.1 deleted them, so there's nothing left to skip.)
--   * flowers the player has unchecked in the config are skipped too — if they
--     aren't shown, there's no reason to spend a query pricing them;
--   * each id appears at most once.
function ns.BuildScanQueue(items)
	local queue, seen = {}, {}
	for _, entry in ipairs(items or ns.ITEMS) do
		local hidden = (entry.kind == "dye" and ns.IsDyeHidden(entry.key))
			or (entry.kind == "herb" and ns.IsHerbHidden(entry.name))
		if entry.id and ns.IsTradeable(entry)
			and not hidden and not seen[entry.id] then
			seen[entry.id] = true
			queue[#queue + 1] = entry.id
		end
	end
	return queue
end

-- Price everything by querying the auction house ourselves. This is the fallback
-- source: it's the only one that needs no other addon, but it's also the slow one
-- (one throttled query per item, and you have to be standing at the AH). Prices.lua
-- puts the faster sources in front of it.
function ns.StartAHScan(items)
	if scan.active then return false, "already scanning" end
	if not ahOpen or type(C_AuctionHouse) ~= "table" then
		return false, "open the Auction House first"
	end

	scan.queue = ns.BuildScanQueue(items)
	if #scan.queue == 0 then
		return false, "nothing to price: every flower is hidden"
	end

	scan.active = true
	scan.index = 0
	scan.tries = 0
	scan.waits = 0
	scan.failed = 0
	-- "Hold your brutosaurs…" now rides the floating overlay, not the chat frame.
	AdvanceScan()
	return true
end

-- Default entry point. Prices.lua replaces this with a dispatcher that can route to
-- Auctionator or TSM instead; assigning here means the AH scan still works on its
-- own if that file is ever absent or fails to load.
ns.StartScan = ns.StartAHScan

function ns.StopScan()
	InvalidateInFlight()
	scan.active = false
	scan.itemID = nil
	scan.awaitingNext = false
end

scanFrame = CreateFrame("Frame")
scanFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
scanFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
for _, ev in ipairs({
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_UPDATED",
	"AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}) do
	pcall(scanFrame.RegisterEvent, scanFrame, ev)
end

scanFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		ns.Refresh()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ahOpen = false
		ns.StopScan()
		ns.Refresh()
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		-- arg1 is the item the results belong to. A reply for anything other than the
		-- query in flight is a late answer to one we already timed out on — storing it
		-- would file one item's listings under another item's price.
		if scan.active and scan.itemID and (arg1 == nil or arg1 == scan.itemID) then
			StoreScannedPrice(scan.itemID)
			AdvanceScan()
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		-- One of our items turned out non-commodity: skip pricing, keep going.
		if scan.active then AdvanceScan() end
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		if scan.active and scan.awaitingNext then TryDispatch() end
	end
end)

--------------------------------------------------------------------------------
-- Recipes — the herbs -> dye chain
--
-- A dye is made from HERBS of its color, in one step at a Dye Station. Herbs of a
-- color form a fungible pool — any herb of the color makes that color's dye — so
-- the useful figure is the total herb count for the color, not per-herb.
--
-- This was a two-step chain until 12.1 (10 herbs -> 1 pigment -> 1 dye) and the
-- middle of it is gone. Nothing here counts a pigment any more, and the functions
-- kept their names because what they answer hasn't changed, only how many steps it
-- takes to answer it.
--------------------------------------------------------------------------------

-- The supply picture for one color: how many dyes the account already holds, how
-- many more it could make from its herb pool, and the herb breakdown.
function ns.GetColorSupply(color)
	local dye = ns.byKey[color]
	local ownedDyes = (dye and dye.kind == "dye") and ns.GetTotal(dye.key) or 0

	local perDye = ns.HERBS_PER_DYE

	-- A dye takes 10 of the SAME herb, so a color's yield is the sum of
	-- floor(count / 10) over each herb separately — NOT floor(total / 10). Odd
	-- remainders in different herbs can't be combined into a dye.
	local herbs = ns.herbsByColor[color] or {}
	local ownedHerbs, dyesFromHerbs, breakdown = 0, 0, {}
	for _, herb in ipairs(herbs) do
		local have = ns.GetTotal(herb.key)
		ownedHerbs = ownedHerbs + have
		dyesFromHerbs = dyesFromHerbs + math.floor(have / perDye)
		breakdown[#breakdown + 1] = {
			key = herb.key,
			name = herb.name or ("Item " .. tostring(herb.id)), -- pending a cached name
			have = have,
			-- The other colors this herb also feeds, so the UI can flag contention.
			colors = herb.colors or {},
		}
	end

	return {
		color = color,
		ownedDyes = ownedDyes,
		ownedHerbs = ownedHerbs,
		herbsPerDye = perDye,
		dyesFromHerbs = dyesFromHerbs,             -- makeable right now from flowers held
		makeableDyes = ownedDyes + dyesFromHerbs,  -- held + makeable
		herbs = breakdown,
	}
end

-- Status for one color against its goal. Treats this color's herbs in isolation
-- (dedicated to this dye); the cross-color contention — where a shared herb can't
-- feed two colors at once — is flagged in the row tooltip instead.
function ns.GetRecipeStatus(dyeKey)
	local dye = ns.byKey[dyeKey]
	if not dye or dye.kind ~= "dye" then return nil end

	local color = dye.color
	local supply = ns.GetColorSupply(color)
	local perDye = ns.HERBS_PER_DYE

	local owned = ns.GetTotal(dyeKey)
	local goal = ns.GetGoal(dyeKey)
	local shortfall = math.max(0, goal - owned)

	-- What's missing to hit the goal, and how many MORE herbs to gather for it.
	-- Current herbs already cover `dyesFromHerbs` of the shortfall, and because a dye
	-- takes 10 of the same herb, each dye beyond that needs a fresh stack of 10.
	local herbsNeeded = shortfall * perDye
	local herbsShort = math.max(0, shortfall - supply.dyesFromHerbs) * perDye

	return {
		key = dyeKey,
		color = color,
		owned = owned,
		goal = goal,
		shortfall = shortfall,
		ownedHerbs = supply.ownedHerbs,
		herbsPerDye = perDye,
		herbsNeeded = herbsNeeded,       -- herbs to make the whole shortfall
		herbsShort = herbsShort,         -- herbs still to gather/buy
		craftableNow = supply.dyesFromHerbs, -- dyes makeable right now from flowers held
		canCraftGoal = supply.dyesFromHerbs >= shortfall, -- can the flowers close the gap?
		herbs = supply.herbs,
		shades = ns.shadesByColor[color] or {},
	}
end

-- Craft breakdown for a color's expand view. One dye costs 10 of a SINGLE flower,
-- so making it via a flower costs 10 × that flower's unit price. Per flower:
-- how many you hold, how many dyes that makes, its craft cost, and whether it's the
-- cheapest route into this color. Flowers are ordered cheapest-to-craft first.
--
-- This used to be a craft-VS-BUY comparison. Warband-bound dyes killed the "buy"
-- half of it — there's no price to weigh crafting against, because crafting is the
-- only way to get one now. So the question the expand view answers changed from
-- "should I make this or buy it?" to "which flower should I make it out of?", which
-- is the one still worth asking. The comparison is now flower against flower.
function ns.GetCraftBreakdown(dyeKey)
	local dye = ns.byKey[dyeKey]
	if not dye or dye.kind ~= "dye" then return nil end

	local perDye = ns.HERBS_PER_DYE -- flowers per dye

	local hiddenHerbs = DyeingDownTheHouseDB.ui.hiddenHerbs or {}
	local flowers, cheapestCraft = {}, nil
	for _, herb in ipairs(ns.herbsByColor[dye.color] or {}) do
		-- Skip flowers the player has hidden (by name). No `goto` — WoW's Lua 5.1
		-- has no goto (luajit would accept it, so it'd pass tests and break in game).
		if not (herb.name and hiddenHerbs[herb.name:lower()]) then
			local have = ns.GetTotal(herb.key)
			local price = ns.GetPrice(herb.key)
			local craftCost = price and price * perDye or nil
			if craftCost and (not cheapestCraft or craftCost < cheapestCraft) then
				cheapestCraft = craftCost
			end
			flowers[#flowers + 1] = {
				key = herb.key,
				name = herb.name or ("Item " .. tostring(herb.id)),
				id = herb.id,
				have = have,
				dyesEach = math.floor(have / perDye),      -- dyes this flower alone can make
				price = price,                              -- flower unit price (nil if unscanned)
				craftCost = craftCost,                      -- 10 × price
				isCheapest = nil,                           -- filled in below
			}
		end
	end

	-- Cheapest craft cost first; unscanned flowers last; then name.
	table.sort(flowers, function(a, b)
		if (a.craftCost ~= nil) ~= (b.craftCost ~= nil) then return a.craftCost ~= nil end
		if a.craftCost and b.craftCost and a.craftCost ~= b.craftCost then return a.craftCost < b.craftCost end
		return a.name < b.name
	end)

	-- true = the cheapest way into this color, false = a dearer one, nil = unpriced.
	-- Ties all count as cheapest: two flowers at the same cost are equally right, and
	-- marking one of them the loser on sort order alone would be a lie.
	for _, fl in ipairs(flowers) do
		if fl.craftCost then fl.isCheapest = (fl.craftCost == cheapestCraft) end
	end

	return {
		key = dyeKey,
		color = dye.color,
		flowersPerDye = perDye,
		cheapestCraft = cheapestCraft, -- what this dye costs to make, via its best flower
		flowers = flowers,
	}
end

-- Which flower to actually use for this color, and why.
--
-- The reagent picker's green check answers this only once flower PRICES exist, and
-- there are two ordinary situations where they don't: a fresh install that hasn't
-- scanned, and a realm whose auction house is empty. In both, the addon knew
-- perfectly well what to recommend and said nothing — the flowers in your bags are
-- a fact, and no market is needed to read them.
--
-- So it answers in three tiers, best first:
--   held    a flower you already have ten or more of. Nothing to buy, and the most
--           of it wins, so you spend down the biggest pile first.
--   cheap   nothing held in quantity, but flowers are priced: the cheapest to buy.
--   short   nothing held and nothing priced: whichever you have most of, so the
--           answer is "keep picking this one" rather than a blank.
--
-- Returns nil only when the color has no flowers at all.
function ns.SuggestFlower(color)
	local perDye = ns.HERBS_PER_DYE
	local hiddenHerbs = DyeingDownTheHouseDB.ui.hiddenHerbs or {}

	local held, cheap, most
	for _, herb in ipairs(ns.herbsByColor[color] or {}) do
		if not (herb.name and hiddenHerbs[herb.name:lower()]) then
			local have = ns.GetTotal(herb.key)
			local price = ns.GetPrice(herb.key)
			local entry = {
				key = herb.key,
				name = herb.name or ("Item " .. tostring(herb.id)),
				id = herb.id,
				have = have,
				dyes = math.floor(have / perDye),
				price = price,
				cost = price and price * perDye or nil,
			}
			if entry.dyes > 0 and (not held or entry.have > held.have) then held = entry end
			if entry.cost and (not cheap or entry.cost < cheap.cost) then cheap = entry end
			if not most or entry.have > most.have then most = entry end
		end
	end

	if held then held.reason = "held"; return held end
	if cheap then cheap.reason = "cheap"; return cheap end
	if most then most.reason = "short"; return most end
	return nil
end

-- What one of this dye costs to make, in copper: 10 × the cheapest flower of its
-- color. nil when none of that color's flowers has been priced yet. This is what
-- the Cost column and the price sort read, and it's the closest thing a dye still
-- has to a number now that it can't be bought.
function ns.GetCraftCost(dyeKey)
	local dye = ns.byKey[dyeKey]
	if not dye or dye.kind ~= "dye" then return nil end

	local perDye = ns.HERBS_PER_DYE
	local hiddenHerbs = DyeingDownTheHouseDB.ui.hiddenHerbs or {}
	local cheapest
	for _, herb in ipairs(ns.herbsByColor[dye.color] or {}) do
		if not (herb.name and hiddenHerbs[herb.name:lower()]) then
			local price = ns.GetPrice(herb.key)
			if price and (not cheapest or price < cheapest) then cheapest = price end
		end
	end
	return cheapest and cheapest * perDye or nil
end

-- Is THIS flower the one to take to the station for `color`?
-- Returns true (cheapest route into the color — use this), false (a dearer flower
-- would do the same job for less), or nil (nothing of this color is priced yet, so
-- there's no honest answer and the picker shows no mark at all).
--
-- The comparison used to be against the dearest dye of the color — the most the
-- pigment could become. Warband-bound dyes have no price to be dearest, so the
-- check is now flower against flower: of everything that makes this color, which
-- costs least? A red X no longer means "don't bother", it means "there's a cheaper
-- flower in this list".
function ns.GetHerbCraftVerdict(herbKey, color)
	local herbPrice = ns.GetPrice(herbKey)
	if not herbPrice then return nil end

	local cheapest
	for _, herb in ipairs(ns.herbsByColor[color] or {}) do
		local p = ns.GetPrice(herb.key)
		if p and (not cheapest or p < cheapest) then cheapest = p end
	end
	if not cheapest then return nil end
	return herbPrice <= cheapest
end

-- Same, keyed by the herb's item ID.
function ns.GetHerbCraftVerdictByID(itemID, color)
	local entry = ns.byID[itemID]
	if not entry then return nil end
	return ns.GetHerbCraftVerdict(entry.key, color)
end

--------------------------------------------------------------------------------
-- Search filter and sort (pure, over the dye list)
--------------------------------------------------------------------------------

-- Dyes matching `query` (case-insensitive substring). A dye matches when the
-- needle is found in its own name, in its color-family name, OR in the name of any
-- SHADE of that family. Empty or nil query returns every dye, in Data.lua order.
--
-- That last one is what keeps the search useful after 12.1. There are only nine
-- items now, so searching them alone would be pointless — but the 77 color names
-- are what a player actually has in mind, and typing "obsidium" should land on
-- Black rather than find nothing. ns.MatchedShades gives the UI the specific
-- shades that matched, so it can show which ones they were.
local function ShadeMatch(color, needle)
	for _, shade in ipairs(ns.shadesByColor[color] or {}) do
		if shade.name:lower():find(needle, 1, true) then return true end
	end
	return false
end

function ns.FilterDyes(query)
	local out = {}
	local needle = query and query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, dye in ipairs(ns.DYES) do
		local match = not needle or needle == ""
			or dye.name:lower():find(needle, 1, true) and true
			or (dye.color and tostring(dye.color):lower():find(needle, 1, true)) and true
			or ShadeMatch(dye.color, needle)
		if match then
			out[#out + 1] = dye
		end
	end
	return out
end

-- The shades of `color` whose name contains the current search, or nil when there's
-- no search running. The UI uses this to pull matches to the top of an opened row.
function ns.MatchedShades(color, query)
	query = query or (DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui.search) or ""
	local needle = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if needle == "" then return nil end
	local out = {}
	for _, shade in ipairs(ns.shadesByColor[color] or {}) do
		if shade.name:lower():find(needle, 1, true) then out[#out + 1] = shade end
	end
	return out
end

-- A new list sorted by `mode` and `dir` ("asc"/"desc"). Sorts a COPY so the
-- caller's list is untouched. Name is always the tiebreaker, ascending.
--   "alpha" — by name
--   "owned" — by account-wide count
--   "price" — by what the dye costs to CRAFT (its cheapest flower × 10); dyes with
--             no priced flower always sort last, either direction. The mode keeps
--             its old name so saved sort preferences survive the change of meaning.
-- When `dir` is omitted, each mode's natural default is used (A–Z, most-owned,
-- highest-price), which is what keeps two-argument callers working.
-- Sortable columns and each one's natural default direction.
local VALID_SORT = {
	alpha = true, owned = true, goal = true, price = true,
	craft = true, craftherb = true, short = true,
}
local DEFAULT_DIR = {
	alpha    = "asc",   -- A–Z
	owned    = "desc",  -- most owned first
	goal     = "desc",  -- biggest goals first
	price    = "asc",   -- cheapest to craft first (it's a cost now, not a value)
	craft    = "desc",  -- most makeable first
	craftherb = "desc", -- most flowers held first
	short    = "desc",  -- most work outstanding first
}

-- The value(s) a mode sorts on, per dye: a primary and an optional secondary that
-- breaks ties before the name. `craftherb` (the Flowers column) ties by dyes
-- makeable, then by flowers HELD, so equal-makeable rows still read biggest-pile
-- first. Primary nil means "no value" (price only — unpriced sorts last).
--
-- `craftpig` was dropped with the pigments themselves. A saved preference naming it
-- falls through VALID_SORT to alpha rather than erroring, which is the right
-- outcome for a column that no longer exists.
local function MetricPair(mode, key)
	if mode == "owned" then return ns.GetTotal(key) end
	if mode == "goal"  then return ns.GetGoal(key) end
	if mode == "price" then return ns.GetCraftCost(key) end      -- may be nil
	if mode == "short" then
		local rc = ns.GetRecipeStatus(key)
		return rc and rc.shortfall or 0
	end
	if mode == "craft" or mode == "craftherb" then
		local rc = ns.GetRecipeStatus(key)
		if not rc then return 0, 0 end
		if mode == "craftherb" then return rc.ownedHerbs, rc.craftableNow end
		return rc.craftableNow, rc.ownedHerbs
	end
	return 0
end

function ns.SortDyes(list, mode, dir)
	if not VALID_SORT[mode] then mode = "alpha" end
	dir = dir or DEFAULT_DIR[mode]
	local asc = (dir == "asc")

	local out = {}
	for i = 1, #list do out[i] = list[i] end

	if mode == "alpha" then
		table.sort(out, function(a, b)
			if asc then return a.name < b.name else return a.name > b.name end
		end)
		return out
	end

	-- Numeric modes: precompute the metric pair once per dye (some, like craft, are
	-- not cheap), then sort. Name is always the final ascending tiebreak.
	local m1, m2 = {}, {}
	for _, d in ipairs(list) do m1[d.key], m2[d.key] = MetricPair(mode, d.key) end

	table.sort(out, function(a, b)
		local ma, mb = m1[a.key], m1[b.key]
		-- Price only: dyes with no price sink below priced ones, either direction.
		if mode == "price" and (ma ~= nil) ~= (mb ~= nil) then return ma ~= nil end
		ma, mb = ma or 0, mb or 0
		if ma ~= mb then if asc then return ma < mb else return ma > mb end end
		-- Secondary key (e.g. flowers held), same direction as the primary.
		local sa, sb = m2[a.key], m2[b.key]
		if sa and sb and sa ~= sb then if asc then return sa < sb else return sa > sb end end
		return a.name < b.name
	end)

	return out
end

-- What the window shows: the name filter, minus dyes the player has hidden, then
-- the current sort + direction. Reads the persisted ui.* so the UI and slash
-- commands share one path.
function ns.GetDisplayDyes()
	local ui = DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui or {}
	local hidden = ui.hiddenDyes or {}
	local shown = {}
	for _, d in ipairs(ns.FilterDyes(ui.search)) do
		-- `hideZero` drops colours you hold none of. A colour you have a GOAL for
		-- stays regardless: "hide what I have none of" cannot reasonably mean "hide
		-- the ones I still need", which is the list's whole purpose.
		local drop = hidden[d.key]
			or (ui.hideZero and ns.GetTotal(d.key) == 0 and ns.GetGoal(d.color) == 0)
		if not drop then shown[#shown + 1] = d end
	end
	return ns.SortDyes(shown, ui.sort, ui.sortDir)
end

--------------------------------------------------------------------------------
-- The By Dye tab
--
-- One row per SHADE — the 77 names you can actually paint with — because that's
-- where a goal gets typed. The family tab answers what those goals cost; this one
-- is where they're set.
--------------------------------------------------------------------------------

local VALID_SHADE_SORT = { alpha = true, family = true, goal = true }
local SHADE_DEFAULT_DIR = { alpha = "asc", family = "asc", goal = "desc" }

function ns.GetShadeSort()
	local ui = DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui or {}
	local mode = VALID_SHADE_SORT[ui.shadeSort] and ui.shadeSort or "alpha"
	return mode, ui.shadeSortDir or SHADE_DEFAULT_DIR[mode]
end

function ns.SetShadeSort(mode, dir)
	if not VALID_SHADE_SORT[mode] then return false end
	local ui = DyeingDownTheHouseDB.ui
	ui.shadeSort, ui.shadeSortDir = mode, dir or SHADE_DEFAULT_DIR[mode]
	ns.Refresh()
	return true
end

function ns.CycleShadeSort(mode)
	if not VALID_SHADE_SORT[mode] then return end
	local ui = DyeingDownTheHouseDB.ui
	if ui.shadeSort == mode then
		ui.shadeSortDir = (ui.shadeSortDir == "asc") and "desc" or "asc"
	else
		ui.shadeSort, ui.shadeSortDir = mode, SHADE_DEFAULT_DIR[mode]
	end
	ns.Refresh()
end

-- The shade rows the By Dye tab shows: the search applied, families the player has
-- hidden dropped, then sorted.
--
-- A shade of a hidden family is hidden too. Unticking Black means "I don't care
-- about black", and leaving its twelve shade names in the list while the family
-- itself is gone from the other tab would be the addon disagreeing with itself.
--
-- The "unattributed" remainder rides along as a row of its own wherever one
-- exists, so a migrated family goal can be seen and cleared rather than being a
-- number that only shows up in a total.
function ns.GetDisplayShades()
	local ui = DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui or {}
	local hidden = ui.hiddenDyes or {}
	local needle = (ui.search or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

	local order = {}
	for i, color in ipairs(ns.COLORS) do order[color] = i end

	local rows = {}
	for _, shade in ipairs(ns.SHADES or {}) do
		if shade.color and not hidden[shade.color] then
			local match = needle == ""
				or shade.name:lower():find(needle, 1, true)
				or shade.color:lower():find(needle, 1, true)
			if match then
				rows[#rows + 1] = {
					kind = "shade",
					name = shade.name,
					key = shade.key,
					color = shade.color,
					guess = shade.guess,
					goal = ns.GetShadeGoal(shade.name),
					index = order[shade.color] or 99,
				}
			end
		end
	end

	for _, color in ipairs(ns.COLORS) do
		local left = ns.GetUnassignedGoal(color)
		if left > 0 and not hidden[color] then
			local label = color:gsub("^%l", string.upper) .. " (unassigned)"
			if needle == "" or label:lower():find(needle, 1, true) then
				rows[#rows + 1] = {
					kind = "unassigned",
					name = label,
					color = color,
					goal = left,
					index = order[color] or 99,
				}
			end
		end
	end

	local mode, dir = ns.GetShadeSort()
	local asc = (dir == "asc")
	table.sort(rows, function(a, b)
		if mode == "goal" then
			if a.goal ~= b.goal then
				if asc then return a.goal < b.goal else return a.goal > b.goal end
			end
		elseif mode == "family" then
			if a.index ~= b.index then
				if asc then return a.index < b.index else return a.index > b.index end
			end
		elseif a.name ~= b.name then
			if asc then return a.name < b.name else return a.name > b.name end
		end
		return a.name < b.name
	end)
	return rows
end

--------------------------------------------------------------------------------
-- Opening a row
--
-- There used to be two tabs and two sort systems here, because a dye and a color
-- family were different things: flowers and pigment belonged to the family, counts
-- and goals to the dye. 12.1 made them the same thing, so both views collapsed
-- into the one list and all of that machinery went with them.
--
-- What's left is which rows are open. A row opens onto its flowers and, if the
-- player wants them, the color names that family covers.
--------------------------------------------------------------------------------

-- A color is open when the player opened it — or whenever a search is running. A
-- search that matched a shade but left every row shut would look like it had found
-- nothing at all, when the match is precisely the thing hidden inside the row.
function ns.IsColorExpanded(color)
	local ui = DyeingDownTheHouseDB.ui
	if (ui.search or "") ~= "" then return true end
	return ui.expanded[color] == true
end

function ns.ToggleColor(color)
	local ui = DyeingDownTheHouseDB.ui
	ui.expanded[color] = (not ui.expanded[color]) or nil
	ns.Refresh()
end

local VALID_TAB = { color = true, dye = true }

function ns.GetTab()
	local ui = DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui or {}
	return VALID_TAB[ui.tab] and ui.tab or "color"
end

function ns.SetTab(tab)
	if not VALID_TAB[tab] then return false end
	DyeingDownTheHouseDB.ui.tab = tab
	ns.Refresh()
	return true
end

function ns.SetAllColorsExpanded(open)
	local e = DyeingDownTheHouseDB.ui.expanded
	for _, color in ipairs(ns.COLORS) do e[color] = open and true or nil end
	ns.Refresh()
end

-- The craft breakdown for a whole color. One dye per color now, so this is just
-- GetCraftBreakdown under the name the UI calls it by. Kept as its own function
-- because "the flowers for this color" is what the expand view is actually asking,
-- and because a color key that names no dye should give nil rather than an error.
function ns.GetColorCraftBreakdown(color)
	local dye = ns.byKey[color]
	if not (dye and dye.kind == "dye") then return nil end
	return ns.GetCraftBreakdown(dye.key)
end

function ns.IsDyeHidden(key)
	return (DyeingDownTheHouseDB.ui.hiddenDyes[key] == true)
end

function ns.SetDyeHidden(key, hidden)
	DyeingDownTheHouseDB.ui.hiddenDyes[key] = hidden and true or nil
	ns.Refresh()
end

-- Show or hide every dye at once (the Check All / Uncheck All buttons).
function ns.SetAllDyesHidden(hidden)
	local h = DyeingDownTheHouseDB.ui.hiddenDyes
	for _, dye in ipairs(ns.DYES) do h[dye.key] = hidden and true or nil end
	ns.Refresh()
end

-- Flowers are hidden by NAME (so all of a flower's quality tiers hide together).
function ns.IsHerbHidden(name)
	return name ~= nil and DyeingDownTheHouseDB.ui.hiddenHerbs[name:lower()] == true
end

function ns.SetHerbHidden(name, hidden)
	if not name then return end
	DyeingDownTheHouseDB.ui.hiddenHerbs[name:lower()] = hidden and true or nil
	ns.Refresh()
end

function ns.SetAllHerbsHidden(hidden)
	local h = DyeingDownTheHouseDB.ui.hiddenHerbs
	for _, herb in ipairs(ns.HERBS) do
		if herb.name then h[herb.name:lower()] = hidden and true or nil end
	end
	ns.Refresh()
end

-- The distinct flower names (quality tiers collapsed), alphabetical — for the
-- "Flowers to show" checklist.
function ns.GetDistinctHerbNames()
	local seen, out = {}, {}
	for _, herb in ipairs(ns.HERBS) do
		if herb.name and not seen[herb.name] then
			seen[herb.name] = true
			out[#out + 1] = herb.name
		end
	end
	table.sort(out)
	return out
end

-- A string colored letter-by-letter across a rainbow, for the flashy title.
-- Spaces are left uncolored. Cheap enough to build once at login.
function ns.RainbowText(str)
	local function hsv(h)
		h = h % 1
		local i = math.floor(h * 6)
		local f = h * 6 - i
		local p, q, t = 0, 1 - f, f
		local r, g, b
		if i == 0 then r, g, b = 1, t, p
		elseif i == 1 then r, g, b = q, 1, p
		elseif i == 2 then r, g, b = p, 1, t
		elseif i == 3 then r, g, b = p, q, 1
		elseif i == 4 then r, g, b = t, p, 1
		else r, g, b = 1, p, q end
		return r, g, b
	end
	local letters = {}
	local n = #str
	for i = 1, n do
		local ch = str:sub(i, i)
		if ch == " " then
			letters[i] = " "
		else
			local r, g, b = hsv((i - 1) / math.max(1, n))
			letters[i] = ("|cff%02x%02x%02x%s|r"):format(
				math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), ch)
		end
	end
	return table.concat(letters)
end

function ns.SetSearch(text)
	DyeingDownTheHouseDB.ui.search = text or ""
	ns.Refresh()
end

function ns.GetSearch()
	return DyeingDownTheHouseDB.ui.search or ""
end

function ns.SetSort(mode, dir)
	if not VALID_SORT[mode] then return false end
	DyeingDownTheHouseDB.ui.sort = mode
	DyeingDownTheHouseDB.ui.sortDir = dir or DEFAULT_DIR[mode]
	ns.Refresh()
	return true
end

function ns.GetSort()
	local ui = DyeingDownTheHouseDB and DyeingDownTheHouseDB.ui or {}
	return ui.sort or "alpha", ui.sortDir or DEFAULT_DIR[ui.sort or "alpha"]
end

-- Header-click behavior: clicking the active column flips its direction; clicking
-- a different column switches to it at that column's natural default direction.
function ns.CycleSort(mode)
	if not VALID_SORT[mode] then return end
	local ui = DyeingDownTheHouseDB.ui
	if ui.sort == mode then
		ui.sortDir = (ui.sortDir == "asc") and "desc" or "asc"
	else
		ui.sort = mode
		ui.sortDir = DEFAULT_DIR[mode]
	end
	ns.Refresh()
end

-- Reset the list to its default view: no search, alphabetical A–Z.
function ns.ClearFilters()
	local ui = DyeingDownTheHouseDB.ui
	ui.search, ui.sort, ui.sortDir = "", "alpha", DEFAULT_DIR.alpha
	ns.Refresh()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- Said once, ever, on the first login after dyes went Warband-bound.
--
-- Prices for half the addon's items disappearing is exactly the kind of change that
-- reads as the addon having broken, and plenty of people don't read patch notes. So
-- it says what happened and what the numbers mean now — once, and then never again,
-- because the second telling is nagging. Only a profile that predates the patch has
-- the flag set (see Migrate): there's nothing to explain to someone who never saw a
-- dye price in the first place.
local function AnnounceWarbandDyes()
	if ns.DYES_TRADEABLE then return end
	if not DyeingDownTheHouseDB.warbandNoticePending then return end
	DyeingDownTheHouseDB.warbandNoticePending = false

	Print("heads up, housing dyes are |cffffd100Warband-bound|r now, in preparation for patch 12.1.")
	Print("scans price flowers only from here; this addon will stay updated as things change!")
end

local refreshPending = false

local function QueueRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.2, function()
		refreshPending = false
		ScanBags()
		ScanBank()
		-- After the scans: bags must be current before the cached figures can be
		-- checked against what the character can actually reach.
		ReconcileLive()
		ns.Refresh()
	end)
end

local frame = CreateFrame("Frame")

for _, event in ipairs({
	"ADDON_LOADED",
	"PLAYER_LOGIN",
	"BAG_UPDATE_DELAYED",
	"BANKFRAME_OPENED",
	"BANKFRAME_CLOSED",
}) do
	frame:RegisterEvent(event)
end

-- Legacy bank events that the 12.0 bank rework removed, and which throw on
-- RegisterEvent if the client no longer knows them. BAG_UPDATE_DELAYED already
-- covers bank containers on modern clients, so these are belt-and-braces for older
-- builds only — register them individually so one unknown name can't take the rest
-- of the block down with it.
for _, event in ipairs({
	"PLAYERBANKSLOTS_CHANGED",
	"PLAYERBANKBAGSLOTS_CHANGED",
}) do
	pcall(frame.RegisterEvent, frame, event)
end

-- Spending reagents on a craft or a work order can take them straight from the
-- Warband bank, which changes nothing in bags and so fires no bag event. These
-- give us a moment to re-check the live counts. Registered individually under
-- pcall because an event name the client doesn't know throws.
for _, event in ipairs({
	"ITEM_COUNT_CHANGED",
	"TRADE_SKILL_ITEM_CRAFTED_RESULT",
	"CRAFTINGORDERS_ORDER_PLACED",
	"CRAFTINGORDERS_CLAIMED_ORDER_UPDATED",
	"CRAFTINGORDERS_UPDATE_ORDER_COUNT",
}) do
	pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end

		-- Dev vs live saved variables. A DEV build carries "[DEV]" in its Title (the
		-- gitignored dev loader) and declares its own DyeingDownTheHouseDevDB, so dev experiments never
		-- touch a live profile and both copies can sit installed side by side.
		local isDev = C_AddOns and C_AddOns.GetAddOnMetadata
			and ((C_AddOns.GetAddOnMetadata(ADDON, "Title") or ""):find("%[DEV%]") ~= nil)
		if isDev then DyeingDownTheHouseDB = DyeingDownTheHouseDevDB end
		DyeingDownTheHouseDB = DyeingDownTheHouseDB or {}
		ApplyDefaults(DyeingDownTheHouseDB, defaults)
		-- Defaults are additive and harmless on any client; the MIGRATION is the
		-- one-way part, so it is the part an old client must not run. Skipping it
		-- leaves the profile exactly as 1.3.0 left it, still readable by 1.3.0.
		if ns.ClientSupported() then
			Migrate(DyeingDownTheHouseDB)
		end
		if isDev then DyeingDownTheHouseDevDB = DyeingDownTheHouseDB end   -- persist to the dev saved variable

		local name, realm = UnitFullName("player")
		realm = realm or GetRealmName()
		charKey = name .. "-" .. realm
		DyeingDownTheHouseDB.chars[charKey] = DyeingDownTheHouseDB.chars[charKey] or {}

		local char = DyeingDownTheHouseDB.chars[charKey]
		char.bags = char.bags or {}
		char.bank = char.bank or {}
		char.name = name
		char.realm = realm
		char.class = select(2, UnitClass("player"))

		-- Re-apply any item IDs learned by name matching in earlier sessions.
		for key, id in pairs(DyeingDownTheHouseDB.learned) do
			local entry = ns.byKey[key]
			if entry then
				entry.id = id
				ns.byID[id] = entry
			end
		end

		bagGroups = BuildBagGroups()

	elseif event == "PLAYER_LOGIN" then
		ns.BuildUI()
		-- After our own scan, so characters we can see for ourselves always win.
		ScanBags()
		RefreshBorrowed()
		ns.Refresh()
		if DyeingDownTheHouseDB.ui.shown then ns.Show() end
		AnnounceWarbandDyes()

	elseif event == "BANKFRAME_OPENED" then
		bankOpen = true
		QueueRefresh()

	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false
		ns.Refresh()

	else
		QueueRefresh()
	end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_DYEINGDOWNTHEHOUSE1 = "/dye"
SLASH_DYEINGDOWNTHEHOUSE2 = "/dyes"
SLASH_DYEINGDOWNTHEHOUSE3 = "/ddth"

SlashCmdList.DYEINGDOWNTHEHOUSE = function(msg)
	local cmd, rest = msg:lower():match("^(%S*)%s*(.-)$")
	-- The search term needs its original case preserved for display, so re-derive
	-- it from the untouched message rather than the lowercased copy.
	local _, rawRest = msg:match("^(%S*)%s*(.-)$")

	if cmd == "lock" then
		DyeingDownTheHouseDB.ui.locked = true
		Print("frame locked.")
	elseif cmd == "unlock" then
		DyeingDownTheHouseDB.ui.locked = false
		Print("frame unlocked — drag it anywhere.")
	elseif cmd == "reset" then
		DyeingDownTheHouseDB.ui.point, DyeingDownTheHouseDB.ui.relPoint = "CENTER", "CENTER"
		DyeingDownTheHouseDB.ui.x, DyeingDownTheHouseDB.ui.y, DyeingDownTheHouseDB.ui.scale = 0, 0, 1.0
		if ns.RestorePosition then ns.RestorePosition() end
		Print("position reset.")
	elseif cmd == "hidezero" then
		DyeingDownTheHouseDB.ui.hideZero = not DyeingDownTheHouseDB.ui.hideZero
		ns.Refresh()
		Print(("colors you hold none of are now %s on the By Color tab (ones with a goal always show)."):format(
			DyeingDownTheHouseDB.ui.hideZero and "hidden" or "shown"))
	elseif cmd == "search" or cmd == "find" then
		ns.SetSearch(rawRest)
		if rawRest == "" then
			Print("search cleared.")
		else
			Print(("filtering by \"%s\"."):format(rawRest))
		end
	elseif cmd == "sort" then
		if ns.SetSort(rest) then
			Print("sorting by " .. rest .. ".")
		else
			Print("usage: /dye sort <alpha | price | owned>")
		end
	elseif cmd == "tab" then
		if ns.SetTab(rest) then
			Print("showing the " .. rest .. " tab.")
		else
			Print("usage: /dye tab <color | dye>")
		end
	elseif cmd == "expand" or cmd == "collapse" then
		ns.SetAllColorsExpanded(cmd == "expand")
		Print(cmd == "expand" and "all colors opened." or "all colors closed.")
	elseif cmd == "options" or cmd == "config" then
		if ns.OpenOptions then ns.OpenOptions() end
	elseif cmd == "probe" then
		-- Undocumented on purpose (it isn't in /dye help): a development tool for
		-- reading the shape of Blizzard's 12.1 house dye panel, which moved and took
		-- our goal box with it. See Probe.lua.
		if ns.RunProbe then ns.RunProbe(rest) else Print("probe isn't loaded.") end
	elseif cmd == "scan" then
		local ok, err = ns.StartScan()
		if not ok then Print(err or "cannot scan right now.") end
	elseif cmd == "source" then
		if rest == "" then
			local current = ns.GetPriceSource and ns.GetPriceSource() or "auto"
			local using = ns.ResolvePriceSource and select(1, ns.ResolvePriceSource())
			Print(("price source: %s%s"):format(current,
				(current == "auto" and using) and (" (using " .. using.name .. ")") or ""))
			print("  available:")
			for _, s in ipairs(ns.GetAvailablePriceSources and ns.GetAvailablePriceSources() or {}) do
				print(("    %s — %s"):format(s.key, s.name))
			end
			print("  /dye source <auto | tsm | auctionator | blizzard>")
		elseif ns.SetPriceSource and ns.SetPriceSource(rest) then
			local using = select(1, ns.ResolvePriceSource())
			Print(("price source set to %s (using %s)."):format(rest, using.name))
		else
			Print("unknown source. Try: auto, tsm, auctionator, blizzard")
		end
	elseif cmd == "chars" then
		Print("characters contributing to the totals:")
		for _, c in ipairs(ns.GetScanInfo().chars) do
			local bags = ns.FormatAge(c.bagsSeen)
			local bank = ns.FormatAge(c.bankSeen)
			print(("  %s — bags %s, bank %s"):format(c.key, bags, bank))
		end
	elseif cmd == "forget" then
		if rest == "" then
			Print("usage: /dye forget <Name-Realm> (see /dye chars)")
		else
			local target
			for ck in pairs(DyeingDownTheHouseDB.chars) do
				if ck:lower() == rest then target = ck end
			end
			if not target then
				Print("no character matching '" .. rest .. "'. Try /dye chars.")
			elseif target == ns.GetCharKey() then
				Print("can't forget the character you're logged into.")
			else
				DyeingDownTheHouseDB.chars[target] = nil
				ns.Refresh()
				Print("forgot " .. target .. ".")
			end
		end
	elseif cmd == "help" then
		Print("commands:")
		print("  /dye — toggle the window")
		print("  /dye search <text> — filter by color or by a shade name like \"obsidium\" (blank clears)")
		print("  /dye sort <alpha | price | owned> — change the order (price = cost to make)")
		print("  /dye scan — price the flowers from your chosen price source")
		print("  /dye source [auto|tsm|auctionator|blizzard] — where prices come from")
		print("  /dye tab <color | dye> — switch between the totals and the color names")
		print("  /dye expand | collapse — open or close every color")
		print("  /dye hidezero — toggle hiding colors you have no dye of")
		print("  /dye lock | unlock — freeze or free the frame")
		print("  /dye reset — recenter the frame")
		print("  /dye options — open the settings panel")
		print("  /dye chars — list characters and when they were last scanned")
		print("  /dye forget <Name-Realm> — drop a deleted character's data")
	else
		if ns.Toggle then ns.Toggle() end
	end
end

-- Addon Compartment (the button on the minimap's addon list).
function DyeingDownTheHouse_OnAddonCompartmentClick()
	if ns.Toggle then ns.Toggle() end
end
