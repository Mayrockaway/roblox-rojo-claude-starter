--!strict
-- Centralizes `Shared.Remotes` waits so `init.client` stays under Luau's per-chunk local register limit.
-- **Canonical load:** `require(PlayerScripts.Client.ClientRemotes)` — prefer `GetClientRemotes` from nested modules.
-- Use `Remotes.requestStartDrill`, etc. Drills-only refactor: pump / pipe / drum / prospector remotes are gone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
	teleportHomeApplied: RemoteEvent,
	requestTeleportToDocks: RemoteEvent,
	requestTeleportToHire: RemoteEvent,
	requestUpgradeWarehouse: RemoteEvent,
	requestSellAllWarehouse: RemoteEvent,
	requestTeleportToWarehouse: RemoteEvent,
	warehouseGateLocalSfx: RemoteEvent,
	warehouseStateUpdate: RemoteEvent,
	requestWarehouseSnapshot: RemoteFunction,
	biomeRevealEvent: RemoteEvent,
	requestRevealTile: RemoteEvent,
	requestDispatchShipment: RemoteEvent,
	requestSetSelectedBoat: RemoteEvent,
	-- Step 6: boat-equip flow. The planned boat-inventory UI fires this
	-- after `RequestUnlockBoat` succeeds (or directly when re-equipping
	-- an already-owned boat). Server handler:
	-- `PlotResourceService` → `OilStateService:SetEquippedBoatId`.
	-- Distinct from `requestSetSelectedBoat` (legacy ship-picker
	-- payload that also accepts the legacy `boatTypeId` shape via
	-- `ShipProfileMigration`); the two will collapse once the boat-
	-- inventory UI replaces the legacy picker.
	requestSetEquippedBoat: RemoteEvent,
	requestUnlockBoat: RemoteEvent,
	-- `requestUpgradeShipSpeed` / `requestUpgradeShipCapacity` aliases were
	-- deleted by Step 4 of the boat-progression refactor. Speed/capacity
	-- are baked per-boat in `BoatCatalog` (`speedLevel` /
	-- `capacityLevel`); progression happens via `RequestUnlockBoat` +
	-- `RequestSetEquippedBoat`. Removed simultaneously with the matching
	-- `RemoteNames` entries to avoid a `waitRemote(nil)` boot crash.
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
	pirateRaidInteractiveResult: RemoteEvent,
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
	requestPromptRobuxPurchase: RemoteEvent,
	monetizationResult: RemoteEvent,
	requestMonetizationCatalog: RemoteFunction,
	requestCurrencyPackPreview: RemoteFunction,
	gamePassEffectsUpdate: RemoteEvent,
	requestSetAutoShip: RemoteEvent,
	autoShipStateUpdate: RemoteEvent,
	requestClaimDailyDrill: RemoteEvent,
	dailyDrillUpdate: RemoteEvent,
	--- 7-day calendar (`StarterGui.Daily` modal). Separate from `requestClaimDailyDrill`
	--- (the ShopPanel pinned card). See `DailyRewardCalendarService` (server) +
	--- `DailyPanel` (client). Server pushes a snapshot
	--- `{ claimedCount, secondsUntilNext, totalRewards, cooldownSeconds }`
	--- on join and after each successful claim.
	requestClaimDailyReward: RemoteEvent,
	dailyRewardUpdate: RemoteEvent,
	--- Oil Heaven teleport (rebirth sky-island).
	requestTeleportToOilHeaven: RemoteEvent,
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
	teleportHomeApplied = waitRemote(RemoteNames.TeleportHomeApplied) :: RemoteEvent,
	requestTeleportToDocks = waitRemote(RemoteNames.RequestTeleportToDocks) :: RemoteEvent,
	requestTeleportToHire = waitRemote(RemoteNames.RequestTeleportToHire) :: RemoteEvent,
	requestUpgradeWarehouse = waitRemote(RemoteNames.RequestUpgradeWarehouse) :: RemoteEvent,
	requestSellAllWarehouse = waitRemote(RemoteNames.RequestSellAllWarehouse) :: RemoteEvent,
	requestTeleportToWarehouse = waitRemote(RemoteNames.RequestTeleportToWarehouse) :: RemoteEvent,
	warehouseGateLocalSfx = waitRemote(RemoteNames.WarehouseGateLocalSfx) :: RemoteEvent,
	warehouseStateUpdate = waitRemote(RemoteNames.WarehouseStateUpdate) :: RemoteEvent,
	requestWarehouseSnapshot = waitRemote(RemoteNames.RequestWarehouseSnapshot) :: RemoteFunction,
	biomeRevealEvent = waitRemote(RemoteNames.BiomeRevealEvent) :: RemoteEvent,
	requestRevealTile = waitRemote(RemoteNames.RequestRevealTile) :: RemoteEvent,
	requestDispatchShipment = waitRemote(RemoteNames.RequestDispatchShipment) :: RemoteEvent,
	requestSetSelectedBoat = waitRemote(RemoteNames.RequestSetSelectedBoat) :: RemoteEvent,
	requestSetEquippedBoat = waitRemote(RemoteNames.RequestSetEquippedBoat) :: RemoteEvent,
	requestUnlockBoat = waitRemote(RemoteNames.RequestUnlockBoat) :: RemoteEvent,
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
	pirateRaidInteractiveResult = waitRemote(RemoteNames.PirateRaidInteractiveResult) :: RemoteEvent,
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
	requestPromptRobuxPurchase = waitRemote(RemoteNames.RequestPromptRobuxPurchase) :: RemoteEvent,
	monetizationResult = waitRemote(RemoteNames.MonetizationResult) :: RemoteEvent,
	requestMonetizationCatalog = waitRemote(RemoteNames.RequestMonetizationCatalog) :: RemoteFunction,
	requestCurrencyPackPreview = waitRemote(RemoteNames.RequestCurrencyPackPreview) :: RemoteFunction,
	--- Server → one client: `{ effects = { DoubleEarnings = true, ... } }` snapshot
	--- of which `gamePassEffect` ids the player currently owns. Pushed on join
	--- and again whenever a GamePass prompt finishes with `wasPurchased = true`.
	--- Consumed by `EarningsGamepassController` to drive the HUD active-state chrome.
	gamePassEffectsUpdate = waitRemote(RemoteNames.GamePassEffectsUpdate) :: RemoteEvent,
	requestSetAutoShip = waitRemote(RemoteNames.RequestSetAutoShip) :: RemoteEvent,
	autoShipStateUpdate = waitRemote(RemoteNames.AutoShipStateUpdate) :: RemoteEvent,
	requestClaimDailyDrill = waitRemote(RemoteNames.RequestClaimDailyDrill) :: RemoteEvent,
	dailyDrillUpdate = waitRemote(RemoteNames.DailyDrillUpdate) :: RemoteEvent,
	requestClaimDailyReward = waitRemote(RemoteNames.RequestClaimDailyReward) :: RemoteEvent,
	dailyRewardUpdate = waitRemote(RemoteNames.DailyRewardUpdate) :: RemoteEvent,
	requestTeleportToOilHeaven = waitRemote(RemoteNames.RequestTeleportToOilHeaven) :: RemoteEvent,
}

local devLogEvent = waitRemote(RemoteNames.DevLog) :: RemoteEvent
devLogEvent.OnClientEvent:Connect(function(msg: any)
	if RunService:IsStudio() then
		print("[SRV] " .. tostring(msg))
	end
end)

-- Dev-only: `/hideui` toggles ALL UI for marketing footage.
-- Hides every ScreenGui in PlayerGui, every BillboardGui in Workspace,
-- and all ProximityPrompts. Fires again to restore.
do
	local Players = game:GetService("Players")
	local Workspace = game:GetService("Workspace")
	local devHideUIEvent = waitRemote(RemoteNames.DevHideUI) :: RemoteEvent
	local uiHidden = false
	-- Stash original Enabled states so we can restore exactly.
	local stashedScreenGuis: { [ScreenGui]: boolean } = {}
	local stashedBillboards: { [BillboardGui]: boolean } = {}
	local stashedPrompts: { [ProximityPrompt]: boolean } = {}

	devHideUIEvent.OnClientEvent:Connect(function()
		local playerGui = Players.LocalPlayer:FindFirstChildWhichIsA("PlayerGui")
		if not playerGui then return end

		uiHidden = not uiHidden

		if uiHidden then
			-- Hide: stash + disable
			stashedScreenGuis = {}
			stashedBillboards = {}
			stashedPrompts = {}

			for _, sg in ipairs(playerGui:GetChildren()) do
				if sg:IsA("ScreenGui") then
					stashedScreenGuis[sg] = sg.Enabled
					sg.Enabled = false
				end
			end
			for _, bb in ipairs(Workspace:GetDescendants()) do
				if bb:IsA("BillboardGui") then
					stashedBillboards[bb] = bb.Enabled
					bb.Enabled = false
				end
			end
			for _, pp in ipairs(Workspace:GetDescendants()) do
				if pp:IsA("ProximityPrompt") then
					stashedPrompts[pp] = pp.Enabled
					pp.Enabled = false
				end
			end
			print("[Dev] UI hidden for marketing footage. /hideui again to restore.")
		else
			-- Restore
			for sg, wasEnabled in pairs(stashedScreenGuis) do
				if sg and sg.Parent then sg.Enabled = wasEnabled end
			end
			for bb, wasEnabled in pairs(stashedBillboards) do
				if bb and bb.Parent then bb.Enabled = wasEnabled end
			end
			for pp, wasEnabled in pairs(stashedPrompts) do
				if pp and pp.Parent then pp.Enabled = wasEnabled end
			end
			stashedScreenGuis = {}
			stashedBillboards = {}
			stashedPrompts = {}
			print("[Dev] UI restored.")
		end
	end)
end

return Remotes
