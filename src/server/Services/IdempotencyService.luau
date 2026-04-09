--!strict

local IdempotencyService = {}

function IdempotencyService:Init()
	self._keys = {}
end

function IdempotencyService:Start()
	-- no-op
end

function IdempotencyService:Stop()
	self._keys = {}
end

function IdempotencyService:TryMark(key: string): boolean
	if self._keys[key] then
		return false
	end
	self._keys[key] = true
	return true
end

return IdempotencyService
