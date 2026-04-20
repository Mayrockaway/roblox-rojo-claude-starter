--!strict
-- LoadingBootstrap (ReplicatedFirst.LoadingBootstrap)
--
-- Roblox replicates `ReplicatedFirst` to the client BEFORE `Workspace` /
-- `StarterGui` / characters / sounds. Anything we want to render on the
-- player's first frame (a cover image to hide pop-in, asset streaming, and
-- the initial HUD bind) MUST live here. A `LocalScript` under
-- `ReplicatedFirst` is the only place where this works reliably.
--
-- Source-of-truth contract:
--   * Visuals (`ScreenGui` named `LoadingScreenGui`, `Canvas`, `Cover`,
--     `BottomBar.ProgressTrack.ProgressFill`, `BottomBar.LoadingLabel`) are
--     AUTHORED IN STUDIO under `ReplicatedFirst` (one-shot via
--     `scripts/mcp_author_loading_screen.luau`).
--     `default.project.json` lists `ReplicatedFirst` with
--     `$ignoreUnknownInstances = true` so the authored ScreenGui survives
--     Rojo sync. Per `ui-architecture.mdc`, behavior lives here in Lua;
--     layout + styling stay in Studio.
--   * If the authored ScreenGui is missing (fresh place / pre-author), this
--     script builds a minimal fallback so loading still covers correctly.
--
-- Scaling contract (matches `ui-scaling-responsive.mdc`):
--   * `Canvas` viewport-root: scale `(1, 1)`, centered.
--   * Cover `ImageLabel`: scale `(1, 1)`, `ScaleType = Crop` so the asset
--     fills any phone / desktop / console aspect with no bars and no stretch.
--   * Progress bar uses scale-based `Size` so it shrinks with phone width;
--     bottom label uses `TextScaled` + `UITextSizeConstraint` (authored).
--
-- Behavior summary:
--   1. Remove default Roblox loading UI and parent the cover ScreenGui.
--   2. Start BGM as soon as the BGM template replicates (idempotent with
--      `BgmPlayer` so the later `BgmBootstrap.client.luau` is a no-op).
--   3. Wait for `game.Loaded`, then `ContentProvider:PreloadAsync` EVERY
--      `Instance` reachable from `ReplicatedStorage`, `Workspace`,
--      `Lighting`, `SoundService`, `MaterialService`, `StarterGui`,
--      `StarterPack`, `StarterPlayer`. The async callback drives a live
--      progress-fill tween + a "Loading… N%" label.
--   4. Wait for the local character to spawn and for `PlayerGui.HUD` to clone
--      from `StarterGui` (the canonical first-painted-gameplay-frame cue).
--   5. Force the bar to 100%, brief grace, then fade `Canvas` + `Cover` +
--      bar + label transparencies to 1 and `:Destroy()`.

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local StarterGui = game:GetService("StarterGui")
local StarterPack = game:GetService("StarterPack")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local COVER_ASSET = "rbxassetid://94495457583750"
local BGM_CLONE_NAME = "OTS_ClientBGM" -- MUST match `BgmPlayer.CLONE_NAME` for de-dupe.

pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--- Build a minimal loading shell when no authored `LoadingScreenGui` is
--- present in `ReplicatedFirst`. Mirrors the Studio author intent (Canvas
--- viewport-root + full-bleed Cover + ProgressTrack/ProgressFill + label) so
--- visuals are correct on phone / desktop / console even before the asset is
--- authored in Studio.
local function buildFallbackScreen(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "LoadingScreenGui"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 1_000_000
	screen.Enabled = true

	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	canvas.BackgroundTransparency = 0
	canvas.BorderSizePixel = 0
	canvas.Parent = screen

	local cover = Instance.new("ImageLabel")
	cover.Name = "Cover"
	cover.AnchorPoint = Vector2.new(0.5, 0.5)
	cover.Position = UDim2.fromScale(0.5, 0.5)
	cover.Size = UDim2.fromScale(1, 1)
	cover.BackgroundTransparency = 1
	cover.Image = COVER_ASSET
	cover.ScaleType = Enum.ScaleType.Crop
	cover.Parent = canvas

	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0.5, 1)
	bottomBar.Position = UDim2.fromScale(0.5, 0.94)
	bottomBar.Size = UDim2.fromScale(0.6, 0.08)
	bottomBar.BackgroundTransparency = 1
	bottomBar.Parent = canvas

	local track = Instance.new("Frame")
	track.Name = "ProgressTrack"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.fromScale(0.5, 0)
	track.Size = UDim2.fromScale(1, 0.35)
	track.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	track.BackgroundTransparency = 0.45
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = bottomBar
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = Color3.fromRGB(255, 255, 255)
	trackStroke.Thickness = 1
	trackStroke.Transparency = 0.4
	trackStroke.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "ProgressFill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local label = Instance.new("TextLabel")
	label.Name = "LoadingLabel"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, 1)
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = "Loading…"
	label.Parent = bottomBar
	local sizeCap = Instance.new("UITextSizeConstraint")
	sizeCap.MinTextSize = 12
	sizeCap.MaxTextSize = 28
	sizeCap.Parent = label

	return screen
end

--- Resolve the authored `LoadingScreenGui` under `ReplicatedFirst`. We MOVE
--- (not clone) it to `PlayerGui` so it owns its lifetime cleanly and a
--- second `CharacterAdded` cannot resurrect it from `ReplicatedFirst`.
local function acquireScreen(): ScreenGui
	local existing = ReplicatedFirst:FindFirstChild("LoadingScreenGui")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local deadline = os.clock() + 0.5
	while os.clock() < deadline do
		existing = ReplicatedFirst:FindFirstChild("LoadingScreenGui")
		if existing and existing:IsA("ScreenGui") then
			return existing
		end
		RunService.Heartbeat:Wait()
	end
	return buildFallbackScreen()
end

local screen = acquireScreen()
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.DisplayOrder = math.max(screen.DisplayOrder, 1_000_000)
screen.Enabled = true
screen.Parent = playerGui

-- Resolve progress widgets (authored in Studio or built by the fallback).
-- All lookups are tolerant: a missing widget simply means that piece of
-- feedback is skipped, never an error.
local canvasFrame = screen:FindFirstChild("Canvas")
local coverImage = canvasFrame and canvasFrame:FindFirstChild("Cover")
local progressTrack: Frame? = nil
local progressFill: Frame? = nil
local loadingLabel: TextLabel? = nil
do
	if canvasFrame then
		local anyTrack = canvasFrame:FindFirstChild("ProgressTrack", true)
		if anyTrack and anyTrack:IsA("Frame") then
			progressTrack = anyTrack
			local anyFill = anyTrack:FindFirstChild("ProgressFill", true)
			if anyFill and anyFill:IsA("Frame") then
				progressFill = anyFill
			end
		end
		local anyLabel = canvasFrame:FindFirstChild("LoadingLabel", true)
		if anyLabel and anyLabel:IsA("TextLabel") then
			loadingLabel = anyLabel
		end
	end
end

-- Progress state shared between the preload coroutine and the UI tween loop.
-- `targetRatio` is the authoritative source the bar tweens toward; per-frame
-- code lerps `currentRatio` to it. Using a tween-toward-target instead of
-- a single TweenService:Create per callback keeps the bar moving smoothly
-- even when 200 assets resolve in the same frame.
local targetRatio = 0
local currentRatio = 0
local preloadDone = false
local preloadTotal = 0

local function setLabelPercent(ratio: number)
	if not loadingLabel then
		return
	end
	local pct = math.clamp(math.floor(ratio * 100 + 0.5), 0, 100)
	loadingLabel.Text = string.format("Loading… %d%%", pct)
end

setLabelPercent(0)
if progressFill then
	progressFill.Size = UDim2.fromScale(0, progressFill.Size.Y.Scale)
end

local progressLoopThread = task.spawn(function()
	while screen.Parent do
		-- Lerp toward `targetRatio` at a rate that finishes ~0.25s after each
		-- jump, smooth on phones (Heartbeat dt) and not jittery on desktop.
		local dt = RunService.Heartbeat:Wait()
		local lerp = math.clamp(dt / 0.25, 0, 1)
		currentRatio += (targetRatio - currentRatio) * lerp
		if progressFill then
			progressFill.Size = UDim2.fromScale(currentRatio, progressFill.Size.Y.Scale)
		end
		setLabelPercent(currentRatio)
		if preloadDone and currentRatio >= 0.999 then
			break
		end
	end
end)

--- Start BGM as early as `ReplicatedStorage.Assets.SFX.BGM` is reachable.
--- Idempotent with `src/client/BgmPlayer.luau` -- both create the same
--- `SoundService.OTS_ClientBGM` clone, and the second one to run sees the
--- existing instance and bails. Runs in a coroutine so a slow CDN does not
--- block the loading bar from showing.
local function startBgmAsync()
	task.spawn(function()
		if SoundService:FindFirstChild(BGM_CLONE_NAME) then
			return
		end
		local okAssets, assets = pcall(function()
			return ReplicatedStorage:WaitForChild("Assets", 60)
		end)
		if not okAssets or not assets then
			return
		end
		local okSfx, sfx = pcall(function()
			return assets:WaitForChild("SFX", 60)
		end)
		if not okSfx or not sfx then
			return
		end
		local okBgm, bgm = pcall(function()
			return sfx:WaitForChild("BGM", 60)
		end)
		if not okBgm or not bgm or not bgm:IsA("Sound") then
			return
		end
		if SoundService:FindFirstChild(BGM_CLONE_NAME) then
			return
		end
		-- Pre-warm the BGM file itself so playback starts crisp instead of
		-- with a half-second silent buffer while the audio CDN responds.
		pcall(function()
			ContentProvider:PreloadAsync({ bgm })
		end)
		if SoundService:FindFirstChild(BGM_CLONE_NAME) then
			return
		end
		local clone = bgm:Clone()
		clone.Name = BGM_CLONE_NAME
		clone.Playing = false
		clone.Parent = SoundService
		clone:Play()
	end)
end

startBgmAsync()

local function waitForGameLoaded()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
end

--- Collect every `Instance` that could host an asset reference (`Image`,
--- `SoundId`, `MeshId`, `TextureId`, decals, particles, materials, etc.).
--- Pulling whole-service descendants and letting `ContentProvider` figure
--- out which ones have content properties is simpler and more exhaustive
--- than maintaining a hand-curated allow-list -- and per the user's spec we
--- want EVERY asset preloaded before the cover lifts.
local function gatherEverything(): { Instance }
	local out: { Instance } = {}
	local roots: { Instance } = {
		ReplicatedStorage,
		Workspace,
		Lighting,
		SoundService,
		MaterialService,
		StarterGui,
		StarterPack,
		StarterPlayer,
	}
	for _, root in ipairs(roots) do
		table.insert(out, root)
		for _, d in ipairs(root:GetDescendants()) do
			table.insert(out, d)
		end
	end
	return out
end

waitForGameLoaded()

local assetList = gatherEverything()
preloadTotal = #assetList

if preloadTotal == 0 then
	preloadDone = true
	targetRatio = 1
else
	-- `PreloadAsync(list, callback)` fires the callback once per content id
	-- as it resolves (success OR failure -- both count as "done" for our
	-- progress meter). We aggregate progress on a Heartbeat tick so a burst
	-- of cached assets does not thrash the tween loop with thousands of
	-- per-callback Size writes per frame.
	task.spawn(function()
		local resolved = 0
		local function onResolved(_contentId: string, _status: Enum.AssetFetchStatus)
			resolved += 1
			targetRatio = math.min(1, resolved / preloadTotal)
		end
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(assetList, onResolved)
		end)
		if not ok then
			warn("[LoadingBootstrap] PreloadAsync failed: " .. tostring(err))
		end
		preloadDone = true
		targetRatio = 1
	end)
end

local function waitForCharacter()
	local char = player.Character
	if not char then
		char = player.CharacterAdded:Wait()
	end
	return char
end

--- Wait for the HUD `ScreenGui` to clone from `StarterGui` into `PlayerGui`.
--- This is the canonical "first painted gameplay frame" cue for this game
--- (everything else hangs off `HUD.Canvas`). Bounded so a missing HUD never
--- stalls login indefinitely.
local function waitForHud()
	local hud = playerGui:FindFirstChild("HUD")
	if hud then
		return hud
	end
	local done = false
	local conn
	conn = playerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" and child:IsA("ScreenGui") then
			done = true
		end
	end)
	local deadline = os.clock() + 8
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if conn then
		conn:Disconnect()
	end
	return playerGui:FindFirstChild("HUD")
end

waitForCharacter()
waitForHud()

-- Block until the preload coroutine has actually finished (every asset
-- resolved). The earlier waits already overlap with preloading, so this
-- usually returns immediately on a warm cache and only stalls on a cold
-- first join.
while not preloadDone do
	task.wait(0.05)
end

-- Force the visual bar to 100% and let the tween loop catch up. Without
-- this, a cold preload that finished while the player was still in the
-- character/HUD waits would leave the bar at e.g. 92% before the fade.
targetRatio = 1
local barDeadline = os.clock() + 0.6
while currentRatio < 0.999 and os.clock() < barDeadline do
	task.wait()
end

-- Small grace so first-frame controllers (CashStrip text, hotbar slots,
-- StraitStatusPanel etc.) stamp in BEFORE we lift the cover.
task.wait(0.25)

if progressLoopThread then
	pcall(task.cancel, progressLoopThread)
end

--- Fade the cover. Tween BackgroundTransparency, ImageTransparency, bar fill
--- transparency, and label transparencies together so neither plane snaps.
local function fadeAndDestroy()
	local fadeInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	if canvasFrame and canvasFrame:IsA("Frame") then
		TweenService:Create(canvasFrame, fadeInfo, { BackgroundTransparency = 1 }):Play()
	end
	if coverImage and coverImage:IsA("ImageLabel") then
		TweenService:Create(coverImage, fadeInfo, { ImageTransparency = 1 }):Play()
	end
	if progressTrack then
		TweenService:Create(progressTrack, fadeInfo, { BackgroundTransparency = 1 }):Play()
		for _, d in ipairs(progressTrack:GetDescendants()) do
			if d:IsA("Frame") then
				TweenService:Create(d, fadeInfo, { BackgroundTransparency = 1 }):Play()
			elseif d:IsA("UIStroke") then
				TweenService:Create(d, fadeInfo, { Transparency = 1 }):Play()
			end
		end
	end
	if loadingLabel then
		TweenService:Create(loadingLabel, fadeInfo, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end

	task.wait(0.45)
	screen:Destroy()
end

fadeAndDestroy()
