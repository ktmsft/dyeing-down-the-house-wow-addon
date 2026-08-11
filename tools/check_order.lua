-- Catches three Lua traps that WoW turns into silent feature outages. All of them
-- compile cleanly, so none shows up until the code path actually runs.
--
-- 1. A FORWARD REFERENCE to a file-scope local:
--
--      local function Helper() ... end        -- declared at line 200
--      function ns.Thing() Helper() end       -- written at line 100
--
--    The call above the declaration doesn't see the local at all. It compiles to a
--    global lookup, so there's no syntax error and no warning. When the caller runs
--    at file load, the whole file aborts partway and everything below it silently
--    never happens.
--
-- 2. A CALL TO A HELPER THAT ISN'T THERE:
--
--      local outer = FollowFrom(pane, {...})  -- FollowFrom was deleted in a refactor
--
--    Identical failure, different cause. A rewrite of Housing.lua dropped the
--    section defining FollowFrom, CopyArt and ArtBleed while leaving three calls to
--    them behind. Check 1 didn't fire — nothing was declared, so there was nothing
--    to be "before" — and the panel just stopped appearing with no error until the
--    code ran. Deleting a definition is at least as easy as misordering one, so
--    both are worth checking.
--
-- 3. A CONSTANT THAT WAS RENAMED:
--
--      for i = 1, #ORDER do                   -- ORDER is now ORDER_BY_TAB
--
--    Check 2 only looks at things being CALLED, so a bare read walked straight
--    past it: a nil global, an error on the first row built, and a window that
--    never appeared. Only ALL-CAPS names are checked, because every constant here
--    is written that way and a broader rule would flag every local in the file.
--
-- Run: luajit tools/check_order.lua

local FILES = { "Data.lua", "Core.lua", "Discover.lua", "Prices.lua", "UI.lua",
	"Options.lua", "Crafting.lua", "Housing.lua", "Probe.lua" }
local root = (arg[0]:match("^(.*[/\\])") or "") .. ".."
local sep = package.config:sub(1, 1)

-- Capitalised globals we legitimately call: WoW's API and Lua's own. Check 2 looks
-- only at names starting with a capital, because that's the convention every
-- helper in this addon follows and it keeps the list to something maintainable —
-- `pcall`, `ipairs` and friends never need listing.
--
-- Add to this when the addon starts calling a new Blizzard global. That's the
-- point: a new name here should be a deliberate "yes, the client provides this".
local KNOWN_GLOBALS = {
	-- frames and the UI
	CreateFrame = true, EnumerateFrames = true, UIParent = true,
	GameTooltip = true, GameTooltip_Hide = true, GameFontNormal = true,
	FauxScrollFrame_Update = true, FauxScrollFrame_GetOffset = true,
	FauxScrollFrame_SetOffset = true, FauxScrollFrame_OnVerticalScroll = true,
	Settings = true, StaticPopup_Show = true,
	-- player and world
	UnitFullName = true, UnitClass = true, GetRealmName = true,
	GetBuildInfo = true, GetInboxNumItems = true, GetInboxItemLink = true,
	-- namespaced APIs (called as C_Thing.Method, but listed for completeness)
	C_Timer = true, C_Item = true, C_Container = true, C_AuctionHouse = true,
	C_AddOns = true, C_DyeColor = true, C_TradeSkillUI = true,
	C_HousingCustomizeMode = true, C_HousingDecor = true,
	Enum = true, Constants = true,
	-- hooks and misc
	SlashCmdList = true, RunTimers = true, hooksecurefunc = true,
	GetCoinTextureString = true, STANDARD_TEXT_FONT = true,
	-- foreign addons we read through, feature-detected at every call site
	TSM_API = true, Auctionator = true, DataStore = true,
	OpenProfessionsItemFlyout = true, ProfessionsFrame = true,
}

-- Explicit paths override the addon's own files, so the check can be tested
-- against a file that deliberately contains the bug.
local explicit = #arg > 0
if explicit then
	FILES = arg
	root, sep = ".", ""
end

local problems = 0

for _, file in ipairs(FILES) do
	local path = explicit and file or (root .. sep .. file)
	local handle = io.open(path, "r")
	if not handle then
		-- A file listed here may not exist yet during early scaffolding; that is
		-- not a forward-reference bug, so note it and move on rather than failing.
		print(("  (skipping %s — not present)"):format(file))
	else
		local lines = {}
		for line in handle:lines() do lines[#lines + 1] = line end
		handle:close()

		-- Every name this file defines, however it defines it. Check 2 needs all of
		-- them; check 1 only cares about the `local function` ones, because those
		-- are the ones whose declaration line is meaningful.
		-- Reduce each line to just its code before scanning.
		--
		-- Strings are blanked first, or a perfectly ordinary bit of prose inside one
		-- — `W("-- the DyeSelectionPopout (grid) --")` — reads as a call to a
		-- function named DyeSelectionPopout.
		--
		-- Then trailing comments go, or a note ABOUT a function counts as a use of
		-- it: `local PANEL_GAP = 10  -- fallback; PanelGap() measures the real one`
		-- was reported as calling PanelGap 76 lines before its declaration. Strings
		-- have to be blanked first so a `--` inside one isn't mistaken for the start
		-- of a comment. Crude, but a tokenizer is not worth writing here.
		local code = {}
		for n, line in ipairs(lines) do
			code[n] = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"):gsub("%-%-.*$", "")
		end

		local declaredAt, defined = {}, {}
		for n, line in ipairs(code) do
			-- Nested helpers are indented, so this must not anchor hard to the line
			-- start — `local function` inside a `do` block or another function still
			-- defines the name.
			local name = line:match("^%s*local function%s+([%w_]+)")
			if name then
				-- Only a TOP-LEVEL local can be forward-referenced in the way check 1
				-- is about; a nested one is scoped to its block. Record the line only
				-- for the unindented ones, but count both as defined.
				if line:match("^local function") and not declaredAt[name] then
					declaredAt[name] = n
				end
				defined[name] = true
			end
			-- `local Name`, `local Name = ...`, `local A, B = ...`
			local locals = line:match("^%s*local%s+([%w_,%s]+)")
			if locals then
				for word in locals:gmatch("[%w_]+") do
					if word ~= "function" then defined[word] = true end
				end
			end
			-- `function Name(`, `function ns.Name(`, `function obj:Name(`
			local fnName = line:match("^%s*function%s+([%w_]+)%s*%(")
			if fnName then defined[fnName] = true end
			-- Loop variables and function parameters are locals too.
			local forNames = line:match("^%s*for%s+([%w_,%s]+)%s+in")
				or line:match("^%s*for%s+([%w_]+)%s*=")
			if forNames then
				for word in forNames:gmatch("[%w_]+") do defined[word] = true end
			end
			local params = line:match("function%s*[%w_.:]*%s*%(([^)]*)%)")
			if params then
				for word in params:gmatch("[%w_]+") do defined[word] = true end
			end
		end

		for n, line in ipairs(code) do
			if not line:match("^%s*%-%-") then
				-- 1. forward references
				for name, declLine in pairs(declaredAt) do
					if n < declLine and line:find("[^%w_]" .. name .. "%s*%(") then
						print(("  %s:%d calls %s(), declared at line %d")
							:format(file, n, name, declLine))
						problems = problems + 1
					end
				end

				-- 2. calls to helpers that were never defined. The whole dotted token
				-- is captured so `pane:GetPreviewDyeInfos()` and `C_Item.GetItemInfo()`
				-- can be recognised as field access and skipped — whether THOSE exist
				-- is a runtime question about somebody else's table, not ours. And a
				-- token has to START with a capital, so `setAll(` is not read as a
				-- call to `All`.
				for token in line:gmatch("([%w_%.:]+)%s*%(") do
					if not token:find("[%.:]") and token:match("^[A-Z]")
						and not defined[token] and not KNOWN_GLOBALS[token] then
						print(("  %s:%d calls %s(), which is never defined in this file")
							:format(file, n, token))
						problems = problems + 1
					end
				end

				-- 3. an UPPER_CASE constant that isn't defined here. Check 2 only looks
				-- at things being CALLED, so `for i = 1, #ORDER do` sailed straight past
				-- it after ORDER was renamed ORDER_BY_TAB: a nil global, an error on the
				-- first row built, and a window that never appeared.
				--
				-- Narrowed to ALL-CAPS on purpose. Every constant in this addon is
				-- written that way, while checking every capitalised identifier would
				-- flag each local frame, entry and widget in the file. A tight rule that
				-- stays on is worth more than a broad one that gets switched off.
				-- A name with `=` after it is being WRITTEN, not read: a global this
				-- addon deliberately sets (SLASH_DYEINGDOWNTHEHOUSE1), or a key in a
				-- table constructor (`{ ID = 11 }`). Neither is a lookup that can come
				-- back nil, so neither is this check's business. `==` is a comparison
				-- and stays in scope.
				local assigned = {}
				for name in line:gmatch("([%w_]+)%s*=[^=]") do assigned[name] = true end

				for token in line:gmatch("([%w_%.:]+)") do
					if not token:find("[%.:]") and #token > 1
						and token:match("^[A-Z][A-Z0-9_]*$")
						and not assigned[token]
						and not defined[token] and not KNOWN_GLOBALS[token] then
						print(("  %s:%d reads %s, which is never defined in this file")
							:format(file, n, token))
						problems = problems + 1
					end
				end
			end
		end
	end
end

if problems > 0 then
	print(("\n%d problem(s) — these fail at runtime, not at compile time.")
		:format(problems))
	os.exit(1)
end

print("no forward references or undefined helpers")
