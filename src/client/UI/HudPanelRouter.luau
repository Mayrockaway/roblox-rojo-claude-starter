--!strict
-- Wires `HUD.Canvas.LeftStack` + `TopRow` buttons to modal `ScreenGuis` (exclusive group + toggle).
-- Retries until every mapped button is wired or attempts exhaust — StarterGui clones can arrive late.

local ActiveManifestController = require(script.Parent.ActiveManifestController)
local EquipmentShopPanel = require(script.Parent.HudPanels.EquipmentShopPanel)
local OilPriceInfoPanel = require(script.Parent.HudPanels.OilPriceInfoPanel)
local SellOilPanel = require(script.Parent.HudPanels.SellOilPanel)
local ShipManagementPanel = require(script.Parent.HudPanels.ShipManagementPanel)
local ShipOilPanel = require(script.Parent.HudPanels.ShipOilPanel)
local StraitControlPanel = require(script.Parent.HudPanels.StraitControlPanel)
local StraitInfoPanel = require(script.Parent.HudPanels.StraitInfoPanel)
local HudPanelTypes = require(script.Parent.HudPanelTypes)
local HudTriggerHover = require(script.Parent.HudTriggerHover)

local STRAIT_CONTROL_CTA_ALIASES = { "StraitControlCta", "StraitControlCTA" }

local BUTTON_TO_SCREEN: { [string]: string } = {
	OilPriceButton = OilPriceInfoPanel.screenName(),
	StraitStatusButton = StraitInfoPanel.screenName(),
	StraitControlCta = StraitControlPanel.screenName(),
	ShopButton = EquipmentShopPanel.screenName(),
	ShipOilButton = ShipOilPanel.screenName(),
	ManageShipButton = ShipManagementPanel.screenName(),
	SellOilButton = SellOilPanel.screenName(),
}

local SCREEN_BIND: { [string]: (PlayerGui) -> HudPanelTypes.HudPanelController? } = {
	[OilPriceInfoPanel.screenName()] = OilPriceInfoPanel.bind,
	[StraitControlPanel.screenName()] = StraitControlPanel.bind,
	[StraitInfoPanel.screenName()] = StraitInfoPanel.bind,
	[EquipmentShopPanel.screenName()] = EquipmentShopPanel.bind,
	[ShipOilPanel.screenName()] = ShipOilPanel.bind,
	[ShipManagementPanel.screenName()] = ShipManagementPanel.bind,
	[SellOilPanel.screenName()] = SellOilPanel.bind,
}

local HudPanelRouter = {}

local started = false

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
	print("[Client] HudPanelRouter: start() — waiting for HUD + all modal ScreenGuis…")

	task.spawn(function()
		local needButtons = expectedButtonCount()
		local wiredButton: { [string]: boolean } = {}

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
			local leftStack = canvas and canvas:FindFirstChild("LeftStack")
			local topRow = canvas and canvas:FindFirstChild("TopRow")
			if not (leftStack and leftStack:IsA("Frame")) or not (topRow and topRow:IsA("Frame")) then
				task.wait(0.5)
				continue
			end

			ActiveManifestController.start(playerGui)

			local byScreen: { [string]: HudPanelTypes.HudPanelController } = {}
			local controllers: { HudPanelTypes.HudPanelController } = {}

			local function ensurePanel(screenName: string)
				if byScreen[screenName] then
					return
				end
				local binder = SCREEN_BIND[screenName]
				if not binder then
					return
				end
				local ctrl = binder(playerGui)
				if ctrl then
					byScreen[screenName] = ctrl
					table.insert(controllers, ctrl)
				end
			end

			for screenName in pairs(SCREEN_BIND) do
				ensurePanel(screenName)
			end

			local function closeAllExcept(keep: HudPanelTypes.HudPanelController?)
				for _, c in ipairs(controllers) do
					if c ~= keep then
						c.Close()
					end
				end
			end

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
				for _, tryName in ipairs(names) do
					local b = topRow:FindFirstChild(tryName, true)
					if b and b:IsA("GuiButton") then
						return b
					end
					b = leftStack:FindFirstChild(tryName, true)
					if b and b:IsA("GuiButton") then
						return b
					end
					b = hud:FindFirstChild(tryName, true)
					if b and b:IsA("GuiButton") then
						return b
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
					if attempt == 1 or attempt % 20 == 0 then
						warn("[Client] HudPanelRouter: missing button", buttonName, "under HUD (TopRow / LeftStack)")
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
				local missingScreens: { string } = {}
				for _, screenName in pairs(BUTTON_TO_SCREEN) do
					if not byScreen[screenName] then
						table.insert(missingScreens, screenName)
					end
				end
				table.sort(missingScreens)
				print(
					"[Client] HudPanelRouter: waiting for ScreenGuis (",
					wired,
					"/",
					needButtons,
					" buttons) missing:",
					table.concat(missingScreens, ", ")
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

return HudPanelRouter
