--!strict

local TelemetryService = {}

function TelemetryService:Init()
	self._events = {}
end

function TelemetryService:Start()
	-- no-op
end

function TelemetryService:Stop()
	self._events = {}
end

function TelemetryService:Track(eventName: string, payload)
	local record = {
		at = workspace:GetServerTimeNow(),
		event = eventName,
		payload = payload,
	}
	table.insert(self._events, record)
	if #self._events > 200 then
		table.remove(self._events, 1)
	end
	print("[Telemetry]", eventName, payload)
end

return TelemetryService
