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
	RequestPlacePipe = "RequestPlacePipe",
	RequestRemovePipe = "RequestRemovePipe",
	RequestPlaceDrum = "RequestPlaceDrum",
	RequestRemoveDrum = "RequestRemoveDrum",
	RequestPickupBarrel = "RequestPickupBarrel",
	RequestDispatchShipment = "RequestDispatchShipment",
	OilStateUpdate = "OilStateUpdate",
	OilActionResult = "OilActionResult",
}

return RemoteNames
