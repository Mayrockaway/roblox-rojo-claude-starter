--!strict
-- Ship oil cargo modal (`StarterGui.ShipOilPanelGui` → `PlayerGui`).
-- Inventory = refinery/plot storage (`OilStateService` `oilByTier`), not strait-side `WarehouseService` barrels.
-- UI counts whole barrels; manifest uses oil units (`barrels selected * PerBarrelOil`) to match `ConsumeManifest`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "ShipOilPanelGui"

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

--- Text used in Studio for the oil type (before script may overwrite with `hudShortLabel`).
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
local rowBindings: { [string]: {
	tier: string,
	inventoryLabel: TextLabel,
	amountLabel: TextLabel,
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
local cargoSubtotalLabel: TextLabel? = nil
local dispatchButton: GuiButton? = nil
local lastDispatchFire = 0.0
local requestDispatchShipmentEvent: RemoteEvent? = nil
-- Boat cooldown state: populated from snapshot (OilState.boatState/boatCooldownEndsAt) and
-- from OilActionResult("ERR_BOAT_COOLDOWN") payloads. os.clock()-based timestamps.
local latestBoatState: string? = nil
local latestBoatCooldownEndsAt: number? = nil
local defaultDispatchText: string? = nil

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

local function formatBarrelInventoryCount(count: number): string
	local n = math.max(0, math.floor(count))
	return string.format("%d Barrels", n)
end

-- One-time when wiring: brighter copy + stroke so "N Barrels" reads at parity with stepper amounts (Studio can still override defaults before bind).
local function emphasizeInventoryCountLabel(label: TextLabel)
	label.TextColor3 = Color3.fromRGB(218, 244, 255)
	label.Font = Enum.Font.GothamBold
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
	local title = QualityConfig.hudShortLabel(tier)
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
	for _, bind in pairs(rowBindings) do
		local tier = bind.tier
		local inv = maxBarrelsInRefineryForTier(tier)
		bind.inventoryLabel.Text = formatBarrelInventoryCount(inv)
		local s = math.min(selected[tier] or 0, inv)
		selected[tier] = s
		bind.amountLabel.Text = tostring(s)
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
		totalBarrelsLabel.Text = string.format("Total barrels: %d", totalBarrels)
	end
	if cargoSubtotalLabel then
		if totalBarrels > 0 then
			cargoSubtotalLabel.Text = string.format("%d barrel%s selected", totalBarrels, if totalBarrels == 1 then "" else "s")
		else
			cargoSubtotalLabel.Text = "No barrels selected"
		end
	end
	if dispatchButton then
		local fee = rs.dispatchFee
		local cap = rs.capacity
		local remaining = boatCooldownRemaining()
		local inCooldown = remaining > 0
			or latestBoatState == "cooldown"
			or latestBoatState == "swapping"
			or latestBoatState == "sailing"
		local can = oilLoad > 0 and latestCash >= fee and oilLoad <= cap and not inCooldown
		dispatchButton.Active = can
		dispatchButton.AutoButtonColor = can
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
	lastDispatchFire = now
	local oilLoad = sumSelectedOilUnits()
	local rs = resolvedStats()
	if oilLoad <= 0 or oilLoad > rs.capacity then
		return
	end
	if latestCash < rs.dispatchFee then
		return
	end
	if boatCooldownRemaining() > 0
		or latestBoatState == "cooldown"
		or latestBoatState == "swapping"
		or latestBoatState == "sailing"
	then
		return
	end
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
	shipmentCostLabel = nil
	totalBarrelsLabel = nil
	cargoSubtotalLabel = nil
	dispatchButton = nil
	requestDispatchShipmentEvent = nil
	wiredScreen = nil
	latestResolved = nil
end

local function wireShipOil(screen: ScreenGui)
	if wiredScreen == screen then
		return
	end
	disconnectAll()
	wiredScreen = screen

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
	local cargoRows = cargoSection and cargoSection:FindFirstChild("CargoRows")
	local sub = cargoSection and cargoSection:FindFirstChild("CargoSubtotalRow")
	if sub then
		if sub:IsA("TextLabel") then
			cargoSubtotalLabel = sub
		else
			local tl = sub:FindFirstChildWhichIsA("TextLabel", true)
			if tl and tl:IsA("TextLabel") then
				cargoSubtotalLabel = tl
			end
		end
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
			if not (minus and minus:IsA("GuiButton") and plus and plus:IsA("GuiButton") and amt and amt:IsA("TextLabel")) then
				continue
			end
			rowBindings[ch.Name] = {
				tier = tier,
				inventoryLabel = invLabel :: TextLabel,
				amountLabel = amt :: TextLabel,
				minus = minus :: GuiButton,
				plus = plus :: GuiButton,
			}
			table.insert(connections, (minus :: GuiButton).Activated:Connect(function()
				bumpTier(tier, -1)
			end))
			table.insert(connections, (plus :: GuiButton).Activated:Connect(function()
				bumpTier(tier, 1)
			end))
		end
	end

	if dispatchButton then
		table.insert(connections, dispatchButton.Activated:Connect(tryDispatch))
	end

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
			for _, k in ipairs(TIER_KEYS) do
				selected[k] = 0
			end
			refreshRowUi()
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

	clampSelectionsToInventory()
	refreshRowUi()
	refreshFooter()
end

function ShipOilPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	wireShipOil(ctrl.ScreenGui)
	return ctrl
end

function ShipOilPanel.screenName(): string
	return SCREEN_NAME
end

return ShipOilPanel
