-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Crafting.lua — decorate the Dye Station's crafting window.
--
-- THIS FILE WAS DELETED EARLIER IN THIS RELEASE AND IS BACK, because the premise
-- it was deleted on was wrong. Blizzard's post says "there are no recipes in your
-- own crafting book to manage", which I read as the crafting UI being gone. It
-- isn't — the recipes moved OUT of your profession book and INTO the station,
-- which opens a perfectly ordinary Professions-style window titled "Dye Crafting"
-- with nine recipes in it, one per colour. Worth recording as a lesson: the post
-- described where the recipes live, not whether a window exists, and deleting a
-- feature on a reading of prose rather than a look at the client was too eager.
--
-- What it adds, once you're standing at a station:
--
--   * A marker on any dye you own fewer of than your goal, so the ones worth
--     making stand out in the game's own list.
--   * A "have X / need Y" line under the recipe title.
--   * A green check or red X on each herb in the reagent picker: is THIS the
--     cheapest flower to make this colour out of, at today's prices? A dye takes
--     ten of one flower and a colour has up to fifteen to choose between, so this
--     is the one decision the window doesn't help you with.
--
-- The Professions UI is internal and load-on-demand, and 12.1 has already moved
-- one panel out from under this addon — so every step is feature-detected and
-- pcall-wrapped, and a recipe row is matched against its own item link rather
-- than trusted by position. `/dye probe station` reports the live shape if this
-- ever stops finding it.
--
-- Verified shapes (2026-07-20, and unchanged in the 12.1 station window):
--   ProfessionsFrame.CraftingPage.RecipeList.ScrollBox:GetFrames()
--   button:GetElementData().data.recipeInfo  -> { name, recipeID, hyperlink, ... }
--------------------------------------------------------------------------------

-- Which of the nine a recipe row is for.
--
-- The item link first, because it carries the real item ID and cannot be a near
-- miss. The name second, which is what covers the window before Discover.lua has
-- filled the IDs in — the recipes are named exactly "<Colour> Housing Dye", which
-- is what ns.byName holds.
local function DyeFromRecipeInfo(recipeInfo)
	if type(recipeInfo) ~= "table" then return nil end

	local itemID = recipeInfo.hyperlink and tonumber(recipeInfo.hyperlink:match("Hitem:(%d+)"))
	local entry = itemID and ns.byID[itemID]
	if entry and entry.kind == "dye" then return entry end

	if recipeInfo.name then
		local byName = ns.byName[recipeInfo.name:lower()]
		if byName and byName.kind == "dye" then return byName end
	end
	return nil
end

local function ShouldCraft(dye)
	local goal = ns.GetGoal(dye.key)
	return goal > 0 and ns.GetTotal(dye.key) < goal
end

--------------------------------------------------------------------------------
-- The recipe list
--------------------------------------------------------------------------------

local function DecorateButton(button)
	local ed = button.GetElementData and button:GetElementData()
	local data = ed and ed.data
	local recipeInfo = data and data.recipeInfo
	local dye = recipeInfo and DyeFromRecipeInfo(recipeInfo)

	-- Mark ONLY colours you want to make: a goal is set and you hold fewer than it.
	if dye and ShouldCraft(dye) then
		if not button.ddthMark then
			local t = button:CreateTexture(nil, "OVERLAY")
			t:SetSize(16, 16)
			t:SetPoint("RIGHT", button, "RIGHT", -4, 0)
			t:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon") -- yellow "!" = make this
			button.ddthMark = t
		end
		button.ddthMark:Show()
	elseif button.ddthMark then
		button.ddthMark:Hide()
	end
end

local function DecorateList()
	-- The list laying itself out is the moment the station's recipes are readable,
	-- and their reagents ARE the herb -> colour map. Discover.lua bounds this to one
	-- read per visit, so calling it on every re-layout is free. See ns.TryLearnHerbs.
	if ns.TryLearnHerbs then pcall(ns.TryLearnHerbs) end

	local pf = _G.ProfessionsFrame
	local rl = pf and pf.CraftingPage and pf.CraftingPage.RecipeList
	local sb = rl and rl.ScrollBox
	if not sb or type(sb.GetFrames) ~= "function" then return end
	local ok, frames = pcall(sb.GetFrames, sb)
	if not ok or type(frames) ~= "table" then return end
	for _, button in ipairs(frames) do
		pcall(DecorateButton, button)
	end
end

--------------------------------------------------------------------------------
-- The detail panel
--------------------------------------------------------------------------------

local function CurrentRecipeDye()
	local pf = _G.ProfessionsFrame
	local sf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
	if not (sf and type(sf.GetRecipeInfo) == "function") then return nil end
	local ok, ri = pcall(sf.GetRecipeInfo, sf)
	if not ok then return nil end
	return DyeFromRecipeInfo(ri), sf
end

-- Two lines under the recipe title: how you're doing, and which flower to use.
--
-- The "use this one" line is the point of the file. The reagent picker's green
-- check only answers once flower prices exist, and a fresh install or an empty
-- realm auction house has none -- so the recommendation lives here too, where it
-- can fall back on what's in your bags. See ns.SuggestFlower.
local function DecorateDetail()
	local dye, sf = CurrentRecipeDye()
	if not sf then return end

	if not sf.ddthHaveNeed then
		local fs = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
		if sf.OutputText then
			fs:SetPoint("TOPLEFT", sf.OutputText, "BOTTOMLEFT", 0, -6)
		else
			fs:SetPoint("TOPLEFT", sf, "TOPLEFT", 60, -46)
		end
		sf.ddthHaveNeed = fs

		local use = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		use:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4)
		use:SetJustifyH("LEFT")
		sf.ddthUseFlower = use
	end
	local fs, use = sf.ddthHaveNeed, sf.ddthUseFlower

	if not dye then fs:Hide(); use:Hide(); return end

	local have, goal = ns.GetTotal(dye.key), ns.GetGoal(dye.key)
	if goal > 0 then
		fs:SetText(("You have %d  /  need %d"):format(have, goal))
		if have >= goal then fs:SetTextColor(0.5, 0.9, 0.5) else fs:SetTextColor(1.0, 0.82, 0.2) end
	else
		fs:SetText(("You have %d"):format(have))
		fs:SetTextColor(0.8, 0.8, 0.8)
	end
	fs:Show()

	local pick = ns.SuggestFlower and ns.SuggestFlower(dye.color)
	if not pick then
		use:Hide()
	else
		if pick.reason == "held" then
			-- You already own enough. Say how many it makes, because that is the
			-- number that decides whether you're done or still shopping.
			use:SetText(("Use |cffffd100%s|r — %d held, makes %d")
				:format(pick.name, pick.have, pick.dyes))
			use:SetTextColor(0.55, 0.85, 0.55)
		elseif pick.reason == "cheap" then
			use:SetText(("Cheapest: |cffffd100%s|r — %s for one dye")
				:format(pick.name, GetCoinTextureString and GetCoinTextureString(pick.cost)
					or (math.floor(pick.cost / 10000) .. "g")))
			use:SetTextColor(0.8, 0.8, 0.8)
		else
			-- Nothing held in quantity and nothing priced. Still better than silence:
			-- name the one they're closest on and how far off it is.
			local short = math.max(0, ns.HERBS_PER_DYE - pick.have)
			use:SetText(("Closest: |cffffd100%s|r — %d held, %d more for one dye")
				:format(pick.name, pick.have, short))
			use:SetTextColor(0.95, 0.7, 0.4)
		end
		use:Show()
	end
end

--------------------------------------------------------------------------------
-- The reagent picker: green check / red X on each flower
--
-- A dye takes ten of ONE flower, and a colour has as many as fifteen that make it.
-- Which is cheapest changes week to week, and the window sorts them by nothing in
-- particular — so this is the only part of the decision the game doesn't help
-- with. The verdict is flower-against-flower (see ns.GetHerbCraftVerdict): a red X
-- means "there's a cheaper flower in this list", not "don't bother".
--
-- The recipe IS the dye now, so the colour comes straight off the recipe. Before
-- 12.1 this had to work back from which pigment the recipe consumed.
--------------------------------------------------------------------------------

local CHECK_READY    = "Interface\\RaidFrame\\ReadyCheck-Ready"    -- green check
local CHECK_NOTREADY = "Interface\\RaidFrame\\ReadyCheck-NotReady" -- red X

local function CurrentRecipeColor()
	local dye = CurrentRecipeDye()
	return dye and dye.color or nil
end

local function DecorateFlyoutButton(btn, color)
	-- Respect the config toggle: if off, clear any mark and stop.
	if not DyeingDownTheHouseDB.ui.markHerbs then
		if btn.ddthVerdict then btn.ddthVerdict:Hide() end
		return
	end
	local ok, itemID = pcall(btn.GetItemID, btn)
	itemID = ok and itemID or nil
	-- NB: keep false (dearer) distinct from nil (unknown) — an `and/or` here would
	-- collapse false to nil and the red X would never show.
	local verdict = nil
	if color and itemID then verdict = ns.GetHerbCraftVerdictByID(itemID, color) end

	if verdict == nil then
		if btn.ddthVerdict then btn.ddthVerdict:Hide() end
		return
	end
	if not btn.ddthVerdict then
		local t = btn:CreateTexture(nil, "OVERLAY")
		t:SetSize(15, 15)
		t:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 2, 2)
		btn.ddthVerdict = t
	end
	btn.ddthVerdict:SetTexture(verdict and CHECK_READY or CHECK_NOTREADY)
	btn.ddthVerdict:Show()
end

local function DecorateFlyout(sb)
	if type(sb.GetFrames) ~= "function" then return end
	local ok, frames = pcall(sb.GetFrames, sb)
	if not ok or type(frames) ~= "table" then return end
	local color = CurrentRecipeColor()
	for _, btn in ipairs(frames) do
		if type(btn.GetItemID) == "function" then pcall(DecorateFlyoutButton, btn, color) end
	end
end

-- Scrollboxes already hooked (the flyout is reused, so hook its Update once).
local hookedFlyoutSB = setmetatable({}, { __mode = "k" })

-- Is this scrollbox the flower picker?
--
-- It used to be identified by `elementData.reagent`, which is what an ordinary
-- reagent flyout carries. 12.1's dye recipes are SALVAGE recipes and open a "Select
-- Item to Salvage" picker instead, which doesn't carry it — so the checkmarks
-- silently stopped appearing on the only recipes this addon exists for. Nothing
-- errored; the loop simply walked every frame in the client and matched none.
--
-- So it is identified by its CONTENTS now: a scrollbox whose buttons hand back item
-- IDs we know to be flowers IS the flower picker, whatever Blizzard is calling the
-- field this week. Self-validating, and immune to the next rename — which is the
-- same lesson the herb map and the dye panel both taught this release.
local function LooksLikeFlowerPicker(frames)
	for i = 1, math.min(#frames, 8) do
		local btn = frames[i]
		if type(btn.GetItemID) == "function" then
			local ok, itemID = pcall(btn.GetItemID, btn)
			local entry = ok and itemID and ns.byID[itemID]
			if entry and entry.kind == "herb" then return true end
		end
	end

	-- The pre-12.1 shape, kept as a fallback for an ordinary reagent flyout whose
	-- items we happen not to know.
	local first = frames[1]
	if first and type(first.GetElementData) == "function" then
		local ok, ed = pcall(first.GetElementData, first)
		if ok and type(ed) == "table" and ed.reagent then return true end
	end
	return false
end

local function FindAndDecorateFlyout()
	if type(EnumerateFrames) ~= "function" then return end
	local fr, guard = EnumerateFrames(), 0
	while fr and guard < 12000 do
		guard = guard + 1
		if fr.IsShown and fr:IsShown() then
			local sb = fr.ScrollBox
			if sb and type(sb.GetFrames) == "function" then
				local ok, frames = pcall(sb.GetFrames, sb)
				if ok and type(frames) == "table" and #frames > 0
					and LooksLikeFlowerPicker(frames) then
					if not hookedFlyoutSB[sb] then
						hookedFlyoutSB[sb] = true
						if type(sb.Update) == "function" then
							hooksecurefunc(sb, "Update", function() DecorateFlyout(sb) end)
						end
					end
					DecorateFlyout(sb)
					return
				end
			end
		end
		fr = EnumerateFrames(fr)
	end
end

--------------------------------------------------------------------------------
-- Hooking it up
--------------------------------------------------------------------------------

-- Exposed so the addon can refresh the markers when goals/counts change while the
-- window is open (ns.Refresh calls it). No-op until the window has been hooked.
ns.RefreshCraftingMarkers = function() end

-- Exposed so `/dye probe station` can report whether this ever managed to attach.
-- "I hooked nothing" and "I hooked it and there is nothing to mark" look identical
-- from the outside, and they need completely different fixes.
ns.craftingHooked = false

local hooked = false
local function Hook()
	if hooked then return end
	local pf = _G.ProfessionsFrame
	local rl = pf and pf.CraftingPage and pf.CraftingPage.RecipeList
	local sb = rl and rl.ScrollBox
	if not sb then return end
	hooked = true

	-- Redecorate whenever the list re-lays-out (scroll, filter, category collapse).
	if type(sb.Update) == "function" then hooksecurefunc(sb, "Update", DecorateList) end
	-- Update the "have/need" line whenever a recipe is shown in the detail panel.
	local sf = pf.CraftingPage.SchematicForm
	if sf then
		if type(sf.Init) == "function" then hooksecurefunc(sf, "Init", DecorateDetail) end
		if type(sf.Refresh) == "function" then hooksecurefunc(sf, "Refresh", DecorateDetail) end
	end
	-- Our own refresh (goal/count changes) updates both the list and the detail.
	ns.RefreshCraftingMarkers = function() DecorateList(); DecorateDetail() end
	ns.craftingHooked = true
	DecorateList()
	DecorateDetail()

	-- When the reagent picker opens, mark each flower. Defer a frame so the flyout
	-- is populated before we look for it.
	if type(_G.OpenProfessionsItemFlyout) == "function" then
		hooksecurefunc("OpenProfessionsItemFlyout", function()
			C_Timer.After(0, FindAndDecorateFlyout)
		end)
	end
end

-- Attaching is RETRIED, because the addon loading and its frames existing are two
-- different moments. ADDON_LOADED fires when the file has run, which can be before
-- CraftingPage.RecipeList.ScrollBox has been built -- and the old version gave up
-- permanently at that point, leaving `hooked` false with nothing left to try again.
-- A window that loads a fraction early would silently never be decorated.
--
-- Bounded, so a client where this frame genuinely doesn't exist stops asking.
local MAX_ATTEMPTS = 20
local attempts = 0

local function TryHook()
	if hooked then return end
	attempts = attempts + 1
	pcall(Hook)
	if not hooked and attempts < MAX_ATTEMPTS then
		C_Timer.After(0.5, TryHook)
	end
end

local waiter = CreateFrame("Frame")
waiter:RegisterEvent("ADDON_LOADED")
waiter:RegisterEvent("PLAYER_ENTERING_WORLD")
waiter:SetScript("OnEvent", function(_, event, name)
	if hooked then return end
	if event == "PLAYER_ENTERING_WORLD" then
		TryHook()
	elseif type(name) == "string" and name:lower():find("profession", 1, true) then
		-- Any professions addon, not just the one name. The station's window is
		-- Blizzard_Professions today; being narrower than that buys nothing.
		attempts = 0
		TryHook()
	end
end)

-- Already loaded (e.g. /reload with the window open)? Attach straight away.
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
	TryHook()
end
