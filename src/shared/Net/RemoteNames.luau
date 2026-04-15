--!strict

local RemoteNames = {
	RequestUpgrade = "RequestUpgrade",
	RequestAdminForceClose = "RequestAdminForceClose",
	GlobalStateUpdate = "GlobalStateUpdate",
	PlayerStateUpdate = "PlayerStateUpdate",
	UpgradeCatalog = "UpgradeCatalog",
	ShipmentVisualEvent = "ShipmentVisualEvent",
	ActionResult = "ActionResult",

	-- oil system v2 (chunked plots, free-placed drills)
	RequestOilSnapshot = "RequestOilSnapshot",
	RequestPlaceDrill = "RequestPlaceDrill",      -- legacy; now routes to pump-place
	RequestStartDrill = "RequestStartDrill",      -- new: begin drilling a tile (consumable drill)
	RequestPlacePump = "RequestPlacePump",        -- new: place a pump on a drilled tile
	DrillProgressUpdate = "DrillProgressUpdate",  -- server -> client: drill started / completed
	RequestProspect = "RequestProspect",          -- new: place prospector on a tile (reveals whole 5x5 chunk)
	ProspectProgressUpdate = "ProspectProgressUpdate", -- server -> client: prospect started / completed
	RequestHammerDestroy = "RequestHammerDestroy", -- new: hammer destroys any placed object, 10% refund
	RequestRemoveDrill = "RequestRemoveDrill",
	RequestBuyChunk = "RequestBuyChunk",
	RequestClearObstacle = "RequestClearObstacle",
	BiomeRevealEvent = "BiomeRevealEvent",
	RequestPlacePipe = "RequestPlacePipe",
	RequestRemovePipe = "RequestRemovePipe",
	PipePlacedFx = "PipePlacedFx", -- server -> all clients: one-shot spatial pipe place SFX
	RequestPlaceDrum = "RequestPlaceDrum",
	RequestRemoveDrum = "RequestRemoveDrum",
	RequestPickupBarrel = "RequestPickupBarrel",
	RequestTeleportToShip = "RequestTeleportToShip",
	RequestTeleportHome = "RequestTeleportHome",
	RequestTeleportToDocks = "RequestTeleportToDocks",
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

	-- Per-plot oil tanks: three tubes (HeavyCrude/LightSweet/PremiumRefined) upgradable 1..10.
	RequestUpgradeOilTank = "RequestUpgradeOilTank",

	-- Dev-only: server-side diagnostic line shipped to all client consoles.
	DevLog = "DevLog",
}

return RemoteNames
