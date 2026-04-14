-- Dev-only diagnostic shim: server side prints AND broadcasts to all clients so the
-- in-Studio Output for Client 1 shows server traces too. Avoids hunting separate
-- Studio processes for Server logs in multi-player Test mode.

local RunService = game:GetService("RunService")

local DevLog = {}
local _broadcast: ((string) -> ())? = nil

function DevLog.SetBroadcaster(fn: (string) -> ())
	_broadcast = fn
end

function DevLog.log(msg: string)
	print(msg)
	if RunService:IsServer() and _broadcast then
		_broadcast(msg)
	end
end

return DevLog
