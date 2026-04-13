--!strict
-- Ship management modal (`StarterGui.ShipManagementPanelGui` → `PlayerGui`).
-- `ChangeShipButton` opens `SelectShipPanelGui` (bound from `SelectShipPanel`).
-- Stats, upgrade costs, BUY actions, and hero viewport sync from `OilStateUpdate` / snapshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))

local SelectShipPanel = require(script.Parent.SelectShipPanel)
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local HudTriggerHover = require(script.Parent.Parent.HudTriggerHover)
local ViewportShipFit = require(script.Parent.Parent.ViewportShipFit)

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

local requestUpgradeShipSpeed: RemoteEvent? = nil
local requestUpgradeShipCapacity: RemoteEvent? = nil

local lastSpeedUpgradeFire = 0.0
local lastCapacityUpgradeFire = 0.0

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

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

local function fillShipViewport(vp: ViewportFrame, skinId: string)
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("Model") or c:IsA("BasePart") then
			c:Destroy()
		end
	end

	local skin = ShipSkinCatalog.GetSkin(skinId)
	local templateName = skin.templateName
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(templateName)
	if not (template and template:IsA("Model")) then
		template = assets and assets:FindFirstChild("Tanker")
	end
	if not (template and template:IsA("Model")) then
		return
	end

	local clone = template:Clone()
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
	if clone.PrimaryPart then
		local function applyFit()
			ViewportShipFit.frameModelInViewport(vp, clone, nil)
		end
		applyFit()
		task.defer(applyFit)
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

	if speedValueLabel then
		speedValueLabel.Text = string.format("%d/%d", speedLevel, ShipUpgradeConfig.MaxSpeedLevel)
	end
	if capacityValueLabel then
		capacityValueLabel.Text = string.format("%d/%d", capLevel, ShipUpgradeConfig.MaxCapacityLevel)
	end

	local speedCost = (snap :: any).upgradeShipSpeedCost
	local capCost = (snap :: any).upgradeShipCapacityCost
	local speedNum = tonumber(speedCost)
	local capNum = tonumber(capCost)

	if speedCostLabel then
		if speedNum and speedNum > 0 then
			speedCostLabel.Text = tostring(math.floor(speedNum))
		else
			speedCostLabel.Text = "MAX"
		end
	end
	if capacityCostLabel then
		if capNum and capNum > 0 then
			capacityCostLabel.Text = tostring(math.floor(capNum))
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
		local canBuy = capNum ~= nil and capNum > 0 and cash >= capNum
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
	else
		speedBuyButton = nil
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
	else
		capacityBuyButton = nil
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

	local rf = remotesFolder()
	requestUpgradeShipSpeed = rf:WaitForChild(RemoteNames.RequestUpgradeShipSpeed) :: RemoteEvent
	requestUpgradeShipCapacity = rf:WaitForChild(RemoteNames.RequestUpgradeShipCapacity) :: RemoteEvent

	if speedBuyButton then
		table.insert(connections, speedBuyButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastSpeedUpgradeFire < 0.4 then
				return
			end
			lastSpeedUpgradeFire = now
			if requestUpgradeShipSpeed then
				requestUpgradeShipSpeed:FireServer()
			end
		end))
	end

	if capacityBuyButton then
		table.insert(connections, capacityBuyButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastCapacityUpgradeFire < 0.4 then
				return
			end
			lastCapacityUpgradeFire = now
			if requestUpgradeShipCapacity then
				requestUpgradeShipCapacity:FireServer()
			end
		end))
	end

	local oilUp = rf:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
	table.insert(connections, oilUp.OnClientEvent:Connect(function(snap: any)
		if wiredScreen and wiredScreen.Enabled then
			applyShipManagementUi(snap)
		end
	end))

	table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			local snapFn = rf:FindFirstChild(RemoteNames.RequestOilSnapshot)
			if snapFn and snapFn:IsA("RemoteFunction") then
				local ok, pack = pcall(function()
					return (snapFn :: RemoteFunction):InvokeServer()
				end)
				if ok and typeof(pack) == "table" and typeof((pack :: any).state) == "table" then
					applyShipManagementUi((pack :: any).state)
				end
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
		local rf = remotesFolder()
		local snapFn = rf:FindFirstChild(RemoteNames.RequestOilSnapshot)
		if snapFn and snapFn:IsA("RemoteFunction") then
			local ok, pack = pcall(function()
				return (snapFn :: RemoteFunction):InvokeServer()
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
