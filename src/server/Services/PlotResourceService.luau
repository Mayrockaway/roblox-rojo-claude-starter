--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local PlotResourceService = {}

function PlotResourceService:Init(remoteService, oilStateService, plotService, oilVisualService, oilShipmentService, chunkOwnershipService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._oilVisualService = oilVisualService
	self._oilShipmentService = oilShipmentService
	self._chunkOwnershipService = chunkOwnershipService
	self._connections = {}
	self._requestBuckets = {}
end

function PlotResourceService:Start()
	local placeEvent = self._remoteService:GetEvent(RemoteNames.RequestPlaceDrill)
	local removeEvent = self._remoteService:GetEvent(RemoteNames.RequestRemoveDrill)
	local buyChunkEvent = self._remoteService:GetEvent(RemoteNames.RequestBuyChunk)
	local placePipeEvent = self._remoteService:GetEvent(RemoteNames.RequestPlacePipe)
	local removePipeEvent = self._remoteService:GetEvent(RemoteNames.RequestRemovePipe)
	local snapshotFn = self._remoteService:GetFunction(RemoteNames.RequestOilSnapshot)

	table.insert(self._connections, placeEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePlaceDrillRequest(player, payload)
	end))

	table.insert(self._connections, removeEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleRemoveDrillRequest(player, payload)
	end))

	table.insert(self._connections, buyChunkEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleBuyChunkRequest(player, payload)
	end))

	table.insert(self._connections, placePipeEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePlacePipeRequest(player, payload)
	end))

	table.insert(self._connections, removePipeEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleRemovePipeRequest(player, payload)
	end))

	local clearObstacleEvent = self._remoteService:GetEvent(RemoteNames.RequestClearObstacle)
	table.insert(self._connections, clearObstacleEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleClearObstacleRequest(player, payload)
	end))

	local pickupBarrelEvent = self._remoteService:GetEvent(RemoteNames.RequestPickupBarrel)
	table.insert(self._connections, pickupBarrelEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePickupBarrelRequest(player, payload)
	end))

	local setBoatEvent = self._remoteService:GetEvent(RemoteNames.RequestSetSelectedBoat)
	table.insert(self._connections, setBoatEvent.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "table" or typeof(payload.boatTypeId) ~= "string" then
			return
		end
		local ok, _err = self._oilStateService:SetSelectedBoatTypeId(player.UserId, payload.boatTypeId)
		if ok then
			self._oilStateService:PushState(player.UserId)
		end
	end))

	snapshotFn.OnServerInvoke = function(player)
		return {
			state = self._oilStateService:GetStateForClient(player.UserId),
			config = {
				drillPlacementCost = OilConfig.DrillPlacementCost,
				drillMinSpacing = OilConfig.DrillMinSpacing,
				removeDrillHoldSeconds = OilConfig.RemoveDrillHoldSeconds,
				removeDrillRangeStuds = OilConfig.RemoveDrillRangeStuds,
				chunkUnlockBaseCost = OilConfig.ChunkUnlockBaseCost,
				chunkUnlockDistanceMultiplier = OilConfig.ChunkUnlockDistanceMultiplier,
				pipeCost = OilConfig.Pipes.Cost,
				pipeMinLength = OilConfig.Pipes.MinLength,
				pipeMaxLength = OilConfig.Pipes.MaxLength,
				pipeSnapRadius = OilConfig.Pipes.EndpointSnapRadius,
				chunks = {
					size = OilConfig.Chunks.Size,
					rows = OilConfig.Chunks.GridRows,
					cols = OilConfig.Chunks.GridCols,
					startingCenterSize = OilConfig.Chunks.StartingCenterSize,
				},
				boatCatalog = self._oilShipmentService and self._oilShipmentService:GetBoatCatalogForClient() or {},
			},
		}
	end
end

function PlotResourceService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._requestBuckets = {}
end

function PlotResourceService:_handleBuyChunkRequest(player: Player, payload)
	if not self:_allow(player.UserId, "buyChunk", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many buy requests.")
		return
	end

	if typeof(payload) ~= "table" or typeof(payload.chunkId) ~= "string" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing chunkId.")
		return
	end

	local ok, code, message = self._oilStateService:TryBuyChunk(player.UserId, payload.chunkId)
	self:_sendResult(player, ok, code, message, { chunkId = payload.chunkId })
	if ok then
		if self._chunkOwnershipService then
			self._chunkOwnershipService:RefreshChunk(player.UserId, payload.chunkId)
		end
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handlePlaceDrillRequest(player: Player, payload)
	if not self:_allow(player.UserId, "placeDrill", 30, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many drill placement requests.")
		return
	end

	if typeof(payload) ~= "table" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing payload.")
		return
	end

	local ok, code, message, data = self._oilStateService:TryPlaceDrill(player.UserId, payload)
	self:_sendResult(player, ok, code, message, data or { chunkId = payload.chunkId })
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handleRemoveDrillRequest(player: Player, payload)
	if not self:_allow(player.UserId, "removeDrill", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many drill remove requests.")
		return
	end

	if typeof(payload) ~= "table" or typeof(payload.drillId) ~= "number" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing drillId.")
		return
	end

	if not self:_playerHasEmptyHands(player) then
		self:_sendResult(player, false, "ERR_HAND_NOT_EMPTY", "Hands must be empty to remove a drill.")
		return
	end

	if not self:_isInRemoveRangeOfDrill(player, payload.drillId) then
		self:_sendResult(player, false, "ERR_TOO_FAR", "Move closer to remove this drill.")
		return
	end

	local ok, code, message = self._oilStateService:TryRemoveDrill(player.UserId, payload.drillId)
	self:_sendResult(player, ok, code, message, { drillId = payload.drillId })
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handlePlacePipeRequest(player: Player, payload)
	if not self:_allow(player.UserId, "placePipe", 60, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many pipe placement requests.")
		return
	end

	if typeof(payload) ~= "table" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing payload.")
		return
	end

	local ok, code, message, data = self._oilStateService:TryPlacePipe(player.UserId, payload)
	self:_sendResult(player, ok, code, message, data)
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handleRemovePipeRequest(player: Player, payload)
	if not self:_allow(player.UserId, "removePipe", 30, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many pipe remove requests.")
		return
	end

	if typeof(payload) ~= "table" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing payload.")
		return
	end

	if not self:_playerHasEmptyHands(player) then
		self:_sendResult(player, false, "ERR_HAND_NOT_EMPTY", "Hands must be empty to remove a pipe.")
		return
	end

	local ok, code, message = self._oilStateService:TryRemovePipe(player.UserId, payload)
	self:_sendResult(player, ok, code, message, payload)
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_allow(userId: number, action: string, limit: number, windowSeconds: number): boolean
	local key = tostring(userId) .. ":" .. action
	local now = workspace:GetServerTimeNow()
	local bucket = self._requestBuckets[key]
	if not bucket then
		bucket = {
			start = now,
			count = 0,
		}
		self._requestBuckets[key] = bucket
	end

	if now - bucket.start >= windowSeconds then
		bucket.start = now
		bucket.count = 0
	end

	if bucket.count >= limit then
		return false
	end
	bucket.count += 1
	return true
end

function PlotResourceService:_sendResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function PlotResourceService:_playerHasEmptyHands(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			return false
		end
	end
	return true
end

function PlotResourceService:_handleClearObstacleRequest(player: Player, payload)
	if not self:_allow(player.UserId, "clearObstacle", 10, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many requests.")
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.chunkId) ~= "string" or typeof(payload.tileKey) ~= "string" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing chunkId or tileKey.")
		return
	end
	local ok, code, message = self._oilStateService:TryClearObstacle(player.UserId, payload.chunkId, payload.tileKey)
	self:_sendResult(player, ok, code, message)
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handlePickupBarrelRequest(player: Player, payload)
	if not self:_allow(player.UserId, "pickupBarrel", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many pickup requests.")
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.barrelName) ~= "string" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing barrel name.")
		return
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then
		self:_sendResult(player, false, "ERR_NO_PLOT", "No plot owned.")
		return
	end

	-- Find the barrel in the OilVisuals.Barrels folder
	local visuals = plot:FindFirstChild("OilVisuals")
	local barrelsFolder = visuals and visuals:FindFirstChild("Barrels")
	if not barrelsFolder then
		self:_sendResult(player, false, "ERR_NO_BARREL", "Barrel not found.")
		return
	end

	local barrel = barrelsFolder:FindFirstChild(payload.barrelName)
	if not barrel or not barrel:GetAttribute("OnConveyor") then
		self:_sendResult(player, false, "ERR_NOT_ON_CONVEYOR", "Can only pick up barrels from conveyor.")
		return
	end

	local tier = barrel:GetAttribute("Tier")
	barrel:Destroy()

	-- Create a Tool in the player's backpack with the barrel model
	local tierTemplates = OilConfig.Barrels and OilConfig.Barrels.TierTemplates or {}
	local templateName = tierTemplates[tier]
	local assetsFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
	local template = assetsFolder and templateName and assetsFolder:FindFirstChild(templateName)

	local tool = Instance.new("Tool")
	tool.Name = (tier or "Oil") .. " Barrel"
	tool.RequiresHandle = false
	tool.CanBeDropped = true

	if template then
		local visual = template:Clone()
		visual.Name = "BarrelVisual"
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.CanCollide = false
				d.Massless = true
			end
			if d:IsA("ProximityPrompt") then
				d:Destroy()
			end
		end
		-- Create a handle part
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Transparency = 1
		handle.CanCollide = false
		handle.Massless = true
		handle.Parent = tool

		if visual:IsA("Model") then
			visual.Parent = tool
		elseif visual:IsA("BasePart") then
			visual.Parent = tool
		end
	end

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		tool.Parent = backpack
	end

	self:_sendResult(player, true, "OK", "Picked up " .. (tier or "oil") .. " barrel.", { tier = tier })
end

function PlotResourceService:_isInRemoveRangeOfDrill(player: Player, drillId: number): boolean
	local drill = self._oilStateService:GetDrillById(player.UserId, drillId)
	if not drill then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return false
	end
	return (hrp.Position - drill.position).Magnitude <= OilConfig.RemoveDrillRangeStuds
end

return PlotResourceService
