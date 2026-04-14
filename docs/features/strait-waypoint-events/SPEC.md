# Strait waypoint shipment events — SPEC

Authoritative handoff for **oil shipment** strait events: design intent, tuning numbers, and **what is implemented** in this repository. **Canonical event list and numbers:** `src/shared/Config/StraitEvents/Catalog.luau` (this SPEC summarizes behavior).

---

## 1. Goal

- During each **oil shipment** voyage, evaluate **up to three** independent strait events at **fixed lane waypoints** (ordinals **3, 6, 9** along the sorted route polyline).
- Event **chance** and **severity pool** depend on the **current global strait state** at the moment the ship **crosses** each trigger (strait may change mid-voyage).
- Outcomes are **server-authoritative**; **all clients** receive notifications so other players can see that something happened to a shipment.
- **Legacy** time-random voyage hazard ticks on the shipment timeline are **removed** for oil in favor of this system.
- **Future:** player upgrades may reduce event chance; boat `eventRisk` in config is reserved for that (not used yet).

---

## 2. Out of scope (this slice)

- **Implementation** of world VFX/SFX/HUD (covered by **locked plan §8.2–8.5**; assign to gameplay / UI implementers).
- Per-player mitigation upgrades (design hook reserved).
- Adding engine states beyond **Open / Restricted / Closed** (the model is fixed at three).

---

## 3. Files / modules

| Area | Path |
|------|------|
| Event catalog (**single source of truth**; ids, flags, tuning) | `src/shared/Config/StraitEvents/Catalog.luau` |
| Per-event design writeups + backlog | [EVENTS.md](./EVENTS.md) |
| Playtest full-screen title (temporary) | `src/client/UI/StraitEventPlaytestBanner.luau` + `init.client` `ShipmentVisualEvent` |
| Strait world VFX module | `src/client/StraitWaypointWorldFx.luau` |
| Occurrence/severeity tuning, lane trigger ordinals, default pause | `src/shared/Config/StraitEventConfig.luau` |
| Voyage loop, crossing detection, apply event, pause clock | `src/server/Services/OilShipmentService.luau` |
| Global strait state (Open, Restricted, Closed) | `src/shared/Config/StraitConfig.luau` |
| Strait state replication / rolls | `src/server/Services/StraitStateService.luau` |
| Server bootstrap (Telemetry + Strait + OilShipment wiring) | `src/server/init.server.luau` |
| Client broadcast handling for strait events | `src/client/init.client.luau` |
| Visual remote | `RemoteNames.ShipmentVisualEvent` → `ShipmentVisualEvent` |
| Strait presentation (VFX/SFX; branches on `packet.type`) | `StraitWaypointWorldFx` required from `init.client` — see **§8.2** |
| Interim strait title banner | `StraitEventPlaytestBanner` — see **§8.3** |

---

## 4. Architecture

### 4.1 Path and triggers

- `OilShipmentService` builds `path[1] = dock`, then `path[2..]` = lane waypoint positions (parts under each lane folder, sorted by **numeric name**).
- **Lane waypoint ordinal N** corresponds to **`path[1 + N]`**.
- Triggers are at **N ∈ { 3, 6, 9 }** → **`path[4]`, `path[7]`, `path[10]`**.
- Cumulative distance along the polyline to vertex `path[k]` uses existing `segDists[k]`.
- **Crossing:** fire when `prevTargetDist < segDists[pathIndex] <= targetDist` (handles frame skips).
- Each ordinal fires **at most once** per shipment.
- If a lane has **fewer than 9** waypoints, missing path indices are **omitted** (no trigger for that slot).

### 4.2 Strait state read time

- **Crossing time:** `OilShipmentService:_handleStraitWaypointTrigger` reads `StraitStateService:GetCurrentState()` **when the crossing is processed**, not at dispatch. If the strait escalates mid-trip, later waypoints use harder odds.

### 4.3 Engine states and event brackets

The live game uses **three** values from `StraitConfig` / `StraitStateService`: **`Open`**, **`Restricted`**, **`Closed`**. **Event math** uses the **same three names** as brackets (no separate “engine vs public” tier list).

Implementation: `StraitEventConfig.PublicBracketFromEngineState` (identity for the three states). **Legacy** persisted strings `Tense` / `Dangerous` / `Crisis` from older saves are mapped to **Restricted** / **Restricted** / **Closed** when read from MemoryStore or MessagingService.

### 4.4 Occurrence probability (per trigger, independent rolls)

Each of the three waypoints rolls separately:

| Bracket | P(event at this waypoint) |
|---------|----------------------------|
| Open | **10%** |
| Restricted | **50%** |
| Closed | **80%** (fixed at 80%, not 80–90%) |

**Closed** is intentionally harsh to discourage shipping during closure; tuning note in product: upgrades will later soften this.

### 4.5 Severity pool (given that an event fires)

| Bracket | Severity rules |
|---------|----------------|
| Open | **Low only** |
| Restricted | **25%** High; remaining **75%** split **50/50** Low vs Medium |
| Closed | **No Low** — **50%** Medium, **50%** High |

(`RestrictedHighChance` and `ClosedMediumChance` live in `StraitEventConfig`.)

### 4.6 Event selection

- After severity is chosen, a concrete event is picked uniformly from `StraitEventCatalog.GetPool(severity)`.
- New gameplay events are added as rows in `Catalog.Events` with `id`, `severity`, `displayName`, and effect fields (see §6).

### 4.7 Networking

- Server fires `ShipmentVisualEvent` with `type` set per pipeline, e.g. **`StraitWaypointEvent`** (generic pause / multiplier / simple FX), **`StormEvent`**, **`TornadoEvent`**, **`PirateRaidEvent`**, **`CoastGuardInspectionEvent`**, **`USShipSlapEvent`**, **`MineStrikeEvent`**, **`MissileStrikeEvent`**. Each `data` table includes **`eventId`**, **`displayName`**, **`playtestTitle`** (for playtest banner; from `Catalog.GetPlaytestTitle`), **`ownerUserId`**, **`shipmentId`**, **`severity`**, **`worldPosition`**, plus kind-specific fields.
- **All clients** receive the same packets; handlers in `init.client` run world FX and status copy for owners vs non-owners.

Legacy **`ShipmentEvent`** (random voyage hazard ticks on the non–oil shipment path) is **no longer emitted** by `OilShipmentService`.

---

## 5. Event definition schema (`Catalog.luau`)

Each event may set:

| Field | Meaning |
|-------|---------|
| `id` | Stable string id |
| `severity` | `Low` \| `Medium` \| `High` |
| `displayName` | UI / status string |
| `playtestTitle` | Optional; if set, preferred line for interim full-screen banner (else `displayName`) |
| `totalLoss` | On catalog row: marks intent; **actual** total loss is applied in the branch that handles `usShipSlapEvent`, mine hit, missile direct hit, or rare generic `StraitWaypointEvent` total loss |
| `priceMultiplierFactor` | Multiplies cumulative `shipment.priceMultiplier` (applied at payout resolution) |
| `skipWaypointPause` | If true: **no** default pause at waypoint (explicit opt-out) |
| `pauseSeconds` | If pausing: override default pause length (catalog may use `ExtendedWaypointPauseSeconds`) |
| `looseBarrelLossFraction` | Whole-barrel strip before/around cinematics (e.g. pirate raid); tier order Heavy → … → Premium |
| `missileEvent` / `mineEvent` / `pirateEvent` / `stormEvent` / `tornadoEvent` / `coastGuardEvent` / `usShipSlapEvent` | Select dedicated `OilShipmentService` + client handlers (`MissileStrikeEvent`, …) |

**Default pause:** unless `skipWaypointPause`, generic `StraitWaypointEvent` path uses `pauseSeconds` or **`DefaultWaypointPauseSeconds` (~5s)**. `EXT` = **`ExtendedWaypointPauseSeconds` (~10s)**.

**Total loss:** depends on pipeline (e.g. **`USShipSlapEvent`** then cleanup; mine/missile branches emit dedicated kinds first). Generic **`StraitWaypointEvent`** with `totalLoss` remains possible for future catalog rows.

**Voyage clock:** after a pause (non–total-loss), `voyageClock.startTime` is **advanced** by the pause duration so **route progress does not jump** (alpha stays frozen during wait).

---

## 6. Implemented catalog entries (consolidated set)

Defined in `StraitEvents/Catalog.luau`. **Design notes, merge history:** [EVENTS.md](./EVENTS.md).

- **Low:** `RoutinePaperwork` (generic waypoint + paperwork FX); `CoastGuardInspection` (**`CoastGuardInspectionEvent`** — absorbs former glance); `HighWinds` (**`tornadoEvent`** → **`TornadoEvent`**, same as tornado pipeline)
- **Medium:** `EngineRoomSmoke` (generic waypoint; **EXT** pause + payout trim); `PirateRaid` (**`PirateRaidEvent`**); `Storm` (**`StormEvent`** — replaces old fixed-fraction turbulent-seas row)
- **High:** `USShipSlap` (**`USShipSlapEvent`** — absorbs former boarding-only total loss); `Tornado` (**`TornadoEvent`**); `MineStrike` / `MissileStrike` (**`MineStrikeEvent`** / **`MissileStrikeEvent`**)

---

## 7. Implementation details (server)

- `OilShipmentService:Init(..., straitStateService)` stores `StraitStateService` reference.
- `_buildStraitTriggerSlots` builds sorted slots `{ laneWaypointIndex, pathIndex, distance }`.
- Voyage loop: removed `_buildEventTimes` / `_rollDamagePercent` and time-based `ShipmentEvent` damage.
- **`_handleStraitWaypointTrigger`:** branches on catalog flags in a fixed order (missile → mine → coast guard → US slap → pirate → storm → tornado → generic `totalLoss` → generic pause/barrels/multiplier). Each branch emits the matching **`ShipmentVisualEvent.type`** and advances `voyageClock` for pauses.
- **Total loss:** e.g. **`USShipSlapEvent`** + `_finishShipmentWithoutPayout`; mine hit / missile direct hit paths; rare generic **`StraitWaypointEvent`** with `totalLoss` if a future catalog row uses only that flag.
- Shipments still run **asynchronously** per player via existing `task.spawn` around `_runShipment`.

---

## 8. Implementation details (client)

### 8.1 Current (shipped)

- `shipmentVisualEvent` handler branches on **`packet.type`** (`StraitWaypointEvent`, `StormEvent`, `TornadoEvent`, `PirateRaidEvent`, `CoastGuardInspectionEvent`, `USShipSlapEvent`, `MineStrikeEvent`, `MissileStrikeEvent`, …) **before** the owner-only guard for non–strait kinds.
- **Playtest:** `StraitEventPlaytestBanner` shows **`playtestTitle`** (or `displayName`) once per strait trigger (missile barrage: first missile only).
- Owner vs non-owner status strings differ; both see that a strait event occurred; owner may see `barrelsLost` / `totalLoaded` when present.

### 8.2 Locked plan — world VFX & SFX (cosmetic only)

**Authority:** The server owns all outcomes. Clients **only spawn cosmetics** in response to replicated `ShipmentVisualEvent` packets. **No** client-side changes to economy, manifest, or voyage state.

**Entry point:** `init.client` subscribes to `ShipmentVisualEvent`, dispatches **`StraitWaypointWorldFx`** methods per `packet.type`, and handles **`StraitWaypointEvent`** for generic catalog rows (optional `StraitWaypointsFx/<eventId>` folder clone).

**Payload contract** (do not remove or rename without a **version / migration** strategy; additive fields are OK):

| Field | Use |
|-------|-----|
| `eventId` | **Primary key** into presentation table (must match `StraitEvents/Catalog.luau` `id`). |
| `displayName` | HUD copy; optional subtitle on world feedback. |
| `playtestTitle` | Interim full-screen banner text (server sends; client falls back to `displayName`). |
| `severity` | `"Low"` \| `"Medium"` \| `"High"` — **fallback** row when `eventId` unknown. |
| `worldPosition` | Table `{ x, y, z }` (numbers) — **spawn anchor** for particles / `Sound` / attachments. |
| `pauseSeconds` | Align **effect length** (emit duration, looping cutoff, or “hold” timer) with server hold so VFX does not outrun the frozen ship. |
| `totalLoss` | If true, use **high-impact preset** (e.g. burst + alarm); same `pauseSeconds` window as server pre-cleanup wait. |
| `ownerUserId`, `shipmentId`, `laneWaypointIndex` | Debug, future ship lookup, analytics. |
| `barrelsLost`, `totalLoaded`, `priceMultiplier` | **HUD only** — not for spawning gameplay objects. |

**`eventId` → presentation row:** Shared or client config table: per `eventId`, optional `ParticleEmitter` template name (ReplicatedStorage/Assets), `Sound` asset id, optional secondary cue (light flash, beam). **Unknown `eventId`:** use **severity-only** generic row (Low / Medium / High) so new catalog events always get *something*.

**Spatial anchor:** **Default:** use `worldPosition` for a one-shot attachment (e.g. invisible `Part` anchored briefly at sea level) or parent to workspace at that point. **Phase 2 (optional):** if anchor missing or invalid, resolve **active boat** by `shipmentId` / owner (only if server later adds a stable client-visible link — not required for v1).

**Replication:** Effects are **local** to each client; all clients receive the same event and spawn their own copies. **Do not** rely on client-only VFX for hidden information.

### 8.3 HUD — status line + interim banner

**Shipped (playtest):** `StraitEventPlaytestBanner` — large temporary title using **`playtestTitle`** / **`displayName`** on strait visual kinds (see `init.client`).

**Planned / polish:** Dedicated strait toast with **severity** badge/color and richer copy (not only `setStatus`); non-owners keep abbreviated text. **Owner:** UI implementer per repo UI rules.

**Authority:** Display only; strings and numbers come from **payload** (server-authoritative).

### 8.4 Locked plan — deck barrels after spill (optional Phase 2)

**Gap:** `looseBarrelLossFraction` updates **manifest** server-side; **deck instances** spawned at load may no longer match counts.

**Preferred:** **Server** destroys or hides **N** barrel instances under `ActiveShipmentBoat` when spill applies (**Gameplay**-owned slice), keeping visuals aligned with manifest without trusting the client.

**Acceptable later:** Client-only removal of N descendants when `barrelsLost` is set — **risk of desync**; document as inferior fallback.

### 8.5 Owner slices (handoff)

| Slice | Agent / role | Notes |
|-------|----------------|--------|
| Listener + `eventId`/severity presentation table + world VFX/SFX | **Gameplay systems engineer** | §8.2; minimal diff; no authority changes |
| Strait toast / banner HUD | **UI implementer** | §8.3 |
| Destroy N deck barrels on spill | **Gameplay systems engineer** (Phase 2) | §8.4 |

**Architect** updates this SPEC when the **contract** or **ownership** changes; implementers follow §8.x unless the user approves a spec revision.

---

## 9. Server bootstrap

- `TelemetryService:Init()` then `StraitStateService:Init(RemoteService, TelemetryService)`.
- `StraitStateService:Start()` runs before / alongside other services (state ticks and replication).
- `OilShipmentService:Init` receives `StraitStateService`.
- `BindToClose`: `StraitStateService:Stop()`.

---

## 9b. How to test (events are data, not Studio instances)

**Events “exist”** as rows in `src/shared/Config/StraitEvents/Catalog.luau`. The server picks by severity and applies the row’s flags (`stormEvent`, `missileEvent`, …) and numeric tuning blocks (`StormConfig`, `MissileConfig`, …). **Dedicated** rows emit dedicated **`ShipmentVisualEvent`** kinds; generic rows use **`StraitWaypointEvent`**.

**Why you might see nothing in play:**

1. **RNG** — Open is only **10%** per waypoint; you can run many trips and see no hit.
2. **Lane geometry** — Triggers need **at least 9** numbered parts on the chosen lane so `path[4]`, `path[7]`, `path[10]` exist. Shorter lanes or **fallback** dock→exit paths produce **zero** waypoint slots.
3. **Strait state** — `StraitStateService` must be running (it is from `init.server.luau`); bracket comes from live state unless you use debug overrides below.

**Debug overrides** (`src/shared/Constants.luau` → `StraitEventsDebug`):

| Field | Effect |
|-------|--------|
| `ForceOccurrenceAtWaypoint = true` | Skip the occurrence roll; every valid 3/6/9 crossing still runs severity + catalog pick (best for “does the pipe work?”). |
| `ForceBracket = "Closed"` (or `"Restricted"` / `"Open"`) | Ignore engine state for **bracket only**; combine with forced occurrence to test Closed severity mix every time. |
| `LogWaypointTriggers = true` | **Server Output** (any environment): full strait waypoint diagnostics. |
| `VerboseStraitWaypointLogsInStudio = true` (default) | In **Roblox Studio**, server prints the same diagnostics **without** setting `LogWaypointTriggers`. Use **View → Output** and confirm the **Server** filter. Set to `false` to silence Studio spam. |

**Do not** ship with `ForceOccurrenceAtWaypoint` enabled in production. Turn flags off before release.

**Strait dev UI (3 buttons):** Top-right panel **in Roblox Studio only** by default (`RunService:IsStudio()`), or enable anywhere with `Constants.StraitDevUiEnabled = true` (server must allow the remote — same check). Buttons fire `RequestDevSetStraitBracket` with `{ bracket = "Open" \| "Restricted" \| "Closed" }`. Server sets the **engine** state to the same string (**1:1** with the HUD / event brackets). After a dev set, automatic strait rolls are delayed by `StraitDevStateHoldSeconds` (default 24h) so the selection sticks while testing. The panel listens to `GlobalStateUpdate` to show the current **engine** state string.

**Optional:** Client status line still updates on `StraitWaypointEvent` for the local player / others.

---

## 10. Test checklist

- [ ] Open: only Low severities on successful hits; ~10% empirical over many runs per waypoint.
- [ ] Restricted: High appears ~25% of hits (stochastic); Low/Medium otherwise.
- [ ] Closed: no Low; Medium/High only; ~80% hit rate per waypoint.
- [ ] Strait state change **mid-voyage**: later waypoint uses new bracket.
- [ ] Pause: ship holds position timing-wise (no alpha jump after pause).
- [ ] `skipWaypointPause` event: no wait, no clock shift.
- [ ] Total loss: no double payout, warehouse not credited, `ShipmentResolved` failure path.
- [ ] Lane with &lt;9 parts: no error; missing triggers skipped.
- [ ] Fallback path (dock → exit only): no strait slots → no waypoint events.
- [ ] Two concurrent shipments: independent rolls; both receive each other’s `StraitWaypointEvent` on client.
- [ ] **Presentation (when implemented):** world effect spawns at `worldPosition`; unknown `eventId` falls back to severity preset; effect duration sane vs `pauseSeconds`; total-loss cue runs for payload `pauseSeconds`.

---

## 11. Open questions / follow-ups

- **Presentation:** implement §8.2–8.3 (VFX/SFX + HUD); optional §8.4 deck sync.
- Wire `eventRisk` / upgrades into `GetOccurrenceChance` (e.g. multiplicative mitigation).
- Whether non-owners should see `ShipmentResolved` for others (currently owner-filtered for other kinds).
- Map ping / compass hook for strait events (optional; not in §8 lock).

---

## 12. Revision history

| Date | Note |
|------|------|
| 2026-04-10 | Initial SPEC: design + implementation snapshot after strait waypoint system landed. |
| 2026-04-10 | **§8.2–8.5:** Locked client presentation plan (world VFX/SFX, HUD, optional deck sync) + handoff table; §2/§3/§7/§11 aligned. |
| 2026-04-09 | **Consolidated catalog** (fewer ids; glance→inspection, high winds→tornado pipeline, turbulent→storm, boarding→USShipSlap). **§4.7 / §5–7 / §8:** multi-type `ShipmentVisualEvent`, `playtestTitle`, `StraitWaypointWorldFx` + playtest banner paths. §3 file table updated. |
