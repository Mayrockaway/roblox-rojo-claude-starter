--!strict
-- Equipment shop modal (`StarterGui.ShopPanelGui` → `PlayerGui`).
-- Studio layout: `…ShopScroll.ScrollContent.EquipmentSection` with
-- `DRILLSBlock.DRILLSRow` (Low/Medium/High StyleCard), `COLLECTORSBlock.COLLECTORSRow`, and
-- `ProspectorPipesBlock.ProspectorPipesRow` (FieldProspectorHalfCard, HeavyPipeHalfCard).
-- Catalog + purchase: `RequestEquipmentShopCatalog` / `RequestPurchaseEquipment` + `OilActionResult`.
--
-- Slots are re-resolved every time the panel opens so late-cloned StarterGui / layout changes still wire.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local EquipmentShopPopulate = require(script.Parent.EquipmentShopPopulate)

local SCREEN_NAME = "ShopPanelGui"

type CatalogItem = {
	id: string,
	displayName: string,
	cost: number,
	toolTemplateName: string,
	toolKind: string?,
	tier: string?,
	subtitle: string?,
	available: boolean,
}

type CatalogPayload = {
	items: { CatalogItem },
	templateFolderName: string,
	maxQuantityPerPurchase: number,
}

type Slot = { card: GuiObject, itemId: string }

local EquipmentShopPanel = {}

--- Child labels *and* nested `TextButton` "BUY" chrome are `GuiObject`s with `Active = true` by default; they
--- steal hits so the parent `ImageButton` never sees `Activated`. Disable `Active` on **all** descendants.
local function passthroughBuyDecorations(buy: GuiButton)
	for _, d in ipairs(buy:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Active = false
		end
	end
end

local lastPurchaseAttempt = 0.0
local PURCHASE_DEBOUNCE_SEC = 0.35

local function firePurchase(requestPurchase: RemoteEvent, itemId: string)
	local now = os.clock()
	if now - lastPurchaseAttempt < PURCHASE_DEBOUNCE_SEC then
		return
	end
	lastPurchaseAttempt = now
	requestPurchase:FireServer({ itemId = itemId, quantity = 1 })
end

local function waitRemotesFolder(): Folder
	local rf = Shared:FindFirstChild("Remotes")
	while rf == nil or not rf:IsA("Folder") do
		task.wait(0.1)
		rf = Shared:FindFirstChild("Remotes")
	end
	return rf
end

--- Resolve equipment cards under this ScreenGui (recursive so minor hierarchy drift still works).
local function resolveEquipmentSlots(screen: ScreenGui): { Slot }
	local slots: { Slot } = {}
	local es = screen:FindFirstChild("EquipmentSection", true)
	if not (es and es:IsA("GuiObject")) then
		return slots
	end

	local drillsBlock = es:FindFirstChild("DRILLSBlock", true)
	local drillsRow = drillsBlock and drillsBlock:FindFirstChild("DRILLSRow", true)
	if drillsRow and drillsRow:IsA("GuiObject") then
		-- Cards may sit under layout wrappers; `FindFirstChild` without recursive misses them.
		local low = drillsRow:FindFirstChild("LowStyleCard", true)
		local med = drillsRow:FindFirstChild("MediumStyleCard", true)
		local high = drillsRow:FindFirstChild("HighStyleCard", true)
		if low and low:IsA("GuiObject") then
			table.insert(slots, { card = low, itemId = "drill_t1" })
		end
		if med and med:IsA("GuiObject") then
			table.insert(slots, { card = med, itemId = "drill_t2" })
		end
		if high and high:IsA("GuiObject") then
			table.insert(slots, { card = high, itemId = "drill_t3" })
		end
	end

	local collectorsBlock = es:FindFirstChild("COLLECTORSBlock", true)
	local pumpsRow = collectorsBlock and collectorsBlock:FindFirstChild("COLLECTORSRow", true)
	if pumpsRow and pumpsRow:IsA("GuiObject") then
		local low = pumpsRow:FindFirstChild("LowStyleCard", true)
		local med = pumpsRow:FindFirstChild("MediumStyleCard", true)
		local high = pumpsRow:FindFirstChild("HighStyleCard", true)
		if low and low:IsA("GuiObject") then
			table.insert(slots, { card = low, itemId = "pump_t1" })
		end
		if med and med:IsA("GuiObject") then
			table.insert(slots, { card = med, itemId = "pump_t2" })
		end
		if high and high:IsA("GuiObject") then
			table.insert(slots, { card = high, itemId = "pump_t3" })
		end
	end

	local ppBlock = es:FindFirstChild("ProspectorPipesBlock", true)
	local ppRow = ppBlock and ppBlock:FindFirstChild("ProspectorPipesRow", true)
	if ppRow and ppRow:IsA("GuiObject") then
		local prospect = ppRow:FindFirstChild("FieldProspectorHalfCard", true)
		local pipe = ppRow:FindFirstChild("HeavyPipeHalfCard", true)
		if prospect and prospect:IsA("GuiObject") then
			table.insert(slots, { card = prospect, itemId = "prospector" })
		end
		if pipe and pipe:IsA("GuiObject") then
			table.insert(slots, { card = pipe, itemId = "pipe" })
		end
	end

	return slots
end

local function catalogById(payload: CatalogPayload?): { [string]: EquipmentShopPopulate.CatalogRow }
	local map: { [string]: EquipmentShopPopulate.CatalogRow } = {}
	if not payload or typeof(payload.items) ~= "table" then
		return map
	end
	for _, it in ipairs(payload.items) do
		if typeof(it) == "table" and typeof(it.id) == "string" then
			local avail = it.available == true
			local sub: string? = nil
			if typeof(it.subtitle) == "string" and it.subtitle ~= "" then
				sub = it.subtitle
			end
			map[it.id] = {
				id = it.id,
				displayName = typeof(it.displayName) == "string" and it.displayName or it.id,
				cost = math.max(0, math.floor(tonumber(it.cost) or 0)),
				available = avail,
				subtitle = sub,
			}
		end
	end
	return map
end

function EquipmentShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	local remotes = waitRemotesFolder()
	local requestCatalog = remotes:WaitForChild(RemoteNames.RequestEquipmentShopCatalog) :: RemoteFunction
	local requestPurchase = remotes:WaitForChild(RemoteNames.RequestPurchaseEquipment) :: RemoteEvent
	local oilActionResult = remotes:WaitForChild(RemoteNames.OilActionResult) :: RemoteEvent

	local screen = ctrl.ScreenGui
	local slotBuyConns: { RBXScriptConnection } = {}

	local function disconnectSlotBuys()
		for _, c in ipairs(slotBuyConns) do
			c:Disconnect()
		end
		table.clear(slotBuyConns)
	end

	local function refreshCatalog(slots: { Slot })
		local ok, payload = pcall(function()
			return requestCatalog:InvokeServer()
		end)
		if ok and typeof(payload) == "table" then
			local byId = catalogById(payload :: any)
			for _, slot in ipairs(slots) do
				local row = byId[slot.itemId]
				EquipmentShopPopulate.ApplyCard(slot.card, row)

				local buy = slot.card:FindFirstChild("BuyButton", true)
				if buy and buy:IsA("GuiButton") then
					passthroughBuyDecorations(buy)
					buy.AutoButtonColor = row ~= nil and row.available == true
					buy.Active = row ~= nil and row.available == true
				end
			end
		else
			warn("[EquipmentShopPanel] RequestEquipmentShopCatalog failed:", payload)
			for _, slot in ipairs(slots) do
				EquipmentShopPopulate.ApplyCard(slot.card, nil)
				local buy = slot.card:FindFirstChild("BuyButton", true)
				if buy and buy:IsA("GuiButton") then
					passthroughBuyDecorations(buy)
					buy.AutoButtonColor = false
					buy.Active = false
				end
			end
		end
	end

	local function wireSlotBuys(slots: { Slot })
		disconnectSlotBuys()
		for _, slot in ipairs(slots) do
			local buy = slot.card:FindFirstChild("BuyButton", true)
			if buy and buy:IsA("GuiButton") then
				passthroughBuyDecorations(buy)
				local itemId = slot.itemId
				local function onBuy()
					local id = slot.card:GetAttribute("EquipmentShopItemId")
					if typeof(id) ~= "string" or id == "" then
						id = itemId
					end
					firePurchase(requestPurchase, id)
				end
				table.insert(slotBuyConns, buy.Activated:Connect(onBuy))
				-- Some `ImageButton` + child setups only deliver mouse through `MouseButton1Click`.
				table.insert(slotBuyConns, buy.MouseButton1Click:Connect(onBuy))
			end
		end
	end

	-- Studio scripts (or other code) may set `ScreenGui.Enabled = true` without calling `ctrl.Open`.
	-- Refresh whenever this bound instance becomes visible so copy never stays on StarterGui defaults.
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not screen.Enabled then
			return
		end
		local slotsNow = resolveEquipmentSlots(screen)
		wireSlotBuys(slotsNow)
		refreshCatalog(slotsNow)
	end)

	-- `Enabled` does not fire if the modal was already visible when this bind ran.
	if screen.Enabled then
		task.defer(function()
			local slotsBoot = resolveEquipmentSlots(screen)
			wireSlotBuys(slotsBoot)
			refreshCatalog(slotsBoot)
		end)
	end

	oilActionResult.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" then
			return
		end
		local data = msg.data
		if typeof(data) == "table" and typeof(data.itemId) == "string" then
			local slotsNow = resolveEquipmentSlots(screen)
			if #slotsNow > 0 then
				refreshCatalog(slotsNow)
			end
		end
	end)

	local baseOpen = ctrl.Open
	ctrl.Open = function()
		local slotsNow = resolveEquipmentSlots(screen)
		if #slotsNow == 0 then
			warn(
				"[EquipmentShopPanel] No equipment cards found under ",
				screen:GetFullName(),
				" — expected descendant `EquipmentSection` with DRILLSRow / COLLECTORSRow / ProspectorPipesRow."
			)
		end
		wireSlotBuys(slotsNow)
		refreshCatalog(slotsNow)
		baseOpen()
	end

	return ctrl
end

function EquipmentShopPanel.screenName(): string
	return SCREEN_NAME
end

return EquipmentShopPanel
