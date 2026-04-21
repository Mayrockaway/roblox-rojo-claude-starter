--!strict
-- Sell oil / warehouse modal (`StarterGui.SellOilPanelGui` → `PlayerGui`).
-- Stored counts = warehouse barrels; prices from `MarketPriceUpdate` / `RequestMarketSnapshot`.
-- `WarehouseHeader.WarehouseTitle` = strait **`WarehouseService`** used/total capacity (`WarehouseStateUpdate`).
-- Crude (Tier 1) row = `Crude` only (no blending of refined / premium product).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local StepperHold = require(script.Parent.Parent:WaitForChild("StepperHold"))
local FtueDispatchPointerSignals = require(script.Parent.Parent:WaitForChild("FtueDispatchPointerSignals"))
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
}
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()

local SCREEN_NAME = "SellOilPanelGui"

type RowUiConfig = { kind: "crude" } | { kind: "tier", tier: string }

-- Studio row `Frame` names → tier mapping. Canonical names only after the
-- holistic Crude/Refined/Premium rename. Renamed rows can still resolve via
-- the `SellOilTier` attribute or `TypeName` text (see `resolveRowUiConfig`).
local ROW_UI: { [string]: RowUiConfig } = {
	OilSellRowCrude = { kind = "crude" },
	OilSellRowRefined = { kind = "tier", tier = "Refined" },
	OilSellRowPremium = { kind = "tier", tier = "Premium" },
}

--- TotalsPanel subtotal row `Frame` names by **warehouse tier** (rows are looked up by tier, not oil-row frame name).
local SUBTOTAL_NAMES_BY_TIER: { [string]: { string } } = {
	Crude = { "SubtotalCrude" },
	Refined = { "SubtotalRefined" },
	Premium = { "SubtotalPremium" },
}

local TIER_KEYS = { "Crude", "Refined", "Premium" }

local SellOilPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}

local ERROR_NOTIFICATION_NAME = "ErrorNotification"

local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

--- Studio-authored ephemeral red label, located anywhere under the panel
--- (canonically `Canvas.PanelHost.ErrorNotification`). Runtime ONLY mutates
--- `Text` / `Visible` / `TextTransparency` — appearance + placement stay 1:1
--- with the Studio placeholder. If Studio hasn't authored one, we surface
--- a single warn so it's caught (no fabricated fallback that drifts visually).
local function findStudioErrorNotificationLabel(screen: ScreenGui): TextLabel?
	local found = screen:FindFirstChild(ERROR_NOTIFICATION_NAME, true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
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
		tierKey = "Crude"
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
	if a == "Crude" then
		return { kind = "crude" }
	elseif a == "Refined" then
		return { kind = "tier", tier = "Refined" }
	elseif a == "Premium" then
		return { kind = "tier", tier = "Premium" }
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
		if tierKey == "Crude" then
			return { kind = "crude" }
		elseif tierKey == "Refined" then
			return { kind = "tier", tier = "Refined" }
		elseif tierKey == "Premium" then
			return { kind = "tier", tier = "Premium" }
		end
	end
	return nil
end

local function dataTierForRowConfig(cfg: RowUiConfig): string
	if cfg.kind == "crude" then
		return "Crude"
	end
	return cfg.tier
end

local rowBindings: { RowBinding } = {}

local warehouseBarrelsByTier: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}

local pricesByTier: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}

local selected: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}

local totalProfitLabel: TextLabel? = nil
local warehouseTitleLabel: TextLabel? = nil
local warehouseStoredTotal = 0
local warehouseCapTotal = 0
local hasWarehouseTotals = false
local sellButton: GuiButton? = nil
local sellAllButton: GuiButton? = nil
-- Shared debounce: both `SellConfirmButton` and `SellAllConfirmButton` hit the
-- same `requestSellWarehouseBarrels` remote, so a single floor stops a quick
-- toggle between the two from double-firing the server.
local lastSellFire = 0.0

--- Last values sent to FTUE pointer sequencing (debounced).
local lastFtueSellPeekOpen: boolean? = nil
local lastFtueSellPeekBarrels: number? = nil

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
	return maxBarrelsInWarehouseForTier("Crude")
end

local function crudeBlendSelected(): number
	return selected.Crude or 0
end

local function sumSelectedSellBarrels(): number
	return crudeBlendSelected() + (selected.Refined or 0) + (selected.Premium or 0)
end

local function sumWarehouseBarrelsAll(): number
	local n = 0
	for _, k in ipairs(TIER_KEYS) do
		n += math.max(0, math.floor(warehouseBarrelsByTier[k] or 0))
	end
	return n
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
	local wH = maxBarrelsInWarehouseForTier("Crude")
	local h = math.min(selected.Crude or 0, wH)
	selected.Crude = h
end

local function clampSelectionsToInventory()
	for _, k in ipairs({ "Refined", "Premium" }) do
		local inv = maxBarrelsInWarehouseForTier(k)
		if (selected[k] or 0) > inv then
			selected[k] = inv
		end
	end
	clampCrudeSelectionToWarehouse()
end

local function crudeDisplayPriceText(): string
	local pH = pricesByTier.Crude or 0
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
		return (selected.Crude or 0) * (pricesByTier.Crude or 0)
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

--- Wired AmountLabel TextBoxes → manifest tier key (Crude for crude row).
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
	if sellAllButton then
		-- "SELL ALL" is gated on warehouse contents, not on the per-tier
		-- selection, so a player can liquidate everything in one tap without
		-- first ticking each row up to its stored amount. Visual dim mirrors
		-- the regular Sell button so the two read as paired CTAs.
		local total = sumWarehouseBarrelsAll()
		sellAllButton.Active = true
		sellAllButton.AutoButtonColor = total > 0
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
	bumpTier("Crude", delta)
end

local function trySell()
	local h = selected.Crude or 0
	local ls, pr = selected.Refined or 0, selected.Premium or 0
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
	UiSfx.playKaching()
	ClientRemotes.requestSellWarehouseBarrels:FireServer({
		Crude = h,
		Refined = ls,
		Premium = pr,
	})
end

local function trySellAll()
	-- Liquidate every barrel currently in the warehouse, ignoring per-row
	-- selections. The server (`requestSellWarehouseBarrels` handler) already
	-- clamps incoming counts to the player's actual stored amounts and is
	-- the price-of-record, so the worst that can happen if our local
	-- snapshot is mid-update (e.g. a payload arrived during this frame) is
	-- the server sells slightly less than we asked for — never more, never
	-- the wrong tier. After the sell resolves, `oilActionResult` zeros the
	-- selections + closes the panel via the same path as the regular Sell
	-- button, so there's no second cleanup pass needed here.
	local h = math.max(0, math.floor(warehouseBarrelsByTier.Crude or 0))
	local ls = math.max(0, math.floor(warehouseBarrelsByTier.Refined or 0))
	local pr = math.max(0, math.floor(warehouseBarrelsByTier.Premium or 0))
	if h + ls + pr <= 0 then
		UiSfx.playUiDenied()
		showErrorNotification("Warehouse is empty.", 4)
		return
	end
	local now = os.clock()
	if now - lastSellFire < 0.45 then
		return
	end
	lastSellFire = now
	UiSfx.playKaching()
	ClientRemotes.requestSellWarehouseBarrels:FireServer({
		Crude = h,
		Refined = ls,
		Premium = pr,
	})
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
	sellAllButton = nil
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

	-- Studio authors `ErrorNotification` somewhere under the panel
	-- (canonically `Canvas.PanelHost.ErrorNotification`) with `Visible = true`
	-- so it can be positioned + restyled in Edit mode. We hide on wire and
	-- only swap `.Text` at runtime — placement + look stay 1:1 with Studio.
	errorNotificationLabel = findStudioErrorNotificationLabel(screen)
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
		errorNotificationLabel.TextTransparency = 0
	else
		warn(
			"[SellOilPanel] No `ErrorNotification` TextLabel found under "
				.. screen:GetFullName()
				.. " — author one in Studio (recommended path: Canvas.PanelHost.ErrorNotification). Errors will be silent until added."
		)
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
		-- Studio-authored "SELL ALL" sibling of `SellConfirmButton`. Optional —
		-- if a build of the panel doesn't have it yet we just skip wiring (no
		-- warn) so legacy panels keep working with only the per-row Sell.
		local btnAll = footer:FindFirstChild("SellAllConfirmButton", true)
		if btnAll and btnAll:IsA("GuiButton") then
			sellAllButton = btnAll
		end
	end

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
				tierForAmount = "Crude"
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
				StepperHold.bind(bind.minus, function()
					bumpCrudeBlend(-1)
				end, connections)
				StepperHold.bind(bind.plus, function()
					bumpCrudeBlend(1)
				end, connections)
				if amt:IsA("TextBox") then
					table.insert(connections, amt.FocusLost:Connect(function()
						applyTypedSellTier("Crude", amt.Text)
					end))
				end
			elseif cfg.kind == "tier" then
				local tier = cfg.tier
				StepperHold.bind(bind.minus, function()
					bumpTier(tier, -1)
				end, connections)
				StepperHold.bind(bind.plus, function()
					bumpTier(tier, 1)
				end, connections)
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
	if sellAllButton then
		table.insert(connections, sellAllButton.Activated:Connect(trySellAll))
	end

	table.insert(connections, ClientRemotes.warehouseStateUpdate.OnClientEvent:Connect(function(data: any)
		if mergeWarehouseFromPayload(data) then
			clampSelectionsToInventory()
			refreshRowUi()
		end
	end))

	table.insert(connections, ClientRemotes.marketPriceUpdate.OnClientEvent:Connect(function(data: any)
		if mergePricesFromMarketSnapshot(data) then
			refreshRowUi()
		end
	end))

	table.insert(connections, ClientRemotes.oilActionResult.OnClientEvent:Connect(function(payload: any)
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

	do
		local ok, data = pcall(function()
			return ClientRemotes.requestWarehouseSnapshot:InvokeServer()
		end)
		if ok then
			mergeWarehouseFromPayload(data)
		end
	end

	do
		local ok, data = pcall(function()
			return ClientRemotes.requestMarketSnapshot:InvokeServer()
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
