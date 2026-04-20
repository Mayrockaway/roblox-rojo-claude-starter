--!strict
-- Centralizes `Shared.Remotes` waits so `init.client` stays under Luau's per-chunk local register limit.
-- **Canonical load:** `require(PlayerScripts.Client.ClientRemotes)` — prefer `GetClientRemotes` from nested modules.
-- Use `Remotes.requestStartDrill`, etc. Drills-only refactor: pump / pipe / drum / prospector remotes are gone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local remotesFolder = Shared:WaitForChild("Remotes")
local REMOTE_WAIT_SECS = 60

local function waitRemote(name: string): Instance
	local child = remotesFolder:WaitForChild(name, REMOTE_WAIT_SECS)
	if not child then
		error(
			string.format(
				"[Client] Timed out waiting for Remotes.%s — is Server running RemoteService:Init()?",
				name
			),
			0
		)
	end
	return child
end

export type ClientRemotes = {
	requestOilSnapshot: RemoteFunction,
	requestStartDrill: RemoteEvent,
	drillProgressUpdate: RemoteEvent,
	requestHammerDestroy: RemoteEvent,
	requestRemoveDrill: RemoteEvent,
	requestBuyChunk: RemoteEvent,
	requestPickupBarrel: RemoteEvent,
	requestTeleportToShip: RemoteEvent,
	requestTeleportHome: RemoteEvent,
	requestTeleportToDocks: RemoteEvent,
	requestTeleportToHire: RemoteEvent,
	requestUpgradeWarehouse: RemoteEvent,
	requestSellAllWarehouse: RemoteEvent,
	requestTeleportToWarehouse: RemoteEvent,
	warehouseStateUpdate: RemoteEvent,
	requestWarehouseSnapshot: RemoteFunction,
	biomeRevealEvent: RemoteEvent,
	requestRevealTile: RemoteEvent,
	requestDispatchShipment: RemoteEvent,
	requestSetSelectedBoat: RemoteEvent,
	requestUpgradeShipSpeed: RemoteEvent,
	requestUpgradeShipCapacity: RemoteEvent,
	requestSellWarehouseBarrels: RemoteEvent,
	requestEquipmentShopCatalog: RemoteFunction,
	requestPurchaseEquipment: RemoteEvent,
	equipmentShopStockUpdate: RemoteEvent,
	oilStateUpdate: RemoteEvent,
	oilActionResult: RemoteEvent,
	requestOilmanSell: RemoteEvent,
	requestInstantSell: RemoteEvent,
	requestFtueAcknowledge: RemoteEvent,
	requestFtueSkip: RemoteEvent,
	requestFtueDocksProgress: RemoteEvent,
	ftueStateUpdate: RemoteEvent,
	shipmentVisualEvent: RemoteEvent,
	requestDevSetStraitBracket: RemoteEvent,
	globalStateUpdate: RemoteEvent,
	fighterFlyoverEvent: RemoteEvent,
	requestPirateHireTargets: RemoteFunction,
	requestPirateHireAction: RemoteEvent,
	pirateHireOpenEvent: RemoteEvent,
	pirateHireResultEvent: RemoteEvent,
	pirateHitAlertEvent: RemoteEvent,
	armyGeneralOpenEvent: RemoteEvent,
	requestArmyGeneralAction: RemoteEvent,
	requestArmyGeneralTargets: RemoteFunction,
	armyGeneralResultEvent: RemoteEvent,
	nukeCountdownEvent: RemoteEvent,
	nukeDetonateEvent: RemoteEvent,
	airStrikeEvent: RemoteEvent,
	marketPriceUpdate: RemoteEvent,
	requestSellWarehouseType: RemoteEvent,
	requestMarketSnapshot: RemoteFunction,
}

local Remotes: ClientRemotes = {
	--- `OilSnapshotClient` + HUD panels (`SelectShipPanel`, `ShipManagementPanel`, …) — must stay `RemoteNames.RequestOilSnapshot`.
	requestOilSnapshot = waitRemote(RemoteNames.RequestOilSnapshot) :: RemoteFunction,
	requestStartDrill = waitRemote(RemoteNames.RequestStartDrill) :: RemoteEvent,
	drillProgressUpdate = waitRemote(RemoteNames.DrillProgressUpdate) :: RemoteEvent,
	requestHammerDestroy = waitRemote(RemoteNames.RequestHammerDestroy) :: RemoteEvent,
	requestRemoveDrill = waitRemote(RemoteNames.RequestRemoveDrill) :: RemoteEvent,
	requestBuyChunk = waitRemote(RemoteNames.RequestBuyChunk) :: RemoteEvent,
	requestPickupBarrel = waitRemote(RemoteNames.RequestPickupBarrel) :: RemoteEvent,
	requestTeleportToShip = waitRemote(RemoteNames.RequestTeleportToShip) :: RemoteEvent,
	requestTeleportHome = waitRemote(RemoteNames.RequestTeleportHome) :: RemoteEvent,
	requestTeleportToDocks = waitRemote(RemoteNames.RequestTeleportToDocks) :: RemoteEvent,
	requestTeleportToHire = waitRemote(RemoteNames.RequestTeleportToHire) :: RemoteEvent,
	requestUpgradeWarehouse = waitRemote(RemoteNames.RequestUpgradeWarehouse) :: RemoteEvent,
	requestSellAllWarehouse = waitRemote(RemoteNames.RequestSellAllWarehouse) :: RemoteEvent,
	requestTeleportToWarehouse = waitRemote(RemoteNames.RequestTeleportToWarehouse) :: RemoteEvent,
	warehouseStateUpdate = waitRemote(RemoteNames.WarehouseStateUpdate) :: RemoteEvent,
	requestWarehouseSnapshot = waitRemote(RemoteNames.RequestWarehouseSnapshot) :: RemoteFunction,
	biomeRevealEvent = waitRemote(RemoteNames.BiomeRevealEvent) :: RemoteEvent,
	requestRevealTile = waitRemote(RemoteNames.RequestRevealTile) :: RemoteEvent,
	requestDispatchShipment = waitRemote(RemoteNames.RequestDispatchShipment) :: RemoteEvent,
	requestSetSelectedBoat = waitRemote(RemoteNames.RequestSetSelectedBoat) :: RemoteEvent,
	requestUpgradeShipSpeed = waitRemote(RemoteNames.RequestUpgradeShipSpeed) :: RemoteEvent,
	requestUpgradeShipCapacity = waitRemote(RemoteNames.RequestUpgradeShipCapacity) :: RemoteEvent,
	requestSellWarehouseBarrels = waitRemote(RemoteNames.RequestSellWarehouseBarrels) :: RemoteEvent,
	requestEquipmentShopCatalog = waitRemote(RemoteNames.RequestEquipmentShopCatalog) :: RemoteFunction,
	requestPurchaseEquipment = waitRemote(RemoteNames.RequestPurchaseEquipment) :: RemoteEvent,
	equipmentShopStockUpdate = waitRemote(RemoteNames.EquipmentShopStockUpdate) :: RemoteEvent,
	--- Full oil state replication; `init.client` applies via `OilSnapshotClient.onOilStatePush` (same maps as snapshot).
	oilStateUpdate = waitRemote(RemoteNames.OilStateUpdate) :: RemoteEvent,
	oilActionResult = waitRemote(RemoteNames.OilActionResult) :: RemoteEvent,
	requestOilmanSell = waitRemote(RemoteNames.RequestOilmanSell) :: RemoteEvent,
	requestInstantSell = waitRemote(RemoteNames.RequestInstantSell) :: RemoteEvent,
	requestFtueAcknowledge = waitRemote(RemoteNames.RequestFtueAcknowledge) :: RemoteEvent,
	requestFtueSkip = waitRemote(RemoteNames.RequestFtueSkip) :: RemoteEvent,
	requestFtueDocksProgress = waitRemote(RemoteNames.RequestFtueDocksProgress) :: RemoteEvent,
	ftueStateUpdate = waitRemote(RemoteNames.FtueStateUpdate) :: RemoteEvent,
	shipmentVisualEvent = waitRemote(RemoteNames.ShipmentVisualEvent) :: RemoteEvent,
	requestDevSetStraitBracket = waitRemote(RemoteNames.RequestDevSetStraitBracket) :: RemoteEvent,
	globalStateUpdate = waitRemote(RemoteNames.GlobalStateUpdate) :: RemoteEvent,
	fighterFlyoverEvent = waitRemote(RemoteNames.FighterFlyoverEvent) :: RemoteEvent,
	requestPirateHireTargets = waitRemote(RemoteNames.RequestPirateHireTargets) :: RemoteFunction,
	requestPirateHireAction = waitRemote(RemoteNames.RequestPirateHireAction) :: RemoteEvent,
	pirateHireOpenEvent = waitRemote(RemoteNames.PirateHireOpen) :: RemoteEvent,
	pirateHireResultEvent = waitRemote(RemoteNames.PirateHireResult) :: RemoteEvent,
	pirateHitAlertEvent = waitRemote(RemoteNames.PirateHitAlert) :: RemoteEvent,
	armyGeneralOpenEvent = waitRemote(RemoteNames.ArmyGeneralOpen) :: RemoteEvent,
	requestArmyGeneralAction = waitRemote(RemoteNames.RequestArmyGeneralAction) :: RemoteEvent,
	requestArmyGeneralTargets = waitRemote(RemoteNames.RequestArmyGeneralTargets) :: RemoteFunction,
	armyGeneralResultEvent = waitRemote(RemoteNames.ArmyGeneralResult) :: RemoteEvent,
	nukeCountdownEvent = waitRemote(RemoteNames.NukeCountdownEvent) :: RemoteEvent,
	nukeDetonateEvent = waitRemote(RemoteNames.NukeDetonateEvent) :: RemoteEvent,
	airStrikeEvent = waitRemote(RemoteNames.AirStrikeEvent) :: RemoteEvent,
	marketPriceUpdate = waitRemote(RemoteNames.MarketPriceUpdate) :: RemoteEvent,
	requestSellWarehouseType = waitRemote(RemoteNames.RequestSellWarehouseType) :: RemoteEvent,
	requestMarketSnapshot = waitRemote(RemoteNames.RequestMarketSnapshot) :: RemoteFunction,
}

local devLogEvent = waitRemote(RemoteNames.DevLog) :: RemoteEvent
devLogEvent.OnClientEvent:Connect(function(msg: any)
	print("[SRV] " .. tostring(msg))
end)

return Remotes
