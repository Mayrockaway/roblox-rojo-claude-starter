--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))

local Validation = {}

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
