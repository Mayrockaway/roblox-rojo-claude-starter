--!strict
-- Binds `PlayerGui` FTUE ScreenGui: finds Title, Body, ContinueButton, SkipButton (any depth).
-- Title/Body may be swapped via `FtueConfig.DialogueSwapTitleBodySlots`. Behavior only — Studio owns layout.
--
-- **Portrait images (optional)** — author in Studio, assign assets in `FtueConfig.PortraitImageByStep`:
--   `FTUEDialogueGui` → … → `PortraitFrame` (Frame; your fixed card size + corner radius)
--     └── `PortraitImage` (ImageLabel) — Size (1,0),(1,0) scale, Position (0,0), ImageTransparency 0,
--         BackgroundTransparency 1, ScaleType Fit or Crop (Fit = whole image visible; Crop = fill frame).
--   Omit `PortraitFrame` / `PortraitImage` if unused. Code only sets `Image` + `Visible` on the image and frame.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local FtueTpHomePointerState = require(script.Parent:WaitForChild("FtueTpHomePointerState"))
local FtueTpHomePointerSignals = require(script.Parent:WaitForChild("FtueTpHomePointerSignals"))
local FtueDispatchPointerSignals = require(script.Parent:WaitForChild("FtueDispatchPointerSignals"))
local UiSfx = require(script.Parent.Parent:WaitForChild("UiSfx"))

local ACK_STEPS: { [string]: boolean } = {
	[FtueConfig.Step.Intro] = true,
	[FtueConfig.Step.WaitSell] = true,
	[FtueConfig.Step.WaitDocksShipUpgrade] = true,
	[FtueConfig.Step.WaitDocksHire] = true,
}

local FtueDialogueController = {}

local function setGuiText(host: Instance?, text: string)
	if not host then
		return
	end
	if host:IsA("TextLabel") or host:IsA("TextButton") or host:IsA("TextBox") then
		(host :: any).Text = text
		return
	end
	local tl = host:FindFirstChildWhichIsA("TextLabel", true)
	if tl then
		tl.Text = text
	end
end

local function resolveTextHost(name: string, root: Instance?): GuiObject?
	if not root then
		return nil
	end
	local node = root:FindFirstChild(name, true)
	if not node then
		return nil
	end
	if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
		return node :: GuiObject
	end
	if node:IsA("GuiObject") then
		local tl = node:FindFirstChildWhichIsA("TextLabel", true)
		if tl then
			return tl
		end
	end
	return nil
end

local TITLE_ALIASES = { "Title", "TitleLabel", "Headline", "DialogTitle", "FtueTitle", "Header" }
local BODY_ALIASES = { "Body", "BodyLabel", "Message", "Copy", "Subtitle", "DialogBody", "FtueBody", "Description" }

local function resolveTextHostFirst(aliases: { string }, root: Instance?): GuiObject?
	for _, name in ipairs(aliases) do
		local h = resolveTextHost(name, root)
		if h then
			return h
		end
	end
	return nil
end

local function isUnderGuiButton(inst: Instance): boolean
	local p: Instance? = inst.Parent
	while p do
		if p:IsA("GuiButton") then
			return true
		end
		p = p.Parent
	end
	return false
end

local function resolveTextHostsFallback(root: Instance): (GuiObject?, GuiObject?)
	local function collect(container: Instance): { TextLabel }
		local labels: { TextLabel } = {}
		for _, d in ipairs(container:GetDescendants()) do
			if d:IsA("TextLabel") and not isUnderGuiButton(d) then
				table.insert(labels, d)
			end
		end
		return labels
	end
	for _, containerName in ipairs({ "Card", "Canvas", "Dialog", "Main", "Panel", "Container", "Content" }) do
		local container = root:FindFirstChild(containerName, true)
		if container then
			local labels = collect(container)
			if #labels >= 2 then
				return labels[1], labels[2]
			elseif #labels == 1 then
				return labels[1], nil
			end
		end
	end
	local any = collect(root)
	if #any >= 2 then
		return any[1], any[2]
	elseif #any == 1 then
		return any[1], nil
	end
	return nil, nil
end

local function normalizeStep(step: any): string?
	if typeof(step) ~= "string" then
		return nil
	end
	local s = (step :: string):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil
	end
	return s
end

local PORTRAIT_FRAME_NAME = "PortraitFrame"
local PORTRAIT_IMAGE_NAME = "PortraitImage"

local function applyFtuePortrait(screenGui: ScreenGui, step: string?)
	local map = (FtueConfig :: any).PortraitImageByStep
	if typeof(map) ~= "table" then
		return
	end
	local frame = screenGui:FindFirstChild(PORTRAIT_FRAME_NAME, true)
	if not frame or not frame:IsA("GuiObject") then
		return
	end
	local img = frame:FindFirstChild(PORTRAIT_IMAGE_NAME, true)
	if not (img and img:IsA("ImageLabel")) then
		return
	end
	local id = typeof(step) == "string" and (map :: any)[step]
	if typeof(id) ~= "string" or id == "" then
		img.Visible = false
		(frame :: GuiObject).Visible = false
		return
	end
	(img :: ImageLabel).Image = id
	img.Visible = true
	(frame :: GuiObject).Visible = true
end

local function findDialogueScreenGui(playerGui: PlayerGui): ScreenGui?
	local a = playerGui:FindFirstChild("FtueDialogueGui", true)
	if a and a:IsA("ScreenGui") then
		return a
	end
	local b = playerGui:FindFirstChild("FTUEDialogueGui", true)
	if b and b:IsA("ScreenGui") then
		return b
	end
	return nil
end

--- Hide dialogue chrome but keep `Canvas.Pointers` visible (Teleport Home pointer after FTUE ends).
local function hideNonPointersUnderCanvas(sg: ScreenGui, pointersOnly: boolean)
	local canvas = sg:FindFirstChild("Canvas")
	if not canvas then
		return
	end
	for _, ch in ipairs(canvas:GetChildren()) do
		if ch:IsA("GuiObject") then
			if ch.Name == "Pointers" or ch.Name == "pointers" then
				ch.Visible = true
			else
				ch.Visible = not pointersOnly
			end
		end
	end
end

function FtueDialogueController.start(
	player: Player,
	playerGui: PlayerGui,
	requestFtueAcknowledge: RemoteEvent,
	requestFtueSkip: RemoteEvent,
	ftueStateUpdate: RemoteEvent,
	oilActionResult: RemoteEvent
)
	local sg = findDialogueScreenGui(playerGui)
	if not sg then
		warn("[FTUE] No FtueDialogueGui / FTUEDialogueGui under PlayerGui — dialogue disabled.")
		return
	end

	local continueBtnNames = { "ContinueButton", "Continue", "OkButton", "OK", "NextButton" }
	local skipBtnNames = {
		"SkipButton",
		"Skip",
		"CloseButton",
		"Close",
		"DismissButton",
		"X",
	}

	local titleHost: GuiObject? = nil
	local bodyHost: GuiObject? = nil
	local continueBtn: GuiButton? = nil
	local skipBtn: GuiButton? = nil
	local continueLabelStudio = ""

	local function findButton(names: { string }): GuiButton?
		for _, n in ipairs(names) do
			local node = sg:FindFirstChild(n, true)
			if node and node:IsA("GuiButton") then
				return node
			end
		end
		return nil
	end

	local function resolveTextHostsNow()
		titleHost = resolveTextHostFirst(TITLE_ALIASES, sg)
		bodyHost = resolveTextHostFirst(BODY_ALIASES, sg)
		if not titleHost or not bodyHost then
			local a, b = resolveTextHostsFallback(sg)
			if not titleHost then
				titleHost = a
			end
			if not bodyHost then
				bodyHost = b
			end
		end
	end

	resolveTextHostsNow()

	continueBtn = findButton(continueBtnNames)
	skipBtn = findButton(skipBtnNames)

	if continueBtn then
		local lab = continueBtn:FindFirstChildWhichIsA("TextLabel", true)
		if lab then
			continueLabelStudio = lab.Text
		elseif continueBtn:IsA("TextButton") then
			continueLabelStudio = (continueBtn :: TextButton).Text
		end
	end

	local function setContinueButtonText(btn: GuiButton, text: string)
		local lab = btn:FindFirstChildWhichIsA("TextLabel", true)
		if lab then
			lab.Text = text
		elseif btn:IsA("TextButton") then
			(btn :: TextButton).Text = text
		end
	end

	-- Use `Activated` only. Wiring both `MouseButton1Click` and `Activated` fires twice per click,
	-- so WaitSell Continue would: (1) advance to Done, (2) immediately acknowledge Done and skip the final page.
	local function wireButton(btn: GuiButton, fn: () -> ())
		btn.Activated:Connect(fn)
	end

	if not continueBtn and not skipBtn then
		warn("[FTUE] FTUE dialogue has no ContinueButton or skip/close control — cannot wire.")
		return
	end
	if not titleHost and not bodyHost then
		warn(
			"[FTUE] No Title/Body text hosts found (tried Title, Body, Message, …). "
				.. "Buttons will still work; rename labels in Studio or add Title + Body."
		)
	end

	print(
		string.format(
			"[FTUE] wired under %s | Title=%s Body=%s Continue=%s Skip=%s | FtueConfig.Enabled=%s",
			sg.Name,
			titleHost and titleHost.Name or "nil",
			bodyHost and bodyHost.Name or "nil",
			continueBtn and continueBtn.Name or "nil",
			skipBtn and skipBtn.Name or "nil",
			tostring(FtueConfig.Enabled)
		)
	)

	local dismissedStep: string? = nil
	local lastKachingStep: string? = nil
	--- Avoid replaying the "panel open" SFX when `applyStep` runs multiple times for the same FTUE step.
	local lastDialogueOpenSoundStep: string? = nil
	local function maybePlayFtueDialogueOpen(forStep: string?)
		if typeof(forStep) ~= "string" or forStep == "" then
			return
		end
		if lastDialogueOpenSoundStep == forStep then
			return
		end
		lastDialogueOpenSoundStep = forStep
		UiSfx.playFtueDialogueOpen()
	end
	local function maybePlayFtueKaching(forStep: string?)
		if forStep ~= FtueConfig.Step.WaitPlotShipment and forStep ~= FtueConfig.Step.Done then
			return
		end
		if lastKachingStep == forStep then
			return
		end
		lastKachingStep = forStep
		UiSfx.playKaching()
	end

	local function copyForStep(step: string?)
		if typeof(step) ~= "string" or step == "" then
			return nil, nil
		end
		local row = FtueConfig.Copy[step]
		if typeof(row) ~= "table" then
			return "Tutorial", ""
		end
		return tostring((row :: any).title or "Tutorial"), tostring((row :: any).body or "")
	end

	local lastBody = ""

	--- Hide duplicate TextLabels under Continue on Done (Studio may have ghost copies).
	local function hideDuplicateContinueLabels(btn: GuiButton?)
		if not btn then
			return
		end
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("TextLabel") and d ~= btn:FindFirstChildWhichIsA("TextLabel", true) then
				d.Visible = false
			end
		end
	end

	local function applyStep(stepIn: string?)
		local step = normalizeStep(stepIn)
		if FtueConfig.Enabled ~= true then
			sg.Enabled = false
			hideNonPointersUnderCanvas(sg, false)
			dismissedStep = nil
			lastDialogueOpenSoundStep = nil
			applyFtuePortrait(sg, nil)
			return
		end
		if step == nil or step == "" then
			if FtueTpHomePointerState.shouldUsePointerOnlyDialogueMode() then
				sg.Enabled = true
				hideNonPointersUnderCanvas(sg, true)
				dismissedStep = nil
				lastDialogueOpenSoundStep = nil
				applyFtuePortrait(sg, nil)
				return
			end
			sg.Enabled = false
			hideNonPointersUnderCanvas(sg, false)
			dismissedStep = nil
			lastDialogueOpenSoundStep = nil
			applyFtuePortrait(sg, nil)
			return
		end
		if step == FtueConfig.Step.Done then
			FtueTpHomePointerState.markLegActive()
			FtueDispatchPointerSignals.fireFtuePointersRefresh()
			if dismissedStep ~= nil and dismissedStep ~= step then
				dismissedStep = nil
			end
			if dismissedStep == step then
				sg.Enabled = false
				hideNonPointersUnderCanvas(sg, false)
				return
			end
			if
				(not titleHost or not titleHost:IsDescendantOf(sg))
				or (not bodyHost or not bodyHost:IsDescendantOf(sg))
			then
				resolveTextHostsNow()
			end
			hideNonPointersUnderCanvas(sg, false)
			sg.Enabled = true
			maybePlayFtueDialogueOpen(step)
			local t, b = copyForStep(step)
			local swap = FtueConfig.DialogueSwapTitleBodySlots == true
			local titleSlot = if swap then bodyHost else titleHost
			local bodySlot = if swap then titleHost else bodyHost
			if t then
				setGuiText(titleSlot, t)
			end
			if b then
				setGuiText(bodySlot, b)
				lastBody = b
			end
			maybePlayFtueKaching(step)
			if skipBtn then
				skipBtn.Visible = false
			end
			if continueBtn then
				continueBtn.Visible = true
				continueBtn.AutoButtonColor = true
				setContinueButtonText(continueBtn, FtueConfig.DoneContinueButtonText)
				hideDuplicateContinueLabels(continueBtn)
			end
			applyFtuePortrait(sg, step)
			return
		end
		if dismissedStep ~= nil and dismissedStep ~= step then
			dismissedStep = nil
		end
		if dismissedStep == step then
			sg.Enabled = false
			hideNonPointersUnderCanvas(sg, false)
			return
		end
		if
			(not titleHost or not titleHost:IsDescendantOf(sg))
			or (not bodyHost or not bodyHost:IsDescendantOf(sg))
		then
			resolveTextHostsNow()
		end
		hideNonPointersUnderCanvas(sg, false)
		sg.Enabled = true
		maybePlayFtueDialogueOpen(step)
		local t, b = copyForStep(step)
		local swap = FtueConfig.DialogueSwapTitleBodySlots == true
		local titleSlot = if swap then bodyHost else titleHost
		local bodySlot = if swap then titleHost else bodyHost
		if t then
			setGuiText(titleSlot, t)
		end
		if b then
			setGuiText(bodySlot, b)
			lastBody = b
		end
		if step == FtueConfig.Step.WaitPlotShipment then
			maybePlayFtueKaching(step)
		end
		if continueBtn then
			if continueLabelStudio ~= "" then
				setContinueButtonText(continueBtn, continueLabelStudio)
			end
			continueBtn.Visible = ACK_STEPS[step] == true
			continueBtn.AutoButtonColor = ACK_STEPS[step] == true
		end
		if skipBtn then
			skipBtn.Visible = true
		end
		applyFtuePortrait(sg, step)
	end

	local function applyStepFromPlayer()
		applyStep(player:GetAttribute(Constants.FtueStepAttribute) :: any)
	end

	applyStepFromPlayer()
	task.defer(applyStepFromPlayer)
	task.delay(0.5, applyStepFromPlayer)

	player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(applyStepFromPlayer)

	sg.DescendantAdded:Connect(function(child)
		if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
			task.defer(applyStepFromPlayer)
		end
	end)

	ftueStateUpdate.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local s = (payload :: any).step
		if s == nil then
			applyStep(nil)
			return
		end
		if typeof(s) == "string" then
			applyStep(s)
		end
	end)

	if continueBtn then
		continueBtn.Active = true
		continueBtn.Selectable = true
		wireButton(continueBtn, function()
			local attr = player:GetAttribute(Constants.FtueStepAttribute)
			if typeof(attr) == "string" and attr == FtueConfig.Step.Done then
				dismissedStep = FtueConfig.Step.Done
				FtueTpHomePointerState.markLegActive()
				sg.Enabled = true
				hideNonPointersUnderCanvas(sg, true)
				requestFtueAcknowledge:FireServer()
				return
			end
			requestFtueAcknowledge:FireServer()
		end)
	else
		warn("[FTUE] ContinueButton not found under " .. sg.Name)
	end

	if skipBtn then
		skipBtn.Active = true
		skipBtn.Selectable = true
		wireButton(skipBtn, function()
			local attr = player:GetAttribute(Constants.FtueStepAttribute)
			if typeof(attr) == "string" and attr == FtueConfig.Step.Done then
				dismissedStep = FtueConfig.Step.Done
				FtueTpHomePointerState.markLegActive()
				sg.Enabled = true
				hideNonPointersUnderCanvas(sg, true)
				requestFtueAcknowledge:FireServer()
				return
			end
			requestFtueSkip:FireServer()
			sg.Enabled = false
			hideNonPointersUnderCanvas(sg, false)
		end)
	else
		warn("[FTUE] No skip/close button found (SkipButton, CloseButton, …).")
	end

	FtueTpHomePointerSignals.subscribeTeleportHomePressed(function()
		local d = findDialogueScreenGui(playerGui)
		if not d then
			return
		end
		if not FtueTpHomePointerState.shouldShowPointer() then
			d.Enabled = false
			hideNonPointersUnderCanvas(d, false)
		end
	end)

	oilActionResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.code ~= "ERR_FTUE_WRONG_TILE" then
			return
		end
		if not sg.Enabled then
			return
		end
		local swap = FtueConfig.DialogueSwapTitleBodySlots == true
		local bodySlot = if swap then titleHost else bodyHost
		local msg = tostring(payload.message or "")
		if msg ~= "" then
			setGuiText(bodySlot, msg)
		end
		task.delay(4, function()
			if not bodySlot or not bodySlot.Parent then
				return
			end
			local step = player:GetAttribute(Constants.FtueStepAttribute) :: any
			if typeof(step) == "string" then
				local _, b = copyForStep(step)
				if b then
					setGuiText(bodySlot, b)
				end
			elseif lastBody ~= "" then
				setGuiText(bodySlot, lastBody)
			end
		end)
	end)
end

return FtueDialogueController
