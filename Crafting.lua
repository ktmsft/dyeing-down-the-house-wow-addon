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

-- A "have X / need Y" line under the recipe title.
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
	end
	local fs = sf.ddthHaveNeed

	if not dye then fs:Hide(); return end

	local have, goal = ns.GetTotal(dye.key), ns.GetGoal(dye.key)
	if goal > 0 then
		fs:SetText(("You have %d  /  need %d"):format(have, goal))
		if have >= goal then fs:SetTextColor(0.5, 0.9, 0.5) else fs:SetTextColor(1.0, 0.82, 0.2) end
	else
		fs:SetText(("You have %d"):format(have))
		fs:SetTextColor(0.8, 0.8, 0.8)
	end
	fs:Show()
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

local function FindAndDecorateFlyout()
	if type(EnumerateFrames) ~= "function" then return end
	local fr, guard = EnumerateFrames(), 0
	while fr and guard < 12000 do
		guard = guard + 1
		if fr.IsShown and fr:IsShown() then
			local sb = fr.ScrollBox
			if sb and type(sb.GetFrames) == "function" then
				local ok, frames = pcall(sb.GetFrames, sb)
				local first = ok and frames and frames[1]
				-- The reagent flyout's buttons expose an item ID and a .reagent.
				if first and type(first.GetElementData) == "function" then
					local ok2, ed = pcall(first.GetElementData, first)
					if ok2 and type(ed) == "table" and ed.reagent then
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

local waiter = CreateFrame("Frame")
waiter:RegisterEvent("ADDON_LOADED")
waiter:SetScript("OnEvent", function(_, _, name)
	if name == "Blizzard_Professions" then
		pcall(Hook)
		waiter:UnregisterEvent("ADDON_LOADED")
	end
end)

-- Already loaded (e.g. /reload with the window open)? Hook straight away.
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
	pcall(Hook)
end
