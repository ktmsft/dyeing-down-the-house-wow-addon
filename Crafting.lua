local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Crafting.lua — decorate Blizzard's Dye Crafting window.
--
-- Puts a small "to craft" box on any recipe row for a dye you own fewer of than
-- your goal, so the ones worth crafting stand out in the game's own list.
--
-- This hooks the retail Professions UI (Blizzard_Professions, load-on-demand),
-- which is internal and can shift between patches — so every step is
-- feature-detected and pcall-wrapped, and the recipe→dye match is verified against
-- the row's own item hyperlink (never guessed). Verified shapes (2026-07-20):
--   ProfessionsFrame.CraftingPage.RecipeList.ScrollBox:GetFrames()
--   button:GetElementData().data.recipeInfo  -> { name, recipeID, hyperlink, ... }
--------------------------------------------------------------------------------

local function DyeFromRecipeInfo(recipeInfo)
	if type(recipeInfo) ~= "table" then return nil end
	-- Prefer the exact item ID carried in the row's hyperlink.
	local itemID = recipeInfo.hyperlink and tonumber(recipeInfo.hyperlink:match("Hitem:(%d+)"))
	local entry = itemID and ns.byID[itemID]
	if entry and entry.kind == "dye" then return entry end
	-- Fall back to a name match.
	if recipeInfo.name then
		local e = ns.byName[recipeInfo.name:lower()]
		if e and e.kind == "dye" then return e end
	end
	return nil
end

local function ShouldCraft(dye)
	local goal = ns.GetGoal(dye.key)
	return goal > 0 and ns.GetTotal(dye.key) < goal
end

local function DecorateButton(button)
	local ed = button.GetElementData and button:GetElementData()
	local data = ed and ed.data
	local recipeInfo = data and data.recipeInfo
	local dye = recipeInfo and DyeFromRecipeInfo(recipeInfo)

	-- Mark ONLY dyes you want to craft: a goal is set and you own fewer than it.
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

-- A "have X / need Y" line under the recipe title in the detail (schematic) panel.
local function DecorateDetail()
	local pf = _G.ProfessionsFrame
	local sf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
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

	local ok, ri = pcall(sf.GetRecipeInfo, sf)
	local dye = ok and DyeFromRecipeInfo(ri)
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
-- Pigment crafting: green check / red X on each herb in the reagent picker.
--
-- The picker is an anonymous ScrollBox flyout (verified: buttons expose
-- :GetItemID() and elementData.reagent.itemID). Its recipe is a pigment, whose
-- color decides the verdict — is milling this herb worth it for that color
-- (10 × herb price vs the best dye of the color)?
--------------------------------------------------------------------------------

local CHECK_READY   = "Interface\\RaidFrame\\ReadyCheck-Ready"    -- green check
local CHECK_NOTREADY = "Interface\\RaidFrame\\ReadyCheck-NotReady" -- red X

local function CurrentPigmentColor()
	local pf = _G.ProfessionsFrame
	local sf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
	if not (sf and type(sf.GetRecipeInfo) == "function") then return nil end
	local ok, ri = pcall(sf.GetRecipeInfo, sf)
	if not ok or type(ri) ~= "table" then return nil end
	local itemID = ri.hyperlink and tonumber(ri.hyperlink:match("Hitem:(%d+)"))
	local entry = itemID and ns.byID[itemID]
	if entry and entry.kind == "pigment" then return entry.color end
	if ri.name then
		local e = ns.byName[ri.name:lower()]
		if e and e.kind == "pigment" then return e.color end
	end
	return nil
end

local function DecorateFlyoutButton(btn, color)
	-- Respect the config toggle: if off, clear any mark and stop.
	if not DyeingDownTheHouseDB.ui.markHerbs then
		if btn.ddthVerdict then btn.ddthVerdict:Hide() end
		return
	end
	local ok, itemID = pcall(btn.GetItemID, btn)
	itemID = ok and itemID or nil
	-- NB: keep false (prohibitive) distinct from nil (unknown) — an `and/or` here
	-- would collapse false to nil and the red X would never show.
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
	local color = CurrentPigmentColor()
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

	-- Feature #2: when the reagent picker opens, mark each herb craft-worth. Defer a
	-- frame so the flyout is populated before we look for it.
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
