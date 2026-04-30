--!strict
-- Rebirth shop server (`RebirthShopPanelGui`). Validates and processes
-- token purchases from `RebirthShopConfig.Items`. Today only the `drill`
-- entry is purchasable; success grants `grantsDrillCount` rebirth-drill
-- consumables via `OilStateService:AddRebirthDrills`, which the
-- `OilHeavenDrillService` attribute watcher turns into a Backpack tool.
--
-- Wire shape:
--   Client → server: `RequestRebirthShopPurchase` ({ itemId }) → server
--                    replies on `OilActionResult` with action
--                    `"RebirthShopPurchase"`.
--   Client → server: `RequestRebirthShopSnapshot` (RemoteFunction) →
--                    `{ tokens, drills, bonusTotals }` for panel-open hydration.
--
-- Result codes (action = "RebirthShopPurchase"):
--   * `OK`                       — purchase applied, `data` carries the new wallet.
--   * `ERR_BAD_PAYLOAD`          — missing / non-string itemId.
--   * `ERR_BAD_ITEM`             — itemId not in `RebirthShopConfig.Items`.
--   * `ERR_NOT_AVAILABLE`        — item exists but `available = false` (coming-soon).
--   * `ERR_INSUFFICIENT_TOKENS`  — wallet < tokenCost (drives client error toast).
--   * `ERR_RATE_LIMIT`           — same-userId request inside the debounce window.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RebirthShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("RebirthShopConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local Telemetry = require(Shared:WaitForChild("Telemetry"))

local PURCHASE_DEBOUNCE_SECONDS = 0.35
--- Rebirth is a destructive operation; the debounce prevents a fast
--- double-click from invoking it twice (the first invocation would have
--- already wiped state, so the second would hit `ERR_NOT_ENOUGH_CASH` and
--- be harmless — but we still rate-limit for safety).
local REBIRTH_DEBOUNCE_SECONDS = 1.5

local RebirthShopService = {}

function RebirthShopService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {} :: { RBXScriptConnection }
	self._lastPurchaseAtByUser = {} :: { [number]: number }
	self._lastRebirthAtByUser = {} :: { [number]: number }
	self._running = false
	-- Per-service handles wired post-Init via `Set*Service` so the bootstrap
	-- order doesn't dictate construction order. Each is optional — a missing
	-- service just skips that piece of the rebirth cleanup.
	self._warehouseService = nil :: any?
	self._drillingService = nil :: any?
	self._equipmentShopService = nil :: any?
	self._oilShipmentService = nil :: any?
end

function RebirthShopService:SetWarehouseService(svc: any)
	self._warehouseService = svc
end

function RebirthShopService:SetDrillingService(svc: any)
	self._drillingService = svc
end

function RebirthShopService:SetEquipmentShopService(svc: any)
	self._equipmentShopService = svc
end

function RebirthShopService:SetOilShipmentService(svc: any)
	self._oilShipmentService = svc
end

function RebirthShopService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data: any?, action: string?)
	local actionResultEvent = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	actionResultEvent:FireClient(player, {
		action = action or "RebirthShopPurchase",
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function RebirthShopService:_handlePurchase(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Bad request.", nil)
		return
	end
	local itemId = payload.itemId
	if typeof(itemId) ~= "string" or itemId == "" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Missing itemId.", nil)
		return
	end

	local now = os.clock()
	local last = self._lastPurchaseAtByUser[player.UserId] or 0
	if now - last < PURCHASE_DEBOUNCE_SECONDS then
		self:_sendActionResult(player, false, "ERR_RATE_LIMIT", "Slow down.", nil)
		return
	end
	self._lastPurchaseAtByUser[player.UserId] = now

	local item = RebirthShopConfig.GetItem(itemId)
	if not item then
		self:_sendActionResult(player, false, "ERR_BAD_ITEM", "Unknown rebirth shop item.", nil)
		return
	end
	if not item.available then
		self:_sendActionResult(player, false, "ERR_NOT_AVAILABLE", "Coming soon.", nil)
		return
	end

	local tokens = self._oilStateService:GetRebirthTokens(player.UserId)
	if tokens < item.tokenCost then
		self:_sendActionResult(player, false, "ERR_INSUFFICIENT_TOKENS", "Not enough Rebirth Tokens.", {
			itemId = item.id,
			tokens = tokens,
			tokenCost = item.tokenCost,
		})
		return
	end

	-- Debit first, then grant. Both calls floor at 0 internally so a partial
	-- failure can't produce negative balances; the grant is monotone, so this
	-- ordering means a wallet read between the two is briefly low-by-cost but
	-- never negative-by-cost.
	local newTokens = self._oilStateService:AddRebirthTokens(player.UserId, -item.tokenCost)
	local newDrills = self._oilStateService:GetRebirthDrills(player.UserId)
	if item.grantsDrillCount > 0 then
		newDrills = self._oilStateService:AddRebirthDrills(player.UserId, item.grantsDrillCount)
	end

	self._oilStateService:PushState(player.UserId)

	-- Telemetry: economy Sink against `rebirth_tokens` so the dashboard sees
	-- the spend alongside the cash → tokens Source from `OilStateService:Rebirth`.
	-- `item` is the catalog item id (`drill`, etc.) so per-item conversion can
	-- be sliced. pcall'd — a telemetry failure must never block the purchase.
	if item.tokenCost > 0 then
		pcall(function()
			Telemetry.Economy(
				player,
				"Sink",
				item.tokenCost,
				"rebirth_tokens",
				"rebirth_tokens_spent",
				item.id
			)
		end)
	end

	self:_sendActionResult(player, true, "OK", "Purchase complete.", {
		itemId = item.id,
		tokens = newTokens,
		drills = newDrills,
	})
end

function RebirthShopService:_handleRebirth(player: Player)
	local now = os.clock()
	local last = self._lastRebirthAtByUser[player.UserId] or 0
	if now - last < REBIRTH_DEBOUNCE_SECONDS then
		self:_sendActionResult(player, false, "ERR_RATE_LIMIT", "Slow down.", nil, "Rebirth")
		return
	end
	self._lastRebirthAtByUser[player.UserId] = now

	-- The state mutation is the load-bearing step. Per-service cleanups
	-- (warehouse barrels, equipment backpack tools, drill timers) run AFTER
	-- and are best-effort: each is pcall'd so a single failure can't leave
	-- the player half-rebirthed. The OilStateService state is the source of
	-- truth — even if a per-service cleanup fails, the next state push or
	-- character respawn will reconcile that service's view eventually.
	local ok, code, data = self._oilStateService:Rebirth(player.UserId)
	if not ok then
		local message = "Rebirth failed."
		if code == "ERR_NOT_ENOUGH_CASH" then
			message = "Not enough cash for one Rebirth Token."
		elseif code == "ERR_NO_STATE" then
			message = "State unavailable — try again in a moment."
		elseif code == "ERR_NO_PLOT" then
			message = "Plot unavailable — try again in a moment."
		elseif code == "ERR_BUILD_FAILED" then
			message = "Rebirth build failed — your progress is unchanged."
		end
		self:_sendActionResult(player, false, code, message, data, "Rebirth")
		return
	end

	-- Per-service cleanups, each pcall'd so one failure doesn't cascade.
	if self._warehouseService and typeof(self._warehouseService.ResetForRebirth) == "function" then
		pcall(function()
			self._warehouseService:ResetForRebirth(player.UserId)
		end)
	end
	if self._drillingService and typeof(self._drillingService.CancelDrillsForUser) == "function" then
		pcall(function()
			self._drillingService:CancelDrillsForUser(player.UserId)
		end)
	end
	if self._equipmentShopService and typeof(self._equipmentShopService.ReconcileForUser) == "function" then
		pcall(function()
			self._equipmentShopService:ReconcileForUser(player)
		end)
	end
	if self._oilShipmentService and typeof(self._oilShipmentService.CancelShipmentsForUser) == "function" then
		pcall(function()
			self._oilShipmentService:CancelShipmentsForUser(player.UserId)
		end)
	end

	-- Push the wiped state to the client so the plot grid, drill models,
	-- cash strip, and warehouse visuals all re-render in one frame.
	pcall(function()
		self._oilStateService:PushState(player.UserId)
	end)

	self:_sendActionResult(player, true, "OK", "Rebirth complete.", data, "Rebirth")
end

function RebirthShopService:_handleSnapshot(player: Player): any
	local userId = player.UserId
	local tokens = self._oilStateService:GetRebirthTokens(userId)
	local drills = self._oilStateService:GetRebirthDrills(userId)
	local bonusTotals = self._oilStateService:GetOilHeavenBonusTotals(userId)
	-- `cash` is included for `RebirthPanelGui` (the rebirth-flow modal) — it
	-- needs an open-time snapshot of cash so the CashAmount / TokenCount
	-- preview paints immediately on first open. Subsequent live updates come
	-- through `oilStateUpdate`. The shop panel ignores this field.
	local cash = self._oilStateService:GetCash(userId)
	return {
		tokens = tokens,
		drills = drills,
		bonusTotals = bonusTotals,
		cash = cash,
	}
end

function RebirthShopService:Start()
	if self._running then
		return
	end
	self._running = true

	local purchaseEvent = self._remoteService:GetEvent(RemoteNames.RequestRebirthShopPurchase)
	table.insert(self._connections, purchaseEvent.OnServerEvent:Connect(function(player: Player, payload: any)
		self:_handlePurchase(player, payload)
	end))

	local rebirthEvent = self._remoteService:GetEvent(RemoteNames.RequestRebirth)
	table.insert(self._connections, rebirthEvent.OnServerEvent:Connect(function(player: Player)
		self:_handleRebirth(player)
	end))

	local snapshotFn = self._remoteService:GetFunction(RemoteNames.RequestRebirthShopSnapshot)
	snapshotFn.OnServerInvoke = function(player: Player)
		return self:_handleSnapshot(player)
	end
end

function RebirthShopService:Stop()
	self._running = false
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return RebirthShopService
