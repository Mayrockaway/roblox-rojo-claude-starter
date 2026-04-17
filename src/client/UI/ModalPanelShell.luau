--!strict
-- Shared modal shell wiring: named close `GuiButton`s only.
-- Backdrop / dimmer click-to-dismiss was removed — it conflicted with panel controls (e.g. footer CTAs). Close via **X** (or other named buttons).

local DEBUG_MODAL_CLOSE_WIRE = false

local CLOSE_BUTTON_NAMES: { string } = {
	"CloseButton",
	"HeaderCloseButton",
	"ClosePanelButton",
	"Close",
	"CloseImageButton",
	"XButton",
	-- Common Studio / design variants
	"X",
	"Exit",
	"Dismiss",
	"CloseBtn",
	"BtnClose",
	"HeaderClose",
}

local closeWired: { [ScreenGui]: boolean } = {}
local closeButtonConnections: { [GuiButton]: RBXScriptConnection } = {}

local ModalPanelShell = {}

local function nameIsCloseButton(name: string): boolean
	local ln = string.lower(name)
	for _, n in ipairs(CLOSE_BUTTON_NAMES) do
		if ln == string.lower(n) then
			return true
		end
	end
	return false
end

function ModalPanelShell.bindCloseControls(screen: ScreenGui)
	if closeWired[screen] then
		return
	end
	closeWired[screen] = true

	local function closeSelf()
		screen.Enabled = false
	end

	local function tryWireCloseButton(inst: Instance)
		if not inst:IsA("GuiButton") then
			return
		end
		local btn = inst :: GuiButton
		if not nameIsCloseButton(btn.Name) then
			return
		end
		if closeButtonConnections[btn] then
			return
		end
		-- Studio-authored **`ImageButton`** often has **`Active = false`**; it will not receive clicks until enabled.
		btn.Active = true
		if DEBUG_MODAL_CLOSE_WIRE then
			print("[ModalPanelShell] Wiring close GuiButton:", btn:GetFullName(), "screen=", screen.Name)
		end
		closeButtonConnections[btn] = btn.Activated:Connect(function()
			if DEBUG_MODAL_CLOSE_WIRE then
				print("[ModalPanelShell] Close Activated fired:", btn:GetFullName())
			end
			closeSelf()
		end)
	end

	for _, inst in ipairs(screen:GetDescendants()) do
		tryWireCloseButton(inst)
	end

	screen.DescendantAdded:Connect(function(inst)
		tryWireCloseButton(inst)
	end)
end

return ModalPanelShell
