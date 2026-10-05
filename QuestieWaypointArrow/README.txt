Questie Waypoint Arrow 1.1.0
============================

Standalone companion addon for Questie-335 on WoW 3.3.5a.

WHY THIS VERSION
----------------
This package keeps Questie itself untouched, so Questie can be replaced or
updated normally. The arrow reads Questie's live quest/map data at runtime.

FEATURES
--------
- Waypoint arrow for tracked quest objectives and turn-ins
- Optional available-quest pickup suggestions
- Smart Leveling Suggestions
- Distance-aware smart routing: nearby turn-in > nearby pickup > nearby objective > distant turn-in
- Hard Maximum Quest Pickup Range for new quest pickups
- Minimap breadcrumb trail
- World-map breadcrumb trail
- Movable/lockable/scalable arrow
- Own standalone saved settings
- One-time migration of settings from the previous embedded Questie port

INSTALL
-------
1. Restore/install the normal maintained Questie-335 build.
2. Remove the modified Questie-335 waypoint-port folder rather than merging it.
3. Put the QuestieWaypointArrow folder beside Questie-335 in Interface/AddOns.
4. Reload/login.

Questie remains required. The addon waits for Questie to finish starting before
it initializes, and it does not ship any quest database of its own.

COMMANDS
--------
/qwa
/qwa options
/qwa status
/qwa target
/qwa smart on|off
/qwa available on|off
/qwa pickuprange 200-1200
/qwa trail on|off
/qwa maptrail on|off
/qwa lock | unlock | reset
/qwa scale 0.5-3

NOTES
-----
The addon intentionally uses Questie runtime modules such as QuestieDB,
QuestieMap, AvailableQuests and HereBeDragons rather than copying Questie's
quest database. If an upstream Questie update renames those internal modules,
the companion may need a small compatibility update, but Questie itself will
remain clean and updateable.

SMART ROUTE PRIORITY (1.1.0)
----------------------------
When Smart Leveling Suggestions is enabled, completed quests are no longer an
unconditional top priority. The route now prefers:

1. Completed turn-ins within 350 yards
2. Recommended quest pickups inside Maximum Quest Pickup Range
3. Active objectives when a hand-in is a long detour and the objective is local
   (within 700 yards) or saves at least 250 yards of immediate travel
4. The distant completed turn-in
5. Remaining active/fallback quest targets

The Maximum Quest Pickup Range still applies ONLY to new quest pickups. It does
not hide active objectives or completed turn-ins. `/qwa status` reports the
current routeDecision to make routing behaviour easier to diagnose.
