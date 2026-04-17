--!strict
-- Fired when the HUD Teleport Home button runs (`HudTeleportRouter`). Used to dismiss the TP Home FTUE pointer.

local FtueTpHomePointerState = require(script.Parent:WaitForChild("FtueTpHomePointerState"))

local listeners: { () -> () } = {}

local FtueTpHomePointerSignals = {}

function FtueTpHomePointerSignals.subscribeTeleportHomePressed(fn: () -> ())
	table.insert(listeners, fn)
end

function FtueTpHomePointerSignals.fireTeleportHomePressed()
	FtueTpHomePointerState.markDismissed()
	for _, f in ipairs(listeners) do
		task.defer(f)
	end
end

return FtueTpHomePointerSignals
