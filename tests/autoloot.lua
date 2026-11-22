-- Run from the repository root: lua tests\autoloot.lua
local frames = {}
local equippedItem
local lootedSlots = {}
local closeCount = 0

SlashCmdList = {}
UIParent = {}
EverFishingDB = { enableAutoLoot = true }

function GetBuildInfo()
    return nil, nil, nil, 16001
end

function CreateFrame()
    local frame = { scripts = {} }
    function frame:SetAttribute() end
    function frame:SetSize() end
    function frame:SetPoint() end
    function frame:SetAlpha() end
    function frame:RegisterForClicks() end
    function frame:Show() end
    function frame:RegisterEvent() end
    function frame:SetScript(event, handler)
        self.scripts[event] = handler
    end
    frames[#frames + 1] = frame
    return frame
end

function InCombatLockdown() return false end
function ClearOverrideBindings() end
function GetInventoryItemID(unit, slot)
    assert(unit == "player" and slot == 16)
    return equippedItem
end
function GetItemInfoInstant(itemID)
    local subclass = ({ [100] = 20, [101] = 25, [200] = 7 })[itemID]
    return nil, nil, nil, nil, nil, 2, subclass
end
function GetNumLootItems() return 2 end
function LootSlot(slot)
    lootedSlots[#lootedSlots + 1] = slot
end
function CloseLoot()
    closeCount = closeCount + 1
end

local addon = {}
assert(loadfile("EverFishing\\Data.lua"))("EverFishing", addon)
assert(loadfile("EverFishing\\Core.lua"))("EverFishing", addon)
addon.InitializeClickHandling()
local clickFrame = frames[#frames]

local function checkLoot(event, expected, description)
    lootedSlots = {}
    closeCount = 0
    clickFrame.scripts.OnEvent(clickFrame, event)
    assert(#lootedSlots == (expected and 2 or 0), description .. ": loot calls")
    assert(closeCount == (expected and 1 or 0), description .. ": close calls")
    if expected then
        assert(lootedSlots[1] == 1 and lootedSlots[2] == 2, description .. ": slots")
    end
end

equippedItem = 100
checkLoot("LOOT_OPENED", true, "Fishing pole equipped")
equippedItem = 200
clickFrame.scripts.OnEvent(clickFrame, "PLAYER_EQUIPMENT_CHANGED", 16)
checkLoot("LOOT_OPENED", false, "Swapped to a weapon after fishing")
equippedItem = nil
checkLoot("LOOT_OPENED", false, "Empty main hand")
equippedItem = 101
checkLoot("LOOT_OPENED", true, "Re-equipped Forever fishing pole")
EverFishingDB.enableAutoLoot = false
checkLoot("LOOT_OPENED", false, "Auto-loot disabled with pole equipped")
EverFishingDB.enableAutoLoot = true
checkLoot("LOOT_READY", false, "Loot-ready does not loot")
checkLoot("LOOT_CLOSED", false, "Loot-closed does not loot")

print("Auto-loot regression tests passed.")
