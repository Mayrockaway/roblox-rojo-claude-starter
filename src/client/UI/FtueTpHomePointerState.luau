--!strict
-- Tracks the "Teleport Home" FTUE pointer leg: from `Done` through post-completion until the player
-- uses Teleport Home. Shared by `FtueUiPointers` and `FtueDialogueController` (pointer-only dialogue mode).

local FtueTpHomePointerState = {}

local legActive = false
local dismissed = false

function FtueTpHomePointerState.markLegActive()
	legActive = true
end

function FtueTpHomePointerState.markDismissed()
	dismissed = true
end

function FtueTpHomePointerState.shouldShowPointer(): boolean
	return legActive and not dismissed
end

--- After FTUE ends, keep `FTUEDialogueGui` enabled with only `Canvas.Pointers` visible.
function FtueTpHomePointerState.shouldUsePointerOnlyDialogueMode(): boolean
	return FtueTpHomePointerState.shouldShowPointer()
end

return FtueTpHomePointerState
