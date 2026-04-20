--!strict
-- World-space raised border on the FTUE tutorial tile (**`WaitDrillOil_WIP`** drill/pipe/pump legs): reads
-- `FtueRestrictDrillCellKey` on the player (drills are the only FTUE-restricted action).

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))

local FtueTutorialTileHighlight = {}

local WALL_HEIGHT = 3.4
local WALL_THICK = 0.22
local EDGE_COLOR = Color3.fromRGB(255, 230, 55)

local SUB_TILE_SIZE = 8

local function staticGrid()
	local sectionCols = OilConfig.Chunks.GridCols
	local sectionRows = OilConfig.Chunks.GridRows
	local sectionSize = OilConfig.Chunks.Size
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE)
	return {
		sectionCols = sectionCols,
		sectionRows = sectionRows,
		sectionSize = sectionSize,
		subTilesPerSide = subTilesPerSide,
		globalCols = sectionCols * subTilesPerSide,
		globalRows = sectionRows * subTilesPerSide,
	}
end

local function parseCellKey(key: string): (number?, number?)
	local rStr, cStr = string.match(key, "^R(%d+)C(%d+)$")
	local r = tonumber(rStr)
	local c = tonumber(cStr)
	if not r or not c then
		return nil, nil
	end
	return r, c
end

local function globalCellToSectionIdAndTileKey(row: number, col: number): (string?, string?)
	local s = staticGrid()
	local sRow = math.floor((row - 1) / s.subTilesPerSide) + 1
	local sCol = math.floor((col - 1) / s.subTilesPerSide) + 1
	local localR = row - (sRow - 1) * s.subTilesPerSide
	local localC = col - (sCol - 1) * s.subTilesPerSide
	if localR < 1 or localR > s.subTilesPerSide or localC < 1 or localC > s.subTilesPerSide then
		return nil, nil
	end
	return string.format("S%02d_%02d", sRow, sCol), string.format("T%d%d", localR, localC)
end

local function getOwnedPlotByAttribute(plotId: number): Model?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local plots = map:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, item in ipairs(plots:GetChildren()) do
		if item:IsA("Model") then
			local id = item:GetAttribute("PlotId")
			if typeof(id) ~= "number" then
				id = tonumber(item.Name:match("(%d+)"))
			end
			if typeof(id) == "number" and id == plotId then
				return item
			end
		end
	end
	return nil
end

local function findTilePart(plot: Model, row: number, col: number): BasePart?
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return nil
	end
	local sectionId, tileKey = globalCellToSectionIdAndTileKey(row, col)
	if not sectionId or not tileKey then
		return nil
	end
	local section = ground:FindFirstChild(sectionId)
	if not (section and section:IsA("Model")) then
		return nil
	end
	local inst = section:FindFirstChild(tileKey, true)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	for _, d in ipairs(section:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == tileKey then
			return d
		end
	end
	return nil
end

local function currentFtueCellKey(player: Player): string?
	local d = player:GetAttribute(Constants.FtueRestrictDrillCellKeyAttribute)
	if typeof(d) == "string" and d ~= "" then
		return (d :: string):gsub("^%s+", ""):gsub("%s+$", "") :: any
	end
	return nil
end

local function destroyBorder(folder: Folder?)
	if folder and folder.Parent then
		folder:Destroy()
	end
end

local function createRaisedBorder(tile: BasePart, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "FtueTutorialZoneBorder"
	folder.Parent = parent

	local sz = tile.Size
	local cf = tile.CFrame
	local hx = sz.X / 2
	local hz = sz.Z / 2
	local yMid = sz.Y / 2 + WALL_HEIGHT / 2

	local function addWall(localOffset: Vector3, size: Vector3)
		local p = Instance.new("Part")
		p.Name = "FtueZoneEdge"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.Neon
		p.Color = EDGE_COLOR
		p.Size = size
		p.CFrame = cf * CFrame.new(localOffset) * CFrame.new(0, yMid, 0)
		p.Parent = folder
	end

	addWall(Vector3.new(0, 0, hz + WALL_THICK / 2), Vector3.new(sz.X - WALL_THICK * 2, WALL_HEIGHT, WALL_THICK))
	addWall(Vector3.new(0, 0, -hz - WALL_THICK / 2), Vector3.new(sz.X - WALL_THICK * 2, WALL_HEIGHT, WALL_THICK))
	addWall(Vector3.new(hx + WALL_THICK / 2, 0, 0), Vector3.new(WALL_THICK, WALL_HEIGHT, sz.Z - WALL_THICK * 2))
	addWall(Vector3.new(-hx - WALL_THICK / 2, 0, 0), Vector3.new(WALL_THICK, WALL_HEIGHT, sz.Z - WALL_THICK * 2))

	return folder
end

function FtueTutorialTileHighlight.start(player: Player)
	local borderFolder: Folder? = nil
	local conn: RBXScriptConnection? = nil
	local attrConn: { RBXScriptConnection } = {}

	local function refresh()
		destroyBorder(borderFolder)
		borderFolder = nil

		local pid = player:GetAttribute("PlotId") :: any
		if typeof(pid) ~= "number" then
			return
		end
		local plotId = pid :: number
		local plot = getOwnedPlotByAttribute(plotId)
		if not plot then
			return
		end

		local ck = currentFtueCellKey(player)
		if not ck then
			return
		end
		local row, col = parseCellKey(ck)
		if not row or not col then
			return
		end
		local tile = findTilePart(plot, row, col)
		if not tile then
			return
		end

		borderFolder = createRaisedBorder(tile, Workspace)
	end

	local function hook()
		for _, c in ipairs(attrConn) do
			c:Disconnect()
		end
		table.clear(attrConn)
		table.insert(attrConn, player:GetAttributeChangedSignal("PlotId"):Connect(refresh))
		table.insert(attrConn, player:GetAttributeChangedSignal(Constants.FtueRestrictDrillCellKeyAttribute):Connect(refresh))
		table.insert(attrConn, player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
			local st = player:GetAttribute(Constants.FtueStepAttribute)
			if typeof(st) ~= "string" then
				destroyBorder(borderFolder)
				borderFolder = nil
				return
			end
			refresh()
		end))
		refresh()
	end

	hook()
	conn = player:GetAttributeChangedSignal("PlotId"):Connect(hook)

	player.AncestryChanged:Connect(function()
		if not player.Parent then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			for _, c in ipairs(attrConn) do
				c:Disconnect()
			end
			table.clear(attrConn)
			destroyBorder(borderFolder)
		end
	end)
end

return FtueTutorialTileHighlight
