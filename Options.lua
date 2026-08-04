-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Options.lua — the settings panel ("/dye options" or Interface > AddOns).
--
-- A custom canvas panel: column-visibility toggles and display options in tidy
-- columns, plus two collapsible checklists (Dyes and Flowers) where everything is
-- on by default and the player unchecks what they don't want to see. Built once
-- at login, wrapped so a Settings-API change can never take the addon down.
--------------------------------------------------------------------------------

local category, panel, panelTitle
local checks = {} -- { {cb, get}, ... } refreshed whenever the panel is shown
local priceRadios = {} -- { {cb, source}, ... } — availability re-checked on show

local function RefreshChecks()
	for _, c in ipairs(checks) do c.cb:SetChecked(c.get()) end
end

-- A price source can appear or vanish between openings of this panel (the player
-- enables TSM and reloads, or disables it mid-session), so availability is read
-- every time rather than baked in when the panel was built.
local function RefreshPriceRadios()
	for _, r in ipairs(priceRadios) do
		if r.source and r.source.addon then
			local available = ns.IsPriceSourceAvailable and ns.IsPriceSourceAvailable(r.source)
			r.cb:SetEnabled(available and true or false)
			r.cb.label:SetText(available and r.source.name
				or (r.source.name .. "   (not installed)"))
			local shade = available and 1 or 0.45
			r.cb.label:SetTextColor(shade, shade, shade)
		end
	end
end

local function ApplyPanelTitle()
	if not panelTitle then return end
	if DyeingDownTheHouseDB.ui.rainbowTitle then
		panelTitle:SetText(ns.RainbowText("Dyeing Down The House"))
	else
		panelTitle:SetText("Dyeing Down The House")
		if ns.ACCENT then panelTitle:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3]) end
	end
end

local function MakeCheck(parent, label, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	checks[#checks + 1] = { cb = cb, get = get }
	return cb
end

-- A radio row: picks one value out of a set rather than toggling a flag, so these
-- set rather than invert. UIRadioButtonTemplate is the right look, but it's a
-- Blizzard template like any other and could be renamed out from under us — fall
-- back to the checkbox template the rest of the panel already uses.
local function MakeRadio(parent, label, value, get, set)
	local cb
	local made = pcall(function()
		cb = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
	end)
	if not made or not cb then
		cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
	end
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	fs:SetText(label)
	cb.label = fs
	-- Selecting one has to visibly deselect the others, and they're independent
	-- widgets — so re-read every row's state after any change.
	cb:SetScript("OnClick", function() set(value); RefreshChecks() end)
	checks[#checks + 1] = { cb = cb, get = function() return get() == value end }
	return cb
end

local function SectionHeader(parent, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	fs:SetText(text)
	return fs
end

-- One checklist (all items on by default; uncheck to hide). Returns the container
-- frame and its pixel height. `swatchColor` optional (dye colors).
local function BuildChecklist(content, items, isHidden, setHidden, setAll, swatchColor)
	local c = CreateFrame("Frame", nil, content)

	local allBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
	allBtn:SetSize(90, 20)
	allBtn:SetPoint("TOPLEFT", 16, -2)
	allBtn:SetText("Check All")
	allBtn:SetScript("OnClick", function() setAll(false); RefreshChecks() end)
	local noneBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
	noneBtn:SetSize(90, 20)
	noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 8, 0)
	noneBtn:SetText("Uncheck All")
	noneBtn:SetScript("OnClick", function() setAll(true); RefreshChecks() end)

	local COLS, COLW, ROWH, TOP = 3, 188, 22, -28
	for i, it in ipairs(items) do
		local col = (i - 1) % COLS
		local rowIdx = math.floor((i - 1) / COLS)
		local cb = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
		cb:SetPoint("TOPLEFT", 16 + col * COLW, TOP - rowIdx * ROWH)

		local anchor, gap = cb, 2
		if swatchColor then
			local sw = cb:CreateTexture(nil, "OVERLAY")
			sw:SetSize(9, 9)
			sw:SetPoint("LEFT", cb, "RIGHT", 1, 0)
			local col3 = swatchColor(it) or { 0.6, 0.6, 0.6 }
			sw:SetColorTexture(col3[1], col3[2], col3[3])
			anchor, gap = sw, 3
		end
		local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", anchor, "RIGHT", gap, 0)
		fs:SetWidth(COLW - 34)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetText(it.label)

		cb:SetScript("OnClick", function(self) setHidden(it, not self:GetChecked()) end)
		checks[#checks + 1] = { cb = cb, get = function() return not isHidden(it) end }
	end

	local rows = math.ceil(#items / COLS)
	local h = 28 + rows * ROWH + 6
	c:SetSize(560, h)
	return c, h
end

local function BuildPanel()
	if panel then return end
	if type(Settings) ~= "table"
		or not (Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
		return
	end

	panel = CreateFrame("Frame")
	panel:Hide()

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -10)
	scroll:SetPoint("BOTTOMRIGHT", -28, 10)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(580, 100)
	scroll:SetScrollChild(content)

	local COL2 = 285
	local y = -8

	panelTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	panelTitle:SetPoint("TOPLEFT", 8, y)
	ApplyPanelTitle()
	y = y - 34

	local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", 10, y)
	subtitle:SetText("Tracks the housing dyes you still need, and the cheapest way to get them, craft or buy.")
	subtitle:SetTextColor(0.7, 0.7, 0.7)
	y = y - 24

	-- Columns to show -------------------------------------------------------
	SectionHeader(content, "Columns to show   (By Dye tab)"):SetPoint("TOPLEFT", 8, y)
	y = y - 24
	-- These are the "By Dye" (per-dye) tab's columns. The "By Color Family" tab has
	-- a fixed set — every column there is the reason that view exists — so it has
	-- nothing to toggle.
	local colDefs = {
		{ "pigment", "Pigments — owned & craftable" },
		{ "flowers", "Flowers — owned & craftable" },
		{ "value",   "Dye cost (to craft)" },
		{ "goal",    "Dye needed (goal)" },
	}
	for i, cd in ipairs(colDefs) do
		local key = cd[1]
		local cb = MakeCheck(content, cd[2],
			function() return DyeingDownTheHouseDB.ui.cols[key] ~= false end,
			function(v)
				DyeingDownTheHouseDB.ui.cols[key] = v
				if ns.ApplyColumnLayout then ns.ApplyColumnLayout() end
				ns.Refresh()
			end)
		cb:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * COL2, y - math.floor((i - 1) / 2) * 26)
	end
	y = y - 26 * 2 - 12

	-- Display ---------------------------------------------------------------
	SectionHeader(content, "Display"):SetPoint("TOPLEFT", 8, y)
	y = y - 24
	MakeCheck(content, "Show only the cheapest flowers",
		function() return DyeingDownTheHouseDB.ui.hideCostlyFlowers end,
		function(v) DyeingDownTheHouseDB.ui.hideCostlyFlowers = v; ns.Refresh() end)
		:SetPoint("TOPLEFT", 16, y)
	MakeCheck(content, "Lock the window in place",
		function() return DyeingDownTheHouseDB.ui.locked end,
		function(v) DyeingDownTheHouseDB.ui.locked = v end)
		:SetPoint("TOPLEFT", 16 + COL2, y)
	y = y - 26
	MakeCheck(content, "Track dyes needed in housing panel",
		function() return DyeingDownTheHouseDB.ui.housingGoalInput end,
		function(v) DyeingDownTheHouseDB.ui.housingGoalInput = v end)
		:SetPoint("TOPLEFT", 16, y)
	MakeCheck(content, "Mark the cheapest herbs when crafting",
		function() return DyeingDownTheHouseDB.ui.markHerbs end,
		function(v) DyeingDownTheHouseDB.ui.markHerbs = v; if ns.RefreshCraftingMarkers then ns.RefreshCraftingMarkers() end end)
		:SetPoint("TOPLEFT", 16 + COL2, y)
	y = y - 26
	MakeCheck(content, "Rainbow title  (off = plain)",
		function() return DyeingDownTheHouseDB.ui.rainbowTitle end,
		function(v)
			DyeingDownTheHouseDB.ui.rainbowTitle = v
			ApplyPanelTitle()
			if ns.ApplyTitleColor then ns.ApplyTitleColor() end
		end)
		:SetPoint("TOPLEFT", 16, y)
	y = y - 36

	-- Where prices come from ------------------------------------------------
	-- Guarded on ns.PRICE_SOURCES so the panel still builds if Prices.lua is absent;
	-- the addon falls back to its own auction-house scan and this section is simply
	-- not drawn.
	if ns.PRICE_SOURCES and ns.GetPriceSource and ns.SetPriceSource then
		SectionHeader(content, "Where prices come from"):SetPoint("TOPLEFT", 8, y)
		y = y - 24

		local note = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		note:SetPoint("TOPLEFT", 16, y)
		note:SetWidth(540)
		note:SetJustifyH("LEFT")
		note:SetText("TSM and Auctionator price every flower instantly, anywhere in the world. " ..
			"The built-in scan needs no other addon, but has to query the auction house one item at a time.")
		note:SetTextColor(0.7, 0.7, 0.7)
		y = y - 32

		-- Whichever source they pick, it prices flowers and only flowers. Said here
		-- as well as on the Scan button, because this panel is the other place a
		-- player goes looking when the dye prices they remember have gone.
		if ns.DYES_TRADEABLE == false then
			local warband = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			warband:SetPoint("TOPLEFT", 16, y)
			warband:SetWidth(540)
			warband:SetJustifyH("LEFT")
			warband:SetText("Flowers are all that any of them price. Dyes are Warband-bound, so they can't be bought or sold and have no auction price — the Cost column is what a dye costs to make instead.")
			warband:SetTextColor(0.95, 0.8, 0.4)
			y = y - 32
		end

		local rows = { { label = "Automatic — use the best one installed", value = "auto" } }
		for _, source in ipairs(ns.PRICE_SOURCES) do
			rows[#rows + 1] = { label = source.name, value = source.key, source = source }
		end

		for i, row in ipairs(rows) do
			local cb = MakeRadio(content, row.label, row.value,
				ns.GetPriceSource,
				function(v) ns.SetPriceSource(v) end)
			cb:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * COL2, y - math.floor((i - 1) / 2) * 24)
			priceRadios[#priceRadios + 1] = { cb = cb, source = row.source }
		end
		y = y - 24 * math.ceil(#rows / 2) - 16
	end

	-- Two collapsible checklists (Dyes, Flowers) ----------------------------
	local dyeItems = {}
	do
		local colIndex = {}
		for i, cc in ipairs(ns.COLORS or {}) do colIndex[cc] = i end
		for _, d in ipairs(ns.DYES) do
			dyeItems[#dyeItems + 1] = { label = (d.name:gsub(" Dye$", "")), key = d.key, color = d.color }
		end
		table.sort(dyeItems, function(a, b)
			if a.color ~= b.color then return (colIndex[a.color] or 99) < (colIndex[b.color] or 99) end
			return a.label < b.label
		end)
	end
	local dyeContainer = BuildChecklist(content, dyeItems,
		function(it) return ns.IsDyeHidden(it.key) end,
		function(it, hidden) ns.SetDyeHidden(it.key, hidden) end,
		ns.SetAllDyesHidden,
		function(it) return ns.SWATCH and ns.SWATCH[it.color] end)

	local herbItems = {}
	for _, name in ipairs(ns.GetDistinctHerbNames()) do
		herbItems[#herbItems + 1] = { label = name, name = name }
	end
	local herbContainer = BuildChecklist(content, herbItems,
		function(it) return ns.IsHerbHidden(it.name) end,
		function(it, hidden) ns.SetHerbHidden(it.name, hidden) end,
		ns.SetAllHerbsHidden)

	local sections = {
		{ label = ("Dyes to show   (%d) — uncheck to hide"):format(#dyeItems),
			container = dyeContainer, open = false },
		{ label = ("Flowers to show   (%d) — uncheck to hide"):format(#herbItems),
			container = herbContainer, open = false },
	}
	local startY = y

	local function Relayout()
		local yy = startY
		for _, s in ipairs(sections) do
			s.header.fs:SetText((s.open and "−  " or "+  ") .. s.label)
			s.header:ClearAllPoints()
			s.header:SetPoint("TOPLEFT", 8, yy)
			yy = yy - 26
			if s.open then
				s.container:ClearAllPoints()
				s.container:SetPoint("TOPLEFT", 0, yy)
				s.container:Show()
				yy = yy - s.container:GetHeight()
			else
				s.container:Hide()
			end
			yy = yy - 10
		end
		content:SetSize(580, -yy + 20)
	end

	for _, s in ipairs(sections) do
		local btn = CreateFrame("Button", nil, content)
		btn:SetSize(360, 22)
		btn.fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		btn.fs:SetPoint("LEFT")
		btn:SetScript("OnClick", function() s.open = not s.open; Relayout() end)
		btn:SetScript("OnEnter", function() btn.fs:SetTextColor(1, 1, 1) end)
		btn:SetScript("OnLeave", function() btn.fs:SetTextColor(1, 0.82, 0) end)
		s.header = btn
	end
	Relayout()

	panel:SetScript("OnShow", function()
		RefreshChecks()
		RefreshPriceRadios()
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel,
		DyeingDownTheHouseDB.ui.rainbowTitle and ns.RainbowText("Dyeing Down The House") or "Dyeing Down The House")
	Settings.RegisterAddOnCategory(category)

	function ns.OpenOptions()
		if category then Settings.OpenToCategory(category:GetID()) end
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	pcall(BuildPanel)
end)
