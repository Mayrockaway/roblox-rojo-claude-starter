--!strict
-- Ship management modal (`StarterGui.ShipManagementPanelGui` → `PlayerGui`).
-- `ChangeShipButton` opens `SelectShipPanelGui` (bound from `SelectShipPanel`).

local SelectShipPanel = require(script.Parent.SelectShipPanel)
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "ShipManagementPanelGui"

local ShipManagementPanel = {}
local changeShipConnection: RBXScriptConnection? = nil

function ShipManagementPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	SelectShipPanel.bind(playerGui)

	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	if changeShipConnection then
		changeShipConnection:Disconnect()
		changeShipConnection = nil
	end

	local changeShip = ctrl.ScreenGui:FindFirstChild("ChangeShipButton", true)
	if changeShip and changeShip:IsA("GuiButton") then
		local selectCtrl = SelectShipPanel.bind(playerGui)
		changeShipConnection = changeShip.Activated:Connect(function()
			if selectCtrl then
				selectCtrl.Open()
			end
		end)
	end

	return ctrl
end

function ShipManagementPanel.screenName(): string
	return SCREEN_NAME
end

return ShipManagementPanel
