--!strict
-- Sell oil / warehouse modal (`StarterGui.SellOilPanelGui` → `PlayerGui`).
-- Stored counts = warehouse barrels; prices from `MarketPriceUpdate` / `RequestMarketSnapshot`.
-- `WarehouseHeader.WarehouseTitle` = strait **`WarehouseService`** used/total capacity (`WarehouseStateUpdate`).
-- Heavy crude row = `HeavyCrude` only (all sub–light-sweet product).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local FtueDispatchPointerSignals = require(script.Parent.Parent:WaitForChild("FtueDispatchPointerSignals"))
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
}

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

--- TotalsPanel subtotal row `Frame` names by **warehouse tier** (not by oil row frame name — rows may be reordered/renamed in Studio).
local SUBTOTAL_NAMES_BY_TIER: { [string]: { string } } = {
	HeavyCrude = { "SubtotalHeavyCrude", "SubtotalCrude", "SubtotalHeavy" },
	LightSweet = { "SubtotalLightSweet", "SubtotalLight" },
	PremiumRefined = { "SubtotalPremiumRefined", "SubtotalPremium", "SubtotalStandard" },
}

local TIER_KEYS = { "HeavyCrude", "LightSweet", "PremiumRefined" }

local SellOilPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}

local STATUS_TOAST_TEXT_RED = Color3.fromRGB(220, 40, 40)
local ERROR_NOTIFICATION_NAME = "ErrorNotification"

local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

local function ensureErrorNotificationLabel(screen: ScreenGui): TextLabel?
	local canvas = screen:FindFirstChild("Canvas")
	if not canvas then
		return nil
	end
	local existing = canvas:FindFirstChild(ERROR_NOTIFICATION_NAME)
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local toast = Instance.new("TextLabel")
	toast.Name = ERROR_NOTIFICATION_NAME
	toast.BackgroundTransparency = 1
	toast.BorderSizePixel = 0
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 0.88, 0)
	toast.Size = UDim2.new(0.5, 0, 0, 0)
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.ZIndex = 50
	toast.Visible = false
	toast.Text = ""
	toast.TextColor3 = STATUS_TOAST_TEXT_RED
	toast.TextScaled = true
	toast.TextWrapped = true
	toast.Font = Enum.Font.Merriweather
	toast.TextXAlignment = Enum.TextXAlignment.Center
	toast.TextYAlignment = Enum.TextYAlignment.Bottom
	local tc = Instance.new("UITextSizeConstraint")
	tc.MaxTextSize = 22
	tc.MinTextSize = 10
	tc.Parent = toast
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(40, 10, 10)
	stroke.Thickness = 1.25
	stroke.Parent = toast
	toast.Parent = canvas
	return toast
end

local function hideErrorNotification()
	errorNotificationSeq += 1
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
	end
end

local function showErrorNotification(message: string, holdSeconds: number)
	local label = errorNotificationLabel
	if not label or not label.Parent then
		return
	end
	errorNotificationSeq += 1
	local seq = errorNotificationSeq
	label.Text = message
	label.TextTransparency = 0
	label.Visible = true
	task.delay(holdSeconds, function()
		if seq ~= errorNotificationSeq or not label.Parent then
			return
		end
		local tw = TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		})
		tw:Play()
		tw.Completed:Wait()
		if seq ~= errorNotificationSeq or not label.Parent then
			return
		end
		label.Visible = false
		label.TextTransparency = 0
	end)
end

type AmountField = TextLabel | TextBox

type RowBinding = {
	kind: "crude" | "tier",
	tier: string?,
	rowName: string,
	typeNameLabel: TextLabel?,
	storedLabel: TextLabel,
	priceLabel: TextLabel,
	amountField: AmountField,
	minus: GuiButton,
	plus: GuiButton,
	subtotalRight: TextLabel?,
}

local function rowDisplayTitle(bind: RowBinding): string?
	local tierKey: string?
	if bind.kind == "crude" then
		tierKey = "HeavyCrude"
	elseif bind.kind == "tier" and bind.tier then
		tierKey = bind.tier
	end
	if tierKey then
		local def = QualityConfig.Tiers[tierKey :: any]
		if def then
			return def.displayName
		end
	end
	return nil
end

local function inferTierKeyFromTypeNameText(text: string): string?
	local norm = string.lower((string.match(text, "^%s*(.-)%s*$") or text))
	for tierKey, def in pairs(QualityConfig.Tiers) do
		if norm == string.lower(def.displayName) or norm == string.lower(def.hudShortName) then
			return tierKey :: string
		end
	end
	return nil
end

--- `SellOilTier` on the row wins over `Name` so tier data matches visual order if frame names drift.
local function rowConfigFromSellOilTierAttr(a: string): RowUiConfig?
	if a == "HeavyCrude" then
		return { kind = "crude" }
	elseif a == "LightSweet" then
		return { kind = "tier", tier = "LightSweet" }
	elseif a == "PremiumRefined" then
		return { kind = "tier", tier = "PremiumRefined" }
	end
	return nil
end

--- Studio may rename row frames; resolve tier from **`SellOilTier`** attribute, **canonical names**, or **`TypeName`** text vs `QualityConfig.Tiers`.
local function resolveRowUiConfig(row: GuiObject): RowUiConfig?
	local attr = row:GetAttribute("SellOilTier")
	if typeof(attr) == "string" then
		local fromAttr = rowConfigFromSellOilTierAttr(attr :: string)
		if fromAttr then
			return fromAttr
		end
	end
	local byName = ROW_UI[row.Name]
	if byName then
		return byName
	end
	local infoCol = row:FindFirstChild("InfoColumn", true)
	local typeName = infoCol and infoCol:FindFirstChild("TypeName", true)
	if typeName and typeName:IsA("TextLabel") then
		local tierKey = inferTierKeyFromTypeNameText(typeName.Text)
		if tierKey == "HeavyCrude" then
			return { kind = "crude" }
		elseif tierKey == "LightSweet" then
			return { kind = "tier", tier = "LightSweet" }
		elseif tierKey == "PremiumRefined" then
			return { kind = "tier", tier = "PremiumRefined" }
		end
	end
	return nil
end

local function dataTierForRowConfig(cfg: RowUiConfig): string
	if cfg.kind == "crude" then
		return "HeavyCrude"
	end
	return cfg.tier
end

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
local warehouseTitleLabel: TextLabel? = nil
local warehouseStoredTotal = 0
local warehouseCapTotal = 0
local hasWarehouseTotals = false
local sellButton: GuiButton? = nil
local requestSellWarehouseBarrels: RemoteEvent? = nil
local lastSellFire = 0.0

--- Last values sent to FTUE pointer sequencing (debounced).
local lastFtueSellPeekOpen: boolean? = nil
local lastFtueSellPeekBarrels: number? = nil

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

local function mergeWarehouseTotalsFromPayload(data: any): boolean
	if typeof(data) ~= "table" then
		return false
	end
	local totRaw = (data :: any).totalBarrels
	local capRaw = (data :: any).capacity
	if totRaw == nil and capRaw == nil then
		return false
	end
	hasWarehouseTotals = true
	if typeof(totRaw) == "number" then
		warehouseStoredTotal = math.max(0, math.floor(totRaw))
	end
	if typeof(capRaw) == "number" then
		warehouseCapTotal = math.max(0, math.floor(capRaw))
	end
	return true
end

local function mergeWarehouseFromPayload(data: any): boolean
	local any = false
	if typeof(data) == "table" and typeof(data.barrels) == "table" then
		local b = data.barrels :: { [string]: any }
		for _, k in ipairs(TIER_KEYS) do
			warehouseBarrelsByTier[k] = math.max(0, math.floor(tonumber(b[k]) or 0))
		end
		any = true
	end
	if mergeWarehouseTotalsFromPayload(data) then
		any = true
	end
	return any
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

local function sumSelectedSellBarrels(): number
	return crudeBlendSelected() + (selected.LightSweet or 0) + (selected.PremiumRefined or 0)
end

--- For `FtueUiPointers` during the **Sell** FTUE step.
function SellOilPanel.peekOpenAndBarrelsForSellFtue(): (boolean, number)
	if not wiredScreen or not wiredScreen.Parent then
		return false, 0
	end
	return wiredScreen.Enabled, sumSelectedSellBarrels()
end

local function maybeFireFtueSellPointerRefresh()
	if not wiredScreen then
		return
	end
	local open = wiredScreen.Enabled
	local barrels = sumSelectedSellBarrels()
	if lastFtueSellPeekOpen == open and lastFtueSellPeekBarrels == barrels then
		return
	end
	lastFtueSellPeekOpen = open
	lastFtueSellPeekBarrels = barrels
	FtueDispatchPointerSignals.fireSellOilUiChanged()
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

local function parseUnsignedBarrelInput(text: string): number
	local n = tonumber(text)
	if n == nil then
		local digits = string.match(text, "%d+")
		n = digits and tonumber(digits) or 0
	end
	return math.max(0, math.floor(n :: number))
end

local function setAmountFieldText(field: AmountField, value: number)
	local t = tostring(value)
	if field:IsA("TextBox") then
		field.Text = t
	else
		(field :: TextLabel).Text = t
	end
end

--- Wired AmountLabel TextBoxes → manifest tier key (HeavyCrude for crude row).
local sellAmountTextBoxTier: { [TextBox]: string } = {}

local function findSubtotalRight(totalsPanel: Instance?, dataTier: string): TextLabel?
	if not totalsPanel then
		return nil
	end
	local names = SUBTOTAL_NAMES_BY_TIER[dataTier]
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

--- Matches authored `StoredLabel` gold; `SELL_OIL_PANEL.md` accent ~212, 178, 122.
local FALLBACK_STORED_LABEL_GOLD = Color3.fromRGB(212, 178, 122)

local function storedLabelGoldForTitle(): Color3
	for _, bind in ipairs(rowBindings) do
		if bind.storedLabel.Parent then
			return bind.storedLabel.TextColor3
		end
	end
	return FALLBACK_STORED_LABEL_GOLD
end

local function color3ToRichTextHex(c: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.clamp(math.floor(c.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.B * 255 + 0.5), 0, 255)
	)
end

local function refreshWarehouseTitle()
	if not warehouseTitleLabel then
		return
	end
	warehouseTitleLabel.RichText = true
	local hex = color3ToRichTextHex(storedLabelGoldForTitle())
	if hasWarehouseTotals then
		warehouseTitleLabel.Text = string.format(
			'Warehouse <font color="%s">%d/%d</font>',
			hex,
			warehouseStoredTotal,
			warehouseCapTotal
		)
	else
		warehouseTitleLabel.Text = string.format('Warehouse <font color="%s">—/—</font>', hex)
	end
end

local function refreshRowUi()
	clampSelectionsToInventory()
	for _, bind in ipairs(rowBindings) do
		bind.priceLabel.Text = rowPriceText(bind)
		if bind.kind == "crude" then
			local inv = maxCrudeWarehouseBarrels()
			bind.storedLabel.Text = string.format("Stored: %d barrels", inv)
			clampCrudeSelectionToWarehouse()
			setAmountFieldText(bind.amountField, crudeBlendSelected())
		elseif bind.kind == "tier" and bind.tier then
			local tier = bind.tier
			local inv = maxBarrelsInWarehouseForTier(tier)
			bind.storedLabel.Text = string.format("Stored: %d barrels", inv)
			local s = math.min(selected[tier] or 0, inv)
			selected[tier] = s
			setAmountFieldText(bind.amountField, s)
		end
		if bind.typeNameLabel then
			local title = rowDisplayTitle(bind)
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
		local n = sumSelectedSellBarrels()
		sellButton.Active = true
		sellButton.AutoButtonColor = n > 0
	end
	refreshWarehouseTitle()
	maybeFireFtueSellPointerRefresh()
end

local function applyTypedSellTier(tier: string, raw: string)
	local want = parseUnsignedBarrelInput(raw)
	local inv = maxBarrelsInWarehouseForTier(tier)
	selected[tier] = math.min(want, inv)
	clampSelectionsToInventory()
	refreshRowUi()
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
	local h = selected.HeavyCrude or 0
	local ls, pr = selected.LightSweet or 0, selected.PremiumRefined or 0
	if h + ls + pr <= 0 then
		UiSfx.playUiDenied()
		showErrorNotification("Select at least one barrel to sell.", 4)
		return
	end
	local now = os.clock()
	if now - lastSellFire < 0.45 then
		return
	end
	lastSellFire = now
	local ev = requestSellWarehouseBarrels
	if ev then
		UiSfx.playKaching()
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
	table.clear(sellAmountTextBoxTier)
	totalProfitLabel = nil
	warehouseTitleLabel = nil
	warehouseStoredTotal = 0
	warehouseCapTotal = 0
	hasWarehouseTotals = false
	sellButton = nil
	requestSellWarehouseBarrels = nil
	wiredScreen = nil
	lastFtueSellPeekOpen = nil
	lastFtueSellPeekBarrels = nil
	hideErrorNotification()
	errorNotificationLabel = nil
end

local function wireSellOil(screen: ScreenGui, closePanel: (() -> ())?)
	if wiredScreen == screen then
		return
	end
	disconnectAll()
	wiredScreen = screen

	errorNotificationLabel = ensureErrorNotificationLabel(screen)
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
		errorNotificationLabel.TextTransparency = 0
	end

	local panel = screen:FindFirstChild("Panel", true)
	local body = panel and panel:FindFirstChild("Body", true)
	local whHeader = body and body:FindFirstChild("WarehouseHeader", true)
	local whTitle = whHeader and whHeader:FindFirstChild("WarehouseTitle", true)
	if whTitle and whTitle:IsA("TextLabel") then
		warehouseTitleLabel = whTitle
	end
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
		local rowCandidates: { { ch: GuiObject, cfg: RowUiConfig } } = {}
		for _, ch in ipairs(oilRows:GetChildren()) do
			if not ch:IsA("GuiObject") then
				continue
			end
			local cfg = resolveRowUiConfig(ch)
			if not cfg then
				continue
			end
			table.insert(rowCandidates, { ch = ch, cfg = cfg })
		end
		table.sort(rowCandidates, function(a, b)
			if a.ch.LayoutOrder ~= b.ch.LayoutOrder then
				return a.ch.LayoutOrder < b.ch.LayoutOrder
			end
			return a.ch.Name < b.ch.Name
		end)
		for _, entry in ipairs(rowCandidates) do
			local ch = entry.ch
			local cfg = entry.cfg
			if cfg.kind == "crude" then
				if crudeRowWired then
					continue
				end
				crudeRowWired = true
			end
			local infoCol = ch:FindFirstChild("InfoColumn", true)
			local typeName = infoCol and infoCol:FindFirstChild("TypeName", true)
			local stored = ch:FindFirstChild("StoredLabel", true)
				or (infoCol and infoCol:FindFirstChild("StoredLabel", true))
			local priceLabel = ch:FindFirstChild("PriceLabel", true)
			local stepper = ch:FindFirstChild("Stepper", true)
			if not (stored and stored:IsA("TextLabel") and priceLabel and priceLabel:IsA("TextLabel") and stepper) then
				continue
			end
			local minus = stepper:FindFirstChild("MinusButton", true)
			local plus = stepper:FindFirstChild("PlusButton", true)
			local amt = stepper:FindFirstChild("AmountLabel", true)
			if not (minus and minus:IsA("GuiButton") and plus and plus:IsA("GuiButton") and amt) then
				continue
			end
			if not (amt:IsA("TextBox") or amt:IsA("TextLabel")) then
				continue
			end
			local amountField = amt :: AmountField
			local tierForAmount: string
			if cfg.kind == "crude" then
				tierForAmount = "HeavyCrude"
			else
				tierForAmount = cfg.tier :: string
			end
			if amt:IsA("TextBox") then
				amt.ClearTextOnFocus = false
				sellAmountTextBoxTier[amt :: TextBox] = tierForAmount
			end
			local dataTier = dataTierForRowConfig(cfg)
			local bind: RowBinding = {
				kind = cfg.kind,
				tier = if cfg.kind == "tier" then cfg.tier else nil,
				rowName = ch.Name,
				typeNameLabel = if typeName and typeName:IsA("TextLabel") then typeName :: TextLabel else nil,
				storedLabel = stored :: TextLabel,
				priceLabel = priceLabel :: TextLabel,
				amountField = amountField,
				minus = minus :: GuiButton,
				plus = plus :: GuiButton,
				subtotalRight = findSubtotalRight(totalsPanel, dataTier),
			}
			table.insert(rowBindings, bind)
			if cfg.kind == "crude" then
				table.insert(connections, bind.minus.Activated:Connect(function()
					bumpCrudeBlend(-1)
				end))
				table.insert(connections, bind.plus.Activated:Connect(function()
					bumpCrudeBlend(1)
				end))
				if amt:IsA("TextBox") then
					table.insert(connections, amt.FocusLost:Connect(function()
						applyTypedSellTier("HeavyCrude", amt.Text)
					end))
				end
			elseif cfg.kind == "tier" then
				local tier = cfg.tier
				table.insert(connections, bind.minus.Activated:Connect(function()
					bumpTier(tier, -1)
				end))
				table.insert(connections, bind.plus.Activated:Connect(function()
					bumpTier(tier, 1)
				end))
				if amt:IsA("TextBox") then
					table.insert(connections, amt.FocusLost:Connect(function()
						applyTypedSellTier(tier, amt.Text)
					end))
				end
			end
		end
	end

	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode ~= Enum.KeyCode.Return and input.KeyCode ~= Enum.KeyCode.KeypadEnter then
			return
		end
		local tb = UserInputService:GetFocusedTextBox()
		if not tb then
			return
		end
		local tKey = sellAmountTextBoxTier[tb]
		if not tKey then
			return
		end
		applyTypedSellTier(tKey, tb.Text)
		tb:ReleaseFocus()
	end))

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
		hideErrorNotification()
		for _, k in ipairs(TIER_KEYS) do
			selected[k] = 0
		end
		refreshRowUi()
		if wiredScreen == screen and screen.Enabled and closePanel then
			closePanel()
		end
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

	table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		maybeFireFtueSellPointerRefresh()
	end))
	maybeFireFtueSellPointerRefresh()
end

function SellOilPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	wireSellOil(ctrl.ScreenGui, function()
		ctrl.Close()
	end)
	return ctrl
end

function SellOilPanel.screenName(): string
	return SCREEN_NAME
end

return SellOilPanel
