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
	WarehouseStateUpdate = "WarehouseStateUpdate",
	RequestWarehouseSnapshot = "RequestWarehouseSnapshot",
	RequestDispatchShipment = "RequestDispatchShipment",
	RequestSetSelectedBoat = "RequestSetSelectedBoat",
	RequestSetShipSkin = "RequestSetShipSkin",
	RequestUpgradeShipSpeed = "RequestUpgradeShipSpeed",
	RequestUpgradeShipCapacity = "RequestUpgradeShipCapacity",
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

	-- Per-plot oil tanks: three tubes (Crude/Refined/Premium) upgradable 1..10.
	RequestUpgradeOilTank = "RequestUpgradeOilTank",

	-- Dev-only: server-side diagnostic line shipped to all client consoles.
	DevLog = "DevLog",

	-- FTUE (`FtueService` + `FtueDialogueController`).
	RequestFtueAcknowledge = "RequestFtueAcknowledge",
	RequestFtueSkip = "RequestFtueSkip",
	FtueStateUpdate = "FtueStateUpdate",
	--- Client → server: docks FTUE progression (`DockmanOpened`, `SelectShipOpened`,
	--- `SelectShipClosed`, `ShipPanelClosed`, `EquipmentShopPanelClosed`). See `FtueService`.
	RequestFtueDocksProgress = "RequestFtueDocksProgress",
}

return RemoteNames
