--!strict
-- Always clear sitting before moving the character with PivotTo / HRP CFrame so `Seat` welds
-- do not drag `DeckSeat` off the ship or leave floating seats.

local SETTLE_AFTER_UNSEAT_SECONDS = 0.1

local CharacterTeleport = {}

function CharacterTeleport.unseatIfSitting(character: Model)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum and hum.SeatPart then
		hum.SeatPart:Sit(nil)
		task.wait(SETTLE_AFTER_UNSEAT_SECONDS)
	end
end

return CharacterTeleport
