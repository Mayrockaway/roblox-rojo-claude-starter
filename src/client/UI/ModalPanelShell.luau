--!strict
-- Shared modal shell wiring: named close `GuiButton`s only.
-- Backdrop / dimmer click-to-dismiss was removed — it conflicted with panel controls (e.g. footer CTAs). Close via **X** (or other named buttons).

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
		local ln = string.lower(inst.Name)
		for _, n in ipairs(CLOSE_BUTTON_NAMES) do
			if ln == string.lower(n) then
				inst.Activated:Connect(closeSelf)
				break
			end
		end
	end
end

return ModalPanelShell
