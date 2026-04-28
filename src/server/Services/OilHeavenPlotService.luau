--!strict
--- `OilHeavenPlotService` — pre-places 8 Oil Heaven sky plots + 1 shared
--- sky box at server start, positioned directly above each main beach plot
--- at Y=10000. Players are 1-to-1 assigned: Plot_03 on the beach =
--- OilHeavenPlot_03 in the sky. No cloning per player, no destroying on leave.
---
--- Template structure in ServerStorage.OilHeavenTemplate:
---   SkyBox/      — shared white box enclosure (cloned once)
---   Clouds1/     — shared cloud decor (cloned once)
---   Clouds2/     — shared cloud decor (cloned once)
---   Plot1/       — per-player plot (cloned 8 times), contains:
---     LandingPlotHeaven/ — spawn area with ClaimPad
---     SpecialPlot/       — tile grid with sections

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilHeavenConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilHeavenConfig"))

local OilHeavenPlotService = {}
local HEAVEN_PLOT_EXTRA_SLOT_SPACING = 96

local function getPlotNumber(plotModel: Model): number
	local plotIdAttr = plotModel:GetAttribute("PlotId")
	if typeof(plotIdAttr) == "number" then
		return plotIdAttr
	end
	return tonumber(string.match(plotModel.Name, "(%d+)")) or 0
end

local function translateDescendants(root: Instance, delta: Vector3)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + delta
		end
	end
end

local function buildPlotOrderMap(plotsFolder: Instance): { [number]: number }
	local orderedPlots = {}
	for _, plot in ipairs(plotsFolder:GetChildren()) do
		if plot:IsA("Model") then
			table.insert(orderedPlots, plot)
		end
	end

	table.sort(orderedPlots, function(a, b)
		return a:GetPivot().Position.X < b:GetPivot().Position.X
	end)

	local orderByPlotNumber: { [number]: number } = {}
	for index, plot in ipairs(orderedPlots) do
		local plotNumber = getPlotNumber(plot)
		if plotNumber ~= 0 then
			orderByPlotNumber[plotNumber] = index
		end
	end

	return orderByPlotNumber
end

local function getSkyPlotSpreadOffset(plotNumber: number, orderedPlotCount: number, orderByPlotNumber: { [number]: number }): Vector3
	local orderIndex = orderByPlotNumber[plotNumber]
	if not orderIndex then
		return Vector3.zero
	end

	local midpoint = (orderedPlotCount + 1) * 0.5
	local centeredIndex = orderIndex - midpoint
	return Vector3.new(centeredIndex * HEAVEN_PLOT_EXTRA_SLOT_SPACING, 0, 0)
end

function OilHeavenPlotService:Init(plotService: any, oilStateService: any)
	self._plotService = plotService
	self._oilStateService = oilStateService
	self._assignedByUserId = {} :: { [number]: Model }
	self._skyPlots = {} :: { [number]: Model } -- plotNumber -> sky plot model
	self._skyBox = nil :: Model?
	self._connections = {} :: { RBXScriptConnection }
	self._template = nil :: Model?
end

function OilHeavenPlotService:Start()
	self._template = ServerStorage:FindFirstChild("OilHeavenTemplate")
	if not self._template then
		warn("[OilHeavenPlotService] Missing ServerStorage.OilHeavenTemplate — Oil Heaven will not work.")
		return
	end

	local plotTemplate = self._template:FindFirstChild("Plot1")
	if not plotTemplate then
		warn("[OilHeavenPlotService] OilHeavenTemplate missing Plot1.")
		return
	end

	-- Clone shared sky box + clouds once, positioned above the center of all plots
	local plotsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Plots")
	if not plotsFolder then
		warn("[OilHeavenPlotService] Workspace.Map.Plots not found.")
		return
	end

	-- Find center of all main plots
	local sumX, sumY, sumZ, plotCount = 0, 0, 0, 0
	for _, plot in ipairs(plotsFolder:GetChildren()) do
		if plot:IsA("Model") then
			local pivot = plot:GetPivot()
			sumX += pivot.Position.X
			sumY += pivot.Position.Y
			sumZ += pivot.Position.Z
			plotCount += 1
		end
	end
	local centerX = if plotCount > 0 then sumX / plotCount else 0
	local centerY = if plotCount > 0 then sumY / plotCount else 0
	local centerZ = if plotCount > 0 then sumZ / plotCount else 0
	local orderByPlotNumber = buildPlotOrderMap(plotsFolder)
	local plotTemplatePivot = plotTemplate:GetPivot().Position
	local sharedDelta = Vector3.new(
		centerX,
		(centerY + Constants.OilHeavenHeightOffset) - plotTemplatePivot.Y,
		centerZ
	)

	-- Clone and place shared elements (SkyBox, Clouds)
	for _, childName in ipairs({ "SkyBox", "Clouds1", "Clouds2" }) do
		local source = self._template:FindFirstChild(childName)
		if source then
			local clone = source:Clone()
			clone.Name = childName
			translateDescendants(clone, sharedDelta)
			if childName == "SkyBox" then
				for _, descendant in ipairs(clone:GetDescendants()) do
					if descendant:IsA("BasePart") then
						descendant.Transparency = 1
						descendant.CastShadow = false
					end
				end
			end
			clone.Parent = workspace
			if childName == "SkyBox" then
				self._skyBox = clone
			end
		end
	end

	-- Clone Plot1 for each of the 8 main plots
	for _, mainPlot in ipairs(plotsFolder:GetChildren()) do
		if not mainPlot:IsA("Model") then continue end

		local plotNumber = getPlotNumber(mainPlot)
		if plotNumber == 0 then continue end

		local mainPivot = mainPlot:GetPivot()
		local spreadOffset = getSkyPlotSpreadOffset(plotNumber, plotCount, orderByPlotNumber)
		local skyCenter = mainPivot.Position + Vector3.new(
			spreadOffset.X,
			Constants.OilHeavenHeightOffset,
			spreadOffset.Z
		)

		local skyPlot = plotTemplate:Clone()
		skyPlot.Name = string.format("OilHeavenPlot_%02d", plotNumber)

		-- Shift all parts from template origin to sky position
		local templatePivot = skyPlot:GetPivot()
		local delta = skyCenter - templatePivot.Position
		translateDescendants(skyPlot, delta)

		skyPlot:SetAttribute("OwnerUserId", 0)
		skyPlot:SetAttribute("PlotNumber", plotNumber)
		skyPlot.Parent = workspace

		self._skyPlots[plotNumber] = skyPlot
	end

	-- Assign sky plots when main plots are assigned (1-to-1)
	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, mainPlot: Model)
		local plotNumber = getPlotNumber(mainPlot)
		local previousPlot = self._assignedByUserId[userId]
		if previousPlot and previousPlot.Parent and previousPlot ~= self._skyPlots[plotNumber] then
			previousPlot:SetAttribute("OwnerUserId", 0)
		end

		local skyPlot = self._skyPlots[plotNumber]
		if skyPlot then
			self._assignedByUserId[userId] = skyPlot
			skyPlot:SetAttribute("OwnerUserId", userId)
			self:_applyLockState(skyPlot, userId)
		end
	end))

	-- Release sky plot on leave (don't destroy — just unassign)
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		local skyPlot = self._assignedByUserId[player.UserId]
		if skyPlot then
			skyPlot:SetAttribute("OwnerUserId", 0)
			self._assignedByUserId[player.UserId] = nil
		end
	end))

	-- Catch up with players already in game
	for _, player in ipairs(Players:GetPlayers()) do
		local mainPlot = self._plotService:GetOwnedPlot(player.UserId)
		if mainPlot then
			local plotNumber = getPlotNumber(mainPlot)
			local skyPlot = self._skyPlots[plotNumber]
			if skyPlot then
				self._assignedByUserId[player.UserId] = skyPlot
				skyPlot:SetAttribute("OwnerUserId", player.UserId)
				self:_applyLockState(skyPlot, player.UserId)
			end
		end
	end
end

--- Returns the assigned sky plot for a player (nil if none).
function OilHeavenPlotService:GetAssignedPlot(userId: number): Model?
	return self._assignedByUserId[userId]
end

function OilHeavenPlotService:GetSpawnCFrame(userId: number): CFrame?
	local plot = self._assignedByUserId[userId]
	if not plot or not plot.Parent then
		return nil
	end
	-- ClaimPad is inside Plot1.LandingPlotHeaven.ClaimPad
	local landing = plot:FindFirstChild("LandingPlotHeaven")
	local claimPad = landing and landing:FindFirstChild("ClaimPad")
	if not claimPad or not claimPad:IsA("BasePart") then
		-- Fallback: search recursively
		claimPad = plot:FindFirstChild("ClaimPad", true)
	end
	if not claimPad or not claimPad:IsA("BasePart") then
		return nil
	end
	return claimPad.CFrame + Vector3.new(0, OilHeavenConfig.SpawnHeightOffset, 0)
end

--- Called after a rebirth to refresh which sections are locked/unlocked.
function OilHeavenPlotService:RefreshUnlocks(userId: number)
	local plot = self._assignedByUserId[userId]
	if not plot or not plot.Parent then
		return
	end
	self:_applyLockState(plot, userId)
end

function OilHeavenPlotService:GetSkyBox(): Instance?
	return self._skyBox
end

function OilHeavenPlotService:Stop()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

--------------------------------------------------------------------------------
-- Private
--------------------------------------------------------------------------------

function OilHeavenPlotService:_applyLockState(plot: Model, userId: number)
	local rebirthCount = self._oilStateService:GetRebirthCount(userId)

	-- TileGrid is inside SpecialPlot
	local specialPlot = plot:FindFirstChild("SpecialPlot")
	local tileGrid = specialPlot and specialPlot:FindFirstChild("TileGrid")

	if tileGrid then
		for _, tile in ipairs(tileGrid:GetChildren()) do
			if tile:IsA("BasePart") then
				local required = tile:GetAttribute("RebirthRequired")
				if typeof(required) == "number" then
					local locked = rebirthCount < required
					tile:SetAttribute("Locked", locked)
					if locked then
						tile.Transparency = OilHeavenConfig.LockedTileTransparency
						tile.Material = OilHeavenConfig.LockedTileMaterial
					else
						tile.Transparency = 0
						tile.Material = OilHeavenConfig.UnlockedTileMaterial
					end
				end
			end
		end
	end

	-- Rebuild barriers
	local oldBarriers = plot:FindFirstChild("Barriers")
	if oldBarriers then
		oldBarriers:Destroy()
	end
	self:_buildBarriers(plot, rebirthCount)
end

function OilHeavenPlotService:_buildBarriers(plot: Model, rebirthCount: number)
	local tileSize = OilHeavenConfig.TileSize
	local cols = OilHeavenConfig.Columns
	local rowsPerSec = OilHeavenConfig.RowsPerSection
	local gridWidth = cols * tileSize

	-- Find ClaimPad for position reference
	local claimPad = plot:FindFirstChild("ClaimPad", true)
	if not claimPad or not claimPad:IsA("BasePart") then
		return
	end

	local s1CenterRow = math.ceil(rowsPerSec / 2)
	local s1CenterCol = math.ceil(cols / 2)
	local gridOriginX = claimPad.Position.X - (s1CenterCol - 1) * tileSize
	local gridOriginZ = claimPad.Position.Z - (s1CenterRow - 1) * tileSize
	local tileY = claimPad.Position.Y - 1

	local barriers = Instance.new("Folder")
	barriers.Name = "Barriers"
	barriers.Parent = plot

	for _, section in ipairs(OilHeavenConfig.Sections) do
		if rebirthCount < section.rebirthRequired then
			local sectionIndex = table.find(OilHeavenConfig.Sections, section)
			if not sectionIndex then break end
			local rowOffset = (sectionIndex - 1) * rowsPerSec
			local barrierZ = gridOriginZ + (rowOffset - 0.5) * tileSize
			local barrierX = gridOriginX + (gridWidth / 2) - (tileSize / 2)

			local wall = Instance.new("Part")
			wall.Name = string.format("Barrier_%s", section.id)
			wall.Anchored = true
			wall.CanCollide = true
			wall.Size = Vector3.new(gridWidth, OilHeavenConfig.BarrierHeight, OilHeavenConfig.BarrierThickness)
			wall.CFrame = CFrame.new(barrierX, tileY + OilHeavenConfig.BarrierHeight / 2, barrierZ)
			wall.Color = OilHeavenConfig.BarrierColor
			wall.Transparency = OilHeavenConfig.BarrierTransparency
			wall.Material = Enum.Material.ForceField
			wall.TopSurface = Enum.SurfaceType.Smooth
			wall.BottomSurface = Enum.SurfaceType.Smooth
			wall.Parent = barriers
			break
		end
	end
end

return OilHeavenPlotService
