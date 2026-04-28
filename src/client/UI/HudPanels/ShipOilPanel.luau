--!strict
-- Ship oil cargo modal (`StarterGui.ShipOilPanelGui` → `PlayerGui`).
-- Cargo rows = refinery/plot storage (`OilStateService` `oilByTier`). `WarehouseCapacityLabel` = strait **`WarehouseService`** totals (`WarehouseStateUpdate`).
-- UI counts whole barrels; manifest uses oil units (`barrels selected * PerBarrelOil`) to match `ConsumeManifest`.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local InstantSellConfig = require(Shared:WaitForChild("Config"):WaitForChild("InstantSellConfig"))
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))

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
	maxButton: GuiButton?,
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
local _useSecurityPersonnel = false
local _securityOwnedCount = 0
-- Cargo Hauler arm flag + owned-stack count. Same shape as the Security
-- Personnel pair above: `_useCargoHauler` is the local toggle the player
-- flips on/off via `RunUpgradeCard2`'s pill, `_cargoHaulerOwnedCount`
-- mirrors `runUpgradeOwnedByItemId.cargo_hauler` from the latest oil-state
-- snapshot. Both feed the dispatch payload (`useCargoHauler`) and the
-- "×2" capacity-readout hint in `refreshFooter`.
local _useCargoHauler = false
local _cargoHaulerOwnedCount = 0
-- Red "×2!" attention badge that paints next to `TotalBarrelsLabel` while
-- Cargo Hauler is armed. Lazy-created the first time `refreshFooter` runs
-- with the label resolved, kept around (parented under `totalBarrelsLabel`
-- itself) until `disconnectAll` tears down the panel — at which point it
-- dies with its parent. The pulse tween is held so we can `:Cancel()` it
-- on disarm; otherwise an idle tween would keep firing on a hidden label.
local cargoHaulerBadge: TextLabel? = nil
local cargoHaulerBadgeScale: UIScale? = nil
local cargoHaulerBadgeTween: Tween? = nil
local latestCash = 0
local shipmentCostLabel: TextLabel? = nil
local totalBarrelsLabel: TextLabel? = nil
local shipCapacityLabel: TextLabel? = nil
local warehouseCapacityLabel: TextLabel? = nil
-- Authored default color of `WarehouseCapacityLabel`, captured the first time
-- the label resolves so we can flip to red when the warehouse hits 0 slots
-- left and restore the design color when capacity opens back up. Stored as
-- a `Color3?` (nil until first bind) instead of hard-coding a fallback so
-- restyling the panel in Studio keeps the off-red color consistent.
local warehouseCapacityLabelDefaultColor: Color3? = nil
local WAREHOUSE_FULL_TEXT_COLOR = Color3.fromRGB(255, 80, 80)
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
		-- Pre-snapshot fallback. Boat progression refactor (Step 2): use
		-- the starter boat's baked stats instead of `Resolve(1, 1)` so
		-- the placeholder matches what the server will compute on the
		-- first `OilStateUpdate` push.
		cap = ShipStats.ResolveForBoat("Tier1Boat").capacity
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
	--- `HudPanelRouter.start` binds modals inside `task.spawn`; `FtueUiPointers`
	--- can refresh first while `ShipOilPanelGui` is already `Enabled` (e.g. plot
	--- dispatch prox). Without `wiredScreen`, FTUE used to think the panel was
	--- closed and hid all in-panel pointers. Eager-bind once — idempotent with
	--- `wireShipOil` when the same `ScreenGui` is already wired.
	if not (wiredScreen and wiredScreen.Parent) then
		local plr = Players.LocalPlayer
		local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
		if pg then
			ShipOilPanel.bind(pg)
		end
	end
	if wiredScreen and wiredScreen.Parent then
		return wiredScreen.Enabled, sumSelectedBarrels()
	end
	return false, 0
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

------------------------------------------------------------
-- Warehouse-capacity safety (steppers + typed amount)
------------------------------------------------------------
-- Server-side `OilShipmentService` already rejects oversized dispatches with
-- `ERR_WAREHOUSE_FULL`, but we also stop the +/- stepper and the AmountLabel
-- TextBox from staging more barrels than the warehouse can absorb on
-- delivery. That gives the player two layers of feedback (immediate at the
-- input, second pass at dispatch) instead of letting them happily build a
-- manifest that the server is guaranteed to reject.
--
-- The cap projection mirrors the WarehouseCapacityLabel formula in
-- `refreshFooter`: `cap - stored - selected`. When `hasWarehouseTotals` is
-- false (no payload yet) the safety opens up — the dispatch-time ERR is
-- still the backstop.
local WAREHOUSE_FULL_SAFETY_MESSAGE = "Too many barrels for warehouse storage!"
local WAREHOUSE_FULL_SAFETY_DEBOUNCE = 0.6
local lastWarehouseFullSafetyAt = 0

local function warehouseSpotsRemainingForCurrentSelection(): number
	if not hasWarehouseTotals or warehouseCapTotal <= 0 then
		-- Unknown / disabled warehouse cap → don't block, defer to server.
		return math.huge
	end
	return math.max(0, warehouseCapTotal - warehouseStoredTotal - sumSelectedBarrels())
end

--- Headroom for `tier` only (subtracts the OTHER tiers' staged barrels from
--- the cap, not this tier's own contribution). Used by typed-amount clamp so
--- the new value isn't double-counted with the value being replaced.
local function maxBarrelsForWarehouseRemaining(tier: string): number
	if not hasWarehouseTotals or warehouseCapTotal <= 0 then
		return math.huge
	end
	local otherStaged = sumSelectedBarrels() - (selected[tier] or 0)
	return math.max(0, warehouseCapTotal - warehouseStoredTotal - otherStaged)
end

local function notifyWarehouseFullSafety()
	if not errorNotificationLabel then
		-- Studio hasn't authored the toast label; play deny SFX so the user
		-- still gets *some* feedback (mirrors the dispatch-side guard).
		UiSfx.playUiDenied()
		return
	end
	local now = os.clock()
	if now - lastWarehouseFullSafetyAt < WAREHOUSE_FULL_SAFETY_DEBOUNCE then
		return
	end
	lastWarehouseFullSafetyAt = now
	showErrorNotification(WAREHOUSE_FULL_SAFETY_MESSAGE, 4)
	UiSfx.playUiDenied()
end

--- Per-field default text color, captured the first time `setAmountFieldText`
--- runs against a field. Lets us flip stepper amounts green while Cargo
--- Hauler is armed and restore the Studio-authored color (typically the
--- gold accent) on disarm without hard-coding a specific RGB. Cleared in
--- `disconnectAll` alongside the other rebound maps.
local _amountFieldOriginalColor: { [GuiObject]: Color3 } = {}

local CARGO_HAULER_GREEN = Color3.fromRGB(60, 200, 80)

local function setAmountFieldText(field: AmountField, value: number, cargoHaulerArmed: boolean?)
	-- Snapshot the original color BEFORE we ever overwrite, so the first
	-- "armed → disarm" cycle restores the authored accent rather than
	-- whatever fallback we baked in.
	if _amountFieldOriginalColor[field :: any] == nil then
		_amountFieldOriginalColor[field :: any] = field.TextColor3
	end
	-- Cargo Hauler doubles the *displayed* value while leaving the
	-- internal `selected[tier]` untouched (server still pays dispatch
	-- fee on the un-doubled selection; the doubling is a server-side
	-- grant). So the stepper reads "40" while `selected.Crude == 20`.
	local displayValue = if cargoHaulerArmed then value * 2 else value
	local t = tostring(displayValue)
	if field:IsA("TextBox") then
		-- Always sync from `selected` so +/- works while the field is focused (stale typed text was blocking updates).
		field.Text = t
	else
		(field :: TextLabel).Text = t
	end
	field.TextColor3 = if cargoHaulerArmed
		then CARGO_HAULER_GREEN
		else (_amountFieldOriginalColor[field :: any] or Color3.fromRGB(255, 255, 255))
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
	if typeof(snap) ~= "table" or typeof((snap :: any).resolvedBoat) ~= "table" then
		return
	end
	local rs = (snap :: any).resolvedBoat
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
	-- Cargo Hauler arm flag: when set, the stepper's `AmountLabel`
	-- displays each tier's `selected` value × 2 in green so the player
	-- sees the doubled barrels they'll dispatch. The internal `selected`
	-- table stays at the un-doubled value — server-side `_handleDispatch`
	-- does the actual ×2 multiply on the manifest after the fee+inventory
	-- consume, so the player only pays/loses 20 from inventory but
	-- dispatches 40.
	local cargoHaulerArmed = _useCargoHauler and _cargoHaulerOwnedCount > 0
	for _, bind in pairs(rowBindings) do
		local tier = bind.tier
		local inv = maxBarrelsInRefineryForTier(tier)
		bind.inventoryLabel.Text = formatBarrelInventoryCount(inv)
		local s = math.min(selected[tier] or 0, inv)
		selected[tier] = s
		setAmountFieldText(bind.amountField, s, cargoHaulerArmed)
	end
end

local function refreshFooter()
	local totalBarrels = sumSelectedBarrels()
	local oilLoad = sumSelectedOilUnits()
	local rs = resolvedStats()
	if shipmentCostLabel then
		shipmentCostLabel.Text = string.format("Shipment Cost: $%d", rs.dispatchFee)
	end
	-- Cargo Hauler arm state visibly modifies the footer readouts: when
	-- armed, paint both labels gold AND show a bright red "×2!" badge
	-- next to TotalBarrels with an infinite-repeat scale pulse so the
	-- player can't miss that their next dispatch is doubled. The arm flag
	-- is canonical client-side state (server re-validates on dispatch),
	-- so this paint is safe to run from `refreshFooter` on every
	-- tier-amount tick.
	local cargoHaulerArmed = _useCargoHauler and _cargoHaulerOwnedCount > 0
	-- Cargo Hauler "armed" accent is the module-level `CARGO_HAULER_GREEN`
	-- shared by every armed-state element: stepper amounts (doubled),
	-- TotalBarrels (doubled), ShipCapacity (load+cap both doubled), and
	-- the pulsing ×2! badge. One green so the doubled signals all read
	-- as one visual unit.

	-- Lazy-create the red ×2! badge as a child of `totalBarrelsLabel` —
	-- pinned to its right edge (anchor (0, 0.5), pos (1, 8px, 0.5, 0)) so
	-- it floats just outside the label's text. UIScale child is what the
	-- pulse tween animates, leaving the label's geometry untouched.
	local function ensureCargoHaulerBadge()
		if cargoHaulerBadge and cargoHaulerBadge.Parent then
			return
		end
		if not totalBarrelsLabel then
			return
		end
		local badge = Instance.new("TextLabel")
		badge.Name = "CargoHaulerBadge"
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.new(1, 8, 0.5, 0)
		badge.Size = UDim2.fromScale(0.4, 0.95)
		badge.BackgroundTransparency = 1
		badge.FontFace = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
		badge.Text = "×2!"
		badge.TextColor3 = CARGO_HAULER_GREEN
		badge.TextScaled = true
		badge.TextXAlignment = Enum.TextXAlignment.Left
		badge.TextYAlignment = Enum.TextYAlignment.Center
		badge.Visible = false
		badge.ZIndex = (totalBarrelsLabel.ZIndex or 1) + 5
		badge.BorderSizePixel = 0
		badge.Parent = totalBarrelsLabel

		-- Black stroke so the red reads punchy on any panel bg.
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Thickness = 2
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = badge

		local scale = Instance.new("UIScale")
		scale.Scale = 1
		scale.Parent = badge

		cargoHaulerBadge = badge
		cargoHaulerBadgeScale = scale
	end

	--- Show / hide the badge and start / stop its pulse tween. Idempotent;
	--- safe to call every refresh tick.
	local function setCargoHaulerBadgeArmed(armed: boolean)
		ensureCargoHaulerBadge()
		if not (cargoHaulerBadge and cargoHaulerBadge.Parent and cargoHaulerBadgeScale) then
			return
		end
		cargoHaulerBadge.Visible = armed
		if armed then
			-- Re-create the tween only if it isn't already playing — calling
			-- `:Play()` on a live looping tween is a no-op so this branch
			-- is cheap on subsequent refresh ticks while armed.
			local existing = cargoHaulerBadgeTween
			if not existing or existing.PlaybackState == Enum.PlaybackState.Cancelled or existing.PlaybackState == Enum.PlaybackState.Completed then
				cargoHaulerBadgeScale.Scale = 1
				cargoHaulerBadgeTween = TweenService:Create(
					cargoHaulerBadgeScale,
					-- 0.45s out-and-back via Reverses=true; RepeatCount=-1 loops
					-- forever until disarm.
					TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Scale = 1.4 }
				)
				cargoHaulerBadgeTween:Play()
			end
		else
			if cargoHaulerBadgeTween then
				cargoHaulerBadgeTween:Cancel()
				cargoHaulerBadgeTween = nil
			end
			cargoHaulerBadgeScale.Scale = 1
		end
	end

	if totalBarrelsLabel then
		if cargoHaulerArmed then
			-- Show the doubled total inline; the green ×2! pulse badge to
			-- the right is the attention beat. Both green so the two
			-- elements read as one "your barrels are doubled" signal.
			totalBarrelsLabel.Text = string.format("Total Barrels: %d", totalBarrels * 2)
			totalBarrelsLabel.TextColor3 = CARGO_HAULER_GREEN
		else
			totalBarrelsLabel.Text = string.format("Total Barrels: %d", totalBarrels)
			-- Restore Studio-authored color (white). If a future re-skin
			-- changes the resting color, capture it on first bind the same
			-- way `_warehouseLabelDefaultColor` does — for now white is the
			-- canonical authored color.
			totalBarrelsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end
	if shipCapacityLabel then
		local load = sumSelectedOilUnits()
		local cap = math.max(0, math.floor(maxShipCapacityOilUnits()))
		if cargoHaulerArmed then
			-- Both load AND cap doubled so the readout reads "40/40"
			-- instead of "20/20" — emphasizes that the dispatched ship
			-- carries 2× its normal payload (the boat's actual capacity
			-- is unchanged; this is a visual representation of the
			-- doubled grant).
			shipCapacityLabel.Text = string.format("%d/%d Ship Capacity", load * 2, cap * 2)
			shipCapacityLabel.TextColor3 = CARGO_HAULER_GREEN
		else
			shipCapacityLabel.Text = string.format("%d/%d Ship Capacity", load, cap)
			shipCapacityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end
	-- Drive the badge after the label text update so it pins against the
	-- updated text width on the same frame.
	setCargoHaulerBadgeArmed(cargoHaulerArmed)
	if warehouseCapacityLabel then
		-- Live "slots left" projection: warehouse cap minus what is already
		-- stored minus the barrels the player has staged in this manifest.
		-- Dispatched ship cargo ends up in the warehouse (see the
		-- "Warehouse full! Reduce cargo before dispatch" guard further
		-- below), so as the player nudges +/- on the steppers this number
		-- ticks down to zero and gives them an at-a-glance budget without
		-- mental math against `Stored / Cap`. Clamps at 0 so the label
		-- never reads negative if a payload arrives mid-edit.
		--
		-- Color flip: when staged + stored saturates the warehouse cap
		-- (`remaining == 0`) the label turns red so the player sees at a
		-- glance that the next +1 nudge would overflow on dispatch (the
		-- "Warehouse full!" dispatch guard would then block them). The
		-- design color is captured once on first resolve so restyling the
		-- panel in Studio keeps the off-red default in sync.
		if hasWarehouseTotals then
			local staged = sumSelectedBarrels()
			local remaining = math.max(0, warehouseCapTotal - warehouseStoredTotal - staged)
			warehouseCapacityLabel.Text = string.format("%d Warehouse Spots", remaining)
			if remaining <= 0 and warehouseCapTotal > 0 then
				warehouseCapacityLabel.TextColor3 = WAREHOUSE_FULL_TEXT_COLOR
			elseif warehouseCapacityLabelDefaultColor then
				warehouseCapacityLabel.TextColor3 = warehouseCapacityLabelDefaultColor
			end
		else
			warehouseCapacityLabel.Text = "— Warehouse Spots"
			if warehouseCapacityLabelDefaultColor then
				warehouseCapacityLabel.TextColor3 = warehouseCapacityLabelDefaultColor
			end
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
	local invShipLegal = maxLegalBarrelsForTier(tier)
	local warehouseLegal = maxBarrelsForWarehouseRemaining(tier)
	local legal = math.min(invShipLegal, warehouseLegal)
	local clamped = math.min(want, legal)
	-- Surface the warehouse-full toast only when the *warehouse* is what
	-- pulled the typed value down (inventory + ship-cap denials stay silent
	-- to match the existing stepper UX). `hasWarehouseTotals` guards against
	-- firing during the brief window before the first WarehouseStateUpdate.
	if hasWarehouseTotals and want > clamped and clamped == warehouseLegal and warehouseLegal < invShipLegal then
		notifyWarehouseFullSafety()
	elseif hasWarehouseTotals and want > clamped and clamped == warehouseLegal and warehouseLegal == invShipLegal then
		-- Tied caps: the warehouse limit is just as binding as inventory/ship
		-- here, but the user still typed past warehouse capacity, so make the
		-- safety message visible (matches user request: "amount should not go
		-- over the max when summed up").
		notifyWarehouseFullSafety()
	end
	selected[tier] = clamped
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
		-- Block + when the warehouse can't absorb another barrel on
		-- shipment delivery. Ship cargo lands in the warehouse on success
		-- (`OilShipmentService` → `WarehouseService`), so a manifest one
		-- larger than `cap - stored - staged` is guaranteed to bounce on
		-- the server with `ERR_WAREHOUSE_FULL`. Catching it here gives the
		-- player immediate feedback at the stepper and keeps the
		-- `WarehouseSpotsLabel` from ever projecting negative.
		if warehouseSpotsRemainingForCurrentSelection() <= 0 then
			notifyWarehouseFullSafety()
			return
		end
	end
	selected[tier] = nextSel
	refreshRowUi()
	refreshFooter()
end

--- One-shot Max button: stage every legal barrel of `tier` the player owns,
--- clamped to whichever cap binds first (refinery inventory, ship cargo room
--- after the OTHER tiers, or warehouse headroom). When the cap pulls below
--- inventory we surface a per-cause toast + deny SFX so the player understands
--- why the count didn't reach the refinery total. Quiet success only when
--- nothing was held back.
local function setMaxForTier(tier: string)
	local inv = maxBarrelsInRefineryForTier(tier)
	local per = perBarrelOilUnits()
	local otherOil = sumSelectedOilUnits() - (selected[tier] or 0) * per
	local shipRoomBarrels = math.max(0, math.floor((maxShipCapacityOilUnits() - otherOil) / per))

	local warehouseRoomBarrels: number
	if hasWarehouseTotals and warehouseCapTotal > 0 then
		local otherStaged = sumSelectedBarrels() - (selected[tier] or 0)
		warehouseRoomBarrels = math.max(0, warehouseCapTotal - warehouseStoredTotal - otherStaged)
	else
		warehouseRoomBarrels = math.huge
	end

	local actualMax = math.min(inv, shipRoomBarrels, warehouseRoomBarrels)
	local cur = selected[tier] or 0
	local changed = actualMax ~= cur

	if changed then
		selected[tier] = actualMax
		refreshRowUi()
		refreshFooter()
	end

	-- Quiet success: Max gave the player every barrel they own.
	if actualMax >= inv and changed then
		return
	end

	-- Either a no-op tap at the current cap or a successful-but-clamped Max
	-- with inventory still on the dock. Both deserve a message + deny SFX so
	-- the player sees the binding constraint. Ship-vs-warehouse precedence
	-- mirrors the implicit ordering elsewhere in the file (ship cap is the
	-- harder limit; warehouse safety is the secondary guard).
	--
	-- Cargo Hauler arm state: when armed, every visible barrel readout in
	-- the panel (stepper, TotalBarrels, ShipCapacity) shows the doubled
	-- value, so the cap message must too — otherwise the player sees
	-- "40/40 Ship Capacity" + stepper "40" + an error saying "capped at
	-- 20 barrels" and rightfully wonders which number to trust. We scale
	-- the displayed cap by the same multiplier the dispatch grant uses
	-- and append a "(×2 with Cargo Hauler)" tag so the player understands
	-- where the doubled number came from. Inventory count stays real
	-- (`inv`) because the inventory column on the row never doubles —
	-- it's the player's actual barrels on the dock.
	local cargoHaulerArmed = _useCargoHauler and _cargoHaulerOwnedCount > 0
	local displayedCap = if cargoHaulerArmed then actualMax * 2 else actualMax
	local cargoHaulerNote = if cargoHaulerArmed then " (×2 with Cargo Hauler)" else ""
	local tierDisplay = (QualityConfig.Tiers[tier :: any] and QualityConfig.Tiers[tier :: any].displayName) or tier
	local message: string
	if actualMax >= inv then
		message = string.format("All %d %s barrels already loaded.", inv, tierDisplay)
	elseif shipRoomBarrels <= warehouseRoomBarrels then
		message = string.format("Ship cargo full — %s capped at %d barrels%s.", tierDisplay, displayedCap, cargoHaulerNote)
	else
		message = string.format("Warehouse near full — %s capped at %d barrels%s.", tierDisplay, displayedCap, cargoHaulerNote)
	end
	showErrorNotification(message, 4)
	UiSfx.playUiDenied()
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
		useSecurityPersonnel = _useSecurityPersonnel == true,
		-- Mirror Security Personnel's opt-in shape: server only doubles
		-- when the player has explicitly toggled the Cargo Hauler card on
		-- AND owns ≥1 stack (server re-validates `_cargoHaulerService:
		-- TryConsumeForDispatch` so a tampered client can't free-ride).
		useCargoHauler = _useCargoHauler == true,
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
-- Cargo Hauler — same shape as the Security Personnel constants above. The
-- inventory id is what `OilStateService.runUpgradeOwnedByItemId` keys on
-- (set by `CargoHaulerService:SetMonetizationService`'s consumable handler);
-- the catalog id is what `RequestPromptRobuxPurchase` carries to the server.
local RUN_UPGRADE_CARGO_ITEM_ID = "consumable.cargo_hauler_x1"
local RUN_UPGRADE_CARGO_INVENTORY_ID = "cargo_hauler"

-- Shared "purple Robux chrome" applied to the BUY button on every
-- run-upgrade card. Mirrors the chrome the RobuxShop panel uses (purple
-- bg, vertical depth gradient, top sheen strip, scaled stroke, single
-- centered "R$XX" label). Wipes whatever Studio authored on the button so
-- the visual stays consistent across cards regardless of authoring drift.
local BUY_PURPLE       = Color3.fromRGB(124, 92, 252)
local BUY_PURPLE_STROKE = Color3.fromRGB(60, 40, 160)
local BUY_TEXT_STROKE  = Color3.fromRGB(40, 25, 100)
local FONT_BUY         = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

local function applyRobuxChromeToBuyButton(button: GuiButton, priceText: string)
	-- Idempotent strip — re-runs of `wireRunUpgradeCard1/2` (e.g. when the
	-- panel re-opens) replace prior chrome cleanly instead of stacking.
	for _, c in ipairs(button:GetChildren()) do
		c:Destroy()
	end

	if button:IsA("ImageButton") then
		button.Image = ""
		button.ImageTransparency = 1
	end
	button.BackgroundColor3 = BUY_PURPLE
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.AutoButtonColor = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.28, 0)
	corner.Parent = button

	-- Scaled stroke — same Thickness=0.2 contextual mode as the RobuxShop
	-- buttons so all "Robux chrome" surfaces look uniform.
	local stroke = Instance.new("UIStroke")
	stroke.Color = BUY_PURPLE_STROKE
	stroke.Thickness = 0.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = button

	-- Vertical depth gradient. Multipliers (white → light gray) so any
	-- future hover-tween of `BackgroundColor3` rides the gradient cleanly.
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 220, 230)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(165, 165, 195)),
	})
	grad.Parent = button

	-- Top sheen strip — glossy upper edge, mirrors the RobuxShop chrome.
	local highlight = Instance.new("Frame")
	highlight.Name = "TopHighlight"
	highlight.BackgroundColor3 = Color3.new(1, 1, 1)
	highlight.BackgroundTransparency = 0.55
	highlight.BorderSizePixel = 0
	highlight.AnchorPoint = Vector2.new(0.5, 0)
	highlight.Position = UDim2.fromScale(0.5, 0.07)
	highlight.Size = UDim2.fromScale(0.88, 0.32)
	highlight.ZIndex = 2
	local hCorner = Instance.new("UICorner")
	hCorner.CornerRadius = UDim.new(1, 0)
	hCorner.Parent = highlight
	local hGrad = Instance.new("UIGradient")
	hGrad.Rotation = 90
	hGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	hGrad.Parent = highlight
	highlight.Parent = button

	-- Centered "R$XX" label. Single string (vs split icon+price) — the
	-- ShipOilPanel buttons are short pills where icon+price doesn't fit
	-- without crowding. Stroke for legibility against the lighter top of
	-- the depth gradient.
	local label = Instance.new("TextLabel")
	label.Name = "Price"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.84, 0.62)
	label.FontFace = FONT_BUY
	label.Text = priceText
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 3
	label.BorderSizePixel = 0
	label.Parent = button
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color = BUY_TEXT_STROKE
	labelStroke.Thickness = 1.25
	labelStroke.Transparency = 0.25
	labelStroke.Parent = label
end

--- Resolve a catalog item's `robuxPrice` to the "R$XX" string the BUY
--- button surfaces. Returns "R$—" for missing/zero prices so a half-wired
--- catalog entry still renders something instead of a blank pill.
local function formatBuyButtonPrice(item: any): string
	local price = item and item.robuxPrice
	if typeof(price) == "number" and price > 0 then
		return string.format("R$%d", math.floor(price))
	end
	return "R$—"
end

local runUpgradeCard1Binding: {
	titleLabel: TextLabel,
	descriptionLabel: TextLabel?,
	costPill: GuiObject?,
	costPillGradient: UIGradient?,
	costLabel: TextLabel?,
	toggleDisplay: TextLabel?,
	toggleButton: TextButton?,
	buyButton: GuiButton,
	baseTitle: string,
	baseDescription: string,
}? = nil

local function formatRunUpgradeDescription(ownedCount: number): string
	if not runUpgradeCard1Binding then
		return ""
	end
	local base = runUpgradeCard1Binding.baseDescription
	if ownedCount <= 0 then
		return base
	end
	-- Armed state: explicitly tell the player the guard is on the next
	-- shipment. Mirrors the visible signal — when this run dispatches,
	-- `OilShipmentService:_runShipment` calls
	-- `SecurityPersonnelService:MountForShipment`, which drops the cloned
	-- `Assets.SecurityPersonnel` rig onto the boat's `NPC_POSITION` anchor.
	-- Stacking shows the queue length so the player can tell at a glance
	-- whether they're set for one more dispatch or several.
	if ownedCount == 1 then
		return "Security Personnel active on next run"
	end
	return string.format("Security Personnel active on next ×%d runs", ownedCount)
end

local function refreshRunUpgradeCard1(ownedCount: number)
	local b = runUpgradeCard1Binding
	if not b then
		return
	end
	_securityOwnedCount = math.max(0, math.floor(ownedCount))
	if _securityOwnedCount <= 0 then
		_useSecurityPersonnel = false
	end
	if b.descriptionLabel then
		if _useSecurityPersonnel then
			b.descriptionLabel.Text = string.format("ON — 1/%d will be used on dispatch", _securityOwnedCount)
		elseif _securityOwnedCount > 0 then
			b.descriptionLabel.Text = string.format("OFF — %d available", _securityOwnedCount)
		else
			b.descriptionLabel.Text = "Protects your ship from all events on next run"
		end
	end
	-- CostPill = OFF/ON toggle display
	if b.costLabel and b.costLabel:IsA("TextLabel") then
		b.costLabel.Text = _useSecurityPersonnel and "ON" or "OFF"
		-- Hide coin icon so OFF/ON text is visible
		local coinIcon = b.costLabel.Parent and b.costLabel.Parent:FindFirstChild("CoinIcon")
		if coinIcon and coinIcon:IsA("GuiObject") then
			coinIcon.Visible = false
		end
	end
end

refreshRunUpgradeCard1 = function(ownedCount: number)
	local b = runUpgradeCard1Binding
	if not b then
		return
	end
	_securityOwnedCount = math.max(0, math.floor(ownedCount))
	if _securityOwnedCount <= 0 then
		_useSecurityPersonnel = false
	end
	if b.descriptionLabel then
		if _useSecurityPersonnel then
			b.descriptionLabel.Text = string.format("ON - 1/%d will be used on dispatch", _securityOwnedCount)
		elseif _securityOwnedCount > 0 then
			b.descriptionLabel.Text = string.format("OFF - %d available", _securityOwnedCount)
		else
			b.descriptionLabel.Text = b.baseDescription
		end
	end
	if b.costPill and b.costPill.Parent then
		b.costPill.BackgroundColor3 = if _useSecurityPersonnel
			then Color3.fromRGB(46, 166, 74)
			else Color3.fromRGB(196, 64, 102)
		b.costPill.BackgroundTransparency = 0
	end
	if b.costPillGradient and b.costPillGradient.Parent then
		b.costPillGradient.Enabled = false
	end
	if b.toggleDisplay and b.toggleDisplay.Parent then
		b.toggleDisplay.Text = _useSecurityPersonnel and "ON" or "OFF"
	end
end

--- Always returns a non-negative int. Missing / malformed
--- `runUpgradeOwnedByItemId` (e.g. stale client payloads) is treated as
--- 0 so we still repaint the card — never skip refresh with `nil`.
local function readRunUpgradeOwnedFromSnapshot(snap: any): number
	if typeof(snap) ~= "table" then
		return 0
	end
	local owned = (snap :: any).runUpgradeOwnedByItemId
	if typeof(owned) ~= "table" then
		return 0
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

	-- Mirror Card2/Card3 policy: while a Studio-authored `ComingSoonOverlay`
	-- is parented to the card, treat the product as unavailable. The overlay
	-- already covers the full card (`Size (1,1)`, `ZIndex 30+`) and visually
	-- blocks the BuyButton; this short-circuit also stops `Activated` from
	-- firing the Robux prompt if input ever bleeds through. Removing the
	-- overlay in Studio re-enables the wire on the next bind pass.
	if card:FindFirstChild("ComingSoonOverlay") then
		runUpgradeCard1Binding = nil
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
		else "Protects your ship from all events on next run"

	if costLabel and costLabel:IsA("TextLabel") then
		local price = item.robuxPrice
		if typeof(price) == "number" and price > 0 then
			costLabel.Text = string.format("R$%d", math.floor(price))
		else
			costLabel.Text = "R$—"
		end
	end

	-- Re-skin the BUY button as the canonical purple Robux chrome with
	-- the catalog price as its centered label. The CostPill below still
	-- gets repurposed as the OFF/ON arm toggle; the BUY button stays
	-- focused on "spend Robux to buy more stacks".
	applyRobuxChromeToBuyButton(buyButton :: GuiButton, formatBuyButtonPrice(item))

	runUpgradeCard1Binding = {
		titleLabel = titleLabel :: TextLabel,
		descriptionLabel = (descLabel and descLabel:IsA("TextLabel")) and (descLabel :: TextLabel) or nil,
		costPill = costPill,
		costPillGradient = (costPill and costPill:FindFirstChild("UIGradient") and costPill:FindFirstChild("UIGradient"):IsA("UIGradient"))
			and (costPill:FindFirstChild("UIGradient") :: UIGradient)
			or nil,
		costLabel = (costLabel and costLabel:IsA("TextLabel")) and (costLabel :: TextLabel) or nil,
		toggleDisplay = nil,
		toggleButton = nil,
		buyButton = buyButton :: GuiButton,
		baseTitle = titleLabel.Text,
		baseDescription = baseDescription,
	}

	-- Initial paint with `0` owned; the snapshot fetched below in
	-- `wireShipOil` will overwrite this within the same wire pass.
	refreshRunUpgradeCard1(0)

	-- BUY button: always buy more
	table.insert(conns, (buyButton :: GuiButton).Activated:Connect(function()
		ClientRemotes.requestPromptRobuxPurchase:FireServer({ itemId = RUN_UPGRADE_ITEM_ID })
	end))

	-- CostPill = OFF/ON toggle. Keep the authored pill as the visible base,
	-- then layer a display label plus a transparent hit target over it.
	local costPill = buyButton.Parent and buyButton.Parent:FindFirstChild("CostPill")
	if costPill and costPill:IsA("GuiObject") and costLabel and costLabel:IsA("TextLabel") then
		costLabel.Text = ""
		costLabel.ClipsDescendants = false
		local coinIcon = costPill:FindFirstChild("CoinIcon")
		if coinIcon and coinIcon:IsA("GuiObject") then
			coinIcon.Visible = false
		end

		local toggleDisplay = costLabel:FindFirstChild("SecurityToggleDisplay")
		if toggleDisplay and not toggleDisplay:IsA("TextLabel") then
			toggleDisplay:Destroy()
			toggleDisplay = nil
		end
		if not toggleDisplay then
			local display = Instance.new("TextLabel")
			display.Name = "SecurityToggleDisplay"
			display.AnchorPoint = Vector2.new(0, 0.5)
			display.Position = UDim2.new(-0.5, 0, 0.5, 0)
			display.Size = UDim2.new(2, 0, 1, 0)
			display.BorderSizePixel = 0
			display.TextColor3 = Color3.fromRGB(255, 255, 255)
			display.TextScaled = true
			display.BackgroundTransparency = 1
			display.Font = Enum.Font.GothamBold
			display.TextXAlignment = Enum.TextXAlignment.Center
			display.TextYAlignment = Enum.TextYAlignment.Center
			display.ZIndex = math.max(costPill.ZIndex + 2, costLabel.ZIndex + 2, buyButton.ZIndex + 1)
			display.Parent = costLabel

			local textConstraint = Instance.new("UITextSizeConstraint")
			textConstraint.MaxTextSize = 20
			textConstraint.MinTextSize = 12
			textConstraint.Parent = display

			toggleDisplay = display
		end

		local toggleButton = costLabel:FindFirstChild("ToggleHit")
		if toggleButton and not toggleButton:IsA("TextButton") then
			toggleButton:Destroy()
			toggleButton = nil
		end
		if not toggleButton then
			local hit = Instance.new("TextButton")
			hit.Name = "ToggleHit"
			hit.AnchorPoint = Vector2.new(0, 0.5)
			hit.Position = UDim2.new(-0.5, 0, 0.5, 0)
			hit.Size = UDim2.new(2, 0, 1, 0)
			hit.BackgroundTransparency = 1
			hit.AutoButtonColor = false
			hit.BorderSizePixel = 0
			hit.Text = ""
			hit.ZIndex = math.max(costPill.ZIndex + 3, costLabel.ZIndex + 3, buyButton.ZIndex + 2)
			hit.Parent = costLabel
			toggleButton = hit
		end

		runUpgradeCard1Binding.toggleDisplay = toggleDisplay :: TextLabel
		runUpgradeCard1Binding.toggleButton = toggleButton :: TextButton
		table.insert(conns, (toggleButton :: TextButton).Activated:Connect(function()
			-- The OFF/ON pill is *only* the arm-on-next-dispatch toggle —
			-- it never opens the Robux prompt. The purple BUY button on
			-- the right of the card owns the purchase flow. When the
			-- player owns nothing, clicking the toggle is a no-op (stays
			-- OFF) so they don't get a back-door purchase prompt from a
			-- mis-clicked toggle.
			if _securityOwnedCount > 0 then
				_useSecurityPersonnel = not _useSecurityPersonnel
			end
			refreshRunUpgradeCard1(_securityOwnedCount)
		end))
		refreshRunUpgradeCard1(_securityOwnedCount)
	end

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

--==============================================================================
-- RunUpgradeCard2 — Cargo Hauler (doubles next dispatch's barrels).
-- Authoring + behavior intentionally mirror `RunUpgradeCard1` (Security
-- Personnel) with a Studio-authored card under the same RunUpgradesSection;
-- the visible "armed" signal additionally lights up the footer's
-- TotalBarrels + ShipCapacity readouts in gold with "×2" via `refreshFooter`.
--==============================================================================

local cargoHaulerCard2Binding: {
	titleLabel: TextLabel,
	descriptionLabel: TextLabel?,
	costPill: GuiObject?,
	costPillGradient: UIGradient?,
	costLabel: TextLabel?,
	toggleDisplay: TextLabel?,
	toggleButton: TextButton?,
	buyButton: GuiButton,
	baseTitle: string,
	baseDescription: string,
}? = nil

local refreshRunUpgradeCard2: ((ownedCount: number) -> ())

refreshRunUpgradeCard2 = function(ownedCount: number)
	local b = cargoHaulerCard2Binding
	if not b then
		return
	end
	_cargoHaulerOwnedCount = math.max(0, math.floor(ownedCount))
	-- Unlike Security Personnel, dropping the owned count to 0 forces the
	-- arm flag back off so a stale "ON" pill can't carry across to the
	-- next purchase.
	if _cargoHaulerOwnedCount <= 0 then
		_useCargoHauler = false
	end
	if b.descriptionLabel then
		if _useCargoHauler then
			b.descriptionLabel.Text = string.format("ON - 1/%d will be used on dispatch", _cargoHaulerOwnedCount)
		elseif _cargoHaulerOwnedCount > 0 then
			b.descriptionLabel.Text = string.format("OFF - %d available", _cargoHaulerOwnedCount)
		else
			b.descriptionLabel.Text = b.baseDescription
		end
	end
	-- Same red/green pill paint as Card1 — green when armed, red when off.
	-- Keeps the two run-upgrade cards visually parallel.
	if b.costPill and b.costPill.Parent then
		b.costPill.BackgroundColor3 = if _useCargoHauler
			then Color3.fromRGB(46, 166, 74)
			else Color3.fromRGB(196, 64, 102)
		b.costPill.BackgroundTransparency = 0
	end
	if b.costPillGradient and b.costPillGradient.Parent then
		b.costPillGradient.Enabled = false
	end
	if b.toggleDisplay and b.toggleDisplay.Parent then
		b.toggleDisplay.Text = _useCargoHauler and "ON" or "OFF"
	end
end

--- Read `runUpgradeOwnedByItemId.cargo_hauler` defensively. Same shape as
--- the Security Personnel reader; missing/malformed payloads → 0 so the
--- card still repaints cleanly with no count.
local function readCargoHaulerOwnedFromSnapshot(snap: any): number
	if typeof(snap) ~= "table" then
		return 0
	end
	local owned = (snap :: any).runUpgradeOwnedByItemId
	if typeof(owned) ~= "table" then
		return 0
	end
	local n = (owned :: { [string]: any })[RUN_UPGRADE_CARGO_INVENTORY_ID]
	if typeof(n) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(n))
end

local function wireRunUpgradeCard2(screen: ScreenGui, conns: { RBXScriptConnection })
	local section = screen:FindFirstChild("RunUpgradesSection", true)
	local cards = section and section:FindFirstChild("RunUpgradeCards")
	local card = cards and cards:FindFirstChild("RunUpgradeCard2")
	if not (card and card:IsA("GuiObject")) then
		warn("[ShipOilPanel] RunUpgradeCard2 not found under " .. screen:GetFullName() .. " — Cargo Hauler buy CTA will not be wired.")
		return
	end

	-- Same `ComingSoonOverlay` policy as Card1: while Studio has the overlay
	-- attached, treat the product as unavailable.
	if card:FindFirstChild("ComingSoonOverlay") then
		cargoHaulerCard2Binding = nil
		return
	end

	local titleLabel = card:FindFirstChild("TitleLabel", true)
	local descLabel = card:FindFirstChild("DescriptionLabel", true)
	local costPill = card:FindFirstChild("CostPill", true)
	-- Studio's per-card cost label naming convention: `CostLabel<N>` matches
	-- the card index, falls back to any nested `TextLabel` inside the pill
	-- if a future re-author drops the suffix.
	local costLabel = costPill and (costPill:FindFirstChild("CostLabel2") or costPill:FindFirstChildWhichIsA("TextLabel", true))
	local buyButton = card:FindFirstChild("BuyButton", true)

	if not (titleLabel and titleLabel:IsA("TextLabel")) then
		warn("[ShipOilPanel] RunUpgradeCard2.TitleLabel missing — skipping wire.")
		return
	end
	if not (buyButton and buyButton:IsA("GuiButton")) then
		warn("[ShipOilPanel] RunUpgradeCard2.BuyButton missing — skipping wire.")
		return
	end

	local item = MonetizationCatalog.GetItem(RUN_UPGRADE_CARGO_ITEM_ID)
	if not item then
		warn(string.format(
			"[ShipOilPanel] MonetizationCatalog has no entry for %q — RunUpgradeCard2 will keep Studio placeholder text.",
			RUN_UPGRADE_CARGO_ITEM_ID
		))
		return
	end

	titleLabel.Text = (typeof(item.displayName) == "string" and item.displayName) or titleLabel.Text
	local baseDescription = if typeof(item.subtitle) == "string" and item.subtitle ~= ""
		then item.subtitle
		else "Doubles your next run's barrels"

	if costLabel and costLabel:IsA("TextLabel") then
		local price = item.robuxPrice
		if typeof(price) == "number" and price > 0 then
			costLabel.Text = string.format("R$%d", math.floor(price))
		else
			costLabel.Text = "R$—"
		end
	end

	-- Same purple chrome as Card1's BUY button.
	applyRobuxChromeToBuyButton(buyButton :: GuiButton, formatBuyButtonPrice(item))

	cargoHaulerCard2Binding = {
		titleLabel = titleLabel :: TextLabel,
		descriptionLabel = (descLabel and descLabel:IsA("TextLabel")) and (descLabel :: TextLabel) or nil,
		costPill = costPill,
		costPillGradient = (costPill and costPill:FindFirstChild("UIGradient") and costPill:FindFirstChild("UIGradient"):IsA("UIGradient"))
			and (costPill:FindFirstChild("UIGradient") :: UIGradient)
			or nil,
		costLabel = (costLabel and costLabel:IsA("TextLabel")) and (costLabel :: TextLabel) or nil,
		toggleDisplay = nil,
		toggleButton = nil,
		buyButton = buyButton :: GuiButton,
		baseTitle = titleLabel.Text,
		baseDescription = baseDescription,
	}

	refreshRunUpgradeCard2(0)

	-- BUY: open the Robux prompt for the catalog item — always buy more,
	-- regardless of current owned count.
	table.insert(conns, (buyButton :: GuiButton).Activated:Connect(function()
		ClientRemotes.requestPromptRobuxPurchase:FireServer({ itemId = RUN_UPGRADE_CARGO_ITEM_ID })
	end))

	-- CostPill = OFF/ON toggle. Same authoring trick as Card1: the Studio-
	-- authored pill becomes the visible base, we layer a display label
	-- + a transparent hit target that owns the click.
	if costPill and costPill:IsA("GuiObject") and costLabel and costLabel:IsA("TextLabel") then
		costLabel.Text = ""
		costLabel.ClipsDescendants = false
		local coinIcon = costPill:FindFirstChild("CoinIcon")
		if coinIcon and coinIcon:IsA("GuiObject") then
			coinIcon.Visible = false
		end

		local toggleDisplay = costLabel:FindFirstChild("CargoHaulerToggleDisplay")
		if toggleDisplay and not toggleDisplay:IsA("TextLabel") then
			toggleDisplay:Destroy()
			toggleDisplay = nil
		end
		if not toggleDisplay then
			local display = Instance.new("TextLabel")
			display.Name = "CargoHaulerToggleDisplay"
			display.AnchorPoint = Vector2.new(0, 0.5)
			display.Position = UDim2.new(-0.5, 0, 0.5, 0)
			display.Size = UDim2.new(2, 0, 1, 0)
			display.BorderSizePixel = 0
			display.TextColor3 = Color3.fromRGB(255, 255, 255)
			display.TextScaled = true
			display.BackgroundTransparency = 1
			display.Font = Enum.Font.GothamBold
			display.TextXAlignment = Enum.TextXAlignment.Center
			display.TextYAlignment = Enum.TextYAlignment.Center
			display.ZIndex = math.max(costPill.ZIndex + 2, costLabel.ZIndex + 2, buyButton.ZIndex + 1)
			display.Parent = costLabel
			local textConstraint = Instance.new("UITextSizeConstraint")
			textConstraint.MaxTextSize = 20
			textConstraint.MinTextSize = 12
			textConstraint.Parent = display
			toggleDisplay = display
		end

		local toggleButton = costLabel:FindFirstChild("ToggleHit")
		if toggleButton and not toggleButton:IsA("TextButton") then
			toggleButton:Destroy()
			toggleButton = nil
		end
		if not toggleButton then
			local hit = Instance.new("TextButton")
			hit.Name = "ToggleHit"
			hit.AnchorPoint = Vector2.new(0, 0.5)
			hit.Position = UDim2.new(-0.5, 0, 0.5, 0)
			hit.Size = UDim2.new(2, 0, 1, 0)
			hit.BackgroundTransparency = 1
			hit.AutoButtonColor = false
			hit.BorderSizePixel = 0
			hit.Text = ""
			hit.ZIndex = math.max(costPill.ZIndex + 3, costLabel.ZIndex + 3, buyButton.ZIndex + 2)
			hit.Parent = costLabel
			toggleButton = hit
		end

		cargoHaulerCard2Binding.toggleDisplay = toggleDisplay :: TextLabel
		cargoHaulerCard2Binding.toggleButton = toggleButton :: TextButton
		table.insert(conns, (toggleButton :: TextButton).Activated:Connect(function()
			-- Toggle is *only* the arm-on-next-dispatch flag — never opens
			-- a Robux prompt. The purple BUY button owns purchasing. A
			-- click while owned == 0 is a no-op (stays OFF) so the player
			-- doesn't get a back-door purchase prompt.
			if _cargoHaulerOwnedCount > 0 then
				_useCargoHauler = not _useCargoHauler
			end
			refreshRunUpgradeCard2(_cargoHaulerOwnedCount)
			-- Toggling Cargo Hauler changes:
			--   * Stepper AmountLabels → display × 2 in green (refreshRowUi)
			--   * Footer TotalBarrels + ShipCapacity → green doubled value (refreshFooter)
			--   * Pulsing ×2! badge visibility (refreshFooter)
			-- Repaint both immediately rather than waiting for the next
			-- snapshot tick so the toggle feels responsive.
			refreshRowUi()
			refreshFooter()
		end))
		refreshRunUpgradeCard2(_cargoHaulerOwnedCount)
	end

	-- Console-only failure surfacing for this card (mirrors Card1 — there
	-- is no per-card error toast; dispatch errors own the panel's
	-- `ErrorNotification`).
	table.insert(conns, ClientRemotes.monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local data = (payload :: any).data
		local itemId = (typeof(data) == "table" and (data :: any).itemId) or nil
		if itemId ~= RUN_UPGRADE_CARGO_ITEM_ID then
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
	-- Clear any FTUE hide-pass attribute markers + restore visibility on
	-- the previously-wired screen so the next bind (or a Studio reload)
	-- doesn't inherit a stale set of forcibly-hidden GuiObjects. Runs
	-- BEFORE the connection / state teardown so `wiredScreen` still
	-- points at the old screen here.
	if wiredScreen and wiredScreen.Parent then
		for _, d in ipairs(wiredScreen:GetDescendants()) do
			if d:IsA("GuiObject") and d:GetAttribute("FtueWaitPlotHidden") == true then
				d.Visible = true
				d:SetAttribute("FtueWaitPlotHidden", nil)
			end
		end
	end
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
	cargoHaulerCard2Binding = nil
	-- Reset arm flag + owned mirror so a new wire pass starts from a
	-- clean state (matches how `_useSecurityPersonnel` / `_securityOwnedCount`
	-- get re-derived from the next snapshot push).
	_useCargoHauler = false
	_cargoHaulerOwnedCount = 0
	-- Drop the captured per-field original colors so the next wire pass
	-- captures fresh against the new bound fields (the previous fields
	-- are stale once `rowBindings` is cleared above).
	table.clear(_amountFieldOriginalColor)
	-- Cancel the badge pulse and drop our refs. The TextLabel itself
	-- belongs to `totalBarrelsLabel` (cleared just above) and is destroyed
	-- when the panel tears down, but we explicitly nil-out so the next
	-- wire pass lazy-creates a fresh badge under the new label.
	if cargoHaulerBadgeTween then
		cargoHaulerBadgeTween:Cancel()
		cargoHaulerBadgeTween = nil
	end
	cargoHaulerBadge = nil
	cargoHaulerBadgeScale = nil
	hideErrorNotification()
	errorNotificationLabel = nil
end

--- Attribute marker stamped on every GuiObject that the FTUE
--- WaitPlotShipment hide pass forces invisible. Restoring visibility on
--- step-change scans for the marker so we never re-show GuiObjects that
--- some other system (panel modals, idle decorations) already hid.
local FTUE_PLOT_HIDE_ATTR = "FtueWaitPlotHidden"

--- Targeted hide list for the FTUE WaitPlotShipment leg. Names match
--- Studio-authored frames under `ShipOilPanelGui.Canvas.PanelHost.Panel.Body`
--- (and one nested capacity label). Everything not in this list — `Banner`
--- (panel header + close button), `HeaderDivider`, `CargoHeader` (the
--- "Cargo" subheader), `ShipCargoRowCrude`, `ShipFooterDivider`, and
--- `Footer` — stays visible so the panel still reads as the Ship Oil
--- panel; we just collapse the noisy widgets the new player can't act on.
--- Add a name here when a future Body section needs hiding during the
--- first-shipment leg.
local FTUE_WAIT_PLOT_HIDE_NAMES: { string } = {
	"ShipCargoRowRefined",
	"ShipCargoRowPremium",
	"ShipCapacityBand",
	"WarehouseCapacityLabel",
	"RunUpgradesSection",
	"InstantSellSection",
	"ShipmentCostBand",
}

local function applyFtueWaitPlotShipmentHide(screen: ScreenGui)
	local hideSet: { [string]: boolean } = {}
	for _, name in ipairs(FTUE_WAIT_PLOT_HIDE_NAMES) do
		hideSet[name] = true
	end
	for _, d in ipairs(screen:GetDescendants()) do
		if not d:IsA("GuiObject") then
			continue
		end
		if not hideSet[d.Name] then
			continue
		end
		if d.Visible then
			d:SetAttribute(FTUE_PLOT_HIDE_ATTR, true)
			d.Visible = false
		end
	end
end

local function clearFtueWaitPlotShipmentHide(screen: ScreenGui)
	for _, d in ipairs(screen:GetDescendants()) do
		if d:IsA("GuiObject") and d:GetAttribute(FTUE_PLOT_HIDE_ATTR) == true then
			d.Visible = true
			d:SetAttribute(FTUE_PLOT_HIDE_ATTR, nil)
		end
	end
end

local function applyFtueShipOilModeForStep(screen: ScreenGui, stepValue: any)
	if typeof(stepValue) == "string" and stepValue == FtueConfig.Step.WaitPlotShipment then
		applyFtueWaitPlotShipmentHide(screen)
	else
		clearFtueWaitPlotShipmentHide(screen)
	end
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
		-- Snapshot the Studio-authored color the first time we bind so the
		-- "warehouse full" red flip can restore the design color when capacity
		-- opens back up. Captured once per panel-resolve; subsequent re-binds
		-- keep the original snapshot so a previous red flash doesn't get
		-- frozen as the new "default."
		if warehouseCapacityLabelDefaultColor == nil then
			warehouseCapacityLabelDefaultColor = whCap.TextColor3
		end
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
			local maxBtnRaw = stepper:FindFirstChild("MaxButton", true)
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
			local maxButton: GuiButton? = (maxBtnRaw and maxBtnRaw:IsA("GuiButton")) and (maxBtnRaw :: GuiButton) or nil
			rowBindings[ch.Name] = {
				tier = tier,
				inventoryLabel = invLabel :: TextLabel,
				amountField = amountField,
				minus = minus :: GuiButton,
				plus = plus :: GuiButton,
				maxButton = maxButton,
			}
			StepperHold.bind(minus :: GuiButton, function()
				bumpTier(tier, -1)
			end, connections)
			StepperHold.bind(plus :: GuiButton, function()
				bumpTier(tier, 1)
			end, connections)
			if maxButton then
				-- Single-tap Activated (no StepperHold accel — Max is one-shot).
				table.insert(connections, maxButton.Activated:Connect(function()
					setMaxForTier(tier)
				end))
				attachColorFadeHover(maxButton, connections)
			end
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

	-- Security Personnel run-upgrade card — MUST wire before `oilStateUpdate` and
	-- before the `requestOilSnapshot` block so `runUpgradeCard1Binding` exists when
	-- those refresh the description (bundle grants +5 stacks were losing the first
	-- push because the binding was still nil, then `refreshRunUpgradeCard1(0)` in
	-- the late wire clobbered the right count until a second purchase re-pushed).
	wireRunUpgradeCard1(screen, connections)
	-- Cargo Hauler card. Same wire-before-snapshot ordering reasoning as
	-- Card1 — the binding must exist before the first `oilStateUpdate`
	-- packet refreshes it, otherwise the bundle-grant first-push gets
	-- silently lost and the panel paints "0 owned" until the next push.
	wireRunUpgradeCard2(screen, connections)

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
		-- RunUpgradeCard1/Card2 "Ready ×N" badges update in the same frame
		-- as a successful Robux receipt OR a dispatch consume.
		refreshRunUpgradeCard1(readRunUpgradeOwnedFromSnapshot(snap))
		refreshRunUpgradeCard2(readCargoHaulerOwnedFromSnapshot(snap))
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
				refreshRunUpgradeCard1(readRunUpgradeOwnedFromSnapshot(st))
				refreshRunUpgradeCard2(readCargoHaulerOwnedFromSnapshot(st))
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

	--- FTUE WaitPlotShipment hide pass. Apply on every step-change for
	--- the local player so the panel collapses to just the Crude row +
	--- Footer while the new player is on their first plot shipment, and
	--- restores the full layout the moment they advance to `WaitShipment`.
	--- Re-applies whenever the panel reopens (`Enabled` flip) so the hide
	--- survives Roblox re-instantiating sub-frames. Re-runs after the
	--- final `applyMerriweatherToPanelText` / row binds so we operate on
	--- the fully-resolved tree.
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		local function refresh()
			if not (wiredScreen == screen and screen.Parent) then
				return
			end
			applyFtueShipOilModeForStep(screen, localPlayer:GetAttribute(Constants.FtueStepAttribute))
		end
		refresh()
		table.insert(
			connections,
			localPlayer:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(refresh)
		)
		table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
			if screen.Enabled then
				refresh()
			end
		end))
	end
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
