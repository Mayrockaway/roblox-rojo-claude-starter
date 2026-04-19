--!strict
-- Ship management modal (`StarterGui.ShipManagementPanelGui` → `PlayerGui`).
-- `ChangeShipButton` opens `SelectShipPanelGui` (bound from `SelectShipPanel`).
-- Stats, upgrade costs, BUY actions, and hero viewport sync from `OilStateUpdate` / snapshot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))
local SelectShipPanel = require(script.Parent.SelectShipPanel)
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local HudTriggerHover = require(script.Parent.Parent.HudTriggerHover)
local ViewportShipFit = require(script.Parent.Parent.ViewportShipFit)
local ShipViewportPreviewFactory = require(script.Parent.Parent.ShipViewportPreviewFactory)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()

local SCREEN_NAME = "ShipManagementPanelGui"

local ShipManagementPanel = {}

local changeShipConnection: RBXScriptConnection? = nil
local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}

local speedValueLabel: TextLabel? = nil
local capacityValueLabel: TextLabel? = nil
local speedCostLabel: TextLabel? = nil
local capacityCostLabel: TextLabel? = nil
local speedBuyButton: GuiButton? = nil
local capacityBuyButton: GuiButton? = nil
local shipViewport: ViewportFrame? = nil
local shipNameHeader: TextLabel? = nil

-- Right-column placard accessories: 8 segment frames per placard plus the level
-- subtitle and next-tier preview labels. Set in `wireShipManagement` from the
-- authored `SpeedLevelProgress` / `CapacityLevelProgress` subtrees.
local speedLevelSegments: { Frame } = {}
local capacityLevelSegments: { Frame } = {}
local speedLevelSubtitle: TextLabel? = nil
local capacityLevelSubtitle: TextLabel? = nil
-- After the `TierLabel` was removed and the placard condensed, `PlacardDescription`
-- now serves as the next-level preview line ("Next Level: 40s" / "Next Level: 24 bbls").
-- The original standalone `Speed/CapacityNextValueLabel` instances are still looked
-- up so legacy panels keep working — they're hidden in the current Studio layout but
-- remain wired in case a designer re-enables them.
local speedNextValueLabel: TextLabel? = nil
local capacityNextValueLabel: TextLabel? = nil
local speedDescriptionLabel: TextLabel? = nil
local capacityDescriptionLabel: TextLabel? = nil

-- Sampled from the authored `Segment1` (filled, gold) and `Segment8` (empty, navy)
-- in `StarterGui.ShipManagementPanelGui` so the live tint matches whatever the
-- designer set, but kept as constants here so we can re-render without re-reading
-- the panel each tick. If the panel is re-tinted, refresh these to keep parity.
local SEGMENT_FILLED_COLOR = Color3.fromRGB(218, 175, 55)
local SEGMENT_FILLED_TRANSPARENCY = 0
local SEGMENT_EMPTY_COLOR = Color3.fromRGB(16, 24, 42)
local SEGMENT_EMPTY_TRANSPARENCY = 0.35

local lastSpeedUpgradeFire = 0.0
local lastCapacityUpgradeFire = 0.0

--- `fillShipViewport` used to run on **every** `oilStateUpdate` — each pass cloned the full tanker into
--- the `ViewportFrame` and called `GetBoundingBox()` (brutal on Union-heavy rigs). Only rebuild when
--- `skinId` changes; defer clone + fit so opening the panel does not freeze a single frame for seconds.
local viewportFilledSkinId: string? = nil
local viewportFillJob = 0

local function passthroughDecorationsToTrigger(btn: GuiButton)
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			d.Active = false
		end
	end
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	viewportFillJob += 1
	viewportFilledSkinId = nil
end

local function findFirstNamed(root: Instance, names: { string }): Instance?
	for _, n in ipairs(names) do
		local d = root:FindFirstChild(n, true)
		if d then
			return d
		end
	end
	return nil
end

--- Walk `placard → progressName → BarHost → Segment1..SegmentN` and return the
--- segment frames in numeric `Name` order. Returns an empty table if the progress
--- subtree isn't present (e.g. legacy panel layout) so the caller can no-op.
--- Tolerates `Segment` vs `segment` casing and gaps in the numbering.
local function collectLevelSegments(placard: Instance, progressName: string): { Frame }
	local out: { Frame } = {}
	local progress = placard:FindFirstChild(progressName, true)
	if not progress then
		return out
	end
	local host = progress:FindFirstChild("BarHost", true) or progress
	local indexed: { [number]: Frame } = {}
	local maxIndex = 0
	for _, child in ipairs(host:GetChildren()) do
		if child:IsA("Frame") then
			local n = tonumber(string.match(child.Name, "^[Ss]egment(%d+)$"))
			if n then
				indexed[n] = child
				if n > maxIndex then maxIndex = n end
			end
		end
	end
	for i = 1, maxIndex do
		local seg = indexed[i]
		if seg then
			table.insert(out, seg)
		end
	end
	return out
end

local function getViewportShipModel(vp: ViewportFrame): Model?
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("Model") then
			return c
		end
	end
	return nil
end

local function fillShipViewport(vp: ViewportFrame, skinId: string)
	local cur = getViewportShipModel(vp)
	if cur and viewportFilledSkinId == skinId then
		return
	end

	viewportFillJob += 1
	local job = viewportFillJob
	task.defer(function()
		if job ~= viewportFillJob then
			return
		end
		if not vp.Parent then
			return
		end
		local again = getViewportShipModel(vp)
		if again and viewportFilledSkinId == skinId then
			return
		end

		for _, c in ipairs(vp:GetChildren()) do
			if c:IsA("Model") or c:IsA("BasePart") then
				c:Destroy()
			end
		end

		local skin = ShipSkinCatalog.GetSkin(skinId)
		local templateName = skin.templateName
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local fullTemplate: Model? = nil
		if assets and assets:IsA("Folder") then
			local t = assets:FindFirstChild(templateName)
			if t and t:IsA("Model") then
				fullTemplate = t
			else
				local fb = assets:FindFirstChild("Tanker")
				if fb and fb:IsA("Model") then
					fullTemplate = fb
				end
			end
		end

		local sourceModel = ShipViewportPreviewFactory.resolveViewportSourceModel(assets, templateName, fullTemplate)
		local clone = sourceModel:Clone()
		clone.Parent = vp
		if not clone.PrimaryPart then
			local pp = clone:FindFirstChildWhichIsA("BasePart", true)
			if pp and pp:IsA("BasePart") then
				clone.PrimaryPart = pp
			end
		end
		if clone.PrimaryPart then
			clone:SetPrimaryPartCFrame(CFrame.new(0, 0, 0))
		end
		if job ~= viewportFillJob or not clone.PrimaryPart then
			clone:Destroy()
			viewportFilledSkinId = nil
			return
		end

		viewportFilledSkinId = skinId
		local function applyFit()
			if clone.Parent == vp and clone.PrimaryPart then
				ViewportShipFit.frameModelInViewport(vp, clone, nil)
			end
		end
		applyFit()
		task.defer(applyFit)
	end)
end

--- Tint the first `level` segments as filled (gold), the rest as empty (navy w/
--- transparency). Mutates `BackgroundColor3` + `BackgroundTransparency` only —
--- the authored `UICorner`, layout, and stroke are preserved. No-op if the
--- segments table is empty (e.g. panel hasn't bound yet).
local function paintLevelBar(segments: { Frame }, level: number, maxLevel: number)
	if #segments == 0 then
		return
	end
	local filled = math.clamp(math.floor(level), 0, maxLevel)
	for i, seg in ipairs(segments) do
		if i <= filled then
			seg.BackgroundColor3 = SEGMENT_FILLED_COLOR
			seg.BackgroundTransparency = SEGMENT_FILLED_TRANSPARENCY
		else
			seg.BackgroundColor3 = SEGMENT_EMPTY_COLOR
			seg.BackgroundTransparency = SEGMENT_EMPTY_TRANSPARENCY
		end
	end
end

local function applyShipManagementUi(snap: any)
	if typeof(snap) ~= "table" then
		return
	end

	local speedLevel = math.clamp(math.floor(tonumber((snap :: any).shipSpeedLevel) or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
	local capLevel = math.clamp(math.floor(tonumber((snap :: any).shipCapacityLevel) or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
	local skinId = if typeof((snap :: any).shipSkinId) == "string" then (snap :: any).shipSkinId else "DefaultTanker"
	local cash = tonumber((snap :: any).cash) or 0

	-- Resolve the actual gameplay numbers (prefer the snapshot's `resolvedShip`
	-- which the server sends authoritative; fall back to the local `ShipStats`
	-- resolver if absent so the panel still renders before the first OilStateUpdate).
	local rs = (snap :: any).resolvedShip
	local travelSec: number?
	local cargoUnits: number?
	if typeof(rs) == "table" then
		travelSec = tonumber((rs :: any).travelSeconds)
		cargoUnits = tonumber((rs :: any).capacity)
	end
	local resolved = ShipStats.Resolve(speedLevel, capLevel)
	if travelSec == nil then
		travelSec = resolved.travelSeconds
	end
	if cargoUnits == nil then
		cargoUnits = resolved.capacity
	end

	-- Stat pills: raw current values (the small chip next to the SPEED / CAPACITY
	-- title). Format chosen by product: `XXs` for voyage seconds, `XX bbls` plural.
	if speedValueLabel then
		speedValueLabel.Text = string.format("%ds", math.floor((travelSec or 0) + 0.5))
	end
	if capacityValueLabel then
		capacityValueLabel.Text = string.format("%d bbls", math.floor((cargoUnits or 0) + 0.5))
	end

	-- 8-segment progress bars on each placard: fill `level` of `maxLevel` segments.
	paintLevelBar(speedLevelSegments, speedLevel, ShipUpgradeConfig.MaxSpeedLevel)
	paintLevelBar(capacityLevelSegments, capLevel, ShipUpgradeConfig.MaxCapacityLevel)

	-- Subtitle line under the bar: "Level N / 8 total upgrades". `MAX` when capped
	-- so the subtitle and the cost pill agree.
	if speedLevelSubtitle then
		if speedLevel >= ShipUpgradeConfig.MaxSpeedLevel then
			speedLevelSubtitle.Text = string.format("MAX (%d / %d)", speedLevel, ShipUpgradeConfig.MaxSpeedLevel)
		else
			speedLevelSubtitle.Text = string.format("Level %d / %d total upgrades", speedLevel, ShipUpgradeConfig.MaxSpeedLevel)
		end
	end
	if capacityLevelSubtitle then
		if capLevel >= ShipUpgradeConfig.MaxCapacityLevel then
			capacityLevelSubtitle.Text = string.format("MAX (%d / %d)", capLevel, ShipUpgradeConfig.MaxCapacityLevel)
		else
			capacityLevelSubtitle.Text = string.format("Level %d / %d total upgrades", capLevel, ShipUpgradeConfig.MaxCapacityLevel)
		end
	end

	-- Next-tier preview. Two display surfaces:
	--   * `PlacardDescription` (current condensed layout): "Next Level: 40s" / "Next Level: 24 bbls"
	--   * `Speed/CapacityNextValueLabel` (legacy standalone label, hidden in current Studio
	--     layout but kept wired so re-enabling it Just Works).
	-- Hide the preview at max level rather than showing a nonsense duplicate of the
	-- current value — for the description we use "Maxed Out" so it reads as a sentence.
	local nextSpeedText: string
	local descSpeedText: string
	if speedLevel >= ShipUpgradeConfig.MaxSpeedLevel then
		nextSpeedText = "Next: —"
		descSpeedText = "Maxed Out"
	else
		local nextSec = ShipUpgradeConfig.GetTravelSeconds(speedLevel + 1)
		nextSpeedText = string.format("Next: %ds", math.floor(nextSec + 0.5))
		descSpeedText = string.format("Next Level: %ds", math.floor(nextSec + 0.5))
	end
	if speedNextValueLabel then
		speedNextValueLabel.Text = nextSpeedText
	end
	if speedDescriptionLabel then
		speedDescriptionLabel.Text = descSpeedText
	end

	local nextCapText: string
	local descCapText: string
	if capLevel >= ShipUpgradeConfig.MaxCapacityLevel then
		nextCapText = "Next: —"
		descCapText = "Maxed Out"
	else
		local nextCap = ShipUpgradeConfig.GetCargoCapacity(capLevel + 1)
		nextCapText = string.format("Next: %d bbls", math.floor(nextCap + 0.5))
		descCapText = string.format("Next Level: %d bbls", math.floor(nextCap + 0.5))
	end
	if capacityNextValueLabel then
		capacityNextValueLabel.Text = nextCapText
	end
	if capacityDescriptionLabel then
		capacityDescriptionLabel.Text = descCapText
	end

	local speedCost = (snap :: any).upgradeShipSpeedCost
	local capCost = (snap :: any).upgradeShipCapacityCost
	local speedNum = tonumber(speedCost)
	local capNum = tonumber(capCost)

	--- `tonumber(0)` is **0** (truthy in Luau). `cost and cost > 0` is false for 0, so we must not treat 0 as "MAX".
	if speedCostLabel then
		if speedLevel >= ShipUpgradeConfig.MaxSpeedLevel then
			speedCostLabel.Text = "MAX"
		elseif speedNum ~= nil and speedNum > 0 then
			speedCostLabel.Text = tostring(math.floor(speedNum))
		elseif speedNum == 0 then
			speedCostLabel.Text = "FREE"
		else
			speedCostLabel.Text = "MAX"
		end
	end
	if capacityCostLabel then
		if capLevel >= ShipUpgradeConfig.MaxCapacityLevel then
			capacityCostLabel.Text = "MAX"
		elseif capNum ~= nil and capNum > 0 then
			capacityCostLabel.Text = tostring(math.floor(capNum))
		elseif capNum == 0 then
			capacityCostLabel.Text = "FREE"
		else
			capacityCostLabel.Text = "MAX"
		end
	end

	if speedBuyButton then
		local canBuy = speedNum ~= nil and speedNum > 0 and cash >= speedNum
		speedBuyButton.Active = canBuy
		speedBuyButton.AutoButtonColor = canBuy
	end
	if capacityBuyButton then
		local canBuy = false
		if capNum ~= nil and capLevel < ShipUpgradeConfig.MaxCapacityLevel then
			if capNum == 0 then
				canBuy = true
			elseif capNum > 0 then
				canBuy = cash >= capNum
			end
		end
		capacityBuyButton.Active = canBuy
		capacityBuyButton.AutoButtonColor = canBuy
	end

	if shipNameHeader then
		shipNameHeader.Text = ShipSkinCatalog.GetSkin(skinId).displayName
	end
	if shipViewport then
		fillShipViewport(shipViewport, skinId)
	end
end

local function wireShipManagement(screen: ScreenGui)
	disconnectAll()
	wiredScreen = screen

	local speedLbl = findFirstNamed(screen, { "SpeedValueLabel", "speedvaluelabel", "SpeedStatValue" })
	if speedLbl and speedLbl:IsA("TextLabel") then
		speedValueLabel = speedLbl
	else
		speedValueLabel = nil
	end

	local capLbl = findFirstNamed(screen, { "CapacityValueLabel", "capacityvaluelabel", "CapacityStatValue" })
	if capLbl and capLbl:IsA("TextLabel") then
		capacityValueLabel = capLbl
	else
		capacityValueLabel = nil
	end

	local speedCost = findFirstNamed(screen, { "SpeedUpgradeCostLabel", "speedupgradecostlabel" })
	if speedCost and speedCost:IsA("TextLabel") then
		speedCostLabel = speedCost
	else
		speedCostLabel = nil
	end

	local capCost = findFirstNamed(screen, { "CapacityUpgradeCostLabel", "capacityupgradecostlabel" })
	if capCost and capCost:IsA("TextLabel") then
		capacityCostLabel = capCost
	else
		capacityCostLabel = nil
	end

	local speedPlacard = screen:FindFirstChild("SpeedUpgradePlacard", true)
	if speedPlacard then
		local buy = speedPlacard:FindFirstChild("PlacardBuyButton", true)
		if buy and buy:IsA("GuiButton") then
			speedBuyButton = buy
			passthroughDecorationsToTrigger(buy)
			HudTriggerHover.attach(buy)
		else
			speedBuyButton = nil
		end
		speedLevelSegments = collectLevelSegments(speedPlacard, "SpeedLevelProgress")
		local sub = speedPlacard:FindFirstChild("SpeedLevelSubtitle", true)
		speedLevelSubtitle = if sub and sub:IsA("TextLabel") then sub else nil
		local nxt = speedPlacard:FindFirstChild("SpeedNextValueLabel", true)
		speedNextValueLabel = if nxt and nxt:IsA("TextLabel") then nxt else nil
		local desc = speedPlacard:FindFirstChild("PlacardDescription", true)
		speedDescriptionLabel = if desc and desc:IsA("TextLabel") then desc else nil
	else
		speedBuyButton = nil
		speedLevelSegments = {}
		speedLevelSubtitle = nil
		speedNextValueLabel = nil
		speedDescriptionLabel = nil
	end

	local capPlacard = screen:FindFirstChild("CapacityUpgradePlacard", true)
	if capPlacard then
		local buy = capPlacard:FindFirstChild("PlacardBuyButton", true)
		if buy and buy:IsA("GuiButton") then
			capacityBuyButton = buy
			passthroughDecorationsToTrigger(buy)
			HudTriggerHover.attach(buy)
		else
			capacityBuyButton = nil
		end
		capacityLevelSegments = collectLevelSegments(capPlacard, "CapacityLevelProgress")
		local sub = capPlacard:FindFirstChild("CapacityLevelSubtitle", true)
		capacityLevelSubtitle = if sub and sub:IsA("TextLabel") then sub else nil
		local nxt = capPlacard:FindFirstChild("CapacityNextValueLabel", true)
		capacityNextValueLabel = if nxt and nxt:IsA("TextLabel") then nxt else nil
		local desc = capPlacard:FindFirstChild("PlacardDescription", true)
		capacityDescriptionLabel = if desc and desc:IsA("TextLabel") then desc else nil
	else
		capacityBuyButton = nil
		capacityLevelSegments = {}
		capacityLevelSubtitle = nil
		capacityNextValueLabel = nil
		capacityDescriptionLabel = nil
	end

	local vpHolder = screen:FindFirstChild("ShipViewportHolder", true)
	local vp = vpHolder and vpHolder:FindFirstChild("ShipViewport")
	if vp and vp:IsA("ViewportFrame") then
		shipViewport = vp
	else
		local vpAny = findFirstNamed(screen, { "ShipViewport" })
		shipViewport = if vpAny and vpAny:IsA("ViewportFrame") then vpAny else nil
	end

	local nameHdr = findFirstNamed(screen, { "ShipNameHeader", "shipnameheader" })
	shipNameHeader = if nameHdr and nameHdr:IsA("TextLabel") then nameHdr else nil

	if speedBuyButton then
		table.insert(connections, speedBuyButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastSpeedUpgradeFire < 0.4 then
				return
			end
			lastSpeedUpgradeFire = now
			ClientRemotes.requestUpgradeShipSpeed:FireServer()
		end))
	end

	if capacityBuyButton then
		table.insert(connections, capacityBuyButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastCapacityUpgradeFire < 0.4 then
				return
			end
			lastCapacityUpgradeFire = now
			ClientRemotes.requestUpgradeShipCapacity:FireServer()
		end))
	end

	table.insert(connections, ClientRemotes.oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if wiredScreen and wiredScreen.Enabled then
			applyShipManagementUi(snap)
		end
	end))

	table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			local plr = Players.LocalPlayer
			--- FTUE: `DockmanOpened` must run **before** the first snapshot so server reports free capacity cost.
			--- `ProximityPanelOpener` fires after `openScreen`, so we advance the sub-step here then defer pull.
			if
				plr
				and plr:GetAttribute(Constants.FtueStepAttribute) == FtueConfig.Step.WaitDocksUpgradeShip
				and plr:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute) == "Dockman"
			then
				ClientRemotes.requestFtueDocksProgress:FireServer("DockmanOpened")
				task.defer(function()
					if not screen.Enabled then
						return
					end
					local ok, pack = pcall(function()
						return ClientRemotes.requestOilSnapshot:InvokeServer()
					end)
					if ok and typeof(pack) == "table" and typeof((pack :: any).state) == "table" then
						applyShipManagementUi((pack :: any).state)
					end
				end)
			else
				local ok, pack = pcall(function()
					return ClientRemotes.requestOilSnapshot:InvokeServer()
				end)
				if ok and typeof(pack) == "table" and typeof((pack :: any).state) == "table" then
					applyShipManagementUi((pack :: any).state)
				end
			end
		else
			local plr = Players.LocalPlayer
			if
				plr
				and plr:GetAttribute(Constants.FtueStepAttribute) == FtueConfig.Step.WaitDocksUpgradeShip
				and plr:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute) == "CloseModal"
			then
				ClientRemotes.requestFtueDocksProgress:FireServer("ShipPanelClosed")
			end
		end
	end))
end

function ShipManagementPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local selectCtrl = SelectShipPanel.bind(playerGui)

	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	if changeShipConnection then
		changeShipConnection:Disconnect()
		changeShipConnection = nil
	end

	if ctrl.ScreenGui ~= wiredScreen then
		disconnectAll()
	end

	wireShipManagement(ctrl.ScreenGui)

	local changeShip = ctrl.ScreenGui:FindFirstChild("ChangeShipButton", true)
	if changeShip and changeShip:IsA("GuiButton") then
		passthroughDecorationsToTrigger(changeShip)
		HudTriggerHover.attach(changeShip)
		changeShipConnection = changeShip.Activated:Connect(function()
			if selectCtrl then
				selectCtrl.Open()
			end
		end)
	end

	-- Initial fill when panel is already enabled (e.g. first open via router).
	if ctrl.ScreenGui.Enabled then
		local plr = Players.LocalPlayer
		if
			plr
			and plr:GetAttribute(Constants.FtueStepAttribute) == FtueConfig.Step.WaitDocksUpgradeShip
			and plr:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute) == "Dockman"
		then
			ClientRemotes.requestFtueDocksProgress:FireServer("DockmanOpened")
			task.defer(function()
				if not ctrl.ScreenGui.Enabled then
					return
				end
				local ok, pack = pcall(function()
					return ClientRemotes.requestOilSnapshot:InvokeServer()
				end)
				if ok and typeof(pack) == "table" and typeof((pack :: any).state) == "table" then
					applyShipManagementUi((pack :: any).state)
				end
			end)
		else
			local ok, pack = pcall(function()
				return ClientRemotes.requestOilSnapshot:InvokeServer()
			end)
			if ok and typeof(pack) == "table" and typeof((pack :: any).state) == "table" then
				applyShipManagementUi((pack :: any).state)
			end
		end
	end

	return ctrl
end

function ShipManagementPanel.screenName(): string
	return SCREEN_NAME
end

return ShipManagementPanel
