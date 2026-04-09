--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipmentConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipmentConfig"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))

local Validation = {}

function Validation.ValidateShipmentPayload(payload): (boolean, string, any)
	if typeof(payload) ~= "table" then
		return false, ErrorCodes.InvalidPayload, nil
	end

	local sizeId = payload.sizeId
	if typeof(sizeId) ~= "string" or ShipmentConfig.Sizes[sizeId] == nil then
		return false, ErrorCodes.InvalidShipmentSize, nil
	end

	local composition = nil
	if payload.composition ~= nil then
		if typeof(payload.composition) ~= "table" then
			return false, ErrorCodes.InvalidPayload, nil
		end

		composition = {}
		for _, tier in ipairs(QualityConfig.TierOrder) do
			local raw = payload.composition[tier]
			if raw ~= nil then
				local n = tonumber(raw)
				if n == nil then
					return false, ErrorCodes.InvalidPayload, nil
				end
				local value = math.max(0, math.floor(n))
				composition[tier] = value
			end
		end
	end

	return true, ErrorCodes.Ok, {
		sizeId = sizeId,
		composition = composition,
	}
end

function Validation.ValidateUpgradePayload(payload): (boolean, string, string?)
	if typeof(payload) ~= "table" then
		return false, ErrorCodes.InvalidPayload, nil
	end

	local upgradeId = payload.upgradeId
	if typeof(upgradeId) ~= "string" then
		return false, ErrorCodes.InvalidPayload, nil
	end

	return true, ErrorCodes.Ok, upgradeId
end

return Validation
