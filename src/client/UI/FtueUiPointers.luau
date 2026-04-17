--!strict
-- Toggles Studio-authored pointer **frames** (`*PointerRoot`) for the current `FtueStep`.
-- Most pointers live under `FTUEDialogueGui.Canvas.Pointers`. Ship / Sell arrows must sit under the **same
-- subtree as the card** — e.g. `ShipOilPanelGui.Canvas.PanelHost` (full-size transparent overlay **sibling
-- of** `Panel`, high `ZIndex`), **not** `Canvas.Pointers` beside `PanelHost`. Otherwise arrows use viewport
-- space while the panel uses the aspect-letterboxed `PanelHost` space and drift in the device emulator.
-- This module resolves `ShipBarrelPointerRoot` / `DispatchPointerRoot` and `SellBarrelPointerRoot` /
-- `SellButtonPointerRoot` under those modals first.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local ShipOilPanel = require(script.Parent:WaitForChild("HudPanels"):WaitForChild("ShipOilPanel"))
local SellOilPanel = require(script.Parent:WaitForChild("HudPanels"):WaitForChild("SellOilPanel"))
local FtueDispatchPointerSignals = require(script.Parent:WaitForChild("FtueDispatchPointerSignals"))

local FtueUiPointers = {}

--- Pointers live under the FTUE dialogue `ScreenGui`, not as separate top-level `ScreenGui`s.
--- `Dispatch` / `Sell` use sequential roots (HUD button → steppers → primary CTA); see `resolveActivePointerRootName`.
local POINTER_ROOT_BY_STEP: { [string]: string } = {
	[FtueConfig.Step.WaitShipment] = "StraitPointerRoot",
	[FtueConfig.Step.WaitSell] = "OilPricePointerRoot",
}

local ALL_POINTER_ROOT_NAMES = {
	"ShipOilPointerRoot",
	"ShipBarrelPointerRoot",
	"DispatchPointerRoot",
	"StraitPointerRoot",
	"SellOilPointerRoot",
	"SellBarrelPointerRoot",
	"SellButtonPointerRoot",
	"OilPricePointerRoot",
}

local SHIP_OIL_PANEL_GUI = "ShipOilPanelGui"
local SELL_OIL_PANEL_GUI = "SellOilPanelGui"

--- Prefer modal `ScreenGui` for roots that must align with cargo / CTA (author under that panel in Studio).
local PANEL_FIRST_ROOT: { [string]: string } = {
	ShipBarrelPointerRoot = SHIP_OIL_PANEL_GUI,
	DispatchPointerRoot = SHIP_OIL_PANEL_GUI,
	SellBarrelPointerRoot = SELL_OIL_PANEL_GUI,
	SellButtonPointerRoot = SELL_OIL_PANEL_GUI,
}

local function resolveActivePointerRootName(step: string): string?
	if step == FtueConfig.Step.Dispatch then
		local open, barrels = ShipOilPanel.peekOpenAndBarrelsForFtue()
		if not open then
			return "ShipOilPointerRoot"
		elseif barrels <= 0 then
			return "ShipBarrelPointerRoot"
		else
			return "DispatchPointerRoot"
		end
	elseif step == FtueConfig.Step.Sell then
		local open, barrels = SellOilPanel.peekOpenAndBarrelsForSellFtue()
		if not open then
			return "SellOilPointerRoot"
		elseif barrels <= 0 then
			return "SellBarrelPointerRoot"
		else
			return "SellButtonPointerRoot"
		end
	end
	return POINTER_ROOT_BY_STEP[step]
end

local AMP_OFFSET_PX = 12
local TWEEN_SECS = 0.6

local function normStep(any: any): string
	if typeof(any) ~= "string" then
		return ""
	end
	return (any :: string):gsub("^%s+", ""):gsub("%s+$", "")
end

local STEP_ORDER: { [string]: number } = {}
for i, s in ipairs(FtueConfig.Order) do
	STEP_ORDER[s] = i
end

local function pickDisplayedStep(attrStep: string, remoteStep: string): string
	local a = attrStep
	local r = remoteStep
	if r == "" then
		return a
	end
	if a == "" then
		return r
	end
	if a == r then
		return a
	end
	local ia = STEP_ORDER[a]
	local ir = STEP_ORDER[r]
	if typeof(ia) == "number" and typeof(ir) == "number" then
		return (ia >= ir) and a or r
	end
	return a
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

local function findPointersFolder(dialogue: ScreenGui): Instance?
	local canvas = dialogue:FindFirstChild("Canvas") or dialogue:FindFirstChild("canvas")
	if not canvas then
		canvas = dialogue:FindFirstChild("Canvas", true)
	end
	if not canvas then
		return nil
	end
	return canvas:FindFirstChild("Pointers") or canvas:FindFirstChild("pointers")
end

--- One `*PointerRoot` instance: modal-hosted first (if configured), else `FTUEDialogueGui.Canvas.Pointers`.
local function findPointerRootFrame(playerGui: PlayerGui, rootName: string): GuiObject?
	local panelFirst = PANEL_FIRST_ROOT[rootName]
	if typeof(panelFirst) == "string" then
		local sg = playerGui:FindFirstChild(panelFirst, true)
		if sg and sg:IsA("ScreenGui") then
			local fr = sg:FindFirstChild(rootName, true)
			if fr and fr:IsA("GuiObject") then
				return fr
			end
		end
	end
	local dialogue = findDialogueScreenGui(playerGui)
	local folder = dialogue and findPointersFolder(dialogue)
	if folder then
		local fr = folder:FindFirstChild(rootName)
		if fr and fr:IsA("GuiObject") then
			return fr
		end
	end
	return nil
end

--- e.g. `ShipOilPointerRoot` → tween child `ShipOilPointer` when present.
local function findTweenTarget(rootFrame: GuiObject): GuiObject
	local n = rootFrame.Name
	local innerName = n:gsub("Root$", "")
	if innerName ~= n then
		local inner = rootFrame:FindFirstChild(innerName)
		if inner and inner:IsA("GuiObject") then
			return inner
		end
	end
	local img = rootFrame:FindFirstChildWhichIsA("ImageLabel", true)
	if img and img:IsA("GuiObject") then
		return img
	end
	local ib = rootFrame:FindFirstChildWhichIsA("ImageButton", true)
	if ib and ib:IsA("GuiObject") then
		return ib
	end
	return rootFrame
end

function FtueUiPointers.start(player: Player, playerGui: PlayerGui, ftueStateUpdate: RemoteEvent?)
	local tweensByGui: { [GuiObject]: Tween } = {}
	local basePosByGui: { [GuiObject]: UDim2 } = {}
	local stepFromRemote: string = ""

	local function currentFtueStep(): string
		return pickDisplayedStep(normStep(player:GetAttribute(Constants.FtueStepAttribute)), stepFromRemote)
	end

	local function stopTween(gui: GuiObject)
		local tw = tweensByGui[gui]
		if tw then
			tw:Cancel()
		end
		tweensByGui[gui] = nil
		local base = basePosByGui[gui]
		if base then
			gui.Position = base
			basePosByGui[gui] = nil
		end
	end

	local function startTween(gui: GuiObject)
		stopTween(gui)
		local base = gui.Position
		basePosByGui[gui] = base
		local left = UDim2.new(base.X.Scale, base.X.Offset - AMP_OFFSET_PX, base.Y.Scale, base.Y.Offset)
		local right = UDim2.new(base.X.Scale, base.X.Offset + AMP_OFFSET_PX, base.Y.Scale, base.Y.Offset)
		gui.Position = left
		local ti = TweenInfo.new(TWEEN_SECS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		local tw = TweenService:Create(gui, ti, { Position = right })
		tweensByGui[gui] = tw
		tw:Play()
	end

	local warnedMissingHost = false

	local function refresh()
		if FtueConfig.Enabled ~= true then
			for _, rootName in ipairs(ALL_POINTER_ROOT_NAMES) do
				local fr = findPointerRootFrame(playerGui, rootName)
				if fr then
					fr.Visible = false
					stopTween(findTweenTarget(fr))
				end
			end
			local toStop = {}
			for g in pairs(tweensByGui) do
				table.insert(toStop, g)
			end
			for _, g in ipairs(toStop) do
				stopTween(g)
			end
			return
		end

		local dialogue = findDialogueScreenGui(playerGui)
		local pointersFolder = dialogue and findPointersFolder(dialogue)
		if not pointersFolder then
			if not warnedMissingHost then
				warnedMissingHost = true
				warn(
					"[FTUE] FtueUiPointers: missing `Canvas.Pointers` under FtueDialogueGui — HUD/strait/sell-intro pointers need it. (Ship/Sell barrel pointers can live under ShipOilPanelGui / SellOilPanelGui.)"
				)
			end
		end

		local step = currentFtueStep()
		local activeRootName = resolveActivePointerRootName(step)

		for _, rootName in ipairs(ALL_POINTER_ROOT_NAMES) do
			local frAny = findPointerRootFrame(playerGui, rootName)
			if not (frAny and frAny:IsA("GuiObject")) then
				continue
			end
			local fr = frAny :: GuiObject
			local show = activeRootName ~= nil and activeRootName == rootName
			local tweenTarget = findTweenTarget(fr)
			fr.Visible = show
			--- Studio often leaves the inner `*Pointer` image `Visible = false` while the `*PointerRoot` is true; the root alone shows nothing.
			if show and tweenTarget ~= fr then
				tweenTarget.Visible = true
			end
			if show then
				startTween(tweenTarget)
			else
				stopTween(tweenTarget)
			end
		end

		--- If `ShipBarrelPointerRoot` (etc.) exists under both the modal and `FTUEDialogueGui`, hide the FTUE copy so only one shows.
		local dlg = findDialogueScreenGui(playerGui)
		local dupFolder = dlg and findPointersFolder(dlg)
		if dupFolder then
			for dupName in pairs(PANEL_FIRST_ROOT) do
				local canonical = findPointerRootFrame(playerGui, dupName)
				local dup = dupFolder:FindFirstChild(dupName)
				if canonical and dup and dup:IsA("GuiObject") and dup ~= canonical then
					dup.Visible = false
					stopTween(findTweenTarget(dup))
				end
			end
		end
	end

	refresh()
	task.defer(refresh)
	task.delay(0.5, refresh)
	player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
		local a = normStep(player:GetAttribute(Constants.FtueStepAttribute))
		if a == "" then
			stepFromRemote = ""
		end
		refresh()
	end)
	if ftueStateUpdate then
		ftueStateUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) == "table" and typeof((payload :: any).step) == "string" then
				stepFromRemote = normStep((payload :: any).step)
			end
			task.defer(refresh)
		end)
	end

	local function hookDescendantRefresh(sg: ScreenGui)
		sg.DescendantAdded:Connect(function()
			task.defer(refresh)
		end)
	end

	local dlg0 = findDialogueScreenGui(playerGui)
	if dlg0 then
		hookDescendantRefresh(dlg0)
	end

	local ship0 = playerGui:FindFirstChild(SHIP_OIL_PANEL_GUI, true)
	if ship0 and ship0:IsA("ScreenGui") then
		hookDescendantRefresh(ship0)
	end
	local sell0 = playerGui:FindFirstChild(SELL_OIL_PANEL_GUI, true)
	if sell0 and sell0:IsA("ScreenGui") then
		hookDescendantRefresh(sell0)
	end

	playerGui.ChildAdded:Connect(function(ch)
		if ch:IsA("ScreenGui") and (ch.Name == "FTUEDialogueGui" or ch.Name == "FtueDialogueGui") then
			hookDescendantRefresh(ch)
			task.defer(refresh)
		end
		if ch:IsA("ScreenGui") and (ch.Name == SHIP_OIL_PANEL_GUI or ch.Name == SELL_OIL_PANEL_GUI) then
			hookDescendantRefresh(ch)
			task.defer(refresh)
		end
	end)

	playerGui.DescendantAdded:Connect(function(inst)
		if inst.Name == "FTUEDialogueGui" or inst.Name == "FtueDialogueGui" then
			task.defer(refresh)
		end
		if inst.Name == "Pointers" then
			task.defer(refresh)
		end
		if inst.Name == SHIP_OIL_PANEL_GUI or inst.Name == SELL_OIL_PANEL_GUI then
			task.defer(refresh)
		end
	end)

	FtueDispatchPointerSignals.subscribeRefresh(function()
		refresh()
	end)
end

return FtueUiPointers
