--[[
	Re-apply canonical anchors/sizes for StarterGui.HUD (see CANONICAL_STUDIO_LAYOUT.md).
	Run via MCP execute_luau (paste serialized) or Studio Command Bar.

	Does not recreate instances — only fixes drift on LeftStack.
	(Legacy `TeleportStack` was removed; teleport buttons now live in `Canvas.Buttons`.)
]]

local canvas = game:GetService("StarterGui"):WaitForChild("HUD"):WaitForChild("Canvas")

local left = canvas:WaitForChild("LeftStack")
left.AnchorPoint = Vector2.new(0.5, 0.5)
left.Position = UDim2.new(0.25, 0, 0.5, 0)
left.Size = UDim2.new(0.22, 0, 0.46, 0)

print("[normalize] StarterGui.HUD Canvas LeftStack applied.")
