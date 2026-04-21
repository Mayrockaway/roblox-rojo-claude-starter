--!strict
-- Shared coordinator for the `Hint` line under `ShipmentProgressPanel`.
--
-- Two unrelated client systems write into the same label and used to clobber
-- each other:
--   * `ClientPlotGrid.setStatus` / `setStatusLocked` (drilling chatter,
--     contractor / strategic-strike alerts, FTUE prompts, etc.)
--   * `ShipmentProgressHud` direct writes (cruise dots, "Ship halted!",
--     "Shipment lost…", "Shipment successful!" etc.)
--
-- This module exposes the small amount of state both sides need to cooperate:
--
--   * `setLockUntil(seconds)`      — `setStatusLocked` extends a priority lock.
--   * `isLocked()` / `getLockExpiryClock()` — both writer paths consult this
--                                    before stomping a locked message
--                                    (`setStatus` skips, `ShipmentProgressHud`
--                                    cruise-dot tick skips, halt/success
--                                    writers also skip).
--   * `markNonCruiseWritten()`     — every "real" write (setStatus, halt text,
--                                    success/loss text) calls this so we know
--                                    when the line last had something specific
--                                    on it. Cruise-dot rewrites do **not**
--                                    update the timestamp.
--   * `getLastNonCruiseClock()`    — `ShipmentProgressHud`'s halt-resume
--                                    thread reads this to back off cruise-text
--                                    resumption until the last specific
--                                    message has had its full read time
--                                    (matches the 5s fade hold in
--                                    `ClientPlotGrid`).
--
-- All times are `os.clock()` based (per-client wall clock, no replication).

local HintLineState = {}

local lockUntilClock: number = 0
local lastNonCruiseTextAtClock: number = 0

--- Extend the priority lock so lower-priority writers (`setStatus`, cruise
--- dots, halt text) skip until at least `os.clock() + holdSeconds`. Multiple
--- locks stack by max-extending the expiry; never shortens an existing lock.
function HintLineState.setLockUntil(holdSeconds: number)
	if typeof(holdSeconds) ~= "number" or holdSeconds <= 0 then
		return
	end
	local expiry = os.clock() + holdSeconds
	if expiry > lockUntilClock then
		lockUntilClock = expiry
	end
end

function HintLineState.isLocked(): boolean
	return os.clock() < lockUntilClock
end

function HintLineState.getLockExpiryClock(): number
	return lockUntilClock
end

--- Call from any "real" write to the Hint line — anything that should be given
--- its full 5s of read time before cruise dots or other low-priority text
--- comes back. Cruise-dot rewrites must NOT call this.
function HintLineState.markNonCruiseWritten()
	lastNonCruiseTextAtClock = os.clock()
end

function HintLineState.getLastNonCruiseClock(): number
	return lastNonCruiseTextAtClock
end

return HintLineState
