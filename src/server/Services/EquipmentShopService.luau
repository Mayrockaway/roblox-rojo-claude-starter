--!strict
-- Server-authoritative consumable equipment: spend plot cash (`OilStateService`), clone `Tool`
-- templates from **ServerStorage → `EquipmentShopConfig.TemplateFolderName`**, parent to **Backpack**.
-- Shop tools stack in **one** `Tool` per `EquipmentItemId` with replicated **`EquipmentStackCount`**.
-- Client shop UI: call `RequestEquipmentShopCatalog` then `RequestPurchaseEquipment` with `{ itemId, quantity? }`.
-- Results mirror other oil flows via **`OilActionResult`** (`ok`, `code`, `message`, optional `data`).
-- **Owned counts** persist in `OilMiningProfiles_v3` (`equipmentOwned`); backpack is reconciled on load / plot assign.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local EquipmentCatalog = require(Shared:WaitForChild("Config"):WaitForChild("EquipmentCatalog"))
local EquipmentShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("EquipmentShopConfig"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local STACK_ATTR = Constants.EquipmentStackCountAttribute

local EquipmentShopService = {}

local function floorPositive(n: number): number
	return math.max(0, math.floor(n))
end

local function stackUnitsOnTool(tool: Tool): number
	if tool:GetAttribute("EquipmentShopConsumable") ~= true then
		return 0
	end
	local v = tool:GetAttribute(STACK_ATTR)
	if typeof(v) == "number" and v == v and v > 0 then
		return floorPositive(v)
	end
	return 1
end

local function isShopToolForItem(tool: Tool, itemId: string): boolean
	return tool:GetAttribute("EquipmentShopConsumable") == true and tool:GetAttribute("EquipmentItemId") == itemId
end

function EquipmentShopService:Init(remoteService, oilStateService, plotService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._ftueService = nil :: any?
	self._connections = {}
	self._running = false
	self._templateFolder = nil :: Folder?
	-- Duplicate-request cache: per userId, map of requestId → expiry os.clock().
	-- Client sends a GUID per click; same id within 2 s is ignored.
	self._recentRequestIds = {} :: { [number]: { [string]: number } }
	-- Rotating-shop state. `_currentStock[itemId]` is the remaining count for
	-- this rotation; nil means "not rotating → unlimited". `_currentStockMax`
	-- is the per-rotation **cap** (the `hi` `rollShopStock` rolled against);
	-- the UI uses this to render "X / hi" so the displayed limit matches the
	-- actual cap (which scales with player count via `band.perPlayer`).
	-- `_refreshEndsAt` is the Unix-ish timestamp when the next rotation fires
	-- (via `workspace:GetServerTimeNow()` so clients can sync their countdown).
	self._currentStock = {} :: { [string]: number }
	self._currentStockMax = {} :: { [string]: number }
	self._refreshEndsAt = 0.0
	self._rotationRng = Random.new()
end

local REQUEST_ID_TTL_SECONDS = 2.0

local function isDuplicateRequestId(self, userId: number, requestId: string): boolean
	local now = os.clock()
	local byUser = self._recentRequestIds[userId]
	if not byUser then
		byUser = {}
		self._recentRequestIds[userId] = byUser
	end
	-- Sweep expired entries lazily.
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

function EquipmentShopService:Start()
	if self._running then
		return
	end
	self._running = true

	local folder = ServerStorage:FindFirstChild(EquipmentShopConfig.TemplateFolderName)
	if folder and folder:IsA("Folder") then
		self._templateFolder = folder
	else
		self._templateFolder = nil
		warn(
			string.format(
				"[EquipmentShopService] Missing ServerStorage folder %q — purchases will fail until templates exist.",
				EquipmentShopConfig.TemplateFolderName
			)
		)
	end

	local purchase = self._remoteService:GetEvent(RemoteNames.RequestPurchaseEquipment)
	table.insert(self._connections, purchase.OnServerEvent:Connect(function(player, payload)
		self:_handlePurchase(player, payload)
	end))

	local catalogFn = self._remoteService:GetFunction(RemoteNames.RequestEquipmentShopCatalog)
	catalogFn.OnServerInvoke = function(invokingPlayer: Player)
		return self:GetCatalogForClient(invokingPlayer)
	end

	if self._plotService then
		table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, _plot: Model)
			local player = Players:GetPlayerByUserId(userId)
			if player then
				task.defer(function()
					self:_reconcileOwnedShopTools(player)
				end)
			end
		end))
	end

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player: Player)
		table.insert(self._connections, player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_reconcileOwnedShopTools(player)
			end)
		end))
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		self._recentRequestIds[player.UserId] = nil
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(self._connections, player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_reconcileOwnedShopTools(player)
			end)
		end))
		if player.Character then
			task.defer(function()
				self:_reconcileOwnedShopTools(player)
			end)
		end
	end

	-- Rotating-shop loop: roll stock immediately, then every RefreshIntervalSeconds.
	-- Does NOT persist — server-restart is a fresh roll.
	self:_rollShopStock()
	task.spawn(function()
		while self._running do
			local interval = math.max(5, tonumber(EquipmentCatalog.ShopRotation.RefreshIntervalSeconds) or 180)
			task.wait(interval)
			if not self._running then
				break
			end
			self:_rollShopStock()
		end
	end)
end

--- Player-count is sampled at roll time (every `RefreshIntervalSeconds`), NOT
--- on every join/leave — see chat 2026-04 "store capacity scaling" for the
--- design call. Players who join mid-rotation shop against the snapshot taken
--- at the start of the window and wait at most `RefreshIntervalSeconds` for
--- the next roll to reflect them. Avoids disorienting mid-window stock churn
--- for players already shopping.
function EquipmentShopService:_rollShopStock()
	local playerCount = #Players:GetPlayers()
	local stock = EquipmentCatalog.rollShopStock(self._rotationRng, playerCount)
	-- Sample max with the **same** playerCount used for `rollShopStock` so the
	-- displayed cap matches the cap the RNG actually rolled against.
	local stockMax = EquipmentCatalog.computeShopStockMax(playerCount)
	self._currentStock = stock
	self._currentStockMax = stockMax
	local interval = math.max(5, tonumber(EquipmentCatalog.ShopRotation.RefreshIntervalSeconds) or 180)
	self._refreshEndsAt = workspace:GetServerTimeNow() + interval
	self:_broadcastStock("rotation")
end

--- `reason` is `"rotation"` only when called from `_rollShopStock` (the
--- periodic stock refresh tick). Purchases re-broadcast to keep stock counts
--- in sync but pass `nil` so the client doesn't show the
--- `ShopRefreshNotification` gold banner on every buy.
function EquipmentShopService:_broadcastStock(reason: string?)
	local ev = self._remoteService:GetEvent(RemoteNames.EquipmentShopStockUpdate)
	ev:FireAllClients({
		stock = self._currentStock,
		stockMax = self._currentStockMax,
		refreshEndsAt = self._refreshEndsAt,
		reason = reason,
	})
end

--- Late wire-up — `FtueService` is constructed **after** `EquipmentShopService` in
--- `init.server`. Setting this lets `_handlePurchase` notify the FTUE state machine
--- after a successful free dock-equipment-shop drill purchase.
function EquipmentShopService:SetFtueService(ftueService)
	self._ftueService = ftueService
end

--- True when this purchase should be granted free + bypass rotation stock as the
--- one-shot `WaitDocksEquipmentShop` reward. Reads both player attribute (live step)
--- and persisted oil state (`ftueStep` + `ftueFreeDocksDrillUsed`) so a stale
--- replication frame can't re-arm the discount after the flag is consumed.
function EquipmentShopService:_isFtueFreeDocksDrillPurchase(player: Player, itemId: string): boolean
	if FtueConfig.Enabled ~= true then
		return false
	end
	local freeId = FtueConfig.FtueDocksFreeDrillItemId
	if typeof(freeId) ~= "string" or freeId == "" or itemId ~= freeId then
		return false
	end
	local stepAttr = player:GetAttribute(Constants.FtueStepAttribute)
	if stepAttr ~= FtueConfig.Step.WaitDocksEquipmentShop then
		return false
	end
	local state = self._oilStateService:GetState(player.UserId)
	if not state then
		return false
	end
	if (state :: any).ftueStep ~= FtueConfig.Step.WaitDocksEquipmentShop then
		return false
	end
	if (state :: any).ftueFreeDocksDrillUsed == true then
		return false
	end
	return true
end

function EquipmentShopService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
end

function EquipmentShopService:_collectShopToolsOrdered(player: Player, itemId: string): { Tool }
	local list: { Tool } = {}
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		for _, ch in ipairs(bp:GetChildren()) do
			if ch:IsA("Tool") and isShopToolForItem(ch, itemId) then
				table.insert(list, ch)
			end
		end
	end
	local char = player.Character
	if char then
		for _, ch in ipairs(char:GetChildren()) do
			if ch:IsA("Tool") and isShopToolForItem(ch, itemId) then
				table.insert(list, ch)
			end
		end
	end
	return list
end

function EquipmentShopService:_applyShopToolAttrs(clone: Tool, item: any, stackCount: number)
	clone:SetAttribute("EquipmentItemId", item.id)
	clone:SetAttribute("EquipmentShopConsumable", true)
	clone:SetAttribute("ToolKind", item.toolKind)
	if item.tier ~= nil then
		clone:SetAttribute("Tier", item.tier)
	else
		clone:SetAttribute("Tier", nil)
	end
	clone:SetAttribute(STACK_ATTR, math.max(1, floorPositive(stackCount)))
end

function EquipmentShopService:_findExistingShopToolForMerge(player: Player, itemId: string): Tool?
	local char = player.Character
	if char then
		for _, ch in ipairs(char:GetChildren()) do
			if ch:IsA("Tool") and isShopToolForItem(ch, itemId) then
				return ch
			end
		end
	end
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		for _, ch in ipairs(bp:GetChildren()) do
			if ch:IsA("Tool") and isShopToolForItem(ch, itemId) then
				return ch
			end
		end
	end
	return nil
end

function EquipmentShopService:_seedingCountsFromInventory(player: Player)
	local state = self._oilStateService:GetState(player.UserId)
	if not state or state.equipmentOwnedNeedsInventoryBackfill ~= true then
		return
	end
	local found: { [string]: number } = {}
	local function scan(container: Instance?)
		if not container then
			return
		end
		for _, ch in ipairs(container:GetChildren()) do
			if ch:IsA("Tool") and ch:GetAttribute("EquipmentShopConsumable") == true then
				local id = ch:GetAttribute("EquipmentItemId")
				if typeof(id) == "string" and id ~= "" then
					found[id] = (found[id] or 0) + stackUnitsOnTool(ch :: Tool)
				end
			end
		end
	end
	scan(player.Character)
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		scan(bp)
	end
	for id, c in pairs(found) do
		state.equipmentOwnedByItemId[id] = math.max(state.equipmentOwnedByItemId[id] or 0, c)
	end
	self._oilStateService:MarkEquipmentInventoryBackfillComplete(player.UserId)
end

function EquipmentShopService:_reconcileOwnedShopTools(player: Player)
	if not self._running then
		return
	end
	self:_seedingCountsFromInventory(player)
	local state = self._oilStateService:GetState(player.UserId)
	if not state then
		return
	end
	local folder = self._templateFolder
	for _, item in ipairs(EquipmentShopConfig.Items) do
		local id = item.id
		local target = state.equipmentOwnedByItemId[id] or 0
		local tools = self:_collectShopToolsOrdered(player, id)

		if target <= 0 then
			for _, t in ipairs(tools) do
				t:Destroy()
			end
			continue
		end

		if not folder then
			continue
		end
		local template = folder:FindFirstChild(item.toolTemplateName)
		if not template or not template:IsA("Tool") then
			continue
		end

		local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 8)
		if not backpack or not backpack:IsA("Backpack") then
			continue
		end

		if #tools == 0 then
			local clone = template:Clone()
			self:_applyShopToolAttrs(clone, item, target)
			clone.Parent = backpack
		else
			local survivor = tools[1]
			for i = 2, #tools do
				tools[i]:Destroy()
			end
			survivor:SetAttribute(STACK_ATTR, target)
		end
	end
end

function EquipmentShopService:_findItem(itemId: string)
	for _, item in ipairs(EquipmentShopConfig.Items) do
		if item.id == itemId then
			return item
		end
	end
	return nil
end

function EquipmentShopService:GetCatalogForClient(player: Player)
	local rows = {}
	for _, item in ipairs(EquipmentShopConfig.Items) do
		local templateAvailable = false
		local folder = self._templateFolder
		if folder then
			local t = folder:FindFirstChild(item.toolTemplateName)
			templateAvailable = t ~= nil and t:IsA("Tool")
		end
		local stockCount = self._currentStock[item.id]
		local isRotating = stockCount ~= nil
		--- FTUE one-shot free dock drill: force this row to **$0** AND treat it as
		--- in stock so the rotation roll (`drill_t3 = { min = 0, max = 1 }`) can't
		--- strand the player on this leg. Both the cost and the `available` flag
		--- are mirrored to the live `_handlePurchase` checks below.
		local cost = item.cost
		local ftueFreeOverride = self:_isFtueFreeDocksDrillPurchase(player, item.id)
		if ftueFreeOverride then
			cost = 0
		end
		-- `available` = buyable right now (template present AND, if rotating, stock > 0).
		local available = templateAvailable and (ftueFreeOverride or not isRotating or stockCount > 0)
		table.insert(rows, {
			id = item.id,
			displayName = item.displayName,
			cost = cost,
			toolTemplateName = item.toolTemplateName,
			toolKind = item.toolKind,
			tier = item.tier,
			subtitle = item.subtitle,
			available = available,
			stock = if ftueFreeOverride then nil else stockCount, -- hide stock during FTUE freebie
			-- Per-rotation cap (the `hi` `rollShopStock` rolled against). Mirrors
			-- the FTUE override on `stock` so we don't render "X / 1" while the
			-- freebie row hides its current count.
			stockMax = if ftueFreeOverride then nil else self._currentStockMax[item.id],
		})
	end
	return {
		items = rows,
		templateFolderName = EquipmentShopConfig.TemplateFolderName,
		maxQuantityPerPurchase = EquipmentShopConfig.MaxQuantityPerPurchase,
		refreshEndsAt = self._refreshEndsAt,
	}
end

function EquipmentShopService:_sendOilAction(player: Player, ok: boolean, code: string, message: string, data: any?)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function EquipmentShopService:_handlePurchase(player: Player, payload: any)
	if typeof(payload) ~= "table" or typeof(payload.itemId) ~= "string" then
		if RunService:IsStudio() then
			warn("[EquipmentShopService] invalid payload from ", player.Name, " ", payload)
		end
		self:_sendOilAction(player, false, ErrorCodes.InvalidPayload, "Missing itemId.")
		return
	end

	-- Idempotency: drop retries / double-fires that carry the same requestId.
	-- Silent drop (no sendOilAction) so the legitimate first request's response
	-- is the only one the client sees.
	if typeof(payload.requestId) == "string" and payload.requestId ~= "" then
		if isDuplicateRequestId(self, player.UserId, payload.requestId) then
			return
		end
	end

	local itemId = payload.itemId :: string
	local qty = floorPositive(tonumber(payload.quantity) or 1)
	if qty < 1 then
		self:_sendOilAction(player, false, ErrorCodes.EquipmentQuantity, "Quantity must be at least 1.")
		return
	end
	if qty > EquipmentShopConfig.MaxQuantityPerPurchase then
		self:_sendOilAction(player, false, ErrorCodes.EquipmentQuantity, "Quantity too high.")
		return
	end

	local item = self:_findItem(itemId)
	if not item then
		self:_sendOilAction(player, false, ErrorCodes.EquipmentNotFound, "Item not in shop catalog.")
		return
	end

	local folder = self._templateFolder
	if not folder then
		self:_sendOilAction(player, false, ErrorCodes.EquipmentTemplateMissing, "Shop templates folder not set up.")
		return
	end

	local template = folder:FindFirstChild(item.toolTemplateName)
	if not template or not template:IsA("Tool") then
		self:_sendOilAction(
			player,
			false,
			ErrorCodes.EquipmentTemplateMissing,
			string.format("Template %q is missing or not a Tool.", item.toolTemplateName)
		)
		return
	end

	--- FTUE freebie gate: while on `WaitDocksEquipmentShop`, the configured drill
	--- (`FtueConfig.FtueDocksFreeDrillItemId`) is **free** and **bypasses rotation
	--- stock** so the rotation roll cannot strand the player. Limited to **qty=1**
	--- per leg (one-shot via `ftueFreeDocksDrillUsed`); any extras on the same
	--- click follow the normal price + stock path.
	local ftueFreeQty = 0
	if qty > 0 and self:_isFtueFreeDocksDrillPurchase(player, itemId) then
		ftueFreeQty = 1
	end
	local paidQty = qty - ftueFreeQty
	local totalCost = item.cost * paidQty
	if totalCost < 0 or totalCost ~= totalCost then
		self:_sendOilAction(player, false, ErrorCodes.Unknown, "Invalid item cost.")
		return
	end

	-- Rotating-shop stock check. Only gate items listed in the rotation; items
	-- absent from `_currentStock` are treated as always-available (future-proofing).
	-- The FTUE freebie unit (`ftueFreeQty`) is exempt from this check.
	local stockCount = self._currentStock[itemId]
	local isRotating = stockCount ~= nil
	if isRotating and stockCount < paidQty then
		self:_sendOilAction(player, false, ErrorCodes.EquipmentOutOfStock, "That item is sold out this rotation.", {
			itemId = itemId,
			stockRemaining = stockCount,
			refreshEndsAt = self._refreshEndsAt,
		})
		return
	end

	if not self._oilStateService:TrySpendCash(player.UserId, totalCost) then
		if RunService:IsStudio() then
			warn("[EquipmentShopService] TrySpendCash failed ", player.Name, " item=", itemId, " cost=", totalCost)
		end
		self:_sendOilAction(player, false, ErrorCodes.NotEnoughCash, "Not enough cash.")
		return
	end

	-- Reserve the stock now so a concurrent request can't double-allocate the
	-- last unit. Refunded below if backpack-grant fails. Only the **paid** units
	-- consume rotation stock; the FTUE freebie does not.
	if isRotating then
		self._currentStock[itemId] = stockCount - paidQty
	end

	local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack or not backpack:IsA("Backpack") then
		-- Refund — `skipMultiplier = true` so a DoubleEarnings owner doesn't
		-- get back 2x the equipment's cost when the backpack-grant fails.
		self._oilStateService:AddCash(player.UserId, totalCost, { skipMultiplier = true })
		if isRotating then
			self._currentStock[itemId] = (self._currentStock[itemId] or 0) + paidQty
		end
		self:_sendOilAction(player, false, ErrorCodes.Unknown, "Backpack not ready.")
		return
	end

	self._oilStateService:AddShopEquipmentOwned(player.UserId, item.id, qty)

	local existing = self:_findExistingShopToolForMerge(player, item.id)
	if existing then
		local cur = stackUnitsOnTool(existing)
		existing:SetAttribute(STACK_ATTR, cur + qty)
	else
		local clone = template:Clone()
		self:_applyShopToolAttrs(clone, item, qty)
		clone.Parent = backpack
	end

	--- FTUE one-shot consumption: stamp the flag **before** notifying the FTUE
	--- service so any same-frame catalog re-fetch / duplicate purchase can no
	--- longer read this row as the freebie.
	if ftueFreeQty > 0 then
		local oilState = self._oilStateService
		if oilState and typeof((oilState :: any).GetState) == "function" then
			local st = (oilState :: any):GetState(player.UserId)
			if st then
				(st :: any).ftueFreeDocksDrillUsed = true
				if typeof((oilState :: any)._markDirty) == "function" then
					(oilState :: any):_markDirty(player.UserId)
				end
			end
		end
	end

	self._oilStateService:PushState(player.UserId)

	if isRotating then
		self:_broadcastStock()
	end

	if RunService:IsStudio() then
		print("[EquipmentShopService] bought ", qty, "×", item.displayName, " for ", player.Name, " ($", totalCost, ")")
	end
	self:_sendOilAction(player, true, ErrorCodes.Ok, string.format("Bought %d × %s.", qty, item.displayName), {
		itemId = item.id,
		quantity = qty,
		totalCost = totalCost,
	})

	--- FTUE step advance: notify after the inventory + state are committed so the
	--- next step transition (`WaitDocksUpgradeShip` + `Dockman` sub-step) is
	--- driven from a consistent server snapshot.
	if ftueFreeQty > 0 and self._ftueService and typeof((self._ftueService :: any).OnFtueEquipmentShopPurchase) == "function" then
		(self._ftueService :: any):OnFtueEquipmentShopPurchase(player, item.id)
	end
end

--- FTUE / rewards: add owned shop stacks without charging cash; clones or merges into Backpack like a purchase.
function EquipmentShopService:GrantFreeOwnedEquipment(player: Player, itemId: string, qty: number)
	if not self._running then
		return
	end
	if typeof(itemId) ~= "string" or itemId == "" or qty < 1 then
		return
	end
	local item = self:_findItem(itemId)
	if not item then
		warn("[EquipmentShopService] GrantFreeOwnedEquipment: unknown itemId ", itemId)
		return
	end
	local folder = self._templateFolder
	if not folder then
		warn("[EquipmentShopService] GrantFreeOwnedEquipment: no ServerStorage template folder")
		return
	end
	local template = folder:FindFirstChild(item.toolTemplateName)
	if not template or not template:IsA("Tool") then
		warn(
			string.format(
				"[EquipmentShopService] GrantFreeOwnedEquipment: missing Tool template %q",
				tostring(item.toolTemplateName)
			)
		)
		return
	end
	self._oilStateService:AddShopEquipmentOwned(player.UserId, itemId, qty)
	self:_reconcileOwnedShopTools(player)
	self._oilStateService:PushState(player.UserId)
end

--- Inject `MonetizationService` from `init.server.luau` and register the
--- global `Equipment` grant handler so Robux bundles (e.g. the Starter
--- Pack `drill_t5 x2` sub-grant) land here. Returning `(false, code)`
--- causes the parent `_grantBundle` to log a warn and continue with the
--- other sub-grants — see `MonetizationService:_grantBundle` for the
--- best-effort policy.
function EquipmentShopService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end
	monetizationService:SetEquipmentHandler(function(userId: number, itemId: string, quantity: number): (boolean, string?)
		if not self._running then
			return false, "ERR_EQUIPMENT_SHOP_NOT_RUNNING"
		end
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			return false, "ERR_EQUIPMENT_BUYER_OFFLINE"
		end
		local item = self:_findItem(itemId)
		if not item then
			return false, "ERR_EQUIPMENT_UNKNOWN_ITEM"
		end
		local folder = self._templateFolder
		if not folder then
			return false, "ERR_EQUIPMENT_NO_TEMPLATE_FOLDER"
		end
		local template = folder:FindFirstChild(item.toolTemplateName)
		if not template or not template:IsA("Tool") then
			return false, "ERR_EQUIPMENT_MISSING_TEMPLATE"
		end
		-- Reuse the canonical grant path so backpack reconciliation + state
		-- push behave identically to the FTUE / dev-grant flows.
		self:GrantFreeOwnedEquipment(player, itemId, quantity)
		return true, nil
	end)
end

return EquipmentShopService
