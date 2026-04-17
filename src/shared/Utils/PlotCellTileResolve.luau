--!strict
-- Resolves world hit (X/Z) on a plot to the same **global cell key** string as `OilStateService`
-- (`R{row}C{col}`). Used by the client for FTUE “wrong tile” checks; math must match server grid.

local OilConfig = require(script.Parent.Parent.Config.OilConfig)

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
	}
end

local function plotCellOrigin(plot: Model): (number, number)
	local s = staticGrid()
	-- Match `OilStateService.plotGridOrigin`: default (0,0) when no section CenterX/CenterZ.
	local centerX, centerZ = 0, 0
	local ground = plot:FindFirstChild("PlotGround")
	local count = 0
	local totalX, totalZ = 0, 0
	if ground then
		for _, section in ipairs(ground:GetChildren()) do
			if section:IsA("Model") then
				local cx = section:GetAttribute("CenterX")
				local cz = section:GetAttribute("CenterZ")
				if typeof(cx) == "number" and typeof(cz) == "number" then
					totalX += cx
					totalZ += cz
					count += 1
				end
			end
		end
		if count > 0 then
			centerX = totalX / count
			centerZ = totalZ / count
		end
	end
	local startX = centerX - ((s.sectionCols - 1) / 2) * s.sectionSize
	local startZ = centerZ - ((s.sectionRows - 1) / 2) * s.sectionSize
	local cellOriginX = startX - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	return cellOriginX, cellOriginZ
end

local function worldToCell(plot: Model, x: number, z: number): (number, number)
	local ox, oz = plotCellOrigin(plot)
	local col = math.floor((x - ox) / SUB_TILE_SIZE + 0.5) + 1
	local row = math.floor((z - oz) / SUB_TILE_SIZE + 0.5) + 1
	return row, col
end

-- Must match `OilStateService.tileKeyToLocalRowCol` (tile names are T + two digits).
local function tileKeyToLocalRowCol(tileKey: string): (number?, number?)
	local a, b = string.match(tileKey, "^T(%d)(%d)$")
	local r = tonumber(a)
	local c = tonumber(b)
	if not r or not c then
		return nil, nil
	end
	return r, c
end

local PlotCellTileResolve = {}

--- Authoritative path matches `OilStateService.resolveTileAt` + `_validateTilePlacement`: nearest `T##`
--- inside the section named `chunkId`, then global row/col from chunk grid indices. Falls back to
--- formula `worldToCell` when section/tiles or chunk indices are unavailable (streaming / legacy).
function PlotCellTileResolve.globalCellKeyFromChunkHit(
	plot: Model,
	chunkId: string,
	worldX: number,
	worldZ: number,
	chunkRow: number?,
	chunkCol: number?
): string
	local s = staticGrid()
	local ground = plot:FindFirstChild("PlotGround")
	local section = ground and ground:FindFirstChild(chunkId)
	if section and typeof(chunkRow) == "number" and typeof(chunkCol) == "number" then
		local nearest: BasePart? = nil
		local nearestDist = math.huge
		for _, t in ipairs(section:GetDescendants()) do
			if t:IsA("BasePart") and t.Name:match("^T%d%d$") then
				local dx = t.Position.X - worldX
				local dz = t.Position.Z - worldZ
				local d2 = dx * dx + dz * dz
				if d2 < nearestDist then
					nearestDist = d2
					nearest = t
				end
			end
		end
		if nearest then
			local localR, localC = tileKeyToLocalRowCol(nearest.Name)
			if localR and localC then
				local cellR = (chunkRow - 1) * s.subTilesPerSide + localR
				local cellC = (chunkCol - 1) * s.subTilesPerSide + localC
				return string.format("R%dC%d", cellR, cellC)
			end
		end
	end
	local row, col = worldToCell(plot, worldX, worldZ)
	return string.format("R%dC%d", row, col)
end

return PlotCellTileResolve
