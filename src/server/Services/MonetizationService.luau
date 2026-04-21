--!strict
--- MonetizationService
---
--- Server-side bridge between Roblox `MarketplaceService` and the rest of the
--- game. Owns three responsibilities:
---   1. **Prompt** — when a client clicks "Buy" on a `MonetizationCatalog`
---      item, it fires `RequestPromptRobuxPurchase` and we look the item up,
---      validate the `productId`, and call `MarketplaceService:Prompt*`.
---   2. **Receipt** — claim `MarketplaceService.ProcessReceipt` so we can
---      verify the receipt, look the item up by `ProductId`, and run the
---      grant payload (e.g. `OilStateService:GrantShipSkin`). Idempotent on
---      `(userId, purchaseId)` via DataStore so a double-network-flush can't
---      grant a ship twice.
---   3. **Ownership** — for GamePass items, expose a `HasGamePassEffect`
---      helper that consuming services (e.g. boost services later) can call
---      without duplicating `MarketplaceService:UserOwnsGamePassAsync` glue.
---
--- Mirrors the lifecycle of every other service (`Init` / `Start` / `Stop`).
--- Catalog reads stay in `MonetizationCatalog`; this module never embeds
--- product ids or Robux prices itself.

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Constants = require(Shared:WaitForChild("Constants"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local MonetizationService = {}

--- DataStore key namespace for receipt idempotency. Bumping the version
--- string forces a resync (e.g. if we change the receipt envelope shape).
local PURCHASE_HISTORY_STORE = "MonetizationPurchases_v1"
--- TTL on in-memory dedup so a Roblox retry within the same session can't
--- grant the same product twice even before the DataStore write lands.
local IN_MEMORY_RECEIPT_TTL_SECONDS = 60

local function isStudioWithoutDataStores(): boolean
	return RunService:IsStudio()
end

function MonetizationService:Init(remoteService, oilStateService, straitStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	-- `straitStateService` is optional only so existing tests / call sites that
	-- haven't been updated still load. Production wiring (`init.server.luau`)
	-- always passes it; without it the strait force-open / force-close
	-- consumables fail with `ERR_STRAIT_LOCK_REJECTED` rather than silently
	-- granting nothing.
	self._straitStateService = straitStateService
	self._connections = {}
	self._running = false
	--- userId -> { [purchaseId] = expiresClock } in-memory dedup. Persistent
	--- dedup lives in DataStore; this just covers the gap before SetAsync
	--- completes when Roblox immediately retries a failed receipt.
	self._recentReceipts = {} :: { [number]: { [string]: number } }
	--- userId -> { [gamePassId] = boolean } cached `UserOwnsGamePassAsync`.
	--- Cleared on `PlayerRemoving` so a returning player can't be falsely
	--- locked out / falsely granted access if they bought / refunded between
	--- sessions.
	self._gamePassCache = {} :: { [number]: { [number]: boolean } }

	pcall(function()
		self._purchaseStore = DataStoreService:GetDataStore(PURCHASE_HISTORY_STORE)
	end)
	if not self._purchaseStore and not isStudioWithoutDataStores() then
		warn("[MonetizationService] No purchase history DataStore — receipts will use in-memory dedup only.")
	end
end

function MonetizationService:Start()
	if self._running then
		return
	end
	self._running = true

	-- Claim ProcessReceipt. Roblox enforces a single owner per place; if
	-- something else also assigns this, last-writer wins and we silently
	-- stop receiving receipts.
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_processReceipt(receiptInfo)
	end

	local promptEvent = self._remoteService:GetEvent(RemoteNames.RequestPromptRobuxPurchase)
	table.insert(self._connections, promptEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePromptRequest(player, payload)
	end))

	local catalogFn = self._remoteService:GetFunction(RemoteNames.RequestMonetizationCatalog)
	catalogFn.OnServerInvoke = function(_player)
		return MonetizationCatalog.ListForClient()
	end

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self._recentReceipts[player.UserId] = nil
		self._gamePassCache[player.UserId] = nil
	end))

	-- GamePass purchases never go through `ProcessReceipt`; instead Roblox
	-- fires `PromptGamePassPurchaseFinished` when the prompt closes. We use
	-- this signal to (a) invalidate `_gamePassCache` so the next
	-- `HasGamePassEffect` call re-asks `UserOwnsGamePassAsync` (which now
	-- returns true), and (b) re-push the player's effect snapshot so the
	-- HUD active-state chrome (e.g. rainbow stroke around the 2x earnings
	-- icon) lights up immediately without a rejoin. Cache is invalidated
	-- even on `wasPurchased = false` because Roblox occasionally fires the
	-- event with stale `wasPurchased` and the next ownership check is the
	-- final word anyway.
	table.insert(self._connections, MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		local byUser = self._gamePassCache[player.UserId]
		if byUser then
			byUser[gamePassId] = nil
		end
		if wasPurchased then
			self:_pushGamePassEffectsToClient(player)
			-- Mirror the DevProduct receipt path: a successful GamePass buy
			-- also suppresses the post-login Robux Shop auto-open. Idempotent
			-- on already-dismissed profiles. See `_processReceipt` for the
			-- DevProduct equivalent and `OilStateService:MarkRobuxShopAutoOpenDismissed`
			-- for the persisted flag semantics.
			if self._oilStateService and typeof(self._oilStateService.MarkRobuxShopAutoOpenDismissed) == "function" then
				pcall(function()
					self._oilStateService:MarkRobuxShopAutoOpenDismissed(player.UserId)
				end)
			end
		end
	end))

	-- Push the initial effects snapshot to every player as they join. Done
	-- on a deferred task so the client's `ClientRemotes` `WaitForChild`
	-- has a chance to land before the event fires (a `FireClient` to a
	-- player who hasn't connected the listener yet is silently dropped).
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			if player.Parent then
				self:_pushGamePassEffectsToClient(player)
			end
		end)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		task.delay(2, function()
			if player.Parent then
				self:_pushGamePassEffectsToClient(player)
			end
		end)
	end

	self:_registerStraitForceLockHandlers()
end

--- Wire `consumable.id` → `StraitStateService:ForceStateForDuration` for the
--- two Robux strait products. Kept in `MonetizationService` (not a separate
--- service) because (a) there is no other consumer for the lock, (b) the
--- handler's whole job is "translate a receipt into a one-shot state lock",
--- which is exactly what `_grantConsumable` plugs into.
---
--- Conflict & refund policy: if `ForceStateForDuration` returns false (lock
--- already active) we propagate `false, "ERR_STRAIT_LOCK_REJECTED"` from the
--- handler. `_processReceipt` then returns `NotProcessedYet`, which Roblox
--- treats as "do not consume Robux"; the buyer is auto-refunded on the next
--- session. This is the documented contract from `MonetizationCatalog.luau`.
function MonetizationService:_registerStraitForceLockHandlers()
	if not self._straitStateService then
		warn("[MonetizationService] No StraitStateService injected — strait force-open / force-close consumables will reject all receipts.")
		return
	end
	local function makeHandler(state: string)
		return function(userId: number, _quantity: number): (boolean, string?)
			local player = Players:GetPlayerByUserId(userId)
			-- Player may have left between purchase confirmation and receipt
			-- replay; we still apply the lock (server-wide effect) but lose
			-- the display-name attribution. Banner falls back to "A Player".
			local applied = self._straitStateService:ForceStateForDuration(state, Constants.StraitForceLockSeconds, player)
			if not applied then
				return false, "ERR_STRAIT_LOCK_REJECTED"
			end
			return true, nil
		end
	end
	self:SetConsumableHandler("strait_open_2min", makeHandler("Open"))
	self:SetConsumableHandler("strait_close_2min", makeHandler("Closed"))
end

function MonetizationService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
	-- Intentionally leave `MarketplaceService.ProcessReceipt` in place; if we
	-- cleared it during a server-shutdown receipt re-deliver, Roblox would
	-- fall back to "not granted" and re-deliver again next session, which is
	-- the desired behavior.
end

-- =================== PROMPT ===================

function MonetizationService:_sendResult(player: Player, ok: boolean, code: string, message: string, data: any?)
	local ev = self._remoteService:GetEvent(RemoteNames.MonetizationResult)
	ev:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function MonetizationService:_handlePromptRequest(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing payload.")
		return
	end
	local itemId = payload.itemId
	local item = MonetizationCatalog.GetItem(itemId)
	if not item then
		self:_sendResult(player, false, "ERR_UNKNOWN_ITEM", "That item isn't on the menu.", { itemId = itemId })
		return
	end
	if not MonetizationCatalog.Enabled then
		self:_sendResult(player, false, "ERR_MONETIZATION_DISABLED", "Robux purchases are currently disabled.", { itemId = itemId })
		return
	end
	if not MonetizationCatalog.IsValidProductId(item.productId) then
		-- Studio path: catalog seeded with `productId = 0` placeholders so
		-- the UI is testable before the real Roblox dashboard ids exist.
		-- Surface a "Coming Soon" toast instead of crashing the prompt.
		self:_sendResult(player, false, "ERR_PRODUCT_NOT_CONFIGURED", "This item isn't on sale yet.", { itemId = itemId })
		return
	end

	-- One-time-purchase gate. Authoritative server-side check so the player
	-- cannot re-buy a Featured/Limited bundle even if their client UI is
	-- stale (e.g. snapshot hadn't landed yet, or the Studio author tree
	-- doesn't hide the row). The actual flag flip happens in
	-- `_processReceipt` once the receipt is verified — see the
	-- `MonetizationItem.oneTimePurchase` doc for the full contract. We do
	-- this AFTER `IsValidProductId` so an item still being authored
	-- (`productId = 0`) reports the more useful "Coming soon" code first.
	if item.oneTimePurchase == true and self._oilStateService
		and typeof(self._oilStateService.HasPurchasedOneTimeItem) == "function"
		and self._oilStateService:HasPurchasedOneTimeItem(player.UserId, item.id)
	then
		self:_sendResult(player, false, "ERR_ALREADY_PURCHASED", "You already own this one-time bundle.", { itemId = item.id })
		return
	end

	local ok, err = pcall(function()
		if item.productKind == "GamePass" then
			MarketplaceService:PromptGamePassPurchase(player, item.productId)
		else
			MarketplaceService:PromptProductPurchase(player, item.productId)
		end
	end)
	if not ok then
		warn(string.format("[MonetizationService] Prompt failed for %s (%s): %s", item.id, tostring(item.productId), tostring(err)))
		self:_sendResult(player, false, "ERR_PROMPT_FAILED", "Couldn't open the purchase prompt.", { itemId = item.id })
		return
	end
	self:_sendResult(player, true, "PROMPT_OPENED", "Opening Roblox purchase prompt.", { itemId = item.id })
end

-- =================== RECEIPT ===================

local function isDuplicateInMemory(self, userId: number, purchaseId: string): boolean
	local now = os.clock()
	local byUser = self._recentReceipts[userId]
	if not byUser then
		byUser = {}
		self._recentReceipts[userId] = byUser
	end
	for id, expires in pairs(byUser) do
		if expires <= now then
			byUser[id] = nil
		end
	end
	if byUser[purchaseId] then
		return true
	end
	byUser[purchaseId] = now + IN_MEMORY_RECEIPT_TTL_SECONDS
	return false
end

local function purchaseHistoryKey(userId: number, purchaseId: string): string
	return string.format("%d_%s", userId, purchaseId)
end

--- Returns true if the DataStore already has a record of this purchase
--- (Roblox retried a previously-granted receipt). Returns false on first-see
--- *or* on DataStore unavailability — we degrade to "treat as new" so a
--- legit purchase isn't lost when DataStores hiccup; the in-memory dedup
--- still prevents same-session double grants.
function MonetizationService:_isReceiptAlreadyGranted(userId: number, purchaseId: string): boolean
	if not self._purchaseStore then
		return false
	end
	local key = purchaseHistoryKey(userId, purchaseId)
	local ok, value = pcall(function()
		return self._purchaseStore:GetAsync(key)
	end)
	if ok and value == true then
		return true
	end
	return false
end

function MonetizationService:_recordReceiptGranted(userId: number, purchaseId: string)
	if not self._purchaseStore then
		return
	end
	local key = purchaseHistoryKey(userId, purchaseId)
	local ok, err = pcall(function()
		self._purchaseStore:SetAsync(key, true)
	end)
	if not ok then
		warn(string.format("[MonetizationService] Failed to record receipt %s for user %d: %s", purchaseId, userId, tostring(err)))
	end
end

function MonetizationService:_processReceipt(receiptInfo)
	if typeof(receiptInfo) ~= "table" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local userId = tonumber(receiptInfo.PlayerId)
	local productId = tonumber(receiptInfo.ProductId)
	local purchaseId = receiptInfo.PurchaseId
	if not userId or not productId or typeof(purchaseId) ~= "string" then
		warn("[MonetizationService] Malformed receipt — refusing.")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if isDuplicateInMemory(self, userId, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if self:_isReceiptAlreadyGranted(userId, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local item = MonetizationCatalog.ItemForReceipt(productId)
	if not item then
		warn(string.format("[MonetizationService] Unknown product id %d in receipt — refusing.", productId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Defensive replay-skip for `oneTimePurchase` items. Roblox can
	-- re-deliver a receipt across server restarts (or if our DataStore
	-- record-write hiccuped previously). For one-time bundles we must NOT
	-- re-run the bundle: ship sub-grant is idempotent (`OK_ALREADY_OWNED`),
	-- but `Currency` and `Equipment` aren't — re-granting would silently
	-- top up the player's wallet + drill stack on every retry. Mark the
	-- receipt granted so Roblox stops retrying; skip the grant body. The
	-- player keeps what they got the first time. The pre-prompt gate in
	-- `_handlePromptRequest` is what prevents the buyer from being charged
	-- a second time in the first place; this is just belt-and-braces for
	-- the rare cross-session retry window.
	if item.oneTimePurchase == true and self._oilStateService
		and typeof(self._oilStateService.HasPurchasedOneTimeItem) == "function"
		and self._oilStateService:HasPurchasedOneTimeItem(userId, item.id)
	then
		self:_recordReceiptGranted(userId, purchaseId)
		DevLog.log(string.format(
			"[Monetization] Skipped re-grant of one-time item %s for user %d (replay; flag already set).",
			item.id, userId
		))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local granted, err = self:_applyGrant(userId, item)
	if not granted then
		warn(string.format("[MonetizationService] Grant failed for %s (user=%d): %s", item.id, userId, tostring(err)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	self:_recordReceiptGranted(userId, purchaseId)
	DevLog.log(string.format("[Monetization] Granted %s to user %d.", item.id, userId))

	-- One-time-purchase post-grant flip. Persists immediately so the next
	-- prompt click hits `ERR_ALREADY_PURCHASED` and the next snapshot push
	-- (triggered inside `MarkPurchasedOneTimeItem`) repaints the open
	-- `RobuxShopPanel` to hide the Featured row without a rejoin. pcall'd
	-- because a state mutation failure must not block reporting the
	-- purchase as granted to the client (Roblox would re-deliver and we'd
	-- now hit the replay-skip branch above and lose the cash + drills).
	if item.oneTimePurchase == true and self._oilStateService
		and typeof(self._oilStateService.MarkPurchasedOneTimeItem) == "function"
	then
		pcall(function()
			self._oilStateService:MarkPurchasedOneTimeItem(userId, item.id)
		end)
	end

	-- Suppress the post-login Robux Shop auto-open for this player from now
	-- on. They've spent Robux at least once, so re-prompting the upsell on
	-- every subsequent login is more nag than upsell. The shop is still
	-- accessible via the HUD `RobuxShop` button at any time.
	-- Idempotent on already-dismissed profiles, and pcall'd because a state
	-- error must not block reporting the purchase as granted to the client.
	if self._oilStateService and typeof(self._oilStateService.MarkRobuxShopAutoOpenDismissed) == "function" then
		pcall(function()
			self._oilStateService:MarkRobuxShopAutoOpenDismissed(userId)
		end)
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		self:_sendResult(player, true, "OK", "Purchase complete.", { itemId = item.id })
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- =================== GRANT DISPATCH ===================

function MonetizationService:_applyGrant(userId: number, item: MonetizationCatalog.MonetizationItem): (boolean, string?)
	-- Top-level grants dispatch through `_dispatchGrant` so `Bundle` entries
	-- can re-use the same routing without duplicating the kind table. The
	-- parent item's `equipOnGrant` is forwarded as the default for ship
	-- sub-grants that don't override it themselves.
	return self:_dispatchGrant(userId, item.grant, item.equipOnGrant == true)
end

--- Route a single `MonetizationGrant` (top-level OR a Bundle child) to the
--- right `_grant*` helper. Bundle children inherit the parent item's
--- `equipOnGrant` unless they set their own.
function MonetizationService:_dispatchGrant(userId: number, grant: MonetizationCatalog.MonetizationGrant, parentEquipOnGrant: boolean): (boolean, string?)
	local kind = grant.kind
	if kind == "Ship" then
		local equip = if grant.equipOnGrant ~= nil then grant.equipOnGrant == true else parentEquipOnGrant
		return self:_grantShip(userId, equip, grant.skinId)
	elseif kind == "Currency" then
		return self:_grantCurrency(userId, grant.cashAmount)
	elseif kind == "Consumable" then
		return self:_grantConsumable(userId, grant.consumable)
	elseif kind == "GamePassEffect" then
		-- GamePass effects don't require state mutation — the entitlement
		-- lives in `UserOwnsGamePassAsync`. We still report success so the
		-- receipt is marked granted and `_sendResult` reaches the client.
		return true, nil
	elseif kind == "Cosmetic" then
		return self:_grantCosmetic(userId, grant.cosmetic)
	elseif kind == "Equipment" then
		return self:_grantEquipment(userId, grant.equipment)
	elseif kind == "Bundle" then
		return self:_grantBundle(userId, grant.bundle, parentEquipOnGrant)
	end
	return false, "ERR_UNHANDLED_GRANT_KIND"
end

function MonetizationService:_grantShip(userId: number, equipOnGrant: boolean, skinId: string?): (boolean, string?)
	if typeof(skinId) ~= "string" or skinId == "" then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	local ok, code = self._oilStateService:GrantShipSkin(userId, skinId)
	-- `OK_ALREADY_OWNED` is a valid no-op outcome (re-grant from a re-deliver).
	if not ok and code ~= "OK_ALREADY_OWNED" then
		return false, code
	end

	if equipOnGrant then
		-- Best-effort auto-equip — we don't fail the grant if this falls
		-- through because the player is mid-disconnect.
		pcall(function()
			self._oilStateService:SetShipSkinId(userId, skinId)
		end)
	end
	pcall(function()
		self._oilStateService:PushState(userId)
	end)
	return true, nil
end

function MonetizationService:_grantCurrency(userId: number, cashAmount: number?): (boolean, string?)
	if typeof(cashAmount) ~= "number" or cashAmount <= 0 then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	-- Direct Robux → cash grants opt out of the DoubleEarnings multiplier:
	-- the Robux price for a "Cash $5,000" pack is sized against the listed
	-- `cashAmount`. Doubling that on top of the GamePass would silently
	-- double-pay every owner. Same reasoning applies to Bundle sub-grants
	-- whose `kind == "Currency"` (they route here too).
	local added = self._oilStateService:AddCash(userId, cashAmount, { skipMultiplier = true })
	if not added then
		return false, "ERR_NO_STATE"
	end
	pcall(function()
		self._oilStateService:PushState(userId)
	end)
	return true, nil
end

function MonetizationService:_grantConsumable(_userId: number, consumable: { id: string, quantity: number }?): (boolean, string?)
	if typeof(consumable) ~= "table" or typeof(consumable.id) ~= "string" or typeof(consumable.quantity) ~= "number" then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	-- No consumable inventory exists yet (nukes etc. will live behind
	-- `ArmyGeneralService`). When the first consumable lands here, route to
	-- the owning service via a `SetConsumableHandler(kind, fn)` plug below.
	-- For now, reject explicitly so a half-wired item isn't silently lost.
	local handler = self._consumableHandlers and self._consumableHandlers[consumable.id]
	if not handler then
		return false, "ERR_NO_CONSUMABLE_HANDLER"
	end
	return handler(_userId, consumable.quantity)
end

function MonetizationService:_grantEquipment(userId: number, equipment: { itemId: string, quantity: number }?): (boolean, string?)
	if typeof(equipment) ~= "table" or typeof(equipment.itemId) ~= "string" or typeof(equipment.quantity) ~= "number" then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	if equipment.quantity < 1 then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	local handler = self._equipmentHandler
	if not handler then
		-- `EquipmentShopService:SetMonetizationService` registers this. Until
		-- then any `Equipment` grant fails so a half-wired bundle can't
		-- silently eat Robux without delivering drills.
		return false, "ERR_NO_EQUIPMENT_HANDLER"
	end
	return handler(userId, equipment.itemId, equipment.quantity)
end

function MonetizationService:_grantBundle(userId: number, bundle: { MonetizationCatalog.MonetizationGrant }?, parentEquipOnGrant: boolean): (boolean, string?)
	if typeof(bundle) ~= "table" or #bundle == 0 then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	-- Best-effort: dispatch every sub-grant, log failures, and report
	-- success so the receipt is marked granted. See `MonetizationGrant.bundle`
	-- doc on `MonetizationCatalog` for why retry-on-partial-failure is unsafe
	-- (currency + equipment grants are not idempotent; ship is).
	local firstFailureCode: string? = nil
	for index, sub in ipairs(bundle) do
		local ok, code = self:_dispatchGrant(userId, sub, parentEquipOnGrant)
		if not ok then
			warn(string.format(
				"[MonetizationService] Bundle sub-grant %d (%s) failed for user %d: %s — recipient will need a manual grant.",
				index,
				tostring(sub.kind),
				userId,
				tostring(code)
			))
			if firstFailureCode == nil then
				firstFailureCode = code or "ERR_BUNDLE_SUB_GRANT_FAILED"
			end
		end
	end
	-- Always succeed at the receipt boundary; partial failures are the dev's
	-- problem to chase via the warns above.
	return true, nil
end

function MonetizationService:_grantCosmetic(_userId: number, cosmetic: { kind: string, id: string }?): (boolean, string?)
	if typeof(cosmetic) ~= "table" then
		return false, "ERR_BAD_GRANT_PAYLOAD"
	end
	local handler = self._cosmeticHandlers and self._cosmeticHandlers[cosmetic.kind]
	if not handler then
		return false, "ERR_NO_COSMETIC_HANDLER"
	end
	return handler(_userId, cosmetic.id)
end

-- =================== EXTENSION HOOKS ===================

--- Register a server-side handler for a `Consumable` grant id (e.g. "nuke").
--- Lets `ArmyGeneralService` add itself without `MonetizationService` having
--- to import every consumer. Same shape for cosmetics below.
function MonetizationService:SetConsumableHandler(id: string, fn: (userId: number, quantity: number) -> (boolean, string?))
	self._consumableHandlers = self._consumableHandlers or {}
	self._consumableHandlers[id] = fn
end

function MonetizationService:SetCosmeticHandler(kind: string, fn: (userId: number, id: string) -> (boolean, string?))
	self._cosmeticHandlers = self._cosmeticHandlers or {}
	self._cosmeticHandlers[kind] = fn
end

--- Register the global Equipment grant handler. Called by
--- `EquipmentShopService:SetMonetizationService` once both services are
--- inited. There's only one equipment subsystem so we keep this as a single
--- function rather than a `kind`-keyed table like consumables/cosmetics.
--- Handler signature: `(userId, equipmentItemId, quantity) -> (ok, err?)`.
function MonetizationService:SetEquipmentHandler(fn: (userId: number, itemId: string, quantity: number) -> (boolean, string?))
	self._equipmentHandler = fn
end

-- =================== GAMEPASS LOOKUP ===================

function MonetizationService:HasGamePass(player: Player, gamePassId: number): boolean
	if not MonetizationCatalog.IsValidProductId(gamePassId) then
		return false
	end
	local cached = self._gamePassCache[player.UserId]
	if cached and cached[gamePassId] ~= nil then
		return cached[gamePassId]
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	local result = ok and owns == true
	self._gamePassCache[player.UserId] = self._gamePassCache[player.UserId] or {}
	self._gamePassCache[player.UserId][gamePassId] = result
	return result
end

--- Convenience: "does this player own the gamepass that grants the named
--- effect?". Looks up the first GamePass-kind item with matching
--- `grant.gamePassEffect` in the catalog.
function MonetizationService:HasGamePassEffect(player: Player, effectId: string): boolean
	for _, item in ipairs(MonetizationCatalog.Items) do
		if item.productKind == "GamePass" and item.grant.kind == "GamePassEffect" and item.grant.gamePassEffect == effectId then
			if self:HasGamePass(player, item.productId) then
				return true
			end
		end
	end
	return false
end

--- Snapshot every distinct `gamePassEffect` declared in the catalog → boolean
--- ownership for the given player. The map only includes effect ids the
--- catalog actually publishes a GamePass for; clients should treat missing
--- keys as `false`. Used by the HUD chrome (`EarningsGamepassController`)
--- to decide whether to show the active-state pulsing rainbow stroke.
function MonetizationService:GetGamePassEffectsForPlayer(player: Player): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, item in ipairs(MonetizationCatalog.Items) do
		if
			item.productKind == "GamePass"
			and item.grant.kind == "GamePassEffect"
			and typeof(item.grant.gamePassEffect) == "string"
			and item.grant.gamePassEffect ~= ""
			and MonetizationCatalog.IsValidProductId(item.productId)
		then
			local effectId = item.grant.gamePassEffect :: string
			if out[effectId] ~= true then
				out[effectId] = self:HasGamePass(player, item.productId)
			end
		end
	end
	return out
end

function MonetizationService:_pushGamePassEffectsToClient(player: Player)
	if not self._remoteService then
		return
	end
	local ok, ev = pcall(function()
		return self._remoteService:GetEvent(RemoteNames.GamePassEffectsUpdate)
	end)
	if not ok or not ev then
		return
	end
	local effects = self:GetGamePassEffectsForPlayer(player)
	pcall(function()
		ev:FireClient(player, { effects = effects })
	end)
end

return MonetizationService
