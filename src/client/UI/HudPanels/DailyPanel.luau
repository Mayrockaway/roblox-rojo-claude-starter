--!strict
-- Daily rewards modal (`StarterGui.Daily` → `PlayerGui.Daily`). Shell + content authored
-- in Studio; this controller only exposes Open/Close/IsOpen so `HudPanelRouter` can include
-- it in the modal-exclusivity group. No extra wiring inside the panel yet — populate when
-- daily-rewards backend is added.
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "Daily"

local DailyPanel = {}

function DailyPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function DailyPanel.screenName(): string
	return SCREEN_NAME
end

return DailyPanel
