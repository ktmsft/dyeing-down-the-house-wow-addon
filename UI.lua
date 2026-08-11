-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- UI.lua — the on-screen window.
--
-- A movable, resizable window showing one row per color:
--
--   Color | Have | Flowers | Makeable | Cost | Dye Needed
--
-- Open a row and it shows the flowers that color is made from, cheapest first, and
-- the shades that color can paint.
--
-- This had TWO tabs until 12.1, and losing them is the single biggest change in
-- here. They existed because a dye and a color family were different things: 62 dye
-- items each with their own count and goal, sitting on top of a pigment pile and a
-- flower pool that belonged to the family. Printing the family's figures on all six
-- black rows implied six stockpiles where there was one, so the family view stated
-- them once and the dye view answered "how am I doing on THIS dye".
--
-- 12.1 collapsed the 62 into nine, one per color. The dye IS the family now, both
-- tabs were showing the same nine rows, and keeping them would have been two names
-- for one list. The shades live on as names you can paint — so they're what you get
-- when you open a row, which is exactly where the flowers already were.
--
-- Optional columns can be hidden from the options panel; hidden columns reflow away.
-- Clickable headers sort. All data comes from Core.
--------------------------------------------------------------------------------

local ROW_H   = 22
local MAXROWS = 40
local HEIGHT_MIN, HEIGHT_MAX = 200, 900
-- The window has a natural "column-fit" width (see ComputeFrameWidth). The user may
-- drag it narrower or wider within this slack: shrinking is capped so the leftmost
-- data header can't collide with the "Dye" header; growing is capped so the flexible
-- Dye-name column can't balloon. Both bounds ride the fit width, so they shift as
-- columns are shown/hidden and the window can never scale out of control.
local WIDTH_SHRINK, WIDTH_GROW = 60, 240
-- Where the column headers sit, and where the list starts under them. Both came
-- up by the height of the tab strip when the second view was removed.
local HEADER_Y = 70
local TOP_INSET = 94
local BOT_INSET = 14
local COLLAPSED_H = 34   -- height of the title-bar strip when collapsed
local ROW_RIGHT = -30          -- a row's right edge, in frame-right coordinates
local GAP, MARGIN = 8, 6

-- One view, one column set. Every column is per-color, because a color is all
-- there is now: one dye item, one flower pool, one goal.
--
-- `Pigment` is gone with the pigments. The Makeable column absorbed what it was
-- really for — "can I close this gap without going shopping" — and now answers it
-- in one number instead of two.
local COLDEF = {
	owned   = { header = "Have",    sort = "owned",     w = 44,
		hint = "Housing dyes of this color across every character, bank and the Warband bank." },
	flowers = { header = "Flowers", sort = "craftherb", w = 66, optional = true,
		hint = "Flowers of this color you hold, and in ( ) how many dyes they'd make.\nTen of the SAME flower make one dye." },
	makeable = { header = "Makeable", sort = "craft",   w = 70, optional = true,
		hint = "Dyes of this color you could make right now from the flowers on hand.\nTen of the SAME flower make one dye, so odd remainders don't add up." },
	-- Was "Value" — a dye's auction price — until dyes went Warband-bound and stopped
	-- having one. What's left that's still a number is what it costs to MAKE, so
	-- that's what the column shows. The key and sort mode keep their old names so
	-- saved column and sort preferences carry over.
	value   = { header = "Cost",    sort = "price",     w = 72, optional = true,
		hint = "What one costs to make: ten of this color's cheapest flower.\n(Dyes are Warband-bound, so there's no price to buy one at.)" },
	-- Wide enough for a four-figure shortfall: a goal of 500 on a color you own 10 of
	-- is an ordinary thing to set, and 48px clipped it.
	goal    = { header = "Dye Needed", sort = "goal",   w = 68, optional = true,
		hint = "How many of this color you want. The window counts down to it, and the\nhouse dye panel can set it while you're looking at the decor." },
}

-- Right to left.
local ORDER = { "goal", "value", "makeable", "flowers", "owned" }

local function ActiveOrder()
	return ORDER
end

-- Teal is gone from the game, and gone from here. A saved preference naming it
-- migrates to blue (see Core's Migrate); nothing should ever ask for the swatch.
local SWATCH = {
	black  = { 0.32, 0.32, 0.34 }, blue   = { 0.25, 0.45, 0.95 },
	brown  = { 0.55, 0.38, 0.22 }, green  = { 0.32, 0.72, 0.34 },
	orange = { 0.96, 0.56, 0.16 }, purple = { 0.62, 0.32, 0.85 },
	red    = { 0.87, 0.26, 0.26 },
	white  = { 0.95, 0.95, 0.95 }, yellow = { 0.96, 0.86, 0.22 },
}
local ACCENT = { 0.70, 0.53, 1.00 }

-- Shared with Options.lua so its dye list can show matching color swatches.
ns.SWATCH = SWATCH
ns.ACCENT = ACCENT

local frame, scroll, scrollBar, rows, searchBox, titleFS
local headers = {}
local layout = {}
local sepCount = 0   -- how many column dividers are currently visible (per color row)
local visible = 12

-- Very short "how long ago" for the scan stamp: now / 5m / 2h / 3d.
local function ShortAge(ts)
	if not ts then return nil end
	local d = time() - ts
	if d < 60 then return "now" end
	if d < 3600 then return math.floor(d / 60) .. "m" end
	if d < 86400 then return math.floor(d / 3600) .. "h" end
	return math.floor(d / 86400) .. "d"
end

-- The price source a scan would use right now, or nil if Prices.lua isn't loaded
-- (in which case Core's AH scan is all there is and the button behaves as it always
-- did). Resolved fresh each time: the player can install or unload TSM mid-session.
local function ActivePriceSource()
	if not ns.ResolvePriceSource then return nil end
	local ok, source = pcall(ns.ResolvePriceSource)
	return ok and source or nil
end

-- Rainbow or plain title, per the ui.rainbowTitle toggle. Exposed so the options
-- checkbox can re-apply it live.
function ns.ApplyTitleColor()
	if not titleFS then return end
	if DyeingDownTheHouseDB.ui.rainbowTitle then
		titleFS:SetText(ns.RainbowText("Dyeing Down The House"))
	else
		titleFS:SetText("Dyeing Down The House")
		titleFS:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ColShown(key)
	if not COLDEF[key].optional then return true end
	return DyeingDownTheHouseDB.ui.cols[key] ~= false
end

-- The window width is DERIVED from which columns are shown, never dragged: a base
-- (the Dye name + always-on Owned column and chrome) plus each visible optional
-- column's width and gap. Hiding a column shrinks the window by exactly that much,
-- leaving the Dye-name column the same width. Height is the only user-sized axis.
local BASE_W = 300
local function ComputeFrameWidth()
	local w = BASE_W
	for _, key in ipairs(ActiveOrder()) do
		-- "owned" is folded into BASE_W as the always-present first data column.
		if key ~= "owned" and ColShown(key) then
			w = w + COLDEF[key].w + GAP
		end
	end
	return w
end

-- Sort caret sprite: an arrow lifted from the Auction House texture sheet (path and
-- tex-coords verified against the sheet). Ascending shows it as-is; descending flips
-- it vertically by swapping the V (top/bottom) coords — done this way rather than
-- SetRotation, which fights SetTexCoord on the same texture. Declared above Refresh
-- (which reads them) so they're never a forward reference to a file-scope local.
local SORT_ARROW_TEX  = "Interface\\AuctionFrame\\AuctionHouse"
local SORT_ARROW_UP   = { 0.19844, 0.22969, 0.96562, 0.99687 }
local SORT_ARROW_DOWN = { 0.19844, 0.22969, 0.99687, 0.96562 } -- same region, V flipped

-- Flavor for the scan overlay. The icon is the Mighty Caravan Brutosaur's — a real
-- FileDataID probed in-game via C_MountJournal (never guessed). nil = text only.
local BRUTOSAUR_ICON = 6075464
local function BrutosaurFlavor()
	local icon = BRUTOSAUR_ICON and ("|T" .. BRUTOSAUR_ICON .. ":20:20|t ") or ""
	return icon .. "Hold your brutosaurs..."
end

local function FormatMoney(copper)
	if not copper then return "—" end
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	if g > 0 then return ("%dg"):format(g) end
	if s > 0 then return ("%ds"):format(s) end
	return ("%dc"):format(copper % 100)
end

local function ResetScroll()
	if scrollBar then scrollBar:SetValue(0) end
	FauxScrollFrame_SetOffset(scroll, 0)
end

-- A colored square, inline in text, via a white texture with a vertex tint (the
-- last three escape params are 0–255 RGB). Renders in tooltips and font strings.
local function SwatchIcon(color)
	local c = SWATCH[color] or { 0.6, 0.6, 0.6 }
	return ("|TInterface\\Buttons\\WHITE8X8:12:12:0:0:8:8:0:8:0:8:%d:%d:%d|t")
		:format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

--------------------------------------------------------------------------------
-- Tooltip
--------------------------------------------------------------------------------

-- One tooltip, because there's one kind of data row now. What the color holds, what
-- it could make, how far off the goal is, and which of its flowers are wanted by
-- another color too — that last one being the thing a per-color view would
-- otherwise hide completely.
local function ShowColorTooltip(row)
	local color = row.color
	if not color then return end
	local rc = ns.GetRecipeStatus(color)
	if not rc then return end
	local dye = ns.byKey[color]

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(SwatchIcon(color) .. " " .. color:gsub("^%l", string.upper),
		ACCENT[1], ACCENT[2], ACCENT[3])
	if dye and dye.name then
		GameTooltip:AddLine(dye.name .. (dye.id and "" or "   (not seen yet)"), 0.7, 0.7, 0.7)
	end

	GameTooltip:AddDoubleLine("Held", rc.owned, 0.8, 0.8, 0.8, 1, 1, 1)
	if rc.goal > 0 then GameTooltip:AddDoubleLine("Needed", rc.goal, 0.8, 0.8, 0.8, 1, 1, 1) end
	GameTooltip:AddDoubleLine("Flowers held",
		("%d (%d more dyes)"):format(rc.ownedHerbs, rc.craftableNow),
		0.8, 0.8, 0.8, 0.6, 0.9, 0.6)
	GameTooltip:AddDoubleLine("Makeable now", rc.craftableNow, 0.8, 0.8, 0.8, 0.5, 1, 0.5)

	if rc.goal > 0 and rc.shortfall > 0 then
		if rc.canCraftGoal then
			GameTooltip:AddLine(("Make %d more to reach it"):format(rc.shortfall), 0.4, 0.9, 0.4)
		else
			GameTooltip:AddLine(("Short %d dye (%d more flowers)"):format(rc.shortfall, rc.herbsShort),
				0.95, 0.6, 0.3)
		end
	end

	-- The shades this one dye paints. The whole point of 12.1: it isn't "a Midnight
	-- Blue Dye" any more, it's a Blue Housing Dye that does all of these.
	local shades = rc.shades or {}
	if #shades > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(("Paints %d colors:"):format(#shades), 0.7, 0.7, 0.7)
		local names = {}
		for i = 1, math.min(#shades, 6) do
			names[#names + 1] = shades[i].name .. (shades[i].guess and "?" or "")
		end
		local line = table.concat(names, ", ")
		if #shades > 6 then line = line .. (", and %d more"):format(#shades - 6) end
		GameTooltip:AddLine("   " .. line, 0.8, 0.8, 0.8, true)
	end

	-- Flowers that feed more than one family. Spending them here denies them there.
	local shared = {}
	for _, herb in ipairs(rc.herbs or {}) do
		if herb.have > 0 and #(herb.colors or {}) > 1 then shared[#shared + 1] = herb end
	end
	if #shared > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Flowers also wanted elsewhere:", 0.95, 0.8, 0.4)
		for i = 1, math.min(#shared, 5) do
			local herb = shared[i]
			local others = {}
			for _, c in ipairs(herb.colors) do
				if c ~= color then others[#others + 1] = c end
			end
			GameTooltip:AddLine(("   %s x%d — also %s"):format(herb.name, herb.have,
				table.concat(others, ", ")), 0.8, 0.8, 0.8)
		end
		if #shared > 5 then
			GameTooltip:AddLine(("   ...and %d more"):format(#shared - 5), 0.6, 0.6, 0.6)
		end
	end

	GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function CreateRow(index)
	local row = CreateFrame("Button", nil, scroll)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", 2, -((index - 1) * ROW_H))
	row:SetPoint("TOPRIGHT", -2, -((index - 1) * ROW_H))

	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(1, 1, 1, 0.06)

	-- Expanded-block chrome -------------------------------------------------
	-- An expanded flower list has no columns, so against a row that does it reads as
	-- a row whose columns have gone wrong. These give the block its own container:
	-- a faint fill (shared with the opened row above it, so the two read as one
	-- panel), a color stripe down the left tying it to the family it belongs to, and
	-- a hairline closing the bottom.
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.035)
	row.bg:Hide()

	row.stripe = row:CreateTexture(nil, "BORDER")
	row.stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 8, 0)
	row.stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 0)
	row.stripe:SetWidth(2)
	row.stripe:Hide()

	row.capBottom = row:CreateTexture(nil, "BORDER")
	row.capBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 0)
	row.capBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 0)
	row.capBottom:SetHeight(1)
	row.capBottom:Hide()

	-- Color-row widgets -----------------------------------------------------
	row.expander = row:CreateTexture(nil, "OVERLAY")
	row.expander:SetSize(14, 14)
	row.expander:SetPoint("LEFT", 3, 0)

	row.swatch = row:CreateTexture(nil, "ARTWORK")
	row.swatch:SetSize(10, 10)
	row.swatch:SetPoint("LEFT", 20, 0)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)


	row.cells = {}
	for key in pairs(COLDEF) do
		if key ~= "goal" then
			local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetJustifyH("CENTER")
			row.cells[key] = fs
		end
	end

	local goal = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	goal:SetHeight(ROW_H - 6)
	goal:SetAutoFocus(false)
	goal:SetNumeric(true)
	goal:SetJustifyH("CENTER")
	local function CommitGoal(self)
		if row.color then ns.SetGoal(row.color, self:GetNumber()) end
	end
	goal:SetScript("OnEnterPressed", function(self) CommitGoal(self); self:ClearFocus() end)
	goal:SetScript("OnEditFocusLost", CommitGoal)
	goal:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.Refresh() end)
	row.goalBox = goal

	-- Green check when the goal is covered by dyes actually HELD. Positioned to the
	-- right of the goal box by the column layout (ApplyColumnLayout).
	row.goalCheck = row:CreateTexture(nil, "OVERLAY")
	row.goalCheck:SetSize(13, 13)
	row.goalCheck:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
	row.goalCheck:Hide()

	-- Sub-row widgets, shared by the flower rows and the shade rows. Both are an
	-- icon or swatch, a name, and a line of detail hanging off it, so one set of
	-- three does for both rather than two sets that would have to stay in step.
	row.fIcon = row:CreateTexture(nil, "ARTWORK")
	row.fIcon:SetSize(14, 14)
	row.fIcon:SetPoint("LEFT", 32, 0) -- clear of the block's left stripe
	row.fName = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.fName:SetPoint("LEFT", row.fIcon, "RIGHT", 6, 0)
	row.fName:SetJustifyH("LEFT") -- no fixed width, so the detail hugs the name
	row.fDetail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.fDetail:SetPoint("LEFT", row.fName, "RIGHT", 10, 0)
	row.fDetail:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	row.fDetail:SetJustifyH("LEFT")
	row.fDetail:SetWordWrap(false) -- keep it a single line; never wrap the verdict

	-- Column dividers live ON the row (one per column boundary) so they only show
	-- on color rows — the expanded sub-rows stay clean, no lines through them.
	row.seps = {}
	for i = 1, #ORDER do
		local s = row:CreateTexture(nil, "ARTWORK")
		s:SetColorTexture(1, 1, 1, 0.07)
		s:SetWidth(1)
		row.seps[i] = s
	end

	row:RegisterForClicks("LeftButtonUp")
	row:SetScript("OnClick", function()
		-- A color row opens onto its flowers and its shades. Nothing else is clickable.
		if row.entryKind == "color" and row.color then
			ns.ToggleColor(row.color)
			ResetScroll()
		end
	end)
	row:SetScript("OnEnter", function()
		if row.entryKind == "color" then ShowColorTooltip(row) end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)

	return row
end

-- The three row shapes: a color row, and the two kinds of sub-row it opens onto.
-- Each owns the name's anchors outright.

-- A color: expander, swatch, color name, then its columns. These are real cells in
-- the laid-out grid, not a run-on line of text, so they line up under their headers.
local BLOCK_FILL = 0.035 -- the expanded panel's tint
local BLOCK_HEAD = 0.055 -- the opened row itself, a touch stronger

-- Reset the expanded-block chrome, then tint the row if it's the head of an open
-- block so the panel appears to start at the row you clicked.
local function ClearBlockChrome(row, open)
	row.stripe:Hide(); row.capBottom:Hide()
	row.hl:SetAlpha(1)
	if open then
		row.bg:SetColorTexture(1, 1, 1, BLOCK_HEAD)
		row.bg:Show()
	else
		row.bg:Hide()
	end
end

local function SetColorMode(row, open)
	ClearBlockChrome(row, open)
	row.expander:Show(); row.swatch:Show(); row.name:Show()
	row.name:ClearAllPoints()
	row.name:SetWidth(0)
	row.name:SetPoint("LEFT", row.swatch, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row, "RIGHT", layout.name_r or -180, 0)
	for key, fs in pairs(row.cells) do fs:SetShown(layout[key] ~= nil) end
	-- The goal box lives on the color row now. It used to be a per-dye field, and
	-- there is no per-dye any more: you stock a color.
	row.goalBox:SetShown(layout.goal ~= nil)
	for i, s in ipairs(row.seps) do s:SetShown(i <= sepCount) end
	row.fIcon:Hide(); row.fName:Hide(); row.fDetail:Hide()
end

-- A sub-row: a flower, or a shade. `color` tints the block's stripe to the family
-- it belongs to; `last` closes the bottom edge, so a run of them reads as one panel
-- hanging off the row above rather than as more list items with broken columns.
local function SetSubMode(row, color, last)
	row.expander:Hide(); row.swatch:Hide(); row.name:Hide()
	for _, fs in pairs(row.cells) do fs:Hide() end
	row.goalBox:Hide(); row.goalCheck:Hide()
	-- No column dividers: this block has no columns, and drawing them here is exactly
	-- what made the layout look broken.
	for _, s in ipairs(row.seps) do s:Hide() end
	row.fIcon:Show(); row.fName:Show(); row.fDetail:Show()

	row.bg:SetColorTexture(1, 1, 1, BLOCK_FILL)
	row.bg:Show()
	local sw = SWATCH[color] or { 0.55, 0.55, 0.6 }
	row.stripe:SetColorTexture(sw[1], sw[2], sw[3], 0.8)
	row.stripe:Show()
	row.capBottom:SetColorTexture(1, 1, 1, 0.22)
	row.capBottom:SetShown(last and true or false)
	-- Nothing happens when you click a sub-row, so don't imply otherwise.
	row.hl:SetAlpha(0)
end

--------------------------------------------------------------------------------
-- Column layout — recompute positions from the current column config
--------------------------------------------------------------------------------

function ns.ApplyColumnLayout()
	if not frame then return end

	-- Pack visible fixed columns right-to-left; record separator boundaries.
	layout = {}
	local bounds = {}
	local x = -MARGIN
	for _, key in ipairs(ActiveOrder()) do
		if ColShown(key) then
			local w = COLDEF[key].w
			layout[key] = { r = x, w = w }
			x = x - w
			bounds[#bounds + 1] = x - GAP / 2
			x = x - GAP
		end
	end
	layout.name_r = x
	sepCount = #bounds

	-- Position row cells and the per-row column dividers. The name is deliberately
	-- NOT anchored here: each row mode anchors it differently (a color header hugs
	-- its name to leave room for the summary), so they own it and read layout.name_r
	-- for themselves.
	for _, row in ipairs(rows) do
		for key, def in pairs(COLDEF) do
			local L = layout[key]
			local widget = (key == "goal") and row.goalBox or row.cells[key]
			widget:ClearAllPoints()
			if L then
				if key == "goal" then
					-- A narrow entry field with the achieved-check tucked to its right:
					-- the check sits at the column's right edge, the box just left of it.
					local CHECK_SLOT = 16
					row.goalCheck:ClearAllPoints()
					row.goalCheck:SetPoint("RIGHT", row, "RIGHT", L.r - 3, 0)
					widget:SetSize(L.w - 6 - CHECK_SLOT, ROW_H - 6)
					widget:SetPoint("RIGHT", row.goalCheck, "LEFT", -3, 0)
				else
					widget:SetPoint("RIGHT", row, "RIGHT", L.r, 0)
					widget:SetWidth(L.w)
				end
				widget:Show()
			else
				widget:Hide()
			end
		end
		for i, s in ipairs(row.seps) do
			s:ClearAllPoints()
			if bounds[i] then
				s:SetPoint("TOP", row, "TOPRIGHT", bounds[i], 0)
				s:SetPoint("BOTTOM", row, "BOTTOMRIGHT", bounds[i], 0)
			end
		end
	end

	-- Position headers.
	for key, def in pairs(COLDEF) do
		local h = headers[key]
		local L = layout[key]
		if L then
			h:ClearAllPoints()
			h:SetPoint("TOPRIGHT", frame, "TOPRIGHT", L.r + ROW_RIGHT, -HEADER_Y)
			h:SetWidth(L.w)
			h:Show()
		else
			h:Hide()
		end
	end

	-- Set the width bounds from the current column-fit width, then apply the user's
	-- saved width clamped into them (so hiding a column pulls an over-wide window in,
	-- and showing one pushes a too-narrow window out). Untouched while collapsed.
	if not DyeingDownTheHouseDB.ui.collapsed then
		local fit = ComputeFrameWidth()
		local minW, maxW = fit - WIDTH_SHRINK, fit + WIDTH_GROW
		if frame.SetResizeBounds then frame:SetResizeBounds(minW, HEIGHT_MIN, maxW, HEIGHT_MAX) end
		local ui = DyeingDownTheHouseDB.ui
		local w = math.max(minW, math.min(maxW, ui.width or fit))
		ui.width = w
		frame:SetWidth(w)
	end
end

--------------------------------------------------------------------------------
-- Layout (visible-row count) and Refresh
--------------------------------------------------------------------------------

local function Layout()
	local h = scroll:GetHeight()
	visible = math.max(1, math.min(MAXROWS, math.floor(h / ROW_H)))
	for i = 1, MAXROWS do
		if rows[i] then rows[i]:SetShown(false) end
	end
end

-- The Flowers cell reads "held (dyes makeable)": how many flowers of that color the
-- account holds, and in parentheses how many dyes that stock would make right now.
local function HeldCell(held, dyes)
	local text = ("%d (%d)"):format(held, dyes)
	if dyes > 0 then return text, 0.65, 0.95, 0.65 end   -- can make some now
	if held > 0 then return text, 0.9, 0.9, 0.9 end       -- have stock, not enough yet
	return text, 0.45, 0.45, 0.45                          -- nothing
end

local function CellValue(key, dye, rc)
	if key == "owned" then
		return ns.GetTotal(dye.key), 1, 1, 1
	elseif key == "flowers" then
		return HeldCell(rc and rc.ownedHerbs or 0, rc and rc.craftableNow or 0)
	elseif key == "makeable" then
		local n = rc and rc.craftableNow or 0
		if n > 0 then return n, 0.5, 0.87, 0.5 end
		return n, 0.45, 0.45, 0.45
	elseif key == "value" then
		-- What one costs to make — ten of the cheapest flower of its color. There's no
		-- sale price to show any more (Warband-bound), and this is the number you
		-- actually compare across colors now: which of these is cheap to make today.
		local c = ns.GetCraftCost(dye.key)
		local text = c and ("~%s/ea"):format(FormatMoney(c)) or "—"
		return text, c and 1 or 0.4, c and 0.9 or 0.4, c and 0.4 or 0.4
	end
end

function ns.Refresh()
	if not frame or not frame:IsShown() then return end
	-- Collapsed to the title bar: don't touch the list (it re-shows the scroll frame,
	-- which would spill the rows out below the short bar on any bag/loot refresh).
	if DyeingDownTheHouseDB.ui.collapsed then return end

	local sort, dir = ns.GetSort()

	-- Sort caret is a real sprite (a scrollbar arrow atlas), tinted to the accent and
	-- flipped 180° for descending. A rotatable Texture means one "up" atlas covers
	-- both directions. Only clients missing the atlas fall back to an ASCII caret.
	local fallback = (dir == "asc") and " ^" or " v"
	for _, h in pairs(headers) do
		local on = (h.sort == sort)
		if h.arrow then
			h.fs:SetText(h.label)
			if on then
				h.arrow:ClearAllPoints()
				if h.leftJustified then
					h.arrow:SetPoint("LEFT", h.fs, "LEFT", h.fs:GetStringWidth() + 3, 0)
				else
					h.arrow:SetPoint("RIGHT", h.fs, "RIGHT", 0, 0)
				end
				h.arrow:SetTexCoord(unpack(dir == "asc" and SORT_ARROW_UP or SORT_ARROW_DOWN))
				h.arrow:Show()
			else
				h.arrow:Hide()
			end
		else
			h.fs:SetText(h.label .. (on and fallback or ""))
		end
		h.fs:SetTextColor(on and ACCENT[1] or 0.75, on and ACCENT[2] or 0.75, on and ACCENT[3] or 0.75)
	end

	-- Build the flat entry list: one color row per family, and when a family is open,
	-- its flowers followed by the shades it paints.
	local hideCostly = DyeingDownTheHouseDB.ui.hideCostlyFlowers
	local showShades = DyeingDownTheHouseDB.ui.showShades ~= false
	local entries = {}

	-- Marks the ends of each expanded run so the UI can cap the block. Done here
	-- rather than while drawing, because the filters decide which sub-row is last.
	local function CloseBlock(from)
		if #entries >= from then
			entries[from].first = true
			entries[#entries].last = true
		end
	end

	for _, dye in ipairs(ns.GetDisplayDyes()) do
		local color = dye.color
		local open = ns.IsColorExpanded(color)
		entries[#entries + 1] = { kind = "color", dye = dye, color = color, open = open }
		if open then
			local from = #entries + 1

			local breakdown = ns.GetColorCraftBreakdown(color)
			for _, fl in ipairs(breakdown and breakdown.flowers or {}) do
				-- Optionally hide flowers that aren't the cheapest way into this color.
				-- (isCheapest == false means dearer; nil means unpriced — keep those.)
				if not (hideCostly and fl.isCheapest == false) then
					entries[#entries + 1] = { kind = "flower", flower = fl, color = color }
				end
			end

			-- Then the shades this color paints. A search pulls its matches to the front
			-- of them: when someone types "obsidium", the one line they came for should
			-- not be nineteen rows down inside the block.
			if showShades then
				local matched = ns.MatchedShades and ns.MatchedShades(color)
				local hit, ordered = {}, {}
				for _, shade in ipairs(matched or {}) do
					hit[shade.name] = true
					ordered[#ordered + 1] = shade
				end
				for _, shade in ipairs(ns.shadesByColor[color] or {}) do
					if not hit[shade.name] then ordered[#ordered + 1] = shade end
				end
				for _, shade in ipairs(ordered) do
					entries[#entries + 1] = {
						kind = "shade", shade = shade, color = color, matched = hit[shade.name],
					}
				end
			end

			CloseBlock(from)
		end
	end

	-- Note: `X and X()` would truncate GetScanProgress's 3 returns to 1, leaving
	-- done/total nil — call it directly.
	local scanning, done, total
	if ns.GetScanProgress then scanning, done, total = ns.GetScanProgress() end
	if frame.scanOverlay then
		if scanning then
			frame.scanOverlay:SetText(("Scanning  %d / %d"):format(done or 0, total or 0))
			frame.scanOverlay:Show()
			if frame.scanFlavor then frame.scanFlavor:SetText(BrutosaurFlavor()); frame.scanFlavor:Show() end
		else
			frame.scanOverlay:Hide()
			if frame.scanFlavor then frame.scanFlavor:Hide() end
		end
	end
	if frame.scanBtn then
		if scanning then
			frame.scanBtn:SetText("Scanning"); frame.scanBtn:Disable()
		else
			-- Only the built-in AH scan needs an auction house. TSM and Auctionator read
			-- a database they already keep, so the button stays live anywhere — and says
			-- "Prices" rather than "Scan", because nothing is being scanned.
			local source = ActivePriceSource()
			if source and source.instant then
				frame.scanBtn:SetText("Prices"); frame.scanBtn:Enable()
			else
				frame.scanBtn:SetText("Scan"); frame.scanBtn:SetEnabled(ns.IsAHOpen and ns.IsAHOpen())
			end
		end
	end

	FauxScrollFrame_Update(scroll, #entries, visible, ROW_H)
	scroll:Show() -- FauxScrollFrame_Update hides it when the list fits; keep rows visible
	local offset = FauxScrollFrame_GetOffset(scroll)
	local maxOffset = math.max(0, #entries - visible)
	if offset > maxOffset then offset = maxOffset; FauxScrollFrame_SetOffset(scroll, offset) end

	for i = 1, MAXROWS do
		local row = rows[i]
		local e = (i <= visible) and entries[i + offset] or nil
		if e and e.kind == "color" then
			local dye = e.dye
			row.entryKind, row.color = "color", e.color
			SetColorMode(row, e.open)
			row.expander:SetTexture(e.open
				and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
			local sw = SWATCH[e.color] or { 0.6, 0.6, 0.6 }
			row.swatch:SetColorTexture(sw[1], sw[2], sw[3])
			row.name:SetText(e.color:gsub("^%l", string.upper))
			row.name:SetTextColor(1, 0.82, 0)

			local rc = ns.GetRecipeStatus(dye.key)
			for key, fs in pairs(row.cells) do
				if layout[key] then
					local text, r, g, b = CellValue(key, dye, rc)
					if text ~= nil then fs:SetText(text); fs:SetTextColor(r, g, b) end
				end
			end
			if layout.goal and not row.goalBox:HasFocus() then
				local gval = ns.GetGoal(dye.key)
				row.goalBox:SetText(gval > 0 and gval or "")
			end
			-- Goal met means you HOLD them. Flowers that could still become dyes
			-- deliberately don't count: when stock-in-hand did count, a color could show
			-- a green tick here while its own Makeable column was still telling you to
			-- go and make some. One definition, and Makeable answers the other question.
			local covered = layout.goal and rc and rc.goal > 0 and rc.owned >= rc.goal
			row.goalCheck:SetShown(covered and true or false)
			if GameTooltip:IsOwned(row) then ShowColorTooltip(row) end
			row:Show()

		elseif e and e.kind == "flower" then
			local fl = e.flower
			row.entryKind, row.color = "flower", nil
			SetSubMode(row, e.color, e.last)
			local icon = C_Item and C_Item.GetItemIconByID and fl.id and C_Item.GetItemIconByID(fl.id)
			row.fIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.fIcon:SetVertexColor(1, 1, 1)
			row.fName:SetText(fl.name)
			row.fName:SetTextColor(1, 0.82, 0)

			local parts = { ("%d held"):format(fl.have),
				("makes %d %s"):format(fl.dyesEach, fl.dyesEach == 1 and "dye" or "dyes") }
			if fl.craftCost then
				-- Color the craft cost itself: green on the cheapest way into this color,
				-- red on a dearer one, default when nothing here is priced yet to compare.
				local craft = FormatMoney(fl.craftCost) .. " to make"
				if fl.isCheapest == true then craft = "|cff66dd66" .. craft .. "|r"
				elseif fl.isCheapest == false then craft = "|cffdd6666" .. craft .. "|r" end
				parts[#parts + 1] = craft
			end
			row.fDetail:SetText(table.concat(parts, "   ·   "))
			row:Show()

		elseif e and e.kind == "shade" then
			-- A shade is a color you can paint, not a thing you can hold — so it gets a
			-- plain swatch rather than an item icon, and no counts. Reusing the flower
			-- row's three widgets keeps the block visually of a piece.
			local shade = e.shade
			row.entryKind, row.color = "shade", nil
			SetSubMode(row, e.color, e.last)
			row.fIcon:SetTexture("Interface\\Buttons\\WHITE8X8")
			local sw = SWATCH[e.color] or { 0.6, 0.6, 0.6 }
			row.fIcon:SetVertexColor(sw[1], sw[2], sw[3])
			row.fName:SetText(shade.name)
			-- A search match is the row the player came for, so it's the one lit up.
			if e.matched then
				row.fName:SetTextColor(1, 1, 1)
			else
				row.fName:SetTextColor(0.72, 0.72, 0.76)
			end
			-- `guess` means Data.lua inferred which family this shade belongs to rather
			-- than reading it from the game. Saying so is the whole point of the flag:
			-- an unverified placement that looks identical to a verified one is worse
			-- than not showing it, because nobody would ever think to check it.
			row.fDetail:SetText(shade.guess and "|cff8a8a94family not confirmed|r" or "")
			row:Show()

		else
			row.entryKind, row.color = nil, nil
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Headers
--------------------------------------------------------------------------------

local function MakeHeader(key, label, sortMode)
	local btn = CreateFrame("Button", nil, frame)
	btn:SetSize(COLDEF[key] and COLDEF[key].w or 120, 16)
	btn.fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.fs:SetAllPoints()
	btn.fs:SetJustifyH(key == "name" and "LEFT" or "CENTER")
	btn.fs:SetText(label)
	btn.label = label
	btn.sort = sortMode
	btn.leftJustified = (key == "name")
	-- A real sprite for the sort caret (Refresh points it up or down).
	local a = btn:CreateTexture(nil, "OVERLAY")
	a:SetSize(10, 10)
	a:SetTexture(SORT_ARROW_TEX)
	a:SetTexCoord(unpack(SORT_ARROW_UP))
	a:Hide()
	btn.arrow = a
	btn.hint = COLDEF[key] and COLDEF[key].hint
	btn:SetScript("OnClick", function()
		if sortMode then ns.CycleSort(sortMode) end
		ResetScroll(); ns.Refresh()
	end)
	btn:SetScript("OnEnter", function()
		btn.fs:SetTextColor(1, 1, 1)
		if btn.hint then
			GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(btn.label, 1, 1, 1)
			GameTooltip:AddLine(btn.hint, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end
	end)
	btn:SetScript("OnLeave", function() GameTooltip_Hide(); ns.Refresh() end)
	headers[key] = btn
	return btn
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function ns.BuildUI()
	if frame then return end

	frame = CreateFrame("Frame", "DyeingDownTheHouseFrame", UIParent, "BackdropTemplate")
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	-- Width is user-sizable within slack around the column-fit width; ApplyColumnLayout
	-- refines these bounds whenever the visible columns change.
	if frame.SetResizeBounds then
		local fit = ComputeFrameWidth()
		frame:SetResizeBounds(fit - WIDTH_SHRINK, HEIGHT_MIN, fit + WIDTH_GROW, HEIGHT_MAX)
	end
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not DyeingDownTheHouseDB.ui.locked then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		local ui = DyeingDownTheHouseDB.ui
		ui.point, ui.relPoint, ui.x, ui.y = point, relPoint, x, y
	end)
	frame:SetScript("OnSizeChanged", function(self)
		local ui = DyeingDownTheHouseDB.ui
		if ui.collapsed then return end -- don't persist the title-bar height
		ui.width, ui.height = self:GetWidth(), self:GetHeight()
		Layout()
		ns.Refresh()
	end)
	frame:Hide()

	titleFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleFS:SetPoint("TOPLEFT", 14, -12)
	ns.ApplyTitleColor()

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, -4)
	close:SetScript("OnClick", function() ns.Hide() end)

	-- Minimize: collapse to a title-bar strip (re-click to expand).
	local minBtn = CreateFrame("Button", nil, frame)
	minBtn:SetSize(18, 18)
	minBtn:SetPoint("TOPRIGHT", -26, -8)
	minBtn.fs = minBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	minBtn.fs:SetPoint("CENTER", 0, 1)
	minBtn.fs:SetText("−")
	minBtn:SetScript("OnClick", function() ns.ToggleCollapse() end)
	minBtn:SetScript("OnEnter", function() minBtn.fs:SetTextColor(1, 1, 1) end)
	minBtn:SetScript("OnLeave", function() minBtn.fs:SetTextColor(1, 0.82, 0) end)
	minBtn.fs:SetTextColor(1, 0.82, 0)
	frame.minBtn = minBtn

	local opts = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	opts:SetSize(60, 18)
	opts:SetPoint("TOPRIGHT", -48, -9)
	opts:SetText("Options")
	opts:SetScript("OnClick", function() if ns.OpenOptions then ns.OpenOptions() end end)

	local scanBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	scanBtn:SetSize(60, 18)
	scanBtn:SetPoint("RIGHT", opts, "LEFT", -4, 0)
	scanBtn:SetText("Scan")
	scanBtn:SetScript("OnClick", function()
		local ok, err = ns.StartScan()
		if not ok then print("|cffb388ffDyeing Down The House|r: " .. (err or "cannot scan.")) end
		ns.Refresh()
	end)
	scanBtn:SetScript("OnEnter", function()
		GameTooltip:SetOwner(scanBtn, "ANCHOR_BOTTOM")
		local source = ActivePriceSource()
		if source and source.instant then
			GameTooltip:AddLine("Update prices")
			GameTooltip:AddLine(("Reads every shown flower straight from %s.\nNo auction house visit needed."):format(source.name),
				0.8, 0.8, 0.8, true)
		else
			GameTooltip:AddLine("Scan AH prices")
			GameTooltip:AddLine("Open the Auction House, then Scan to price every shown flower\n(lowest buyout with real market depth behind it).",
				0.8, 0.8, 0.8, true)
			GameTooltip:AddLine("Run TSM or Auctionator? /dye source lets you read their prices\ninstead, instantly and anywhere.", 0.6, 0.6, 0.7, true)
		end
		-- The note for anyone who didn't read the patch notes and is wondering where
		-- the dye prices went. It belongs here: this is the button they press when
		-- they notice, and the answer is why it now scans half of what it used to.
		if ns.DYES_TRADEABLE == false then
			GameTooltip:AddLine("Flowers only. Warband-bound dyes have no auction price.", 0.95, 0.8, 0.4, true)
		end
		local age = ShortAge(DyeingDownTheHouseDB.lastScan)
		if age then
			GameTooltip:AddLine(age == "now" and "Last scan: just now" or ("Last scan: " .. age .. " ago"),
				0.6, 0.85, 0.6)
		end
		GameTooltip:Show()
	end)
	scanBtn:SetScript("OnLeave", GameTooltip_Hide)
	frame.scanBtn = scanBtn

	-- A temporary two-line scan tracker that floats just above the window in white
	-- with a black stroke, shown only while a price scan runs — so it needs no
	-- permanent spot in the header. The count sits just above the frame; the
	-- "Hold your brutosaurs…" flavor line sits atop the count.
	local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
	frame.scanOverlay = frame:CreateFontString(nil, "OVERLAY")
	frame.scanOverlay:SetFont(FONT, 14, "THICKOUTLINE")
	frame.scanOverlay:SetTextColor(1, 1, 1)
	frame.scanOverlay:SetPoint("BOTTOM", frame, "TOP", 0, 6)
	frame.scanOverlay:Hide()

	frame.scanFlavor = frame:CreateFontString(nil, "OVERLAY")
	frame.scanFlavor:SetFont(FONT, 13, "THICKOUTLINE")
	frame.scanFlavor:SetTextColor(1, 0.92, 0.6) -- warm flavor tint
	frame.scanFlavor:SetPoint("BOTTOM", frame.scanOverlay, "TOP", 0, 3)
	frame.scanFlavor:Hide()

	local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	clear:SetSize(48, 20)
	clear:SetPoint("TOPRIGHT", -30, -38)
	clear:SetText("Clear")
	clear:SetScript("OnClick", function()
		if searchBox then searchBox:SetText("") end
		ns.ClearFilters()
		ResetScroll()
		ns.Refresh()
	end)

	local sLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sLabel:SetPoint("TOPLEFT", 16, -44)
	sLabel:SetText("Search")
	searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	searchBox:SetHeight(20)
	searchBox:SetPoint("LEFT", sLabel, "RIGHT", 10, 0)
	searchBox:SetPoint("RIGHT", clear, "LEFT", -10, 0)
	searchBox:SetAutoFocus(false)
	searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
	searchBox:SetScript("OnTextChanged", function(self)
		ns.SetSearch(self:GetText() or "")
		ResetScroll()
		ns.Refresh()
	end)

	-- Headers. The tab strip that used to sit above these is gone with the second
	-- view; the list starts straight under the search box now.
	local dyeHead = MakeHeader("name", "Color", "alpha")
	dyeHead:ClearAllPoints()
	dyeHead:SetPoint("TOPLEFT", 30, -HEADER_Y)
	dyeHead:SetWidth(120)
	-- Every column gets a header; ApplyColumnLayout shows only the ones laid out.
	for key, def in pairs(COLDEF) do
		MakeHeader(key, def.header, def.sort)
	end

	-- Scroll + rows
	scroll = CreateFrame("ScrollFrame", "DyeingDownTheHouseScroll", frame, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -TOP_INSET)
	scroll:SetPoint("BOTTOMRIGHT", -28, BOT_INSET)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, ns.Refresh)
	end)
	scrollBar = _G["DyeingDownTheHouseScrollScrollBar"] or scroll.ScrollBar

	rows = {}
	for i = 1, MAXROWS do rows[i] = CreateRow(i) end

	-- Resize grip
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function()
		if not DyeingDownTheHouseDB.ui.locked then frame:StartSizing("BOTTOMRIGHT") end
	end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		local ui = DyeingDownTheHouseDB.ui
		ui.width, ui.height = frame:GetWidth(), frame:GetHeight()
		Layout()
		ns.Refresh()
	end)

	-- Everything hidden when collapsed to the title bar (headers handled separately).
	frame.contentWidgets = { searchBox, sLabel, clear, opts, scanBtn, scroll, grip }

	ns.RestorePosition()
	ns.ApplyColumnLayout()
	Layout()
	if DyeingDownTheHouseDB.ui.collapsed then ns.SetCollapsed(true) end
end

--------------------------------------------------------------------------------
-- Collapse to / expand from a title-bar strip
--------------------------------------------------------------------------------

function ns.SetCollapsed(collapsed)
	DyeingDownTheHouseDB.ui.collapsed = collapsed and true or nil -- set first: OnSizeChanged skips saving
	if not frame then return end
	for _, w in ipairs(frame.contentWidgets or {}) do if w then w:SetShown(not collapsed) end end
	for _, h in pairs(headers) do h:SetShown(not collapsed) end
	if collapsed then
		if frame.scanOverlay then frame.scanOverlay:Hide() end
		if frame.scanFlavor then frame.scanFlavor:Hide() end
	end
	if frame.minBtn then frame.minBtn.fs:SetText(collapsed and "+" or "−") end
	-- Center the title in the short bar when collapsed; top-anchor it when expanded.
	if titleFS then
		titleFS:ClearAllPoints()
		if collapsed then
			titleFS:SetPoint("LEFT", frame, "TOPLEFT", 14, -COLLAPSED_H / 2)
		else
			titleFS:SetPoint("TOPLEFT", 14, -12)
		end
	end
	if collapsed then
		frame:SetHeight(COLLAPSED_H)
	else
		frame:SetHeight(DyeingDownTheHouseDB.ui.height or 460)
		Layout()
		ns.Refresh()
	end
end

function ns.ToggleCollapse()
	ns.SetCollapsed(not DyeingDownTheHouseDB.ui.collapsed)
end

--------------------------------------------------------------------------------
-- Show / hide / position
--------------------------------------------------------------------------------

function ns.RestorePosition()
	if not frame then return end
	local ui = DyeingDownTheHouseDB.ui
	local fit = ComputeFrameWidth()
	local w = math.max(fit - WIDTH_SHRINK, math.min(fit + WIDTH_GROW, ui.width or fit))
	frame:SetSize(w, ui.height or 460)
	frame:ClearAllPoints()
	frame:SetPoint(ui.point or "CENTER", UIParent, ui.relPoint or "CENTER", ui.x or 0, ui.y or 0)
	frame:SetScale(ui.scale or 1.0)
	Layout()
end

function ns.Show()
	if not frame then ns.BuildUI() end
	DyeingDownTheHouseDB.ui.shown = true
	frame:Show()
	Layout()
	ns.Refresh()
end

function ns.Hide()
	if frame then frame:Hide() end
	if DyeingDownTheHouseDB then DyeingDownTheHouseDB.ui.shown = false end
end

function ns.Toggle()
	if frame and frame:IsShown() then ns.Hide() else ns.Show() end
end
