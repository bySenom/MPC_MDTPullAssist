-- MPC_MDTPullAssist - Nameplates
-- Adds visual pull indicators on nameplates for mobs in upcoming MDT route pulls.
-- Multi-strategy mob identification: GUID → nameplate name text → fingerprint (self-learning).
-- Midnight (12.0.1) compatible: name text and fingerprints work when GUIDs are secret.
local ADDON_NAME, NS = ...
local PA = NS.PullAssist

local Nameplates = {}
PA.Nameplates = Nameplates

-- DO NOT read issecretvalue at file scope (causes execution taint).
-- Use the shared isSecretValue() wrapper from core.lua via PA namespace.
local function isSecret(val)
    local fn = rawget(_G, "issecretvalue")
    if fn then return fn(val) end
    return false
end

-- State
local overlays = {}             -- [nameplate frame] = overlay frame
local nameLookup = {}           -- [mobName] = npcID
local npcPullMap = {}           -- [npcID] = { pullIndices sorted }
local modelFrame = nil          -- hidden PlayerModel for fingerprinting
local learnedFingerprints = {}  -- [fingerprint] = npcID
local mpcFingerprints = {}      -- [fingerprint] = npcID (loaded from MythicPlusCountDB)

-- Colors per pull proximity
local PULL_COLORS = {
    current  = { 0.20, 1.00, 0.30, 1.0 },  -- bright green
    upcoming = { 1.00, 0.82, 0.00, 0.9 },  -- yellow (next 1-2)
    future   = { 0.55, 0.55, 0.60, 0.7 },  -- gray (distant)
}

----------------------------------------------------------------
-- Init
----------------------------------------------------------------
function Nameplates:Init()
    self:CreateModelFrame()
    self:RegisterEvents()
end

function Nameplates:CreateModelFrame()
    if modelFrame then return end
    -- PlayerModel must remain shown for SetUnit/GetModelFileID to work.
    -- Hide() and SetAlpha(0) both prevent model loading.
    -- Position offscreen at 1x1 pixel — invisible but functional.
    modelFrame = CreateFrame("PlayerModel", nil, UIParent)
    modelFrame:SetSize(1, 1)
    modelFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
end

----------------------------------------------------------------
-- Lookup tables built from current route plan
----------------------------------------------------------------
function Nameplates:BuildLookups()
    wipe(nameLookup)
    wipe(npcPullMap)

    local plan = PA.RouteReader:GetPlan()
    if not plan then
        PA:Debug("Nameplates: BuildLookups - no plan")
        return
    end

    local npcCount = 0
    for pullIdx, pull in ipairs(plan.pulls) do
        for _, mob in ipairs(pull.mobs) do
            if mob.name then
                nameLookup[mob.name] = mob.npcID
            end
            if mob.npcID then
                if not npcPullMap[mob.npcID] then
                    npcPullMap[mob.npcID] = {}
                    npcCount = npcCount + 1
                end
                -- Avoid duplicate pullIdx entries
                local dominated = false
                for _, existing in ipairs(npcPullMap[mob.npcID]) do
                    if existing == pullIdx then dominated = true; break end
                end
                if not dominated then
                    table.insert(npcPullMap[mob.npcID], pullIdx)
                end
            end
        end
    end
    PA:Debug("Nameplates: BuildLookups -", npcCount, "unique npcIDs,", #plan.pulls, "pulls")

    -- Load fingerprint database for this dungeon.
    -- Priority: MPC saved variable > our embedded defaults
    wipe(mpcFingerprints)
    local challengeMapID = plan.challengeMapID
    local fpLoaded = 0

    -- Source 1: MPC saved variable (user-learned fingerprints, most accurate)
    if challengeMapID and MythicPlusCountDB and MythicPlusCountDB.fingerprints then
        local fpMap = MythicPlusCountDB.fingerprints[challengeMapID]
        if fpMap then
            for fp, npcID in pairs(fpMap) do
                mpcFingerprints[fp] = npcID
                fpLoaded = fpLoaded + 1
            end
        end
    end

    -- Source 2: Our embedded defaults (always available, no MPC dungeon visit required)
    if PA.EmbeddedFingerprints and challengeMapID then
        local embedded = PA.EmbeddedFingerprints[challengeMapID]
        if embedded then
            for fp, npcID in pairs(embedded) do
                -- Don't overwrite user-learned data from MPC
                if not mpcFingerprints[fp] then
                    mpcFingerprints[fp] = npcID
                    fpLoaded = fpLoaded + 1
                end
            end
        end
    end

    PA:Debug("Nameplates: Loaded", fpLoaded, "fingerprints for mapID", challengeMapID)
end

----------------------------------------------------------------
-- Mob identification (multi-strategy, Midnight-safe)
----------------------------------------------------------------
function Nameplates:IdentifyUnit(unit)
    -- Strategy 1: GUID parsing (works outside instances)
    local guid = UnitGUID(unit)
    if guid and not isSecret(guid) then
        local guidType = strsplit("-", guid)
        if guidType == "Creature" or guidType == "Vehicle" then
            local _, _, _, _, _, rawID = strsplit("-", guid)
            local npcID = tonumber(rawID)
            if npcID then
                -- Learn fingerprint while GUID is available
                self:LearnFingerprint(unit, npcID)
                if npcPullMap[npcID] then return npcID end
            end
        end
    end

    -- Strategy 2: UnitName matching against MDT names
    local name = UnitName(unit)
    if name and not isSecret(name) then
        local npcID = nameLookup[name]
        if npcID then return npcID end
    end

    -- Strategy 2b: Read displayed name from nameplate frame UI
    local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
    if nameplate then
        local nameFS = self:FindNameFontString(nameplate)
        if nameFS then
            local ok, text = pcall(nameFS.GetText, nameFS)
            if ok and text and not isSecret(text) then
                local npcID = nameLookup[text]
                if npcID then return npcID end
            end
        end
    end

    -- Strategy 3: MPC fingerprint database (pre-built + user-learned via MythicPlusCount)
    local fp = self:BuildFingerprint(unit)
    if fp then
        -- 3a: Check MPC database (exact match)
        if mpcFingerprints[fp] then
            local npcID = mpcFingerprints[fp]
            PA:Debug("Nameplates: identified via MPC fingerprint:", fp, "→ npcID", npcID)
            return npcID
        end

        -- 3b: Check MPC with extended fingerprint (includes buffCount for disambiguation)
        local extFP = self:BuildExtendedFingerprint(unit, fp)
        if extFP and mpcFingerprints[extFP] then
            local npcID = mpcFingerprints[extFP]
            PA:Debug("Nameplates: identified via MPC extended fingerprint:", extFP, "→ npcID", npcID)
            return npcID
        end

        -- 3c: Self-learned fingerprints (from earlier GUID reads in non-secret zones)
        if learnedFingerprints[fp] then
            return learnedFingerprints[fp]
        end
    end

    return nil
end

-- Locate the name FontString across popular nameplate addons
function Nameplates:FindNameFontString(nameplate)
    -- Plater (lowercase unitFrame)
    if nameplate.unitFrame then
        if nameplate.unitFrame.ActorNameSpecial then
            return nameplate.unitFrame.ActorNameSpecial
        end
        if nameplate.unitFrame.healthBar and nameplate.unitFrame.healthBar.actorName then
            return nameplate.unitFrame.healthBar.actorName
        end
    end
    -- Platynator: iterate children to find display frame with widgets[]
    local platynatorName = self:FindPlatynatorWidget(nameplate, "creatureName")
    if platynatorName and platynatorName.text then
        return platynatorName.text
    end
    -- Blizzard default / ElvUI / others (uppercase UnitFrame)
    if nameplate.UnitFrame and nameplate.UnitFrame.name then
        return nameplate.UnitFrame.name
    end
    return nil
end

-- Find a Platynator widget by details.kind on a nameplate
function Nameplates:FindPlatynatorWidget(nameplate, kind)
    for _, child in pairs({nameplate:GetChildren()}) do
        if child ~= nameplate.UnitFrame and child.widgets then
            for _, w in ipairs(child.widgets) do
                if w.details and w.details.kind == kind then
                    return w
                end
            end
        end
    end
    return nil
end

-- Find the health bar frame for anchoring
function Nameplates:FindHealthBar(nameplate)
    -- Plater
    if nameplate.unitFrame and nameplate.unitFrame.healthBar then
        return nameplate.unitFrame.healthBar
    end
    -- Platynator: health widget → statusBar
    local healthWidget = self:FindPlatynatorWidget(nameplate, "health")
    if healthWidget and healthWidget.statusBar then
        return healthWidget.statusBar
    end
    -- Blizzard default
    if nameplate.UnitFrame and nameplate.UnitFrame.healthBar then
        return nameplate.UnitFrame.healthBar
    end
    return nil
end

----------------------------------------------------------------
-- Fingerprint system (mirrors MPC's approach, self-learning)
----------------------------------------------------------------
function Nameplates:BuildFingerprint(unit)
    if not modelFrame then
        PA:Debug("Nameplates: BuildFingerprint - no modelFrame")
        return nil
    end

    local ok, err = pcall(function()
        modelFrame:ClearModel()
        modelFrame:SetUnit(unit)
    end)
    if not ok then
        PA:Debug("Nameplates: SetUnit failed:", err)
        return nil
    end
    local modelID = modelFrame:GetModelFileID()
    if not modelID or isSecret(modelID) then
        PA:Debug("Nameplates: modelID nil or secret for", UnitName(unit) or "?")
        return nil
    end
    if modelID <= 0 then
        PA:Debug("Nameplates: modelID <= 0 for", UnitName(unit) or "?")
        return nil
    end

    local level = UnitLevel(unit)
    if not level or isSecret(level) then return nil end
    local relLevel = level % 10

    local classification = UnitClassification(unit)
    if not classification or isSecret(classification) then classification = "x" end

    local sex = UnitSex(unit)
    if not sex or isSecret(sex) then sex = 0 end

    local _, classToken = UnitClass(unit)
    if not classToken or isSecret(classToken) then classToken = "x" end

    local powerType = UnitPowerType(unit)
    if not powerType or isSecret(powerType) then powerType = -1 end

    return string.format("%d:%d:%s:%d:%s:%d",
        modelID, relLevel, tostring(classification), sex, tostring(classToken), powerType)
end

function Nameplates:LearnFingerprint(unit, npcID)
    local fp = self:BuildFingerprint(unit)
    if fp and npcID then
        if not learnedFingerprints[fp] then
            learnedFingerprints[fp] = npcID
            PA:Debug("Learned fingerprint for npcID", npcID, "→", fp)
        end
    end
end

-- Extended fingerprint with buffCount for disambiguation (matches MPC's format)
function Nameplates:BuildExtendedFingerprint(unit, baseFP)
    if not baseFP then baseFP = self:BuildFingerprint(unit) end
    if not baseFP then return nil end

    local buffCount = 0
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 20 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if ok and aura then
                buffCount = buffCount + 1
            else
                break
            end
        end
    end
    return baseFP .. ":" .. buffCount
end

----------------------------------------------------------------
-- Pull info resolution for a given npcID
----------------------------------------------------------------
function Nameplates:GetPullInfoForNpc(npcID)
    if not npcID then return nil end
    local pulls = npcPullMap[npcID]
    if not pulls or #pulls == 0 then return nil end

    local currentPullIdx = PA.Tracker:GetCurrentPullIndex()
    local bestPull = nil

    -- Find the earliest non-complete pull containing this mob
    for _, pullIdx in ipairs(pulls) do
        local state = PA.Tracker:GetPullState(pullIdx)
        if state ~= "complete" then
            if not bestPull or pullIdx < bestPull then
                bestPull = pullIdx
            end
        end
    end

    if not bestPull then return nil end

    local pullType
    if bestPull == currentPullIdx then
        pullType = "current"
    elseif bestPull <= currentPullIdx + 2 then
        pullType = "upcoming"
    else
        pullType = "future"
    end

    -- Get forces from npc lookup
    local plan = PA.RouteReader:GetPlan()
    local forces = 0
    if plan then
        local npcData = PA.Mapping:BuildNpcLookup(plan.dungeonIdx)
        if npcData and npcData[npcID] then
            forces = npcData[npcID].count or 0
        end
    end

    return {
        pullIdx  = bestPull,
        pullType = pullType,
        forces   = forces,
    }
end

----------------------------------------------------------------
-- Overlay creation / update / removal
----------------------------------------------------------------
function Nameplates:GetOrCreateOverlay(nameplate)
    if overlays[nameplate] then return overlays[nameplate] end

    local overlay = CreateFrame("Frame", nil, nameplate)
    overlay:SetAllPoints()
    -- Use TOOLTIP strata so overlay is guaranteed above Platynator/Plater frames
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel(10)

    -- Pull text
    overlay.text = overlay:CreateFontString(nil, "OVERLAY")
    overlay.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")

    -- Dark background behind text for readability
    overlay.bg = overlay:CreateTexture(nil, "ARTWORK")
    overlay.bg:SetColorTexture(0, 0, 0, 0.6)
    overlay.bg:SetPoint("TOPLEFT", overlay.text, "TOPLEFT", -3, 2)
    overlay.bg:SetPoint("BOTTOMRIGHT", overlay.text, "BOTTOMRIGHT", 3, -2)

    overlay:Hide()
    overlays[nameplate] = overlay
    return overlay
end

function Nameplates:AnchorOverlay(overlay, nameplate)
    overlay.text:ClearAllPoints()

    local healthBar = self:FindHealthBar(nameplate)
    if healthBar then
        overlay.text:SetPoint("BOTTOM", healthBar, "TOP", 0, 14)
        return
    end
    -- Fallback
    overlay.text:SetPoint("TOP", nameplate, "TOP", 0, 16)
end

function Nameplates:UpdateNameplate(nameplate, unit)
    -- Only process enemy NPCs
    if not UnitCanAttack("player", unit) then return end
    if UnitIsPlayer(unit) then return end
    if UnitIsDead(unit) then
        self:RemoveOverlay(nameplate)
        return
    end

    local settings = PA:GetSettings()
    if settings.nameplatesEnabled == false then
        self:RemoveOverlay(nameplate)
        return
    end
    if not PA.RouteReader:HasRoute() then
        PA:Debug("Nameplates: no route loaded for", UnitName(unit) or "?")
        return
    end

    local npcID = self:IdentifyUnit(unit)
    if not npcID then
        PA:Debug("Nameplates: could not identify", UnitName(unit) or "?", "- GUID:", UnitGUID(unit) or "nil")
        self:RemoveOverlay(nameplate)
        return
    end

    local info = self:GetPullInfoForNpc(npcID)
    if not info then
        PA:Debug("Nameplates: npcID", npcID, "not in any upcoming pull")
        self:RemoveOverlay(nameplate)
        return
    end

    -- Respect visibility settings per pull type
    if settings.nameplatesCurrentOnly and info.pullType ~= "current" then
        self:RemoveOverlay(nameplate)
        return
    end

    local overlay = self:GetOrCreateOverlay(nameplate)
    self:AnchorOverlay(overlay, nameplate)

    local color = PULL_COLORS[info.pullType] or PULL_COLORS.future

    local label
    if info.pullType == "current" then
        label = string.format("► Pull %d", info.pullIdx)
    else
        label = string.format("Pull %d", info.pullIdx)
    end

    if settings.nameplateShowForces ~= false and info.forces > 0 then
        label = label .. string.format(" (%d)", info.forces)
    end

    overlay.text:SetText(label)
    overlay.text:SetTextColor(unpack(color))
    overlay:Show()
end

function Nameplates:RemoveOverlay(nameplate)
    local overlay = overlays[nameplate]
    if overlay then overlay:Hide() end
end

----------------------------------------------------------------
-- Bulk refresh
----------------------------------------------------------------
function Nameplates:RefreshAll()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
            if nameplate then
                self:UpdateNameplate(nameplate, unit)
            end
        end
    end
end

----------------------------------------------------------------
-- Callbacks from other modules
----------------------------------------------------------------
function Nameplates:OnRouteChanged()
    self:BuildLookups()
    self:RefreshAll()
end

function Nameplates:OnTrackingChanged()
    self:RefreshAll()
end

----------------------------------------------------------------
-- Event handling
----------------------------------------------------------------
local npFrame = CreateFrame("Frame")
local refreshTicker = nil

function Nameplates:RegisterEvents()
    npFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    npFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

    npFrame:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
            if nameplate then
                Nameplates:UpdateNameplate(nameplate, unit)
            end
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
            if nameplate then
                Nameplates:RemoveOverlay(nameplate)
            end
        end
    end)

    -- Periodic refresh to catch late fingerprinting / model loading
    refreshTicker = C_Timer.NewTicker(3.0, function()
        if PA.RouteReader:HasRoute() then
            Nameplates:RefreshAll()
        end
    end)
end
