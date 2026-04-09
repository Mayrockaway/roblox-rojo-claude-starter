--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local RateLimitService = {}

function RateLimitService:Init()
	self._requests = {}
end

function RateLimitService:Start()
	-- no-op
end

function RateLimitService:Stop()
	self._requests = {}
end

function RateLimitService:Allow(userId: number, action: string, maxRequests: number?): boolean
	local now = workspace:GetServerTimeNow()
	local key = tostring(userId) .. ":" .. action
	local bucket = self._requests[key]
	if bucket == nil then
		bucket = {
			windowStart = now,
			count = 0,
		}
		self._requests[key] = bucket
	end

	local windowSize = Constants.RateLimitWindowSeconds
	if now - bucket.windowStart >= windowSize then
		bucket.windowStart = now
		bucket.count = 0
	end

	local maxAllowed = maxRequests or Constants.RateLimitDefaultMaxRequests
	if bucket.count >= maxAllowed then
		return false
	end
	bucket.count += 1
	return true
end

return RateLimitService
