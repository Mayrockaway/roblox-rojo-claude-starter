--!strict
--[[
	PlacementClient — extracted from init.client.luau

	Drills-only refactor: drill is the only player-placeable equipment. This module
	now handles only:
		- The drill ghost preview that follows the mouse cursor on owned chunks
		- The hover focus billboard that shows chunk biome / cost / tile info
		- The hammer hover billboard for sell-back targeting

	All pump / pipe / prospector ghost + placement code was removed. Pumps are
	static center-pump rigs spawned by the server when a chunk is unlocked.
]]

-- ===================== types =====================
export type InitParams = {
	player: Player,
	playerGui: PlayerGui,
	mouse: Mouse,
	Workspace: Workspace,
	ReplicatedStorage: ReplicatedStorage,
	OilConfig: any,
	Constants: any,
	PlacementAnchor: any,
	PlotCellTileResolve: any,
	ClientPlotGrid: any,
	resolveHammerTarget: () -> any?,
	estimateRefundForTarget: (target: any) -> (number, Instance?),
}

-- ===================== module table =====================
local M = {}

-- ===================== upvalues (set by init) =====================
local _player: Player
local playerGui: PlayerGui
local mouse: Mouse
local _Workspace: Workspace
local _ReplicatedStorage: ReplicatedStorage
local _OilConfig: any
local Constants: any
local PlacementAnchor: any
local PlotCellTileResolve: any
local ClientPlotGrid: any
local resolveHammerTarget: () -> any?
local estimateRefundForTarget: (target: any) -> (number, Instance?)

-- ===================== constants =====================
local TOOL_DRILL = "Drill"

-- ===================== internal state =====================
local ghostDrill: Model? = nil
local ghostHighlight: Highlight? = nil
local ghostTemplateName: string? = nil
local ghostTimerAnchor: BasePart? = nil
local ghostTimerBB: BillboardGui? = nil
local ghostTimerLabel: TextLabel? = nil

local focusBillboard: BillboardGui? = nil
local focusLabel: TextLabel? = nil

local hammerHoverBB: BillboardGui? = nil
local hammerHoverLbl: TextLabel? = nil

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

-- Maps equipped tool (kind + tier) → RS.Assets template name to preview.
-- Drills-only refactor: only Drill_<tier> templates are valid; everything else
-- returns nil so the ghost stays hidden.
local function resolveGhostTemplateName(): string?
	local kind, tier = ClientPlotGrid.getEquippedToolInfo()
	if kind == "Drill" and tier then return "Drill_" .. tier end
	if ClientPlotGrid.getEquippedToolName() == TOOL_DRILL then return "Drill_T1" end
	return nil
end

local function highestWorldYOfPartOBB(part: BasePart): number
	local cf, sz = part.CFrame, part.Size
	local hx, hy, hz = sz.X / 2, sz.Y / 2, sz.Z / 2
	local highestY = -math.huge
	for _, o in ipairs({
		Vector3.new(hx, hy, hz),
		Vector3.new(-hx, hy, hz),
		Vector3.new(hx, -hy, hz),
		Vector3.new(-hx, -hy, hz),
		Vector3.new(hx, hy, -hz),
		Vector3.new(-hx, hy, -hz),
		Vector3.new(hx, -hy, -hz),
		Vector3.new(-hx, -hy, -hz),
	}) do
		local wy = (cf * o).Y
		if wy > highestY then
			highestY = wy
		end
	end
	return highestY
end

local function getGhostTimerAnchorPosition(model: Model, fallbackPosition: Vector3): Vector3
	local topY = -math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			topY = math.max(topY, highestWorldYOfPartOBB(d))
		end
	end
	if topY > -math.huge then
		local bbCf, _ = model:GetBoundingBox()
		return Vector3.new(bbCf.Position.X, topY + 0.5, bbCf.Position.Z)
	end
	return fallbackPosition
end

local function clearGhostTimerUi()
	if ghostTimerAnchor then
		ghostTimerAnchor:Destroy()
		ghostTimerAnchor = nil
	end
	ghostTimerBB = nil
	ghostTimerLabel = nil
end

local function ensureGhost(): Model?
	local wantName = resolveGhostTemplateName()
	if not wantName then return nil end

	-- If the equipped tool changed, rebuild the ghost with the new template
	if ghostDrill and ghostDrill.Parent and ghostTemplateName == wantName then
		return ghostDrill
	end
	if ghostDrill then
		ghostDrill:Destroy()
		ghostDrill = nil
		ghostHighlight = nil
	end
	clearGhostTimerUi()

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

	local timerAnchor = Instance.new("Part")
	timerAnchor.Name = "GhostTimerAnchor"
	timerAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
	timerAnchor.Transparency = 1
	timerAnchor.Anchored = true
	timerAnchor.CanCollide = false
	timerAnchor.CanQuery = false
	timerAnchor.CanTouch = false
	timerAnchor.Parent = _Workspace

	local bb = Instance.new("BillboardGui")
	bb.Name = "GhostTimerGui"
	bb.Adornee = timerAnchor
	bb.Size = UDim2.new(0, 160, 0, 60)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
	bb.AlwaysOnTop = true
	bb.Enabled = false
	bb.Parent = timerAnchor

	local lbl = Instance.new("TextLabel")
	lbl.Name = "GhostTimerLabel"
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundColor3 = Color3.new(0, 0, 0)
	lbl.BackgroundTransparency = 0.4
	lbl.TextColor3 = Color3.fromRGB(255, 230, 100)
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.Text = ""
	lbl.Parent = bb

	ghostDrill = clone
	ghostHighlight = hl
	ghostTemplateName = wantName
	ghostTimerAnchor = timerAnchor
	ghostTimerBB = bb
	ghostTimerLabel = lbl
	return clone
end

local function hideGhost()
	if ghostDrill then
		ghostDrill:Destroy()
		ghostDrill = nil
		ghostHighlight = nil
	end
	clearGhostTimerUi()
end

local function updateGhost()
	local kind = select(1, ClientPlotGrid.getEquippedToolInfo())
	local equipped = ClientPlotGrid.getEquippedToolName()
	if kind ~= "Drill" and equipped ~= TOOL_DRILL then
		hideGhost()
		return
	end
	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then
		hideGhost()
		return
	end
	local equipKind = select(1, ClientPlotGrid.getEquippedToolInfo())
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
	g:PivotTo(CFrame.new(hitPos.X, surfaceY + pivotToBottom, hitPos.Z))
	if ghostTimerAnchor then
		ghostTimerAnchor.Position = getGhostTimerAnchorPosition(g, Vector3.new(hitPos.X, surfaceY + 3, hitPos.Z))
	end
	if ghostHighlight then
		if isPlacementValid(chunkId, hitPos, equipKind) then
			ghostHighlight.FillColor = Color3.fromRGB(80, 220, 120)
			ghostHighlight.OutlineColor = Color3.fromRGB(190, 255, 200)
		else
			ghostHighlight.FillColor = Color3.fromRGB(220, 70, 70)
			ghostHighlight.OutlineColor = Color3.fromRGB(255, 180, 180)
		end
	end

	-- Update ghost timer preview
	if ghostTimerLabel then
		local chunkStateById = ClientPlotGrid.getChunkStateById()
		local chunk = chunkStateById[chunkId]
		local target = mouse.Target
		local _, eqTier = ClientPlotGrid.getEquippedToolInfo()
		if chunk and chunk.tiles and target and target:IsA("BasePart") and eqTier then
			local tileData = chunk.tiles[target.Name]
			local drillTiers = _OilConfig.DrillTiers
			local tierCfg = drillTiers and drillTiers[eqTier]
			if tileData and not tileData.drilled and tierCfg then
				local depth = tonumber(tileData.drillSeconds) or 30
				local speed = tierCfg.timeDivisor or 1
				local secs = math.max(0.5, depth / speed)
				local timeStr
				if secs >= 3600 then
					timeStr = string.format("%.1fh", secs / 3600)
				elseif secs >= 60 then
					timeStr = string.format("%dm %02ds", math.floor(secs / 60), math.floor(secs % 60))
				else
					timeStr = string.format("%.0fs", secs)
				end
				ghostTimerLabel.Text = string.format("0m / %dm\n%s", math.floor(depth), timeStr)
				if ghostTimerBB then
					ghostTimerBB.Enabled = true
				end
			else
				ghostTimerLabel.Text = ""
				if ghostTimerBB then
					ghostTimerBB.Enabled = false
				end
			end
		else
			ghostTimerLabel.Text = ""
			if ghostTimerBB then
				ghostTimerBB.Enabled = false
			end
		end
	end
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
		focusLabel.RichText = true
		local tileInfoText = ""
		if chunk.tiles and mouse.Target and mouse.Target:IsA("BasePart") then
			local targetName = mouse.Target.Name
			local tileData = chunk.tiles[targetName]
			if tileData then
				local tileName = tileData.tileName or "?"
				tileInfoText = string.format(" | %s", tileName)
				if tileData.revealed and tileData.hasOil == false then
					tileInfoText = tileInfoText .. " <font color='rgb(240,70,70)'>— NO OIL</font>"
				elseif tileData.revealed and tileData.hasOil == true then
					tileInfoText = tileInfoText .. " <font color='rgb(80,230,120)'>— HAS OIL</font>"
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
	_player = params.player
	playerGui = params.playerGui
	mouse = params.mouse
	_Workspace = params.Workspace
	_ReplicatedStorage = params.ReplicatedStorage
	_OilConfig = params.OilConfig
	Constants = params.Constants
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
M.distanceXZ = distanceXZ
M.isPlacementValid = isPlacementValid
M.updateGhost = updateGhost
M.updateFocusUi = updateFocusUi
M.updateHammerHover = updateHammerHover
M.hideGhost = hideGhost
M.hideHammerHover = hideHammerHover

return M
