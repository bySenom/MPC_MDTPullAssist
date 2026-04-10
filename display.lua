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
local progressBar = nil     -- forces progress bar
local progressBarText = nil
local warningText = nil     -- off-route warning
local partySyncText = nil   -- party sync indicator

local MAX_MOB_LINES = 14
local FRAME_WIDTH = 260
local FRAME_MIN_HEIGHT = 70
local LINE_HEIGHT = 16
local HEADER_HEIGHT = 24
local PADDING = 10

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
    headerText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    headerText:SetTextColor(unpack(C.accent))
    headerText:SetPoint("TOPLEFT", PADDING, -(PADDING / 2))
    headerText:SetText("Pull #1")

    -- Progress on right side of header
    progressText = mainFrame:CreateFontString(nil, "OVERLAY")
    progressText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    progressText:SetTextColor(unpack(C.textDim))
    progressText:SetPoint("TOPRIGHT", -PADDING, -(PADDING / 2 + 1))
    progressText:SetText("")

    -- Route name (small, below header)
    routeText = mainFrame:CreateFontString(nil, "OVERLAY")
    routeText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    routeText:SetTextColor(unpack(C.textDim))
    routeText:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + 2))
    routeText:SetText("")

    -- Forces progress bar (below route name)
    progressBar = CreateFrame("StatusBar", nil, mainFrame)
    progressBar:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + 14))
    progressBar:SetPoint("RIGHT", mainFrame, "RIGHT", -PADDING, 0)
    progressBar:SetHeight(10)
    progressBar:SetMinMaxValues(0, 100)
    progressBar:SetValue(0)
    progressBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    progressBar:SetStatusBarColor(0.30, 0.85, 0.40, 0.9)

    local barBg = progressBar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.15, 0.15, 0.18, 1.0)

    progressBarText = progressBar:CreateFontString(nil, "OVERLAY")
    progressBarText:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    progressBarText:SetTextColor(1, 1, 1, 0.9)
    progressBarText:SetPoint("CENTER", 0, 0)
    progressBarText:SetText("")
    progressBar:Hide()

    -- Party sync indicator (below warning, hidden by default)
    partySyncText = mainFrame:CreateFontString(nil, "OVERLAY")
    partySyncText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    partySyncText:SetTextColor(1.0, 0.82, 0.0, 0.9)
    partySyncText:SetJustifyH("CENTER")
    partySyncText:SetText("")
    partySyncText:Hide()

    -- "No route loaded" text
    noRouteText = mainFrame:CreateFontString(nil, "OVERLAY")
    noRouteText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    noRouteText:SetTextColor(unpack(C.textDim))
    noRouteText:SetPoint("CENTER", 0, 0)
    noRouteText:SetText("No MDT route loaded")
    noRouteText:Hide()

    -- Pre-create mob line FontStrings
    for i = 1, MAX_MOB_LINES do
        local line = {}

        line.name = mainFrame:CreateFontString(nil, "OVERLAY")
        line.name:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        line.name:SetTextColor(unpack(C.textNormal))
        line.name:SetJustifyH("LEFT")
        line.name:SetWordWrap(false)

        line.forces = mainFrame:CreateFontString(nil, "OVERLAY")
        line.forces:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
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
    MenuUtil.CreateContextMenu(mainFrame, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle("MDT Pull Assist")
        rootDescription:CreateButton("Reload Route", function()
            PA:ReloadRoute()
        end)
        rootDescription:CreateButton("Reset Tracking", function()
            PA.Tracker:Reset()
            self:Update()
        end)
        rootDescription:CreateDivider()
        rootDescription:CreateButton("Next Pull", function()
            local idx = PA.Tracker:GetCurrentPullIndex()
            PA.Tracker:SetCurrentPull(idx + 1)
        end)
        rootDescription:CreateButton("Previous Pull", function()
            local idx = PA.Tracker:GetCurrentPullIndex()
            if idx > 1 then PA.Tracker:SetCurrentPull(idx - 1) end
        end)
        rootDescription:CreateDivider()
        rootDescription:CreateButton("Hide", function()
            self:SetShown(false)
        end)
    end)
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

    -- Update forces progress bar
    local rawCount, total = PA:ReadEnemyForcesRaw()
    if total > 0 then
        local pct = (rawCount / total) * 100
        progressBar:SetValue(pct)
        progressBarText:SetText(string.format("%d/%d (%.1f%%)", rawCount, total, pct))
        progressBar:Show()
    elseif PA:IsDebugMode() or not PA:IsInMythicPlus() then
        -- Outside M+: show cumulative route % through current pull
        local pullIdx = PA.Tracker:GetCurrentPullIndex()
        local pull = plan.pulls[pullIdx]
        if pull then
            progressBar:SetValue(pull.cumPercent)
            progressBarText:SetText(string.format("Route: %.1f%%", pull.cumPercent))
        else
            progressBar:SetValue(100)
            progressBarText:SetText("Route: 100%")
        end
        progressBar:Show()
    else
        progressBar:Hide()
    end

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
    local settings = PA:GetSettings()
    local headerColor = C.accent
    if settings.usePullColors ~= false and pull.color then
        headerColor = { pull.color[1], pull.color[2], pull.color[3], 1.0 }
    end
    headerText:SetText(string.format("Next Pull |cFFFFFFFF#%d|r", pullIdx))
    headerText:SetTextColor(unpack(headerColor))
    progressText:SetText(string.format("%d/%d", pullIdx - 1, #plan.pulls))
    routeText:SetText(plan.routeName)

    -- Get per-mob kill data for current pull
    local mobKills = PA.Tracker:GetMobKillsForPull(pullIdx)

    -- Mob lines
    local showCount = settings.showCount ~= false
    local showPercent = settings.showPercent ~= false
    local lineCount = 0
    local MOB_TOP_OFFSET = HEADER_HEIGHT + 28  -- shifted down for progress bar

    for i, mob in ipairs(pull.mobs) do
        if i > MAX_MOB_LINES then break end
        lineCount = i
        local line = mobLines[i]

        -- Check kill progress
        local killInfo = mobKills and mobKills[mob.npcID]
        local killed = killInfo and killInfo.killed or 0
        local expected = killInfo and killInfo.expected or mob.quantity
        local isComplete = killed >= expected and expected > 0

        -- Name with quantity prefix and kill progress
        local nameStr
        if mob.quantity > 1 then
            if isComplete then
                nameStr = string.format("|cFF666666x %dx %s|r", mob.quantity, mob.name)
            elseif killed > 0 then
                nameStr = string.format("|cFFCCCCCC%dx|r %s |cFFFFCC00(%d/%d)|r", mob.quantity, mob.name, killed, expected)
            else
                nameStr = string.format("|cFFCCCCCC%dx|r %s", mob.quantity, mob.name)
            end
        else
            if isComplete then
                nameStr = string.format("|cFF666666x %s|r", mob.name)
            else
                nameStr = mob.name
            end
        end
        line.name:SetText(nameStr)

        -- Text color: dim for completed mobs
        if isComplete then
            line.name:SetTextColor(0.4, 0.4, 0.4, 0.7)
        else
            line.name:SetTextColor(unpack(C.textNormal))
        end

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
            line.forces:SetTextColor(1.0, 0.82, 0.0, 1.0)
            if totalMobForces == 0 then forcesStr = "BOSS" end
        elseif isComplete then
            line.forces:SetTextColor(0.4, 0.4, 0.4, 0.7)
        else
            line.forces:SetTextColor(unpack(C.green))
        end
        line.forces:SetText(forcesStr)

        -- Position (shifted down for progress bar)
        local yOff = -(MOB_TOP_OFFSET + (i - 1) * LINE_HEIGHT)
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
        local yOff = -(MOB_TOP_OFFSET + lineCount * LINE_HEIGHT + 4)
        line.name:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, yOff)
        line.name:SetPoint("RIGHT", line.forces, "LEFT", -4, 0)
        line.forces:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, yOff)

        line.name:SetText("|cFF888888Pull Total:|r")
        line.name:SetTextColor(unpack(C.textDim))

        local totalStr = ""
        if showCount and showPercent then
            totalStr = string.format("|cFFFFFFFF%d|r (|cFF66CCFF%.1f%%|r) > cum. |cFF66CCFF%.1f%%|r",
                pull.totalForces, pull.totalPercent, pull.cumPercent)
        elseif showCount then
            totalStr = string.format("|cFFFFFFFF%d|r > cum. %d", pull.totalForces, pull.cumForces)
        else
            totalStr = string.format("|cFF66CCFF%.1f%%|r > cum. |cFF66CCFF%.1f%%|r", pull.totalPercent, pull.cumPercent)
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

    -- Pull note (if enabled and present)
    if settings.showPullNotes ~= false and pull.note then
        lineCount = lineCount + 1
        if lineCount <= MAX_MOB_LINES then
            local line = mobLines[lineCount]
            local yOff = -(MOB_TOP_OFFSET + (lineCount - 1) * LINE_HEIGHT + 2)
            line.name:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, yOff)
            line.name:SetPoint("RIGHT", mainFrame, "RIGHT", -PADDING, 0)
            line.forces:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, yOff)
            line.name:SetText("|cFFAAAA66Note: " .. pull.note .. "|r")
            line.name:SetTextColor(0.67, 0.67, 0.4, 0.9)
            line.forces:SetText("")
            line.forces:Hide()
            line.name:Show()
        end
    end

    -- Hide remaining lines
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
    if progressBar then progressBar:Hide() end
    if warningText then warningText:Hide() end
    if partySyncText then partySyncText:Hide() end
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
    -- Extra 10px for progress bar
    local height = HEADER_HEIGHT + 24 + math.max(lineCount, 1) * LINE_HEIGHT + PADDING + 4
    height = math.max(height, FRAME_MIN_HEIGHT)
    mainFrame:SetHeight(height)
end

-- Pull transition callbacks
function Display:OnPullAdvanced(newIdx)
    if flashAnim then flashAnim:Play() end
    self:Update()
    -- Broadcast pull to party
    PA:BroadcastPull(newIdx)
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

----------------------------------------------------------------
-- Off-route warning frame (standalone, movable, fades out)
----------------------------------------------------------------
local warningFrame = nil
local warningFadeAnim = nil

local WARNING_SOUNDS = {
    ["RaidWarning"]   = 8959,   -- RAID_WARNING
    ["ReadyCheck"]    = 8960,   -- READY_CHECK
    ["FlagTaken"]     = 8174,   -- PVP_FLAG_TAKEN_HORDE
    ["LevelUp"]       = 888,    -- LEVEL_UP
    ["None"]          = nil,
}

function Display:CreateWarningFrame()
    if warningFrame then return end

    warningFrame = CreateFrame("Frame", "MPCPullAssistWarning", UIParent, "BackdropTemplate")
    warningFrame:SetSize(320, 50)
    warningFrame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    warningFrame:SetFrameStrata("HIGH")
    warningFrame:SetFrameLevel(100)
    warningFrame:SetClampedToScreen(true)
    warningFrame:SetMovable(true)
    warningFrame:EnableMouse(true)
    warningFrame:RegisterForDrag("LeftButton")
    warningFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    warningFrame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        -- Save position
        local settings = PA:GetSettings()
        local point, _, relPoint, x, y = f:GetPoint()
        settings.warningPoint = { point, relPoint, x, y }
    end)

    warningFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    warningFrame:SetBackdropColor(0.15, 0.02, 0.02, 0.85)
    warningFrame:SetBackdropBorderColor(0.90, 0.20, 0.20, 0.9)

    warningText = warningFrame:CreateFontString(nil, "OVERLAY")
    warningText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    warningText:SetTextColor(1.0, 0.30, 0.30, 1.0)
    warningText:SetPoint("CENTER", 0, 0)
    warningText:SetJustifyH("CENTER")

    -- Fade-out animation
    warningFadeAnim = warningFrame:CreateAnimationGroup()
    local fadeOut = warningFadeAnim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(1.5)
    fadeOut:SetStartDelay(3.0)  -- visible 3s, then 1.5s fade
    fadeOut:SetOrder(1)
    warningFadeAnim:SetScript("OnFinished", function()
        warningFrame:Hide()
        warningFrame:SetAlpha(1)
    end)

    -- Restore saved position
    local settings = PA:GetSettings()
    if settings.warningPoint then
        local p = settings.warningPoint
        warningFrame:ClearAllPoints()
        warningFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    warningFrame:Hide()
end

function Display:ShowOffRouteWarning(mobName)
    if not warningFrame then self:CreateWarningFrame() end
    if not warningFrame or not warningText then return end

    local label = mobName and ("OFF ROUTE: " .. mobName) or "ADD PULLED OFF ROUTE"
    warningText:SetText(label)

    -- Stop existing fade, reset alpha
    if warningFadeAnim then warningFadeAnim:Stop() end
    warningFrame:SetAlpha(1)
    warningFrame:Show()

    -- Start fade animation (skip if unlocked for positioning)
    if not warningFrame.unlocked and warningFadeAnim then
        warningFadeAnim:Play()
    end

    -- Clear auto-dismiss timer from old system (no-op, kept for safety)

    -- Play sound (supports built-in IDs and SharedMedia paths)
    local settings = PA:GetSettings()
    local soundKey = settings.warnSound or "RaidWarning"
    if soundKey ~= "None" then
        -- Try saved path first (SharedMedia)
        if settings.warnSoundPath then
            PlaySoundFile(settings.warnSoundPath, "Master")
        else
            local soundID = settings.warnSoundID or WARNING_SOUNDS[soundKey]
            if soundID then
                PlaySound(soundID, "Master")
            end
        end
    end
end

-- Toggle warning frame unlock for repositioning
function Display:ToggleWarningUnlock()
    if not warningFrame then self:CreateWarningFrame() end
    if not warningFrame then return end

    warningFrame.unlocked = not warningFrame.unlocked

    if warningFrame.unlocked then
        -- Show with drag hint, no fade
        if warningFadeAnim then warningFadeAnim:Stop() end
        warningFrame:SetAlpha(1)
        warningText:SetText("-- Drag to reposition --")
        warningText:SetTextColor(1.0, 0.82, 0.0, 1.0)
        warningFrame:SetBackdropBorderColor(1.0, 0.82, 0.0, 0.9)
        warningFrame:Show()
    else
        -- Lock and hide
        warningText:SetTextColor(1.0, 0.30, 0.30, 1.0)
        warningFrame:SetBackdropBorderColor(0.90, 0.20, 0.20, 0.9)
        warningFrame:Hide()
    end
end

-- Update party sync indicator text
function Display:UpdatePartySync(text)
    if not mainFrame or not partySyncText then return end
    if text and text ~= "" then
        partySyncText:SetText(text)
        partySyncText:ClearAllPoints()
        partySyncText:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", PADDING, 2)
        partySyncText:SetPoint("RIGHT", mainFrame, "RIGHT", -PADDING, 0)
        partySyncText:Show()
    else
        partySyncText:Hide()
    end
end
