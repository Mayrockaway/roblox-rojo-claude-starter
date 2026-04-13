--!strict
-- Shared modal shell wiring: named close `GuiButton`s only (dimmer does not close — product choice).
-- Layout stays Studio-authored; only `Enabled` / click behavior here.

local CLOSE_BUTTON_NAMES: { string } = { "CloseButton", "HeaderCloseButton", "ClosePanelButton" }

local closeWired: { [ScreenGui]: boolean } = {}

local ModalPanelShell = {}

function ModalPanelShell.bindCloseControls(screen: ScreenGui)
	if closeWired[screen] then
		return
	end
	closeWired[screen] = true

	local function closeSelf()
		screen.Enabled = false
	end

	for _, inst in ipairs(screen:GetDescendants()) do
		if not inst:IsA("GuiButton") then
			continue
		end
		for _, n in ipairs(CLOSE_BUTTON_NAMES) do
			if inst.Name == n then
				inst.Activated:Connect(closeSelf)
				break
			end
		end
	end
end

return ModalPanelShell
