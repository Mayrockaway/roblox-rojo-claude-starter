--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))

local OilProductionService = {}

local TIERS = {
	"HeavyCrude",
	"LightSweet",
	"PremiumRefined",
}

local function emptyTierFloats()
	return {
		HeavyCrude = 0,
		LightSweet = 0,
		PremiumRefined = 0,
	}
end

function OilProductionService:Init(oilStateService, pipeNetworkService)
	self._oilStateService = oilStateService
	self._pipeNetworkService = pipeNetworkService
	self._running = false
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

function OilProductionService:_accumulateCenterPumpChunk(userId: number, state, centerPump, deltaSeconds: number, additionsByTier)
	local chunk = state.chunksById and state.chunksById[centerPump.chunkId]
	if not chunk or typeof(chunk.tiles) ~= "table" then
		return
	end
	local pumpDef = VeinConfig.PumpUpgrades[centerPump.tier] or VeinConfig.PumpUpgrades.T1
	local pumpMult = pumpDef and pumpDef.flowMult or 1
	for tileKey, tile in pairs(chunk.tiles) do
		if tileKey ~= "T33" and tile.drilled == true and tile.hasOil ~= false and typeof(tile.visualsStartedAt) == "number" and typeof(tile.veinTypeId) == "string" then
			local def = VeinCrateConfig.GetById(tile.veinTypeId)
			if def and not def.isUnlucky then
				for _, stream in ipairs(def.streams) do
					local tier = stream.internalOilType
					if additionsByTier[tier] ~= nil and not self._oilStateService:TankIsFull(userId, tier) then
						addTierFlow(additionsByTier, tier, stream.barrelsPerSecond * pumpMult * deltaSeconds)
					end
				end
			end
		end
	end
end

function OilProductionService:_runTick(deltaSeconds: number)
	local perf = _G.Perf
	for userId, state in pairs(self._oilStateService:GetAllStates()) do
		if state.activeDrillCount <= 0 then
			continue
		end

		if self._pipeNetworkService then
			local connectHandle = perf and perf:OpenSpan("Production.connectivity")
			self._pipeNetworkService:MarkConnectivityForTick(state)
			if connectHandle then
				perf:CloseSpan("Production.connectivity", connectHandle)
			end
		end

		local connectedAdditions = emptyTierFloats()
		local pushNeeded = false
		local drillHandle = perf and perf:OpenSpan("Production.drillLoop")
		local drills = self._oilStateService:GetActiveDrills(userId)
		local centerPumpsByChunk = {}

		for _, drill in ipairs(drills) do
			if drill.isCenterPump == true then
				centerPumpsByChunk[drill.chunkId] = drill
				continue
			end

			local flow = drill.flowBase * deltaSeconds
			local perDrillAdditions = emptyTierFloats()
			local tileOilType = drill.tileOilType
			if tileOilType and perDrillAdditions[tileOilType] ~= nil then
				perDrillAdditions[tileOilType] = flow
			else
				for _, tier in ipairs(TIERS) do
					local weightPercent = drill.tierMix[tier] or 0
					perDrillAdditions[tier] = flow * (weightPercent / 100)
				end
			end

			for _, tier in ipairs(TIERS) do
				if self._oilStateService:TankIsFull(userId, tier) then
					perDrillAdditions[tier] = 0
				end
			end

			if drill.connected then
				local drained = self._oilStateService:DrainDrillBuffer(userId, drill.drillId)
				if drained > 0 then
					pushNeeded = true
				end
				for _, tier in ipairs(TIERS) do
					connectedAdditions[tier] += perDrillAdditions[tier]
				end
			else
				self._oilStateService:AddToDrillBuffer(userId, drill.drillId, perDrillAdditions)
				pushNeeded = true
			end
		end

		for _, centerPump in pairs(centerPumpsByChunk) do
			self:_accumulateCenterPumpChunk(userId, state, centerPump, deltaSeconds, connectedAdditions)
		end

		if drillHandle then
			perf:CloseSpan("Production.drillLoop", drillHandle)
		end

		local applyHandle = perf and perf:OpenSpan("Production.apply")
		local added = self._oilStateService:ApplyProduction(userId, connectedAdditions)
		if applyHandle then
			perf:CloseSpan("Production.apply", applyHandle)
		end
		if added > 0 or pushNeeded then
			local pushHandle = perf and perf:OpenSpan("Production.push")
			self._oilStateService:PushState(userId)
			if pushHandle then
				perf:CloseSpan("Production.push", pushHandle)
			end
		end
	end
end

return OilProductionService
