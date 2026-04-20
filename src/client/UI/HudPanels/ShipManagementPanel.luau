--!strict
-- Ship management modal (`StarterGui.ShipManagementPanelGui` → `PlayerGui`).
-- `ChangeShipButton` opens `SelectShipPanelGui` (bound from `SelectShipPanel`).
-- Stats, upgrade costs, BUY actions, and hero viewport sync from `OilStateUpdate` / snapshot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
}

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
--- Hero ship preview slot. Currently authored as a `ViewportFrame` (legacy 3D
--- preview path) **or** as an `ImageLabel` (icon-based path, post-swap). Held
--- as `GuiObject` so the resolver can accept either; `fillShipViewport` /
--- icon-paint code branch on the actual class. Kept nullable so the panel
--- stays bound even if a designer removes the slot temporarily.
local shipViewport: GuiObject? = nil
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

--- `ErrorNotification` is an authored `TextLabel` under `Canvas.PanelHost` (red,
--- with `UIStroke`). Studio leaves it `Visible = true` so the designer can
--- position / restyle it; we hide it on `wireShipManagement` and surface it
--- only when an upgrade fails. `errorNotificationSeq` lets a fresh message
--- cancel the previous fade-out so back-to-back errors do not flicker.
local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

--- Cached from the latest snapshot so the buy-button click handler can do an
--- instant client-side preflight (`cash >= cost?`) without waiting for the
--- server's `oilActionResult` round-trip. The server is still authoritative —
--- we also listen for `ERR_NOT_ENOUGH_CASH` from `oilActionResult` to catch
--- cases where the local snapshot is stale.
local latestCash: number = 0
local latestSpeedUpgradeCost: number? = nil
local latestCapacityUpgradeCost: number? = nil

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
	-- Cancel any in-flight fade and drop the cached label so the next bind
	-- (potentially against a fresh `ScreenGui` instance) re-resolves it.
	errorNotificationSeq += 1
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
	end
	errorNotificationLabel = nil
	latestCash = 0
	latestSpeedUpgradeCost = nil
	latestCapacityUpgradeCost = nil
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

--- Match `ShipOilPanel.showErrorNotification` so error UX feels identical
--- across the dock modals: hold the message at full opacity for `holdSeconds`,
--- then fade `TextTransparency → 1` over 0.35s. `errorNotificationSeq` cancels
--- any in-flight fade if a newer message comes in (avoids flicker on rapid
--- repeat clicks of the BUY button while broke).
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

--- Single source of truth for "you can't afford this upgrade" UX: the red
--- toast + the project-standard deny SFX. Server `message` (e.g. "Need $1200
--- to upgrade speed.") is preferred over the client fallback so currency /
--- copy stays in sync with `OilStateService:TryUpgradeShip*`.
local function showInsufficientCashError(message: string?)
	local text = (typeof(message) == "string" and message ~= "" and message)
		or "Not enough cash for this upgrade."
	showErrorNotification(text, 4.0)
	UiSfx.playUiDenied()
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

	-- Cache for the buy-button preflight (`showInsufficientCashError`). Live
	-- snapshot wins over any value the click handler computes locally.
	latestCash = cash
	latestSpeedUpgradeCost = speedNum
	latestCapacityUpgradeCost = capNum

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

	-- Keep `Active = true` while NOT maxed so the click handler runs even when
	-- the player can't afford the upgrade — that's how `showInsufficientCashError`
	-- gets a chance to fire. Only fully disable input at MAX (no upgrade to
	-- attempt). `AutoButtonColor` mirrors affordability for visual feedback.
	if speedBuyButton then
		local atMax = speedLevel >= ShipUpgradeConfig.MaxSpeedLevel
		local canAfford = speedNum ~= nil and speedNum > 0 and cash >= speedNum
		speedBuyButton.Active = not atMax
		speedBuyButton.AutoButtonColor = canAfford
	end
	if capacityBuyButton then
		local atMax = capLevel >= ShipUpgradeConfig.MaxCapacityLevel
		local canAfford = false
		if capNum ~= nil and not atMax then
			if capNum == 0 then
				canAfford = true
			elseif capNum > 0 then
				canAfford = cash >= capNum
			end
		end
		capacityBuyButton.Active = not atMax
		capacityBuyButton.AutoButtonColor = canAfford
	end

	if shipNameHeader then
		shipNameHeader.Text = ShipSkinCatalog.GetSkin(skinId).displayName
	end
	if shipViewport then
		-- Two authoring paths supported:
		--   * `ViewportFrame` (legacy 3D preview) — clone + fit the hull.
		--   * `ImageLabel` (post-viewport-swap icon shell) — paint the per-skin
		--     `icon` from `ShipSkinCatalog`. When the skin has no `icon` we
		--     leave `Image = ""` so a missing asset reads as the empty grey
		--     shell rather than a broken-image badge.
		if shipViewport:IsA("ViewportFrame") then
			fillShipViewport(shipViewport, skinId)
		elseif shipViewport:IsA("ImageLabel") then
			local iconAsset = ShipSkinCatalog.GetSkin(skinId).icon
			shipViewport.Image = if typeof(iconAsset) == "string" then iconAsset else ""
		end
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

	-- `ShipViewport` may be a `ViewportFrame` (legacy 3D preview) or an
	-- `ImageLabel` (post-swap icon shell). Accept either; the fill-time branch
	-- (`fillShipViewport` vs. the upcoming icon writer) decides what to do.
	local vpHolder = screen:FindFirstChild("ShipViewportHolder", true)
	local vp = vpHolder and vpHolder:FindFirstChild("ShipViewport")
	if vp and vp:IsA("GuiObject") then
		shipViewport = vp
	else
		local vpAny = findFirstNamed(screen, { "ShipViewport" })
		shipViewport = if vpAny and vpAny:IsA("GuiObject") then vpAny else nil
	end

	local nameHdr = findFirstNamed(screen, { "ShipNameHeader", "shipnameheader" })
	shipNameHeader = if nameHdr and nameHdr:IsA("TextLabel") then nameHdr else nil

	-- Studio authors `Canvas.PanelHost.ErrorNotification` `Visible = true` so it
	-- can be positioned + restyled in Edit mode. We hide on bind and only
	-- surface it on a failed BUY.
	local errLabel = screen:FindFirstChild("ErrorNotification", true)
	errorNotificationLabel = if errLabel and errLabel:IsA("TextLabel") then errLabel else nil
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
		errorNotificationLabel.TextTransparency = 0
	end

	if speedBuyButton then
		table.insert(connections, speedBuyButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastSpeedUpgradeFire < 0.4 then
				return
			end
			-- Client-side preflight: instant feedback while broke. Server is
			-- still authoritative — `oilActionResult` `ERR_NOT_ENOUGH_CASH`
			-- below catches the case where `latestSnap` is stale.
			local cost = latestSpeedUpgradeCost
			if cost and cost > 0 and latestCash < cost then
				lastSpeedUpgradeFire = now
				showInsufficientCashError(string.format(
					"Not enough cash. Need $%d to upgrade speed (you have $%d).",
					math.floor(cost),
					math.floor(latestCash)
				))
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
			-- Cargo can be FREE (FTUE first upgrade): only short-circuit the
			-- request when there is a real positive cost the player can't pay.
			local cost = latestCapacityUpgradeCost
			if cost and cost > 0 and latestCash < cost then
				lastCapacityUpgradeFire = now
				showInsufficientCashError(string.format(
					"Not enough cash. Need $%d to upgrade capacity (you have $%d).",
					math.floor(cost),
					math.floor(latestCash)
				))
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

	-- Defense-in-depth for the click-side preflight: surface the server's
	-- `ERR_NOT_ENOUGH_CASH` for ship Speed / Capacity upgrades when the local
	-- snapshot was stale (race between `oilStateUpdate` and the click). The
	-- server's `message` already contains the exact required amount.
	table.insert(connections, ClientRemotes.oilActionResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if not (wiredScreen and wiredScreen.Enabled) then
			return
		end
		local action = (payload :: any).action
		if action ~= "UpgradeShipSpeed" and action ~= "UpgradeShipCapacity" then
			return
		end
		if (payload :: any).ok == false and (payload :: any).code == "ERR_NOT_ENOUGH_CASH" then
			showInsufficientCashError((payload :: any).message)
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
			-- Modal closed: cancel any pending fade so the next open does not
			-- inherit a half-faded message.
			hideErrorNotification()
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
