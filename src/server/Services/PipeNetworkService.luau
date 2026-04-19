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

	-- New system: every drill in a section with a center pump is auto-connected.
	-- No pipes or drums needed. A drill is "connected" if its chunkId matches
	-- any chunk that has an unlocked section (which always has a center pump).
	local chunksWithPumps = {}
	if typeof(state.chunksById) == "table" then
		for chunkId, chunk in pairs(state.chunksById) do
			if chunk.unlocked then
				chunksWithPumps[chunkId] = true
			end
		end
	end

	for _, drill in pairs(state.drillsById or {}) do
		drill.connected = drill.chunkId ~= nil and chunksWithPumps[drill.chunkId] == true
	end
end

return PipeNetworkService
