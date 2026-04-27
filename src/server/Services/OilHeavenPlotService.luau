--!strict
--- `OilHeavenPlotService` — clones the `ServerStorage.OilHeavenTemplate` model
--- and positions it at Y=10000 above each player's main plot on first access.
--- Destroyed on `PlayerRemoving`.
---
--- The template is authored in Studio (editable in Explorer) and contains:
---   TileGrid/   — 108 tile Parts with Section, Row, Col, RebirthRequired attributes
---   SkyBox/     — 6-wall Neon enclosure simulating heaven
---   BasePlatform — floating island slab
---   ClaimPad    — invisible spawn point (PrimaryPart)
---
--- Tiles are non-interactable for now; mechanics will be layered on later.
--- Locked sections (rebirth-gated) are visible but darkened with barriers.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilHeavenConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilHeavenConfig"))

local OilHeavenPlotService = {}

function OilHeavenPlotService:Init(plotService: any, oilStateService: any)
	self._plotService = plotService
	self._oilStateService = oilStateService
	self._generatedPlots = {} :: { [number]: Model } -- userId -> cloned Model
	self._connections = {} :: { RBXScriptConnection }
	self._template = nil :: Model?
end

function OilHeavenPlotService:Start()
	-- Grab the authored template from ServerStorage
	self._template = ServerStorage:FindFirstChild("OilHeavenTemplate")
	if not self._template then
		warn("[OilHeavenPlotService] Missing ServerStorage.OilHeavenTemplate — Oil Heaven will not work.")
	end

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:CleanupPlot(player.UserId)
	end))
end

--- Returns the cached plot or clones one on first access.
function OilHeavenPlotService:GetOrCreatePlot(userId: number): Model?
	local existing = self._generatedPlots[userId]
	if existing and existing.Parent then
		return existing
	end

	if not self._template then
		warn("[OilHeavenPlotService] No template — cannot create plot for", userId)
		return nil
	end

	local mainPlot = self._plotService:GetOwnedPlot(userId)
	if not mainPlot then
		warn("[OilHeavenPlotService] No main plot for userId", userId)
		return nil
	end

	local mainPivot = mainPlot:GetPivot()
	local ohCenter = mainPivot.Position + Vector3.new(0, Constants.OilHeavenHeightOffset, 0)

	-- Clone template and reposition
	local plot = self._template:Clone()
	plot.Name = string.format("OilHeavenPlot_%d", userId)

	-- Template is authored at origin (0,0,0). Shift everything to ohCenter.
	local templatePivot = plot:GetPivot()
	local delta = ohCenter - templatePivot.Position
	for _, descendant in ipairs(plot:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + delta
		end
	end

	-- Apply lock state based on player's rebirth count
	self:_applyLockState(plot, userId)

	plot.Parent = workspace
	self._generatedPlots[userId] = plot
	return plot
end

function OilHeavenPlotService:GetSpawnCFrame(userId: number): CFrame?
	local plot = self._generatedPlots[userId]
	if not plot or not plot.Parent then
		return nil
	end
	local claimPad = plot:FindFirstChild("ClaimPad")
	if not claimPad or not claimPad:IsA("BasePart") then
		return nil
	end
	return claimPad.CFrame + Vector3.new(0, OilHeavenConfig.SpawnHeightOffset, 0)
end

function OilHeavenPlotService:CleanupPlot(userId: number)
	local plot = self._generatedPlots[userId]
	if plot then
		plot:Destroy()
		self._generatedPlots[userId] = nil
	end
end

--- Called after a rebirth to refresh which sections are locked/unlocked.
function OilHeavenPlotService:RefreshUnlocks(userId: number)
	local plot = self._generatedPlots[userId]
	if not plot or not plot.Parent then
		return
	end
	self:_applyLockState(plot, userId)
end

function OilHeavenPlotService:Stop()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)

	for userId, _ in pairs(self._generatedPlots) do
		self:CleanupPlot(userId)
	end
end

--------------------------------------------------------------------------------
-- Private
--------------------------------------------------------------------------------

--- Applies locked/unlocked visuals to tiles and builds barriers based on rebirth count.
function OilHeavenPlotService:_applyLockState(plot: Model, userId: number)
	local rebirthCount = self._oilStateService:GetRebirthCount(userId)
	local tileGrid = plot:FindFirstChild("TileGrid")

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

--- Builds barrier walls at the boundary of the first locked section.
function OilHeavenPlotService:_buildBarriers(plot: Model, rebirthCount: number)
	local tileSize = OilHeavenConfig.TileSize
	local cols = OilHeavenConfig.Columns
	local rowsPerSec = OilHeavenConfig.RowsPerSection
	local gridWidth = cols * tileSize

	local claimPad = plot:FindFirstChild("ClaimPad")
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
			break -- only need the first barrier
		end
	end
end

return OilHeavenPlotService
