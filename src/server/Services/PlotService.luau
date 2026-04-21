--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DevLog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevLog"))
local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("RemoteNames"))
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)
local ResponsiveBillboard = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("ResponsiveBillboard"))

--- Cached on first use. The `Remotes` folder is populated by `RemoteService:Init()` (runs in
--- `init.server.luau` before `PlotService:Start()`), so by the time any spawn happens this
--- lookup is a single `FindFirstChild` on a folder that already exists.
local _teleportHomeAppliedEvent: RemoteEvent? = nil
local function getTeleportHomeAppliedEvent(): RemoteEvent?
	if _teleportHomeAppliedEvent and _teleportHomeAppliedEvent.Parent then
		return _teleportHomeAppliedEvent
	end
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local remotes = shared and shared:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild(RemoteNames.TeleportHomeApplied)
	if ev and ev:IsA("RemoteEvent") then
		_teleportHomeAppliedEvent = ev
		return ev
	end
	return nil
end

local PlotService = {}

local CLAIMED_COLOR = Color3.fromRGB(240, 95, 95)
local UNCLAIMED_COLOR = Color3.fromRGB(105, 210, 120)

local PLOT_OWNER_BILLBOARD_NAME = "PlotOwnerBillboard"
-- Server-authored `BillboardGui` on workspace `ClaimPad`; replicates to every client.
local PLOT_NAME_BILLBOARD_STUDS_OFFSET_Y = 54
-- `TextScaled` fills the BillboardGui, and the BillboardGui itself is
-- distance-scaled by the engine. The `BillboardGui.Size` is set via
-- `ResponsiveBillboard.Mark` (and the client controller rescales per-
-- viewport), so 440x96 is the *design-target* pixel size at the reference
-- viewport (1366 wide) — phones get a proportional shrink, 1080p / 4K get
-- a proportional grow.
local PLOT_NAME_BILLBOARD_BASE_W = 440
local PLOT_NAME_BILLBOARD_BASE_H = 96
local PLOT_NAME_TEXT_MAX_SIZE = 96
local PLOT_NAME_TEXT_MIN_SIZE = 18
-- Max camera distance (studs) at which the plot ownership plate renders.
-- BillboardGui culls automatically beyond `MaxDistance`, so this acts as a
-- proximity gate — players only see other players' plot plates when their
-- camera is roughly "on or near" that plot, not from across the map.
-- Plots span ~50-80 studs so 120 keeps the plate visible while you walk up
-- to it but hides distant plates that would otherwise clutter the skyline.
local PLOT_NAME_BILLBOARD_MAX_DISTANCE = 120
local PREFERRED_PLOT_CLAIM_ORDER = { 3, 4, 5, 6, 2, 1, 7, 8 }

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

local function resetUnclaimedPlotTankUi(plot: Model)
	local tanks = plot:FindFirstChild("OilTanks")
	if not tanks then
		return
	end

	for _, descendant in ipairs(tanks:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			if descendant.Name == "TankSign" or descendant.Name == "HoloGui" then
				descendant.Enabled = false
			end
		elseif descendant:IsA("SurfaceGui") then
			descendant.Enabled = false
			descendant.Active = false
		elseif descendant:IsA("ClickDetector") or descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			if string.sub(descendant.Name, 1, 9) == "TankHolo_" then
				descendant:Destroy()
			end
		end
	end
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
	Players.RespawnTime = Constants.RespawnDelayAfterDeathSeconds

	-- SpawnLocation guard: imported decor models (US aircraft carrier, OIL RIG,
	-- and any future free-model dock/ship/island) frequently ship with their
	-- own enabled `SpawnLocation` instances on their decks. Roblox's engine
	-- auto-pivots a freshly-loaded character to the nearest enabled
	-- SpawnLocation, which competes with our `_teleportCharacterToOwnedPlot`
	-- and drops the player on a random carrier deck. The PlotService home
	-- claim pad is the only intended spawn point; force-disable everything
	-- else and watch for new decor added during the session.
	local function disableSpawnLocation(inst: Instance)
		if not inst:IsA("SpawnLocation") then
			return
		end
		if not inst.Enabled then
			return
		end
		inst.Enabled = false
		local p = inst.Position
		DevLog.log(string.format(
			"[PlotService.SpawnGuard] Disabled SpawnLocation %s pos=(%.1f,%.1f,%.1f)",
			inst:GetFullName(), p.X, p.Y, p.Z
		))
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		disableSpawnLocation(inst)
	end
	table.insert(self._connections, Workspace.DescendantAdded:Connect(disableSpawnLocation))

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

		self:_ensureCoreMachineAnchorsAndSnap(plot)
		self:_ensurePlotMarkers(plot)
		self:_ensurePerPlotDecor(plot)
		self:_refreshPlotVisual(plot)
		resetUnclaimedPlotTankUi(plot)
		self:_updatePlotNameBillboard(plot, nil)
	end
end

--- Per-plot world decor cloned from `ReplicatedStorage.Assets.<name>` templates
--- (currently `PlotDispatch` only). Templates are authored against `Plot_01`,
--- so each clone is shifted by `(plotPivot - plot01Pivot)` to land in the
--- equivalent position on every plot. Idempotent: skips templates that already
--- exist as direct children of `plot`.
---
--- `OilmanPlot` was previously cloned per plot but has been removed — the only
--- live Oilman NPC is the town one at `Workspace.Oilman.RodgerDodger` (owned by
--- `OilmanService`). Any pre-existing `OilmanPlot` clones inside a plot are
--- destroyed defensively so legacy / authored copies do not linger.
function PlotService:_ensurePerPlotDecor(plot: Model)
	local PER_PLOT_TEMPLATES = { "PlotDispatch" }
	local LEGACY_REMOVED_TEMPLATES = { "OilmanPlot" }

	for _, name in ipairs(LEGACY_REMOVED_TEMPLATES) do
		local existing = plot:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return
	end

	local plot01 = self._plotsFolder and self._plotsFolder:FindFirstChild("Plot_01")
	if not (plot01 and plot01:IsA("Model")) then
		warn("[PlotService] Per-plot decor: Plot_01 reference plot not found.")
		return
	end
	local plot01Pivot = plot01:GetPivot().Position
	local thisPivot = plot:GetPivot().Position
	local delta = thisPivot - plot01Pivot

	for _, name in ipairs(PER_PLOT_TEMPLATES) do
		if plot:FindFirstChild(name) then
			continue
		end
		local template = assets:FindFirstChild(name)
		if not template then
			warn(string.format("[PlotService] Per-plot decor: %s missing under ReplicatedStorage.Assets.", name))
			continue
		end
		local clone = template:Clone()
		clone.Name = name
		clone.Parent = plot

		-- Shift authored Plot_01 layout to this plot's frame. Folders cannot `PivotTo`,
		-- so we fall back to translating each top-level Model / BasePart child.
		if delta.Magnitude > 0.001 then
			if clone:IsA("Model") then
				clone:PivotTo(clone:GetPivot() + delta)
			else
				for _, child in ipairs(clone:GetChildren()) do
					if child:IsA("Model") then
						child:PivotTo(child:GetPivot() + delta)
					elseif child:IsA("BasePart") then
						child.CFrame = child.CFrame + delta
					end
				end
			end
		end
	end
end

function PlotService:_ensureCoreMachineAnchorsAndSnap(plot: Model)
	local specs = {
		{ modelName = "Lab Machine", anchorName = "LabMachineAnchor" },
		{ modelName = "BarrelStagingArea", anchorName = "BarrelStagingAnchor" },
	}
	for _, spec in ipairs(specs) do
		local model = plot:FindFirstChild(spec.modelName)
		if model and model:IsA("Model") then
			local anchor = plot:FindFirstChild(spec.anchorName)
			if anchor and not anchor:IsA("BasePart") then
				anchor:Destroy()
				anchor = nil
			end
			if not anchor then
				local a = Instance.new("Part")
				a.Name = spec.anchorName
				a.Size = Vector3.new(1, 1, 1)
				a.Anchored = true
				a.CanCollide = false
				a.CanQuery = false
				a.CanTouch = false
				a.Transparency = 1
				a.CFrame = model:GetPivot()
				a.Parent = plot
				anchor = a
			end
			model:PivotTo(anchor.CFrame)
		end
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
	-- Keep runtime anchor helper fully hidden in-game.
	barrelRoot.Transparency = 1

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
		stackPad.Transparency = 1
		stackPad.Parent = plot
		stackPad.CFrame = barrelRoot.CFrame * CFrame.new(0, -0.65, 0)
	end
	-- Keep helper pad non-visible in runtime.
	stackPad.Transparency = 1

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

		-- Markers are logical anchors, not player-facing visuals.
		marker.Transparency = 1

		if created then
			marker.CFrame = anchor.CFrame * CFrame.new(offset)
		end
	end

	local function hideLegacyMarker(name: string)
		local marker = plot:FindFirstChild(name)
		if marker and marker:IsA("BasePart") then
			marker.Transparency = 1
			marker.CanCollide = false
			marker.CanQuery = false
			marker.CanTouch = false
		end
	end

	ensureMarker("ShipLoadPoint", Vector3.new(0, 3, 20), Color3.fromRGB(80, 160, 220))
	hideLegacyMarker("BoatSpawn")
	hideLegacyMarker("BoatExit")
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

--- World-space title above the plot: server-only `BillboardGui` on `ClaimPad` (all players see every plot name).
function PlotService:_updatePlotNameBillboard(plot: Model, ownerPlayer: Player?)
	local anchor = plot:FindFirstChild("ClaimPad") :: BasePart?
	if not (anchor and anchor:IsA("BasePart")) then
		anchor = getSpawnPart(plot)
	end
	if not anchor then
		return
	end

	local existing = anchor:FindFirstChild(PLOT_OWNER_BILLBOARD_NAME)
	if not ownerPlayer then
		if existing and existing:IsA("BillboardGui") then
			existing.Enabled = false
		end
		return
	end

	local text = string.format("%s's Plot", ownerPlayer.Name)
	local bb: BillboardGui
	if existing and existing:IsA("BillboardGui") then
		bb = existing
	else
		if existing then
			existing:Destroy()
		end
		bb = Instance.new("BillboardGui")
		bb.Name = PLOT_OWNER_BILLBOARD_NAME
		bb.AlwaysOnTop = true
		ResponsiveBillboard.Mark(bb, PLOT_NAME_BILLBOARD_BASE_W, PLOT_NAME_BILLBOARD_BASE_H)
		bb.StudsOffset = Vector3.new(0, PLOT_NAME_BILLBOARD_STUDS_OFFSET_Y, 0)
		bb.MaxDistance = PLOT_NAME_BILLBOARD_MAX_DISTANCE
		bb.LightInfluence = 0
		bb.Parent = anchor
		local tl = Instance.new("TextLabel")
		tl.Name = "PlotNameText"
		tl.Size = UDim2.fromScale(1, 1)
		tl.BackgroundTransparency = 1
		tl.TextColor3 = Color3.fromRGB(255, 252, 245)
		tl.Font = Enum.Font.Merriweather
		tl.TextStrokeTransparency = 0.4
		tl.TextStrokeColor3 = Color3.fromRGB(15, 18, 28)
		tl.TextScaled = true
		tl.Parent = bb
		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = PLOT_NAME_TEXT_MAX_SIZE
		tsc.MinTextSize = PLOT_NAME_TEXT_MIN_SIZE
		tsc.Parent = tl
	end
	bb.Enabled = true
	bb.StudsOffset = Vector3.new(0, PLOT_NAME_BILLBOARD_STUDS_OFFSET_Y, 0)
	-- Live cleanup: legacy plates from older code paths may be missing the
	-- responsive base-size attributes (`ResponsiveBillboard.EnsureMarked`
	-- only stamps if absent — won't clobber a value already in place) and
	-- may still have the old `MaxDistance = 380` (visible across the whole
	-- map). Re-apply the proximity gate; the client controller picks up
	-- the responsive Size on the next viewport tick.
	ResponsiveBillboard.EnsureMarked(bb, PLOT_NAME_BILLBOARD_BASE_W, PLOT_NAME_BILLBOARD_BASE_H)
	if bb.MaxDistance ~= PLOT_NAME_BILLBOARD_MAX_DISTANCE then
		bb.MaxDistance = PLOT_NAME_BILLBOARD_MAX_DISTANCE
	end
	local tl = bb:FindFirstChild("PlotNameText", true)
	if tl and tl:IsA("TextLabel") then
		tl.Font = Enum.Font.Merriweather
		tl.Text = text
		local tsc = tl:FindFirstChildOfClass("UITextSizeConstraint")
		if tsc then
			tsc.MaxTextSize = PLOT_NAME_TEXT_MAX_SIZE
			tsc.MinTextSize = PLOT_NAME_TEXT_MIN_SIZE
		end
	end
end

function PlotService:_claimRandomOpenPlot(userId: number): Model?
	local openByPlotId = {}
	local fallbackOpenPlots = {}
	for _, plot in ipairs(self:_getPlotsSorted()) do
		local owner = plot:GetAttribute("OwnerUserId")
		if typeof(owner) ~= "number" or owner == 0 then
			local plotId = getPlotId(plot)
			openByPlotId[plotId] = plot
			table.insert(fallbackOpenPlots, plot)
		end
	end

	local selected = nil
	for _, plotId in ipairs(PREFERRED_PLOT_CLAIM_ORDER) do
		selected = openByPlotId[plotId]
		if selected then
			break
		end
	end

	if not selected then
		selected = fallbackOpenPlots[1]
	end
	if not selected then
		return nil
	end

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

		-- CharacterAutoLoads=false: we must explicitly respawn on Died, otherwise
		-- the player gets stuck on the death screen (or Roblox falls back to
		-- default spawn = world origin = mid-ocean on this map).
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				--- DIAG: capture death context (where they died) — use this to
				--- correlate with KillZone hits, ship voyage flows, etc.
				local diedHrp = character:FindFirstChild("HumanoidRootPart")
				local diedPos = if diedHrp and diedHrp:IsA("BasePart") then diedHrp.Position else Vector3.zero
				local seatPart = humanoid.SeatPart
				DevLog.log(string.format(
					"[PlotService.Died] %s died at pos=(%.1f,%.1f,%.1f) seatPart=%s state=%s",
					player.Name, diedPos.X, diedPos.Y, diedPos.Z,
					tostring(seatPart and seatPart:GetFullName() or "nil"),
					tostring(humanoid:GetState())
				))
				task.wait(Constants.RespawnDelayAfterDeathSeconds)
				if player.Parent then
					DevLog.log(string.format("[PlotService.Died] %s LoadCharacter()", player.Name))
					player:LoadCharacter()
				end
			end)
		end
	end)
end

function PlotService:_releasePlot(plot: Model?)
	if not plot then
		return
	end
	plot:SetAttribute("OwnerUserId", 0)
	self:_refreshPlotVisual(plot)
	resetUnclaimedPlotTankUi(plot)
	self:_updatePlotNameBillboard(plot, nil)
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

	local hum = character:FindFirstChildOfClass("Humanoid")
	local wasSitting = hum ~= nil and hum.SeatPart ~= nil
	CharacterTeleport.unseatIfSitting(character)

	--- Preserve the ClaimPad's authored rotation so the character spawns facing whichever
	--- way the pad is pointed (currently 180° → looking at the Delivery Man). Using
	--- `CFrame.new(x,y,z)` here would discard rotation and the player would always land
	--- facing world -Z. `CFrame.Rotation + Vector3` keeps the pad's LookVector and just
	--- translates to the lifted XYZ.
	local target = spawnPart.CFrame.Rotation + Vector3.new(
		spawnPart.Position.X,
		math.max(14, spawnPart.Position.Y + 8),
		spawnPart.Position.Z
	)

	--- DO NOT add `SetNetworkOwner(nil)` here — see the matching comment in
	--- `CharacterTeleport.teleportWithUnseat`. Stealing net ownership presents
	--- as visible movement lag, ragdoll/Freefall pose on land, and the
	--- character clipping into the floor while server-side gravity runs.

	local prevPos = hrp.Position
	local prevVel = hrp.AssemblyLinearVelocity

	-- Set HRP CFrame directly — more reliable than PivotTo during character load.
	hrp.CFrame = target
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	DevLog.log(string.format(
		"[teleport] path=PlotService:spawnClaim seated=%s prevPos=(%.1f,%.1f,%.1f) prevVel=(%.1f,%.1f,%.1f) target=(%.1f,%.1f,%.1f)",
		tostring(wasSitting),
		prevPos.X, prevPos.Y, prevPos.Z,
		prevVel.X, prevVel.Y, prevVel.Z,
		target.X, target.Y, target.Z
	))

	--- Camera snap on spawn. Originally I assumed Roblox would auto-rotate the default
	--- follow camera behind the new character on `CharacterAdded`, but in this game the
	--- camera keeps its previous yaw — same failure mode as the live `PivotTo` teleport-
	--- home path. Reuse the same `TeleportHomeApplied` signal so `HudTeleportRouter`
	--- runs `snapCameraBehindCharacter` and the player ends up looking at the Delivery
	--- Man over their own shoulder.
	---
	--- Why fire **twice** (immediate + after the safety re-teleport):
	---   • t=0: covers in-session **respawn** — `HudTeleportRouter` is already required
	---     and `OnClientEvent` is connected, so this snap lands.
	---   • t=0.4 (after the 0.3s safety re-teleport): covers **initial join** — on the
	---     very first spawn the client's `HudTeleportRouter` may not have required /
	---     connected `OnClientEvent` yet, so the t=0 fire would silently drop. By 0.4s
	---     the client has bootstrapped in the common case.
	--- Both fires target the same CFrame, so when both land it's a no-op refinement
	--- (`cam.CFrame` is set to the same value twice).
	local snapEvent = getTeleportHomeAppliedEvent()
	if snapEvent then
		snapEvent:FireClient(player, target)
	end

	--- Engine spawn-pivot race window. After our `CharacterAdded` teleport the engine's own
	--- spawn pipeline runs its default pivot 1-2 frames later and slams the character to
	--- `(0, 103, 0)` (the "no SpawnLocation" fallback — we disabled all SpawnLocations in
	--- `Start()` so imported decor models can't hijack spawn). A single `task.delay(0.3, …)`
	--- safety re-teleport corrected the position but left a visible ~300ms flash of the
	--- character suspended over world origin.
	---
	--- Tight poll instead: check on `Heartbeat` for at most ~150ms (~9 frames at 60Hz).
	--- Re-snap **only** when the engine actually drifts us (≥10 studs) and bail the moment
	--- we see two consecutive "stable" frames. The 1-frame visible drift (~16ms) is
	--- imperceptible, but the loop still terminates fast enough that we don't repeat the
	--- multi-respawn stutter the longer hold loop caused before.
	task.spawn(function()
		local stableFrames = 0
		local maxFrames = 9
		local logged = false
		for _ = 1, maxFrames do
			RunService.Heartbeat:Wait()
			if not (hrp.Parent and character.Parent and player.Parent) then
				return
			end
			local drift = (hrp.Position - target.Position).Magnitude
			if drift > 10 then
				if not logged then
					logged = true
					DevLog.log(string.format(
						"[PlotService.spawnClaim+poll] %s DRIFTED %.1f studs from target — re-teleporting (curPos=(%.1f,%.1f,%.1f) curVel=(%.1f,%.1f,%.1f))",
						player.Name, drift,
						hrp.Position.X, hrp.Position.Y, hrp.Position.Z,
						hrp.AssemblyLinearVelocity.X, hrp.AssemblyLinearVelocity.Y, hrp.AssemblyLinearVelocity.Z
					))
				end
				hrp.CFrame = target
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				stableFrames = 0
			else
				stableFrames += 1
				if stableFrames >= 2 then
					return
				end
			end
		end
	end)

	--- DIAG: 1.2s post-spawn audit. If the character has drifted significantly
	--- from the claim pad (kill-plane Y or large XZ distance), log it loudly so
	--- the next death-loop repro tells us whether the server really thinks the
	--- character is at the pad (= client-side visual issue) or the character
	--- actually slid off / got pushed away (= a different service is moving it).
	task.delay(1.2, function()
		if not (hrp.Parent and character.Parent and player.Parent) then
			return
		end
		local drift = (hrp.Position - target.Position).Magnitude
		local belowMap = hrp.Position.Y < (Constants.KillZoneUnderMapCenterY + Constants.KillZoneUnderMapThicknessY)
		if drift > 25 or belowMap then
			DevLog.log(string.format(
				"[PlotService.spawnClaim+1.2s] %s DRIFTED %.1f studs (belowKillZone=%s) — pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) targetWasY=%.1f",
				player.Name, drift, tostring(belowMap),
				hrp.Position.X, hrp.Position.Y, hrp.Position.Z,
				hrp.AssemblyLinearVelocity.X, hrp.AssemblyLinearVelocity.Y, hrp.AssemblyLinearVelocity.Z,
				target.Position.Y
			))
		end
	end)

	task.delay(0.4, function()
		if not (hrp.Parent and character.Parent and player.Parent) then
			return
		end
		local ev = getTeleportHomeAppliedEvent()
		if ev then
			ev:FireClient(player, target)
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
	self:_updatePlotNameBillboard(plot, player)
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
