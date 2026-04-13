# Strait waypoint shipment events — SPEC

Authoritative handoff for **oil shipment** strait events: design intent, tuning numbers, and **what is implemented** in this repository (as of this document).

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
| Event catalog (add new events here) | `src/shared/Config/StraitEvents/Catalog.luau` |
| Per-event design writeups + backlog | [EVENTS.md](./EVENTS.md) |
| Occurrence/severeity tuning, lane trigger ordinals, default pause | `src/shared/Config/StraitEventConfig.luau` |
| Voyage loop, crossing detection, apply event, pause clock | `src/server/Services/OilShipmentService.luau` |
| Global strait state (Open, Restricted, Closed) | `src/shared/Config/StraitConfig.luau` |
| Strait state replication / rolls | `src/server/Services/StraitStateService.luau` |
| Server bootstrap (Telemetry + Strait + OilShipment wiring) | `src/server/init.server.luau` |
| Client broadcast handling for strait events | `src/client/init.client.luau` |
| Visual remote | `RemoteNames.ShipmentVisualEvent` → `ShipmentVisualEvent` |
| **Planned:** strait presentation (VFX/SFX listener + `eventId` table) | *TBD module path* — see **§8.2** (thin bootstrap in `init.client` acceptable v1) |
| **Planned:** strait HUD toast | *UI layer* — see **§8.3** |

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

- Server fires `ShipmentVisualEvent` with `type = "StraitWaypointEvent"` and a `data` table (owner, shipment id, event id, severity, lane waypoint index, `totalLoss`, optional multiplier/pause/barrel-loss fields, `worldPosition`).
- **All clients** are fired; client shows **StraitWaypointEvent** even when `ownerUserId` is not the local player (abbreviated copy for non-owners).

Legacy **`ShipmentEvent`** (random voyage hazard ticks on the non–oil shipment path) is **no longer emitted** by `OilShipmentService`.

---

## 5. Event definition schema (`Catalog.luau`)

Each event may set:

| Field | Meaning |
|-------|---------|
| `id` | Stable string id |
| `severity` | `Low` \| `Medium` \| `High` |
| `displayName` | UI / status string |
| `totalLoss` | If true: shipment ends with **no payout**, boat cleaned up, `ShipmentResolved` with failure reason |
| `priceMultiplierFactor` | Multiplies cumulative `shipment.priceMultiplier` (applied at payout resolution) |
| `skipWaypointPause` | If true: **no** default pause at waypoint (explicit opt-out) |
| `pauseSeconds` | If pausing: override default pause length (catalog may use `ExtendedWaypointPauseSeconds`) |
| `looseBarrelLossFraction` | e.g. `0.1` → lose `ceil(onShipTotal * 0.1)` **whole** barrels from `shipment.manifest` (Heavy → … → Premium); `totalLoaded` updated |

**Default pause:** unless `skipWaypointPause`, the server `task.wait`s for `pauseSeconds` or `StraitEventConfig.DefaultWaypointPauseSeconds` (**5** seconds) for VFX. Catalog entries that previously used longer holds use **`ExtendedWaypointPauseSeconds` (10)** (`EXT` in `Catalog.luau`).

**Total loss:** server emits `StraitWaypointEvent` with `pauseSeconds` = default (**5**), then `task.wait`s that long before cleanup.

**Voyage clock:** after a pause (non–total-loss), `voyageClock.startTime` is **advanced** by the pause duration so **route progress does not jump** (alpha stays frozen during wait).

---

## 6. Implemented catalog entries (initial set)

Defined in `StraitEvents/Catalog.luau`. **Design notes, fantasy, and backlog:** [EVENTS.md](./EVENTS.md).

- **Low:** `RoutinePaperwork`, `CoastGuardGlance` (default **5s** pause), `MinorInspection`, `HighWinds` (**10s** extended pause)
- **Medium:** `TurbulentSeas` (10% barrels + **5s** default pause), `PirateRaid` (25% barrels, same whole-barrel logic + **5s** default pause), `ExtendedInspection` / `EngineRoomSmoke` (**10s** `EXT`), `FuelSiphoningAttempt` (**5s** default pause)
- **High:** `BoardingAndSeizure`, `MineStrike`, `MissileStrike` (all `totalLoss`)

---

## 7. Implementation details (server)

- `OilShipmentService:Init(..., straitStateService)` stores `StraitStateService` reference.
- `_buildStraitTriggerSlots` builds sorted slots `{ laneWaypointIndex, pathIndex, distance }`.
- Voyage loop: removed `_buildEventTimes` / `_rollDamagePercent` and time-based `ShipmentEvent` damage.
- **Total loss:** emit `StraitWaypointEvent` (includes `pauseSeconds`), **`task.wait`** for that duration (animation window), then disconnect boarding, unseat, `_cleanupShip`, `_finishShipmentWithoutPayout(shipment, "Strait event: total loss")`, return from `_runShipment`.
- Shipments still run **asynchronously** per player via existing `task.spawn` around `_runShipment`.

---

## 8. Implementation details (client)

### 8.1 Current (shipped)

- `shipmentVisualEvent` handler processes **`StraitWaypointEvent` before** the owner-only guard.
- Owner vs non-owner strings differ slightly; both see that a strait event occurred (and total loss vs non-loss tone); owner may see `barrelsLost` / `totalLoaded` when present.

### 8.2 Locked plan — world VFX & SFX (cosmetic only)

**Authority:** The server owns all outcomes. Clients **only spawn cosmetics** in response to replicated `ShipmentVisualEvent` packets. **No** client-side changes to economy, manifest, or voyage state.

**Entry point:** One code path subscribing to `ShipmentVisualEvent`, branching on `packet.type == "StraitWaypointEvent"`. May live in a small **dedicated module** required from `init.client.luau` (preferred as the table grows) or inline for v1.

**Payload contract** (do not remove or rename without a **version / migration** strategy; additive fields are OK):

| Field | Use |
|-------|-----|
| `eventId` | **Primary key** into presentation table (must match `StraitEvents/Catalog.luau` `id`). |
| `displayName` | HUD copy; optional subtitle on world feedback. |
| `severity` | `"Low"` \| `"Medium"` \| `"High"` — **fallback** row when `eventId` unknown. |
| `worldPosition` | Table `{ x, y, z }` (numbers) — **spawn anchor** for particles / `Sound` / attachments. |
| `pauseSeconds` | Align **effect length** (emit duration, looping cutoff, or “hold” timer) with server hold so VFX does not outrun the frozen ship. |
| `totalLoss` | If true, use **high-impact preset** (e.g. burst + alarm); same `pauseSeconds` window as server pre-cleanup wait. |
| `ownerUserId`, `shipmentId`, `laneWaypointIndex` | Debug, future ship lookup, analytics. |
| `barrelsLost`, `totalLoaded`, `priceMultiplier` | **HUD only** — not for spawning gameplay objects. |

**`eventId` → presentation row:** Shared or client config table: per `eventId`, optional `ParticleEmitter` template name (ReplicatedStorage/Assets), `Sound` asset id, optional secondary cue (light flash, beam). **Unknown `eventId`:** use **severity-only** generic row (Low / Medium / High) so new catalog events always get *something*.

**Spatial anchor:** **Default:** use `worldPosition` for a one-shot attachment (e.g. invisible `Part` anchored briefly at sea level) or parent to workspace at that point. **Phase 2 (optional):** if anchor missing or invalid, resolve **active boat** by `shipmentId` / owner (only if server later adds a stable client-visible link — not required for v1).

**Replication:** Effects are **local** to each client; all clients receive the same event and spawn their own copies. **Do not** rely on client-only VFX for hidden information.

### 8.3 Locked plan — HUD (ScreenGui / toast)

**Owner:** **UI implementer** (`.cursor/agents/ui-implementer.md`) — StarterGui templates + controller modules per repo UI rules.

**Behavior:** Dedicated **strait toast or banner** (not only `setStatus`): `displayName`, `severity` badge/color, optional `barrelsLost` / `totalLoaded` for owner. Non-owners keep **short** copy (existing pattern) but may reuse the same visual system with abbreviated text.

**Authority:** Display only; all numbers come from **payload** (already server-authoritative).

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

**Events already “exist”** as rows in `src/shared/Config/StraitEvents/Catalog.luau`. There are no separate scripts or models required for the server to pick an event: it chooses a catalog entry by severity and applies `priceMultiplierFactor`, `totalLoss`, `looseBarrelLossFraction`, and pause flags.

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
