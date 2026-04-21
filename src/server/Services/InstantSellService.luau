--!strict
-- ShipOilPanel.InstantSell handler — receives `RequestInstantSell` from
-- the DeliveryMan flow ({ quantities, requestId }), atomically consumes
-- those barrels from `OilStateService.state.oilByTier`, and pays the
-- player at fixed `InstantSellConfig` prices.
--
-- Mirrors `OilmanService:_handleSell` (same state/cash plumbing,
-- same idempotency-by-requestId guard, same `OilActionResult` envelope)
-- but reads its prices from `InstantSellConfig.pricePerBarrel` so the
-- two flows can be tuned independently.
--
-- No NPC prompt of its own — the InstantSell modal lives inside
-- `ShipOilPanelGui` and is opened by the player after they've already
-- triggered the DeliveryMan ProximityPrompt (`DeliveryManDialogue`
-- client → `HudPanelRouter.openScreen("ShipOilPanelGui")`).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InstantSellConfig = require(Shared:WaitForChild("Config"):WaitForChild("InstantSellConfig"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local InstantSellService = {}

local REQUEST_ID_TTL_SECONDS = 2.0

local function floorPositive(n: number): number
	return math.max(0, math.floor(n))
end

function InstantSellService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._running = false
	self._connections = {}
	-- Per-userId idempotency cache (same shape as OilmanService): client
	-- generates a GUID per click; we silently drop dup retries so a network
	-- hiccup can't double-charge inventory.
	self._recentRequestIds = {} :: { [number]: { [string]: number } }
end

local function isDuplicateRequestId(self, userId: number, requestId: string): boolean
	local now = os.clock()
	local byUser = self._recentRequestIds[userId]
	if not byUser then
		byUser = {}
		self._recentRequestIds[userId] = byUser
	end
	for id, expires in pairs(byUser) do
		if expires <= now then
			byUser[id] = nil
		end
	end
	if byUser[requestId] then
		return true
	end
	byUser[requestId] = now + REQUEST_ID_TTL_SECONDS
	return false
end

function InstantSellService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data: any?)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
		-- Tag so the client can distinguish InstantSell receipts from
		-- Oilman / Dispatch results landing on the same `OilActionResult`
		-- channel.
		action = "InstantSell",
	})
end

function InstantSellService:_handleSell(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.InvalidPayload, "Missing payload.")
		return
	end

	if typeof(payload.requestId) == "string" and payload.requestId ~= "" then
		if isDuplicateRequestId(self, player.UserId, payload.requestId) then
			return
		end
	end

	local quantities = payload.quantities
	if typeof(quantities) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.InvalidPayload, "Missing quantities.")
		return
	end

	local state = self._oilStateService:GetState(player.UserId)
	if not state or typeof(state.oilByTier) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.Unknown, "Your state isn't ready yet.")
		return
	end

	local consumeManifest = {} :: { [string]: number }
	local lines = {}
	local totalBarrels = 0
	local totalPayout = 0
	for _, tier in ipairs(InstantSellConfig.TierOrder) do
		local requested = floorPositive(tonumber(quantities[tier]) or 0)
		local have = floorPositive(tonumber(state.oilByTier[tier]) or 0)
		local take = math.min(requested, have)
		if take > 0 then
			local pricePer = InstantSellConfig.pricePerBarrel(tier)
			local payout = take * pricePer
			consumeManifest[tier] = take
			totalBarrels += take
			totalPayout += payout
			table.insert(lines, {
				tier = tier,
				quantity = take,
				pricePerBarrel = pricePer,
				payout = payout,
			})
		end
	end

	if totalBarrels <= 0 then
		self:_sendActionResult(player, false, ErrorCodes.NoOil, "Nothing to sell.")
		return
	end

	local consumed = self._oilStateService:ConsumeManifest(player.UserId, consumeManifest)
	if not consumed then
		self:_sendActionResult(player, false, ErrorCodes.Unknown, "Sell failed — please retry.")
		return
	end
	-- `actualPayout` carries the post-DoubleEarnings amount so the toast
	-- message + payload reflect what was actually credited.
	local _ok, actualPayout = self._oilStateService:AddCash(player.UserId, totalPayout)
	self._oilStateService:PushState(player.UserId)

	DevLog.log(string.format(
		"[InstantSell] %s sold %d barrels for $%d",
		player.Name,
		totalBarrels,
		actualPayout
	))

	self:_sendActionResult(player, true, ErrorCodes.Ok,
		string.format("Sold %d barrels for $%d.", totalBarrels, actualPayout),
		{ lines = lines, totalBarrels = totalBarrels, totalPayout = actualPayout })
end

function InstantSellService:Start()
	if self._running then
		return
	end
	self._running = true

	local sellEvent = self._remoteService:GetEvent(RemoteNames.RequestInstantSell)
	table.insert(self._connections, sellEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleSell(player, payload)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		self._recentRequestIds[player.UserId] = nil
	end))
end

function InstantSellService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
end

return InstantSellService
