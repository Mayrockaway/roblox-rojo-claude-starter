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

-- ===================== shared utils =====================
local UserInputService = game:GetService("UserInputService")
local ResponsiveBillboard = require(
	game:GetService("ReplicatedStorage")
		:WaitForChild("Shared")
		:WaitForChild("Utils")
		:WaitForChild("ResponsiveBillboard")
)

-- ===================== mobile placement constants =====================
-- Forward projection distance for the touch-device facing preview: the
-- ghost is anchored this far ahead of the player along
-- `HumanoidRootPart.LookVector` (XZ-projected). Locked to
-- `SUB_TILE_SIZE = 8` (one tile ahead) so projecting forward from any
-- position on the player's current tile **reliably crosses the next
-- tile boundary** and snaps to a single, predictable target tile.
-- Smaller values (e.g. 5) made the ghost visually closer but caused the
-- snap raycast to land back on the player's current tile when the
-- player was in the trailing half of it — producing red ghosts over
-- already-drilled tiles the player thought they were past. See chat
-- 2026-04 "red on empty tile" bug repro.
local TOUCH_FORWARD_PROJECTION_STUDS = 8

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

-- Mobile / touch placement: **facing-projection preview**. On pure-touch
-- devices (`TouchEnabled and not MouseEnabled`) the ghost floats one tile
-- ahead of the player along their `HumanoidRootPart` LookVector (XZ-projected)
-- and slides **smoothly** with facing — the visual is the un-snapped
-- projection point, so turning rotates the ghost around the player without
-- it clicking from one tile center to the next. Validity / commit still
-- snap to the host tile (so green/red and the server payload reflect what
-- placement will actually do, matching `OilStateService:_validateTilePlacement`'s
-- own snap). A single tap on the ghost (or its host tile) commits via
-- `tryPrimaryAction`; the desktop click-flow and FTUE cell restrictions
-- are unchanged. See `resolveProjectedTileFromCharacter`, `getDesiredPlacementHit`,
-- and `isTouchOverGhostOrHostTile`.

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

--- True when this client should use the **facing-projection** mobile flow
--- (auto-preview ahead of the character + tap-to-commit) instead of the
--- desktop mouse-cursor flow. Restricted to **pure-touch** devices so
--- hybrid inputs (touchscreen laptops, tablets with hardware mice) keep
--- the precise mouse-cursor placement.
local function isPureTouchDevice(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

--- Snap a raw ray hit to the **center** of the tile BasePart that was
--- struck so the cell-key resolver (`globalCellKeyFromChunkHit`) and the
--- drill-spacing check (`distanceXZ` in `isPlacementValid`) read the
--- authored center, not a corner / edge that could resolve to the wrong
--- cell. Shared between the camera-ray path and the projection path.
local function tileCenterHitFromPart(part: BasePart): Vector3
	return Vector3.new(
		part.Position.X,
		part.Position.Y + part.Size.Y / 2,
		part.Position.Z
	)
end

--- Climb parents of a ray-hit BasePart to find the chunk Model carrying a
--- `ChunkId` attribute. Stops at the owned plot's parent so we never walk
--- the whole DataModel.
local function chunkIdFromInstance(hitInst: Instance, ownedPlot: Model): string?
	local cursor: Instance? = hitInst
	while cursor do
		if typeof(cursor:GetAttribute("ChunkId")) == "string" then
			return cursor:GetAttribute("ChunkId") :: string
		end
		cursor = cursor.Parent
		if cursor == nil or cursor == ownedPlot.Parent then
			return nil
		end
	end
	return nil
end

--- **Mobile facing-projection.** Projects a point one tile ahead of the
--- player's `HumanoidRootPart` along the XZ-flattened LookVector, then
--- short-rays straight down onto the plot to resolve which tile / chunk
--- the ghost should sit on. Returns `(chunkId, snappedHitPos, tileName, rawHitPos)`:
---
---   * `snappedHitPos` — the host tile's authored center XZ + tile-top Y.
---     Used for **validity / commit** so the green/red highlight and the
---     server payload reflect what placement will actually do (server
---     itself also snaps in `OilStateService:_validateTilePlacement`,
---     this matches that authoritative behaviour client-side so spacing
---     and FTUE cell-key checks stay consistent).
---   * `rawHitPos` — the un-snapped projected point. Used by `updateGhost`
---     for the **visual** ghost position so the preview glides smoothly
---     with the player's facing instead of clicking from tile-center to
---     tile-center.
---
--- Why a downward ray (and not a 2D bucket lookup): the plot tiles are
--- already physical BaseParts with `CanQuery=true`, so a 16-stud-tall ray
--- snaps to the correct tile top **and** lets sub-tile resolution match
--- the existing `mouse.Target` semantics for free. Cost is one raycast per
--- frame — same order as the old mouse path.
local function resolveProjectedTileFromCharacter(): (string?, Vector3?, string?, Vector3?)
	if not _player then
		return nil, nil, nil, nil
	end
	local character = _player.Character
	if not character then
		return nil, nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil, nil, nil, nil
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	if not ownedPlot then
		return nil, nil, nil, nil
	end

	-- Flatten LookVector onto XZ (ignore pitch) so looking up/down doesn't
	-- shorten the projected distance.
	local look = hrp.CFrame.LookVector
	local lookXZ = Vector3.new(look.X, 0, look.Z)
	if lookXZ.Magnitude < 1e-3 then
		-- Edge case: character facing straight up/down; fall back to the
		-- HumanoidRootPart's RightVector × world-up so we still pick a
		-- direction instead of hiding the ghost.
		lookXZ = Vector3.new(hrp.CFrame.RightVector.X, 0, hrp.CFrame.RightVector.Z)
		if lookXZ.Magnitude < 1e-3 then
			return nil, nil, nil, nil
		end
	end
	lookXZ = lookXZ.Unit

	local projected = Vector3.new(
		hrp.Position.X + lookXZ.X * TOUCH_FORWARD_PROJECTION_STUDS,
		hrp.Position.Y,
		hrp.Position.Z + lookXZ.Z * TOUCH_FORWARD_PROJECTION_STUDS
	)

	-- Cast straight down from above the projected XZ. Skip the local
	-- character (so HumanoidRootPart / accessories don't intercept) and the
	-- ghost itself (so it doesn't shadow the actual tile when streaming
	-- catches up mid-frame).
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { character }
	if ghostDrill then
		table.insert(exclude, ghostDrill)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true

	local origin = projected + Vector3.new(0, 200, 0)
	local result = _Workspace:Raycast(origin, Vector3.new(0, -400, 0), params)
	if not (result and result.Instance) then
		return nil, nil, nil, nil
	end
	local hitInst = result.Instance
	local chunkId = chunkIdFromInstance(hitInst, ownedPlot)
	if not chunkId then
		return nil, nil, nil, nil
	end
	-- Defence-in-depth: only proceed if the resolved chunk belongs to the
	-- local player's plot state. Stops a stray ray that lands on a
	-- neighbour plot from showing a ghost we couldn't possibly place.
	if not ClientPlotGrid.getChunkPartById()[chunkId] then
		return nil, nil, nil, nil
	end
	-- Raw hit Y comes from the downward ray landing on whatever surface
	-- (tile top, decor, etc.). Use it as-is for the smooth visual; the
	-- snapped Y below is the authoritative tile-top for placement.
	local rawHitPos = result.Position
	local tileName: string? = nil
	local snappedHitPos = rawHitPos
	if hitInst:IsA("BasePart") and hitInst.Name:match("^T%d%d$") then
		tileName = hitInst.Name
		snappedHitPos = tileCenterHitFromPart(hitInst)
	end
	return chunkId, snappedHitPos, tileName, rawHitPos
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

local function isPlacementValid(chunkId: string, hitPos: Vector3, equipKind: string?, tileName: string?): boolean
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
		-- Chunk-level FTUE restriction (WaitDrillOil_WIP): any tile in starter chunk is valid.
		local wantChunk = readLocalFtueCellKey(Constants.FtueRestrictDrillChunkIdAttribute)
		if wantChunk and wantChunk ~= "" then
			if chunkId ~= wantChunk then
				return false
			end
		end
		-- Single-cell FTUE restriction (WaitReveal / legacy)
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
		-- Already-drilled host tile: mirror the server's `TryStartDrill`
		-- gates so the ghost color matches the actual placement outcome
		-- instead of going green and surprising the player with a toast:
		--   * `hasCenterPump`        → permanent center pump, never placeable
		--                              (server: `ERR_CENTER_PUMP`)
		--   * `revealPending`        → drilled but not yet shoveled; ALL
		--                              tiers blocked, even T4+ `canRedrill`,
		--                              so the player has to shovel first
		--                              (server: `ERR_TILE_AWAITING_SHOVEL`)
		--   * drilled + revealed +   → only tiers with `canRedrill = true`
		--     no-redrill tier          (T4+) may re-drill; lower tiers go
		--                              red (server: `ERR_ALREADY_DRILLED`)
		if tileName then
			local ch = chunkStateById[chunkId]
			local tileData = ch and ch.tiles and ch.tiles[tileName]
			if tileData and tileData.drilled then
				if tileData.hasCenterPump then
					return false
				end
				if tileData.revealPending then
					return false
				end
				local _, tier = ClientPlotGrid.getEquippedToolInfo()
				local tierCfg = tier and _OilConfig and _OilConfig.DrillTiers and _OilConfig.DrillTiers[tier]
				if not (tierCfg and tierCfg.canRedrill == true) then
					return false
				end
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
	-- Match the active-drill `TimerGui` design-target (180x70) so the
	-- placement-preview text reads at the same on-screen size as the live
	-- drill timer once placed. Sizing per-viewport is driven by
	-- `ResponsiveBillboard`.
	ResponsiveBillboard.Mark(bb, 180, 70)
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

--- Resolve the **commit / validity** placement coordinate. On **pure-touch
--- devices** (`isPureTouchDevice()`), this returns the facing-projection
--- preview snapped to the host tile's center so green/red highlight, FTUE
--- cell-key, and drill-spacing checks all reflect what placement will
--- actually do (the server snaps too, in `OilStateService:_validateTilePlacement`).
--- On **desktop / hybrid** devices, falls back to the live `mouse.Hit`
--- reading from `getTargetedChunkHit()`.
---
--- For the **visual** ghost position on touch devices (smooth follow
--- instead of tile-snapped), use `resolveTouchGhostVisualHit` instead.
local function getDesiredPlacementHit(): (string?, Vector3?, string?)
	if isPureTouchDevice() then
		local chunkId, snappedHitPos, tileName, _raw = resolveProjectedTileFromCharacter()
		return chunkId, snappedHitPos, tileName
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

--- Visual-only companion to `getDesiredPlacementHit` for the touch flow.
--- Returns the **raw** un-snapped projected hit (so the ghost slides
--- smoothly with the player's facing) plus the chunkId / tileName / snapped
--- hit so `updateGhost` can still drive the surface-Y look-up and validity
--- check from the same single projection call. Returns `nil` on desktop /
--- hybrid devices — desktop ghost positioning stays on the existing
--- `getDesiredPlacementHit` path.
local function resolveTouchGhostVisualHit(): (string?, Vector3?, string?, Vector3?)
	if not isPureTouchDevice() then
		return nil, nil, nil, nil
	end
	return resolveProjectedTileFromCharacter()
end

--- Generous mobile tap target: returns true if a touch at `touchScreenPos`
--- lands on (a) the ghost's **screen-space** projected bounding box,
--- (b) the live ghost preview's geometry via raycast, (c) the ghost's
--- world-space XZ footprint (so a finger that lands on the visible drill
--- silhouette still counts when the ray slips between sparse drill parts —
--- thin stem + small base — and lands on the tile underneath), or (d) the
--- **same tile** the ghost is currently sitting on (`hostChunkId` /
--- `hostTileName`). A tap on a different tile **outside** the ghost's XZ
--- footprint returns false — the player must walk to face that tile, which
--- is the deliberate "aim with body, tap to commit" model.
---
--- Why the screen-space pass exists (check (a)): drills are tall and
--- sparse — the visible silhouette covers a much larger area than the
--- physical `BasePart`s. With `DepthMode = AlwaysOnTop`, the player sees
--- a solid drill outline, but a tap near the **top** of that silhouette
--- shoots a ray that enters the bbox high, finds no part to hit, and
--- continues forward to land on a tile far behind the ghost. Both the
--- world-XZ check (c) and the host-tile check (d) miss in that case.
--- The screen-space check projects the ghost's 3D OBB corners to viewport
--- pixel coords and accepts any tap inside the resulting 2D AABB — which
--- mirrors what the player visually sees regardless of where the world
--- ray ends up. Skipped if any corner is behind the camera (extreme close
--- camera or player inside the ghost) — falls through to the raycast
--- checks below.
---
--- Why the XZ-footprint pass (check (c)) also exists: even when all 8
--- corners are in front of the camera, the world-XZ check still catches
--- taps that resolve onto a neighbour tile inside the ghost's footprint
--- (e.g. when the ghost overhangs slightly during smooth follow).
---
--- The ghost normally has `CanQuery = false` (so its placement raycast
--- doesn't shadow the tile beneath); we flip it on temporarily for the
--- raycast and restore it before returning so no other system sees the
--- ghost as queryable.
local GHOST_XZ_FOOTPRINT_PADDING_STUDS = 0.5
local GHOST_SCREEN_TAP_PAD_PX = 8

local function isTouchOverGhostOrHostTile(
	touchScreenPos: Vector2,
	hostChunkId: string?,
	hostTileName: string?
): boolean
	if not (ghostDrill and ghostDrill.Parent) then
		return false
	end
	local camera = _Workspace.CurrentCamera
	if not camera then
		return false
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	if not ownedPlot then
		return false
	end
	local bbCf, bbSize = ghostDrill:GetBoundingBox()
	-- (a) Screen-space AABB: project the ghost's 3D OBB corners to
	-- viewport pixel coords, build the 2D AABB, accept any tap inside
	-- (with a small pixel pad). Mirrors the visible silhouette since
	-- the highlight is `AlwaysOnTop`. Falls through to raycast checks if
	-- any corner is behind the camera.
	do
		local hx, hy, hz = bbSize.X / 2, bbSize.Y / 2, bbSize.Z / 2
		local corners = {
			Vector3.new(hx, hy, hz),
			Vector3.new(-hx, hy, hz),
			Vector3.new(hx, -hy, hz),
			Vector3.new(-hx, -hy, hz),
			Vector3.new(hx, hy, -hz),
			Vector3.new(-hx, hy, -hz),
			Vector3.new(hx, -hy, -hz),
			Vector3.new(-hx, -hy, -hz),
		}
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		local allInFront = true
		for _, c in ipairs(corners) do
			local world = bbCf * c
			local sp = camera:WorldToViewportPoint(world)
			if sp.Z <= 0 then
				allInFront = false
				break
			end
			if sp.X < minX then minX = sp.X end
			if sp.Y < minY then minY = sp.Y end
			if sp.X > maxX then maxX = sp.X end
			if sp.Y > maxY then maxY = sp.Y end
		end
		if allInFront then
			local pad = GHOST_SCREEN_TAP_PAD_PX
			if
				touchScreenPos.X >= minX - pad and touchScreenPos.X <= maxX + pad
				and touchScreenPos.Y >= minY - pad and touchScreenPos.Y <= maxY + pad
			then
				return true
			end
		end
	end
	-- Snapshot + restore CanQuery on every BasePart in the ghost so the
	-- temporary flip can never leak even if a downstream call yields.
	local restored: { { part: BasePart, prev: boolean } } = {}
	for _, d in ipairs(ghostDrill:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(restored, { part = d, prev = d.CanQuery })
			d.CanQuery = true
		end
	end
	local ray = camera:ViewportPointToRay(touchScreenPos.X, touchScreenPos.Y, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Skip the local character so a tap that grazes the avatar still
	-- resolves to the ghost / tile underneath.
	local exclude: { Instance } = {}
	if _player and _player.Character then
		table.insert(exclude, _player.Character)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local result = _Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	for _, r in ipairs(restored) do
		r.part.CanQuery = r.prev
	end
	if not (result and result.Instance) then
		return false
	end
	local hitInst = result.Instance
	-- (b) Tap landed on the ghost itself → confirm.
	if hitInst:IsDescendantOf(ghostDrill) then
		return true
	end
	-- (c) Tap landed on a non-ghost surface, but the world hit position
	-- falls inside the ghost's bounding box projected onto the XZ plane
	-- (plus a small forgiveness pad). Catches the "ray slipped past the
	-- sparse drill parts and resolved to the tile underneath" case where
	-- the player visually tapped clean inside the green drill silhouette.
	-- Compared in the bbox's local frame so a rotated ghost still tests
	-- correctly.
	local hitPos = result.Position
	local localHit = bbCf:PointToObjectSpace(Vector3.new(hitPos.X, bbCf.Position.Y, hitPos.Z))
	local pad = GHOST_XZ_FOOTPRINT_PADDING_STUDS
	if math.abs(localHit.X) <= bbSize.X / 2 + pad and math.abs(localHit.Z) <= bbSize.Z / 2 + pad then
		return true
	end
	-- (d) Tap landed on the same tile the ghost is sitting on → confirm.
	if hostChunkId and hostTileName then
		if hitInst:IsA("BasePart") and hitInst.Name == hostTileName then
			local chunkId = chunkIdFromInstance(hitInst, ownedPlot)
			if chunkId == hostChunkId then
				return true
			end
		end
	end
	return false
end

local function updateGhost()
	local kind = select(1, ClientPlotGrid.getEquippedToolInfo())
	local equipped = ClientPlotGrid.getEquippedToolName()
	if kind ~= "Drill" and equipped ~= TOOL_DRILL then
		-- Off-Drill: hide the ghost. Touch projection is computed live every
		-- frame from `getDesiredPlacementHit`, so there's no preview state
		-- left to clear here (the old tap-to-preview lock was retired).
		hideGhost()
		return
	end
	-- Touch flow: one projection call returns both the **snapped** hit
	-- (used for validity / surface Y / commit) and the **raw** hit (used
	-- for the smooth ghost visual that follows facing without snapping
	-- between tile centers). Desktop / hybrid devices fall through to the
	-- mouse-cursor path with no visual override.
	local chunkId: string?, hitPos: Vector3?, tileName: string?, rawHitPos: Vector3?
	if isPureTouchDevice() then
		chunkId, hitPos, tileName, rawHitPos = resolveProjectedTileFromCharacter()
	else
		chunkId, hitPos, tileName = getDesiredPlacementHit()
	end
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
	--   2. Touch-projection's host tile name → look up that tile's Y in
	--      the chunk so the ghost sits flush with the tile that placement
	--      will actually land on.
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
	-- **Visual XZ:** prefer the raw projected XZ on touch devices so the
	-- preview slides smoothly with the player's facing. Snapped Y stays
	-- (so the ghost rests on the host tile's top, not at the raw ray's
	-- decor-or-tile-edge Y), and validity / commit still use the snapped
	-- XZ below — only the visible position drifts within the tile.
	local visualX, visualZ = hitPos.X, hitPos.Z
	if rawHitPos then
		visualX, visualZ = rawHitPos.X, rawHitPos.Z
	end
	g:PivotTo(CFrame.new(visualX, surfaceY + pivotToBottom, visualZ))
	if ghostTimerAnchor then
		ghostTimerAnchor.Position = getGhostTimerAnchorPosition(g, Vector3.new(visualX, surfaceY + 3, visualZ))
	end
	if ghostHighlight then
		if isPlacementValid(chunkId, hitPos, equipKind, tileName) then
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
		-- Sizing is driven by `ResponsiveBillboard` (the client controller
		-- in init.client rescales tagged BillboardGuis on viewport change),
		-- so no per-call size assertion is needed here.
		return
	end
	focusBillboard = Instance.new("BillboardGui")
	focusBillboard.Name = "ChunkFocus"
	-- Design-target pixel size at the reference viewport (1366 wide). The
	-- responsive controller shrinks for phones and grows for 4K so the
	-- on-screen proportion is the same across devices. Distance falloff
	-- stays intact (`Size` is still in offset units).
	-- Base trimmed from 280×56 → 230×46 to dial down the tile hover label
	-- footprint on mobile (the responsive controller's MIN_SCALE clamp meant
	-- phones were already capped, so the effective shrink hits hardest there
	-- — exactly what the request was — with only a slight reduction on
	-- desktop / 4K.
	ResponsiveBillboard.Mark(focusBillboard, 230, 46)
	focusBillboard.StudsOffset = Vector3.new(0, 4.5, 0)
	focusBillboard.AlwaysOnTop = true
	focusBillboard.Enabled = false
	focusBillboard.Parent = playerGui

	focusLabel = Instance.new("TextLabel")
	focusLabel.Size = UDim2.fromScale(1, 1)
	focusLabel.BackgroundTransparency = 0.2
	focusLabel.BackgroundColor3 = Color3.fromRGB(21, 27, 38)
	focusLabel.TextColor3 = Color3.fromRGB(239, 239, 239)
	focusLabel.Font = Enum.Font.LuckiestGuy
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
	-- Generous ceiling: the responsive controller scales the box up on big
	-- viewports, so a low MaxTextSize would leave 4K text underfilling the
	-- larger box. MinTextSize keeps small-phone text legible.
	sizeCap.MinTextSize = 14
	sizeCap.MaxTextSize = 50
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
-- Mobile placement (facing-projection preview + generous tap-to-commit):
M.getDesiredPlacementHit = getDesiredPlacementHit
M.isPureTouchDevice = isPureTouchDevice
M.resolveProjectedTileFromCharacter = resolveProjectedTileFromCharacter
M.resolveTouchGhostVisualHit = resolveTouchGhostVisualHit
M.isTouchOverGhostOrHostTile = isTouchOverGhostOrHostTile

--- Returns the current ghost drill Model (or nil if hidden).
function M.getGhostDrill(): Model?
	return ghostDrill
end

--- Direct mouse-target hit for mobile (no ghost projection).
--- Returns chunkId, snapped hit position, and tile name from whatever
--- tile the player tapped on.
function M.getChunkHitFromMouse(): (string?, Vector3?, string?)
	local target = mouse.Target
	if not (target and target:IsA("BasePart")) then
		return nil, nil, nil
	end
	local ownedPlot = ClientPlotGrid.getOwnedPlot()
	if not ownedPlot then
		return nil, nil, nil
	end
	-- Walk up parents looking for ChunkId
	local cursor: Instance? = target
	local chunkId: string? = nil
	while cursor do
		local cid = cursor:GetAttribute("ChunkId")
		if typeof(cid) == "string" then
			chunkId = cid
			break
		end
		cursor = cursor.Parent
	end
	if not chunkId then
		return nil, nil, nil
	end
	-- Snap to tile center
	local hitPos = tileCenterHitFromPart(target)
	local tileName = target.Name
	return chunkId, hitPos, tileName
end

return M
