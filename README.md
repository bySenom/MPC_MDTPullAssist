# MPC - MDT Pull Assist

A World of Warcraft addon for **Midnight 12.0.1** that displays the next pull from your [MythicDungeonTools](https://www.curseforge.com/wow/addons/mythic-dungeon-tools) route in real-time during Mythic+ dungeons.

Hooks into [MythicPlusCount](https://github.com/noobheartx/MythicPlusCount) as a standalone plugin via the Extras system — adds functionality without modifying the original addon.

## Features

- **Next Pull Display** — Shows the mobs, forces count, and percentage for the upcoming pull from your active MDT route
- **Auto Pull Tracking** — Automatically detects completed pulls using scenario forces + mob death tracking
- **Hybrid Detection** — Forces-based (primary) + NPC death tracking (secondary) for accurate pull completion
- **Out-of-Order Support** — Greedy matching handles groups that pull out of route order
- **Route Auto-Load** — Automatically reads the active MDT route when entering a M+ dungeon
- **Route Change Detection** — Detects when you switch MDT routes mid-dungeon
- **MPC Integration** — Registers into MPC's Extras system (settings tab, lock/unlock, visibility rules)
- **Secret Value Compatible** — Uses MPC's fingerprint-based mob identification; no direct NPC ID API calls affected by Midnight's secret value restrictions

## Supported Dungeons (Midnight Season 1)

| Dungeon | Challenge Map ID |
|---------|:---:|
| Pit of Saron | 556 |
| Skyreach | 161 |
| Windrunner Spire | 557 |
| Magisters' Terrace | 558 |
| Maisara Caverns | 560 |
| Nexus-Point Xenas | 559 |
| Algeth'ar Academy | 402 |
| Seat of the Triumvirate | 239 |

## Requirements

- **MythicPlusCount** (required dependency)
- **MythicDungeonTools** (required dependency)

## Installation

1. Download or clone this repository into your WoW AddOns folder:
   ```
   World of Warcraft\_retail_\Interface\AddOns\MPC_MDTPullAssist\
   ```
2. Make sure MythicPlusCount and MythicDungeonTools are also installed
3. Reload your UI (`/reload`)

## Usage

### Slash Commands

| Command | Description |
|---------|-------------|
| `/mdtpa` or `/mdtpa show` | Show the pull assist frame |
| `/mdtpa hide` | Hide the pull assist frame |
| `/mdtpa reload` | Reload the MDT route |
| `/mdtpa reset` | Reset pull tracking |
| `/mdtpa status` | Print current route and pull info to chat |
| `/mdtpa pull N` | Jump to pull #N |
| `/mdtpa help` | Show all commands |

### Settings

Open MythicPlusCount settings (`/mpc`) → Enable **MDT Pull Assist** in the Extras section. Options include:

- Show/hide mob names, forces count, forces percent
- Completion threshold slider (default 90%)
- Reload route / Reset tracking buttons

### Right-Click Menu

Right-click the pull assist frame for quick actions:
- Reload Route
- Reset Tracking
- Next/Previous Pull
- Hide

## How It Works

1. **Route Reading** — On dungeon entry, reads the active MDT preset for the current dungeon and resolves each pull's mobs (npcID, name, forces) from `MDT.dungeonEnemies`
2. **Mapping Bridge** — Translates between MPC's `challengeMapID` and MDT's `dungeonIdx` via a static mapping table
3. **Pull Tracking** — Monitors `SCENARIO_CRITERIA_UPDATE` (forces gained) and `COMBAT_LOG_EVENT UNIT_DIED` (specific mob deaths) to determine which pulls are complete
4. **Display** — Shows the next incomplete pull with aggregated mob counts (e.g., "3× Arcane Magister"), forces, and cumulative progress

### Secret Values (Midnight 12.0)

Blizzard restricts NPC identification inside M+ instances via `issecretvalue()`. This addon handles it:

- **MDT data** — NPC IDs are loaded from `.lua` data files at addon init (not affected by runtime secret value checks)
- **MPC identification** — Uses compound fingerprints (model ID, level, class, etc.) to identify mobs on nameplates
- **Our tracking** — Primary tracking uses scenario forces (no NPC IDs needed); secondary tracking uses `COMBAT_LOG_EVENT` GUIDs which may be secret inside instances but gracefully falls back to forces-only tracking

## File Structure

```
MPC_MDTPullAssist/
├── MPC_MDTPullAssist.toc   -- Addon manifest
├── mapping.lua             -- challengeMapID ↔ MDT dungeonIdx bridge
├── route_reader.lua        -- MDT route/preset parsing
├── tracker.lua             -- Pull completion tracking
├── display.lua             -- UI frame for next pull
├── options.lua             -- Settings tab (MPC Extras)
├── core.lua                -- Init, events, slash commands
└── README.md
```

## License

MIT
