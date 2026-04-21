--[[
	Re-apply the active-state visual chrome on
	`StarterGui.HUD.Canvas.EarningsGamepass` (the 2x earnings GamePass HUD icon).

	Authors:
	  * `EarningsGamepass.ActiveStroke` (UIStroke, Enabled=false)  — pulses on
	    when the local player owns DoubleEarnings.
	  * `ActiveStroke.RainbowGradient` (UIGradient)                — controller
	    rotates this for the cycling colour border.

	Idempotent: re-running re-uses existing instances. Run via MCP
	`execute_luau` (or Studio Command Bar) any time the chrome drifts (e.g.
	someone deleted the children in Studio). The runtime controller lives at
	`ReplicatedStorage.StarterPlayer.StarterPlayerScripts.Client.UI.EarningsGamepassController`.

	Save the place after running so the authored children persist.
]]

local sg = game:GetService("StarterGui")
local hud = sg:FindFirstChild("HUD")
assert(hud and hud:IsA("ScreenGui"), "[normalize] StarterGui.HUD missing.")
local canvas = hud:FindFirstChild("Canvas")
assert(canvas and canvas:IsA("Frame"), "[normalize] HUD.Canvas missing.")
local btn = canvas:FindFirstChild("EarningsGamepass")
assert(btn and btn:IsA("ImageButton"), "[normalize] HUD.Canvas.EarningsGamepass missing.")

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 64, 64)),
	ColorSequenceKeypoint.new(0.16, Color3.fromRGB(255, 170, 64)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 240, 64)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(80, 255, 120)),
	ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 200, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(180, 100, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 64, 200)),
})

local stroke = btn:FindFirstChild("ActiveStroke")
if not stroke then
	stroke = Instance.new("UIStroke")
	stroke.Name = "ActiveStroke"
	stroke.Parent = btn
end
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.LineJoinMode = Enum.LineJoinMode.Round
stroke.Thickness = 3
stroke.Transparency = 0
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Enabled = false

local grad = stroke:FindFirstChild("RainbowGradient")
if not grad then
	grad = Instance.new("UIGradient")
	grad.Name = "RainbowGradient"
	grad.Parent = stroke
end
grad.Color = RAINBOW
grad.Rotation = 0
grad.Enabled = true

print("[normalize] EarningsGamepass.ActiveStroke + RainbowGradient applied.")
