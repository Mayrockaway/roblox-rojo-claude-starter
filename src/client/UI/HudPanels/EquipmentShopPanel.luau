--!strict
-- Equipment shop modal (`StarterGui.ShopPanelGui` → `PlayerGui`).

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "ShopPanelGui"

local EquipmentShopPanel = {}

function EquipmentShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function EquipmentShopPanel.screenName(): string
	return SCREEN_NAME
end

return EquipmentShopPanel
