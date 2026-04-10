--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatConfig = require(Shared:WaitForChild("Config"):WaitForChild("BoatConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilShipmentService = {}

local TIER_ORDER = {
	"PremiumRefined",
	"LightSweet",
	"StandardCrude",
	"HeavyCrude",
}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

local function clamp01(value: number): number
	return math.max(0, math.min(1, value))
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			return child
		end
	end
	return nil
end

local function anchorAll(instance: Instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = true
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			child.Anchored = true
			child.CanCollide = false
			child.CanTouch = false
			child.CanQuery = true
		end
	end
end

local function setInstanceCFrame(instance: Instance, cf: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cf)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cf
	end
end

function OilShipmentService:Init(remoteService, oilStateService, plotService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._connections = {}

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	self._boatTemplate = assetsFolder and assetsFolder:FindFirstChild("Tanker") or nil
end

function OilShipmentService:Start()
	local requestDispatch = self._remoteService:GetEvent(RemoteNames.RequestDispatchShipment)
	table.insert(self._connections, requestDispatch.OnServerEvent:Connect(function(player, payload)
		self:_handleDispatch(player, payload)
	end))
end

function OilShipmentService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function OilShipmentService:GetBoatCatalogForClient()
	local list = {}
	for boatTypeId, def in pairs(BoatConfig.Boats) do
		table.insert(list, {
			boatTypeId = boatTypeId,
			displayName = def.displayName,
			dispatchFee = def.dispatchFee,
			capacity = def.capacity,
			hullHp = def.hullHp,
			travelSeconds = def.travelSeconds,
		})
	end
	table.sort(list, function(a, b)
		return a.capacity < b.capacity
	end)
	return list
end

function OilShipmentService:_handleDispatch(player: Player, payload)
	if typeof(payload) ~= "table" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Bad dispatch payload.")
		return
	end

	local boatTypeId = payload.boatTypeId
	local manifest = payload.manifest
	if typeof(boatTypeId) ~= "string" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Missing boatTypeId.")
		return
	end
	if typeof(manifest) ~= "table" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Missing manifest.")
		return
	end

	local boatDef = BoatConfig.Boats[boatTypeId]
	if not boatDef then
		self:_sendActionResult(player, false, "ERR_BAD_BOAT", "Unknown boat type.")
		return
	end

	local state = self._oilStateService:GetState(player.UserId)
	if not state then
		self:_sendActionResult(player, false, "ERR_NO_STATE", "State unavailable.")
		return
	end

	if (state.activeShipmentCount or 0) >= BoatConfig.MaxConcurrentShipmentsPerPlayer then
		self:_sendActionResult(player, false, "ERR_TOO_MANY_SHIPMENTS", "Too many active shipments.")
		return
	end

	local okManifest, codeManifest, messageManifest, totalRequested = self._oilStateService:CanConsumeManifest(player.UserId, manifest)
	if not okManifest then
		self:_sendActionResult(player, false, codeManifest, messageManifest)
		return
	end
	if totalRequested > boatDef.capacity then
		self:_sendActionResult(player, false, "ERR_BOAT_CAPACITY", "Boat capacity exceeded.")
		return
	end

	local normalizedManifest = {}
	for _, tier in ipairs(TIER_ORDER) do
		normalizedManifest[tier] = floorPositive(tonumber(manifest[tier]) or 0)
	end

	if not self._oilStateService:TrySpendCash(player.UserId, boatDef.dispatchFee) then
		self:_sendActionResult(player, false, "ERR_NOT_ENOUGH_CASH", "Not enough cash for dispatch fee.")
		return
	end

	if not self._oilStateService:ConsumeManifest(player.UserId, normalizedManifest) then
		self:_sendActionResult(player, false, "ERR_MANIFEST_CONSUME", "Failed to load selected barrels.")
		return
	end

	self._oilStateService:IncrementShipmentCount(player.UserId)
	self._oilStateService:PushState(player.UserId)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = player.UserId,
		boatTypeId = boatTypeId,
		manifest = normalizedManifest,
		totalLoaded = totalRequested,
		dispatchFee = boatDef.dispatchFee,
		travelSeconds = boatDef.travelSeconds,
		hullMax = boatDef.hullHp,
		hullCurrent = boatDef.hullHp,
		eventRisk = boatDef.eventRisk,
		priceMultiplier = BoatConfig.DefaultPriceMultiplier,
	}

	self:_sendActionResult(player, true, "OK", "Shipment dispatched.", {
		shipmentId = shipment.shipmentId,
		boatTypeId = boatTypeId,
		totalLoaded = totalRequested,
	})

	task.spawn(function()
		self:_runShipment(shipment)
	end)
end

function OilShipmentService:_runShipment(shipment)
	local ownerUserId = shipment.ownerUserId
	local plot = self._plotService:GetOwnedPlot(ownerUserId)
	if not plot then
		self:_finishShipmentWithoutPayout(shipment, "Owner plot unavailable.")
		return
	end

	local boat = self:_spawnBoat(plot)
	local spawnPart = plot:FindFirstChild("BoatSpawn")
	local exitPart = plot:FindFirstChild("BoatExit")
	local loadPoint = plot:FindFirstChild("ShipLoadPoint")
	local stackRoot = plot:FindFirstChild("BarrelStackRoot")

	local startCf = if spawnPart and spawnPart:IsA("BasePart") then spawnPart.CFrame else CFrame.new(0, 5, 0)
	local endCf = if exitPart and exitPart:IsA("BasePart") then exitPart.CFrame else (startCf * CFrame.new(0, 0, -140))
	local directionTarget = endCf.Position
	setInstanceCFrame(boat, CFrame.lookAt(startCf.Position, directionTarget))

	self:_emitShipmentEvent("ShipmentStarted", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boatTypeId = shipment.boatTypeId,
		loaded = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
	})

	self:_playLoadAnimation(stackRoot, loadPoint, shipment.totalLoaded)
	task.wait(1.2)

	local eventTimes = self:_buildEventTimes(shipment.eventRisk, shipment.travelSeconds)
	local startTime = workspace:GetServerTimeNow()
	local eventCursor = 1

	while true do
		local elapsed = workspace:GetServerTimeNow() - startTime
		local alpha = clamp01(elapsed / shipment.travelSeconds)
		local currentPos = startCf.Position:Lerp(endCf.Position, alpha)
		local currentCf = CFrame.lookAt(currentPos, directionTarget)
		setInstanceCFrame(boat, currentCf)

		if eventCursor <= #eventTimes and elapsed >= eventTimes[eventCursor] then
			local damagePercent = self:_rollDamagePercent(shipment.eventRisk)
			local damage = floorPositive(shipment.hullMax * damagePercent)
			shipment.hullCurrent = math.max(0, shipment.hullCurrent - damage)

			self:_emitShipmentEvent("ShipmentEvent", {
				ownerUserId = ownerUserId,
				shipmentId = shipment.shipmentId,
				damage = damage,
				hullCurrent = shipment.hullCurrent,
				hullMax = shipment.hullMax,
			})
			eventCursor += 1
		end

		if alpha >= 1 then
			break
		end
		task.wait(0.12)
	end

	local hpPercent = clamp01(shipment.hullCurrent / shipment.hullMax)
	local deliveredManifest = {}
	local totalDelivered = 0
	local payoutBase = 0

	for _, tier in ipairs(TIER_ORDER) do
		local loadedTier = shipment.manifest[tier] or 0
		local deliveredTier = floorPositive(loadedTier * hpPercent)
		deliveredManifest[tier] = deliveredTier
		totalDelivered += deliveredTier

		local tierInfo = QualityConfig.Tiers[tier]
		if tierInfo then
			payoutBase += deliveredTier * tierInfo.basePricePerBarrel
		end
	end

	local payout = floorPositive(payoutBase * shipment.priceMultiplier)
	if payout > 0 then
		self._oilStateService:AddCash(ownerUserId, payout)
	end
	self._oilStateService:DecrementShipmentCount(ownerUserId)
	self._oilStateService:PushState(ownerUserId)

	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boatTypeId = shipment.boatTypeId,
		hpPercent = hpPercent,
		loaded = shipment.totalLoaded,
		delivered = totalDelivered,
		lost = shipment.totalLoaded - totalDelivered,
		payout = payout,
		dispatchFee = shipment.dispatchFee,
		deliveredByTier = deliveredManifest,
	})

	task.delay(1.5, function()
		if boat and boat.Parent then
			boat:Destroy()
		end
	end)
end

function OilShipmentService:_finishShipmentWithoutPayout(shipment, reason: string)
	self._oilStateService:DecrementShipmentCount(shipment.ownerUserId)
	self._oilStateService:PushState(shipment.ownerUserId)
	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = shipment.ownerUserId,
		shipmentId = shipment.shipmentId,
		boatTypeId = shipment.boatTypeId,
		hpPercent = 0,
		loaded = shipment.totalLoaded,
		delivered = 0,
		lost = shipment.totalLoaded,
		payout = 0,
		dispatchFee = shipment.dispatchFee,
		failureReason = reason,
	})
end

function OilShipmentService:_buildEventTimes(eventRisk: number, travelSeconds: number)
	local times = {}
	local roll = math.random()
	local eventCount = 0
	if roll < eventRisk * 0.25 then
		eventCount = 2
	elseif roll < eventRisk then
		eventCount = 1
	end

	for _ = 1, eventCount do
		table.insert(times, math.random() * (travelSeconds * 0.75) + (travelSeconds * 0.15))
	end
	table.sort(times, function(a, b)
		return a < b
	end)
	return times
end

function OilShipmentService:_rollDamagePercent(eventRisk: number): number
	local minDamage = 0.08 + (eventRisk * 0.08)
	local maxDamage = 0.22 + (eventRisk * 0.20)
	return math.random() * (maxDamage - minDamage) + minDamage
end

function OilShipmentService:_spawnBoat(plot: Model): Instance
	local container = plot:FindFirstChild("OilVisuals")
	if not (container and container:IsA("Folder")) then
		container = Instance.new("Folder")
		container.Name = "OilVisuals"
		container.Parent = plot
	end

	local boat = if self._boatTemplate then self._boatTemplate:Clone() else self:_createFallbackBoat()
	boat.Name = "ActiveShipmentBoat"
	anchorAll(boat)
	if boat:IsA("Model") and boat.PrimaryPart == nil then
		local first = getFirstBasePart(boat)
		if first then
			boat.PrimaryPart = first
		end
	end
	boat.Parent = container
	return boat
end

function OilShipmentService:_createFallbackBoat(): Model
	local model = Instance.new("Model")
	model.Name = "FallbackTanker"

	local hull = Instance.new("Part")
	hull.Name = "Hull"
	hull.Size = Vector3.new(14, 3, 30)
	hull.Material = Enum.Material.Metal
	hull.Color = Color3.fromRGB(58, 72, 88)
	hull.Anchored = true
	hull.CanCollide = false
	hull.Parent = model

	local deck = Instance.new("Part")
	deck.Name = "Deck"
	deck.Size = Vector3.new(10, 2, 16)
	deck.Material = Enum.Material.Metal
	deck.Color = Color3.fromRGB(90, 96, 106)
	deck.Anchored = true
	deck.CanCollide = false
	deck.CFrame = hull.CFrame * CFrame.new(0, 2.0, 0)
	deck.Parent = model

	model.PrimaryPart = hull
	return model
end

function OilShipmentService:_playLoadAnimation(stackRoot: Instance?, loadPoint: Instance?, totalLoaded: number)
	if not (stackRoot and stackRoot:IsA("BasePart")) then
		return
	end
	if not (loadPoint and loadPoint:IsA("BasePart")) then
		return
	end

	local visuals = math.min(totalLoaded, 18)
	for i = 1, visuals do
		task.delay(i * 0.05, function()
			local part = Instance.new("Part")
			part.Name = "LoadBarrelFX"
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(1.4, 1.8, 1.4)
			part.Material = Enum.Material.Metal
			part.Color = Color3.fromRGB(162, 120, 50)
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Orientation = Vector3.new(0, 0, 90)

			local jitter = Vector3.new(math.random(-2, 2), math.random(0, 3), math.random(-2, 2))
			part.CFrame = stackRoot.CFrame * CFrame.new(jitter)
			part.Parent = stackRoot.Parent

			local tween = TweenService:Create(part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				CFrame = loadPoint.CFrame * CFrame.new(0, 2, 0),
				Transparency = 0.1,
			})
			tween:Play()
			tween.Completed:Connect(function()
				if part.Parent then
					part:Destroy()
				end
			end)
		end)
	end
end

function OilShipmentService:_emitShipmentEvent(kind: string, payload)
	local event = self._remoteService:GetEvent(RemoteNames.ShipmentVisualEvent)
	event:FireAllClients({
		type = kind,
		data = payload,
	})
end

function OilShipmentService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

return OilShipmentService
