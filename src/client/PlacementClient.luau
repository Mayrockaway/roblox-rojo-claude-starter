--!strict
--[[
	PlacementClient — extracted from init.client.luau
	Singleton module handling placement ghosts, pipe placement previews,
	focus billboard UI, and hammer hover billboard.

	Usage:
		local PlacementClient = require(resolveClientModule(script, "PlacementClient"))
		PlacementClient.init({ ... })
]]

local RunService = game:GetService("RunService")

-- ===================== types =====================
export type InitParams = {
	player: Player,
	playerGui: PlayerGui,
	mouse: Mouse,
	Workspace: Workspace,
	ReplicatedStorage: ReplicatedStorage,
	OilConfig: any,
	Constants: any,
	requestPlacePipe: RemoteEvent,
	PlacementAnchor: any,
	PlotCellTileResolve: any,
	ClientPlotGrid: any,
	resolveHammerTarget: () -> any?,
	estimateRefundForTarget: (target: any) -> (number, Instance?),
}

-- ===================== module table =====================
local M = {}

-- ===================== upvalues (set by init) =====================
local player: Player
local playerGui: PlayerGui
local mouse: Mouse
local _Workspace: Workspace
local _ReplicatedStorage: ReplicatedStorage
local OilConfig: any
local Constants: any
local requestPlacePipe: RemoteEvent
local PlacementAnchor: any
local PlotCellTileResolve: any
local ClientPlotGrid: any
local resolveHammerTarget: () -> any?
local estimateRefundForTarget: (target: any) -> (number, Instance?)

-- ===================== constants =====================
local TOOL_DRILL = "Drill"
local TOOL_PIPE = "Pipe"

-- ===================== internal state =====================
local ghostDrill: Model? = nil
local ghostHighlight: Highlight? = nil
local ghostTemplateName: string? = nil

local pipeGhost: Model? = nil
local lastPipeDebugAt = 0

local focusBillboard: BillboardGui? = nil
local focusLabel: TextLabel? = nil

local hammerHoverBB: BillboardGui? = nil
local hammerHoverLbl: TextLabel? = nil

-- ===================== internal helpers =====================

local function pipeDebugLog(msg: string)
	if not RunService:IsStudio() then
		return
	end
	local now = os.clock()
	if now - lastPipeDebugAt < 0.12 then
		return
	end
	lastPipeDebugAt = now
	print("[PipeDebug] " .. msg)
end

-- ===================== exported functions =====================

local function getTargetedChunkHit(): (Instance?, Vector3?, string?)
	local target = mouse.Target
	if not (target and target:IsA("BasePart")) then
		return nil, nil, nil
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	if not ownedPlot then
		return nil, nil, nil
	end
	-- Walk up parents looking for any instance carrying a ChunkId attribute (Model or BasePart)
	local cursor: Instance? = target
	while cursor do
		if typeof(cursor:GetAttribute("ChunkId")) == "string" then
			return cursor, mouse.Hit.Position, cursor:GetAttribute("ChunkId")
		end
		cursor = cursor.Parent
		if cursor == nil or cursor == ownedPlot.Parent then
			break
		end
	end
	return nil, nil, nil
end

local function isChunkUnlocked(chunkId: string): boolean
	local c = ClientPlotGrid.getChunkStateById()[chunkId]
	return c ~= nil and c.unlocked == true
end

-- Returns the top Y of a chunk's surface (the highest sub-tile). Uses descendants so nested
-- authored tiles still resolve; avoids falling back to `hitPos.Y` (StartBeach / void) when grazing.
local function getChunkSurfaceY(chunkId: string): number?
	local sectionModel = ClientPlotGrid.getChunkPartById()[chunkId]
	if not sectionModel then
		return nil
	end
	local topY: number? = nil
	for _, d in ipairs(sectionModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
			local surface = d.Position.Y + d.Size.Y / 2
			if topY == nil or surface > topY then
				topY = surface
			end
		end
	end
	return topY
end

-- When the mouse hits a tile part directly, use that surface (matches server tile snap).
local function surfaceYFromRayTarget(): number?
	local t = mouse.Target
	if t and t:IsA("BasePart") and t.Name:match("^T%d%d$") then
		return t.Position.Y + t.Size.Y / 2
	end
	return nil
end

local function pumpGhostVisualGroundLiftStuds(tier: string?): number
	if typeof(tier) ~= "string" then
		return 0
	end
	local pt = (OilConfig.PumpTiers :: { [string]: any })[tier]
	if pt and typeof(pt.visualGroundOffsetStuds) == "number" then
		return pt.visualGroundOffsetStuds :: number
	end
	return 0
end

local function distanceXZ(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function isPlacementValid(chunkId: string, hitPos: Vector3, equipKind: string?): boolean
	if not isChunkUnlocked(chunkId) then
		return false
	end
	local kind = equipKind
	if kind == nil then
		kind = select(1, ClientPlotGrid.getEquippedToolInfo())
		if kind == nil and ClientPlotGrid.getEquippedToolName() == TOOL_DRILL then
			kind = "Drill"
		end
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	local chunkStateById = ClientPlotGrid.getChunkStateById()
	local readLocalFtueCellKey = ClientPlotGrid.readLocalFtueCellKey
	if kind == "Drill" then
		local want = readLocalFtueCellKey(Constants.FtueRestrictDrillCellKeyAttribute)
		if want and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= want then
				return false
			end
		end
	elseif kind == "Pump" then
		local want = readLocalFtueCellKey(Constants.FtueRestrictPumpCellKeyAttribute)
		if want and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= want then
				return false
			end
		end
	end
	local config = ClientPlotGrid.getConfig()
	local drillStateById = ClientPlotGrid.getDrillStateById()
	for _, drill in pairs(drillStateById) do
		local pos = Vector3.new(drill.position.x, drill.position.y, drill.position.z)
		if distanceXZ(pos, hitPos) < (config.drillMinSpacing or 6) then
			return false
		end
	end
	return true
end

-- Maps equipped tool (kind + tier) → RS.Assets template name to preview
local function resolveGhostTemplateName(): string?
	local kind, tier = ClientPlotGrid.getEquippedToolInfo()
	if kind == "Drill" and tier then return "Drill_" .. tier end
	if kind == "Pump" and tier then return "Pump_" .. tier end
	if kind == "Prospector" then return "Prospector" end
	-- Legacy fallback
	if ClientPlotGrid.getEquippedToolName() == TOOL_DRILL then return "Drill_T1" end
	return nil
end

local function ensureGhost(): Model?
	local wantName = resolveGhostTemplateName()
	if not wantName then return nil end

	-- If the equipped tool changed, rebuild the ghost with the new template
	if ghostDrill and ghostDrill.Parent and ghostTemplateName == wantName then
		return ghostDrill
	end
	if ghostDrill then ghostDrill:Destroy(); ghostDrill = nil; ghostHighlight = nil end

	local assets = _ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(wantName)
	if not template then return nil end

	local clone = template:Clone()
	clone.Name = "PlacementGhost"
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then d:Destroy() end
		if d:IsA("BasePart") then
			d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
		end
	end
	local hl = Instance.new("Highlight")
	hl.Name = "GhostHighlight"
	hl.FillColor = Color3.fromRGB(80, 220, 120)
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = clone
	clone.Parent = _Workspace
	ghostDrill = clone
	ghostHighlight = hl
	ghostTemplateName = wantName
	return clone
end

local function hideGhost()
	if ghostDrill then
		ghostDrill:Destroy()
		ghostDrill = nil
		ghostHighlight = nil
	end
end

local function updateGhost()
	local kind = select(1, ClientPlotGrid.getEquippedToolInfo())
	local equipped = ClientPlotGrid.getEquippedToolName()
	if kind ~= "Drill" and kind ~= "Pump" and kind ~= "Prospector" and equipped ~= TOOL_DRILL then
		hideGhost()
		return
	end
	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then
		hideGhost()
		return
	end
	local equipKind = select(1, ClientPlotGrid.getEquippedToolInfo())
	local equipTier = select(2, ClientPlotGrid.getEquippedToolInfo())
	if equipKind == nil and equipped == TOOL_DRILL then
		equipKind = "Drill"
	end

	local g = ensureGhost()
	if not g then
		return
	end
	local surfaceY = surfaceYFromRayTarget() or getChunkSurfaceY(chunkId) or hitPos.Y
	-- Pivot → ground: optional `Bottom` / `bottom` anchor part, else full-model bbox (PlacementAnchor).
	local pivotToBottom = 0
	if g:IsA("Model") then
		pivotToBottom = PlacementAnchor.pivotYMinusBottomWorldY(g)
	end
	local catalogLift = (equipKind == "Pump") and pumpGhostVisualGroundLiftStuds(equipTier) or 0
	g:PivotTo(CFrame.new(hitPos.X, surfaceY + pivotToBottom + catalogLift, hitPos.Z))
	if ghostHighlight then
		if isPlacementValid(chunkId, hitPos, equipKind) then
			ghostHighlight.FillColor = Color3.fromRGB(80, 220, 120)
			ghostHighlight.OutlineColor = Color3.fromRGB(190, 255, 200)
		else
			ghostHighlight.FillColor = Color3.fromRGB(220, 70, 70)
			ghostHighlight.OutlineColor = Color3.fromRGB(255, 180, 180)
		end
	end
end

-- =================== CELL-GRID PIPE PLACEMENT ===================

local function getPipeHit(): (Vector3?, string?)
	local _chunkInst, hitPos, chunkId = getTargetedChunkHit()
	if not hitPos or not chunkId then
		pipeDebugLog("no valid chunk hit")
		return nil, nil
	end
	if not isChunkUnlocked(chunkId) then
		pipeDebugLog("chunk locked: " .. tostring(chunkId))
		return nil, nil
	end
	return hitPos, chunkId
end

local function ensurePipeGhost(): Model
	if pipeGhost and pipeGhost.Parent then
		return pipeGhost
	end
	local m = Instance.new("Model")
	m.Name = "PipePreview"
	local p = Instance.new("Part")
	p.Name = "Body"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(6, 1.5, 6)
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(80, 220, 120)
	p.Transparency = 0.45
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = m
	m.PrimaryPart = p
	m.Parent = _Workspace
	pipeGhost = m
	return m
end

local function hidePipeGhost()
	if pipeGhost then
		pipeGhost:Destroy()
		pipeGhost = nil
	end
end

local function pipeHitValid(chunkId: string?): (boolean, string?)
	if not chunkId or chunkId == "" then
		return false, "No chunk"
	end
	local section = ClientPlotGrid.getChunkStateById()[chunkId]
	if not section or section.unlocked ~= true then
		return false, "Locked section"
	end
	return true, nil
end

local function updatePipeGhost()
	local equipped = ClientPlotGrid.getEquippedToolName()
	if equipped ~= TOOL_PIPE then
		hidePipeGhost()
		return
	end
	local worldPos, chunkId = getPipeHit()
	if not worldPos then
		pipeDebugLog("ghost hidden: no valid pipe cell")
		hidePipeGhost()
		return
	end
	local valid = pipeHitValid(chunkId)
	local g = ensurePipeGhost()
	local body = g:FindFirstChild("Body")
	if body and body:IsA("BasePart") then
		local y = (chunkId and (surfaceYFromRayTarget() or getChunkSurfaceY(chunkId) or worldPos.Y)) or worldPos.Y
		body.Position = Vector3.new(worldPos.X, y + 0.75, worldPos.Z)
		body.Color = valid and Color3.fromRGB(80, 220, 120) or Color3.fromRGB(220, 70, 70)
	end
end

local function tryPipeAction()
	if ClientPlotGrid.getEquippedToolName() ~= TOOL_PIPE then
		return
	end
	local worldPos, chunkId = getPipeHit()
	if not worldPos then
		pipeDebugLog("place failed: no valid owned tile under cursor")
		ClientPlotGrid.setStatus("Click on an owned chunk.", false)
		return
	end
	local valid, reason = pipeHitValid(chunkId)
	if not valid then
		pipeDebugLog(string.format("place blocked chunk=%s reason=%s", tostring(chunkId), tostring(reason)))
		ClientPlotGrid.setStatus(reason or "Cannot place pipe here.", false)
		return
	end
	requestPlacePipe:FireServer({ x = worldPos.X, z = worldPos.Z, chunkId = chunkId })
	pipeDebugLog(string.format("place request chunk=%s x=%.2f z=%.2f", tostring(chunkId), worldPos.X, worldPos.Z))
end

-- =================== FOCUS BILLBOARD ===================

local function ensureFocusBillboard()
	if focusBillboard and focusLabel and focusBillboard.Parent then
		return
	end
	focusBillboard = Instance.new("BillboardGui")
	focusBillboard.Name = "ChunkFocus"
	focusBillboard.Size = UDim2.fromOffset(170, 32)
	focusBillboard.StudsOffset = Vector3.new(0, 4, 0)
	focusBillboard.AlwaysOnTop = true
	focusBillboard.Enabled = false
	focusBillboard.Parent = playerGui

	focusLabel = Instance.new("TextLabel")
	focusLabel.Size = UDim2.fromScale(1, 1)
	focusLabel.BackgroundTransparency = 0.2
	focusLabel.BackgroundColor3 = Color3.fromRGB(21, 27, 38)
	focusLabel.TextColor3 = Color3.fromRGB(239, 239, 239)
	focusLabel.Font = Enum.Font.Merriweather
	focusLabel.TextSize = 12
	focusLabel.Parent = focusBillboard
end

local function updateFocusUi()
	ensureFocusBillboard()
	if not (focusBillboard and focusLabel) then
		return
	end
	local hit, _, chunkId = getTargetedChunkHit()
	if not (hit and chunkId) then
		focusBillboard.Enabled = false
		return
	end
	local chunkStateById = ClientPlotGrid.getChunkStateById()
	local chunk = chunkStateById[chunkId]
	if not chunk then
		focusBillboard.Enabled = false
		return
	end
	-- Use the section's LockOverlay (always present) as adornee since Models need a PrimaryPart
	local adornee: BasePart? = nil
	if hit:IsA("BasePart") then
		adornee = hit
	else
		local overlay = hit:FindFirstChild("LockOverlay")
		if overlay and overlay:IsA("BasePart") then
			adornee = overlay
		end
	end
	if not adornee then
		focusBillboard.Enabled = false
		return
	end
	focusBillboard.Adornee = adornee
	if chunk.unlocked and chunk.revealed then
		-- Show biome + tile name. Oil status line only appears once the chunk has been prospected.
		focusLabel.RichText = true
		local tileInfoText = ""
		if chunk.tiles and mouse.Target and mouse.Target:IsA("BasePart") then
			local targetName = mouse.Target.Name
			local tileData = chunk.tiles[targetName]
			if tileData then
				local tileName = tileData.tileName or "?"
				tileInfoText = string.format(" | %s", tileName)
				if chunk.prospected then
					if tileData.hasOil == false then
						tileInfoText = tileInfoText .. " <font color='rgb(240,70,70)'>— NO OIL</font>"
					else
						tileInfoText = tileInfoText .. " <font color='rgb(80,230,120)'>— HAS OIL</font>"
					end
				end
			end
		end
		focusLabel.Text = string.format("%s%s", chunk.biome or "?", tileInfoText)
		focusLabel.TextColor3 = Color3.fromRGB(160, 230, 170)
	elseif not chunk.unlocked then
		local label = string.format("??? — $%d", chunk.cost or 0)
		if chunk.canBuy == false then
			label = label .. " (no neighbour)"
		end
		focusLabel.Text = label
		focusLabel.TextColor3 = Color3.fromRGB(252, 220, 120)
	end
	focusBillboard.Enabled = true
end

-- =================== HAMMER HOVER ===================

local function ensureHammerHover()
	if hammerHoverBB and hammerHoverBB.Parent then
		return hammerHoverBB, hammerHoverLbl
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "HammerHoverBB"
	bb.Size = UDim2.new(0, 180, 0, 44)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true
	bb.Parent = playerGui
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	lbl.BackgroundTransparency = 0.15
	lbl.TextColor3 = Color3.fromRGB(255, 210, 80)
	lbl.TextStrokeTransparency = 0
	lbl.Font = Enum.Font.Merriweather
	lbl.TextScaled = true
	lbl.Text = ""
	lbl.Parent = bb
	hammerHoverBB = bb
	hammerHoverLbl = lbl
	return bb, lbl
end

local function hideHammerHover()
	if hammerHoverBB then
		hammerHoverBB.Enabled = false
		hammerHoverBB.Adornee = nil
	end
end

-- Called from RenderStepped when hammer is equipped — updates the billboard
local function updateHammerHover()
	local kind = select(1, ClientPlotGrid.getEquippedToolInfo())
	if kind ~= "Hammer" then
		hideHammerHover()
		return
	end
	local target = resolveHammerTarget()
	if not target then
		hideHammerHover()
		return
	end
	-- Find a BasePart on the target to adorn
	local adorn: BasePart? = nil
	local ancestor = mouse.Target
	while ancestor and ancestor.Parent do
		if ancestor:IsA("BasePart") then adorn = ancestor; break end
		ancestor = ancestor.Parent
	end
	if not adorn then hideHammerHover(); return end
	local refund = estimateRefundForTarget(target)
	local bb, lbl = ensureHammerHover()
	bb.Adornee = adorn
	bb.Enabled = true
	if lbl then lbl.Text = string.format("Click to refund $%d", refund) end
end

-- ===================== init =====================

function M.init(params: InitParams)
	player = params.player
	playerGui = params.playerGui
	mouse = params.mouse
	_Workspace = params.Workspace
	_ReplicatedStorage = params.ReplicatedStorage
	OilConfig = params.OilConfig
	Constants = params.Constants
	requestPlacePipe = params.requestPlacePipe
	PlacementAnchor = params.PlacementAnchor
	PlotCellTileResolve = params.PlotCellTileResolve
	ClientPlotGrid = params.ClientPlotGrid
	resolveHammerTarget = params.resolveHammerTarget
	estimateRefundForTarget = params.estimateRefundForTarget
end

-- ===================== exports =====================

M.getTargetedChunkHit = getTargetedChunkHit
M.isChunkUnlocked = isChunkUnlocked
M.getChunkSurfaceY = getChunkSurfaceY
M.surfaceYFromRayTarget = surfaceYFromRayTarget
M.pumpGhostVisualGroundLiftStuds = pumpGhostVisualGroundLiftStuds
M.distanceXZ = distanceXZ
M.isPlacementValid = isPlacementValid
M.updateGhost = updateGhost
M.updatePipeGhost = updatePipeGhost
M.tryPipeAction = tryPipeAction
M.updateFocusUi = updateFocusUi
M.updateHammerHover = updateHammerHover
M.hideGhost = hideGhost
M.hidePipeGhost = hidePipeGhost
M.hideHammerHover = hideHammerHover
M.getPipeHit = getPipeHit
M.pipeDebugLog = pipeDebugLog

return M
