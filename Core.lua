local addonName, EF = ...
EF = EF or {}
_G.EverFishing = EF
local DATA = EF.Data

local MIN_DOUBLE_CLICK = 0.05
local lastClickTime = 0
local pendingClearTimer = nil
local clearBindingOnMouseUp = false
local lootOpen = false
local fishingPaused = false
local clickDiagnostics = {
    mouseDowns = 0,
    mouseUps = 0,
    bindingsArmed = 0,
    bindingsExpired = 0,
    securePreClicks = 0,
    secureReadyClicks = 0,
    securePostClicks = 0,
    lastBlocker = "No selected mouse click observed yet.",
}

local DB_DEFAULTS = {
    enableAutoLure = true,
    lureStrategy = "Smart", -- "Smart", "Weakest", "Strongest"
    doubleClickDelay = 0.4,
    doubleClickButton = "LeftButton",
    castClickMode = "DoubleClick",
    enableAutoLoot = true,
}

local BUTTON_OPTIONS = {
    { key = "LeftButton", binding = "BUTTON1", label = "Left Mouse" },
    { key = "RightButton", binding = "BUTTON2", label = "Right Mouse" },
    { key = "MiddleButton", binding = "BUTTON3", label = "Middle Mouse" },
    { key = "Button4", binding = "BUTTON4", label = "Mouse Button 4" },
    { key = "Button5", binding = "BUTTON5", label = "Mouse Button 5" },
}

local BUTTON_BY_KEY = {}
for _, option in ipairs(BUTTON_OPTIONS) do
    BUTTON_BY_KEY[option.key] = option
end

local function GetButtonOption(key)
    return BUTTON_BY_KEY[key] or BUTTON_BY_KEY[DB_DEFAULTS.doubleClickButton]
end

local function InitializeSettings()
    if type(EverFishingDB) ~= "table" then EverFishingDB = {} end
    for key, default in pairs(DB_DEFAULTS) do
        if type(EverFishingDB[key]) ~= type(default) then
            EverFishingDB[key] = default
        end
    end
    if not BUTTON_BY_KEY[EverFishingDB.doubleClickButton] then
        EverFishingDB.doubleClickButton = DB_DEFAULTS.doubleClickButton
    end
    if EverFishingDB.castClickMode ~= "SingleClick" and EverFishingDB.castClickMode ~= "DoubleClick" then
        EverFishingDB.castClickMode = DB_DEFAULTS.castClickMode
    end
    if EverFishingDB.lureStrategy ~= "Smart" and EverFishingDB.lureStrategy ~= "Weakest" and EverFishingDB.lureStrategy ~= "Strongest" then
        EverFishingDB.lureStrategy = DB_DEFAULTS.lureStrategy
    end
    local delay = EverFishingDB.doubleClickDelay
    if delay ~= delay then delay = DB_DEFAULTS.doubleClickDelay end
    EverFishingDB.doubleClickDelay = math.max(0.1, math.min(0.8, delay))
end

local function GetDoubleClickDelay()
    return EverFishingDB.doubleClickDelay or DB_DEFAULTS.doubleClickDelay
end

local function IsFishingPoleEquipped()
    local mainHand = GetInventoryItemID("player", DATA.MAIN_HAND_SLOT)
    if not mainHand then return false end
    local _, classID, subclassID
    if C_Item and C_Item.GetItemInfoInstant then
        _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(mainHand)
    elseif GetItemInfoInstant then
        _, _, _, _, _, classID, subclassID = GetItemInfoInstant(mainHand)
    elseif GetItemInfo then
        _, _, _, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfo(mainHand)
    end
    return classID == DATA.FISHING_ITEM_CLASS_ID and DATA.FISHING_POLE_SUBCLASS_IDS[subclassID]
end

local function GetFishingSpellName()
    local name
    if C_Spell and C_Spell.GetSpellName then
        for _, spellID in ipairs(DATA.FISHING_SPELL_IDS) do
            name = C_Spell.GetSpellName(spellID)
            if name then break end
        end
    elseif GetSpellInfo then
        for _, spellID in ipairs(DATA.FISHING_SPELL_IDS) do
            name = GetSpellInfo(spellID)
            if name then break end
        end
    end
    return name or "Fishing"
end

local function IsFishingChannelActive()
    return UnitChannelInfo("player") == GetFishingSpellName()
end

local function IsMouseOverWorld()
    if type(GetMouseFoci) == "function" then
        local foci = GetMouseFoci()
        if type(foci) == "table" and #foci > 0 then
            return foci[1] == WorldFrame
        end
    end
    if WorldFrame and type(WorldFrame.IsMouseMotionFocus) == "function"
        and WorldFrame:IsMouseMotionFocus() then
        return true
    end
    if type(GetMouseFocus) == "function" then
        return GetMouseFocus() == WorldFrame
    end
    return false
end

local function GetFishingSkill()
    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        local _, _, _, fishingIndex = GetProfessions()
        if fishingIndex then
            local _, _, skillLevel, maximumSkill = GetProfessionInfo(fishingIndex)
            if type(skillLevel) == "number" then
                return skillLevel, tonumber(maximumSkill)
            end
        end
    end

    if not GetNumSkillLines or not GetSkillLineInfo then return nil end
    local fishingName = GetFishingSpellName()
    for index = 1, GetNumSkillLines() do
        local skillName, isHeader, _, rank, _, _, maximumSkill = GetSkillLineInfo(index)
        if not isHeader and skillName == fishingName and type(rank) == "number" then
            return rank, tonumber(maximumSkill)
        end
    end
end

local function GetItemCountWrapper(itemID)
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID)
    elseif GetItemCount then
        return GetItemCount(itemID)
    end
    return 0
end

local function GetAvailableLures()
    local available = {}
    local skill = GetFishingSkill() or 0
    for _, lure in ipairs(DATA.LURES) do
        local count = GetItemCountWrapper(lure.id)
        if count > 0 and skill >= lure.minimumSkill then
            table.insert(available, { id = lure.id, count = count, bonus = lure.bonus or 0 })
        end
    end
    table.sort(available, function(first, second)
        if first.bonus == second.bonus then
            return first.id < second.id
        end
        return first.bonus < second.bonus
    end)
    return available
end

local function GetAutoLureID()
    if not EverFishingDB or not EverFishingDB.enableAutoLure then return nil end
    if not IsFishingPoleEquipped() then return nil end

    local hasMainHandEnchant = GetWeaponEnchantInfo()
    if hasMainHandEnchant then return nil end

    -- Smart Lure Logic: Check if we are max skill
    if EverFishingDB.lureStrategy == "Smart" then
        local skill, maxSkill = GetFishingSkill()
        if skill and maxSkill and skill >= maxSkill then
            return nil -- We are maxed out, save the lures!
        end
    end

    local availableLures = GetAvailableLures()
    if #availableLures == 0 then return nil end

    local strategy = EverFishingDB.lureStrategy or "Smart"
    local lure
    if strategy == "Strongest" then
        lure = availableLures[#availableLures]
    else
        -- Default to Weakest for both "Weakest" and "Smart" (if not maxed)
        lure = availableLures[1] 
    end
    
    return lure and lure.id
end

-- ---------------------------------------------------------------------------
-- Click-to-cast
-- ---------------------------------------------------------------------------

local castOwner = CreateFrame("Frame", "EverFishingCastOwner", UIParent, "SecureHandlerStateTemplate")
castOwner:SetAttribute("_onstate-efcombat", [[
    if newstate == "combat" then self:ClearBindings() end
]])
if RegisterStateDriver then
    RegisterStateDriver(castOwner, "efcombat", "[combat] combat; safe")
end

local function CancelPendingTimer()
    if pendingClearTimer then
        pendingClearTimer:Cancel()
        pendingClearTimer = nil
    end
end

local function ClearBinding()
    CancelPendingTimer()
    if not InCombatLockdown() then
        ClearOverrideBindings(castOwner)
    end
    lastClickTime = 0
    clearBindingOnMouseUp = false
end

local autoLureButton = CreateFrame(
    "Button", "EverFishingAutoLureButton", UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate")
autoLureButton:SetSize(1, 1)
autoLureButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, -10)
autoLureButton:SetAlpha(0)
autoLureButton:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
autoLureButton:SetAttribute("useOnKeyDown", true)
autoLureButton:Show()

autoLureButton:SetAttribute("_onstate-efcombat", [[
    if newstate == "combat" then self:SetAttribute("type", nil) end
]])
if RegisterStateDriver then
    RegisterStateDriver(autoLureButton, "efcombat", "[combat] combat; safe")
end

local function CanStartFishing()
    return not fishingPaused and not lootOpen and not InCombatLockdown()
        and not UnitChannelInfo("player")
        and (not UnitCastingInfo or not UnitCastingInfo("player"))
        and GetUnitSpeed("player") == 0 and IsFishingPoleEquipped()
end

local function PrepareCastAction(button)
    local lureID = GetAutoLureID()
    button:SetAttribute("type", lureID and "item" or "spell")
    button:SetAttribute("item", lureID and ("item:" .. lureID) or nil)
    button:SetAttribute("target-slot", lureID and DATA.MAIN_HAND_SLOT or nil)
    button:SetAttribute("spell", not lureID and GetFishingSpellName() or nil)
end

autoLureButton:SetScript("PreClick", function(self)
    clickDiagnostics.securePreClicks = clickDiagnostics.securePreClicks + 1
    if InCombatLockdown() then return end
    if not CanStartFishing() or not IsMouseOverWorld() or UnitExists("mouseover") then
        clickDiagnostics.lastBlocker = "Secure click rejected: " .. GetMouseFishingStatus()
        self:SetAttribute("type", nil)
        ClearBinding()
    elseif self:GetAttribute("type") then
        clickDiagnostics.secureReadyClicks = clickDiagnostics.secureReadyClicks + 1
    end
end)
autoLureButton:SetScript("PostClick", function(self, _, down)
    clickDiagnostics.securePostClicks = clickDiagnostics.securePostClicks + 1
    local singleClick = EverFishingDB.castClickMode == "SingleClick"
    if (singleClick and not down) or (not singleClick and down) then
        ClearBinding()
    end
end)

local function SetFishingPaused(value)
    fishingPaused = not not value
    ClearBinding()
end

local GetMouseFishingStatus
GetMouseFishingStatus = function()
    if fishingPaused then return "Fishing is paused. Use /evf resume." end
    if InCombatLockdown() then return "Casting is blocked in combat." end
    if lootOpen then return "Casting is blocked while loot is open." end
    if not IsFishingPoleEquipped() then return "No fishing pole detected in the main hand." end
    if UnitChannelInfo("player") or UnitCastingInfo and UnitCastingInfo("player") then
        return "A spell is already being cast or channeled."
    end
    if GetUnitSpeed("player") > 0 then return "Stand still to cast." end
    if UnitExists("mouseover") then return "Move the cursor away from units to cast." end
    if not IsMouseOverWorld() then return "Move the cursor over the game world, not a UI control." end
    local lureID = GetAutoLureID()
    local button = GetButtonOption(EverFishingDB.doubleClickButton).label
    local clickPattern = EverFishingDB.castClickMode == "SingleClick" and "single-click " or "double-click "
    local ready = "Ready: " .. clickPattern .. button .. "."
    if lureID then return ready .. " Next action applies lure " .. lureID .. "." end
    return ready .. " Next action casts Fishing."
end

local function BindCastAction(buttonName)
    if not CanStartFishing() then return end
    local option = GetButtonOption(buttonName)
    PrepareCastAction(autoLureButton)
    autoLureButton:SetAttribute("useOnKeyDown", EverFishingDB.castClickMode ~= "SingleClick")

    SetOverrideBindingClick(
        castOwner, true, option.binding, autoLureButton:GetName(), "LeftButton")
    clickDiagnostics.bindingsArmed = clickDiagnostics.bindingsArmed + 1
    clickDiagnostics.lastBlocker = "Binding armed; waiting for the configured click."
end

function EF.InitializeClickHandling()
    if WorldFrame and type(WorldFrame.EnableMouseMotion) == "function" then
        WorldFrame:EnableMouseMotion(true)
    end
    local clickFrame = CreateFrame("Frame")
    clickFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
    clickFrame:RegisterEvent("GLOBAL_MOUSE_UP")
    clickFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    clickFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    clickFrame:RegisterEvent("LOOT_OPENED")
    clickFrame:RegisterEvent("LOOT_READY")
    clickFrame:RegisterEvent("LOOT_CLOSED")
    for _, event in ipairs({ "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING",
        "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED",
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        clickFrame:RegisterEvent(event)
    end
    clickFrame:SetScript("OnEvent", function(_, evt, buttonName)
        if evt == "LOOT_READY" or evt == "LOOT_OPENED" or evt == "LOOT_CLOSED" then
            lootOpen = evt ~= "LOOT_CLOSED"
            ClearBinding()
            
            -- Auto-Loot Logic
            if evt == "LOOT_OPENED" and EverFishingDB and EverFishingDB.enableAutoLoot then
                for i = 1, GetNumLootItems() do
                    LootSlot(i)
                end
                CloseLoot()
            end
            
            return
        end
        if evt == "PLAYER_REGEN_DISABLED" or evt == "PLAYER_REGEN_ENABLED" then
            ClearBinding()
            return
        end
        if evt ~= "GLOBAL_MOUSE_DOWN" and evt ~= "GLOBAL_MOUSE_UP" then
            if evt:find("^UNIT_") and buttonName ~= "player" then return end
            ClearBinding()
            return
        end

        if buttonName == EverFishingDB.doubleClickButton then
            if evt == "GLOBAL_MOUSE_DOWN" then
                clickDiagnostics.mouseDowns = clickDiagnostics.mouseDowns + 1
                clickDiagnostics.lastBlocker = GetMouseFishingStatus()
            else
                clickDiagnostics.mouseUps = clickDiagnostics.mouseUps + 1
            end
        end

        if evt == "GLOBAL_MOUSE_UP" then
            if clearBindingOnMouseUp then
                clearBindingOnMouseUp = false
                CancelPendingTimer()
                pendingClearTimer = C_Timer.NewTimer(0, ClearBinding)
                return
            end

            if buttonName ~= EverFishingDB.doubleClickButton or lastClickTime <= 0 then
                return
            end

            if GetTime() - lastClickTime > GetDoubleClickDelay()
                or lootOpen
                or fishingPaused
                or InCombatLockdown()
                or IsFishingChannelActive()
                or not IsFishingPoleEquipped()
                or not IsMouseOverWorld()
                or UnitExists("mouseover")
                or GetUnitSpeed("player") > 0 then
                ClearBinding()
                return
            end

            BindCastAction(buttonName)
            return
        end

        local selectedKey = EverFishingDB.doubleClickButton
        if buttonName ~= selectedKey then
            if lastClickTime > 0 then
                ClearBinding()
            end
            return
        end

        if lootOpen
            or fishingPaused
            or InCombatLockdown()
            or IsFishingChannelActive()
            or not IsFishingPoleEquipped()
            or not IsMouseOverWorld()
            or UnitExists("mouseover")
            or GetUnitSpeed("player") > 0 then
            if lastClickTime > 0 then
                ClearBinding()
            end
            return
        end

        local now = GetTime()
        local delta = now - lastClickTime
        if EverFishingDB.castClickMode == "SingleClick" then
            lastClickTime = 0
            CancelPendingTimer()
            BindCastAction(buttonName)
            clearBindingOnMouseUp = true
            return
        end

        if lastClickTime > 0 and delta >= MIN_DOUBLE_CLICK and delta <= GetDoubleClickDelay() then
            lastClickTime = 0
            CancelPendingTimer()
            clearBindingOnMouseUp = true
        else
            lastClickTime = now
            CancelPendingTimer()
            pendingClearTimer = C_Timer.NewTimer(GetDoubleClickDelay(), function()
                pendingClearTimer = nil
                clickDiagnostics.bindingsExpired = clickDiagnostics.bindingsExpired + 1
                clickDiagnostics.lastBlocker = "Double-click window expired before the second press."
                if not InCombatLockdown() then
                    ClearOverrideBindings(castOwner)
                end
                lastClickTime = 0
            end)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Options UI Panel
-- ---------------------------------------------------------------------------

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "EverFishingOptionsPanel")
    panel.name = "EverFishing"

    -- Set the total height of the panel so the scroll frame behaves correctly
    panel:SetHeight(600)

    -- 1. Main Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cffffd100EverFishing|r • General Options")

    -- 2. The Divider Rule
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15) 
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 16, -42)
    divider:SetPoint("TOPRIGHT", -16, -42)

    -- 3. Subtitle
    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -12)
    subtitle:SetText("Configure your fishing click-to-cast and automatic lures.")

    -- =======================================================================
    -- HELPER FUNCTIONS
    -- =======================================================================

    local function CreateHeader(parent, text, relativeTo, yOffset)
        local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetPoint("TOPLEFT", relativeTo, "BOTTOMLEFT", 4, yOffset)
        header:SetText(text)
        header:SetTextColor(1, 0.82, 0, 1)
        return header
    end

    local function CreateBox(parent, width, height, relativeTo, yOffset)
        local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        box:SetSize(width, height)
        box:SetPoint("TOPLEFT", relativeTo, "BOTTOMLEFT", 0, yOffset)
        
        box:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        box:SetBackdropColor(0, 0, 0, 0.5)
        box:SetBackdropBorderColor(1, 0.82, 0, 0.3)
        return box
    end

    local function CreateCheckbox(parent, text, getter, setter, xOffset, yOffset)
        local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
        cb.Text:SetFontObject(GameFontHighlight)
        cb.Text:SetText(text)
        
        cb:SetScript("OnShow", function(self) self:SetChecked(getter()) end)
        cb:SetScript("OnClick", function(self)
            setter(self:GetChecked())
            ClearBinding() 
        end)
        return cb
    end

    -- =======================================================================
    -- SECTION 1: Lure & Loot Options
    -- =======================================================================
    local lureHeader = CreateHeader(panel, "Lure & Loot Options", subtitle, -20)
    local lureBox = CreateBox(panel, 530, 115, lureHeader, -8)

    local autoLureCB = CreateCheckbox(
        lureBox, "Enable Auto Lure", 
        function() return EverFishingDB.enableAutoLure end,
        function(v) EverFishingDB.enableAutoLure = v end,
        12, -12
    )

    local autoLootCB = CreateCheckbox(
        lureBox, "Enable Auto-Loot", 
        function() return EverFishingDB.enableAutoLoot end,
        function(v) EverFishingDB.enableAutoLoot = v end,
        260, -12
    )

    -- Lure Strategy Dropdown
    local strategyLabel = lureBox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    strategyLabel:SetPoint("TOPLEFT", lureBox, "TOPLEFT", 16, -48)
    strategyLabel:SetText("Lure Strategy:")

    local strategyDropdown = CreateFrame("Frame", "EverFishingStrategyDropdown", lureBox, "UIDropDownMenuTemplate")
    strategyDropdown:SetPoint("TOPLEFT", strategyLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(strategyDropdown, 150)
    
    UIDropDownMenu_Initialize(strategyDropdown, function(self, level)
        local options = { 
            { text = "Smart (Save lures if maxed)", value = "Smart" }, 
            { text = "Weakest Lure First", value = "Weakest" },
            { text = "Strongest Lure First", value = "Strongest" }
        }
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.func = function()
                EverFishingDB.lureStrategy = opt.value
                UIDropDownMenu_SetSelectedValue(strategyDropdown, opt.value)
                UIDropDownMenu_SetText(strategyDropdown, opt.text)
                ClearBinding()
            end
            info.checked = (EverFishingDB.lureStrategy == opt.value)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetSelectedValue(strategyDropdown, EverFishingDB.lureStrategy)
    
    local initialText = "Smart (Save lures if maxed)"
    if EverFishingDB.lureStrategy == "Weakest" then initialText = "Weakest Lure First"
    elseif EverFishingDB.lureStrategy == "Strongest" then initialText = "Strongest Lure First" end
    UIDropDownMenu_SetText(strategyDropdown, initialText)

    -- =======================================================================
    -- SECTION 2: Click-to-Cast Settings (Nested Layout)
    -- =======================================================================
    local castHeader = CreateHeader(panel, "Click-to-Cast Settings", lureBox, -20)
    local castOuterBox = CreateBox(panel, 530, 235, castHeader, -8)

    local mouseSub = castOuterBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    mouseSub:SetPoint("TOPLEFT", castOuterBox, "TOPLEFT", 12, -10)
    mouseSub:SetText("Mouse Configuration")
    mouseSub:SetTextColor(1, 0.82, 0, 1)

    local mouseInnerBox = CreateBox(castOuterBox, 480, 65, mouseSub, -8)

    local modeLabel = mouseInnerBox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    modeLabel:SetPoint("TOPLEFT", mouseInnerBox, "TOPLEFT", 20, -10)
    modeLabel:SetText("Cast Click Mode:")

    local modeDropdown = CreateFrame("Frame", "EverFishingModeDropdown", mouseInnerBox, "UIDropDownMenuTemplate")
    modeDropdown:SetPoint("TOPLEFT", modeLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(modeDropdown, 130)
    
    UIDropDownMenu_Initialize(modeDropdown, function(self, level)
        local options = { { text = "Single Click", value = "SingleClick" }, { text = "Double Click", value = "DoubleClick" } }
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.func = function()
                EverFishingDB.castClickMode = opt.value
                UIDropDownMenu_SetSelectedValue(modeDropdown, opt.value)
                UIDropDownMenu_SetText(modeDropdown, opt.text)
                ClearBinding()
            end
            info.checked = (EverFishingDB.castClickMode == opt.value)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetSelectedValue(modeDropdown, EverFishingDB.castClickMode)
    UIDropDownMenu_SetText(modeDropdown, EverFishingDB.castClickMode == "SingleClick" and "Single Click" or "Double Click")

    local buttonLabel = mouseInnerBox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    buttonLabel:SetPoint("TOPLEFT", modeLabel, "TOPLEFT", 230, 0)
    buttonLabel:SetText("Cast Mouse Button:")

    local buttonDropdown = CreateFrame("Frame", "EverFishingButtonDropdown", mouseInnerBox, "UIDropDownMenuTemplate")
    buttonDropdown:SetPoint("TOPLEFT", buttonLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(buttonDropdown, 130)
    
    UIDropDownMenu_Initialize(buttonDropdown, function(self, level)
        for _, opt in ipairs(BUTTON_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.func = function()
                EverFishingDB.doubleClickButton = opt.key
                UIDropDownMenu_SetSelectedValue(buttonDropdown, opt.key)
                UIDropDownMenu_SetText(buttonDropdown, opt.label)
                ClearBinding()
            end
            info.checked = (EverFishingDB.doubleClickButton == opt.key)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetSelectedValue(buttonDropdown, EverFishingDB.doubleClickButton)
    UIDropDownMenu_SetText(buttonDropdown, GetButtonOption(EverFishingDB.doubleClickButton).label)

    local timingSub = castOuterBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    timingSub:SetPoint("TOPLEFT", mouseInnerBox, "BOTTOMLEFT", 12, -15)
    timingSub:SetText("Timing Settings")
    timingSub:SetTextColor(1, 0.82, 0, 1)

    local timingInnerBox = CreateBox(castOuterBox, 480, 75, timingSub, -8)

    local delaySlider = CreateFrame("Slider", "EverFishingDelaySlider", timingInnerBox, "OptionsSliderTemplate")
    delaySlider:SetPoint("TOPLEFT", timingInnerBox, "TOPLEFT", 30, -30)
    delaySlider:SetWidth(250)
    delaySlider:SetMinMaxValues(0.1, 0.8)
    delaySlider:SetValueStep(0.05)
    delaySlider:SetObeyStepOnDrag(true)
    
    _G[delaySlider:GetName() .. "Low"]:SetText("0.1s")
    _G[delaySlider:GetName() .. "High"]:SetText("0.8s")
    
    local sliderLabel = timingInnerBox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sliderLabel:SetPoint("BOTTOMLEFT", delaySlider, "TOPLEFT", 4, 6)
    sliderLabel:SetText("Double-Click Window")
    
    delaySlider:SetScript("OnShow", function(self)
        self:SetValue(EverFishingDB.doubleClickDelay or 0.4)
    end)
    
    delaySlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor((value + 0.025) * 20 + 0.5) / 20
        EverFishingDB.doubleClickDelay = value
        sliderLabel:SetText(string.format("Double-Click Window: |cffffffff%.2fs|r", value))
        ClearBinding()
    end)

    -- =======================================================================
    -- SECTION 3: About
    -- =======================================================================
    local aboutHeader = CreateHeader(panel, "About", castOuterBox, -20)
    local aboutBox = CreateBox(panel, 530, 65, aboutHeader, -8)
    
    local versionText = aboutBox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    versionText:SetPoint("TOPLEFT", aboutBox, "TOPLEFT", 12, -12)
    versionText:SetText("EverFishing Version 0.1.0")
    
    local slashText = aboutBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    slashText:SetPoint("TOPLEFT", versionText, "BOTTOMLEFT", 0, -6)
    slashText:SetText("Type |cffFFFF00/evf|r in chat to see all commands.")

    -- Register the panel with the game's Settings API
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    
    SLASH_EVERFISHINGOPTIONS1 = "/evf options"
    SlashCmdList["EVERFISHINGOPTIONS"] = function()
        Settings.OpenToCategory(category:GetID())
    end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function LureStatusLine()
    local available = GetAvailableLures()
    local total = 0
    for _, lure in ipairs(available) do total = total + lure.count end
    local hasEnchant = GetWeaponEnchantInfo()
    local enchantText = hasEnchant and "active" or "none"
    return string.format("pole enchant: %s  |  eligible lures in bags: %d", enchantText, total)
end

SLASH_EVERFISHING1 = "/evf"
SLASH_EVERFISHING2 = "/everfishing"
SlashCmdList.EVERFISHING = function(message)
    local cmd, rest = message:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):lower()

    if cmd == "" or cmd == "status" then
        print("EverFishing: " .. GetMouseFishingStatus())
        print(string.format("EverFishing: button=%s  mode=%s  delay=%.2fs  autoLure=%s  strategy=%s  autoLoot=%s",
            GetButtonOption(EverFishingDB.doubleClickButton).label,
            EverFishingDB.castClickMode,
            GetDoubleClickDelay(),
            tostring(EverFishingDB.enableAutoLure),
            tostring(EverFishingDB.lureStrategy),
            tostring(EverFishingDB.enableAutoLoot)))
        print("EverFishing: " .. LureStatusLine())
    elseif cmd == "button" then
        for _, opt in ipairs(BUTTON_OPTIONS) do
            if rest == opt.key:lower() or rest == opt.label:lower()
                or (opt.key == "LeftButton" and rest == "left")
                or (opt.key == "RightButton" and rest == "right")
                or (opt.key == "MiddleButton" and rest == "middle") then
                EverFishingDB.doubleClickButton = opt.key
                ClearBinding()
                print("EverFishing: cast button set to " .. opt.label)
                return
            end
        end
        print("EverFishing: usage /evf button left|right|middle|4|5")
    elseif cmd == "delay" then
        local value = tonumber(rest)
        if value then
            value = math.max(0.1, math.min(0.8, value))
            EverFishingDB.doubleClickDelay = value
            ClearBinding()
            print(string.format("EverFishing: double-click delay set to %.2fs", value))
        else
            print("EverFishing: usage /evf delay <0.1-0.8>")
        end
    elseif cmd == "mode" then
        if rest == "single" or rest == "singleclick" then
            EverFishingDB.castClickMode = "SingleClick"
            ClearBinding()
            print("EverFishing: single click mode")
        elseif rest == "double" or rest == "doubleclick" then
            EverFishingDB.castClickMode = "DoubleClick"
            ClearBinding()
            print("EverFishing: double click mode")
        else
            print("EverFishing: usage /evf mode single|double")
        end
    elseif cmd == "lure" then
        if rest == "on" then EverFishingDB.enableAutoLure = true
        elseif rest == "off" then EverFishingDB.enableAutoLure = false
        else print("EverFishing: usage /evf lure on|off"); return end
        ClearBinding()
        print("EverFishing: auto lure " .. rest)
    elseif cmd == "strategy" then
        if rest == "smart" then EverFishingDB.lureStrategy = "Smart"
        elseif rest == "weakest" or rest == "weak" then EverFishingDB.lureStrategy = "Weakest"
        elseif rest == "strongest" or rest == "strong" then EverFishingDB.lureStrategy = "Strongest"
        else print("EverFishing: usage /evf strategy smart|weakest|strongest"); return end
        ClearBinding()
        print("EverFishing: lure strategy set to " .. EverFishingDB.lureStrategy)
    elseif cmd == "loot" then
        if rest == "on" then EverFishingDB.enableAutoLoot = true
        elseif rest == "off" then EverFishingDB.enableAutoLoot = false
        else print("EverFishing: usage /evf loot on|off"); return end
        ClearBinding()
        print("EverFishing: auto-loot " .. rest)
    elseif cmd == "pause" then
        SetFishingPaused(true)
        print("EverFishing: paused")
    elseif cmd == "resume" then
        SetFishingPaused(false)
        print("EverFishing: resumed")
    else
        print("EverFishing commands:")
        print("  /evf status                        - show current settings and readiness")
        print("  /evf button <left|right|middle|4|5> - set cast mouse button")
        print("  /evf mode <single|double>          - set click pattern")
        print("  /evf delay <0.1-0.8>               - set double-click window")
        print("  /evf lure <on|off>                 - toggle automatic lure application")
        print("  /evf strategy <smart|weakest|strongest> - set lure strategy")
        print("  /evf loot <on|off>                 - toggle automatic looting")
        print("  /evf pause | /evf resume           - pause/resume casting")
    end
end

-- ---------------------------------------------------------------------------
-- Initialization
-- ---------------------------------------------------------------------------

local mainFrame = CreateFrame("Frame")
mainFrame:RegisterEvent("PLAYER_LOGIN")
mainFrame:SetScript("OnEvent", function()
    InitializeSettings()
    CreateOptionsPanel()
    EF.InitializeClickHandling()
end)