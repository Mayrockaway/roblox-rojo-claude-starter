--!strict
-- Robux strait control shell (`StarterGui.StraitControlPanelGui` → `PlayerGui`).
-- Open/close from `StraitControlCta` later; `HudPanelBase` + `ModalPanelShell` wire **`CloseButton`** only.

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "StraitControlPanelGui"

local StraitControlPanel = {}

function StraitControlPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function StraitControlPanel.screenName(): string
	return SCREEN_NAME
end

return StraitControlPanel
