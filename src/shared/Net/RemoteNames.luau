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
	-- Server → all clients: rotating-shop stock map + refreshEndsAt. Fires on
	-- every rotation refresh and on every successful purchase.
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

	-- Per-plot oil tanks: three tubes (Crude/Refined/Premium) upgradable 1..10.
	RequestUpgradeOilTank = "RequestUpgradeOilTank",

	-- Dev-only: server-side diagnostic line shipped to all client consoles.
	DevLog = "DevLog",

	-- FTUE (`FtueService` + `FtueDialogueController`).
	RequestFtueAcknowledge = "RequestFtueAcknowledge",
	RequestFtueSkip = "RequestFtueSkip",
	FtueStateUpdate = "FtueStateUpdate",
	--- Client → server: docks FTUE progression (`DockmanOpened`, `ShipPanelClosed`). See `FtueService`.
	RequestFtueDocksProgress = "RequestFtueDocksProgress",
}

return RemoteNames
