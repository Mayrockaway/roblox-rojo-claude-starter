--!strict
-- Ephemeral dev-only ScreenGui: sets global strait via `RequestDevSetStraitBracket` (server accepts in Studio or when `Constants.StraitDevUiEnabled`).
-- Not part of authored StarterGui; see `ui-architecture.mdc` §9 (debug UI).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local GUI_NAME = "StraitDevPanelGui"

local StraitDevPanel = {}

function StraitDevPanel.shouldShow(): boolean
	if Constants.StraitDevUiDisabled == true then
		return false
	end
	return RunService:IsStudio() or Constants.StraitDevUiEnabled == true
end

function StraitDevPanel.mount(
	playerGui: PlayerGui,
	requestDevSetStraitBracket: RemoteEvent,
	globalStateUpdate: RemoteEvent
)
	if not StraitDevPanel.shouldShow() then
		return
	end

	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100_000
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Panel"
	-- Top-right: clear of `ActiveManifestPanel` (middle-right) and the top-row pills.
	-- Inset Y by ~`GuiInset` (36 px) so it sits below the topbar instead of behind it.
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -12, 0, 44)
	root.Size = UDim2.fromOffset(168, 132)
	root.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	root.BackgroundTransparency = 0.12
	root.BorderSizePixel = 0
	root.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 90, 100)
	stroke.Thickness = 1
	stroke.Parent = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 1
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(220, 220, 230)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Strait (dev)"
	title.Parent = root

	local current = Instance.new("TextLabel")
	current.Name = "CurrentState"
	current.LayoutOrder = 2
	current.BackgroundTransparency = 1
	current.Size = UDim2.new(1, 0, 0, 16)
	current.Font = Enum.Font.Gotham
	current.TextSize = 11
	current.TextColor3 = Color3.fromRGB(160, 200, 160)
	current.TextXAlignment = Enum.TextXAlignment.Left
	current.Text = "Engine: …"
	current.Parent = root

	local lastFire = 0.0
	local debounceSec = 0.35

	local function fire(bracket: string)
		local now = os.clock()
		if now - lastFire < debounceSec then
			return
		end
		lastFire = now
		requestDevSetStraitBracket:FireServer({ bracket = bracket })
	end

	local function makeButton(layoutOrder: number, label: string, bracket: string): TextButton
		local b = Instance.new("TextButton")
		b.Name = label .. "Button"
		b.LayoutOrder = layoutOrder
		b.Size = UDim2.new(1, 0, 0, 26)
		b.Text = label
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 13
		b.AutoButtonColor = true
		b.BackgroundColor3 = Color3.fromRGB(48, 52, 62)
		b.TextColor3 = Color3.fromRGB(235, 235, 240)
		b.BorderSizePixel = 0
		b.MouseButton1Click:Connect(function()
			fire(bracket)
		end)
		b.Parent = root
		return b
	end

	makeButton(3, "Open", "Open")
	makeButton(4, "Restricted", "Restricted")
	makeButton(5, "Closed", "Closed")

	globalStateUpdate.OnClientEvent:Connect(function(snapshot: any)
		if typeof(snapshot) ~= "table" then
			return
		end
		local st = snapshot.state
		if typeof(st) == "string" then
			current.Text = "Engine: " .. st
		end
	end)
end

return StraitDevPanel
