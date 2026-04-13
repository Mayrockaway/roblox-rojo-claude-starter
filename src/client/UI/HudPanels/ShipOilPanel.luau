--!strict
-- Ship oil cargo modal (`StarterGui.ShipOilPanelGui` → `PlayerGui`).
-- Inventory = refinery/plot storage (`OilStateService` `oilByTier`), not strait-side `WarehouseService` barrels.
-- UI counts whole barrels; manifest uses oil units (`barrels selected * PerBarrelOil`) to match `ConsumeManifest`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatConfig = require(Shared:WaitForChild("Config"):WaitForChild("BoatConfig"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "ShipOilPanelGui"

-- Studio row names → manifest tier keys (UI order: Heavy → Light Sweet → Premium).
local ROW_NAME_TO_TIER: { [string]: string } = {
	ShipCargoRowHeavy = "HeavyCrude",
	ShipCargoRowLight = "LightSweet",
	ShipCargoRowStandard = "PremiumRefined",
	ShipCargoRowPremium = "PremiumRefined",
	-- Aliases if hierarchy still uses strait-market names (binds one tier per row).
	ShipCargoRowCrude = "HeavyCrude",
	ShipCargoRowLightSweet = "LightSweet",
	ShipCargoRowPremiumRefined = "PremiumRefined",
}

local ROW_FRAME_TITLE: { [string]: string } = {
	ShipCargoRowHeavy = "Heavy Crude",
	ShipCargoRowLight = "Light Sweet",
	ShipCargoRowStandard = "Premium Refined",
	ShipCargoRowPremium = "Premium Refined",
	ShipCargoRowCrude = "Heavy Crude",
	ShipCargoRowLightSweet = "Light Sweet",
	ShipCargoRowPremiumRefined = "Premium Refined",
}

local TIER_KEYS = { "HeavyCrude", "StandardCrude", "LightSweet", "PremiumRefined" }

local ShipOilPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
local rowBindings: { [string]: {
	inventoryLabel: TextLabel,
	amountLabel: TextLabel,
	minus: GuiButton,
	plus: GuiButton,
} } = {}

-- Raw oil units at home refinery (same keys / semantics as `OilStateService` server state).
local refineryOilByTier: { [string]: number } = {
	HeavyCrude = 0,
	StandardCrude = 0,
	LightSweet = 0,
	PremiumRefined = 0,
}

local function perBarrelOilUnits(): number
	local barrelsCfg = OilConfig.Barrels
	local n = (barrelsCfg and barrelsCfg.PerBarrelOil) or 1
	return math.max(1, math.floor(n))
end
local selected: { [string]: number } = {
	HeavyCrude = 0,
	StandardCrude = 0,
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

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

local function sortedBoats(): { { boatTypeId: string, capacity: number, dispatchFee: number } }
	local list: { { boatTypeId: string, capacity: number, dispatchFee: number } } = {}
	for boatTypeId, def in pairs(BoatConfig.Boats) do
		table.insert(list, {
			boatTypeId = boatTypeId,
			capacity = def.capacity,
			dispatchFee = def.dispatchFee,
		})
	end
	table.sort(list, function(a, b)
		return a.capacity < b.capacity
	end)
	return list
end

local function maxBoatCapacity(): number
	local m = 0
	for _, def in pairs(BoatConfig.Boats) do
		m = math.max(m, def.capacity)
	end
	return m
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

-- `BoatConfig` capacity is in oil units (same as manifest / `OilStateService:CanConsumeManifest`).
local function pickBoatForLoad(oilUnits: number): { boatTypeId: string, capacity: number, dispatchFee: number }?
	if oilUnits <= 0 then
		return nil
	end
	local boats = sortedBoats()
	for _, b in ipairs(boats) do
		if b.capacity >= oilUnits then
			return b
		end
	end
	return boats[#boats]
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

local function applyCargoRowTitles(row: Instance)
	local title = ROW_FRAME_TITLE[row.Name]
	if not title then
		return
	end
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
	for tier, bind in pairs(rowBindings) do
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
	local boat = pickBoatForLoad(oilLoad)
	if shipmentCostLabel then
		if boat then
			shipmentCostLabel.Text = string.format("Shipment Cost: $%d", boat.dispatchFee)
		else
			shipmentCostLabel.Text = "Shipment Cost: —"
		end
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
		local fee = boat and boat.dispatchFee or 0
		local can = oilLoad > 0 and boat ~= nil and latestCash >= fee and oilLoad <= maxBoatCapacity()
		dispatchButton.Active = can
		dispatchButton.AutoButtonColor = can
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
		if sumSelectedOilUnits() + per > maxBoatCapacity() then
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
	local boat = pickBoatForLoad(oilLoad)
	if not boat or oilLoad <= 0 then
		return
	end
	if oilLoad > boat.capacity then
		return
	end
	if latestCash < boat.dispatchFee then
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
			boatTypeId = boat.boatTypeId,
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
		for _, ch in ipairs(cargoRows:GetChildren()) do
			if not ch:IsA("GuiObject") then
				continue
			end
			local tier = ROW_NAME_TO_TIER[ch.Name]
			if not tier then
				continue
			end
			applyCargoRowTitles(ch)
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
			rowBindings[tier] = {
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
		end
	end))

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
