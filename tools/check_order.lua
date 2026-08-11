-- Catches a Lua trap that WoW turns into a silent feature outage:
--
--   local function Helper() ... end        -- declared at line 200
--   function ns.Thing() Helper() end       -- written at line 100
--
-- The call above the declaration doesn't see the local at all. It compiles to a
-- global lookup, so there's no syntax error and no warning — it fails only when
-- that code path runs. When the caller runs at file load, the whole file aborts
-- partway and everything below it silently never happens.
--
-- Run: luajit tools/check_order.lua

local FILES = { "Data.lua", "Core.lua", "Prices.lua", "UI.lua", "Options.lua",
	"Housing.lua", "Probe.lua" }
local root = (arg[0]:match("^(.*[/\\])") or "") .. ".."
local sep = package.config:sub(1, 1)

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

		-- Where each file-scope local function is declared.
		local declaredAt = {}
		for n, line in ipairs(lines) do
			local name = line:match("^local function%s+([%w_]+)")
			if name and not declaredAt[name] then declaredAt[name] = n end
		end

		-- Any use of one of those names on an earlier line is the bug. Comments
		-- are skipped, and so is the declaration line itself.
		for n, line in ipairs(lines) do
			if not line:match("^%s*%-%-") then
				for name, declLine in pairs(declaredAt) do
					if n < declLine and line:find("[^%w_]" .. name .. "%s*%(") then
						print(("  %s:%d calls %s(), declared at line %d")
							:format(file, n, name, declLine))
						problems = problems + 1
					end
				end
			end
		end
	end
end

if problems > 0 then
	print(("\n%d forward reference(s) to file-scope locals — these fail at runtime, not at compile time.")
		:format(problems))
	os.exit(1)
end

print("no forward references to file-scope locals")
