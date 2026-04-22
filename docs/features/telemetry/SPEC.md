# Gameplay telemetry pipeline — SPEC

Server-authoritative analytics pipeline that answers funnel, economy, engagement, monetization and FTUE questions for **Open The Strait**. **Documentation-only handoff.** This SPEC defines the module API, the event catalog, and the per-service insertion-point map. **No `src/` files are modified by this document** — implementation is reserved for a follow-up gameplay slice.

> **Template note.** `docs/SPEC_TEMPLATE.md` does **not** exist in this repo. This SPEC mirrors the section structure of the closest reference, [`docs/features/strait-waypoint-events/SPEC.md`](../strait-waypoint-events/SPEC.md) (1. Goal · 2. Out of scope · 3. Files / modules · 4. Architecture · 5. Schema · 6. Catalog · 7. Server impl · 8. Client / sampling · 9. Bootstrap · 10. Test checklist · 11. Open questions · 12. Verification stub). When `SPEC_TEMPLATE.md` is added, re-run a header pass against this file.

---

## 1. Goal

A single, **server-authoritative** telemetry pipeline so we can answer:

- **Funnel** — install (first join) → first dispatch → first delivered shipment → first oil sale → first Robux purchase → D1 / D7 retention proxies.
- **Economy** — oil and cash earn rate per minute by tier (Crude / Refined / Premium), sink rate by reason (warehouse upgrades, plot unlocks, equipment, ship upgrades, dispatch fees, charges/consumables), price-point sensitivity (sell volume vs `OilMarketService` rolled price).
- **Engagement** — voyage success rate, death / wipe events, **strait events** (Coast Guard / Pirate Raid / Air Strike / Mines / Missile / Storm / Tornado / US Ship Slap / Security Personnel deflects), session length, average dispatches per session.
- **Monetization** — GamePass + DevProduct prompt → purchase → grant counts and conversion ratios. Currently wired ids: **`gamepass.auto_ship` (1801587146)**, **`gamepass.double_earnings` (1805656447)**, **`consumable.security_personnel_x1` (3579486599)**, **`starter_pack` (3578811060)**, plus the `consumable.strait_*` and `consumable.nuke_x1` rows in `MonetizationCatalog`.
- **FTUE** — which `FtueConfig.Step` players drop off at, and how long each step takes.

**Non-goals (also in §2):** rendering dashboards, replacing the DataStore-backed game state, real-time anti-cheat decisions, building a custom backend.

---

## 2. Out of scope (this slice)

- **Implementation** of the `Telemetry` module, the wire-up edits inside each gameplay service, and the BindToClose flush. Reserved for `gameplay-systems-engineer`; this SPEC is the handoff.
- **Dashboard / chart authoring** in PlayFab / GameAnalytics / Creator Hub. Visualization owners decide what views to build *after* events ship.
- **Removing every `print` / `DevLog.log` call** for production. The new pipeline is the production replacement; the dev-log scrub is its own follow-up issue and **must not** depend on this feature shipping.
- **Cross-server aggregation in-game** (e.g. live "X players right now"). PlayFab Insights, GameAnalytics dashboards, and Roblox Creator Dashboard own that.
- **PII collection.** UserId only. See §6 / §7 (§7-Privacy).
- **UI surface for telemetry** (no HUD, no panel). Consequently `ui-architecture.mdc` / `ui-scaling-responsive.mdc` rules are not in scope here — no `StarterGui` work.

---

## 3. Files / modules

### 3.1 Already present in repo (this SPEC reads but does not edit)

| Area | Path | Current role |
|------|------|--------------|
| **Existing telemetry shim** (placeholder; in-memory ring buffer + `print`) | `src/server/Services/TelemetryService.luau` | `Init` / `Start` / `Stop` / `Track(eventName, payload)` — caps at 200 entries, prints `[Telemetry] <event> <payload>`. **Does not** receive `player` context, sessionId, or rate-limit. **Replace** (see §5). |
| Existing call sites of the placeholder | `src/server/Services/PersistenceService.luau` (`profile_load_failed`, `profile_save_failed`), `src/server/Services/PlayerStateService.luau` (`player_state_loaded`), `src/server/Services/StraitStateService.luau` (`strait_force_lock`), `src/server/Services/UpgradeService.luau` (`upgrade_purchased`), `src/server/Services/AdminService.luau` (`admin_force_close`) | These call sites are **kept as-is** but will route through the new module after rename — see §4.4 migration. |
| Dev-only diagnostic shim (NOT analytics) | `src/shared/DevLog.luau` | `DevLog.log(msg)` — `print` server-side and (Studio only) `FireAllClients` so server traces show in client Output. Not a telemetry replacement. The new pipeline lives **alongside** `DevLog`; nothing in this SPEC removes `DevLog`. |
| Server bootstrap (Init / Start / BindToClose ordering) | `src/server/init.server.luau` | Already constructs `TelemetryService` first and passes it into `StraitStateService`. New module slots into the same place (§9). |
| Remote layout | `src/shared/Net/RemoteNames.luau` | **No new remotes** for v1 — telemetry is server-only. v2 may add **`RequestClientTelemetryHello`** for client-fired metrics (FPS, input latency); deferred. |
| FTUE step ids + canonical order | `src/shared/Config/FtueConfig.luau` | Drives the **funnel step ordinal** for `funnel_ftue` (see §6). |
| Robux storefront ids | `src/shared/Config/MonetizationCatalog.luau` | Source of `productId` → `id` mapping for `monetization_*` events (see §6). |

### 3.2 Server services that own state changes worth emitting

These are the **insertion-point owners** for §6 events. None are edited by this SPEC.

| Service | Path | Why it emits |
|---------|------|--------------|
| `OilStateService` | `src/server/Services/OilStateService.luau` | `AddCash`, drill complete, lootbox / vein reveal, ship skin / level grants, run-upgrade owned, persistence load/save edges. |
| `OilShipmentService` | `src/server/Services/OilShipmentService.luau` | Dispatch, voyage start, **strait waypoint trigger** (already branches by event id), shipment success / total loss / refund, teleport-to-ship / home / docks. **Highest-leverage emit site after `MonetizationService`.** |
| `MonetizationService` | `src/server/Services/MonetizationService.luau` | Prompt fired, `ProcessReceipt` granted / replayed / failed, `PromptGamePassPurchaseFinished` (purchased / cancelled), `HasGamePassEffect` first-resolve. |
| `FtueService` | `src/server/Services/FtueService.luau` | `_setStep` (every transition), `OnDispatchShipmentSuccess`, `OnFtueWarehouseSaleSuccess`, `OnFtueDocksTownTeleportSuccess`, `OnFtueEquipmentShopPurchase`, `OnFtueShipCapacityUpgradeSuccess`, FTUE skip / acknowledge. |
| `EquipmentShopService` | `src/server/Services/EquipmentShopService.luau` | `_rollShopStock` (rotation), `_handlePurchase` (purchase / failed / FTUE-free), `GrantFreeOwnedEquipment` (Robux + dev grants). |
| `ChunkOwnershipService` | `src/server/Services/ChunkOwnershipService.luau` | Chunk unlock (sink event) — wire after the chunk sign hook flips `isOwned` (currently inside `_applyChunkVisual` / unlock callback path). |
| `WarehouseService` | `src/server/Services/WarehouseService.luau` | `DeliverBarrels` / `DeliverHitBarrels` (earn), `TryUpgrade` (sink), `SellAll` / sub-type sales (handoff to `OilMarketService`). |
| `OilMarketService` | `src/server/Services/OilMarketService.luau` | `HandleSellType` / `HandleSellWarehouseBarrels` / `HandleSellAll` (cash-out events, with current price + strait state context). |
| `OilTankService` | `src/server/Services/OilTankService.luau` | Tank tier upgrades (sink). |
| `StraitStateService` | `src/server/Services/StraitStateService.luau` | Engine-state transitions (already emits `strait_force_lock` via the placeholder; keep + add `strait_state_changed`). |
| `HitContractService` | `src/server/Services/HitContractService.luau` | Pirate hire created / refunded / executed. |
| `ArmyGeneralService` | `src/server/Services/ArmyGeneralService.luau` | Nuke / Airstrike fired (Robux-gated). |
| `SecurityPersonnelService` | `src/server/Services/SecurityPersonnelService.luau` | `TryConsumeForDispatch` (consumed → next-run protection deflects an event). |
| `AutoShipService` | `src/server/Services/AutoShipService.luau` | Set-on / set-off, auto-dispatch fired / failed. |
| `KillZoneService` | `src/server/Services/KillZoneService.luau` | Player death / wipe (engagement). |
| `DrillingService` | `src/server/Services/DrillingService.luau` | Drill started / completed / cancelled, replayed-on-rejoin. |
| `BoatDockService` | `src/server/Services/BoatDockService.luau` | Dock idle ↔ active transitions (per-shipment cycle bookkeeping). |
| `LeaderboardService` | `src/server/Services/LeaderboardService.luau` | (Existing) on-rank-change events as a low-priority signal. |

### 3.3 New files to author (in implementation slice, NOT this SPEC)

| New path | Role |
|----------|------|
| `src/shared/Telemetry/init.luau` | Public module — see §5. Lives in **`ReplicatedStorage.Shared.Telemetry`** so server services and a future client telemetry shim can both `require` the same type definitions. **Runtime calls are server-only** for v1 (the module rejects client calls — see §8). |
| `src/shared/Telemetry/EventCatalog.luau` | Compile-time event name table (constants) so insertion-point bugs are caught by Luau (`Telemetry.Track(player, EventCatalog.SHIPMENT_DISPATCHED, …)`). |
| `src/shared/Telemetry/GameAnalyticsAdapter.luau` | REST v2 adapter (init / user / session_start / events / session_end / HMAC / batching / backoff). See §4.6. |
| `src/shared/Vendor/HmacSha256.luau` | **Vendored** pure-Lua HMAC-SHA256 (~200 lines, MIT). One of the few `Vendor/` exceptions in this repo because Roblox ships no native equivalent — call this out in the file header. Required by `GameAnalyticsAdapter`. |
| `src/shared/Config/TelemetryConfig.luau` | Config (values **locked** by §11 resolved decisions): `Debug = RunService:IsStudio()`, `ForceBackends = false`, `RateLimit = { perPlayerEventsPerMinute = 30, perServerEventsPerMinute = 5000, oversizePayloadBytes = 4096 }`, `Sampling = { strait_waypoint_evaluated = 0.1, oil_pumped = 0.05, oil_pump_collected = 0.05, default = 1.0 }`, **`RobuxToUsd = 0.0035`** (USD per 1 R$ — used by §4.6.7 `business` events; convert to integer USD cents at the GA adapter via `math.floor(robuxAmount * RobuxToUsd * 100)`), **`SessionStartCustomDimensions`** (locked, §11.A.4): `{ accountAgeBuckets = { {max = 7, label = "<7d"}, {max = 30, label = "7-30d"}, {max = 90, label = "30-90d"}, {max = math.huge, label = ">90d"} }, bucketAccountAge = function(days) -> string, membershipLabels = { Premium = "premium", default = "standard" } }`, `GameAnalytics = { endpoint = "https://api.gameanalytics.com/v2/", flushIntervalSeconds = 8, flushAtBufferSize = 100, hardCapBufferSize = 500, backoffSecondsCap = 30, eventMaxAgeSeconds = 300 }`. |
| `src/server/Services/TelemetryService.luau` | **Replaces** the current placeholder. Server-side façade in front of `Telemetry`. Owns: per-player session table, GA buffer drain task, `BindToClose` flush. |
| Roblox first-party Secrets — **`GA_GAME_KEY`** (Creator Hub) | Set on the Creator Hub at `https://create.roblox.com/dashboard/creations` → Configure Experience → Secrets. Read at runtime via `HttpService:GetSecret("GA_GAME_KEY")` → returns a `Secret` userdata that the GA adapter folds into the URL via `:AddPrefix(...)` / `:AddSuffix(...)`. Never reified to a string. |
| `ServerStorage.Secrets.GameAnalytics` (ModuleScript, **place-local, gitignored** — see §11.A.1) | `return { secretKey = "…" }`. **Secret Key only** — the Game Key lives in `HttpService:GetSecret("GA_GAME_KEY")` above. The repo ships **`src/server/Secrets/Secrets.template.luau`** (committed) as a discoverability placeholder; the real `src/server/Secrets/GameAnalytics.luau` is gitignored and pasted into Studio under `ServerStorage.Secrets.GameAnalytics` by the place owner. **Why split:** HMAC-SHA256 needs raw key bytes that `HttpService:GetSecret`'s `Secret` userdata deliberately does not expose — see §4.6.3. Both Game Key + Secret Key must be present for GA fan-out; either missing → no-op (one-shot warn, Roblox `AnalyticsService` keeps running). |

---

## 4. Architecture

### 4.1 Layering — **dual fan-out (chosen design)**

Every event from `Shared.Telemetry` fans out to **two backends concurrently**. There is no Phase 1 / Phase 2 split and no `TelemetryConfig.Backend` flag — both backends are always on in production, always off (or printed only) in Studio.

```
Gameplay services (OilShipmentService, MonetizationService, ...)
   │
   │  Telemetry.Track(player, eventName, props?)         ← public API (§5)
   ▼
Shared.Telemetry  (queue + session context + rate limit + sampling)
   │
   ├──► Roblox AnalyticsService                                          ← synchronous
   │      LogFunnelStepEvent / LogEconomyEvent / LogProgressionEvent /
   │      LogCustomEvent
   │      • free, no HTTP, no allowlist, surfaces in Creator Dashboard
   │      • per-event call (not batched — the API takes one event per call)
   │
   └──► GameAnalytics REST v2  (`api.gameanalytics.com/v2/<game_key>/`)  ← buffered + batched
          • HMAC-SHA256 signed POST via HttpService:RequestAsync
          • mandatory init → user → session_start ordering per user
          • per-user buffer, flush every 8s / 100 events / on leave
          • exponential backoff on non-2xx
```

**Independence requirement.** The two adapters are wrapped in their own `pcall`s inside `Shared.Telemetry._fanOut`. **Either backend failing must not block the other and must not surface back to the gameplay caller.** A GameAnalytics HTTP timeout never blocks a `Telemetry.Track` call — events queue, the drain loop owns the network failure mode.

**Studio default.** When `RunService:IsStudio()` and `TelemetryConfig.ForceBackends ~= true`, both adapters route through the debug `print` adapter instead so playtests do not pollute the live Creator Dashboard or burn GameAnalytics quota.

### 4.2 Authority

- **Server-only emit.** Every `Track` runs inside a server script. Client behaviors that need to register telemetry travel through their existing validated remotes (`RequestPurchaseEquipment`, `RequestSellWarehouseType`, etc.) and the **server** emits after authorization.
- The module **rejects** client-side requires by checking `RunService:IsServer()` in `Track` and returning silently in client contexts (so a future shared client telemetry stub does not need a separate require path).
- **Zero remotes** for v1. No new entries in `RemoteNames.luau`.

### 4.3 Player session context (auto-attached)

Every event payload is decorated server-side before fan-out:

| Field | Source |
|-------|--------|
| `userId` | `player.UserId` |
| `sessionId` | UUID assigned in `Telemetry._onPlayerAdded` (per join) |
| `placeVersion` | `game.PlaceVersion` (cached at `Init`) |
| `placeId` | `game.PlaceId` |
| `serverId` | `game.JobId` |
| `playTimeSecondsAtEvent` | `os.clock() - sessionStartedAt` |
| `playerCash` | `OilStateService:GetCash(userId)` (best-effort; nil if state not loaded) |
| `shipSpeedLevel` / `shipCapacityLevel` / `shipSkinId` | `OilStateService:GetState(userId)` snapshot |
| `straitEngineState` | `StraitStateService:GetCurrentState()` |
| `activeShipmentId` | `OilShipmentService:GetActiveShipmentForUser(userId)?.id` |
| `playerCount` | `#Players:GetPlayers()` |

The decorator is the **only** place that touches other services. Gameplay code passes the player + the **delta-only** payload (`{ amount = 250, reason = "warehouse_upgrade" }`).

### 4.4 Migration of existing call sites

The five existing `self._telemetryService:Track(...)` call sites listed in §3.1 are kept on the same string event names so existing log greps keep working. They get the new auto-attached context for free once `TelemetryService:Track` proxies to `Shared.Telemetry.Track`. Existing call signatures (`Track(eventName, payload)` without a `player` arg) are accepted by the new wrapper as a back-compat overload that emits with `userId = nil` (i.e. server-scope events).

### 4.5 Backend A — Roblox `AnalyticsService` (Creator Dashboard)

- **Free, no HTTP, no allowlist, no secrets.** Surfaces in the Creator Dashboard within ~5 minutes (Roblox documented latency).
- **One call per event** (the Roblox API does not accept batches).
- Wrapper functions in `Shared.Telemetry`:
  - `Telemetry.Funnel(player, funnelName, step, stepName)` → `AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId, step, stepName)`
  - `Telemetry.Economy(player, flowType, amount, currency, reason, item?)` → `AnalyticsService:LogEconomyEvent(player, Enum.AnalyticsEconomyFlowType[flowType], currency, amount, reason, Enum.AnalyticsEconomyTransactionType.Gameplay, itemSku?)`
  - `Telemetry.Progression(player, status, p1, p2?, p3?)` → `AnalyticsService:LogProgressionEvent(player, p1, Enum.AnalyticsProgressionStatus[status], p2, p3)`
  - Anything else → `AnalyticsService:LogCustomEvent(player, eventName, value?, customField1?, …)`
- **Server-only** (Roblox `AnalyticsService` is restricted to the server context).
- **No PII risk** — the Roblox API itself only takes the `Player` instance plus typed scalars.

### 4.6 Backend B — GameAnalytics REST v2 (third-party)

GameAnalytics ships **no official Roblox SDK** in 2026 (the historical community SDK is unmaintained and last touched ~2021). We call REST v2 directly. This subsection is the operational bible for the gameplay engineer — if anything below is unclear, escalate before writing the adapter.

#### 4.6.1 Endpoint and routes

- **Base URL:** `https://api.gameanalytics.com/v2/<game_key>/`
- **Routes used:**
  - `POST /init` — handshake. Returns `{ enabled: bool, server_ts: number, flags?: [...] }`. Cache `server_ts - os.time()` as the per-server **clock offset**; every event timestamp we emit must use `os.time() + offset` so GA's server-side dedup works.
  - `POST /events` — accepts a **JSON array** of event objects. **Never** post a single object — wrap in `[ {...} ]`.

#### 4.6.2 Keys and secret storage — split storage (locked, §11.A.1)

GameAnalytics uses two keys per "game" (one per environment):

| Key | Purpose | Storage in this project |
|-----|---------|--------------------------|
| **Game Key** | Identifier that goes into the URL path. Not strictly secret, but no reason to check into git. | **Roblox first-party Secrets** via `HttpService:GetSecret("GA_GAME_KEY")`. |
| **Secret Key** | HMAC-SHA256 signing secret. **Treat as a credential.** | **Gitignored `ServerStorage.Secrets.GameAnalytics` ModuleScript** returning `{ secretKey = "…" }`. *(See §4.6.3 for why the Secret Key cannot live in `HttpService:GetSecret`.)* |

**Why the split.** Roblox's first-party `HttpService:GetSecret(name)` returns a `Secret` userdata, **not a string**. The userdata can be embedded into HTTP request fields (`Secret:AddPrefix` / `Secret:AddSuffix` for headers, query params, etc.) but **cannot** be read out as raw bytes — printing or concatenating it raises an error. That property is exactly what makes it safe; it's also what makes it unusable for HMAC, where we need raw key bytes to feed into SHA-256. So:

- **Game Key** → `HttpService:GetSecret`. We never touch its raw value: the adapter builds the URL via `HttpService:GetSecret("GA_GAME_KEY"):AddPrefix("https://api.gameanalytics.com/v2/"):AddSuffix("/events")` (or equivalent — the adapter constructs once at boot).
- **Secret Key** → ModuleScript with the raw string, gitignored. Used purely as input to the vendored HMAC-SHA256 (§4.6.3); the result is a base64 string that goes into the `Authorization` header as a normal string.

**Creator Hub setup (canonical names — use these exact identifiers):**

1. `https://create.roblox.com/dashboard/creations` → pick the experience → **Configure Experience** → **Secrets** sidebar entry.
2. Create secret named **`GA_GAME_KEY`** with the GameAnalytics Game Key value.

**Studio / repo setup for the Secret Key:**

1. Repo ships **`src/server/Secrets/Secrets.template.luau`** (committed) with `return { secretKey = "PASTE_GAMEANALYTICS_SECRET_KEY_HERE" }` so the file path is discoverable.
2. The real **`src/server/Secrets/GameAnalytics.luau`** (mirroring to `ServerStorage.Secrets.GameAnalytics`) is **gitignored**. Place owner copies the template, pastes the real Secret Key, Saves the place. Persists with the `.rbxl`, not the repo.
3. Acceptable fallback for non-coders: a `StringValue` named `GameAnalyticsSecretKey` under `ServerStorage`, resolved via `game:GetService("ServerStorage"):FindFirstChild(…)` at boot.

**Boot-time loading (inside `GameAnalyticsAdapter`):**

- Wrap each lookup in its own `pcall` (the Roblox docs are explicit: `HttpService:GetSecret` raises if the secret name doesn't exist).
- If `HttpService:GetSecret("GA_GAME_KEY")` fails OR returns nil OR the `ServerStorage.Secrets.GameAnalytics` ModuleScript is missing OR returns no `secretKey`: the GA adapter no-ops cleanly for the session, the Roblox `AnalyticsService` half stays running, and the adapter logs **exactly one** warn:

   ```
   [Telemetry/GA] Secrets missing — GameAnalytics fan-out disabled this session.
     • Game Key: add a secret named "GA_GAME_KEY" on Creator Hub → Configure Experience → Secrets.
     • Secret Key: paste the GameAnalytics Secret Key into ServerStorage.Secrets.GameAnalytics
       (ModuleScript returning { secretKey = "..." }). The repo template lives at
       src/server/Secrets/Secrets.template.luau.
   ```

#### 4.6.3 Auth — HMAC-SHA256 (and why the Secret Key cannot live in `HttpService:GetSecret`)

Every `POST` to GameAnalytics must include:

```
Authorization: <base64( hmac_sha256( request_body_bytes, secretKeyBytes ) )>
Content-Type: application/json
```

**The conflict.** `HttpService:GetSecret(name)` is purpose-built to keep secrets out of script memory — it returns a `Secret` userdata that you can splice into HTTP requests via `Secret:AddPrefix(prefix)` / `Secret:AddSuffix(suffix)` (which return new `Secret` values), but you **cannot read its raw bytes**, print it, or concatenate it into a regular Lua string. That's the entire safety story: the secret never enters Luau as a string, so it can't accidentally leak into logs, telemetry payloads, or remote events.

That property makes `Secret` perfect for **Bearer-token-style auth** (where the secret IS the header) and useless for **HMAC** (where you need raw key bytes to feed into the SHA-256 inner state). GameAnalytics requires HMAC, not Bearer.

**Two options the engineer can pick from at implementation time:**

- **Option A — recommended (this SPEC's locked path).** Use `HttpService:GetSecret` only for the GA **Game Key** (which goes in the URL path; not strictly secret but worth keeping out of git), and store the GA **Secret Key** as a plain string in the gitignored `ServerStorage.Secrets.GameAnalytics` ModuleScript per §4.6.2. Trade-off: the Secret Key sits in script memory at runtime, so a hostile script with `require` access could read it; we mitigate by keeping the require local to the GA adapter and never logging the value. This is the same blast radius as the original ModuleScript-only design — we're upgrading the Game Key path, not regressing the Secret Key path.
- **Option B — verify first; likely not viable.** If GameAnalytics has shipped (or ships in the future) a Bearer-token / OAuth REST endpoint that does **not** require HMAC over the body, prefer that path: the Secret Key (or token) can live entirely in `HttpService:GetSecret` with no raw-string exposure. As of the last public docs check, the v2 production and sandbox endpoints both require HMAC; the engineer should re-verify against current GameAnalytics REST docs at implementation time before committing to Option A. If a Bearer endpoint exists, switch — the SPEC will be updated.

**HMAC implementation (Option A path).** Roblox's standard library does not include HMAC-SHA256. **Vendor a small pure-Lua implementation** under **`src/shared/Vendor/HmacSha256.luau`** (~200 lines). Vendor folders are otherwise discouraged in this repo — call this exception out in the file header (`-- Vendor: pure-Lua HMAC-SHA256 used by Shared.Telemetry GameAnalytics adapter. No Luau-native equivalent exists.`). MIT-licensed reference implementations exist (e.g. the `LuaCrypt` family); pick one that has `digest(key, message) -> bytes` and `hex_encode` / `base64_encode` helpers, audit the ~200 lines manually, and freeze the version. **Do not** require it from any other module — keep blast radius small. The adapter calls it like:

```
local secretKey: string = require(ServerStorage.Secrets.GameAnalytics).secretKey
local body: string = HttpService:JSONEncode(slice)
local authHeader: string = HmacSha256.base64(HmacSha256.digest(secretKey, body))
```

The Game Key, by contrast, is folded into the URL via the `Secret` API and never reified to a string:

```
local gameKey: Secret = HttpService:GetSecret("GA_GAME_KEY")
local url: Secret = gameKey:AddPrefix("https://api.gameanalytics.com/v2/"):AddSuffix("/events")
HttpService:RequestAsync({
    Url = url,                              -- Secret userdata, not a string
    Method = "POST",
    Headers = { ["Authorization"] = authHeader, ["Content-Type"] = "application/json" },
    Body = body,
})
```

#### 4.6.4 HttpService allowlist (deploy-time)

GameAnalytics only works if HttpService can reach the public internet. Two distinct toggles, in two different places — both are deploy-time configuration, **neither is a design blocker** (the GA adapter handles failure gracefully, and Roblox `AnalyticsService` is unaffected by either).

> **This place's status (verified by user on 2026-04-18):** the experience is on **legacy blanket-allow HTTP mode** — no per-domain "Allowed API Domains" entry is visible in the Creator Hub Security sidebar. The Studio toggle in step 1 is **sufficient on its own**; step 2 does not apply unless and until Roblox migrates this experience to the per-domain system. The §10.A 403-recovery procedure stays documented for future-proofing and for any sibling experience that's already on the per-domain system.

1. **Always required — Studio.** **Game Settings → Security → Allow HTTP Requests** = **on**. (`HttpService.HttpEnabled` reflects this; cannot be flipped from script.)
2. **Conditionally required — Creator Hub website.** Some experiences (typically newer creations and any that have been migrated to Roblox's per-domain HTTP allowlist) additionally require the destination domain to be on a per-experience URL allowlist. **This list is NOT in Studio's Game Settings dialog.** It lives on the Creator Hub:

   `https://create.roblox.com/dashboard/creations` → pick the experience → **Configure Experience** → **Security** → **"Allowed API Domains" / "HTTP request URL allowlist"** → add **`api.gameanalytics.com`** (no wildcards, no scheme).

   Older experiences that were never migrated to the per-domain system pass with **just** the Studio toggle from step 1; the Creator Hub list is irrelevant for them.

**How to know which case you're in:** the first time the GA adapter posts `/init`, watch the response.

- HTTP 200 → fine; experience is in the "Studio toggle is enough" group.
- HTTP 403 with a "domain not allowed" or similar message → experience is on the per-domain system; add `api.gameanalytics.com` per step 2 and redeploy. The GA adapter wraps every call in `pcall` and the §4.6.9 backoff so the failure does not crash anything; events queue and start delivering once the allowlist update is live.

Roblox `AnalyticsService` (Backend A) is unaffected by either toggle — it uses an internal Roblox transport, not `HttpService`.

#### 4.6.5 Required initial events (per session, in order)

GameAnalytics rejects events for a user until `init` + `user` + `session_start` have been delivered for that user. **Order matters.**

1. **`/init` (per-server, once at boot)** — POST `{ platform, os_version, sdk_version }`. Cache the returned `server_ts` offset. If `enabled = false` in the response, GA wants us to stop sending — set a global `_gaDisabled = true` flag and no-op for the session.
2. **`user` event (per-user, on `PlayerAdded`)** — first event in the user's queue. Category `"user"`. Required fields: `platform`, `os_version`, `sdk_version`, `device`, `manufacturer`. Roblox does not expose most of these — send sentinels:

   ```
   { category = "user", platform = "roblox", os_version = "roblox 0.0.0",
     manufacturer = "roblox", device = "unknown", sdk_version = "roblox-rest-1.0" }
   ```

3. **`session_start` event (per-user, immediately after `user`)** — category `"session_start"`. Must precede every other event for that user. After this lands, the user's queue is open.

   **Custom dimensions** attached to `session_start` (locked, §11 Resolved §11.A.4):

   ```
   {
     category = "session_start",
     custom_01 = TelemetryConfig.SessionStartCustomDimensions.bucketAccountAge(player.AccountAge),
        -- "<7d" | "7-30d" | "30-90d" | ">90d"
     custom_02 = if player.MembershipType == Enum.MembershipType.Premium then "premium" else "standard",
        -- "premium" | "standard"
     ...standard GA session_start fields...
   }
   ```

   Bucketing `AccountAge` (instead of sending the raw integer days) deliberately avoids leaking a player's exact join date to the third party while still letting the GA dashboard segment cohorts by tenure. Both `MembershipType` and `AccountAge` are public Roblox profile data; this is an explicit privacy decision, not an oversight (see §11 Resolved §11.A.4).

If the user disconnects before `session_start` flushes, drop their queue silently — partial sessions corrupt GA's funnel math.

#### 4.6.6 Required final event

- **`session_end`** — category `"session_end"`, with `length` field in **integer seconds**. Fire from `Players.PlayerRemoving` and again from `BindToClose` for any still-online user. Without this, GA's session-length distribution and DAU computation drift.

#### 4.6.7 Event mapping — internal vocabulary → GameAnalytics category

| Our event(s) | GA `category` | Notes |
|--------------|---------------|-------|
| `oil_sold`, `oilman_sold`, `instant_sold`, `dispatch_fee`, `equipment_purchased`, `chunk_unlocked`, `warehouse_upgraded`, `oil_tank_upgraded`, `ship_speed_upgraded`, `ship_capacity_upgraded`, `cash_granted_dev` | `resource` | Soft currency. `flow_type = "Source" \| "Sink"`, `currency = "cash" \| "oil_<tier>"`, `amount = <int>`, `item_type = "<reason>"`, `item_id = "<sku>"`. |
| `monetization_purchased` (DevProduct), `gamepass_purchased`, `monetization_first_purchase` | `business` | Real money. `cart_type = "DevProduct" \| "GamePass"`, `item_type = "<category>"`, `item_id = "<itemId>"`, `currency = "USD"`, `amount = math.floor(robuxPrice * TelemetryConfig.RobuxToUsd * 100)` (integer USD cents) with **`RobuxToUsd = 0.0035`** (locked, §11 Resolved §11.3). |
| `funnel_ftue`, `funnel_first_run` | `progression` | `progression01 = "ftue"`, `progression02 = "<stepId>"`, status = `Start` / `Complete` / `Fail`. |
| `shipment_dispatched`, `shipment_voyage_started`, `shipment_completed`, `shipment_total_loss`, `shipment_pirate_hit*`, `strait_event_fired`, `strait_waypoint_evaluated`, `strait_state_changed`, `strait_force_lock`, `nuke_fired`, `airstrike_fired`, `pirate_hire_*`, `auto_ship_*`, `dock_idle_to_active`, `equipment_shop_rotated`, `ship_skin_equipped`, `security_personnel_*`, `player_died` | `design` | Custom event. `event_id = "<domain>:<verb>:<qualifier>"`, e.g. `voyage:dispatched:t1`, `strait:event_fired:storm`, `monetization:gamepass_cancelled:auto_ship`. Use `value` for the most relevant numeric (barrels, cash, seconds). |
| `profile_load_failed`, `profile_save_failed`, `oil_state_load_failed`, `monetization_grant_failed`, `equipment_purchase_failed`, `telemetry_dropped`, `telemetry_circuit_open` | `error` | `severity = "info" \| "debug" \| "warning" \| "error" \| "critical"`. Use `error` for grant failures, `warning` for save retries, `critical` for circuit-open. |
| `session_start`, `session_end`, `first_join` | `session_start` / `session_end` (built-ins) | Special — see §4.6.5 / §4.6.6. `first_join` does **not** map to a GA built-in; emit it as a `design` event `meta:first_join`. |
| Anything else | `design` | Fallback; never silently drop. |

#### 4.6.8 Batching

- **Per-user buffer.** Each player has their own array of pending GA event JSON objects.
- **Flush triggers** (whichever fires first):
  1. Buffer reaches **100 events**.
  2. **8 seconds** have passed since the buffer's last flush attempt.
  3. `Players.PlayerRemoving` for that user.
  4. `BindToClose`.
- **Hard cap: 500 events** per user buffer. If we hit 500 before a flush completes, drop the **oldest** events and emit one `telemetry_dropped { reason = "ga_buffer_overflow", droppedCount }`.
- **Body shape:** `HttpService:JSONEncode(arrayOfEvents)`. Compute the HMAC over the exact bytes you POST.

#### 4.6.9 Backoff and retention

- On `2xx` response → success; clear the in-flight slice.
- On `4xx` (other than 429) → log once, drop the slice (we sent malformed data; retrying won't help).
- On `429` or `5xx` or HTTP error → **exponential backoff**: 1s → 2s → 4s → 8s → 16s → 30s cap. Re-queue the slice at the head of the buffer.
- **Age-out:** drop any event whose `client_ts` is older than **5 minutes** at flush time. Stale events skew GA's session math and waste payload size on data nobody will look at.

---

## 5. Module shape — `Shared.Telemetry`

Single public module. Strict types. No globals.

```luau
-- (Indicative API — implementer fills the body in the gameplay slice.)
local Telemetry = {}

export type EconomyFlow = "Source" | "Sink"
export type ProgressionStatus = "Start" | "Complete" | "Fail"

function Telemetry.Track(player: Player?, eventName: string, properties: {[string]: any}?)
function Telemetry.Funnel(player: Player, funnelName: string, step: number, stepName: string)
function Telemetry.Economy(player: Player, flowType: EconomyFlow, amount: number, currency: string, reason: string, item: {kind: string, id: string}?)
function Telemetry.Progression(player: Player, status: ProgressionStatus, p1: string, p2: string?, p3: string?)
function Telemetry.Purchase(player: Player, productKind: "DevProduct" | "GamePass", productId: number, robuxAmount: number, itemId: string?, oneTime: boolean?)
function Telemetry.SetSession(userId: number, key: string, value: any)   -- e.g. set 'firstDispatchAt'
function Telemetry.Flush(player: Player?, opts: {graceSeconds: number?}?)  -- BindToClose / on-leave
return Telemetry
```

**Internals** the implementer must build:

- **Dual fan-out.** `Track` / `Funnel` / `Economy` / `Progression` / `Purchase` decorate the payload (§4.3) and then call `_fanOut(decorated)`, which independently dispatches to the Roblox `AnalyticsService` adapter (synchronous, per-event) and queues into the GameAnalytics adapter (buffered, batched). Each adapter is wrapped in its own `pcall` so one failing cannot block the other or the gameplay caller.
- **Per-player session record** (`{ sessionId, startedAt, eventsThisMinute, deniedThisMinute, eventsByName, firstDispatchAt, firstSaleAt, firstPurchaseAt, gaInitDone, gaUserSent, gaSessionStartSent, gaBuffer, gaBackoffUntil }`) keyed by `UserId`. Session ends on `Players.PlayerRemoving` and emits `session_end` with duration + counts (Roblox custom event AND GA `session_end` with `length`).
- **Rate limit:** rolling 60-second window per player. Hard cap from `TelemetryConfig.RateLimit.perPlayerEventsPerMinute` (default **30**). Exceeding events are dropped *and* a single `telemetry_dropped` summary event fires per minute per player (so we can see drops without a runaway loop).
- **Payload size guard:** if a properties table serializes (`HttpService:JSONEncode`) > `oversizePayloadBytes` (default **4096**), drop the event and emit `telemetry_dropped { reason = "oversize", eventName, sizeBytes }` once per (event, player, minute).
- **Sampling:** for high-volume events listed in `TelemetryConfig.Sampling`, draw `math.random()` against the configured rate before queueing.
- **Queue + drain.** Roblox `AnalyticsService` is dispatched **synchronously, per event** inside `_fanOut` (its API takes one event per call and returns instantly). GameAnalytics is **buffered per user** with a background drain `task` that flushes per §4.6.8 (every 8s / 100 events / on leave / on `BindToClose`) and applies §4.6.9 backoff on failure.
- **Debug mode:** when `TelemetryConfig.Debug == true` (default in Studio), `Track` also `print`s a structured line `[Telemetry] eventName user=12345 sessionId=… {props}`. **Never** `print` in production: the prod toggle is `Debug = false`.

---

## 6. Event catalog (insertion target for the implementer)

Naming convention: **`snake_case`**, domain prefix, present-tense verb where it's an action. Every event automatically gets the §4.3 context fields; only **delta** properties are listed below.

**Sample rates:** default **1.0** unless noted. Listed in `TelemetryConfig.Sampling`.

**`gaCategory` column** is the GameAnalytics category each event maps to per §4.6.7. Roblox `AnalyticsService` routing is implicit per event class (Funnel / Economy / Progression / Custom) and does not need a column.

### 6.1 Onboarding / session

| Event | gaCategory | Trigger (file → function) | Properties (delta-only) |
|-------|------------|---------------------------|-------------------------|
| `session_start` | `session_start` (built-in, after `init`+`user`) | `Telemetry._onPlayerAdded` (new module) | `joinedAtUnix`, `accountAgeDays = player.AccountAge`, `membershipType = player.MembershipType.Name` |
| `session_end` | `session_end` (built-in, with `length`) | `Telemetry._onPlayerRemoving` | `durationSeconds`, `dispatchesThisSession`, `salesThisSession`, `cashEarnedThisSession`, `robuxSpentThisSession` |
| `first_join` | `design` (`event_id = "meta:first_join"`) | `OilStateService:_loadProfile` when `version == nil` (i.e. brand-new save) | `oilProfileVersionAtCreate` |
| `ftue_started` | `design` (`event_id = "ftue:started"`) | `FtueService:_setStep` when prev `nil` → `Intro` | `step = "Intro"` |
| `client_ready` | `design` (`event_id = "meta:client_ready"`) | (deferred) client → server hello via existing `RequestOilSnapshot` round-trip | `clientLoadSeconds` (if measurable) |

### 6.2 FTUE funnel (use `Telemetry.Funnel(player, "ftue", ordinal, stepId)`)

The funnel ordinal comes from `FtueConfig.Order` (1 = `Intro`, 2 = `WaitDrillOil_WIP`, …, 12 = `Done`).

| Event | gaCategory | Trigger | Properties |
|-------|------------|---------|------------|
| `funnel_ftue` (start of step) | `progression` (`Start`, `progression01="ftue"`, `progression02=stepId`) | `FtueService:_setStep` on **transition** | `funnelStep = ordinal`, `stepId`, `secondsInPreviousStep` |
| `ftue_step_completed` | `progression` (`Complete`) | Same site, on the **outgoing** step before `_setStep` advances | `stepId`, `secondsInStep` |
| `ftue_skipped` | `progression` (`Fail`) | `FtueService` `RequestFtueSkip` handler | `stepIdAtSkip` |
| `ftue_done` | `progression` (`Complete`, `progression02="Done"`) | `FtueService` reaches `Done` and grants `TutorialCompleteCashReward` | `cashGranted = FtueConfig.TutorialCompleteCashReward` |

### 6.3 Voyage / engagement

| Event | gaCategory | Trigger (file → function) | Properties |
|-------|------------|---------------------------|------------|
| `shipment_dispatched` | `design` (`voyage:dispatched`) | `OilShipmentService:_handleDispatch` after the manifest validates and `BoatDockService` reserves the dock | `shipmentId`, `manifestBarrels`, `manifestByTier`, `dispatchFee`, `shipSpeedLevel`, `shipCapacityLevel`, `shipSkinId`, `straitEngineStateAtDispatch`, `autoShip = bool`, `securityPersonnelActive = bool` |
| `shipment_first_dispatched` | `design` (`voyage:first_dispatched`) | Same site, only when `Telemetry.SessionGet(userId, "firstDispatchAt") == nil` | `secondsSinceJoin` |
| `shipment_voyage_started` | `design` (`voyage:started`) | `OilShipmentService:_runShipment` after path build | `pathLength`, `laneIndex`, `straitTriggerSlots = #slots` |
| `strait_waypoint_evaluated` | `design` (`strait:waypoint_evaluated`) | `OilShipmentService:_handleStraitWaypointTrigger` start (every trigger crossing) — **sample 0.1** | `pathIndex`, `bracket`, `occurred = bool` |
| `strait_event_fired` | `design` (`strait:event_fired:<eventId>`) | Same function, when an event is selected | `eventId`, `severity`, `bracket`, `displayName`, `priceMultiplierFactor?`, `pauseSeconds?`, `barrelsLost?`, `totalLoss = bool` |
| `shipment_completed` | `design` (`voyage:completed`) | `OilShipmentService:_runShipment` success branch (warehouse delivered) | `shipmentId`, `barrelsDelivered`, `payoutEstimate`, `straitEventsHit`, `voyageSeconds`, `priceMultiplierFinal` |
| `shipment_total_loss` | `design` (`voyage:total_loss:<reason>`) | `OilShipmentService:_finishShipmentWithoutPayout` | `shipmentId`, `reason` (`"missile"`, `"mine"`, `"us_ship_slap"`, `"forced_pirate_hit"`, …), `barrelsLost`, `eventId?` |
| `shipment_pirate_hit` | `design` (`pirate:hit_victim`) | `OilShipmentService:_executeForcedContractPirateRaid` victim branch | `shipmentId`, `contractorUserId`, `stolenByTier`, `stolenTotal` |
| `shipment_pirate_hit_payout` | `design` (`pirate:hit_payout`) | Same function, **contractor** branch (`_deliverContractStolenOil`) | `contractId`, `victimUserId`, `stolenByTier`, `stolenTotal` |
| `security_personnel_consumed` | `design` (`security:consumed`) | `SecurityPersonnelService:TryConsumeForDispatch` → returns true | `shipmentId`, `remainingOwned` |
| `security_personnel_deflected` | `design` (`security:deflected:<eventId>`) | `OilShipmentService:_handleStraitWaypointTrigger` early-return on `shipment.eventImmunity` | `eventIdThatWouldHaveFired`, `severity` |
| `player_died` | `design` (`player:died:<cause>`) | `KillZoneService` death handler (or `Player.CharacterRemoving` + `Humanoid.Died`) | `cause` (`"killzone"`, `"airstrike"`, `"nuke"`, `"unknown"`), `position` (`{x,y,z}`), `streakBeforeDeath?` |

### 6.4 Economy — sources and sinks (use `Telemetry.Economy`)

`flowType = "Source"` increases player wallet / inventory; `"Sink"` decreases it. Soft currency goes to GA `resource`; the dedicated `equipment_purchase_failed` row goes to GA `error`.

| Event (`reason`) | gaCategory | Trigger | `currency` | Properties |
|------------------|------------|---------|------------|------------|
| `oil_pumped` (Source) | `resource` (Source, `oil_<tier>`) | `OilProductionService` per-pump tick — **sample 0.05** | `"oil_<tier>"` | `tier`, `barrels`, `chunkId`, `tileId` |
| `oil_pump_collected` (Source) | `resource` (Source, `oil_<tier>`) | `OilProductionService` `pumpCollected` — **sample 0.05** | `"oil_<tier>"` | `barrelsCollected`, `chunkId` |
| `oil_sold` (Source) | `resource` (Source, `cash`, `item_type="oil_sold"`) | `OilMarketService:HandleSellType` / `HandleSellWarehouseBarrels` / `HandleSellAll` | `"cash"` | `barrelsByTier`, `cashGained`, `currentPrices`, `straitEngineState`, `marketTrend` |
| `oilman_sold` (Source) | `resource` (Source, `cash`, `item_type="oilman_sold"`) | `OilmanService` `RequestOilmanSell` handler | `"cash"` | `barrelsByTier`, `cashGained` |
| `instant_sold` (Source) | `resource` (Source, `cash`, `item_type="instant_sold"`) | `InstantSellService` `RequestInstantSell` handler | `"cash"` | `barrelsByTier`, `cashGained` |
| `cash_granted_dev` (Source) | `resource` (Source, `cash`, `item_type="dev_grant"`) | `OilStateService:AddCash` when called with `{ skipMultiplier = true }` AND from a dev grant path | `"cash"` | `amount`, `reason = "dev_grant"` |
| `dispatch_fee` (Sink) | `resource` (Sink, `cash`, `item_type="dispatch_fee"`) | `OilShipmentService:_handleDispatch` after fee deduction | `"cash"` | `feeAmount`, `shipmentId` |
| `equipment_purchased` (Sink) | `resource` (Sink, `cash`, `item_type="equipment"`, `item_id=<itemId>`) | `EquipmentShopService:_handlePurchase` success | `"cash"` | `itemId`, `price`, `stackCount`, `ftueFreeOverride = bool` |
| `equipment_purchase_failed` | `error` (`severity="warning"`) | Same, failure path | n/a | `itemId`, `code`, `message` |
| `chunk_unlocked` (Sink) | `resource` (Sink, `cash`, `item_type="chunk"`, `item_id=<chunkId>`) | `ChunkOwnershipService` on owned-flag flip after pay | `"cash"` | `chunkId`, `cost` |
| `warehouse_upgraded` (Sink) | `resource` (Sink, `cash`, `item_type="warehouse_upgrade"`) | `WarehouseService:TryUpgrade` success | `"cash"` | `tierFrom`, `tierTo`, `cost`, `newCapacity` |
| `oil_tank_upgraded` (Sink) | `resource` (Sink, `cash`, `item_type="oil_tank_upgrade:<oilType>"`) | `OilTankService` upgrade handler | `"cash"` | `oilType`, `tierFrom`, `tierTo`, `cost` |
| `ship_speed_upgraded` (Sink) | `resource` (Sink, `cash`, `item_type="ship_speed"`) | `OilStateService:TryUpgradeShipSpeed` success | `"cash"` | `levelFrom`, `levelTo`, `cost` |
| `ship_capacity_upgraded` (Sink) | `resource` (Sink, `cash`, `item_type="ship_capacity"`) | `OilStateService:TryUpgradeShipCapacity` success | `"cash"` | `levelFrom`, `levelTo`, `cost` |
| `ship_skin_equipped` | `design` (`ship:skin_equipped:<skinId>`) | `OilStateService:SetShipSkinId` | n/a | `skinIdFrom`, `skinIdTo` |
| `equipment_shop_rotated` | `design` (`shop:rotation`) | `EquipmentShopService:_rollShopStock` | n/a | `rotationId`, `itemsInStock = #stockMap` |

### 6.5 Strait / world events

| Event | gaCategory | Trigger | Properties |
|-------|------------|---------|------------|
| `strait_state_changed` | `design` (`strait:state_changed:<next>`) | `StraitStateService:_publishState` when value differs from previous | `previous`, `next`, `cause` (`"organic_roll"`, `"force_lock"`, `"messaging"`) |
| `strait_force_lock` | `design` (`strait:force_lock:<engineState>`) | `StraitStateService:ForceStateForDuration` (already emitted via placeholder) | `engineState`, `seconds`, `byUserId` |
| `nuke_fired` | `design` (`army:nuke_fired`) | `ArmyGeneralService:_executeNuke` | `victimUserId?`, `freeOrPaid` |
| `airstrike_fired` | `design` (`army:airstrike_fired`) | `ArmyGeneralService:_handleAirstrike` after grant | `victimUserId`, `freeOrPaid` |
| `pirate_hire_created` | `design` (`pirate:hire_created`) | `HitContractService:TryCreateHit` success | `contractId`, `victimUserId`, `freeToken = bool` |
| `pirate_hire_refunded` | `design` (`pirate:hire_refunded:<reason>`) | `HitContractService:RefundContract` | `contractId`, `reason` |
| `pirate_hire_executed` | `design` (`pirate:hire_executed`) | `HitContractService:MarkContractExecuted` | `contractId`, `shipmentId?` |

### 6.6 Monetization

`Telemetry.Purchase` is the wrapper. Each successful Robux event fans out to (a) `AnalyticsService:LogEconomyEvent` with `currencyType = "Robux"` and (b) GameAnalytics `business` with `currency="USD"` + `amount=math.floor(robuxPrice * TelemetryConfig.RobuxToUsd * 100)` integer USD cents, **`RobuxToUsd = 0.0035`** (locked, §11 Resolved §11.3). Failure / replay events go to GA `error` instead.

| Event | gaCategory | Trigger (file → function) | Properties |
|-------|------------|---------------------------|------------|
| `monetization_prompted` | `design` (`monetization:prompted:<itemId>`) | `MonetizationService:_handlePromptRequest` after pre-prompt validation passes | `productKind`, `productId`, `itemId`, `robuxPrice`, `oneTimePurchase` |
| `monetization_prompt_failed` | `error` (`severity="warning"`) | Same function on early reject | `code` (`ERR_PRODUCT_NOT_CONFIGURED`, `ERR_ALREADY_PURCHASED`, …), `itemId` |
| `monetization_purchased` | `business` (`cart_type="DevProduct"`, `currency="USD"`, `amount=<cents>`) | `MonetizationService:_processReceipt` after `_recordReceiptGranted` | `productKind = "DevProduct"`, `productId`, `itemId`, `robuxPrice`, `replay = false` |
| `monetization_purchased_replay` | `error` (`severity="info"`) | `_processReceipt` early-return on already-granted | `productId`, `itemId` |
| `monetization_grant_failed` | `error` (`severity="error"`) | `_processReceipt` when `_applyGrant` returns false | `productId`, `itemId`, `error` |
| `monetization_first_purchase` | `design` (`monetization:first_purchase`) | `_processReceipt` when `Telemetry.SessionGet(userId, "firstPurchaseAt") == nil` | `productId`, `secondsSinceJoin` |
| `gamepass_purchased` | `business` (`cart_type="GamePass"`, `currency="USD"`, `amount=<cents>`) | `MonetizationService` `MarketplaceService.PromptGamePassPurchaseFinished` connection (`wasPurchased = true`) | `productKind = "GamePass"`, `productId`, `itemId`, `gamePassEffect?` |
| `gamepass_prompt_cancelled` | `design` (`monetization:gamepass_cancelled:<itemId>`) | Same connection (`wasPurchased = false`) | `productId`, `itemId` |
| `gamepass_owned_resolved` | `design` (`monetization:gamepass_owned_resolved`) | `MonetizationService:HasGamePass` first-resolve on join | `gamePassId`, `owned` |

### 6.7 Engagement / errors

| Event | gaCategory | Trigger | Properties |
|-------|------------|---------|------------|
| `profile_load_failed` | `error` (`severity="error"`) | `PersistenceService` (already wired) | `userId`, `error` |
| `profile_save_failed` | `error` (`severity="warning"`) | `PersistenceService` (already wired) | `userId`, `error` |
| `oil_state_load_failed` | `error` (`severity="error"`) | `OilStateService:_loadProfile` pcall failure | `userId`, `attempt`, `error` |
| `auto_ship_engaged` | `design` (`autoship:engaged`) | `AutoShipService:_onSetAutoShip` when enabled flips false → true | `priority`, `devBypass` |
| `auto_ship_dispatched` | `design` (`autoship:dispatched`) | `AutoShipService:_tryAutoDispatch` success | `manifestBarrels`, `priority` |
| `auto_ship_skipped` | `design` (`autoship:skipped:<reason>`) | `_tryAutoDispatch` returns false (no barrels / dock busy) | `reason` |
| `dock_idle_to_active` | `design` (`dock:idle_to_active`) | `BoatDockService` transition | `userId` |
| `telemetry_dropped` | `error` (`severity="warning"`) | Internal — emitted by `Telemetry` itself when rate limit / oversize / GA buffer overflow fires | `reason`, `eventName?`, `count` |
| `telemetry_circuit_open` | `error` (`severity="critical"`) | Internal — emitted once when the per-server 5000 events/min circuit breaker trips (§8) | `windowSeconds`, `eventsInWindow` |

### 6.8 D1 / D7 retention proxies (no separate emit; computed from `session_start`)

We do **not** emit a distinct `retained_d1` event — retention is **derived** from `session_start` timestamps in GameAnalytics' built-in retention dashboard (and from `LogCustomEvent("session_start")` aggregation in the Roblox Creator Dashboard). Implementer just needs to make sure `session_start` always fires for both backends and includes `userId` and `joinedAtUnix`.

---

## 7. Wire-up plan — per service insertion-point map

For the gameplay engineer: where exactly to drop `Telemetry.*` calls. **No code in this SPEC** — just bullet-form file + function + event id.

- **`OilShipmentService:_handleDispatch`** (after `BoatDockService` reserves and `AddCash(-fee)`):
  - `Telemetry.Economy(player, "Sink", fee, "cash", "dispatch_fee", { kind = "shipment", id = shipmentId })`
  - `Telemetry.Track(player, "shipment_dispatched", { …§6.3… })`
  - If `firstDispatchAt == nil`: also `Telemetry.Track(player, "shipment_first_dispatched", …)` and `Telemetry.SetSession(userId, "firstDispatchAt", os.time())`.
  - `Telemetry.Funnel(player, "first_run", 2, "first_dispatch")` if first.

- **`OilShipmentService:_runShipment`** start: `Telemetry.Track(owner, "shipment_voyage_started", …)`.

- **`OilShipmentService:_handleStraitWaypointTrigger`** at top: `Telemetry.Track(owner, "strait_waypoint_evaluated", { occurred = false, … })` (sampled 0.1). After event selection: `Telemetry.Track(owner, "strait_event_fired", { eventId, severity, … })`.

- **`OilShipmentService` success branch** (`_handleOwnerAfterSuccessfulShipmentFinish` or the last lines of `_runShipment` before resolve): `Telemetry.Track(owner, "shipment_completed", …)` and `Telemetry.Funnel(owner, "first_run", 3, "first_delivered")` if `firstDeliveredAt == nil`.

- **`OilShipmentService:_finishShipmentWithoutPayout`**: `Telemetry.Track(owner, "shipment_total_loss", { reason, eventId? })`.

- **`OilShipmentService:_executeForcedContractPirateRaid`** (both victim and contractor branches): `shipment_pirate_hit` and `shipment_pirate_hit_payout`.

- **`MonetizationService:_handlePromptRequest`** end (post pre-prompt validation, before / after `MarketplaceService:Prompt*Purchase`): `monetization_prompted` on success, `monetization_prompt_failed` on early reject.

- **`MonetizationService:_processReceipt`** after `_recordReceiptGranted` (both happy and replay paths): `monetization_purchased` / `monetization_purchased_replay`. On `_applyGrant` failure (before the `NotProcessedYet` return): `monetization_grant_failed`. On `firstPurchaseAt == nil`: also `monetization_first_purchase` + `Telemetry.Funnel(player, "first_run", 5, "first_purchase")`.

- **`MonetizationService` `PromptGamePassPurchaseFinished` connection**: `gamepass_purchased` / `gamepass_prompt_cancelled`. After `HasGamePass` resolves on join: `gamepass_owned_resolved`.

- **`FtueService:_setStep`** (canonical transition site):
  - On the *outgoing* step (if any): `Telemetry.Track(player, "ftue_step_completed", { stepId = previous, secondsInStep })`.
  - On the *incoming* step: `Telemetry.Funnel(player, "ftue", ordinal(step), step)`.
  - On `step == "Done"` first time: `ftue_done`.

- **`FtueService` `RequestFtueSkip` handler**: `ftue_skipped`.

- **`OilMarketService:HandleSellType` / `HandleSellWarehouseBarrels` / `HandleSellAll`** after `AddCash` succeeds: `Telemetry.Economy(player, "Source", cashGained, "cash", "oil_sold", { kind = "oil", id = oilType or "mixed" })` + `Telemetry.Track(player, "oil_sold", { currentPrices = OilMarketService:GetCurrentPrices(), straitEngineState })`. If `firstSaleAt == nil`: `Telemetry.Funnel(player, "first_run", 4, "first_sale")`.

- **`OilmanService` / `InstantSellService`** sell handlers: same shape with `reason = "oilman_sold"` / `"instant_sold"`.

- **`EquipmentShopService:_handlePurchase`** success: `Telemetry.Economy(player, "Sink", price, "cash", "equipment_purchased", { kind = "equipment", id = itemId })` + `Telemetry.Track(player, "equipment_purchased", { ftueFreeOverride })`. Failure: `equipment_purchase_failed`.

- **`EquipmentShopService:_rollShopStock`**: `equipment_shop_rotated` (server-scoped: pass `nil` for player).

- **`ChunkOwnershipService`** at the place that sets `chunk.isOwned = true` after pay (currently the proximity / sign click handler — wire on the same `OilStateService:AddCash(-cost)` callback): `chunk_unlocked` Sink.

- **`WarehouseService:TryUpgrade`** success: `warehouse_upgraded` Sink.

- **`OilStateService:TryUpgradeShipSpeed` / `TryUpgradeShipCapacity`** success: `ship_speed_upgraded` / `ship_capacity_upgraded` Sink.

- **`OilStateService:SetShipSkinId`**: `ship_skin_equipped`.

- **`OilTankService`** upgrade handler success: `oil_tank_upgraded` Sink.

- **`StraitStateService:_publishState`** when previous != current: `strait_state_changed`. Existing `strait_force_lock` call site stays.

- **`HitContractService:TryCreateHit` / `RefundContract` / `MarkContractExecuted`**: `pirate_hire_*` events.

- **`ArmyGeneralService:_executeNuke` / `_handleAirstrike`** success: `nuke_fired` / `airstrike_fired`.

- **`SecurityPersonnelService:TryConsumeForDispatch`** when it returns true: `security_personnel_consumed`. **`OilShipmentService:_handleStraitWaypointTrigger`** when it short-circuits on `eventImmunity`: `security_personnel_deflected`.

- **`AutoShipService:_onSetAutoShip` / `_tryAutoDispatch`**: `auto_ship_engaged` / `auto_ship_dispatched` / `auto_ship_skipped`.

- **`KillZoneService`** death hook: `player_died`.

- **`Players.PlayerAdded` / `Players.PlayerRemoving`** in `Telemetry` itself: `session_start` / `session_end`.

- **`game:BindToClose`** in `init.server.luau` (already present): add a `Telemetry.Flush({ graceSeconds = 4 })` call **before** `RemoteService:Stop()` so the flush completes before the server tears down.

---

## 8. Server-authoritative + anti-spam + sampling

- **Server-only emit.** `Telemetry.Track` early-returns when `not RunService:IsServer()`. There is **no** v1 RemoteEvent that lets clients enqueue arbitrary events.
- **Per-player rate limit.** Default **30 events / minute / player** from `TelemetryConfig.RateLimit.perPlayerEventsPerMinute`. Drops emit a single `telemetry_dropped` summary per minute per player so we can see drops without spamming the backends with the dropped payloads themselves.
- **Server-scope rate limit.** Server-level events (no player) share a separate **120 / minute** bucket so a runaway service loop cannot DOS either backend.
- **Per-server global circuit breaker.** GameAnalytics' free tier is generous but not unlimited. Track a rolling 60-second total across **all** events emitted on this server; if it exceeds **5000 events / minute** (`TelemetryConfig.RateLimit.perServerEventsPerMinute`), open the circuit: drop new events for the rest of the window AND emit exactly **one** `telemetry_circuit_open` event into GA's `error` category (`severity = "critical"`) with `eventsInWindow` and `windowSeconds`. Roblox `AnalyticsService` is also short-circuited during the open window so we don't fan out a flood the breaker just declared abusive. Reset on the next minute boundary.
- **Oversize guard.** `HttpService:JSONEncode` size > `oversizePayloadBytes` (default 4096) → drop, emit `telemetry_dropped { reason = "oversize" }` once per (event, player, minute).
- **GA buffer overflow.** Per §4.6.8 hard cap: per-user buffer > 500 → drop oldest, emit `telemetry_dropped { reason = "ga_buffer_overflow" }` once per (player, minute).
- **Sampling.** High-volume events (`strait_waypoint_evaluated`, `oil_pump_collected`, `oil_pumped`) ship at < 1.0 from `TelemetryConfig.Sampling`. The drop is a `math.random()` check; the surviving event records its `sampleRate` so downstream queries can scale up.
- **No PII.** Payload assembler **strips** `player.Name`, `player.DisplayName`, character positions tighter than 1-stud snap, and any string that looks like chat content. UserId only.
- **HttpService tolerance (GA only).** GA calls go through a wrapper with `HttpService:RequestAsync` + 10s timeout + the §4.6.9 backoff. On terminal failure we drop the slice and emit `telemetry_dropped { reason = "ga_http_failed" }`. A failed GA batch must **never** crash the service, block the Roblox `AnalyticsService` fan-out, or block gameplay.

---

## 9. Bootstrap & shutdown — exact ordering for dual fan-out

In `src/server/init.server.luau` (no edits in this SPEC; documenting target shape for the implementer):

### 9.1 Server boot

1. `RemoteService:Init()` (already first).
2. Load secrets: `local secrets = require(ServerStorage:WaitForChild("Secrets"):FindFirstChild("GameAnalytics"))` (the `Secrets/` folder is gitignored; `Secrets.template.luau` lives in repo). If the require fails or returns `nil`, log one warn and continue — GA fan-out becomes a no-op for the session.
3. `local Telemetry = require(ReplicatedStorage.Shared.Telemetry)` then:

    ```luau
    Telemetry.Init({
        gaGameKey = secrets and secrets.gameKey,
        gaSecretKey = secrets and secrets.secretKey,
        playerStateLookup  = function(userId) return OilStateService:GetState(userId) end,
        straitLookup       = function() return StraitStateService:GetCurrentState() end,
        shipmentLookup     = function(userId) return OilShipmentService:GetActiveShipmentForUser(userId) end,
    })
    ```

4. `Telemetry.Init` issues **one** GA `POST /init` (server-wide, before any user events). Cache `serverTimestampOffset = response.server_ts - os.time()`. If `enabled = false` in the response, set `_gaDisabled = true` and skip GA fan-out for the session (Roblox `AnalyticsService` keeps working).
5. `TelemetryService:Init()` (the existing wrapper service) is kept so `StraitStateService:Init(RemoteService, TelemetryService)` and the four other services that already take `telemetryService` keep compiling. The wrapper proxies to `Telemetry.Track`.

### 9.2 Per-player lifecycle

On `Players.PlayerAdded(player)`:

1. Assign `sessionId = HttpService:GenerateGUID(false)`. Set `sessionStartedAt = os.clock()`.
2. **Roblox fan-out (synchronous):** `AnalyticsService:LogCustomEvent(player, "session_start", 1, accountAgeDays, membershipType, …)`.
3. **GA fan-out (queued, in this exact order):**
    1. Queue a `user` event (§4.6.5 step 2).
    2. Queue a `session_start` event (§4.6.5 step 3) with the freshly-minted `sessionId` as GA's `session_id`.
    3. From this point any other gameplay-emitted events for this user may queue; the drain loop guarantees `user` and `session_start` POST first.

On `Players.PlayerRemoving(player)`:

1. Compute `durationSeconds = math.floor(os.clock() - sessionStartedAt)`.
2. **Roblox fan-out:** `AnalyticsService:LogCustomEvent(player, "session_end", durationSeconds, dispatchesThisSession, salesThisSession, robuxSpentThisSession)`.
3. **GA fan-out:** queue a `session_end` event with `length = durationSeconds`.
4. Force-flush the user's GA buffer with a **2-second timeout** (`task.wait` loop polling the in-flight slice). If the flush has not completed in 2s, leave the slice in the buffer; the `BindToClose` flush picks it up.
5. Drop the per-player session record (`gaUserSent`, `gaSessionStartSent`, etc.) **after** the flush attempt.

### 9.3 Server shutdown

Inside the existing `game:BindToClose` block in `init.server.luau`, **before** `RemoteService:Stop()`:

1. **5-second grace.** Allow any in-flight per-user flush from §9.2 step 4 to complete.
2. **Iterate all users with non-empty GA buffers** and drain — each one gets up to 5s of HTTP time.
3. **Hard ceiling: 25 seconds total.** Roblox kills the server at ~30s; we leave a 5s buffer for the existing service `:Stop()` calls. If we hit 25s and buffers are still non-empty, drop them (data is lost on this shutdown — accept it; alternative is the server killed mid-flush which is no better).
4. Roblox `AnalyticsService` events emitted during `BindToClose` flush synchronously inside the same call, so no extra grace is needed for them.

### 9.4 Studio behavior

- `RunService:IsStudio()` and `TelemetryConfig.ForceBackends ~= true`:
  - Roblox `AnalyticsService` calls are made (cheap, harmless).
  - GA HTTP calls are **replaced** by `print("[Telemetry/GA-debug] " .. HttpService:JSONEncode(slice))` so the structure is auditable in Output without burning quota.
- Override with `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true` in the command bar for end-to-end QA in Studio (you must still have HttpService allowlisted and secrets present in `ServerStorage`).

---

## 10. Test checklist

- [ ] `session_start` fires once per join and `session_end` once per leave, with `durationSeconds` matching real session length within 1s.
- [ ] `shipment_dispatched` fires exactly once per successful dispatch; `shipment_completed` exactly once per successful delivery; `shipment_total_loss` exactly once per failure (no double-emit on missile + total loss).
- [ ] `strait_waypoint_evaluated` sampled ≈ 10% across many trips (verify with N=200 runs).
- [ ] `monetization_purchased` fires after `_recordReceiptGranted`; on a Roblox receipt-replay it routes to `monetization_purchased_replay`, not duplicate `monetization_purchased`.
- [ ] `gamepass_purchased` fires from `PromptGamePassPurchaseFinished(wasPurchased = true)` only (not from `HasGamePass` resolve on join).
- [ ] `funnel_ftue` ordinals match `FtueConfig.Order`; skipping with `RequestFtueSkip` emits `ftue_skipped` and does NOT emit further `funnel_ftue` for the skipped tail.
- [ ] Rate limit: a fake service emitting 100 events / 5s for one player produces ≤ 30 events delivered + 1 `telemetry_dropped` summary in that minute.
- [ ] Oversize: a payload with a 5KB string is dropped + `telemetry_dropped { reason = "oversize" }` fires once per (event, minute).
- [ ] No PII: a `Telemetry.Track` call that includes `player.Name` in `properties` strips the field at the assembler before fan-out.
- [ ] `BindToClose` flush completes within 4s in a synthetic shutdown test (use Studio Run + Stop with 5 in-flight events).
- [ ] Studio `Debug = true`: every `Track` call also `print`s the structured line.
- [ ] Live build `Debug = false`: zero `[Telemetry]` lines in Output during a normal session.
- [ ] Roblox fan-out: every event in §6 that maps to `AnalyticsService` shows up in the **Roblox Creator Dashboard** within ~5min (Roblox's documented latency).
- [ ] GameAnalytics fan-out: every event reaches the **GameAnalytics live event log** with the expected `user_id` (= `UserId` as string), `session_id`, and `category`. `init` + `user` + `session_start` always precede the first gameplay event for a user.
- [ ] HMAC: a request to `POST /events` with a deliberately-mangled body fails GA's signature check (returns 401); the production path produces 200 OK.
- [ ] Backoff: simulating a 500 from GA causes the slice to re-queue and the next attempt to fire after ≥ 1s; chained 500s reach the 30s cap, then a successful response clears the slice.
- [ ] Buffer cap: a synthetic 600-event burst for one user produces ≤ 500 buffered + 1 `telemetry_dropped { reason = "ga_buffer_overflow" }`.
- [ ] Circuit breaker: a synthetic 6000-event burst within 60s for the server trips the breaker; exactly one `telemetry_circuit_open` reaches GA `error`; subsequent events in the window are dropped on both backends.
- [ ] Secrets missing — Game Key: deleting the `GA_GAME_KEY` Creator Hub secret and rebooting produces one `[Telemetry/GA] Secrets missing` warn and zero HTTP calls; Roblox `AnalyticsService` events still flow.
- [ ] Secrets missing — Secret Key: removing `ServerStorage.Secrets.GameAnalytics` (or its `secretKey` field) and rebooting produces the same one-shot warn; same fan-out independence.
- [ ] Secret Key never reaches Output: a deliberate `print(secretKey)` would leak it (Option A trade-off). Verify by `rg "print.*secretKey" src/` returning no production hits, and that the GA adapter's only `secretKey` reference is the HMAC call site.
- [ ] `Secret` userdata stays opaque: the Game Key is built via `HttpService:GetSecret("GA_GAME_KEY"):AddPrefix(...):AddSuffix(...)` and passed straight into `HttpService:RequestAsync({ Url = secretUrl, ... })`; no `tostring(secretUrl)` / `print(secretUrl)` anywhere in the adapter.
- [ ] `session_start` GA payload includes `custom_01` ∈ {`"<7d"`, `"7-30d"`, `"30-90d"`, `">90d"`} (NOT raw `accountAge`) and `custom_02` ∈ {`"premium"`, `"standard"`}. Verify in the GameAnalytics live event log on the first join.

### 10.A Deploy-time checklist (run once per place rollout)

1. **Studio toggle** — `Game Settings → Security → Allow HTTP Requests = ON` saved into the place file. *(Confirmed sufficient for this place — legacy blanket-allow mode, no per-domain allowlist enforcement; see §4.6.4.)*
2. **Game Key secret present** — Creator Hub → Configure Experience → **Secrets** → secret named **`GA_GAME_KEY`** with the GameAnalytics Game Key value.
3. **Secret Key present in `ServerStorage`** — `ServerStorage.Secrets.GameAnalytics` ModuleScript exists in the saved place returning `{ secretKey = "<real value>" }`. The repo `Secrets.template.luau` is **not** the live secret — confirm the live `secretKey` value is not the `PASTE_…` placeholder.
4. **First boot watch** — tail server Output (or use the GA live event log) for `[Telemetry/GA]`-prefixed messages from the first 60 seconds.
   - **Healthy:** `init` returns 200, `user` + `session_start` post 200, gameplay events follow.
   - **Failure mode A — `Http 403 domain-not-allowed`** (or similar): this place has been migrated off legacy blanket-allow onto Roblox's per-domain HTTP allowlist system. Open `https://create.roblox.com/dashboard/creations` → the experience → **Configure Experience** → **Security** → **"Allowed API Domains" / "HTTP request URL allowlist"** → add **`api.gameanalytics.com`** → redeploy. Roblox `AnalyticsService` half of the fan-out is unaffected and continues delivering throughout this window. *(Not expected for this place per §4.6.4 status note; documented for sibling experiences and future migrations.)*
   - **Failure mode B — `HttpService not enabled`**: redo step 1, save, redeploy.
   - **Failure mode C — secrets missing warn**: check which key the warn names and redo step 2 or 3 accordingly. The Game Key and Secret Key are checked independently; each missing one disables GA fan-out on its own.
   - **Failure mode D — `HttpService:GetSecret raised`**: the `GA_GAME_KEY` secret name doesn't exist on the Creator Hub for this experience. The `pcall` catches it; same recovery as failure mode C step 2.

---

## 11. Open questions for the user (decisions needed before implementation)

### 11.A Resolved decisions

| # | Date | Decision |
|---|------|----------|
| §11.A.0 | 2026-04-21 | **Backend choice = dual fan-out**: Roblox `AnalyticsService` (Creator Dashboard) + GameAnalytics REST v2. The earlier "PlayFab vs GameAnalytics vs custom" question is closed. |
| §11.A.1 | 2026-04-18 (revised) | **GA secret storage = split.** **Game Key** lives in Roblox first-party Secrets (Creator Hub → Configure Experience → Secrets → name `GA_GAME_KEY`), read at runtime via `HttpService:GetSecret("GA_GAME_KEY")`. **Secret Key** lives in the gitignored `ServerStorage.Secrets.GameAnalytics` ModuleScript returning `{ secretKey = "..." }`, with `src/server/Secrets/Secrets.template.luau` checked in for discoverability. **Why split:** `HttpService:GetSecret` returns a `Secret` userdata that cannot be reified to a string (that's its safety property); HMAC-SHA256 needs raw key bytes that the GA REST v2 protocol mandates. The Game Key (URL path identifier, low sensitivity) gets the first-party safe path; the Secret Key (true credential, but unavoidable in script memory for HMAC) keeps the original ModuleScript path with the same blast-radius mitigations. See §4.6.2 / §4.6.3 for the full protocol. Both must be present for GA fan-out; either missing → no-op. |
| §11.A.2 | 2026-04-18 | **Sample rates locked.** `Sampling.strait_waypoint_evaluated = 0.1`, `Sampling.oil_pumped = 0.05`, `Sampling.oil_pump_collected = 0.05`, all others `1.0`. Lives in `TelemetryConfig.Sampling` per §3.3. Treat as canonical until a follow-up decision changes them — do not silently re-tune. |
| §11.A.3 | 2026-04-18 | **Robux→USD conversion locked.** `TelemetryConfig.RobuxToUsd = 0.0035` (USD per 1 R$, DevEx-aligned). GA `business` `amount` = `math.floor(robuxPrice * 0.0035 * 100)` integer USD cents. Used by §4.6.7 + §6.6. |
| §11.A.4 | 2026-04-18 | **AccountAge + MembershipType on `session_start` approved with bucketing.** Both are public Roblox profile data and may be sent to GameAnalytics on `session_start` as `custom_01 = bucketed accountAge` (`"<7d"` / `"7-30d"` / `"30-90d"` / `">90d"`) and `custom_02 = membership` (`"premium"` / `"standard"`). Bucketing accountAge avoids leaking the exact join date. Locked in `TelemetryConfig.SessionStartCustomDimensions` per §3.3, spelled out in §4.6.5 step 3. |
| §11.A.5 | 2026-04-18 | **HTTP allowlist treated as deploy-time, not design-time.** The Studio toggle (`Game Settings → Security → Allow HTTP Requests = ON`) is always required. The per-domain Creator Hub allowlist (`https://create.roblox.com/dashboard/creations` → Configure Experience → Security → "Allowed API Domains" / "HTTP request URL allowlist" → add `api.gameanalytics.com`) is conditionally required only for experiences on Roblox's per-domain system, detected at first GA `POST /init`. Verification belongs in the §10.A deploy checklist; the GA adapter handles failure with §4.6.9 backoff and the Roblox `AnalyticsService` half is unaffected. See §4.6.4 for the full procedure. |
| §11.A.6 | 2026-04-18 | **DevLog deprecation timing locked: `T + 48h after GA fan-out is healthy in prod`.** The DevLog/`print` sweep ships as a **separate final PR** (PR 7 in §13) explicitly **gated** on: (a) the GA fan-out PR (PR 4) has been live in production for **≥ 48 hours**, AND (b) the GameAnalytics dashboard shows non-zero event ingestion across that window (proves the pipeline is delivering, not silently failing). If either gate is unmet, hold the DevLog PR — do not merge on a schedule. |

### 11.B Still open

*None.* All §11 questions are resolved as of 2026-04-18. Net-new questions raised during implementation should be added here with a date-tagged row.

---

## 12. Verification stub (QA to fill after implementation)

This section is a placeholder for `qa-reviewer`. Do not fill until the implementer's PR lands.

- [ ] Static review: every event in §6 has a matching `Telemetry.*` call site in source, found by `rg "Telemetry\.(Track|Funnel|Economy|Progression|Purchase)\(" src/server`.
- [ ] Live verification: a single 5-minute Studio session produces, at minimum, `session_start`, `session_end`, `funnel_ftue` (≥ 3 ordinals), `shipment_dispatched`, `oil_sold`, and zero `telemetry_dropped`.
- [ ] Production smoke: 1-hour observed shard produces > 95% events successfully delivered to the chosen backend (PlayFab / GameAnalytics) with `telemetry_dropped` rate < 1%.
- [ ] No regressions in existing `_telemetryService:Track` call sites (all five from §3.1 still appear in the backend with the original event names).
- [ ] No new entries in `RemoteNames.luau` (v1 is server-only).
- [ ] No `StarterGui` changes (rule check: `ui-architecture.mdc` is not in scope).

---

## Owner slices (handoff)

| Slice | Owner agent | Notes |
|-------|-------------|-------|
| `Shared.Telemetry` module + `TelemetryConfig.luau` + Roblox `AnalyticsService` fan-out + replace `TelemetryService` shim | **gameplay-systems-engineer** | First PR — §5 + §3.3 + §4.5. Verify in Studio with `Telemetry.Debug = true` before adding GA. |
| `Shared.Vendor.HmacSha256` + `Shared.Telemetry.GameAnalyticsAdapter` + `ServerStorage.Secrets.GameAnalytics` template | **gameplay-systems-engineer** | Second PR — §4.6. Includes HttpService allowlist check + secret loader. |
| Per-service insertion calls (§7) — top 5 events first | **gameplay-systems-engineer** | Third PR. Voyage + Economy + Monetization first, FTUE + retention next. |
| Per-service insertion calls (§7) — remainder | **gameplay-systems-engineer** | Fourth PR. |
| Verification (§12) | **qa-reviewer** | After each implementation PR lands. |
| UI / dashboards | **out of scope** | No StarterGui or ReplicatedStorage UI work. GameAnalytics dashboard tuning is owned outside the repo. |

---

## 13. Implementation order (gameplay engineer step-by-step)

Ship in **six** small PRs. Do not skip steps — each one isolates a failure mode you'd otherwise debug under the noise of the next.

1. **PR 1 — Config skeleton.** Add `src/shared/Config/TelemetryConfig.luau` with the table from §3.3 (sample rates, GA endpoint, batch size, backoff). No behavior yet. Reviewable in 10 minutes.
2. **PR 2 — Vendor HMAC.** Add `src/shared/Vendor/HmacSha256.luau` (~200 lines, MIT). File header documents the vendor exception. Add a tiny `tests/HmacSha256_spec.luau` (or a temporary `print` block) that round-trips a known vector against a published GameAnalytics test fixture so we know it works **before** we point it at the live API.
3. **PR 3 — `Shared.Telemetry` (Roblox fan-out only).** Build `init.luau` + `EventCatalog.luau`. Wire Roblox `AnalyticsService` only. `TelemetryConfig.GameAnalytics.enabled = false` for this PR. Verify in Studio with `Telemetry.Debug = true` — every `Track`, `Funnel`, `Economy`, `Progression`, `Purchase` call prints structured Output. Replace the existing placeholder `TelemetryService` so existing call sites compile.
4. **PR 4 — GameAnalytics REST client.** Add `GameAnalyticsAdapter.luau` (init / user / session_start / events / session_end + HMAC + per-user buffer + 8s drain + backoff per §4.6). Add the `ServerStorage.Secrets.GameAnalytics` template + gitignore rule. Document the HttpService allowlist domain (`api.gameanalytics.com`) in the PR description. Flip `TelemetryConfig.GameAnalytics.enabled = true`. Verify with a 1-player Studio session that GA's live event log shows `init` → `user` → `session_start` → some events → `session_end`.
5. **PR 5 — Wire the 5 highest-leverage events.** From §6: `shipment_dispatched`, `shipment_completed`, `oil_sold`, `monetization_purchased`, `funnel_ftue`. Ship to live; let it bake for 24h; verify both dashboards.
6. **PR 6 — Wire the remainder.** Everything else in §6/§7 in a single follow-up PR.
7. **PR 7 — DevLog / `print` deprecation sweep (gated, do NOT auto-merge).** Replace remaining `DevLog.log(...)` and ad-hoc `print(...)` diagnostics with `Telemetry.Track(...)` (`error` / `design` categories as appropriate) and delete the `DevLog` shim. **Gate (per §11.A.6):**
   - PR 4 (GA fan-out) has been live in production for **≥ 48 hours**, AND
   - The GameAnalytics dashboard shows **non-zero event ingestion** across that 48h window (proves delivery — not just "no crash").
   - If either condition fails, hold this PR and re-evaluate. Do not merge on a calendar schedule.

---

## 14. Revision history

| Date | Note |
|------|------|
| 2026-04-21 | Initial SPEC (architect handoff). Phase 1 = `AnalyticsService` only; Phase 2 default = PlayFab; existing placeholder `TelemetryService` documented as the pre-replacement state. |
| 2026-04-21 | **Backend decision: dual fan-out.** Replaced Phase 1/Phase 2 framing with concurrent Roblox `AnalyticsService` + GameAnalytics REST v2. Added §4.6 (GA integration specifics, HMAC, allowlist, init/user/session_start ordering, batching, backoff, secret storage, internal→GA category mapping). Added `gaCategory` column across §6. Added per-server 5000 events/min circuit breaker with `telemetry_circuit_open` event. Rewrote §9 with exact dual-fan-out bootstrap / shutdown ordering. Updated §11 (resolved backend question; added GA secret storage, allowlist, Robux→USD constant questions). Added §13 implementation order. |
| 2026-04-18 | **Decisions §11.1–§11.3 resolved** (secret storage path, sample rates, Robux→USD constant). §3.3, §4.6.7, §6.6 updated to reference the locked values directly; §11 reorganised into "Resolved decisions" (§11.A) + "Still open" (§11.B). |
| 2026-04-18 | **Decisions §11.B.1–§11.B.3 resolved** (allowlist as deploy-time check, AccountAge/MembershipType bucketed dimensions approved, DevLog deprecation gated on 48h post-launch). §4.6.4 expanded with Studio toggle vs Creator Hub per-domain allowlist split + 403 recovery procedure; §4.6.5 step 3 spells out the `custom_01` / `custom_02` payload; §3.3 adds `SessionStartCustomDimensions` to `TelemetryConfig`; §10 adds the deploy-time checklist (§10.A) and a custom-dimensions verification row; §13 adds gated PR 7; §11.B is now empty. |
| 2026-04-18 | **Secret storage split: GA Game Key via `HttpService:GetSecret`, GA Secret Key via gitignored ServerStorage ModuleScript** (HMAC requires raw bytes; `Secret` objects are non-extractable). Canonical Creator Hub secret name = `GA_GAME_KEY`. §3.3, §4.6.2, §4.6.3, §10, §10.A, §11.A.1 updated. **HTTP allowlist confirmed not enforced for this place** (legacy blanket-allow mode); §4.6.4 + §10.A note this and keep the per-domain recovery procedure documented for future migrations. |
