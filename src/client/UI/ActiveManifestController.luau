--!strict
-- Drives **`PlayerGui.HUD.Canvas.ActiveManifestPanel`** from **`ShipmentVisualEvent`**:
-- `ManifestHudSnapshot` (server-authoritative manifest + optional per-incident tier loss), `ShipmentResolved` (idle).
-- Incidents: three fixed-height slots (preserves vertical space); clones **`IncidentRow_1`** archetype; **`LossChip`** only for tiers with barrel loss > 0.
-- Allowed runtime: **`Text`**, **`Visible`**, cloning from authored templates/rows (see `ui-architecture` world/manifest exception).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local ActiveManifestHud = require(script.Parent.ActiveManifestHud)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ManifestIncidentTitle = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("ManifestIncidentTitle"))

local TIER_ORDER = { "HeavyCrude", "LightSweet", "PremiumRefined" }

local ROW_FOR_TIER: { [string]: string } = {
	HeavyCrude = "LoadedRow_Heavy",
	LightSweet = "LoadedRow_Standard",
	PremiumRefined = "LoadedRow_Light",
}

local TIER_CHIP_COLOR: { [string]: Color3 } = {
	HeavyCrude = Color3.fromRGB(30, 25, 20),
	LightSweet = Color3.fromRGB(220, 180, 60),
	PremiumRefined = Color3.fromRGB(200, 200, 210),
}

local TITLE_ACTIVE = "ACTIVE MANIFEST"
local TITLE_IDLE = "No Active Shipment"

local playerGuiRef: PlayerGui? = nil
local panelRef: Frame? = nil
local archetypeRow: Frame? = nil
local chipArchetype: Frame? = nil
local activeShipmentId: string? = nil
local hydratedShipmentId: string? = nil
local lastPerBarrel = 1

local INCIDENT_SLOT_COUNT = 3
local nextIncidentSlotIndex = 0

-- Readable incident titles (Studio template was TextSize 8 / max 15; align clones + cached archetype here).
local INCIDENT_TITLE_TEXT_SIZE = 14
local INCIDENT_TITLE_CONSTRAINT_MIN = 10
local INCIDENT_TITLE_CONSTRAINT_MAX = 24

local function applyIncidentTitleReadability(tit: TextLabel)
	tit.TextSize = INCIDENT_TITLE_TEXT_SIZE
	local c = tit:FindFirstChildOfClass("UITextSizeConstraint")
	if c then
		c.MinTextSize = INCIDENT_TITLE_CONSTRAINT_MIN
		c.MaxTextSize = INCIDENT_TITLE_CONSTRAINT_MAX
	end
end

local function findHud(playerGui: PlayerGui): ScreenGui?
	local h = playerGui:FindFirstChild("HUD")
	if h and h:IsA("ScreenGui") then
		return h
	end
	local deep = playerGui:FindFirstChild("HUD", true)
	if deep and deep:IsA("ScreenGui") then
		return deep
	end
	return nil
end

local function resolvePanel(playerGui: PlayerGui): Frame?
	local hud = findHud(playerGui)
	local canvas = hud and hud:FindFirstChild("Canvas")
	local panel = canvas and canvas:FindFirstChild("ActiveManifestPanel")
	if panel and panel:IsA("Frame") then
		return panel
	end
	return nil
end

local function oilUnitsToBarrels(oilUnits: number, perBarrel: number): number
	local p = math.max(1, math.floor(perBarrel))
	return math.max(0, math.floor(math.max(0, oilUnits) / p))
end

local function sumOil(m: { [string]: any }?): number
	if typeof(m) ~= "table" then
		return 0
	end
	local t = 0
	for _, tier in ipairs(TIER_ORDER) do
		t += math.max(0, math.floor(tonumber(m[tier]) or 0))
	end
	return t
end

local function ensureArchetypes(panel: Frame)
	if archetypeRow and archetypeRow.Parent then
		return
	end
	if archetypeRow and not archetypeRow.Parent then
		archetypeRow = nil
	end
	if chipArchetype and not chipArchetype.Parent then
		chipArchetype = nil
	end
	local inc = panel:FindFirstChild("IncidentsSection")
	local body = inc and inc:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	local src: Frame? = nil
	local row1 = body:FindFirstChild("IncidentRow_1")
	if row1 and row1:IsA("Frame") then
		src = row1
	else
		local sgHud = StarterGui:FindFirstChild("HUD", true)
		local sgCanvas = sgHud and sgHud:FindFirstChild("Canvas")
		local sgPanel = sgCanvas and sgCanvas:FindFirstChild("ActiveManifestPanel")
		local sgInc = sgPanel and sgPanel:FindFirstChild("IncidentsSection")
		local sgBody = sgInc and sgInc:FindFirstChild("SectionBody")
		local alt = sgBody and sgBody:FindFirstChild("IncidentRow_1")
		if alt and alt:IsA("Frame") then
			src = alt
		end
	end
	if not (src and src:IsA("Frame")) then
		return
	end
	archetypeRow = src:Clone()
	archetypeRow.Name = "_IncidentRowArchetype"
	archetypeRow.Visible = false
	archetypeRow.Parent = panel
	if chipArchetype and chipArchetype.Parent then
		chipArchetype:Destroy()
	end
	chipArchetype = nil
	local top0 = archetypeRow:FindFirstChild("IncidentTop", true)
	local host0 = top0 and top0:FindFirstChild("LossChipsHost")
	local chip0 = host0 and host0:FindFirstChild("LossChip")
	if chip0 and chip0:IsA("Frame") then
		chipArchetype = chip0:Clone()
		chipArchetype.Name = "_LossChipArchetype"
		chipArchetype.Visible = false
		chipArchetype.Parent = panel
	end
	local titArc = archetypeRow:FindFirstChild("IncidentTop", true)
	titArc = titArc and titArc:FindFirstChild("IncidentTitle")
	if titArc and titArc:IsA("TextLabel") then
		applyIncidentTitleReadability(titArc)
	end
end

-- Idle / between shipments: remove runtime slot clones only; keep **`IncidentRow_1`** so the first voyage can build archetypes.
local function clearIncidentRuntimeSlots(panel: Frame)
	local inc = panel:FindFirstChild("IncidentsSection")
	local body = inc and inc:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	for _, ch in ipairs(body:GetChildren()) do
		if ch:IsA("Frame") and string.sub(ch.Name, 1, 13) == "IncidentSlot_" then
			ch:Destroy()
		end
	end
end

-- New shipment hydrate: strip template row + old slots before re-cloning from archetype.
local function clearIncidentHydrate(panel: Frame)
	local inc = panel:FindFirstChild("IncidentsSection")
	local body = inc and inc:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	for _, ch in ipairs(body:GetChildren()) do
		if ch:IsA("Frame") then
			local n = ch.Name
			if string.sub(n, 1, 12) == "IncidentRow_" or string.sub(n, 1, 13) == "IncidentSlot_" then
				ch:Destroy()
			end
		end
	end
end

local function layoutLossChips(host: Frame, lossOilByTier: { [string]: any }, perBarrel: number)
	for _, c in ipairs(host:GetChildren()) do
		if c.Name == "LossChip" then
			c:Destroy()
		end
	end
	if not chipArchetype then
		return
	end
	local order: { { tier: string, barrels: number } } = {}
	for _, tier in ipairs(TIER_ORDER) do
		local oil = math.max(0, math.floor(tonumber(lossOilByTier[tier]) or 0))
		local b = oilUnitsToBarrels(oil, perBarrel)
		if b > 0 then
			table.insert(order, { tier = tier, barrels = b })
		end
	end
	local n = #order
	if n == 0 then
		return
	end
	local gap = 0.012
	local padR = 0.008
	local avail = 1 - padR - gap * math.max(0, n - 1)
	local w = math.clamp(avail / n, 0.12, 0.28)
	for i, entry in ipairs(order) do
		local chip = chipArchetype:Clone()
		chip.Name = "LossChip"
		chip.Visible = true
		chip.Parent = host
		local k = n - i + 1
		local rightEdge = 1 - padR - (k - 1) * (w + gap)
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.Position = UDim2.new(rightEdge, 0, 0.5, 0)
		chip.Size = UDim2.new(w, 0, 0.82, 0)
		local ticon = chip:FindFirstChild("TierIcon")
		if ticon and ticon:IsA("ImageLabel") then
			local col = TIER_CHIP_COLOR[entry.tier] or Color3.fromRGB(90, 90, 90)
			ticon.Image = ""
			ticon.BackgroundColor3 = col
			ticon.BackgroundTransparency = 0
		end
		local lam = chip:FindFirstChild("LossAmount")
		if lam and lam:IsA("TextLabel") then
			lam.Text = "-" .. tostring(entry.barrels)
		end
	end
end

local function clearIncidentSlotRow(row: Frame)
	local top = row:FindFirstChild("IncidentTop")
	local tit = top and top:FindFirstChild("IncidentTitle")
	if tit and tit:IsA("TextLabel") then
		tit.Text = ""
		applyIncidentTitleReadability(tit)
	end
	local host = top and top:FindFirstChild("LossChipsHost")
	if host and host:IsA("Frame") then
		layoutLossChips(host, {}, math.max(1, lastPerBarrel))
	end
end

local function layoutIncidentSlotStack(body: Frame)
	local gap = 0.008
	local h = (1 - gap * math.max(0, INCIDENT_SLOT_COUNT - 1)) / INCIDENT_SLOT_COUNT
	for i = 1, INCIDENT_SLOT_COUNT do
		local row = body:FindFirstChild("IncidentSlot_" .. tostring(i))
		if row and row:IsA("Frame") then
			row.AnchorPoint = Vector2.new(0, 0)
			row.Position = UDim2.new(0, 0, (i - 1) * (h + gap), 0)
			row.Size = UDim2.new(1, 0, h, 0)
		end
	end
end

local function ensureIncidentSlots(panel: Frame)
	if not archetypeRow then
		return
	end
	local inc = panel:FindFirstChild("IncidentsSection")
	local body = inc and inc:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	for i = 1, INCIDENT_SLOT_COUNT do
		local row = archetypeRow:Clone()
		row.Name = "IncidentSlot_" .. tostring(i)
		row.Visible = true
		row.Parent = body
		clearIncidentSlotRow(row)
	end
	layoutIncidentSlotStack(body)
end

local function resolveIncidentTitle(inc: { [string]: any }): string
	if inc.totalLoss == true then
		return "Total loss"
	end
	local eid = inc.eventId
	if typeof(eid) == "string" and eid ~= "" then
		return ManifestIncidentTitle.fromEventId(eid)
	end
	return ManifestIncidentTitle.fromDisplayName(tostring(inc.title or ""))
end

local function fillNextIncidentSlot(panel: Frame, inc: { [string]: any }, lossOilByTier: { [string]: any }, perBarrel: number)
	local incSec = panel:FindFirstChild("IncidentsSection")
	local body = incSec and incSec:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	nextIncidentSlotIndex += 1
	if nextIncidentSlotIndex > INCIDENT_SLOT_COUNT then
		return
	end
	local row = body:FindFirstChild("IncidentSlot_" .. tostring(nextIncidentSlotIndex))
	if not row or not row:IsA("Frame") then
		return
	end
	local top = row:FindFirstChild("IncidentTop")
	local tit = top and top:FindFirstChild("IncidentTitle")
	if tit and tit:IsA("TextLabel") then
		tit.Text = resolveIncidentTitle(inc)
		applyIncidentTitleReadability(tit)
	end
	local host = top and top:FindFirstChild("LossChipsHost")
	if host and host:IsA("Frame") then
		layoutLossChips(host, lossOilByTier, perBarrel)
	end
end

local function setIdle(panel: Frame)
	activeShipmentId = nil
	hydratedShipmentId = nil
	nextIncidentSlotIndex = 0
	clearIncidentRuntimeSlots(panel)
	local mh = panel:FindFirstChild("ManifestHeader")
	local mtitle = mh and mh:FindFirstChild("ManifestTitle")
	if mtitle and mtitle:IsA("TextLabel") then
		mtitle.Text = TITLE_IDLE
	end
	for _, name in ipairs({ "LoadedSection", "IncidentsSection", "DeliverySection" }) do
		local sec = panel:FindFirstChild(name)
		if sec and sec:IsA("Frame") then
			sec.Visible = false
		end
	end
end

local function setActiveChrome(panel: Frame)
	local mh = panel:FindFirstChild("ManifestHeader")
	local mtitle = mh and mh:FindFirstChild("ManifestTitle")
	if mtitle and mtitle:IsA("TextLabel") then
		mtitle.Text = TITLE_ACTIVE
	end
	for _, name in ipairs({ "LoadedSection", "IncidentsSection", "DeliverySection" }) do
		local sec = panel:FindFirstChild(name)
		if sec and sec:IsA("Frame") then
			sec.Visible = true
		end
	end
end

local function applyLoadedAndDelivery(panel: Frame, dispatched: { [string]: any }, remaining: { [string]: any }, perBarrel: number)
	local loaded = panel:FindFirstChild("LoadedSection")
	local lb = loaded and loaded:FindFirstChild("SectionBody")
	if lb then
		for tier, rowName in pairs(ROW_FOR_TIER) do
			local row = lb:FindFirstChild(rowName)
			if row and row:IsA("Frame") then
				local oil = math.max(0, math.floor(tonumber(dispatched[tier]) or 0))
				local cnt = row:FindFirstChild("BarrelCount")
				if cnt and cnt:IsA("TextLabel") then
					cnt.Text = "x" .. tostring(oilUnitsToBarrels(oil, perBarrel))
				end
			end
		end
	end
	local ds = panel:FindFirstChild("DeliverySection")
	local db = ds and ds:FindFirstChild("SectionBody")
	if db then
		local netOil = sumOil(remaining)
		local netBarrels = oilUnitsToBarrels(netOil, perBarrel)
		for _, ch in ipairs(db:GetChildren()) do
			if ch:IsA("TextLabel") then
				ch.Text = string.format("Net %d barrels", netBarrels)
				break
			end
		end
	end
end

local function onManifestHudSnapshot(player: Player, data: { [string]: any })
	local panel = panelRef or resolvePanel(playerGuiRef :: PlayerGui)
	if not panel then
		return
	end
	panelRef = panel
	local sid = data.shipmentId
	if typeof(sid) ~= "string" then
		return
	end
	activeShipmentId = sid
	lastPerBarrel = math.max(1, math.floor(tonumber(data.perBarrelOil) or 1))
	local dispatched = data.dispatchedOilByTier
	local remaining = data.remainingOilByTier
	if typeof(dispatched) ~= "table" or typeof(remaining) ~= "table" then
		return
	end
	if sid ~= hydratedShipmentId then
		hydratedShipmentId = sid
		ensureArchetypes(panel)
		clearIncidentHydrate(panel)
		ensureIncidentSlots(panel)
		nextIncidentSlotIndex = 0
	end
	setActiveChrome(panel)
	applyLoadedAndDelivery(panel, dispatched, remaining, lastPerBarrel)
	local inc = data.incident
	if typeof(inc) == "table" then
		local lossOil = inc.lossOilByTier
		if typeof(lossOil) == "table" then
			fillNextIncidentSlot(panel, inc, lossOil, lastPerBarrel)
		end
	end
end

local function onShipmentResolved(_player: Player, data: { [string]: any })
	local sid = data.shipmentId
	if typeof(sid) == "string" and activeShipmentId and sid ~= activeShipmentId then
		return
	end
	local panel = panelRef or resolvePanel(playerGuiRef :: PlayerGui)
	if not panel then
		return
	end
	setIdle(panel)
end

local ActiveManifestController = {}

function ActiveManifestController.start(playerGui: PlayerGui)
	playerGuiRef = playerGui
	ActiveManifestHud.tryBind(playerGui)
	local panel = resolvePanel(playerGui)
	if panel then
		if not panelRef then
			panelRef = panel
			setIdle(panel)
		end
	end
end

function ActiveManifestController.onVisualPacket(kind: string, data: { [string]: any }, localPlayer: Player)
	if typeof(data) ~= "table" then
		return
	end
	if kind == "ManifestHudSnapshot" then
		onManifestHudSnapshot(localPlayer, data)
	elseif kind == "ShipmentResolved" then
		onShipmentResolved(localPlayer, data)
	end
end

return ActiveManifestController
