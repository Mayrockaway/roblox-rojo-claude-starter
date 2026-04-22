--!strict
--- GlobalEventBanner (client) — wires the AUTHORED Studio UI
--
-- Visuals (sizes, fonts, colors, layout, padding, corner radius, stroke,
-- aspect constraints, position) are AUTHORED under
-- `StarterGui.GlobalEventBannerGui` per the project's UI architecture
-- rule (`ui-architecture.mdc` §1, §3, §11). This controller does NOT
-- build geometry, set Position/Size/AnchorPoint on persistent chrome, or
-- restyle the bar. It only:
--   1. Subscribes to `GlobalEventClientState.Changed` (which owns the
--      single `GlobalEventStateUpdate` remote connection).
--   2. Clones `EventRowTemplate` for each new active event.
--   3. Updates `EventName.Text`, `EventSubtitle.Text`, `Countdown.Text`,
--      and the row's `BackgroundColor3` / `BorderStroke.Color` per
--      `bannerKind` palette (Buff / Threat / Cooperative).
--   4. Adds a runtime gold accent UIStroke + UIScale pulse on each row
--      while it's live (allowed by `ui-architecture.mdc` §6 — feedback
--      tween / status emphasis on dynamic clones, not on persistent
--      authored chrome). The accent stroke is removed when the row
--      fades, so the next clone starts clean.
--   5. Tweens transparency on expire and removes the row.
--
-- To tweak ANY visual (text size cap, padding, position above the
-- shipment progress bar, row aspect, row colors, font), open Studio →
-- `StarterGui.GlobalEventBannerGui.Canvas.List.EventRowTemplate` and
-- edit there. The controller picks up the new template the next time a
-- player joins / a row is built.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local GlobalEventClientState = require(script.Parent:WaitForChild("GlobalEventClientState"))

local GlobalEventBanner = {}

--==============================================================================
-- Constants (only behavioral, NOT visual sizing)
--==============================================================================

local GUI_NAME = "GlobalEventBannerGui"
local TEMPLATE_NAME = "EventRowTemplate"
local FADE_TIME = 0.35

--- Live-event chrome accent. A runtime-added UIStroke that sits on top
--- of the authored `BorderStroke`, drawn in gold and tween-transparency
--- looped to read as "pulsing / alive". Removed on row fade.
local ACCENT_STROKE_NAME = "LiveEventAccentStroke"
local ACCENT_GOLD = Color3.fromRGB(255, 213, 99)
local ACCENT_THICKNESS = 6
local ACCENT_PULSE_TIME = 0.85 -- seconds per half-cycle (0.2 → 0.85 transparency)
local ACCENT_TRANSPARENCY_LO = 0.15
local ACCENT_TRANSPARENCY_HI = 0.85
local ACCENT_SCALE_NAME = "LiveEventAccentScale"
local ROW_PULSE_TIME = 1.1
local ROW_PULSE_SCALE = 1.04

--- Per `bannerKind` palette. Only colors are runtime-applied — geometry,
--- font, padding, etc. are all authored on the template in Studio. To
--- change palette tints permanently, edit Studio defaults; these values
--- are runtime overrides keyed off the snapshot.
local PALETTE = {
	Buff = {
		fill = Color3.fromRGB(28, 60, 32),
		stroke = Color3.fromRGB(120, 220, 130),
		text = Color3.fromRGB(225, 255, 230),
	},
	Threat = {
		fill = Color3.fromRGB(60, 12, 16),
		stroke = Color3.fromRGB(220, 110, 90),
		text = Color3.fromRGB(255, 230, 220),
	},
	Cooperative = {
		fill = Color3.fromRGB(50, 40, 14),
		stroke = Color3.fromRGB(240, 200, 90),
		text = Color3.fromRGB(255, 240, 210),
	},
}

local function paletteFor(kind: string)
	return PALETTE[kind] or PALETTE.Threat
end

local function formatCountdown(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	if s >= 60 then
		local m = math.floor(s / 60)
		local r = s % 60
		return string.format("%d:%02d", m, r)
	end
	return string.format("0:%02d", s)
end

--==============================================================================
-- Module state
--==============================================================================

type RowParts = {
	root: Frame,
	name: TextLabel?,
	sub: TextLabel?,
	timer: TextLabel?,
	stroke: UIStroke?,
	accentStroke: UIStroke?,
	accentScale: UIScale?,
	accentStrokeTween: Tween?,
	accentScaleTween: Tween?,
}

local _player: Player? = nil
local _gui: ScreenGui? = nil
local _list: Frame? = nil
local _template: Frame? = nil
local _heartbeat: RBXScriptConnection? = nil
local _changedConn: RBXScriptConnection? = nil

local _rowsById: { [string]: RowParts } = {}

--==============================================================================
-- Authored UI lookup (Studio-first, no runtime fallback build)
--==============================================================================

local function resolveAuthoredUI(): (ScreenGui?, Frame?, Frame?)
	if _gui and _gui.Parent and _list and _list.Parent and _template and _template.Parent then
		return _gui, _list, _template
	end
	local plr = _player or Players.LocalPlayer
	if not plr then return nil, nil, nil end
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil, nil, nil end

	local gui = pg:FindFirstChild(GUI_NAME)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[GlobalEventBanner] missing authored UI: PlayerGui." .. GUI_NAME
			.. " — author it under StarterGui.GlobalEventBannerGui (see ui-architecture.mdc §11).")
		return nil, nil, nil
	end
	local canvas = gui:FindFirstChild("Canvas")
	local list = canvas and canvas:FindFirstChild("List")
	if not list or not list:IsA("Frame") then
		warn("[GlobalEventBanner] authored UI missing Canvas.List frame.")
		return nil, nil, nil
	end
	local template = list:FindFirstChild(TEMPLATE_NAME)
	if not template or not template:IsA("Frame") then
		warn("[GlobalEventBanner] authored UI missing " .. TEMPLATE_NAME .. " frame inside List.")
		return nil, nil, nil
	end
	-- Hard-guarantee the template never renders itself, even if a save
	-- accidentally toggles it Visible in Studio.
	if template.Visible then template.Visible = false end

	_gui = gui
	_list = list
	_template = template
	return gui, list, template
end

--==============================================================================
-- Row management (clone-and-populate; never build geometry)
--==============================================================================

local function applyPalette(parts: RowParts, kind: string)
	local pal = paletteFor(kind)
	parts.root.BackgroundColor3 = pal.fill
	if parts.name then parts.name.TextColor3 = pal.text end
	if parts.sub then parts.sub.TextColor3 = pal.text end
	if parts.timer then parts.timer.TextColor3 = pal.text end
	if parts.stroke then parts.stroke.Color = pal.stroke end
end

--- Adds the gold accent stroke + pulsing UIScale, and starts looped
--- tweens for both. Idempotent — re-calling on an existing row is a
--- no-op so snapshot reconciliation can call freely.
local function attachLiveAccent(parts: RowParts)
	if parts.accentStroke then return end

	local accentStroke = Instance.new("UIStroke")
	accentStroke.Name = ACCENT_STROKE_NAME
	accentStroke.Color = ACCENT_GOLD
	accentStroke.Thickness = ACCENT_THICKNESS
	accentStroke.Transparency = ACCENT_TRANSPARENCY_LO
	accentStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	accentStroke.LineJoinMode = Enum.LineJoinMode.Round
	accentStroke.Parent = parts.root

	local accentScale = parts.root:FindFirstChild(ACCENT_SCALE_NAME)
	if not (accentScale and accentScale:IsA("UIScale")) then
		accentScale = Instance.new("UIScale")
		accentScale.Name = ACCENT_SCALE_NAME
		accentScale.Scale = 1
		accentScale.Parent = parts.root
	end
	local accentScaleInst = accentScale :: UIScale
	accentScaleInst.Scale = 1

	local strokeInfo = TweenInfo.new(
		ACCENT_PULSE_TIME,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut,
		-1, -- loop forever
		true -- reverse on each cycle
	)
	local strokeTween = TweenService:Create(accentStroke, strokeInfo, {
		Transparency = ACCENT_TRANSPARENCY_HI,
	})
	strokeTween:Play()

	local scaleInfo = TweenInfo.new(
		ROW_PULSE_TIME,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut,
		-1,
		true
	)
	local scaleTween = TweenService:Create(accentScaleInst, scaleInfo, {
		Scale = ROW_PULSE_SCALE,
	})
	scaleTween:Play()

	parts.accentStroke = accentStroke
	parts.accentScale = accentScaleInst
	parts.accentStrokeTween = strokeTween
	parts.accentScaleTween = scaleTween
end

local function detachLiveAccent(parts: RowParts)
	if parts.accentStrokeTween then parts.accentStrokeTween:Cancel() ; parts.accentStrokeTween = nil end
	if parts.accentScaleTween then parts.accentScaleTween:Cancel() ; parts.accentScaleTween = nil end
	if parts.accentStroke then parts.accentStroke:Destroy() ; parts.accentStroke = nil end
	if parts.accentScale then parts.accentScale:Destroy() ; parts.accentScale = nil end
end

--- Populate whichever labels the authored template actually has. The
--- user is free to delete `EventName` (subtitle-only layout), delete
--- `EventSubtitle` (title-only layout), or even keep just `Countdown`.
--- We never fail the row build over a missing label — we only fail if
--- the template itself can't be cloned.
--
-- Note: each label is pulled into a local before assigning `.Text`. The
-- `(parts.x :: TextLabel).Text = ...` form trips Luau's "ambiguous
-- syntax: looks like a function call" parse error, which silently
-- prevents the whole module from loading.
local function applyText(parts: RowParts, entry: GlobalEventClientState.ActiveEntry)
	local nameLbl = parts.name
	local subLbl = parts.sub
	local timerLbl = parts.timer

	if nameLbl then
		nameLbl.Text = entry.displayName
	end
	if subLbl then
		if nameLbl then
			subLbl.Text = entry.subtitle
		else
			-- No EventName label: combine "{name} — {subtitle}" into the
			-- subtitle so the player still sees which event is active.
			if entry.subtitle ~= "" then
				subLbl.Text = string.format("%s — %s", entry.displayName, entry.subtitle)
			else
				subLbl.Text = entry.displayName
			end
		end
	end
	if timerLbl then
		timerLbl.Text = "0:00"
	end
end

local function buildRow(entry: GlobalEventClientState.ActiveEntry): RowParts?
	local _, list, template = resolveAuthoredUI()
	if not list or not template then return nil end

	local row = template:Clone()
	row.Name = "Row_" .. entry.id
	row.Visible = true
	row.LayoutOrder = math.floor(entry.expiresAt) -- soonest-expiring first
	row.Parent = list

	local function findLabel(label: string): TextLabel?
		local inst = row:FindFirstChild(label)
		if inst and inst:IsA("TextLabel") then
			return inst :: TextLabel
		end
		return nil
	end

	local parts: RowParts = {
		root = row :: Frame,
		name = findLabel("EventName"),
		sub = findLabel("EventSubtitle"),
		timer = findLabel("Countdown"),
		stroke = row:FindFirstChildOfClass("UIStroke"),
	}

	if not parts.name and not parts.sub and not parts.timer then
		warn("[GlobalEventBanner] EventRowTemplate has no EventName / EventSubtitle / Countdown TextLabels — row will be blank.")
	end

	applyText(parts, entry)
	applyPalette(parts, entry.bannerKind)
	attachLiveAccent(parts)
	return parts
end

local function fadeAndDestroy(parts: RowParts)
	detachLiveAccent(parts)
	local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	pcall(function()
		TweenService:Create(parts.root, info, { BackgroundTransparency = 1 }):Play()
		if parts.name then TweenService:Create(parts.name, info, { TextTransparency = 1 }):Play() end
		if parts.sub then TweenService:Create(parts.sub, info, { TextTransparency = 1 }):Play() end
		if parts.timer then TweenService:Create(parts.timer, info, { TextTransparency = 1 }):Play() end
		if parts.stroke then TweenService:Create(parts.stroke, info, { Transparency = 1 }):Play() end
	end)
	task.delay(FADE_TIME + 0.05, function()
		if parts.root and parts.root.Parent then
			parts.root:Destroy()
		end
	end)
end

--==============================================================================
-- Snapshot reconciliation
--==============================================================================

local function reconcile()
	local active = GlobalEventClientState.GetActiveById()

	for id, parts in pairs(_rowsById) do
		if not active[id] then
			fadeAndDestroy(parts)
			_rowsById[id] = nil
		end
	end

	for id, entry in pairs(active) do
		local existing = _rowsById[id]
		if existing then
			applyText(existing, entry)
			existing.root.LayoutOrder = math.floor(entry.expiresAt)
			applyPalette(existing, entry.bannerKind)
			attachLiveAccent(existing) -- idempotent; ensures pulse if a re-clone happened
		else
			local row = buildRow(entry)
			if row then
				_rowsById[id] = row
			end
		end
	end
end

local function tickCountdown()
	if next(_rowsById) == nil then return end
	local approxServerNow = GlobalEventClientState.ApproxServerNow()
	local active = GlobalEventClientState.GetActiveById()
	for id, parts in pairs(_rowsById) do
		local entry = active[id]
		local timerLbl = parts.timer
		if entry and timerLbl then
			local remaining = entry.expiresAt - approxServerNow
			timerLbl.Text = formatCountdown(remaining)
		end
	end
end

--==============================================================================
-- Lifecycle
--==============================================================================

function GlobalEventBanner.start()
	if _player then return end
	_player = Players.LocalPlayer
	if not _player then return end

	-- Pre-resolve the authored UI so any missing nodes warn loudly on
	-- boot rather than silently when the first event fires.
	resolveAuthoredUI()

	-- The shared state module owns the remote connection. It must be
	-- started by `init.client.luau` BEFORE this controller; calling
	-- `start()` here too is safe (idempotent) and protects against
	-- ordering regressions.
	GlobalEventClientState.start()
	_changedConn = GlobalEventClientState.Changed:Connect(reconcile)
	_heartbeat = RunService.Heartbeat:Connect(tickCountdown)

	-- Pick up any snapshot the state module already received before we
	-- subscribed (Changed only fires on NEW snapshots, not catch-up).
	reconcile()
end

function GlobalEventBanner.stop()
	if _changedConn then _changedConn:Disconnect() ; _changedConn = nil end
	if _heartbeat then _heartbeat:Disconnect() ; _heartbeat = nil end
	for _, parts in pairs(_rowsById) do
		detachLiveAccent(parts)
		if parts.root and parts.root.Parent then
			parts.root:Destroy()
		end
	end
	_rowsById = {}
end

return GlobalEventBanner
