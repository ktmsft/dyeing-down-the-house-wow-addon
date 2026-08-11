-- Stub harness: runs Data.lua + Core.lua against a fake WoW API.
--
-- Run it with:  luajit tests/test_dyeingdownthehouse.lua   (from anywhere)
--
-- The addon folder is resolved from this script's own location rather than
-- hardcoded, so the suite travels with the repo.
--
-- Data.lua now carries real IDs, read from the game rather than guessed.
-- never guessed). So the counting/recipe/filter/sort logic is proven against a
-- FIXTURE dataset injected below — fake keys and fake item IDs, but the exact
-- shape the real data will take. When real data lands, these tests keep guarding
-- the logic; a separate data-sanity test can then guard the data.
local SEP = package.config:sub(1, 1)
local HERE = (arg and arg[0] or ""):match("^(.*[/\\])") or ("." .. SEP)
local DIR = HERE .. ".." .. SEP

local failures, checks = 0, 0
local function check(name, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(("FAIL  %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
	else
		print(("ok    %s = %s"):format(name, tostring(got)))
	end
end

--------------------------------------------------------------------------------
-- Fake WoW API
--------------------------------------------------------------------------------

Enum = { BagIndex = {
	Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
	CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8,
	CharacterBankTab_4 = 9, CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
	AccountBankTab_1 = 12, AccountBankTab_2 = 13, AccountBankTab_3 = 14,
	AccountBankTab_4 = 15, AccountBankTab_5 = 16,
	Bank = -1, Keyring = -2, Reagentbank = -3,
} }

-- itemID -> name, for the fake GetItemInfo. Fake IDs (9000xx) — test-only.
local ITEM_NAMES = {
	-- dyes: one per color, the 12.1 shape
	[900001] = "Red Housing Dye",   [900002] = "Green Housing Dye",
	[900003] = "Blue Housing Dye",  [900004] = "White Housing Dye",
	-- herbs
	[900101] = "Rose",     -- red only
	[900102] = "Poppy",    -- red + blue (an overlapping herb)
	[900103] = "Iris",     -- blue only
	[900104] = "Mystivine",-- a herb with no ID in the fixture, to be learned
	[900999] = "Red Housing Dye", -- a name collision: a different item sharing a name
	[6948]   = "Hearthstone",
}

-- bagID -> { [slot] = {itemID, count} }
local BAGS = {}
local bankAccessible = false

local function bagIsBankSide(bag) return bag >= 6 end

C_Container = {
	GetContainerNumSlots = function(bag)
		if bag < 0 then return 0 end -- legacy containers report empty on modern clients
		if bagIsBankSide(bag) and not bankAccessible then return 0 end
		return BAGS[bag] and 36 or 0
	end,
	GetContainerItemInfo = function(bag, slot)
		if bagIsBankSide(bag) and not bankAccessible then return nil end
		local e = BAGS[bag] and BAGS[bag][slot]
		if not e then return nil end
		return { itemID = e[1], stackCount = e[2], hyperlink = "|Hitem:" .. e[1] .. "|h" }
	end,
}

-- name -> id, for the fake GetItemInfoInstant (built from ITEM_NAMES). Only the
-- first id wins for a name shared by two items, mirroring a client cache.
local ID_BY_NAME = {}
for id, name in pairs(ITEM_NAMES) do
	ID_BY_NAME[name] = ID_BY_NAME[name] or id
end
-- A couple of the fixture items are deliberately left UNCACHED, so the harvester's
-- "unresolved" path is exercised.
local UNCACHED = { ["Blue Dye Pigment"] = true }

C_Item = {
	GetItemInfo = function(query)
		-- Real C_Item.GetItemInfo accepts an item link, an item name, or a numeric
		-- item ID; the stub handles a link, a bare numeric id, and a plain name.
		local id = tonumber(query) or tonumber(tostring(query):match("item:(%d+)"))
		if id then return ITEM_NAMES[id] end
		if type(query) == "string" then return ID_BY_NAME[query] and query or nil end
		return nil
	end,
	GetItemInfoInstant = function(query)
		if type(query) == "string" then
			if UNCACHED[query] then return nil end
			return ID_BY_NAME[query]
		end
		return tonumber(query)
	end,
	GetItemIconByID = function() return 12345 end,
}

-- Fake profession API. 12.1 removed the dye recipes from the crafting book
-- entirely, so nothing in the addon reads these any more -- they're left as a stub
-- purely so a stray call can't nil-index during a load.
C_TradeSkillUI = {
	GetBaseProfessionInfo = function() return { professionName = "Inscription" } end,
	GetAllRecipeIDs = function() return { 5001, 5002 } end,
	GetRecipeInfo = function(rid)
		return { recipeID = rid, name = "unused" }
	end,
	GetRecipeSchematic = function(rid)
		if rid == 5001 then
			return {
				recipeID = 5001, name = "Red Dye Pigment",
				outputItemID = 900201, quantityMin = 1, quantityMax = 1,
				reagentSlotSchematics = {
					{ reagents = { { itemID = 900101 } }, quantityRequired = 10, reagentType = 1 },
				},
			}
		else
			return {
				recipeID = 5002, name = "unused",
				outputItemID = 900001, quantityMin = 1, quantityMax = 1,
				reagentSlotSchematics = {
					{ reagents = { { itemID = 900201 } }, quantityRequired = 1, reagentType = 1 },
				},
			}
		end
	end,
}

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function RunTimers()
	local t = timers; timers = {}
	for _, fn in ipairs(t) do fn() end
end

time = os.time -- WoW exposes this as a global; stock Lua does not

function UnitFullName() return "Riker", "Enterprise" end
function UnitClass() return "Warrior", "WARRIOR" end
function GetRealmName() return "Enterprise" end

-- Core creates two frames — the bag/bank watcher and the auction scanner — and the
-- real client delivers an event to every frame listening for it. Keeping only the
-- last handler meant the scanner's events were unreachable, so its whole state
-- machine went untested. Dispatch to all of them, like the client does.
local handlers = {}
function CreateFrame()
	return {
		RegisterEvent = function() end,
		UnregisterEvent = function() end,
		SetScript = function(_, script, fn)
			if script == "OnEvent" then handlers[#handlers + 1] = fn end
		end,
	}
end
local function Fire(event, arg1)
	for _, fn in ipairs(handlers) do fn(nil, event, arg1) end
end

--------------------------------------------------------------------------------
-- Fake auction house.
--
-- The important knob is which items ever ANSWER a query. An item absent from
-- `ahListings` (or excluded by the driver below) simply never replies — which is
-- exactly what Blizzard's rate limiter does when it silently drops a query, and is
-- the case that used to hang the scan forever.
--------------------------------------------------------------------------------

local ahSent = {}       -- every query actually sent, in order
local ahListings = {}   -- [itemID] = { { unitPrice =, quantity = }, ... }
local ahThrottled = false

C_AuctionHouse = {
	MakeItemKey = function(itemID) return { itemID = itemID } end,
	SendSearchQuery = function(itemKey)
		ahSent[#ahSent + 1] = itemKey.itemID
		return true
	end,
	IsThrottledMessageSystemReady = function() return not ahThrottled end,
	GetNumCommoditySearchResults = function(itemID) return #(ahListings[itemID] or {}) end,
	GetCommoditySearchResultInfo = function(itemID, i) return (ahListings[itemID] or {})[i] end,
}

SlashCmdList = {}

--------------------------------------------------------------------------------
-- Load addon
--------------------------------------------------------------------------------

local ns = {}
assert(loadfile(DIR .. "Data.lua"))("DyeingDownTheHouse", ns)
assert(loadfile(DIR .. "Core.lua"))("DyeingDownTheHouse", ns)
assert(loadfile(DIR .. "Discover.lua"))("DyeingDownTheHouse", ns)
assert(loadfile(DIR .. "Prices.lua"))("DyeingDownTheHouse", ns)

--------------------------------------------------------------------------------
-- Data sanity: validate the REAL Data.lua (before fixtures replace it below).
--
-- 12.1 shape: nine dye items (one per color), no pigments, 77 shades that are NOT
-- items, and the herb table carried over with teal folded into blue.
--
-- The dye IDs are deliberately allowed to be nil here. They are not published
-- anywhere yet and the file's rule is that an ID is read from the game or it does
-- not ship, so "no ID" is a legitimate state that Core's name-matching covers. What
-- IS checked is that every dye has a NAME, because that fallback is the only thing
-- holding counting up until the IDs land.
--------------------------------------------------------------------------------
print("-- Real Data.lua sanity --")
do
	ns.RebuildLookups() -- build lookups over the real Data.lua tables
	local keySeen, idSeen, dupKey, dupID = {}, {}, 0, 0
	local isColor = {}
	for _, c in ipairs(ns.COLORS) do isColor[c] = true end
	for _, e in ipairs(ns.ITEMS) do
		if keySeen[e.key] then dupKey = dupKey + 1 end
		keySeen[e.key] = true
		if e.id then
			if idSeen[e.id] then dupID = dupID + 1 end
			idSeen[e.id] = true
		end
	end

	-- Dyes: one per color, keyed BY color, and every one of them named.
	local dyeBadColor, dyeKeyNotColor, dyeNoName, colorHasDye = 0, 0, 0, {}
	for _, d in ipairs(ns.DYES) do
		if not isColor[d.color] then dyeBadColor = dyeBadColor + 1 end
		if d.key ~= d.color then dyeKeyNotColor = dyeKeyNotColor + 1 end
		if not d.name or d.name == "" then dyeNoName = dyeNoName + 1 end
		colorHasDye[d.color] = true
	end
	local coveredByDye = 0
	for _, c in ipairs(ns.COLORS) do if colorHasDye[c] then coveredByDye = coveredByDye + 1 end end

	-- Herbs: an id, at least one color, and every color it feeds must be real.
	local herbNoId, herbNoColor, herbBadColor = 0, 0, 0
	for _, hb in ipairs(ns.HERBS) do
		if not hb.id then herbNoId = herbNoId + 1 end
		if not hb.colors or #hb.colors == 0 then herbNoColor = herbNoColor + 1 end
		for _, c in ipairs(hb.colors or {}) do
			if not isColor[c] then herbBadColor = herbBadColor + 1 end
		end
	end

	-- Shades: a name, a real family, and no duplicate names.
	local shadeBadColor, shadeDupName, shadeNames = 0, 0, {}
	for _, sh in ipairs(ns.SHADES) do
		if not isColor[sh.color] then shadeBadColor = shadeBadColor + 1 end
		if shadeNames[sh.name] then shadeDupName = shadeDupName + 1 end
		shadeNames[sh.name] = true
	end

	check("no duplicate keys in Data.lua", dupKey, 0)
	check("no duplicate item IDs in Data.lua", dupID, 0)
	check("9 dyes present", #ns.DYES, 9)
	check("9 colors present", #ns.COLORS, 9)
	check("teal is retired", isColor.teal, nil)
	check("no pigment table any more", ns.PIGMENTS, nil)
	check("every dye's color is a real color", dyeBadColor, 0)
	check("every dye is keyed by its color", dyeKeyNotColor, 0)
	check("every dye has a name to match on", dyeNoName, 0)
	check("every color has a dye", coveredByDye, 9)
	check("77 shades present", #ns.SHADES, 77)
	check("every shade has a real family", shadeBadColor, 0)
	check("no duplicate shade names", shadeDupName, 0)
	check("96 herb item IDs present", #ns.HERBS, 96)
	check("every herb has an id", herbNoId, 0)
	check("every herb has >=1 color", herbNoColor, 0)
	check("every herb color is a real color", herbBadColor, 0)
	-- every color is fed by at least one herb (no empty supply pool)
	local colorHasHerb = {}
	for _, hb in ipairs(ns.HERBS) do
		for _, c in ipairs(hb.colors or {}) do colorHasHerb[c] = true end
	end
	local colorsCovered = 0
	for _, c in ipairs(ns.COLORS) do if colorHasHerb[c] then colorsCovered = colorsCovered + 1 end end
	check("all 9 colors have herbs", colorsCovered, 9)
	-- Shades whose family is inferred rather than read from the game. This number is
	-- a REMINDER, not a rule: it should fall to 0 as the PTR confirms each one, and
	-- the test failing when it does is the point -- it forces the count to be
	-- updated deliberately rather than drifting.
	local guessed = 0
	for _, sh in ipairs(ns.SHADES) do if sh.guess then guessed = guessed + 1 end end
	check("shades still awaiting confirmation", guessed, 9)
end

-- Core must be self-sufficient without the UI layer: UI.lua / Options.lua load
-- AFTER Core in the TOC and can be absent (or fail), so Core defaults every UI
-- hook to a no-op. This is the in-game bug that a bag event fired a refresh timer
-- into a nil ns.Refresh. Assert the defaults exist BEFORE we stub anything — the
-- stubs below would otherwise mask exactly this.
print("-- Core runs without the UI layer --")
check("ns.Refresh defaulted", type(ns.Refresh), "function")
check("ns.BuildUI defaulted", type(ns.BuildUI), "function")
check("ns.Show defaulted", type(ns.Show), "function")
check("ns.Toggle defaulted", type(ns.Toggle), "function")

-- Stand in for UI.lua (overrides the no-op defaults; identical behavior, but lets
-- a test observe calls if it needs to).
ns.BuildUI = function() end
ns.Refresh = function() end
ns.Show = function() end

--------------------------------------------------------------------------------
-- Inject the fixture dataset (Data.lua ships empty)
--------------------------------------------------------------------------------

-- Four colors, so the sort tests still have something to order. Green and white
-- have no herbs on purpose: an empty supply pool is a real state (nothing in the
-- game guarantees you hold a flower for every color) and the maths has to survive
-- it rather than divide by zero or drop the row.
ns.COLORS = { "red", "blue", "green", "white" }

-- Keyed BY color, exactly like the shipped table. `white` deliberately has no item
-- ID, mirroring Data.lua before anyone has read the IDs off the PTR -- so the
-- name-matching path is exercised on a dye and not only on a herb.
ns.DYES = {
	{ key = "red",   name = "Red Housing Dye",   id = 900001, color = "red" },
	{ key = "green", name = "Green Housing Dye", id = 900002, color = "green" },
	{ key = "blue",  name = "Blue Housing Dye",  id = 900003, color = "blue" },
	{ key = "white", name = "White Housing Dye", color = "white" },
}

-- Shades are not items. `Plain` carries the guess flag so the "unconfirmed family"
-- path has something to report.
ns.SHADES = {
	{ name = "Crimson", color = "red" },
	{ name = "Scarlet", color = "red" },
	{ name = "Azure",   color = "blue" },
	{ name = "Plain",   color = "blue", guess = true },
	{ name = "Moss",    color = "green" },
}

ns.HERBS = {
	{ key = "rose",      name = "Rose",   id = 900101, colors = { "red" } },
	{ key = "poppy",     name = "Poppy",  id = 900102, colors = { "red", "blue" } }, -- overlap
	{ key = "iris",      name = "Iris",   id = 900103, colors = { "blue" } },
	{ key = "mystivine", name = "Mystivine", colors = { "red" } }, -- no id: learned by name
}

ns.RebuildLookups()

--------------------------------------------------------------------------------
-- Counting scenario. Herbs and a pigment live in bags (so they count anywhere);
-- the red dye is spread across bags, character bank and the Warband bank to exercise
-- the cache. poppy is a red+blue overlap herb.
--------------------------------------------------------------------------------

BAGS[0]  = { [1] = { 900001, 10 }, [2] = { 6948, 1 }, [5] = { 900001, 5 } } -- 15 red dye, split
BAGS[1]  = { [1] = { 900101, 25 }, [2] = { 900102, 4 } }                    -- 25 rose, 4 poppy
BAGS[2]  = { [1] = { 900103, 100 } }                                        -- 100 iris
BAGS[6]  = { [1] = { 900001, 50 } }                                         -- character bank
BAGS[12] = { [1] = { 900001, 400 } }                                        -- warband bank

Fire("ADDON_LOADED", "DyeingDownTheHouse")
Fire("PLAYER_LOGIN")

print("\n-- Away from bank (never visited) --")
check("red dye total (bags only)", ns.GetTotal("red"), 15)
check("HasBankData", ns.HasBankData(), false)
check("rose total (bags)", ns.GetTotal("rose"), 25)
check("iris total (bags)", ns.GetTotal("iris"), 100)
check("hearthstone not tracked", ns.byID[6948], nil)

print("\n-- At the bank --")
bankAccessible = true
Fire("BANKFRAME_OPENED")
RunTimers()
check("red dye total (bags+bank+warband)", ns.GetTotal("red"), 465)
check("HasBankData", ns.HasBankData(), true)

print("\n-- Walked away: bank numbers must persist from cache --")
bankAccessible = false
Fire("BANKFRAME_CLOSED")
Fire("BAG_UPDATE_DELAYED")
RunTimers()
check("red dye total still cached", ns.GetTotal("red"), 465)

print("\n-- Name collision: a different item sharing 'Red Housing Dye' must NOT count --")
BAGS[4] = { [1] = { 900999, 99 } }
Fire("BAG_UPDATE_DELAYED")
RunTimers()
check("red dye total ignores the collision item", ns.GetTotal("red"), 465)
check("red dye id unchanged", ns.byID[900001].id, 900001)
check("collision item did not get learned", DyeingDownTheHouseDB.learned.red, nil)
BAGS[4] = nil

print("\n-- Learning an item ID by name (herb with no ID in the fixture) --")
BAGS[4] = { [1] = { 900104, 8 } } -- Mystivine, id absent from HERBS
Fire("BAG_UPDATE_DELAYED")
RunTimers()
check("mystivine learned its id", ns.byKey.mystivine.id, 900104)
check("learned id recorded for next session", DyeingDownTheHouseDB.learned.mystivine, 900104)
check("mystivine now counts", ns.GetTotal("mystivine"), 8)
BAGS[4] = nil -- remove it again so red herb supply returns to a clean 29
Fire("BAG_UPDATE_DELAYED")
RunTimers()

print("\n-- A dye with no ID yet is still learned by name --")
-- This is the state Data.lua actually ships in: nine dyes, no IDs. The white dye
-- has none in the fixture, so seeing one in a bag has to resolve it by name or
-- nothing about white would ever count.
BAGS[4] = { [1] = { 900004, 7 } } -- White Housing Dye
Fire("BAG_UPDATE_DELAYED")
RunTimers()
check("white dye learned its id", ns.byKey.white.id, 900004)
check("white dye now counts", ns.GetTotal("white"), 7)
check("learned id recorded for next session", DyeingDownTheHouseDB.learned.white, 900004)
BAGS[4] = nil
Fire("BAG_UPDATE_DELAYED"); RunTimers()

print("\n-- Goals --")
ns.SetGoal("red", 500)
check("goal set", ns.GetGoal("red"), 500)
ns.SetGoal("red", 0)
check("goal cleared by 0", ns.GetGoal("red"), 0)
ns.SetGoal("red", "abc")
check("goal cleared by junk", ns.GetGoal("red"), 0)

--------------------------------------------------------------------------------
-- Color supply and the herb overlap
--
-- Holdings: rose 25 (red), poppy 4 (red+blue), iris 100 (blue), 465 red dye.
--   red  herbs = rose 25 + poppy 4  = 29  -> floor(25/10)+floor(4/10)  = 2 dyes
--   blue herbs = poppy 4 + iris 100 = 104 -> floor(4/10)+floor(100/10) = 10 dyes
-- poppy's 4 count toward BOTH colors — that's the overlap the game double-counts.
--------------------------------------------------------------------------------

print("\n-- Color supply (a dye needs 10 of the SAME herb) --")
local red = ns.GetColorSupply("red")
check("red owned herbs (rose 25 + poppy 4)", red.ownedHerbs, 29)
-- per-herb floors: floor(25/10) + floor(4/10) = 2 + 0 = 2
check("red dyes makeable from flowers (per-herb floors)", red.dyesFromHerbs, 2)
check("red dyes already held", red.ownedDyes, 465)
check("red makeable (held+from flowers)", red.makeableDyes, 467)

local blue = ns.GetColorSupply("blue")
check("blue owned herbs (poppy 4 + iris 100)", blue.ownedHerbs, 104)
-- floor(4/10) + floor(100/10) = 0 + 10 = 10
check("blue dyes makeable from flowers", blue.dyesFromHerbs, 10)

print("\n-- A color with no flowers at all --")
local none = ns.GetColorSupply("green")
check("green has no flowers", none.ownedHerbs, 0)
check("green makes nothing", none.dyesFromHerbs, 0)
check("green still reports a herb list", type(none.herbs), "table")

print("\n-- Same-herb rule: sub-10 stacks of different herbs don't combine --")
BAGS[4] = { [1] = { 900104, 8 } } -- 8 mystivine (red); red now 25 rose + 4 poppy + 8 mystivine = 37
Fire("BAG_UPDATE_DELAYED"); RunTimers()
local redX = ns.GetColorSupply("red")
check("red flowers total is 37", redX.ownedHerbs, 37)
-- a fungible pool would give floor(37/10)=3; same-herb gives 2+0+0 = 2.
check("makeable stays 2, not 3 (no mixed-herb dye)", redX.dyesFromHerbs, 2)
BAGS[4] = nil
Fire("BAG_UPDATE_DELAYED"); RunTimers()

print("\n-- Overlap: poppy feeds both colors' herb pools --")
local function herbInSupply(supply, key)
	for _, h in ipairs(supply.herbs) do if h.key == key then return h.have end end
	return nil
end
check("poppy counted in red supply", herbInSupply(red, "poppy"), 4)
check("poppy counted in blue supply", herbInSupply(blue, "poppy"), 4)

--------------------------------------------------------------------------------
-- Per-dye recipe status (the pigment chain)
--------------------------------------------------------------------------------

print("\n-- Recipe: goal reachable from the flowers on hand --")
-- blue owned 0, goal 8; blue flowers make 10.
ns.SetGoal("blue", 8)
local rs = ns.GetRecipeStatus("blue")
check("blue color", rs.color, "blue")
check("blue shortfall", rs.shortfall, 8)
check("herbs needed for the shortfall (8*10)", rs.herbsNeeded, 80)
check("dyes makeable now from blue flowers", rs.craftableNow, 10)
check("goal IS makeable", rs.canCraftGoal, true)
check("no more flowers needed", rs.herbsShort, 0)
ns.SetGoal("blue", 0)

print("\n-- Recipe: goal beyond the flowers on hand --")
-- green owned 0, goal 3, and green has no flowers at all.
ns.SetGoal("green", 3)
rs = ns.GetRecipeStatus("green")
check("goal NOT makeable", rs.canCraftGoal, false)
check("herbs needed (3*10)", rs.herbsNeeded, 30)
check("herbs still short (nothing on hand)", rs.herbsShort, 30)
ns.SetGoal("green", 0)

print("\n-- Recipe: flowers on hand cover part of the gap --")
-- blue goal 14, flowers make 10 -> 4 short, each needing a fresh stack of 10.
ns.SetGoal("blue", 14)
rs = ns.GetRecipeStatus("blue")
check("goal not makeable at 14", rs.canCraftGoal, false)
check("herbs still short ((14-10)*10)", rs.herbsShort, 40)
ns.SetGoal("blue", 0)

print("\n-- Recipe status carries the shades the color paints --")
local rsh = ns.GetRecipeStatus("blue")
check("blue lists its shades", #rsh.shades, 2)

print("\n-- Recipe status is dye-only --")
check("nil for a herb key", ns.GetRecipeStatus("rose"), nil)
check("nil for an unknown key", ns.GetRecipeStatus("nope"), nil)
check("nil for a shade name", ns.GetRecipeStatus("Crimson"), nil)

--------------------------------------------------------------------------------
-- Search filter
--------------------------------------------------------------------------------

print("\n-- Filter by name --")
check("empty query returns every dye", #ns.FilterDyes(""), 4)
check("nil query returns every dye", #ns.FilterDyes(nil), 4)
check("'housing dye' matches all (shared suffix)", #ns.FilterDyes("housing dye"), 4)
check("'gree' matches green only", #ns.FilterDyes("gree"), 1)
check("match is the right dye", ns.FilterDyes("gree")[1].key, "green")
check("case-insensitive", ns.FilterDyes("GREE")[1].key, "green")
check("leading/trailing space trimmed", ns.FilterDyes("  whit  ")[1].key, "white")
check("no match returns empty", #ns.FilterDyes("zzz"), 0)

print("\n-- Filter by SHADE name (the search that matters after 12.1) --")
-- There are only nine items now, so searching item names alone would be useless.
-- "Crimson" is not a dye, not a color and not a herb -- a hit can only have come
-- from the shade list, which is the whole point.
check("'crimson' finds its family", #ns.FilterDyes("crimson"), 1)
check("and the family is red", ns.FilterDyes("crimson")[1].key, "red")
check("shade search is case-insensitive", ns.FilterDyes("CRIMSON")[1].key, "red")
check("partial shade name works", ns.FilterDyes("azu")[1].key, "blue")
check("a shade that matches nothing", #ns.FilterDyes("chartreuse"), 0)

print("\n-- MatchedShades reports which shades matched --")
local ms = ns.MatchedShades("red", "crimson")
check("one red shade matched", #ms, 1)
check("and it is Crimson", ms[1].name, "Crimson")
check("no search -> nil, not an empty list", ns.MatchedShades("red", ""), nil)
check("a family with no match returns empty", #ns.MatchedShades("blue", "crimson"), 0)

--------------------------------------------------------------------------------
-- Sort
--------------------------------------------------------------------------------

print("\n-- Sort alphabetical --")
local function keys(list)
	local out = {}
	for i, d in ipairs(list) do out[i] = d.key end
	return table.concat(out, ",")
end
check("alpha order", keys(ns.SortDyes(ns.DYES, "alpha")), "blue,green,red,white")
check("unknown mode falls back to alpha", keys(ns.SortDyes(ns.DYES, "wat")), "blue,green,red,white")
-- craftpig was dropped with the pigments. A profile that saved it must degrade to
-- alpha rather than error or sort on nothing.
check("retired craftpig mode falls back to alpha", keys(ns.SortDyes(ns.DYES, "craftpig")), "blue,green,red,white")

print("\n-- Sort by number owned --")
-- Owned: red 465, the rest 0. Zeros tie-break by name: Blue, Green, White.
check("owned order (red leads, zeros by name)",
	keys(ns.SortDyes(ns.DYES, "owned")), "red,blue,green,white")

print("\n-- Prices and value --")
ns.SetPrice("rose", 5000)
check("GetPrice reads back", ns.GetPrice("rose"), 5000)
check("GetValue = total * price", ns.GetValue("rose"), 25 * 5000)
check("GetValue nil when unpriced", ns.GetValue("iris"), nil)
check("SetPrice(nil) clears", (function() ns.SetPrice("rose", nil); return ns.GetPrice("rose") end)(), nil)

print("\n-- AH market price: lowest price with >= minDepth units behind it --")
-- deep cheap market: 500 @ 31g -> reaches depth in the first listing -> 31g.
check("deep cheap market -> its price", ns.ComputeMarketPrice({ { unitPrice = 310000, quantity = 500 } }, 200), 310000)
-- spiteful 5 @ 1g under a real 30g wall: the 5 don't reach 200, so we move on -> 30g.
local spite = { { unitPrice = 10000, quantity = 5 }, { unitPrice = 300000, quantity = 2000 } }
check("spiteful low stack skipped", ns.ComputeMarketPrice(spite, 200), 300000)
-- the price of the 200th cheapest unit: 100@10g + 100@20g reaches 200 at 20g.
local depth = { { unitPrice = 100000, quantity = 100 }, { unitPrice = 200000, quantity = 100 } }
check("price of the 200th unit", ns.ComputeMarketPrice(depth, 200), 200000)
-- thinner than minDepth: only 50 on the market -> the dearest (to clear it all).
local thin = { { unitPrice = 10000, quantity = 5 }, { unitPrice = 300000, quantity = 45 } }
check("thin market -> dearest listing", ns.ComputeMarketPrice(thin, 200), 300000)
check("units counted is returned", (select(2, ns.ComputeMarketPrice(depth, 200))), 200)
check("no listings -> nil", ns.ComputeMarketPrice({}, 200), nil)

print("\n-- Craft breakdown: which flower to make this color out of (10 = 1 dye) --")
-- A dye has no price to weigh against (Warband-bound), so the comparison is flower
-- against flower: rose 400 -> 4000 a dye, poppy 600 -> 6000. Rose wins.
ns.SetPrice("rose", 400)
ns.SetPrice("poppy", 600)
local cb = ns.GetCraftBreakdown("red")
check("cheapest craft = 10 x cheapest flower (rose)", cb.cheapestCraft, 4000)
check("flowers per dye", cb.flowersPerDye, 10)
-- flowers ordered cheapest first: rose (4000) before poppy (6000); unscanned last.
check("cheapest flower first", cb.flowers[1].key, "rose")
check("rose craft cost = 10 x 400", cb.flowers[1].craftCost, 4000)
check("rose is the cheapest route", cb.flowers[1].isCheapest, true)
check("poppy craft cost = 10 x 600", cb.flowers[2].craftCost, 6000)
check("poppy NOT cheapest (false, not nil)", cb.flowers[2].isCheapest, false)
-- an unscanned flower (mystivine) has nil price -> nil verdict, sorts last
local last = cb.flowers[#cb.flowers]
check("unscanned flower has no craft cost", last.craftCost, nil)
check("unscanned flower verdict is nil", last.isCheapest, nil)

print("\n-- Which flower to actually use --")
-- The station's advice has to work with NO prices at all: a fresh install hasn't
-- scanned, and an empty realm auction house never will. What is in the bags is a
-- fact either way, so the recommendation is graded rather than withheld.
ns.SetPrice("rose", nil); ns.SetPrice("poppy", nil)
-- Holdings: rose 25, poppy 4. Only rose reaches ten.
local pick = ns.SuggestFlower("red")
check("recommends a flower with no prices at all", pick ~= nil, true)
check("picks the one there is enough of", pick.name, "Rose")
check("...and says why", pick.reason, "held")
check("...and how many it makes", pick.dyes, 2)

print("\n-- Most held wins, so the biggest pile goes first --")
BAGS[4] = { [1] = { 900102, 60 } } -- 60 poppy, beating rose's 25
Fire("BAG_UPDATE_DELAYED"); RunTimers()
check("the bigger pile is recommended", ns.SuggestFlower("red").name, "Poppy")
BAGS[4] = nil
Fire("BAG_UPDATE_DELAYED"); RunTimers()

print("\n-- Nothing held in quantity: fall back to cheapest priced --")
-- Drop iris below ten so neither blue flower qualifies on holdings.
BAGS[2] = { [1] = { 900103, 5 } }
Fire("BAG_UPDATE_DELAYED"); RunTimers()
ns.SetPrice("poppy", 900)
ns.SetPrice("iris", 100)
local cheap = ns.SuggestFlower("blue")
check("falls back to the cheapest to buy", cheap.name, "Iris")
check("...and says so", cheap.reason, "cheap")
check("...with the cost of one dye", cheap.cost, 1000)

print("\n-- Nothing held, nothing priced: name the closest anyway --")
ns.SetPrice("poppy", nil); ns.SetPrice("iris", nil)
local short = ns.SuggestFlower("blue")
check("still answers rather than going blank", short ~= nil, true)
check("names the one you have most of", short.name, "Iris")
check("...flagged as short", short.reason, "short")

print("\n-- A color with no flowers has nothing to suggest --")
check("nil rather than a made-up answer", ns.SuggestFlower("green"), nil)

print("\n-- Hidden flowers are never recommended --")
ns.SetHerbHidden("Iris", true)
check("a hidden flower is skipped", ns.SuggestFlower("blue").name, "Poppy")
ns.SetHerbHidden("Iris", false)
BAGS[2] = { [1] = { 900103, 100 } }
Fire("BAG_UPDATE_DELAYED"); RunTimers()
-- Put back the prices the sections below were written against.
ns.SetPrice("rose", 400); ns.SetPrice("poppy", 600)
ns.SetPrice("iris", nil)

print("\n-- GetCraftCost is what the Cost column reads --")
check("red costs 10 x its cheapest flower", ns.GetCraftCost("red"), 4000)
check("a color with no priced flower has no cost", ns.GetCraftCost("green"), nil)
check("nil for a herb key", ns.GetCraftCost("rose"), nil)

print("\n-- Station verdict: is this the flower to bring for the color? --")
check("rose is the one to bring for red", ns.GetHerbCraftVerdict("rose", "red"), true)
check("poppy is not (rose is cheaper)", ns.GetHerbCraftVerdict("poppy", "red"), false)
-- Ties both count as cheapest: equally right, and picking a loser on sort order
-- alone would be a lie.
ns.SetPrice("poppy", 400)
check("a tie counts as cheapest too", ns.GetHerbCraftVerdict("poppy", "red"), true)
ns.SetPrice("poppy", 600)
ns.SetPrice("rose", nil)
check("unknown flower price -> nil verdict", ns.GetHerbCraftVerdict("rose", "red"), nil)
ns.SetPrice("rose", 400)
check("by item ID resolves to the same verdict", ns.GetHerbCraftVerdictByID(900101, "red"), true)

print("\n-- Hidden flowers drop from the craft breakdown --")
local flowersBefore = #ns.GetCraftBreakdown("red").flowers -- red: rose, poppy, mystivine
ns.SetHerbHidden("Rose", true)
check("hiding a flower removes it", #ns.GetCraftBreakdown("red").flowers, flowersBefore - 1)
check("IsHerbHidden is case-insensitive", ns.IsHerbHidden("rose"), true)
ns.SetHerbHidden("Rose", false)
check("unhiding restores it", #ns.GetCraftBreakdown("red").flowers, flowersBefore)
check("distinct herb names (rose/poppy/iris/mystivine)", #ns.GetDistinctHerbNames(), 4)
ns.SetAllHerbsHidden(true)
check("hide all flowers -> empty breakdown", #ns.GetCraftBreakdown("red").flowers, 0)
ns.SetAllHerbsHidden(false)
ns.SetPrice("rose", nil); ns.SetPrice("poppy", nil)

print("\n-- Rainbow text --")
local rt = ns.RainbowText("ab c")
check("rainbow adds color codes", rt:find("|cff", 1, true) ~= nil, true)
check("rainbow keeps the space", rt:find(" ", 1, true) ~= nil, true)

print("\n-- Scan queue prices flowers only --")
-- Dyes are Warband-bound, so a query for one is a guaranteed empty answer on a
-- rate-limited API. Nothing that isn't a flower belongs in the queue.
do
	local queue = ns.BuildScanQueue()
	local nonHerb = 0
	for _, id in ipairs(queue) do
		local e = ns.byID[id]
		if not e or e.kind ~= "herb" then nonHerb = nonHerb + 1 end
	end
	check("queue is flowers and nothing else", nonHerb, 0)
end

print("\n-- Sort by price (cost to make; unpriced sinks last) --")
-- rose 400 -> red costs 4000. Nothing else has a priced flower.
ns.SetPrice("rose", 400)
check("price asc (cheapest to make first, unpriced last)",
	keys(ns.SortDyes(ns.DYES, "price", "asc")), "red,blue,green,white")
check("price desc still keeps unpriced last",
	keys(ns.SortDyes(ns.DYES, "price", "desc")), "red,blue,green,white")
ns.SetPrice("rose", nil)

print("\n-- SortDyes does not mutate the caller's list --")
check("original DYES order preserved", keys(ns.DYES), "red,green,blue,white")

print("\n-- Sort direction (asc/desc) --")
check("alpha asc", keys(ns.SortDyes(ns.DYES, "alpha", "asc")), "blue,green,red,white")
check("alpha desc reverses", keys(ns.SortDyes(ns.DYES, "alpha", "desc")), "white,red,green,blue")
-- owned: red 465, rest 0. desc = red first; asc = red last.
check("owned desc (default)", keys(ns.SortDyes(ns.DYES, "owned")), "red,blue,green,white")
check("owned asc puts the big holding last", keys(ns.SortDyes(ns.DYES, "owned", "asc")), "blue,green,white,red")

print("\n-- Sort by goal --")
ns.SetGoal("red", 5)
ns.SetGoal("blue", 10)
-- goal desc: blue 10, red 5, then the two 0-goal by name.
check("goal desc (biggest first)", keys(ns.SortDyes(ns.DYES, "goal")), "blue,red,green,white")

print("\n-- Sort by shortfall --")
-- red owns 465 against a goal of 5, so it is not short at all; blue owns 0 of 10.
check("short desc (most outstanding first)", keys(ns.SortDyes(ns.DYES, "short")), "blue,green,red,white")
ns.SetGoal("red", 0)
ns.SetGoal("blue", 0)

print("\n-- Sort by makeable-now --")
-- red flowers -> 2 dyes; blue flowers -> 10; green and white have none.
check("craft desc (most makeable first)", keys(ns.SortDyes(ns.DYES, "craft")), "blue,red,green,white")
check("craft asc (least first)", keys(ns.SortDyes(ns.DYES, "craft", "asc")), "green,white,red,blue")

print("\n-- Flowers sort, and its tiebreak --")
-- craftherb sorts on flowers HELD: blue 104, red 29.
check("sort by flowers held", keys(ns.SortDyes(ns.DYES, "craftherb")), "blue,red,green,white")
-- +76 rose gives red 105 flowers against blue's 104, so red takes the lead.
BAGS[4] = { [1] = { 900101, 76 } }
Fire("BAG_UPDATE_DELAYED"); RunTimers()
local rr = ns.GetColorSupply("red")
check("red now makes 10 from flowers", rr.dyesFromHerbs, 10)
check("more flowers held leads", keys(ns.SortDyes(ns.DYES, "craftherb")), "red,blue,green,white")
BAGS[4] = nil
Fire("BAG_UPDATE_DELAYED"); RunTimers()

print("\n-- CycleSort toggles direction on repeat, resets on switch --")
ns.SetSort("alpha", "asc")
ns.CycleSort("alpha")
check("same column flips to desc", select(2, ns.GetSort()), "desc")
ns.CycleSort("alpha")
check("and back to asc", select(2, ns.GetSort()), "asc")
ns.CycleSort("owned")
local m, d = ns.GetSort()
check("switching column sets that column", m, "owned")
check("switching uses the column default dir", d, "desc")

print("\n-- ClearFilters resets to the default view --")
ns.SetSearch("dye")
ns.SetSort("price", "asc")
ns.ClearFilters()
check("search cleared", ns.GetSearch(), "")
local cm, cd = ns.GetSort()
check("sort back to alpha", cm, "alpha")
check("direction back to asc", cd, "asc")

print("\n-- Per-color hide list --")
ns.SetDyeHidden("blue", true)
check("hidden color is dropped from the display", keys(ns.SortDyes(ns.GetDisplayDyes(), "alpha")), "green,red,white")
check("IsDyeHidden true", ns.IsDyeHidden("blue"), true)
check("IsDyeHidden false for others", ns.IsDyeHidden("red"), false)
ns.SetDyeHidden("blue", false)
check("unhidden dye returns", #ns.GetDisplayDyes(), 4)
ns.SetAllDyesHidden(true)
check("hide all -> empty display", #ns.GetDisplayDyes(), 0)
ns.SetAllDyesHidden(false)
check("show all -> full display", #ns.GetDisplayDyes(), 4)

print("\n-- Scan queue honours hide lists --")
do
	local function hasid(list, id)
		for _, v in ipairs(list) do if v == id then return true end end
		return false
	end
	ns.SetAllDyesHidden(false)
	ns.SetAllHerbsHidden(false)
	local full = ns.BuildScanQueue()
	local n0 = #full
	check("queue excludes dyes (Warband-bound)", hasid(full, 900001), false)
	check("queue includes a herb (rose)", hasid(full, 900101), true)

	ns.SetHerbHidden("Rose", true) -- name lookup is case-insensitive
	local filtered = ns.BuildScanQueue()
	check("hidden herb excluded from scan", hasid(filtered, 900101), false)
	check("one fewer item queued", #filtered, n0 - 1)

	ns.SetHerbHidden("Rose", false)
	check("unhiding restores the queue", #ns.BuildScanQueue(), n0)
end

print("\n-- Display path honours persisted search + sort --")
ns.SetSearch("housing dye")
check("SetSort validates", ns.SetSort("owned"), true)
check("SetSort rejects junk", ns.SetSort("sideways"), false)
check("display uses stored filter+sort", keys(ns.GetDisplayDyes()), "red,blue,green,white")
ns.SetSearch("")
ns.SetSort("alpha")

--------------------------------------------------------------------------------
-- Account-wide: log in an alt
--------------------------------------------------------------------------------

print("\n-- Alt logs in: its bags must join the account total --")
local rikerTotal = ns.GetTotal("red")

function UnitFullName() return "Troi", "Enterprise" end
function UnitClass() return "Priest", "PRIEST" end

BAGS[0] = { [1] = { 900001, 12 } } -- Troi's bags
BAGS[1] = nil
BAGS[6] = nil                      -- Troi has never opened her bank

Fire("ADDON_LOADED", "DyeingDownTheHouse")
Fire("PLAYER_LOGIN")

check("current char is now Troi", ns.GetCharKey(), "Troi-Enterprise")
check("account total = Riker's cache + Troi's bags", ns.GetTotal("red"), rikerTotal + 12)

local bd = ns.GetBreakdown("red")
check("two characters listed", #bd.chars, 2)
check("current char sorts first", bd.chars[1].isCurrent, true)
check("current char is Troi", bd.chars[1].name, "Troi")
check("Troi bags", bd.chars[1].bags, 12)
check("Troi bank", bd.chars[1].bank, 0)
check("Riker still counted while offline", bd.chars[2].total, 65) -- 15 bags + 50 bank
check("warband counted once, not per char", bd.warband, 400)
check("breakdown total matches GetTotal", bd.total, ns.GetTotal("red"))

print("\n-- Warband is shared: Troi's bank visit replaces, not adds --")
bankAccessible = true
BAGS[12] = { [1] = { 900001, 400 } } -- same shared warband
Fire("BANKFRAME_OPENED")
RunTimers()
check("warband still 400, not 800", ns.GetBreakdown("red").warband, 400)
check("warbandSeenBy updated", DyeingDownTheHouseDB.warbandSeenBy, "Troi-Enterprise")
bankAccessible = false
Fire("BANKFRAME_CLOSED")

print("\n-- Scan freshness --")
local info = ns.GetScanInfo()
check("scan info covers both chars", #info.chars, 2)
check("warbandSeen recorded", type(info.warbandSeen), "number")
check("FormatAge(nil)", (ns.FormatAge(nil)), "never")
check("FormatAge(now)", (ns.FormatAge(time())), "just now")
check("FormatAge(-90s)", (ns.FormatAge(time() - 90)), "1 minute ago")
check("FormatAge(-2h)", (ns.FormatAge(time() - 7200)), "2 hours ago")
check("FormatAge(-3d)", (ns.FormatAge(time() - 259200)), "3 days ago")

print("\n-- Goals are account-wide, shared across characters --")
ns.SetGoal("red", 500)
check("goal visible from alt", ns.GetGoal("red"), 500)
ns.SetGoal("red", 0)

--------------------------------------------------------------------------------
-- Optional DataStore support
--------------------------------------------------------------------------------

print("\n-- Without DataStore, nothing changes --")
check("no DataStore detected", ns.HasDataStore(), false)
check("no borrowed characters", ns.GetBorrowedCount(), 0)

local totalBefore = ns.GetTotal("red")
local warbandBefore = ns.GetBreakdown("red").warband

print("\n-- With DataStore providing an alt we've never seen --")

strsplit = function(sep, str)
	local out = {}
	for piece in str:gmatch("([^" .. sep .. "]+)") do out[#out + 1] = piece end
	return unpack(out)
end

local DS_CHARS = {
	["Default.Enterprise.Crusher"] = { [900001] = { 10, 5, 2 } }, -- bags, bank, reagent
	["Default.Enterprise.Troi"]    = { [900001] = { 999, 999, 999 } }, -- we already know Troi
}

DataStore = {
	IterateCharacters = function(_, callback)
		for key in pairs(DS_CHARS) do callback(key, key) end
	end,
	GetContainerItemCount = function(_, id, itemID)
		local row = DS_CHARS[id] and DS_CHARS[id][itemID]
		if not row then return 0, 0, 0 end
		return row[1], row[2], row[3]
	end,
}

Fire("PLAYER_LOGIN")

check("DataStore now detected", ns.HasDataStore(), true)
check("borrowed only the unseen character", ns.GetBorrowedCount(), 1)

local bd2 = ns.GetBreakdown("red")
local crusher
for _, c in ipairs(bd2.chars) do
	if c.name == "Crusher" then crusher = c end
end
check("borrowed character appears", crusher ~= nil, true)
check("bags include the reagent bag", crusher and crusher.bags, 12) -- 10 + 2
check("bank kept separate", crusher and crusher.bank, 5)
check("flagged as borrowed", crusher and crusher.fromDataStore, true)
check("total grew by exactly the borrowed amount", ns.GetTotal("red"), totalBefore + 17)
check("warband unchanged by DataStore", ns.GetBreakdown("red").warband, warbandBefore)

print("\n-- A character we scan ourselves is never taken from DataStore --")
local troi
for _, c in ipairs(bd2.chars) do
	if c.name == "Troi" then troi = c end
end
check("Troi is not flagged as borrowed", troi and troi.fromDataStore, false)
check("Troi's bags are our scan, not DataStore's 999", troi and troi.bags, 12)

print("\n-- A broken DataStore must not break the addon --")
DataStore = {
	IterateCharacters = function() error("DataStore exploded") end,
	GetContainerItemCount = function() return 0, 0, 0 end,
}
check("login survives a throwing DataStore", pcall(Fire, "PLAYER_LOGIN"), true)
check("falls back to no borrowed data", ns.GetBorrowedCount(), 0)
check("totals back to our own", ns.GetTotal("red"), totalBefore)

DataStore = nil

--------------------------------------------------------------------------------
-- Spending on crafting / selling — reconcile against live counts
--------------------------------------------------------------------------------

print("\n-- Spending from the Warband bank (bags untouched) --")

DyeingDownTheHouseDB.chars = {}
DyeingDownTheHouseDB.warband = {}
function UnitFullName() return "Riker", "Enterprise" end
BAGS[0] = { [1] = { 900001, 30 } }
BAGS[1], BAGS[2], BAGS[3] = nil, nil, nil -- clear leftover herbs/pigment
BAGS[6] = { [1] = { 900001, 100 } }
BAGS[12] = { [1] = { 900001, 400 } }
bankAccessible = true
Fire("ADDON_LOADED", "DyeingDownTheHouse")
Fire("PLAYER_LOGIN")
Fire("BANKFRAME_OPENED")
RunTimers()
bankAccessible = false
Fire("BANKFRAME_CLOSED")

check("starting total", ns.GetTotal("red"), 530) -- 30 + 100 + 400

-- The character can reach bags + own bank + Warband = 530. Spend 150 from the
-- Warband bank via a work order: bags don't change, only the live count reveals it.
local liveCount = 530 - 150
C_Item.GetItemCount = function(itemID)
	if itemID == 900001 then return liveCount end
	return 0
end

Fire("BAG_UPDATE_DELAYED")
RunTimers()

check("total drops by what was spent", ns.GetTotal("red"), 380)
check("bags untouched — nothing left them", ns.GetBreakdown("red").chars[1].bags, 30)

local after = ns.GetBreakdown("red")
check("own bank absorbed the shortfall first", after.chars[1].bank, 0)
check("warband took only the remainder", after.warband, 350) -- 400 - (150 - 100)

print("\n-- Reconciling never inflates --")
liveCount = 99999
Fire("BAG_UPDATE_DELAYED")
RunTimers()
check("a larger live count changes nothing", ns.GetTotal("red"), 380)

print("\n-- No live API means no reconciliation, not a crash --")
C_Item.GetItemCount = nil
check("survives without the API", pcall(function()
	Fire("BAG_UPDATE_DELAYED")
	RunTimers()
end), true)
check("totals untouched", ns.GetTotal("red"), 380)

--------------------------------------------------------------------------------
-- Price sources (Prices.lua) and scan recovery (Core.lua)
--
-- The regression that matters most here: a scan must never be able to hang.
-- Blizzard drops auction queries once you exceed its rate limit — no results, no
-- error — and the old scanner was a pure event chain with no timeout, so a single
-- dropped reply stranded the run partway through. Reported in the wild as "the
-- scan stops after 8 or 12 items".
--------------------------------------------------------------------------------

-- Record what the addon says to the player, while still echoing it. Core prints
-- through a file-local helper onto the global print, so tapping `print` is the only
-- way to see it — stubbing ns.Print would miss everything Core itself reports.
local said = {}
do
	local realPrint = print
	print = function(...)
		said[#said + 1] = tostring((...))
		realPrint(...)
	end
end

-- Did the addon say `needle` while `fn` ran?
local function SaidWhile(needle, fn)
	local mark = #said
	fn()
	for i = mark + 1, #said do
		if said[i]:find(needle, 1, true) then return true end
	end
	return false
end

DyeingDownTheHouseDB.ui.hiddenDyes = {}
DyeingDownTheHouseDB.ui.hiddenHerbs = {}

print("\n-- Price source selection --")

Auctionator, TSM_API = nil, nil
DyeingDownTheHouseDB.priceSource = "auto"
check("no price addon -> the built-in scan", (ns.ResolvePriceSource()).key, "blizzard")
check("the built-in scan is not instant", (ns.ResolvePriceSource()).instant, false)

-- Auctionator's real contract: (callerID string, itemID number) -> copper. It
-- raises on a bad callerID or a non-number itemID, so getting either wrong would
-- take our scan down with it — the stub enforces both.
local AUCTIONATOR_PRICES = { [900001] = 5000, [900101] = 400 }
Auctionator = { API = { v1 = {
	GetAuctionPriceByItemID = function(callerID, itemID)
		if type(callerID) ~= "string" then error("Auctionator: callerID must be a string") end
		if type(itemID) ~= "number" then error("Auctionator: itemID must be a number") end
		return AUCTIONATOR_PRICES[itemID]
	end,
} } }
check("Auctionator installed -> preferred over scanning", (ns.ResolvePriceSource()).key, "auctionator")
check("Auctionator is an instant source", (ns.ResolvePriceSource()).instant, true)

local tsmAsked = {}
-- Flower prices only. TSM has nothing to say about a Warband-bound dye, and the
-- import must not ask -- 900001 is here precisely so a stray ask would show up as
-- an unexpected extra price.
local TSM_PRICES = { ["i:900001"] = 5500, ["i:900102"] = 900, ["i:900101"] = 420 }
TSM_API = {
	ToItemString = function(link) return link end,
	GetCustomPriceValue = function(key, itemString)
		tsmAsked[#tsmAsked + 1] = key
		return TSM_PRICES[itemString]
	end,
}
check("TSM outranks Auctionator in auto", (ns.ResolvePriceSource()).key, "tsm")

ns.SetPriceSource("auctionator")
check("a pinned source beats the preference order", (ns.ResolvePriceSource()).key, "auctionator")
check("pinning an installed source is not a fallback", select(2, ns.ResolvePriceSource()), false)

Auctionator = nil
check("pinned but uninstalled falls back instead of failing", (ns.ResolvePriceSource()).key, "tsm")
check("...and reports that it fell back", select(2, ns.ResolvePriceSource()), true)
check("the preference itself is left alone", ns.GetPriceSource(), "auctionator")

check("an unknown source key is rejected", ns.SetPriceSource("nonsense"), false)

print("\n-- Which items a price update covers --")

DyeingDownTheHouseDB.priceSource = "auto" -- TSM
local priceable, sawDye = 0, false
for _, entry in ipairs(ns.ITEMS) do
	if ns.ShouldPriceEntry(entry) then
		priceable = priceable + 1
		if entry.kind == "dye" then sawDye = true end
	end
end
check("Warband-bound dyes are never priced", sawDye, false)
check("a dye is not priceable", ns.ShouldPriceEntry(ns.byKey.red), false)
check("a flower is", ns.ShouldPriceEntry(ns.byKey.rose), true)

ns.SetHerbHidden("Iris", true)
check("a hidden flower is skipped", ns.ShouldPriceEntry(ns.byKey.iris), false)
ns.SetHerbHidden("Iris", false)

print("\n-- Importing from TSM --")

DyeingDownTheHouseDB.prices = {}
tsmAsked = {}
local priced, missing = ns.ImportPrices()
check("priced every flower TSM knew", priced, 2)
check("the rest are counted, not invented", missing, priceable - 2)
check("rose took TSM's price", ns.GetPrice("rose"), 420)
check("poppy took TSM's price", ns.GetPrice("poppy"), 900)
check("the dye TSM had a price for was never asked", ns.GetPrice("red"), nil)
check("an item TSM never saw stays unpriced", ns.GetPrice("iris"), nil)
check("the price records where it came from", ns.GetPriceInfo("rose").source, "tsm")
check("TSM was asked with the configured key", tsmAsked[1], "DBMarket")

DyeingDownTheHouseDB.tsmPriceKey = "DBMinBuyout"
tsmAsked = {}
ns.ImportPrices()
check("changing the TSM price key is honored", tsmAsked[1], "DBMinBuyout")
DyeingDownTheHouseDB.tsmPriceKey = "DBMarket"

-- An import must not need an auction house — that's the whole point of it.
check("importing works away from the AH", ns.IsAHOpen(), false)
check("...and StartScan routes to it", select(1, ns.StartScan()), true)

print("\n-- A price source that throws cannot take the addon down --")

TSM_API.GetCustomPriceValue = function() error("TSM exploded") end
DyeingDownTheHouseDB.prices = {}
local survived, gotPriced = pcall(ns.ImportPrices)
check("an erroring source is survivable", survived, true)
check("...and prices nothing rather than half-writing", gotPriced, 0)
TSM_API = nil
Auctionator = nil

--------------------------------------------------------------------------------
-- The scan itself
--------------------------------------------------------------------------------

-- Run a scan to completion, answering only the items in `answer`. Anything else
-- gets silence, standing in for a query the server dropped.
local function DriveScan(answer, maxRounds)
	local rounds = 0
	while ns.IsScanning() and rounds < (maxRounds or 500) do
		rounds = rounds + 1
		local before = #ahSent
		RunTimers()
		for i = before + 1, #ahSent do
			if answer[ahSent[i]] then Fire("COMMODITY_SEARCH_RESULTS_UPDATED", ahSent[i]) end
		end
	end
	return rounds
end

-- Flowers, because they are the only thing a scan queues now. Passing dyes here
-- would build an empty queue and every scan test would pass by doing nothing.
local THREE = {
	{ key = "rose",  id = 900101, kind = "herb" },
	{ key = "poppy", id = 900102, kind = "herb" },
	{ key = "iris",  id = 900103, kind = "herb" },
}

print("\n-- A scan where every query answers --")

DyeingDownTheHouseDB.priceSource = "blizzard"
DyeingDownTheHouseDB.prices = {}
ahSent, ahListings = {}, {
	[900101] = { { unitPrice = 5000, quantity = 300 } },
	[900102] = { { unitPrice = 900,  quantity = 300 } },
	[900103] = { { unitPrice = 250,  quantity = 300 } },
}
Fire("AUCTION_HOUSE_SHOW")
check("the scan starts at the AH", select(1, ns.StartAHScan(THREE)), true)
DriveScan({ [900101] = true, [900102] = true, [900103] = true })
check("it finished", ns.IsScanning(), false)
check("one query per item, no retries needed", #ahSent, 3)
check("nothing was skipped", select(4, ns.GetScanProgress()), 0)
check("prices landed", ns.GetPrice("rose"), 5000)
check("marked as auction-house sourced", ns.GetPriceInfo("rose").source, "ah")

print("\n-- THE BUG: queries that never answer must not hang the scan --")

ahSent = {}
DyeingDownTheHouseDB.prices = {}
check("the scan starts", select(1, ns.StartAHScan(THREE)), true)
local rounds
-- A partial scan must SAY so. Silently pricing some of the list would leave the
-- cheapest-flower verdicts confidently wrong with nothing on screen to explain why.
check("the player is told the scan was partial",
	SaidWhile("skipped", function() rounds = DriveScan({}) end), true) -- answers nothing
check("it still finished instead of hanging", ns.IsScanning(), false)
check("it did not spin forever", rounds < 500, true)
check("every item was retried before giving up", #ahSent, 3 * (1 + ns.SCAN_RETRIES))
check("all three were reported skipped", select(4, ns.GetScanProgress()), 3)

print("\n-- A single dead item does not strand the ones behind it --")

ahSent = {}
DyeingDownTheHouseDB.prices = {}
ns.StartAHScan(THREE)
DriveScan({ [900101] = true, [900103] = true }) -- 900102 never answers
check("the scan completed", ns.IsScanning(), false)
check("only the dead one was skipped", select(4, ns.GetScanProgress()), 1)
check("the item before it was priced", ns.GetPrice("rose"), 5000)
check("the item AFTER it was still reached", ns.GetPrice("iris"), 250)

print("\n-- A reply for the wrong item is ignored --")

ahSent = {}
DyeingDownTheHouseDB.prices = {}
ns.StartAHScan({ { key = "rose", id = 900101, kind = "herb" } })
RunTimers() -- sends the query for rose
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 900102) -- a late answer to an abandoned query
check("a mismatched reply stores nothing", ns.GetPrice("rose"), nil)
check("...and does not advance the scan", ns.IsScanning(), true)
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 900101)
check("the right reply is accepted", ns.GetPrice("rose"), 5000)
DriveScan({})
check("the scan then ends", ns.IsScanning(), false)

print("\n-- Throttling delays the scan, it does not break it --")

ahSent = {}
ahThrottled = true
DyeingDownTheHouseDB.prices = {}
ns.StartAHScan({ { key = "rose", id = 900101, kind = "herb" } })
RunTimers(); RunTimers(); RunTimers()
check("nothing is sent while throttled", #ahSent, 0)
check("but the scan is still alive", ns.IsScanning(), true)
ahThrottled = false
Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
check("clearing the throttle sends the query", #ahSent, 1)
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 900101)
DriveScan({})
check("and the scan completes", ns.IsScanning(), false)

print("\n-- Closing the auction house abandons the scan cleanly --")

ahSent = {}
ns.StartAHScan(THREE)
RunTimers()
Fire("AUCTION_HOUSE_CLOSED")
check("the scan stopped", ns.IsScanning(), false)
local sentAfterClose = #ahSent
RunTimers(); RunTimers()
check("no queries leak out afterwards", #ahSent, sentAfterClose)
check("a scan away from the AH is refused", select(1, ns.StartAHScan(THREE)), false)

--------------------------------------------------------------------------------
-- The single list
--
-- Grouping, tabs and a second sort system all lived here until 12.1. They existed
-- because a dye and a color family were different things; now a dye IS a family, so
-- what's left to test is the one list, what opening a row shows, and that the
-- migration turns an old profile into a new one without losing the player's work.
--------------------------------------------------------------------------------

print("\n-- The display list is one row per color --")

ns.ClearFilters()
DyeingDownTheHouseDB.ui.hiddenDyes = {}
DyeingDownTheHouseDB.ui.expanded = {}

-- ClearFilters leaves the sort at alpha ascending, and alpha sorts on the item
-- NAME, so this comes out Blue/Green/Red/White rather than in ns.COLORS order.
check("one row per color", keys(ns.GetDisplayDyes()), "blue,green,red,white")
ns.SetDyeHidden("green", true)
check("a hidden color drops out", keys(ns.GetDisplayDyes()), "blue,red,white")
ns.SetDyeHidden("green", false)

print("\n-- Open and closed rows --")

check("rows start closed", ns.IsColorExpanded("red"), false)
ns.ToggleColor("red")
check("opening one opens only it", ns.IsColorExpanded("red"), true)
check("...and not its neighbour", ns.IsColorExpanded("blue"), false)
ns.ToggleColor("red")
check("toggling closes it again", ns.IsColorExpanded("red"), false)

ns.SetAllColorsExpanded(true)
check("expand-all opens every color", ns.IsColorExpanded("blue"), true)
ns.SetAllColorsExpanded(false)
check("collapse-all closes every color", ns.IsColorExpanded("blue"), false)

-- A search that matched a SHADE has to open the row, because the shade is inside
-- it. Leaving the rows shut would look like the search had found nothing.
ns.SetSearch("azure")
check("a search opens the rows it matched", ns.IsColorExpanded("blue"), true)
check("...even though none were opened by hand", DyeingDownTheHouseDB.ui.expanded.blue, nil)
check("and the list holds just the match", keys(ns.GetDisplayDyes()), "blue")
ns.SetSearch("")
check("clearing the search closes them again", ns.IsColorExpanded("blue"), false)

print("\n-- Craft breakdown by color --")

ns.SetPrice("rose", 400)
local colorCB = ns.GetColorCraftBreakdown("red")
check("the color breakdown exists", colorCB ~= nil, true)
check("rose costs 10x its price to make a dye with", colorCB.flowers[1].craftCost, 4000)
check("...and is the cheapest way into red", colorCB.flowers[1].isCheapest, true)
check("an unknown color has no breakdown", ns.GetColorCraftBreakdown("chartreuse"), nil)
check("a herb key is not a color", ns.GetColorCraftBreakdown("rose"), nil)
ns.SetPrice("rose", nil)

--------------------------------------------------------------------------------
-- Migrating a pre-12.1 profile (v2 -> v3)
--
-- The one part of this release that can destroy something the player can't get
-- back. Goals are hand-entered and there is no undo, so each rule gets its own
-- check rather than one "it migrated" assertion.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Goals live on shades; families are the roll-up
--
-- The model people actually decorate with: you want five Alliance Blue for a wall,
-- and what that COSTS is five Blue Housing Dye. The number is typed once against
-- the shade and derived everywhere else, so the two can never disagree.
--------------------------------------------------------------------------------

print("\n-- Setting goals on shades --")
DyeingDownTheHouseDB.goals = {}
DyeingDownTheHouseDB.unassigned = {}

ns.SetShadeGoal("Crimson", 5)
check("a shade goal reads back", ns.GetShadeGoal("Crimson"), 5)
check("shade goals are case-insensitive", ns.GetShadeGoal("crimson"), 5)
check("...on the way in as well", (function()
	ns.SetShadeGoal("SCARLET", 3); return ns.GetShadeGoal("Scarlet")
end)(), 3)
check("a shade with no goal is 0, not nil", ns.GetShadeGoal("Azure"), 0)
check("an unknown shade name is harmless", ns.GetShadeGoal("Chartreuse"), 0)

print("\n-- The family is the sum of its shades --")
-- Crimson 5 + Scarlet 3, both red.
check("red needs what its shades add up to", ns.GetGoal("red"), 8)
check("blue has no shade goals yet", ns.GetGoal("blue"), 0)
ns.SetShadeGoal("Azure", 4)
check("blue follows its own shade", ns.GetGoal("blue"), 4)
check("...and red is unaffected", ns.GetGoal("red"), 8)

print("\n-- Clearing a shade goal --")
ns.SetShadeGoal("Scarlet", 0)
check("the shade is cleared", ns.GetShadeGoal("Scarlet"), 0)
check("and the family total drops with it", ns.GetGoal("red"), 5)
ns.SetShadeGoal("Scarlet", "junk")
check("junk clears rather than erroring", ns.GetShadeGoal("Scarlet"), 0)

print("\n-- The unattributed remainder --")
-- Carried over from before shades could hold a goal. It still counts, and it can
-- still be cleared, which is what stops a migrated number being stuck forever.
ns.SetUnassignedGoal("red", 10)
check("unassigned reads back", ns.GetUnassignedGoal("red"), 10)
check("and adds to the shades", ns.GetGoal("red"), 15)
check("SetGoal writes the unattributed bucket", (function()
	ns.SetGoal("red", 2); return ns.GetUnassignedGoal("red")
end)(), 2)
check("...so the family total follows", ns.GetGoal("red"), 7)
ns.SetUnassignedGoal("red", 0)
check("it can be cleared away entirely", ns.GetGoal("red"), 5)

print("\n-- The breakdown behind a family total --")
ns.SetShadeGoal("Scarlet", 9)
local bd = ns.GetGoalBreakdown("red")
check("only shades carrying a goal appear", #bd, 2)
check("biggest first", bd[1].name, "Scarlet")
check("...then the rest", bd[2].name, "Crimson")
check("a family with no shade goals is empty", #ns.GetGoalBreakdown("white"), 0)

print("\n-- The rest of the addon reads the roll-up --")
-- GetRecipeStatus, the station line and the Short column all go through GetGoal,
-- so a shade goal has to move them without any of them knowing shades exist.
DyeingDownTheHouseDB.goals = {}
DyeingDownTheHouseDB.unassigned = {}
ns.SetShadeGoal("Azure", 6)
local rs = ns.GetRecipeStatus("blue")
check("recipe status sees the rolled-up goal", rs.goal, 6)
check("...and its shortfall", rs.shortfall, 6)
check("sorting by goal sees it too", keys(ns.SortDyes(ns.DYES, "goal")), "blue,green,red,white")
DyeingDownTheHouseDB.goals = {}
DyeingDownTheHouseDB.unassigned = {}

print("\n-- v2 -> v3 migration --")

-- A profile as it stood before the patch: real pre-12.1 keys, of colors the fixture
-- also has, so the result can be read against the fixture's own dyes.
DyeingDownTheHouseDB = {
	version = 2,
	goals = { hordered = 5, mahogany = 3, allianceblue = 4, ungorogreen = 2 },
	prices = { red_pigment = { copper = 100, seen = 1, source = "ah" },
	           hordered = { copper = 900, seen = 1, source = "ah" },
	           rose = { copper = 400, seen = 1, source = "ah" } },
	warband = { hordered = 9, red_pigment = 4, rose = 20 },
	chars = { ["Riker-Enterprise"] = { bags = { mahogany = 2, rose = 5 }, bank = {} } },
	learned = { hordered = 111, rose = 900101 },
	ui = {
		-- every red dye unticked, but only one of the blues
		hiddenDyes = {
			deepmageroyalred = true, firebloomred = true, gilneanrose = true,
			hinterlandshickory = true, hordered = true, mahogany = true,
			rainpoppyred = true, ratchetrust = true,
			allianceblue = true,
		},
		expanded = { hordered = true },
		expandedColors = { teal = true },
		tab = "dye", groupSort = "pigment", groupSortDir = "asc",
		cols = { pigment = true, flowers = true },
	},
}
Fire("ADDON_LOADED", "DyeingDownTheHouse")

local db = DyeingDownTheHouseDB
check("schema version bumped", db.version, 4)

-- GOALS fold by addition: 5 Horde Red + 3 Mahogany is 8 Red Housing Dye, which is
-- exactly what Hestia's mail does to the items themselves. v4 then moves the
-- family total to `unassigned`, since goals now live on shade names and the addon
-- cannot know which shades a family goal was meant to cover.
check("red goals added together", db.unassigned.red, 8)
check("blue goal carried over", db.unassigned.blue, 4)
check("an ex-teal goal follows its new family", db.unassigned.green, 2)
check("no old dye key survives in goals", db.goals.hordered, nil)
check("nor as a colour key", db.goals.red, nil)
-- What matters to everything downstream is that the TOTAL is unchanged.
check("the family still needs what it needed", ns.GetGoal("red"), 8)

-- COUNTS are dropped, never folded: the old items no longer exist and the new ones
-- arrive by mail the player still has to collect, so folding would claim dyes that
-- aren't in the bags. Under-reporting until the next scan beats inventing stock.
check("warband dye counts dropped", db.warband.hordered, nil)
check("warband pigment counts dropped", db.warband.red_pigment, nil)
check("flower counts untouched", db.warband.rose, 20)
check("character dye counts dropped", db.chars["Riker-Enterprise"].bags.mahogany, nil)
check("character flower counts untouched", db.chars["Riker-Enterprise"].bags.rose, 5)

-- PRICES for things that no longer exist are junk.
check("pigment prices dropped", db.prices.red_pigment, nil)
check("stale dye prices dropped", db.prices.hordered, nil)
check("flower prices kept", db.prices.rose.copper, 400)

-- LEARNED ids pointed at deleted items.
check("learned dye ids dropped", db.learned.hordered, nil)
check("learned flower ids kept", db.learned.rose, 900101)

-- HIDDEN folds with AND: a family disappears only if every one of its shades was
-- unticked. Unticking one blue must not hide all of blue.
check("a fully-hidden family stays hidden", db.ui.hiddenDyes.red, true)
check("a partly-hidden family comes back", db.ui.hiddenDyes.blue, nil)
check("no old dye key survives in the hide list", db.ui.hiddenDyes.hordered, nil)

-- OPEN ROWS merge into one table, teal included.
check("an opened dye row becomes its color", db.ui.expanded.red, true)
check("an opened teal group becomes blue", db.ui.expanded.blue, true)
check("the separate expandedColors table is gone", db.ui.expandedColors, nil)

-- Settings for things that no longer exist would re-apply a layout that isn't there.
check("the tab preference is dropped", db.ui.tab, nil)
check("the group sort is dropped", db.ui.groupSort, nil)
check("the pigment column is dropped", db.ui.cols.pigment, nil)
check("other column choices are kept", db.ui.cols.flowers, true)

print("\n-- Migrating twice changes nothing --")
local goalsRed = db.unassigned.red
Fire("ADDON_LOADED", "DyeingDownTheHouse")
check("goals are not doubled on a second run", DyeingDownTheHouseDB.unassigned.red, goalsRed)
check("still at the current version", DyeingDownTheHouseDB.version, 4)

print("\n-- A profile already on the current schema is left alone --")
DyeingDownTheHouseDB = {
	version = 4, goals = { ["alliance blue"] = 12 }, unassigned = { red = 3 }, ui = {},
}
Fire("ADDON_LOADED", "DyeingDownTheHouse")
check("its shade goals survive untouched", DyeingDownTheHouseDB.goals["alliance blue"], 12)
check("its unassigned goals survive too", DyeingDownTheHouseDB.unassigned.red, 3)

--------------------------------------------------------------------------------
-- Discovery: reading the dyes out of C_DyeColor
--
-- 12.1 ships an API that answers what Data.lua could only infer -- every shade's
-- name and the item it costs. Grouping shades by that item yields the families,
-- their item IDs and the shade -> family map, all from the client.
--
-- What's guarded here is mostly what discovery must NOT do. It runs against live
-- data on someone's account, it rewrites the table the whole addon is driven from,
-- and a bad pass would be both invisible and permanent for that session.
--------------------------------------------------------------------------------

print("\n-- Discovery from C_DyeColor --")

-- Reset to a known fixture: two families, one shade each side, plus a shade
-- Data.lua has never heard of and a family whose item cannot be named yet.
ns.COLORS = { "red", "blue", "green", "white" }
ns.DYES = {
	{ key = "red",   name = "Red Housing Dye",   color = "red" },
	{ key = "green", name = "Green Housing Dye", color = "green" },
	{ key = "blue",  name = "Blue Housing Dye",  color = "blue" },
	{ key = "white", name = "White Housing Dye", color = "white" },
}
ns.SHADES = {
	{ name = "Crimson", color = "red" },
	{ name = "Scarlet", color = "red" },
	{ name = "Azure",   color = "blue" },
	{ name = "Plain",   color = "blue", guess = true },
	{ name = "Moss",    color = "green" },
}
ns.SHADE_BY_COLORID = {}
ns.RebuildLookups()

-- 800001 names itself; 800003 does NOT (uncached), so it has to be placed by the
-- shades it holds. 800004 can be placed by neither and must be left alone.
ITEM_NAMES[800001] = "Red Housing Dye"
ITEM_NAMES[800003] = nil
ID_BY_NAME["Red Housing Dye"] = 800001

local requested = {}
C_Item.RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end

C_DyeColor = {
	GetAllDyeColors = function() return { 11, 12, 13, 14, 15, 16 } end,
	GetDyeColorInfo = function(colorID)
		local rows = {
			[11] = { ID = 11, name = "Crimson",   itemID = 800001 },
			[12] = { ID = 12, name = "Scarlet",   itemID = 800001 },
			-- a shade the fixture has never seen, on a known item
			[13] = { ID = 13, name = "Vermilion", itemID = 800001 },
			-- an item with no cached name: placed by its shades instead
			[14] = { ID = 14, name = "Azure",     itemID = 800003 },
			[15] = { ID = 15, name = "Plain",     itemID = 800003 },
			-- an item that can be placed by nothing at all
			[16] = { ID = 16, name = "Puce",      itemID = 800004 },
		}
		return rows[colorID]
	end,
}

local dok, dinfo = ns.DiscoverDyes()
check("discovery ran", dok, true)
check("every shade was read", dinfo.shades, 6)
check("three distinct dye items seen", dinfo.items, 3)
check("two of them were placed", dinfo.colors, 2)
check("the unplaceable one is pending", dinfo.pending, 1)

print("\n-- Item IDs land on the right family --")
check("red learned its item ID from the item name", ns.byKey.red.id, 800001)
check("blue was placed by its shades instead", ns.byKey.blue.id, 800003)
check("an unplaceable item is NOT guessed onto a family", ns.byKey.white.id, nil)
check("...and green is untouched too", ns.byKey.green.id, nil)
check("the client was asked to load the unnamed item", requested[1] ~= nil, true)

print("\n-- Shades are placed and their guess flags cleared --")
local function shade(name)
	for _, sh in ipairs(ns.SHADES) do if sh.name == name then return sh end end
end
check("a known shade keeps its family", shade("Crimson").color, "red")
check("...and carries the game's colour ID", shade("Crimson").dyeColorID, 11)
check("a GUESSED family is confirmed by the game", shade("Plain").color, "blue")
check("...and stops being flagged as a guess", shade("Plain").guess, nil)
check("a shade Data.lua never knew is added", shade("Vermilion") ~= nil, true)
check("...on the right family", shade("Vermilion").color, "red")
check("a shade on an unplaceable item is left alone", shade("Puce"), nil)

print("\n-- The colour-ID index the house panel reads --")
check("indexed by the game's dyeColorID", ns.SHADE_BY_COLORID[11].name, "Crimson")
check("a newly added shade is indexed too", ns.SHADE_BY_COLORID[13].name, "Vermilion")
check("an unplaced shade is not indexed", ns.SHADE_BY_COLORID[16], nil)

print("\n-- Lookups are rebuilt, so the rest of the addon sees it --")
check("the new shade joins its family", #ns.shadesByColor.red, 3)
check("searching finds a shade discovered at runtime", #ns.FilterDyes("vermilion"), 1)
check("...and lands on its family", ns.FilterDyes("vermilion")[1].key, "red")
check("the learned item ID resolves in byID", ns.byID[800001].key, "red")

print("\n-- Running it twice changes nothing --")
local before = #ns.SHADES
ns.DiscoverDyes()
check("shades are not duplicated", #ns.SHADES, before)
check("item IDs are unchanged", ns.byKey.red.id, 800001)

print("\n-- The item name wins over the shades when they disagree --")
-- Data.lua says Moss is green; the game says its item is the RED dye. The item is
-- the fact and the static table is the inference, so the item has to win -- this is
-- the case that fixes a wrong colour rather than entrenching it.
C_DyeColor.GetAllDyeColors = function() return { 21 } end
C_DyeColor.GetDyeColorInfo = function() return { ID = 21, name = "Moss", itemID = 800001 } end
ns.DiscoverDyes()
check("the shade moves to the item's family", shade("Moss").color, "red")

print("\n-- A client without C_DyeColor is not a failure --")
C_DyeColor = nil
local nok, nerr = ns.DiscoverDyes()
check("it declines rather than erroring", nok, false)
check("...and says why", type(nerr), "string")
check("the data it already learned survives", ns.byKey.red.id, 800001)

print("\n-- A broken API cannot take the addon down --")
C_DyeColor = {
	GetAllDyeColors = function() error("C_DyeColor exploded") end,
	GetDyeColorInfo = function() error("C_DyeColor exploded") end,
}
local sok = ns.DiscoverDyes()
check("an erroring API is survivable", sok, false)
C_DyeColor = {
	GetAllDyeColors = function() return { 31 } end,
	GetDyeColorInfo = function() error("boom") end,
}
check("a throwing per-colour call is survivable", (pcall(ns.DiscoverDyes)), true)
C_DyeColor = nil

print(("\n%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
