--!strict
-- Hold MouseButton1 / touch on a GuiButton to repeat an action (steppers on shop/sell/dispatch modals).
-- Roblox routes touch on ScreenGui buttons through MouseButton1*.

export type HoldOpts = {
	--- Seconds after first tick before repeating starts.
	initialDelaySec: number?,
	--- Seconds between repeats while held.
	repeatIntervalSec: number?,
}

local DEFAULT_INITIAL_DELAY = 0.42
local DEFAULT_REPEAT_INTERVAL = 0.065

local StepperHold = {}

--[[
	Fires `onRepeat` once on press, then after `initialDelaySec` repeats every `repeatIntervalSec`
	until release or pointer leaves the button.
	Prefer this over `Activated` for +/- so a quick tap is exactly one tick (no duplicate from release).
]]
function StepperHold.bind(button: GuiButton, onRepeat: () -> (), connections: { RBXScriptConnection }, opts: HoldOpts?)
	local initialDelay = DEFAULT_INITIAL_DELAY
	local repeatInterval = DEFAULT_REPEAT_INTERVAL
	if opts then
		if opts.initialDelaySec ~= nil then
			initialDelay = opts.initialDelaySec :: number
		end
		if opts.repeatIntervalSec ~= nil then
			repeatInterval = opts.repeatIntervalSec :: number
		end
	end

	local holding = false
	local repeatThread: thread? = nil

	local function stopHold()
		holding = false
		if repeatThread ~= nil then
			task.cancel(repeatThread :: thread)
			repeatThread = nil
		end
	end

	local function repeatLoop()
		task.wait(initialDelay)
		while holding do
			onRepeat()
			task.wait(repeatInterval)
		end
	end

	table.insert(connections, button.MouseButton1Down:Connect(function()
		stopHold()
		holding = true
		onRepeat()
		repeatThread = task.spawn(repeatLoop)
	end))
	table.insert(connections, button.MouseButton1Up:Connect(stopHold))
	table.insert(connections, button.MouseLeave:Connect(stopHold))
end

return StepperHold
