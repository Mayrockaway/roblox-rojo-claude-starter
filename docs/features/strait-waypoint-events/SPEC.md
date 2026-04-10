# Strait waypoint shipment events — SPEC

Authoritative handoff for **oil shipment** strait events: design intent, tuning numbers, and **what is implemented** in this repository (as of this document).

---

## 1. Goal

- During each **oil shipment** voyage, evaluate **up to three** independent strait events at **fixed lane waypoints** (ordinals **3, 6, 9** along the sorted route polyline).
- Event **chance** and **severity pool** depend on the **current global strait state** at the moment the ship **crosses** each trigger (strait may change mid-voyage).
- Outcomes are **server-authoritative**; **all clients** receive notifications so other players can see that something happened to a shipment.
- **Legacy** time-random hull events during the voyage are **removed** in favor of this system.
- **Future:** player upgrades may reduce event chance; boat `eventRisk` in config is reserved for that (not used yet).

---

## 2. Out of scope (this slice)

- Rich client VFX/audio tied to each `eventId` (status text only for now).
- Per-player mitigation upgrades (design hook reserved).
- Changing `StraitConfig` from five engine states to three literal states (see §4 — we **map** engine states to three **event brackets**).

---

## 3. Files / modules

| Area | Path |
|------|------|
| Event catalog (add new events here) | `src/shared/Config/StraitEvents/Catalog.luau` |
| Occurrence/severeity tuning, lane trigger ordinals, default pause | `src/shared/Config/StraitEventConfig.luau` |
| Voyage loop, crossing detection, apply event, pause clock | `src/server/Services/OilShipmentService.luau` |
| Global strait state (Open, Tense, …, Closed) | `src/shared/Config/StraitConfig.luau` |
| Strait state replication / rolls | `src/server/Services/StraitStateService.luau` |
| Server bootstrap (Telemetry + Strait + OilShipment wiring) | `src/server/init.server.luau` |
| Client broadcast handling for strait events | `src/client/init.client.luau` |
| Visual remote | `RemoteNames.ShipmentVisualEvent` → `ShipmentVisualEvent` |

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

### 4.3 Engine states → event brackets (three logical modes)

The live game uses **five** values from `StraitConfig` / `StraitStateService`. **Event math** uses **three brackets**:

| Engine state (`GetCurrentState()`) | Event bracket |
|-----------------------------------|---------------|
| `Open` | **Open** |
| `Closed` | **Closed** |
| `Tense`, `Dangerous`, `Crisis` | **Restricted** |

Implementation: `StraitEventConfig.PublicBracketFromEngineState`.

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

- Server fires `ShipmentVisualEvent` with `type = "StraitWaypointEvent"` and a `data` table (owner, shipment id, event id, severity, lane waypoint index, `totalLoss`, optional hull/multiplier/pause, `worldPosition`).
- **All clients** are fired; client shows **StraitWaypointEvent** even when `ownerUserId` is not the local player (abbreviated copy for non-owners).

Legacy **`ShipmentEvent`** (random hull hits during voyage) is **no longer emitted** by `OilShipmentService`.

---

## 5. Event definition schema (`Catalog.luau`)

Each event may set:

| Field | Meaning |
|-------|---------|
| `id` | Stable string id |
| `severity` | `Low` \| `Medium` \| `High` |
| `displayName` | UI / status string |
| `totalLoss` | If true: shipment ends with **no payout**, boat cleaned up, `ShipmentResolved` with failure reason |
| `hullDamageFraction` | Fraction of `hullMax` subtracted from `hullCurrent` (affects delivered barrels via existing HP %) |
| `priceMultiplierFactor` | Multiplies cumulative `shipment.priceMultiplier` (applied at payout resolution) |
| `skipWaypointPause` | If true: **no** default pause at waypoint (explicit opt-out) |
| `pauseSeconds` | If pausing: override default pause length |

**Default pause:** unless `skipWaypointPause`, the server `task.wait`s for `pauseSeconds` or `StraitEventConfig.DefaultWaypointPauseSeconds` (**3** seconds).

**Voyage clock:** after a pause, `voyageClock.startTime` is **advanced** by the pause duration so **route progress does not jump** (alpha stays frozen during wait).

---

## 6. Implemented catalog entries (initial set)

Defined in `StraitEvents/Catalog.luau` (expand over time):

- **Low:** `RoutinePaperwork`, `CoastGuardGlance`, `MinorInspection`
- **Medium:** `ExtendedInspection`, `FuelSiphoningAttempt` (`skipWaypointPause = true`), `EngineRoomSmoke`
- **High:** `BoardingAndSeizure`, `MineStrike` (both `totalLoss`)

---

## 7. Implementation details (server)

- `OilShipmentService:Init(..., straitStateService)` stores `StraitStateService` reference.
- `_buildStraitTriggerSlots` builds sorted slots `{ laneWaypointIndex, pathIndex, distance }`.
- Voyage loop: removed `_buildEventTimes` / `_rollDamagePercent` and time-based `ShipmentEvent` damage.
- **Total loss:** after emitting `StraitWaypointEvent`, disconnect boarding, unseat, `_cleanupShip`, `_finishShipmentWithoutPayout(shipment, "Strait event: total loss")`, return from `_runShipment`.
- Shipments still run **asynchronously** per player via existing `task.spawn` around `_runShipment`.

---

## 8. Implementation details (client)

- `shipmentVisualEvent` handler processes **`StraitWaypointEvent` before** the owner-only guard.
- Owner vs non-owner strings differ slightly; both see that a strait event occurred (and total loss vs non-loss tone).

---

## 9. Server bootstrap

- `TelemetryService:Init()` then `StraitStateService:Init(RemoteService, TelemetryService)`.
- `StraitStateService:Start()` runs before / alongside other services (state ticks and replication).
- `OilShipmentService:Init` receives `StraitStateService`.
- `BindToClose`: `StraitStateService:Stop()`.

---

## 9b. How to test (events are data, not Studio instances)

**Events already “exist”** as rows in `src/shared/Config/StraitEvents/Catalog.luau`. There are no separate scripts or models required for the server to pick an event: it chooses a catalog entry by severity and applies `hullDamageFraction`, `priceMultiplierFactor`, `totalLoss`, and pause flags.

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

**Strait dev UI (3 buttons):** Top-right panel **in Roblox Studio only** by default (`RunService:IsStudio()`), or enable anywhere with `Constants.StraitDevUiEnabled = true` (server must allow the remote — same check). Buttons fire `RequestDevSetStraitBracket` with `{ bracket = "Open" \| "Restricted" \| "Closed" }`. Server maps **Restricted → engine state `Dangerous`** (same event bracket as Tense/Crisis). After a dev set, automatic strait rolls are delayed by `StraitDevStateHoldSeconds` (default 24h) so the selection sticks while testing. The panel listens to `GlobalStateUpdate` to show the current **engine** state string.

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

---

## 11. Open questions / follow-ups

- Replace status labels with richer UX (map ping, ship VFX at `worldPosition`).
- Wire `eventRisk` / upgrades into `GetOccurrenceChance` (e.g. multiplicative mitigation).
- Whether non-owners should see `ShipmentResolved` for others (currently owner-filtered for other kinds).

---

## 12. Revision history

| Date | Note |
|------|------|
| 2026-04-10 | Initial SPEC: design + implementation snapshot after strait waypoint system landed. |
