--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("UpgradeConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))
local Validation = require(script.Parent.Parent:WaitForChild("Utils"):WaitForChild("Validation"))

local UpgradeService = {}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

function UpgradeService:Init(remoteService, playerStateService, rateLimitService)
	self._remoteService = remoteService
	self._playerStateService = playerStateService
	self._rateLimitService = rateLimitService
	self._connections = {}
end

function UpgradeService:Start()
	local requestUpgrade = self._remoteService:GetEvent(RemoteNames.RequestUpgrade)
	table.insert(self._connections, requestUpgrade.OnServerEvent:Connect(function(player, payload)
		self:_handleUpgradeRequest(player, payload)
	end))
end

function UpgradeService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function UpgradeService:GetCatalog()
	local catalog = {}
	for upgradeId, definition in pairs(UpgradeConfig.Definitions) do
		table.insert(catalog, {
			upgradeId = upgradeId,
			displayName = definition.displayName,
			maxLevel = definition.maxLevel,
			baseCost = definition.baseCost,
			costGrowth = definition.costGrowth,
			effectPerLevel = definition.effectPerLevel,
		})
	end
	return catalog
end

function UpgradeService:GetNextCost(upgradeId: string, currentLevel: number): number
	local definition = UpgradeConfig.Definitions[upgradeId]
	if definition == nil then
		return math.huge
	end
	local raw = definition.baseCost * (definition.costGrowth ^ floorPositive(currentLevel))
	return floorPositive(raw)
end

function UpgradeService:_handleUpgradeRequest(player: Player, payload)
	if not self._rateLimitService:Allow(player.UserId, "upgrade", 30) then
		self:_sendActionResult(player, false, ErrorCodes.RateLimited, "Too many upgrade requests.")
		return
	end

	local ok, code, upgradeId = Validation.ValidateUpgradePayload(payload)
	if not ok then
		self:_sendActionResult(player, false, code, "Invalid upgrade request.")
		return
	end

	local definition = UpgradeConfig.Definitions[upgradeId]
	if definition == nil then
		self:_sendActionResult(player, false, ErrorCodes.UpgradeNotFound, "Upgrade not found.")
		return
	end

	local currentLevel = self._playerStateService:GetUpgradeLevel(player.UserId, upgradeId)
	if currentLevel >= definition.maxLevel then
		self:_sendActionResult(player, false, ErrorCodes.UpgradeMaxed, "Upgrade already maxed.")
		return
	end

	local cost = self:GetNextCost(upgradeId, currentLevel)
	local spent = self._playerStateService:TrySpendCash(player.UserId, cost)
	if not spent then
		self:_sendActionResult(player, false, ErrorCodes.NotEnoughCash, "Not enough cash.")
		return
	end

	self._playerStateService:SetUpgradeLevel(player.UserId, upgradeId, currentLevel + 1)
	-- NOTE: this is the legacy generic `UpgradeService` (orphan in current
	-- wiring). The SPEC §6.4 wires per-upgrade events
	-- (`warehouse_upgraded`, `ship_speed_upgraded`, `ship_capacity_upgraded`,
	-- `oil_tank_upgraded`) directly inside `WarehouseService`,
	-- `OilStateService`, and `OilTankService` instead, so we don't fire
	-- the legacy `upgrade_purchased` row here. If this service is ever
	-- re-enabled, route through `Telemetry.Economy(player, "Sink", cost,
	-- "cash", "<per-upgrade reason>", { kind = "upgrade", id = upgradeId })`.

	self:_sendActionResult(player, true, ErrorCodes.Ok, "Upgrade purchased.", {
		upgradeId = upgradeId,
		level = currentLevel + 1,
	})
end

function UpgradeService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.ActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

return UpgradeService
