local addonName, addon = ...
local E = addon:Eve()

local CACHE_TIMEOUT = 5 -- seconds to keep stale information before issuing a new inspect

local print = function()
end -- lazy debug print
local GuidCache = {} -- [guid] = {ilevel, specName, timestamp}
local ActiveGUID  -- unit passed to NotifyInspect before INSPECT_READY fires
local ScannedGUID  -- actually-inspected unit from INSPECT_READY
local INSPECT_TIMEOUT = 1.5 -- safety cap on how often the api will allow us to call NotifyInspect without issues
-- lowering will result in the function silently failing without firing the inspection event

local function GetUnitIDFromGUID(guid)
	local _, _, _, _, _, name = GetPlayerInfoByGUID(guid)
	if UnitExists(name) then -- unit is in our group and can use its name as a unit ID
		return name, name
	elseif UnitGUID("mouseover") == guid then -- unit is under our cursor
		return "mouseover", name
	elseif UnitGUID("target") == guid then -- unit is our target
		return "target", name
	elseif GetCVar("nameplateShowFriends") == "1" then -- friendly nameplates are visible
		for i = 1, 30 do
			local unitID = "nameplate" .. i
			local nameplateGUID = UnitGUID(unitID)
			if nameplateGUID then
				if nameplateGUID == guid then
					return unitID, name
				end
			else
				break
			end
		end
	else -- scan every group member's target (this is probably overkill)
		local numMembers = GetNumGroupMembers()
		if numMembers > 0 then
			local unitPrefix = IsInRaid() and "raid" or "party"
			if unitPrefix == "party" then
				numMembers = numMembers - 1
			end
			for i = 1, numMembers do
				local unitID = unitPrefix .. i .. "-target"
				local targetGUID = UnitGUID(unitID)
				if targetGUID == guid then
					return unitID, name
				end
			end
		end
	end
	-- no convenient unit ID is available, we tried
	return nil, name
end

local function ColorGradient(perc, r1, g1, b1, r2, g2, b2)
	if perc >= 1 then
		local r, g, b = r2, g2, b2 -- select(select('#', ...) - 2, ...)
		return r, g, b
	elseif perc <= 0 then
		local r, g, b = r1, g1, b1
		return r, g, b
	end

	--local num = 2 -- select('#', ...) / 3
	--local segment, relperc = math.modf(perc) --*(num-1))
	--local r1, g1, b1, r2, g2, b2 = select((segment*3)+1, ...)

	return r1 + (r2 - r1) * perc, g1 + (g2 - g1) * perc, b1 + (b2 - b1) * perc
end

local function ColorDiff(a, b)
	local diff = a - b
	local perc = diff / 30

	local r, g, b
	if perc < 0 then -- higher ilevel than us
		perc = perc * -1
		r, g, b = ColorGradient(perc, 1, 1, 0, 0, 1, 0)
	else
		r, g, b = ColorGradient(perc, 1, 1, 0, 1, 0, 0)
	end
	return r, g, b
end

local ItemLevelPattern1 = ITEM_LEVEL:gsub("%%d", "(%%d+)")
local ItemLevelPattern2 = ITEM_LEVEL_ALT:gsub("([()])", "%%%1"):gsub("%%d", "(%%d+)")

local TwoHanders = {
	-- item types that are two handed, as returned as the 4th result from GetItemInfoInstant
	["INVTYPE_RANGED"] = true,
	["INVTYPE_RANGEDRIGHT"] = true,
	["INVTYPE_2HWEAPON"] = true
}

local InventorySlots = {}
for i = 1, 17 do
	if i ~= 4 then -- ignore shirt, tabard is 19
		tinsert(InventorySlots, i)
	end
end

local function IsArtifact(itemLink)
	return itemLink:find("|cffe6cc80") -- this is probably a horrible way to find whether it's an artifact
end

local function IsLegendary(itemLink)
	return false
	-- return itemLink:find('|cffff8000')
end

local function IsCached(itemLink) -- we can't get the correct level of an artifact until all of its relics have been cached
	local cached = true
	local _, itemID, _, relic1, relic2, relic3 = strsplit(":", itemLink)
	print(strsplit(":", itemLink))
	if not GetDetailedItemLevelInfo(itemID) then
		cached = false
	end
	if IsArtifact(itemLink) then
		if relic1 and relic1 ~= "" and not GetDetailedItemLevelInfo(relic1) then
			cached = false
		end
		if relic2 and relic2 ~= "" and not GetDetailedItemLevelInfo(relic2) then
			cached = false
		end
		if relic3 and relic3 ~= "" and not GetDetailedItemLevelInfo(relic3) then
			cached = false
		end
	end
	print(cached)
	return cached
end

local Sekret = "|Hilvl|h"
local function AddLine(sekret, leftText, rightText, r1, g1, b1, r2, g2, b2, dontShow)
	--if GameTooltip:IsVisible() then
	if not r1 then
		r1, g1, b1, r2, g2, b2 = 1, 1, 0, 1, 1, 0
	end
	leftText = sekret .. leftText
	for i = 2, GameTooltip:NumLines() do
		local leftStr = _G["GameTooltipTextLeft" .. i]
		local text = leftStr and leftStr:IsShown() and leftStr:GetText()
		if text and text:find(sekret) then
			-- edit line
			--local rightStr = _G['GameTooltipTextRight' .. i]
			leftStr:SetText(leftText)
			--rightStr:SetText(rightText)
			if r1 and g1 and b1 then
				leftStr:SetTextColor(r1, g1, b1)
			end
			--if r2 and g2 and b2 then
			--rightStr:SetTextColor(r2, g2, b2)
			--end
			return
		end
	end
	if not dontShow or GameTooltip:IsShown() then
		GameTooltip:AddLine(leftText, r1, g1, b1)
		GameTooltip:Show()
	end
	--end
end

-- OnTooltipSetUnit: NotifyInspect(unit)
-- on INSPECT_READY do
-- for each slot, tooltip:SetInventoryItem(unit, slot)
-- OnTooltipSetItem: if IsCached then update slot item level
-- when all items are accounted for, update tooltip
local SlotCache = {} -- [slot] = itemLevel or false
local ItemCache = {} -- [slot] = itemLink
local TestTips = {}
for i, slot in pairs(InventorySlots) do
	local tip = CreateFrame("GameTooltip", "AverageItemLevelTooltip" .. slot, nil, "GameTooltipTemplate")
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	TestTips[slot] = tip
	tip.slot = slot
	tip:SetScript(
		"OnTooltipSetItem",
		function(self)
			local slot = self.slot
			local _, itemLink = self:GetItem()
			local tipName = self:GetName()
			if self.itemLink then
				itemLink = self.itemLink
			end
			if itemLink then
				local isCached = IsCached(itemLink)
				if isCached then
					for i = 2, self:NumLines() do
						local str = _G[tipName .. "TextLeft" .. i]
						local text = str and str:GetText()
						if text then
							local ilevel = text:match(ItemLevelPattern1)
							if not ilevel then
								ilevel = text:match(ItemLevelPattern2)
							end
							if ilevel then
								SlotCache[slot] = tonumber(ilevel)
								ItemCache[slot] = itemLink
							end
						end
					end
				end
			end

			local finished = true
			local totalItemLevel = 0
			for slot, ilevel in pairs(SlotCache) do
				if not ilevel then
					finished = false
					break
				else
					if slot ~= 16 and slot ~= 17 then
						totalItemLevel = totalItemLevel + ilevel
					end
				end
			end

			if finished then
				local weaponLevel = 0
				local isDual = false
				if SlotCache[16] and SlotCache[17] then -- we have 2 weapons
					isDual = true
					if IsArtifact(ItemCache[16]) or IsArtifact(ItemCache[17]) then -- take the higher of the 2 weapons and double it
						local ilevelMain = SlotCache[16]
						local ilevelOff = SlotCache[17]
						weaponLevel = ilevelMain > ilevelOff and ilevelMain or ilevelOff
						totalItemLevel = totalItemLevel + (weaponLevel * 2)
					else
						local ilevelMain = SlotCache[16]
						local ilevelOff = SlotCache[17]
						totalItemLevel = totalItemLevel + ilevelMain + ilevelOff
						if ilevelMain > ilevelOff then
							weaponLevel = ilevelMain
						else
							weaponLevel = ilevelOff
						end
					end
				elseif SlotCache[16] then -- main hand only
					local _, _, _, weaponType = GetItemInfoInstant(ItemCache[16])
					local ilevelMain = SlotCache[16]
					weaponLevel = ilevelMain
					if TwoHanders[weaponType] then -- 2 handed, count it twice
						totalItemLevel = totalItemLevel + (ilevelMain * 2)
					else
						totalItemLevel = totalItemLevel + ilevelMain
					end
				elseif SlotCache[17] then -- off hand only?
					local ilevelOff = SlotCache[17]
					totalItemLevel = totalItemLevel + ilevelOff
					weaponLevel = ilevelOff
				end

				if weaponLevel >= 900 and ScannedGUID ~= UnitGUID("player") then
					weaponLevel = weaponLevel + 15
					if isDual then
						totalItemLevel = totalItemLevel + 15
					else
						totalItemLevel = totalItemLevel + 30
					end
				end

				local averageItemLevel = totalItemLevel / 16

				-- should we just return the cache for this GUID?
				local guid = ScannedGUID
				if not GuidCache[guid] then
					GuidCache[guid] = {}
				end
				--GuidCache[guid].specName = specName
				GuidCache[guid].ilevel = averageItemLevel
				GuidCache[guid].weaponLevel = weaponLevel
				GuidCache[guid].neckLevel = SlotCache[2]
				--GuidCache[guid].levelText = levelText
				GuidCache[guid].timestamp = GetTime()

				-- todo: figure out why this can fire multiple times
				wipe(GuidCache[guid].legos)
				for slot, link in pairs(ItemCache) do
					if IsLegendary(link) then
						tinsert(GuidCache[guid].legos, link)
					end
				end

				E("ItemScanComplete", guid, GuidCache[guid])
			end
		end
	)
end

local function GetTooltipGUID()
	--if GameTooltip:IsVisible() then
	local _, unitID = GameTooltip:GetUnit()
	local guid = unitID and UnitGUID(unitID)
	if UnitIsPlayer(unitID) and CanInspect(unitID) then
		return guid
	end
	--end
end

local f = CreateFrame("frame", nil, GameTooltip)
local ShouldInspect = false
local LastInspect = 0
local FailTimeout = 1
f:SetScript(
	"OnUpdate",
	function(self, elapsed)
		local _, unitID = GameTooltip:GetUnit()
		local guid = unitID and UnitGUID(unitID)
		if not guid or (InspectFrame and InspectFrame:IsVisible()) then
			return
		end
		local timeSince = GetTime() - LastInspect
		if ShouldInspect and (ActiveGUID == guid or (timeSince >= INSPECT_TIMEOUT)) then
			ShouldInspect = false
			-- inspect whoever's in the tooltip and set to a unit we can inspect
			if ActiveGUID ~= guid then -- todo: make sure this isn't going to be a problem
				local cache = GuidCache[guid]
				if cache and GetTime() - cache.timestamp <= CACHE_TIMEOUT then -- rescan only if enough time has elapsed
					print("Still cached")
				elseif CanInspect(unitID) then
					NotifyInspect(unitID)
				end
			end
		elseif ShouldInspect and (timeSince < INSPECT_TIMEOUT) then -- we are waiting for another inspection to time out before starting a new one
			if unitID and UnitIsPlayer(unitID) and CanInspect(unitID) and not GuidCache[guid] then
			-- AddLine(Sekret, 'Pending', format('%.1fs', INSPECT_TIMEOUT - (GetTime() - LastInspect)), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
			end
		else
			-- todo: handle the tooltip being visible with no attempt at inspecting the unit
			if ActiveGUID then
				if guid == ActiveGUID then
					if timeSince <= FailTimeout then
						-- AddLine(Sekret, 'Scanning', format('%d%%', timeSince / FailTimeout * 100), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
					else
						-- AddLine(Sekret, 'Scanning', 'Failed', 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
						ActiveGUID = nil
					end
				else
					ActiveGUID = nil
					-- inspected guid doesn't match who the tooltip is displaying
					if timeSince > FailTimeout and CanInspect(unitID) then
						NotifyInspect(unitID) -- reissue notification attempt
					end
				end
			end
		end
	end
)

hooksecurefunc(
	"NotifyInspect",
	function(unitID)
		print("NotifyInspect!", unitID, UnitGUID(unitID), (select(6, GetPlayerInfoByGUID(UnitGUID(unitID)))))
		if not GuidCache[UnitGUID(unitID)] then
			ActiveGUID = UnitGUID(unitID)
		end
		LastInspect = GetTime()
	end
)

hooksecurefunc(
	"ClearInspectPlayer",
	function()
		ActiveGUID = nil
	end
)

local function DoInspect()
	ShouldInspect = true
end

local function DecorateTooltip(guid)
	local cache = GuidCache[guid]
	if not cache then
		print("no cache?")
		return
	end
	if GetTooltipGUID() == guid then -- make sure we're looking at the same unit
		--AddLine(STAT_AVERAGE_ITEM_LEVEL, cache.ilevel, 1, 1, 0, 1, 1, 1, true)
		local ourMaxItemLevel, ourEquippedItemLevel = GetAverageItemLevel()

		local averageItemLevel = cache.ilevel or 0
		--local weaponLevel = cache.weaponLevel or 0
		local neckLevel = cache.neckLevel or 0
		local r1, g1, b1 = ColorDiff(ourEquippedItemLevel, averageItemLevel)
		local ourNeck = GetInventoryItemLink("player", 2)
		local ourNeckLevel = GetDetailedItemLevelInfo(ourNeck or "") or 0
		--[[
		local ourWeaponMain = GetInventoryItemLink('player', 16)
		local ourWeaponOff = GetInventoryItemLink('player', 17)
		local ourWeaponLevel = 0
		if ourWeaponOff and ourWeaponMain then -- dual wielding
			local mainLevel = GetDetailedItemLevelInfo(ourWeaponMain)
			local offLevel = GetDetailedItemLevelInfo(ourWeaponOff)
			if mainLevel > offLevel then
				ourWeaponLevel = mainLevel
			else
				ourWeaponLevel = offLevel
			end
		elseif ourWeaponMain then
			ourWeaponLevel = GetDetailedItemLevelInfo(ourWeaponMain)
		elseif ourWeaponOff then
			ourWeaponLevel = GetDetailedItemLevelInfo(ourWeaponOff)
		end
		--]]
		local r2, g2, b2 = ColorDiff(ourNeckLevel, neckLevel)

		--local levelText = format('%s |cff%2x%2x%2x%.1f|r |cff%2x%2x%2x(%s)|r', cache.specName or '', r1 * 255, g1 * 255, b1 * 255, averageItemLevel, r2 * 255, g2 * 255, b2 * 255, cache.itemLevel)
		local levelText =
			format("%s ilvl |cff%2x%2x%2x%.1f|r", cache.specName or "", r1 * 255, g1 * 255, b1 * 255, averageItemLevel)
		--local levelText = format('|cff%2x%2x%2x%.1f|r', r1 * 255, g1 * 255, b1 * 255, averageItemLevel, r2 * 255, g2 * 255, b2 * 255)

		AddLine(Sekret, levelText, "", 1, 1, 0, r1, g1, b1)

		for i, lego in ipairs(cache.legos) do
			AddLine("|Hlego" .. i .. "|h", lego, " ", 1, 1, 1, 1, 1, 1)
		end
	else
		print("tooltip GUID does not match expected guid")
	end
end

local function ScanUnit(unitID)
	print("SCANNING UNIT", unitID)
	ScannedGUID = UnitGUID(unitID)
	wipe(SlotCache)
	wipe(ItemCache)
	wipe(GuidCache[ScannedGUID].legos)
	local numEquipped = 0
	for i, slot in pairs(InventorySlots) do
		if GetInventoryItemTexture(unitID, slot) then -- we have an item in this slot
			SlotCache[slot] = false
			print("GetInventoryItemTexture", slot, GetInventoryItemTexture(unitID, slot))
			numEquipped = numEquipped + 1
		end
	end

	if numEquipped > 0 then
		for slot in pairs(SlotCache) do
			TestTips[slot].itemLink = GetInventoryItemLink(unitID, slot)
			--print('GetInveotryItemLink', TestTips[slot].itemLink, slot)
			TestTips[slot]:SetOwner(WorldFrame, "ANCHOR_NONE")
			TestTips[slot]:SetInventoryItem(unitID, slot)
		end
	else -- they don't appear to be wearing anything, return nothing
		local guid = ScannedGUID
		if not GuidCache[guid] then
			GuidCache[guid] = {}
		end
		GuidCache[guid].ilevel = 0
		GuidCache[guid].weaponLevel = 0
		GuidCache[guid].timestamp = GetTime()
		E("ItemScanComplete", guid, GuidCache[guid])
	end
end

function E:INSPECT_READY(guid)
	print("INSPECT_READY")
	ActiveGUID = nil
	local unitID, name = GetUnitIDFromGUID(guid)
	if unitID then
		print("INSPECT_READY", unitID, name)
		local classDisplayName, class = UnitClass(unitID)
		local colors = class and RAID_CLASS_COLORS[class]
		local specID = GetInspectSpecialization(unitID)
		local specName  -- = GuidCache[guid].specName
		if not specName and specID and specID ~= 0 then
			specID, specName = GetSpecializationInfoByID(specID, UnitSex(unitID))
			if colors then
				specName = "|c" .. colors.colorStr .. specName .. "|r"
			end
		end

		if not GuidCache[guid] then
			GuidCache[guid] = {ilevel = 0, weaponLevel = 0, timestamp = 0, legos = {}}
		end
		local cache = GuidCache[guid]
		cache.specID = specID
		cache.class = class
		cache.specName = specName
		cache.itemLevel = C_PaperDollInfo.GetInspectItemLevel(unitID)

		ScanUnit(unitID)
	--else
	--	print(format('No unit ID available to inspect %s', name))
	end
end

function E:ItemScanComplete(guid, cache)
	print("ItemScanComplete", guid, cache)
	--AddLine(STAT_AVERAGE_ITEM_LEVEL, cache.ilevel, 1, 1, 0, 1, 1, 1, true)
	DecorateTooltip(guid)
end

GameTooltip:HookScript(
	"OnTooltipSetUnit",
	function(self) -- this fires before the tooltip is visible
		print("OnTooltipSetUnit")
		local _, unitID = self:GetUnit()
		local guid = unitID and UnitGUID(unitID)
		if guid and UnitIsPlayer(unitID) then
			print("OnTooltipSetUnit", guid, UnitName(unitID))
			local cache = GuidCache[guid]
			if cache then
				-- fill tooltip with cached data, but initiate a new scan anyway to update it
				--AddLine(STAT_AVERAGE_ITEM_LEVEL, '???', 1, 0, 0, 1, 0, 0)
				DecorateTooltip(guid)
			end
			if CanInspect(unitID) then
				DoInspect()
			end
		end
	end
)
