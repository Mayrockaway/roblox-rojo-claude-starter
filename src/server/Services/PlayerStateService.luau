--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local UpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("UpgradeConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local PlayerStateService = {}

local function makeEmptyOilByTier()
	return {
		Crude = 0,
		Refined = 0,
		Premium = 0,
	}
end

local function deepCopy(source)
	if typeof(source) ~= "table" then
		return source
	end
	local out = {}
	for k, v in pairs(source) do
		out[k] = deepCopy(v)
	end
	return out
end

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

function PlayerStateService:Init(remoteService, persistenceService)
	self._remoteService = remoteService
	self._persistenceService = persistenceService
	self._rng = Random.new()
	self._statesByUserId = {}
	self._playersByUserId = {}
	self._running = false
	self._connections = {}
end

function PlayerStateService:Start()
	if self._running then
		return
	end
	self._running = true

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end

	task.spawn(function()
		while self._running do
			task.wait(Constants.ProductionTickSeconds)
			self:_runProductionTick(Constants.ProductionTickSeconds)
		end
	end)
end

function PlayerStateService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	for userId, state in pairs(self._statesByUserId) do
		self:_saveState(userId, state)
	end
end

function PlayerStateService:GetSerializableState(player: Player)
	return self:GetSerializableStateByUserId(player.UserId)
end

function PlayerStateService:GetSerializableStateByUserId(userId: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return nil
	end

	return {
		cash = state.cash,
		capacity = self:_computeCapacity(state),
		totalOil = state.totalOil,
		oilByTier = deepCopy(state.oilByTier),
		activeShipmentCount = state.activeShipmentCount,
		upgrades = deepCopy(state.upgrades),
		pendingPayout = state.pendingPayout,
	}
end

function PlayerStateService:GetOilByTier(player: Player)
	local state = self._statesByUserId[player.UserId]
	if state == nil then
		return nil
	end
	return state.oilByTier
end

function PlayerStateService:GetTotalOil(player: Player): number
	local state = self._statesByUserId[player.UserId]
	if state == nil then
		return 0
	end
	return state.totalOil
end

function PlayerStateService:GetActiveShipmentCount(player: Player): number
	local state = self._statesByUserId[player.UserId]
	if state == nil then
		return 0
	end
	return state.activeShipmentCount
end

function PlayerStateService:GetStateByUserId(userId: number)
	return self._statesByUserId[userId]
end

function PlayerStateService:AddActiveShipment(userId: number, shipmentRecord)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	state.activeShipmentCount += 1
	state.activeShipments[shipmentRecord.shipmentId] = shipmentRecord
	self:_dirtyState(userId)
	self:_pushState(userId)
end

function PlayerStateService:GetActiveShipments(userId: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return {}
	end
	local out = {}
	for _, shipment in pairs(state.activeShipments) do
		table.insert(out, deepCopy(shipment))
	end
	return out
end

function PlayerStateService:UpdateActiveShipment(userId: number, shipmentId: string, mutator)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	local shipment = state.activeShipments[shipmentId]
	if shipment == nil then
		return
	end
	mutator(shipment)
	self:_dirtyState(userId)
end

function PlayerStateService:RemoveActiveShipment(userId: number, shipmentId: string)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	if state.activeShipments[shipmentId] ~= nil then
		state.activeShipments[shipmentId] = nil
		state.activeShipmentCount = math.max(0, state.activeShipmentCount - 1)
		self:_dirtyState(userId)
		self:_pushState(userId)
	end
end

function PlayerStateService:GetPlayerByUserId(userId: number): Player?
	return self._playersByUserId[userId]
end

function PlayerStateService:TryConsumeOil(player: Player, byTier): (boolean, string)
	local state = self._statesByUserId[player.UserId]
	if state == nil then
		return false, "Player state unavailable."
	end
	if state.locked then
		return false, "Player state busy."
	end

	state.locked = true
	local ok, reason = self:_tryConsumeOilUnsafe(state, byTier)
	state.locked = false
	if ok then
		self:_dirtyState(player.UserId)
		self:_pushState(player.UserId)
	end
	return ok, reason
end

function PlayerStateService:ConsumeAllOil(player: Player): number
	local state = self._statesByUserId[player.UserId]
	if state == nil then
		return 0
	end
	local total = state.totalOil
	state.oilByTier = makeEmptyOilByTier()
	state.totalOil = 0
	self:_dirtyState(player.UserId)
	self:_pushState(player.UserId)
	return total
end

function PlayerStateService:AddCashByUserId(userId: number, amount: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	state.cash += floorPositive(amount)
	state.pendingPayout = math.max(0, state.pendingPayout - floorPositive(amount))
	self:_dirtyState(userId)
	self:_pushState(userId)
end

function PlayerStateService:AddPendingPayoutByUserId(userId: number, amount: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	state.pendingPayout += floorPositive(amount)
	self:_dirtyState(userId)
	self:_pushState(userId)
end

function PlayerStateService:TrySpendCash(userId: number, amount: number): boolean
	local state = self._statesByUserId[userId]
	if state == nil then
		return false
	end
	local spend = floorPositive(amount)
	if state.cash < spend then
		return false
	end
	state.cash -= spend
	self:_dirtyState(userId)
	self:_pushState(userId)
	return true
end

function PlayerStateService:GetUpgradeLevel(userId: number, upgradeId: string): number
	local state = self._statesByUserId[userId]
	if state == nil then
		return 0
	end
	return floorPositive(state.upgrades[upgradeId] or 0)
end

function PlayerStateService:SetUpgradeLevel(userId: number, upgradeId: string, level: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	state.upgrades[upgradeId] = floorPositive(level)
	self:_dirtyState(userId)
	self:_pushState(userId)
end

function PlayerStateService:GetShipmentModifiers(userId: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return {
			durabilityBonus = 0,
			escortBonus = 0,
		}
	end

	local durabilityDef = UpgradeConfig.Definitions.TankerDurability
	local escortDef = UpgradeConfig.Definitions.EscortBonus
	local durabilityLevel = floorPositive(state.upgrades.TankerDurability or 0)
	local escortLevel = floorPositive(state.upgrades.EscortBonus or 0)

	return {
		durabilityBonus = durabilityLevel * durabilityDef.effectPerLevel,
		escortBonus = escortLevel * escortDef.effectPerLevel,
	}
end

function PlayerStateService:_tryConsumeOilUnsafe(state, byTier): (boolean, string)
	local totalToConsume = 0
	for tier, amount in pairs(byTier) do
		local quantity = floorPositive(tonumber(amount) or 0)
		if quantity > 0 then
			if (state.oilByTier[tier] or 0) < quantity then
				return false, "Not enough oil in tier " .. tostring(tier)
			end
			totalToConsume += quantity
		end
	end

	if totalToConsume <= 0 then
		return false, "No oil selected."
	end

	for tier, amount in pairs(byTier) do
		local quantity = floorPositive(tonumber(amount) or 0)
		if quantity > 0 then
			state.oilByTier[tier] -= quantity
		end
	end

	state.totalOil = math.max(0, state.totalOil - totalToConsume)
	return true, "OK"
end

function PlayerStateService:_onPlayerAdded(player: Player)
	local existing = self._statesByUserId[player.UserId]
	if existing ~= nil then
		existing.isOnline = true
		self._playersByUserId[player.UserId] = player
		self:_pushState(player.UserId)
		return
	end

	local profile = self._persistenceService:LoadProfile(player.UserId)
	local oilByTier = makeEmptyOilByTier()
	for tier, _ in pairs(oilByTier) do
		if typeof(profile.oilByTier[tier]) == "number" then
			oilByTier[tier] = floorPositive(profile.oilByTier[tier])
		end
	end

	local totalOil = 0
	for _, amount in pairs(oilByTier) do
		totalOil += amount
	end

	local state = {
		userId = player.UserId,
		cash = floorPositive(profile.cash or 0),
		baseCapacity = math.max(1, floorPositive(profile.capacity or Constants.DefaultStorageCapacity)),
		oilByTier = oilByTier,
		totalOil = totalOil,
		activeShipmentCount = 0,
		activeShipments = {},
		upgrades = deepCopy(profile.upgrades or UpgradeConfig.DefaultLevels),
		pendingPayout = floorPositive(profile.pendingPayout or 0),
		dirty = false,
		locked = false,
		isOnline = true,
	}

	if typeof(profile.activeShipments) == "table" then
		for _, shipment in ipairs(profile.activeShipments) do
			if typeof(shipment) == "table" and typeof(shipment.shipmentId) == "string" then
				state.activeShipments[shipment.shipmentId] = shipment
				state.activeShipmentCount += 1
			end
		end
	end

	self._statesByUserId[player.UserId] = state
	self._playersByUserId[player.UserId] = player
	self:_pushState(player.UserId)
	-- `player_state_loaded` was a placeholder log; `Shared.Telemetry`
	-- already fires `session_start` for every join (SPEC §6.1) which
	-- covers the same "player joined and state is live" signal.
end

function PlayerStateService:_onPlayerRemoving(player: Player)
	local userId = player.UserId
	local state = self._statesByUserId[userId]
	if state ~= nil then
		state.isOnline = false
		self:_saveState(userId, state)
	end
	self._playersByUserId[userId] = nil
end

function PlayerStateService:_runProductionTick(deltaSeconds: number)
	for userId, state in pairs(self._statesByUserId) do
		if not state.isOnline then
			continue
		end
		local capacity = self:_computeCapacity(state)
		if state.totalOil >= capacity then
			continue
		end

		local produced = self:_computeProductionPerTick(state, deltaSeconds)
		local available = capacity - state.totalOil
		local granted = math.min(available, produced)
		if granted <= 0 then
			continue
		end

		for _ = 1, granted do
			local tier = self:_rollQualityTier(state)
			state.oilByTier[tier] += 1
			state.totalOil += 1
		end
		self:_dirtyState(userId)
		self:_pushState(userId)
	end
end

function PlayerStateService:_computeProductionPerTick(state, deltaSeconds: number): number
	local pumpLevel = floorPositive(state.upgrades.PumpRate or 0)
	local pumpDef = UpgradeConfig.Definitions.PumpRate
	local multiplier = 1 + (pumpLevel * pumpDef.effectPerLevel)
	local produced = Constants.DefaultBarrelsPerSecond * multiplier * deltaSeconds
	return math.max(0, math.floor(produced))
end

function PlayerStateService:_computeCapacity(state): number
	local storageLevel = floorPositive(state.upgrades.StorageCapacity or 0)
	local storageDef = UpgradeConfig.Definitions.StorageCapacity
	local bonus = storageLevel * storageDef.effectPerLevel
	return math.max(1, floorPositive(state.baseCapacity + bonus))
end

function PlayerStateService:_rollQualityTier(state): string
	local qualityBiasLevel = floorPositive(state.upgrades.QualityBias or 0)
	local biasDef = UpgradeConfig.Definitions.QualityBias
	local biasScalar = qualityBiasLevel * biasDef.effectPerLevel

	local rank = {
		Crude = -2,
		Refined = 1,
		Premium = 2,
	}

	local totalWeight = 0
	local adjusted = {}
	for _, tier in ipairs(QualityConfig.TierOrder) do
		local baseWeight = QualityConfig.Tiers[tier].productionWeight
		local tierRank = rank[tier] or 0
		local multiplier = math.clamp(1 + (tierRank * biasScalar * 0.4), 0.1, 5)
		local weighted = baseWeight * multiplier
		adjusted[tier] = weighted
		totalWeight += weighted
	end

	local roll = self._rng:NextNumber(0, totalWeight)
	local cursor = 0
	for _, tier in ipairs(QualityConfig.TierOrder) do
		cursor += adjusted[tier]
		if roll <= cursor then
			return tier
		end
	end
	return "Crude"
end

function PlayerStateService:_dirtyState(userId: number)
	local state = self._statesByUserId[userId]
	if state == nil then
		return
	end
	state.dirty = true
	self:_saveState(userId, state)
end

function PlayerStateService:_saveState(userId: number, state)
	if state == nil then
		return
	end
	local activeShipments = {}
	for _, shipment in pairs(state.activeShipments) do
		table.insert(activeShipments, shipment)
	end

	self._persistenceService:SetProfile(userId, {
		cash = state.cash,
		capacity = state.baseCapacity,
		oilByTier = deepCopy(state.oilByTier),
		upgrades = deepCopy(state.upgrades),
		activeShipments = activeShipments,
		pendingPayout = state.pendingPayout,
	})
	state.dirty = false
end

function PlayerStateService:_pushState(userId: number)
	local player = self._playersByUserId[userId]
	if player == nil then
		return
	end
	local updateEvent = self._remoteService:GetEvent(RemoteNames.PlayerStateUpdate)
	updateEvent:FireClient(player, self:GetSerializableStateByUserId(userId))
end

return PlayerStateService
