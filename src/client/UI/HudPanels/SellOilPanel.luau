--!strict
-- Sell oil / warehouse modal (`StarterGui.SellOilPanelGui` → `PlayerGui`).
-- Stored counts = warehouse barrels; prices from `MarketPriceUpdate` / `RequestMarketSnapshot`.
-- Heavy crude row = `HeavyCrude` only (all sub–light-sweet product).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "SellOilPanelGui"

type RowUiConfig = { kind: "crude" } | { kind: "tier", tier: string }

-- Row `Frame` names: prefer **`OilSellRowHeavyCrude`**, **`OilSellRowLightSweet`**, **`OilSellRowPremiumRefined`** in Studio; legacy names remain wired.
local ROW_UI: { [string]: RowUiConfig } = {
	OilSellRowHeavyCrude = { kind = "crude" },
	OilSellRowCrude = { kind = "crude" },
	OilSellRowHeavy = { kind = "crude" },
	OilSellRowLightSweet = { kind = "tier", tier = "LightSweet" },
	OilSellRowLight = { kind = "tier", tier = "LightSweet" },
	OilSellRowPremiumRefined = { kind = "tier", tier = "PremiumRefined" },
	OilSellRowStandard = { kind = "tier", tier = "PremiumRefined" },
}

local SUBTOTAL_FRAME_NAMES: { [string]: { string } } = {
	OilSellRowHeavyCrude = { "SubtotalHeavyCrude", "SubtotalCrude", "SubtotalHeavy" },
	OilSellRowCrude = { "SubtotalHeavyCrude", "SubtotalCrude", "SubtotalHeavy" },
	OilSellRowHeavy = { "SubtotalHeavyCrude", "SubtotalCrude", "SubtotalHeavy" },
	OilSellRowLightSweet = { "SubtotalLightSweet", "SubtotalLight" },
	OilSellRowLight = { "SubtotalLightSweet", "SubtotalLight" },
	OilSellRowPremiumRefined = { "SubtotalPremiumRefined", "SubtotalPremium", "SubtotalStandard" },
	OilSellRowStandard = { "SubtotalPremiumRefined", "SubtotalPremium", "SubtotalStandard" },
}

local TIER_KEYS = { "HeavyCrude", "LightSweet", "PremiumRefined" }

local function rowTypeTitle(rowName: string): string?
	local cfg = ROW_UI[rowName]
	if not cfg then
		return nil
	end
	if cfg.kind == "crude" then
		return QualityConfig.hudShortLabel("HeavyCrude")
	end
	if cfg.kind == "tier" then
		return QualityConfig.hudShortLabel(cfg.tier)
	end
	return nil
end

local SellOilPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}

type RowBinding = {
	kind: "crude" | "tier",
	tier: string?,
	rowName: string,
	typeNameLabel: TextLabel?,
	storedLabel: TextLabel,
	priceLabel: TextLabel,
	amountLabel: TextLabel,
	minus: GuiButton,
	plus: GuiButton,
	subtotalRight: TextLabel?,
}

local rowBindings: { RowBinding } = {}

local warehouseBarrelsByTier: { [string]: number } = {
	HeavyCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
}

local pricesByTier: { [string]: number } = {
	HeavyCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
}

local selected: { [string]: number } = {
	HeavyCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
}

local totalProfitLabel: TextLabel? = nil
local sellButton: GuiButton? = nil
local requestSellWarehouseBarrels: RemoteEvent? = nil
local lastSellFire = 0.0

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

local function mergeWarehouseFromPayload(data: any): boolean
	if typeof(data) ~= "table" or typeof(data.barrels) ~= "table" then
		return false
	end
	local b = data.barrels :: { [string]: any }
	for _, k in ipairs(TIER_KEYS) do
		warehouseBarrelsByTier[k] = math.max(0, math.floor(tonumber(b[k]) or 0))
	end
	return true
end

local function mergePricesFromMarketSnapshot(data: any): boolean
	if typeof(data) ~= "table" or typeof(data.prices) ~= "table" then
		return false
	end
	local p = data.prices :: { [string]: any }
	for _, k in ipairs(TIER_KEYS) do
		pricesByTier[k] = math.max(0, math.floor(tonumber(p[k]) or 0))
	end
	return true
end

local function maxBarrelsInWarehouseForTier(tier: string): number
	return math.max(0, math.floor(warehouseBarrelsByTier[tier] or 0))
end

local function maxCrudeWarehouseBarrels(): number
	return maxBarrelsInWarehouseForTier("HeavyCrude")
end

local function crudeBlendSelected(): number
	return selected.HeavyCrude or 0
end

local function clampCrudeSelectionToWarehouse()
	local wH = maxBarrelsInWarehouseForTier("HeavyCrude")
	local h = math.min(selected.HeavyCrude or 0, wH)
	selected.HeavyCrude = h
end

local function clampSelectionsToInventory()
	for _, k in ipairs({ "LightSweet", "PremiumRefined" }) do
		local inv = maxBarrelsInWarehouseForTier(k)
		if (selected[k] or 0) > inv then
			selected[k] = inv
		end
	end
	clampCrudeSelectionToWarehouse()
end

local function crudeDisplayPriceText(): string
	local pH = pricesByTier.HeavyCrude or 0
	if pH <= 0 then
		return "$—/bbl"
	end
	return string.format("$%d/bbl", pH)
end

local function rowPriceText(bind: RowBinding): string
	if bind.kind == "crude" then
		return crudeDisplayPriceText()
	elseif bind.kind == "tier" and bind.tier then
		local p = pricesByTier[bind.tier] or 0
		if p <= 0 then
			return "$—/bbl"
		end
		return string.format("$%d/bbl", p)
	end
	return "$—/bbl"
end

local function subtotalDollarsForRow(bind: RowBinding): number
	if bind.kind == "crude" then
		return (selected.HeavyCrude or 0) * (pricesByTier.HeavyCrude or 0)
	elseif bind.kind == "tier" and bind.tier then
		local t = bind.tier
		return (selected[t] or 0) * (pricesByTier[t] or 0)
	end
	return 0
end

local function totalSelectedPayout(): number
	local t = 0
	for _, bind in ipairs(rowBindings) do
		t += subtotalDollarsForRow(bind)
	end
	return t
end

local function findSubtotalRight(totalsPanel: Instance?, rowName: string): TextLabel?
	if not totalsPanel then
		return nil
	end
	local names = SUBTOTAL_FRAME_NAMES[rowName]
	if not names then
		return nil
	end
	for _, frameName in ipairs(names) do
		local row = totalsPanel:FindFirstChild(frameName, true)
		if row then
			local rt = row:FindFirstChild("RightText", true)
			if rt and rt:IsA("TextLabel") then
				return rt
			end
		end
	end
	return nil
end

local function refreshRowUi()
	for _, bind in ipairs(rowBindings) do
		bind.priceLabel.Text = rowPriceText(bind)
		if bind.kind == "crude" then
			local inv = maxCrudeWarehouseBarrels()
			bind.storedLabel.Text = string.format("Stored: %d barrels", inv)
			clampCrudeSelectionToWarehouse()
			bind.amountLabel.Text = tostring(crudeBlendSelected())
		elseif bind.kind == "tier" and bind.tier then
			local tier = bind.tier
			local inv = maxBarrelsInWarehouseForTier(tier)
			bind.storedLabel.Text = string.format("Stored: %d barrels", inv)
			local s = math.min(selected[tier] or 0, inv)
			selected[tier] = s
			bind.amountLabel.Text = tostring(s)
		end
		if bind.typeNameLabel then
			local title = rowTypeTitle(bind.rowName)
			if title then
				bind.typeNameLabel.Text = title
			end
		end
		if bind.subtotalRight then
			bind.subtotalRight.Text = string.format("$%d", subtotalDollarsForRow(bind))
		end
	end
	if totalProfitLabel then
		totalProfitLabel.Text = string.format("$%d", totalSelectedPayout())
	end
	if sellButton then
		local n = crudeBlendSelected() + (selected.LightSweet or 0) + (selected.PremiumRefined or 0)
		sellButton.Active = n > 0
		sellButton.AutoButtonColor = n > 0
	end
end

local function bumpTier(tier: string, delta: number)
	local inv = maxBarrelsInWarehouseForTier(tier)
	local cur = selected[tier] or 0
	local nextSel = cur + delta
	if nextSel < 0 or nextSel > inv then
		return
	end
	selected[tier] = nextSel
	refreshRowUi()
end

local function bumpCrudeBlend(delta: number)
	bumpTier("HeavyCrude", delta)
end

local function trySell()
	local now = os.clock()
	if now - lastSellFire < 0.45 then
		return
	end
	lastSellFire = now
	local h = selected.HeavyCrude or 0
	local ls, pr = selected.LightSweet or 0, selected.PremiumRefined or 0
	if h + ls + pr <= 0 then
		return
	end
	local ev = requestSellWarehouseBarrels
	if ev then
		ev:FireServer({
			HeavyCrude = h,
			LightSweet = ls,
			PremiumRefined = pr,
		})
	end
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(rowBindings)
	totalProfitLabel = nil
	sellButton = nil
	requestSellWarehouseBarrels = nil
	wiredScreen = nil
end

local function wireSellOil(screen: ScreenGui)
	if wiredScreen == screen then
		return
	end
	disconnectAll()
	wiredScreen = screen

	local panel = screen:FindFirstChild("Panel", true)
	local body = panel and panel:FindFirstChild("Body", true)
	local content = body and body:FindFirstChild("Content", true)
	local oilRows = content and content:FindFirstChild("OilRows")
	local summaryStrip = content and content:FindFirstChild("SummaryStrip", true)
	local totalsPanel = summaryStrip and summaryStrip:FindFirstChild("TotalsPanel", true)
	if totalsPanel then
		local totalRow = totalsPanel:FindFirstChild("TotalSaleRow", true)
			or totalsPanel:FindFirstChild("TotalProfitRow", true)
		if totalRow then
			local tr = totalRow:FindFirstChild("RightText", true)
			if tr and tr:IsA("TextLabel") then
				totalProfitLabel = tr
			end
		end
	end
	local footer = body and body:FindFirstChild("Footer", true)
	if footer then
		local btn = footer:FindFirstChild("SellConfirmButton", true)
		if btn and btn:IsA("GuiButton") then
			sellButton = btn
		end
	end

	local rf = remotesFolder()
	requestSellWarehouseBarrels = rf:WaitForChild(RemoteNames.RequestSellWarehouseBarrels) :: RemoteEvent

	local crudeRowWired = false
	if oilRows and oilRows:IsA("Instance") then
		for _, ch in ipairs(oilRows:GetChildren()) do
			if not ch:IsA("GuiObject") then
				continue
			end
			local cfg = ROW_UI[ch.Name]
			if not cfg then
				continue
			end
			if cfg.kind == "crude" then
				if crudeRowWired then
					continue
				end
				crudeRowWired = true
			end
			local infoCol = ch:FindFirstChild("InfoColumn", true)
			local typeName = infoCol and infoCol:FindFirstChild("TypeName", true)
			local stored = infoCol and infoCol:FindFirstChild("StoredLabel", true)
			local priceLabel = ch:FindFirstChild("PriceLabel", true)
			local stepper = ch:FindFirstChild("Stepper", true)
			if not (stored and stored:IsA("TextLabel") and priceLabel and priceLabel:IsA("TextLabel") and stepper) then
				continue
			end
			local minus = stepper:FindFirstChild("MinusButton", true)
			local plus = stepper:FindFirstChild("PlusButton", true)
			local amt = stepper:FindFirstChild("AmountLabel", true)
			if not (minus and minus:IsA("GuiButton") and plus and plus:IsA("GuiButton") and amt and amt:IsA("TextLabel")) then
				continue
			end
			local bind: RowBinding = {
				kind = cfg.kind,
				tier = if cfg.kind == "tier" then cfg.tier else nil,
				rowName = ch.Name,
				typeNameLabel = if typeName and typeName:IsA("TextLabel") then typeName :: TextLabel else nil,
				storedLabel = stored :: TextLabel,
				priceLabel = priceLabel :: TextLabel,
				amountLabel = amt :: TextLabel,
				minus = minus :: GuiButton,
				plus = plus :: GuiButton,
				subtotalRight = findSubtotalRight(totalsPanel, ch.Name),
			}
			table.insert(rowBindings, bind)
			if cfg.kind == "crude" then
				table.insert(connections, bind.minus.Activated:Connect(function()
					bumpCrudeBlend(-1)
				end))
				table.insert(connections, bind.plus.Activated:Connect(function()
					bumpCrudeBlend(1)
				end))
			elseif cfg.kind == "tier" then
				local tier = cfg.tier
				table.insert(connections, bind.minus.Activated:Connect(function()
					bumpTier(tier, -1)
				end))
				table.insert(connections, bind.plus.Activated:Connect(function()
					bumpTier(tier, 1)
				end))
			end
		end
	end

	if sellButton then
		table.insert(connections, sellButton.Activated:Connect(trySell))
	end

	local whUp = rf:WaitForChild(RemoteNames.WarehouseStateUpdate) :: RemoteEvent
	table.insert(connections, whUp.OnClientEvent:Connect(function(data: any)
		if mergeWarehouseFromPayload(data) then
			clampSelectionsToInventory()
			refreshRowUi()
		end
	end))

	local mktUp = rf:WaitForChild(RemoteNames.MarketPriceUpdate) :: RemoteEvent
	table.insert(connections, mktUp.OnClientEvent:Connect(function(data: any)
		if mergePricesFromMarketSnapshot(data) then
			refreshRowUi()
		end
	end))

	local oilResult = rf:WaitForChild(RemoteNames.OilActionResult) :: RemoteEvent
	table.insert(connections, oilResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.ok ~= true then
			return
		end
		local data = (payload :: any).data
		if typeof(data) == "table" and typeof(data.shipmentId) == "string" then
			return
		end
		for _, k in ipairs(TIER_KEYS) do
			selected[k] = 0
		end
		refreshRowUi()
	end))

	local snapWh = rf:FindFirstChild(RemoteNames.RequestWarehouseSnapshot)
	if snapWh and snapWh:IsA("RemoteFunction") then
		local ok, data = pcall(function()
			return (snapWh :: RemoteFunction):InvokeServer()
		end)
		if ok then
			mergeWarehouseFromPayload(data)
		end
	end

	local snapMkt = rf:FindFirstChild(RemoteNames.RequestMarketSnapshot)
	if snapMkt and snapMkt:IsA("RemoteFunction") then
		local ok, data = pcall(function()
			return (snapMkt :: RemoteFunction):InvokeServer()
		end)
		if ok then
			mergePricesFromMarketSnapshot(data)
		end
	end

	clampSelectionsToInventory()
	refreshRowUi()
end

function SellOilPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	wireSellOil(ctrl.ScreenGui)
	return ctrl
end

function SellOilPanel.screenName(): string
	return SCREEN_NAME
end

return SellOilPanel
