--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PricingConfig = require(Shared:WaitForChild("Config"):WaitForChild("PricingConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local OIL_TYPES = { "Crude", "Refined", "Premium" }

local OilMarketService = {}

-- Per-server first-sale gate. `Telemetry.SetSession`/`SessionGet` were not
-- shipped in PR 3, so this service tracks first-* idempotency locally.
local _firstSaleByUserId: { [number]: boolean } = {}

local function _emitOilSold(player: Player, payload: {
	itemSku: string,
	cashGained: number,
	barrelsByTier: { [string]: number },
	currentPrices: { [string]: number },
	straitEngineState: string?,
	marketTrend: string?,
})
	-- Wrap in pcall so a Telemetry bug can never block a sell handler
	-- mid-payout.
	pcall(function()
		Telemetry.Economy(
			player,
			"Source",
			payload.cashGained,
			"cash",
			"oil_sold",
			payload.itemSku
		)
		Telemetry.Track(player, "oil_sold", {
			barrelsByTier = payload.barrelsByTier,
			cashGained = payload.cashGained,
			currentPrices = payload.currentPrices,
			straitEngineState = payload.straitEngineState,
			marketTrend = payload.marketTrend,
		})
		if not _firstSaleByUserId[player.UserId] then
			_firstSaleByUserId[player.UserId] = true
			Telemetry.Funnel(player, "first_run", 4, "first_sale")
		end
	end)
end

function OilMarketService:Init(remoteService, straitStateService, warehouseService, oilStateService)
	self._remoteService = remoteService
	self._straitStateService = straitStateService
	self._warehouseService = warehouseService
	self._oilStateService = oilStateService
	self._ftueService = nil :: any

	self._rng = Random.new()
	self._running = false
	self._connections = {}
	self._currentStraitState = "Open"
	self._baseOilPrice = PricingConfig.BasePrice -- the ONE price that fluctuates
	self._currentPrices = {} -- derived per QualityConfig.Tiers keys
	self._basePriceHistory = {} -- track base price for trend
	self._nextMicroTickAt = 0
end

function OilMarketService:SetFtueService(ftueService: any)
	self._ftueService = ftueService
end

function OilMarketService:Start()
	self._running = true

	-- Get initial strait state
	local snapshot = self._straitStateService:GetSnapshot()
	self._currentStraitState = snapshot.state or "Open"

	-- Initial price roll
	self:_rollPrice(self._currentStraitState)
	self:_broadcastMarketUpdate()

	-- Subscribe to strait state changes
	local straitConn = self._straitStateService:OnStateChanged(function(newSnapshot)
		if not self._running then return end
		self._currentStraitState = newSnapshot.state or "Open"
		self:_rollPrice(self._currentStraitState)
		self:_broadcastMarketUpdate()
	end)
	table.insert(self._connections, straitConn)

	-- Micro-tick loop
	self._nextMicroTickAt = workspace:GetServerTimeNow() + self:_sampleMicroTickDelay()
	task.spawn(function()
		while self._running do
			local now = workspace:GetServerTimeNow()
			if now >= self._nextMicroTickAt then
				self:_rollPrice(self._currentStraitState)
				self:_broadcastMarketUpdate()
				self._nextMicroTickAt = now + self:_sampleMicroTickDelay()
			end
			task.wait(1)
		end
	end)

	-- Sell per-type handler
	local sellTypeEvent = self._remoteService:GetEvent(RemoteNames.RequestSellWarehouseType)
	sellTypeEvent.OnServerEvent:Connect(function(player, data)
		if not self._running then return end
		if typeof(data) ~= "table" or typeof(data.oilType) ~= "string" then return end
		self:HandleSellType(player.UserId, data.oilType)
	end)

	-- Sell all handler
	local sellAllEvent = self._remoteService:GetEvent(RemoteNames.RequestSellAllWarehouse)
	sellAllEvent.OnServerEvent:Connect(function(player)
		if not self._running then return end
		self:HandleSellAll(player.UserId)
	end)

	local sellBarrelsEvent = self._remoteService:GetEvent(RemoteNames.RequestSellWarehouseBarrels)
	sellBarrelsEvent.OnServerEvent:Connect(function(player, data)
		if not self._running then return end
		if typeof(data) ~= "table" then return end
		self:HandleSellWarehouseBarrels(player.UserId, data)
	end)

	-- Market snapshot request (RemoteFunction for initial client load)
	local snapshotFn = self._remoteService:GetFunction(RemoteNames.RequestMarketSnapshot)
	snapshotFn.OnServerInvoke = function(_player)
		return self:GetMarketSnapshot()
	end

	-- Push market state to players who join mid-session
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			local event = self._remoteService:GetEvent(RemoteNames.MarketPriceUpdate)
			event:FireClient(player, self:GetMarketSnapshot())
		end)
	end))

	-- Clean up first-sale tracking on leave
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		_firstSaleByUserId[player.UserId] = nil
	end))
end

function OilMarketService:Stop()
	self._running = false
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

-- =================== PRICING ===================

function OilMarketService:_sampleMicroTickDelay(): number
	local jitter = self._rng:NextInteger(-PricingConfig.MicroTickJitterSeconds, PricingConfig.MicroTickJitterSeconds)
	return math.max(10, PricingConfig.MicroTickSeconds + jitter)
end

function OilMarketService:_rollPrice(straitState: string)
	local band = PricingConfig.Bands[straitState]
	if not band then
		band = PricingConfig.Bands.Open
	end

	-- Push old base price to history
	if self._baseOilPrice then
		table.insert(self._basePriceHistory, self._baseOilPrice)
		if #self._basePriceHistory > PricingConfig.TrendMemory then
			table.remove(self._basePriceHistory, 1)
		end
	end

	-- Roll ONE base oil price
	local randomFactor = self._rng:NextNumber() -- [0, 1]
	local multiplier = band.minMul + (band.maxMul - band.minMul) * randomFactor
	self._baseOilPrice = math.max(1, math.floor(PricingConfig.BasePrice * multiplier))

	-- Derive per-type prices
	for _, oilType in ipairs(OIL_TYPES) do
		local typeMul = PricingConfig.TypeMultipliers[oilType] or 1.0
		self._currentPrices[oilType] = math.max(1, math.floor(self._baseOilPrice * typeMul))
	end
end

function OilMarketService:_computeTrend(): string
	if #self._basePriceHistory == 0 then return "stable" end
	local sum = 0
	for _, p in ipairs(self._basePriceHistory) do sum += p end
	local avg = sum / #self._basePriceHistory
	if self._baseOilPrice > avg * PricingConfig.TrendUpThreshold then
		return "up"
	elseif self._baseOilPrice < avg * PricingConfig.TrendDownThreshold then
		return "down"
	end
	return "stable"
end

function OilMarketService:GetCurrentPrices()
	return self._currentPrices
end

function OilMarketService:GetMarketSnapshot()
	return {
		basePrice = self._baseOilPrice,
		prices = self._currentPrices,
		trend = self:_computeTrend(),
		straitState = self._currentStraitState,
		nextChangeAt = self._nextMicroTickAt,
		globalBaseMin = PricingConfig.GlobalBaseMin,
		globalBaseMax = PricingConfig.GlobalBaseMax,
		typeMultipliers = PricingConfig.TypeMultipliers,
	}
end

-- =================== BROADCASTING ===================

function OilMarketService:_broadcastMarketUpdate()
	local event = self._remoteService:GetEvent(RemoteNames.MarketPriceUpdate)
	event:FireAllClients(self:GetMarketSnapshot())
end

-- =================== SELLING ===================

function OilMarketService:HandleSellType(userId: number, oilType: string)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	if not QualityConfig.Tiers[oilType] then
		resultEvent:FireClient(player, { ok = false, message = "Invalid oil type" })
		return
	end

	local barrelCount = self._warehouseService:GetBarrelsByType(userId, oilType)
	if barrelCount <= 0 then
		local displayName = QualityConfig.Tiers[oilType] and QualityConfig.Tiers[oilType].displayName or oilType
		resultEvent:FireClient(player, { ok = false, message = "No " .. displayName .. " in warehouse" })
		return
	end

	local price = self._currentPrices[oilType] or 0
	if price <= 0 then
		resultEvent:FireClient(player, { ok = false, message = "Market not ready" })
		return
	end

	local payout = barrelCount * price
	self._warehouseService:RemoveBarrelsByType(userId, oilType)
	-- `actualPayout` reflects the post-DoubleEarnings amount so the toast
	-- below shows the real number credited (2x for owners, 1x otherwise).
	local _ok, actualPayout = self._oilStateService:AddCash(userId, payout)
	self._oilStateService:PushState(userId)

	if actualPayout > 0 then
		_emitOilSold(player, {
			itemSku = oilType,
			cashGained = actualPayout,
			barrelsByTier = { [oilType] = barrelCount },
			currentPrices = self:GetCurrentPrices(),
			straitEngineState = self._currentStraitState,
			marketTrend = self:_computeTrend(),
		})
	end

	if self._ftueService and FtueConfig.Enabled and actualPayout > 0 then
		(self._ftueService :: any):OnFtueWarehouseSaleSuccess(userId, actualPayout)
	end

	local displayName = QualityConfig.Tiers[oilType] and QualityConfig.Tiers[oilType].displayName or oilType
	resultEvent:FireClient(player, {
		ok = true,
		message = string.format("Sold %d %s for $%s!", barrelCount, displayName, tostring(actualPayout)),
	})
end

function OilMarketService:HandleSellWarehouseBarrels(userId: number, payload: any)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	local p = payload :: { [string]: any }

	local removals: { [string]: number } = {}
	local totalSell = 0
	for _, oilType in ipairs(OIL_TYPES) do
		local n = math.max(0, math.floor(tonumber(p[oilType]) or 0))
		removals[oilType] = n
		totalSell += n
	end

	if totalSell <= 0 then
		resultEvent:FireClient(player, { ok = false, message = "Select barrels to sell." })
		return
	end

	local allBarrels = self._warehouseService:GetAllBarrels(userId)
	for _, oilType in ipairs(OIL_TYPES) do
		local want = removals[oilType] or 0
		local have = allBarrels[oilType] or 0
		if want > have then
			resultEvent:FireClient(player, { ok = false, message = "Not enough barrels in warehouse." })
			return
		end
	end

	local totalPayout = 0
	for _, oilType in ipairs(OIL_TYPES) do
		local n = removals[oilType] or 0
		if n > 0 then
			local price = self._currentPrices[oilType] or 0
			if price <= 0 then
				resultEvent:FireClient(player, { ok = false, message = "Market not ready" })
				return
			end
			totalPayout += n * price
		end
	end

	if not self._warehouseService:TryRemoveBarrelsByCounts(userId, removals) then
		resultEvent:FireClient(player, { ok = false, message = "Could not update warehouse." })
		return
	end

	-- `actualPayout` carries the post-DoubleEarnings amount so the message
	-- and FTUE callback below reflect what the player actually received.
	local _ok, actualPayout = self._oilStateService:AddCash(userId, totalPayout)
	self._oilStateService:PushState(userId)

	if actualPayout > 0 then
		_emitOilSold(player, {
			itemSku = "mixed",
			cashGained = actualPayout,
			barrelsByTier = removals,
			currentPrices = self:GetCurrentPrices(),
			straitEngineState = self._currentStraitState,
			marketTrend = self:_computeTrend(),
		})
	end

	if self._ftueService and FtueConfig.Enabled and actualPayout > 0 then
		(self._ftueService :: any):OnFtueWarehouseSaleSuccess(userId, actualPayout)
	end

	resultEvent:FireClient(player, {
		ok = true,
		message = string.format("Sold %d barrels for $%d!", totalSell, actualPayout),
	})
end

function OilMarketService:HandleSellAll(userId: number)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	local allBarrels = self._warehouseService:GetAllBarrels(userId)
	local totalPayout = 0
	local totalSold = 0

	-- Reject the sale if any held tier has no valid market price. Mirrors
	-- the guard in `HandleSellWarehouseBarrels` / `HandleSellOilByType` —
	-- without this, a race during cross-platform handoff (player joins
	-- before `_rollPrice` populates `_currentPrices`) silently wipes the
	-- warehouse for $0 because `count * 0 = 0` and the empty-warehouse
	-- guard below only checks barrel count, not payout.
	for _, oilType in ipairs(OIL_TYPES) do
		local count = allBarrels[oilType] or 0
		if count > 0 then
			local price = self._currentPrices[oilType] or 0
			if price <= 0 then
				resultEvent:FireClient(player, { ok = false, message = "Market not ready" })
				return
			end
			totalPayout += count * price
		end
		totalSold += count
	end

	if totalSold <= 0 then
		resultEvent:FireClient(player, { ok = false, message = "Warehouse is empty" })
		return
	end

	self._warehouseService:RemoveAllBarrels(userId)
	-- `actualPayout` is the post-DoubleEarnings amount so the toast +
	-- FTUE callback reflect what was actually credited.
	local _ok, actualPayout = self._oilStateService:AddCash(userId, totalPayout)
	self._oilStateService:PushState(userId)

	if actualPayout > 0 then
		_emitOilSold(player, {
			itemSku = "mixed",
			cashGained = actualPayout,
			barrelsByTier = allBarrels,
			currentPrices = self:GetCurrentPrices(),
			straitEngineState = self._currentStraitState,
			marketTrend = self:_computeTrend(),
		})
	end

	if self._ftueService and FtueConfig.Enabled and actualPayout > 0 then
		(self._ftueService :: any):OnFtueWarehouseSaleSuccess(userId, actualPayout)
	end

	resultEvent:FireClient(player, {
		ok = true,
		message = string.format("Sold %d barrels for $%s!", totalSold, tostring(actualPayout)),
	})
end

return OilMarketService
