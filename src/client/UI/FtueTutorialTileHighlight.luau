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

--- Prefer the server-stamped `IsFtueTutorialTile` attribute as the single source
--- of truth: `OilStateService:SetFtueTutorialTileMarker` already chose the right
--- BasePart (handling the case where a tile is a `Model` whose `PrimaryPart` is
--- the cosmetic part). Falling back to client-side cell-key geometry can pick a
--- *different* BasePart (or fail entirely) if the tile hierarchy is non-trivial,
--- which leaves the highlight off while the world beam (which uses the marker)
--- works fine. The fallback handles legacy / pre-stamp cases.
local function findTilePartByMarker(plot: Model): BasePart?
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("IsFtueTutorialTile") == true then
			return d
		end
	end
	return nil
end

local function findTilePartByCell(plot: Model, row: number, col: number): BasePart?
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

local function findTilePart(plot: Model, row: number?, col: number?): BasePart?
	local marked = findTilePartByMarker(plot)
	if marked then
		return marked
	end
	if typeof(row) == "number" and typeof(col) == "number" then
		return findTilePartByCell(plot, row, col)
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

local function currentFtueChunkId(player: Player): string?
	local d = player:GetAttribute(Constants.FtueRestrictDrillChunkIdAttribute)
	if typeof(d) == "string" and d ~= "" then
		return (d :: string):gsub("^%s+", ""):gsub("%s+$", "") :: any
	end
	return nil
end

--- Find the chunk section Model inside PlotGround.
local function findChunkSectionModel(plot: Model, chunkId: string): Model?
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then return nil end
	local section = ground:FindFirstChild(chunkId)
	if section and section:IsA("Model") then return section end
	return nil
end

--- Compute a bounding box from all T## tiles in a chunk section.
--- Returns CFrame, Size or nil if no tiles found.
local function chunkBoundsFromSection(section: Model): (CFrame?, Vector3?)
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	local refY, refSizeY = 0, 0
	local count = 0
	for _, d in ipairs(section:GetDescendants()) do
		if d:IsA("BasePart") and string.match(d.Name, "^T%d%d$") then
			local pos = d.Position
			local half = d.Size / 2
			if pos.X - half.X < minX then minX = pos.X - half.X end
			if pos.X + half.X > maxX then maxX = pos.X + half.X end
			if pos.Z - half.Z < minZ then minZ = pos.Z - half.Z end
			if pos.Z + half.Z > maxZ then maxZ = pos.Z + half.Z end
			refY = pos.Y
			refSizeY = d.Size.Y
			count += 1
		end
	end
	if count == 0 then return nil, nil end
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	return CFrame.new(cx, refY, cz), Vector3.new(maxX - minX, refSizeY, maxZ - minZ)
end

--- Create raised neon border from a CFrame + Size (used for chunk-level highlight).
local function createRaisedBorderFromBounds(cf: CFrame, sz: Vector3, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "FtueTutorialZoneBorder"
	folder.Parent = parent

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

	addWall(Vector3.new(0, 0, hz + WALL_THICK / 2), Vector3.new(sz.X + WALL_THICK, WALL_HEIGHT, WALL_THICK))
	addWall(Vector3.new(0, 0, -hz - WALL_THICK / 2), Vector3.new(sz.X + WALL_THICK, WALL_HEIGHT, WALL_THICK))
	addWall(Vector3.new(hx + WALL_THICK / 2, 0, 0), Vector3.new(WALL_THICK, WALL_HEIGHT, sz.Z))
	addWall(Vector3.new(-hx - WALL_THICK / 2, 0, 0), Vector3.new(WALL_THICK, WALL_HEIGHT, sz.Z))

	return folder
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
	--- Streaming-retry watchers: rebound every refresh to react to plot or tile
	--- replication. Without these, a player on slower hardware (mobile) whose
	--- plot is **not** in their `Workspace.Map.Plots` when the first refresh
	--- runs would never see the highlight — `FtueStep` / `FtueRestrictDrillCellKey`
	--- replicate **before** the plot model on first spawn, so attribute-change
	--- signals alone don't recover.
	local streamingConn: { RBXScriptConnection } = {}

	local function clearStreamingWatchers()
		for _, c in ipairs(streamingConn) do
			c:Disconnect()
		end
		table.clear(streamingConn)
	end

	local refresh

	local function watchPlotsRoot()
		local map = Workspace:FindFirstChild("Map")
		local plots = map and map:FindFirstChild("Plots")
		if not plots then
			--- `Map.Plots` itself isn't replicated yet (very early spawn). Watch
			--- Workspace for it to appear; the next `refresh` rebinds the watcher.
			table.insert(streamingConn, Workspace.DescendantAdded:Connect(function(d)
				if d.Name == "Plots" or d.Name == "Map" then
					refresh()
				end
			end))
			return
		end
		--- Plot model itself streams in as a child of `Plots`.
		table.insert(streamingConn, plots.ChildAdded:Connect(function()
			refresh()
		end))
	end

	local function watchPlotInternals(plot: Model)
		--- Sections and individual tiles can stream in lazily once the plot model
		--- is present; refresh whenever a `BasePart` with the marker attribute
		--- appears, or whenever any descendant whose name looks like a tile shows up.
		table.insert(streamingConn, plot.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") and d:GetAttribute("IsFtueTutorialTile") == true then
				refresh()
				return
			end
			if d:IsA("BasePart") and string.match(d.Name, "^T%d+$") then
				refresh()
			end
		end))
		--- Marker can be **stamped on** a part that already streamed in (server
		--- moves the marker between tiles between drill / reveal legs). Catch
		--- attribute changes on every existing BasePart in the plot too.
		for _, d in ipairs(plot:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(streamingConn, d:GetAttributeChangedSignal("IsFtueTutorialTile"):Connect(function()
					if d:GetAttribute("IsFtueTutorialTile") == true then
						refresh()
					end
				end))
			end
		end
	end

	refresh = function()
		destroyBorder(borderFolder)
		borderFolder = nil
		clearStreamingWatchers()

		local pid = player:GetAttribute("PlotId") :: any
		if typeof(pid) ~= "number" then
			return
		end
		local plotId = pid :: number
		local plot = getOwnedPlotByAttribute(plotId)
		if not plot then
			--- Plot model not in `Workspace.Map.Plots` yet (streaming or first
			--- spawn race). Watch for it to arrive then retry.
			watchPlotsRoot()
			return
		end

		-- Chunk-level highlight (WaitDrillOil_WIP): border around entire 5x5 area.
		local chunkId = currentFtueChunkId(player)
		if chunkId then
			local section = findChunkSectionModel(plot, chunkId)
			if not section then
				watchPlotInternals(plot)
				return
			end
			local cf, sz = chunkBoundsFromSection(section)
			if not cf or not sz then
				watchPlotInternals(plot)
				return
			end
			borderFolder = createRaisedBorderFromBounds(cf, sz, Workspace)
			return
		end

		-- Single-tile highlight (WaitReveal): border around the drilled tile.
		local ck = currentFtueCellKey(player)
		if not ck then
			return
		end
		local row, col = parseCellKey(ck)
		local tile = findTilePart(plot, row, col)
		if not tile then
			watchPlotInternals(plot)
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
		table.insert(attrConn, player:GetAttributeChangedSignal(Constants.FtueRestrictDrillChunkIdAttribute):Connect(refresh))
		table.insert(attrConn, player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
			local st = player:GetAttribute(Constants.FtueStepAttribute)
			if typeof(st) ~= "string" then
				destroyBorder(borderFolder)
				borderFolder = nil
				clearStreamingWatchers()
				return
			end
			refresh()
		end))
		--- Re-spawn / respawn re-replicates plot under the player; trigger another
		--- attempt so a death mid-FTUE doesn't lose the highlight.
		table.insert(attrConn, player.CharacterAdded:Connect(function()
			task.defer(refresh)
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
			clearStreamingWatchers()
			destroyBorder(borderFolder)
		end
	end)
end

return FtueTutorialTileHighlight
