--!strict
--- Performance mode: "standard" (full visuals) or "lite" (reduced rendering).
--- Tied to the "Other Players Plot VFX" preference — Lite = VFX off.
--- Single source of truth: ClientPlotVfxPreferences.isOtherPlayersPlotVfxEnabled().

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local ClientPlotVfxPreferences = require(script.Parent:WaitForChild("ClientPlotVfxPreferences"))

local LocalPlayer = Players.LocalPlayer
local CHOSEN_ATTR = "PerformanceModeChosen"
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local PerformanceMode = {}

function PerformanceMode.isLite(): boolean
	return not ClientPlotVfxPreferences.isOtherPlayersPlotVfxEnabled()
end

function PerformanceMode.hasChosen(): boolean
	return LocalPlayer:GetAttribute(CHOSEN_ATTR) == true
end

--- Called from the loading screen prompt. Sets the underlying preference.
function PerformanceMode.setFromPrompt(mode: string)
	LocalPlayer:SetAttribute(CHOSEN_ATTR, true)
	ClientPlotVfxPreferences.init()
	ClientPlotVfxPreferences.setOtherPlayersPlotVfxEnabled(mode == "standard")
end

function PerformanceMode.onChanged(callback: () -> ()): RBXScriptConnection
	return ClientPlotVfxPreferences.changedSignal():Connect(callback)
end

function PerformanceMode.isMobile(): boolean
	return IS_MOBILE
end

return PerformanceMode
