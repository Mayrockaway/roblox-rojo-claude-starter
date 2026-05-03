--!strict
--- Quick black fade overlay for world teleports (heaven ↔ home).
--- Usage:
---   TeleportFade.fadeToBlack()   -- yields ~0.3s while screen goes black
---   TeleportFade.fadeFromBlack() -- yields ~0.3s while screen clears

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local FADE_DURATION = 0.3
local DISPLAY_ORDER = 999999
local TWEEN_STYLE = Enum.EasingStyle.Quad

local LocalPlayer = Players.LocalPlayer
local overlay: Frame? = nil
local screenGui: ScreenGui? = nil

local function ensureOverlay(): (ScreenGui, Frame)
	if screenGui and screenGui.Parent and overlay and overlay.Parent then
		return screenGui, overlay
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		error("[TeleportFade] No PlayerGui")
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "TeleportFadeGui"
	gui.DisplayOrder = DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Overlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 100
	frame.Parent = gui

	screenGui = gui
	overlay = frame
	return gui, frame
end

local TeleportFade = {}

function TeleportFade.fadeToBlack()
	local _, frame = ensureOverlay()
	frame.BackgroundTransparency = 1
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(FADE_DURATION, TWEEN_STYLE, Enum.EasingDirection.In),
		{ BackgroundTransparency = 0 }
	)
	tween:Play()
	tween.Completed:Wait()
end

function TeleportFade.fadeFromBlack()
	local _, frame = ensureOverlay()
	frame.BackgroundTransparency = 0
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(FADE_DURATION, TWEEN_STYLE, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Wait()
	-- Clean up after fade out
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
		overlay = nil
	end
end

return TeleportFade
