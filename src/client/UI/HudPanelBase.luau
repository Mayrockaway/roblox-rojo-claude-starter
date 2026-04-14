--!strict

local HudPanelTypes = require(script.Parent.HudPanelTypes)
local ModalPanelShell = require(script.Parent.ModalPanelShell)

export type HudPanelController = HudPanelTypes.HudPanelController

local HudPanelBase = {}

function HudPanelBase.bindScreenGui(screen: ScreenGui, screenName: string): HudPanelController
	ModalPanelShell.bindCloseControls(screen)
	return {
		ScreenName = screenName,
		ScreenGui = screen,
		Open = function()
			screen.Enabled = true
			-- Some shells keep `Canvas.Visible = false` while `ScreenGui.Enabled` toggles; force show.
			local canvas = screen:FindFirstChild("Canvas")
			if canvas and canvas:IsA("GuiObject") then
				(canvas :: GuiObject).Visible = true
			end
		end,
		Close = function()
			screen.Enabled = false
		end,
		IsOpen = function()
			return screen.Enabled
		end,
	}
end

function HudPanelBase.tryBind(playerGui: PlayerGui, screenName: string): HudPanelController?
	-- Prefer the real PlayerGui modal (direct child). Recursive search can grab a stray nested
	-- duplicate name first and leave wiring on a hidden instance while the player sees another.
	local sg = playerGui:FindFirstChild(screenName)
	if not (sg and sg:IsA("ScreenGui")) then
		sg = playerGui:FindFirstChild(screenName, true)
	end
	if not (sg and sg:IsA("ScreenGui")) then
		return nil
	end
	return HudPanelBase.bindScreenGui(sg, screenName)
end

return HudPanelBase
