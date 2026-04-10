--!strict

local RemoteNames = {
	-- legacy / previously scaffolded
	RequestShipment = "RequestShipment",
	RequestInitialState = "RequestInitialState",
	RequestUpgrade = "RequestUpgrade",
	RequestLocalSell = "RequestLocalSell",
	RequestAdminForceClose = "RequestAdminForceClose",
	GlobalStateUpdate = "GlobalStateUpdate",
	PlayerStateUpdate = "PlayerStateUpdate",
	UpgradeCatalog = "UpgradeCatalog",
	ShipmentVisualEvent = "ShipmentVisualEvent",
	ActionResult = "ActionResult",

	-- oil system v2 (chunked plots, free-placed drills)
	RequestOilSnapshot = "RequestOilSnapshot",
	RequestPlaceDrill = "RequestPlaceDrill",
	RequestRemoveDrill = "RequestRemoveDrill",
	RequestBuyChunk = "RequestBuyChunk",
	RequestClearObstacle = "RequestClearObstacle",
	BiomeRevealEvent = "BiomeRevealEvent",
	RequestPlacePipe = "RequestPlacePipe",
	RequestRemovePipe = "RequestRemovePipe",
	RequestPlaceDrum = "RequestPlaceDrum",
	RequestRemoveDrum = "RequestRemoveDrum",
	RequestPickupBarrel = "RequestPickupBarrel",
	RequestTeleportToShip = "RequestTeleportToShip",
	RequestTeleportHome = "RequestTeleportHome",
	RequestUpgradeWarehouse = "RequestUpgradeWarehouse",
	RequestSellAllWarehouse = "RequestSellAllWarehouse",
	RequestTeleportToWarehouse = "RequestTeleportToWarehouse",
	WarehouseStateUpdate = "WarehouseStateUpdate",
	RequestDispatchShipment = "RequestDispatchShipment",
	OilStateUpdate = "OilStateUpdate",
	OilActionResult = "OilActionResult",
	RequestDevSetStraitBracket = "RequestDevSetStraitBracket",
}

return RemoteNames
