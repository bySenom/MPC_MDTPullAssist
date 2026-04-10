-- MPC_MDTPullAssist - Options
-- Standalone settings panel with dark theme.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local Options = {}
PA.Options = Options

local optionsFrame = nil

-- UI helpers (matching MPC's options style)
local C = {
    bg         = { 0.08, 0.08, 0.10, 0.95 },
    bgCard     = { 0.12, 0.12, 0.14, 1.0 },
    border     = { 0.25, 0.25, 0.30, 1.0 },
    accent     = { 0.30, 0.70, 1.00, 1.0 },
    textNormal = { 0.85, 0.85, 0.85, 1.0 },
    textBright = { 1.00, 1.00, 1.00, 1.0 },
    textDim    = { 0.55, 0.55, 0.60, 1.0 },
    green      = { 0.30, 0.85, 0.40, 1.0 },
    red        = { 0.90, 0.35, 0.35, 1.0 },
}

local function CreateCheckbox(parent, label, xOff, yOff, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", xOff, yOff)
    cb:SetSize(24, 24)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked())
    end)

    local text = cb:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    text:SetTextColor(unpack(C.textNormal))
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)

    return cb, text
end

local function CreateSlider(parent, label, xOff, yOff, minVal, maxVal, step, getter, setter)
    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", xOff, yOff)
    slider:SetSize(180, 16)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(getter())

    if slider.Text then slider.Text:SetText(label) end
    if slider.Low then slider.Low:SetText(tostring(minVal)) end
    if slider.High then slider.High:SetText(tostring(maxVal)) end

    local valueText = slider:CreateFontString(nil, "OVERLAY")
    valueText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    valueText:SetTextColor(unpack(C.textBright))
    valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    valueText:SetText(string.format("%.0f%%", getter() * 100))

    slider:SetScript("OnValueChanged", function(self, value)
        setter(value)
        valueText:SetText(string.format("%.0f%%", value * 100))
    end)

    return slider
end

local function CreateButton(parent, label, xOff, yOff, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetPoint("TOPLEFT", xOff, yOff)
    btn:SetSize(width, 22)
    btn:SetText(label)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function CreateSectionHeader(parent, text, yOff)
    local header = parent:CreateFontString(nil, "OVERLAY")
    header:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    header:SetTextColor(unpack(C.accent))
    header:SetPoint("TOPLEFT", 12, yOff)
    header:SetText(text)

    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
    line:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    line:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)

    return header
end

function Options:Toggle()
    if optionsFrame and optionsFrame:IsShown() then
        optionsFrame:Hide()
    else
        self:Show()
    end
end

function Options:Show()
    if not optionsFrame then
        self:CreatePanel()
    end
    self:RefreshStatus()
    optionsFrame:Show()
end

function Options:CreatePanel()
    local settings = PA:GetSettings()

    optionsFrame = CreateFrame("Frame", "MPCPullAssistOptions", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(340, 830)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:SetClampedToScreen(true)

    optionsFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    optionsFrame:SetBackdropColor(unpack(C.bg))
    optionsFrame:SetBackdropBorderColor(unpack(C.border))

    -- Title bar
    local titleBg = optionsFrame:CreateTexture(nil, "ARTWORK")
    titleBg:SetPoint("TOPLEFT", 1, -1)
    titleBg:SetPoint("TOPRIGHT", -1, -1)
    titleBg:SetHeight(24)
    titleBg:SetColorTexture(0.10, 0.10, 0.14, 1.0)

    local title = optionsFrame:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    title:SetTextColor(unpack(C.accent))
    title:SetPoint("TOPLEFT", 10, -5)
    title:SetText("MDT Pull Assist - Settings")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -1)
    closeBtn:SetSize(20, 20)

    -- Escape to close
    tinsert(UISpecialFrames, "MPCPullAssistOptions")

    -- Content area
    local content = CreateFrame("Frame", nil, optionsFrame)
    content:SetPoint("TOPLEFT", 0, -30)
    content:SetPoint("BOTTOMRIGHT", 0, 0)

    local yOff = -10

    -- Display section
    CreateSectionHeader(content, "Display", yOff)
    yOff = yOff - 30

    CreateCheckbox(content, "Show forces count", 16, yOff,
        function() return settings.showCount ~= false end,
        function(v) settings.showCount = v; PA.Display:Update() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Show forces percent", 16, yOff,
        function() return settings.showPercent ~= false end,
        function(v) settings.showPercent = v; PA.Display:Update() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Show outside Mythic+", 16, yOff,
        function() return settings.showOutsideMPlus == true end,
        function(v) settings.showOutsideMPlus = v; PA.Display:UpdateVisibility() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Use MDT pull colors", 16, yOff,
        function() return settings.usePullColors ~= false end,
        function(v) settings.usePullColors = v; PA.Display:Update() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Show pull notes from MDT", 16, yOff,
        function() return settings.showPullNotes ~= false end,
        function(v) settings.showPullNotes = v; PA.Display:Update() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Show next pull on nameplates", 16, yOff,
        function() return settings.showNextPull == true end,
        function(v) settings.showNextPull = v; PA.Nameplates:RefreshAll() end)
    yOff = yOff - 36

    -- Nameplates section
    CreateSectionHeader(content, "Nameplates", yOff)
    yOff = yOff - 30

    CreateCheckbox(content, "Show pull number on nameplates", 16, yOff,
        function() return settings.nameplatesEnabled ~= false end,
        function(v) settings.nameplatesEnabled = v; PA.Nameplates:RefreshAll() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Show forces count on nameplates", 16, yOff,
        function() return settings.nameplateShowForces ~= false end,
        function(v) settings.nameplateShowForces = v; PA.Nameplates:RefreshAll() end)
    yOff = yOff - 26

    CreateCheckbox(content, "Current pull only (hide future pulls)", 16, yOff,
        function() return settings.nameplatesCurrentOnly == true end,
        function(v) settings.nameplatesCurrentOnly = v; PA.Nameplates:RefreshAll() end)
    yOff = yOff - 36

    -- Tracking section
    CreateSectionHeader(content, "Tracking", yOff)
    yOff = yOff - 30

    CreateSlider(content, "Completion Threshold", 16, yOff, 0.5, 1.0, 0.05,
        function() return PA.Tracker:GetThreshold() end,
        function(v) PA.Tracker:SetThreshold(v); settings.threshold = v end)
    yOff = yOff - 50

    -- Alerts section
    CreateSectionHeader(content, "Alerts", yOff)
    yOff = yOff - 30

    CreateCheckbox(content, "Warn on off-route pulls", 16, yOff,
        function() return settings.warnOffRoute ~= false end,
        function(v) settings.warnOffRoute = v end)
    yOff = yOff - 26

    -- Warning sound dropdown (built-in + SharedMedia)
    local soundLabel = content:CreateFontString(nil, "OVERLAY")
    soundLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    soundLabel:SetTextColor(unpack(C.textNormal))
    soundLabel:SetPoint("TOPLEFT", 42, yOff)
    soundLabel:SetText("Warning sound:")

    local BUILTIN_SOUNDS = {
        { name = "RaidWarning", id = 8959 },
        { name = "ReadyCheck",  id = 8960 },
        { name = "FlagTaken",   id = 8174 },
        { name = "LevelUp",     id = 888 },
        { name = "None",        id = nil },
    }

    local dropName = "MDTPAWarnSoundDropdown"
    local dropdown = CreateFrame("Frame", dropName, content, "UIDropDownMenuTemplate")
    dropdown:SetPoint("LEFT", soundLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(dropdown, 140)

    local function GetSoundChoices()
        local list = {}
        for _, s in ipairs(BUILTIN_SOUNDS) do
            table.insert(list, { name = s.name, id = s.id, path = nil })
        end
        -- Add SharedMedia sounds if available
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        if LSM then
            local mediaList = LSM:List("sound")
            if mediaList then
                for _, sndName in ipairs(mediaList) do
                    local path = LSM:Fetch("sound", sndName)
                    if path then
                        table.insert(list, { name = "SM: " .. sndName, id = nil, path = path })
                    end
                end
            end
        end
        return list
    end

    local function PreviewSound(entry)
        if entry.id then
            PlaySound(entry.id, "Master")
        elseif entry.path then
            PlaySoundFile(entry.path, "Master")
        end
    end

    local function InitDropdown(self, level, menuList)
        local choices = GetSoundChoices()
        local cur = settings.warnSound or "RaidWarning"
        for _, entry in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.name
            info.checked = (cur == entry.name)
            info.func = function()
                settings.warnSound = entry.name
                settings.warnSoundPath = entry.path
                settings.warnSoundID = entry.id
                UIDropDownMenu_SetText(dropdown, entry.name)
                CloseDropDownMenus()
                PreviewSound(entry)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(dropdown, InitDropdown)
    UIDropDownMenu_SetText(dropdown, settings.warnSound or "RaidWarning")
    yOff = yOff - 34

    -- Preview Warning + Unlock Warning Position buttons
    CreateButton(content, "Preview Warning", 42, yOff, 130, function()
        PA.Display:ShowOffRouteWarning("Test Mob")
    end)

    CreateButton(content, "Unlock Warning Pos.", 182, yOff, 140, function()
        PA.Display:ToggleWarningUnlock()
    end)
    yOff = yOff - 30

    -- Pull completion sound
    CreateCheckbox(content, "Play sound on pull complete", 16, yOff,
        function() return settings.pullCompleteSound ~= false end,
        function(v) settings.pullCompleteSound = v end)
    yOff = yOff - 26

    local pcSoundLabel = content:CreateFontString(nil, "OVERLAY")
    pcSoundLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    pcSoundLabel:SetTextColor(unpack(C.textNormal))
    pcSoundLabel:SetPoint("TOPLEFT", 42, yOff)
    pcSoundLabel:SetText("Complete sound:")

    local BUILTIN_PC_SOUNDS = {
        { name = "MapPing",       id = 3175 },
        { name = "QuestComplete", id = 878 },
        { name = "LevelUp",      id = 888 },
        { name = "ReadyCheck",    id = 8960 },
        { name = "None",          id = nil },
    }

    local pcDropName = "MDTPAPullCompleteSoundDropdown"
    local pcDropdown = CreateFrame("Frame", pcDropName, content, "UIDropDownMenuTemplate")
    pcDropdown:SetPoint("LEFT", pcSoundLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(pcDropdown, 130)

    local function GetPCSoundChoices()
        local list = {}
        for _, s in ipairs(BUILTIN_PC_SOUNDS) do
            table.insert(list, { name = s.name, id = s.id, path = nil })
        end
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        if LSM then
            local mediaList = LSM:List("sound")
            if mediaList then
                for _, sndName in ipairs(mediaList) do
                    local path = LSM:Fetch("sound", sndName)
                    if path then
                        table.insert(list, { name = "SM: " .. sndName, id = nil, path = path })
                    end
                end
            end
        end
        return list
    end

    local function InitPCDropdown(self, level, menuList)
        local choices = GetPCSoundChoices()
        local cur = settings.pullCompleteSoundChoice or "MapPing"
        for _, entry in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.name
            info.checked = (cur == entry.name)
            info.func = function()
                settings.pullCompleteSoundChoice = entry.name
                settings.pullCompleteSoundPath = entry.path
                settings.pullCompleteSoundID = entry.id
                UIDropDownMenu_SetText(pcDropdown, entry.name)
                CloseDropDownMenus()
                if entry.id then PlaySound(entry.id, "Master")
                elseif entry.path then PlaySoundFile(entry.path, "Master") end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(pcDropdown, InitPCDropdown)
    UIDropDownMenu_SetText(pcDropdown, settings.pullCompleteSoundChoice or "MapPing")
    yOff = yOff - 34

    CreateCheckbox(content, "Enable party sync", 16, yOff,
        function() return settings.partySyncEnabled ~= false end,
        function(v) settings.partySyncEnabled = v end)
    yOff = yOff - 26

    CreateCheckbox(content, "Hide minimap icon", 16, yOff,
        function() return settings.minimap and settings.minimap.hide or false end,
        function(v)
            if not settings.minimap then settings.minimap = {} end
            settings.minimap.hide = v
            if LibStub and LibStub("LibDBIcon-1.0", true) then
                local icon = LibStub("LibDBIcon-1.0")
                if v then icon:Hide("MDTPullAssist") else icon:Show("MDTPullAssist") end
            end
        end)
    yOff = yOff - 36

    -- Actions section
    CreateSectionHeader(content, "Actions", yOff)
    yOff = yOff - 30

    CreateButton(content, "Reload Route", 16, yOff, 140, function()
        PA:ReloadRoute()
        self:RefreshStatus()
    end)

    CreateButton(content, "Reset Tracking", 170, yOff, 140, function()
        PA.Tracker:Reset()
        PA.Display:Update()
        self:RefreshStatus()
    end)
    yOff = yOff - 34

    CreateButton(content, "Show Frame", 16, yOff, 140, function()
        PA.Display:SetShown(true)
    end)

    CreateButton(content, "Hide Frame", 170, yOff, 140, function()
        PA.Display:SetShown(false)
    end)
    yOff = yOff - 40

    -- Status section
    CreateSectionHeader(content, "Status", yOff)
    yOff = yOff - 26

    optionsFrame.statusText = content:CreateFontString(nil, "OVERLAY")
    optionsFrame.statusText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    optionsFrame.statusText:SetTextColor(unpack(C.textNormal))
    optionsFrame.statusText:SetPoint("TOPLEFT", 16, yOff)
    optionsFrame.statusText:SetWidth(300)
    optionsFrame.statusText:SetJustifyH("LEFT")
end

function Options:RefreshStatus()
    if not optionsFrame or not optionsFrame.statusText then return end
    local plan = PA.RouteReader:GetPlan()
    if plan then
        local pullIdx = PA.Tracker:GetCurrentPullIndex()
        optionsFrame.statusText:SetText(string.format(
            "Route: %s\nPulls: %d | Current: #%d | Completed: %d\nTotal Forces: %d",
            plan.routeName, #plan.pulls, pullIdx,
            PA.Tracker:GetCompletedPullCount(), plan.totalForces))
    else
        optionsFrame.statusText:SetText("No route loaded.\nEnter a M+ dungeon with an MDT route selected.")
    end
end
