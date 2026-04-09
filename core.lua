-- MPC_MDTPullAssist - Core
-- Standalone addon that works alongside MythicPlusCount and MythicDungeonTools.
-- Reads MDT route data, uses MPC's scenario/dungeon detection utilities,
-- and displays the next pull in real-time during M+ dungeons.
--
-- MIDNIGHT (12.0.1) COMPATIBLE:
-- MDT NPC IDs are loaded from .lua files (in-memory, not affected by issecretvalue).
-- Pull tracking uses scenario forces API (no NPC ID queries needed inside instances).
-- COMBAT_LOG UNIT_DIED for secondary tracking may be secret inside instances;
-- gracefully falls back to forces-only tracking.
local ADDON_NAME, NS = ...

-- Addon namespace
local PA = {}
NS.PullAssist = PA

PA.VERSION = "1.0.0"

-- Sub-modules (populated by other files via NS.PullAssist)
PA.Mapping = PA.Mapping or {}
PA.RouteReader = PA.RouteReader or {}
PA.Tracker = PA.Tracker or {}
PA.Display = PA.Display or {}
PA.Nameplates = PA.Nameplates or {}
PA.Options = PA.Options or {}

local issecretvalue = issecretvalue or function() return false end

-- Utility: detect current dungeon challengeMapID
function PA:GetCurrentChallengeMapID()
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local mapID = C_ChallengeMode.GetActiveChallengeMapID()
        if mapID and not issecretvalue(mapID) then return mapID end
    end
    return nil
end

function PA:IsInMythicPlus()
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        return C_ChallengeMode.IsChallengeModeActive()
    end
    return false
end

-- Scenario forces reading (same approach as MPC.Util)
function PA:ReadEnemyForcesRaw()
    if not C_ScenarioInfo or not C_ScenarioInfo.GetScenarioStepInfo then return 0, 0 end
    local stepInfo = C_ScenarioInfo.GetScenarioStepInfo()
    if not stepInfo or not stepInfo.numCriteria then return 0, 0 end
    if issecretvalue(stepInfo.numCriteria) then return 0, 0 end
    for i = 1, stepInfo.numCriteria do
        local cInfo = C_ScenarioInfo.GetCriteriaInfo(i)
        if cInfo and cInfo.isWeightedProgress then
            local total = cInfo.totalQuantity
            if not total or issecretvalue(total) then return 0, 0 end
            local qStr = cInfo.quantityString
            if qStr and not issecretvalue(qStr) then
                local rawCount = tonumber(qStr:match("(%d+)"))
                if rawCount then return rawCount, total end
            end
            local qty = cInfo.quantity
            if qty and not issecretvalue(qty) then return qty, total end
            return 0, total
        end
    end
    return 0, 0
end

function PA:GetCompletedPercent()
    local rawCount, total = self:ReadEnemyForcesRaw()
    if total > 0 then return (rawCount / total) * 100 end
    return 0
end

function PA:GetSettings()
    if not MPC_MDTPullAssistDB then MPC_MDTPullAssistDB = {} end
    return MPC_MDTPullAssistDB
end

function PA:IsEnabled()
    -- Always enabled when addon is loaded
    return true
end

function PA:Debug(...)
    local settings = self:GetSettings()
    if not settings.debugMode then return end
    local msg = "|cFF00AAFF[PullAssist]|r"
    for i = 1, select("#", ...) do
        msg = msg .. " " .. tostring(select(i, ...))
    end
    print(msg)
end

function PA:Print(...)
    local msg = "|cFF66CCFF[MDT Pull Assist]|r"
    for i = 1, select("#", ...) do
        msg = msg .. " " .. tostring(select(i, ...))
    end
    print(msg)
end

-- Detect current dungeon, trying multiple methods
function PA:DetectCurrentMapID()
    -- Method 1: Direct challenge mode API
    local mapID = self:GetCurrentChallengeMapID()
    if mapID then return mapID end

    -- Method 2: From MDT's current dungeon selection
    if MDT and MDT.GetCurrentPreset then
        local ok, preset = pcall(MDT.GetCurrentPreset, MDT)
        if ok and preset and preset.value and preset.value.currentDungeonIdx then
            local challengeMapID = self.Mapping:GetChallengeMapID(preset.value.currentDungeonIdx)
            if challengeMapID then return challengeMapID end
        end
    end

    -- Method 3: From MDT zone mapping
    if MDT and MDT.zoneIdToDungeonIdx and C_Map and C_Map.GetBestMapForUnit then
        local zoneId = C_Map.GetBestMapForUnit("player")
        if zoneId and not issecretvalue(zoneId) then
            local dungeonIdx = MDT.zoneIdToDungeonIdx[zoneId]
            if dungeonIdx then
                local challengeMapID = self.Mapping:GetChallengeMapID(dungeonIdx)
                if challengeMapID then return challengeMapID end
            end
        end
    end

    return nil
end

-- Load or reload the MDT route for the current dungeon
function PA:ReloadRoute()
    local mapID = self:DetectCurrentMapID()

    if not mapID then
        self:Print("Not in a supported dungeon.")
        return false
    end

    PA.Mapping:ClearCache()
    local success = self.RouteReader:LoadRoute(mapID)
    if success then
        self.Tracker:Reset()
        self.Nameplates:OnRouteChanged()
        self.Display:Update()
        self:Print("Route loaded:", self.RouteReader:GetPlan().routeName,
            "-", self.RouteReader:GetPullCount(), "pulls")
    else
        self:Print("Could not load MDT route. Make sure MDT has a route for this dungeon.")
        self.Display:Update()
    end
    return success
end

-- Event frame
local eventFrame = CreateFrame("Frame")

-- RegisterEvent() is protected during /reload in combat.
-- InCombatLockdown() returns false during addon load even when protected.
-- NEVER call RegisterEvent at file load time. Instead, defer to OnUpdate
-- which fires on the next rendered frame when the frame system is safe.
local allEvents = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "CHALLENGE_MODE_START",
    "CHALLENGE_MODE_COMPLETED",
    "CHALLENGE_MODE_RESET",
    "SCENARIO_CRITERIA_UPDATE",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ZONE_CHANGED_NEW_AREA",
}

local eventsRegistered = false
eventFrame:SetScript("OnUpdate", function(self)
    if InCombatLockdown() then return end
    for _, event in ipairs(allEvents) do
        self:RegisterEvent(event)
    end
    eventsRegistered = true
    self:SetScript("OnUpdate", nil)

    -- We may have missed ADDON_LOADED, trigger init manually
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(ADDON_NAME) then
        OnAddonLoaded(ADDON_NAME)
    elseif IsAddOnLoaded and IsAddOnLoaded(ADDON_NAME) then
        OnAddonLoaded(ADDON_NAME)
    end
end)

local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then return end

    -- Initialize saved variables
    if not MPC_MDTPullAssistDB then MPC_MDTPullAssistDB = {} end

    -- Enable immediately
    PA:OnEnable()
end

-- Called when the addon is enabled
local enabled = false
function PA:OnEnable()
    if enabled then return end
    enabled = true

    -- Initialize display
    self.Display:Init()

    -- Initialize nameplates
    self.Nameplates:Init()

    -- Initialize tracker
    self.Tracker:Init()

    -- Apply saved threshold
    local settings = self:GetSettings()
    if settings.threshold then
        self.Tracker:SetThreshold(settings.threshold)
    end

    -- Try loading route immediately if in a dungeon
    C_Timer.After(1, function()
        PA:TryAutoLoad()
    end)

    PA:Debug("Enabled, v" .. PA.VERSION)
end

-- Auto-load route when entering a dungeon
function PA:TryAutoLoad()
    if not self:IsEnabled() then return end

    local mapID = self:DetectCurrentMapID()
    if not mapID then return end

    -- Only auto-load if we don't have a plan or dungeon changed
    local plan = self.RouteReader:GetPlan()
    if not plan or plan.challengeMapID ~= mapID then
        self:ReloadRoute()
    end

    self.Display:UpdateVisibility()
end

-- Combat log handler for mob death tracking
local function HandleCombatLog()
    local _, subEvent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    if subEvent ~= "UNIT_DIED" then return end

    if not destGUID or type(destGUID) ~= "string" then return end

    local issecretvalue = issecretvalue or function() return false end
    if issecretvalue(destGUID) then return end

    -- Parse NPC ID from GUID
    local guidType = strsplit("-", destGUID)
    if guidType ~= "Creature" and guidType ~= "Vehicle" then return end

    local _, _, _, _, _, npcID = strsplit("-", destGUID)
    npcID = npcID and tonumber(npcID)

    if npcID then
        PA.Tracker:OnMobDeath(npcID)
    else
        -- GUID parsing failed (secret value) - try MPC fingerprint system
        -- We can't resolve fingerprints from a GUID alone, but scenario updates
        -- will still track overall progress via forces-based tracking
        PA:Debug("Could not parse npcID from GUID (secret value?)")
    end
end

-- Route change detection ticker
local routeCheckTicker = nil

local function StartRouteCheckTicker()
    if routeCheckTicker then return end
    routeCheckTicker = C_Timer.NewTicker(10, function()
        if not PA:IsEnabled() then return end
        local mapID = PA:DetectCurrentMapID()
        if not mapID then return end
        if PA.RouteReader:HasRouteChanged(mapID) then
            PA:Debug("MDT route change detected, reloading...")
            PA:ReloadRoute()
        end
    end)
end

local function StopRouteCheckTicker()
    if routeCheckTicker then
        routeCheckTicker:Cancel()
        routeCheckTicker = nil
    end
end

-- Event dispatcher
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(...)
        return
    end

    -- Ignore all other events until fully initialized
    if not enabled then return end

    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2, function()
            PA:TryAutoLoad()
        end)

    elseif event == "CHALLENGE_MODE_START" then
        PA:Debug("M+ key started")
        C_Timer.After(1, function()
            PA:ReloadRoute()
            StartRouteCheckTicker()
        end)

    elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
        PA:Debug("M+ ended")
        StopRouteCheckTicker()
        PA.Display:UpdateVisibility()

    elseif event == "SCENARIO_CRITERIA_UPDATE" then
        PA.Tracker:OnScenarioUpdate()

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLog()

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat
        PA.Display:Update()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Left combat - delayed update for final scenario values
        C_Timer.After(0.5, function()
            PA.Tracker:OnScenarioUpdate()
            PA.Display:Update()
        end)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(1, function()
            PA:TryAutoLoad()
        end)
    end
end)

-- Slash commands
SLASH_MDTPULLASSIST1 = "/mdtpa"
SLASH_MDTPULLASSIST2 = "/pullassist"

SlashCmdList["MDTPULLASSIST"] = function(input)
    local cmd = (input or ""):trim():lower()

    if cmd == "" or cmd == "show" then
        PA.Display:SetShown(true)
        PA.Display:Update()

    elseif cmd == "config" or cmd == "options" or cmd == "settings" then
        PA.Options:Toggle()

    elseif cmd == "hide" then
        PA.Display:SetShown(false)

    elseif cmd == "lock" then
        local settings = PA:GetSettings()
        settings.locked = true
        PA.Display:UpdateLock()
        PA:Print("Frame locked.")

    elseif cmd == "unlock" then
        local settings = PA:GetSettings()
        settings.locked = false
        PA.Display:UpdateLock()
        PA:Print("Frame unlocked - drag to reposition.")

    elseif cmd == "reload" or cmd == "refresh" then
        PA:ReloadRoute()

    elseif cmd == "reset" then
        PA.Tracker:Reset()
        PA.Display:Update()
        PA:Print("Tracking reset.")

    elseif cmd == "debug" then
        local settings = PA:GetSettings()
        settings.debugMode = not settings.debugMode
        PA:Print("Debug mode:", settings.debugMode and "|cFF44FF44ON|r" or "|cFFFF4444OFF|r")

    elseif cmd == "status" then
        local plan = PA.RouteReader:GetPlan()
        if plan then
            local pullIdx = PA.Tracker:GetCurrentPullIndex()
            PA:Print(string.format("Route: %s | Pulls: %d | Current: #%d | Completed: %d/%d",
                plan.routeName, #plan.pulls, pullIdx,
                PA.Tracker:GetCompletedPullCount(), #plan.pulls))

            local nextPull = PA.Tracker:GetNextPull()
            if nextPull then
                local mobList = {}
                for _, mob in ipairs(nextPull.mobs) do
                    if mob.quantity > 1 then
                        mobList[#mobList + 1] = string.format("%dx %s", mob.quantity, mob.name)
                    else
                        mobList[#mobList + 1] = mob.name
                    end
                end
                PA:Print(string.format("Next pull #%d: %s (%d forces, %.1f%%)",
                    nextPull.index, table.concat(mobList, ", "),
                    nextPull.totalForces, nextPull.totalPercent))
            end
        else
            PA:Print("No route loaded. Use /mdtpa reload in a dungeon.")
        end

    elseif cmd:match("^pull%s+(%d+)") then
        local idx = tonumber(cmd:match("^pull%s+(%d+)"))
        if idx then
            PA.Tracker:SetCurrentPull(idx)
            PA:Print("Set to pull #" .. idx)
        end

    elseif cmd == "help" then
        PA:Print("Commands:")
        PA:Print("  /mdtpa         - Show the pull assist frame")
        PA:Print("  /mdtpa config  - Open settings panel")
        PA:Print("  /mdtpa hide    - Hide the pull assist frame")
        PA:Print("  /mdtpa lock    - Lock frame position")
        PA:Print("  /mdtpa unlock  - Unlock frame for dragging")
        PA:Print("  /mdtpa reload  - Reload MDT route")
        PA:Print("  /mdtpa reset   - Reset pull tracking")
        PA:Print("  /mdtpa status  - Print current status")
        PA:Print("  /mdtpa pull N  - Jump to pull #N")
        PA:Print("  /mdtpa debug   - Toggle debug mode")
        PA:Print("  /mdtpa help    - This help message")

    else
        PA:Print("Unknown command. Use /mdtpa help")
    end
end
