--!strict
-- `ProgressFill.Size` follows **arc-length progress along the voyage polyline** (server `RouteProgress01`).
-- No wall-clock fill during an active shipment — only distance. If the attribute is not yet replicated, fill stays 0
-- briefly. Until `ShipmentVoyageComplete`, then full until `ShipmentResolved`.
-- Cruise hint: `.` → `..` → `...` text only (no UIScale bounce). Strait halt freezes bar.
-- **Studio:** author a `TextLabel` named `Hint` under `ShipmentProgressPanel` (see `docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md`). If track + fill exist but no bindable status line is found, a single `TextLabel` named `Hint` is created under that panel once (fallback only).
-- Wired from `ShipmentProgressBootstrap.client.luau` (expects `{ type, data }` packets with owner id).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StraitEventCatalog = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog"))
local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
--- Coordinates with `ClientPlotGrid.setStatus` / `setStatusLocked` so cruise
--- dots, halt text, and resolved text don't clobber locked or recently-written
--- non-cruise messages (and vice versa). See `HintLineState.luau` header.
local HintLineState = require(script.Parent:WaitForChild("HintLineState")) :: any

local localPlayer = Players.LocalPlayer

--- Lazy-resolve `requestTeleportToShip` from `PlayerScripts.Client.ClientRemotes` for marker spectate clicks.
local cachedTeleportShipRemote: RemoteEvent? = nil
local function resolveTeleportShipRemote(): RemoteEvent?
	if cachedTeleportShipRemote and cachedTeleportShipRemote.Parent then
		return cachedTeleportShipRemote
	end
	local ev = getClientRemotes().requestTeleportToShip
	cachedTeleportShipRemote = ev
	return ev
end

export type Packet = { [string]: any }

type StatusText = TextLabel | TextButton

--- Hint-line text color contract (strict — do NOT introduce gold/yellow
--- shipment text here; gold is reserved for cross-system notifications like
--- the equipment-shop refresh banner from `ShopRefreshNotification`):
---   * `cruise`  — pure white. The default "Shipment safely in progress" tick.
---                 Anything sailing-normal goes through this color; if you find
---                 yourself painting cruise text any other color, that's a bug.
---   * `low`     — orange. Used ONLY for genuinely low-tier hostile events
---                 (coast guard inspection, low-severity strait waypoint).
---                 Still a "bad thing happened" cue, just not loud-red.
---   * `medium`  — red. Most hostile events: pirate raids, mid-tier strait
---                 hits, storm/tornado defaults, missile small-hit.
---   * `high`    — deep red. Catastrophic events: missile direct hit, mine
---                 strike, US ship slap. Same family as `medium` but visibly
---                 angrier so the player can tell "this is the bad one".
---   * `success` — green. Voyage finished without total loss; written by
---                 `ShipmentResolved` happy-path. Reused by `evaded` so a
---                 missile miss reads in the same positive register.
---   * `evaded`  — green. Currently aliased to `success` because both are
---                 "good outcome" signals. Kept as a separate key so a future
---                 designer can split (e.g. softer mint green) without
---                 re-threading every call site.
---   * `lost`    — red. Total-loss / failure path on `ShipmentResolved` and
---                 `StraitWaypointEvent.totalLoss`.
--- ProgressFill colors are cosmetic for the bar fill ONLY; never assigned to
--- `TextColor3`. Keeping them in the same table for one-stop tuning.
local COLORS = {
	cruise = Color3.fromRGB(255, 255, 255),
	low = Color3.fromRGB(255, 150, 60),
	medium = Color3.fromRGB(235, 65, 65),
	high = Color3.fromRGB(210, 35, 35),
	success = Color3.fromRGB(75, 200, 115),
	evaded = Color3.fromRGB(75, 200, 115),
	lost = Color3.fromRGB(235, 65, 65),
	-- ProgressFill: bright gold → warm amber (readable on water). Cosmetic
	-- ONLY — never used for the Hint TextColor3 (gold there would conflict
	-- with the equipment-shop refresh banner).
	progressFillLeft = Color3.fromRGB(255, 232, 120),
	progressFillRight = Color3.fromRGB(255, 155, 55),
	progressFillSolid = Color3.fromRGB(255, 205, 85),
}

local CRUISE_TEXT = "Shipment safely in progress"
--- Hide entirely when there is no active shipment and no recent `setStatus`
--- chatter. Empty string + the `ClientPlotGrid` fade hook (TextTransparency
--- tween at 5s) means the line collapses to nothing on its own; we never
--- print a "Dispatch a shipment to see status here." filler line anymore.
local IDLE_STATUS_TEXT = ""

--- After a halt resolves, only resume cruise dots when the line has had at
--- least this many seconds since its last non-cruise write — matches the 5s
--- fade hold in `ClientPlotGrid` so explicit messages get their full read
--- time before cruise dots come back.
local CRUISE_RESUME_READ_SECONDS = 5

local playerGuiRef: PlayerGui? = nil
local hudChildConn: RBXScriptConnection? = nil
local voyageProgressThread: thread? = nil
local voyageProgressSession = 0

local progressFill: GuiObject? = nil
local progressTrack: GuiObject? = nil
local statusLine: StatusText? = nil
local hintFxScale: UIScale? = nil

local MAX_CROWD_MARKERS = 8
local CROWD_MARKER_HOST_NAME = "CrowdShipmentMarkersHost"

type CrowdStateRow = {
	shipmentId: string?,
	voyageStart: number,
	voyageEnd: number,
	voyageComplete: boolean,
	displayName: string,
	--- Same idea as owner `haltProgressFreezeUntil` / `haltFrozenFillAlpha`: hold marker during strait/cinematic pauses.
	haltFreezeUntil: number?,
	haltFrozenAlpha: number?,
}

local crowdState: { [number]: CrowdStateRow } = {}
local crowdMarkers: { [number]: ImageButton } = {}
local crowdHeartbeatConn: RBXScriptConnection? = nil
local crowdPlayerRemovingConn: RBXScriptConnection? = nil

local voyageStartTime: number? = nil
local voyageEndTime: number? = nil
--- While set, `voyageTick` keeps fill at `haltFrozenFillAlpha` until server time passes (ship halted / strait pause).
local haltProgressFreezeUntil: number? = nil
local haltFrozenFillAlpha: number? = nil
local activeShipmentId: string? = nil
local clearTask: thread? = nil
--- Avoid full Workspace scans every tick once the voyage boat is resolved (same pattern as `ShipmentOceanWavesSfx`).
local routeProgressBoatCache: Model? = nil

local VOYAGE_POLL_SEC = 0.12
--- Server fired `ShipmentVoyageComplete`: bar stays full until `ShipmentResolved`.
local voyageHudComplete = false

local cruiseDotsThread: thread? = nil
local cruiseDotsSession = 0

local haltResumeThread: thread? = nil
local shakeConn: RBXScriptConnection? = nil
local pulseTween: Tween? = nil
local shakeBasePos: UDim2? = nil
local haltGeneration = 0
local shakeGeneration = 0
local lastPanelForInputLock: Instance? = nil
local lastFillStyled: Instance? = nil
local hudStructureConn: RBXScriptConnection? = nil
local hudWatchTarget: Instance? = nil
local tryResolveScheduled = false

local baselineTextColor: Color3 = COLORS.cruise
local baselineRichText: boolean = false
local warnedMissingHint: boolean = false
local warnedPanelDiagnosis: boolean = false

local function ownerIdFromData(data: Packet): number?
	local o = data.ownerUserId or data.playerUserId
	if typeof(o) == "number" then
		return o
	end
	return nil
end

local function shipmentIdFromData(data: Packet): string?
	local sid = data.shipmentId
	if typeof(sid) == "string" then
		return sid
	end
	if typeof(sid) == "number" then
		return tostring(sid)
	end
	return nil
end

local function mineHaltSeconds(data: Packet): number
	local mc = StraitEventCatalog.MineConfig
	local rise = tonumber(data.riseSeconds) or mc.RiseSeconds
	return rise + mc.PauseAfterSurface + 1
end

local function missileBarrageHintSeconds(): number
	local m = StraitEventCatalog.MissileConfig
	local n = math.max(1, m.MissileCount)
	return (n - 1) * m.BarrageStagger + m.FlightSeconds + (m.BarragePauseAfter or 2)
end

--- `HUD` is usually a direct child of `PlayerGui`, but some places nest ScreenGuis; search recursively.
local function findHudScreen(playerGui: PlayerGui): ScreenGui?
	for _, d in ipairs(playerGui:GetChildren()) do
		if d.Name == "HUD" and d:IsA("ScreenGui") then
			return d
		end
	end
	local deep = playerGui:FindFirstChild("HUD", true)
	if deep and deep:IsA("ScreenGui") then
		return deep
	end
	return nil
end

local function scoreShipmentPanel(panel: Instance): number
	local score = 0
	if panel:FindFirstChild("ProgressTrack", true) then
		score += 4
	end
	if panel:FindFirstChild("ProgressFill", true) then
		score += 4
	end
	for _, d in ipairs(panel:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			score += 2
			break
		end
	end
	return score
end

local function gatherShipmentProgressPanelsUnderRoot(root: Instance, candidates: { Instance }, seen: { [Instance]: boolean })
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == "ShipmentProgressPanel" and d:IsA("GuiObject") and not seen[d] then
			seen[d] = true
			table.insert(candidates, d)
		end
	end
end

--- May exist multiple times (templates vs live HUD). Prefer the instance that has track + fill + text.
--- Scopes `GetDescendants` to **`HUD`** (or top-level `LayerCollector`s) — **not** all of `PlayerGui` (avoids ~100k+ nodes when other ScreenGuis churn).
local function findShipmentProgressPanel(playerGui: PlayerGui, hud: ScreenGui?, _canvas: Instance?): Instance?
	local candidates: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	if hud then
		gatherShipmentProgressPanelsUnderRoot(hud, candidates, seen)
	else
		for _, c in ipairs(playerGui:GetChildren()) do
			if c:IsA("LayerCollector") then
				gatherShipmentProgressPanelsUnderRoot(c, candidates, seen)
			end
		end
		if #candidates == 0 then
			gatherShipmentProgressPanelsUnderRoot(playerGui, candidates, seen)
		end
	end
	if #candidates == 0 then
		return nil
	end
	if #candidates == 1 then
		return candidates[1]
	end
	local best = candidates[1]
	local bestScore = scoreShipmentPanel(best)
	for i = 2, #candidates do
		local p = candidates[i]
		local s = scoreShipmentPanel(p)
		if s > bestScore then
			bestScore = s
			best = p
		end
	end
	return best
end

local function applyProgressFillStyle(fill: GuiObject)
	lastFillStyled = fill
	fill.BackgroundColor3 = COLORS.progressFillSolid
	local grad = fill:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(COLORS.progressFillLeft, COLORS.progressFillRight)
		grad.Rotation = 0
	end
	if fill:IsA("ImageLabel") then
		fill.ImageColor3 = COLORS.progressFillSolid
	elseif fill:IsA("ImageButton") then
		fill.ImageColor3 = COLORS.progressFillSolid
	end
end

local function isStatusText(inst: Instance): boolean
	return inst:IsA("TextLabel") or inst:IsA("TextButton")
end

local function getDisplayText(inst: Instance): string
	if inst:IsA("TextLabel") then
		return inst.Text
	end
	if inst:IsA("TextButton") then
		return inst.Text
	end
	return ""
end

--- Static header/title labels (not driven by shipment events) — skip when picking a fallback status line.
local function isLikelyShipmentPanelTitle(inst: Instance): boolean
	if not isStatusText(inst) then
		return false
	end
	local n = string.lower(inst.Name)
	if n == "title" or n == "header" or n == "shipmentstatustitle" then
		return true
	end
	if string.find(n, "title", 1, true) and n ~= "subtitle" and string.find(n, "hint", 1, true) == nil then
		return true
	end
	local raw = getDisplayText(inst)
	local trimmed = string.match(raw, "^%s*(.-)%s*$") or raw
	local t = string.lower(trimmed)
	if t == "shipment status" then
		return true
	end
	return false
end

--- Binds to Studio UI: **`Hint`** = `TextLabel` / `TextButton`, or container `Hint` holding one; else first line under panel / placeholder search.
--- `hintSearchRoot` is usually **`HUD`** so we never walk **`PlayerGui`** for the placeholder pass.
local function findHintLine(panel: Instance, track: Instance?, hintSearchRoot: Instance?): StatusText?
	local function resolveHintInstance(inst: Instance?): StatusText?
		if not inst then
			return nil
		end
		if isStatusText(inst) then
			return inst :: StatusText
		end
		local tl = inst:FindFirstChildWhichIsA("TextLabel", true)
		if tl and tl:IsA("TextLabel") then
			return tl
		end
		local tb = inst:FindFirstChildWhichIsA("TextButton", true)
		if tb and tb:IsA("TextButton") then
			return tb
		end
		return nil
	end

	local h = resolveHintInstance(panel:FindFirstChild("Hint", true))
	if h then
		return h
	end
	if track then
		h = resolveHintInstance(track:FindFirstChild("Hint", true))
		if h then
			return h
		end
	end
	for _, d in ipairs(panel:GetDescendants()) do
		if isStatusText(d) and (not track or not d:IsDescendantOf(track)) and not isLikelyShipmentPanelTitle(d) then
			return d :: StatusText
		end
	end
	for _, d in ipairs(panel:GetDescendants()) do
		if isStatusText(d) and not isLikelyShipmentPanelTitle(d) then
			return d :: StatusText
		end
	end
	local scope = hintSearchRoot or panel
	for _, panelC in ipairs(scope:GetDescendants()) do
		if panelC.Name == "ShipmentProgressPanel" and panelC:IsA("GuiObject") then
			for _, d in ipairs(panelC:GetDescendants()) do
				if isStatusText(d) then
					local t = string.lower(getDisplayText(d))
					if string.find(t, "placeholder", 1, true) or string.find(t, "shipment route", 1, true) then
						return d :: StatusText
					end
				end
			end
		end
	end
	return nil
end

--- Last resort when Studio has track + fill but no `TextLabel` / `TextButton` we can drive.
local function ensureRuntimeHintLabel(panel: Instance): TextLabel
	local existing = panel:FindFirstChild("Hint")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local holder = existing
	if holder and not isStatusText(holder) then
		local inner = holder:FindFirstChildWhichIsA("TextLabel", true)
		if inner and inner:IsA("TextLabel") then
			return inner
		end
		local tl = Instance.new("TextLabel")
		tl.Name = "Line"
		tl.BackgroundTransparency = 1
		tl.Size = UDim2.new(1, 0, 1, 0)
		tl.Font = Enum.Font.Merriweather
		tl.TextSize = 18
		tl.TextColor3 = COLORS.cruise
		tl.TextWrapped = true
		tl.TextXAlignment = Enum.TextXAlignment.Center
		tl.TextYAlignment = Enum.TextYAlignment.Top
		tl.Text = IDLE_STATUS_TEXT
		tl.Parent = holder
		return tl
	end
	local maxOrder = 0
	for _, c in ipairs(panel:GetChildren()) do
		if c:IsA("GuiObject") then
			maxOrder = math.max(maxOrder, (c :: GuiObject).LayoutOrder)
		end
	end
	local tl = Instance.new("TextLabel")
	tl.Name = "Hint"
	tl.BackgroundTransparency = 1
	tl.Size = UDim2.new(1, 0, 0, 28)
	tl.AutomaticSize = Enum.AutomaticSize.Y
	tl.Font = Enum.Font.Merriweather
	tl.TextSize = 18
	tl.TextColor3 = COLORS.cruise
	tl.TextWrapped = true
	tl.TextXAlignment = Enum.TextXAlignment.Center
	tl.TextYAlignment = Enum.TextYAlignment.Top
	tl.Text = IDLE_STATUS_TEXT
	tl.LayoutOrder = maxOrder + 1
	tl.Parent = panel
	return tl
end

local function warnShipmentPanelLayout(panel: Instance)
	if warnedPanelDiagnosis then
		return
	end
	warnedPanelDiagnosis = true
	local parts = {}
	for _, ch in ipairs(panel:GetChildren()) do
		table.insert(parts, string.format("%s(%s)", ch.Name, ch.ClassName))
	end
	warn(
		"[ShipmentProgressHud] `ShipmentProgressPanel` has no bindable TextLabel/TextButton for status. Direct children: "
			.. table.concat(parts, " ")
			.. " — add `Hint` (TextLabel or TextButton) or see CANONICAL_STUDIO_LAYOUT.md."
	)
end

local function findProgressFill(panel: Instance, track: Instance?): GuiObject?
	if track then
		local f = track:FindFirstChild("ProgressFill")
		if f and f:IsA("GuiObject") then
			return f
		end
	end
	local deep = panel:FindFirstChild("ProgressFill", true)
	if deep and deep:IsA("GuiObject") then
		return deep
	end
	return nil
end

local function applyDisplayOnlyInput(panel: Instance)
	for _, d in panel:GetDescendants() do
		if d:IsA("GuiObject") then
			d.Active = false
		end
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			d.Selectable = false
		end
	end
	if panel:IsA("GuiObject") then
		(panel :: GuiObject).Active = false
	end
end

local function findControls(root: PlayerGui): (GuiObject?, StatusText?)
	progressTrack = nil
	local hud = findHudScreen(root)
	local canvas = hud and hud:FindFirstChild("Canvas", true)
	local panel = findShipmentProgressPanel(root, hud, canvas)
	local track = panel and panel:FindFirstChild("ProgressTrack", true)
	if track and track:IsA("GuiObject") then
		progressTrack = track
	end
	local fill = if panel then findProgressFill(panel, track) else nil
	if panel and panel ~= lastPanelForInputLock then
		applyDisplayOnlyInput(panel)
		lastPanelForInputLock = panel
	elseif not panel then
		lastPanelForInputLock = nil
		lastFillStyled = nil
	end
	local fillGo: GuiObject? = nil
	if fill and fill:IsA("GuiObject") then
		fillGo = fill
		applyProgressFillStyle(fillGo)
	end
	local h: StatusText? = if panel then findHintLine(panel, track, hud) else nil
	if panel and fillGo and not h then
		h = ensureRuntimeHintLabel(panel)
	end
	if h then
		h.Active = false
		h.Selectable = false
	end
	if panel and not h then
		warnShipmentPanelLayout(panel)
	end
	return fillGo, h
end

local function crowdRemoveUser(uid: number)
	crowdState[uid] = nil
	local fr = crowdMarkers[uid]
	if fr then
		fr:Destroy()
		crowdMarkers[uid] = nil
	end
end

local function crowdFirstUserId(): number?
	for k, _ in pairs(crowdState) do
		return k
	end
	return nil
end

local function crowdCountUsers(): number
	local n = 0
	for _ in pairs(crowdState) do
		n += 1
	end
	return n
end

local function crowdEnsureHost(track: GuiObject): Frame
	local h = track:FindFirstChild(CROWD_MARKER_HOST_NAME)
	if h and h:IsA("Frame") then
		return h
	end
	local host = Instance.new("Frame")
	host.Name = CROWD_MARKER_HOST_NAME
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = UDim2.new(1, 0, 1, 0)
	host.Position = UDim2.new(0, 0, 0, 0)
	host.ClipsDescendants = false
	host.ZIndex = 12
	host.Parent = track
	return host
end

--- `BoatDockService` parents voyage hulls under **`dOCKS.Boats`** (see `_ensureBoatsFolder` / `CheckoutBoat`).
--- Scan that folder only — avoids `Workspace:GetDescendants()` (~70k+ instances) on every Heartbeat cache miss.
local function getDocksRootForShipmentBoats(): Instance?
	return Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
		or Workspace:FindFirstChild("dOCKS", true)
end

local function getShipmentBoatsFolder(): Folder?
	local docks = getDocksRootForShipmentBoats()
	if not docks then
		return nil
	end
	local boats = docks:FindFirstChild("Boats")
	if boats and boats:IsA("Folder") then
		return boats
	end
	return nil
end

local function collectAllActiveShipmentBoatModels(): { Model }
	local out: { Model } = {}
	local boatsFolder = getShipmentBoatsFolder()
	if boatsFolder then
		for _, inst in ipairs(boatsFolder:GetChildren()) do
			if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" then
				table.insert(out, inst)
			end
		end
		return out
	end
	return out
end

local function clearRouteProgressBoatCache()
	routeProgressBoatCache = nil
end

local function findActiveShipmentBoat(ownerUserId: number, shipmentId: string?): Model?
	if routeProgressBoatCache and routeProgressBoatCache.Parent and routeProgressBoatCache.Name == "ActiveShipmentBoat" then
		if shipmentId and shipmentId ~= "" then
			local csid = routeProgressBoatCache:GetAttribute("ShipmentId")
			if csid ~= nil and tostring(csid) == shipmentId then
				return routeProgressBoatCache
			end
		else
			local co = routeProgressBoatCache:GetAttribute("OwnerUserId")
			if typeof(co) == "number" and co == ownerUserId then
				return routeProgressBoatCache
			end
		end
	end

	local candidates = collectAllActiveShipmentBoatModels()
	-- 1) `ShipmentId` is unique per voyage — match first (works before `OwnerUserId` replicates).
	if shipmentId and shipmentId ~= "" then
		for _, boat in ipairs(candidates) do
			local sid = boat:GetAttribute("ShipmentId")
			if sid ~= nil and tostring(sid) == shipmentId then
				routeProgressBoatCache = boat
				return boat
			end
		end
	end
	-- 2) Owner match once `OwnerUserId` is a number.
	for _, boat in ipairs(candidates) do
		local o = boat:GetAttribute("OwnerUserId")
		if typeof(o) == "number" and o == ownerUserId then
			routeProgressBoatCache = boat
			return boat
		end
	end
	routeProgressBoatCache = nil
	return nil
end

local function routeProgress01FromBoat(ownerUserId: number, shipmentId: string?): number?
	local boat = findActiveShipmentBoat(ownerUserId, shipmentId)
	if not boat then
		return nil
	end
	local r = tonumber(boat:GetAttribute("RouteProgress01"))
	if r == nil then
		return nil
	end
	return math.clamp(r, 0, 1)
end

local function crowdProgressSnapshot(userId: number, row: CrowdStateRow, now: number): number
	local route = routeProgress01FromBoat(userId, row.shipmentId)
	if route ~= nil then
		return route
	end
	return crowdLinearAlphaAtNow(row, now)
end

local function crowdLinearAlphaAtNow(row: CrowdStateRow, now: number): number
	if row.voyageComplete then
		return 1
	end
	local vs, ve = row.voyageStart, row.voyageEnd
	if now <= vs then
		return 0
	elseif now >= ve then
		return 1
	end
	local span = ve - vs
	if span <= 0 then
		return 1
	end
	return (now - vs) / span
end

local function crowdAlphaForRow(userId: number, row: CrowdStateRow): number
	local now = workspace:GetServerTimeNow()
	if row.haltFreezeUntil then
		if now < row.haltFreezeUntil then
			local frozen = row.haltFrozenAlpha
			if typeof(frozen) == "number" then
				return math.clamp(frozen :: number, 0, 1)
			end
			local route = routeProgress01FromBoat(userId, row.shipmentId)
			if route ~= nil then
				return route
			end
			return math.clamp(crowdLinearAlphaAtNow(row, now), 0, 1)
		end
		row.haltFreezeUntil = nil
		row.haltFrozenAlpha = nil
	end
	if row.voyageComplete then
		return 1
	end
	local route = routeProgress01FromBoat(userId, row.shipmentId)
	if route ~= nil then
		return route
	end
	return math.clamp(crowdLinearAlphaAtNow(row, now), 0, 1)
end

local function crowdBuildMarker(userId: number, displayName: string): ImageButton
	-- `ImageButton` root: the whole marker area clicks → spectate teleport. Children
	-- disable `Active` so the parent receives `Activated` cleanly.
	local root = Instance.new("ImageButton")
	root.Name = "CrowdMarker_" .. tostring(userId)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.AutoButtonColor = false
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Size = UDim2.fromOffset(100, 72)
	root.ZIndex = 13
	-- `UIListLayout` child below clashes with a sized ImageButton hit-region, so
	-- we keep the layout on an inner Frame instead.

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.BackgroundTransparency = 1
	inner.BorderSizePixel = 0
	inner.Size = UDim2.fromScale(1, 1)
	inner.Active = false
	inner.ZIndex = 13
	inner.Parent = root

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = inner

	local icon = Instance.new("ImageLabel")
	icon.Name = "Avatar"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(40, 40)
	icon.LayoutOrder = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Active = false
	icon.ZIndex = 13
	icon.Parent = inner

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "DisplayName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0, 18)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 11
	nameLabel.TextColor3 = Color3.fromRGB(228, 236, 248)
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = displayName
	nameLabel.LayoutOrder = 2
	nameLabel.Active = false
	nameLabel.ZIndex = 13
	nameLabel.Parent = inner

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.35
	stroke.Parent = nameLabel

	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)
		end)
		if ok and typeof(url) == "string" and icon.Parent then
			icon.Image = url
		end
	end)

	-- Hover affordance: grow to 110% + brighten name on mouse enter; reset on leave.
	local baseScale = Instance.new("UIScale")
	baseScale.Scale = 1.0
	baseScale.Parent = root
	root.MouseEnter:Connect(function()
		baseScale.Scale = 1.10
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end)
	root.MouseLeave:Connect(function()
		baseScale.Scale = 1.0
		nameLabel.TextColor3 = Color3.fromRGB(228, 236, 248)
	end)

	-- Click → spectate teleport to this player's active voyage boat.
	local lastClickAt = 0.0
	root.Activated:Connect(function()
		if localPlayer and userId == localPlayer.UserId then
			return -- clicking your own marker is a no-op; use the regular ship-teleport button.
		end
		local now = os.clock()
		if now - lastClickAt < 0.4 then
			return
		end
		lastClickAt = now
		local ev = resolveTeleportShipRemote()
		if ev then
			ev:FireServer({ targetUserId = userId })
		end
	end)

	return root
end

local function crowdStep()
	local track = progressTrack
	if not (track and track.Parent) then
		return
	end
	local host = crowdEnsureHost(track)
	for userId, row in pairs(crowdState) do
		local alpha = math.clamp(crowdAlphaForRow(userId, row), 0, 1)
		local fr = crowdMarkers[userId]
		if not fr or not fr.Parent then
			fr = crowdBuildMarker(userId, row.displayName)
			crowdMarkers[userId] = fr
		end
		fr.Parent = host
		fr.Position = UDim2.new(alpha, 0, 0, 2)
	end
end

local function crowdStopHeartbeatIfIdle()
	if not crowdHeartbeatConn then
		return
	end
	if next(crowdState) == nil then
		crowdHeartbeatConn:Disconnect()
		crowdHeartbeatConn = nil
	end
end

local function crowdEnsureHeartbeat()
	if crowdHeartbeatConn then
		return
	end
	if next(crowdState) == nil then
		return
	end
	crowdHeartbeatConn = RunService.Heartbeat:Connect(function()
		if next(crowdState) == nil then
			if crowdHeartbeatConn then
				crowdHeartbeatConn:Disconnect()
				crowdHeartbeatConn = nil
			end
			return
		end
		crowdStep()
	end)
end

local function crowdDisplayName(uid: number, data: Packet): string
	local pl = Players:GetPlayerByUserId(uid)
	if pl then
		return pl.DisplayName
	end
	local s = data.shipDisplayName
	if typeof(s) == "string" and s ~= "" then
		return s
	end
	return "Player"
end

local function crowdOnVisualPacket(kind: string, data: Packet, localPlayer: Player)
	if kind == "ManifestHudSnapshot" then
		return
	end
	local uid = ownerIdFromData(data)
	if typeof(uid) ~= "number" then
		return
	end

	if kind == "ShipmentStarted" then
		if uid == localPlayer.UserId then
			return
		end
		local vs = tonumber(data.voyageStartTime)
		local ve = tonumber(data.voyageEndTime)
		if typeof(vs) ~= "number" or typeof(ve) ~= "number" then
			return
		end
		if crowdCountUsers() >= MAX_CROWD_MARKERS and not crowdState[uid] then
			local victim = crowdFirstUserId()
			if victim then
				crowdRemoveUser(victim)
			end
		end
		local sid = shipmentIdFromData(data)
		crowdState[uid] = {
			shipmentId = sid,
			voyageStart = vs,
			voyageEnd = ve,
			voyageComplete = false,
			displayName = crowdDisplayName(uid, data),
			haltFreezeUntil = nil,
			haltFrozenAlpha = nil,
		}
		local old = crowdMarkers[uid]
		if old then
			old:Destroy()
			crowdMarkers[uid] = nil
		end
		crowdEnsureHeartbeat()
		crowdStep()
		return
	end

	if kind == "ShipmentVoyageComplete" then
		if uid == localPlayer.UserId then
			return
		end
		local st = crowdState[uid]
		if not st then
			return
		end
		local sid = shipmentIdFromData(data)
		if st.shipmentId and sid and sid ~= st.shipmentId then
			return
		end
		st.voyageComplete = true
		crowdStep()
		return
	end

	if kind == "ShipmentResolved" then
		if uid == localPlayer.UserId then
			return
		end
		local st = crowdState[uid]
		local sid = shipmentIdFromData(data)
		if st and st.shipmentId and sid and sid ~= st.shipmentId then
			return
		end
		crowdRemoveUser(uid)
		crowdStopHeartbeatIfIdle()
		return
	end

	-- Other players: mirror owner's progress bar — freeze marker for strait pauses and cinematic sequences.
	if uid == localPlayer.UserId then
		return
	end
	local stOther = crowdState[uid]
	if not stOther then
		return
	end
	local sidOther = shipmentIdFromData(data)
	if stOther.shipmentId and sidOther and sidOther ~= stOther.shipmentId then
		return
	end

	local nowOther = workspace:GetServerTimeNow()
	local function startCrowdHalt(holdSeconds: number)
		local hold = math.clamp(holdSeconds, 0.35, 120)
		stOther.haltFrozenAlpha = crowdProgressSnapshot(uid, stOther, nowOther)
		stOther.haltFreezeUntil = nowOther + hold
		crowdStep()
	end

	if kind == "StraitWaypointEvent" then
		local totalLoss = data.totalLoss == true
		local pauseSec = tonumber(data.pauseSeconds) or 0
		if totalLoss then
			local hold = math.clamp(if pauseSec > 0 then pauseSec else 5, 0.35, 60)
			stOther.haltFrozenAlpha = crowdProgressSnapshot(uid, stOther, nowOther)
			stOther.haltFreezeUntil = nowOther + hold
			crowdStep()
		else
			local hold = if pauseSec > 0 then pauseSec else 0.85
			startCrowdHalt(hold)
		end
		return
	end

	if kind == "PirateRaidEvent" then
		startCrowdHalt(StraitEventCatalog.PirateRaidConfig.SequenceDuration)
		return
	end

	if kind == "MineStrikeEvent" then
		startCrowdHalt(mineHaltSeconds(data))
		return
	end

	if kind == "MissileStrikeEvent" then
		local idx = tonumber(data.missileIndex) or 1
		if idx ~= 1 then
			return
		end
		startCrowdHalt(missileBarrageHintSeconds())
		return
	end

	if kind == "StormEvent" then
		local hold = tonumber(data.sequenceSeconds) or StraitEventCatalog.StormConfig.BaseSequenceSeconds
		startCrowdHalt(hold)
		return
	end

	if kind == "TornadoEvent" then
		local hold = tonumber(data.sequenceSeconds) or StraitEventCatalog.TornadoConfig.BaseSequenceSeconds
		startCrowdHalt(hold)
		return
	end

	if kind == "CoastGuardInspectionEvent" then
		startCrowdHalt(StraitEventCatalog.CoastGuardInspectionConfig.SequenceDuration)
		return
	end

	if kind == "USShipSlapEvent" then
		startCrowdHalt(StraitEventCatalog.USShipSlapConfig.SequenceDuration)
		return
	end
end

local function crowdRebindMarkersToTrack()
	local track = progressTrack
	if not (track and track.Parent) then
		for id, fr in pairs(crowdMarkers) do
			fr:Destroy()
			crowdMarkers[id] = nil
		end
		return
	end
	local host = crowdEnsureHost(track)
	for id, fr in pairs(crowdMarkers) do
		if crowdState[id] then
			fr.Parent = host
		else
			fr:Destroy()
			crowdMarkers[id] = nil
		end
	end
	task.defer(crowdStep)
end

local function ensureHintFxScale(line: StatusText): UIScale
	local existing = line:FindFirstChild("HintFxScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = "HintFxScale"
	s.Scale = 1
	s.Parent = line
	return s
end

local function setFillScaleX(alpha: number)
	local fill = progressFill
	if not (fill and fill.Parent) then
		return
	end
	local a = math.clamp(alpha, 0, 1)
	fill.Size = UDim2.new(a, 0, 1, 0)
end

local function bindHudStructureWatch(hud: Instance)
	if hudWatchTarget == hud and hudStructureConn then
		return
	end
	if hudStructureConn then
		hudStructureConn:Disconnect()
		hudStructureConn = nil
	end
	hudWatchTarget = hud
	hudStructureConn = hud.DescendantAdded:Connect(function(desc)
		local n = desc.Name
		if n == "ShipmentProgressPanel" or n == "ProgressTrack" or n == "ProgressFill" then
			task.defer(tryResolve)
			return
		end
		-- `Hint` is a common name across HUDs; only re-resolve when it belongs to a shipment panel tree.
		if n == "Hint" then
			local a: Instance? = desc.Parent
			while a do
				if a.Name == "ShipmentProgressPanel" then
					task.defer(tryResolve)
					return
				end
				a = a.Parent
			end
		end
	end)
end

local function tryResolveOnce()
	local pg = playerGuiRef
	if not pg then
		return
	end
	local hud = findHudScreen(pg)
	local panelBefore = pg:FindFirstChild("ShipmentProgressPanel", true)
	local screenForWatch: Instance? = hud
	if not screenForWatch and panelBefore then
		screenForWatch = panelBefore:FindFirstAncestorOfClass("ScreenGui")
	end
	if screenForWatch then
		bindHudStructureWatch(screenForWatch)
	end
	local fill, line = findControls(pg)
	progressFill = fill
	statusLine = line
	crowdRebindMarkersToTrack()
	if line then
		hintFxScale = ensureHintFxScale(line)
		shakeBasePos = line.Position
		-- Hard-code cruise white as the baseline rather than reading
		-- `line.TextColor3`. If a panel rebuild fires `tryResolve` mid-banner
		-- (e.g. `ShopRefreshNotification` painted gold a moment ago, then
		-- `ShipmentProgressPanel` was destroyed/recreated by a Studio sync),
		-- reading the live color would latch the banner's color as the
		-- "neutral" cruise color and `restoreHintBaseline` would later
		-- "restore" the line back to gold. Cruise is pure white, full stop.
		baselineTextColor = COLORS.cruise
		baselineRichText = line.RichText
		if not activeShipmentId then
			local t = line.Text
			local trimmed = string.match(t, "^%s*(.-)%s*$") or t
			local lower = string.lower(trimmed)
			if
				trimmed == ""
				or string.find(lower, "placeholder", 1, true)
				or string.find(lower, "shipment route", 1, true)
				or lower == "shipment status"
			then
				line.Text = IDLE_STATUS_TEXT
			end
		end
	end
end

--- Coalesce bursts (e.g. many `DescendantAdded` in one frame) into a single bind pass.
local function tryResolve()
	if tryResolveScheduled then
		return
	end
	tryResolveScheduled = true
	task.defer(function()
		tryResolveScheduled = false
		tryResolveOnce()
	end)
end

local function stopCruiseDots()
	if cruiseDotsThread then
		task.cancel(cruiseDotsThread)
		cruiseDotsThread = nil
	end
	cruiseDotsSession += 1
end

local function stopHaltResume()
	if haltResumeThread then
		task.cancel(haltResumeThread)
		haltResumeThread = nil
	end
end

local function stopShake()
	shakeGeneration += 1
	if shakeConn then
		shakeConn:Disconnect()
		shakeConn = nil
	end
	local h = statusLine
	if h and h.Parent and shakeBasePos then
		h.Position = shakeBasePos
	end
end

local function stopPulseTween()
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
end

local function cancelAllHintFx()
	haltGeneration += 1
	stopCruiseDots()
	stopHaltResume()
	stopShake()
	stopPulseTween()
	local scale = hintFxScale
	if scale then
		scale.Scale = 1
	end
end

local function restoreHintBaseline()
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	h.TextColor3 = baselineTextColor
	h.RichText = baselineRichText
	if shakeBasePos then
		h.Position = shakeBasePos
	end
	if hintFxScale then
		hintFxScale.Scale = 1
	end
end

local function startCruiseDots()
	stopCruiseDots()
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	restoreHintBaseline()
	h.RichText = false
	h.TextColor3 = COLORS.cruise
	local sid = cruiseDotsSession
	local phase = 0
	-- Cruise tick is the lowest-priority writer on the Hint line: skip the
	-- text update while a higher-priority lock is active (e.g. contractor
	-- "your hit landed" gold notification from `setStatusLocked`). The lock
	-- typically lines up with the 5s fade hold, so cruise resumes naturally
	-- once the lock expires.
	if not HintLineState.isLocked() then
		h.TextColor3 = COLORS.cruise
		h.Text = CRUISE_TEXT .. "."
	end
	cruiseDotsThread = task.spawn(function()
		while sid == cruiseDotsSession and h.Parent do
			phase = (phase % 3) + 1
			-- Re-assert cruise color every tick (not just on `startCruiseDots`).
			-- Other writers (`setStatusLocked` from the equipment-shop refresh
			-- banner, the contractor "your hit landed" alert, etc.) repaint
			-- the line and the cruise loop must own its color back the moment
			-- the lock window expires, otherwise cruise text inherits the
			-- previous writer's color (the "everything looks gold" bug).
			if not HintLineState.isLocked() then
				local dots = string.rep(".", phase)
				h.TextColor3 = COLORS.cruise
				h.Text = CRUISE_TEXT .. dots
			end
			task.wait(0.42)
		end
	end)
end

local function severityKey(sev: string): "low" | "medium" | "high"
	local s = string.lower(sev)
	if s == "low" then
		return "low"
	elseif s == "high" then
		return "high"
	end
	return "medium"
end

local function startPulseLoop(level: "low" | "medium" | "high")
	stopPulseTween()
	local scale = hintFxScale
	if not (scale and scale.Parent) then
		return
	end
	local gen = haltGeneration
	local peak = if level == "low" then 1.035 elseif level == "medium" then 1.07 else 1.1
	local dur = if level == "low" then 0.55 elseif level == "medium" then 0.42 else 0.32
	local function pulseOut()
		if not scale.Parent or gen ~= haltGeneration then
			return
		end
		pulseTween = TweenService:Create(scale, TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Scale = peak })
		pulseTween:Play()
		pulseTween.Completed:Wait()
		if not scale.Parent or gen ~= haltGeneration then
			return
		end
		pulseTween = TweenService:Create(scale, TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { Scale = 1 })
		pulseTween:Play()
		pulseTween.Completed:Wait()
	end
	task.spawn(function()
		while gen == haltGeneration and scale.Parent do
			pulseOut()
		end
	end)
end

local function startShake(intensity: number)
	stopShake()
	local h = statusLine
	if not (h and h.Parent and shakeBasePos) then
		return
	end
	local base = shakeBasePos
	local acc = 0
	local gen = shakeGeneration
	shakeConn = RunService.RenderStepped:Connect(function(dt)
		if gen ~= shakeGeneration or not h.Parent then
			return
		end
		acc += dt * 22
		local ox = math.sin(acc * 1.7) * intensity
		local oy = math.cos(acc * 2.1) * intensity * 0.65
		h.Position = UDim2.new(base.X.Scale, base.X.Offset + ox, base.Y.Scale, base.Y.Offset + oy)
	end)
end

local function progressAlphaFromClock(): number
	if not (voyageStartTime and voyageEndTime) then
		return 0
	end
	local now = workspace:GetServerTimeNow()
	if now < voyageStartTime then
		return 0
	elseif now >= voyageEndTime then
		return 1
	end
	local span = voyageEndTime - voyageStartTime
	if span <= 0 then
		return 1
	end
	return (now - voyageStartTime) / span
end

--- `RouteProgress01` only (polyline distance 0–1 from server). Never ETA clock while a shipment is active.
local function ownerProgressFillAlpha(): number
	local lp = Players.LocalPlayer
	if not lp or not activeShipmentId then
		return progressAlphaFromClock()
	end
	local r = routeProgress01FromBoat(lp.UserId, activeShipmentId)
	if r ~= nil then
		return r
	end
	return 0
end

--- Try to resume cruise dots after a halt, but back off until any recent
--- non-cruise message (`setStatus` chatter, halt text, success/loss text) has
--- had `CRUISE_RESUME_READ_SECONDS` of read time on screen, AND the priority
--- lock from `setStatusLocked` has expired. Re-schedules itself instead of
--- writing if either condition isn't met.
local function tryResumeCruiseDots(originalHaltGen: number)
	if originalHaltGen ~= haltGeneration then
		return
	end
	if not activeShipmentId then
		return
	end
	local nowClock = os.clock()
	local sinceLastNonCruise = nowClock - HintLineState.getLastNonCruiseClock()
	if sinceLastNonCruise < CRUISE_RESUME_READ_SECONDS then
		local wait = CRUISE_RESUME_READ_SECONDS - sinceLastNonCruise
		haltResumeThread = task.delay(wait, function()
			haltResumeThread = nil
			tryResumeCruiseDots(originalHaltGen)
		end)
		return
	end
	if HintLineState.isLocked() then
		local lockRemaining = math.max(0.05, HintLineState.getLockExpiryClock() - nowClock)
		haltResumeThread = task.delay(lockRemaining, function()
			haltResumeThread = nil
			tryResumeCruiseDots(originalHaltGen)
		end)
		return
	end
	startCruiseDots()
end

--- Initial UIScale used by `primeStatusPopIn` so the next pulse cycle
--- visually pops the status line up from a smaller-than-rest scale. The
--- pulse loop's first half-tween then carries it up past `1` (Sine-Out
--- to `peak`) and back to `1` — a single perceived "punch" instead of a
--- silent text swap. Tuned conservative so the text remains readable
--- even in the smallest frame; smaller values exaggerate the pop but
--- start to wash out the glyphs against the bar.
local STATUS_POP_INITIAL_SCALE = 0.65

--- Stamp the next pulse-loop start to "pop in" — set the UIScale below 1
--- right before `startPulseLoop`, so the pulse's first Sine-Out tween
--- ramps it up to `peak` from this floor rather than from a flat `1`.
--- Safe no-op if the UIScale isn't authored yet.
local function primeStatusPopIn()
	local scale = hintFxScale
	if scale and scale.Parent then
		scale.Scale = STATUS_POP_INITIAL_SCALE
	end
end

--- Title Case + warning-glyph helper used by the default "Ship Halted!"
--- string and any caller that wants polish without authoring its own
--- decorated label. Glyph defaults to a triangle warning sign (`⚠`) for
--- halts; pass `"✓"` (or any other prefix) for evaded / positive states.
local function decoratedAlertText(label: string, glyph: string?): string
	local g = if typeof(glyph) == "string" and glyph ~= "" then glyph else "⚠"
	return string.format("%s  %s", g, label)
end

--- `customMessage` (optional): overrides the default "⚠ Ship Halted!" text
--- so callers can label the halt with the specific event id (e.g.
--- "⚠ Mine Strike!" or "⚠ Pirate Raid!") for clearer player feedback.
--- Severity coloring + FX still apply. Pass `nil` (or omit) to keep the
--- generic decorated default. Whatever you pass is rendered as-is, so
--- pre-decorate the string with the warning glyph to stay on-style.
local function showHalted(severityRaw: string, holdSeconds: number, customMessage: string?)
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	local hold = math.clamp(holdSeconds, 0.35, 120)
	haltFrozenFillAlpha = ownerProgressFillAlpha()
	haltProgressFreezeUntil = workspace:GetServerTimeNow() + hold
	cancelAllHintFx()
	h.RichText = false
	local level = severityKey(severityRaw)
	-- Skip the text overwrite while a higher-priority lock is active, but keep
	-- driving the FX (pulse / shake / fill freeze) — those are still useful.
	if not HintLineState.isLocked() then
		h.Text = if typeof(customMessage) == "string" and customMessage ~= ""
			then customMessage
			else decoratedAlertText("Ship Halted!", "⚠")
		if level == "low" then
			h.TextColor3 = COLORS.low
		elseif level == "medium" then
			h.TextColor3 = COLORS.medium
		else
			h.TextColor3 = COLORS.high
		end
		HintLineState.markNonCruiseWritten()
	end
	primeStatusPopIn()
	if level == "low" then
		startPulseLoop("low")
	elseif level == "medium" then
		startPulseLoop("medium")
	else
		startPulseLoop("high")
		startShake(2.2)
	end

	local resumeGen = haltGeneration
	haltResumeThread = task.delay(hold, function()
		haltResumeThread = nil
		if resumeGen ~= haltGeneration then
			return
		end
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
		stopShake()
		stopPulseTween()
		if hintFxScale then
			hintFxScale.Scale = 1
		end
		tryResumeCruiseDots(resumeGen)
	end)
end

--- Positive-outcome counterpart to `showHalted` — paints the Hint line green
--- with the supplied evaded message (e.g. "Missile evaded!"), holds the bar
--- frozen for `holdSeconds` so progress doesn't snap forward mid-cinematic,
--- runs a gentle low-tier pulse (no shake — it's good news), then resumes
--- cruise dots. Mirrors `showHalted`'s lock-respecting write so a higher
--- priority message (contractor alert, shop refresh banner) still wins.
local function showEvaded(message: string, holdSeconds: number)
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	local hold = math.clamp(holdSeconds, 0.35, 120)
	haltFrozenFillAlpha = ownerProgressFillAlpha()
	haltProgressFreezeUntil = workspace:GetServerTimeNow() + hold
	cancelAllHintFx()
	h.RichText = false
	if not HintLineState.isLocked() then
		-- Caller may pass a pre-decorated string; otherwise prefix a
		-- positive ✓ check so the green text reads as "good news, this
		-- threat is gone" rather than just-another-event.
		local decorated = if string.sub(message, 1, 1) == "⚠" or string.sub(message, 1, 1) == "✓"
			then message
			else decoratedAlertText(message, "✓")
		h.Text = decorated
		h.TextColor3 = COLORS.evaded
		HintLineState.markNonCruiseWritten()
	end
	primeStatusPopIn()
	startPulseLoop("low")

	local resumeGen = haltGeneration
	haltResumeThread = task.delay(hold, function()
		haltResumeThread = nil
		if resumeGen ~= haltGeneration then
			return
		end
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
		stopPulseTween()
		if hintFxScale then
			hintFxScale.Scale = 1
		end
		tryResumeCruiseDots(resumeGen)
	end)
end

local function showTotalLossDuringPause(holdSeconds: number)
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	local hold = math.clamp(holdSeconds, 0.35, 60)
	haltFrozenFillAlpha = ownerProgressFillAlpha()
	haltProgressFreezeUntil = workspace:GetServerTimeNow() + hold
	cancelAllHintFx()
	h.RichText = false
	if not HintLineState.isLocked() then
		h.Text = decoratedAlertText("Shipment Lost", "⚠")
		h.TextColor3 = COLORS.lost
		HintLineState.markNonCruiseWritten()
	end
	primeStatusPopIn()
	startPulseLoop("high")
	startShake(3.5)
	haltResumeThread = task.delay(hold, function()
		haltResumeThread = nil
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
	end)
	-- Shake/pulse continue until ShipmentResolved or next cancel; do not return to cruise (voyage ends).
end

local function stopVoyageTick()
	if voyageProgressThread then
		task.cancel(voyageProgressThread)
		voyageProgressThread = nil
	end
	voyageProgressSession += 1
end

local function voyageTick()
	if voyageHudComplete then
		if not progressFill or not progressFill.Parent then
			tryResolve()
		end
		if progressFill and progressFill.Parent then
			setFillScaleX(1)
		end
		return
	end
	if not (voyageStartTime and voyageEndTime) then
		return
	end
	if not progressFill or not progressFill.Parent or not statusLine or not statusLine.Parent then
		tryResolve()
	end
	if not progressFill then
		return
	end
	local now = workspace:GetServerTimeNow()
	if haltProgressFreezeUntil then
		if now < haltProgressFreezeUntil then
			setFillScaleX(haltFrozenFillAlpha or 0)
			return
		end
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
	end
	setFillScaleX(ownerProgressFillAlpha())
end

local function startVoyageTick()
	stopVoyageTick()
	local sid = voyageProgressSession
	voyageProgressThread = task.spawn(function()
		while sid == voyageProgressSession do
			if voyageHudComplete or (voyageStartTime and voyageEndTime) then
				voyageTick()
			end
			task.wait(VOYAGE_POLL_SEC)
		end
	end)
end

local function stopClearTask()
	if clearTask then
		task.cancel(clearTask)
		clearTask = nil
	end
end

local function matchesActiveShipment(data: Packet): boolean
	local sid = shipmentIdFromData(data)
	if not activeShipmentId then
		return false
	end
	return sid == nil or sid == activeShipmentId
end

local ShipmentProgressHud = {}

function ShipmentProgressHud.init(playerGui: PlayerGui)
	playerGuiRef = playerGui
	if not crowdPlayerRemovingConn then
		crowdPlayerRemovingConn = Players.PlayerRemoving:Connect(function(left)
			crowdRemoveUser(left.UserId)
			crowdStopHeartbeatIfIdle()
		end)
	end
	tryResolve()
	setFillScaleX(0)
	if not hudChildConn then
		hudChildConn = playerGui.ChildAdded:Connect(function(child)
			if child.Name == "HUD" or child:IsA("ScreenGui") then
				task.defer(function()
					tryResolve()
					setFillScaleX(0)
				end)
			end
		end)
	end
	task.spawn(function()
		for _ = 1, 40 do
			tryResolve()
			setFillScaleX(0)
			if progressFill then
				break
			end
			task.wait(0.25)
		end
	end)
end

function ShipmentProgressHud.onVisualPacket(kind: string, data: Packet, localPlayer: Player)
	if not (progressFill and progressFill.Parent and statusLine and statusLine.Parent) then
		tryResolve()
	end

	crowdOnVisualPacket(kind, data, localPlayer)

	local uid = ownerIdFromData(data)
	if typeof(uid) ~= "number" or uid ~= localPlayer.UserId then
		return
	end

	-- Manifest HUD listens separately; do not treat as shipment progress.
	if kind == "ManifestHudSnapshot" then
		return
	end

	if kind == "ShipmentResolved" then
		local sid = shipmentIdFromData(data)
		if sid and activeShipmentId and sid ~= activeShipmentId then
			return
		end

		stopClearTask()
		cancelAllHintFx()
		stopVoyageTick()
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
		voyageHudComplete = false
		voyageStartTime = nil
		voyageEndTime = nil
		activeShipmentId = nil
		clearRouteProgressBoatCache()
		setFillScaleX(0)

		if not (progressFill and progressFill.Parent and statusLine and statusLine.Parent) then
			tryResolve()
		end

		local h = statusLine
		local failed = typeof(data.failureReason) == "string" and (data.failureReason :: string) ~= ""
		if h and h.Parent then
			if failed then
				h.RichText = false
				if not HintLineState.isLocked() then
					h.Text = "Shipment lost…"
					h.TextColor3 = COLORS.lost
					HintLineState.markNonCruiseWritten()
				end
				startShake(4)
				startPulseLoop("high")
			else
				local lost = tonumber(data.lost) or 0
				h.RichText = false
				if not HintLineState.isLocked() then
					h.TextColor3 = COLORS.success
					if lost > 0 then
						h.Text = string.format(
							"Shipment successful! %d barrel(s) lost at sea — the rest reached your warehouse.",
							lost
						)
					else
						h.Text = "Shipment successful!"
					end
					HintLineState.markNonCruiseWritten()
				end
				if hintFxScale then
					hintFxScale.Scale = 1
					local pop = TweenService:Create(
						hintFxScale,
						TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
						{ Scale = 1.18 }
					)
					pop:Play()
					pop.Completed:Connect(function()
						if hintFxScale and hintFxScale.Parent then
							TweenService:Create(
								hintFxScale,
								TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
								{ Scale = 1 }
							):Play()
						end
					end)
				end
			end
		end

		clearTask = task.delay(3.4, function()
			clearTask = nil
			-- Always cancel the FX state (shake / pulse) here — it would otherwise
			-- keep running until the next ShipmentStarted/Resolved cancelAllHintFx.
			cancelAllHintFx()
			restoreHintBaseline()
			-- Clear text only if nothing more recent has claimed the line in the
			-- last `CRUISE_RESUME_READ_SECONDS` and no priority lock is active.
			-- Otherwise leave the recent message visible (the fade hook will
			-- still hide it on its own 5s timer).
			if statusLine and statusLine.Parent then
				local sinceLastNonCruise = os.clock() - HintLineState.getLastNonCruiseClock()
				if not HintLineState.isLocked() and sinceLastNonCruise >= CRUISE_RESUME_READ_SECONDS then
					statusLine.Text = IDLE_STATUS_TEXT
					statusLine.RichText = baselineRichText
				end
			end
			setFillScaleX(0)
		end)
		return
	end

	if kind == "ShipmentStarted" then
		stopClearTask()
		cancelAllHintFx()
		clearRouteProgressBoatCache()
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
		voyageHudComplete = false
		local voyageStart = tonumber(data.voyageStartTime)
		local voyageEnd = tonumber(data.voyageEndTime)
		if typeof(voyageStart) == "number" and typeof(voyageEnd) == "number" then
			voyageStartTime = voyageStart
			voyageEndTime = voyageEnd
		else
			-- Legacy tanker path: progress bar only if times exist.
			voyageStartTime = nil
			voyageEndTime = nil
		end
		activeShipmentId = shipmentIdFromData(data)
		tryResolve()
		setFillScaleX(0)
		if not (statusLine and statusLine.Parent) then
			if not warnedMissingHint then
				warnedMissingHint = true
				warn(
					"[ShipmentProgressHud] Could not bind status text. Add `TextLabel` or `TextButton` named `Hint` under `ShipmentProgressPanel`, "
						.. "or ensure one status line (TextLabel/TextButton) exists under that panel / ProgressTrack. "
						.. "Check Output for `[ShipmentProgressHud] ShipmentProgressPanel has no bindable…` if layout is wrong. "
						.. "See docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md § ShipmentProgressPanel (Studio)."
				)
			end
		end
		startCruiseDots()
		startVoyageTick()
		return
	end

	if kind == "ShipmentVoyageComplete" then
		if not activeShipmentId then
			return
		end
		local sid = shipmentIdFromData(data)
		if sid and sid ~= activeShipmentId then
			return
		end
		voyageHudComplete = true
		setFillScaleX(1)
		return
	end

	if not matchesActiveShipment(data) then
		return
	end

	if kind == "StraitWaypointEvent" then
		local totalLoss = data.totalLoss == true
		local pauseSec = tonumber(data.pauseSeconds) or 0
		local sev = tostring(data.severity or "Medium")
		if totalLoss then
			showTotalLossDuringPause(if pauseSec > 0 then pauseSec else 5)
		else
			local hold = if pauseSec > 0 then pauseSec else 0.85
			showHalted(sev, hold)
		end
		return
	end

	if kind == "PirateRaidEvent" then
		local sev = tostring(data.severity or "Medium")
		local dur = StraitEventCatalog.PirateRaidConfig.SequenceDuration
		showHalted(sev, dur, decoratedAlertText("Pirate Raid!", "⚠"))
		return
	end

	if kind == "MineStrikeEvent" then
		local sev = tostring(data.severity or "High")
		local total = mineHaltSeconds(data)
		local alertLabel = decoratedAlertText("Mine Strike!", "⚠")
		if data.didHit == true then
			-- Real hit: stay on the alert message for the full halt; the
			-- subsequent total-loss handler will paint the lost state.
			showHalted(sev, total, alertLabel)
		else
			-- Hold "⚠ Mine Strike!" for a full 4s so the player has time
			-- to read the threat before it transitions to the green
			-- "✓ Mine Strike Evaded!" line. Capped to leave at least 0.5s
			-- of evaded message before cruise dots resume on shorter halts.
			-- `showEvaded` calls `cancelAllHintFx` which bumps
			-- `haltGeneration`, so the showHalted resume thread no-ops
			-- and the evaded hold-window cleanly takes over.
			local alertHold = math.min(4, math.max(0.35, total - 0.5))
			showHalted(sev, alertHold, alertLabel)
			task.delay(alertHold, function()
				local remaining = total - alertHold
				if remaining > 0 then
					showEvaded(decoratedAlertText("Mine Strike Evaded!", "✓"), remaining)
				end
			end)
		end
		return
	end

	if kind == "MissileStrikeEvent" then
		local idx = tonumber(data.missileIndex) or 1
		if idx ~= 1 then
			return
		end
		local outcome = tostring(data.outcome or "miss")
		-- Miss = evaded → green positive cue, not an orange halt label.
		-- Hit / smallHit still go through `showHalted` so red shake/pulse fires.
		if outcome == "miss" then
			showEvaded(decoratedAlertText("Missile Evaded!", "✓"), missileBarrageHintSeconds())
		else
			local sev = if outcome == "hit" then "High" else "Medium"
			showHalted(sev, missileBarrageHintSeconds(), decoratedAlertText("Missile Strike!", "⚠"))
		end
		return
	end

	-- Server emits these cinematic / weather events (not only `StraitWaypointEvent`); must cancel cruise dots.
	if kind == "StormEvent" then
		local sev = tostring(data.severity or "Medium")
		local total = tonumber(data.sequenceSeconds) or StraitEventCatalog.StormConfig.BaseSequenceSeconds
		local alertLabel = decoratedAlertText("Thunderstorm!", "⚠")
		local hadLoss = data.didBarrelLoss == true or (tonumber(data.barrelsLost) or 0) > 0
		if hadLoss then
			-- Real storm with barrel loss — stay on the alert message for the
			-- whole sequence; the cargo manifest snapshot will land before
			-- cruise resumes and tells the player what was lost.
			showHalted(sev, total, alertLabel)
		else
			-- Harmless storm (FTUE showcase or a real storm whose rolls came
			-- up empty) — lead with the alert, then transition to a green
			-- "Storm Passed!" so the player isn't left wondering whether
			-- they took damage.
			local alertHold = math.min(4, math.max(0.35, total - 0.5))
			showHalted(sev, alertHold, alertLabel)
			task.delay(alertHold, function()
				local remaining = total - alertHold
				if remaining > 0 then
					showEvaded(decoratedAlertText("Storm Passed!", "✓"), remaining)
				end
			end)
		end
		return
	end

	if kind == "TornadoEvent" then
		local sev = tostring(data.severity or "High")
		local total = tonumber(data.sequenceSeconds) or StraitEventCatalog.TornadoConfig.BaseSequenceSeconds
		local alertLabel = decoratedAlertText("Tornado!", "⚠")
		local hadLoss = data.didBarrelLoss == true or (tonumber(data.barrelsLost) or 0) > 0
		if hadLoss then
			showHalted(sev, total, alertLabel)
		else
			local alertHold = math.min(4, math.max(0.35, total - 0.5))
			showHalted(sev, alertHold, alertLabel)
			task.delay(alertHold, function()
				local remaining = total - alertHold
				if remaining > 0 then
					showEvaded(decoratedAlertText("Tornado Cleared!", "✓"), remaining)
				end
			end)
		end
		return
	end

	if kind == "CoastGuardInspectionEvent" then
		-- Coast Guard inspections never apply barrel loss in any mode (regular
		-- gameplay or FTUE showcase) — they're a cinematic boarding sequence,
		-- not a damage event. Always paint the alert first, then resolve to a
		-- green "Inspection Cleared!" so the line tells a complete story.
		local total = StraitEventCatalog.CoastGuardInspectionConfig.SequenceDuration
		local alertHold = math.min(4, math.max(0.35, total - 0.5))
		showHalted("Low", alertHold, decoratedAlertText("Coast Guard Inspection!", "⚠"))
		task.delay(alertHold, function()
			local remaining = total - alertHold
			if remaining > 0 then
				showEvaded(decoratedAlertText("Inspection Cleared!", "✓"), remaining)
			end
		end)
		return
	end

	if kind == "USShipSlapEvent" then
		local dur = StraitEventCatalog.USShipSlapConfig.SequenceDuration
		showHalted("High", dur, decoratedAlertText("Navy Strike!", "⚠"))
		return
	end
end

return ShipmentProgressHud
