--!strict
-- Equipment shop modal (`StarterGui.EquipmentShopPanelGui` → `PlayerGui`).

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "EquipmentShopPanelGui"

local EquipmentShopPanel = {}

function EquipmentShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function EquipmentShopPanel.screenName(): string
	return SCREEN_NAME
end

return EquipmentShopPanel
