# Strait events — design catalog

**Canonical implementation:** `src/shared/Config/StraitEvents/Catalog.luau` (single source of truth for ids, severity pools, flags, tuning blocks, and optional `playtestTitle`).  
**Systems spec:** [SPEC.md](./SPEC.md) — **client VFX:** `src/client/StraitWaypointWorldFx.luau`; **playtest banner:** `src/client/UI/StraitEventPlaytestBanner.luau`.

This document describes **fantasy**, **player feel**, and **how each row maps to code**. If this file disagrees with `Catalog.luau`, **trust the Luau module**.

---

## Design template (copy for each new event)

```markdown
### `<id>` (e.g. `SmugglerShakedown`)

| Field | Value |
|-------|--------|
| **Severity** | Low \| Medium \| High |
| **displayName** | Short player-facing line |
| **playtestTitle** | (Optional) override for temporary full-screen banner |
| **Fantasy** | What happened in the strait (1–3 sentences) |
| **Player feels** | Delayed? Robbed? Lucky escape? |
| **Mechanics** | Flags: `stormEvent`, `tornadoEvent`, `priceMultiplierFactor`, `looseBarrelLossFraction`, `missileEvent`, etc. |
| **Catalog row** | Paste the Luau table row when implemented |
| **Status** | Draft \| Ready \| In catalog \| Cut |
```

**Mechanics reference (fields on `StraitEventDef`):**

| Knob | Effect |
|------|--------|
| `priceMultiplierFactor` | Multiplies running `shipment.priceMultiplier` (stacks across events) |
| `skipWaypointPause` | If true: no wait at waypoint (rare); else `pauseSeconds` or **`DefaultWaypointPauseSeconds` (~5s)** |
| `pauseSeconds` | Override pause when the generic strait waypoint path waits |
| `totalLoss` | Marks shipment for failure when combined with server branches (e.g. slap, mine hit, missile hit) |
| `looseBarrelLossFraction` | e.g. `0.25` → **`ceil(onShipBarrels × fraction)`** whole barrels removed (HeavyCrude → LightSweet → PremiumRefined) |
| `missileEvent` / `mineEvent` / `pirateEvent` / `stormEvent` / `tornadoEvent` / `coastGuardEvent` / `usShipSlapEvent` | Select dedicated server + client cinematic pipelines (`MissileStrikeEvent`, `StormEvent`, …) |

*Known gap:* deck **visual** barrel count is set at load; mid-voyage loss updates **manifest / payout** until deck sync exists.

---

## Severity bands (design intent)

| Severity | Typical fantasy | Success impact |
|----------|-----------------|----------------|
| **Low** | Annoyance, paperwork, light scrutiny | Small time sink and/or small payout trim |
| **Medium** | Weather, raids, smoke | Pause + payout and/or scripted loss rolls; run usually continues |
| **High** | Catastrophic | Total loss (slap / mine hit / missile hit) or near-loss tornado/storm rolls |

---

## Summary — active catalog (`Catalog.Events`)

Waypoints follow **`StraitEventConfig.LaneWaypointTriggers`** (lane ordinals **2–9**).

| Severity | `id` | `displayName` | Server / client pipeline | Impacts (high level) |
|----------|------|-----------------|--------------------------|----------------------|
| **Low** | `RoutinePaperwork` | Routine paperwork | `StraitWaypointEvent` + `RoutinePaperwork` FX hook | Default pause; **×0.97** payout |
| **Low** | `CoastGuardInspection` | Coast guard inspection | **`CoastGuardInspectionEvent`** (merged old *glance* into this one row) | Full inspection sequence; no automatic barrel strip from catalog row |
| **Low** | `HighWinds` | High winds | **`TornadoEvent`** (same as `Tornado`: `TornadoConfig` rolls + tornado VFX) | Delay / barrel-loss per tornado math—not the old “pause only” high-winds row |
| **Medium** | `EngineRoomSmoke` | Engine room smoke | `StraitWaypointEvent` only (no bespoke world FX yet) | **~10s** `EXT` pause; **×0.9** payout |
| **Medium** | `PirateRaid` | Pirate raid | **`PirateRaidEvent`** | **`ceil(25% × barrels)`** removed; default pause |
| **Medium** | `Storm` | Thunderstorm | **`StormEvent`** + `StormConfig` | Replaces old fixed-fraction **Turbulent seas**; delay + optional fractional barrel loss per storm rolls |
| **High** | `USShipSlap` | Government seizure | **`USShipSlapEvent`** | Total loss via slap cinematic (replaces old **Boarding and seizure** row) |
| **High** | `Tornado` | Strait tornado | **`TornadoEvent`** + `TornadoConfig` | Same pipeline as **HighWinds** id with different display name |
| **High** | `MineStrike` | Mine strike | **`MineStrikeEvent`** + `MineConfig` | Hit → total loss; survive → no loss |
| **High** | `MissileStrike` | Missile strike | **`MissileStrikeEvent`** + `MissileConfig` | Barrage; direct hit → total loss; small hit → partial barrels |

**Playtest visibility:** server adds **`playtestTitle`** to strait payloads (defaults via `Catalog.GetPlaytestTitle` → `displayName`). Client shows a large temporary banner (`StraitEventPlaytestBanner`) for these kinds; missile barrage shows the title once (first missile only).

---

## Per-event notes (aligned with code)

### `RoutinePaperwork`

| Field | Value |
|-------|--------|
| **Pipeline** | Generic `StraitWaypointEvent`; custom `EVENT_FX["RoutinePaperwork"]` in `StraitWaypointWorldFx` |
| **Mechanics** | `priceMultiplierFactor = 0.97`; default waypoint pause |

### `CoastGuardInspection`

| Field | Value |
|-------|--------|
| **Pipeline** | `CoastGuardInspectionEvent`; duration from `CoastGuardInspectionConfig` |
| **Note** | Former **`CoastGuardGlance`** row removed—same inspection experience, one catalog id |

### `HighWinds`

| Field | Value |
|-------|--------|
| **Pipeline** | `tornadoEvent = true` → **`TornadoEvent`** (assets under `StraitWaypointsFx/Tornado`, etc.) |
| **Note** | Fantasy copy can stay “high winds”; gameplay is **tornado** rolls, not legacy extended-pause-only |

### `EngineRoomSmoke`

| Field | Value |
|-------|--------|
| **Pipeline** | `StraitWaypointEvent` only |
| **Mechanics** | `pauseSeconds = EXT`; `priceMultiplierFactor = 0.9` |

### `PirateRaid`

| Field | Value |
|-------|--------|
| **Pipeline** | `PirateRaidEvent`; `PirateRaidConfig` timing |
| **Mechanics** | `looseBarrelLossFraction = 0.25` before cinematic |

### `Storm`

| Field | Value |
|-------|--------|
| **Pipeline** | `StormEvent`; `StormConfig` for delay + barrel-loss chance/fraction ranges |
| **Note** | Former **`TurbulentSeas`** (`looseBarrelLossFraction = 0.1`) removed in favor of this stochastic storm model |

### `USShipSlap`

| Field | Value |
|-------|--------|
| **Pipeline** | `USShipSlapEvent`; `USShipSlapConfig` |
| **Mechanics** | Total loss after slap sequence |
| **Note** | Former **`BoardingAndSeizure`** (`StraitWaypointEvent` total loss only) removed—use this slap pipeline |

### `Tornado`

| Field | Value |
|-------|--------|
| **Pipeline** | `TornadoEvent`; `TornadoConfig` |

### `MineStrike` / `MissileStrike`

| Field | Value |
|-------|--------|
| **Pipeline** | `MineStrikeEvent` / `MissileStrikeEvent` with respective config tables |
| **Mechanics** | See `MineConfig` / `MissileConfig` in `Catalog.luau` |

---

## Removed ids (consolidation v2, 2026-04)

| Removed `id` | Replaced by |
|----------------|-------------|
| `CoastGuardGlance` | `CoastGuardInspection` (`CoastGuardInspectionEvent`) |
| `MinorInspection` | *cut* |
| `ExtendedInspection` | *cut* |
| `FuelSiphoningAttempt` | *cut* |
| `TurbulentSeas` | `Storm` (`StormEvent` + `StormConfig`) |
| `BoardingAndSeizure` | `USShipSlap` (`USShipSlapEvent`) |

---

## Quick numeric summary (matches `Catalog.luau`)

| id | Sev | Price × | Pause | Special flags |
|----|-----|---------|-------|----------------|
| RoutinePaperwork | Low | 0.97 | default ~5s | — |
| CoastGuardInspection | Low | — | inspection seq | `coastGuardEvent` |
| HighWinds | Low | — | tornado seq | `tornadoEvent` |
| EngineRoomSmoke | Med | 0.9 | EXT ~10s | — |
| PirateRaid | Med | — | pirate seq + default WP pause | `pirateEvent`, `looseBarrelLossFraction=0.25` |
| Storm | Med | — | storm seq | `stormEvent` |
| USShipSlap | High | — | slap seq | `usShipSlapEvent`, `totalLoss` |
| Tornado | High | — | tornado seq | `tornadoEvent` |
| MineStrike | High | — | mine seq | `mineEvent`, `totalLoss` |
| MissileStrike | High | — | missile seq | `missileEvent`, `totalLoss` |

---

## Backlog — events to design

| id (proposed) | Severity (target) | One-line hook | Status |
|---------------|-------------------|---------------|--------|
| | | | |

---

## Workflow

1. Edit **`Catalog.luau`** first (new row + tuning block if needed).  
2. Update **this file** summary + per-event notes.  
3. If networking or client contract changes, update **SPEC.md**.  
4. Playtest (`Constants.StraitEventsDebug`, strait dev UI, banner visibility).

---

## Revision history

| Date | Note |
|------|------|
| 2026-04-09 | **v2 consolidation:** `Catalog.luau` is authoritative; merged glance→inspection, high winds→tornado pipeline, turbulent→storm, boarding→USShipSlap; cut minor/extended/fuel events; `playtestTitle` + playtest banner; this doc rewritten to match code. |
| 2026-04-10 | Initial EVENTS.md + v1 catalog (superseded by v2 rows above). |
