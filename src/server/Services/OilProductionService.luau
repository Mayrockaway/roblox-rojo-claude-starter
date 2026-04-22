--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local OilProductionService = {}

local TIERS = {
	"Crude",
	"Refined",
	"Premium",
}

local function emptyTierFloats()
	return {
		Crude = 0,
		Refined = 0,
		Premium = 0,
	}
end

--- `remoteService` is optional — when provided, the production loop fires a
--- `DrillProgressUpdate { kind = "pumpCollected", ownerUserId, pumpId }` packet
--- per pump per tick that actually contributed > 0 oil (broadcast to all
--- clients so spatial pump SFX rolls off correctly for nearby visitors). Kept
--- optional so callers that just want production math without the FX wiring
--- (tests, headless tooling) don't have to thread the remote service through.
function OilProductionService:Init(oilStateService, remoteService)
	self._oilStateService = oilStateService
	self._running = false
	self._progressEvent = nil
	if remoteService and typeof((remoteService :: any).GetEvent) == "function" then
		--- Reuses the same `DrillProgressUpdate` channel as `started` /
		--- `completed` / `revealed` / `pumpPlaced` so the existing
		--- `getClientRemotes().drillProgressUpdate` wiring on the client
		--- carries the new `kind = "pumpCollected"` packets without a new
		--- remote name or bootstrap.
		self._progressEvent = (remoteService :: any):GetEvent(RemoteNames.DrillProgressUpdate)
	end
end

function OilProductionService:Start()
	if self._running then
		return
	end
	self._running = true

	task.spawn(function()
		while self._running do
			task.wait(OilConfig.ProductionTickSeconds)
			local perf = _G.Perf
			if perf then
				local handle = perf:OpenSpan("OilProduction.runTick")
				self:_runTick(OilConfig.ProductionTickSeconds)
				perf:CloseSpan("OilProduction.runTick", handle)
			else
				self:_runTick(OilConfig.ProductionTickSeconds)
			end
		end
	end)
end

function OilProductionService:Stop()
	self._running = false
end

local function addTierFlow(target, tier: string, amount: number)
	if amount <= 0 then
		return
	end
	target[tier] = (target[tier] or 0) + amount
end

--- Returns the total barrels this pump contributed across all tiers this
--- tick. Used by `_runTick` to fire a `pumpCollected` FX packet only for
--- pumps that actually pulled oil (i.e. tank wasn't full for at least one
--- of the streams it draws). A return of 0 means the pump was idle this
--- tick (no drilled tiles, all unlucky, or every stream's tank was full)
--- so no audio/visual cue should fire client-side.
function OilProductionService:_accumulateCenterPumpChunk(userId: number, state, centerPump, deltaSeconds: number, additionsByTier): number
	local chunk = state.chunksById and state.chunksById[centerPump.chunkId]
	if not chunk or typeof(chunk.tiles) ~= "table" then
		return 0
	end
	local pumpDef = VeinConfig.PumpUpgrades[centerPump.tier] or VeinConfig.PumpUpgrades.T1
	local pumpMult = pumpDef and pumpDef.flowMult or 1
	local pumpProduced = 0
	for tileKey, tile in pairs(chunk.tiles) do
		if tileKey ~= "T33" and tile.drilled == true and tile.hasOil ~= false and typeof(tile.visualsStartedAt) == "number" and typeof(tile.veinTypeId) == "string" then
			local def = VeinCrateConfig.GetById(tile.veinTypeId)
			if def and not def.isUnlucky then
				for _, stream in ipairs(def.streams) do
					local tier = stream.internalOilType
					if additionsByTier[tier] ~= nil and not self._oilStateService:TankIsFull(userId, tier) then
						local amt = stream.barrelsPerSecond * pumpMult * deltaSeconds
						addTierFlow(additionsByTier, tier, amt)
						pumpProduced += amt
					end
				end
			end
		end
	end
	return pumpProduced
end

function OilProductionService:_runTick(deltaSeconds: number)
	local perf = _G.Perf
	for userId, state in pairs(self._oilStateService:GetAllStates()) do
		if state.activeDrillCount <= 0 then
			continue
		end

		local connectedAdditions = emptyTierFloats()
		local drillHandle = perf and perf:OpenSpan("Production.drillLoop")
		local drills = self._oilStateService:GetActiveDrills(userId)

		--- Track which pumps actually contributed > 0 this tick so we can fire
		--- per-pump `pumpCollected` FX packets after `ApplyProduction` confirms
		--- the user's aggregate addition stuck. Pre-sized as a loose array of
		--- pumpIds; `nil` when no FX channel is wired (Init was called without
		--- `remoteService`) so we skip the bookkeeping entirely.
		local producingPumpIds: { number }? = if self._progressEvent then {} else nil

		-- Drills-only refactor: `drillsById` now contains center pumps exclusively. Each
		-- center pump pulls oil from drilled tiles in its chunk (no per-drill flowBase or
		-- pipe connectivity remains).
		for _, centerPump in ipairs(drills) do
			if centerPump.isCenterPump == true then
				local pumpAmt = self:_accumulateCenterPumpChunk(userId, state, centerPump, deltaSeconds, connectedAdditions)
				if producingPumpIds and pumpAmt > 0 and typeof(centerPump.drillId) == "number" then
					table.insert(producingPumpIds, centerPump.drillId)
				end
			end
		end

		if drillHandle then
			perf:CloseSpan("Production.drillLoop", drillHandle)
		end

		local applyHandle = perf and perf:OpenSpan("Production.apply")
		local added = self._oilStateService:ApplyProduction(userId, connectedAdditions)
		if applyHandle then
			perf:CloseSpan("Production.apply", applyHandle)
		end

		if added > 0 then
			local pushHandle = perf and perf:OpenSpan("Production.push")
			self._oilStateService:PushState(userId)
			if pushHandle then
				perf:CloseSpan("Production.push", pushHandle)
			end
			--- Fire one `pumpCollected` packet per pump that produced this tick
			--- (after `ApplyProduction` confirmed at least some of the additions
			--- persisted). Broadcast to all clients so visiting friends hear the
			--- spatial audio with normal rolloff. The client treats the per-tick
			--- stream as a heartbeat for a continuous looped Sound — see
			--- `PumpCollectSpatialSfx` on the client.
			if producingPumpIds and self._progressEvent then
				for _, pumpId in ipairs(producingPumpIds) do
					self._progressEvent:FireAllClients({
						kind = "pumpCollected",
						ownerUserId = userId,
						pumpId = pumpId,
					})
				end
			end
			-- Telemetry §6.4 `oil_pumped` (sample 0.05) — one row per
			-- producing tick per user, aggregating barrel flow by tier.
			-- Sampling is enforced inside `Telemetry.Track` via the
			-- catalog row's `sampleRate`; we still gate `pcall` to keep
			-- the production loop bullet-proof.
			pcall(function()
				local plr = Players:GetPlayerByUserId(userId)
				Telemetry.Track(plr, "oil_pumped", {
					crude = connectedAdditions.Crude or 0,
					refined = connectedAdditions.Refined or 0,
					premium = connectedAdditions.Premium or 0,
					added = added,
					producingPumps = if producingPumpIds then #producingPumpIds else 0,
				})
				-- `oil_pump_collected` (sample 0.05) — one row per pump
				-- that contributed > 0 this tick. SPEC §6.4 names the
				-- per-pump fire moment so analytics can size pump-ROI
				-- per pump, not per user.
				if producingPumpIds then
					for _, pumpId in ipairs(producingPumpIds) do
						Telemetry.Track(plr, "oil_pump_collected", {
							pumpId = pumpId,
						})
					end
				end
			end)
		end
	end
end

return OilProductionService
