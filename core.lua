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

PA.VERSION = "1.1.0"

-- Keybind header and names (must be globals for WoW Key Bindings UI)
BINDING_HEADER_MDTPULLASSIST = "MDT Pull Assist"
BINDING_NAME_MDTPA_TOGGLE_FRAME = "Toggle Pull Assist Frame"
BINDING_NAME_MDTPA_NEXT_PULL = "Next Pull"
BINDING_NAME_MDTPA_PREV_PULL = "Previous Pull"

-- Global keybind functions (called from Bindings.xml)
function PA_ToggleFrame()
    if PA.Display then
        local frame = PA.Display:GetFrame()
        if frame and frame:IsShown() then
            PA.Display:SetShown(false)
        else
            PA.Display:SetShown(true)
            PA.Display:Update()
        end
    end
end

function PA_NextPull()
    if PA.Tracker then
        local idx = PA.Tracker:GetCurrentPullIndex()
        PA.Tracker:SetCurrentPull(idx + 1)
    end
end

function PA_PrevPull()
    if PA.Tracker then
        local idx = PA.Tracker:GetCurrentPullIndex()
        if idx > 1 then PA.Tracker:SetCurrentPull(idx - 1) end
    end
end

-- Sub-modules (populated by other files via NS.PullAssist)
PA.Mapping = PA.Mapping or {}
PA.RouteReader = PA.RouteReader or {}
PA.Tracker = PA.Tracker or {}
PA.Display = PA.Display or {}
PA.Nameplates = PA.Nameplates or {}
PA.Options = PA.Options or {}

-- DO NOT read the issecretvalue global at file scope!
-- It is a Blizzard secure function; reading it taints the execution chunk,
-- causing all subsequent RegisterEvent/CreateFrame calls to trigger
-- ADDON_ACTION_FORBIDDEN. Access it lazily inside function bodies only.
local function isSecretValue(val)
    local fn = rawget(_G, "issecretvalue")
    if fn then return fn(val) end
    return false
end

-- Utility: detect current dungeon challengeMapID
function PA:GetCurrentChallengeMapID()
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local mapID = C_ChallengeMode.GetActiveChallengeMapID()
        if mapID and not isSecretValue(mapID) then return mapID end
    end
    return nil
end

function PA:IsInMythicPlus()
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        return C_ChallengeMode.IsChallengeModeActive()
    end
    return false
end

function PA:IsDebugMode()
    local settings = self:GetSettings()
    return settings.debugMode == true
end

-- Scenario forces reading (same approach as MPC.Util)
function PA:ReadEnemyForcesRaw()
    if not C_ScenarioInfo or not C_ScenarioInfo.GetScenarioStepInfo then return 0, 0 end
    local stepInfo = C_ScenarioInfo.GetScenarioStepInfo()
    if not stepInfo or not stepInfo.numCriteria then return 0, 0 end
    if isSecretValue(stepInfo.numCriteria) then return 0, 0 end
    for i = 1, stepInfo.numCriteria do
        local cInfo = C_ScenarioInfo.GetCriteriaInfo(i)
        if cInfo and cInfo.isWeightedProgress then
            local total = cInfo.totalQuantity
            if not total or isSecretValue(total) then return 0, 0 end
            local qStr = cInfo.quantityString
            if qStr and not isSecretValue(qStr) then
                local rawCount = tonumber(qStr:match("(%d+)"))
                if rawCount then return rawCount, total end
            end
            local qty = cInfo.quantity
            if qty and not isSecretValue(qty) then return qty, total end
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
        if zoneId and not isSecretValue(zoneId) then
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

-- Force-load a specific dungeon route (for debug/follower dungeon testing)
function PA:ForceLoadDungeon(challengeMapID)
    PA.Mapping:ClearCache()
    local success = self.RouteReader:LoadRoute(challengeMapID)
    if success then
        self.Tracker:Reset()
        self.Nameplates:OnRouteChanged()
        self.Display:SetShown(true)
        self.Display:Update()
        self:Print("Force-loaded:", self.Mapping:GetDungeonName(challengeMapID),
            "-", self.RouteReader:GetPullCount(), "pulls")
    else
        self:Print("Could not load MDT route for", self.Mapping:GetDungeonName(challengeMapID))
    end
    return success
end

-- Event frame
-- Create the frame AND register events inside C_Timer.After(0) so both
-- happen in a clean, untainted execution context (the main chunk is
-- tainted by other addons reading secure globals before us).
local eventFrame

C_Timer.After(0, function()
    -- Saved-variables are available now (all ADDON_LOADED events have fired)
    if not MPC_MDTPullAssistDB then MPC_MDTPullAssistDB = {} end
    PA:OnEnable()

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    eventFrame:RegisterEvent("CHALLENGE_MODE_RESET")
    eventFrame:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
    eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    PA:SetupEventDispatcher(eventFrame)

    -- Fire initial load since we missed PLAYER_ENTERING_WORLD if already in-world
    C_Timer.After(1, function()
        PA:TryAutoLoad()
    end)
end)

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

    -- Minimap button (LibDataBroker + LibDBIcon, bundled by MDT)
    if LibStub then
        local LDB = LibStub("LibDataBroker-1.1", true)
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDB and LDBIcon then
            if not settings.minimap then settings.minimap = {} end
            local dataObj = LDB:NewDataObject("MDTPullAssist", {
                type = "data source",
                text = "Pull Assist",
                icon = "Interface\\Icons\\INV_Misc_Map_01",
                OnClick = function(_, button)
                    if button == "LeftButton" then
                        PA_ToggleFrame()
                    elseif button == "RightButton" then
                        PA.Options:Toggle()
                    end
                end,
                OnTooltipShow = function(tt)
                    tt:AddLine("|cFF66CCFFMDT Pull Assist|r")
                    local plan = PA.RouteReader:GetPlan()
                    if plan then
                        tt:AddLine(plan.routeName, 0.85, 0.85, 0.85)
                        local idx = PA.Tracker:GetCurrentPullIndex()
                        tt:AddLine(string.format("Pull %d / %d", idx, #plan.pulls), 0.55, 0.55, 0.6)
                    else
                        tt:AddLine("No route loaded", 0.55, 0.55, 0.6)
                    end
                    tt:AddLine(" ")
                    tt:AddLine("|cFFAAAAAALeft-click:|r Toggle frame", 0.8, 0.8, 0.8)
                    tt:AddLine("|cFFAAAAAARight-click:|r Options", 0.8, 0.8, 0.8)
                end,
            })
            LDBIcon:Register("MDTPullAssist", dataObj, settings.minimap)
        end
    end

    -- Initialize party sync
    self:InitPartySync()

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

    -- Ensure route check ticker is running if in M+ (covers /reload mid-key)
    if self:IsInMythicPlus() then
        StartRouteCheckTicker()
    end

    self.Display:UpdateVisibility()
end

----------------------------------------------------------------
-- Party Sync (addon comms)
----------------------------------------------------------------
local COMM_PREFIX = "MDTPA"
local partyPulls = {}           -- [playerName] = pullIdx
local lastBroadcastTime = 0
local BROADCAST_THROTTLE = 5    -- seconds

function PA:InitPartySync()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
    end
end

function PA:BroadcastPull(pullIdx)
    local settings = self:GetSettings()
    if settings.partySyncEnabled == false then return end
    if not IsInGroup() then return end

    local now = GetTime()
    if (now - lastBroadcastTime) < BROADCAST_THROTTLE then return end
    lastBroadcastTime = now

    local channel = IsInGroup(2) and "INSTANCE_CHAT" or (IsInRaid() and "RAID" or "PARTY")
    local msg = "PULL:" .. tostring(pullIdx)
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, channel)
    self:Debug("Party sync: broadcast pull", pullIdx, "to", channel)
end

function PA:OnPartySyncReceived(prefix, msg, channel, sender)
    if prefix ~= COMM_PREFIX then return end
    local settings = self:GetSettings()
    if settings.partySyncEnabled == false then return end

    -- Ignore our own messages
    sender = Ambiguate(sender, "none")
    local myName = UnitName("player")
    if sender == myName then return end

    local cmd, value = strsplit(":", msg, 2)
    if cmd == "PULL" then
        local pullIdx = tonumber(value)
        if pullIdx then
            partyPulls[sender] = pullIdx
            self:UpdatePartySyncDisplay()
        end
    end
end

function PA:UpdatePartySyncDisplay()
    local myPull = self.Tracker:GetCurrentPullIndex()
    local mismatches = {}
    for name, pullIdx in pairs(partyPulls) do
        if pullIdx ~= myPull then
            mismatches[#mismatches + 1] = string.format("%s: Pull %d", name, pullIdx)
        end
    end
    if #mismatches > 0 then
        self.Display:UpdatePartySync("! " .. table.concat(mismatches, ", "))
    else
        self.Display:UpdatePartySync(nil)
    end
end

-- Combat log handler for mob death tracking
local function HandleCombatLog()
    local _, subEvent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
    if subEvent ~= "UNIT_DIED" then return end

    if not destGUID or type(destGUID) ~= "string" then return end

    if isSecretValue(destGUID) then return end

    -- Parse NPC ID from GUID
    local guidType = strsplit("-", destGUID)
    if guidType ~= "Creature" and guidType ~= "Vehicle" then return end

    local _, _, _, _, _, npcID = strsplit("-", destGUID)
    npcID = npcID and tonumber(npcID)

    if npcID then
        PA.Tracker:OnMobDeath(npcID)

        -- Off-route warning: if this npcID is not in any route pull
        local settings = PA:GetSettings()
        if settings.warnOffRoute ~= false and PA.RouteReader:HasRoute() then
            if not PA.Tracker:IsNpcInRoute(npcID) then
                local mobName = destName
                if mobName and isSecretValue(mobName) then mobName = nil end
                PA.Display:ShowOffRouteWarning(mobName)
                PA:Debug("Off-route mob killed:", mobName or "?", "npcID:", npcID)
            end
        end
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

-- Event dispatcher (called from C_Timer.After to keep the frame untainted)
function PA:SetupEventDispatcher(ef)
    ef:SetScript("OnEvent", function(_, event, ...)
    -- Ignore all events until fully initialized
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

    elseif event == "CHAT_MSG_ADDON" then
        PA:OnPartySyncReceived(...)

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Clean stale partyPulls entries for players no longer in group
        for name in pairs(partyPulls) do
            local inGroup = false
            for i = 1, GetNumGroupMembers() do
                local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
                local uName = UnitName(unit)
                if uName and Ambiguate(uName, "none") == name then
                    inGroup = true
                    break
                end
            end
            if not inGroup then
                partyPulls[name] = nil
            end
        end
        PA:UpdatePartySyncDisplay()
    end
    end)
end

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
        if settings.debugMode then
            PA:Print("  Frame always visible. COMBAT_LOG tracking active.")
            PA:Print("  Use /mdtpa load <dungeon> to force-load a route.")
            PA:Print("  Use /mdtpa done to mark current pull complete.")
            PA:Print("  Dungeons: pit, skyreach, windrunner, magisters, maisara, nexus, algeth, seat")
        end
        PA.Display:UpdateVisibility()

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

    elseif cmd:match("^load%s+(.+)") then
        local dungeonName = cmd:match("^load%s+(.+)")
        local mapID = PA.Mapping:ResolveDungeonAlias(dungeonName)
        if mapID then
            PA:ForceLoadDungeon(mapID)
        else
            PA:Print("Unknown dungeon: '" .. dungeonName .. "'")
            PA:Print("Available: pit, skyreach, windrunner, magisters, maisara, nexus, algeth, seat")
        end

    elseif cmd == "done" or cmd == "completepull" then
        local plan = PA.RouteReader:GetPlan()
        if not plan then
            PA:Print("No route loaded.")
        else
            local idx = PA.Tracker:GetCurrentPullIndex()
            if idx <= #plan.pulls then
                PA.Tracker:CompletePull(idx)
                PA:Print(string.format("Pull #%d marked complete.", idx))
            else
                PA:Print("All pulls already complete.")
            end
        end

    elseif cmd == "dungeons" or cmd == "list" then
        PA:Print("Supported dungeons:")
        for mapID, name in pairs(PA.Mapping:GetAllDungeonNames()) do
            PA:Print(string.format("  %s (ID: %d)", name, mapID))
        end

    elseif cmd == "nptest" or cmd == "scanplates" then
        PA:Print("|cFF44FF44Scanning nameplates...|r")
        local plan = PA.RouteReader:GetPlan()
        if not plan then
            PA:Print("  No route loaded!")
        else
            PA:Print(string.format("  Route: %s (%d pulls, dungeonIdx %d, mapID %s)",
                plan.routeName, #plan.pulls, plan.dungeonIdx,
                tostring(plan.challengeMapID)))
            -- Show fingerprint database status
            local mpcFPCount = 0
            if plan.challengeMapID and MythicPlusCountDB and MythicPlusCountDB.fingerprints then
                local fpMap = MythicPlusCountDB.fingerprints[plan.challengeMapID]
                if fpMap then
                    for _ in pairs(fpMap) do mpcFPCount = mpcFPCount + 1 end
                end
            end
            local embeddedCount = 0
            if plan.challengeMapID and PA.EmbeddedFingerprints and PA.EmbeddedFingerprints[plan.challengeMapID] then
                for _ in pairs(PA.EmbeddedFingerprints[plan.challengeMapID]) do embeddedCount = embeddedCount + 1 end
            end
            local totalFP = mpcFPCount + embeddedCount
            PA:Print(string.format("  Fingerprints: %d (MPC: %d, embedded: %d) %s",
                totalFP, mpcFPCount, embeddedCount,
                totalFP > 0 and "|cFF44FF44OK|r" or "|cFFFF4444none!|r"))
        end
        local found = 0
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if UnitExists(unit) then
                found = found + 1
                local name = UnitName(unit) or "?"
                local guid = UnitGUID(unit)
                local npcID = "?"
                local guidInfo = "nil"
                if guid then
                    if isSecretValue(guid) then
                        guidInfo = "SECRET"
                    else
                        guidInfo = guid
                        local guidType = strsplit("-", guid)
                        if guidType == "Creature" or guidType == "Vehicle" then
                            local _, _, _, _, _, rawID = strsplit("-", guid)
                            npcID = rawID or "?"
                        end
                    end
                end
                -- Try full identification chain (including MPC fingerprints)
                local identifiedNpc = PA.Nameplates and PA.Nameplates.IdentifyUnit
                    and PA.Nameplates:IdentifyUnit(unit)
                if identifiedNpc then npcID = tostring(identifiedNpc) end

                local inPullMap = identifiedNpc and PA.Nameplates:GetPullInfoForNpc(identifiedNpc)
                local canAttack = UnitCanAttack("player", unit)
                local isDead = UnitIsDead(unit)
                local isPlayer = UnitIsPlayer(unit)
                local status = canAttack and "|cFF44FF44ATK|r" or "|cFFFF4444friendly|r"
                if isDead then status = "|cFF888888DEAD|r" end
                if isPlayer then status = "|cFF8888FFplayer|r" end
                local pullStr = inPullMap and
                    string.format("|cFF44FF44Pull %d (%s)|r", inPullMap.pullIdx, inPullMap.pullType or "?") or
                    "|cFFFF4444not in route|r"
                -- Show fingerprint for unidentified mobs
                local fpStr = ""
                if not identifiedNpc and canAttack and not isPlayer then
                    local fp = PA.Nameplates.BuildFingerprint and PA.Nameplates:BuildFingerprint(unit)
                    if fp then
                        fpStr = " | fp=" .. fp
                    else
                        -- Diagnose why fingerprint failed
                        local reason = "?"
                        if not modelFrame then
                            -- modelFrame is local to nameplates.lua, check via method
                            reason = "no modelFrame"
                        else
                            reason = "see debug"
                        end
                        -- Inline diagnosis: try the individual steps
                        local diagModelFrame = CreateFrame("PlayerModel")
                        diagModelFrame:SetSize(1, 1)
                        local diagOk, diagErr = pcall(diagModelFrame.SetUnit, diagModelFrame, unit)
                        if not diagOk then
                            reason = "SetUnit err: " .. tostring(diagErr)
                        else
                            local mid = diagModelFrame:GetModelFileID()
                            if not mid then
                                reason = "modelID=nil"
                            elseif isSecretValue(mid) then
                                reason = "modelID=SECRET"
                            elseif mid <= 0 then
                                reason = "modelID=" .. tostring(mid)
                            else
                                -- Model ID works, check other fields
                                local lvl = UnitLevel(unit)
                                if not lvl or isSecretValue(lvl) then
                                    reason = "level=SECRET"
                                else
                                    local relLvl = lvl % 10
                                    local cls = UnitClassification(unit) or "x"
                                    local sx = UnitSex(unit) or 0
                                    local _, ct = UnitClass(unit)
                                    ct = ct or "x"
                                    local pt = UnitPowerType(unit) or -1
                                    reason = string.format("built=%d:%d:%s:%d:%s:%d",
                                        mid, relLvl, tostring(cls), sx, tostring(ct), pt)
                                end
                            end
                        end
                        diagModelFrame:Hide()
                        fpStr = " | fp=nil (" .. reason .. ")"
                    end
                end
                PA:Print(string.format("  [%d] %s | npcID=%s | guid=%s | %s | %s%s",
                    i, name, tostring(npcID), guidInfo, status, pullStr, fpStr))
            end
        end
        if found == 0 then
            PA:Print("  No nameplates found. Make sure enemy nameplates are enabled (V key).")
        else
            PA:Print(string.format("  %d nameplates scanned.", found))
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
        PA:Print("  |cFF44FF44Debug commands:|r")
        PA:Print("  /mdtpa load <dungeon> - Force-load a dungeon route")
        PA:Print("  /mdtpa done    - Mark current pull complete")
        PA:Print("  /mdtpa dungeons - List supported dungeons")
        PA:Print("  /mdtpa nptest  - Scan all visible nameplates (diagnose)")
        PA:Print("  /mdtpa help    - This help message")

    else
        PA:Print("Unknown command. Use /mdtpa help")
    end
end
