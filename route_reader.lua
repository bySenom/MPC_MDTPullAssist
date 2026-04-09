-- MPC_MDTPullAssist - Route Reader
-- Reads the active MDT route/preset and resolves pulls into
-- an ordered list of { mobs, totalForces, totalPercent }.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local RouteReader = {}
PA.RouteReader = RouteReader

-- Current resolved pull plan
local currentPlan = nil   -- { dungeonIdx, pulls = { [i] = PullInfo }, totalForces, routeUID }
local lastRouteUID = nil

-- PullInfo structure:
-- {
--     index       = <pull number>,
--     mobs        = { { npcID, name, count, quantity } },  -- quantity = how many of this npc
--     totalForces = <sum of forces for this pull>,
--     totalPercent= <totalForces / dungeonTotal * 100>,
--     cumForces   = <cumulative forces through this pull>,
--     cumPercent  = <cumulative percent through this pull>,
-- }

function RouteReader:GetPlan()
    return currentPlan
end

function RouteReader:HasRoute()
    return currentPlan ~= nil and #currentPlan.pulls > 0
end

function RouteReader:GetPullCount()
    if not currentPlan then return 0 end
    return #currentPlan.pulls
end

function RouteReader:GetPull(index)
    if not currentPlan then return nil end
    return currentPlan.pulls[index]
end

-- Read and resolve the current MDT route for a given challengeMapID
function RouteReader:LoadRoute(challengeMapID)
    currentPlan = nil
    lastRouteUID = nil

    if not MDT then return false end

    local dungeonIdx = PA.Mapping:GetMDTIndex(challengeMapID)
    if not dungeonIdx then
        PA:Debug("No MDT dungeon index for challengeMapID", challengeMapID)
        return false
    end

    -- Ensure MDT has enemy data for this dungeon
    local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
    if not enemies then
        PA:Debug("No MDT enemy data for dungeonIdx", dungeonIdx)
        return false
    end

    -- Get the active MDT preset
    local preset = self:GetActivePreset(dungeonIdx)
    if not preset or not preset.value or not preset.value.pulls then
        PA:Debug("No active MDT route found for dungeonIdx", dungeonIdx)
        return false
    end

    local pulls = preset.value.pulls
    local totalCount = PA.Mapping:GetTotalCount(dungeonIdx)
    if totalCount <= 0 then totalCount = 1 end

    local plan = {
        dungeonIdx = dungeonIdx,
        challengeMapID = challengeMapID,
        totalForces = totalCount,
        routeUID = preset.uid or tostring(preset),
        routeName = preset.text or "Unknown Route",
        pulls = {},
    }

    local cumForces = 0

    for pullIdx, pullData in ipairs(pulls) do
        local pullInfo = {
            index = pullIdx,
            mobs = {},
            totalForces = 0,
            totalPercent = 0,
            cumForces = 0,
            cumPercent = 0,
        }

        -- MDT pull format: pullData[enemyIdx] = { cloneIdx1, cloneIdx2, ... }
        local mobAggregation = {}  -- npcID → { npcID, name, count, quantity }

        for enemyIdx, cloneIndices in pairs(pullData) do
            if type(enemyIdx) == "number" and type(cloneIndices) == "table" then
                local enemy = enemies[enemyIdx]
                if enemy and enemy.id then
                    local npcID = enemy.id
                    local cloneCount = #cloneIndices

                    if not mobAggregation[npcID] then
                        mobAggregation[npcID] = {
                            npcID = npcID,
                            enemyIdx = enemyIdx,
                            name = enemy.name or ("NPC " .. npcID),
                            count = enemy.count or 0,
                            quantity = 0,
                            isBoss = enemy.isBoss or false,
                            -- Store clone group IDs for tracking
                            cloneGroups = {},
                        }
                    end

                    mobAggregation[npcID].quantity = mobAggregation[npcID].quantity + cloneCount

                    -- Record which clone groups (g values) are part of this pull
                    for _, cloneIdx in ipairs(cloneIndices) do
                        if enemy.clones and enemy.clones[cloneIdx] then
                            local g = enemy.clones[cloneIdx].g
                            if g then
                                mobAggregation[npcID].cloneGroups[g] = true
                            end
                        end
                    end
                end
            end
        end

        -- Flatten aggregation into sorted mob list
        local pullForces = 0
        for _, mob in pairs(mobAggregation) do
            pullInfo.mobs[#pullInfo.mobs + 1] = mob
            pullForces = pullForces + (mob.count * mob.quantity)
        end

        -- Sort mobs by forces descending, then name
        table.sort(pullInfo.mobs, function(a, b)
            local fa = a.count * a.quantity
            local fb = b.count * b.quantity
            if fa ~= fb then return fa > fb end
            return (a.name or "") < (b.name or "")
        end)

        pullInfo.totalForces = pullForces
        pullInfo.totalPercent = (pullForces / totalCount) * 100
        cumForces = cumForces + pullForces
        pullInfo.cumForces = cumForces
        pullInfo.cumPercent = (cumForces / totalCount) * 100

        plan.pulls[#plan.pulls + 1] = pullInfo
    end

    currentPlan = plan
    lastRouteUID = plan.routeUID
    PA:Debug("Route loaded:", plan.routeName, "-", #plan.pulls, "pulls,", cumForces, "total forces")
    return true
end

-- Get the active MDT preset for a dungeon
function RouteReader:GetActivePreset(dungeonIdx)
    if not MDT then return nil end

    -- Method 1: If MDT has GetDB (standard API)
    if MDT.GetDB then
        local db = MDT:GetDB()
        if db and db.global and db.global.presets and db.global.presets[dungeonIdx] then
            local presetIdx = 1
            if db.global.currentPreset and db.global.currentPreset[dungeonIdx] then
                presetIdx = db.global.currentPreset[dungeonIdx]
            end
            local preset = db.global.presets[dungeonIdx][presetIdx]
            if preset then return preset end
        end
    end

    -- Method 2: Try MDT:GetCurrentPreset() if MDT is showing this dungeon
    if MDT.GetCurrentPreset then
        local preset = MDT:GetCurrentPreset()
        if preset and preset.value and preset.value.currentDungeonIdx == dungeonIdx then
            return preset
        end
    end

    return nil
end

-- Check if the MDT route has changed since last load
function RouteReader:HasRouteChanged(challengeMapID)
    if not MDT or not currentPlan then return true end

    local dungeonIdx = PA.Mapping:GetMDTIndex(challengeMapID)
    if not dungeonIdx then return true end

    local preset = self:GetActivePreset(dungeonIdx)
    if not preset then return lastRouteUID ~= nil end

    local uid = preset.uid or tostring(preset)
    return uid ~= lastRouteUID
end

-- Clear loaded route
function RouteReader:Clear()
    currentPlan = nil
    lastRouteUID = nil
end
