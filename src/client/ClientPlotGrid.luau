--!strict
--[[
	ClientPlotGrid — extracted from init.client.luau
	Singleton module holding plot/grid state, cell-grid helpers, prompt wiring,
	and status-line display for the oil gameplay HUD.

	Usage:
		local ClientPlotGrid = require(resolveClientModule(script, "ClientPlotGrid"))
		ClientPlotGrid.init({ ... })
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--- Coordinates Hint-line writes between this module's `setStatus` /
--- `setStatusLocked` and `ShipmentProgressHud`'s direct text writes (cruise
--- dots, "Ship halted!", success/loss). See `UI/HintLineState.luau` header.
local HintLineState = require(script.Parent:WaitForChild("UI"):WaitForChild("HintLineState")) :: any

-- ===================== types =====================
export type InitParams = {
	player: Player,
	playerGui: PlayerGui,
	Workspace: Workspace,
	ReplicatedStorage: ReplicatedStorage,
	Constants: any,
	OilConfig: any,
	mouse: Mouse,
	requestBuyChunk: RemoteEvent,
	oilActionResult: RemoteEvent,
}

-- ===================== module table =====================
local M = {}

-- ===================== upvalues (set by init) =====================
local player: Player
local playerGui: PlayerGui
local _Workspace: Workspace
local _ReplicatedStorage: ReplicatedStorage
local Constants: any
local OilConfig: any
local mouse: Mouse
local requestBuyChunk: RemoteEvent
local oilActionResult: RemoteEvent

-- ===================== state =====================
local state = nil
local cashTextLabel: TextLabel? = nil

local config = {
	drillPlacementCost = 200,
	drillMinSpacing = 6,
	removeDrillHoldSeconds = 2,
	removeDrillRangeStuds = 18,
	chunks = { size = 8, rows = 10, cols = 10, startingCenterSize = 4 },
	boatCatalog = {},
}

local ownedPlot: Model? = nil
local chunkPartById = {}
local chunkStateById = {}
local drillStateById = {}

local promptConnections = {}
local _wiredPromptSet: { [ProximityPrompt]: true } = {}

-- =================== CLIENT CELL-GRID HELPERS ===================
local SUB_TILE_SIZE = 8
local _clientGridCache = nil

local function plotGridConstants()
	if _clientGridCache then return unpack(_clientGridCache) end

	-- Must match server `OilConfig.Chunks` (not legacy `config.chunks` defaults) so cell keys align with FTUE / drills.
	local oc = OilConfig.Chunks
	local sectionCols = oc.GridCols
	local sectionRows = oc.GridRows
	local sectionSize = oc.Size
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE)

	-- Derive center from actual plot sections; default (0,0) matches `OilStateService.plotGridOrigin`
	-- when sections have no CenterX/CenterZ (legacy hardcoded -840,-1020 broke grid vs server).
	local centerX, centerZ = 0, 0
	if ownedPlot then
		local ground = ownedPlot:FindFirstChild("PlotGround")
		if ground then
			local totalX, totalZ, count = 0, 0, 0
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
	end

	local startX = centerX - ((sectionCols - 1) / 2) * sectionSize
	local startZ = centerZ - ((sectionRows - 1) / 2) * sectionSize
	local cellOriginX = startX - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local globalCols = sectionCols * subTilesPerSide
	local globalRows = sectionRows * subTilesPerSide

	_clientGridCache = { cellOriginX, cellOriginZ, globalRows, globalCols, subTilesPerSide }
	return cellOriginX, cellOriginZ, globalRows, globalCols, subTilesPerSide
end

local function cellKeyOf(row, col): string
	return string.format("R%dC%d", row, col)
end

local function readLocalFtueCellKey(attributeName: string): string?
	local v = player:GetAttribute(attributeName)
	if typeof(v) ~= "string" then
		return nil
	end
	local s = (v :: string):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil
	end
	return s
end

local function clientWorldToCell(x, z): (number, number)
	local cellOriginX, cellOriginZ = plotGridConstants()
	local col = math.floor((x - cellOriginX) / SUB_TILE_SIZE + 0.5) + 1
	local row = math.floor((z - cellOriginZ) / SUB_TILE_SIZE + 0.5) + 1
	return row, col
end

local function clientCellToWorld(row, col): (number, number)
	local cellOriginX, cellOriginZ = plotGridConstants()
	local x = cellOriginX + (col - 1) * SUB_TILE_SIZE
	local z = cellOriginZ + (row - 1) * SUB_TILE_SIZE
	return x, z
end

local function clientCellInBounds(row, col): boolean
	local _, _, globalRows, globalCols = plotGridConstants()
	return row >= 1 and row <= globalRows and col >= 1 and col <= globalCols
end

--- Shipment strip `Hint` under `HUD` / `ShipmentProgressPanel` (see CANONICAL_STUDIO_LAYOUT.md).
local function resolveShipmentHintLine(): (TextLabel | TextButton)?
	local panel = playerGui:FindFirstChild("ShipmentProgressPanel", true)
	if not (panel and panel:IsA("GuiObject")) then
		return nil
	end
	local hint = panel:FindFirstChild("Hint", true)
	if hint and hint:IsA("TextLabel") then
		return hint
	end
	if hint and hint:IsA("TextButton") then
		return hint
	end
	if hint and hint:IsA("GuiObject") then
		for _, d in ipairs(hint:GetDescendants()) do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				return d
			end
		end
	end
	return nil
end

--- High-priority status writes (e.g. contractor "your hit landed" alert) can
--- claim the shipment hint line for a few seconds so the breakdown isn't
--- clobbered by routine `setStatus` chatter (drilling progress, prospector
--- pings, etc.). `setStatus` checks this gate and silently drops while the
--- lock is still in effect; once it expires, the next `setStatus` wins.
---
--- Lock state lives in `HintLineState` so `ShipmentProgressHud` (cruise dots,
--- halt text, success/loss writes) can also honor it — otherwise the cruise
--- loop's 0.42s tick would overwrite locked text.

-- ===================== shipment-hint auto-fade =====================
-- The shipment-hint `TextLabel` (under `ShipmentProgressPanel.Hint`) is a
-- shared notification surface: written by `setStatus` / `setStatusLocked`
-- here, **and** directly by `ShipmentProgressHud` (cruise dots animation,
-- "Ship halted!", "Shipment lost…", success line, etc.). To make *every*
-- update auto-fade after 5s of no further updates — regardless of who wrote
-- it — we hook the label's `Text` property change signal and drive the fade
-- from there. Side benefits:
--   * `ShipmentProgressHud.startCruiseDots` writes Text every ~0.42s, which
--     keeps the timer reset → cruise text never fades during an active
--     shipment, only once the dots stop.
--   * `setStatusLocked`'s 5s lock window lines up with the 5s fade hold, so
--     the contractor's gold notification stays opaque the entire lock then
--     fades cleanly when the lock expires.
local STATUS_FADE_HOLD_SECONDS = 5
local STATUS_FADE_DURATION = 0.6
local STATUS_FADE_INFO = TweenInfo.new(STATUS_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local hintFadeAttachedTo: Instance? = nil
local hintFadeTextConn: RBXScriptConnection? = nil
local hintFadeAncestryConn: RBXScriptConnection? = nil
local hintFadeToken: number = 0
local hintFadeTextTween: Tween? = nil
local hintFadeStrokeTweens: { Tween } = {}

local function snapHintOpaque(line: TextLabel | TextButton)
	hintFadeToken += 1
	if hintFadeTextTween then
		hintFadeTextTween:Cancel()
		hintFadeTextTween = nil
	end
	for _, tw in ipairs(hintFadeStrokeTweens) do
		tw:Cancel()
	end
	table.clear(hintFadeStrokeTweens)
	line.TextTransparency = 0
	for _, child in ipairs(line:GetChildren()) do
		if child:IsA("UIStroke") then
			child.Transparency = 0
		end
	end
end

local function scheduleHintFade(line: TextLabel | TextButton)
	local myToken = hintFadeToken
	task.delay(STATUS_FADE_HOLD_SECONDS, function()
		-- Newer write happened — abort; the new write already snapped opaque
		-- and started its own timer.
		if myToken ~= hintFadeToken then
			return
		end
		if not (line and line.Parent) then
			return
		end
		local tw = TweenService:Create(line, STATUS_FADE_INFO, { TextTransparency = 1 })
		hintFadeTextTween = tw
		for _, child in ipairs(line:GetChildren()) do
			if child:IsA("UIStroke") then
				local st = TweenService:Create(child, STATUS_FADE_INFO, { Transparency = 1 })
				table.insert(hintFadeStrokeTweens, st)
				st:Play()
			end
		end
		tw:Play()
	end)
end

local function ensureHintFadeWatch(line: TextLabel | TextButton)
	if hintFadeAttachedTo == line then
		return
	end
	if hintFadeTextConn then
		hintFadeTextConn:Disconnect()
		hintFadeTextConn = nil
	end
	if hintFadeAncestryConn then
		hintFadeAncestryConn:Disconnect()
		hintFadeAncestryConn = nil
	end
	hintFadeAttachedTo = line
	-- Catch every Text write — ours and anyone else's (e.g. ShipmentProgressHud).
	-- Setting Text inside the callback would loop, but we only mutate transparency
	-- here, so this is safe.
	hintFadeTextConn = line:GetPropertyChangedSignal("Text"):Connect(function()
		if not line.Parent then
			return
		end
		snapHintOpaque(line)
		scheduleHintFade(line)
	end)
	-- If the label is destroyed (Studio rebuild, ShipmentProgressHud fallback
	-- recreates Hint), forget it so the next `setStatus` re-resolves and
	-- attaches a fresh watcher.
	hintFadeAncestryConn = line.AncestryChanged:Connect(function(_, parent)
		if not parent and hintFadeAttachedTo == line then
			hintFadeAttachedTo = nil
			if hintFadeTextConn then
				hintFadeTextConn:Disconnect()
				hintFadeTextConn = nil
			end
		end
	end)
	-- Kick off a timer for the current text so an authored idle string still
	-- fades after 5s (matches the "any update lasts 5s then fades" rule).
	snapHintOpaque(line)
	scheduleHintFade(line)
end

local function setStatus(message: string, ok: boolean?)
	if HintLineState.isLocked() then
		if RunService:IsStudio() then
			print("[Client] status (suppressed by lock):", message, " ok=", ok)
		end
		return
	end
	local line = resolveShipmentHintLine()
	if line then
		if line:IsA("TextLabel") or line:IsA("TextButton") then
			line.Font = Enum.Font.Merriweather
		end
		line.RichText = false
		line.Text = message
		if ok == true then
			line.TextColor3 = Color3.fromRGB(75, 200, 115)
		elseif ok == false then
			line.TextColor3 = Color3.fromRGB(235, 100, 100)
		else
			line.TextColor3 = Color3.fromRGB(218, 228, 240)
		end
		ensureHintFadeWatch(line)
		HintLineState.markNonCruiseWritten()
	end
	if RunService:IsStudio() then
		print("[Client] status:", message, " ok=", ok)
	end
end

--- Paint the shipment hint with an explicit color and **lock** the line for
--- `holdSeconds` so subsequent `setStatus` calls are dropped. Used for
--- high-stakes one-shot notifications that must read clearly (e.g. contractor
--- pirate-hit landed: bright gold, 5-second hold). Pass `holdSeconds <= 0` to
--- paint without locking. The line is not auto-restored after the hold —
--- whatever calls `setStatus` next once the lock expires wins.
local function setStatusLocked(message: string, color: Color3, holdSeconds: number)
	local line = resolveShipmentHintLine()
	if line then
		if line:IsA("TextLabel") or line:IsA("TextButton") then
			line.Font = Enum.Font.Merriweather
		end
		line.RichText = false
		line.Text = message
		line.TextColor3 = color
		ensureHintFadeWatch(line)
		HintLineState.markNonCruiseWritten()
	end
	if typeof(holdSeconds) == "number" and holdSeconds > 0 then
		HintLineState.setLockUntil(holdSeconds)
	end
	if RunService:IsStudio() then
		print(string.format("[Client] status (locked %.1fs):", math.max(0, holdSeconds)), message)
	end
end

local function getEquippedToolName(): string?
	local character = player.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			return child.Name
		end
	end
	return nil
end

-- Returns (kind, tier) for the currently equipped tool based on its attributes.
-- kind ∈ {"Drill", nil} after the drills-only refactor.
local function getEquippedToolInfo(): (string?, string?)
	local character = player.Character
	if not character then return nil, nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			local kind = child:GetAttribute("ToolKind")
			local tier = child:GetAttribute("Tier")
			return typeof(kind) == "string" and kind or nil, typeof(tier) == "string" and tier or nil
		end
	end
	return nil, nil
end

local function getOwnedPlotByAttribute(): Model?
	local plotId = player:GetAttribute("PlotId")
	if typeof(plotId) ~= "number" or plotId <= 0 then return nil end
	local map = _Workspace:FindFirstChild("Map")
	if not map then return nil end
	local plots = map:FindFirstChild("Plots")
	if not plots then return nil end
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

local function rebuildStateMaps()
	chunkStateById = {}
	drillStateById = {}
	if not state then
		return
	end
	for _, chunk in ipairs(state.chunks or {}) do
		chunkStateById[chunk.chunkId] = chunk
	end
	for _, drill in ipairs(state.drills or {}) do
		drillStateById[drill.drillId] = drill
	end
end

local function disconnectPromptConnections()
	for _, c in ipairs(promptConnections) do
		c:Disconnect()
	end
	promptConnections = {}
end

local function wireBuyPrompt(prompt: ProximityPrompt)
	if _wiredPromptSet[prompt] then return end
	_wiredPromptSet[prompt] = true
	local conn = prompt.Triggered:Connect(function(triggeringPlayer)
		if RunService:IsStudio() then
			print(string.format("[Client] BuyPrompt Triggered by %s on %s",
				triggeringPlayer and triggeringPlayer.Name or "?", prompt:GetFullName()))
		end
		if triggeringPlayer ~= player then
			return
		end
		local cursor: Instance? = prompt
		while cursor and cursor.Parent do
			cursor = cursor.Parent
			if cursor and typeof(cursor:GetAttribute("ChunkId")) == "string" then
				local chunkId = cursor:GetAttribute("ChunkId")
				if RunService:IsStudio() then
					print(string.format("[Client] firing RequestBuyChunk chunkId=%s", chunkId))
				end
				requestBuyChunk:FireServer({ chunkId = chunkId })
				return
			end
		end
		if RunService:IsStudio() then
			print("[Client] BuyPrompt: no ChunkId ancestor")
		end
	end)
	table.insert(promptConnections, conn)
end

local function bindPromptsForOwnedPlot()
	disconnectPromptConnections()
	_wiredPromptSet = {}
	if not ownedPlot then return end
	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then return end

	local wired = 0
	for _, descendant in ipairs(ground:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Name == "BuyPrompt" then
			wireBuyPrompt(descendant)
			wired += 1
		end
	end
	if RunService:IsStudio() then
		print(string.format("[Client] bindPromptsForOwnedPlot: wired %d BuyPrompts on %s (initial)", wired, ownedPlot.Name))
	end

	-- Streaming-resilient: catch BuyPrompts that replicate in later.
	local boundPlot = ownedPlot
	local streamConn = ground.DescendantAdded:Connect(function(d)
		if boundPlot ~= ownedPlot then return end
		if d:IsA("ProximityPrompt") and d.Name == "BuyPrompt" then
			wireBuyPrompt(d)
			if RunService:IsStudio() then
				print(string.format("[Client] BuyPrompt wired late via DescendantAdded: %s", d:GetFullName()))
			end
		end
	end)
	table.insert(promptConnections, streamConn)
end

local function bindOwnedPlot()
	chunkPartById = {}
	local prevOwned = ownedPlot
	ownedPlot = getOwnedPlotByAttribute()
	_clientGridCache = nil
	if not ownedPlot then
		warn(string.format("[Client] bindOwnedPlot: ownedPlot=nil (PlotId attr=%s, prev=%s, plots-folder-exists=%s, plots-count=%s)",
			tostring(player:GetAttribute("PlotId")),
			prevOwned and prevOwned.Name or "nil",
			tostring(_Workspace.Map and _Workspace.Map:FindFirstChild("Plots") ~= nil),
			(_Workspace.Map and _Workspace.Map:FindFirstChild("Plots")) and tostring(#_Workspace.Map.Plots:GetChildren()) or "?"))
		return
	end

	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		warn(string.format("[Client] bindOwnedPlot: %s has no PlotGround", ownedPlot.Name))
		return
	end

	local count = 0
	for _, item in ipairs(ground:GetChildren()) do
		if item:IsA("Model") then
			local chunkId = item:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				chunkPartById[chunkId] = item
				count += 1
			end
		end
	end

	if RunService:IsStudio() then
		print(string.format("[Client] bindOwnedPlot: %s bound, %d chunks found", ownedPlot.Name, count))
	end

	bindPromptsForOwnedPlot()
end

-- ===================== init =====================
function M.init(params: InitParams)
	player = params.player
	playerGui = params.playerGui
	_Workspace = params.Workspace
	_ReplicatedStorage = params.ReplicatedStorage
	Constants = params.Constants
	OilConfig = params.OilConfig
	mouse = params.mouse
	requestBuyChunk = params.requestBuyChunk
	oilActionResult = params.oilActionResult
end

-- ===================== getters =====================
function M.getState()
	return state
end

function M.getConfig(): { [string]: any }
	return config :: { [string]: any }
end

function M.getOwnedPlot(): Model?
	return ownedPlot
end

function M.getChunkPartById(): { [string]: any }
	return chunkPartById
end

function M.getChunkStateById(): { [string]: any }
	return chunkStateById
end

function M.getDrillStateById(): { [string]: any }
	return drillStateById
end

-- ===================== setters =====================
function M.setState(newState: any)
	state = newState
end

function M.setConfig(newConfig: any)
	-- Merge new keys into existing config so callers that captured a reference still see defaults
	for k, v in pairs(newConfig) do
		(config :: any)[k] = v
	end
end

function M.setOwnedPlot(plot: Model?)
	ownedPlot = plot
end

-- ===================== cache =====================
function M.invalidatePlotGridCache()
	_clientGridCache = nil
end

-- ===================== exported helpers =====================
M.plotGridConstants = plotGridConstants
M.cellKeyOf = cellKeyOf
M.readLocalFtueCellKey = readLocalFtueCellKey
M.clientWorldToCell = clientWorldToCell
M.clientCellToWorld = clientCellToWorld
M.clientCellInBounds = clientCellInBounds
M.setStatus = setStatus
M.setStatusLocked = setStatusLocked
M.getEquippedToolName = getEquippedToolName
M.getEquippedToolInfo = getEquippedToolInfo
M.getOwnedPlotByAttribute = getOwnedPlotByAttribute
M.rebuildStateMaps = rebuildStateMaps
M.disconnectPromptConnections = disconnectPromptConnections
M.wireBuyPrompt = wireBuyPrompt
M.bindPromptsForOwnedPlot = bindPromptsForOwnedPlot
M.bindOwnedPlot = bindOwnedPlot
M.SUB_TILE_SIZE = SUB_TILE_SIZE

return M
