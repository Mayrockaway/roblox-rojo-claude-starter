--!strict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local MY_PLOT_ATTR = "MyPlotVfxEnabled"
local OTHER_PLAYERS_ATTR = "OtherPlayersPlotVfxEnabled"
local LOW_END_ATTR = "OtherPlayersPlotVfxAutoDisabled"

local started = false
local myPlotVfxEnabled = true
local otherPlayersPlotVfxEnabled = true
local autoDisabledForLowEnd = false
local changedEvent = Instance.new("BindableEvent")

local function isLowEndDevice(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function syncAttributes()
	if not localPlayer then
		return
	end
	localPlayer:SetAttribute(MY_PLOT_ATTR, myPlotVfxEnabled)
	localPlayer:SetAttribute(OTHER_PLAYERS_ATTR, otherPlayersPlotVfxEnabled)
	localPlayer:SetAttribute(LOW_END_ATTR, autoDisabledForLowEnd)
end

local ClientPlotVfxPreferences = {}

function ClientPlotVfxPreferences.init()
	if started then
		return
	end
	started = true
	autoDisabledForLowEnd = isLowEndDevice()
	myPlotVfxEnabled = true
	otherPlayersPlotVfxEnabled = not autoDisabledForLowEnd
	syncAttributes()
end

function ClientPlotVfxPreferences.isMyPlotVfxEnabled(): boolean
	return myPlotVfxEnabled
end

function ClientPlotVfxPreferences.setMyPlotVfxEnabled(enabled: boolean)
	if myPlotVfxEnabled == enabled then
		return
	end
	myPlotVfxEnabled = enabled
	syncAttributes()
	changedEvent:Fire()
end

function ClientPlotVfxPreferences.isOtherPlayersPlotVfxEnabled(): boolean
	return otherPlayersPlotVfxEnabled
end

function ClientPlotVfxPreferences.setOtherPlayersPlotVfxEnabled(enabled: boolean)
	if otherPlayersPlotVfxEnabled == enabled then
		return
	end
	otherPlayersPlotVfxEnabled = enabled
	syncAttributes()
	changedEvent:Fire()
end

function ClientPlotVfxPreferences.wasAutoDisabledForLowEnd(): boolean
	return autoDisabledForLowEnd
end

function ClientPlotVfxPreferences.changedSignal(): RBXScriptSignal
	return changedEvent.Event
end

return ClientPlotVfxPreferences
