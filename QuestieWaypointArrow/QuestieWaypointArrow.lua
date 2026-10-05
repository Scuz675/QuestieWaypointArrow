-- Questie Waypoint Arrow - standalone companion addon for Questie-335 / WotLK 3.3.5a.
-- Questie itself is never modified: this addon reads Questie's live quest/map data.

local ADDON_NAME = ...
---@class QuestieWaypointArrow
local QWA = {}
QWA.isStandalone = true
_G.QuestieWaypointArrow = QWA
local eventFrame = CreateFrame("Frame", "QuestieWaypointArrowStandaloneDriver", UIParent)

local math_abs = math.abs
local math_floor = math.floor
local math_pi = math.pi
local math_rad = math.rad
local pairs = pairs
local rawget = rawget
local tonumber = tonumber
local tostring = tostring
local type = type

-- WoW 3.3.5 exposes a global atan2 that returns degrees. Keep a fallback in case
-- another client shim is used.
local atan2 = atan2 or function(x, y)
    if math.atan2 then
        return math.deg(math.atan2(x, y))
    end
    return math.deg(math.atan(x / y))
end

local QuestieMap
local QuestiePlayer
local QuestieDB
local QuestieLib
local ZoneDB
local HBD
local HBDPins
local QuestieTracker
local TrackerBaseFrame
local LevelingAdvisor
local AvailableQuests

local arrowFrame
local target
local targetRefresh = 0
local updateThrottle = 0
local modulesReady = false
local trackerWasVisible = false
local SlashHandler
local ClearTrail
local ClearMinimapTrail
local ClearWorldMapTrail

local trailDots = {}
local trailVisible = false
local trailNextRefresh = 0
local trailLastTargetKey = nil
local trailLastPlayerX = nil
local trailLastPlayerY = nil
local TRAIL_REF = {}

local worldTrailDots = {}
local worldTrailVisible = false
local worldTrailNextRefresh = 0
local worldTrailLastTargetKey = nil
local worldTrailLastPlayerX = nil
local worldTrailLastPlayerY = nil
local worldTrailLastMapID = nil
local worldTrailLastReason = "not-updated"
local WORLD_TRAIL_REF = {}
local worldMapTrailDriver
local worldMapDriverElapsed = 0
local lastPickupScan = {recommended = 0, optional = 0, skip = 0, sweep = 0, outOfRange = 0, attempted = 0, candidates = 0, cacheCandidates = 0, frameCandidates = 0, directCandidates = 0, miniFrames = 0, worldFrames = 0}
local lastRouteDecision = "not-evaluated"

-- Smart route tiers. These deliberately stay separate from the pickup-range slider:
-- that slider is a hard cap only for NEW quest pickups. Completed hand-ins and
-- active objectives remain routable at any distance.
local SMART_NEARBY_TURNIN_RANGE = 350
local SMART_LOCAL_OBJECTIVE_RANGE = 700
local SMART_OBJECTIVE_SAVINGS = 250

local ADDON_PATH = "Interface\\AddOns\\" .. ADDON_NAME .. "\\"
local ARROW_TEXTURE = ADDON_PATH .. "Icons\\arrow.tga"
local TRAIL_TEXTURE = ADDON_PATH .. "Icons\\route.tga"

local defaults = {
    enabled = true,
    trackedOnly = true,
    includeAvailable = true,
    smartLeveling = true,
    smartPickupRange = 650,
    showDistance = true,
    trailEnabled = true,
    worldMapTrailEnabled = true,
    trailDotSize = 7,
    worldMapTrailDotSize = 8,
    trailSpacing = 35,
    locked = false,
    scale = 1.2,
    refresh = 1.0,
    position = {"CENTER", 0, -100},
    migratedFromEmbedded = false,
}

local embeddedKeyMap = {
    waypointArrowEnabled = "enabled",
    waypointArrowTrackedOnly = "trackedOnly",
    waypointArrowIncludeAvailable = "includeAvailable",
    waypointArrowShowDistance = "showDistance",
    waypointArrowLocked = "locked",
    waypointArrowScale = "scale",
    waypointArrowRefresh = "refresh",
    waypointArrowPosition = "position",
}

local function CopyTable(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for k, v in pairs(value) do
        copy[k] = CopyTable(v)
    end
    return copy
end

local function EnsureDB()
    local db = _G.QuestieWaypointArrowDB
    if type(db) ~= "table" then
        db = {}
        _G.QuestieWaypointArrowDB = db
    end

    for key, value in pairs(defaults) do
        if rawget(db, key) == nil then
            db[key] = CopyTable(value)
        end
    end

    -- One-time migration from the embedded Questie port. This lets a player
    -- switch back to an untouched/upstream Questie without losing arrow setup.
    if not db.migratedFromEmbedded and Questie and Questie.db and Questie.db.profile then
        local embedded = rawget(Questie.db.profile, "waypointArrow")
        if type(embedded) == "table" then
            for key in pairs(defaults) do
                if key ~= "migratedFromEmbedded" then
                    local value = rawget(embedded, key)
                    if value ~= nil then
                        db[key] = CopyTable(value)
                    end
                end
            end
        end

        -- Also recognise the older flat embedded keys from the earliest port.
        for oldKey, newKey in pairs(embeddedKeyMap) do
            local value = rawget(Questie.db.profile, oldKey)
            if value ~= nil then
                db[newKey] = CopyTable(value)
            end
        end
        db.migratedFromEmbedded = true
    end

    return db
end

-- Server-neutral leveling advisor. This deliberately uses only the destination
-- server's existing Questie database and normal WotLK quest levels. It does not
-- import Triumvirate XP multipliers, scaled level rules, manual skips, or custom
-- quest metadata.
LevelingAdvisor = {}

local LEVELING_LABELS = {
    recommended = "Recommended",
    optional = "Optional",
    skip = "Low priority",
}

local function QueryQuestValue(questId, key)
    if not (QuestieDB and QuestieDB.QueryQuestSingle) then
        return nil
    end
    local ok, value = pcall(QuestieDB.QueryQuestSingle, questId, key)
    if ok then
        return value
    end
    return nil
end

local function HasTableEntries(value)
    return type(value) == "table" and next(value) ~= nil
end

local function HasUsefulChainValue(questId)
    local nextQuest = tonumber(QueryQuestValue(questId, "nextQuestInChain")) or 0
    if nextQuest > 0 then
        return true
    end
    if HasTableEntries(QueryQuestValue(questId, "childQuests")) then
        return true
    end
    if HasTableEntries(QueryQuestValue(questId, "preQuestSingle")) or HasTableEntries(QueryQuestValue(questId, "preQuestGroup")) then
        return true
    end
    local parentQuest = tonumber(QueryQuestValue(questId, "parentQuest")) or 0
    if parentQuest > 0 then
        return true
    end
    local breadcrumbFor = tonumber(QueryQuestValue(questId, "breadcrumbForQuestId")) or 0
    return breadcrumbFor > 0
end

local function GetPlayerLevelForAdvisor()
    if QuestiePlayer and QuestiePlayer.GetPlayerLevel then
        local ok, level = pcall(QuestiePlayer.GetPlayerLevel, QuestiePlayer)
        if ok and tonumber(level) then
            return tonumber(level)
        end
        ok, level = pcall(QuestiePlayer.GetPlayerLevel)
        if ok and tonumber(level) then
            return tonumber(level)
        end
    end
    return UnitLevel("player") or 1
end

local function IsDungeonQuestForAdvisor(questId)
    return QuestieDB and QuestieDB.IsDungeonQuest and QuestieDB.IsDungeonQuest(questId) or false
end

function LevelingAdvisor:IsActive()
    local db = EnsureDB()
    return db and db.enabled and db.smartLeveling and true or false
end

function LevelingAdvisor:ShouldOptimizeArrow()
    return self:IsActive()
end

function LevelingAdvisor:GetRecommendation(questId, targetType)
    if not self:IsActive() then
        return nil
    end

    questId = tonumber(questId)
    if not questId then
        return nil
    end

    local playerLevel = GetPlayerLevelForAdvisor()
    local questLevel = tonumber(QueryQuestValue(questId, "questLevel"))
    if not questLevel or questLevel == 0 then
        questLevel = playerLevel
    elseif questLevel == -1 then
        -- Scaling quests should behave as level-appropriate.
        questLevel = playerLevel
    end

    local levelDiff = questLevel - playerLevel
    local isTrivial = QuestieDB and QuestieDB.IsTrivial and QuestieDB.IsTrivial(questLevel) or false
    local dungeon = IsDungeonQuestForAdvisor(questId)
    local hasChain = HasUsefulChainValue(questId)
    local key
    local reason

    if targetType == "turnin" or targetType == "complete" then
        key = "recommended"
        reason = "ready to turn in"
    elseif dungeon then
        key = "optional"
        reason = "dungeon quest"
    elseif levelDiff >= 5 then
        key = "optional"
        reason = "red quest"
    elseif isTrivial then
        key = "skip"
        reason = "grey quest"
    elseif levelDiff >= 3 then
        key = "recommended"
        reason = "orange quest"
    elseif levelDiff >= -2 then
        key = "recommended"
        reason = "yellow quest"
    else
        key = "recommended"
        reason = "green quest"
    end

    -- Chain continuations are especially useful while leveling. Do not turn a
    -- grey quest into a primary route target, but remember the chain value for
    -- tie-breaking and diagnostics.
    return {
        key = key,
        label = LEVELING_LABELS[key],
        questLevel = questLevel,
        levelDiff = levelDiff,
        hasChain = hasChain,
        isDungeon = dungeon,
        reason = reason,
        routeBlocked = (targetType == "available" and key == "skip") and true or false,
    }
end

function LevelingAdvisor:GetArrowScore(candidate)
    if not candidate then
        return -999999
    end

    local rec = self:GetRecommendation(candidate.questId, candidate.targetType)
    local distance = tonumber(candidate.distance) or 999999
    if not rec then
        return -distance, nil
    end

    local score
    if rec.key == "recommended" then
        score = 12000
    elseif rec.key == "optional" then
        score = 6000
    else
        score = -12000
    end

    if candidate.targetType == "turnin" then
        score = score + 4000
    elseif candidate.targetType == "available" then
        score = score + 700
        if rec.key == "recommended" then
            if distance <= 350 then
                score = score + 1800
            elseif distance <= 700 then
                score = score + 1200
            elseif distance <= 1200 then
                score = score + 500
            end
        end
    elseif candidate.targetType == "objective" then
        score = score + 1000
        if rec.isDungeon then
            score = score - 1500
        end
    end

    local currentZone = QuestiePlayer and QuestiePlayer.GetCurrentZoneId and QuestiePlayer:GetCurrentZoneId()
    if currentZone and candidate.zone == currentZone then
        score = score + 600
    end
    if rec.hasChain then
        score = score + 350
    end

    score = score - math.min(distance, 12000)
    return score, rec
end

function LevelingAdvisor:GetPickupRange()
    local db = EnsureDB()
    local pickupRange = tonumber(db and db.smartPickupRange) or 650
    if pickupRange < 200 then pickupRange = 200 end
    if pickupRange > 1200 then pickupRange = 1200 end
    if db then db.smartPickupRange = pickupRange end
    return pickupRange
end

function LevelingAdvisor:IsPickupWithinRange(candidate)
    if not candidate or candidate.targetType ~= "available" then
        return true
    end
    return (tonumber(candidate.distance) or 999999999) <= self:GetPickupRange()
end

function LevelingAdvisor:GetPickupSweepPriority(candidate)
    if not candidate or candidate.targetType ~= "available" then
        return nil, nil
    end

    local rec = self:GetRecommendation(candidate.questId, "available")
    if not rec or rec.key == "skip" then
        return nil, rec
    end

    local pickupRange = self:GetPickupRange()
    local distance = tonumber(candidate.distance) or 999999999

    -- Smart pickup range is a hard cap for available-quest suggestions. Normal
    -- quests inside the cap may be collected before a longer objective run.
    -- Dungeon/red quests remain lower priority and only steal the route when
    -- they are essentially on the player's doorstep.
    if rec.key == "recommended" and distance <= pickupRange then
        local priority = 2
        if rec.hasChain then priority = priority + 0.25 end
        if rec.levelDiff >= -2 and rec.levelDiff <= 4 then priority = priority + 0.10 end
        return priority, rec
    end
    if rec.key == "optional" and distance <= math.min(120, pickupRange) then
        return 1, rec
    end

    return nil, rec
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Questie Waypoint:|r " .. tostring(message))
end

local function TryLib(name)
    if not LibStub then
        return nil
    end

    return LibStub(name, true)
end

local function ImportQuestieModules()
    if modulesReady then
        return true
    end

    if not QuestieLoader then
        return false
    end

    QuestieMap = QuestieLoader:ImportModule("QuestieMap")
    QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
    QuestieDB = QuestieLoader:ImportModule("QuestieDB")
    QuestieLib = QuestieLoader:ImportModule("QuestieLib")
    ZoneDB = QuestieLoader:ImportModule("ZoneDB")
    QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
    TrackerBaseFrame = QuestieLoader:ImportModule("TrackerBaseFrame")
    AvailableQuests = QuestieLoader:ImportModule("AvailableQuests")
    HBD = (QuestieCompat and QuestieCompat.HBD) or TryLib("HereBeDragonsQuestie-2.0") or TryLib("HereBeDragons-2.0")
    HBDPins = (QuestieCompat and QuestieCompat.HBDPins) or TryLib("HereBeDragonsQuestie-Pins-2.0") or TryLib("HereBeDragons-Pins-2.0")

    modulesReady = QuestieMap and QuestiePlayer and QuestieDB and QuestieLib and ZoneDB and HBD and QuestieTracker and TrackerBaseFrame
    return modulesReady
end

local function IsTrackerVisibleAndExpanded()
    if not (Questie and Questie.db and Questie.db.profile and Questie.db.char) then
        return false
    end

    -- The waypoint arrow is part of the tracker experience. Mirror the tracker
    -- instead of behaving as a separate HUD element:
    --   * disabled tracker -> hidden arrow
    --   * collapsed tracker -> hidden arrow
    --   * tracker hidden by combat/dungeon/options -> hidden arrow
    --   * tracker with no visible base frame -> hidden arrow
    if not Questie.db.profile.trackerEnabled then
        return false
    end

    if not Questie.db.char.isTrackerExpanded then
        return false
    end

    if QuestieTracker and QuestieTracker.disableHooks == true then
        return false
    end

    local baseFrame = (TrackerBaseFrame and TrackerBaseFrame.baseFrame) or _G.Questie_BaseFrame
    return baseFrame and baseFrame:IsShown() and true or false
end


local function IsSmartLevelingAutopilotEligible()
    local db = EnsureDB()
    if not (db and db.includeAvailable and Questie and Questie.db and Questie.db.profile and Questie.db.char) then
        return false
    end
    if not Questie.db.profile.trackerEnabled or not Questie.db.char.isTrackerExpanded then
        return false
    end
    if QuestieTracker and QuestieTracker.disableHooks == true then
        return false
    end
    if WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown() then
        return false
    end
    return LevelingAdvisor and LevelingAdvisor.IsActive and LevelingAdvisor:IsActive()
end

function QWA:IsTrackerVisible()
    if not ImportQuestieModules() then
        return false
    end

    return IsTrackerVisibleAndExpanded()
end

function QWA:OnTrackerStateChanged(forceTarget)
    local db = EnsureDB()
    if (not db) or (not arrowFrame) then
        return false
    end

    local shouldShow = db.enabled
        and Questie
        and Questie.started
        and ImportQuestieModules()
        and (IsTrackerVisibleAndExpanded() or IsSmartLevelingAutopilotEligible())

    if not shouldShow then
        trackerWasVisible = false
        arrowFrame.content:Hide()
        if ClearMinimapTrail then ClearMinimapTrail() end

        -- Opening the full world map commonly hides Questie's tracker frame.
        -- Keep the world-map route alive in that case even though the HUD arrow
        -- itself is hidden.
        local keepWorldMapTrail = db.worldMapTrailEnabled
            and WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown()
        if (not keepWorldMapTrail) and ClearWorldMapTrail then
            ClearWorldMapTrail()
        end
        return false
    end

    arrowFrame:Show()
    if forceTarget or not trackerWasVisible then
        targetRefresh = 0
    end
    trackerWasVisible = true
    return true
end

local function Modulo(value, by)
    return value - math_floor(value / by) * by
end

local function Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function GetDirectionColor(percent)
    percent = Clamp(percent or 0, 0, 1)
    if percent <= 0.5 then
        return 1, percent * 2, 0
    end

    return (1 - percent) * 2, 1, 0
end

local function IsQuestTracked(questId)
    if not Questie or not Questie.db then
        return false
    end

    if Questie.db.profile and Questie.db.profile.autoTrackQuests then
        return not (Questie.db.char and Questie.db.char.AutoUntrackedQuests and Questie.db.char.AutoUntrackedQuests[questId])
    end

    return Questie.db.char and Questie.db.char.TrackedQuests and Questie.db.char.TrackedQuests[questId]
end

local function FormatDistance(distance)
    distance = tonumber(distance) or 0
    if distance >= 1000 then
        return string.format("%.1fk yd", distance / 1000)
    end

    return tostring(math_floor(distance + 0.5)) .. " yd"
end

local function GetQuestName(quest, questId)
    if quest and quest.name then
        return quest.name
    end

    local dbName = QuestieDB and QuestieDB.QueryQuestSingle and QuestieDB.QueryQuestSingle(questId, "name")
    return dbName or ("Quest " .. tostring(questId))
end

local function GetTargetTexture(iconType)
    if Questie and Questie.usedIcons and iconType and Questie.usedIcons[iconType] then
        return Questie.usedIcons[iconType]
    end

    return ADDON_PATH .. "Icons\\node.tga"
end

local function GetWorldCoordinates(areaId, x, y)
    if (not areaId) or (not x) or (not y) then
        return nil, nil, nil, nil
    end

    local uiMapId = ZoneDB and ZoneDB.GetUiMapIdByAreaId and ZoneDB:GetUiMapIdByAreaId(areaId)
    if uiMapId and HBD and HBD.GetWorldCoordinatesFromZone then
        local worldX, worldY, instance = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
        return worldX, worldY, instance, uiMapId
    end

    return nil, nil, nil, uiMapId
end

local function GetWorldDistance(worldX, worldY, instance, fallbackDistance)
    if not HBD then
        return fallbackDistance
    end

    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
    if (not playerX) or (not playerY) or (not worldX) or (not worldY) then
        return fallbackDistance
    end

    local distance = HBD:GetWorldDistance(instance or playerInstance, playerX, playerY, worldX, worldY)
    if distance and instance and playerInstance and instance ~= playerInstance then
        -- Keep cross-instance/continent targets below valid nearby targets but still
        -- deterministic if no same-instance target exists.
        distance = 500000 + (distance * 100)
    end

    return distance or fallbackDistance
end


local function GetTrailTargetKey(trailTarget)
    if not trailTarget then
        return nil
    end

    return tostring(trailTarget.questId or "") .. ":" .. tostring(trailTarget.targetType or "") .. ":"
        .. string.format("%.2f", tonumber(trailTarget.worldX) or 0) .. ":"
        .. string.format("%.2f", tonumber(trailTarget.worldY) or 0)
end

local function CreateTrailDot(index)
    local dot = trailDots[index]
    if dot then
        return dot
    end

    dot = CreateFrame("Frame", "QuestieWaypointTrailDot" .. tostring(index), UIParent)
    dot:SetWidth(7)
    dot:SetHeight(7)
    dot:EnableMouse(false)

    dot.texture = dot:CreateTexture(nil, "OVERLAY")
    dot.texture:SetAllPoints(dot)
    dot.texture:SetTexture(TRAIL_TEXTURE)
    dot.texture:SetBlendMode("BLEND")
    dot.texture:SetVertexColor(1, 0.82, 0.2, 0.8)
    dot:Hide()

    trailDots[index] = dot
    return dot
end

ClearMinimapTrail = function()
    if HBDPins and HBDPins.RemoveAllMinimapIcons and trailVisible then
        HBDPins:RemoveAllMinimapIcons(TRAIL_REF)
    else
        for _, dot in pairs(trailDots) do
            dot:Hide()
        end
    end

    trailVisible = false
    trailNextRefresh = 0
    trailLastTargetKey = nil
    trailLastPlayerX = nil
    trailLastPlayerY = nil
end

local function CreateWorldTrailDot(index)
    local dot = worldTrailDots[index]
    if dot then
        return dot
    end

    -- World-map trail dots are positioned directly on WorldMapButton rather than
    -- going through the HBD world-pin registry. Questie's 3.3.5 compatibility
    -- layer already gives us reliable local map coordinates; direct anchoring is
    -- both simpler and avoids a legacy pin-layout edge case that could leave the
    -- trail registered but invisible.
    dot = CreateFrame("Frame", "QuestieWaypointWorldTrailDot" .. tostring(index), UIParent)
    dot:SetWidth(8)
    dot:SetHeight(8)
    dot:EnableMouse(false)

    dot.texture = dot:CreateTexture(nil, "OVERLAY")
    dot.texture:SetAllPoints(dot)
    dot.texture:SetTexture(TRAIL_TEXTURE)
    dot.texture:SetBlendMode("BLEND")
    dot.texture:SetVertexColor(1, 0.82, 0.2, 0.85)
    dot:Hide()

    worldTrailDots[index] = dot
    return dot
end

ClearWorldMapTrail = function()
    -- Remove any pins left behind by the v5/v6 HBD implementation, then hide the
    -- direct world-map frames used by v7+.
    if HBDPins and HBDPins.RemoveAllWorldMapIcons then
        HBDPins:RemoveAllWorldMapIcons(WORLD_TRAIL_REF)
    end
    for _, dot in pairs(worldTrailDots) do
        dot:Hide()
        dot:ClearAllPoints()
    end

    worldTrailVisible = false
    worldTrailNextRefresh = 0
    worldTrailLastTargetKey = nil
    worldTrailLastPlayerX = nil
    worldTrailLastPlayerY = nil
    worldTrailLastMapID = nil
end

ClearTrail = function()
    ClearMinimapTrail()
    ClearWorldMapTrail()
end

local function UpdateMinimapTrail(playerX, playerY, playerInstance, trailTarget)
    local db = EnsureDB()
    if (not db) or (not db.enabled) or (not db.trailEnabled) or (not HBDPins) or (not HBD)
        or (not trailTarget) or (not playerX) or (not playerY) or (not playerInstance)
        or (not trailTarget.worldX) or (not trailTarget.worldY) then
        ClearMinimapTrail()
        return
    end

    if trailTarget.instance and trailTarget.instance ~= playerInstance then
        ClearMinimapTrail()
        return
    end

    local now = GetTime and GetTime() or 0
    local targetKey = GetTrailTargetKey(trailTarget)
    local moved = 999999
    if trailLastPlayerX and trailLastPlayerY then
        moved = HBD:GetWorldDistance(playerInstance, trailLastPlayerX, trailLastPlayerY, playerX, playerY) or moved
    end

    if targetKey == trailLastTargetKey and now < trailNextRefresh and moved < 15 then
        return
    end

    trailNextRefresh = now + 0.60
    trailLastTargetKey = targetKey
    trailLastPlayerX = playerX
    trailLastPlayerY = playerY

    local distance, deltaX, deltaY = HBD:GetWorldDistance(playerInstance, playerX, playerY, trailTarget.worldX, trailTarget.worldY)
    if (not distance) or distance < 8 then
        ClearMinimapTrail()
        return
    end

    local spacing = Clamp(tonumber(db.trailSpacing) or 35, 20, 80)
    local dotSize = Clamp(tonumber(db.trailDotSize) or 7, 4, 14)
    db.trailSpacing = spacing
    db.trailDotSize = dotSize

    -- Questie's 3.3.5 HBD minimap pin layer only processes pins within roughly
    -- 500 yards. Twelve forward breadcrumbs at 20-80 yd spacing therefore fill
    -- the useful minimap range without creating an excessive number of frames.
    local maxDots = 12
    local dotCount = math.ceil(distance / spacing)
    if dotCount < 1 then dotCount = 1 end
    if dotCount > maxDots then dotCount = maxDots end

    for index = 1, dotCount do
        local stepDistance = index * spacing
        if stepDistance > distance then
            stepDistance = distance
        end
        local ratio = stepDistance / distance
        local worldX = playerX + (deltaX * ratio)
        local worldY = playerY + (deltaY * ratio)
        local dot = CreateTrailDot(index)

        dot:SetWidth(dotSize)
        dot:SetHeight(dotSize)
        local progress = index / dotCount
        dot.texture:SetVertexColor(1, 0.82, 0.2, 0.45 + (0.45 * progress))
        HBDPins:AddMinimapIconWorld(TRAIL_REF, dot, playerInstance, worldX, worldY, false)
    end

    for index = dotCount + 1, #trailDots do
        if HBDPins.RemoveMinimapIcon then
            HBDPins:RemoveMinimapIcon(TRAIL_REF, trailDots[index])
        else
            trailDots[index]:Hide()
        end
    end

    trailVisible = dotCount > 0
end

local function UpdateWorldMapTrail(playerX, playerY, playerInstance, trailTarget)
    local db = EnsureDB()
    local mapVisible = (WorldMapFrame and WorldMapFrame.IsVisible and WorldMapFrame:IsVisible())
        or (WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown())
        or (WorldMapButton and WorldMapButton.IsVisible and WorldMapButton:IsVisible())

    if (not db) or (not db.enabled) or (not db.worldMapTrailEnabled) or (not HBD)
        or (not trailTarget) or (not trailTarget.worldX) or (not trailTarget.worldY)
        or (not mapVisible) or (not WorldMapButton) then
        if not db or not db.enabled then
            worldTrailLastReason = "addon-disabled"
        elseif db and not db.worldMapTrailEnabled then
            worldTrailLastReason = "trail-disabled"
        elseif not trailTarget then
            worldTrailLastReason = "no-target"
        elseif not mapVisible then
            worldTrailLastReason = "map-not-visible"
        elseif not WorldMapButton then
            worldTrailLastReason = "no-worldmap-button"
        else
            worldTrailLastReason = "missing-world-target"
        end
        ClearWorldMapTrail()
        return
    end

    if playerInstance and trailTarget.instance and trailTarget.instance ~= playerInstance then
        worldTrailLastReason = "different-instance"
        ClearWorldMapTrail()
        return
    end

    local uiMapID
    if QuestieCompat and QuestieCompat.GetCurrentUiMapID then
        uiMapID = QuestieCompat.GetCurrentUiMapID()
    elseif WorldMapFrame.GetMapID then
        uiMapID = WorldMapFrame:GetMapID()
    end
    if not uiMapID then
        worldTrailLastReason = "no-current-map"
        ClearWorldMapTrail()
        return
    end

    -- On the 3.3.5 world map the most reliable coordinates are the coordinates
    -- already owned by the displayed map itself. v5-v7 routed both ends back
    -- through world-space conversion, which can fail while the fullscreen map
    -- has changed the client's map context even when both are on the same UiMapID.
    local playerMapX, playerMapY
    if GetPlayerMapPosition then
        local px, py = GetPlayerMapPosition("player")
        if px and py and (px > 0 or py > 0) then
            playerMapX, playerMapY = px, py
        end
    end

    local targetMapX, targetMapY
    if trailTarget.uiMapId == uiMapID and trailTarget.x and trailTarget.y then
        local tx = tonumber(trailTarget.x)
        local ty = tonumber(trailTarget.y)
        if tx and ty then
            targetMapX, targetMapY = tx / 100, ty / 100
        end
    end

    -- Fallback for maps/targets where direct displayed-map coordinates are not
    -- available. allowOutOfBounds=true avoids edge rounding suppressing a valid
    -- point; explicit bounds checks below still prevent cross-map lines.
    if (not playerMapX or not playerMapY) and playerX and playerY then
        playerMapX, playerMapY = HBD:GetZoneCoordinatesFromWorld(playerX, playerY, uiMapID, true)
    end
    if (not targetMapX or not targetMapY) then
        targetMapX, targetMapY = HBD:GetZoneCoordinatesFromWorld(trailTarget.worldX, trailTarget.worldY, uiMapID, true)
    end

    if (not playerMapX) or (not playerMapY) then
        worldTrailLastReason = "no-player-map-coordinates"
        ClearWorldMapTrail()
        return
    end
    if (not targetMapX) or (not targetMapY) then
        worldTrailLastReason = "no-target-map-coordinates"
        ClearWorldMapTrail()
        return
    end

    if playerMapX < -0.02 or playerMapX > 1.02 or playerMapY < -0.02 or playerMapY > 1.02 then
        worldTrailLastReason = "player-outside-map"
        ClearWorldMapTrail()
        return
    end
    if targetMapX < -0.02 or targetMapX > 1.02 or targetMapY < -0.02 or targetMapY > 1.02 then
        worldTrailLastReason = "target-outside-map"
        ClearWorldMapTrail()
        return
    end

    local mapWidth = WorldMapButton:GetWidth()
    local mapHeight = WorldMapButton:GetHeight()
    if (not mapWidth) or (not mapHeight) or mapWidth <= 1 or mapHeight <= 1 then
        worldTrailLastReason = "invalid-map-size"
        ClearWorldMapTrail()
        return
    end

    local now = GetTime and GetTime() or 0
    local targetKey = GetTrailTargetKey(trailTarget)
    local moved = 999999
    if playerX and playerY and playerInstance and worldTrailLastPlayerX and worldTrailLastPlayerY then
        moved = HBD:GetWorldDistance(playerInstance, worldTrailLastPlayerX, worldTrailLastPlayerY, playerX, playerY) or moved
    end

    if targetKey == worldTrailLastTargetKey and uiMapID == worldTrailLastMapID
        and now < worldTrailNextRefresh and moved < 15 then
        return
    end

    worldTrailNextRefresh = now + 0.25
    worldTrailLastTargetKey = targetKey
    worldTrailLastPlayerX = playerX
    worldTrailLastPlayerY = playerY
    worldTrailLastMapID = uiMapID

    local distance
    if playerX and playerY and playerInstance then
        distance = HBD:GetWorldDistance(playerInstance, playerX, playerY, trailTarget.worldX, trailTarget.worldY)
    end
    distance = distance or trailTarget.distance

    local dx = targetMapX - playerMapX
    local dy = targetMapY - playerMapY
    local normalizedDistance = math.sqrt((dx * dx) + (dy * dy))
    if (distance and distance < 8) or normalizedDistance < 0.004 then
        worldTrailLastReason = "target-too-close"
        ClearWorldMapTrail()
        return
    end

    local dotSize = Clamp(tonumber(db.worldMapTrailDotSize) or 8, 4, 16)
    db.worldMapTrailDotSize = dotSize

    local dotCount
    if distance then
        dotCount = math.ceil(distance / 60)
    else
        dotCount = math.ceil(normalizedDistance * 36)
    end
    if dotCount < 3 then dotCount = 3 end
    if dotCount > 32 then dotCount = 32 end

    local baseLevel = (WorldMapButton.GetFrameLevel and WorldMapButton:GetFrameLevel()) or 1
    for index = 1, dotCount do
        local ratio = index / dotCount
        local mapX = playerMapX + ((targetMapX - playerMapX) * ratio)
        local mapY = playerMapY + ((targetMapY - playerMapY) * ratio)
        local dot = CreateWorldTrailDot(index)

        local size = dotSize
        if index == dotCount then
            size = dotSize + 2
        end
        dot:SetParent(WorldMapButton)
        if dot.SetFrameLevel then
            dot:SetFrameLevel(baseLevel + 50)
        end
        dot:SetWidth(size)
        dot:SetHeight(size)
        dot.texture:SetVertexColor(1, 0.82, 0.2, 0.48 + (0.42 * ratio))
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", WorldMapButton, "TOPLEFT", mapX * mapWidth, -(mapY * mapHeight))
        dot:Show()
    end

    for index = dotCount + 1, #worldTrailDots do
        worldTrailDots[index]:Hide()
        worldTrailDots[index]:ClearAllPoints()
    end

    worldTrailVisible = dotCount > 0
    worldTrailLastReason = worldTrailVisible and ("shown:" .. tostring(dotCount)) or "no-dots"
end

local function ConsiderCandidate(best, candidate)
    if (not candidate) or (not candidate.worldX) or (not candidate.worldY) then
        return best
    end

    candidate.distance = GetWorldDistance(candidate.worldX, candidate.worldY, candidate.instance, candidate.distance) or 999999999

    if LevelingAdvisor and LevelingAdvisor.ShouldOptimizeArrow and LevelingAdvisor:ShouldOptimizeArrow() then
        candidate.routeScore, candidate.routeRecommendation = LevelingAdvisor:GetArrowScore(candidate)
        -- The advisor may hard-veto a pickup (currently grey available quests)
        -- rather than merely giving it a low score. This prevents an otherwise
        -- useless quest start becoming the arrow target just because it is alone.
        if candidate.routeRecommendation and candidate.routeRecommendation.routeBlocked then
            return best
        end
        if (not best) then
            return candidate
        end
        if best.routeScore == nil then
            best.routeScore, best.routeRecommendation = LevelingAdvisor:GetArrowScore(best)
        end
        if candidate.routeScore > best.routeScore or (candidate.routeScore == best.routeScore and candidate.distance < best.distance) then
            return candidate
        end
        return best
    end

    if (not best) or candidate.distance < best.distance then
        return candidate
    end

    return best
end

local function NormalizeNearestQuestSpawn(quest)
    if (not QuestieMap) or (not QuestieMap.GetNearestQuestSpawn) then
        return nil
    end

    local spawn, zone, spawnName, fourth, fifth, sixth = QuestieMap:GetNearestQuestSpawn(quest)
    local spawnId, spawnType, distance

    -- QuestieMap:GetNearestQuestSpawn returns six values for normal objectives,
    -- but completed/no-objective quests use the finisher helper which returns five.
    -- Normalize both shapes so turn-ins can be targeted reliably.
    if sixth ~= nil then
        spawnId = fourth
        spawnType = fifth
        distance = sixth
    else
        spawnId = nil
        spawnType = fourth
        distance = fifth
    end

    return spawn, zone, spawnName, spawnId, spawnType, distance
end

local function BuildCandidateFromQuestSpawn(questId, quest)
    local spawn, zone, spawnName, spawnId, spawnType, distance = NormalizeNearestQuestSpawn(quest)
    if (not spawn) or (not zone) or (not spawn[1]) or (not spawn[2]) then
        return nil
    end

    local worldX, worldY, instance, uiMapId = GetWorldCoordinates(zone, spawn[1], spawn[2])
    if not worldX or not worldY then
        return nil
    end

    local complete = quest and quest.IsComplete and quest:IsComplete() == 1
    return {
        questId = questId,
        questName = GetQuestName(quest, questId),
        level = quest and quest.level,
        x = spawn[1],
        y = spawn[2],
        zone = zone,
        uiMapId = uiMapId,
        worldX = worldX,
        worldY = worldY,
        instance = instance,
        name = spawnName,
        spawnId = spawnId,
        spawnType = spawnType,
        targetType = complete and "turnin" or "objective",
        iconType = complete and Questie and Questie.ICON_TYPE_COMPLETE or Questie and Questie.ICON_TYPE_NODE,
        distance = distance,
    }
end

local function BuildCandidateFromQuestFrame(questId, questFrame)
    if (not questFrame) or (not questFrame.data) or questFrame.data.Type ~= "available" then
        return nil
    end

    -- On the 3.3.5 client the fullscreen world-map copy of an available quest
    -- icon is not guaranteed to stay resident while the map is closed. The
    -- minimap copy *is* resident and carries the same AreaID/x/y data, so treat
    -- either copy as a valid navigation source and deduplicate by coordinate
    -- later. v9 rejected minimap frames outright, which is why visible ! icons
    -- around the player could still produce pickup scan GO=0/OPT=0/SKIP=0.
    questId = tonumber(questId) or tonumber(questFrame.data.Id)
    if not questId then
        return nil
    end

    local x = tonumber(questFrame.x)
    local y = tonumber(questFrame.y)
    local zone = tonumber(questFrame.AreaID)
    local uiMapId = tonumber(questFrame.UiMapID)

    if (not zone) and uiMapId and ZoneDB and ZoneDB.GetAreaIdByUiMapId then
        local ok, areaId = pcall(ZoneDB.GetAreaIdByUiMapId, ZoneDB, uiMapId)
        if ok then zone = tonumber(areaId) end
    end

    if not (x and y) then
        return nil
    end

    local worldX, worldY, instance, resolvedUiMapId
    if zone then
        worldX, worldY, instance, resolvedUiMapId = GetWorldCoordinates(zone, x, y)
    end
    uiMapId = resolvedUiMapId or uiMapId

    -- If an AreaID cannot be recovered, the live Questie frame still gives us
    -- its UiMapID. HBD can convert that directly on 3.3.5.
    if (not worldX or not worldY) and uiMapId and HBD and HBD.GetWorldCoordinatesFromZone then
        worldX, worldY, instance = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
    end
    if not worldX or not worldY then
        return nil
    end

    local quest = questFrame.data.QuestData or (QuestieDB and QuestieDB.GetQuest and QuestieDB.GetQuest(questId))
    return {
        questId = questId,
        questName = GetQuestName(quest, questId),
        level = quest and quest.level,
        x = x,
        y = y,
        zone = zone,
        uiMapId = uiMapId,
        worldX = worldX,
        worldY = worldY,
        instance = instance,
        name = questFrame.data.Name or "Quest start",
        spawnId = questFrame.data.Id,
        spawnType = questFrame.data.StarterType or "available",
        targetType = "available",
        iconType = questFrame.data.Icon or (Questie and Questie.ICON_TYPE_AVAILABLE),
        frameSource = questFrame.miniMapIcon and "minimap" or "worldmap",
    }
end

local function BuildCandidateFromAvailableLocation(questId, location)
    if not (location and location.x and location.y) then
        return nil
    end

    local areaId = tonumber(location.areaId)
    local x = tonumber(location.x)
    local y = tonumber(location.y)
    local uiMapId = tonumber(location.uiMapId)
    local worldX, worldY, instance, resolvedUiMapId

    if areaId then
        worldX, worldY, instance, resolvedUiMapId = GetWorldCoordinates(areaId, x, y)
    end
    uiMapId = resolvedUiMapId or uiMapId

    if (not worldX or not worldY) and uiMapId and HBD and HBD.GetWorldCoordinatesFromZone then
        worldX, worldY, instance = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
    end
    if not worldX or not worldY then
        return nil
    end

    local quest = QuestieDB and QuestieDB.GetQuest and QuestieDB.GetQuest(questId)
    return {
        questId = questId,
        questName = GetQuestName(quest, questId),
        level = quest and quest.level,
        x = x,
        y = y,
        zone = areaId,
        uiMapId = uiMapId,
        worldX = worldX,
        worldY = worldY,
        instance = instance,
        name = location.name or "Quest start",
        spawnId = location.starterId,
        spawnType = location.starterType or "available",
        targetType = "available",
        iconType = Questie and Questie.ICON_TYPE_AVAILABLE,
        cachedAvailable = true,
    }
end

local function BuildDirectAvailableCandidate(questId)
    if not (QuestieDB and QuestieDB.GetQuest and ZoneDB and HBD) then
        return nil
    end

    local quest = QuestieDB.GetQuest(questId)
    if not (quest and quest.Starts) then
        return nil
    end

    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
    local best

    local function ConsiderSpawn(areaId, x, y, starterName, starterId, starterType)
        if not (areaId and x and y) then
            return
        end
        local worldX, worldY, instance, uiMapId = GetWorldCoordinates(areaId, x, y)
        if not (worldX and worldY and instance) then
            return
        end
        local distance = GetWorldDistance(worldX, worldY, instance, 999999999) or 999999999
        if (not best) or distance < best.distance then
            best = {
                questId = questId,
                questName = GetQuestName(quest, questId),
                level = quest.level,
                x = x,
                y = y,
                zone = areaId,
                uiMapId = uiMapId,
                worldX = worldX,
                worldY = worldY,
                instance = instance,
                name = starterName or "Quest start",
                spawnId = starterId,
                spawnType = starterType or "available",
                targetType = "available",
                iconType = Questie and Questie.ICON_TYPE_AVAILABLE,
                distance = distance,
                directAvailable = true,
            }
        end
    end

    local function ConsiderSpawnTable(spawns, starterName, starterId, starterType)
        if type(spawns) ~= "table" then
            return
        end
        for areaId, coordsList in pairs(spawns) do
            if type(coordsList) == "table" then
                for _, coords in pairs(coordsList) do
                    local x = coords and coords[1]
                    local y = coords and coords[2]
                    if x == -1 or y == -1 then
                        local dungeonLocation = ZoneDB.GetDungeonLocation and ZoneDB:GetDungeonLocation(areaId)
                        if dungeonLocation then
                            for _, entrance in pairs(dungeonLocation) do
                                if entrance and entrance[1] and entrance[2] and entrance[3] then
                                    ConsiderSpawn(entrance[3], entrance[1], entrance[2], starterName, starterId, starterType)
                                end
                            end
                        end
                    elseif x and y then
                        ConsiderSpawn(areaId, x, y, starterName, starterId, starterType)
                    end
                end
            end
        end
    end

    for starterType, starters in pairs(quest.Starts) do
        if starterType == "NPC" then
            for _, starterId in pairs(starters or {}) do
                local npc = QuestieDB.GetNPC and QuestieDB:GetNPC(starterId)
                if npc then
                    ConsiderSpawnTable(npc.spawns, npc.name, starterId, "NPC")
                end
            end
        elseif starterType == "GameObject" then
            for _, starterId in pairs(starters or {}) do
                local object = QuestieDB.GetObject and QuestieDB:GetObject(starterId)
                if object then
                    ConsiderSpawnTable(object.spawns, object.name, starterId, "GameObject")
                end
            end
        end
    end

    return best
end

local function ForQuestFrames(questId, callback)
    if QuestieMap and QuestieMap.ForQuestFrames then
        return QuestieMap:ForQuestFrames(questId, callback)
    end

    local frameNames = QuestieMap and QuestieMap.questIdFrames and QuestieMap.questIdFrames[questId]
    if not frameNames then
        return false
    end

    for _, name in pairs(frameNames) do
        local frame = _G[name]
        if frame and callback(frame, name) then
            return true
        end
    end

    return false
end

local function ConsiderPickupSweep(bestPickup, bestPriority, candidate)
    if not candidate then
        return bestPickup, bestPriority
    end

    local priority, rec
    if LevelingAdvisor and LevelingAdvisor.GetPickupSweepPriority then
        priority, rec = LevelingAdvisor:GetPickupSweepPriority(candidate)
    end

    if rec and lastPickupScan[rec.key] ~= nil then
        lastPickupScan[rec.key] = lastPickupScan[rec.key] + 1
    end

    if not priority then
        return bestPickup, bestPriority
    end

    lastPickupScan.sweep = lastPickupScan.sweep + 1
    candidate.routeRecommendation = candidate.routeRecommendation or rec
    candidate.pickupSweepPriority = priority

    if (not bestPickup) or priority > (bestPriority or 0)
        or (priority == (bestPriority or 0) and (candidate.distance or 999999999) < (bestPickup.distance or 999999999)) then
        return candidate, priority
    end

    return bestPickup, bestPriority
end

function QWA:FindNearestQuestTarget()
    local db = EnsureDB()
    if (not db) or (not db.enabled) or (not Questie) or (not Questie.started) or (not ImportQuestieModules()) then
        return nil
    end

    lastPickupScan.recommended = 0
    lastPickupScan.optional = 0
    lastPickupScan.skip = 0
    lastPickupScan.sweep = 0
    lastPickupScan.outOfRange = 0
    lastPickupScan.attempted = 0
    lastPickupScan.candidates = 0
    lastPickupScan.cacheCandidates = 0
    lastPickupScan.frameCandidates = 0
    lastPickupScan.directCandidates = 0
    lastPickupScan.miniFrames = 0
    lastPickupScan.worldFrames = 0
    lastPickupScan.nearest = nil
    lastPickupScan.prioritized = nil

    local currentQuestlog = QuestiePlayer.currentQuestlog
    local best
    local bestTurnin
    local bestObjective
    local bestPickup
    local bestPickupPriority
    lastRouteDecision = "scanning"

    if currentQuestlog then
        for questId in pairs(currentQuestlog) do
            if (not db.trackedOnly) or IsQuestTracked(questId) then
                local quest = QuestieDB.GetQuest and QuestieDB.GetQuest(questId)
                if quest then
                    local candidate = BuildCandidateFromQuestSpawn(questId, quest)
                    if candidate then
                        best = ConsiderCandidate(best, candidate)
                        if candidate.targetType == "turnin" then
                            bestTurnin = ConsiderCandidate(bestTurnin, candidate)
                        else
                            bestObjective = ConsiderCandidate(bestObjective, candidate)
                        end
                    end
                end
            end
        end
    end

    local seenPickupLocations = {}
    local function AddAvailableCandidate(candidate, source)
        if not candidate then
            return false
        end

        -- World-map and minimap frames normally represent the same spawn. Keep
        -- one logical pickup candidate while still allowing multiple real
        -- starters/locations for the same quest.
        local key = tostring(candidate.questId or "") .. ":" .. tostring(candidate.uiMapId or candidate.zone or "")
            .. ":" .. string.format("%.3f", tonumber(candidate.x) or 0)
            .. ":" .. string.format("%.3f", tonumber(candidate.y) or 0)
        if seenPickupLocations[key] then
            return false
        end
        seenPickupLocations[key] = true

        candidate.distance = GetWorldDistance(candidate.worldX, candidate.worldY, candidate.instance, candidate.distance) or 999999999
        lastPickupScan.candidates = lastPickupScan.candidates + 1
        if source == "cache" or candidate.cachedAvailable then
            lastPickupScan.cacheCandidates = lastPickupScan.cacheCandidates + 1
        elseif source == "direct" or candidate.directAvailable then
            lastPickupScan.directCandidates = lastPickupScan.directCandidates + 1
        else
            lastPickupScan.frameCandidates = lastPickupScan.frameCandidates + 1
            if candidate.frameSource == "minimap" then
                lastPickupScan.miniFrames = lastPickupScan.miniFrames + 1
            else
                lastPickupScan.worldFrames = lastPickupScan.worldFrames + 1
            end
        end

        local pickupInRange = true
        if LevelingAdvisor and LevelingAdvisor.IsActive and LevelingAdvisor:IsActive()
            and LevelingAdvisor.IsPickupWithinRange then
            pickupInRange = LevelingAdvisor:IsPickupWithinRange(candidate)
        end

        -- V3 only applied smartPickupRange to the hub-sweep override. The generic
        -- smart route score could therefore still select a distant available quest
        -- (for example a 528 yd pickup with the slider set to 200 yd). In smart
        -- leveling mode, treat the configured pickup range as a hard maximum for
        -- *all* available-quest targets. Active objectives and turn-ins are not
        -- distance-capped by this setting.
        if pickupInRange then
            best = ConsiderCandidate(best, candidate)
            bestPickup, bestPickupPriority = ConsiderPickupSweep(bestPickup, bestPickupPriority, candidate)
        else
            lastPickupScan.outOfRange = (lastPickupScan.outOfRange or 0) + 1
        end

        if (not lastPickupScan.nearest) or (candidate.distance or 999999999) < (lastPickupScan.nearest.distance or 999999999) then
            lastPickupScan.nearest = candidate
        end
        return true
    end

    if db.includeAvailable then
        local seenAvailable = {}
        local availableTable = AvailableQuests and AvailableQuests.GetAvailableQuestTable and AvailableQuests.GetAvailableQuestTable()

        -- Prefer Questie's canonical availability set. Map frames are an output of
        -- that calculation and can be temporarily unloaded while changing maps or
        -- during a fast refresh; using only questIdFrames made the arrow sometimes
        -- forget that there were quests to pick up.
        if type(availableTable) == "table" then
            for questId in pairs(availableTable) do
                if ((not currentQuestlog) or (not currentQuestlog[questId])) then
                    lastPickupScan.attempted = lastPickupScan.attempted + 1
                    seenAvailable[questId] = true
                    local foundCandidate = false

                    -- Primary source on 3.3.5: consume the exact locations that
                    -- AvailableQuests recorded while drawing its visible ! icons.
                    -- This bypasses frame-pool/index differences entirely.
                    local drawnLocations = AvailableQuests.GetAvailableQuestLocations and AvailableQuests.GetAvailableQuestLocations(questId)
                    if type(drawnLocations) == "table" then
                        for _, location in pairs(drawnLocations) do
                            local candidate = BuildCandidateFromAvailableLocation(questId, location)
                            if candidate and AddAvailableCandidate(candidate, "cache") then
                                foundCandidate = true
                            end
                        end
                    end

                    if not foundCandidate then
                        ForQuestFrames(questId, function(questFrame)
                            local candidate = BuildCandidateFromQuestFrame(questId, questFrame)
                            if candidate and AddAvailableCandidate(candidate, "frame") then
                                foundCandidate = true
                            end
                            return false
                        end)
                    end
                    if not foundCandidate then
                        AddAvailableCandidate(BuildDirectAvailableCandidate(questId), "direct")
                    end
                end
            end
        end

        -- Compatibility/fallback: if availability is in the middle of rebuilding,
        -- keep using any still-live available frames so the route does not blink.
        if QuestieMap.questIdFrames then
            for questId in pairs(QuestieMap.questIdFrames) do
                if (not seenAvailable[questId]) and ((not currentQuestlog) or (not currentQuestlog[questId])) then
                    ForQuestFrames(questId, function(questFrame)
                        AddAvailableCandidate(BuildCandidateFromQuestFrame(questId, questFrame), "frame")
                        return false
                    end)
                end
            end

            -- Final 3.3.5 safety net: trust the live icon data itself. This is
            -- intentionally independent of AvailableQuests' table because the
            -- minimap can still be showing a valid ! while that availability
            -- calculation is between refreshes. Only frames explicitly marked
            -- Type=available are considered.
            for questId in pairs(QuestieMap.questIdFrames) do
                if ((not currentQuestlog) or (not currentQuestlog[questId])) then
                    ForQuestFrames(questId, function(questFrame)
                        if questFrame and questFrame.data and questFrame.data.Type == "available" then
                            AddAvailableCandidate(BuildCandidateFromQuestFrame(questId, questFrame), "frame")
                        end
                        return false
                    end)
                end
            end
        end
    end

    -- Smart leveling route tiers. A completed quest no longer wins globally just
    -- because it is complete: that could send a low-level character 1k+ yards
    -- away while useful work was immediately nearby. The intended leveling flow is:
    --   1) nearby hand-in
    --   2) worthwhile pickup inside Maximum Quest Pickup Range
    --   3) nearby / meaningfully closer active objective
    --   4) distant hand-in
    --   5) remaining active/fallback target
    -- This keeps chain-unlocking local hand-ins valuable without creating long
    -- backtracking detours in the middle of a questing area.
    local smartActive = LevelingAdvisor and LevelingAdvisor.IsActive and LevelingAdvisor:IsActive()
    if smartActive then
        local turninDistance = bestTurnin and (tonumber(bestTurnin.distance) or 999999999) or 999999999
        local objectiveDistance = bestObjective and (tonumber(bestObjective.distance) or 999999999) or 999999999

        if bestTurnin and turninDistance <= SMART_NEARBY_TURNIN_RANGE then
            lastRouteDecision = "nearby-turnin"
            return bestTurnin
        end

        if bestPickup then
            lastPickupScan.prioritized = bestPickup
            lastRouteDecision = "nearby-pickup"
            return bestPickup
        end

        if bestObjective then
            if not bestTurnin then
                lastRouteDecision = "active-objective"
                return bestObjective
            end

            -- Only demote a hand-in once it is genuinely a travel leg. A local
            -- objective wins if it is within the local-work radius, or if doing it
            -- first saves at least 250 yards compared with the distant hand-in.
            if turninDistance > SMART_LOCAL_OBJECTIVE_RANGE
                and (objectiveDistance <= SMART_LOCAL_OBJECTIVE_RANGE
                    or objectiveDistance + SMART_OBJECTIVE_SAVINGS <= turninDistance) then
                lastRouteDecision = "objective-before-distant-turnin"
                return bestObjective
            end
        end

        if bestTurnin then
            lastRouteDecision = "distant-turnin"
            return bestTurnin
        end

        if bestObjective then
            lastRouteDecision = "active-objective-fallback"
            return bestObjective
        end
    end

    if bestPickup then
        lastPickupScan.prioritized = bestPickup
    end
    lastRouteDecision = best and "generic-best" or "no-target"
    return best
end

local function ApplyScale()
    local db = EnsureDB()
    if (not db) or (not arrowFrame) or (not arrowFrame.content) then return end

    local scale = tonumber(db.scale) or 1.2
    scale = Clamp(scale, 0.5, 3.0)
    db.scale = scale
    arrowFrame.content:SetScale(scale)
end

local function ApplyPosition()
    local db = EnsureDB()
    if (not db) or (not arrowFrame) then return end

    arrowFrame:ClearAllPoints()
    local pos = db.position
    if type(pos) == "table" and pos[1] then
        arrowFrame:SetPoint(pos[1], UIParent, pos[1], pos[2] or 0, pos[3] or -100)
    else
        arrowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
    end
end

function QWA:GetDB()
    return EnsureDB()
end

function QWA:Refresh(forceTarget)
    local db = EnsureDB()
    if (not db) or (not arrowFrame) then return end

    ApplyScale()
    ApplyPosition()

    if db.locked then
        arrowFrame:EnableMouse(false)
    else
        arrowFrame:EnableMouse(true)
    end

    if not db.trailEnabled then
        ClearMinimapTrail()
    end
    if not db.worldMapTrailEnabled then
        ClearWorldMapTrail()
    end

    if db.enabled then
        -- Keep the parent frame shown so OnUpdate can notice when Questie finishes
        -- starting up. Only the visible content is hidden while no target exists.
        arrowFrame:Show()
        if forceTarget then
            targetRefresh = 0
        end
    else
        trackerWasVisible = false
        arrowFrame.content:Hide()
        ClearTrail()
        arrowFrame:Hide()
    end
end

function QWA:ResetPosition()
    local db = EnsureDB()
    if not db then return end
    db.position = {"CENTER", 0, -100}
    ApplyPosition()
end

function QWA:SetEnabled(enabled)
    local db = EnsureDB()
    if not db then return end
    db.enabled = enabled and true or false
    self:Refresh(true)
end

local function UpdateTextForTarget(newTarget)
    if (not arrowFrame) or (not newTarget) then return end

    local title = newTarget.questName or "Quest target"
    if newTarget.level then
        title = "[" .. tostring(newTarget.level) .. "] " .. title
    end

    local label = "Objective"
    if newTarget.targetType == "available" then
        label = "PICK UP"
    elseif newTarget.targetType == "turnin" then
        label = "Turn-in"
    end

    if LevelingAdvisor and LevelingAdvisor.GetRecommendation then
        local rec = newTarget.routeRecommendation or LevelingAdvisor:GetRecommendation(newTarget.questId, newTarget.targetType)
        if rec then
            label = label .. " | " .. rec.label
        end
    end

    arrowFrame.title:SetText("|cffffcc00" .. title .. "|r")
    arrowFrame.description:SetText(label .. ": " .. tostring(newTarget.name or "Quest target"))
    arrowFrame.texture:SetTexture(GetTargetTexture(newTarget.iconType))
    arrowFrame.texture:SetVertexColor(1, 1, 1, 1)
end

local function UpdateTarget(force)
    if force then
        targetRefresh = 0
    end

    local db = EnsureDB()
    if not db then return end
    local now = GetTime()
    if now < targetRefresh then
        return
    end

    targetRefresh = now + (tonumber(db.refresh) or 1.0)
    local newTarget = QWA:FindNearestQuestTarget()

    local targetChanged = newTarget and ((not target) or target.questId ~= newTarget.questId or target.name ~= newTarget.name or target.x ~= newTarget.x or target.y ~= newTarget.y or target.targetType ~= newTarget.targetType)
    if targetChanged then
        UpdateTextForTarget(newTarget)
        trailNextRefresh = 0
        worldTrailNextRefresh = 0
    end

    target = newTarget
end

local function OnArrowUpdate(self, elapsed)
    updateThrottle = updateThrottle + (elapsed or 0)
    if updateThrottle < 0.05 then
        return
    end
    updateThrottle = 0

    local db = EnsureDB()
    if (not db) or (not db.enabled) then
        self.content:Hide()
        return
    end

    if (not ImportQuestieModules()) or (not Questie) or (not Questie.started) then
        trackerWasVisible = false
        self.content:Hide()
        return
    end

    local trackerActive = QWA:OnTrackerStateChanged(false)
    local worldMapActive = db.worldMapTrailEnabled and (
        (WorldMapFrame and WorldMapFrame.IsVisible and WorldMapFrame:IsVisible())
        or (WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown())
        or (WorldMapButton and WorldMapButton.IsVisible and WorldMapButton:IsVisible())
    )
    if (not trackerActive) and (not worldMapActive) then
        return
    end

    UpdateTarget(false)

    if not target then
        self.content:Hide()
        ClearTrail()
        return
    end

    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()

    -- Draw the fullscreen-map trail first. It has a direct map-coordinate path and
    -- should survive the temporary world-position quirks caused by opening the
    -- 3.3.5 fullscreen map.
    if worldMapActive then
        UpdateWorldMapTrail(playerX, playerY, playerInstance, target)
    end

    if (not playerX) or (not playerY) or (not playerInstance)
        or (target.instance and target.instance ~= playerInstance) then
        self.content:Hide()
        ClearMinimapTrail()
        return
    end

    if not trackerActive then
        ClearMinimapTrail()
        self.content:Hide()
        return
    end

    local facing = GetPlayerFacing and GetPlayerFacing()
    if not facing then
        self.content:Hide()
        ClearMinimapTrail()
        return
    end

    UpdateMinimapTrail(playerX, playerY, playerInstance, target)
    self.content:Show()

    local distance = HBD:GetWorldDistance(playerInstance, playerX, playerY, target.worldX, target.worldY) or target.distance or 0

    -- HereBeDragons world coordinates are converted from map coordinates as
    -- left - width * x and top - height * y, so both axes are inverted versus
    -- local Questie/pfQuest map coordinates. Convert the vector back to
    -- map-style deltas before calculating the arrow heading.
    local xDelta = (playerX - target.worldX) * 1.5
    local yDelta = (playerY - target.worldY)
    local dir = atan2(xDelta, -yDelta)
    dir = dir > 0 and (math_pi * 2) - dir or -dir
    if dir < 0 then
        dir = dir + 360
    end

    local angle = math_rad(dir) - facing
    local percent = math_abs(((math_pi - math_abs(angle)) / math_pi))
    local r, g, b = GetDirectionColor(math_floor(percent * 100) / 100)

    local cell = Modulo(math_floor(angle / (math_pi * 2) * 108 + 0.5), 108)
    local column = Modulo(cell, 9)
    local row = math_floor(cell / 9)
    local xstart = (column * 56) / 512
    local ystart = (row * 42) / 512
    local xend = ((column + 1) * 56) / 512
    local yend = ((row + 1) * 42) / 512

    self.model:SetTexCoord(xstart, xend, ystart, yend)
    self.model:SetVertexColor(r, g, b, 1)

    if db.showDistance then
        local formatted = FormatDistance(distance)
        if self.distance.lastValue ~= formatted then
            self.distance:SetText("|cffaaaaaaDistance: " .. formatted .. "|r")
            self.distance.lastValue = formatted
        end
    else
        self.distance:SetText("")
        self.distance.lastValue = nil
    end

    -- The server-neutral advisor intentionally does not invent a zone progression
    -- guide; it only ranks Questie's currently available/active quest data.
    if self.zoneHint then
        self.zoneHint:SetText("")
    end
end

local function OnWorldMapTrailDriverUpdate(self, elapsed)
    worldMapDriverElapsed = worldMapDriverElapsed + (elapsed or 0)
    if worldMapDriverElapsed < 0.10 then
        return
    end
    worldMapDriverElapsed = 0

    local db = EnsureDB()
    if not (db and db.enabled and db.worldMapTrailEnabled) then
        return
    end

    local mapVisible = (WorldMapFrame and WorldMapFrame.IsVisible and WorldMapFrame:IsVisible())
        or (WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown())
        or (WorldMapButton and WorldMapButton.IsVisible and WorldMapButton:IsVisible())
    if not mapVisible then
        worldTrailLastReason = "map-not-visible"
        return
    end

    if (not ImportQuestieModules()) or (not Questie) or (not Questie.started) or (not HBD) then
        worldTrailLastReason = "driver-waiting-for-questie"
        return
    end

    -- The fullscreen 3.3.5 map can hide the normal HUD frame that owns the arrow's
    -- OnUpdate script. Refresh the route from a map-owned driver so opening the map
    -- always causes an actual trail-render pass.
    UpdateTarget(false)
    if not target then
        worldTrailLastReason = "no-target"
        ClearWorldMapTrail()
        return
    end

    local playerX, playerY, playerInstance = HBD:GetPlayerWorldPosition()
    UpdateWorldMapTrail(playerX, playerY, playerInstance, target)
end

local function CreateWorldMapTrailDriver()
    if worldMapTrailDriver then
        return
    end

    local parent = WorldMapFrame or UIParent
    worldMapTrailDriver = CreateFrame("Frame", "QuestieWaypointWorldMapTrailDriver", parent)
    if parent and worldMapTrailDriver.SetAllPoints then
        worldMapTrailDriver:SetAllPoints(parent)
    end
    worldMapTrailDriver:EnableMouse(false)
    worldMapTrailDriver:SetScript("OnUpdate", OnWorldMapTrailDriverUpdate)
    worldMapTrailDriver:Show()

    if WorldMapFrame and WorldMapFrame.HookScript then
        WorldMapFrame:HookScript("OnShow", function()
            worldTrailNextRefresh = 0
            worldTrailLastReason = "map-open-awaiting-render"
        end)
        WorldMapFrame:HookScript("OnHide", function()
            ClearWorldMapTrail()
            worldTrailLastReason = "map-not-visible"
        end)
    end
end

local function CreateArrowFrame()
    if arrowFrame then
        return
    end

    arrowFrame = CreateFrame("Frame", "QuestieWaypointArrowFrame", UIParent)
    arrowFrame:SetWidth(48)
    arrowFrame:SetHeight(36)
    arrowFrame:SetClampedToScreen(true)
    arrowFrame:SetMovable(true)
    arrowFrame:RegisterForDrag("LeftButton")
    arrowFrame:SetScript("OnDragStart", function(self)
        local db = EnsureDB()
        if db and ((not db.locked) or IsShiftKeyDown()) then
            self:StartMoving()
        end
    end)
    arrowFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = EnsureDB()
        if not db then return end
        local point, _, _, x, y = self:GetPoint(1)
        db.position = {point or "CENTER", x or 0, y or -100}
    end)
    arrowFrame:SetScript("OnUpdate", OnArrowUpdate)

    arrowFrame.content = CreateFrame("Frame", nil, arrowFrame)
    arrowFrame.content:SetPoint("TOPLEFT", arrowFrame, "TOPLEFT", -80, 0)
    arrowFrame.content:SetPoint("BOTTOMRIGHT", arrowFrame, "BOTTOMRIGHT", 80, -58)

    arrowFrame.model = arrowFrame.content:CreateTexture("QuestieWaypointArrowTexture", "MEDIUM")
    arrowFrame.model:SetTexture(ARROW_TEXTURE)
    arrowFrame.model:SetBlendMode("BLEND")
    arrowFrame.model:SetAlpha(1)
    arrowFrame.model:SetTexCoord(0, 0, 0.109375, 0.08203125)
    arrowFrame.model:SetWidth(48)
    arrowFrame.model:SetHeight(36)
    arrowFrame.model:SetPoint("TOP", arrowFrame.content, "TOP", 0, 0)

    arrowFrame.texture = arrowFrame.content:CreateTexture("QuestieWaypointArrowNodeTexture", "OVERLAY")
    arrowFrame.texture:SetWidth(26)
    arrowFrame.texture:SetHeight(26)
    arrowFrame.texture:SetPoint("BOTTOM", arrowFrame.model, "BOTTOM", 0, 0)
    arrowFrame.texture:SetTexture(GetTargetTexture(nil))

    arrowFrame.title = arrowFrame.content:CreateFontString(nil, "HIGH", "GameFontNormal")
    arrowFrame.title:SetPoint("TOP", arrowFrame.model, "BOTTOM", 0, -10)
    arrowFrame.title:SetWidth(220)
    arrowFrame.title:SetJustifyH("CENTER")
    arrowFrame.title:SetText("Questie Waypoint")

    arrowFrame.description = arrowFrame.content:CreateFontString(nil, "HIGH", "GameFontWhite")
    arrowFrame.description:SetPoint("TOP", arrowFrame.title, "BOTTOM", 0, -2)
    arrowFrame.description:SetWidth(220)
    arrowFrame.description:SetJustifyH("CENTER")
    arrowFrame.description:SetTextColor(1, 1, 1, 1)
    arrowFrame.description:SetText("")

    arrowFrame.distance = arrowFrame.content:CreateFontString(nil, "HIGH", "GameFontWhiteSmall")
    arrowFrame.distance:SetPoint("TOP", arrowFrame.description, "BOTTOM", 0, -2)
    arrowFrame.distance:SetWidth(220)
    arrowFrame.distance:SetJustifyH("CENTER")
    arrowFrame.distance:SetTextColor(0.8, 0.8, 0.8, 1)
    arrowFrame.distance:SetText("")

    arrowFrame.zoneHint = arrowFrame.content:CreateFontString(nil, "HIGH", "GameFontWhiteSmall")
    arrowFrame.zoneHint:SetPoint("TOP", arrowFrame.distance, "BOTTOM", 0, -2)
    arrowFrame.zoneHint:SetWidth(260)
    arrowFrame.zoneHint:SetJustifyH("CENTER")
    arrowFrame.zoneHint:SetText("")

    arrowFrame.content:Hide()
    arrowFrame:Hide()
end

function QWA:PrintTarget()
    UpdateTarget(true)
    if target then
        Print("Target: " .. tostring(target.targetType or "target") .. " - " .. tostring(target.questName) .. " - " .. tostring(target.name or "objective") .. " (" .. string.format("%.1f", target.x or 0) .. ", " .. string.format("%.1f", target.y or 0) .. ")")
    else
        Print("No valid quest target right now.")
    end
end

local function OpenOptions()
    if _G.QuestieWaypointArrow_OpenOptions then
        _G.QuestieWaypointArrow_OpenOptions()
    else
        Print("options are still loading; try /qwa options again in a moment.")
    end
end

SlashHandler = function(message)
    message = string.lower(message or "")
    local cmd, rest = message:match("^(%S*)%s*(.-)$")
    local db = EnsureDB()
    if not db then
        Print("Questie is still starting; try again after login.")
        return
    end

    if cmd == "on" or cmd == "enable" then
        QWA:SetEnabled(true)
        Print("enabled.")
    elseif cmd == "off" or cmd == "disable" then
        QWA:SetEnabled(false)
        Print("disabled.")
    elseif cmd == "toggle" or cmd == "" then
        QWA:SetEnabled(not db.enabled)
        Print(db.enabled and "enabled." or "disabled.")
    elseif cmd == "lock" then
        db.locked = true
        QWA:Refresh()
        Print("locked.")
    elseif cmd == "unlock" then
        db.locked = false
        QWA:Refresh()
        Print("unlocked.")
    elseif cmd == "reset" then
        QWA:ResetPosition()
        QWA:Refresh(true)
        Print("position reset.")
    elseif cmd == "available" then
        local value = string.lower(rest or "")
        if value == "on" or value == "enable" or value == "enabled" then
            db.includeAvailable = true
        elseif value == "off" or value == "disable" or value == "disabled" then
            db.includeAvailable = false
        else
            db.includeAvailable = not db.includeAvailable
        end
        QWA:Refresh(true)
        Print(db.includeAvailable and "available quest starts enabled." or "available quest starts disabled.")
    elseif cmd == "smart" or cmd == "leveling" then
        local value = string.lower(rest or "")
        if value == "on" or value == "enable" or value == "enabled" then
            db.smartLeveling = true
        elseif value == "off" or value == "disable" or value == "disabled" then
            db.smartLeveling = false
        else
            db.smartLeveling = not db.smartLeveling
        end
        QWA:Refresh(true)
        Print(db.smartLeveling and "smart leveling suggestions enabled." or "smart leveling suggestions disabled.")
    elseif cmd == "pickuprange" then
        local value = tonumber(rest)
        if value then
            db.smartPickupRange = Clamp(value, 200, 1200)
            QWA:Refresh(true)
            Print("smart pickup range set to " .. tostring(db.smartPickupRange) .. " yd.")
        else
            Print("usage: /qwa pickuprange 650")
        end
    elseif cmd == "tracked" then
        db.trackedOnly = not db.trackedOnly
        QWA:Refresh(true)
        Print(db.trackedOnly and "tracked-only mode enabled." or "tracked-only mode disabled.")
    elseif cmd == "distance" then
        db.showDistance = not db.showDistance
        QWA:Refresh()
        Print(db.showDistance and "distance enabled." or "distance disabled.")
    elseif cmd == "trail" then
        local value = string.lower(rest or "")
        if value == "on" or value == "enable" then
            db.trailEnabled = true
        elseif value == "off" or value == "disable" then
            db.trailEnabled = false
        else
            db.trailEnabled = not db.trailEnabled
        end
        QWA:Refresh(true)
        Print(db.trailEnabled and "minimap trail enabled." or "minimap trail disabled.")
    elseif cmd == "maptrail" or cmd == "worldtrail" then
        local value = string.lower(rest or "")
        if value == "on" or value == "enable" then
            db.worldMapTrailEnabled = true
        elseif value == "off" or value == "disable" then
            db.worldMapTrailEnabled = false
        else
            db.worldMapTrailEnabled = not db.worldMapTrailEnabled
        end
        worldTrailNextRefresh = 0
        QWA:Refresh(true)
        Print(db.worldMapTrailEnabled and "world map trail enabled." or "world map trail disabled.")
    elseif cmd == "maptrailsize" or cmd == "worldtrailsize" then
        local value = tonumber(rest)
        if value then
            db.worldMapTrailDotSize = Clamp(value, 4, 16)
            worldTrailNextRefresh = 0
            QWA:Refresh(true)
            Print("world map trail dot size set to " .. tostring(db.worldMapTrailDotSize) .. ".")
        else
            Print("usage: /qwa maptrailsize 8")
        end
    elseif cmd == "trailspacing" then
        local value = tonumber(rest)
        if value then
            db.trailSpacing = Clamp(value, 20, 80)
            trailNextRefresh = 0
            QWA:Refresh(true)
            Print("trail spacing set to " .. tostring(db.trailSpacing) .. " yd.")
        else
            Print("usage: /qwa trailspacing 35")
        end
    elseif cmd == "trailsize" then
        local value = tonumber(rest)
        if value then
            db.trailDotSize = Clamp(value, 4, 14)
            trailNextRefresh = 0
            QWA:Refresh(true)
            Print("trail dot size set to " .. tostring(db.trailDotSize) .. ".")
        else
            Print("usage: /qwa trailsize 7")
        end
    elseif cmd == "scale" then
        local value = tonumber(rest)
        if value then
            db.scale = Clamp(value, 0.5, 3.0)
            QWA:Refresh()
            Print("scale set to " .. tostring(db.scale) .. ".")
        else
            Print("usage: /qwa scale 1.2")
        end
    elseif cmd == "target" then
        QWA:PrintTarget()
    elseif cmd == "status" then
        ImportQuestieModules()
        local baseFrame = (TrackerBaseFrame and TrackerBaseFrame.baseFrame) or _G.Questie_BaseFrame
        local expanded = Questie and Questie.db and Questie.db.char and Questie.db.char.isTrackerExpanded
        local trackerEnabled = Questie and Questie.db and Questie.db.profile and Questie.db.profile.trackerEnabled
        local baseShown = baseFrame and baseFrame:IsShown() or false
        local integratedShown = arrowFrame and arrowFrame.content and arrowFrame.content:IsShown() or false
        local currentUiMapID = QuestieCompat and QuestieCompat.GetCurrentUiMapID and QuestieCompat.GetCurrentUiMapID() or nil
        local availableCount = 0
        local availableTable = AvailableQuests and AvailableQuests.GetAvailableQuestTable and AvailableQuests.GetAvailableQuestTable()
        if type(availableTable) == "table" then
            for _ in pairs(availableTable) do availableCount = availableCount + 1 end
        end
        Print("status: trackerEnabled=" .. tostring(trackerEnabled)
            .. " expanded=" .. tostring(expanded)
            .. " trackerFrameShown=" .. tostring(baseShown)
            .. " arrowShown=" .. tostring(integratedShown)
            .. " includeAvailable=" .. tostring(db.includeAvailable)
            .. " smartLeveling=" .. tostring(db.smartLeveling)
            .. " smartPickupRange=" .. tostring(db.smartPickupRange)
            .. " trackedOnly=" .. tostring(db.trackedOnly)
            .. " trailEnabled=" .. tostring(db.trailEnabled)
            .. " trailShown=" .. tostring(trailVisible)
            .. " mapTrailEnabled=" .. tostring(db.worldMapTrailEnabled)
            .. " mapTrailShown=" .. tostring(worldTrailVisible)
            .. " mapTrailReason=" .. tostring(worldTrailLastReason)
            .. " currentMap=" .. tostring(currentUiMapID)
            .. " available=" .. tostring(availableCount)
            .. " routeDecision=" .. tostring(lastRouteDecision))
        if target then
            Print("route target: " .. tostring(target.targetType) .. " | " .. tostring(target.questName)
                .. " | map=" .. tostring(target.uiMapId) .. " | zone=" .. tostring(target.zone)
                .. " | distance=" .. FormatDistance(target.distance))
        end
        local nearestPickup = lastPickupScan.nearest
        local sweepPickup = lastPickupScan.prioritized
        Print("pickup scan: GO=" .. tostring(lastPickupScan.recommended or 0)
            .. " OPT=" .. tostring(lastPickupScan.optional or 0)
            .. " SKIP=" .. tostring(lastPickupScan.skip or 0)
            .. " sweepEligible=" .. tostring(lastPickupScan.sweep or 0)
            .. " outOfRange=" .. tostring(lastPickupScan.outOfRange or 0)
            .. " attempted=" .. tostring(lastPickupScan.attempted or 0)
            .. " candidates=" .. tostring(lastPickupScan.candidates or 0)
            .. " cache=" .. tostring(lastPickupScan.cacheCandidates or 0)
            .. " frame=" .. tostring(lastPickupScan.frameCandidates or 0)
            .. " mini=" .. tostring(lastPickupScan.miniFrames or 0)
            .. " world=" .. tostring(lastPickupScan.worldFrames or 0)
            .. " direct=" .. tostring(lastPickupScan.directCandidates or 0)
            .. (nearestPickup and (" | nearest=" .. tostring(nearestPickup.questName) .. " " .. FormatDistance(nearestPickup.distance)) or "")
            .. (sweepPickup and (" | sweep=" .. tostring(sweepPickup.questName) .. " " .. FormatDistance(sweepPickup.distance)) or ""))
    elseif cmd == "options" or cmd == "config" then
        OpenOptions()
    else
        Print("commands: on, off, toggle, lock, unlock, reset, available [on|off], smart [on|off], pickuprange <200-1200>, tracked, distance, trail [on|off], maptrail [on|off], trailspacing <20-80>, trailsize <4-14>, maptrailsize <4-16>, scale <0.5-3>, target, status, options")
    end
end

SLASH_QUESTIEWAYPOINTARROW1 = "/qwa"
SLASH_QUESTIEWAYPOINTARROW2 = "/questiearrow"
SLASH_QUESTIEWAYPOINTARROW3 = "/qarrow"
SlashCmdList["QUESTIEWAYPOINTARROW"] = SlashHandler

function QWA:Initialize()
    if not EnsureDB() then return end
    ImportQuestieModules()
    CreateArrowFrame()
    CreateWorldMapTrailDriver()
    self:Refresh(true)
    self:OnTrackerStateChanged(true)
end

function QWA:OnProfileChanged()
    target = nil
    targetRefresh = 0
    ClearTrail()
    self:Refresh(true)
    self:OnTrackerStateChanged(true)
end

local initialized = false
local initializationFailed = false
local startupPollElapsed = 0

local function TryInitializeAfterQuestie()
    if initialized or initializationFailed then
        return initialized
    end

    -- Do not touch Questie's runtime modules until the confirmed-working core
    -- startup has completed. This prevents the arrow from blocking the tracker,
    -- settings panel, or database initialization if anything arrow-specific fails.
    if not (Questie and Questie.started and Questie.db and Questie.db.profile) then
        return false
    end

    local ok, err = pcall(QWA.Initialize, QWA)
    if not ok then
        initializationFailed = true
        Print("initialization failed without stopping Questie: " .. tostring(err))
        return false
    end

    initialized = true
    return true
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_INDOORS")

eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if initialized or initializationFailed then
        self:SetScript("OnUpdate", nil)
        return
    end

    startupPollElapsed = startupPollElapsed + (elapsed or 0)
    if startupPollElapsed < 0.5 then
        return
    end
    startupPollElapsed = 0

    if TryInitializeAfterQuestie() then
        self:SetScript("OnUpdate", nil)
    end
end)

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= ADDON_NAME then
        return
    end

    if not initialized then
        TryInitializeAfterQuestie()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "QUEST_LOG_UPDATE"
        or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        targetRefresh = 0
        trailNextRefresh = 0
        worldTrailNextRefresh = 0
        QWA:OnTrackerStateChanged(true)
    end
end)
