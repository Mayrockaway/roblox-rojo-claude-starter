--!strict
-- Equipment shop modal (`StarterGui.ShopPanelGui` → `PlayerGui`).
--
-- Cards are *cloned* per item from Studio-authored `Templates.<Cat>CardTemplate`
-- via `EquipmentShopPopulate.PopulateAllCategories`, driven by the category
-- registry in `ShopPanelTemplates.Categories` (today: DRILLS only). Designers
-- add a new section by stamping `ShopCategory` on a row + template and
-- registering the category in `ShopPanelTemplates.luau` — no code change here.
--
-- Catalog + purchase: `RequestEquipmentShopCatalog` / `RequestPurchaseEquipment` + `OilActionResult`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local EquipmentHotbarController = require(script.Parent.Parent:WaitForChild("EquipmentHotbarController"))
local EquipmentShopPopulate = require(script.Parent.EquipmentShopPopulate)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playKaching: () -> (),
}

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
	stock: number?,
	--- Per-rotation cap the server actually rolled against (scales with player
	--- count via `band.perPlayer`). Drives the "X / N" max in the UI; falls
	--- back to `band.max` client-side if the server didn't send one.
	stockMax: number?,
}

type CatalogPayload = {
	items: { CatalogItem },
	templateFolderName: string,
	maxQuantityPerPurchase: number,
	refreshEndsAt: number?,
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

local HttpService = game:GetService("HttpService")

local lastPurchaseAttempt = 0.0
local PURCHASE_DEBOUNCE_SEC = 0.35

local function firePurchase(requestPurchase: RemoteEvent, itemId: string)
	local now = os.clock()
	if now - lastPurchaseAttempt < PURCHASE_DEBOUNCE_SEC then
		return
	end
	lastPurchaseAttempt = now
	requestPurchase:FireServer({
		itemId = itemId,
		quantity = 1,
		requestId = HttpService:GenerateGUID(false),
	})
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
			local stock: number? = nil
			if typeof(it.stock) == "number" then
				stock = math.max(0, math.floor(it.stock))
			end
			local stockMax: number? = nil
			if typeof(it.stockMax) == "number" then
				stockMax = math.max(0, math.floor(it.stockMax))
			end
			map[it.id] = {
				id = it.id,
				displayName = typeof(it.displayName) == "string" and it.displayName or it.id,
				cost = math.max(0, math.floor(tonumber(it.cost) or 0)),
				available = avail,
				subtitle = sub,
				stock = stock,
				stockMax = stockMax,
			}
		end
	end
	return map
end

--- Roblox's `AutomaticCanvasSize.Y` is unreliable on deeply nested
--- `AutomaticSize` chains (the auto-size solver can lock in at a value where
--- `canvas == window` and never grow even after children are added).
--- We drive `CanvasSize.Y` explicitly from `ScrollContent.UIListLayout
--- .AbsoluteContentSize`, which is updated every time the layout re-measures.
--- Returns the connection so the caller can disconnect on cleanup if needed.
local function bindManualCanvasSize(scroll: ScrollingFrame): RBXScriptConnection?
	local content = scroll:FindFirstChild("ScrollContent")
	if not (content and content:IsA("GuiObject")) then
		return nil
	end
	local layout = content:FindFirstChildOfClass("UIListLayout")
	if not layout then
		return nil
	end
	local pad = content:FindFirstChildOfClass("UIPadding")
	-- Take over from AutomaticCanvasSize so the two systems don't fight.
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	local function recompute()
		local h = layout.AbsoluteContentSize.Y
		if pad then
			-- We only sum the offset components — scale paddings on
			-- auto-sized parents are unreliable and intentionally not authored.
			h = h + pad.PaddingTop.Offset + pad.PaddingBottom.Offset
		end
		scroll.CanvasSize = UDim2.new(0, 0, 0, math.ceil(h))
	end
	recompute()
	-- Re-measure one frame later to catch post-clone settling.
	task.defer(recompute)
	return layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(recompute)
end

function EquipmentShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	local ClientRemotes = getClientRemotes()
	local requestCatalog = ClientRemotes.requestEquipmentShopCatalog
	local requestPurchase = ClientRemotes.requestPurchaseEquipment
	local oilActionResult = ClientRemotes.oilActionResult
	local stockUpdate = ClientRemotes.equipmentShopStockUpdate

	local screen = ctrl.ScreenGui
	local slotBuyConns: { RBXScriptConnection } = {}
	local refreshEndsAt = 0.0

	-- Force `ShopScroll.CanvasSize.Y` to follow `ScrollContent`'s real layout
	-- height. AutoCanvasSize was leaving canvas == window even after 6 cards
	-- were cloned in, so the scrollbar never appeared.
	local shopScroll = screen:FindFirstChild("ShopScroll", true)
	if shopScroll and shopScroll:IsA("ScrollingFrame") then
		bindManualCanvasSize(shopScroll)
	end

	-- Studio-authored `ShopRefreshTimer` (Frame with `IsTimerLabel = true` +
	-- `TimeChildName = "TimeText"` attributes) takes priority over the legacy
	-- injected `RotationCountdown` — we update its TimeText label directly.
	local studioTimerLabel: TextLabel? = nil
	local studioTimerFormat = "%d:%02d"
	for _, d in ipairs(screen:GetDescendants()) do
		if d:GetAttribute("IsTimerLabel") == true then
			local childName = d:GetAttribute("TimeChildName")
			local fmt = d:GetAttribute("TimeFormat")
			if typeof(fmt) == "string" and fmt ~= "" then
				studioTimerFormat = fmt
			end
			if typeof(childName) == "string" and childName ~= "" then
				local tl = d:FindFirstChild(childName, true)
				if tl and tl:IsA("TextLabel") then
					studioTimerLabel = tl
					break
				end
			elseif d:IsA("TextLabel") then
				studioTimerLabel = d
				break
			end
		end
	end

	local function wireSlotBuys(slots: { Slot })
		for _, c in ipairs(slotBuyConns) do
			c:Disconnect()
		end
		table.clear(slotBuyConns)
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
				-- Bind ONLY `Activated` — covers mouse, touch, gamepad. Dual
				-- binding with `MouseButton1Click` caused same-frame double-fire
				-- → double-charge on purchase.
				table.insert(slotBuyConns, buy.Activated:Connect(onBuy))
			end
		end
	end

	--- One-shot: pull catalog from server, clone+populate every category row,
	--- and (re)wire buy buttons on the resulting card list.
	local function refreshAndPopulate()
		local ok, payload = pcall(function()
			return requestCatalog:InvokeServer()
		end)
		local byId: { [string]: EquipmentShopPopulate.CatalogRow }
		if ok and typeof(payload) == "table" then
			if typeof((payload :: any).refreshEndsAt) == "number" then
				refreshEndsAt = (payload :: any).refreshEndsAt
			end
			byId = catalogById(payload :: any)
		else
			if not ok then
				warn("[EquipmentShopPanel] RequestEquipmentShopCatalog failed:", payload)
			end
			byId = {}
		end
		local slots = EquipmentShopPopulate.PopulateAllCategories(screen, byId)
		-- Disable Active on cards whose server row is missing/unavailable so
		-- ImageButton.Activated never fires on placeholders.
		for _, slot in ipairs(slots) do
			local row = byId[slot.itemId]
			local available = row ~= nil and row.available == true
			local buy = slot.card:FindFirstChild("BuyButton", true)
			if buy and buy:IsA("GuiButton") then
				buy.AutoButtonColor = available
				buy.Active = available
			end
		end
		wireSlotBuys(slots)
	end

	-- Stock broadcast from server: fires on every rotation refresh and every
	-- successful purchase. Re-populate so stock counts + buy state rebuild.
	stockUpdate.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) == "table" and typeof(msg.refreshEndsAt) == "number" then
			refreshEndsAt = msg.refreshEndsAt
		end
		if screen.Enabled then
			refreshAndPopulate()
		end
	end)

	-- Countdown heartbeat: ticks once per second while the panel is open and
	-- the Studio-authored `ShopRefreshTimer.TimeText` exists. The label keeps
	-- whatever it was last set to between Open/Close cycles (it's hidden with
	-- the panel anyway).
	if studioTimerLabel then
		task.spawn(function()
			while studioTimerLabel and studioTimerLabel.Parent do
				if screen.Enabled and refreshEndsAt > 0 then
					local remaining = math.max(0, refreshEndsAt - workspace:GetServerTimeNow())
					local m = math.floor(remaining / 60)
					local s = math.floor(remaining - m * 60)
					studioTimerLabel.Text = string.format(studioTimerFormat, m, s)
				end
				task.wait(1.0)
			end
		end)
	end

	-- Studio scripts (or other code) may set `ScreenGui.Enabled = true` without calling `ctrl.Open`.
	-- Re-populate whenever this bound instance becomes visible so cards rebuild from the latest catalog.
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not screen.Enabled then
			--- FTUE equipment-shop leg: closing the modal *after* the free Tier 3
			--- drill is purchased advances the player to the dockman leg
			--- (`WaitDocksUpgradeShip`). Server validates step + sub-step before
			--- transitioning so this fire is harmless outside the FTUE.
			local plr = Players.LocalPlayer
			if
				plr
				and plr:GetAttribute(Constants.FtueStepAttribute) == FtueConfig.Step.WaitDocksEquipmentShop
				and plr:GetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute) == "ClosePanel"
			then
				ClientRemotes.requestFtueDocksProgress:FireServer("EquipmentShopPanelClosed")
			end
			return
		end
		refreshAndPopulate()
	end)

	-- `Enabled` does not fire if the modal was already visible when this bind ran.
	if screen.Enabled then
		task.defer(refreshAndPopulate)
	end

	oilActionResult.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" then
			return
		end
		local data = msg.data
		if typeof(data) == "table" and typeof(data.itemId) == "string" then
			if screen.Enabled then
				refreshAndPopulate()
			end
			-- Purchase can merge stacks (**no `ChildAdded`**) or replicate a tick late — force hotbar sync.
			if msg.ok == true then
				UiSfx.playKaching()
				EquipmentHotbarController.requestRebuild()
			end
		end
	end)

	local baseOpen = ctrl.Open
	ctrl.Open = function()
		refreshAndPopulate()
		baseOpen()
	end

	return ctrl
end

function EquipmentShopPanel.screenName(): string
	return SCREEN_NAME
end

return EquipmentShopPanel
