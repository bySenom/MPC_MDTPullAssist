-- MPC_MDTPullAssist - Display
-- Movable/lockable frame showing the next pull from the MDT route.
-- Follows MPC's lock/unlock pattern and visual style.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local Display = {}
PA.Display = Display

local mainFrame = nil
local headerText = nil
local routeText = nil
local mobLines = {}         -- reusable FontString pool
local progressText = nil
local noRouteText = nil
local flashAnim = nil
local unlockGlow = nil

local MAX_MOB_LINES = 12
local FRAME_WIDTH = 220
local FRAME_MIN_HEIGHT = 60
local LINE_HEIGHT = 14
local HEADER_HEIGHT = 20
local PADDING = 8

-- Dark theme colors matching MPC options panel
local C = {
    bg         = { 0.06, 0.06, 0.08, 0.88 },
    border     = { 0.25, 0.25, 0.30, 0.9 },
    accent     = { 0.30, 0.70, 1.00, 1.0 },
    textNormal = { 0.85, 0.85, 0.85, 1.0 },
    textBright = { 1.00, 1.00, 1.00, 1.0 },
    textDim    = { 0.55, 0.55, 0.60, 1.0 },
    green      = { 0.30, 0.85, 0.40, 1.0 },
    yellow     = { 1.00, 0.82, 0.00, 1.0 },
    headerBg   = { 0.10, 0.10, 0.14, 1.0 },
    complete   = { 0.20, 0.65, 0.20, 1.0 },
}

function Display:Init()
    if mainFrame then return end
    self:CreateFrame()
    self:RestorePosition()
    self:UpdateVisibility()
end

function Display:CreateFrame()
    mainFrame = CreateFrame("Frame", "MPCPullAssistFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, FRAME_MIN_HEIGHT)
    mainFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -300)
    mainFrame:SetFrameStrata("MEDIUM")
    mainFrame:SetFrameLevel(50)
    mainFrame:SetClampedToScreen(true)

    mainFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    mainFrame:SetBackdropColor(unpack(C.bg))
    mainFrame:SetBackdropBorderColor(unpack(C.border))

    -- Movable
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(f)
        if not self:IsLocked() then f:StartMoving() end
    end)
    mainFrame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        self:SavePosition()
    end)

    -- Unlock glow
    unlockGlow = mainFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    unlockGlow:SetAllPoints()
    unlockGlow:SetColorTexture(0.2, 0.8, 1.0, 0.25)
    unlockGlow:Hide()

    -- Header background
    local headerBg = mainFrame:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", 1, -1)
    headerBg:SetPoint("TOPRIGHT", -1, -1)
    headerBg:SetHeight(HEADER_HEIGHT)
    headerBg:SetColorTexture(unpack(C.headerBg))

    -- Header: "Pull #N"
    headerText = mainFrame:CreateFontString(nil, "OVERLAY")
    headerText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    headerText:SetTextColor(unpack(C.accent))
    headerText:SetPoint("TOPLEFT", PADDING, -(PADDING / 2))
    headerText:SetText("Pull #1")

    -- Progress on right side of header
    progressText = mainFrame:CreateFontString(nil, "OVERLAY")
    progressText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    progressText:SetTextColor(unpack(C.textDim))
    progressText:SetPoint("TOPRIGHT", -PADDING, -(PADDING / 2 + 1))
    progressText:SetText("")

    -- Route name (small, below header)
    routeText = mainFrame:CreateFontString(nil, "OVERLAY")
    routeText:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
    routeText:SetTextColor(unpack(C.textDim))
    routeText:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + 2))
    routeText:SetText("")

    -- "No route loaded" text
    noRouteText = mainFrame:CreateFontString(nil, "OVERLAY")
    noRouteText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    noRouteText:SetTextColor(unpack(C.textDim))
    noRouteText:SetPoint("CENTER", 0, 0)
    noRouteText:SetText("No MDT route loaded")
    noRouteText:Hide()

    -- Pre-create mob line FontStrings
    for i = 1, MAX_MOB_LINES do
        local line = {}

        line.name = mainFrame:CreateFontString(nil, "OVERLAY")
        line.name:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        line.name:SetTextColor(unpack(C.textNormal))
        line.name:SetJustifyH("LEFT")
        line.name:SetWordWrap(false)

        line.forces = mainFrame:CreateFontString(nil, "OVERLAY")
        line.forces:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        line.forces:SetTextColor(unpack(C.green))
        line.forces:SetJustifyH("RIGHT")

        mobLines[i] = line
    end

    -- Flash animation group for pull transitions
    local flashTex = mainFrame:CreateTexture(nil, "OVERLAY")
    flashTex:SetAllPoints()
    flashTex:SetColorTexture(0.3, 0.7, 1.0, 0)
    flashAnim = flashTex:CreateAnimationGroup()

    local fadeIn = flashAnim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(0.3)
    fadeIn:SetDuration(0.15)
    fadeIn:SetOrder(1)

    local fadeOut = flashAnim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(0.3)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.35)
    fadeOut:SetOrder(2)

    -- Right-click menu
    mainFrame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            self:ShowContextMenu()
        end
    end)
end

function Display:ShowContextMenu()
    local menu = {
        { text = "MDT Pull Assist", isTitle = true, notCheckable = true },
        { text = "Reload Route", notCheckable = true, func = function()
            PA:ReloadRoute()
        end },
        { text = "Reset Tracking", notCheckable = true, func = function()
            PA.Tracker:Reset()
            self:Update()
        end },
        { text = "---", notCheckable = true },
        { text = "Next Pull", notCheckable = true, func = function()
            local idx = PA.Tracker:GetCurrentPullIndex()
            PA.Tracker:SetCurrentPull(idx + 1)
        end },
        { text = "Previous Pull", notCheckable = true, func = function()
            local idx = PA.Tracker:GetCurrentPullIndex()
            if idx > 1 then PA.Tracker:SetCurrentPull(idx - 1) end
        end },
        { text = "---", notCheckable = true },
        { text = "Hide", notCheckable = true, func = function()
            self:SetShown(false)
        end },
    }

    -- Use EasyMenu or fallback
    if not _G.MPCPullAssistDropdown then
        _G.MPCPullAssistDropdown = CreateFrame("Frame", "MPCPullAssistDropdown", UIParent, "UIDropDownMenuTemplate")
    end
    EasyMenu(menu, _G.MPCPullAssistDropdown, "cursor", 0, 0, "MENU")
end

-- Update the display with current pull data
function Display:Update()
    if not mainFrame then return end

    local plan = PA.RouteReader:GetPlan()
    if not plan or #plan.pulls == 0 then
        self:ShowNoRoute()
        return
    end

    noRouteText:Hide()

    local pullIdx = PA.Tracker:GetCurrentPullIndex()
    local pull = plan.pulls[pullIdx]

    if not pull then
        -- All pulls done
        headerText:SetText("|cFF44FF44Route Complete!|r")
        progressText:SetText(string.format("%d/%d", #plan.pulls, #plan.pulls))
        routeText:SetText(plan.routeName)
        self:HideAllMobLines()
        self:ResizeFrame(0)
        return
    end

    -- Header
    headerText:SetText(string.format("Next Pull |cFFFFFFFF#%d|r", pullIdx))
    progressText:SetText(string.format("%d/%d", pullIdx - 1, #plan.pulls))
    routeText:SetText(plan.routeName)

    -- Mob lines
    local settings = PA:GetSettings()
    local showCount = settings.showCount ~= false
    local showPercent = settings.showPercent ~= false
    local lineCount = 0

    for i, mob in ipairs(pull.mobs) do
        if i > MAX_MOB_LINES then break end
        lineCount = i
        local line = mobLines[i]

        -- Name with quantity prefix
        local nameStr
        if mob.quantity > 1 then
            nameStr = string.format("|cFFCCCCCC%d×|r %s", mob.quantity, mob.name)
        else
            nameStr = mob.name
        end
        line.name:SetText(nameStr)

        -- Forces display
        local forcesStr = ""
        local totalMobForces = mob.count * mob.quantity
        if showCount and showPercent then
            local pct = (totalMobForces / plan.totalForces) * 100
            forcesStr = string.format("%d (%.1f%%)", totalMobForces, pct)
        elseif showCount then
            forcesStr = tostring(totalMobForces)
        elseif showPercent then
            local pct = (totalMobForces / plan.totalForces) * 100
            forcesStr = string.format("%.1f%%", pct)
        end

        if mob.isBoss then
            line.forces:SetTextColor(1.0, 0.82, 0.0, 1.0)  -- gold for bosses
            if totalMobForces == 0 then forcesStr = "BOSS" end
        else
            line.forces:SetTextColor(unpack(C.green))
        end
        line.forces:SetText(forcesStr)

        -- Position
        local yOff = -(HEADER_HEIGHT + 14 + (i - 1) * LINE_HEIGHT)
        line.name:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, yOff)
        line.name:SetPoint("RIGHT", line.forces, "LEFT", -4, 0)
        line.forces:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, yOff)

        line.name:Show()
        line.forces:Show()
    end

    -- Hide unused lines
    for i = lineCount + 1, MAX_MOB_LINES do
        mobLines[i].name:Hide()
        mobLines[i].forces:Hide()
    end

    -- Pull total summary line
    local summaryIdx = lineCount + 1
    if summaryIdx <= MAX_MOB_LINES then
        local line = mobLines[summaryIdx]
        local yOff = -(HEADER_HEIGHT + 14 + lineCount * LINE_HEIGHT + 4)
        line.name:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, yOff)
        line.name:SetPoint("RIGHT", line.forces, "LEFT", -4, 0)
        line.forces:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, yOff)

        line.name:SetText("|cFF888888Pull Total:|r")
        line.name:SetTextColor(unpack(C.textDim))

        local totalStr = ""
        if showCount and showPercent then
            totalStr = string.format("|cFFFFFFFF%d|r (|cFF66CCFF%.1f%%|r) → cum. |cFF66CCFF%.1f%%|r",
                pull.totalForces, pull.totalPercent, pull.cumPercent)
        elseif showCount then
            totalStr = string.format("|cFFFFFFFF%d|r → cum. %d", pull.totalForces, pull.cumForces)
        else
            totalStr = string.format("|cFF66CCFF%.1f%%|r → cum. |cFF66CCFF%.1f%%|r", pull.totalPercent, pull.cumPercent)
        end
        line.forces:SetText(totalStr)
        line.forces:SetTextColor(unpack(C.textNormal))
        line.name:Show()
        line.forces:Show()
        lineCount = lineCount + 1
    end

    -- Hide rest
    for i = lineCount + 1, MAX_MOB_LINES do
        mobLines[i].name:Hide()
        mobLines[i].forces:Hide()
    end

    self:ResizeFrame(lineCount)
end

function Display:ShowNoRoute()
    noRouteText:Show()
    headerText:SetText("MDT Pull Assist")
    progressText:SetText("")
    routeText:SetText("")
    self:HideAllMobLines()
    self:ResizeFrame(0)
end

function Display:HideAllMobLines()
    for i = 1, MAX_MOB_LINES do
        mobLines[i].name:Hide()
        mobLines[i].forces:Hide()
    end
end

function Display:ResizeFrame(lineCount)
    if not mainFrame then return end
    local height = HEADER_HEIGHT + 14 + math.max(lineCount, 1) * LINE_HEIGHT + PADDING + 4
    height = math.max(height, FRAME_MIN_HEIGHT)
    mainFrame:SetHeight(height)
end

-- Pull transition callbacks
function Display:OnPullAdvanced(newIdx)
    if flashAnim then flashAnim:Play() end
    self:Update()
end

function Display:OnAllPullsComplete()
    self:Update()
end

-- Visibility
function Display:SetShown(shown)
    if not mainFrame then return end
    local settings = PA:GetSettings()
    settings.shown = shown
    if shown then
        mainFrame:Show()
    else
        mainFrame:Hide()
    end
end

function Display:UpdateVisibility()
    if not mainFrame then return end
    local settings = PA:GetSettings()
    if settings.shown == false then
        mainFrame:Hide()
        return
    end

    local inMPlus = PA:IsInMythicPlus()
    local debugMode = PA:IsDebugMode()
    if not inMPlus and not debugMode and not settings.showOutsideMPlus then
        mainFrame:Hide()
        return
    end

    mainFrame:Show()
end

function Display:IsLocked()
    local settings = PA:GetSettings()
    return settings.locked ~= false
end

function Display:UpdateLock()
    if not mainFrame or not unlockGlow then return end
    if self:IsLocked() then
        unlockGlow:Hide()
    else
        unlockGlow:Show()
    end
end

-- Position save/restore
function Display:SavePosition()
    local settings = PA:GetSettings()
    local point, _, relPoint, x, y = mainFrame:GetPoint()
    settings.framePoint = { point, relPoint, x, y }
end

function Display:RestorePosition()
    if not mainFrame then return end
    local settings = PA:GetSettings()
    if settings.framePoint then
        local p = settings.framePoint
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end
end

function Display:GetFrame()
    return mainFrame
end
