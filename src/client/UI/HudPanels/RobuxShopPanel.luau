--!strict
-- Robux shop modal (`StarterGui.test.RobuxShop` → `PlayerGui.test.RobuxShop`). Authored in
-- Studio; this controller exposes Open/Close/IsOpen so `HudPanelRouter` includes it in the
-- modal-exclusivity group. The ScreenGui currently lives under a `test` folder during
-- iteration — `HudPanelBase.tryBind` falls back to a recursive `FindFirstChild` so the
-- folder location does not matter for binding. When the panel ships, move the ScreenGui to
-- a direct child of `StarterGui` (or rename `test`) and this controller keeps working
-- unchanged.
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "RobuxShop"

local RobuxShopPanel = {}

function RobuxShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function RobuxShopPanel.screenName(): string
	return SCREEN_NAME
end

return RobuxShopPanel
