--!strict
-- Strait passage info (`StarterGui.StraitInfoPanelGui` → `PlayerGui`).

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "StraitInfoPanelGui"

local StraitInfoPanel = {}

function StraitInfoPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function StraitInfoPanel.screenName(): string
	return SCREEN_NAME
end

return StraitInfoPanel
