--!strict
-- Read-only oil price explainer (`StarterGui.OilPriceInfoPanelGui` → `PlayerGui`).

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "OilPriceInfoPanelGui"

local OilPriceInfoPanel = {}

function OilPriceInfoPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function OilPriceInfoPanel.screenName(): string
	return SCREEN_NAME
end

return OilPriceInfoPanel
