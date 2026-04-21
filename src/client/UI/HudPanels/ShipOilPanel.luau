--!strict
-- Ship oil cargo modal (`StarterGui.ShipOilPanelGui` → `PlayerGui`).
-- Cargo rows = refinery/plot storage (`OilStateService` `oilByTier`). `WarehouseCapacityLabel` = strait **`WarehouseService`** totals (`WarehouseStateUpdate`).
-- UI counts whole barrels; manifest uses oil units (`barrels selected * PerBarrelOil`) to match `ConsumeManifest`.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local InstantSellConfig = require(Shared:WaitForChild("Config"):WaitForChild("InstantSellConfig"))
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local StepperHold = require(script.Parent.Parent:WaitForChild("StepperHold"))
local FtueDispatchPointerSignals = require(script.Parent.Parent:WaitForChild("FtueDispatchPointerSignals"))
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
}

local SCREEN_NAME = "ShipOilPanelGui"

--- Entire panel uses Merriweather (Studio defaults may differ; applied once when wired).
local PANEL_FONT = Enum.Font.Merriweather

--- Canvas-level `ErrorNotification` (reusable name; not in `Body` / `Footer` — does not affect layout).
local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

local function applyMerriweatherToPanelText(root: ScreenGui)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			d.Font = PANEL_FONT
		end
	end
end

--- Studio-authored ephemeral red label, located anywhere under the panel
--- (canonically `Canvas.PanelHost.ErrorNotification`). Runtime ONLY mutates
--- `Text` / `Visible` / `TextTransparency` — appearance + placement stay 1:1
--- with the Studio placeholder. If Studio hasn't authored one, we surface
--- a single warn so it's caught (no fabricated fallback that drifts visually).
local ERROR_NOTIFICATION_NAME = "ErrorNotification"

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

--- Deny SFX on failed dispatch (no button color flash — authored `ImageButton` visuals rarely use `BackgroundColor3`).
local function playDispatchShipmentButtonFailTween()
	UiSfx.playUiDenied()
end

-- Studio row `Frame` names → manifest tier keys. Canonical names only after the
-- holistic Crude/Refined/Premium rename. Renamed rows can still be resolved via
-- the `ShipOilTier` attribute or the row's title label (see `resolveRowTierKey`).
local ROW_NAME_TO_TIER: { [string]: string } = {
	ShipCargoRowCrude = "Crude",
	ShipCargoRowRefined = "Refined",
	ShipCargoRowPremium = "Premium",
}

local TIER_KEYS = { "Crude", "Refined", "Premium" }

local function inferTierKeyFromLabelText(text: string): string?
	local norm = string.lower((string.match(text, "^%s*(.-)%s*$") or text))
	for tierKey, def in pairs(QualityConfig.Tiers) do
		if norm == string.lower(def.displayName) or norm == string.lower(def.hudShortName) then
			return tierKey :: string
		end
	end
	return nil
end

--- Text used in Studio for the oil type (before script may overwrite with full `displayName`).
--- Prefer the row's **`NameColumn`** first text label (works regardless of tier-specific
--- title names like **`CrudeTitle`** / **`RefinedTitle`** / **`PremiumTitle`**); fall back
--- to legacy `TypeName`.
local function cargoTierLabelText(row: GuiObject): string?
	local nameCol = row:FindFirstChild("NameColumn", true)
	if nameCol then
		local tl = nameCol:FindFirstChildWhichIsA("TextLabel", true)
		if tl and tl:IsA("TextLabel") then
			return tl.Text
		end
	end
	local typeName = row:FindFirstChild("TypeName", true)
	if typeName and typeName:IsA("TextLabel") then
		return typeName.Text
	end
	return nil
end

--- Resolve warehouse tier when row frames are renamed: canonical **`ShipCargoRow*`** names, optional **`ShipOilTier`** attribute, or label text vs **`QualityConfig.Tiers`**.
local function resolveRowTierKey(row: GuiObject): string?
	local byName = ROW_NAME_TO_TIER[row.Name]
	if byName then
		return byName
	end
	local attr = row:GetAttribute("ShipOilTier")
	if typeof(attr) == "string" then
		local a = attr :: string
		for _, k in ipairs(TIER_KEYS) do
			if a == k then
				return k
			end
		end
	end
	local raw = cargoTierLabelText(row)
	if raw then
		return inferTierKeyFromLabelText(raw)
	end
	return nil
end

local ShipOilPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
type AmountField = TextLabel | TextBox

local rowBindings: { [string]: {
	tier: string,
	inventoryLabel: TextLabel,
	amountField: AmountField,
	minus: GuiButton,
	plus: GuiButton,
} } = {}

-- Raw oil units at home refinery (same keys / semantics as `OilStateService` server state).
local refineryOilByTier: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}

local latestResolved: {
	capacity: number,
}? = nil

local function perBarrelOilUnits(): number
	local barrelsCfg = OilConfig.Barrels
	local n = (barrelsCfg and barrelsCfg.PerBarrelOil) or 1
	return math.max(1, math.floor(n))
end
local selected: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}
local latestCash = 0
local shipmentCostLabel: TextLabel? = nil
local totalBarrelsLabel: TextLabel? = nil
local shipCapacityLabel: TextLabel? = nil
local warehouseCapacityLabel: TextLabel? = nil
local warehouseStoredTotal = 0
local warehouseCapTotal = 0
local hasWarehouseTotals = false
local dispatchButton: GuiButton? = nil
local lastDispatchFire = 0.0
-- Boat cooldown state: populated from snapshot (OilState.boatState/boatCooldownEndsAt) and
-- from OilActionResult("ERR_BOAT_COOLDOWN") payloads. os.clock()-based timestamps.
local latestBoatState: string? = nil
local latestBoatCooldownEndsAt: number? = nil
local defaultDispatchText: string? = nil

--- Last values sent to FTUE pointer sequencing (avoid spamming refresh every 250ms boat tick).
local lastFtueShipOilPeekOpen: boolean? = nil
local lastFtueShipOilPeekBarrels: number? = nil

------------------------------------------------------------
-- InstantSell sub-modal state (`ShipOilInstantSellGui.InstantSellConfirm` —
-- own ScreenGui with `IgnoreGuiInset = true` so the dim covers the full
-- viewport regardless of the underlying ShipOil panel layout).
------------------------------------------------------------
-- Sells from the same `refineryOilByTier` pool the ShipOilPanel cargo rows
-- show, but at fixed `InstantSellConfig` prices instead of going through
-- shipping. Modal lives inside ShipOilPanelGui (sub-modal, not its own
-- ScreenGui) so closing the parent panel implicitly hides it via Visible.
local instantSellModalRoot: Frame? = nil
local instantSellSellButton: GuiButton? = nil
local instantSellSellButtonText: TextLabel? = nil
local instantSellCancelButton: GuiButton? = nil
local instantSellCloseButton: GuiButton? = nil
local instantSellSaleTotalLabel: TextLabel? = nil
local instantSellMarketLossLabel: TextLabel? = nil
local instantSellOpenButton: GuiButton? = nil

type InstantSellRowBinding = {
	tier: string,
	pricePill: TextLabel?,
	amountField: AmountField,
	minus: GuiButton,
	plus: GuiButton,
	maxLabel: TextLabel?,
}

local instantSellRows: { [string]: InstantSellRowBinding } = {}
-- Selected sell qty per tier (driven by steppers; clamped to current holdings).
local instantSellSel: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}
-- Market $/bbl from `MarketPriceUpdate` / `RequestMarketSnapshot`. Used only
-- for the "Market value" + "You lose" subtitles; the sell PRICE itself is
-- always `InstantSellConfig.pricePerBarrel(tier)`.
local marketPricesByTier: { [string]: number } = {
	Crude = 0,
	Refined = 0,
	Premium = 0,
}
-- TextBox lookup so Enter-to-commit (UserInputService) can route the input
-- back to the right tier when the InstantSell amount field is focused.
local instantSellAmountTextBoxTier: { [TextBox]: string } = {}

local function resolvedStats(): { capacity: number, dispatchFee: number }
	local cap: number
	if latestResolved then
		cap = latestResolved.capacity
	else
		cap = ShipStats.Resolve(1, 1).capacity
	end
	local per = perBarrelOilUnits()
	local manifest: { [string]: number } = {}
	for _, k in ipairs(TIER_KEYS) do
		manifest[k] = (selected[k] or 0) * per
	end
	local fee = ShipStats.ComputeDispatchFeeFromManifestOilUnits(manifest, per)
	return { capacity = cap, dispatchFee = fee }
end

local function maxShipCapacityOilUnits(): number
	return resolvedStats().capacity
end

local function sumSelectedBarrels(): number
	local t = 0
	for _, k in ipairs(TIER_KEYS) do
		t += selected[k] or 0
	end
	return t
end

--- For `FtueUiPointers`: whether the ship-oil modal is open and how many barrels are selected.
function ShipOilPanel.peekOpenAndBarrelsForFtue(): (boolean, number)
	if not wiredScreen or not wiredScreen.Parent then
		return false, 0
	end
	return wiredScreen.Enabled, sumSelectedBarrels()
end

local function maybeFireFtueDispatchPointerRefresh()
	if not wiredScreen then
		return
	end
	local open = wiredScreen.Enabled
	local barrels = sumSelectedBarrels()
	if lastFtueShipOilPeekOpen == open and lastFtueShipOilPeekBarrels == barrels then
		return
	end
	lastFtueShipOilPeekOpen = open
	lastFtueShipOilPeekBarrels = barrels
	FtueDispatchPointerSignals.fireDispatchShipOilUiChanged()
end

local function sumSelectedOilUnits(): number
	local per = perBarrelOilUnits()
	local t = 0
	for _, k in ipairs(TIER_KEYS) do
		t += (selected[k] or 0) * per
	end
	return t
end

local function maxBarrelsInRefineryForTier(tier: string): number
	return math.floor((refineryOilByTier[tier] or 0) / perBarrelOilUnits())
end

local function clampSelectionsToInventory()
	for _, k in ipairs(TIER_KEYS) do
		local inv = maxBarrelsInRefineryForTier(k)
		if (selected[k] or 0) > inv then
			selected[k] = inv
		end
	end
end

--- If ship capacity shrinks or tiers change, trim selections (Premium → Refined → Crude) until load fits.
local function clampSelectionsToShipCapacity()
	local cap = maxShipCapacityOilUnits()
	local per = perBarrelOilUnits()
	local guard = 0
	while sumSelectedOilUnits() > cap and guard < 10000 do
		guard += 1
		local reduced = false
		for _, k in ipairs({ "Premium", "Refined", "Crude" }) do
			if sumSelectedOilUnits() <= cap then
				break
			end
			if (selected[k] or 0) > 0 then
				selected[k] = (selected[k] :: number) - 1
				reduced = true
			end
		end
		if not reduced then
			break
		end
	end
end

local function parseUnsignedBarrelInput(text: string): number
	local n = tonumber(text)
	if n == nil then
		local digits = string.match(text, "%d+")
		n = digits and tonumber(digits) or 0
	end
	return math.max(0, math.floor(n :: number))
end

--- Largest barrel count legal for `tier` given refinery inventory and remaining ship capacity (oil units).
local function maxLegalBarrelsForTier(tier: string): number
	local inv = maxBarrelsInRefineryForTier(tier)
	local per = perBarrelOilUnits()
	local otherOil = sumSelectedOilUnits() - (selected[tier] or 0) * per
	local roomOil = maxShipCapacityOilUnits() - otherOil
	local maxFromCap = math.floor(roomOil / per)
	return math.max(0, math.min(inv, maxFromCap))
end

local function setAmountFieldText(field: AmountField, value: number)
	local t = tostring(value)
	if field:IsA("TextBox") then
		-- Always sync from `selected` so +/- works while the field is focused (stale typed text was blocking updates).
		field.Text = t
	else
		(field :: TextLabel).Text = t
	end
end

--- Wired AmountLabel TextBoxes → tier key (for Enter-to-commit).
local shipAmountTextBoxTier: { [TextBox]: string } = {}

local function formatBarrelInventoryCount(count: number): string
	local n = math.max(0, math.floor(count))
	return string.format("%d Barrels", n)
end

-- One-time when wiring: brighter copy + stroke so "N Barrels" reads at parity with stepper amounts (Studio can still override defaults before bind).
local function emphasizeInventoryCountLabel(label: TextLabel)
	label.TextColor3 = Color3.fromRGB(218, 244, 255)
	if label:FindFirstChild("ShipOilInventoryEmphasisStroke") then
		return
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "ShipOilInventoryEmphasisStroke"
	stroke.Color = Color3.fromRGB(10, 18, 32)
	stroke.Thickness = 1.75
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
end

local function mergeOilByTierFromSnapshot(snap: any): boolean
	if typeof(snap) ~= "table" or typeof(snap.oilByTier) ~= "table" then
		return false
	end
	local o = snap.oilByTier :: { [string]: any }
	for _, k in ipairs(TIER_KEYS) do
		refineryOilByTier[k] = math.max(0, math.floor(tonumber(o[k]) or 0))
	end
	return true
end

local function mergeResolvedFromSnapshot(snap: any)
	if typeof(snap) ~= "table" or typeof((snap :: any).resolvedShip) ~= "table" then
		return
	end
	local rs = (snap :: any).resolvedShip
	local cap = tonumber(rs.capacity)
	if cap and cap > 0 then
		latestResolved = { capacity = math.floor(cap) }
	end
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

local function mergeBoatFromSnapshot(snap: any)
	if typeof(snap) ~= "table" then return end
	local s = snap :: any
	latestBoatState = typeof(s.boatState) == "string" and s.boatState or nil
	latestBoatCooldownEndsAt = typeof(s.boatCooldownEndsAt) == "number" and s.boatCooldownEndsAt or nil
end

--- True while the boat is destroyed/swapping and the HUD should block dispatch with a countdown.
local function boatCooldownRemaining(): number
	local endsAt = latestBoatCooldownEndsAt
	if not endsAt then return 0 end
	local remaining = endsAt - os.clock()
	if remaining <= 0 then
		-- Cooldown expired locally; clear so we don't show "in 0s" forever while waiting on a snapshot.
		latestBoatCooldownEndsAt = nil
		return 0
	end
	return remaining
end

local function applyCargoRowTitles(row: Instance, tier: string)
	local tierDef = QualityConfig.Tiers[tier :: any]
	local title = (tierDef and tierDef.displayName) or tier
	local nameCol = row:FindFirstChild("NameColumn", true)
	if nameCol then
		local tl = nameCol:FindFirstChildWhichIsA("TextLabel", true)
		if tl and tl:IsA("TextLabel") then
			tl.Text = title
		end
	end
end

local function refreshRowUi()
	clampSelectionsToInventory()
	clampSelectionsToShipCapacity()
	for _, bind in pairs(rowBindings) do
		local tier = bind.tier
		local inv = maxBarrelsInRefineryForTier(tier)
		bind.inventoryLabel.Text = formatBarrelInventoryCount(inv)
		local s = math.min(selected[tier] or 0, inv)
		selected[tier] = s
		setAmountFieldText(bind.amountField, s)
	end
end

local function refreshFooter()
	local totalBarrels = sumSelectedBarrels()
	local oilLoad = sumSelectedOilUnits()
	local rs = resolvedStats()
	if shipmentCostLabel then
		shipmentCostLabel.Text = string.format("Shipment Cost: $%d", rs.dispatchFee)
	end
	if totalBarrelsLabel then
		totalBarrelsLabel.Text = string.format("Total Barrels: %d", totalBarrels)
	end
	if shipCapacityLabel then
		local load = sumSelectedOilUnits()
		local cap = math.max(0, math.floor(maxShipCapacityOilUnits()))
		shipCapacityLabel.Text = string.format("%d/%d Ship Capacity", load, cap)
	end
	if warehouseCapacityLabel then
		if hasWarehouseTotals then
			warehouseCapacityLabel.Text = string.format("%d/%d Warehouse Storage", warehouseStoredTotal, warehouseCapTotal)
		else
			warehouseCapacityLabel.Text = "—/— Warehouse Storage"
		end
	end
	maybeFireFtueDispatchPointerRefresh()

	if dispatchButton then
		local fee = rs.dispatchFee
		local cap = rs.capacity
		local remaining = boatCooldownRemaining()
		-- Dock / swap locks: no click (different from an active voyage).
		local dockLocked = remaining > 0
			or latestBoatState == "cooldown"
			or latestBoatState == "swapping"
		local shipmentInProgress = latestBoatState == "sailing"
		-- Clickable while sailing so we can show ErrorNotification + fail FX; still blocked during dock cooldown/swap.
		local canAttempt = not dockLocked
		local validForDispatch = oilLoad > 0
			and latestCash >= fee
			and oilLoad <= cap
			and not shipmentInProgress
		dispatchButton.Active = canAttempt
		dispatchButton.AutoButtonColor = canAttempt and validForDispatch
		if defaultDispatchText == nil and dispatchButton:IsA("TextButton") then
			defaultDispatchText = dispatchButton.Text
		end
		if dispatchButton:IsA("TextButton") then
			if remaining > 0 then
				dispatchButton.Text = string.format("Ship in %ds", math.ceil(remaining))
			elseif latestBoatState == "sailing" then
				dispatchButton.Text = "Ship out"
			elseif defaultDispatchText then
				dispatchButton.Text = defaultDispatchText
			end
		end
	end
end

local function applyTypedBarrelsForTier(tier: string, raw: string)
	local want = parseUnsignedBarrelInput(raw)
	local legal = maxLegalBarrelsForTier(tier)
	selected[tier] = math.min(want, legal)
	clampSelectionsToInventory()
	clampSelectionsToShipCapacity()
	refreshRowUi()
	refreshFooter()
end

local function bumpTier(tier: string, delta: number)
	local inv = maxBarrelsInRefineryForTier(tier)
	local cur = selected[tier] or 0
	local per = perBarrelOilUnits()
	local nextSel = cur + delta
	if nextSel < 0 or nextSel > inv then
		return
	end
	if delta > 0 then
		if sumSelectedOilUnits() + per > maxShipCapacityOilUnits() then
			return
		end
	end
	selected[tier] = nextSel
	refreshRowUi()
	refreshFooter()
end

local function tryDispatch()
	local now = os.clock()
	if now - lastDispatchFire < 0.45 then
		return
	end
	local oilLoad = sumSelectedOilUnits()
	local rs = resolvedStats()

	if oilLoad <= 0 then
		lastDispatchFire = now
		showErrorNotification("Select at least one barrel to dispatch.", 4)
		playDispatchShipmentButtonFailTween()
		return
	end
	if oilLoad > rs.capacity then
		lastDispatchFire = now
		showErrorNotification("Selected load exceeds ship capacity.", 4)
		playDispatchShipmentButtonFailTween()
		return
	end
	if latestCash < rs.dispatchFee then
		lastDispatchFire = now
		showErrorNotification(
			string.format("Not enough cash for the fee ($%d). You have $%d.", rs.dispatchFee, math.floor(latestCash)),
			4.5
		)
		playDispatchShipmentButtonFailTween()
		return
	end
	if boatCooldownRemaining() > 0 or latestBoatState == "cooldown" or latestBoatState == "swapping" then
		return
	end
	if latestBoatState == "sailing" then
		lastDispatchFire = now
		showErrorNotification(
			"A shipment is already in progress. Wait for your ship to return before dispatching again.",
			4.5
		)
		playDispatchShipmentButtonFailTween()
		return
	end

	lastDispatchFire = now
	local per = perBarrelOilUnits()
	local manifest: { [string]: number } = {}
	for _, k in ipairs(TIER_KEYS) do
		manifest[k] = (selected[k] or 0) * per
	end
	ClientRemotes.requestDispatchShipment:FireServer({
		manifest = manifest,
	})
end

------------------------------------------------------------
-- InstantSell sub-modal helpers
------------------------------------------------------------
local function instantSellMaxForTier(tier: string): number
	return maxBarrelsInRefineryForTier(tier)
end

local function instantSellPriceForTier(tier: string): number
	return InstantSellConfig.pricePerBarrel(tier)
end

local function instantSellMarketPriceForTier(tier: string): number
	return marketPricesByTier[tier] or 0
end

local function clampInstantSellSelections()
	for _, k in ipairs(TIER_KEYS) do
		local m = instantSellMaxForTier(k)
		if (instantSellSel[k] or 0) > m then
			instantSellSel[k] = m
		end
		if (instantSellSel[k] or 0) < 0 then
			instantSellSel[k] = 0
		end
	end
end

--- Sale total = `Σ qty * InstantSellConfig price`. Drives the SELL button
--- copy + the "Sale Total" label. Market value (informational only) uses
--- the strait market prices.
local function instantSellSaleTotal(): number
	local t = 0
	for _, k in ipairs(TIER_KEYS) do
		t += (instantSellSel[k] or 0) * instantSellPriceForTier(k)
	end
	return t
end

local function instantSellMarketValue(): number
	local t = 0
	for _, k in ipairs(TIER_KEYS) do
		t += (instantSellSel[k] or 0) * instantSellMarketPriceForTier(k)
	end
	return t
end

local function refreshInstantSellRowsAndTotals()
	clampInstantSellSelections()

	for _, bind in pairs(instantSellRows) do
		local t = bind.tier
		local maxQty = instantSellMaxForTier(t)
		local sel = math.min(instantSellSel[t] or 0, maxQty)
		instantSellSel[t] = sel

		setAmountFieldText(bind.amountField, sel)

		if bind.maxLabel then
			bind.maxLabel.Text = string.format("/ %d bbls", maxQty)
		end
		if bind.pricePill then
			local p = instantSellPriceForTier(t)
			bind.pricePill.Text = if p > 0 then string.format("$%d/bbl", p) else "$—/bbl"
		end
	end

	local sale = instantSellSaleTotal()
	local market = instantSellMarketValue()
	local loss = math.max(0, market - sale)

	if instantSellSaleTotalLabel then
		instantSellSaleTotalLabel.Text = string.format("Sale Total: $%d", sale)
	end
	if instantSellMarketLossLabel then
		instantSellMarketLossLabel.Text = string.format("Market value: $%d  —  You lose $%d", market, loss)
	end
	if instantSellSellButtonText then
		instantSellSellButtonText.Text = string.format("SELL FOR $%d", sale)
	end
	if instantSellSellButton then
		-- Disable click + dim auto-color when there's nothing to sell so the
		-- button visibly communicates "no-op" without a separate styled state.
		local hasSomething = sale > 0
		instantSellSellButton.Active = hasSomething
		instantSellSellButton.AutoButtonColor = hasSomething
	end
end

--- Smooth `BackgroundColor3` fade on hover/press for InstantSell modal
--- buttons (stepper +/- and the modal close button). Matches the soft
--- color-shift feel of the ShipOil dispatch steppers — no size tween.
--- Disable `AutoButtonColor` so it doesn't fight the tween.
local STEPPER_HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STEPPER_HOVER_LERP = 0.18
local STEPPER_PRESS_LERP = 0.22

local function attachColorFadeHover(btn: GuiButton, conns: { RBXScriptConnection })
	if btn:GetAttribute("InstantSellHoverFadeBound") == true then
		return
	end
	btn:SetAttribute("InstantSellHoverFadeBound", true)

	-- Strip the previous experiment's scale child if it lingers from prior runs.
	local stale = btn:FindFirstChild("HoverScale")
	if stale and stale:IsA("UIScale") then
		stale:Destroy()
	end

	btn.AutoButtonColor = false

	local baseColor = btn.BackgroundColor3
	local hoverColor = baseColor:Lerp(Color3.new(1, 1, 1), STEPPER_HOVER_LERP)
	local pressedColor = baseColor:Lerp(Color3.new(0, 0, 0), STEPPER_PRESS_LERP)

	local function tweenTo(color: Color3)
		TweenService:Create(btn, STEPPER_HOVER_TWEEN, { BackgroundColor3 = color }):Play()
	end

	table.insert(conns, btn.MouseEnter:Connect(function()
		tweenTo(hoverColor)
	end))
	table.insert(conns, btn.MouseLeave:Connect(function()
		tweenTo(baseColor)
	end))
	table.insert(conns, btn.MouseButton1Down:Connect(function()
		tweenTo(pressedColor)
	end))
	table.insert(conns, btn.MouseButton1Up:Connect(function()
		tweenTo(hoverColor)
	end))
end

local function bumpInstantSellTier(tier: string, delta: number)
	local maxQty = instantSellMaxForTier(tier)
	local cur = instantSellSel[tier] or 0
	local next_ = math.clamp(cur + delta, 0, maxQty)
	if next_ == cur then
		return
	end
	instantSellSel[tier] = next_
	refreshInstantSellRowsAndTotals()
end

local function applyTypedInstantSellTier(tier: string, raw: string)
	local want = parseUnsignedBarrelInput(raw)
	local maxQty = instantSellMaxForTier(tier)
	instantSellSel[tier] = math.clamp(want, 0, maxQty)
	refreshInstantSellRowsAndTotals()
end

local function setInstantSellModalVisible(show: boolean)
	if instantSellModalRoot then
		instantSellModalRoot.Visible = show
	end
end

--- Reset selected qty to the player's current holdings (the "max of all
--- types") whenever the modal opens, per spec. Re-running while open is a
--- no-op since the user controls the steppers from there.
local function openInstantSellModal()
	if not instantSellModalRoot then
		return
	end
	for _, k in ipairs(TIER_KEYS) do
		instantSellSel[k] = instantSellMaxForTier(k)
	end
	refreshInstantSellRowsAndTotals()
	setInstantSellModalVisible(true)
end

local function closeInstantSellModal()
	setInstantSellModalVisible(false)
end

local function tryInstantSell()
	if not instantSellModalRoot or not instantSellModalRoot.Visible then
		return
	end
	local total = instantSellSaleTotal()
	if total <= 0 then
		-- Nothing to sell; the button should already be inactive but guard
		-- anyway in case of stale state.
		return
	end
	local quantities: { [string]: number } = {}
	for _, k in ipairs(TIER_KEYS) do
		local q = math.max(0, math.floor(instantSellSel[k] or 0))
		if q > 0 then
			quantities[k] = q
		end
	end
	if next(quantities) == nil then
		return
	end
	-- Optimistic close: we'll get the receipt on `oilActionResult` (action
	-- = "InstantSell") and play the kaching SFX there. Closing immediately
	-- matches the "instant" feel the modal name implies; if the server
	-- rejects we surface the error via `errorNotificationLabel`.
	closeInstantSellModal()
	ClientRemotes.requestInstantSell:FireServer({
		quantities = quantities,
		requestId = HttpService:GenerateGUID(false),
	})
end

------------------------------------------------------------
-- RunUpgradeCard1 — Security Personnel (Robux DevProduct)
------------------------------------------------------------
-- Wires the FIRST run-upgrade card in `ShipOilPanelGui` to the Security
-- Personnel consumable (`MonetizationCatalog.consumable.security_personnel_x1`).
-- Card 2/3 still carry their `ComingSoonOverlay` in Studio — only card 1 has
-- a live product behind it so we don't touch the other two from script.
--
-- Ownership repaint: piggybacks on the existing `oilStateUpdate` listener
-- below (so the badge updates in the same frame the server pushes the
-- consumed/added stack). Click → `RequestPromptRobuxPurchase`. The
-- "next run protected" toast notification is a separate follow-up; this
-- module deliberately stays silent on success and lets
-- `MonetizationSfxBootstrap` own the kaching.

local RUN_UPGRADE_ITEM_ID = "consumable.security_personnel_x1"
local RUN_UPGRADE_INVENTORY_ID = "security_personnel"

local runUpgradeCard1Binding: {
	titleLabel: TextLabel,
	descriptionLabel: TextLabel?,
	costLabel: TextLabel?,
	buyButton: GuiButton,
	baseTitle: string,
	baseDescription: string,
}? = nil

local function formatRunUpgradeDescription(ownedCount: number): string
	if not runUpgradeCard1Binding then
		return ""
	end
	local base = runUpgradeCard1Binding.baseDescription
	if ownedCount > 0 then
		-- "Ready" emphasises the upgrade is armed; the count makes stacking
		-- legible without a second badge UI element. Keeps the description
		-- short enough that `TextScaled` doesn't shrink unreadably on phones.
		return string.format("Ready ×%d  •  %s", ownedCount, base)
	end
	return base
end

local function refreshRunUpgradeCard1(ownedCount: number)
	local b = runUpgradeCard1Binding
	if not b then
		return
	end
	if b.descriptionLabel then
		b.descriptionLabel.Text = formatRunUpgradeDescription(math.max(0, math.floor(ownedCount)))
	end
end

local function readRunUpgradeOwnedFromSnapshot(snap: any): number?
	if typeof(snap) ~= "table" then
		return nil
	end
	local owned = (snap :: any).runUpgradeOwnedByItemId
	if typeof(owned) ~= "table" then
		return nil
	end
	local n = (owned :: { [string]: any })[RUN_UPGRADE_INVENTORY_ID]
	if typeof(n) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(n))
end

--- Bind `RunUpgradeCard1` to the Security Personnel product. Idempotent on
--- the same screen because `disconnectAll()` clears the binding before
--- `wireShipOil` calls us again. Safe to call before the catalog row exists
--- (warns + early-returns so the rest of the panel still wires).
local function wireRunUpgradeCard1(screen: ScreenGui, conns: { RBXScriptConnection })
	local section = screen:FindFirstChild("RunUpgradesSection", true)
	local cards = section and section:FindFirstChild("RunUpgradeCards")
	local card = cards and cards:FindFirstChild("RunUpgradeCard1")
	if not (card and card:IsA("GuiObject")) then
		warn("[ShipOilPanel] RunUpgradeCard1 not found under " .. screen:GetFullName() .. " — Security Personnel buy CTA will not be wired.")
		return
	end

	local titleLabel = card:FindFirstChild("TitleLabel", true)
	local descLabel = card:FindFirstChild("DescriptionLabel", true)
	local costPill = card:FindFirstChild("CostPill", true)
	-- Studio numbered the per-card cost label `CostLabel1` so it is unique
	-- inside `Body` (matters for any future global `FindFirstChild` lookups).
	local costLabel = costPill and (costPill:FindFirstChild("CostLabel1") or costPill:FindFirstChildWhichIsA("TextLabel", true))
	local buyButton = card:FindFirstChild("BuyButton", true)

	if not (titleLabel and titleLabel:IsA("TextLabel")) then
		warn("[ShipOilPanel] RunUpgradeCard1.TitleLabel missing — skipping wire.")
		return
	end
	if not (buyButton and buyButton:IsA("GuiButton")) then
		warn("[ShipOilPanel] RunUpgradeCard1.BuyButton missing — skipping wire.")
		return
	end

	local item = MonetizationCatalog.GetItem(RUN_UPGRADE_ITEM_ID)
	if not item then
		warn(string.format(
			"[ShipOilPanel] MonetizationCatalog has no entry for %q — RunUpgradeCard1 will keep Studio placeholder text.",
			RUN_UPGRADE_ITEM_ID
		))
		return
	end

	-- `displayName` mirrors the Studio author's text but we re-stamp from
	-- the catalog so a copy change in Lua propagates without a Studio edit.
	titleLabel.Text = (typeof(item.displayName) == "string" and item.displayName) or titleLabel.Text
	local baseDescription = if typeof(item.subtitle) == "string" and item.subtitle ~= ""
		then item.subtitle
		else "Protects your next shipment"

	if costLabel and costLabel:IsA("TextLabel") then
		local price = item.robuxPrice
		if typeof(price) == "number" and price > 0 then
			costLabel.Text = string.format("R$%d", math.floor(price))
		else
			costLabel.Text = "R$—"
		end
	end

	runUpgradeCard1Binding = {
		titleLabel = titleLabel :: TextLabel,
		descriptionLabel = (descLabel and descLabel:IsA("TextLabel")) and (descLabel :: TextLabel) or nil,
		costLabel = (costLabel and costLabel:IsA("TextLabel")) and (costLabel :: TextLabel) or nil,
		buyButton = buyButton :: GuiButton,
		baseTitle = titleLabel.Text,
		baseDescription = baseDescription,
	}

	-- Initial paint with `0` owned; the snapshot fetched below in
	-- `wireShipOil` will overwrite this within the same wire pass.
	refreshRunUpgradeCard1(0)

	table.insert(conns, (buyButton :: GuiButton).Activated:Connect(function()
		ClientRemotes.requestPromptRobuxPurchase:FireServer({ itemId = RUN_UPGRADE_ITEM_ID })
	end))

	-- Surface failure codes for this card's prompt to the console only
	-- (mirrors `RobuxShopPanel`'s policy — there's no per-card error toast,
	-- and we don't want to fight `ShipOilPanel`'s own `ErrorNotification`
	-- which is reserved for dispatch errors).
	table.insert(conns, ClientRemotes.monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local data = (payload :: any).data
		local itemId = (typeof(data) == "table" and (data :: any).itemId) or nil
		if itemId ~= RUN_UPGRADE_ITEM_ID then
			return
		end
		if payload.ok == true then
			return
		end
		local code = tostring(payload.code)
		if code == "ERR_PRODUCT_NOT_CONFIGURED" then
			warn(string.format("[ShipOilPanel] %s — DevProduct id is 0 in MonetizationCatalog. Set the real productId from the Creator Dashboard.", itemId))
		elseif code == "ERR_MONETIZATION_DISABLED" then
			warn(string.format("[ShipOilPanel] %s — MonetizationCatalog.Enabled is false; toggle it on to allow purchases.", itemId))
		elseif code == "ERR_PROMPT_FAILED" then
			warn(string.format("[ShipOilPanel] %s — MarketplaceService prompt failed; user may retry.", itemId))
		end
	end))
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(rowBindings)
	table.clear(shipAmountTextBoxTier)
	table.clear(instantSellRows)
	table.clear(instantSellAmountTextBoxTier)
	-- Hide the InstantSell modal too — it now lives in a sibling
	-- `ShipOilInstantSellGui` ScreenGui that closing the ShipOil panel
	-- doesn't disable on its own.
	if instantSellModalRoot then
		instantSellModalRoot.Visible = false
	end
	for _, k in ipairs(TIER_KEYS) do
		instantSellSel[k] = 0
		marketPricesByTier[k] = 0
	end
	shipmentCostLabel = nil
	totalBarrelsLabel = nil
	shipCapacityLabel = nil
	warehouseCapacityLabel = nil
	warehouseStoredTotal = 0
	warehouseCapTotal = 0
	hasWarehouseTotals = false
	dispatchButton = nil
	instantSellModalRoot = nil
	instantSellSellButton = nil
	instantSellSellButtonText = nil
	instantSellCancelButton = nil
	instantSellCloseButton = nil
	instantSellSaleTotalLabel = nil
	instantSellMarketLossLabel = nil
	instantSellOpenButton = nil
	wiredScreen = nil
	latestResolved = nil
	lastFtueShipOilPeekOpen = nil
	lastFtueShipOilPeekBarrels = nil
	runUpgradeCard1Binding = nil
	hideErrorNotification()
	errorNotificationLabel = nil
end

local function wireShipOil(screen: ScreenGui, closePanel: (() -> ())?)
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
			"[ShipOilPanel] No `ErrorNotification` TextLabel found under "
				.. screen:GetFullName()
				.. " — author one in Studio (recommended path: Canvas.PanelHost.ErrorNotification). Errors will be silent until added."
		)
	end

	local shipmentBand = screen:FindFirstChild("ShipmentCostBand", true)
	if shipmentBand then
		local sc = shipmentBand:FindFirstChild("ShipmentCostLabel")
		if sc and sc:IsA("TextLabel") then
			shipmentCostLabel = sc
		end
	end
	local footer = screen:FindFirstChild("Footer", true)
	if footer then
		local tb = footer:FindFirstChild("TotalBarrelsLabel")
		if tb and tb:IsA("TextLabel") then
			totalBarrelsLabel = tb
		end
		local db = footer:FindFirstChild("DispatchShipmentButton", true)
		if db and db:IsA("GuiButton") then
			dispatchButton = db
		end
	end
	local cargoSection = screen:FindFirstChild("CargoSection", true)
		or screen:FindFirstChild("ShipOil_CargoWash", true)
	local cargoRows = cargoSection and cargoSection:FindFirstChild("CargoRows")

	--- Preferred Studio: `ShipCapacityBand` → `ShipCapacity`. Legacy: `CargoSubtotalBand` / `CargoSubtotalRow` / flat label.
	local function resolveShipCapacityTextLabel(root: Instance?): TextLabel?
		if not root then
			return nil
		end
		local band = root:FindFirstChild("ShipCapacityBand", true)
			or root:FindFirstChild("CargoSubtotalBand", true)
		if band then
			local named = band:FindFirstChild("ShipCapacity")
			if named and named:IsA("TextLabel") then
				return named
			end
			local legacyRow = band:FindFirstChild("CargoSubtotalRow", true)
				or band:FindFirstChild("SubtotalRow", true)
			if legacyRow then
				if legacyRow:IsA("TextLabel") then
					return legacyRow
				end
				local tl = legacyRow:FindFirstChildWhichIsA("TextLabel", true)
				if tl and tl:IsA("TextLabel") then
					return tl
				end
			end
		end
		local flat = root:FindFirstChild("CargoSubtotalRow", true)
		if flat then
			if flat:IsA("TextLabel") then
				return flat
			end
			local tl = flat:FindFirstChildWhichIsA("TextLabel", true)
			if tl and tl:IsA("TextLabel") then
				return tl
			end
		end
		return nil
	end

	shipCapacityLabel = resolveShipCapacityTextLabel(cargoSection)
		or resolveShipCapacityTextLabel(screen)

	local whCap = cargoSection and cargoSection:FindFirstChild("WarehouseCapacityLabel", true)
	if whCap and whCap:IsA("TextLabel") then
		warehouseCapacityLabel = whCap
	end

	if cargoRows and cargoRows:IsA("Instance") then
		local tierSeen: { [string]: boolean } = {}
		for _, ch in ipairs(cargoRows:GetChildren()) do
			if not ch:IsA("GuiObject") then
				continue
			end
			local tier = resolveRowTierKey(ch)
			if not tier then
				continue
			end
			if tierSeen[tier] then
				continue
			end
			tierSeen[tier] = true
			applyCargoRowTitles(ch, tier)
			local invLabel = ch:FindFirstChild("InventoryCount", true)
			local stepper = ch:FindFirstChild("Stepper", true)
			if not (invLabel and invLabel:IsA("TextLabel") and stepper) then
				continue
			end
			emphasizeInventoryCountLabel(invLabel :: TextLabel)
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
			if amt:IsA("TextBox") then
				amt.ClearTextOnFocus = false
				shipAmountTextBoxTier[amt :: TextBox] = tier
			end
			rowBindings[ch.Name] = {
				tier = tier,
				inventoryLabel = invLabel :: TextLabel,
				amountField = amountField,
				minus = minus :: GuiButton,
				plus = plus :: GuiButton,
			}
			StepperHold.bind(minus :: GuiButton, function()
				bumpTier(tier, -1)
			end, connections)
			StepperHold.bind(plus :: GuiButton, function()
				bumpTier(tier, 1)
			end, connections)
			if amt:IsA("TextBox") then
				table.insert(connections, amt.FocusLost:Connect(function()
					applyTypedBarrelsForTier(tier, amt.Text)
				end))
			end
		end
	end

	-- Enter / keypad Enter commits typed amount (FocusLost alone is unreliable on some platforms).
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
		local tKey = shipAmountTextBoxTier[tb]
		if tKey then
			applyTypedBarrelsForTier(tKey, tb.Text)
			tb:ReleaseFocus()
			return
		end
		local instantTier = instantSellAmountTextBoxTier[tb]
		if instantTier then
			applyTypedInstantSellTier(instantTier, tb.Text)
			tb:ReleaseFocus()
		end
	end))

	if dispatchButton then
		table.insert(connections, dispatchButton.Activated:Connect(tryDispatch))
		attachColorFadeHover(dispatchButton, connections)
	end

	table.insert(connections, ClientRemotes.warehouseStateUpdate.OnClientEvent:Connect(function(data: any)
		if mergeWarehouseTotalsFromPayload(data) then
			refreshFooter()
		end
	end))

	table.insert(connections, ClientRemotes.oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then
			return
		end
		if typeof(snap.cash) == "number" then
			latestCash = snap.cash
		end
		mergeResolvedFromSnapshot(snap)
		mergeBoatFromSnapshot(snap)
		if mergeOilByTierFromSnapshot(snap) then
			clampSelectionsToInventory()
			refreshRowUi()
			-- Re-render InstantSell MaxLabel + clamped sel qty whenever
			-- holdings change (drilling / pickup / shipment fulfillment).
			-- Cheap when modal is hidden; only the next open call needs the
			-- updated max anyway.
			if next(instantSellRows) ~= nil then
				refreshInstantSellRowsAndTotals()
			end
		end
		-- Run-upgrade owned counts ride on the same packet so the
		-- RunUpgradeCard1 "Ready ×N" badge updates in the same frame as a
		-- successful Robux receipt OR a dispatch consume. Skips silently
		-- when the card isn't wired yet (Studio template missing).
		local owned = readRunUpgradeOwnedFromSnapshot(snap)
		if owned ~= nil then
			refreshRunUpgradeCard1(owned)
		end
		refreshFooter()
	end))

	table.insert(connections, ClientRemotes.oilActionResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local data = (payload :: any).data
		-- InstantSell receipts (server tags `action = "InstantSell"`). Play
		-- kaching on success; surface the error toast + deny SFX on failure.
		if (payload :: any).action == "InstantSell" then
			if payload.ok == true then
				UiSfx.playKaching()
				for _, k in ipairs(TIER_KEYS) do
					instantSellSel[k] = 0
				end
				if next(instantSellRows) ~= nil then
					refreshInstantSellRowsAndTotals()
				end
			elseif payload.ok == false then
				if errorNotificationLabel and wiredScreen == screen and screen.Enabled then
					local msg = typeof((payload :: any).message) == "string" and (payload :: any).message
						or "Instant sell failed."
					showErrorNotification(msg, 4)
				end
				UiSfx.playUiDenied()
			end
			return
		end
		if payload.ok == true and typeof(data) == "table" and typeof(data.shipmentId) == "string" then
			hideErrorNotification()
			UiSfx.playSetSail()
			for _, k in ipairs(TIER_KEYS) do
				selected[k] = 0
			end
			refreshRowUi()
			refreshFooter()
			if wiredScreen == screen and screen.Enabled and closePanel then
				closePanel()
			end
		elseif payload.ok == false and payload.code == "ERR_WAREHOUSE_FULL" then
			if wiredScreen == screen and screen.Enabled then
				if errorNotificationLabel then
					local msg = typeof((payload :: any).message) == "string" and (payload :: any).message
						or "Warehouse full! Reduce cargo before dispatch."
					showErrorNotification(msg, 4.5)
				end
				playDispatchShipmentButtonFailTween()
			end
			refreshFooter()
		elseif payload.ok == false and payload.code == "ERR_NOT_ENOUGH_CASH" then
			if wiredScreen == screen and screen.Enabled then
				if errorNotificationLabel then
					local msg = typeof((payload :: any).message) == "string" and (payload :: any).message
						or "Not enough cash for the dispatch fee."
					showErrorNotification(msg, 4.5)
				end
				playDispatchShipmentButtonFailTween()
			end
			refreshFooter()
		elseif payload.ok == false and payload.code == "ERR_SHIPMENT_IN_PROGRESS" then
			if wiredScreen == screen and screen.Enabled then
				if errorNotificationLabel then
					local msg = typeof((payload :: any).message) == "string" and (payload :: any).message
						or "A shipment is already in progress. Wait for your ship to return before dispatching again."
					showErrorNotification(msg, 4.5)
				end
				playDispatchShipmentButtonFailTween()
			end
			refreshFooter()
		elseif payload.ok == false and payload.code == "ERR_BOAT_COOLDOWN" then
			if typeof(data) == "table" then
				if typeof(data.cooldownEndsAt) == "number" then
					latestBoatCooldownEndsAt = data.cooldownEndsAt
				end
				if typeof(data.boatState) == "string" then
					latestBoatState = data.boatState
				end
			end
			refreshFooter()
		end
	end))

	-- Periodic countdown tick while the panel is wired.
	task.spawn(function()
		local myScreen = wiredScreen
		while wiredScreen == myScreen and myScreen ~= nil do
			if latestBoatCooldownEndsAt or latestBoatState == "sailing" then
				refreshFooter()
			end
			task.wait(0.25)
		end
	end)

	do
		local ok, snap = pcall(function()
			return ClientRemotes.requestOilSnapshot:InvokeServer()
		end)
		if ok and typeof(snap) == "table" then
			local st = (snap :: any).state
			if typeof(st) == "table" then
				if typeof(st.cash) == "number" then
					latestCash = st.cash
				end
				mergeResolvedFromSnapshot(st)
				mergeBoatFromSnapshot(st)
				if mergeOilByTierFromSnapshot(st) then
					clampSelectionsToInventory()
				end
				local owned = readRunUpgradeOwnedFromSnapshot(st)
				if owned ~= nil then
					refreshRunUpgradeCard1(owned)
				end
			end
		end
	end

	do
		local ok, data = pcall(function()
			return ClientRemotes.requestWarehouseSnapshot:InvokeServer()
		end)
		if ok then
			mergeWarehouseTotalsFromPayload(data)
		end
	end

	------------------------------------------------------------
	-- InstantSell sub-modal wiring (`ShipOilInstantSellGui.InstantSellConfirm`)
	------------------------------------------------------------
	-- The modal lives in its OWN ScreenGui sibling (`ShipOilInstantSellGui`,
	-- DisplayOrder = 41, IgnoreGuiInset = true) so the dim covers the full
	-- viewport regardless of the underlying ShipOil panel's layout / inset.
	-- Falls back to the legacy `Canvas.InstantSellConfirm` location during
	-- a transitional state where the Studio split hasn't been saved yet.
	local function resolveInstantSellModal(): Frame?
		local parent = screen.Parent
		if parent then
			local sib = parent:FindFirstChild("ShipOilInstantSellGui")
			if sib then
				local m = sib:FindFirstChild("InstantSellConfirm")
				if m and m:IsA("Frame") then
					return m :: Frame
				end
			end
		end
		local canvasLegacy = screen:FindFirstChild("Canvas")
		local legacy = canvasLegacy and canvasLegacy:FindFirstChild("InstantSellConfirm")
		if legacy and legacy:IsA("Frame") then
			return legacy :: Frame
		end
		return nil
	end

	local modal = resolveInstantSellModal()
	if modal and modal:IsA("Frame") then
		instantSellModalRoot = modal
		modal.Visible = false -- start hidden; opened via InstantSell button

		local body = modal:FindFirstChild("ConfirmHost", true)
		body = body and body:FindFirstChild("ConfirmCard", true) or body
		body = body and body:FindFirstChild("Body", true) or body

		local closeBtn = body and body:FindFirstChild("CloseButton", true)
		if closeBtn and closeBtn:IsA("GuiButton") then
			instantSellCloseButton = closeBtn
		end

		local actionRow = body and body:FindFirstChild("ActionRow", true)
		local cancelBtn = actionRow and actionRow:FindFirstChild("CancelButton", true)
		if cancelBtn and cancelBtn:IsA("GuiButton") then
			instantSellCancelButton = cancelBtn
		end
		local sellBtn = actionRow and actionRow:FindFirstChild("SellButton", true)
		if sellBtn and sellBtn:IsA("GuiButton") then
			instantSellSellButton = sellBtn
			local txt = sellBtn:FindFirstChild("Text")
			if txt and txt:IsA("TextLabel") then
				instantSellSellButtonText = txt
			end
		end

		local totalsBlock = body and body:FindFirstChild("TotalsBlock", true)
		local saleTotal = totalsBlock and totalsBlock:FindFirstChild("SaleTotalLabel", true)
		if saleTotal and saleTotal:IsA("TextLabel") then
			instantSellSaleTotalLabel = saleTotal
		end
		local marketLoss = totalsBlock and totalsBlock:FindFirstChild("MarketLossLabel", true)
		if marketLoss and marketLoss:IsA("TextLabel") then
			instantSellMarketLossLabel = marketLoss
		end

		-- Per-tier rows (CrudeRow / RefinedRow / PremiumRow).
		local oilRows = body and body:FindFirstChild("OilRows", true)
		local ROW_NAME_FOR_TIER: { [string]: string } = {
			Crude = "CrudeRow",
			Refined = "RefinedRow",
			Premium = "PremiumRow",
		}
		if oilRows then
			for _, tier in ipairs(TIER_KEYS) do
				local rowName = ROW_NAME_FOR_TIER[tier]
				local row = rowName and oilRows:FindFirstChild(rowName)
				if not (row and row:IsA("GuiObject")) then
					continue
				end
				local stepper = row:FindFirstChild("Stepper", true)
				local minus = stepper and stepper:FindFirstChild("MinusButton", true)
				local plus = stepper and stepper:FindFirstChild("PlusButton", true)
				local amt = stepper and stepper:FindFirstChild("AmountLabel", true)
				if not (minus and minus:IsA("GuiButton") and plus and plus:IsA("GuiButton") and amt) then
					continue
				end
				if not (amt:IsA("TextBox") or amt:IsA("TextLabel")) then
					continue
				end
				local amountField = amt :: AmountField
				if amt:IsA("TextBox") then
					amt.ClearTextOnFocus = false
					instantSellAmountTextBoxTier[amt :: TextBox] = tier
				end

				local pricePill = row:FindFirstChild("PricePill", true)
				local maxLabel = row:FindFirstChild("MaxLabel", true)

				instantSellRows[tier] = {
					tier = tier,
					pricePill = (pricePill and pricePill:IsA("TextLabel")) and pricePill or nil,
					amountField = amountField,
					minus = minus :: GuiButton,
					plus = plus :: GuiButton,
					maxLabel = (maxLabel and maxLabel:IsA("TextLabel")) and maxLabel or nil,
				}

				StepperHold.bind(minus :: GuiButton, function()
					bumpInstantSellTier(tier, -1)
				end, connections)
				StepperHold.bind(plus :: GuiButton, function()
					bumpInstantSellTier(tier, 1)
				end, connections)
				attachColorFadeHover(minus :: GuiButton, connections)
				attachColorFadeHover(plus :: GuiButton, connections)
				if amt:IsA("TextBox") then
					table.insert(connections, amt.FocusLost:Connect(function()
						applyTypedInstantSellTier(tier, amt.Text)
					end))
				end
			end
		end

		-- Cancel / Close → hide modal. Close button gets the same color-fade
		-- hover as the steppers so it feels consistent inside the modal.
		if instantSellCancelButton then
			table.insert(connections, instantSellCancelButton.Activated:Connect(closeInstantSellModal))
		end
		if instantSellCloseButton then
			table.insert(connections, instantSellCloseButton.Activated:Connect(closeInstantSellModal))
			attachColorFadeHover(instantSellCloseButton, connections)
		end
		-- Sell → server (`RequestInstantSell`). Receipt comes in on
		-- `oilActionResult` (action = "InstantSell"); we already close on
		-- send for the "instant" feel.
		if instantSellSellButton then
			table.insert(connections, instantSellSellButton.Activated:Connect(tryInstantSell))
		end

		-- Live market prices → drives the "Market value / You lose" line in
		-- the totals block. NOT used for the actual sell price.
		table.insert(connections, ClientRemotes.marketPriceUpdate.OnClientEvent:Connect(function(data: any)
			if typeof(data) ~= "table" or typeof(data.prices) ~= "table" then
				return
			end
			local p = data.prices :: { [string]: any }
			for _, k in ipairs(TIER_KEYS) do
				marketPricesByTier[k] = math.max(0, math.floor(tonumber(p[k]) or 0))
			end
			if instantSellModalRoot and instantSellModalRoot.Visible then
				refreshInstantSellRowsAndTotals()
			end
		end))
		do
			local ok, data = pcall(function()
				return ClientRemotes.requestMarketSnapshot:InvokeServer()
			end)
			if ok and typeof(data) == "table" and typeof((data :: any).prices) == "table" then
				local p = (data :: any).prices
				for _, k in ipairs(TIER_KEYS) do
					marketPricesByTier[k] = math.max(0, math.floor(tonumber(p[k]) or 0))
				end
			end
		end

		-- Initial paint (modal hidden) so labels aren't placeholder copy
		-- the first time the player opens it.
		refreshInstantSellRowsAndTotals()
	end

	-- Run upgrades — only RunUpgradeCard1 (Security Personnel) is live;
	-- cards 2/3 still carry their `ComingSoonOverlay` in Studio so they're
	-- intentionally left unwired here.
	wireRunUpgradeCard1(screen, connections)

	-- InstantSell open button lives on the main panel (`InstantSellSection.InstantSellButton`).
	local instantSellSection = screen:FindFirstChild("InstantSellSection", true)
	local openBtn = instantSellSection and instantSellSection:FindFirstChild("InstantSellButton", true)
	if openBtn and openBtn:IsA("GuiButton") then
		instantSellOpenButton = openBtn
		table.insert(connections, openBtn.Activated:Connect(function()
			openInstantSellModal()
		end))
	end

	applyMerriweatherToPanelText(screen)

	clampSelectionsToInventory()
	refreshRowUi()
	refreshFooter()

	table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		maybeFireFtueDispatchPointerRefresh()
	end))
	maybeFireFtueDispatchPointerRefresh()
end

function ShipOilPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	wireShipOil(ctrl.ScreenGui, function()
		ctrl.Close()
	end)
	return ctrl
end

function ShipOilPanel.screenName(): string
	return SCREEN_NAME
end

return ShipOilPanel
