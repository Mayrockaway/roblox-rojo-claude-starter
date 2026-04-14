--!strict
-- Server-authoritative consumable equipment: spend plot cash (`OilStateService`), clone `Tool`
-- templates from **ServerStorage → `EquipmentShopConfig.TemplateFolderName`**, parent to **Backpack**.
-- Client shop UI: call `RequestEquipmentShopCatalog` then `RequestPurchaseEquipment` with `{ itemId, quantity? }`.
-- Results mirror other oil flows via **`OilActionResult`** (`ok`, `code`, `message`, optional `data`).

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EquipmentShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("EquipmentShopConfig"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local EquipmentShopService = {}

local function floorPositive(n: number): number
	return math.max(0, math.floor(n))
end

function EquipmentShopService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
	self._running = false
	self._templateFolder = nil :: Folder?
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
end

function EquipmentShopService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
end

function EquipmentShopService:_findItem(itemId: string)
	for _, item in ipairs(EquipmentShopConfig.Items) do
		if item.id == itemId then
			return item
		end
	end
	return nil
end

function EquipmentShopService:GetCatalogForClient(_player: Player)
	local rows = {}
	for _, item in ipairs(EquipmentShopConfig.Items) do
		local available = false
		local folder = self._templateFolder
		if folder then
			local t = folder:FindFirstChild(item.toolTemplateName)
			available = t ~= nil and t:IsA("Tool")
		end
		table.insert(rows, {
			id = item.id,
			displayName = item.displayName,
			cost = item.cost,
			toolTemplateName = item.toolTemplateName,
			available = available,
		})
	end
	return {
		items = rows,
		templateFolderName = EquipmentShopConfig.TemplateFolderName,
		maxQuantityPerPurchase = EquipmentShopConfig.MaxQuantityPerPurchase,
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
		self:_sendOilAction(player, false, ErrorCodes.InvalidPayload, "Missing itemId.")
		return
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

	local totalCost = item.cost * qty
	if totalCost < 0 or totalCost ~= totalCost then
		self:_sendOilAction(player, false, ErrorCodes.Unknown, "Invalid item cost.")
		return
	end

	if not self._oilStateService:TrySpendCash(player.UserId, totalCost) then
		self:_sendOilAction(player, false, ErrorCodes.NotEnoughCash, "Not enough cash.")
		return
	end

	local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack or not backpack:IsA("Folder") then
		self._oilStateService:AddCash(player.UserId, totalCost)
		self:_sendOilAction(player, false, ErrorCodes.Unknown, "Backpack not ready.")
		return
	end

	local granted = 0
	for _ = 1, qty do
		local clone = template:Clone()
		clone:SetAttribute("EquipmentItemId", item.id)
		clone:SetAttribute("EquipmentShopConsumable", true)
		clone.Parent = backpack
		granted += 1
	end

	self._oilStateService:PushState(player.UserId)

	self:_sendOilAction(player, true, ErrorCodes.Ok, string.format("Bought %d × %s.", granted, item.displayName), {
		itemId = item.id,
		quantity = granted,
		totalCost = totalCost,
	})
end

return EquipmentShopService
