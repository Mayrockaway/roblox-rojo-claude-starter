--!strict
-- Hold MouseButton1 / touch on a GuiButton to repeat an action (steppers on shop/sell/dispatch modals).
-- Roblox routes touch on ScreenGui buttons through MouseButton1*.
--
-- Acceleration profile (`onRepeat` invocations per real second while held):
--   t < initialDelaySec        : 1 (just the press)
--   initialDelay  → 0.6s held  : ~17/s   (1 per tick @ ~0.06s)
--   0.6s          → 1.2s held  : ~85/s   (5 per tick)
--   1.2s          → 2.0s held  : ~340/s  (20 per tick)
--   2.0s          → ∞          : ~850/s  (50 per tick)
-- Single tap is always exactly one tick. Caller (`bumpTier`, `bumpCrudeBlend`,
-- `bumpInstantSellTier`) is the natural clamp — extra invocations past the
-- ship / warehouse / inventory cap are free no-ops because those callers
-- already short-circuit at the bound. This lets +1 / -1 stepper buttons feel
-- instant for big amounts (was: ~15 per second flat → painful past 30 barrels).

export type HoldOpts = {
	--- Seconds after first tick before repeating starts.
	initialDelaySec: number?,
	--- Seconds between repeats while held.
	repeatIntervalSec: number?,
	--- Disable the burst-multiplier ramp (default acceleration on). Use for
	--- steppers with a large native step (e.g. `Step_+10`, `Step_Max`) where
	--- multiplying the per-tick count would overshoot wildly.
	accelerate: boolean?,
}

local DEFAULT_INITIAL_DELAY = 0.32
local DEFAULT_REPEAT_INTERVAL = 0.06

-- Burst stages: { secondsHeldThreshold, callsPerTick }. Walked top-down on
-- every tick so the ramp keeps climbing as the player holds.
local BURST_STAGES: { { number } } = {
	{ 2.0, 50 },
	{ 1.2, 20 },
	{ 0.6, 5 },
	{ 0.0, 1 },
}

local StepperHold = {}

--[[
	Fires `onRepeat` once on press, then after `initialDelaySec` repeats every `repeatIntervalSec`
	until release or pointer leaves the button.
	Prefer this over `Activated` for +/- so a quick tap is exactly one tick (no duplicate from release).
]]
function StepperHold.bind(button: GuiButton, onRepeat: () -> (), connections: { RBXScriptConnection }, opts: HoldOpts?)
	local initialDelay = DEFAULT_INITIAL_DELAY
	local repeatInterval = DEFAULT_REPEAT_INTERVAL
	local accelerate = true
	if opts then
		if opts.initialDelaySec ~= nil then
			initialDelay = opts.initialDelaySec :: number
		end
		if opts.repeatIntervalSec ~= nil then
			repeatInterval = opts.repeatIntervalSec :: number
		end
		if opts.accelerate ~= nil then
			accelerate = opts.accelerate :: boolean
		end
	end

	local holding = false
	local repeatThread: thread? = nil
	local holdStart = 0.0

	local function stopHold()
		holding = false
		if repeatThread ~= nil then
			task.cancel(repeatThread :: thread)
			repeatThread = nil
		end
	end

	local function callsPerTick(): number
		if not accelerate then
			return 1
		end
		local elapsed = os.clock() - holdStart
		for _, stage in ipairs(BURST_STAGES) do
			if elapsed >= stage[1] then
				return math.floor(stage[2])
			end
		end
		return 1
	end

	local function repeatLoop()
		task.wait(initialDelay)
		while holding do
			local n = callsPerTick()
			for _ = 1, n do
				if not holding then
					break
				end
				onRepeat()
			end
			task.wait(repeatInterval)
		end
	end

	table.insert(connections, button.MouseButton1Down:Connect(function()
		stopHold()
		holding = true
		holdStart = os.clock()
		onRepeat()
		repeatThread = task.spawn(repeatLoop)
	end))
	table.insert(connections, button.MouseButton1Up:Connect(stopHold))
	table.insert(connections, button.MouseLeave:Connect(stopHold))
end

return StepperHold
