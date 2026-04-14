# Strait events — design catalog

**Code:** `src/shared/Config/StraitEvents/Catalog.luau`  
**Systems spec:** [SPEC.md](./SPEC.md) — **client VFX/SFX/HUD contract & handoff:** [SPEC §8](./SPEC.md#8-implementation-details-client)

Use this file to **list and design** each event before (or while) you add it to `Catalog.Events`. Severity pools are chosen by **strait event bracket** (Open / Restricted / Closed), not by individual event—see SPEC §4.5.

---

## Design template (copy for each new event)

```markdown
### `<id>` (e.g. `SmugglerShakedown`)

| Field | Value |
|-------|--------|
| **Severity** | Low \| Medium \| High |
| **displayName** | Short player-facing line |
| **Fantasy** | What happened in the strait (1–3 sentences) |
| **Player feels** | Delayed? Robbed? Lucky escape? |
| **Mechanics** | Map to: price mult, pause, skipPause, totalLoss, `looseBarrelLossFraction` (spill whole barrels) |
| **Catalog row** | Paste the Luau table row when implemented |
| **Status** | Draft \| Ready \| In catalog \| Cut |
```

**Mechanics reference (what code supports today):**

| Knob | Effect |
|------|--------|
| `priceMultiplierFactor` | Multiplies running `shipment.priceMultiplier` (stacks across events) |
| `skipWaypointPause` | If true: no wait at waypoint (rare); if false/omit: `pauseSeconds` or **`DefaultWaypointPauseSeconds` (5s)** |
| `pauseSeconds` | Override pause duration when pausing |
| `totalLoss` | Shipment ends immediately; no payout; failure reason |
| `looseBarrelLossFraction` | e.g. `0.1` → remove **`ceil(onShipBarrels * 0.1)`** whole barrels from manifest (1-barrel case removes 1); tier order **HeavyCrude → LightSweet → PremiumRefined** |

*Known gap:* deck **visual** barrel count is set at load; mid-voyage loss updates **manifest / payout** only until a visual refresh exists.

*Future (not in code yet):* extra voyage time without pause, scripted VFX id, minimum strait bracket only, etc. Note those under **Future hooks**.

---

## Severity bands (design intent)

| Severity | Typical fantasy | Success impact |
|----------|-----------------|----------------|
| **Low** | Annoyance, paperwork, light scrutiny | Small time sink and/or small payout trim |
| **Medium** | Real trouble: inspections, sabotage, cargo loss | Meaningful pause + payout hit and/or barrel loss; player still finishes run |
| **High** | Catastrophic | **Total loss** today, or (if you add more highs later) near-loss variants |

---

## Summary table — all events (fantasy & impacts)

| Severity | `id` | displayName | Fantasy | Impacts (gameplay) |
|----------|------|-------------|---------|-------------------|
| **Low** | `RoutinePaperwork` | Routine paperwork | Minor paperwork snag; convoy idles in channel traffic while clerks sort it. | **~5s** pause; **−3%** payout mult (`×0.97`). |
| **Low** | `CoastGuardGlance` | Coast guard glance | Patrol shadows you; crew runs a rough “safety” drill—cargo rattles but nothing is lost. | **~5s** pause; payout mult unchanged. |
| **Low** | `MinorInspection` | Minor inspection | Quick document/manifest hold; small fee and readiness ding. | **~10s** pause; **−5%** payout mult (`×0.95`). |
| **Low** | `HighWinds` | High winds | Heavy gusts; master heaves to until it eases. | **~10s** pause only (no price / barrel changes). |
| **Medium** | `TurbulentSeas` | Turbulent seas | **Turbulent seas**—the boat **powers through**, but **loses some barrels** as swells work lashings loose and cargo goes over the rail. | **`ceil(10% × on-ship barrels)`** whole barrels removed (Heavy→…→Premium tier order); **~5s** pause; manifest + `totalLoaded` updated for payout. |
| **Medium** | `PirateRaid` | Pirate raid | Pirates board and grab cargo; your **crew fights them off in time**—but not before they **make off with some barrels**. | **`ceil(25% × on-ship barrels)`** whole barrels removed (same tier order as Turbulent Seas); **~5s** pause; manifest + `totalLoaded` updated. |
| **Medium** | `ExtendedInspection` | Extended inspection | Full stop for search and paperwork; time burns; penalties stack. | **~10s** pause; **−12%** payout mult (`×0.88`). |
| **Medium** | `FuelSiphoningAttempt` | Fuel siphoning attempt | Skiffs at night; crew drives them off—fuel and money lost; brief stop to assess. | **~5s** pause; **−18%** payout mult (`×0.82`). |
| **Medium** | `EngineRoomSmoke` | Engine room smoke | Smoke in engineering; crew secures; slowdown and cargo stress. | **~10s** pause; **−10%** payout mult (`×0.9`). |
| **High** | `BoardingAndSeizure` | Boarding and seizure | Armed boarding; cargo seized; voyage ends. | **Total loss** (no payout); **~5s** hold for VFX then cleanup. |
| **High** | `MineStrike` | Mine strike | Drifting hazard / ordnance; catastrophic hit. | **Total loss**; **~5s** hold then cleanup. |
| **High** | `MissileStrike` | Missile strike | Missiles demolish the shipment. | **Total loss**; **~5s** hold then cleanup. |

Pause lengths use **`DefaultWaypointPauseSeconds` (5)** or **`ExtendedWaypointPauseSeconds` (10)** from `StraitEventConfig` unless overridden per event.

---

## Implemented events (v1 — matches `Catalog.luau`)

Numbers below are **exactly** what the repo uses; change the catalog first, then update this table.

### `RoutinePaperwork`

| Field | Value |
|-------|--------|
| **Severity** | Low |
| **displayName** | Routine paperwork |
| **Fantasy** | Authorities flag a minor documentation mismatch; clerks process it while the convoy idles in channel traffic. |
| **Player feels** | Small administrative tax on the run. |
| **Mechanics** | **3%** effective payout trim (`priceMultiplier × 0.97`); **default pause (~5s)**. |
| **Catalog** | `priceMultiplierFactor = 0.97` |
| **Status** | In catalog |

---

### `CoastGuardGlance`

| Field | Value |
|-------|--------|
| **Severity** | Low |
| **displayName** | Coast guard glance |
| **Fantasy** | A patrol boat shadows you briefly; no full stop, but the crew runs a sloppy “safety” drill that rattles cargo. |
| **Player feels** | Nervous moment; no lasting cargo loss. |
| **Mechanics** | No price mult change; **default pause (~5s)**. |
| **Catalog** | `priceMultiplierFactor = 1` |
| **Status** | In catalog |

---

### `MinorInspection`

| Field | Value |
|-------|--------|
| **Severity** | Low |
| **displayName** | Minor inspection |
| **Fantasy** | Quick hold for a document and manifest check; small “processing fee” and a ding to readiness. |
| **Player feels** | Longer hold + light double penalty. |
| **Mechanics** | **Extended pause (~10s)**; **5%** payout trim (`× 0.95`). |
| **Catalog** | `pauseSeconds = ExtendedWaypointPauseSeconds`, `priceMultiplierFactor = 0.95` |
| **Status** | In catalog |

---

### `HighWinds`

| Field | Value |
|-------|--------|
| **Severity** | Low |
| **displayName** | High winds |
| **Fantasy** | Heavy gusts or a nasty blow; the master heaves to and holds station until it eases. |
| **Player feels** | Shipment **held ~10s** at the waypoint; tune `ExtendedWaypointPauseSeconds` later. |
| **Mechanics** | **`ExtendedWaypointPauseSeconds` (~10s)** only—no payout multiplier change, no barrel loss (pure delay). |
| **Catalog** | `pauseSeconds = EXT` (`ExtendedWaypointPauseSeconds`) |
| **Status** | In catalog |

---

### `TurbulentSeas`

| Field | Value |
|-------|--------|
| **Severity** | Medium |
| **displayName** | Turbulent seas |
| **Fantasy** | **Turbulent seas**—the boat **powers through**, but **loses some barrels** as heavy swells work lashings loose and cargo slides over the rail. |
| **Player feels** | Still moving; lost cargo—**whole barrels only**; 1-barrel loads still lose that one barrel. |
| **Mechanics** | **`looseBarrelLossFraction = 0.1`** → barrels removed = **`ceil(onShipTotal × 0.1)`** (e.g. 2 → `ceil(0.2)` = **1**). Removed from tiers **Heavy → Standard → Light → Premium** first. **`totalLoaded`** and manifest updated for end-of-trip payout. Then **default waypoint pause (~5s)**. |
| **Catalog** | `looseBarrelLossFraction = 0.1` |
| **Status** | In catalog |

---

### `PirateRaid`

| Field | Value |
|-------|--------|
| **Severity** | Medium |
| **displayName** | Pirate raid |
| **Fantasy** | Pirates come alongside and steal barrels in the chaos; your **crew drives them off** before they can take the ship—but they **get away with part of the load**. |
| **Player feels** | Serious cargo hit; you **keep the run** (not total loss). |
| **Mechanics** | **`looseBarrelLossFraction = 0.25`** → **`ceil(onShipTotal × 0.25)`** whole barrels (same rules as **TurbulentSeas**: min 1 when math rounds up from a partial barrel, Heavy→…→Premium removal order). **~5s** default pause. |
| **Catalog** | `looseBarrelLossFraction = 0.25` |
| **Status** | In catalog |

---

### `ExtendedInspection`

| Field | Value |
|-------|--------|
| **Severity** | Medium |
| **displayName** | Extended inspection |
| **Fantasy** | Full stop for search and paperwork; time burns and inspectors “find” reasons to assess penalties. |
| **Player feels** | This run is getting expensive. |
| **Mechanics** | **Extended pause (~10s)**; **12%** payout trim (`× 0.88`). |
| **Catalog** | `pauseSeconds = EXT`, `priceMultiplierFactor = 0.88` |
| **Status** | In catalog |

---

### `FuelSiphoningAttempt`

| Field | Value |
|-------|--------|
| **Severity** | Medium |
| **displayName** | Fuel siphoning attempt |
| **Fantasy** | Skiffs try to rob stores at night; crew drives them off but fuel and time are lost; brief full stop while damage is assessed. |
| **Player feels** | Hit to economics; **~5s** hold for VFX. |
| **Mechanics** | **Default pause (~5s)**; **18%** payout trim (`× 0.82`). |
| **Catalog** | No `pauseSeconds` / no `skipWaypointPause` → uses default **5s** |
| **Status** | In catalog |

---

### `EngineRoomSmoke`

| Field | Value |
|-------|--------|
| **Severity** | Medium |
| **displayName** | Engine room smoke |
| **Fantasy** | Electrical/smoke alarm; crew secures engineering; slowdown and cargo stress. |
| **Player feels** | Longer hold + payout slip. |
| **Mechanics** | **Extended pause (~10s)**; **10%** payout trim (`× 0.9`). |
| **Catalog** | `pauseSeconds = EXT`, `priceMultiplierFactor = 0.9` |
| **Status** | In catalog |

---

### `BoardingAndSeizure`

| Field | Value |
|-------|--------|
| **Severity** | High |
| **displayName** | Boarding and seizure |
| **Fantasy** | Armed boarding; cargo confiscated; voyage ends in failure. |
| **Player feels** | Run over; prepare insurance upgrades later. |
| **Mechanics** | **`totalLoss = true`**; **~5s** hold after fire (default pause) for destruction VFX, then cleanup. |
| **Catalog** | `totalLoss = true` |
| **Status** | In catalog |

---

### `MineStrike`

| Field | Value |
|-------|--------|
| **Severity** | High |
| **displayName** | Mine strike |
| **Fantasy** | Drifting hazard or old ordnance; catastrophic damage; total loss. |
| **Player feels** | Sudden end; different fantasy than boarding for variety in High pool. |
| **Mechanics** | **`totalLoss = true`**; **~5s** animation hold before cleanup. |
| **Catalog** | `totalLoss = true` |
| **Status** | In catalog |

---

### `MissileStrike`

| Field | Value |
|-------|--------|
| **Severity** | High |
| **displayName** | Missile strike |
| **Fantasy** | Missiles hit the vessel; the shipment is demolished—nothing salvable. |
| **Player feels** | Instant total loss; distinct from boarding or mine strike. |
| **Mechanics** | **`totalLoss = true`**; **~5s** animation hold before cleanup. |
| **Catalog** | `id = "MissileStrike"`, `totalLoss = true` |
| **Status** | In catalog |

---

## Quick numeric summary (v1)

| id | Sev | Price × | Pause | skipPause | totalLoss |
|----|-----|---------|-------|-----------|-----------|
| RoutinePaperwork | Low | 0.97 | **~5s** default | no | no |
| CoastGuardGlance | Low | 1 | **~5s** default | no | no |
| MinorInspection | Low | 0.95 | **~10s** EXT | no | no |
| HighWinds | Low | — | **~10s** EXT | no | no |
| TurbulentSeas | Med | — | **~5s** default | no | no |
| PirateRaid | Med | — | **~5s** default | no | no |
| ExtendedInspection | Med | 0.88 | **~10s** EXT | no | no |
| FuelSiphoningAttempt | Med | 0.82 | **~5s** default | no | no |
| EngineRoomSmoke | Med | 0.9 | **~10s** EXT | no | no |
| BoardingAndSeizure | High | — | — | **~5s** (then loss) | — | **yes** |
| MineStrike | High | — | — | **~5s** (then loss) | — | **yes** |
| MissileStrike | High | — | — | **~5s** (then loss) | — | **yes** |

**Barrel-loss events:** `TurbulentSeas` → `looseBarrelLossFraction = 0.1`; `PirateRaid` → `0.25` (whole barrels, `ceil`, same tier order; not in columns above).

---

## Backlog — events to design

Add rows as ideas; promote to a full template + `Catalog` entry when ready.

| id (proposed) | Severity (target) | One-line hook | Status |
|---------------|-------------------|---------------|--------|
| | | | |
| | | | |

---

## Workflow

1. Fill a **template** section (or a backlog row) with fantasy + mechanics.  
2. Map mechanics to **existing** fields only, or note **code change** needed in SPEC / task.  
3. Append to `Catalog.Events` and add the row to **Quick numeric summary**.  
4. Playtest in Studio (strait dev UI + debug logs) and tune numbers.

---

## Revision history

| Date | Note |
|------|------|
| 2026-04-10 | Initial EVENTS.md: template + v1 catalog documented. |
| 2026-04-10 | Added **WeatherHazard** (Low, 10s pause only). |
| 2026-04-10 | Renamed to **HighWinds**; added **TurbulentSeas** (Medium, `looseBarrelLossFraction` 10%, whole barrels). |
| 2026-04-10 | Added **MissileStrike** (High, `totalLoss`). |
| 2026-04-10 | Global pause policy: **5s** default, **10s** `ExtendedWaypointPauseSeconds` for former long-pause events; **5s** hold before total-loss cleanup; **FuelSiphoningAttempt** no longer skips pause. |
| 2026-04-10 | Added **Summary table** (all events); **TurbulentSeas** fantasy: powers through + loses barrels. |
| 2026-04-10 | Added **PirateRaid** (Medium, 25% barrel loss, crew wards off pirates). |
| 2026-04-10 | Removed **hull / HP delivery gate**: no `hullDamageFraction`; voyage delivery uses manifest minus barrel-loss events only. Docs + catalog aligned. |
