--[[
	Run entire file body via Roblox Studio MCP tool: execute_luau (paste as code string),
	or Studio Command Bar with game = edited datamodel.

	Prints StarterGui.HUD tree + key GuiObject / layout properties for diffing against
	docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md
]]

local root = game:GetService("StarterGui"):FindFirstChild("HUD")
if not root then
	warn("[dump] StarterGui.HUD not found")
	return
end

local function dump(inst: Instance, depth: number)
	local pad = string.rep("  ", depth)
	if inst:IsA("ScreenGui") then
		print(
			pad
				.. inst.Name
				.. " ScreenGui ResetOnSpawn="
				.. tostring(inst.ResetOnSpawn)
				.. " ZI="
				.. tostring(inst.ZIndexBehavior)
				.. " IgnoreInset="
				.. tostring(inst.IgnoreGuiInset)
				.. " DO="
				.. tostring(inst.DisplayOrder)
		)
	elseif inst:IsA("GuiObject") then
		print(pad .. inst.Name .. " [" .. inst.ClassName .. "]")
		print(
			pad
				.. "  Size={"
				.. inst.Size.X.Scale
				.. ","
				.. inst.Size.X.Offset
				.. "},{"
				.. inst.Size.Y.Scale
				.. ","
				.. inst.Size.Y.Offset
				.. "}"
		)
		print(
			pad
				.. "  Pos={"
				.. inst.Position.X.Scale
				.. ","
				.. inst.Position.X.Offset
				.. "},{"
				.. inst.Position.Y.Scale
				.. ","
				.. inst.Position.Y.Offset
				.. "}"
		)
		print(
			pad
				.. "  AP="
				.. tostring(inst.AnchorPoint)
				.. " Vis="
				.. tostring(inst.Visible)
				.. " BgT="
				.. tostring(inst.BackgroundTransparency)
		)
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			print(pad .. "  Text=" .. string.format("%q", inst.Text) .. " TextScaled=" .. tostring(inst.TextScaled))
		end
	elseif inst:IsA("UIListLayout") then
		print(
			pad
				.. inst.Name
				.. " UIListLayout FD="
				.. tostring(inst.FillDirection)
				.. " Pad="
				.. tostring(inst.Padding)
				.. " HA="
				.. tostring(inst.HorizontalAlignment)
				.. " VA="
				.. tostring(inst.VerticalAlignment)
		)
	elseif inst:IsA("UIPadding") then
		print(
			pad
				.. inst.Name
				.. " UIPadding T="
				.. tostring(inst.PaddingTop)
				.. " B="
				.. tostring(inst.PaddingBottom)
				.. " L="
				.. tostring(inst.PaddingLeft)
				.. " R="
				.. tostring(inst.PaddingRight)
		)
	elseif inst:IsA("UIAspectRatioConstraint") then
		print(
			pad
				.. inst.Name
				.. " UIAspectRatio AR="
				.. tostring(inst.AspectRatio)
				.. " Type="
				.. tostring(inst.AspectType)
				.. " Dom="
				.. tostring(inst.DominantAxis)
		)
	elseif inst:IsA("UICorner") then
		print(pad .. inst.Name .. " UICorner " .. tostring(inst.CornerRadius))
	elseif inst:IsA("UITextSizeConstraint") then
		print(
			pad
				.. inst.Name
				.. " UITextSize Min="
				.. tostring(inst.MinTextSize)
				.. " Max="
				.. tostring(inst.MaxTextSize)
		)
	elseif inst:IsA("UIStroke") then
		print(pad .. inst.Name .. " UIStroke Thick=" .. tostring(inst.Thickness))
	else
		print(pad .. inst.Name .. " [" .. inst.ClassName .. "]")
	end
	for _, ch in ipairs(inst:GetChildren()) do
		dump(ch, depth + 1)
	end
end

dump(root, 0)
