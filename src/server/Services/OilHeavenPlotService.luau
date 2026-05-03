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

local function ensureTileBaseStyleStored(tile: BasePart)
	if tile:GetAttribute("HeavenBaseTransparency") == nil then
		tile:SetAttribute("HeavenBaseTransparency", tile.Transparency)
	end
	if tile:GetAttribute("HeavenBaseMaterial") == nil then
		tile:SetAttribute("HeavenBaseMaterial", tile.Material.Name)
	end
end

local function restoreTileBaseStyle(tile: BasePart)
	local baseTransparency = tile:GetAttribute("HeavenBaseTransparency")
	if typeof(baseTransparency) == "number" then
		tile.Transparency = baseTransparency
	end
	local baseMaterialName = tile:GetAttribute("HeavenBaseMaterial")
	if typeof(baseMaterialName) == "string" and Enum.Material[baseMaterialName] ~= nil then
		tile.Material = Enum.Material[baseMaterialName]
	end
end

local function setQMarkVisible(tile: BasePart, visible: boolean)
	local qmark = tile:FindFirstChild("QMark")
	if not qmark then
		return
	end
	for _, descendant in ipairs(qmark:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if visible then 0 else 1
		end
	end
end

local RARITY_COLORS = {
	Common = Color3.fromRGB(200, 200, 200),
	Rare = Color3.fromRGB(0, 150, 255),
	Epic = Color3.fromRGB(180, 0, 255),
	Legendary = Color3.fromRGB(255, 170, 0),
	Mythic = Color3.fromRGB(255, 50, 50),
}

--- Reshapes the tile grid from the template's 6×3 layout to the configured
--- RowsPerSection×Columns layout with gaps between sections.
--- Uses ClaimPad CFrame for orientation so the grid matches the plot's rotation.
local function reshapeTileGrid(plot: Model)
	local specialPlot = plot:FindFirstChild("SpecialPlot")
	local tileGrid = specialPlot and specialPlot:FindFirstChild("TileGrid")
	if not tileGrid then return end

	local claimPad = plot:FindFirstChild("ClaimPad", true)
	if not claimPad or not claimPad:IsA("BasePart") then return end

	local tileSize = OilHeavenConfig.TileSize
	local cols = OilHeavenConfig.Columns
	local rowsPerSec = OilHeavenConfig.RowsPerSection
	local sectionGap = OilHeavenConfig.SectionGap or 0

	local s1CenterRow = math.ceil(rowsPerSec / 2)
	local s1CenterCol = math.ceil(cols / 2)
	local claimCF = claimPad.CFrame

	-- Group tiles by section (RebirthRequired value)
	local tilesByReq: { [number]: { BasePart } } = {}
	for _, tile in ipairs(tileGrid:GetChildren()) do
		if tile:IsA("BasePart") then
			local req = tile:GetAttribute("RebirthRequired")
			if typeof(req) == "number" then
				if not tilesByReq[req] then tilesByReq[req] = {} end
				table.insert(tilesByReq[req], tile)
			end
		end
	end

	for sectionIdx, sectionCfg in ipairs(OilHeavenConfig.Sections) do
		local tiles = tilesByReq[sectionCfg.rebirthRequired] or {}

		-- Sort tiles in ClaimPad's local space (local Z then local X)
		table.sort(tiles, function(a, b)
			local aLocal = claimCF:PointToObjectSpace(a.Position)
			local bLocal = claimCF:PointToObjectSpace(b.Position)
			if math.abs(aLocal.Z - bLocal.Z) > 1 then
				return aLocal.Z < bLocal.Z
			end
			return aLocal.X < bLocal.X
		end)

		local maxTiles = rowsPerSec * cols
		for i = maxTiles + 1, #tiles do
			tiles[i]:Destroy()
		end

		-- Compute section offset in ClaimPad's local Z + staircase Y
		local sectionLocalZ = (sectionIdx - 1) * (rowsPerSec * tileSize + sectionGap)
		local sectionHeight = (sectionIdx - 1) * 8 -- floating staircase: +8 studs per section

		for i = 1, math.min(maxTiles, #tiles) do
			local row = math.ceil(i / cols)
			local col = ((i - 1) % cols) + 1

			local localX = (col - s1CenterCol) * tileSize
			local localZ = (row - s1CenterRow) * tileSize + sectionLocalZ
			local targetPos = (claimCF * CFrame.new(localX, -1 + sectionHeight, localZ)).Position

			local moveDelta = targetPos - tiles[i].Position
			tiles[i].CFrame = tiles[i].CFrame + moveDelta
			-- Close grid-line gaps: ensure tile fills the full cell
			tiles[i].Size = Vector3.new(tileSize, tiles[i].Size.Y, tileSize)
			for _, desc in ipairs(tiles[i]:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.CFrame = desc.CFrame + moveDelta
				end
			end
		end

	end
end

local function showRewardOnTile(tile: BasePart, displayText: string, rarity: string?)
	setQMarkVisible(tile, false)

	-- Compute offset from tile center to QMark mesh position
	local studsOffset = Vector3.new(0, 2, 0)
	local qmark = tile:FindFirstChild("QMark")
	if qmark then
		local meshPart = qmark:FindFirstChildWhichIsA("BasePart", true)
		if meshPart then
			studsOffset = meshPart.Position - tile.Position
		end
	end

	local gui = tile:FindFirstChild("HeavenRewardGui")
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = "HeavenRewardGui"
		gui.Size = UDim2.new(8, 0, 4, 0)
		gui.StudsOffset = studsOffset
		gui.Adornee = tile
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = math.huge
		gui.Parent = tile

		local label = Instance.new("TextLabel")
		label.Name = "RewardLabel"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		--- Merriweather is the canonical OilHeaven / OTS panel font (matches
		--- `ShipOilPanel.PANEL_FONT`, `PlotService` floor labels, etc.).
		--- `Enum.Font.MerriweatherBold` does NOT exist in the legacy font set —
		--- only the regular weight is enum-accessible. For bolder weights swap
		--- to `FontFace = Font.new(... Bold)` later if design wants it.
		label.Font = Enum.Font.Merriweather
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		label.TextScaled = true
		label.TextWrapped = true
		label.Parent = gui

	else
		gui.StudsOffset = studsOffset
	end

	local color = RARITY_COLORS[rarity or "Common"] or RARITY_COLORS.Common
	local label = gui:FindFirstChild("RewardLabel")
	if label then
		label.Text = displayText
		label.TextColor3 = color
	end
end

local function hideRewardOnTile(tile: BasePart)
	setQMarkVisible(tile, true)
	local gui = tile:FindFirstChild("HeavenRewardGui")
	if gui then gui:Destroy() end
	-- Clean up legacy markers from previous approaches
	local oldMarker = tile:FindFirstChild("HeavenRewardMarker")
	if oldMarker then oldMarker:Destroy() end
	local oldAnchor = tile:FindFirstChild("HeavenRewardAnchor")
	if oldAnchor then oldAnchor:Destroy() end
end

function OilHeavenPlotService:Init(plotService: any, oilStateService: any)
	self._plotService = plotService
	self._oilStateService = oilStateService
	self._heavenDrillService = nil :: any
	self._assignedByUserId = {} :: { [number]: Model }
	self._skyPlots = {} :: { [number]: Model } -- plotNumber -> sky plot model
	self._skyBox = nil :: Model?
	self._connections = {} :: { RBXScriptConnection }
	self._template = nil :: Model?
end

function OilHeavenPlotService:SetHeavenDrillService(heavenDrillService: any)
	self._heavenDrillService = heavenDrillService
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
	if self._heavenDrillService and typeof(self._heavenDrillService.RefreshPlayerPrompts) == "function" then
		self._heavenDrillService:RefreshPlayerPrompts(userId)
	end
end

function OilHeavenPlotService:GetSkyBox(): Instance?
	return self._skyBox
end

function OilHeavenPlotService:GetAllSkyPlots(): { [number]: Model }
	return self._skyPlots
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
				ensureTileBaseStyleStored(tile)
				local required = tile:GetAttribute("RebirthRequired")
				if typeof(required) == "number" then
					local locked = rebirthCount < required
					tile:SetAttribute("Locked", locked)
					if locked then
						tile.Transparency = OilHeavenConfig.LockedTileTransparency
						tile.Material = OilHeavenConfig.LockedTileMaterial
					else
						restoreTileBaseStyle(tile)
					end
					self:_applyTileRewardVisual(tile, userId)
				end
			end
		end
	end

	-- Section barriers were removed — the ForceField walls between rebirth-
	-- gated tile sections were visually disruptive (always tinted green by
	-- the ForceField material regardless of `BarrierColor`). We still nuke
	-- any pre-existing `Barriers` folder on each refresh so plots cloned
	-- from saves with the old barrier layout get cleaned up. `_buildBarriers`
	-- is left below as dead code in case the gating visual returns later;
	-- remove it if the design lands.
	local oldBarriers = plot:FindFirstChild("Barriers")
	if oldBarriers then
		oldBarriers:Destroy()
	end
end

function OilHeavenPlotService:_applyTileRewardVisual(tile: BasePart, userId: number)
	local reward = self._oilStateService:GetOilHeavenTileReward(userId, tile.Name)
	local claimed = self._oilStateService:IsOilHeavenTileDrilled(userId, tile.Name)
	if reward then
		showRewardOnTile(tile, reward.displayText, reward.rarity)
	elseif claimed then
		showRewardOnTile(tile, "CLAIMED", "Common")
	else
		hideRewardOnTile(tile)
	end
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
	local claimCF = claimPad.CFrame
	local sectionGap = OilHeavenConfig.SectionGap or 0

	local barriers = Instance.new("Folder")
	barriers.Name = "Barriers"
	barriers.Parent = plot

	for _, section in ipairs(OilHeavenConfig.Sections) do
		if rebirthCount < section.rebirthRequired then
			local sectionIndex = table.find(OilHeavenConfig.Sections, section)
			if not sectionIndex then break end
			-- Barrier in the gap before this section, in ClaimPad local space
			local sectionLocalZ = (sectionIndex - 1) * (rowsPerSec * tileSize + sectionGap)
			local barrierLocalZ = sectionLocalZ - (s1CenterRow - 1) * tileSize - sectionGap * 0.5
			local barrierCF = claimCF * CFrame.new(0, OilHeavenConfig.BarrierHeight / 2 - 1, barrierLocalZ)

			local wall = Instance.new("Part")
			wall.Name = string.format("Barrier_%s", section.id)
			wall.Anchored = true
			wall.CanCollide = true
			wall.Size = Vector3.new(gridWidth, OilHeavenConfig.BarrierHeight, OilHeavenConfig.BarrierThickness)
			wall.CFrame = barrierCF
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
