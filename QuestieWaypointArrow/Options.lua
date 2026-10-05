-- Standalone Interface Options panel for Questie Waypoint Arrow (3.3.5a).

local panel = CreateFrame("Frame", "QuestieWaypointArrowOptionsPanel", UIParent)
panel.name = "Questie Waypoint Arrow"

local refreshing = false
local controls = {}

local function GetAddon()
    return _G.QuestieWaypointArrow
end

local function GetDB()
    local addon = GetAddon()
    return addon and addon.GetDB and addon:GetDB() or _G.QuestieWaypointArrowDB
end

local function Apply(force)
    local addon = GetAddon()
    if addon and addon.Refresh then
        addon:Refresh(force and true or false)
    end
end

local function SetControlEnabled(control, enabled)
    if not control then return end
    if enabled then
        if control.Enable then control:Enable() end
        if control.SetAlpha then control:SetAlpha(1) end
    else
        if control.Disable then control:Disable() end
        if control.SetAlpha then control:SetAlpha(0.5) end
    end
end

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Questie Waypoint Arrow")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetWidth(610)
subtitle:SetJustifyH("LEFT")
subtitle:SetText("Standalone companion for Questie-335. Questie itself stays untouched and can be updated normally.")

local function CreateCheck(name, label, tip, key, x, y)
    local check = CreateFrame("CheckButton", name, panel, "InterfaceOptionsCheckButtonTemplate")
    check:SetPoint("TOPLEFT", x, y)
    _G[name .. "Text"]:SetText(label)
    check.tooltipText = tip
    check.key = key
    check:SetScript("OnClick", function(self)
        if refreshing then return end
        local db = GetDB()
        if not db then return end
        db[self.key] = self:GetChecked() and true or false
        Apply(true)
        if panel.Refresh then panel:Refresh() end
    end)
    controls[#controls + 1] = check
    return check
end

local function CreateSlider(name, label, tip, key, x, y, minValue, maxValue, step, decimals)
    local slider = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetWidth(250)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider.key = key
    slider.label = label
    slider.decimals = decimals or 0
    slider.tooltipText = tip
    _G[name .. "Low"]:SetText(tostring(minValue))
    _G[name .. "High"]:SetText(tostring(maxValue))
    slider:SetScript("OnValueChanged", function(self, value)
        local rounded
        if self.decimals and self.decimals > 0 then
            local factor = 10 ^ self.decimals
            rounded = math.floor(value * factor + 0.5) / factor
        else
            rounded = math.floor(value + 0.5)
        end
        _G[name .. "Text"]:SetText(self.label .. ": " .. tostring(rounded))
        if refreshing then return end
        local db = GetDB()
        if not db then return end
        db[self.key] = rounded
        Apply(true)
    end)
    controls[#controls + 1] = slider
    return slider
end

local enable = CreateCheck(
    "QuestieWaypointArrowOptEnable",
    "Enable Waypoint Arrow",
    "Show the waypoint arrow when Questie's tracker is active.",
    "enabled", 18, -82
)

local tracked = CreateCheck(
    "QuestieWaypointArrowOptTracked",
    "Tracked Quests Only",
    "Only route active objectives through Questie's tracked quest set. Available quest starts are controlled separately.",
    "trackedOnly", 18, -116
)

local available = CreateCheck(
    "QuestieWaypointArrowOptAvailable",
    "Include Available Quests",
    "Allow Questie quest-start locations to become arrow targets.",
    "includeAvailable", 18, -150
)

local smart = CreateCheck(
    "QuestieWaypointArrowOptSmart",
    "Smart Leveling Suggestions",
    "Prefer sensible level-appropriate pickups, chain continuations and turn-ins instead of simply choosing the nearest marker.",
    "smartLeveling", 18, -184
)

local distance = CreateCheck(
    "QuestieWaypointArrowOptDistance",
    "Show Distance",
    "Show the current target distance below the arrow.",
    "showDistance", 18, -218
)

local miniTrail = CreateCheck(
    "QuestieWaypointArrowOptMiniTrail",
    "Show Minimap Trail",
    "Draw breadcrumb dots on the minimap toward the current arrow target.",
    "trailEnabled", 330, -82
)

local mapTrail = CreateCheck(
    "QuestieWaypointArrowOptMapTrail",
    "Show World Map Trail",
    "Draw breadcrumb dots on the world/zone map toward the current arrow target.",
    "worldMapTrailEnabled", 330, -116
)

local lock = CreateCheck(
    "QuestieWaypointArrowOptLock",
    "Lock Arrow",
    "Prevent dragging the arrow. Hold Shift while dragging to move it anyway.",
    "locked", 330, -150
)

local pickupRange = CreateSlider(
    "QuestieWaypointArrowOptPickupRange",
    "Maximum Quest Pickup Range (yards)",
    "With Smart Leveling enabled, new quest pickups farther away than this are never suggested. Active objectives and turn-ins are unaffected.",
    "smartPickupRange", 18, -278, 200, 1200, 50, 0
)

local arrowScale = CreateSlider(
    "QuestieWaypointArrowOptScale",
    "Arrow Scale",
    "Scale the arrow and target text.",
    "scale", 330, -278, 0.5, 3.0, 0.05, 2
)

local miniSize = CreateSlider(
    "QuestieWaypointArrowOptMiniSize",
    "Minimap Trail Dot Size",
    "Size of minimap breadcrumb dots.",
    "trailDotSize", 18, -342, 4, 14, 1, 0
)

local mapSize = CreateSlider(
    "QuestieWaypointArrowOptMapSize",
    "World Map Trail Dot Size",
    "Size of world-map breadcrumb dots.",
    "worldMapTrailDotSize", 330, -342, 4, 16, 1, 0
)

local spacing = CreateSlider(
    "QuestieWaypointArrowOptSpacing",
    "Minimap Trail Spacing (yards)",
    "Distance between minimap breadcrumb dots.",
    "trailSpacing", 18, -406, 20, 80, 5, 0
)

local refresh = CreateSlider(
    "QuestieWaypointArrowOptRefresh",
    "Target Refresh Seconds",
    "How often the arrow re-evaluates the best quest target.",
    "refresh", 330, -406, 0.25, 5.0, 0.25, 2
)

local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
reset:SetWidth(170)
reset:SetHeight(24)
reset:SetPoint("TOPLEFT", 18, -472)
reset:SetText("Reset Arrow Position")
reset:SetScript("OnClick", function()
    local addon = GetAddon()
    if addon and addon.ResetPosition then addon:ResetPosition() end
end)

local target = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
target:SetWidth(170)
target:SetHeight(24)
target:SetPoint("LEFT", reset, "RIGHT", 10, 0)
target:SetText("Print Current Target")
target:SetScript("OnClick", function()
    local addon = GetAddon()
    if addon and addon.PrintTarget then addon:PrintTarget() end
end)

local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
help:SetPoint("TOPLEFT", 18, -516)
help:SetWidth(610)
help:SetJustifyH("LEFT")
help:SetText("Slash commands: /qwa status, /qwa target, /qwa smart on|off, /qwa available on|off, /qwa pickuprange <200-1200>")

function panel:Refresh()
    local db = GetDB()
    if not db then return end
    refreshing = true

    for _, control in ipairs(controls) do
        if control.key then
            if control:GetObjectType() == "CheckButton" then
                control:SetChecked(db[control.key] and true or false)
            else
                control:SetValue(tonumber(db[control.key]) or 0)
            end
        end
    end

    local enabled = db.enabled and true or false
    SetControlEnabled(tracked, enabled)
    SetControlEnabled(available, enabled)
    SetControlEnabled(smart, enabled)
    SetControlEnabled(distance, enabled)
    SetControlEnabled(miniTrail, enabled)
    SetControlEnabled(mapTrail, enabled)
    SetControlEnabled(lock, enabled)

    SetControlEnabled(pickupRange, enabled and db.includeAvailable and db.smartLeveling)
    SetControlEnabled(arrowScale, enabled)
    SetControlEnabled(miniSize, enabled and db.trailEnabled)
    SetControlEnabled(mapSize, enabled and db.worldMapTrailEnabled)
    SetControlEnabled(spacing, enabled and db.trailEnabled)
    SetControlEnabled(refresh, enabled)

    refreshing = false
end

panel:SetScript("OnShow", function(self) self:Refresh() end)
InterfaceOptions_AddCategory(panel)

_G.QuestieWaypointArrow_OpenOptions = function()
    panel:Refresh()
    -- Calling twice works around the long-standing 3.3.5 category-scroll quirk.
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end
