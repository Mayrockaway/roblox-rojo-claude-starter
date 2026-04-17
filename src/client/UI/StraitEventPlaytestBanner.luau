--!strict
-- Temporary full-screen title for strait waypoint playtests; replace with real UI later.

local TweenService = game:GetService("TweenService")

local StraitEventPlaytestBanner = {}

local GUI_NAME = "StraitEventPlaytestBanner"

function StraitEventPlaytestBanner.show(playerGui: PlayerGui, title: string)
	if title == "" then
		return
	end

	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 200_000
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.AnchorPoint = Vector2.new(0.5, 0.35)
	label.Position = UDim2.new(0.5, 0, 0.28, 0)
	label.Size = UDim2.new(0.92, 0, 0, 96)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.Merriweather
	label.TextSize = 52
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Parent = label

	task.delay(3.8, function()
		if not gui.Parent then
			return
		end
		local t = TweenService:Create(label, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		})
		local t2 = TweenService:Create(stroke, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Transparency = 1,
		})
		t:Play()
		t2:Play()
		t.Completed:Wait()
		gui:Destroy()
	end)
end

return StraitEventPlaytestBanner
