--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevLog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevLog"))
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)

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
	self._characterAddedByUserId = {}
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

	-- Capacity guard: warn loudly if fewer plots than MaxPlayers. Players joining past
	-- the plot count will be kicked with "Server full" at claim time.
	local plotCount = #self:_getPlotsSorted()
	if plotCount < Players.MaxPlayers then
		warn(string.format("[PlotService] Authored plots (%d) < MaxPlayers (%d) — set MaxPlayers to %d in Game Settings.",
			plotCount, Players.MaxPlayers, plotCount))
	end

	-- We drive character spawning manually: plot must be assigned BEFORE the character loads,
	-- or Roblox's default spawn (world origin, mid-ocean on this map) briefly places them
	-- there and subsequent PivotTo calls can be overridden by character-loading logic.
	Players.CharacterAutoLoads = false

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end
end

function PlotService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	for userId, connection in pairs(self._characterAddedByUserId) do
		connection:Disconnect()
		self._characterAddedByUserId[userId] = nil
	end
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

-- Tile parts are usually `T11`-style BaseParts; they may be nested (folders) in authored plots.
function PlotService:FindChunkTileBasePart(sectionModel: Model, tileKey: string): BasePart?
	local inst = sectionModel:FindFirstChild(tileKey, true)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	if inst and inst:IsA("Model") then
		if inst.PrimaryPart and inst.PrimaryPart:IsA("BasePart") then
			return inst.PrimaryPart
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				return d
			end
		end
	end
	for _, d in ipairs(sectionModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == tileKey then
			return d
		end
	end
	return nil
end

function PlotService:GetChunkTileSurfaceWorldY(plot: Model, chunkId: string, tileKey: string): number?
	local section = self:GetChunkModel(plot, chunkId)
	if not section then
		return nil
	end
	local tilePart = self:FindChunkTileBasePart(section, tileKey)
	if not tilePart then
		return nil
	end
	return tilePart.Position.Y + tilePart.Size.Y / 2
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
	local OilConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("OilConfig"))
	local startingSectionId = string.format("S%02d_%02d", OilConfig.Chunks.StartingRow, OilConfig.Chunks.StartingCol)

	for _, plot in ipairs(plots) do
		-- Reset ownership on boot — prevents stale OwnerUserId from prior sessions blocking claims.
		plot:SetAttribute("OwnerUserId", 0)

		-- Warn-only validation; plot authoring in Studio should keep these correct.
		if typeof(plot:GetAttribute("PlotId")) ~= "number" then
			warn(string.format("[PlotService] %s is missing PlotId attribute", plot.Name))
		end
		local ground = plot:FindFirstChild("PlotGround")
		local starterSection = ground and ground:FindFirstChild(startingSectionId)
		if not (starterSection and starterSection:GetAttribute("StartingChunk") == true) then
			warn(string.format("[PlotService] %s %s missing StartingChunk=true", plot.Name, startingSectionId))
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
	-- BoatSpawn / BoatExit per-plot markers are no longer used: boats live at
	-- workspace.dOCKS.BoatSpawn{1..8} managed by BoatDockService.

	-- OilTanks rig: clone ReplicatedStorage.Assets.OilTanksTemplate to <plot>.OilTanks
	-- if missing, pivoted to the plot's OilTanksAnchor (authored in Studio). The rig carries
	-- tier tubes tagged with attribute OilType; the liquid Parts are anchored fill indicators.
	local existingTanks = plot:FindFirstChild("OilTanks")
	local tanksAnchor = plot:FindFirstChild("OilTanksAnchor")
	if not existingTanks and tanksAnchor and tanksAnchor:IsA("BasePart") then
		local assets = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
		local template = assets and assets:FindFirstChild("OilTanksTemplate")
		if template then
			local tanks = template:Clone()
			tanks.Name = "OilTanks"
			tanks:PivotTo(tanksAnchor.CFrame)
			tanks.Parent = plot
		else
			warn(string.format("[PlotService] %s: no OilTanksTemplate in ReplicatedStorage.Assets", plot.Name))
		end
	end
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

function PlotService:_findOwnedPlotByUserId(userId: number): Model?
	for _, plot in ipairs(self:_getPlotsSorted()) do
		local owner = plot:GetAttribute("OwnerUserId")
		if typeof(owner) == "number" and owner == userId then
			return plot
		end
	end
	return nil
end

function PlotService:_ensureCharacterAddedConnection(player: Player)
	local oldConn = self._characterAddedByUserId[player.UserId]
	if oldConn then
		oldConn:Disconnect()
	end
	self._characterAddedByUserId[player.UserId] = player.CharacterAdded:Connect(function(character)
		DevLog.log(string.format("[PlotService] %s CharacterAdded", player.Name))
		self:_teleportCharacterToOwnedPlot(player, character)
	end)
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
		warn(string.format("[PlotService] Teleport %s: no assigned plot", player.Name))
		return
	end
	local spawnPart = getSpawnPart(plot)
	if not spawnPart then
		warn(string.format("[PlotService] Teleport %s: no spawn part on %s", player.Name, plot.Name))
		return
	end

	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not (hrp and hrp:IsA("BasePart")) then
		warn(string.format("[PlotService] Teleport %s: HumanoidRootPart never appeared", player.Name))
		return
	end

	CharacterTeleport.unseatIfSitting(character)

	local target = CFrame.new(
		spawnPart.Position.X,
		math.max(14, spawnPart.Position.Y + 8),
		spawnPart.Position.Z
	)
	-- Set HRP CFrame directly — more reliable than PivotTo during character load.
	hrp.CFrame = target
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	-- One safety re-teleport 0.3s later: absorbs character-load settle (default-spawn
	-- logic, humanoid state transitions) that can clobber the initial CFrame.
	task.delay(0.3, function()
		if hrp.Parent and character.Parent then
			if (hrp.Position - target.Position).Magnitude > 10 then
				hrp.CFrame = target
				hrp.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end)
end

function PlotService:_onPlayerAdded(player: Player)
	local plot = self._assignedByUserId[player.UserId]
	if not plot then
		plot = self:_findOwnedPlotByUserId(player.UserId)
	end
	if not plot then
		plot = self:_claimRandomOpenPlot(player.UserId)
	end
	if not plot then
		player:Kick("Server full - no open plots.")
		return
	end

	local wasAlreadyAssigned = self._assignedByUserId[player.UserId] == plot
	self._assignedByUserId[player.UserId] = plot
	player:SetAttribute("PlotId", getPlotId(plot))
	self:_ensureCharacterAddedConnection(player)

	if wasAlreadyAssigned then
		DevLog.log(string.format("[PlotService] duplicate _onPlayerAdded for %s - reusing %s", player.Name, plot.Name))
		if player.Character then
			self:_teleportCharacterToOwnedPlot(player, player.Character)
		else
			player:LoadCharacter()
		end
		return
	end

	-- Snapshot of plot structure at assignment time
	local ground = plot:FindFirstChild("PlotGround")
	local sectionCount = 0
	local tileCount = 0
	if ground then
		for _, s in ipairs(ground:GetChildren()) do
			if s:IsA("Model") then
				sectionCount += 1
				for _, t in ipairs(s:GetChildren()) do
					if t:IsA("BasePart") and t.Name:match("^T%d%d$") then
						tileCount += 1
					end
				end
			end
		end
	end
	DevLog.log(string.format("[PlotService] %s -> %s ClaimPad.X=%.1f sections=%d tiles=%d",
		player.Name, plot.Name,
		plot.ClaimPad and plot.ClaimPad.Position.X or -999,
		sectionCount, tileCount))

	if self._plotAssignedEvent then
		self._plotAssignedEvent:Fire(player.UserId, plot)
	end

	-- Load the character AFTER plot assignment so its first spawn is on the plot.
	player:LoadCharacter()

	-- Sanity check 2s after join: do we still have state + plot?
	task.delay(2, function()
		local assignedPlot = self._assignedByUserId[player.UserId]
		DevLog.log(string.format("[PlotService] 2s check %s: assignedPlot=%s",
			player.Name, assignedPlot and assignedPlot.Name or "<NONE>"))
	end)
end

function PlotService:_onPlayerRemoving(player: Player)
	local plot = self._assignedByUserId[player.UserId]
	DevLog.log(string.format("[PlotService] %s leaving - releasing %s",
		player.Name, plot and plot.Name or "<none>"))
	self:_releasePlot(plot)

	local characterConn = self._characterAddedByUserId[player.UserId]
	if characterConn then
		characterConn:Disconnect()
		self._characterAddedByUserId[player.UserId] = nil
	end

	if self._plotReleasedEvent and plot then
		self._plotReleasedEvent:Fire(player.UserId, plot)
	end
	self._assignedByUserId[player.UserId] = nil
end

return PlotService
