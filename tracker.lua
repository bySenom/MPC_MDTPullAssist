-- MPC_MDTPullAssist - Tracker
-- Tracks which pulls from the MDT route have been completed.
-- Uses a hybrid approach:
--   1. Primary: Cumulative forces from scenario API (via MPC.Util)
--   2. Secondary: COMBAT_LOG_EVENT UNIT_DIED npcID death tracking
-- Handles out-of-order pulls via greedy matching.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local Tracker = {}
PA.Tracker = Tracker

-- State
local currentPullIdx = 1          -- index into route plan
local pullStates = {}             -- [pullIdx] = "pending" | "active" | "complete"
local deadNpcCounts = {}          -- [npcID] = number of kills (global)
local lastCompletedPct = 0        -- last known scenario completion %
local initialized = false

local COMPLETION_THRESHOLD = 0.90  -- 90% of pull forces → consider pull done

-- Build consumed counts: how many kills of each npcID are "used up" by completed pulls
-- (ordered by pull index so earlier pulls consume first)
local function BuildConsumedCounts(plan)
    local consumed = {}
    for i = 1, #plan.pulls do
        if pullStates[i] == "complete" then
            for _, mob in ipairs(plan.pulls[i].mobs) do
                consumed[mob.npcID] = (consumed[mob.npcID] or 0) + mob.quantity
            end
        end
    end
    return consumed
end

function Tracker:Init()
    initialized = true
end

function Tracker:Reset()
    currentPullIdx = 1
    wipe(pullStates)
    wipe(deadNpcCounts)
    lastCompletedPct = 0

    local plan = PA.RouteReader:GetPlan()
    if plan then
        for i = 1, #plan.pulls do
            pullStates[i] = "pending"
        end
    end
    PA:Debug("Tracker reset, pull 1")
end

function Tracker:GetCurrentPullIndex()
    return currentPullIdx
end

function Tracker:GetNextPull()
    local plan = PA.RouteReader:GetPlan()
    if not plan then return nil end
    return plan.pulls[currentPullIdx]
end

function Tracker:GetPullState(pullIdx)
    return pullStates[pullIdx] or "pending"
end

function Tracker:GetCompletedPullCount()
    local count = 0
    for _, state in pairs(pullStates) do
        if state == "complete" then count = count + 1 end
    end
    return count
end

function Tracker:GetRemainingPulls()
    local plan = PA.RouteReader:GetPlan()
    if not plan then return {} end
    local remaining = {}
    for i = currentPullIdx, #plan.pulls do
        if pullStates[i] ~= "complete" then
            remaining[#remaining + 1] = plan.pulls[i]
        end
    end
    return remaining
end

-- Called when a mob dies (from COMBAT_LOG_EVENT)
function Tracker:OnMobDeath(npcID)
    if not npcID or npcID <= 0 then return end
    deadNpcCounts[npcID] = (deadNpcCounts[npcID] or 0) + 1

    self:EvaluatePulls()
end

-- Called on SCENARIO_CRITERIA_UPDATE
function Tracker:OnScenarioUpdate()
    self:EvaluatePulls()
end

-- Core evaluation: check if any pulls are now complete
function Tracker:EvaluatePulls()
    local plan = PA.RouteReader:GetPlan()
    if not plan or #plan.pulls == 0 then return end

    -- Get current scenario completion
    local completedPct = PA:GetCompletedPercent()

    local changed = false

    -- Strategy 1: Forces-based sequential advancement
    if completedPct > lastCompletedPct then
        lastCompletedPct = completedPct
        for i = 1, #plan.pulls do
            local pull = plan.pulls[i]
            if pullStates[i] ~= "complete" and completedPct >= (pull.cumPercent * COMPLETION_THRESHOLD) then
                pullStates[i] = "complete"
                changed = true
            end
        end
    end

    -- Strategy 2: NPC death tracking with consumed-kill deduction
    -- Rebuild consumed counts from currently-complete pulls so that
    -- kills "used" by earlier pulls don't satisfy later ones.
    local consumed = BuildConsumedCounts(plan)

    for i = 1, #plan.pulls do
        if pullStates[i] ~= "complete" then
            local pull = plan.pulls[i]
            local expectedForces = pull.totalForces
            if expectedForces <= 0 then
                -- Boss pull or zero-forces pull → mark complete if any mob died
                local anyDead = false
                for _, mob in ipairs(pull.mobs) do
                    local totalKilled = deadNpcCounts[mob.npcID] or 0
                    local usedByOthers = consumed[mob.npcID] or 0
                    if (totalKilled - usedByOthers) > 0 then
                        anyDead = true
                        break
                    end
                end
                if anyDead then
                    pullStates[i] = "complete"
                    -- Update consumed so subsequent pulls account for this pull's mobs
                    for _, mob in ipairs(pull.mobs) do
                        consumed[mob.npcID] = (consumed[mob.npcID] or 0) + mob.quantity
                    end
                    changed = true
                end
            else
                local achievedForces = 0
                for _, mob in ipairs(pull.mobs) do
                    local totalKilled = deadNpcCounts[mob.npcID] or 0
                    local usedByOthers = consumed[mob.npcID] or 0
                    local available = math.max(0, totalKilled - usedByOthers)
                    local countForPull = math.min(available, mob.quantity)
                    achievedForces = achievedForces + (countForPull * mob.count)
                end

                if achievedForces >= (expectedForces * COMPLETION_THRESHOLD) then
                    pullStates[i] = "complete"
                    for _, mob in ipairs(pull.mobs) do
                        consumed[mob.npcID] = (consumed[mob.npcID] or 0) + mob.quantity
                    end
                    changed = true
                end
            end
        end
    end

    if changed then
        self:AdvanceCurrentPull()
    end
end

function Tracker:AdvanceCurrentPull()
    local plan = PA.RouteReader:GetPlan()
    if not plan then return end

    local oldIdx = currentPullIdx

    -- Find next pending pull starting from current
    for i = currentPullIdx, #plan.pulls do
        if pullStates[i] ~= "complete" then
            currentPullIdx = i
            if oldIdx ~= currentPullIdx then
                PA:Debug("Advanced to pull", currentPullIdx)
                PA.Display:OnPullAdvanced(currentPullIdx)
                PA.Nameplates:OnTrackingChanged()
            end
            return
        end
    end

    -- All pulls complete
    currentPullIdx = #plan.pulls + 1
    if oldIdx ~= currentPullIdx then
        PA:Debug("All pulls complete!")
        PA.Display:OnAllPullsComplete()
        PA.Nameplates:OnTrackingChanged()
    end
end

-- Set the completion threshold (0.0 - 1.0)
function Tracker:SetThreshold(threshold)
    COMPLETION_THRESHOLD = math.max(0.1, math.min(1.0, threshold))
end

function Tracker:GetThreshold()
    return COMPLETION_THRESHOLD
end

-- Force-set current pull (for manual override)
function Tracker:SetCurrentPull(pullIdx)
    local plan = PA.RouteReader:GetPlan()
    if not plan then return end
    pullIdx = math.max(1, math.min(pullIdx, #plan.pulls))

    -- Mark all pulls before this one as complete
    for i = 1, pullIdx - 1 do
        pullStates[i] = "complete"
    end
    -- Mark this and future pulls as pending
    for i = pullIdx, #plan.pulls do
        pullStates[i] = "pending"
    end

    currentPullIdx = pullIdx
    PA:Debug("Manual set to pull", pullIdx)
    PA.Display:OnPullAdvanced(pullIdx)
    PA.Nameplates:OnTrackingChanged()
end

-- Mark a specific pull as complete and advance (for debug/testing)
function Tracker:CompletePull(pullIdx)
    local plan = PA.RouteReader:GetPlan()
    if not plan then return end
    if pullIdx < 1 or pullIdx > #plan.pulls then return end

    pullStates[pullIdx] = "complete"
    PA:Debug("Manually completed pull", pullIdx)
    self:AdvanceCurrentPull()
end

-- Get per-mob kill progress for a specific pull (consumed-aware)
function Tracker:GetMobKillsForPull(pullIdx)
    local plan = PA.RouteReader:GetPlan()
    if not plan then return nil end
    local pull = plan.pulls[pullIdx]
    if not pull then return nil end

    local consumed = BuildConsumedCounts(plan)
    -- Don't count this pull's own consumption if it's complete
    -- (consumed already includes it, but we want "available before this pull")
    if pullStates[pullIdx] == "complete" then
        for _, mob in ipairs(pull.mobs) do
            consumed[mob.npcID] = math.max(0, (consumed[mob.npcID] or 0) - mob.quantity)
        end
    end

    local result = {}
    for _, mob in ipairs(pull.mobs) do
        local totalKilled = deadNpcCounts[mob.npcID] or 0
        local usedByOthers = consumed[mob.npcID] or 0
        local available = math.max(0, totalKilled - usedByOthers)
        result[mob.npcID] = {
            killed = math.min(available, mob.quantity),
            expected = mob.quantity,
        }
        -- Consume this pull's share so the next mob entry with same npcID is correct
        consumed[mob.npcID] = usedByOthers + mob.quantity
    end
    return result
end

-- Check if a given npcID is in any route pull
function Tracker:IsNpcInRoute(npcID)
    local plan = PA.RouteReader:GetPlan()
    if not plan then return false end
    for _, pull in ipairs(plan.pulls) do
        for _, mob in ipairs(pull.mobs) do
            if mob.npcID == npcID then return true end
        end
    end
    return false
end
