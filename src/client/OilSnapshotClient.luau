--!strict

local RunService = game:GetService("RunService")
-- Server → client oil **snapshot** apply + retry helpers. Lives in its own module so `init.client`
-- stays under Luau's local register limit and snapshot logic is easier to test/extend.

export type SnapshotApplyDeps = {
	setState: (any) -> (),
	getState: () -> any,
	getConfigTable: () -> { [string]: any },
	invalidatePlotGridCache: () -> (),
	rebuildStateMaps: () -> (),
	updateUi: () -> (),
	hasChunkState: () -> boolean,
}

local OilSnapshotClient = {}

--- Uses **`ClientRemotes.requestOilSnapshot`** (same instance as `RemoteNames.RequestOilSnapshot` on the server).
function OilSnapshotClient.invokeOilSnapshot(requestOilSnapshot: RemoteFunction): (boolean, any)
	return pcall(function()
		return requestOilSnapshot:InvokeServer()
	end)
end

function OilSnapshotClient.applySnapshot(deps: SnapshotApplyDeps, snapshot: any): boolean
	if typeof(snapshot) ~= "table" then
		return false
	end
	if typeof(snapshot.state) == "table" then
		deps.setState(snapshot.state)
	end
	if typeof(snapshot.config) == "table" then
		local cfg = deps.getConfigTable()
		for k, v in pairs(snapshot.config) do
			cfg[k] = v
		end
	end
	deps.invalidatePlotGridCache()
	deps.rebuildStateMaps()
	deps.updateUi()
	return typeof(deps.getState()) == "table" and deps.hasChunkState()
end

function OilSnapshotClient.requestSnapshotWithRetry(
	deps: SnapshotApplyDeps,
	requestOilSnapshot: RemoteFunction,
	attempts: number,
	delaySeconds: number
)
	for attempt = 1, attempts do
		local ok, snapshot = OilSnapshotClient.invokeOilSnapshot(requestOilSnapshot)
		if ok and OilSnapshotClient.applySnapshot(deps, snapshot) then
			if attempt > 1 and RunService:IsStudio() then
				print(string.format("[Client] snapshot recovered on retry %d", attempt))
			end
			return
		end
		task.wait(delaySeconds)
	end
	warn("[Client] snapshot retries exhausted (state missing or empty chunks).")
end

function OilSnapshotClient.onOilStatePush(deps: SnapshotApplyDeps, newState: any)
	deps.setState(newState)
	deps.rebuildStateMaps()
	deps.updateUi()
end

return OilSnapshotClient
