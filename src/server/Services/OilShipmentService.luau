--!strict

local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
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
	self._lanes = {}

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	self._boatTemplate = assetsFolder and assetsFolder:FindFirstChild("Tanker") or nil
	self._activeShips = {} -- per-ship runtime state keyed by shipmentId

	-- Collision group: ships don't collide with each other
	local ok, _ = pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	if ok then
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
		end)
	end

	-- Discover strait lane waypoints
	self:_discoverLanes()
end

function OilShipmentService:_discoverLanes()
	self._lanes = {}
	local Workspace = game:GetService("Workspace")
	local map = Workspace:FindFirstChild("Map")
	local ocean = map and map:FindFirstChild("Ocean")
	local strait = ocean and ocean:FindFirstChild("StraitHormuz")
	local routes = strait and strait:FindFirstChild("Routes")
	if not routes then
		warn("[OilShipmentService] No Routes folder found at Map.Ocean.StraitHormuz.Routes")
		return
	end

	for _, lane in ipairs(routes:GetChildren()) do
		if lane:IsA("Folder") or lane:IsA("Model") then
			local waypoints = {}
			for _, wp in ipairs(lane:GetChildren()) do
				if wp:IsA("BasePart") then
					table.insert(waypoints, wp)
				end
			end
			-- Sort numerically by name (01, 02, ..., 11, 12)
			table.sort(waypoints, function(a, b)
				local numA = tonumber(a.Name) or 0
				local numB = tonumber(b.Name) or 0
				return numA < numB
			end)
			if #waypoints >= 2 then
				local positions = {}
				for _, wp in ipairs(waypoints) do
					table.insert(positions, wp.Position)
				end
				table.insert(self._lanes, {
					name = lane.Name,
					positions = positions,
				})
			end
		end
	end

	-- Also find the strait BoatSpawn zone for random spawn position
	local zones = strait and strait:FindFirstChild("Zones")
	self._straitBoatSpawn = zones and zones:FindFirstChild("BoatSpawn")

	print(string.format("[OilShipmentService] Discovered %d lanes", #self._lanes))
end

function OilShipmentService:_pickLane(seed: number)
	if #self._lanes == 0 then
		return nil
	end
	local rng = Random.new(seed)
	local idx = rng:NextInteger(1, #self._lanes)
	return self._lanes[idx]
end

function OilShipmentService:_buildPath(dockSpawnPos: Vector3, lane): { Vector3 }
	-- Full path: dock → each lane waypoint in order
	local path = { dockSpawnPos }
	for _, pos in ipairs(lane.positions) do
		table.insert(path, pos)
	end
	return path
end

function OilShipmentService:_computePathLength(path: { Vector3 }): number
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
	end
	return total
end

function OilShipmentService:Start()
	local requestDispatch = self._remoteService:GetEvent(RemoteNames.RequestDispatchShipment)
	table.insert(self._connections, requestDispatch.OnServerEvent:Connect(function(player, payload)
		self:_handleDispatch(player, payload)
	end))

	local teleportToShip = self._remoteService:GetEvent(RemoteNames.RequestTeleportToShip)
	table.insert(self._connections, teleportToShip.OnServerEvent:Connect(function(player)
		self:_handleTeleportToShip(player)
	end))

	local teleportHome = self._remoteService:GetEvent(RemoteNames.RequestTeleportHome)
	table.insert(self._connections, teleportHome.OnServerEvent:Connect(function(player)
		self:_handleTeleportHome(player)
	end))
end

function OilShipmentService:_handleTeleportToShip(player: Player)
	local character = player.Character
	if not character then return end

	-- Find an active shipment boat for this player
	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then return end
	local visuals = plot:FindFirstChild("OilVisuals")
	if not visuals then return end

	for _, child in ipairs(visuals:GetChildren()) do
		if child.Name == "ActiveShipmentBoat" then
			local seat = child:FindFirstChild("DeckSeat", true)
			if seat and seat:IsA("Seat") then
				character:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					seat:Sit(humanoid)
				end
				return
			end
		end
	end
end

function OilShipmentService:_handleTeleportHome(player: Player)
	local character = player.Character
	if not character then return end

	-- Unseat if sitting
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		humanoid.SeatPart:Sit(nil)
		task.wait(0.1)
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then return end
	local claimPad = plot:FindFirstChild("ClaimPad")
	if claimPad and claimPad:IsA("BasePart") then
		character:PivotTo(CFrame.new(claimPad.Position + Vector3.new(0, 5, 0)))
	end
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
	local loadPoint = plot:FindFirstChild("ShipLoadPoint")
	local stackRoot = plot:FindFirstChild("BarrelStackRoot")

	-- Pick a lane and build the full path: dock → lane waypoints
	local seed = math.floor(workspace:GetServerTimeNow() * 1000) + ownerUserId
	local lane = self:_pickLane(seed)
	if not lane then
		warn("[OilShipmentService] No lanes available, falling back to straight line.")
		local spawnPart = plot:FindFirstChild("BoatSpawn")
		local exitPart = plot:FindFirstChild("BoatExit")
		local startPos = spawnPart and spawnPart.Position or Vector3.new(0, 5, 0)
		local endPos = exitPart and exitPart.Position or (startPos + Vector3.new(0, 0, -140))
		lane = { name = "Fallback", positions = { startPos, endPos } }
	end

	-- Dock spawn position
	local dockSpawnPart = plot:FindFirstChild("BoatSpawn")
	local dockSpawnPos = dockSpawnPart and dockSpawnPart.Position or Vector3.new(0, 5, 0)

	local path = self:_buildPath(dockSpawnPos, lane)
	local totalPathLen = self:_computePathLength(path)
	if totalPathLen < 1 then totalPathLen = 1 end

	-- Ship Y offset: raise above water surface
	local SHIP_Y_OFFSET = 8

	local startRaised = Vector3.new(path[1].X, path[1].Y + SHIP_Y_OFFSET, path[1].Z)
	local initDir = #path >= 2 and (path[2] - path[1]) or Vector3.new(0, 0, -1)

	-- Setup physics-driven ship
	self:_setupShip(shipment.shipmentId, boat, startRaised, initDir)

	self:_emitShipmentEvent("ShipmentStarted", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boatTypeId = shipment.boatTypeId,
		loaded = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
	})

	-- Load animation at the dock
	self:_playLoadAnimation(stackRoot, loadPoint, shipment.totalLoaded)

	-- Stack loaded barrels visually on the ship deck
	self:_loadBarrelsOnDeck(boat, shipment.manifest)

	-- Enable boarding: player can teleport to the deck seat
	local boardConnection = self:_enableBoarding(boat, ownerUserId)

	task.wait(1.2)

	-- Voyage: follow the polyline path over travelSeconds
	local voyageTime = shipment.travelSeconds
	local eventTimes = self:_buildEventTimes(shipment.eventRisk, voyageTime)
	local startTime = workspace:GetServerTimeNow()
	local eventCursor = 1

	-- Pre-compute cumulative segment distances for the polyline
	local segDists = { 0 }
	for i = 2, #path do
		segDists[i] = segDists[i - 1] + (path[i] - path[i - 1]).Magnitude
	end

	local lastPos = path[1]

	while true do
		local elapsed = workspace:GetServerTimeNow() - startTime
		local alpha = clamp01(elapsed / voyageTime)

		-- Map alpha (0..1) to a position along the polyline
		local targetDist = alpha * totalPathLen
		local currentPos = path[#path]
		local nextPos = path[#path]
		for i = 2, #path do
			if segDists[i] >= targetDist then
				local segStart = path[i - 1]
				local segEnd = path[i]
				local segLen = segDists[i] - segDists[i - 1]
				local segAlpha = if segLen > 0 then (targetDist - segDists[i - 1]) / segLen else 0
				currentPos = segStart:Lerp(segEnd, clamp01(segAlpha))
				nextPos = segEnd
				break
			end
		end

		local raisedPos = Vector3.new(currentPos.X, currentPos.Y + SHIP_Y_OFFSET, currentPos.Z)
		local flatDir = Vector3.new(nextPos.X - currentPos.X, 0, nextPos.Z - currentPos.Z)

		self:_updateShipPosition(shipment.shipmentId, boat, raisedPos, flatDir)

		lastPos = currentPos

		-- Fire damage events at scheduled times
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
		task.wait() -- run every frame (~30fps) for smooth movement
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

	-- Unseat riders and destroy
	if boardConnection then
		boardConnection:Disconnect()
	end
	self:_unseatPlayersFromBoat(boat)
	self:_cleanupShip(shipment.shipmentId, boat)
end

function OilShipmentService:_enableBoarding(boat: Instance, ownerUserId: number)
	local seat = boat:FindFirstChild("DeckSeat", true)
	if not (seat and seat:IsA("Seat")) then
		return nil
	end

	local prompt = seat:FindFirstChild("BoardPrompt")
	if not prompt or not prompt:IsA("ProximityPrompt") then
		return nil
	end

	prompt.Enabled = true
	local connection = prompt.Triggered:Connect(function(player: Player)
		if player.UserId ~= ownerUserId then return end
		local character = player.Character
		if not character then return end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		-- Teleport player to the seat
		character:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
		seat:Sit(character:FindFirstChildOfClass("Humanoid"))
	end)

	return connection
end

function OilShipmentService:_unseatPlayersFromBoat(boat: Instance)
	local seat = boat:FindFirstChild("DeckSeat", true)
	if not (seat and seat:IsA("Seat")) then return end

	local occupant = seat.Occupant
	if occupant and occupant:IsA("Humanoid") then
		seat:Sit(nil)
		-- Teleport the player back to their plot
		local character = occupant.Parent
		if character then
			local player = game:GetService("Players"):GetPlayerFromCharacter(character)
			if player then
				local plot = self._plotService:GetOwnedPlot(player.UserId)
				local claimPad = plot and plot:FindFirstChild("ClaimPad")
				if claimPad and claimPad:IsA("BasePart") then
					character:PivotTo(CFrame.new(claimPad.Position + Vector3.new(0, 5, 0)))
				end
			end
		end
	end
end

function OilShipmentService:_loadBarrelsOnDeck(boat: Instance, manifest)
	local stackRoot = boat:FindFirstChild("BarrelStackRoot", true)
	if not stackRoot then return end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return end

	local tierTemplates = {
		PremiumRefined = "Barrel_PremiumRefined",
		LightSweet = "Barrel_LightSweet",
		StandardCrude = "Barrel_StandardCrude",
		HeavyCrude = "Barrel_HeavyCrude",
	}

	local barrelIndex = 0
	local COLUMNS = 3
	local SPACING = 3
	local HEIGHT = 3.5

	for _, tier in ipairs(TIER_ORDER) do
		local count = manifest[tier] or 0
		local templateName = tierTemplates[tier]
		local template = templateName and assetsFolder:FindFirstChild(templateName)

		for _ = 1, math.min(count, 10) do -- cap visual at 10 per tier
			local barrel
			if template then
				barrel = template:Clone()
			else
				barrel = Instance.new("Part")
				barrel.Shape = Enum.PartType.Cylinder
				barrel.Size = Vector3.new(2.2, 2, 2)
				barrel.Material = Enum.Material.Metal
				barrel.Color = Color3.fromRGB(165, 118, 46)
				barrel.Orientation = Vector3.new(0, 0, 90)
			end

			barrel.Name = "DeckBarrel"

			local col = barrelIndex % COLUMNS
			local row = math.floor(barrelIndex / COLUMNS) % COLUMNS
			local layer = math.floor(barrelIndex / (COLUMNS * COLUMNS))

			local offset = Vector3.new(
				(col - 1) * SPACING,
				layer * HEIGHT,
				(row - 1) * SPACING
			)

			-- Position relative to stackRoot
			local targetCf = stackRoot.CFrame * CFrame.new(offset)
			if barrel:IsA("Model") then
				barrel:PivotTo(targetCf)
			elseif barrel:IsA("BasePart") then
				barrel.CFrame = targetCf
			end

			barrel.Parent = boat

			-- Unanchor + weld every part to stackRoot (which is already welded to ship root)
			for _, part in ipairs(barrel:IsA("Model") and barrel:GetDescendants() or {barrel}) do
				if part:IsA("BasePart") then
					part.Anchored = false
					part.Massless = true
					part.CanCollide = true
					local wc = Instance.new("WeldConstraint")
					wc.Part0 = stackRoot
					wc.Part1 = part
					wc.Parent = stackRoot
				end
			end
			barrelIndex += 1
		end
	end
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
	boat.Parent = container
	return boat
end

-- =================== SHIP LIFECYCLE (Physics-Driven) ===================

function OilShipmentService:_setupShip(shipmentId: string, boatModel: Model, startPosition: Vector3, lookDirection: Vector3)
	-- 1. Find root part (largest volume BasePart)
	local root: BasePart? = nil
	local bestVol = 0
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then
				bestVol = v
				root = d
			end
		end
	end
	if not root then
		warn("[OilShipmentService] No root part found for ship")
		return
	end

	-- 2. Build rigid assembly: unanchor all, weld non-root to root.
	-- Skip welding door parts (IsDoor attribute) — they swing via HingeConstraint.
	-- Their frames (DOOR*_Frame) DO get welded so they move with the ship.
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = true
			d.CanTouch = true
			d.CanQuery = true
			if d == root then
				d.Massless = false
			elseif d:GetAttribute("IsDoor") then
				-- Door panel: don't weld, let hinge control it
				d.Massless = true
			else
				d.Massless = true
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = root
				wc.Part1 = d
				wc.Parent = root
			end
			pcall(function()
				d.CollisionGroup = "ShipmentShip"
			end)
		end
	end

	-- 3. Server authority — prevents client from fighting for physics ownership
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	-- 4. Constraints
	local att = Instance.new("Attachment")
	att.Name = "ShipAtt"
	att.Parent = root

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "ShipAlignPos"
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.MaxForce = 1e9
	alignPos.MaxVelocity = 200
	alignPos.Responsiveness = 8
	alignPos.Position = startPosition
	alignPos.Parent = root

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "ShipAlignOri"
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att
	alignOri.MaxTorque = 1e9
	alignOri.Responsiveness = 4
	alignOri.Parent = root

	-- 5. Initial orientation: PivotTo first to get the ship UPRIGHT at startPosition.
	-- Then capture the root's actual rotation (which keeps the ship right-side-up).
	-- Only adjust YAW on top of that base rotation.
	boatModel:PivotTo(CFrame.new(startPosition))

	-- Capture the root's "upright" rotation and its default bow direction
	local baseRotation = root.CFrame - root.CFrame.Position -- rotation-only CFrame
	local defaultBowDir = root.CFrame.RightVector -- +X in world after PivotTo
	local defaultYaw = math.atan2(-defaultBowDir.Z, defaultBowDir.X)

	-- Compute desired yaw from look direction
	local flatDir = Vector3.new(lookDirection.X, 0, lookDirection.Z)
	if flatDir.Magnitude < 0.01 then
		flatDir = Vector3.new(0, 0, -1)
	end
	local bowDir = flatDir.Unit
	-- Bow is at -X, so flip 180° to point -X toward travel direction
	local targetYaw = math.atan2(-bowDir.Z, bowDir.X) + math.pi
	local yawDelta = targetYaw - defaultYaw

	-- Apply: base upright rotation + yaw delta
	local initRotation = CFrame.Angles(0, yawDelta, 0) * baseRotation
	root.CFrame = CFrame.new(startPosition) * initRotation
	alignOri.CFrame = initRotation

	-- Store default yaw for update function
	boatModel:SetAttribute("DefaultYaw", defaultYaw)

	boatModel.PrimaryPart = root

	-- 6. Store runtime state (including baseRotation for update function)
	self._activeShips[shipmentId] = {
		root = root,
		alignPos = alignPos,
		alignOri = alignOri,
		lastForward = bowDir,
		baseRotation = baseRotation,
		connections = {},
	}
end

function OilShipmentService:_updateShipPosition(shipmentId: string, boatModel: Model, targetPosition: Vector3, targetLookDirection: Vector3)
	local state = self._activeShips[shipmentId]
	if not state then return end

	-- Flat direction (yaw only, never pitch)
	local flatDir = Vector3.new(targetLookDirection.X, 0, targetLookDirection.Z)
	if flatDir.Magnitude < 0.01 then
		flatDir = state.lastForward
	else
		flatDir = flatDir.Unit
	end
	state.lastForward = flatDir

	-- Compute yaw delta from the ship's default orientation
	local defaultYaw = boatModel:GetAttribute("DefaultYaw") or 0
	-- Bow is at -X, flip 180°
	local targetYaw = math.atan2(-flatDir.Z, flatDir.X) + math.pi
	local yawDelta = targetYaw - defaultYaw

	-- Capture the base upright rotation (stored at setup, preserved in root's natural orientation)
	-- Re-derive from the root's current CFrame minus the previous yaw we applied
	-- Simpler: just store baseRotation in state
	if not state.baseRotation then
		-- Fallback: read from root now (should have been stored at setup)
		state.baseRotation = CFrame.Angles(0, 0, 0)
	end

	-- Drive constraints: base upright + yaw delta
	state.alignPos.Position = targetPosition
	state.alignOri.CFrame = CFrame.Angles(0, yawDelta, 0) * state.baseRotation
end

function OilShipmentService:_cleanupShip(shipmentId: string, boatModel: Model)
	local state = self._activeShips[shipmentId]
	if state then
		-- Disconnect any tracked connections
		for _, conn in ipairs(state.connections) do
			pcall(function() conn:Disconnect() end)
		end
		self._activeShips[shipmentId] = nil
	end

	-- Unseat any players on the ship
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("Seat") and d.Occupant then
			pcall(function()
				d:Sit(nil)
			end)
		end
	end

	-- Teleport any player standing on/in the ship back to their plot
	task.delay(0.1, function()
		if boatModel and boatModel.Parent then
			boatModel:Destroy()
		end
	end)
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
