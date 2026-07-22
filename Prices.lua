local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Prices.lua — where prices come from.
--
-- Three sources, listed in the order "auto" prefers them:
--   tsm          TradeSkillMaster's price database
--   auctionator  Auctionator's price database
--   blizzard     our own auction-house scan (Core.lua) — always available
--
-- The first two read a database another addon already maintains, so they price
-- every dye and flower instantly, anywhere in the world, with no queries at all.
-- The AH scan has to ask Blizzard one throttled question per item and only works
-- standing at an auction house — so it's the fallback, not the default.
--
-- That ordering is also the fix for a real bug: Blizzard's auction API silently
-- drops queries once you exceed its rate limit, which used to strand a scan partway
-- through. Core.lua now paces and watchdogs that scan, but a player who already runs
-- TSM or Auctionator never has to touch it.
--
-- Every call into a foreign addon is feature-detected and pcall-wrapped. These are
-- other people's addons: they can change shape between versions, be disabled mid
-- session, or be loaded but not yet initialized. A price lookup must never be able
-- to take the rest of the addon down with it.
--
-- API shapes verified against each addon's own source (2026-07-21):
--   Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID) -> copper | nil
--     callerID is a string (the addon asking); itemID must be a NUMBER, and the
--     call raises if it isn't — hence the pcall and the type guard.
--   TSM_API.ToItemString(itemLink)            -> "i:12345"-style item string
--   TSM_API.GetCustomPriceValue(key, itemStr) -> copper | nil, error
--------------------------------------------------------------------------------

local function Print(msg)
	if ns.Print then ns.Print(msg) end
end

--------------------------------------------------------------------------------
-- The sources
--------------------------------------------------------------------------------

-- TSM wants an item string. A real link is better than a bare ID (it carries bonus
-- ids and quality), but plain "i:<id>" is valid and is what TSM itself falls back
-- to, so an uncached item still gets a price.
local function TSMItemString(itemID)
	if type(TSM_API.ToItemString) == "function" and C_Item and C_Item.GetItemInfo then
		local ok, _, link = pcall(C_Item.GetItemInfo, itemID)
		if ok and link then
			local converted, str = pcall(TSM_API.ToItemString, link)
			if converted and type(str) == "string" then return str end
		end
	end
	return "i:" .. tostring(itemID)
end

-- Ordered by preference for "auto". `Ready` tests the API itself rather than just
-- whether the addon is loaded: an addon can be present but not yet initialized, and
-- calling into it then is exactly how you get a load-time error in someone else's
-- code blamed on yours.
ns.PRICE_SOURCES = {
	{
		key = "tsm",
		name = "TradeSkillMaster",
		addon = "TradeSkillMaster",
		instant = true,
		Ready = function()
			return type(TSM_API) == "table"
				and type(TSM_API.GetCustomPriceValue) == "function"
		end,
		GetPrice = function(entry)
			local key = (DyeingDownTheHouseDB and DyeingDownTheHouseDB.tsmPriceKey) or "DBMarket"
			local value = TSM_API.GetCustomPriceValue(key, TSMItemString(entry.id))
			return value
		end,
	},
	{
		key = "auctionator",
		name = "Auctionator",
		addon = "Auctionator",
		instant = true,
		Ready = function()
			return type(Auctionator) == "table"
				and type(Auctionator.API) == "table"
				and type(Auctionator.API.v1) == "table"
				and type(Auctionator.API.v1.GetAuctionPriceByItemID) == "function"
		end,
		GetPrice = function(entry)
			return Auctionator.API.v1.GetAuctionPriceByItemID(ADDON, entry.id)
		end,
	},
	{
		key = "blizzard",
		name = "Auction House scan",
		addon = nil, -- built in; nothing to install
		instant = false,
		Ready = function() return true end,
		GetPrice = nil, -- scanned, not looked up
	},
}

local byKey = {}
for _, source in ipairs(ns.PRICE_SOURCES) do byKey[source.key] = source end

function ns.GetPriceSourceByKey(key)
	return byKey[key]
end

-- Is this source usable right now? Wrapped because `Ready` reaches into a foreign
-- global that may be mid-teardown.
function ns.IsPriceSourceAvailable(source)
	if type(source) == "string" then source = byKey[source] end
	if not source then return false end
	local ok, ready = pcall(source.Ready)
	return ok and ready and true or false
end

-- Every source that could be used right now, in preference order. Always contains
-- at least the built-in AH scan.
function ns.GetAvailablePriceSources()
	local out = {}
	for _, source in ipairs(ns.PRICE_SOURCES) do
		if ns.IsPriceSourceAvailable(source) then out[#out + 1] = source end
	end
	return out
end

-- The source a scan would actually use, plus whether that differs from what the
-- player asked for. A pinned source that's since been uninstalled falls back rather
-- than failing — but the preference is left alone, so reinstalling restores it
-- instead of silently having been rewritten to something else.
function ns.ResolvePriceSource()
	local want = (DyeingDownTheHouseDB and DyeingDownTheHouseDB.priceSource) or "auto"

	if want ~= "auto" then
		local pinned = byKey[want]
		if pinned and ns.IsPriceSourceAvailable(pinned) then return pinned, false end
	end

	local available = ns.GetAvailablePriceSources()
	local best = available[1] or byKey.blizzard
	return best, (want ~= "auto") -- fellBack only if they'd pinned something else
end

function ns.GetPriceSource()
	return (DyeingDownTheHouseDB and DyeingDownTheHouseDB.priceSource) or "auto"
end

function ns.SetPriceSource(key)
	if key ~= "auto" and not byKey[key] then return false end
	DyeingDownTheHouseDB.priceSource = key
	ns.Refresh()
	return true
end

--------------------------------------------------------------------------------
-- Importing from an instant source
--------------------------------------------------------------------------------

-- Which items a price update covers. Same rules as the AH scan queue in Core:
-- pigments are an intermediate nobody buys or sells to make a decision, and hidden
-- dyes and flowers aren't on screen so aren't worth a lookup.
function ns.ShouldPriceEntry(entry)
	if not entry.id or entry.kind == "pigment" then return false end
	if entry.kind == "dye" and ns.IsDyeHidden(entry.key) then return false end
	if entry.kind == "herb" and ns.IsHerbHidden(entry.name) then return false end
	return true
end

-- Read every price from `source` in one pass. Returns how many were priced and how
-- many the source had nothing for.
--
-- A source returning nothing for an item is normal and not an error: it means that
-- addon hasn't seen the item on the AH yet. As in the scan, a missing price leaves
-- any previous one alone rather than wiping it — a stale price beats no price, and
-- the UI shows how old it is.
function ns.ImportPrices(source)
	source = source or ns.ResolvePriceSource()
	if type(source) == "string" then source = byKey[source] end
	if not (source and source.GetPrice) then return 0, 0 end

	local priced, missing = 0, 0
	for _, entry in ipairs(ns.ITEMS) do
		if ns.ShouldPriceEntry(entry) then
			local ok, copper = pcall(source.GetPrice, entry)
			copper = ok and tonumber(copper) or nil
			if copper and copper > 0 then
				ns.SetPrice(entry.key, copper, source.key)
				priced = priced + 1
			else
				missing = missing + 1
			end
		end
	end

	if priced > 0 then DyeingDownTheHouseDB.lastScan = time() end
	return priced, missing
end

--------------------------------------------------------------------------------
-- The dispatcher — replaces Core's default ns.StartScan
--------------------------------------------------------------------------------

function ns.StartScan(items)
	local source, fellBack = ns.ResolvePriceSource()

	if fellBack then
		local wanted = byKey[ns.GetPriceSource()]
		Print(("%s isn't loaded — using %s instead."):format(
			wanted and wanted.name or "That price source", source.name))
	end

	-- The AH scan is the only asynchronous one; hand straight back to Core.
	if source.key == "blizzard" then
		return ns.StartAHScan(items)
	end

	local priced, missing = ns.ImportPrices(source)

	if priced == 0 then
		return false, ("%s has no prices for these items yet. Visit the auction house with it once, or run /dye source blizzard to scan directly.")
			:format(source.name)
	end

	if missing > 0 then
		Print(("priced %d from %s (%d not in its database yet)."):format(priced, source.name, missing))
	else
		Print(("priced %d items from %s."):format(priced, source.name))
	end

	ns.Refresh()
	return true
end
