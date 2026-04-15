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
			local perf = _G.Perf
			if perf then
				local h = perf:OpenSpan("OilProduction.runTick")
				self:_runTick(OilConfig.ProductionTickSeconds)
				perf:CloseSpan("OilProduction.runTick", h)
			else
				self:_runTick(OilConfig.ProductionTickSeconds)
			end
		end
	end)
end

function OilProductionService:Stop()
	self._running = false
end

function OilProductionService:_runTick(deltaSeconds: number)
	local perf = _G.Perf
	for userId, state in pairs(self._oilStateService:GetAllStates()) do
		if state.activeDrillCount <= 0 then
			continue
		end

		-- Recompute connectivity for this player's network
		if self._pipeNetworkService then
			local h = perf and perf:OpenSpan("Production.connectivity")
			self._pipeNetworkService:MarkConnectivityForTick(state)
			if h then perf:CloseSpan("Production.connectivity", h) end
		end

		local connectedAdditions = emptyTierFloats()
		local pushNeeded = false
		local hDrills = perf and perf:OpenSpan("Production.drillLoop")
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

		if hDrills then perf:CloseSpan("Production.drillLoop", hDrills) end

		local hApply = perf and perf:OpenSpan("Production.apply")
		local added = self._oilStateService:ApplyProduction(userId, connectedAdditions)
		if hApply then perf:CloseSpan("Production.apply", hApply) end
		if added > 0 or pushNeeded then
			local hPush = perf and perf:OpenSpan("Production.push")
			self._oilStateService:PushState(userId)
			if hPush then perf:CloseSpan("Production.push", hPush) end
		end
	end
end

return OilProductionService
