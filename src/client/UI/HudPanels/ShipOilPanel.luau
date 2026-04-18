--!strict
-- Ship oil cargo modal (`StarterGui.ShipOilPanelGui` → `PlayerGui`).
-- Cargo rows = refinery/plot storage (`OilStateService` `oilByTier`). `WarehouseCapacityLabel` = strait **`WarehouseService`** totals (`WarehouseStateUpdate`).
-- UI counts whole barrels; manifest uses oil units (`barrels selected * PerBarrelOil`) to match `ConsumeManifest`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local StepperHold = require(script.Parent.Parent:WaitForChild("StepperHold"))
local FtueDispatchPointerSignals = require(script.Parent.Parent:WaitForChild("FtueDispatchPointerSignals"))
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

--- Ephemeral red banner on `Canvas` only (not in `Body` layouts). Default: centered, just above lower area / dispatch zone — reposition freely in Studio.
local STATUS_TOAST_TEXT_RED = Color3.fromRGB(220, 40, 40)

local ERROR_NOTIFICATION_NAME = "ErrorNotification"
local LEGACY_ERROR_TOAST_NAME = "ShipOilStatusToast"

local function ensureErrorNotificationLabel(screen: ScreenGui): TextLabel?
	local canvas = screen:FindFirstChild("Canvas")
	if not canvas then
		return nil
	end
	local existing = canvas:FindFirstChild(ERROR_NOTIFICATION_NAME)
	if not (existing and existing:IsA("TextLabel")) then
		local legacy = canvas:FindFirstChild(LEGACY_ERROR_TOAST_NAME)
		if legacy and legacy:IsA("TextLabel") then
			legacy.Name = ERROR_NOTIFICATION_NAME
			existing = legacy
		end
	end
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local toast = Instance.new("TextLabel")
	toast.Name = ERROR_NOTIFICATION_NAME
	toast.BackgroundTransparency = 1
	toast.BorderSizePixel = 0
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.66, 0, 0.9, 0)
	toast.Size = UDim2.new(0.14, 0, 0, 0)
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.ZIndex = 50
	toast.Visible = false
	toast.Text = ""
	toast.TextColor3 = STATUS_TOAST_TEXT_RED
	toast.TextScaled = true
	toast.TextWrapped = true
	toast.Font = PANEL_FONT
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

--- Deny SFX on failed dispatch (no button color flash — authored `ImageButton` visuals rarely use `BackgroundColor3`).
local function playDispatchShipmentButtonFailTween()
	UiSfx.playUiDenied()
end

-- Studio row `Frame` names → manifest tier keys. Prefer **`ShipCargoRowHeavyCrude`**, **`ShipCargoRowLightSweet`**, **`ShipCargoRowPremiumRefined`**; legacy aliases keep old places working.
-- Renamed rows: set attribute **`ShipOilTier`** = `HeavyCrude` | `LightSweet` | `PremiumRefined`, or keep **`CrudeTitle` / `TypeName` / `NameColumn`** copy matching **`QualityConfig.Tiers`** display / hud short names.
local ROW_NAME_TO_TIER: { [string]: string } = {
	ShipCargoRowHeavyCrude = "HeavyCrude",
	ShipCargoRowHeavy = "HeavyCrude",
	ShipCargoRowCrude = "HeavyCrude",
	ShipCargoRowLightSweet = "LightSweet",
	ShipCargoRowLight = "LightSweet",
	ShipCargoRowPremiumRefined = "PremiumRefined",
	ShipCargoRowStandard = "PremiumRefined",
	ShipCargoRowPremium = "PremiumRefined",
}

local TIER_KEYS = { "HeavyCrude", "LightSweet", "PremiumRefined" }

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
local function cargoTierLabelText(row: GuiObject): string?
	local crude = row:FindFirstChild("CrudeTitle", true)
	if crude and crude:IsA("TextLabel") then
		return crude.Text
	end
	local typeName = row:FindFirstChild("TypeName", true)
	if typeName and typeName:IsA("TextLabel") then
		return typeName.Text
	end
	local nameCol = row:FindFirstChild("NameColumn", true)
	if nameCol then
		local tl = nameCol:FindFirstChildWhichIsA("TextLabel", true)
		if tl and tl:IsA("TextLabel") then
			return tl.Text
		end
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
	HeavyCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
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
	HeavyCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
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
local requestDispatchShipmentEvent: RemoteEvent? = nil
-- Boat cooldown state: populated from snapshot (OilState.boatState/boatCooldownEndsAt) and
-- from OilActionResult("ERR_BOAT_COOLDOWN") payloads. os.clock()-based timestamps.
local latestBoatState: string? = nil
local latestBoatCooldownEndsAt: number? = nil
local defaultDispatchText: string? = nil

--- Last values sent to FTUE pointer sequencing (avoid spamming refresh every 250ms boat tick).
local lastFtueShipOilPeekOpen: boolean? = nil
local lastFtueShipOilPeekBarrels: number? = nil

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

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

--- If ship capacity shrinks or tiers change, trim selections (Premium → Light → Heavy) until load fits.
local function clampSelectionsToShipCapacity()
	local cap = maxShipCapacityOilUnits()
	local per = perBarrelOilUnits()
	local guard = 0
	while sumSelectedOilUnits() > cap and guard < 10000 do
		guard += 1
		local reduced = false
		for _, k in ipairs({ "PremiumRefined", "LightSweet", "HeavyCrude" }) do
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
	local crude = row:FindFirstChild("CrudeTitle", true)
	if crude and crude:IsA("TextLabel") then
		crude.Text = title
		return
	end
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
	local ev = requestDispatchShipmentEvent
	if ev then
		ev:FireServer({
			manifest = manifest,
		})
	end
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(rowBindings)
	table.clear(shipAmountTextBoxTier)
	shipmentCostLabel = nil
	totalBarrelsLabel = nil
	shipCapacityLabel = nil
	warehouseCapacityLabel = nil
	warehouseStoredTotal = 0
	warehouseCapTotal = 0
	hasWarehouseTotals = false
	dispatchButton = nil
	requestDispatchShipmentEvent = nil
	wiredScreen = nil
	latestResolved = nil
	lastFtueShipOilPeekOpen = nil
	lastFtueShipOilPeekBarrels = nil
	hideErrorNotification()
	errorNotificationLabel = nil
end

local function wireShipOil(screen: ScreenGui, closePanel: (() -> ())?)
	if wiredScreen == screen then
		return
	end
	disconnectAll()
	wiredScreen = screen

	-- Studio: sample `Text` + `Visible = true` on `Canvas.ErrorNotification` for layout; we hide when wired.
	errorNotificationLabel = ensureErrorNotificationLabel(screen)
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
		errorNotificationLabel.TextTransparency = 0
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

	local rf = remotesFolder()
	requestDispatchShipmentEvent = rf:WaitForChild(RemoteNames.RequestDispatchShipment) :: RemoteEvent

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
		if not tKey then
			return
		end
		applyTypedBarrelsForTier(tKey, tb.Text)
		tb:ReleaseFocus()
	end))

	if dispatchButton then
		table.insert(connections, dispatchButton.Activated:Connect(tryDispatch))
	end

	local whUp = rf:WaitForChild(RemoteNames.WarehouseStateUpdate) :: RemoteEvent
	table.insert(connections, whUp.OnClientEvent:Connect(function(data: any)
		if mergeWarehouseTotalsFromPayload(data) then
			refreshFooter()
		end
	end))

	local oilUp = rf:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
	table.insert(connections, oilUp.OnClientEvent:Connect(function(snap: any)
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
		end
		refreshFooter()
	end))

	local oilResult = rf:WaitForChild(RemoteNames.OilActionResult) :: RemoteEvent
	table.insert(connections, oilResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local data = (payload :: any).data
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

	local snapFn = rf:FindFirstChild(RemoteNames.RequestOilSnapshot)
	if snapFn and snapFn:IsA("RemoteFunction") then
		local ok, snap = pcall(function()
			return (snapFn :: RemoteFunction):InvokeServer()
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
			end
		end
	end

	local snapWh = rf:FindFirstChild(RemoteNames.RequestWarehouseSnapshot)
	if snapWh and snapWh:IsA("RemoteFunction") then
		local ok, data = pcall(function()
			return (snapWh :: RemoteFunction):InvokeServer()
		end)
		if ok then
			mergeWarehouseTotalsFromPayload(data)
		end
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
