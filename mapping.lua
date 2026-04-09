-- MPC_MDTPullAssist - Mapping
-- Bridges MythicPlusCount challengeMapIDs to MDT dungeonIdx values
-- and builds npcID lookup tables from MDT enemy data.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local Mapping = {}
PA.Mapping = Mapping

-- Static mapping: MPC challengeMapID → MDT dungeonIdx
-- Midnight Season 1 (12.0.1)
local CHALLENGE_TO_MDT = {
    [556] = 150,   -- Pit of Saron
    [161] = 151,   -- Skyreach
    [557] = 152,   -- Windrunner Spire
    [558] = 153,   -- Magisters' Terrace
    [560] = 154,   -- Maisara Caverns
    [559] = 155,   -- Nexus-Point Xenas
    [402] = 45,    -- Algeth'ar Academy
    [239] = 11,    -- Seat of the Triumvirate
}

local MDT_TO_CHALLENGE = {}
for cmap, mdt in pairs(CHALLENGE_TO_MDT) do
    MDT_TO_CHALLENGE[mdt] = cmap
end

function Mapping:GetMDTIndex(challengeMapID)
    return CHALLENGE_TO_MDT[challengeMapID]
end

function Mapping:GetChallengeMapID(mdtDungeonIdx)
    return MDT_TO_CHALLENGE[mdtDungeonIdx]
end

-- Build a lookup: npcID → { enemyIdx, name, count, clones }
-- from MDT.dungeonEnemies for a given dungeon
local npcCache = {}

function Mapping:BuildNpcLookup(dungeonIdx)
    if npcCache[dungeonIdx] then return npcCache[dungeonIdx] end

    local enemies = MDT and MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
    if not enemies then return nil end

    local lookup = {}
    for enemyIdx, enemy in pairs(enemies) do
        if enemy.id and enemy.id > 0 then
            lookup[enemy.id] = {
                enemyIdx = enemyIdx,
                name = enemy.name or ("NPC " .. enemy.id),
                count = enemy.count or 0,
                clones = enemy.clones or {},
                isBoss = enemy.isBoss or false,
            }
        end
    end

    npcCache[dungeonIdx] = lookup
    return lookup
end

-- Reverse lookup: enemyIdx → npcID
function Mapping:GetNpcIDForEnemy(dungeonIdx, enemyIdx)
    local enemies = MDT and MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
    if not enemies or not enemies[enemyIdx] then return nil end
    return enemies[enemyIdx].id
end

-- Get total forces for a dungeon from MDT
function Mapping:GetTotalCount(dungeonIdx)
    if MDT and MDT.dungeonTotalCount and MDT.dungeonTotalCount[dungeonIdx] then
        return MDT.dungeonTotalCount[dungeonIdx].normal or 0
    end
    return 0
end

-- Clear cache (called on route reload)
function Mapping:ClearCache()
    wipe(npcCache)
end

-- Dungeon name aliases for /mdtpa load <name>
local DUNGEON_ALIASES = {
    ["pit"]         = 556, ["pitsaron"]     = 556, ["pos"]       = 556,
    ["skyreach"]    = 161, ["sky"]          = 161, ["sr"]        = 161,
    ["windrunner"]  = 557, ["spire"]        = 557, ["ws"]        = 557,
    ["magisters"]   = 558, ["mt"]           = 558, ["terrace"]   = 558,
    ["maisara"]     = 560, ["caverns"]      = 560, ["mc"]        = 560,
    ["nexus"]       = 559, ["xenas"]        = 559, ["npx"]       = 559,
    ["algeth"]      = 402, ["academy"]      = 402, ["aa"]        = 402,
    ["seat"]        = 239, ["triumvirate"]  = 239, ["sott"]      = 239,
}

-- Reverse: challengeMapID → short display name
local DUNGEON_NAMES = {
    [556] = "Pit of Saron",
    [161] = "Skyreach",
    [557] = "Windrunner Spire",
    [558] = "Magisters' Terrace",
    [560] = "Maisara Caverns",
    [559] = "Nexus-Point Xenas",
    [402] = "Algeth'ar Academy",
    [239] = "Seat of the Triumvirate",
}

function Mapping:ResolveDungeonAlias(input)
    if not input then return nil end
    local key = input:lower():gsub("%s+", "")
    -- Try alias first
    if DUNGEON_ALIASES[key] then return DUNGEON_ALIASES[key] end
    -- Try numeric challengeMapID
    local num = tonumber(input)
    if num and CHALLENGE_TO_MDT[num] then return num end
    -- Try partial match
    for alias, mapID in pairs(DUNGEON_ALIASES) do
        if alias:find(key, 1, true) then return mapID end
    end
    return nil
end

function Mapping:GetDungeonName(challengeMapID)
    return DUNGEON_NAMES[challengeMapID] or ("MapID " .. tostring(challengeMapID))
end

function Mapping:GetAllDungeonNames()
    return DUNGEON_NAMES
end

-- Check if both addons are available
function Mapping:IsReady()
    return MDT ~= nil and MDT.dungeonEnemies ~= nil
end
