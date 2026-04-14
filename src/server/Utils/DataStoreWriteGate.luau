--!strict
-- Waits for Roblox DataStore **write** request budget before `SetAsync` / `UpdateAsync` to reduce queue spam.

local DataStoreService = game:GetService("DataStoreService")

local DataStoreWriteGate = {}

local function writeBudget(): number
	local best = 0
	local candidates: { any } = {
		(Enum.DataStoreRequestType :: any).SetIncrementAsync,
		(Enum.DataStoreRequestType :: any).UpdateAsync,
	}
	for _, rt in ipairs(candidates) do
		if rt ~= nil then
			local ok, b = pcall(function()
				return DataStoreService:GetRequestBudgetForRequestType(rt)
			end)
			if ok and typeof(b) == "number" and b > best then
				best = b
			end
		end
	end
	return best
end

--- Blocks up to **`maxSeconds`** until at least one write budget point is available (best-effort).
function DataStoreWriteGate.waitForWriteBudget(maxSeconds: number?): boolean
	local cap = math.clamp(maxSeconds or 2.5, 0.05, 12)
	local deadline = os.clock() + cap
	while os.clock() < deadline do
		if writeBudget() >= 1 then
			return true
		end
		task.wait(0.06)
	end
	return writeBudget() >= 1
end

return DataStoreWriteGate
