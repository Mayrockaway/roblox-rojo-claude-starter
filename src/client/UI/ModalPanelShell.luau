--!strict
-- Shared modal shell wiring: named close `GuiButton`s + backdrop dismiss.
-- Backdrop uses **`Canvas.Dimmer`** only as a visual; close-on-outside is driven by **pointer vs `PanelHost` AABB**
-- so inactive layout frames cannot pass clicks through to the dimmer (Roblox input does not hit-test `Active = false` GUI).

local UserInputService = game:GetService("UserInputService")

local CLOSE_BUTTON_NAMES: { string } = { "CloseButton", "HeaderCloseButton", "ClosePanelButton" }

-- Direct-child names under `Canvas` or `ScreenGui` (Studio-authored). Not recursive — avoids nested false positives.
local DIMMER_NAMES: { string } = { "Dimmer", "ModalDimmer", "Backdrop", "OverlayDimmer", "ModalBackdrop" }

-- Sibling of dimmer that holds the modal chrome (same parent as `Dimmer`, usually under `Canvas`).
local PANEL_HOST_NAMES: { string } = { "PanelHost", "Panel", "MainPanel", "ModalShell" }

local closeWired: { [ScreenGui]: boolean } = {}

local ModalPanelShell = {}

local function findDimmer(screen: ScreenGui): GuiObject?
	local canvas = screen:FindFirstChild("Canvas")
	local hosts: { Instance } = {}
	if canvas then
		table.insert(hosts, canvas)
	end
	table.insert(hosts, screen)
	for _, host in ipairs(hosts) do
		for _, n in ipairs(DIMMER_NAMES) do
			local ch = host:FindFirstChild(n)
			if ch and ch:IsA("GuiObject") then
				return ch
			end
		end
	end
	for _, n in ipairs(DIMMER_NAMES) do
		local d = screen:FindFirstChild(n, true)
		if d and d:IsA("GuiObject") then
			return d
		end
	end
	return nil
end

local function findPanelHost(dimmer: GuiObject): GuiObject?
	local parent = dimmer.Parent
	if not parent then
		return nil
	end
	for _, n in ipairs(PANEL_HOST_NAMES) do
		local ch = parent:FindFirstChild(n)
		if ch and ch:IsA("GuiObject") and ch ~= dimmer then
			return ch
		end
	end
	for _, ch in ipairs(parent:GetChildren()) do
		if ch ~= dimmer and ch:IsA("GuiObject") then
			return ch :: GuiObject
		end
	end
	return nil
end

local function pointInGuiObject(gui: GuiObject, x: number, y: number): boolean
	local ap = gui.AbsolutePosition
	local sz = gui.AbsoluteSize
	return x >= ap.X and x < ap.X + sz.X and y >= ap.Y and y < ap.Y + sz.Y
end

--- Close when pressing **outside** the panel shell’s axis-aligned bounds (dimmer / letterbox), never when inside — even if frames are `Active = false`.
local function wireBackdropCloseOutsidePanelHost(screen: ScreenGui, panelHost: GuiObject, closeSelf: () -> ())
	UserInputService.InputBegan:Connect(function(input: InputObject, _: boolean)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not screen.Enabled then
			return
		end
		local p: Vector2
		if input.UserInputType == Enum.UserInputType.Touch then
			p = Vector2.new(input.Position.X, input.Position.Y)
		else
			local m = UserInputService:GetMouseLocation()
			p = Vector2.new(m.X, m.Y)
		end
		if pointInGuiObject(panelHost, p.X, p.Y) then
			return
		end
		closeSelf()
	end)
end

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

	local dimmer = findDimmer(screen)
	if dimmer then
		local panelHost = findPanelHost(dimmer)
		if panelHost then
			wireBackdropCloseOutsidePanelHost(screen, panelHost, closeSelf)
		else
			-- No shell sibling: fall back to clicking the dimmer itself.
			if dimmer:IsA("GuiButton") then
				dimmer.Activated:Connect(closeSelf)
				dimmer.MouseButton1Click:Connect(closeSelf)
			else
				(dimmer :: GuiObject).Active = true
				(dimmer :: GuiObject).MouseButton1Click:Connect(closeSelf)
			end
		end
	end
end

return ModalPanelShell
