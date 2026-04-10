--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PlotService = {}

local CLAIMED_COLOR = Color3.fromRGB(240, 95, 95)
local UNCLAIMED_COLOR = Color3.fromRGB(105, 210, 120)

local function getPlotId(plot: Instance): number
	local attr = plot:GetAttribute("PlotId")
	if typeof(attr) == "number" then
		return attr
	end
	local nameNumber = tonumber(string.match(plot.Name, "(%d+)"))
	return nameNumber or 9999
end

local function getSpawnPart(plot: Model): BasePart?
	local preferred = {
		"ClaimPad",
		"PumpSpawn",
		"PlotBounds",
	}
	for _, name in ipairs(preferred) do
		local item = plot:FindFirstChild(name)
		if item and item:IsA("BasePart") then
			return item
		end
	end
	if plot.PrimaryPart and plot.PrimaryPart:IsA("BasePart") then
		return plot.PrimaryPart
	end
	return nil
end

function PlotService:Init()
	self._assignedByUserId = {}
	self._connections = {}
	self._plotsFolder = nil
	self._running = false
	self._rng = Random.new()
	self._plotAssignedEvent = Instance.new("BindableEvent")
	self._plotReleasedEvent = Instance.new("BindableEvent")
end

function PlotService:Start()
	if self._running then
		return
	end
	self._running = true

	local map = Workspace:WaitForChild("Map", 20)
	if not map then
		warn("[PlotService] Workspace.Map not found.")
		return
	end
	self._plotsFolder = map:WaitForChild("Plots", 20)
	if not self._plotsFolder then
		warn("[PlotService] Map.Plots not found.")
		return
	end

	self:_initializePlots()

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end

	print("[PlotService] Running: chunked plot mode")
end

function PlotService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	if self._plotAssignedEvent then
		self._plotAssignedEvent:Destroy()
		self._plotAssignedEvent = nil
	end
	if self._plotReleasedEvent then
		self._plotReleasedEvent:Destroy()
		self._plotReleasedEvent = nil
	end
end

function PlotService:GetOwnedPlot(userId: number): Model?
	return self._assignedByUserId[userId]
end

function PlotService:GetPlotChunkDefinitions(plot: Model)
	local defs = {}
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return defs
	end

	for _, item in ipairs(ground:GetChildren()) do
		if item:IsA("Model") then
			local chunkId = item:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" and #chunkId > 0 then
				local row = item:GetAttribute("Row")
				local col = item:GetAttribute("Col")
				local biome = item:GetAttribute("Biome")
				local starting = item:GetAttribute("StartingChunk") == true
				local cx = item:GetAttribute("CenterX")
				local cz = item:GetAttribute("CenterZ")
				table.insert(defs, {
					chunkId = chunkId,
					row = typeof(row) == "number" and row or 1,
					col = typeof(col) == "number" and col or 1,
					biome = typeof(biome) == "string" and biome or "Desert",
					startingChunk = starting,
					worldX = typeof(cx) == "number" and cx or 0,
					worldZ = typeof(cz) == "number" and cz or 0,
					sectionModel = item,
				})
			end
		end
	end

	table.sort(defs, function(a, b)
		if a.row == b.row then
			return a.col < b.col
		end
		return a.row < b.row
	end)

	return defs
end

function PlotService:GetChunkModel(plot: Model, chunkId: string): Model?
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return nil
	end
	local m = ground:FindFirstChild(chunkId)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

function PlotService:OnPlotAssigned(callback)
	assert(self._plotAssignedEvent ~= nil, "PlotService not initialized.")
	return self._plotAssignedEvent.Event:Connect(callback)
end

function PlotService:OnPlotReleased(callback)
	assert(self._plotReleasedEvent ~= nil, "PlotService not initialized.")
	return self._plotReleasedEvent.Event:Connect(callback)
end

function PlotService:_initializePlots()
	local plots = self:_getPlotsSorted()
	for _, plot in ipairs(plots) do
		if plot:GetAttribute("OwnerUserId") == nil then
			plot:SetAttribute("OwnerUserId", 0)
		end
		self:_ensurePlotMarkers(plot)
		self:_refreshPlotVisual(plot)
	end
end

function PlotService:_ensurePlotMarkers(plot: Model)
	local anchor = plot:FindFirstChild("ClaimPad")
	if not (anchor and anchor:IsA("BasePart")) then
		anchor = plot:FindFirstChild("PlotBounds")
	end
	if not (anchor and anchor:IsA("BasePart")) then
		return
	end

	local barrelRoot = plot:FindFirstChild("BarrelStackRoot")
	if barrelRoot and not barrelRoot:IsA("Part") then
		barrelRoot:Destroy()
		barrelRoot = nil
	end
	if not barrelRoot then
		barrelRoot = Instance.new("Part")
		barrelRoot.Name = "BarrelStackRoot"
		barrelRoot.Size = Vector3.new(1, 1, 1)
		barrelRoot.Anchored = true
		barrelRoot.CanCollide = false
		barrelRoot.CanQuery = false
		barrelRoot.CanTouch = false
		barrelRoot.Transparency = 1
		barrelRoot.Parent = plot
		barrelRoot.CFrame = anchor.CFrame * CFrame.new(0, 1, -12)
	end

	local stackPad = plot:FindFirstChild("BarrelStackPad")
	if stackPad and not stackPad:IsA("Part") then
		stackPad:Destroy()
		stackPad = nil
	end
	if not stackPad then
		stackPad = Instance.new("Part")
		stackPad.Name = "BarrelStackPad"
		stackPad.Size = Vector3.new(8, 0.3, 8)
		stackPad.Anchored = true
		stackPad.CanCollide = false
		stackPad.CanQuery = false
		stackPad.CanTouch = false
		stackPad.Material = Enum.Material.Neon
		stackPad.Color = Color3.fromRGB(56, 126, 186)
		stackPad.Transparency = 0.65
		stackPad.Parent = plot
		stackPad.CFrame = barrelRoot.CFrame * CFrame.new(0, -0.65, 0)
	end

	local function ensureMarker(name: string, offset: Vector3, color: Color3)
		local marker = plot:FindFirstChild(name)
		if marker and not marker:IsA("Part") then
			marker:Destroy()
			marker = nil
		end
		local created = false
		if not marker then
			marker = Instance.new("Part")
			marker.Name = name
			marker.Size = Vector3.new(2, 2, 2)
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanQuery = false
			marker.CanTouch = false
			marker.Material = Enum.Material.Neon
			marker.Color = color
			marker.Transparency = 0.7
			marker.Parent = plot
			created = true
		end

		if created then
			marker.CFrame = anchor.CFrame * CFrame.new(offset)
		end
	end

	ensureMarker("ShipLoadPoint", Vector3.new(0, 3, 20), Color3.fromRGB(80, 160, 220))
	ensureMarker("BoatSpawn", Vector3.new(0, 2, 40), Color3.fromRGB(80, 220, 160))
	ensureMarker("BoatExit", Vector3.new(0, 2, 170), Color3.fromRGB(230, 160, 80))
end

function PlotService:_getPlotsSorted(): { Model }
	local plots = {}
	if not self._plotsFolder then
		return plots
	end
	for _, item in ipairs(self._plotsFolder:GetChildren()) do
		if item:IsA("Model") then
			table.insert(plots, item)
		end
	end
	table.sort(plots, function(a, b)
		return getPlotId(a) < getPlotId(b)
	end)
	return plots
end

function PlotService:_refreshPlotVisual(plot: Model)
	local claimPad = plot:FindFirstChild("ClaimPad")
	if not (claimPad and claimPad:IsA("BasePart")) then
		return
	end
	-- ClaimPad is a spawn marker only. Keep it fully invisible and non-interactive.
	claimPad.Transparency = 1
	claimPad.CanCollide = false
	claimPad.CanQuery = false
	claimPad.CanTouch = false
end

function PlotService:_claimRandomOpenPlot(userId: number): Model?
	local openPlots = {}
	for _, plot in ipairs(self:_getPlotsSorted()) do
		local owner = plot:GetAttribute("OwnerUserId")
		if typeof(owner) ~= "number" or owner == 0 then
			table.insert(openPlots, plot)
		end
	end

	if #openPlots == 0 then
		return nil
	end

	local selected = openPlots[self._rng:NextInteger(1, #openPlots)]
	selected:SetAttribute("OwnerUserId", userId)
	self:_refreshPlotVisual(selected)
	return selected
end

function PlotService:_releasePlot(plot: Model?)
	if not plot then
		return
	end
	plot:SetAttribute("OwnerUserId", 0)
	self:_refreshPlotVisual(plot)
end

function PlotService:_teleportCharacterToOwnedPlot(player: Player, character: Model)
	local plot = self._assignedByUserId[player.UserId]
	if not plot then
		return
	end
	local spawnPart = getSpawnPart(plot)
	if not spawnPart then
		return
	end

	local target = CFrame.new(
		spawnPart.Position.X,
		math.max(14, spawnPart.Position.Y + 8),
		spawnPart.Position.Z
	)

	for _ = 1, 40 do
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			character:PivotTo(target)
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero

			task.delay(0.8, function()
				if character.Parent and hrp.Parent then
					if (hrp.Position - target.Position).Magnitude > 30 then
						character:PivotTo(target)
						hrp.AssemblyLinearVelocity = Vector3.zero
						hrp.AssemblyAngularVelocity = Vector3.zero
					end
				end
			end)
			return
		end
		task.wait(0.1)
	end
end

function PlotService:_onPlayerAdded(player: Player)
	local plot = self:_claimRandomOpenPlot(player.UserId)
	self._assignedByUserId[player.UserId] = plot
	player:SetAttribute("PlotId", plot and getPlotId(plot) or 0)
	if self._plotAssignedEvent and plot then
		self._plotAssignedEvent:Fire(player.UserId, plot)
	end

	player.CharacterAdded:Connect(function(character)
		self:_teleportCharacterToOwnedPlot(player, character)
	end)

	if player.Character then
		task.defer(function()
			self:_teleportCharacterToOwnedPlot(player, player.Character :: Model)
		end)
	end
end

function PlotService:_onPlayerRemoving(player: Player)
	local plot = self._assignedByUserId[player.UserId]
	self:_releasePlot(plot)
	if self._plotReleasedEvent and plot then
		self._plotReleasedEvent:Fire(player.UserId, plot)
	end
	self._assignedByUserId[player.UserId] = nil
end

return PlotService
