--[[
	Re-apply canonical anchors/sizes for StarterGui.HUD (see CANONICAL_STUDIO_LAYOUT.md).
	Run via MCP execute_luau (paste serialized) or Studio Command Bar.

	Does not recreate instances — only fixes drift on LeftStack / TeleportStack / teleport buttons.
]]

local canvas = game:GetService("StarterGui"):WaitForChild("HUD"):WaitForChild("Canvas")

local left = canvas:WaitForChild("LeftStack")
left.AnchorPoint = Vector2.new(0.5, 0.5)
left.Position = UDim2.new(0.25, 0, 0.5, 0)
left.Size = UDim2.new(0.22, 0, 0.46, 0)

local tp = canvas:WaitForChild("TeleportStack")
tp.AnchorPoint = Vector2.new(1, 1)
tp.Position = UDim2.new(1, 0, 1, 0)
-- Taller than 0.17 so four teleport rows (each Y-scale 0.3 of this frame) + UIListLayout padding fit inside the frame.
tp.Size = UDim2.new(0.13, 0, 0.32, 0)

local tpList = tp:FindFirstChildOfClass("UIListLayout")
if tpList then
	tpList.Padding = UDim.new(0.012, 3)
end

for _, ch in ipairs(tp:GetChildren()) do
	if ch:IsA("GuiButton") then
		ch.Size = UDim2.new(1, 0, 0.3, 0)
		local c = ch:FindFirstChildOfClass("UITextSizeConstraint")
		if c then
			c.MaxTextSize = 13
			c.MinTextSize = 8
		end
	end
end

print("[normalize] StarterGui.HUD Canvas LeftStack + TeleportStack applied.")
