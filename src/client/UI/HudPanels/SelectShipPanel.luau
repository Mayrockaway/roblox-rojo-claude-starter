--!strict
-- Select ship modal (`StarterGui.SelectShipPanelGui` → `PlayerGui`).
-- Populated from `BoatConfig`; selection persisted server-side (`OilStateService.selectedBoatTypeId`).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatConfig = require(Shared:WaitForChild("Config"):WaitForChild("BoatConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

local SCREEN_NAME = "SelectShipPanelGui"

local GOLD_STROKE = Color3.fromRGB(212, 178, 122)
local DEFAULT_STROKE = Color3.fromRGB(55, 95, 110)

local SelectShipPanel = {}

local wiredScreen: ScreenGui? = nil
local selectController: HudPanelTypes.HudPanelController? = nil
local connections: { RBXScriptConnection } = {}
local cardSelectButtons: { GuiButton } = {}
local selectedBoatTypeId = "RustSkiff"
local requestSetSelectedBoat: RemoteEvent? = nil
local lastSelectFire = 0.0

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

local function sortedBoatList(): { { boatTypeId: string, displayName: string, capacity: number } }
	local list: { { boatTypeId: string, displayName: string, capacity: number } } = {}
	for boatTypeId, def in pairs(BoatConfig.Boats) do
		table.insert(list, {
			boatTypeId = boatTypeId,
			displayName = def.displayName,
			capacity = def.capacity,
		})
	end
	table.sort(list, function(a, b)
		return a.capacity < b.capacity
	end)
	return list
end

local function boatTemplateModel(boatTypeId: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local byId = assets:FindFirstChild(boatTypeId)
	if byId and byId:IsA("Model") then
		return byId
	end
	local tanker = assets:FindFirstChild("Tanker")
	if tanker and tanker:IsA("Model") then
		return tanker
	end
	return nil
end

local function tryFillViewport(vp: ViewportFrame, boatTypeId: string)
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("Model") or c:IsA("BasePart") then
			c:Destroy()
		end
	end
	local template = boatTemplateModel(boatTypeId)
	if not template then
		return
	end
	local clone = template:Clone()
	clone.Parent = vp
	if clone:IsA("Model") and not clone.PrimaryPart then
		local pp = clone:FindFirstChildWhichIsA("BasePart", true)
		if pp and pp:IsA("BasePart") then
			clone.PrimaryPart = pp
		end
	end
	if clone:IsA("Model") and clone.PrimaryPart then
		clone:SetPrimaryPartCFrame(CFrame.new(0, 0, 0))
	end
	local cam = vp:FindFirstChildOfClass("Camera")
	if cam and clone:IsA("Model") and clone.PrimaryPart then
		local cf, size = clone:GetBoundingBox()
		local ext = size / 2
		local radius = math.max(ext.X, ext.Y, ext.Z, 1)
		local dist = radius * 2.8
		cam.CFrame = CFrame.lookAt(cf.Position + Vector3.new(dist, radius * 0.6, dist * 0.6), cf.Position)
	end
end

local function findSelectButton(card: Instance): GuiButton?
	local b = card:FindFirstChild("SelectShipCardButton", true)
	if b and b:IsA("GuiButton") then
		return b
	end
	b = card:FindFirstChild("SelectShipButton", true)
	if b and b:IsA("GuiButton") then
		return b
	end
	return nil
end

local function setCardSelectedVisual(card: Frame, selected: boolean)
	local stroke = card:FindFirstChild("CardStroke", true)
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = if selected then GOLD_STROKE else DEFAULT_STROKE
	end
end

local function refreshAllCardSelection(cards: { Frame })
	for _, card in ipairs(cards) do
		local id = card:GetAttribute("BoatTypeId")
		if typeof(id) == "string" then
			setCardSelectedVisual(card, id == selectedBoatTypeId)
		end
	end
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(cardSelectButtons)
	requestSetSelectedBoat = nil
	wiredScreen = nil
	selectController = nil
end

local function wireSelectShip(_playerGui: PlayerGui, screen: ScreenGui, ctrl: HudPanelTypes.HudPanelController)
	disconnectAll()
	wiredScreen = screen
	selectController = ctrl

	local templatesFolder = screen:FindFirstChild("Templates", true)
	local template = templatesFolder and templatesFolder:FindFirstChild("ShipSelectCardTemplate")
	local scroll = screen:FindFirstChild("ShipGridScroll", true)
	if not (template and template:IsA("GuiObject") and scroll and scroll:IsA("ScrollingFrame")) then
		return
	end

	for _, ch in ipairs(scroll:GetChildren()) do
		if ch:IsA("Frame") and string.sub(ch.Name, 1, #"ShipCard_") == "ShipCard_" then
			ch:Destroy()
		end
	end

	local cards: { Frame } = {}
	local boats = sortedBoatList()
	for _, entry in ipairs(boats) do
		local card = template:Clone()
		card.Name = "ShipCard_" .. entry.boatTypeId
		card.Visible = true
		card:SetAttribute("BoatTypeId", entry.boatTypeId)
		card.Parent = scroll

		local nameLabel = card:FindFirstChild("ShipCardName", true)
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = entry.displayName
		end
		local rarity = card:FindFirstChild("ShipCardRarity", true)
		if rarity and rarity:IsA("TextLabel") then
			rarity.Text = string.format("Capacity %d", entry.capacity)
		end

		local locked = card:FindFirstChild("LockedPill", true)
		if locked and locked:IsA("GuiObject") then
			locked.Visible = false
		end
		local owned = card:FindFirstChild("OwnedPill", true)
		if owned and owned:IsA("GuiObject") then
			owned.Visible = true
		end

		local vp = card:FindFirstChild("ShipCardViewport", true)
		if vp and vp:IsA("ViewportFrame") then
			tryFillViewport(vp, entry.boatTypeId)
		end

		local selBtn = findSelectButton(card)
		if selBtn then
			selBtn.Visible = true
			table.insert(cardSelectButtons, selBtn)
			local boatTypeId = entry.boatTypeId
			table.insert(connections, selBtn.Activated:Connect(function()
				local now = os.clock()
				if now - lastSelectFire < 0.35 then
					return
				end
				lastSelectFire = now
				local ev = requestSetSelectedBoat
				if ev then
					ev:FireServer({ boatTypeId = boatTypeId })
				end
			end))
		end

		if card:IsA("Frame") then
			table.insert(cards, card)
		end
	end

	local counter = screen:FindFirstChild("ShipsOwnedCounterLabel", true)
	if counter and counter:IsA("TextLabel") then
		counter.Text = string.format("%d / %d ships owned", #boats, #boats)
	end

	local rf = remotesFolder()
	requestSetSelectedBoat = rf:WaitForChild(RemoteNames.RequestSetSelectedBoat) :: RemoteEvent

	local snapFn = rf:FindFirstChild(RemoteNames.RequestOilSnapshot)
	if snapFn and snapFn:IsA("RemoteFunction") then
		local okSnap, pack = pcall(function()
			return (snapFn :: RemoteFunction):InvokeServer()
		end)
		if okSnap and typeof(pack) == "table" then
			local st = (pack :: any).state
			if typeof(st) == "table" and typeof(st.selectedBoatTypeId) == "string" and BoatConfig.Boats[st.selectedBoatTypeId] then
				selectedBoatTypeId = st.selectedBoatTypeId
			end
		end
	end

	local oilUp = rf:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
	table.insert(connections, oilUp.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then
			return
		end
		local id = (snap :: any).selectedBoatTypeId
		if typeof(id) == "string" and BoatConfig.Boats[id] then
			selectedBoatTypeId = id
			refreshAllCardSelection(cards)
		end
	end))

	refreshAllCardSelection(cards)
end

function SelectShipPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	if wiredScreen == ctrl.ScreenGui and selectController then
		return selectController
	end
	wireSelectShip(playerGui, ctrl.ScreenGui, ctrl)
	return ctrl
end

function SelectShipPanel.screenName(): string
	return SCREEN_NAME
end

return SelectShipPanel
