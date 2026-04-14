--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))

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
			self:_runTick(OilConfig.ProductionTickSeconds)
		end
	end)
end

function OilProductionService:Stop()
	self._running = false
end

function OilProductionService:_runTick(deltaSeconds: number)
	for userId, state in pairs(self._oilStateService:GetAllStates()) do
		if state.activeDrillCount <= 0 then
			continue
		end

		-- Recompute connectivity for this player's network
		if self._pipeNetworkService then
			self._pipeNetworkService:MarkConnectivityForTick(state)
		end

		local connectedAdditions = emptyTierFloats()
		local pushNeeded = false
		local drills = self._oilStateService:GetActiveDrills(userId)

		for _, drill in ipairs(drills) do
			local flow = drill.flowBase * deltaSeconds
			local perDrillAdditions = emptyTierFloats()

			-- If the drill's tile has a specific oil type, produce 100% of that type.
			-- Otherwise fall back to the biome tierMix percentage distribution.
			local tileOilType = drill.tileOilType
			if tileOilType and perDrillAdditions[tileOilType] ~= nil then
				perDrillAdditions[tileOilType] = flow
			else
				for _, tier in ipairs(TIERS) do
					local weightPercent = drill.tierMix[tier] or 0
					perDrillAdditions[tier] = flow * (weightPercent / 100)
				end
			end

			-- Per-tier tank-full gating: if tank N is full, stop producing tier N this tick.
			-- Other tiers keep flowing. Matches OilStateService:ApplyProduction's per-tier clamp.
			for _, tier in ipairs(TIERS) do
				if self._oilStateService:TankIsFull(userId, tier) then
					perDrillAdditions[tier] = 0
				end
			end

			if drill.connected then
				-- Drain any buffered oil first
				local drained = self._oilStateService:DrainDrillBuffer(userId, drill.drillId)
				if drained > 0 then
					pushNeeded = true
				end
				-- Then accumulate this tick's flow into the player inventory pile
				for _, tier in ipairs(TIERS) do
					connectedAdditions[tier] += perDrillAdditions[tier]
				end
			else
				-- Disconnected: route into local buffer (until cap)
				local _wasFull = self._oilStateService:AddToDrillBuffer(userId, drill.drillId, perDrillAdditions)
				pushNeeded = true
			end
		end

		local added = self._oilStateService:ApplyProduction(userId, connectedAdditions)
		if added > 0 or pushNeeded then
			self._oilStateService:PushState(userId)
		end
	end
end

return OilProductionService
