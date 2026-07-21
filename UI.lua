local ADDON, ns = ...

--------------------------------------------------------------------------------
-- UI.lua — the on-screen window.
--
-- A movable, resizable window listing the dyes. Columns, left to right:
--   Dye | Owned | Pigment | Flowers | Value | Goal
-- "Pigment" and "Flowers" are the two halves of craftable-now (dyes you can make
-- from pigments you hold, vs by milling the flowers you hold). Every column except
-- Dye and Owned can be hidden from the options panel; hidden columns reflow away.
-- Clickable headers sort (and toggle direction). All data comes from Core.
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
local TOP_INSET = 96
local BOT_INSET = 14
local COLLAPSED_H = 34   -- height of the title-bar strip when collapsed
local ROW_RIGHT = -30          -- a row's right edge, in frame-right coordinates
local GAP, MARGIN = 8, 6

-- Fixed-width columns, right of the flexible Dye column. `sort` is the Core sort
-- mode; `optional` columns can be hidden. Packed right-to-left in ORDER_R2L.
local COLDEF = {
	owned   = { header = "Have",    sort = "owned",     w = 44 },
	pigment = { header = "Pigment", sort = "craftpig",  w = 62, optional = true,
		hint = "Pigments of this color you hold, and in ( ) how many of this dye they'd make." },
	flowers = { header = "Flowers", sort = "craftherb", w = 66, optional = true,
		hint = "Flowers of this color you hold, and in ( ) how many of this dye they'd mill into." },
	value   = { header = "Value",   sort = "price",     w = 72, optional = true },
	goal    = { header = "Dye Needed", sort = "goal",   w = 68, optional = true },
}
local ORDER_R2L = { "goal", "value", "flowers", "pigment", "owned" }

local SWATCH = {
	black  = { 0.32, 0.32, 0.34 }, blue   = { 0.25, 0.45, 0.95 },
	brown  = { 0.55, 0.38, 0.22 }, green  = { 0.32, 0.72, 0.34 },
	orange = { 0.96, 0.56, 0.16 }, purple = { 0.62, 0.32, 0.85 },
	red    = { 0.87, 0.26, 0.26 }, teal   = { 0.20, 0.72, 0.72 },
	white  = { 0.95, 0.95, 0.95 }, yellow = { 0.96, 0.86, 0.22 },
}
local ACCENT = { 0.70, 0.53, 1.00 }

-- Shared with Options.lua so its dye list can show matching colour swatches.
ns.SWATCH = SWATCH
ns.ACCENT = ACCENT

local frame, scroll, scrollBar, rows, searchBox, titleFS
local headers = {}
local layout = {}
local sepCount = 0   -- how many column dividers are currently visible (per dye row)
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

-- Rainbow or plain title, per the ui.rainbowTitle toggle. Exposed so the options
-- checkbox can re-apply it live.
function ns.ApplyTitleColor()
	if not titleFS then return end
	if DyingDownTheHouseDB.ui.rainbowTitle then
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
	return DyingDownTheHouseDB.ui.cols[key] ~= false
end

-- The window width is DERIVED from which columns are shown, never dragged: a base
-- (the Dye name + always-on Owned column and chrome) plus each visible optional
-- column's width and gap. Hiding a column shrinks the window by exactly that much,
-- leaving the Dye-name column the same width. Height is the only user-sized axis.
local BASE_W = 300
local function ComputeFrameWidth()
	local w = BASE_W
	for _, key in ipairs(ORDER_R2L) do
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

local function ShowRowTooltip(row)
	if not row.dyeKey then return end
	local rc = ns.GetRecipeStatus(row.dyeKey)
	if not rc then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	local dye = ns.byKey[row.dyeKey]
	GameTooltip:AddLine(dye and dye.name or row.dyeKey, ACCENT[1], ACCENT[2], ACCENT[3])
	GameTooltip:AddLine((SwatchIcon(rc.color) .. " color family: " .. rc.color), 0.8, 0.8, 0.8)
	GameTooltip:AddDoubleLine("Owned", rc.owned, 0.8, 0.8, 0.8, 1, 1, 1)
	if rc.goal > 0 then GameTooltip:AddDoubleLine("Needed", rc.goal, 0.8, 0.8, 0.8, 1, 1, 1) end
	GameTooltip:AddDoubleLine("Pigments held", ("%d (%d dyes)"):format(rc.ownedPigments, rc.craftableFromPigments), 0.8, 0.8, 0.8, 0.6, 0.9, 0.6)
	GameTooltip:AddDoubleLine("Flowers held", ("%d (%d dyes)"):format(rc.ownedHerbs, rc.craftableFromHerbs), 0.8, 0.8, 0.8, 0.6, 0.9, 0.6)
	GameTooltip:AddDoubleLine("Total craftable now", rc.craftableNow, 0.8, 0.8, 0.8, 0.5, 1, 0.5)
	if rc.goal > 0 and rc.shortfall > 0 then
		if rc.canCraftGoal then
			GameTooltip:AddLine(("Craft %d more to reach it"):format(rc.shortfall), 0.4, 0.9, 0.4)
		elseif rc.pigmentsShort > 0 then
			GameTooltip:AddLine(("Short %d pigment (%d flowers)"):format(rc.pigmentsShort, rc.herbsShort), 0.95, 0.6, 0.3)
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

	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)

	-- Dye-mode widgets ------------------------------------------------------
	row.expander = row:CreateTexture(nil, "OVERLAY")
	row.expander:SetSize(14, 14)
	row.expander:SetPoint("LEFT", 3, 0)

	row.swatch = row:CreateTexture(nil, "ARTWORK")
	row.swatch:SetSize(10, 10)
	row.swatch:SetPoint("LEFT", 20, 0)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("LEFT", row.swatch, "RIGHT", 8, 0)
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
		if row.dyeKey then ns.SetGoal(row.dyeKey, self:GetNumber()) end
	end
	goal:SetScript("OnEnterPressed", function(self) CommitGoal(self); self:ClearFocus() end)
	goal:SetScript("OnEditFocusLost", CommitGoal)
	goal:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.Refresh() end)
	row.goalBox = goal

	-- Green check when the goal is already covered by dyes + ready pigment on hand.
	-- Positioned to the right of the goal box by the column layout (ApplyColumnLayout).
	row.goalCheck = row:CreateTexture(nil, "OVERLAY")
	row.goalCheck:SetSize(13, 13)
	row.goalCheck:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
	row.goalCheck:Hide()

	-- Flower-mode widgets (shown when the row is a flower sub-row) -----------
	row.fIcon = row:CreateTexture(nil, "ARTWORK")
	row.fIcon:SetSize(14, 14)
	row.fIcon:SetPoint("LEFT", 28, 0)
	row.fName = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.fName:SetPoint("LEFT", row.fIcon, "RIGHT", 6, 0)
	row.fName:SetJustifyH("LEFT") -- no fixed width, so the detail hugs the name
	row.fDetail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.fDetail:SetPoint("LEFT", row.fName, "RIGHT", 10, 0)
	row.fDetail:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	row.fDetail:SetJustifyH("LEFT")
	row.fDetail:SetWordWrap(false) -- keep it a single line; never wrap the verdict

	-- Column dividers live ON the row (one per column boundary) so they only show
	-- on dye rows — the expanded flower rows stay clean, no lines through them.
	row.seps = {}
	for i = 1, #ORDER_R2L do
		local s = row:CreateTexture(nil, "ARTWORK")
		s:SetColorTexture(1, 1, 1, 0.07)
		s:SetWidth(1)
		row.seps[i] = s
	end

	row:RegisterForClicks("LeftButtonUp")
	row:SetScript("OnClick", function()
		if row.entryKind == "dye" and row.dyeKey then
			local ex = DyingDownTheHouseDB.ui.expanded
			ex[row.dyeKey] = (not ex[row.dyeKey]) or nil
			ns.Refresh()
		end
	end)
	row:SetScript("OnEnter", function() if row.entryKind == "dye" then ShowRowTooltip(row) end end)
	row:SetScript("OnLeave", GameTooltip_Hide)

	return row
end

-- Show the dye-mode widgets (respecting which columns are visible), hide flower.
local function SetDyeMode(row)
	row.expander:Show(); row.swatch:Show(); row.name:Show()
	for key, fs in pairs(row.cells) do fs:SetShown(layout[key] ~= nil) end
	row.goalBox:SetShown(layout.goal ~= nil)
	for i, s in ipairs(row.seps) do s:SetShown(i <= sepCount) end
	row.fIcon:Hide(); row.fName:Hide(); row.fDetail:Hide()
end

local function SetFlowerMode(row)
	row.expander:Hide(); row.swatch:Hide(); row.name:Hide()
	for _, fs in pairs(row.cells) do fs:Hide() end
	row.goalBox:Hide(); row.goalCheck:Hide()
	for _, s in ipairs(row.seps) do s:Hide() end
	row.fIcon:Show(); row.fName:Show(); row.fDetail:Show()
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
	for _, key in ipairs(ORDER_R2L) do
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

	-- Position row cells and the per-row column dividers.
	for _, row in ipairs(rows) do
		row.name:SetPoint("RIGHT", row, "RIGHT", layout.name_r, 0)
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
			h:SetPoint("TOPRIGHT", frame, "TOPRIGHT", L.r + ROW_RIGHT, -72)
			h:SetWidth(L.w)
			h:Show()
		else
			h:Hide()
		end
	end

	-- Set the width bounds from the current column-fit width, then apply the user's
	-- saved width clamped into them (so hiding a column pulls an over-wide window in,
	-- and showing one pushes a too-narrow window out). Untouched while collapsed.
	if not DyingDownTheHouseDB.ui.collapsed then
		local fit = ComputeFrameWidth()
		local minW, maxW = fit - WIDTH_SHRINK, fit + WIDTH_GROW
		if frame.SetResizeBounds then frame:SetResizeBounds(minW, HEIGHT_MIN, maxW, HEIGHT_MAX) end
		local ui = DyingDownTheHouseDB.ui
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

-- The Pigment/Flowers columns read "held (dyes craftable)": how many of that
-- colour's pigment / flowers the account holds, and in parentheses how many of
-- THIS dye that stock could produce right now.
local function HeldCell(held, dyes)
	local text = ("%d (%d)"):format(held, dyes)
	if dyes > 0 then return text, 0.65, 0.95, 0.65 end   -- can make some now
	if held > 0 then return text, 0.9, 0.9, 0.9 end       -- have stock, not enough yet
	return text, 0.45, 0.45, 0.45                          -- nothing
end

local function CellValue(key, dye, rc)
	if key == "owned" then
		return ns.GetTotal(dye.key), 1, 1, 1
	elseif key == "pigment" then
		return HeldCell(rc and rc.ownedPigments or 0, rc and rc.craftableFromPigments or 0)
	elseif key == "flowers" then
		return HeldCell(rc and rc.ownedHerbs or 0, rc and rc.craftableFromHerbs or 0)
	elseif key == "value" then
		-- Unit sale price (per dye) — matches the Value sort and is what you compare
		-- across dyes for "most profitable". Holdings value is in the tooltip.
		local p = ns.GetPrice(dye.key)
		local text = p and ("~%s/ea"):format(FormatMoney(p)) or "—"
		return text, p and 1 or 0.4, p and 0.9 or 0.4, p and 0.4 or 0.4
	end
end

function ns.Refresh()
	-- Keep the Dye Crafting window's markers in sync even if our window is hidden.
	if ns.RefreshCraftingMarkers then ns.RefreshCraftingMarkers() end
	if not frame or not frame:IsShown() then return end
	-- Collapsed to the title bar: don't touch the list (it re-shows the scroll frame,
	-- which would spill the rows out below the short bar on any bag/loot refresh).
	if DyingDownTheHouseDB.ui.collapsed then return end

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

	-- Build the flat entry list: each visible dye (GetDisplayDyes already drops the
	-- ones the player has hidden), plus its flower sub-rows when expanded.
	local dyes = ns.GetDisplayDyes()
	local expanded = DyingDownTheHouseDB.ui.expanded or {}
	local hideCostly = DyingDownTheHouseDB.ui.hideCostlyFlowers
	local entries = {}
	for _, d in ipairs(dyes) do
		entries[#entries + 1] = { kind = "dye", dye = d }
		if expanded[d.key] then
			local cb = ns.GetCraftBreakdown(d.key)
			for _, fl in ipairs(cb and cb.flowers or {}) do
				-- Optionally hide flowers that cost more to craft than to buy the dye.
				-- (cheaperToCraft == false means dearer; nil means unknown — keep those.)
				if not (hideCostly and fl.cheaperToCraft == false) then
					entries[#entries + 1] = { kind = "flower", flower = fl }
				end
			end
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
			frame.scanBtn:SetText("Scan"); frame.scanBtn:SetEnabled(ns.IsAHOpen and ns.IsAHOpen())
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
		if e and e.kind == "dye" then
			local dye = e.dye
			row.entryKind, row.dyeKey = "dye", dye.key
			SetDyeMode(row)
			row.expander:SetTexture(expanded[dye.key]
				and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
			local sw = SWATCH[dye.color] or { 0.6, 0.6, 0.6 }
			row.swatch:SetColorTexture(sw[1], sw[2], sw[3])
			row.name:SetText(dye.name)

			local rc = ns.GetRecipeStatus(dye.key)
			for key, fs in pairs(row.cells) do
				if layout[key] then
					local text, r, g, b = CellValue(key, dye, rc)
					fs:SetText(text); fs:SetTextColor(r, g, b)
				end
			end
			if layout.goal and not row.goalBox:HasFocus() then
				local gval = ns.GetGoal(dye.key)
				row.goalBox:SetText(gval > 0 and gval or "")
			end
			-- Green check when the goal is covered by dyes + ready pigment on hand.
			local covered = layout.goal and rc and rc.goal > 0
				and (rc.owned + rc.ownedPigments) >= rc.goal
			row.goalCheck:SetShown(covered and true or false)
			if GameTooltip:IsOwned(row) then ShowRowTooltip(row) end
			row:Show()

		elseif e and e.kind == "flower" then
			local fl = e.flower
			row.entryKind, row.dyeKey = "flower", nil
			SetFlowerMode(row)
			local icon = C_Item and C_Item.GetItemIconByID and fl.id and C_Item.GetItemIconByID(fl.id)
			row.fIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.fName:SetText(fl.name)

			local parts = { ("%d held"):format(fl.have),
				("makes %d %s"):format(fl.dyesEach, fl.dyesEach == 1 and "dye" or "dyes") }
			if fl.craftCost then
				-- Colour the craft cost itself: green if cheaper to craft than buy,
				-- red if dearer, default when there's no dye price to compare.
				local craft = FormatMoney(fl.craftCost) .. " to craft"
				if fl.cheaperToCraft == true then craft = "|cff66dd66" .. craft .. "|r"
				elseif fl.cheaperToCraft == false then craft = "|cffdd6666" .. craft .. "|r" end
				parts[#parts + 1] = craft
			end
			row.fDetail:SetText(table.concat(parts, "   ·   "))
			row:Show()

		else
			row.entryKind, row.dyeKey = nil, nil
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
	btn:SetScript("OnClick", function() ns.CycleSort(sortMode); ResetScroll(); ns.Refresh() end)
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

	frame = CreateFrame("Frame", "DyingDownTheHouseFrame", UIParent, "BackdropTemplate")
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
		if not DyingDownTheHouseDB.ui.locked then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		local ui = DyingDownTheHouseDB.ui
		ui.point, ui.relPoint, ui.x, ui.y = point, relPoint, x, y
	end)
	frame:SetScript("OnSizeChanged", function(self)
		local ui = DyingDownTheHouseDB.ui
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
		GameTooltip:AddLine("Scan AH prices")
		GameTooltip:AddLine("Open the Auction House, then Scan to price every shown dye and\nflower (lowest buyout with real market depth behind it).",
			0.8, 0.8, 0.8, true)
		local age = ShortAge(DyingDownTheHouseDB.lastScan)
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

	-- Headers
	local dyeHead = MakeHeader("name", "Dye", "alpha")
	dyeHead:ClearAllPoints()
	dyeHead:SetPoint("TOPLEFT", 30, -72)
	dyeHead:SetWidth(120)
	for _, key in ipairs(ORDER_R2L) do MakeHeader(key, COLDEF[key].header, COLDEF[key].sort) end

	-- Scroll + rows
	scroll = CreateFrame("ScrollFrame", "DyingDownTheHouseScroll", frame, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -TOP_INSET)
	scroll:SetPoint("BOTTOMRIGHT", -28, BOT_INSET)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, ns.Refresh)
	end)
	scrollBar = _G["DyingDownTheHouseScrollScrollBar"] or scroll.ScrollBar

	rows = {}
	for i = 1, MAXROWS do rows[i] = CreateRow(i) end

	-- Resize grip
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function()
		if not DyingDownTheHouseDB.ui.locked then frame:StartSizing("BOTTOMRIGHT") end
	end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		local ui = DyingDownTheHouseDB.ui
		ui.width, ui.height = frame:GetWidth(), frame:GetHeight()
		Layout()
		ns.Refresh()
	end)

	-- Everything hidden when collapsed to the title bar (headers handled separately).
	frame.contentWidgets = { searchBox, sLabel, clear, opts, scanBtn, scroll, grip }

	ns.RestorePosition()
	ns.ApplyColumnLayout()
	Layout()
	if DyingDownTheHouseDB.ui.collapsed then ns.SetCollapsed(true) end
end

--------------------------------------------------------------------------------
-- Collapse to / expand from a title-bar strip
--------------------------------------------------------------------------------

function ns.SetCollapsed(collapsed)
	DyingDownTheHouseDB.ui.collapsed = collapsed and true or nil -- set first: OnSizeChanged skips saving
	if not frame then return end
	for _, w in ipairs(frame.contentWidgets or {}) do if w then w:SetShown(not collapsed) end end
	for _, h in pairs(headers) do h:SetShown(not collapsed) end
	if collapsed then
		if frame.scanOverlay then frame.scanOverlay:Hide() end
		if frame.scanFlavor then frame.scanFlavor:Hide() end
	end
	if frame.minBtn then frame.minBtn.fs:SetText(collapsed and "+" or "−") end
	-- Centre the title in the short bar when collapsed; top-anchor it when expanded.
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
		frame:SetHeight(DyingDownTheHouseDB.ui.height or 460)
		Layout()
		ns.Refresh()
	end
end

function ns.ToggleCollapse()
	ns.SetCollapsed(not DyingDownTheHouseDB.ui.collapsed)
end

--------------------------------------------------------------------------------
-- Show / hide / position
--------------------------------------------------------------------------------

function ns.RestorePosition()
	if not frame then return end
	local ui = DyingDownTheHouseDB.ui
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
	DyingDownTheHouseDB.ui.shown = true
	frame:Show()
	Layout()
	ns.Refresh()
end

function ns.Hide()
	if frame then frame:Hide() end
	if DyingDownTheHouseDB then DyingDownTheHouseDB.ui.shown = false end
end

function ns.Toggle()
	if frame and frame:IsShown() then ns.Hide() else ns.Show() end
end
