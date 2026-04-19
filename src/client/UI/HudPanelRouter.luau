--!strict
-- Wires HUD modal-toggle buttons to `ScreenGui`s (exclusive group; second press closes).
-- Buttons live in authored regions of `HUD.Canvas` (see live Studio layout):
--   * `TopRow`         — OilPriceButton, StraitStatusButton
--   * `Canvas` direct  — StraitControlCta (aliases `StraitControlCTA`)
--   * `Canvas.Buttons` — DailyButton, SettingsButton
-- Shop / ship oil / sell / manage-ship / Robux entrypoints are **not** required here when those
-- buttons were removed or moved (e.g. world `ProximityPrompt` + `openScreen`). `openScreen` lazy-binds
-- any `SCREEN_BIND` panel so prompts do not depend on this loop finishing first.
-- Retries until every **mapped** button is wired or attempts exhaust.

local Players = game:GetService("Players")

local ActiveManifestController = require(script.Parent.ActiveManifestController)
local DailyPanel = require(script.Parent.HudPanels.DailyPanel)
local EquipmentShopPanel = require(script.Parent.HudPanels.EquipmentShopPanel)
local OilPriceInfoPanel = require(script.Parent.HudPanels.OilPriceInfoPanel)
local RobuxShopPanel = require(script.Parent.HudPanels.RobuxShopPanel)
local SellOilPanel = require(script.Parent.HudPanels.SellOilPanel)
local ShipManagementPanel = require(script.Parent.HudPanels.ShipManagementPanel)
local ShipOilPanel = require(script.Parent.HudPanels.ShipOilPanel)
local StraitControlPanel = require(script.Parent.HudPanels.StraitControlPanel)
local SettingsPanel = require(script.Parent.HudPanels.SettingsPanel)
local StraitInfoPanel = require(script.Parent.HudPanels.StraitInfoPanel)
local HudPanelTypes = require(script.Parent.HudPanelTypes)
local HudTriggerHover = require(script.Parent.HudTriggerHover)

local STRAIT_CONTROL_CTA_ALIASES = { "StraitControlCta", "StraitControlCTA" }

-- Maps **HUD GuiButton.Name** → **target ScreenGui name**. `findHudModalButton`
-- searches `Canvas` direct children, then `Canvas.Buttons`, then `Canvas.TopRow`,
-- then a recursive HUD scan as a last resort.
-- Legacy TopRow / grid names (`ShopButton`, `ManageShipButton`, `ShipOilButton`, `SellOilButton`,
-- canvas `RobuxShop`) are intentionally omitted — open those modals from authored prompts / HUD v2.
local BUTTON_TO_SCREEN: { [string]: string } = {
	OilPriceButton = OilPriceInfoPanel.screenName(),
	StraitStatusButton = StraitInfoPanel.screenName(),
	StraitControlCta = StraitControlPanel.screenName(),
	DailyButton = DailyPanel.screenName(),
	SettingsButton = SettingsPanel.screenName(),
}

local SCREEN_BIND: { [string]: (PlayerGui) -> HudPanelTypes.HudPanelController? } = {
	[OilPriceInfoPanel.screenName()] = OilPriceInfoPanel.bind,
	[StraitControlPanel.screenName()] = StraitControlPanel.bind,
	[StraitInfoPanel.screenName()] = StraitInfoPanel.bind,
	[EquipmentShopPanel.screenName()] = EquipmentShopPanel.bind,
	[ShipOilPanel.screenName()] = ShipOilPanel.bind,
	[ShipManagementPanel.screenName()] = ShipManagementPanel.bind,
	[SettingsPanel.screenName()] = SettingsPanel.bind,
	[SellOilPanel.screenName()] = SellOilPanel.bind,
	[DailyPanel.screenName()] = DailyPanel.bind,
	[RobuxShopPanel.screenName()] = RobuxShopPanel.bind,
}

local HudPanelRouter = {}

local started = false

-- Module-scoped registry: filled from `start()` and lazily from `openScreen` when a `ScreenGui` appears later.
-- Exposed via `openScreen` / `closeAll` for non-HUD-button triggers (e.g. ProximityPrompts).
local controllersByScreen: { [string]: HudPanelTypes.HudPanelController? } = {}
local controllersList: { HudPanelTypes.HudPanelController } = {}

local function bindPanelForScreen(playerGui: PlayerGui, screenName: string): HudPanelTypes.HudPanelController?
	local existing = controllersByScreen[screenName]
	if existing then
		return existing
	end
	local binder = SCREEN_BIND[screenName]
	if not binder then
		return nil
	end
	local ctrl = binder(playerGui)
	if ctrl then
		controllersByScreen[screenName] = ctrl
		table.insert(controllersList, ctrl)
	end
	return ctrl
end

local function closeAllExceptCtrl(keep: HudPanelTypes.HudPanelController?)
	for _, c in ipairs(controllersList) do
		if c ~= keep then
			c.Close()
		end
	end
end

local function passthroughDecorationsToTrigger(btn: GuiButton)
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			d.Active = false
		end
	end
end

local function expectedButtonCount(): number
	local n = 0
	for _ in pairs(BUTTON_TO_SCREEN) do
		n += 1
	end
	return n
end

function HudPanelRouter.start(playerGui: PlayerGui)
	if started then
		return
	end
	print("[Client] HudPanelRouter: start() — waiting for HUD + modal ScreenGuis (HUD buttons optional)…")

	task.spawn(function()
		local needButtons = expectedButtonCount()
		local wiredButton: { [string]: boolean } = {}
		local warnedMissingButton: { [string]: boolean } = {}

		for attempt = 1, 120 do
			if started then
				return
			end
			local hud = playerGui:FindFirstChild("HUD")
			if not (hud and hud:IsA("ScreenGui")) then
				task.wait(0.5)
				continue
			end
			local canvas = hud:FindFirstChild("Canvas")
			-- We only require `Canvas` to exist. `TopRow` and `Buttons` are each looked up
			-- per-button in `findHudModalButton`; missing either is fine (e.g. some
			-- StarterGui presets ship without the right-side grid).
			if not (canvas and canvas:IsA("Frame")) then
				task.wait(0.5)
				continue
			end
			local topRow = canvas:FindFirstChild("TopRow")
			local buttonsFrame = canvas:FindFirstChild("Buttons")

			ActiveManifestController.start(playerGui)

			for screenName in pairs(SCREEN_BIND) do
				bindPanelForScreen(playerGui, screenName)
			end

			local closeAllExcept = closeAllExceptCtrl
			local byScreen = controllersByScreen

			local function wireTrigger(btn: GuiButton, ctrl: HudPanelTypes.HudPanelController)
				passthroughDecorationsToTrigger(btn)
				local armed = false
				local function onPress()
					if armed then
						return
					end
					armed = true
					task.defer(function()
						armed = false
					end)
					if ctrl.IsOpen() then
						ctrl.Close()
						return
					end
					closeAllExcept(nil)
					ctrl.Open()
				end
				btn.Activated:Connect(onPress)
				btn.MouseButton1Click:Connect(onPress)
				HudTriggerHover.attach(btn)
			end

			local function findHudModalButton(name: string): GuiButton?
				local names = if name == "StraitControlCta" then STRAIT_CONTROL_CTA_ALIASES else { name }
				-- Search order:
				--   1. Direct child of `Canvas`  (e.g. `StraitControlCta`)
				--   2. `Canvas.Buttons`           (right-side grid: DailyButton, SettingsButton)
				--   3. `Canvas.TopRow`            (status bar: OilPriceButton, StraitStatusButton)
				--   4. Recursive `HUD` fallback   (anywhere else in the HUD)
				local roots: { Instance } = {}
				if canvas then table.insert(roots, canvas) end
				if buttonsFrame and buttonsFrame:IsA("GuiObject") then table.insert(roots, buttonsFrame) end
				if topRow and topRow:IsA("GuiObject") then table.insert(roots, topRow) end
				table.insert(roots, hud)
				for _, tryName in ipairs(names) do
					for i, root in ipairs(roots) do
						-- Direct child first when the root is `Canvas` so we don't recurse
						-- into `Buttons` / `TopRow` / etc. and grab the wrong one.
						local b: Instance? = if i == 1 and root == canvas
							then root:FindFirstChild(tryName)
							else root:FindFirstChild(tryName, true)
						if b and b:IsA("GuiButton") then
							return b :: GuiButton
						end
					end
				end
				return nil
			end

			for buttonName, screenName in pairs(BUTTON_TO_SCREEN) do
				if wiredButton[buttonName] then
					continue
				end
				local btn = findHudModalButton(buttonName)
				local ctrl = byScreen[screenName]
				if not (btn and btn:IsA("GuiButton")) then
					if not warnedMissingButton[buttonName] then
						warnedMissingButton[buttonName] = true
						warn(
							"[Client] HudPanelRouter: no HUD button named",
							buttonName,
							"(modal still openable via ProximityPrompt / openScreen). Skipping wire."
						)
					end
					continue
				end
				if not ctrl then
					continue
				end
				wireTrigger(btn, ctrl)
				wiredButton[buttonName] = true
			end

			local wired = 0
			for _ in pairs(wiredButton) do
				wired += 1
			end

			if wired >= needButtons then
				started = true
				print("[Client] HudPanelRouter: HUD modal buttons wired (" .. tostring(wired) .. "/" .. tostring(needButtons) .. ").")
				return
			end

			if attempt == 1 or attempt % 10 == 0 then
				local missingPanels: { string } = {}
				for sn in pairs(SCREEN_BIND) do
					if not byScreen[sn] then
						table.insert(missingPanels, sn)
					end
				end
				table.sort(missingPanels)
				print(
					"[Client] HudPanelRouter: HUD buttons",
					wired,
					"/",
					needButtons,
					" | ScreenGuis not yet in PlayerGui:",
					#missingPanels > 0 and table.concat(missingPanels, ", ") or "(none)"
				)
			end

			task.wait(0.5)
		end

		started = true
		local wired = 0
		for _ in pairs(wiredButton) do
			wired += 1
		end
		warn(
			"[Client] HudPanelRouter: timed out; wired ",
			wired,
			"/",
			needButtons,
			" — add missing StarterGui ScreenGuis to PlayerGui (Rojo does not sync StarterGui)."
		)
	end)
end

--- Toggle a modal panel by its `ScreenGui.Name` (matches `<Panel>.screenName()` strings),
--- closing all other panels first. Returns true when a panel was toggled, false when the
--- name is unknown or the `ScreenGui` is not in `PlayerGui` yet.
function HudPanelRouter.openScreen(screenName: string): boolean
	local plr = Players.LocalPlayer
	if not plr then
		return false
	end
	local playerGui = plr:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	local ctrl = bindPanelForScreen(playerGui, screenName)
	if not ctrl then
		return false
	end
	if ctrl.IsOpen() then
		ctrl.Close()
		return true
	end
	closeAllExceptCtrl(nil)
	ctrl.Open()
	return true
end

function HudPanelRouter.closeAll()
	closeAllExceptCtrl(nil)
end

return HudPanelRouter
