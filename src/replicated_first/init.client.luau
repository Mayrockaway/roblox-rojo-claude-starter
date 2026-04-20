--!strict

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LoadingManifest = require(Shared:WaitForChild("Config"):WaitForChild("LoadingManifest"))

type LoadingGroup = typeof(LoadingManifest.getGroups()[1])

local COVER_ASSET = "rbxassetid://94495457583750"
local BGM_CLONE_NAME = "OTS_ClientBGM"
local PRELOAD_BATCH_SIZE = 24
local MIN_SCREEN_TIME_SECONDS = 1.2
local BAR_SETTLE_TIMEOUT_SECONDS = 0.6
local FINAL_GRACE_SECONDS = 0.25
local HUD_WAIT_TIMEOUT_SECONDS = 8

pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local player = Players.LocalPlayer
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
						if not seenInstances[descendant] then
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
	print(string.format(
		"[LoadingBootstrap] %s finished in %.2fs (%d targets, %d failures, %d optional misses).",
		group.id,
		elapsed,
		#prepared.targets,
		failureCount,
		missingOptional
	))

	return failureCount, missingOptional
end

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

	print(string.format(
		"[LoadingBootstrap] Blocking preload complete in %.2fs (failures=%d, optional misses=%d).",
		os.clock() - blockingStartedAt,
		blockingFailures,
		optionalGroupMisses
	))

	blockingDone = true
	setProgress("Finishing up...", 1)
end)

waitForCharacter()
waitForHud()

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

if progressLoopThread then
	pcall(task.cancel, progressLoopThread)
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

fadeAndDestroy()

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

	print(string.format(
		"[LoadingBootstrap] Deferred warm complete in %.2fs (failures=%d, optional misses=%d).",
		os.clock() - deferredStartedAt,
		deferredFailures,
		deferredOptionalMisses
	))
end)
