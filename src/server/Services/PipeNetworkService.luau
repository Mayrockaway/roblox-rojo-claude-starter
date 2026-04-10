--!strict

-- PipeNetworkService
--
-- Cell-grid pipe connectivity. The plot is divided into a sub-tile grid (15x20 cells of 8 studs).
-- Each pipe occupies one cell. Drills and drums occupy a "home" cell each.
-- Two cells are connected if they are 4-adjacent (N/E/S/W) AND each contains either a pipe,
-- a drill, or a drum.
-- BFS starts from each drum's cell and propagates through adjacent occupied cells.
-- A drill is "connected" iff its home cell is reached.

local PipeNetworkService = {}

function PipeNetworkService:Init() end
function PipeNetworkService:Start() end
function PipeNetworkService:Stop() end

local function makeKey(row: number, col: number): string
	return string.format("R%dC%d", row, col)
end

function PipeNetworkService:MarkConnectivityForTick(state)
	if not state then return end

	-- Build pipe lookup: cellKey -> { row, col }. Pipes are the ONLY traversable nodes.
	local pipes = {}
	if typeof(state.pipesByCellKey) == "table" then
		for key, pipe in pairs(state.pipesByCellKey) do
			pipes[key] = { row = pipe.row, col = pipe.col }
		end
	end

	-- BFS through pipe cells only, starting from any pipe that is 4-adjacent to a drum cell.
	local reached = {}
	local queue = {}
	if typeof(state.drumsById) == "table" then
		for _, drum in pairs(state.drumsById or {}) do
			if drum.row and drum.col then
				local deltas = { {1,0}, {-1,0}, {0,1}, {0,-1} }
				for _, d in ipairs(deltas) do
					local nKey = makeKey(drum.row + d[1], drum.col + d[2])
					if pipes[nKey] and not reached[nKey] then
						reached[nKey] = true
						table.insert(queue, nKey)
					end
				end
			end
		end
	end

	-- Walk pipe-to-pipe (drum-adjacent seeds expand)
	local head = 1
	while head <= #queue do
		local key = queue[head]
		head += 1
		local cell = pipes[key]
		if cell then
			local deltas = { {1,0}, {-1,0}, {0,1}, {0,-1} }
			for _, d in ipairs(deltas) do
				local nKey = makeKey(cell.row + d[1], cell.col + d[2])
				if pipes[nKey] and not reached[nKey] then
					reached[nKey] = true
					table.insert(queue, nKey)
				end
			end
		end
	end

	-- Mark drills: a drill is connected iff one of its 4-adjacent cells is a reached pipe.
	for _, drill in pairs(state.drillsById or {}) do
		drill.connected = false
		if drill.cellRow and drill.cellCol then
			local deltas = { {1,0}, {-1,0}, {0,1}, {0,-1} }
			for _, d in ipairs(deltas) do
				local nKey = makeKey(drill.cellRow + d[1], drill.cellCol + d[2])
				if reached[nKey] then
					drill.connected = true
					break
				end
			end
		end
	end
end

return PipeNetworkService
