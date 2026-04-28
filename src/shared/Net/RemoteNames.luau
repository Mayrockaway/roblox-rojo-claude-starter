--!strict

local RemoteNames = {
	RequestUpgrade = "RequestUpgrade",
	RequestAdminForceClose = "RequestAdminForceClose",
	GlobalStateUpdate = "GlobalStateUpdate",
	PlayerStateUpdate = "PlayerStateUpdate",
	UpgradeCatalog = "UpgradeCatalog",
	ShipmentVisualEvent = "ShipmentVisualEvent",
	ActionResult = "ActionResult",

	-- oil system v2 (chunked plots; consumable drills + auto-place center pump)
	RequestOilSnapshot = "RequestOilSnapshot",
	RequestStartDrill = "RequestStartDrill",      -- player -> server: begin drilling a tile (consumable drill)
	DrillProgressUpdate = "DrillProgressUpdate",  -- server -> client: drill started / completed
	RequestHammerDestroy = "RequestHammerDestroy", -- hammer destroys placed object, 10% refund (rarely used now)
	RequestRemoveDrill = "RequestRemoveDrill",
	RequestBuyChunk = "RequestBuyChunk",
	RequestClearObstacle = "RequestClearObstacle",
	BiomeRevealEvent = "BiomeRevealEvent",
	RequestPickupBarrel = "RequestPickupBarrel",
	RequestTeleportToShip = "RequestTeleportToShip",
	RequestTeleportHome = "RequestTeleportHome",
	--- Server → one client: fired immediately after a server-driven teleport that changes the
	--- character's facing direction. Payload is the **post-teleport** `CFrame` (i.e. the same
	--- one passed to `PivotTo`) so the client can snap its camera behind the character on the
	--- new LookVector. Required because `PivotTo` rotates the character but does NOT re-align
	--- the default follow camera's internal yaw, so the camera ends up looking at the back of
	--- the player's head until they manually drag.
	---
	--- Fired by:
	---   * `OilShipmentService:_handleTeleportHome`         — Home button
	---   * `OilShipmentService:_handleTeleportToDocks`      — BuyButton (Town)
	---   * `WarehouseService:TryTeleportPlayerToWarehouse`  — SellButton (Warehouse)
	---   * `PlotService:_teleportCharacterToOwnedPlot`      — initial spawn / respawn
	---
	--- Listener: `HudTeleportRouter` (`teleportHomeApplied.OnClientEvent` →
	--- `snapCameraBehindCharacter`). Name kept as `TeleportHomeApplied` for wire-compat
	--- with existing client; the role is generic camera-snap, not Home-specific.
	TeleportHomeApplied = "TeleportHomeApplied",
	RequestTeleportToDocks = "RequestTeleportToDocks",
	RequestTeleportToHire = "RequestTeleportToHire",
	RequestUpgradeWarehouse = "RequestUpgradeWarehouse",
	RequestSellAllWarehouse = "RequestSellAllWarehouse",
	RequestTeleportToWarehouse = "RequestTeleportToWarehouse",
	--- Server → **one** client (warehouse owner): play gate open/close SFX
	--- locally only (`Sound` parented to `CurrentCamera`), so dock gate audio
	--- is not spatial / server-replicated to the whole server. Payload:
	--- `{ kind = "open" | "close" }`. See `WarehouseService:_wireWarehouseGateInteractions`.
	WarehouseGateLocalSfx = "WarehouseGateLocalSfx",
	WarehouseStateUpdate = "WarehouseStateUpdate",
	RequestWarehouseSnapshot = "RequestWarehouseSnapshot",
	RequestDispatchShipment = "RequestDispatchShipment",
	RequestSetSelectedBoat = "RequestSetSelectedBoat",
	-- `RequestSetShipSkin` was renamed to `RequestSetEquippedBoat` in
	-- Step 6 of the boat-progression refactor. The wire id changed
	-- intentionally (no string back-compat) so legacy clients with
	-- stale handlers will simply not find the remote — they were never
	-- shipped firing it (the only consumer was the planned boat-
	-- inventory UI). Do NOT revive `RequestSetShipSkin` as a string id.
	RequestSetEquippedBoat = "RequestSetEquippedBoat",
	-- `RequestUpgradeShipSpeed` / `RequestUpgradeShipCapacity` were
	-- deleted by Step 4 of the boat-progression refactor. Per-boat
	-- speed and capacity are now baked into `BoatCatalog` and selected
	-- via the boat-equip flow (`RequestSetEquippedBoat` plus the
	-- `RequestUnlockBoat` below). Re-introducing per-boat upgrades
	-- would require a fresh remote name; do NOT revive the old ids
	-- because some legacy clients may still have stale handlers.
	--- Boat progression refactor (Step 3). Client → server: spend cash
	--- to unlock a boat from `BoatCatalog.Boats[boatId].unlock` when
	--- `unlock.kind == "cash"`. Payload `{ boatId = string }`. Server
	--- replies on `OilActionResult` with action `"UnlockBoat"` and one of:
	---   * `OK`                     — boat granted (added to `ownedBoatIds`)
	---   * `ERR_BAD_PAYLOAD`        — missing / non-string boatId
	---   * `ERR_BAD_BOAT`           — boatId not in catalog or placeholder
	---   * `ERR_NOT_PURCHASABLE`    — entry has no `unlock` block / 0 cost
	---   * `ERR_STARTER_AUTO_GRANTED` — `unlock.kind == "starter"` (already owned)
	---   * `ERR_USE_ROBUX_PROMPT`   — `unlock.kind == "robux"`; use `RequestPromptRobuxPurchase` instead
	---   * `ERR_ALREADY_OWNED`      — already in `ownedBoatIds`
	---   * `ERR_NOT_ENOUGH_CASH`    — cash debit failed
	---   * `ERR_RATE_LIMIT`         — bucket exhausted
	--- The boat is NOT auto-equipped on success — the UI fires a
	--- separate `RequestSetEquippedBoat` after the unlock confirms.
	RequestUnlockBoat = "RequestUnlockBoat",
	MarketPriceUpdate = "MarketPriceUpdate",
	RequestSellWarehouseType = "RequestSellWarehouseType",
	RequestSellWarehouseBarrels = "RequestSellWarehouseBarrels",
	RequestMarketSnapshot = "RequestMarketSnapshot",
	MissileStrikeEvent = "MissileStrikeEvent",
	MineStrikeEvent = "MineStrikeEvent",
	PirateRaidEvent = "PirateRaidEvent",
	OilStateUpdate = "OilStateUpdate",
	OilActionResult = "OilActionResult",
	RequestDevSetStraitBracket = "RequestDevSetStraitBracket",
	FighterFlyoverEvent = "FighterFlyoverEvent",
	RequestPirateHireTargets = "RequestPirateHireTargets",
	RequestPirateHireAction = "RequestPirateHireAction",
	PirateHireOpen = "PirateHireOpen",
	PirateHireResult = "PirateHireResult",
	PirateHitAlert = "PirateHitAlert",
	--- Client → server: interactive pirate raid result. Payload:
	--- `{ raidToken = string, slappedPirateIds = { number } }`.
	--- Server validates token, pirate indices, timing, then applies
	--- proportional barrel loss (un-slapped pirates steal barrels).
	PirateRaidInteractiveResult = "PirateRaidInteractiveResult",

	-- Daily free drill: claim the current cycle's random drill (same for all players).
	-- Server replies on `OilActionResult` with action `"ClaimDailyDrill"`.
	RequestClaimDailyDrill = "RequestClaimDailyDrill",
	-- Server → client: current daily drill state (itemId, cycleStart, claimed).
	-- Fires on join + after claim so client can render the shop card.
	DailyDrillUpdate = "DailyDrillUpdate",

	-- 7-day daily reward calendar (`StarterGui.Daily` modal). Distinct from
	-- `RequestClaimDailyDrill` above (which is the single ShopPanel pinned
	-- card): this drives a 7-slot streak panel where each successful claim
	-- starts a 12h cooldown on the next slot.
	-- Client → server: claim the next available slot (server validates index
	-- + cooldown). Server replies on `OilActionResult` with action
	-- `"ClaimDailyReward"`.
	RequestClaimDailyReward = "RequestClaimDailyReward",
	-- Server → one client: full calendar snapshot:
	--   { claimedCount, secondsUntilNext, totalRewards, cooldownSeconds }
	-- Fires on join + after every claim. `claimedCount` is 0..totalRewards;
	-- `secondsUntilNext` is `0` when the next slot is claimable right now
	-- (or `0` when `claimedCount == totalRewards`, the all-claimed state).
	DailyRewardUpdate = "DailyRewardUpdate",

	-- Mobile drill hint: one-time dismissal (persisted so it never shows again).
	RequestDismissMobileDrillHint = "RequestDismissMobileDrillHint",

	-- Oil Heaven (rebirth sky plot). Client → server: teleport up to the
	-- player's personal sky island at Y=3000 above their main plot.
	-- Server generates the plot on first visit (`OilHeavenPlotService`).
	RequestTeleportToOilHeaven = "RequestTeleportToOilHeaven",

	-- One-shot equipment shop (Tools cloned into `Player.Backpack`; cash via `OilStateService`).
	RequestPurchaseEquipment = "RequestPurchaseEquipment",
	RequestEquipmentShopCatalog = "RequestEquipmentShopCatalog",
	-- Server → all clients: rotating-shop stock map + `refreshEndsAt`. Fires on
	-- every rotation refresh AND on every successful purchase. Payload includes
	-- `reason = "rotation"` only on the periodic stock refresh — purchases pass
	-- `reason = nil`. `ShopRefreshNotification.luau` shows a gold "shop
	-- refreshed" hint on the shipment progress HUD only when `reason` is
	-- `"rotation"` (not on per-purchase restocks).
	EquipmentShopStockUpdate = "EquipmentShopStockUpdate",

	-- Oilman NPC (`Workspace.Oilman.RodgerDodger`): batch-sells local plot
	-- oil (`oilByTier`) at OilmanConfig prices. Client sends a per-tier
	-- quantity map + requestId; atomic commit.
	RequestOilmanSell = "RequestOilmanSell",

	-- ShipOilPanel "Instant Sell" sub-modal (DeliveryMan): batch-sells local
	-- plot oil (`oilByTier`) at fixed `InstantSellConfig` prices. Same payload
	-- shape as `RequestOilmanSell` ({ quantities = {...}, requestId = "..." });
	-- atomic commit; result on `OilActionResult` with code `Ok` or
	-- `ERR_NO_OIL` / `ERR_INVALID_PAYLOAD`.
	RequestInstantSell = "RequestInstantSell",

	-- Army General NPC: nuke + airstrike
	ArmyGeneralOpen = "ArmyGeneralOpen",
	RequestArmyGeneralAction = "RequestArmyGeneralAction",
	RequestArmyGeneralTargets = "RequestArmyGeneralTargets",
	ArmyGeneralResult = "ArmyGeneralResult",
	NukeCountdownEvent = "NukeCountdownEvent",
	NukeDetonateEvent = "NukeDetonateEvent",
	AirStrikeEvent = "AirStrikeEvent",

	-- Drill vein reveal (player presses E on DrillComplete model)
	RequestRevealTile = "RequestRevealTile",

	-- Robux monetization (`MonetizationCatalog` + `MonetizationService`).
	-- Client → server: "open the Roblox prompt for catalog item id X". Server
	-- looks up the item, validates `productId`, and calls
	-- `MarketplaceService:PromptProductPurchase` (or `PromptGamePassPurchase`).
	RequestPromptRobuxPurchase = "RequestPromptRobuxPurchase",
	-- Server → one client: receipt outcome ({ ok, code, itemId, ... }) so the
	-- ship-select / shop UI can show "purchased!" / "cancelled" toasts
	-- without parsing `OilActionResult`.
	MonetizationResult = "MonetizationResult",
	-- Server → one client: full `MonetizationCatalog.ListForClient()` snapshot.
	-- RemoteFunction so clients can fetch on-demand (panel open) instead of
	-- waiting for a push. Keeps the wire small and snapshot-shaped like
	-- `RequestEquipmentShopCatalog`.
	RequestMonetizationCatalog = "RequestMonetizationCatalog",
	--- Server → invoking client: roll-up dynamic cash-pack sizes from
	--- `SessionEconomics` + current cash hint (`OilStateService:GetEconomicsCashPackPreview`).
	RequestCurrencyPackPreview = "RequestCurrencyPackPreview",
	-- Server → one client: which `gamePassEffect` ids (e.g. "DoubleEarnings")
	-- the player currently owns, as `{ effects = { DoubleEarnings = true, ... } }`.
	-- Pushed on join (after `MarketplaceService:UserOwnsGamePassAsync` resolves)
	-- and again whenever `MarketplaceService.PromptGamePassPurchaseFinished` fires
	-- with `wasPurchased = true` so the HUD active-state chrome (rainbow stroke
	-- around `EarningsGamepass` etc.) lights up immediately after purchase
	-- without requiring a rejoin. Server `MonetizationService:HasGamePassEffect`
	-- stays the source of truth for any cash-multiplier checks; this is
	-- display-only.
	GamePassEffectsUpdate = "GamePassEffectsUpdate",

	-- AutoShip: automatic oil dispatch loop (GamePass).
	RequestSetAutoShip = "RequestSetAutoShip",
	AutoShipStateUpdate = "AutoShipStateUpdate",

	-- Per-plot oil tanks: three tubes (Crude/Refined/Premium) upgradable 1..10.
	RequestUpgradeOilTank = "RequestUpgradeOilTank",

	-- Dev-only: server-side diagnostic line shipped to all client consoles.
	DevLog = "DevLog",

	-- Dev-only: toggle all UI visibility for marketing footage capture.
	DevHideUI = "DevHideUI",

	-- Global events (`GlobalEventService` + `GlobalEventConfig` + client
	-- `GlobalEventBanner`). Server → all clients: full snapshot of currently
	-- active server-wide events. Fires on activate, on expire, on every
	-- new player joining (so they don't sit on a stale "no events" state),
	-- and on the periodic safety-net push from the service.
	--
	-- Payload shape (see `GlobalEventService:_buildSnapshotPayload`):
	--   {
	--     active = {
	--       { id, displayName, subtitle, bannerKind, expiresAt, helpText? },
	--       ...
	--     },
	--     serverNow = number, -- workspace:GetServerTimeNow() at broadcast
	--   }
	-- Client banner uses `expiresAt - serverNow` as the initial countdown
	-- so client/server clock skew doesn't cause the timer to drift past 0.
	GlobalEventStateUpdate = "GlobalEventStateUpdate",

	-- FTUE (`FtueService` + `FtueDialogueController`).
	RequestFtueAcknowledge = "RequestFtueAcknowledge",
	RequestFtueSkip = "RequestFtueSkip",
	FtueStateUpdate = "FtueStateUpdate",
	--- Client → server: docks FTUE progression (`DockmanOpened`, `SelectShipOpened`,
	--- `SelectShipClosed`, `ShipPanelClosed`, `EquipmentShopPanelClosed`). See `FtueService`.
	RequestFtueDocksProgress = "RequestFtueDocksProgress",
}

return RemoteNames
