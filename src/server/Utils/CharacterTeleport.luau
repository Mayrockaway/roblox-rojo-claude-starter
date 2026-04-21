--!strict
-- Always clear sitting before moving the character with PivotTo / HRP CFrame so `Seat` welds
-- do not drag `DeckSeat` off the ship or leave floating seats.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevLog = require(Shared:WaitForChild("DevLog"))

local SETTLE_AFTER_UNSEAT_SECONDS = 0.1

local CharacterTeleport = {}

--- `Seat:Sit(nil)` marks the seat unoccupied but Roblox's internal "SeatWeld"
--- (a `Weld` instance parented to the seat part, linking seat↔HRP) is NOT
--- always destroyed synchronously on the same frame. If we then `PivotTo` the
--- character while that weld is still alive, the HRP drags the seat — and,
--- through the seat's `WeldConstraint`s, the entire ship assembly — along with
--- the teleport, which is what players report as "seat comes with me and ship
--- bugs out". Explicitly destroying the weld closes the race.
local function forceClearSeat(hum: Humanoid)
	local seat = hum.SeatPart
	if not seat then
		return
	end
	-- 1. Official unseat: clears `Occupant`, asks engine to destroy the weld.
	seat:Sit(nil)
	-- 2. Belt-and-suspenders: drop humanoid state out of Sitting so it won't
	--    re-seat on the next physics step.
	hum.Sit = false
	-- 3. Explicitly destroy any leftover `SeatWeld` on the seat part so a
	--    follow-up `PivotTo` doesn't drag the boat. Safe no-op if already gone.
	local weld = seat:FindFirstChild("SeatWeld")
	if weld and weld:IsA("Weld") then
		weld:Destroy()
	end
end

function CharacterTeleport.unseatIfSitting(character: Model)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum and hum.SeatPart then
		forceClearSeat(hum)
		task.wait(SETTLE_AFTER_UNSEAT_SECONDS)
	end
end

--- One-shot unseat-then-pivot. All teleport handlers should prefer this over
--- calling `unseatIfSitting` + `PivotTo` separately — a forgotten unseat is
--- how the "seat drags across teleport" bug reappears.
---
--- Velocity reset: server-side `PivotTo` alone leaves any pre-existing
--- linear/angular velocity in place, so a player falling fast (e.g. straight
--- off a moving boat) keeps that downward velocity right after the teleport
--- and starts falling again immediately. Zero both velocities here.
---
--- DO NOT add `SetNetworkOwner(nil)` here — it routes ALL of the player's
--- subsequent physics input through the server while ownership is held, which
--- presents as visible movement lag, ragdoll/Freefall pose on land, and the
--- character clipping into the floor while gravity runs server-side. If the
--- "1-frame teleport then revert" bug returns, fix it via a short Anchored
--- pulse or a follow-up safety re-teleport — not by stealing net ownership.
function CharacterTeleport.teleportWithUnseat(character: Model, cf: CFrame, logLabel: string?)
	local hum = character:FindFirstChildOfClass("Humanoid")
	local wasSitting = hum ~= nil and hum.SeatPart ~= nil
	if wasSitting then
		forceClearSeat(hum :: Humanoid)
		task.wait(SETTLE_AFTER_UNSEAT_SECONDS)
	end

	character:PivotTo(cf)

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	if logLabel and logLabel ~= "" then
		DevLog.log(string.format("[teleport] path=%s seated=%s", logLabel, tostring(wasSitting)))
	end
end

return CharacterTeleport
