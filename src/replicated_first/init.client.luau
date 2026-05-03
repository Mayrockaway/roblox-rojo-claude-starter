--!strict

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LoadingManifest = require(Shared:WaitForChild("Config"):WaitForChild("LoadingManifest"))

type LoadingGroup = typeof(LoadingManifest.getGroups()[1])

local COVER_ASSET = "rbxassetid://75104414262424"
local BGM_CLONE_NAME = "OTS_ClientBGM"
local PRELOAD_BATCH_SIZE = 24
local MIN_SCREEN_TIME_SECONDS = 1.2
local BAR_SETTLE_TIMEOUT_SECONDS = 0.6
local FINAL_GRACE_SECONDS = 0.25
local HUD_WAIT_TIMEOUT_SECONDS = 8

pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

--- Kill the default Roblox `Backpack` CoreGui at the earliest possible point
--- in the client lifecycle. The custom hotbar lives at
--- `PlayerGui.HUD.Canvas.EquipmentHotbar` and is the only inventory UI we
--- ever want to render — the default toolbar must never flash on screen.
--- Disabling it here (in ReplicatedFirst, before `StarterPlayerScripts`
--- runs) is unconditional and runs before `EquipmentHotbarController` even
--- has a chance to bind, so there is no race where the default slot row
--- shows up while we wait for the custom strip to replicate. The post-bind
--- call in `init.client.luau` stays as a belt-and-braces re-assertion.
local StarterGui = game:GetService("StarterGui")
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

--- `Players.LocalPlayer` can be `nil` for a brief window when a script in
--- `ReplicatedFirst` first runs (the LocalPlayer property is populated
--- asynchronously, very early in client startup, on a separate signal). If we
--- hit `LocalPlayer:WaitForChild("PlayerGui")` while `LocalPlayer` is still
--- `nil`, the whole bootstrap throws `attempt to index nil with 'WaitForChild'`
--- on its very first line, never reaches a single `print`, and the custom
--- loading screen never gets parented to PlayerGui — the player just sees the
--- default Roblox loader cut straight into the world. Wait deterministically
--- before touching `LocalPlayer`. See playtest 2026-04 "loading screen not
--- appearing" — Output had the parser warning at the bottom of this file but
--- zero `[LoadingBootstrap]` runtime lines, which is exactly the signature of
--- a crash before any print on this line.
local player = Players.LocalPlayer
if not player then
	repeat
		Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
		player = Players.LocalPlayer
	until player ~= nil
end
local playerGui = player:WaitForChild("PlayerGui")

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
	label.Text = "Loading..."
	label.Parent = bottomBar

	local sizeCap = Instance.new("UITextSizeConstraint")
	sizeCap.MinTextSize = 12
	sizeCap.MaxTextSize = 28
	sizeCap.Parent = label

	return screen
end

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

local canvasFrame = screen:FindFirstChild("Canvas", true)
local coverImage = canvasFrame and canvasFrame:FindFirstChild("Cover", true)

local progressTrack: Frame? = nil
local progressFill: Frame? = nil
local loadingLabel: TextLabel? = nil
do
	local anyTrack = canvasFrame and canvasFrame:FindFirstChild("ProgressTrack", true)
	if anyTrack and anyTrack:IsA("Frame") then
		progressTrack = anyTrack
		local anyFill = anyTrack:FindFirstChild("ProgressFill", true)
		if anyFill and anyFill:IsA("Frame") then
			progressFill = anyFill
		end
	end

	local anyLabel = canvasFrame and canvasFrame:FindFirstChild("LoadingLabel", true)
	if anyLabel and anyLabel:IsA("TextLabel") then
		loadingLabel = anyLabel
	end
end

local targetRatio = 0
local currentRatio = 0
local targetLabel = "Starting..."
local blockingDone = false
local screenShownAt = os.clock()

local function formatProgressLabel(labelText: string, ratio: number): string
	local pct = math.clamp(math.floor(ratio * 100 + 0.5), 0, 100)
	return string.format("%s %d%%", labelText, pct)
end

local function setProgress(labelText: string?, ratio: number?)
	if typeof(labelText) == "string" and labelText ~= "" then
		targetLabel = labelText
	end
	if typeof(ratio) == "number" then
		targetRatio = math.max(targetRatio, math.clamp(ratio, 0, 1))
	end
end

if progressFill then
	progressFill.Size = UDim2.fromScale(0, progressFill.Size.Y.Scale)
end
if loadingLabel then
	loadingLabel.Text = formatProgressLabel(targetLabel, 0)
end

local progressLoopThread = task.spawn(function()
	while screen.Parent do
		local dt = RunService.Heartbeat:Wait()
		local lerpAlpha = math.clamp(dt / 0.25, 0, 1)
		currentRatio += (targetRatio - currentRatio) * lerpAlpha
		if progressFill then
			progressFill.Size = UDim2.fromScale(currentRatio, progressFill.Size.Y.Scale)
		end
		if loadingLabel then
			loadingLabel.Text = formatProgressLabel(targetLabel, currentRatio)
		end
		if blockingDone and currentRatio >= 0.999 then
			break
		end
	end
end)

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

local function waitForGameLoaded()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
end

local function waitForCharacter()
	local character = player.Character
	if character then
		return character
	end
	return player.CharacterAdded:Wait()
end

local function waitForHud()
	local hud = playerGui:FindFirstChild("HUD")
	if hud then
		return hud
	end

	local found = false
	local conn = playerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" and child:IsA("ScreenGui") then
			found = true
		end
	end)

	local deadline = os.clock() + HUD_WAIT_TIMEOUT_SECONDS
	while not found and os.clock() < deadline do
		task.wait(0.05)
	end
	conn:Disconnect()

	return playerGui:FindFirstChild("HUD")
end

local function splitBatches<T>(items: { T }, batchSize: number): { { T } }
	local batches: { { T } } = {}
	if #items == 0 then
		return batches
	end

	local index = 1
	while index <= #items do
		local batch: { T } = {}
		for _ = index, math.min(index + batchSize - 1, #items) do
			table.insert(batch, items[index])
			index += 1
		end
		table.insert(batches, batch)
	end
	return batches
end

type InstanceDeduper = { [Instance]: boolean }
type ContentDeduper = { [string]: boolean }
type PreparedTargets = {
	targets: { any },
	cleanup: (() -> ())?,
	missingRequired: number,
	missingOptional: number,
}

local function resolveEntry(entry: any): Instance?
	local serviceName = entry.service
	if typeof(serviceName) ~= "string" or serviceName == "" then
		return nil
	end

	local okRoot, root = pcall(function()
		return game:GetService(serviceName)
	end)
	if not okRoot or not root then
		return nil
	end

	local current: Instance = root
	for _, segment in ipairs(entry.segments or {}) do
		local nextInst = current:FindFirstChild(segment)
		if not nextInst then
			return nil
		end
		current = nextInst
	end

	return current
end

local function prepareTargets(group: LoadingGroup, seenInstances: InstanceDeduper, seenContentIds: ContentDeduper): PreparedTargets
	local targets: { any } = {}
	local cleanupItems: { Instance } = {}
	local missingRequired = 0
	local missingOptional = 0

	if group.entries then
		for _, entry in ipairs(group.entries) do
			local resolved = resolveEntry(entry)
			if not resolved then
				if entry.optional == true or group.optional == true then
					missingOptional += 1
				else
					missingRequired += 1
				end
			else
				if not seenInstances[resolved] then
					seenInstances[resolved] = true
					table.insert(targets, resolved)
				end
				if group.kind == "instance_tree" or entry.includeDescendants == true then
					for _, descendant in ipairs(resolved:GetDescendants()) do
						if seenInstances[descendant] then continue end
						-- Skip non-preloadable types
						local dominated = false
						if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
							dominated = (descendant :: any).Image ~= ""
						elseif descendant:IsA("Sound") then
							dominated = (descendant :: any).SoundId ~= ""
						elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
							dominated = (descendant :: any).Texture ~= ""
						elseif descendant:IsA("MeshPart") or descendant:IsA("SpecialMesh")
							or descendant:IsA("Animation") or descendant:IsA("VideoFrame")
							or descendant:IsA("ParticleEmitter") or descendant:IsA("Sky") then
							dominated = true
						end
						if dominated then
							seenInstances[descendant] = true
							table.insert(targets, descendant)
						end
					end
				end
			end
		end
	end

	if group.uris then
		for _, uri in ipairs(group.uris) do
			if typeof(uri) == "string" and uri ~= "" and not seenContentIds[uri] then
				seenContentIds[uri] = true
				local img = Instance.new("ImageLabel")
				img.Name = "LoadingPreloadImage"
				img.BackgroundTransparency = 1
				img.Visible = false
				img.Image = uri
				table.insert(targets, img)
				table.insert(cleanupItems, img)
			end
		end
	end

	if group.contentIds then
		for _, contentId in ipairs(group.contentIds) do
			if typeof(contentId) == "string" and contentId ~= "" and not seenContentIds[contentId] then
				seenContentIds[contentId] = true
				table.insert(targets, contentId)
			end
		end
	end

	local cleanup = nil
	if #cleanupItems > 0 then
		cleanup = function()
			for _, item in ipairs(cleanupItems) do
				item:Destroy()
			end
		end
	end

	return {
		targets = targets,
		cleanup = cleanup,
		missingRequired = missingRequired,
		missingOptional = missingOptional,
	}
end

local function preloadBatch(targets: { any }): number
	local failureCount = 0
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(targets, function(_contentId: string, status: Enum.AssetFetchStatus)
			if status ~= Enum.AssetFetchStatus.Success then
				failureCount += 1
			end
		end)
	end)
	if not ok then
		failureCount += 1
		warn("[LoadingBootstrap] PreloadAsync batch failed: " .. tostring(err))
	end
	return failureCount
end

local function runGroup(
	group: LoadingGroup,
	progressBase: number,
	blockingWeightTotal: number,
	seenInstances: InstanceDeduper,
	seenContentIds: ContentDeduper,
	updateVisualProgress: boolean
): (number, number)
	local startedAt = os.clock()
	local prepared = prepareTargets(group, seenInstances, seenContentIds)
	local missingOptional = prepared.missingOptional
	local labelText = "Loading " .. group.label .. "..."

	if prepared.missingRequired > 0 then
		warn(string.format("[LoadingBootstrap] %s missing %d required entries.", group.id, prepared.missingRequired))
	end
	if missingOptional > 0 then
		warn(string.format("[LoadingBootstrap] %s missing %d optional entries.", group.id, missingOptional))
	end

	if updateVisualProgress then
		setProgress(labelText, progressBase)
	end

	local failureCount = 0
	local batches = splitBatches(prepared.targets, PRELOAD_BATCH_SIZE)
	if #batches == 0 then
		if updateVisualProgress and blockingWeightTotal > 0 then
			setProgress(labelText, progressBase + (group.weight / blockingWeightTotal))
		end
	else
		for index, batch in ipairs(batches) do
			failureCount += preloadBatch(batch)
			if updateVisualProgress and blockingWeightTotal > 0 then
				local groupProgress = group.weight * (index / #batches)
				setProgress(labelText, progressBase + (groupProgress / blockingWeightTotal))
			end
		end
	end

	if prepared.cleanup then
		prepared.cleanup()
	end

	local elapsed = os.clock() - startedAt
	if RunService:IsStudio() then
		print(string.format(
			"[LoadingBootstrap] %s finished in %.2fs (%d targets, %d failures, %d optional misses).",
			group.id,
			elapsed,
			#prepared.targets,
			failureCount,
			missingOptional
		))
	end

	return failureCount, missingOptional
end

--- Performance Mode: prompt shown over the splash screen while loading runs behind it.
--- Loading continues in the background; screen holds at 100% until a choice is made.
local perfModeChosen = player:GetAttribute("PerformanceModeChosen") == true
task.spawn(function()
	local PERF_CHOSEN_ATTR = "PerformanceModeChosen"
	local OTHER_PLAYERS_ATTR = "OtherPlayersPlotVfxEnabled"
	if not perfModeChosen then
		local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

		local promptGui = Instance.new("ScreenGui")
		promptGui.Name = "PerfModePromptGui"
		promptGui.DisplayOrder = 1_000_001
		promptGui.IgnoreGuiInset = true
		promptGui.ResetOnSpawn = false
		promptGui.Parent = playerGui

		-- Semi-transparent tint over the loading screen
		local tint = Instance.new("Frame")
		tint.Name = "Tint"
		tint.Size = UDim2.fromScale(1, 1)
		tint.BackgroundColor3 = Color3.new(0, 0, 0)
		tint.BackgroundTransparency = 0.4
		tint.BorderSizePixel = 0
		tint.Parent = promptGui

		-- Title text floating over the tint
		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(1, 0, 0, 36)
		title.Position = UDim2.new(0, 0, 0.35, 0)
		title.AnchorPoint = Vector2.new(0, 0)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 26
		title.TextColor3 = Color3.new(1, 1, 1)
		title.Text = "Choose Your Experience"
		title.Parent = promptGui

		local titleStroke = Instance.new("UIStroke")
		titleStroke.Color = Color3.new(0, 0, 0)
		titleStroke.Thickness = 1.5
		titleStroke.Transparency = 0.3
		titleStroke.Parent = title

		-- Subtitle
		local sub = Instance.new("TextLabel")
		sub.Name = "Sub"
		sub.Size = UDim2.new(1, 0, 0, 20)
		sub.Position = UDim2.new(0, 0, 0.35, 40)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.Gotham
		sub.TextSize = 14
		sub.TextColor3 = Color3.fromRGB(200, 200, 200)
		sub.Text = "You can change this anytime in Settings."
		sub.Parent = promptGui

		-- Pill buttons centered below text
		local btnContainer = Instance.new("Frame")
		btnContainer.Name = "Buttons"
		btnContainer.Size = UDim2.new(0, 320, 0, 50)
		btnContainer.Position = UDim2.new(0.5, 0, 0.35, 80)
		btnContainer.AnchorPoint = Vector2.new(0.5, 0)
		btnContainer.BackgroundTransparency = 1
		btnContainer.Parent = promptGui

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.Padding = UDim.new(0, 20)
		layout.Parent = btnContainer

		local function makePill(name: string, desc: string, color: Color3): TextButton
			local btn = Instance.new("TextButton")
			btn.Name = name
			btn.Size = UDim2.new(0, 150, 0, 56)
			btn.BackgroundColor3 = color
			btn.BackgroundTransparency = 0
			btn.BorderSizePixel = 0
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 18
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Text = ""
			btn.AutoButtonColor = true
			btn.Parent = btnContainer

			Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 28)

			local btnStroke = Instance.new("UIStroke")
			btnStroke.Color = Color3.new(1, 1, 1)
			btnStroke.Transparency = 0.7
			btnStroke.Thickness = 1
			btnStroke.Parent = btn

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Name = "NameLabel"
			nameLabel.Size = UDim2.new(1, 0, 0, 22)
			nameLabel.Position = UDim2.new(0, 0, 0, 10)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Font = Enum.Font.GothamBold
			nameLabel.TextSize = 18
			nameLabel.TextColor3 = Color3.new(1, 1, 1)
			nameLabel.Text = name
			nameLabel.Parent = btn

			local d = Instance.new("TextLabel")
			d.Name = "Desc"
			d.Size = UDim2.new(1, 0, 0, 14)
			d.Position = UDim2.new(0, 0, 0, 34)
			d.BackgroundTransparency = 1
			d.Font = Enum.Font.Gotham
			d.TextSize = 12
			d.TextColor3 = Color3.new(1, 1, 1)
			d.TextTransparency = 0.25
			d.Text = desc
			d.Parent = btn

			return btn
		end

		local stdBtn = makePill("Standard", "Full visuals", Color3.fromRGB(50, 120, 200))
		local liteBtn = makePill("Lite", "Better FPS", Color3.fromRGB(40, 170, 80))

		if isMobile then
			local highlight = liteBtn:FindFirstChildOfClass("UIStroke")
			if highlight then
				highlight.Transparency = 0
				highlight.Thickness = 2
			end
		end

		local chosen: string? = nil
		local c1 = stdBtn.Activated:Connect(function() chosen = "standard" end)
		local c2 = liteBtn.Activated:Connect(function() chosen = "lite" end)

		while chosen == nil do
			task.wait()
		end

		c1:Disconnect()
		c2:Disconnect()
		promptGui:Destroy()

		player:SetAttribute(OTHER_PLAYERS_ATTR, chosen == "standard")
		player:SetAttribute(PERF_CHOSEN_ATTR, true)
	end
	perfModeChosen = true
end)

startBgmAsync()
setProgress("Starting...", 0)

local groups = LoadingManifest.getGroups()
local blockingGroups: { LoadingGroup } = {}
local deferredGroups: { LoadingGroup } = {}
local blockingWeightTotal = 0

for _, group in ipairs(groups) do
	if group.phase == "deferred" then
		table.insert(deferredGroups, group)
	else
		table.insert(blockingGroups, group)
		blockingWeightTotal += math.max(group.weight, 0)
	end
end

local blockingFailures = 0
local optionalGroupMisses = 0
task.spawn(function()
	local seenInstances: InstanceDeduper = {}
	local seenContentIds: ContentDeduper = {}
	local progressBase = 0
	local blockingStartedAt = os.clock()

	for _, group in ipairs(blockingGroups) do
		if group.id ~= "LoadingShell" then
			waitForGameLoaded()
		end
		local groupFailures, groupOptionalMisses = runGroup(
			group,
			progressBase,
			blockingWeightTotal,
			seenInstances,
			seenContentIds,
			true
		)
		blockingFailures += groupFailures
		optionalGroupMisses += groupOptionalMisses
		progressBase += group.weight / math.max(blockingWeightTotal, 1)
	end

	if RunService:IsStudio() then
		print(string.format(
			"[LoadingBootstrap] Blocking preload complete in %.2fs (failures=%d, optional misses=%d).",
			os.clock() - blockingStartedAt,
			blockingFailures,
			optionalGroupMisses
		))
	end

	blockingDone = true
	setProgress("Finishing up...", 1)
end)

waitForCharacter()
local hudScreen = waitForHud()

while not blockingDone do
	task.wait(0.05)
end

local minTimeRemaining = MIN_SCREEN_TIME_SECONDS - (os.clock() - screenShownAt)
if minTimeRemaining > 0 then
	task.wait(minTimeRemaining)
end

local barDeadline = os.clock() + BAR_SETTLE_TIMEOUT_SECONDS
while currentRatio < 0.999 and os.clock() < barDeadline do
	task.wait()
end

task.wait(FINAL_GRACE_SECONDS)

-- Hold at 100% until player has chosen a performance mode.
while not perfModeChosen do
	task.wait(0.05)
end

if progressLoopThread then
	pcall(task.cancel, progressLoopThread)
end

--- Suppress the HUD ScreenGui ONLY across the fade-and-destroy window so the
--- authored HUD (`EquipmentHotbar`, `CashStrip`, `TopRow`, etc.) cannot bleed
--- through the loading cover during its 0.4s opacity tween (the cover sits
--- at `DisplayOrder = 1_000_000`, fully opaque — but as it fades to
--- transparency the HUD underneath would otherwise peek through). We do this
--- as late as possible (immediately before `fadeAndDestroy`) instead of
--- pre-load so any error / hang during preload cannot leave the HUD
--- permanently disabled — the original earlier-suppression placement bricked
--- the entire HUD (including `EquipmentHotbar`) when anything in the
--- blocking-load loop got stuck. `FtueHudReveal` writes the correct
--- per-piece `Visible` state in parallel so the right pieces are already
--- configured by the time we re-enable.
local hudWasSuppressedForFade = false
if hudScreen and hudScreen:IsA("ScreenGui") then
	hudWasSuppressedForFade = true
	local hudScreenGui = hudScreen :: ScreenGui
	hudScreenGui.Enabled = false
end

--- Watchdog: regardless of how the next ~1.5s plays out (fade tween, destroy,
--- any pcalled error), force the HUD ScreenGui back on after a hard timeout.
--- Last-resort guarantee that the player never gets stranded with a black /
--- empty viewport because of a loading-bootstrap regression. Cheap and
--- idempotent — re-enabling an already-enabled ScreenGui is a no-op.
if hudWasSuppressedForFade then
	task.delay(8, function()
		local hud = playerGui:FindFirstChild("HUD")
			or (hudScreen and hudScreen.Parent ~= nil and hudScreen)
			or nil
		if hud and hud:IsA("ScreenGui") then
			local hudGui = hud :: ScreenGui
			if hudGui.Enabled == false then
				warn("[LoadingBootstrap] HUD ScreenGui was still disabled 8s after fade — forcing Enabled=true (watchdog).")
				hudGui.Enabled = true
			end
		end
	end)
end

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
		for _, descendant in ipairs(progressTrack:GetDescendants()) do
			if descendant:IsA("Frame") then
				TweenService:Create(descendant, fadeInfo, { BackgroundTransparency = 1 }):Play()
			elseif descendant:IsA("UIStroke") then
				TweenService:Create(descendant, fadeInfo, { Transparency = 1 }):Play()
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

--- pcall the fade-and-destroy so a tween/destroy error cannot strand us with
--- the HUD permanently disabled (see suppression block above). The watchdog
--- still re-enables on a hard timeout, but this is the primary path.
local fadeOk, fadeErr = pcall(fadeAndDestroy)
if not fadeOk then
	warn("[LoadingBootstrap] fadeAndDestroy errored — proceeding to restore HUD: " .. tostring(fadeErr))
end

--- Loading cover is gone — restore the HUD ScreenGui so `EquipmentHotbar` /
--- `CashStrip` / `TopRow` / etc. become visible. Per-child visibility was
--- already set by `FtueHudReveal` (FTUE-active players) or defaults to
--- `Visible = true` (FTUE-completed players), so flipping `Enabled` here is
--- the final reveal step. We refetch in case the original handle drifted.
if hudWasSuppressedForFade then
	local hudNow = playerGui:FindFirstChild("HUD")
	if hudNow and hudNow:IsA("ScreenGui") then
		(hudNow :: ScreenGui).Enabled = true
	elseif hudScreen and hudScreen:IsA("ScreenGui") and hudScreen.Parent ~= nil then
		(hudScreen :: ScreenGui).Enabled = true
	end
end

task.spawn(function()
	local seenInstances: InstanceDeduper = {}
	local seenContentIds: ContentDeduper = {}
	local deferredFailures = 0
	local deferredOptionalMisses = 0
	local deferredStartedAt = os.clock()

	for _, group in ipairs(deferredGroups) do
		local groupFailures, groupOptionalMisses = runGroup(
			group,
			0,
			1,
			seenInstances,
			seenContentIds,
			false
		)
		deferredFailures += groupFailures
		deferredOptionalMisses += groupOptionalMisses
	end

	if RunService:IsStudio() then
		print(string.format(
			"[LoadingBootstrap] Deferred warm complete in %.2fs (failures=%d, optional misses=%d).",
			os.clock() - deferredStartedAt,
			deferredFailures,
			deferredOptionalMisses
		))
	end
end)
