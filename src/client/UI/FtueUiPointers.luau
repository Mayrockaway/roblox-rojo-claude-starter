--!strict
-- Toggles Studio-authored pointer **frames** (`*PointerRoot`) for the current `FtueStep`.
-- Most pointers live under `FTUEDialogueGui.Canvas.Pointers`. Sell Oil modal arrows sit under the **same
-- subtree as the card** — `SellOilPanelGui` — so they align with the letterboxed panel (see `PANEL_FIRST_ROOT`).

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local SellOilPanel = require(script.Parent:WaitForChild("HudPanels"):WaitForChild("SellOilPanel"))
local ShipOilPanel = require(script.Parent:WaitForChild("HudPanels"):WaitForChild("ShipOilPanel"))
local FtueDispatchPointerSignals = require(script.Parent:WaitForChild("FtueDispatchPointerSignals"))
local FtueTpHomePointerState = require(script.Parent:WaitForChild("FtueTpHomePointerState"))
local FtueTpHomePointerSignals = require(script.Parent:WaitForChild("FtueTpHomePointerSignals"))

local FtueUiPointers = {}

--- Pointers live under the FTUE dialogue `ScreenGui` (`FTUEDialogueGui.Canvas.Pointers`),
--- or under each modal panel's `Canvas.PanelHost.Pointers` so they align with the letterboxed card.
---
--- **Naming convention:** outer frame is **`*PointerRoot`** (toggled `Visible`), inner image is **`*Pointer`**
--- (used as the tween target). `findTweenTarget` strips the `Root` suffix to find the inner image.
local POINTER_ROOT_BY_STEP: { [string]: string } = {
	[FtueConfig.Step.WaitShipment] = "StraitPointerRoot",
	[FtueConfig.Step.WaitDocksShipUpgrade] = "TownPointerRoot",
	--- `WaitDocksEquipmentShop` resolves through `resolveWaitDocksEquipmentShopPointer`
	--- (sub-step driven: `BuyDrill` → `BuyDrillPointerRoot`, `ClosePanel` →
	--- `CloseButtonPointerRoot`). Both pointers live **inside** `ShopPanelGui` so
	--- they're only visible while the panel is open; the world beam
	--- (`PlayerToPoiBeam` → `DocksShop`) guides the player to the prox prompt before
	--- the panel opens.
	[FtueConfig.Step.WaitDocksHire] = "HirePointerRoot",
	[FtueConfig.Step.WaitSell] = "OilPricePointerRoot",
}

--- Active set the resolver iterates each refresh. Any name in this list is either toggled on (active)
--- or force-hidden (inactive). Legacy roots are included so leftover Studio authoring stays hidden.
local ALL_POINTER_ROOT_NAMES = {
	"StraitPointerRoot",
	"TownPointerRoot",
	"HirePointerRoot",
	"SellBarrelPointerRoot",
	"SellPointerRoot",
	"ShipBarrelPointerRoot",
	"DispatchPointerRoot",
	"CargoUpgradePointerRoot",
	"ClosePointerRoot",
	"OilPricePointerRoot",
	"BuyDrillPointerRoot",
	"CloseButtonPointerRoot",
	"TPHomePointerRoot",
	-- Legacy roots kept so any prior Studio authoring is force-hidden when not active:
	"PlotShipmentPointerRoot",
	"DocksTownBuyPointerRoot",
	"FtueDockmanWorldPointerRoot",
	"ShipCapacityUpgradeBuyPointerRoot",
	"ShipManagementClosePointerRoot",
	"FtuePirateHireWorldPointerRoot",
	"SellOilPointerRoot",
	"SellButtonPointerRoot",
}

local SELL_OIL_PANEL_GUI = "SellOilPanelGui"
local SHIP_MANAGEMENT_PANEL_GUI = "ShipManagementPanelGui"
local SHIP_OIL_PANEL_GUI = "ShipOilPanelGui"
local SHOP_PANEL_GUI = "ShopPanelGui"
local HUD_SCREEN_GUI = "HUD"

--- World-hierarchy `GuiObject` roots (e.g. under `BillboardGui` / `SurfaceGui` in `Workspace`).
--- (NPC pointers — Dockman / PirateHire / ArmyGeneral — are now driven by `PlayerToPoiBeam` instead.)
local WORKSPACE_POINTER_ROOT_NAMES: { [string]: boolean } = {
	FtueDockmanWorldPointerRoot = true,
	FtuePirateHireWorldPointerRoot = true,
}

local warnedMissingTpHomeRoot = false

--- Prefer modal `ScreenGui` for roots that must align with cargo / CTA (author under that panel in Studio).
local PANEL_FIRST_ROOT: { [string]: string } = {
	SellBarrelPointerRoot = SELL_OIL_PANEL_GUI,
	SellPointerRoot = SELL_OIL_PANEL_GUI,
	CargoUpgradePointerRoot = SHIP_MANAGEMENT_PANEL_GUI,
	ClosePointerRoot = SHIP_MANAGEMENT_PANEL_GUI,
	ShipBarrelPointerRoot = SHIP_OIL_PANEL_GUI,
	DispatchPointerRoot = SHIP_OIL_PANEL_GUI,
	BuyDrillPointerRoot = SHOP_PANEL_GUI,
	CloseButtonPointerRoot = SHOP_PANEL_GUI,
	-- Legacy authored roots (kept so they're still discoverable for hide-when-inactive):
	SellButtonPointerRoot = SELL_OIL_PANEL_GUI,
	ShipCapacityUpgradeBuyPointerRoot = SHIP_MANAGEMENT_PANEL_GUI,
	ShipManagementClosePointerRoot = SHIP_MANAGEMENT_PANEL_GUI,
}

--- Equipment shop leg pointer is two-phase, both inside `ShopPanelGui`:
---   `BuyDrill`   → `BuyDrillPointerRoot`   (highlight the free drill_t3 Buy button)
---   `ClosePanel` → `CloseButtonPointerRoot` (after purchase, prompt the player to close;
---                   closing fires `EquipmentShopPanelClosed` which advances FTUE).
--- Sub-step is set server-side (`Constants.FtueDocksEquipmentShopSubStepAttribute`).
local function resolveWaitDocksEquipmentShopPointer(player: Player, step: string): string?
	if step ~= FtueConfig.Step.WaitDocksEquipmentShop then
		return nil
	end
	local subAny = player:GetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute)
	local sub = if typeof(subAny) == "string" then (subAny :: string) else ""
	if sub == "ClosePanel" then
		return "CloseButtonPointerRoot"
	end
	--- Default to the buy pointer for `BuyDrill` (or unset, while the attribute is
	--- replicating on first entry).
	return "BuyDrillPointerRoot"
end

local function resolveWaitDocksUpgradeShipPointer(player: Player, step: string): string?
	if step ~= FtueConfig.Step.WaitDocksUpgradeShip then
		return nil
	end
	local subAny = player:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute)
	local sub = if typeof(subAny) == "string" then (subAny :: string) else ""
	if sub == "CargoBuy" then
		return "CargoUpgradePointerRoot"
	elseif sub == "CloseModal" then
		return "ClosePointerRoot"
	end
	--- `Dockman` substep is covered by the `PlayerToPoiBeam` beam — no UI pointer.
	return nil
end

local function resolveActivePointerRootName(player: Player, step: string): string?
	if step == FtueConfig.Step.WaitWarehouseSell then
		local open, barrels = SellOilPanel.peekOpenAndBarrelsForSellFtue()
		if not open then
			--- Panel not open: warehouse-terminal beam (`PlayerToPoiBeam`) handles guidance.
			return nil
		elseif barrels <= 0 then
			return "SellBarrelPointerRoot"
		else
			return "SellPointerRoot"
		end
	end
	if step == FtueConfig.Step.WaitPlotShipment then
		--- Sequence inside `ShipOilPanelGui`: open prompt → barrel pointer → dispatch pointer → step completes.
		--- Panel not open: `PlotDispatch` beam (`PlayerToPoiBeam`) handles guidance to the prox prompt.
		local open, barrels = ShipOilPanel.peekOpenAndBarrelsForFtue()
		if not open then
			return nil
		elseif barrels <= 0 then
			return "ShipBarrelPointerRoot"
		else
			return "DispatchPointerRoot"
		end
	end
	local docksShip = resolveWaitDocksUpgradeShipPointer(player, step)
	if docksShip then
		return docksShip
	end
	local equipShop = resolveWaitDocksEquipmentShopPointer(player, step)
	if equipShop then
		return equipShop
	end
	return POINTER_ROOT_BY_STEP[step]
end

--- Teleport Home hint: from `Done` through post-FTUE until the player uses Teleport Home.
local function resolveTpHomePointerRootName(): string?
	if FtueTpHomePointerState.shouldShowPointer() then
		return "TPHomePointerRoot"
	end
	return nil
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
	if rootName == "TPHomePointerRoot" or rootName == "DocksTownBuyPointerRoot" then
		local hud = playerGui:FindFirstChild(HUD_SCREEN_GUI, true)
		if hud and hud:IsA("ScreenGui") then
			local frHud = hud:FindFirstChild(rootName, true)
			if frHud and frHud:IsA("GuiObject") then
				return frHud
			end
		end
	end
	if WORKSPACE_POINTER_ROOT_NAMES[rootName] then
		local w = Workspace:FindFirstChild(rootName, true)
		if w and w:IsA("GuiObject") then
			return w :: GuiObject
		end
	end
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
	if dialogue then
		if rootName == "TPHomePointerRoot" then
			local frDlg = dialogue:FindFirstChild(rootName, true)
			if frDlg and frDlg:IsA("GuiObject") then
				return frDlg
			end
		end
		local folder = findPointersFolder(dialogue)
		if folder then
			local fr = folder:FindFirstChild(rootName, true)
			if fr and fr:IsA("GuiObject") then
				return fr
			end
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

	--- Debounced `refresh` scheduler.
	---
	--- Several signals (`DescendantAdded` on multiple ScreenGuis, attribute changes,
	--- remote events) all want to re-evaluate which pointer is active. Without a
	--- guard, opening a single panel can queue dozens of `task.defer(refresh)`
	--- calls in one frame because each descendant added fires the connection
	--- separately and `task.defer` does **not** dedupe. Each `refresh()` does up
	--- to 22 recursive `FindFirstChild(_, true)` walks across `PlayerGui`, so the
	--- pile-up shows up as a multi-hundred-ms hitch in the microprofiler when
	--- the FTUE dialogue or a modal panel pops in.
	---
	--- The flag collapses every request inside the same frame into a single
	--- end-of-frame refresh.
	local refreshScheduled = false
	local refresh -- forward declared so `scheduleRefresh` can capture it
	local function scheduleRefresh()
		if refreshScheduled then
			return
		end
		refreshScheduled = true
		task.defer(function()
			refreshScheduled = false
			if refresh then
				refresh()
			end
		end)
	end

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

	function refresh()
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
		if step == FtueConfig.Step.Done then
			FtueTpHomePointerState.markLegActive()
		end

		local activeRootName: string? = resolveTpHomePointerRootName() or resolveActivePointerRootName(player, step)
		if activeRootName == "TPHomePointerRoot" then
			local test = findPointerRootFrame(playerGui, "TPHomePointerRoot")
			if not test and not warnedMissingTpHomeRoot then
				warnedMissingTpHomeRoot = true
				warn(
					"[FTUE] TPHomePointerRoot not found under PlayerGui (expected under FTUEDialogueGui.Canvas.Pointers or HUD). "
						.. "Author `TPHomePointerRoot` + child `TPHomePointer` in Studio."
				)
			end
		end

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
	scheduleRefresh()
	task.delay(0.5, scheduleRefresh)
	player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
		local a = normStep(player:GetAttribute(Constants.FtueStepAttribute))
		if a == "" then
			stepFromRemote = ""
		end
		scheduleRefresh()
	end)
	player:GetAttributeChangedSignal(Constants.FtueDocksUpgradeSubStepAttribute):Connect(scheduleRefresh)
	player:GetAttributeChangedSignal(Constants.FtueDocksEquipmentShopSubStepAttribute):Connect(scheduleRefresh)
	if ftueStateUpdate then
		ftueStateUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) == "table" then
				local s = (payload :: any).step
				if s == nil then
					stepFromRemote = ""
				elseif typeof(s) == "string" then
					stepFromRemote = normStep(s)
				end
			end
			scheduleRefresh()
		end)
	end

	--- Hook a `ScreenGui` so any descendant change schedules a single coalesced
	--- refresh at end of frame instead of one per descendant. Opening a panel
	--- can produce dozens of `DescendantAdded` events; the debouncer collapses
	--- them into one `refresh()` call.
	local function hookDescendantRefresh(sg: ScreenGui)
		sg.DescendantAdded:Connect(scheduleRefresh)
	end

	local dlg0 = findDialogueScreenGui(playerGui)
	if dlg0 then
		hookDescendantRefresh(dlg0)
	end

	local sell0 = playerGui:FindFirstChild(SELL_OIL_PANEL_GUI, true)
	if sell0 and sell0:IsA("ScreenGui") then
		hookDescendantRefresh(sell0)
	end

	local ship0 = playerGui:FindFirstChild(SHIP_MANAGEMENT_PANEL_GUI, true)
	if ship0 and ship0:IsA("ScreenGui") then
		hookDescendantRefresh(ship0)
	end

	local shipOil0 = playerGui:FindFirstChild(SHIP_OIL_PANEL_GUI, true)
	if shipOil0 and shipOil0:IsA("ScreenGui") then
		hookDescendantRefresh(shipOil0)
	end

	playerGui.ChildAdded:Connect(function(ch)
		if ch:IsA("ScreenGui") and (ch.Name == "FTUEDialogueGui" or ch.Name == "FtueDialogueGui") then
			hookDescendantRefresh(ch)
			scheduleRefresh()
		end
		if
			ch:IsA("ScreenGui")
			and (ch.Name == SELL_OIL_PANEL_GUI or ch.Name == SHIP_MANAGEMENT_PANEL_GUI or ch.Name == SHIP_OIL_PANEL_GUI)
		then
			hookDescendantRefresh(ch)
			scheduleRefresh()
		end
	end)

	playerGui.DescendantAdded:Connect(function(inst)
		if inst.Name == "FTUEDialogueGui" or inst.Name == "FtueDialogueGui" then
			scheduleRefresh()
		end
		if inst.Name == "Pointers" then
			scheduleRefresh()
		end
		if
			inst.Name == SELL_OIL_PANEL_GUI
			or inst.Name == SHIP_MANAGEMENT_PANEL_GUI
			or inst.Name == SHIP_OIL_PANEL_GUI
			or inst.Name == HUD_SCREEN_GUI
		then
			scheduleRefresh()
		end
	end)

	--- **Removed:** previously this module had a `Workspace.DescendantAdded` listener
	--- that fired `task.defer(refresh)` for instances named `FtueDockmanWorldPointerRoot`
	--- or `FtuePirateHireWorldPointerRoot`. With ~37k Workspace descendants, that
	--- callback was invoked once per streamed-in instance, contributing to multi-hundred-ms
	--- hitches when streaming chunks arrived.
	---
	--- The world-hierarchy pointer roots in `WORKSPACE_POINTER_ROOT_NAMES` are
	--- already re-resolved on every FTUE step / sub-step transition (see
	--- attribute-changed signals above) and on every `ftueStateUpdate` remote
	--- payload. If a world pointer root is authored to spawn at a specific step,
	--- those signals will pick it up. If a future caller needs immediate world
	--- discovery, prefer **`CollectionService` tags** so the engine filters in
	--- C++ instead of firing into Lua per descendant.

	FtueDispatchPointerSignals.subscribeRefresh(scheduleRefresh)

	FtueTpHomePointerSignals.subscribeTeleportHomePressed(scheduleRefresh)
end

return FtueUiPointers
