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
local EquipmentShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("EquipmentShopConfig"))
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
			toolKind = item.toolKind,
			tier = item.tier,
			subtitle = item.subtitle,
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
		if RunService:IsStudio() then
			warn("[EquipmentShopService] invalid payload from ", player.Name, " ", payload)
		end
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
		if RunService:IsStudio() then
			warn("[EquipmentShopService] TrySpendCash failed ", player.Name, " item=", itemId, " cost=", totalCost)
		end
		self:_sendOilAction(player, false, ErrorCodes.NotEnoughCash, "Not enough cash.")
		return
	end

	local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack or not backpack:IsA("Backpack") then
		self._oilStateService:AddCash(player.UserId, totalCost)
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

	self._oilStateService:PushState(player.UserId)

	if RunService:IsStudio() then
		print("[EquipmentShopService] bought ", qty, "×", item.displayName, " for ", player.Name, " ($", totalCost, ")")
	end
	self:_sendOilAction(player, true, ErrorCodes.Ok, string.format("Bought %d × %s.", qty, item.displayName), {
		itemId = item.id,
		quantity = qty,
		totalCost = totalCost,
	})
end

return EquipmentShopService
