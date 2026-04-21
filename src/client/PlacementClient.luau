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
local IGNORE_FOR_VISUAL_BOUNDS_ATTR = "IgnoreForVisualBounds"

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

-- Mobile / touch placement: tap-to-preview-then-confirm. The active touch flow
-- locks the ghost onto a specific tile (`MobilePreviewHit` below); a second tap
-- on the **same** tile commits via `tryPrimaryAction` while a tap on a
-- different tile re-locks the preview without placing. Cleared automatically
-- when the player switches off Drill (see `updateGhost`).
export type MobilePreviewHit = {
	chunkId: string,
	hitPos: Vector3,
	tileName: string?,
}
local mobilePreviewHit: MobilePreviewHit? = nil

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

--- Camera-ray version of `getTargetedChunkHit` for **touch** input on mobile —
--- `Mouse.Target`/`Mouse.Hit` are unreliable before a tap actually lands, so
--- the touch handler hands us the screen-space tap position and we cast from
--- the live `Camera` through that point. Returns `(chunkId, hitPos, tileName)`
--- so the touch handler can both lock the preview (`tileName` is the snap key
--- for "is the second tap on the same tile?") and re-snap to the surface Y.
local function raycastTouchToChunk(touchScreenPos: Vector2): (string?, Vector3?, string?)
	local camera = _Workspace.CurrentCamera
	if not camera then
		return nil, nil, nil
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	if not ownedPlot then
		return nil, nil, nil
	end

	local ray = camera:ViewportPointToRay(touchScreenPos.X, touchScreenPos.Y, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Ignore the local character so a tap that grazes the player doesn't snap
	-- the ghost onto the avatar instead of the tile underneath.
	local exclude: { Instance } = {}
	if _player and _player.Character then
		table.insert(exclude, _player.Character)
	end
	if ghostDrill then
		table.insert(exclude, ghostDrill)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true

	local result = _Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not result or not result.Instance then
		return nil, nil, nil
	end
	local hitInst = result.Instance
	local hitPos = result.Position

	-- Tile name (T01..T99) is captured so the touch handler can decide whether
	-- a second tap landed on the **same** tile (= confirm) vs a new one (= move
	-- preview). Walk **only** the ray hit itself for the tile name; chunkId is
	-- found by climbing parents like the desktop path does.
	local tileName: string? = nil
	if hitInst:IsA("BasePart") and hitInst.Name:match("^T%d%d$") then
		tileName = hitInst.Name
	end

	local cursor: Instance? = hitInst
	while cursor do
		if typeof(cursor:GetAttribute("ChunkId")) == "string" then
			return cursor:GetAttribute("ChunkId") :: string, hitPos, tileName
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

--- Per-tile surface Y by name (e.g. `"T13"`) inside a specific chunk. Used by
--- the **mobile** path so the locked preview snaps to the **same** Y as the
--- desktop ray-on-tile path even though `mouse.Target` is stale between taps.
local function tileSurfaceYInChunk(chunkId: string, tileName: string): number?
	if tileName == "" then
		return nil
	end
	local sectionModel = ClientPlotGrid.getChunkPartById()[chunkId]
	if not sectionModel then
		return nil
	end
	for _, d in ipairs(sectionModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == tileName then
			return d.Position.Y + d.Size.Y / 2
		end
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
		if d:IsA("BasePart") and d:GetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR) ~= true then
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
	timerAnchor:SetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR, true)
	timerAnchor.Parent = _Workspace

	local bb = Instance.new("BillboardGui")
	bb.Name = "GhostTimerGui"
	bb.Adornee = timerAnchor
	-- Match the active-drill `TimerGui` sizing in `OilVisualService` (180x70)
	-- so the placement-preview text reads at the same on-screen size as the
	-- live drill timer once placed.
	bb.Size = UDim2.new(0, 180, 0, 70)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 80
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
	-- Match the live drill `TimerLabel` (and the rest of the world billboards
	-- like the pump `HoloGui.Info`) so the placement preview reads with the
	-- same font as the timer it becomes once the drill is placed.
	lbl.Font = Enum.Font.LuckiestGuy
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

--- Resolve the current intended placement coordinate. On **mobile**, when the
--- player has locked a preview via the touch handler, that locked hit wins so
--- the ghost stays pinned to the tapped tile while the player decides whether
--- to confirm. On **desktop** (or before the first mobile tap), falls back to
--- the live `mouse.Hit` reading from `getTargetedChunkHit()`.
local function getDesiredPlacementHit(): (string?, Vector3?, string?)
	if mobilePreviewHit ~= nil then
		return mobilePreviewHit.chunkId, mobilePreviewHit.hitPos, mobilePreviewHit.tileName
	end
	local hit, hitPos, chunkId = getTargetedChunkHit()
	if hit and hitPos and chunkId then
		local tileName: string? = nil
		local mt = mouse.Target
		if mt and mt:IsA("BasePart") and mt.Name:match("^T%d%d$") then
			tileName = mt.Name
		end
		return chunkId, hitPos, tileName
	end
	return nil, nil, nil
end

local function getMobilePreviewHit(): MobilePreviewHit?
	return mobilePreviewHit
end

local function setMobilePreviewHit(chunkId: string, hitPos: Vector3, tileName: string?)
	mobilePreviewHit = {
		chunkId = chunkId,
		hitPos = hitPos,
		tileName = tileName,
	}
end

local function clearMobilePreview()
	mobilePreviewHit = nil
end

local function updateGhost()
	local kind = select(1, ClientPlotGrid.getEquippedToolInfo())
	local equipped = ClientPlotGrid.getEquippedToolName()
	if kind ~= "Drill" and equipped ~= TOOL_DRILL then
		-- Switching off Drill must also drop any locked mobile preview so the
		-- next time we re-equip, the ghost doesn't immediately re-appear on a
		-- stale tile.
		mobilePreviewHit = nil
		hideGhost()
		return
	end
	local chunkId, hitPos, tileName = getDesiredPlacementHit()
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
	-- Surface Y resolution priority:
	--   1. `mouse.Target` is a tile part (desktop hover) — exact tile top.
	--   2. Locked mobile preview's tile name → look up that tile's Y in the
	--      chunk so the second-tap-confirm position matches the ghost exactly.
	--   3. Chunk's highest tile Y (conservative — drill won't sink).
	--   4. Raw ray hit Y (last resort).
	local surfaceY = surfaceYFromRayTarget()
	if not surfaceY and tileName then
		surfaceY = tileSurfaceYInChunk(chunkId, tileName)
	end
	surfaceY = surfaceY or getChunkSurfaceY(chunkId) or hitPos.Y
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

	-- Update ghost timer preview. On mobile, `mouse.Target` is stale between
	-- taps so prefer the tile name resolved by `getDesiredPlacementHit` (which
	-- comes from the locked preview when set, else from the live `mouse.Target`).
	if ghostTimerLabel then
		local chunkStateById = ClientPlotGrid.getChunkStateById()
		local chunk = chunkStateById[chunkId]
		local _, eqTier = ClientPlotGrid.getEquippedToolInfo()
		local resolvedTileName = tileName
		if not resolvedTileName then
			local target = mouse.Target
			if target and target:IsA("BasePart") and target.Name:match("^T%d%d$") then
				resolvedTileName = target.Name
			end
		end
		if chunk and chunk.tiles and resolvedTileName and eqTier then
			local tileData = chunk.tiles[resolvedTileName]
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
	-- Slightly larger pixel box. The BillboardGui is distance-scaled by the
	-- engine, so a bigger offset = proportionally bigger label on every
	-- device (phone / desktop / console) without needing per-platform code.
	focusBillboard.Size = UDim2.fromOffset(220, 44)
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
	-- TextScaled (no fixed TextSize) so the label fills the larger box and
	-- scales cleanly with the BillboardGui. UITextSizeConstraint caps the
	-- top end so close-up hover does not blow the text up to giant.
	focusLabel.TextScaled = true
	focusLabel.TextWrapped = false
	focusLabel.TextTruncate = Enum.TextTruncate.None
	focusLabel.Parent = focusBillboard
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = focusLabel
	local sizeCap = Instance.new("UITextSizeConstraint")
	sizeCap.MinTextSize = 10
	sizeCap.MaxTextSize = 22
	sizeCap.Parent = focusLabel
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
				-- Suppress the redundant `| Bronze` segment when the tile's
				-- own name is identical to the chunk biome (the common
				-- "Bronze | Bronze — 0.010 bbl/sec" duplication). The HAS
				-- OIL / NO OIL / bbl/sec suffixes still attach below.
				if tileName ~= (chunk.biome or "?") then
					tileInfoText = string.format(" | %s", tileName)
				end
				if tileData.revealed and tileData.hasOil == false then
					tileInfoText = tileInfoText .. " <font color='rgb(240,70,70)'>— NO OIL</font>"
				elseif tileData.revealed and tileData.hasOil == true then
					tileInfoText = tileInfoText .. " <font color='rgb(80,230,120)'>— HAS OIL</font>"
				end
				-- For drilled tiles, also show the per-tile flow rate they
				-- are contributing to the chunk's center pump. Mirrors the
				-- summation in `OilVisualService:_syncDrills.getFlowRate`
				-- (`def.barrelsPerSecond * pumpMult`) so the hover number
				-- and the pump's hologram add up. Skip non-producing tiles
				-- and the center tile (T33) — neither contributes.
				if
					tileData.drilled == true
					and tileData.hasOil ~= false
					and typeof(tileData.veinTypeId) == "string"
					and targetName ~= "T33"
				then
					local okVc, VeinCrateConfig = pcall(function()
						return require(_ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
					end)
					local okVg, VeinConfig = pcall(function()
						return require(_ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("VeinConfig"))
					end)
					if okVc and okVg and VeinCrateConfig and VeinConfig then
						local def = VeinCrateConfig.GetById(tileData.veinTypeId)
						if def and not def.isUnlucky then
							-- Resolve the chunk's center pump tier so the
							-- displayed bbl/sec matches the multiplier the
							-- pump applies (T1=1, T2=2, T3=4). Fall back to
							-- T1 when no pump record is found yet.
							local pumpMult = 1
							local drillStateById = ClientPlotGrid.getDrillStateById and ClientPlotGrid.getDrillStateById() or {}
							for _, d in pairs(drillStateById) do
								if d.isCenterPump == true and d.chunkId == chunkId then
									local pumpDef = VeinConfig.PumpUpgrades and VeinConfig.PumpUpgrades[d.tier]
									if pumpDef and typeof(pumpDef.flowMult) == "number" then
										pumpMult = pumpDef.flowMult
									end
									break
								end
							end
							local rate = (def.barrelsPerSecond or 0) * pumpMult
							if rate > 0 then
								tileInfoText = tileInfoText
									.. string.format(" <font color='rgb(120,200,255)'>— %.3f bbl/sec</font>", rate)
							end
						end
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
M.tileSurfaceYInChunk = tileSurfaceYInChunk
M.distanceXZ = distanceXZ
M.isPlacementValid = isPlacementValid
M.updateGhost = updateGhost
M.updateFocusUi = updateFocusUi
M.updateHammerHover = updateHammerHover
M.hideGhost = hideGhost
M.hideHammerHover = hideHammerHover
-- Mobile placement (tap-to-preview, tap-again-to-confirm):
M.raycastTouchToChunk = raycastTouchToChunk
M.getDesiredPlacementHit = getDesiredPlacementHit
M.getMobilePreviewHit = getMobilePreviewHit
M.setMobilePreviewHit = setMobilePreviewHit
M.clearMobilePreview = clearMobilePreview

return M
