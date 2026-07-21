local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Lookups
--
-- The crafting chain is: 10 HERBS -> 1 PIGMENT -> 1 DYE, and everything is grouped
-- by COLOUR. Each colour has one pigment; every herb of that colour mills into it,
-- and every dye of that colour is made from it. All three are real items that live
-- in bags, bank and the Warband bank, so the scanning and counting machinery works
-- over the UNION of all of them (ns.ITEMS). The per-kind views stay available as
-- ns.DYES / ns.PIGMENTS / ns.HERBS, and the colour groupings as ns.pigmentByColor
-- and ns.herbsByColor for the recipe engine.
--------------------------------------------------------------------------------

-- Conversion constants, from the chart. Kept as fields (not magic numbers) so a
-- balance change is a one-line edit, and so the recipe engine reads clearly.
ns.HERBS_PER_PIGMENT = ns.HERBS_PER_PIGMENT or 10
ns.PIGMENTS_PER_DYE  = ns.PIGMENTS_PER_DYE  or 1

ns.byID = {}
ns.byName = {}
ns.byKey = {}
ns.ITEMS = {}
ns.pigmentByColor = {}
ns.herbsByColor = {}

-- Rebuilt from ns.DYES / ns.PIGMENTS / ns.HERBS. Exposed so the test harness can
-- swap in a fixture dataset and rebuild, the same way the real Data.lua drives it
-- at load.
function ns.RebuildLookups()
	ns.byID, ns.byName, ns.byKey, ns.ITEMS = {}, {}, {}, {}
	ns.pigmentByColor, ns.herbsByColor = {}, {}

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
	for _, pigment in ipairs(ns.PIGMENTS or {}) do
		add(pigment, "pigment")
		if pigment.color then ns.pigmentByColor[pigment.color] = pigment end
	end
	for _, herb in ipairs(ns.HERBS or {}) do
		add(herb, "herb")
		-- A herb can mill into more than one colour's pigment (the chart's overlaps),
		-- so it may appear in several colour buckets. `colors` is the list; `color`
		-- is accepted as a one-colour shorthand.
		herb.colors = herb.colors or (herb.color and { herb.color }) or {}
		for _, color in ipairs(herb.colors) do
			local list = ns.herbsByColor[color]
			if not list then list = {}; ns.herbsByColor[color] = list end
			list[#list + 1] = herb
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

local DB_VERSION = 1

local defaults = {
	version = DB_VERSION,

	-- Everything the addon *counts* is account-wide: each character contributes
	-- its bags and bank as it logs in, and the totals shown are the sum across the
	-- whole roster. Only presentation lives in `ui`.
	warband = {},       -- [key] = count, cached from the last bank visit by anyone
	warbandSeen = nil,  -- timestamp of that visit
	warbandSeenBy = nil,-- which character made it
	chars = {},         -- [charKey] = { bags, bank, bagsSeen, bankSeen, name, realm, class }
	goals = {},         -- [dyeKey] = number, account-wide (they measure account totals)
	learned = {},       -- [key] = itemID discovered by name match
	prices = {},        -- [key] = { copper = n, seen = ts, source = "ah" }
	ui = {
		point = "CENTER",
		relPoint = "CENTER",
		x = 0,
		y = 0,
		shown = true,
		locked = false,
		scale = 1.0,
		hideZero = false,
		showGoals = true,
		opacity = 1.0,
		search = "",       -- name filter
		sort = "alpha",    -- see VALID_SORT
		sortDir = "asc",   -- "asc" | "desc"
		-- Which optional columns are shown. Dye + Owned are always shown.
		cols = { pigment = true, flowers = true, value = true, goal = true },
		expanded = {}, -- [dyeKey] = true, rows expanded to show their flowers
		hideCostlyFlowers = false, -- in the expand view, hide flowers dearer to craft than to buy
		hiddenDyes = {}, -- [dyeKey] = true, dyes the player unchecked (hidden from the list)
		hiddenHerbs = {}, -- [herbNameLower] = true, flowers hidden from the expand view
		rainbowTitle = true, -- flashy rainbow name (off = plain)
		housingGoalInput = true, -- show the "Dye Needed" box in the house dye panel
		markHerbs = true, -- green check / red X on herbs in the pigment reagent picker
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
				DyingDownTheHouseDB.learned[entry.key] = info.itemID
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
	local char = DyingDownTheHouseDB.chars[charKey]
	char.bags = ScanGroup(bagGroups.bags)
	char.bagsSeen = time()
end

local function ScanBank()
	if not bankOpen then return end
	local char = DyingDownTheHouseDB.chars[charKey]
	char.bank = ScanGroup(bagGroups.bank)
	char.bankSeen = time()

	-- The Warband bank is one shared inventory, so the newest scan by any character
	-- replaces it wholesale rather than adding to it.
	DyingDownTheHouseDB.warband = ScanGroup(bagGroups.warband)
	DyingDownTheHouseDB.warbandSeen = time()
	DyingDownTheHouseDB.warbandSeenBy = charKey
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
	if not (DyingDownTheHouseDB and charKey) then return end
	local char = DyingDownTheHouseDB.chars[charKey]
	if not char then return end

	local changed = false

	for _, entry in ipairs(ns.ITEMS) do
		if entry.id then
			local live = LiveReachableCount(entry.id)
			if live then
				local bags = (char.bags and char.bags[entry.key]) or 0
				local bank = (char.bank and char.bank[entry.key]) or 0
				local warband = DyingDownTheHouseDB.warband[entry.key] or 0
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
						DyingDownTheHouseDB.warband[entry.key] = math.max(0, warband - deficit)
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
			if DyingDownTheHouseDB.chars[ourKey] then return end -- we have our own scan

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
	for ck, char in pairs(DyingDownTheHouseDB.chars) do
		callback(ck, char, false)
	end
	for ck, char in pairs(borrowed) do
		if not DyingDownTheHouseDB.chars[ck] then
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
	local total = (DyingDownTheHouseDB.warband[key]) or 0
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
		warband = DyingDownTheHouseDB.warband[key] or 0,
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
		warbandSeen = DyingDownTheHouseDB.warbandSeen,
		warbandSeenBy = DyingDownTheHouseDB.warbandSeenBy,
		chars = {},
	}

	for ck, char in pairs(DyingDownTheHouseDB.chars) do
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

-- "3 minutes ago" etc, plus a colour that fades as the data goes stale.
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

function ns.GetGoal(key)
	return DyingDownTheHouseDB.goals[key] or 0
end

function ns.SetGoal(key, value)
	value = tonumber(value)
	if not value or value <= 0 then
		DyingDownTheHouseDB.goals[key] = nil
	else
		DyingDownTheHouseDB.goals[key] = math.floor(value)
	end
	ns.Refresh()
end

-- True once any character on the account has visited a bank, so the UI can say
-- "never scanned" instead of silently showing 0.
function ns.HasBankData()
	return DyingDownTheHouseDB.warbandSeen ~= nil
end

function ns.IsBankOpen()
	return bankOpen
end

--------------------------------------------------------------------------------
-- Prices (populated by the AH scanner — storage and readers only for now)
--
-- Stored per item key in copper, with the timestamp of the scan and its source.
-- The AH scan that fills this in is a separate step; these are the pure readers
-- and writers the value display and the price sort are built on.
--------------------------------------------------------------------------------

function ns.SetPrice(key, copper, source)
	copper = tonumber(copper)
	if not copper or copper < 0 then
		DyingDownTheHouseDB.prices[key] = nil
	else
		DyingDownTheHouseDB.prices[key] = {
			copper = math.floor(copper),
			seen = time(),
			source = source or "ah",
		}
	end
end

-- The stored unit price in copper, or nil if we've never scanned one.
function ns.GetPrice(key)
	local p = DyingDownTheHouseDB.prices[key]
	return p and p.copper or nil
end

function ns.GetPriceInfo(key)
	return DyingDownTheHouseDB.prices[key]
end

-- The gold value of everything the account holds of this item: total × unit price.
-- nil when there's no price to value it against (never guess it as zero — the UI
-- shows "—" instead).
function ns.GetValue(key)
	local price = ns.GetPrice(key)
	if not price then return nil end
	return ns.GetTotal(key) * price
end

--------------------------------------------------------------------------------
-- Auction House scanning
--
-- Value is the volume-weighted average unit price of the cheapest ~N units on the
-- AH — what you'd realistically pay/get, not the single lowest listing (which can
-- be a tiny spiteful stack). Verified against C_AuctionHouse: dyes, pigments and
-- herbs are all commodities, a commodity search returns its whole listing set in
-- one COMMODITY_SEARCH_RESULTS_UPDATED, each listing carrying unitPrice (copper)
-- and quantity.
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

local scan = { active = false, queue = {}, index = 0, itemID = nil, awaitingNext = false }
local ahOpen = false

function ns.IsAHOpen() return ahOpen end
function ns.IsScanning() return scan.active end

-- active, done, total
function ns.GetScanProgress()
	return scan.active, scan.index, #scan.queue
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

local function SendNextQuery()
	scan.index = scan.index + 1
	if scan.index > #scan.queue then
		scan.active = false
		scan.itemID = nil
		DyingDownTheHouseDB.lastScan = time() -- for the "scanned Xm ago" stamp
		-- No chat output: the floating overlay showed progress and now hides itself.
		ns.Refresh()
		return
	end
	scan.itemID = scan.queue[scan.index]

	local sorts
	if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
		sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	end
	local ok, itemKey = pcall(C_AuctionHouse.MakeItemKey, scan.itemID)
	if ok and itemKey then
		pcall(C_AuctionHouse.SendSearchQuery, itemKey, sorts or {}, false)
	else
		-- Couldn't query this one; skip to the next.
		SendNextQuery()
	end
	ns.Refresh()
end

local function AdvanceWhenReady()
	scan.awaitingNext = true
	local ready = true
	if type(C_AuctionHouse.IsThrottledMessageSystemReady) == "function" then
		ready = C_AuctionHouse.IsThrottledMessageSystemReady()
	end
	if ready then
		scan.awaitingNext = false
		SendNextQuery()
	end
	-- else: wait for AUCTION_HOUSE_THROTTLED_SYSTEM_READY
end

-- The list of item IDs a scan will price, in order. Pure, so it's testable.
--   * dyes (the end product's price) and herbs (the ingredient cost) — pigments
--     are an intermediate we never buy/sell to decide, so they're skipped;
--   * dyes and flowers the player has unchecked in the config are skipped too —
--     if they aren't shown, there's no reason to spend a query pricing them;
--   * each id appears at most once.
function ns.BuildScanQueue(items)
	local queue, seen = {}, {}
	for _, entry in ipairs(items or ns.ITEMS) do
		local hidden = (entry.kind == "dye" and ns.IsDyeHidden(entry.key))
			or (entry.kind == "herb" and ns.IsHerbHidden(entry.name))
		if entry.id and entry.kind ~= "pigment" and not hidden and not seen[entry.id] then
			seen[entry.id] = true
			queue[#queue + 1] = entry.id
		end
	end
	return queue
end

function ns.StartScan(items)
	if scan.active then return false, "already scanning" end
	if not ahOpen or type(C_AuctionHouse) ~= "table" then
		return false, "open the Auction House first"
	end

	scan.queue = ns.BuildScanQueue(items)

	scan.active = true
	scan.index = 0
	-- "Hold your brutosaurs…" now rides the floating overlay, not the chat frame.
	AdvanceWhenReady()
	return true
end

function ns.StopScan()
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

scanFrame:SetScript("OnEvent", function(_, event)
	if event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		ns.Refresh()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ahOpen = false
		ns.StopScan()
		ns.Refresh()
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		if scan.active and scan.itemID then
			StoreScannedPrice(scan.itemID)
			AdvanceWhenReady()
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		-- One of our items turned out non-commodity: skip pricing, keep going.
		if scan.active then AdvanceWhenReady() end
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		if scan.active and scan.awaitingNext then
			scan.awaitingNext = false
			SendNextQuery()
		end
	end
end)

--------------------------------------------------------------------------------
-- Recipes — the 10 herbs -> 1 pigment -> 1 dye chain
--
-- Each dye is made from one PIGMENT of the dye's colour; each pigment is milled
-- from HERBS of that colour. Herbs of a colour form a fungible pool — any herb of
-- the colour mills into that colour's pigment — so the useful figure is the total
-- herb count for the colour, not per-herb.
--------------------------------------------------------------------------------

-- The supply picture for one colour: how many pigments the account already holds,
-- how many more it could mill from its herb pool, and the herb breakdown. This is
-- the per-colour number the game's craft window shows (makeablePigments), computed
-- ourselves so it can be combined across colours for the contention view.
function ns.GetColorSupply(color)
	local pigment = ns.pigmentByColor[color]
	local ownedPigments = pigment and ns.GetTotal(pigment.key) or 0

	local perPigment = ns.HERBS_PER_PIGMENT

	-- Milling needs 10 of the SAME herb, so a colour's pigment yield is the sum of
	-- floor(count / 10) over each herb separately — NOT floor(total / 10). Odd
	-- remainders in different herbs can't be combined into a pigment.
	local herbs = ns.herbsByColor[color] or {}
	local ownedHerbs, pigmentsFromHerbs, breakdown = 0, 0, {}
	for _, herb in ipairs(herbs) do
		local have = ns.GetTotal(herb.key)
		ownedHerbs = ownedHerbs + have
		pigmentsFromHerbs = pigmentsFromHerbs + math.floor(have / perPigment)
		breakdown[#breakdown + 1] = {
			key = herb.key,
			name = herb.name or ("Item " .. tostring(herb.id)), -- pending a cached name
			have = have,
			-- The other colours this herb also feeds, so the UI can flag contention.
			colors = herb.colors or {},
		}
	end

	return {
		color = color,
		pigment = pigment and { key = pigment.key, name = pigment.name } or nil,
		ownedPigments = ownedPigments,
		ownedHerbs = ownedHerbs,
		herbsPerPigment = perPigment,
		pigmentsFromHerbs = pigmentsFromHerbs,          -- craftable right now (what the game shows)
		makeablePigments = ownedPigments + pigmentsFromHerbs, -- held + craftable
		herbs = breakdown,
	}
end

-- Status for a single dye against its goal. Treats this colour's herbs in
-- isolation (dedicated to this dye); the cross-colour contention — where a shared
-- herb can't feed two colours at once — is a separate, whole-account question
-- answered by ns.PlanGoals below.
function ns.GetRecipeStatus(dyeKey)
	local dye = ns.byKey[dyeKey]
	if not dye or dye.kind ~= "dye" then return nil end

	local color = dye.color
	local supply = ns.GetColorSupply(color)
	local perPigment = ns.HERBS_PER_PIGMENT
	local perDye = ns.PIGMENTS_PER_DYE

	local owned = ns.GetTotal(dyeKey)
	local goal = ns.GetGoal(dyeKey)
	local shortfall = math.max(0, goal - owned)

	local pigmentsNeeded = shortfall * perDye
	local availablePigments = supply.ownedPigments + supply.pigmentsFromHerbs
	local craftableNow = math.floor(availablePigments / perDye) -- dyes makeable right now
	local canCraftGoal = availablePigments >= pigmentsNeeded

	-- Split the craftable-now figure by source, so the UI can show them separately:
	-- dyes from pigments already held, vs dyes from milling the flowers on hand.
	-- (PIGMENTS_PER_DYE is 1, so these are just the pigment / herb-pigment counts.)
	local craftableFromPigments = math.floor(supply.ownedPigments / perDye)
	local craftableFromHerbs = math.floor(supply.pigmentsFromHerbs / perDye)

	-- What's missing to hit the goal: pigments beyond those already held, the herbs
	-- to mill for them, and how many MORE herbs to gather. Current herbs already
	-- cover `pigmentsFromHerbs` of the needed pigments, and because milling needs 10
	-- of the same herb, each remaining pigment needs a fresh stack of 10.
	local pigmentsShort = math.max(0, pigmentsNeeded - supply.ownedPigments)
	local herbsNeeded = pigmentsShort * perPigment
	local herbsShort = math.max(0, pigmentsShort - supply.pigmentsFromHerbs) * perPigment

	return {
		key = dyeKey,
		color = color,
		owned = owned,
		goal = goal,
		shortfall = shortfall,
		pigment = supply.pigment,
		ownedPigments = supply.ownedPigments,
		ownedHerbs = supply.ownedHerbs,
		herbsPerPigment = perPigment,
		pigmentsPerDye = perDye,
		pigmentsNeeded = pigmentsNeeded,
		pigmentsShort = pigmentsShort,   -- pigments still to mill
		herbsNeeded = herbsNeeded,       -- herbs to mill those pigments
		herbsShort = herbsShort,         -- herbs still to gather/buy
		craftableNow = craftableNow,     -- dyes makeable right now from this colour
		craftableFromPigments = craftableFromPigments, -- dyes from pigments held
		craftableFromHerbs = craftableFromHerbs,       -- dyes from milling flowers held
		canCraftGoal = canCraftGoal,     -- can current supply close the shortfall?
		herbs = supply.herbs,
	}
end

-- Craft-vs-buy breakdown for a dye's expand view. One dye costs 10 of a SINGLE
-- flower to mill, so crafting via a flower costs 10 × that flower's unit price;
-- compared to the dye's own price, that says whether it's cheaper to craft or buy.
-- Per flower: how many you hold, how many dyes that makes, its craft cost, and the
-- craft-vs-buy verdict. Flowers are ordered cheapest-to-craft first.
function ns.GetCraftBreakdown(dyeKey)
	local dye = ns.byKey[dyeKey]
	if not dye or dye.kind ~= "dye" then return nil end

	local perDye = ns.HERBS_PER_PIGMENT * ns.PIGMENTS_PER_DYE -- flowers per dye (10)
	local dyePrice = ns.GetPrice(dyeKey)                       -- buy-outright cost, may be nil

	local hiddenHerbs = DyingDownTheHouseDB.ui.hiddenHerbs or {}
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
			-- true/false = cheaper to craft than buy / not; nil when a price is missing.
			local cheaper = nil
			if craftCost and dyePrice then cheaper = (craftCost < dyePrice) end
			flowers[#flowers + 1] = {
				key = herb.key,
				name = herb.name or ("Item " .. tostring(herb.id)),
				id = herb.id,
				have = have,
				dyesEach = math.floor(have / perDye),      -- dyes this flower alone can make
				price = price,                              -- flower unit price (nil if unscanned)
				craftCost = craftCost,                      -- 10 × price
				cheaperToCraft = cheaper,
			}
		end
	end

	-- Cheapest craft cost first; unscanned flowers last; then name.
	table.sort(flowers, function(a, b)
		if (a.craftCost ~= nil) ~= (b.craftCost ~= nil) then return a.craftCost ~= nil end
		if a.craftCost and b.craftCost and a.craftCost ~= b.craftCost then return a.craftCost < b.craftCost end
		return a.name < b.name
	end)

	return {
		key = dyeKey,
		color = dye.color,
		dyePrice = dyePrice,
		flowersPerDye = perDye,
		cheapestCraft = cheapestCraft,
		-- Overall verdict: is the cheapest craft path cheaper than buying?
		cheaperToCraft = (cheapestCraft and dyePrice) and (cheapestCraft < dyePrice) or nil,
		flowers = flowers,
	}
end

-- For the pigment reagent picker: is milling THIS flower worth it for `color`?
-- 10 flowers make one dye's worth of pigment, so compares 10 × flower price to the
-- best-priced dye of that colour (the most you could get out of the pigment).
-- Returns true (worth crafting), false (cost-prohibitive), or nil (price unknown).
function ns.GetHerbCraftVerdict(herbKey, color)
	local herbPrice = ns.GetPrice(herbKey)
	if not herbPrice then return nil end
	local craftCost = herbPrice * (ns.HERBS_PER_PIGMENT * ns.PIGMENTS_PER_DYE)

	local best
	for _, dye in ipairs(ns.DYES) do
		if dye.color == color then
			local p = ns.GetPrice(dye.key)
			if p and (not best or p > best) then best = p end
		end
	end
	if not best then return nil end
	return craftCost < best
end

-- Same, keyed by the herb's item ID (what the reagent picker hands us).
function ns.GetHerbCraftVerdictByID(itemID, color)
	local entry = ns.byID[itemID]
	if not entry then return nil end
	return ns.GetHerbCraftVerdict(entry.key, color)
end

--------------------------------------------------------------------------------
-- Search filter and sort (pure, over the dye list)
--------------------------------------------------------------------------------

-- Dyes matching `query` (case-insensitive substring). A dye matches when the
-- needle is found in its own name OR in its colour-family name — so "blue" finds
-- the dyes literally named "…Blue…" AND every dye whose family is blue. Empty or
-- nil query returns every dye, in Data.lua order.
function ns.FilterDyes(query)
	local out = {}
	local needle = query and query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, dye in ipairs(ns.DYES) do
		local match = not needle or needle == ""
			or dye.name:lower():find(needle, 1, true)
			or (dye.color and tostring(dye.color):lower():find(needle, 1, true)) and true
		if match then
			out[#out + 1] = dye
		end
	end
	return out
end

-- A new list sorted by `mode` and `dir` ("asc"/"desc"). Sorts a COPY so the
-- caller's list is untouched. Name is always the tiebreaker, ascending.
--   "alpha" — by name
--   "owned" — by account-wide count
--   "price" — by unit price; UNPRICED dyes always sort last, either direction
-- When `dir` is omitted, each mode's natural default is used (A–Z, most-owned,
-- highest-price), which is what keeps two-argument callers working.
-- Sortable columns and each one's natural default direction.
local VALID_SORT = {
	alpha = true, owned = true, goal = true, price = true,
	craft = true, craftpig = true, craftherb = true,
}
local DEFAULT_DIR = {
	alpha    = "asc",   -- A–Z
	owned    = "desc",  -- most owned first
	goal     = "desc",  -- biggest goals first
	price    = "desc",  -- most valuable first
	craft    = "desc",  -- most craftable first
	craftpig = "desc",  -- most craftable from pigments first
	craftherb = "desc", -- most craftable from flowers first
}

-- The value(s) a mode sorts on, per dye: a primary and an optional secondary that
-- breaks ties before the name. `craftherb` (the Flowers column) ties by dyes
-- craftable, then by flowers HELD, so equal-craftable rows still read biggest-pile
-- first. Primary nil means "no value" (price only — unpriced sorts last).
local function MetricPair(mode, key)
	if mode == "owned" then return ns.GetTotal(key) end
	if mode == "goal"  then return ns.GetGoal(key) end
	if mode == "price" then return ns.GetPrice(key) end          -- may be nil
	if mode == "craft" or mode == "craftpig" or mode == "craftherb" then
		local rc = ns.GetRecipeStatus(key)
		if not rc then return 0, 0 end
		if mode == "craftpig"  then return rc.craftableFromPigments, rc.ownedPigments end
		if mode == "craftherb" then return rc.craftableFromHerbs, rc.ownedHerbs end
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
	local ui = DyingDownTheHouseDB and DyingDownTheHouseDB.ui or {}
	local hidden = ui.hiddenDyes or {}
	local shown = {}
	for _, d in ipairs(ns.FilterDyes(ui.search)) do
		if not hidden[d.key] then shown[#shown + 1] = d end
	end
	return ns.SortDyes(shown, ui.sort, ui.sortDir)
end

function ns.IsDyeHidden(key)
	return (DyingDownTheHouseDB.ui.hiddenDyes[key] == true)
end

function ns.SetDyeHidden(key, hidden)
	DyingDownTheHouseDB.ui.hiddenDyes[key] = hidden and true or nil
	ns.Refresh()
end

-- Show or hide every dye at once (the Check All / Uncheck All buttons).
function ns.SetAllDyesHidden(hidden)
	local h = DyingDownTheHouseDB.ui.hiddenDyes
	for _, dye in ipairs(ns.DYES) do h[dye.key] = hidden and true or nil end
	ns.Refresh()
end

-- Flowers are hidden by NAME (so all of a flower's quality tiers hide together).
function ns.IsHerbHidden(name)
	return name ~= nil and DyingDownTheHouseDB.ui.hiddenHerbs[name:lower()] == true
end

function ns.SetHerbHidden(name, hidden)
	if not name then return end
	DyingDownTheHouseDB.ui.hiddenHerbs[name:lower()] = hidden and true or nil
	ns.Refresh()
end

function ns.SetAllHerbsHidden(hidden)
	local h = DyingDownTheHouseDB.ui.hiddenHerbs
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

-- A string coloured letter-by-letter across a rainbow, for the flashy title.
-- Spaces are left uncoloured. Cheap enough to build once at login.
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
	DyingDownTheHouseDB.ui.search = text or ""
	ns.Refresh()
end

function ns.GetSearch()
	return DyingDownTheHouseDB.ui.search or ""
end

function ns.SetSort(mode, dir)
	if not VALID_SORT[mode] then return false end
	DyingDownTheHouseDB.ui.sort = mode
	DyingDownTheHouseDB.ui.sortDir = dir or DEFAULT_DIR[mode]
	ns.Refresh()
	return true
end

function ns.GetSort()
	local ui = DyingDownTheHouseDB and DyingDownTheHouseDB.ui or {}
	return ui.sort or "alpha", ui.sortDir or DEFAULT_DIR[ui.sort or "alpha"]
end

-- Header-click behaviour: clicking the active column flips its direction; clicking
-- a different column switches to it at that column's natural default direction.
function ns.CycleSort(mode)
	if not VALID_SORT[mode] then return end
	local ui = DyingDownTheHouseDB.ui
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
	local ui = DyingDownTheHouseDB.ui
	ui.search, ui.sort, ui.sortDir = "", "alpha", DEFAULT_DIR.alpha
	ns.Refresh()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

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

		DyingDownTheHouseDB = DyingDownTheHouseDB or {}
		ApplyDefaults(DyingDownTheHouseDB, defaults)

		local name, realm = UnitFullName("player")
		realm = realm or GetRealmName()
		charKey = name .. "-" .. realm
		DyingDownTheHouseDB.chars[charKey] = DyingDownTheHouseDB.chars[charKey] or {}

		local char = DyingDownTheHouseDB.chars[charKey]
		char.bags = char.bags or {}
		char.bank = char.bank or {}
		char.name = name
		char.realm = realm
		char.class = select(2, UnitClass("player"))

		-- Re-apply any item IDs learned by name matching in earlier sessions.
		for key, id in pairs(DyingDownTheHouseDB.learned) do
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
		if DyingDownTheHouseDB.ui.shown then ns.Show() end

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

SLASH_DYINGDOWNTHEHOUSE1 = "/dye"
SLASH_DYINGDOWNTHEHOUSE2 = "/dyes"
SLASH_DYINGDOWNTHEHOUSE3 = "/ddth"

local function Print(msg)
	print("|cffb388ffDyeing Down The House|r: " .. msg)
end

SlashCmdList.DYINGDOWNTHEHOUSE = function(msg)
	local cmd, rest = msg:lower():match("^(%S*)%s*(.-)$")
	-- The search term needs its original case preserved for display, so re-derive
	-- it from the untouched message rather than the lowercased copy.
	local _, rawRest = msg:match("^(%S*)%s*(.-)$")

	if cmd == "lock" then
		DyingDownTheHouseDB.ui.locked = true
		Print("frame locked.")
	elseif cmd == "unlock" then
		DyingDownTheHouseDB.ui.locked = false
		Print("frame unlocked — drag it anywhere.")
	elseif cmd == "reset" then
		DyingDownTheHouseDB.ui.point, DyingDownTheHouseDB.ui.relPoint = "CENTER", "CENTER"
		DyingDownTheHouseDB.ui.x, DyingDownTheHouseDB.ui.y, DyingDownTheHouseDB.ui.scale = 0, 0, 1.0
		if ns.RestorePosition then ns.RestorePosition() end
		Print("position reset.")
	elseif cmd == "hidezero" then
		DyingDownTheHouseDB.ui.hideZero = not DyingDownTheHouseDB.ui.hideZero
		ns.Refresh()
		Print("rows with zero dye are now " .. (DyingDownTheHouseDB.ui.hideZero and "hidden" or "shown") .. ".")
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
	elseif cmd == "options" or cmd == "config" then
		if ns.OpenOptions then ns.OpenOptions() end
	elseif cmd == "scan" then
		local ok, err = ns.StartScan()
		if not ok then Print(err or "cannot scan right now.") end
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
			for ck in pairs(DyingDownTheHouseDB.chars) do
				if ck:lower() == rest then target = ck end
			end
			if not target then
				Print("no character matching '" .. rest .. "'. Try /dye chars.")
			elseif target == ns.GetCharKey() then
				Print("can't forget the character you're logged into.")
			else
				DyingDownTheHouseDB.chars[target] = nil
				ns.Refresh()
				Print("forgot " .. target .. ".")
			end
		end
	elseif cmd == "help" then
		Print("commands:")
		print("  /dye — toggle the window")
		print("  /dye search <text> — filter by dye name or colour family (blank clears)")
		print("  /dye sort <alpha | price | owned> — change the order")
		print("  /dye scan — price the dyes from the auction house (at the AH)")
		print("  /dye hidezero — toggle hiding dyes you have none of")
		print("  /dye lock | unlock — freeze or free the frame")
		print("  /dye reset — recentre the frame")
		print("  /dye options — open the settings panel")
		print("  /dye chars — list characters and when they were last scanned")
		print("  /dye forget <Name-Realm> — drop a deleted character's data")
	else
		if ns.Toggle then ns.Toggle() end
	end
end

-- Addon Compartment (the button on the minimap's addon list).
function DyingDownTheHouse_OnAddonCompartmentClick()
	if ns.Toggle then ns.Toggle() end
end
