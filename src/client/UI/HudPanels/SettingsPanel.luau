--!strict
-- Settings modal (`StarterGui.Settings` → `PlayerGui`). Shell + close authored in Studio; `ModalPanelShell` wires **`Close`**.

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "Settings"

local SettingsPanel = {}

function SettingsPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function SettingsPanel.screenName(): string
	return SCREEN_NAME
end

return SettingsPanel
