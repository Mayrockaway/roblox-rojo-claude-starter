# Player ship — one functional ship, upgrade tracks, cosmetic skins — SPEC

Authoritative handoff for **one logical ship per player** with **two upgrade dimensions** (speed, capacity) and **catalog entries as cosmetic skins only**.

**Implementation status:** The refactor described here is **implemented in this repository** (see **§3** and revision **§13**). This document remains the contract for future tuning (economy, new skins/models, strait `eventRisk` wiring) and QA.

---

## 1. Goal

- Every player has **exactly one functional ship** at any time. All **gameplay-relevant** numbers (capacity, voyage duration, dispatch fee, and hooks such as strait `eventRisk` when wired) derive from:
  - **`shipSpeedLevel`**: integer **1 … 10** (level 1 = baseline; max **10**).
  - **`shipCapacityLevel`**: integer **1 … 25** (level 1 = baseline; max **25**).
- **Cosmetic selection** from a **ship skin catalog** changes **only** which **3D model** is spawned for that player’s voyages. **Changing skin does not** change speed, capacity, fee, or travel time.
- **Example (must hold):** Player has default tanker skin, **speed 2**, **capacity 3**. They pick another catalog boat. After selection they still have **speed 2** and **capacity 3**; only the **visible hull** changes.

**Invariant (non-negotiable):**

> **Gameplay numbers = f(speedLevel, capacityLevel) only.**  
> **World appearance = g(skinId) only.**  
> **Never** read voyage/cargo stats from the skin catalog.

---

## 2. Out of scope (this feature slice)

- **Fine economy tuning** for upgrade curves (costs live in `ShipUpgradeConfig.luau`; adjust there after playtests).
- **Unlock rules** for paid or progression-gated skins (`ShipSkinCatalog` has no unlock enforcement yet).
- **Studio art pipeline** beyond the **rig contract** in **§7** (naming, required instances under `ReplicatedStorage.Assets`).
- **Strait waypoint event presentation** — see [strait-waypoint-events SPEC](../strait-waypoint-events/SPEC.md); resolver already exposes **`eventRisk`** for future wiring into strait occurrence math.
- **Dedicated upgrade HUD** in StarterGui (server remotes exist; **§6**).

---

## 3. Implementation snapshot (this repo)

| Area | Path | Role |
|------|------|------|
| Resolver (gameplay stats only) | `src/shared/Config/ShipStats.luau` | `ShipStats.Resolve(speedLevel, capacityLevel)` → `capacity`, `travelSeconds`, `dispatchFee`, `eventRisk` |
| Cosmetic skins | `src/shared/Config/ShipSkinCatalog.luau` | `Skins[skinId]`: `displayName`, `templateName`, optional `fxParticleScale`, `rarityDisplay`. Helpers: `GetSkin`, `ListForClient` |
| Upgrade costs + caps | `src/shared/Config/ShipUpgradeConfig.luau` | `MaxSpeedLevel` / `MaxCapacityLevel`, `GetSpeedUpgradeCost`, `GetCapacityUpgradeCost` |
| Legacy → v4 migration | `src/shared/Config/ShipProfileMigration.luau` | `FromLegacyBoatTypeId`, `SkinIdForLegacyBoatTypeId` (for old remote payloads) |
| Shipment limits / price mult | `src/shared/Config/BoatConfig.luau` | **`MaxConcurrentShipmentsPerPlayer`**, **`DefaultPriceMultiplier`** only (per-type `Boats` removed) |
| FX scale | `src/shared/ParticleFxScale.luau` | `ComputePayloadScale(boat, fxParticleScaleOverride?)` — hull extent × optional skin multiplier |
| Persisted profile v4 + migration | `src/server/Services/OilStateService.luau` | `shipSpeedLevel`, `shipCapacityLevel`, `shipSkinId`; **`version = 4`** on save; load path migrates **`version < 4`** using legacy **`selectedBoatTypeId`**; **`SetShipSkinId`**, **`TryUpgradeShipSpeed`**, **`TryUpgradeShipCapacity`** |
| Client oil snapshot | `OilStateService:GetStateForClient` | Includes **`resolvedShip`** (`capacity`, `dispatchFee`, `travelSeconds`, `eventRisk`), **`upgradeShipSpeedCost`**, **`upgradeShipCapacityCost`**, levels, **`shipSkinId`** |
| Dispatch + spawn + voyage | `src/server/Services/OilShipmentService.luau` | Dispatch payload **`{ manifest }`** only; stats from resolver + state; shipment carries **`shipSkinId`** + snapshot levels; **`GetShipSkinCatalogForClient`**; **`_spawnBoat(plot, shipment)`** clones **`ShipSkinCatalog`** `templateName` with **Tanker** fallback + Studio warn if template missing |
| Remotes + snapshot catalog | `src/server/Services/PlotResourceService.luau` | Oil snapshot **`config.shipSkinCatalog`**; **`RequestSetSelectedBoat`** accepts **`skinId`** or legacy **`boatTypeId`** (mapped via `ShipProfileMigration`); **`RequestSetShipSkin`**; **`RequestUpgradeShipSpeed`** / **`RequestUpgradeShipCapacity`** with rate limits + **`OilActionResult`** |
| Remote names | `src/shared/Net/RemoteNames.luau` | `RequestSetShipSkin`, `RequestUpgradeShipSpeed`, `RequestUpgradeShipCapacity` (plus existing `RequestSetSelectedBoat`, `RequestDispatchShipment`) |
| Dispatch UI | `src/client/UI/HudPanels/ShipOilPanel.luau` | Max load / fee from **`resolvedShip`** on `OilStateUpdate`; dispatch fires **`RequestDispatchShipment`** with **`manifest` only** |
| Skin picker UI | `src/client/UI/HudPanels/SelectShipPanel.luau`, `SelectShipPopulate.luau` | Grid from **`ShipSkinCatalog`**; viewport uses **`templateName`**; selection fires **`{ skinId }`** on **`RequestSetSelectedBoat`** |
| Shipment status line | `src/client/init.client.luau` | **`ShipmentStarted`**: prefers **`shipDisplayName`**, else **`shipSkinId`** / legacy **`boatTypeId`** |

**Legacy persistence:** Old DataStore rows may still contain **`selectedBoatTypeId`**; on load with **`version < 4`**, migration sets skin + levels (see comments in `ShipProfileMigration.luau`). New saves persist **`version = 4`** and ship fields only (no new writes of **`selectedBoatTypeId`**).

**Current skin catalog note:** All shipped skins use **`templateName = "Tanker"`** until additional models exist under **`ReplicatedStorage.Assets`**.

---

## 4. Architecture (implemented)

### 4.1 Module split (Shared)

| Module | Responsibility |
|--------|----------------|
| **`ShipStats`** | Single resolver for all numeric voyage/load stats from **(speed, capacity)** levels. |
| **`ShipSkinCatalog`** | Cosmetic only: ids, display names, **`templateName`**, optional **`fxParticleScale`**. |
| **`ShipUpgradeConfig`** | Per-step upgrade costs; caps 10 / 25. |
| **`ShipProfileMigration`** | Legacy boat type id → **`skinId`** + starting levels for v4 migration and legacy remote payloads. |
| **`BoatConfig`** | Global shipment constants only (`MaxConcurrentShipmentsPerPlayer`, `DefaultPriceMultiplier`). |

### 4.2 Player state and persistence

Persisted (v4): **`shipSpeedLevel`**, **`shipCapacityLevel`**, **`shipSkinId`**, **`version = 4`**.

**Migration:** If persisted **`version < 4`**, apply **`ShipProfileMigration.FromLegacyBoatTypeId(persisted.selectedBoatTypeId)`**. If **`version >= 4`** but **`shipSkinId`** is invalid, fall back to **`DefaultTanker`**; numeric levels are clamped.

### 4.3 Resolver rules

- **`ShipStats.Resolve`** is the **only** source for dispatch capacity check, fee, travel time, and **`eventRisk`** on new shipments.
- **Client** uses **`resolvedShip`** from **`OilStateUpdate`** / snapshot for the cargo UI; server re-validates on dispatch.

### 4.4 Dispatch and in-memory shipment

- **`RequestDispatchShipment`**: **`{ manifest }`**; optional **`boatTypeId`** in payload is **ignored**.
- Shipment row stores **`shipSkinId`**, **`shipSpeedLevel`**, **`shipCapacityLevel`**, plus copied numeric fields at dispatch time (so mid-voyage resolver changes do not alter an active row unless product later allows live mutation).

### 4.5 Spawn

- Clone **`ReplicatedStorage.Assets[templateName]`** from **`ShipSkinCatalog.GetSkin(shipSkinId).templateName`**.
- If template missing: use **`Tanker`** if present; else existing fallback boat builder. **Studio:** warn with skin id + template name.

### 4.6 Replication to client

- **Option A (implemented):** Skin list in **`RequestOilSnapshot`** → **`config.shipSkinCatalog`**; stats on **`OilStateUpdate`** via **`resolvedShip`** and upgrade cost fields.

---

## 5. Networking / remotes (implemented)

| Remote | Payload | Server |
|--------|---------|--------|
| `RequestDispatchShipment` | `{ manifest }` | `OilShipmentService:_handleDispatch` |
| `RequestSetSelectedBoat` | `{ skinId }` **or** legacy `{ boatTypeId }` | `PlotResourceService` → **`OilStateService:SetShipSkinId`** (legacy id mapped when possible) |
| `RequestSetShipSkin` | `{ skinId }` | Same; **`OilActionResult`** success/failure |
| `RequestUpgradeShipSpeed` | _(none)_ | **`TryUpgradeShipSpeed`**; rate limited |
| `RequestUpgradeShipCapacity` | _(none)_ | **`TryUpgradeShipCapacity`**; rate limited |

---

## 6. Client UI

| UI | Status |
|-----|--------|
| **`ShipOilPanel`** | **Shipped:** resolved capacity + fee; dispatch without `boatTypeId`. |
| **`SelectShipPanel` / `SelectShipPopulate`** | **Shipped:** skin-only grid + viewport by **`templateName`**. |
| **Upgrade ladders / toasts** | **Not shipped:** call **`RequestUpgradeShipSpeed`** / **`RequestUpgradeShipCapacity`** from a future HUD; handle **`OilActionResult`**. |

---

## 7. Skin rig contract (`ReplicatedStorage.Assets`)

Every skin template **Model** must expose the **same logical attachment points** the voyage code expects (see `OilShipmentService`: **`DeckSeat`**, **`BarrelStackRoot`**, **`PlayerFlag`**, etc.). Minimum **locked** requirements:

| Name / role | Requirement |
|-------------|-------------|
| **Primary / hull root** | Consistent with **Tanker** for movement / welds. |
| **Deck / barrel anchor** | Same semantics as **Tanker** for deck barrels and load VFX. |
| **Flag / branding** | Same descendant names as **Tanker** where referenced by code. |

Invalid or missing templates **fall back** to **Tanker** (with Studio warning when applicable).

---

## 8. Particle / FX scaling

- **`ParticleFxScale.ComputePayloadScale(boat, fxParticleScaleOverride?)`** uses model horizontal extent × optional **`ShipSkinCatalog`** **`fxParticleScale`** for that shipment’s skin.
- Strait / waypoint VFX use the **spawned** instance’s bounds where applicable.

---

## 9. Telemetry and shipment visual events

- **`ShipmentStarted`** / **`ShipmentResolved`** payloads (via **`ShipmentVisualEvent`**) include **`shipSkinId`**, **`shipDisplayName`**, and **`boatTypeId`** set to the **display name** for older client code that still reads **`boatTypeId`** as a label.
- **`boatTypeId`** as a **legacy functional id** is **not** used for stats after this refactor.

---

## 10. Test checklist

- [ ] Dispatch: manifest at **exactly** **`resolvedShip.capacity`** succeeds; **over capacity** fails with **`ERR_BOAT_CAPACITY`**.
- [ ] Dispatch fee and travel time match **`ShipStats.Resolve`** for the player’s current levels (spot-check in Studio).
- [ ] **Upgrade speed** to max **10** and **capacity** to max **25**; next request returns error (e.g. **`ERR_MAX_SPEED`** / **`ERR_MAX_CAPACITY`**).
- [ ] Change **skin** only: **`resolvedShip`** unchanged on **`OilStateUpdate`**; spawned hull uses new **`templateName`** when distinct assets exist.
- [ ] Missing **`templateName`**: **Tanker** fallback; no server throw.
- [ ] **Migration:** profile with **`version < 4`** and **`selectedBoatTypeId`** loads with valid **`shipSkinId`** and migrated levels per **`ShipProfileMigration`**.
- [ ] **Concurrent shipments:** in-flight shipment stats frozen at dispatch (levels copied on shipment row).
- [ ] **Strait events:** barrel loss / price mult use **shipment manifest** and catalog rules; delivered barrels at voyage end match loaded manifest minus strait **barrel** losses (no HP/hull gate).

---

## 11. Open questions / follow-ups

- **Mid-voyage upgrades:** Currently **not** blocked in code; shipment row already snapshots stats at dispatch. Product can later block **`TryUpgrade*`** while **`activeShipmentCount > 0`** if desired.
- Wire **`eventRisk`** from **`ShipStats.Resolve`** into strait occurrence math ([strait SPEC](../strait-waypoint-events/SPEC.md) §11).
- Add **distinct `ReplicatedStorage.Assets` models** per skin when art is ready; update **`ShipSkinCatalog`** `templateName` values.
- **Upgrade HUD** in StarterGui + `OilActionResult` UX (optional sounds/toasts).

---

## 12. Ownership summary

| Slice | Owner |
|-------|--------|
| Resolver, catalogs, migration, persistence | **Gameplay systems engineer** |
| `OilShipmentService` dispatch + spawn + shipment table | **Gameplay systems engineer** |
| Remotes + `OilStateService` / `PlotResourceService` | **Gameplay systems engineer** |
| HUD: upgrade ladders (not yet built) | **UI implementer** |
| SPEC / contract changes | **Roblox architect** (or lead) |

---

## 13. Revision history

| Date | Note |
|------|------|
| 2026-04-10 | Initial SPEC: one functional ship, speed 1–10, capacity 1–25, cosmetic catalog, migration, resolver invariant, file touchpoints. |
| 2026-04-10 | **Implementation snapshot:** §3/§4–§9 aligned with shipped code (`ShipStats`, `ShipSkinCatalog`, `ShipUpgradeConfig`, `ShipProfileMigration`, slim `BoatConfig`, `OilStateService` v4, `OilShipmentService`, `PlotResourceService`, client ship panels, `ParticleFxScale`, remotes). §6 marks upgrade UI as not shipped. §11/§13 updated. |
| 2026-04-22 | **Boat-progression refactor (Steps 1–6).** §3/§4–§11 are now stale at the symbol level; the rename map below is authoritative until the doc is fully rewritten alongside the boat-inventory UI (Step 7+). Renames: `ShipSkinCatalog` → **`BoatCatalog`** (`Skins` → `Boats`, `SkinDef` → `BoatDef`, `GetSkin` → `GetBoat`, `GetRigForSkin` → `GetRigForBoat`); `ShipStats.ResolveForSkin` → **`ResolveForBoat`**, `LevelsForSkin` → **`LevelsForBoat`**; persisted profile fields `shipSkinId` → **`equippedBoatId`**, `ownedShipSkinIds` → **`ownedBoatIds`**; snapshot `resolvedShip` → **`resolvedBoat`**; `OilStateService:SetShipSkinId` → **`:SetEquippedBoatId`**, `:GrantShipSkin` → **`:GrantBoat`**, `:OwnsShipSkin` → **`:OwnsBoat`**, `:SetSkinChangedHandler` → **`:SetEquippedBoatChangedHandler`**; remote `RequestSetShipSkin` → **`RequestSetEquippedBoat`** (do not revive the old name); boat instance attribute `ShipSkinId` → **`BoatId`**; `MonetizationCatalog.GetShipItemBySkinId` → **`GetShipItemByBoatId`**, grant `skinId` → **`boatId`**; `OilShipmentService:GetShipSkinCatalogForClient` → **`:GetBoatCatalogForClient`**; oil snapshot `config.shipSkinCatalog` → **`config.boatCatalog`**; `ShipProfileMigration.MigrationResult.skinId` → **`boatId`**, `SkinIdForLegacyBoatTypeId` → **`BoatIdForLegacyBoatTypeId`**; telemetry `ship_skin_equipped` → **`boat_equipped`** + new **`boat_unlocked`**. **Profile bumped to `version = 10`** with v9 → v10 migration that preserves Robux-purchased boats (cash-purchased boats reset to starter; equipped boat resets to starter unless Robux-owned). New remote **`RequestUnlockBoat`** + handler `OilStateService:TryUnlockBoat` cover the cash / Robux / starter unlock paths (the upgrade ladder + `RequestUpgradeShipSpeed/Capacity` were deleted in Step 4). |
