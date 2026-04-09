--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local EconomyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EconomyConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipmentConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipmentConfig"))
local StraitConfig = require(Shared:WaitForChild("Config"):WaitForChild("StraitConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))

local Validation = require(script.Parent.Parent:WaitForChild("Utils"):WaitForChild("Validation"))
local ShipmentEngine = require(script.Parent.Parent:WaitForChild("Domain"):WaitForChild("DeterministicShipmentEngine"))

local ShipmentService = {}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
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

function ShipmentService:Init(
	remoteService,
	straitStateService,
	playerStateService,
	upgradeService,
	rateLimitService,
	idempotencyService,
	telemetryService,
	visualService
)
	self._remoteService = remoteService
	self._straitStateService = straitStateService
	self._playerStateService = playerStateService
	self._upgradeService = upgradeService
	self._rateLimitService = rateLimitService
	self._idempotencyService = idempotencyService
	self._telemetryService = telemetryService
	self._visualService = visualService
	self._running = false
	self._connections = {}
	self._inFlight = {}
end

function ShipmentService:Start()
	if self._running then
		return
	end
	self._running = true

	local requestShipment = self._remoteService:GetEvent(RemoteNames.RequestShipment)
	table.insert(self._connections, requestShipment.OnServerEvent:Connect(function(player, payload)
		self:_handleShipmentRequest(player, payload)
	end))

	local requestLocalSell = self._remoteService:GetEvent(RemoteNames.RequestLocalSell)
	table.insert(self._connections, requestLocalSell.OnServerEvent:Connect(function(player)
		self:_handleLocalSellRequest(player)
	end))

	local requestInitialStateFn = self._remoteService:GetFunction(RemoteNames.RequestInitialState)
	requestInitialStateFn.OnServerInvoke = function(player)
		return {
			global = self._straitStateService:GetSnapshot(),
			player = self._playerStateService:GetSerializableState(player),
			upgradeCatalog = self._upgradeService:GetCatalog(),
		}
	end

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			self:_resumeShipmentsForPlayer(player)
		end)
	end))

	task.defer(function()
		self:_resumePersistedShipments()
	end)
end

function ShipmentService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._inFlight = {}
end

function ShipmentService:_resumePersistedShipments()
	for _, player in ipairs(Players:GetPlayers()) do
		self:_resumeShipmentsForPlayer(player)
	end
end

function ShipmentService:_resumeShipmentsForPlayer(player: Player)
	local saved = self._playerStateService:GetActiveShipments(player.UserId)
	for _, shipment in ipairs(saved) do
		if typeof(shipment) == "table" and typeof(shipment.shipmentId) == "string" then
			self:_trackShipment(shipment)
		end
	end
end

function ShipmentService:_handleShipmentRequest(player: Player, payload)
	if not self._rateLimitService:Allow(player.UserId, "shipment", Constants.RateLimitShipmentRequests) then
		self:_sendActionResult(player, false, ErrorCodes.RateLimited, "Too many shipment requests.")
		return
	end

	local valid, code, normalized = Validation.ValidateShipmentPayload(payload)
	if not valid then
		self:_sendActionResult(player, false, code, "Invalid shipment payload.")
		return
	end

	local activeCount = self._playerStateService:GetActiveShipmentCount(player)
	if activeCount >= Constants.MaxConcurrentShipmentsPerPlayer then
		self:_sendActionResult(player, false, ErrorCodes.TooManyShipments, "Too many active shipments.")
		return
	end

	local cargoByTier, totalLoaded, cargoErrCode, cargoErrMessage = self:_buildCargoSelection(player, normalized.sizeId, normalized.composition)
	if cargoByTier == nil then
		self:_sendActionResult(player, false, cargoErrCode, cargoErrMessage)
		return
	end

	local consumed, consumeReason = self._playerStateService:TryConsumeOil(player, cargoByTier)
	if not consumed then
		local codeToSend = ErrorCodes.NoOil
		if string.find(consumeReason, "Not enough oil", 1, true) ~= nil then
			codeToSend = ErrorCodes.NotEnoughTierOil
		end
		self:_sendActionResult(player, false, codeToSend, consumeReason)
		return
	end

	local snapshot = self._straitStateService:GetSnapshot()
	local modifiers = self._playerStateService:GetShipmentModifiers(player.UserId)
	local sizeConfig = ShipmentConfig.Sizes[normalized.sizeId]

	local numericSeed = Random.new():NextInteger(1, 1_000_000_000)
	local plan = ShipmentEngine.BuildPlan({
		seed = numericSeed,
		baseSuccessChance = snapshot.baseSuccessChance,
		escortBonus = modifiers.escortBonus,
		durabilityBonus = modifiers.durabilityBonus,
		sizePenalty = sizeConfig.sizePenalty,
		minVoyageSeconds = Constants.MinVoyageSeconds,
		maxVoyageSeconds = Constants.MaxVoyageSeconds,
		eventContinuationChance = StraitConfig.States[snapshot.state].eventContinuationChance,
	})

	local now = workspace:GetServerTimeNow()
	local shipmentId = HttpService:GenerateGUID(false)
	local shipment = {
		shipmentId = shipmentId,
		playerUserId = player.UserId,
		sizeId = normalized.sizeId,
		seed = numericSeed,
		dispatchSnapshot = snapshot,
		loadedByTier = deepCopy(cargoByTier),
		totalLoaded = totalLoaded,
		startedAt = now,
		expectedArrivalAt = now + plan.plannedDurationSeconds,
		plan = plan,
		eventCursor = 0,
		enteredClosedState = false,
	}

	self._playerStateService:AddActiveShipment(player.UserId, deepCopy(shipment))
	self:_trackShipment(shipment)

	self:_sendActionResult(player, true, ErrorCodes.Ok, "Shipment dispatched.", {
		shipmentId = shipmentId,
	})
end

function ShipmentService:_trackShipment(shipment)
	local shipmentId = shipment.shipmentId
	if self._inFlight[shipmentId] ~= nil then
		return
	end

	if typeof(shipment.plan) ~= "table" then
		local snapshot = shipment.dispatchSnapshot or self._straitStateService:GetSnapshot()
		local sizeId = shipment.sizeId or "Small"
		local sizeDef = ShipmentConfig.Sizes[sizeId] or ShipmentConfig.Sizes.Small
		shipment.plan = ShipmentEngine.BuildPlan({
			seed = shipment.seed or Random.new():NextInteger(1, 1_000_000_000),
			baseSuccessChance = snapshot.baseSuccessChance or 0.5,
			escortBonus = 0,
			durabilityBonus = 0,
			sizePenalty = sizeDef.sizePenalty,
			minVoyageSeconds = Constants.MinVoyageSeconds,
			maxVoyageSeconds = Constants.MaxVoyageSeconds,
			eventContinuationChance = StraitConfig.States[snapshot.state or "Open"].eventContinuationChance,
		})
	end

	self._inFlight[shipmentId] = true

	local now = workspace:GetServerTimeNow()
	local remaining = math.max(0, (tonumber(shipment.expectedArrivalAt) or now) - now)

	self._visualService:SpawnTanker(shipmentId, shipment.playerUserId, remaining)
	self:_fireShipmentVisual({
		type = "ShipmentStarted",
		shipmentId = shipmentId,
		playerUserId = shipment.playerUserId,
		totalLoaded = shipment.totalLoaded,
		loadedByTier = shipment.loadedByTier,
		dispatchState = shipment.dispatchSnapshot and shipment.dispatchSnapshot.state or "Open",
		durationSeconds = remaining,
	})

	task.spawn(function()
		self:_runShipmentLifecycle(shipment)
	end)
end

function ShipmentService:_runShipmentLifecycle(shipment)
	local shipmentId = shipment.shipmentId
	local now = workspace:GetServerTimeNow()

	for _, eventRecord in ipairs(shipment.plan.events) do
		if eventRecord.index <= (shipment.eventCursor or 0) then
			continue
		end

		local emitAt = shipment.startedAt + eventRecord.atOffsetSeconds
		local delay = emitAt - now
		if delay > 0 then
			task.wait(delay)
		end
		now = workspace:GetServerTimeNow()

		if self._straitStateService:GetCurrentState() == "Closed" then
			shipment.enteredClosedState = true
		end

		shipment.eventCursor = eventRecord.index
		self._playerStateService:UpdateActiveShipment(shipment.playerUserId, shipmentId, function(saved)
			saved.eventCursor = shipment.eventCursor
			saved.enteredClosedState = shipment.enteredClosedState
		end)

		self._visualService:MarkDamage(shipmentId)
		self:_fireShipmentVisual({
			type = "ShipmentEvent",
			shipmentId = shipmentId,
			playerUserId = shipment.playerUserId,
			eventId = eventRecord.eventId,
			damage = eventRecord.damage,
			delaySeconds = eventRecord.delaySeconds,
			hp = eventRecord.hpAfter,
		})
	end

	local waitToArrival = shipment.expectedArrivalAt - workspace:GetServerTimeNow()
	if waitToArrival > 0 then
		task.wait(waitToArrival)
	end

	self:_resolveShipment(shipment)
end

function ShipmentService:_resolveShipment(shipment)
	local shipmentId = shipment.shipmentId
	local settlementKey = "settle:" .. shipmentId
	if not self._idempotencyService:TryMark(settlementKey) then
		self._telemetryService:Track("shipment_settlement_duplicate", {
			shipmentId = shipmentId,
		})
		return
	end

	local currentState = self._straitStateService:GetCurrentState()
	if currentState == "Closed" then
		shipment.enteredClosedState = true
	end

	local hp = shipment.plan.hpAfterEvents
	local destroyed = shipment.plan.destroyedByEvents
	if not destroyed and shipment.enteredClosedState then
		local closeRng = Random.new(shipment.seed + 1337)
		if closeRng:NextNumber() <= ShipmentConfig.ClosedStateExtraDestructionFloor then
			destroyed = true
			hp = 0
		end
	end

	local deliveredByTier = {}
	local deliveredTotal = 0
	local outcome = "Success"
	if destroyed then
		outcome = "Destroyed"
	else
		deliveredByTier, deliveredTotal = ShipmentEngine.BuildDeliveredByTier(shipment.loadedByTier, hp)
		if deliveredTotal < shipment.totalLoaded then
			outcome = "Partial"
		end
	end

	local payout = self:_calculatePayout(deliveredByTier, shipment.dispatchSnapshot.priceMultiplier)
	if payout > 0 then
		self._playerStateService:AddPendingPayoutByUserId(shipment.playerUserId, payout)
		self._playerStateService:AddCashByUserId(shipment.playerUserId, payout)
	end

	self._playerStateService:RemoveActiveShipment(shipment.playerUserId, shipmentId)
	self._visualService:ResolveShipment(shipmentId, destroyed)
	self._inFlight[shipmentId] = nil

	self:_fireShipmentVisual({
		type = "ShipmentResolved",
		shipmentId = shipmentId,
		playerUserId = shipment.playerUserId,
		outcome = outcome,
		payout = payout,
		deliveredByTier = deliveredByTier,
		deliveredTotal = deliveredTotal,
		loadedTotal = shipment.totalLoaded,
	})

	self._telemetryService:Track("shipment_resolved", {
		shipmentId = shipmentId,
		userId = shipment.playerUserId,
		outcome = outcome,
		payout = payout,
	})
end

function ShipmentService:_handleLocalSellRequest(player: Player)
	if not self._rateLimitService:Allow(player.UserId, "local_sell", 20) then
		self:_sendActionResult(player, false, ErrorCodes.RateLimited, "Too many local sell requests.")
		return
	end
	if self._straitStateService:GetCurrentState() ~= "Closed" then
		self:_sendActionResult(player, false, ErrorCodes.StraitNotClosed, "Local sell is only available when strait is Closed.")
		return
	end

	local soldBarrels = self._playerStateService:ConsumeAllOil(player)
	if soldBarrels <= 0 then
		self:_sendActionResult(player, false, ErrorCodes.NoOil, "No oil to sell.")
		return
	end

	local payout = floorPositive(soldBarrels * EconomyConfig.LocalSellBasePerBarrel * EconomyConfig.LocalSellMultiplier)
	self._playerStateService:AddCashByUserId(player.UserId, payout)

	self:_sendActionResult(player, true, ErrorCodes.Ok, "Local sell completed.", {
		soldBarrels = soldBarrels,
		payout = payout,
	})
	self._telemetryService:Track("local_sell", {
		userId = player.UserId,
		soldBarrels = soldBarrels,
		payout = payout,
	})
end

function ShipmentService:_buildCargoSelection(player: Player, sizeId: string, manualComposition)
	local inventory = self._playerStateService:GetOilByTier(player)
	if inventory == nil then
		return nil, 0, ErrorCodes.InvalidPayload, "Missing player inventory."
	end

	local totalOil = self._playerStateService:GetTotalOil(player)
	if totalOil <= 0 then
		return nil, 0, ErrorCodes.NoOil, "No oil available."
	end

	local sizeDef = ShipmentConfig.Sizes[sizeId]
	local cap = sizeDef.maxBarrels
	local maxLoad = totalOil
	if cap ~= nil then
		maxLoad = math.min(totalOil, cap)
	end
	if maxLoad <= 0 then
		return nil, 0, ErrorCodes.CapacityExceeded, "Selected shipment size cannot load any oil."
	end

	local hasManual = typeof(manualComposition) == "table" and next(manualComposition) ~= nil
	if hasManual then
		local out = {}
		local total = 0
		for _, tier in ipairs(QualityConfig.TierOrder) do
			local requested = floorPositive(tonumber(manualComposition[tier]) or 0)
			if requested > 0 then
				local available = floorPositive(tonumber(inventory[tier]) or 0)
				if requested > available then
					return nil, 0, ErrorCodes.NotEnoughTierOil, "Not enough " .. tier .. "."
				end
				out[tier] = requested
				total += requested
			end
		end
		if total <= 0 then
			return nil, 0, ErrorCodes.NoOil, "No barrels selected."
		end
		if total > maxLoad then
			return nil, 0, ErrorCodes.CapacityExceeded, "Selection exceeds shipment capacity."
		end
		return out, total, ErrorCodes.Ok, "OK"
	end

	local remaining = maxLoad
	local out = {}
	local total = 0
	for _, tier in ipairs(QualityConfig.TierOrder) do
		if remaining <= 0 then
			break
		end
		local available = floorPositive(tonumber(inventory[tier]) or 0)
		local take = math.min(available, remaining)
		if take > 0 then
			out[tier] = take
			remaining -= take
			total += take
		end
	end

	if total <= 0 then
		return nil, 0, ErrorCodes.NoOil, "No barrels available."
	end
	return out, total, ErrorCodes.Ok, "OK"
end

function ShipmentService:_calculatePayout(deliveredByTier, dispatchPriceMultiplier: number): number
	local subtotal = 0
	for tier, amount in pairs(deliveredByTier) do
		local tierConfig = QualityConfig.Tiers[tier]
		if tierConfig ~= nil then
			local standardBase = EconomyConfig.LocalSellBasePerBarrel
			local qualityMultiplier = tierConfig.basePricePerBarrel / standardBase
			qualityMultiplier = math.clamp(qualityMultiplier, EconomyConfig.QualityMultiplierMin, EconomyConfig.QualityMultiplierMax)
			local unitPrice = standardBase * qualityMultiplier
			subtotal += floorPositive(amount) * unitPrice
		end
	end

	local stateMultiplier = math.clamp(dispatchPriceMultiplier, EconomyConfig.PriceMultiplierMin, EconomyConfig.PriceMultiplierMax)
	local totalMultiplier = math.clamp(stateMultiplier, 0, EconomyConfig.TotalPayoutMultiplierCap)
	local payout = floorPositive(subtotal * totalMultiplier)
	return payout
end

function ShipmentService:_fireShipmentVisual(payload)
	local event = self._remoteService:GetEvent(RemoteNames.ShipmentVisualEvent)
	event:FireAllClients(payload)
end

function ShipmentService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.ActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

return ShipmentService
