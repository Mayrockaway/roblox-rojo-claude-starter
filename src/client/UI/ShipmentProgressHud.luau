--!strict
-- `ProgressFill.Size` X scale from `ShipmentStarted` until `ShipmentVoyageComplete` (server: ship reached path end / finish).
-- Cruise hint: `.` → `..` → `...` text only (no UIScale bounce). Strait halt freezes bar.
-- **Studio:** author a `TextLabel` named `Hint` under `ShipmentProgressPanel` (see `docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md`). If track + fill exist but no bindable status line is found, a single `TextLabel` named `Hint` is created under that panel once (fallback only).
-- Wired from `ShipmentProgressBootstrap.client.luau` (expects `{ type, data }` packets with owner id).

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StraitEventCatalog = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog"))

export type Packet = { [string]: any }

type StatusText = TextLabel | TextButton

local COLORS = {
	cruise = Color3.fromRGB(218, 228, 240),
	low = Color3.fromRGB(230, 200, 70),
	medium = Color3.fromRGB(255, 145, 55),
	high = Color3.fromRGB(235, 65, 65),
	success = Color3.fromRGB(75, 200, 115),
	warningLine = Color3.fromRGB(255, 200, 90),
	lost = Color3.fromRGB(240, 70, 70),
	-- ProgressFill: bright gold → warm amber (readable on water)
	progressFillLeft = Color3.fromRGB(255, 232, 120),
	progressFillRight = Color3.fromRGB(255, 155, 55),
	progressFillSolid = Color3.fromRGB(255, 205, 85),
}

local CRUISE_TEXT = "Shipment safely in progress"
local IDLE_STATUS_TEXT = "Dispatch a shipment to see status here."

local playerGuiRef: PlayerGui? = nil
local hudChildConn: RBXScriptConnection? = nil
local voyageProgressThread: thread? = nil
local voyageProgressSession = 0

local progressFill: GuiObject? = nil
local statusLine: StatusText? = nil
local hintFxScale: UIScale? = nil

local voyageStartTime: number? = nil
local voyageEndTime: number? = nil
--- While set, `voyageTick` keeps fill at `haltFrozenFillAlpha` until server time passes (ship halted / strait pause).
local haltProgressFreezeUntil: number? = nil
local haltFrozenFillAlpha: number? = nil
local activeShipmentId: string? = nil
local clearTask: thread? = nil

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

--- May exist multiple times (templates vs live HUD). Prefer the instance that has track + fill + text.
local function findShipmentProgressPanel(playerGui: PlayerGui, _hud: Instance?, _canvas: Instance?): Instance?
	local candidates: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for _, d in ipairs(playerGui:GetDescendants()) do
		if d.Name == "ShipmentProgressPanel" and d:IsA("GuiObject") and not seen[d] then
			seen[d] = true
			table.insert(candidates, d)
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

--- Binds to Studio UI: **`Hint`** = `TextLabel` / `TextButton`, or container `Hint` holding one; else first line under panel / placeholder search.
local function findHintLine(panel: Instance, track: Instance?, playerGui: PlayerGui): StatusText?
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
		if isStatusText(d) and (not track or not d:IsDescendantOf(track)) then
			return d :: StatusText
		end
	end
	for _, d in ipairs(panel:GetDescendants()) do
		if isStatusText(d) then
			return d :: StatusText
		end
	end
	for _, panelC in ipairs(playerGui:GetDescendants()) do
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
		tl.Font = Enum.Font.GothamMedium
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
	tl.Font = Enum.Font.GothamMedium
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
	local hud = findHudScreen(root)
	local canvas = hud and hud:FindFirstChild("Canvas", true)
	local panel = findShipmentProgressPanel(root, hud, canvas)
	local track = panel and panel:FindFirstChild("ProgressTrack", true)
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
	local h: StatusText? = if panel then findHintLine(panel, track, root) else nil
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
		if
			desc.Name == "ShipmentProgressPanel"
			or desc.Name == "ProgressTrack"
			or desc.Name == "ProgressFill"
			or desc.Name == "Hint"
		then
			task.defer(tryResolve)
		end
	end)
end

local function tryResolve()
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
	if line then
		hintFxScale = ensureHintFxScale(line)
		shakeBasePos = line.Position
		baselineTextColor = line.TextColor3
		baselineRichText = line.RichText
		if not activeShipmentId then
			local t = line.Text
			local lower = string.lower(t)
			if
				t == ""
				or string.find(lower, "placeholder", 1, true)
				or string.find(lower, "shipment route", 1, true)
			then
				line.Text = IDLE_STATUS_TEXT
			end
		end
	end
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
	h.Text = CRUISE_TEXT .. "."
	cruiseDotsThread = task.spawn(function()
		while sid == cruiseDotsSession and h.Parent do
			phase = (phase % 3) + 1
			local dots = string.rep(".", phase)
			h.Text = CRUISE_TEXT .. dots
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

local function showHalted(severityRaw: string, holdSeconds: number)
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	local hold = math.clamp(holdSeconds, 0.35, 120)
	haltFrozenFillAlpha = progressAlphaFromClock()
	haltProgressFreezeUntil = workspace:GetServerTimeNow() + hold
	cancelAllHintFx()
	h.RichText = false
	local level = severityKey(severityRaw)
	h.Text = "Ship halted!"
	if level == "low" then
		h.TextColor3 = COLORS.low
		startPulseLoop("low")
	elseif level == "medium" then
		h.TextColor3 = COLORS.medium
		startPulseLoop("medium")
	else
		h.TextColor3 = COLORS.high
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
		if activeShipmentId then
			startCruiseDots()
		end
	end)
end

local function showTotalLossDuringPause(holdSeconds: number)
	local h = statusLine
	if not (h and h.Parent) then
		return
	end
	local hold = math.clamp(holdSeconds, 0.35, 60)
	haltFrozenFillAlpha = progressAlphaFromClock()
	haltProgressFreezeUntil = workspace:GetServerTimeNow() + hold
	cancelAllHintFx()
	h.RichText = false
	h.Text = "Shipment lost…"
	h.TextColor3 = COLORS.lost
	startPulseLoop("high")
	startShake(3.5)
	haltResumeThread = task.delay(hold, function()
		haltResumeThread = nil
		haltProgressFreezeUntil = nil
		haltFrozenFillAlpha = nil
	end)
	-- Shake/pulse continue until ShipmentResolved or next cancel; do not return to cruise (voyage ends).
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
	setFillScaleX(progressAlphaFromClock())
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

	local uid = ownerIdFromData(data)
	if typeof(uid) ~= "number" or uid ~= localPlayer.UserId then
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
		setFillScaleX(0)

		if not (progressFill and progressFill.Parent and statusLine and statusLine.Parent) then
			tryResolve()
		end

		local h = statusLine
		local failed = typeof(data.failureReason) == "string" and (data.failureReason :: string) ~= ""
		if h and h.Parent then
			if failed then
				h.RichText = false
				h.Text = "Shipment lost…"
				h.TextColor3 = COLORS.lost
				startShake(4)
				startPulseLoop("high")
			else
				local lost = tonumber(data.lost) or 0
				h.RichText = false
				h.TextColor3 = COLORS.success
				if lost > 0 then
					h.Text = string.format(
						"Shipment successful! %d barrel(s) lost at sea — the rest reached your warehouse.",
						lost
					)
				else
					h.Text = "Shipment successful!"
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
			cancelAllHintFx()
			restoreHintBaseline()
			if statusLine and statusLine.Parent then
				statusLine.Text = IDLE_STATUS_TEXT
				statusLine.RichText = baselineRichText
			end
			setFillScaleX(0)
		end)
		return
	end

	if kind == "ShipmentStarted" then
		stopClearTask()
		cancelAllHintFx()
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
		showHalted(sev, dur)
		return
	end

	if kind == "MineStrikeEvent" then
		local sev = tostring(data.severity or "High")
		showHalted(sev, mineHaltSeconds(data))
		return
	end

	if kind == "MissileStrikeEvent" then
		local idx = tonumber(data.missileIndex) or 1
		if idx ~= 1 then
			return
		end
		local outcome = tostring(data.outcome or "miss")
		local sev = if outcome == "hit" then "High" elseif outcome == "smallHit" then "Medium" else "Low"
		showHalted(sev, missileBarrageHintSeconds())
		return
	end
end

return ShipmentProgressHud
