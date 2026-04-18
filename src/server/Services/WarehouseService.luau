--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)
local DataStoreWriteGate = require(script.Parent.Parent.Utils.DataStoreWriteGate)
local WarehouseConfig = require(Shared:WaitForChild("Config"):WaitForChild("WarehouseConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local WarehouseService = {}

local WOOD_SIGN_MODEL_NAME = "Minecraft Wood Sign"
local WOOD_SIGN_RIG_FOLDER = "WarehouseWoodSignRig"
local WOOD_SIGN_CLICK_NAME = "TankUpgradeSignClick"
local WAREHOUSE_TERMINAL_NAME = "WarehouseTerminal"
local MAX_WAREHOUSE_TIER = #WarehouseConfig.Tiers

local function normalizeInstanceName(name: string): string
	return string.lower((name:gsub("%s+", "")))
end

-- Desk / monitor / terminal for upgrade UI: attribute, name variants, or ProximityPrompt text (must run BEFORE stripping prompts).
local function findWarehouseTerminalAnchor(visual: Model): Instance?
	for _, d in ipairs(visual:GetDescendants()) do
		if d:GetAttribute("IsWarehouseTerminal") == true then
			return d
		end
	end
	for _, d in ipairs(visual:GetDescendants()) do
		local n = normalizeInstanceName(d.Name)
		if n == "warehouseterminal" or n == "warehouseterminaldesk" then
			return d
		end
	end
	local legacy = visual:FindFirstChild(WAREHOUSE_TERMINAL_NAME, true)
	if legacy then
		return legacy
	end
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			local blob = string.lower(tostring(d.ActionText) .. " " .. tostring(d.ObjectText))
			if string.find(blob, "upgrade", 1, true) and string.find(blob, "warehouse", 1, true) then
				local p: Instance? = d.Parent
				while p and not (p:IsA("BasePart") or p:IsA("Model")) do
					if p == visual then
						p = nil
						break
					end
					p = p.Parent
				end
				if p then
					return p
				end
			end
		end
	end
	return nil
end

local function stripAllProximityPromptsInWarehouse(visual: Model)
	-- Prompts authored on the template (e.g. SellOilPrompt on UpgradeTerminal) opt out
	-- of the legacy strip via attribute `KeepProximityPrompt = true`. See
	-- `src/client/UI/ProximityPanelOpener.luau` for the trigger contract.
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d:GetAttribute("KeepProximityPrompt") ~= true then
			d:Destroy()
		end
	end
end

local function pivotSignModelAboveTerminal(signModel: Model, terminal: Instance)
	local halfSignY = 2
	pcall(function()
		local _, sz = signModel:GetBoundingBox()
		halfSignY = sz.Y / 2
	end)
	local gap = 0.75
	if terminal:IsA("BasePart") then
		local cf = terminal :: BasePart
		local topY = cf.Position.Y + cf.Size.Y / 2
		local pos = Vector3.new(cf.Position.X, topY + halfSignY + gap, cf.Position.Z)
		local rot = cf.CFrame - cf.CFrame.Position
		signModel:PivotTo(CFrame.new(pos) * rot)
	elseif terminal:IsA("Model") then
		local m = terminal :: Model
		local tcf, size = m:GetBoundingBox()
		local topY = tcf.Position.Y + size.Y / 2
		local pos = Vector3.new(tcf.Position.X, topY + halfSignY + gap, tcf.Position.Z)
		local rot = tcf - tcf.Position
		signModel:PivotTo(CFrame.new(pos) * rot)
	end
end

local TIER_ORDER = { "HeavyCrude", "LightSweet", "PremiumRefined" }
local SAVE_INTERVAL = 25
local AUTOSAVE_START_OFFSET_SECONDS = 12
local MIN_DATASTORE_SET_INTERVAL_SECONDS = 7
local FLUSH_MULTI_USER_SPACING_SECONDS = 0.2

local function emptyBarrelMap()
	return { HeavyCrude = 0, LightSweet = 0, PremiumRefined = 0 }
end

local function copyBarrelMap(src)
	local out = emptyBarrelMap()
	for _, tier in ipairs(TIER_ORDER) do
		out[tier] = math.max(0, math.floor(tonumber(src and src[tier]) or 0))
	end
	return out
end

local function isDatastoreStudioAccessError(err: any): boolean
	local s = tostring(err)
	return string.find(s, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(s, "API access is not enabled", 1, true) ~= nil
		or string.find(s, "Cannot write to DataStore", 1, true) ~= nil
		or string.find(s, "Cannot read from DataStore", 1, true) ~= nil
end

local function totalBarrels(barrels)
	local t = 0
	for _, tier in ipairs(TIER_ORDER) do
		t += barrels[tier] or 0
	end
	return t
end

local function totalBarrelsCombined(baseBarrels, overflowBarrels)
	return totalBarrels(baseBarrels) + totalBarrels(overflowBarrels)
end

function WarehouseService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
	self._stateByUserId = {}
	self._slotByUserId = {}
	self._userBySlot = {}
	self._visualByUserId = {}
	self._slots = {}
	self._dirtyByUserId = {}
	self._memoryStore = {}
	self._dataStoreStudioFallbackWarned = false
	self._lastWarehouseDataStoreSaveClock = {} :: { [number]: number }
	self._dataStore = nil
	self._devSkipSaveOnNextDrop = {} :: { [number]: boolean }
	self._woodSignPrototype = nil :: Model?
	self._woodSignTemplateWarned = false
	self._hookedWarehouseWoodSigns = {} :: { [BasePart]: boolean }
	local okStore, storeOrErr = pcall(function()
		return DataStoreService:GetDataStore(WarehouseConfig.DataStoreName)
	end)
	if okStore then
		self._dataStore = storeOrErr
	else
		warn("[WarehouseService] DataStore unavailable; using memory fallback:", storeOrErr)
	end

	-- Discover slot markers
	local finishPlot = Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("FinishPlot")
	local slotsFolder = finishPlot and finishPlot:FindFirstChild("WarehouseSlots")
	if slotsFolder then
		for _, slot in ipairs(slotsFolder:GetChildren()) do
			if slot:IsA("BasePart") and slot:GetAttribute("SlotId") then
				table.insert(self._slots, {
					slotId = slot:GetAttribute("SlotId"),
					position = slot.Position,
					part = slot,
				})
			end
		end
		table.sort(self._slots, function(a, b) return a.slotId < b.slotId end)
	end

	-- Load warehouse template
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	self._template = assets and assets:FindFirstChild("WarehouseTemplate")

	print(string.format("[WarehouseService] %d slots, template=%s", #self._slots, tostring(self._template ~= nil)))
end

function WarehouseService:Start()
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end))

	-- Remotes
	local upgradeEvent = self._remoteService:GetEvent(RemoteNames.RequestUpgradeWarehouse)
	table.insert(self._connections, upgradeEvent.OnServerEvent:Connect(function(player)
		self:TryUpgrade(player.UserId, player)
	end))

	-- RequestSellAllWarehouse is deprecated — selling handled by OilMarketService

	local teleportEvent = self._remoteService:GetEvent(RemoteNames.RequestTeleportToWarehouse)
	table.insert(self._connections, teleportEvent.OnServerEvent:Connect(function(player)
		self:_teleportToWarehouse(player)
	end))

	local warehouseSnapshotFn = self._remoteService:GetFunction(RemoteNames.RequestWarehouseSnapshot)
	warehouseSnapshotFn.OnServerInvoke = function(player: Player)
		local data = self:GetWarehouseForClient(player.UserId)
		if data then
			return data
		end
		return {
			tier = 1,
			maxTier = MAX_WAREHOUSE_TIER,
			barrels = emptyBarrelMap(),
			capacity = WarehouseConfig.GetCapacity(1),
			totalBarrels = 0,
			slotId = nil,
			upgradeCost = WarehouseConfig.GetUpgradeCost(1),
		}
	end

	-- Autosave (offset from oil autosave to avoid paired bursts for the same user)
	task.spawn(function()
		task.wait(AUTOSAVE_START_OFFSET_SECONDS)
		while true do
			task.wait(SAVE_INTERVAL)
			self:_flushDirty(false)
		end
	end)

	-- Catch up with existing players
	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end
end

function WarehouseService:Stop()
	self:_flushDirty(true)
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	self._connections = {}
	self._hookedWarehouseWoodSigns = {}
end

function WarehouseService:_onPlayerAdded(player: Player)
	local userId = player.UserId
	local persisted = self:_loadProfile(userId)

	local state = {
		tier = 1,
		barrels = emptyBarrelMap(),
		hitOverflowBarrels = emptyBarrelMap(),
		slotId = nil,
	}

	if persisted then
		state.tier = math.clamp(persisted.tier or 1, 1, #WarehouseConfig.Tiers)
		if typeof(persisted.barrels) == "table" then
			local pb = persisted.barrels :: { [string]: any }
			local legacyStandard = math.max(0, math.floor(tonumber(pb.StandardCrude) or 0))
			for _, tier in ipairs(TIER_ORDER) do
				state.barrels[tier] = math.max(0, math.floor(tonumber(pb[tier]) or 0))
			end
			if legacyStandard > 0 then
				state.barrels.HeavyCrude = (state.barrels.HeavyCrude or 0) + legacyStandard
			end
		end
		if typeof((persisted :: any).hitOverflowBarrels) == "table" then
			local ob = (persisted :: any).hitOverflowBarrels :: { [string]: any }
			for _, tier in ipairs(TIER_ORDER) do
				state.hitOverflowBarrels[tier] = math.max(0, math.floor(tonumber(ob[tier]) or 0))
			end
		end
		state.slotId = persisted.slotId
	end

	-- Assign a slot
	if state.slotId and self._userBySlot[state.slotId] then
		state.slotId = nil -- slot taken by someone else
	end
	if not state.slotId then
		state.slotId = self:_claimNextSlot(userId)
	else
		self._userBySlot[state.slotId] = userId
	end

	self._stateByUserId[userId] = state
	self._slotByUserId[userId] = state.slotId

	-- Spawn the warehouse visual
	self:_spawnWarehouseVisual(userId)
	self:_syncBarrelVisuals(userId)
	self:PushState(userId)
end

function WarehouseService:_onPlayerRemoving(player: Player)
	local userId = player.UserId
	if self._devSkipSaveOnNextDrop[userId] then
		self._devSkipSaveOnNextDrop[userId] = nil
	else
		-- Same as oil: persist latest warehouse row on leave even if last autosave cleared dirty.
		-- Brief delay: `PlotService` `PlayerRemoving` runs first and oil may `SetAsync` the same second;
		-- spacing warehouse writes reduces "Key (x2)" DataStore queue pairing in Studio (still not an error).
		task.wait(0.12)
		self:_saveProfile(userId, true, true)
	end

	-- Release slot
	local slotId = self._slotByUserId[userId]
	if slotId then
		self._userBySlot[slotId] = nil
	end

	-- Destroy visual
	local visual = self._visualByUserId[userId]
	if visual and visual.Parent then
		visual:Destroy()
	end
	self._visualByUserId[userId] = nil
	self._stateByUserId[userId] = nil
	self._slotByUserId[userId] = nil
	self._dirtyByUserId[userId] = nil
end

function WarehouseService:_claimNextSlot(userId: number): number?
	for _, slot in ipairs(self._slots) do
		if not self._userBySlot[slot.slotId] then
			self._userBySlot[slot.slotId] = userId
			return slot.slotId
		end
	end
	return nil
end

function WarehouseService:_getSlotPosition(slotId: number): Vector3?
	for _, slot in ipairs(self._slots) do
		if slot.slotId == slotId then
			return slot.position
		end
	end
	return nil
end

function WarehouseService:_getWoodSignPrototype(): Model?
	if self._woodSignPrototype and self._woodSignPrototype.Parent then
		return self._woodSignPrototype
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local direct = assets:FindFirstChild("WarehouseUpgradeWoodSign")
	if direct and direct:IsA("Model") then
		self._woodSignPrototype = direct
		return direct
	end
	local oilTanks = assets:FindFirstChild("OilTanksTemplate")
	if oilTanks then
		for _, d in ipairs(oilTanks:GetDescendants()) do
			if d:IsA("Model") and d.Name == WOOD_SIGN_MODEL_NAME then
				self._woodSignPrototype = d
				return d
			end
		end
	end
	return nil
end

function WarehouseService:_fireWarehouseUpgradeResult(player: Player, ok: boolean, code: string, message: string, data: any?)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "UpgradeWarehouse",
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function WarehouseService:_syncWoodSignGui(signPart: BasePart, userId: number)
	local state = self._stateByUserId[userId]
	if not state or not signPart.Parent then
		return
	end
	local surfaceGui = signPart:FindFirstChildOfClass("SurfaceGui")
	if surfaceGui then
		surfaceGui.Active = false
		local signLabel = surfaceGui:FindFirstChild("SIGN")
		if not (signLabel and signLabel:IsA("TextLabel")) then
			for _, ui in ipairs(surfaceGui:GetDescendants()) do
				if ui:IsA("TextLabel") then
					signLabel = ui
					break
				end
			end
		end
		if signLabel and signLabel:IsA("TextLabel") then
			local cap = WarehouseConfig.GetCapacity(state.tier)
			local total = totalBarrels(state.barrels)
			local nextCost = WarehouseConfig.GetUpgradeCost(state.tier)
			if state.tier >= MAX_WAREHOUSE_TIER or nextCost == nil then
				signLabel.Text = string.format(
					"Warehouse\nTier %d / %d\n%d / %d\nMAXED",
					state.tier,
					MAX_WAREHOUSE_TIER,
					total,
					cap
				)
			else
				signLabel.Text = string.format(
					"Warehouse\nTier %d / %d\n%d / %d\nClick to Upgrade\n$%d",
					state.tier,
					MAX_WAREHOUSE_TIER,
					total,
					cap,
					nextCost
				)
			end
		end
	end
end

function WarehouseService:_hookWarehouseWoodSign(signPart: BasePart, userId: number)
	if self._hookedWarehouseWoodSigns[signPart] then
		return
	end
	self._hookedWarehouseWoodSigns[signPart] = true

	signPart.CanQuery = true
	signPart.CanTouch = false
	signPart.CanCollide = false
	signPart.Anchored = true
	signPart.Massless = true
	signPart:SetAttribute("WarehouseOwnerUserId", userId)

	local click = signPart:FindFirstChild(WOOD_SIGN_CLICK_NAME)
	if click and not click:IsA("ClickDetector") then
		click:Destroy()
		click = nil
	end
	if not click then
		local cd = Instance.new("ClickDetector")
		cd.Name = WOOD_SIGN_CLICK_NAME
		cd.MaxActivationDistance = 22
		cd.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
		cd.Parent = signPart
		click = cd
	end
	if click and click:IsA("ClickDetector") then
		click.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
		click.MaxActivationDistance = math.max(22, click.MaxActivationDistance)
		table.insert(
			self._connections,
			click.MouseClick:Connect(function(player: Player)
				local ownerId = signPart:GetAttribute("WarehouseOwnerUserId")
				if typeof(ownerId) ~= "number" then
					return
				end
				if player.UserId ~= ownerId then
					self:_fireWarehouseUpgradeResult(player, false, "NOT_OWNER", "This is not your warehouse.", nil)
					return
				end
				self:TryUpgrade(ownerId, player)
			end)
		)
	end
end

function WarehouseService:_ensureWarehouseWoodSign(visual: Model, userId: number, terminalAnchor: Instance?)
	local existingRig = visual:FindFirstChild(WOOD_SIGN_RIG_FOLDER, true)
	if existingRig then
		local signModel = existingRig:FindFirstChild(WOOD_SIGN_MODEL_NAME, true)
		local signPart = signModel and signModel:FindFirstChild("Sign")
		if signModel and signModel:IsA("Model") and signPart and signPart:IsA("BasePart") then
			local terminal = terminalAnchor or findWarehouseTerminalAnchor(visual)
			if terminal then
				pivotSignModelAboveTerminal(signModel, terminal)
			end
			self:_hookWarehouseWoodSign(signPart, userId)
			self:_syncWoodSignGui(signPart, userId)
		end
		return
	end

	local proto = self:_getWoodSignPrototype()
	if not proto then
		if not self._woodSignTemplateWarned then
			self._woodSignTemplateWarned = true
			warn(
				"[WarehouseService] No wood sign for warehouse upgrades: add ReplicatedStorage.Assets.WarehouseUpgradeWoodSign "
					.. "(copy of oil tank Minecraft Wood Sign) or ensure OilTanksTemplate contains a Minecraft Wood Sign."
			)
		end
		return
	end

	local rig = Instance.new("Folder")
	rig.Name = WOOD_SIGN_RIG_FOLDER
	rig.Parent = visual

	local signModel = proto:Clone()
	signModel.Name = WOOD_SIGN_MODEL_NAME
	signModel.Parent = rig

	local terminal = terminalAnchor or findWarehouseTerminalAnchor(visual)
	local signPart = signModel:FindFirstChild("Sign")
	if signPart and signPart:IsA("BasePart") then
		if terminal then
			pivotSignModelAboveTerminal(signModel, terminal)
		else
			local anchor = visual:FindFirstChild("WarehouseUpgradeSignAnchor", true)
			if anchor and anchor:IsA("BasePart") then
				signModel:PivotTo(anchor.CFrame)
			else
				local signBoard = visual:FindFirstChild("SignBoard", true)
				if signBoard and signBoard:IsA("BasePart") then
					signModel:PivotTo(signBoard.CFrame * CFrame.new(6, 0, 2))
				end
			end
		end
		for _, d in ipairs(signModel:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = true
				d.CanTouch = false
				d.Massless = true
			end
		end
		self:_hookWarehouseWoodSign(signPart, userId)
		self:_syncWoodSignGui(signPart, userId)
	end
end

function WarehouseService:_spawnWarehouseVisual(userId: number)
	local state = self._stateByUserId[userId]
	if not state or not state.slotId then return end

	local pos = self:_getSlotPosition(state.slotId)
	if not pos then return end

	if not self._template then
		warn("[WarehouseService] No warehouse template")
		return
	end

	local visual = self._template:Clone()
	visual.Name = "Warehouse_" .. tostring(userId)
	visual:PivotTo(CFrame.new(pos))

	-- Resolve terminal while ProximityPrompts still exist (text match), then parent, place wood sign, strip prompts.
	local terminalForWoodSign = findWarehouseTerminalAnchor(visual)

	-- Update sign
	local signBoard = visual:FindFirstChild("SignBoard", true)
	if signBoard then
		local gui = signBoard:FindFirstChild("SignGui")
		if gui then
			local ownerLabel = gui:FindFirstChild("OwnerLabel")
			local player = Players:GetPlayerByUserId(userId)
			if ownerLabel and player then
				ownerLabel.Text = player.Name
			end
			local tierLabel = gui:FindFirstChild("TierLabel")
			if tierLabel then
				local cap = WarehouseConfig.GetCapacity(state.tier)
				tierLabel.Text = string.format("Tier %d | %d/%d", state.tier, totalBarrels(state.barrels), cap)
			end
		end
	end

	-- Expand fence to match tier
	self:_applyFenceSize(visual, state.tier)

	-- Parent to FinishPlot
	local finishPlot = Workspace.Map:FindFirstChild("FinishPlot")
	visual.Parent = finishPlot or Workspace
	self._visualByUserId[userId] = visual
	self:_ensureWarehouseWoodSign(visual, userId, terminalForWoodSign)
	stripAllProximityPromptsInWarehouse(visual)
end

function WarehouseService:_applyFenceSize(_visual: Model, _tier: number)
	-- The warehouse template is pre-built with the correct layout.
	-- Don't resize anything at runtime — the user positioned everything manually.
	-- Future: if we want dynamic expansion, we'll rebuild the fence from scratch.
end

-- =================== PUBLIC API ===================

function WarehouseService:GetCapacity(userId: number): number
	local state = self._stateByUserId[userId]
	if not state then return 20 end
	return WarehouseConfig.GetCapacity(state.tier)
end

function WarehouseService:GetTotalBarrels(userId: number): number
	local state = self._stateByUserId[userId]
	if not state then return 0 end
	return totalBarrelsCombined(state.barrels, state.hitOverflowBarrels)
end

function WarehouseService:CanShip(userId: number, barrelCount: number): boolean
	local state = self._stateByUserId[userId]
	if not state then return false end
	local cap = WarehouseConfig.GetCapacity(state.tier)
	return totalBarrels(state.barrels) + barrelCount <= cap
end

function WarehouseService:DeliverBarrels(userId: number, manifest): boolean
	local state = self._stateByUserId[userId]
	if not state then return false end

	local cap = WarehouseConfig.GetCapacity(state.tier)
	local current = totalBarrels(state.barrels)
	local incoming = 0
	for _, tier in ipairs(TIER_ORDER) do
		incoming += manifest[tier] or 0
	end

	if current + incoming > cap then
		return false
	end

	for _, tier in ipairs(TIER_ORDER) do
		state.barrels[tier] = (state.barrels[tier] or 0) + (manifest[tier] or 0)
	end

	self._dirtyByUserId[userId] = true
	self:_syncBarrelVisuals(userId)
	self:_updateSign(userId)
	self:PushState(userId)
	return true
end

function WarehouseService:DeliverHitBarrels(userId: number, manifest): boolean
	local state = self._stateByUserId[userId]
	if not state then return false end

	local cap = WarehouseConfig.GetCapacity(state.tier)
	local currentBase = totalBarrels(state.barrels)
	local manifestIn = copyBarrelMap(manifest)
	local remainingRoom = math.max(0, cap - currentBase)

	local toBase = emptyBarrelMap()
	local toOverflow = emptyBarrelMap()

	for _, tier in ipairs(TIER_ORDER) do
		local want = manifestIn[tier] or 0
		if want > 0 and remainingRoom > 0 then
			local take = math.min(want, remainingRoom)
			toBase[tier] = take
			want -= take
			remainingRoom -= take
		end
		if want > 0 then
			toOverflow[tier] = want
		end
	end

	for _, tier in ipairs(TIER_ORDER) do
		local addBase = toBase[tier] or 0
		if addBase > 0 then
			state.barrels[tier] = (state.barrels[tier] or 0) + addBase
		end
		local addOverflow = toOverflow[tier] or 0
		if addOverflow > 0 then
			state.hitOverflowBarrels[tier] = (state.hitOverflowBarrels[tier] or 0) + addOverflow
		end
	end

	self._dirtyByUserId[userId] = true
	self:_syncBarrelVisuals(userId)
	self:_updateSign(userId)
	self:PushState(userId)
	return true
end

function WarehouseService:TryUpgrade(userId: number, feedbackPlayer: Player?): (boolean, string)
	local state = self._stateByUserId[userId]
	if not state then
		local msg = "No warehouse state."
		if feedbackPlayer then
			self:_fireWarehouseUpgradeResult(feedbackPlayer, false, "ERR_NO_STATE", msg, nil)
		end
		return false, msg
	end

	local nextCost = WarehouseConfig.GetUpgradeCost(state.tier)
	if not nextCost then
		local msg = "Warehouse already at max tier."
		if feedbackPlayer then
			self:_fireWarehouseUpgradeResult(feedbackPlayer, false, "ERR_MAX_TIER", msg, {
				tier = state.tier,
				maxTier = MAX_WAREHOUSE_TIER,
			})
		end
		return false, msg
	end

	if not self._oilStateService:TrySpendCash(userId, nextCost) then
		local msg = string.format("Need $%d to upgrade.", nextCost)
		if feedbackPlayer then
			self:_fireWarehouseUpgradeResult(feedbackPlayer, false, "ERR_NOT_ENOUGH_CASH", msg, {
				cost = nextCost,
				tier = state.tier,
			})
		end
		return false, msg
	end

	state.tier += 1
	self._dirtyByUserId[userId] = true

	local visual = self._visualByUserId[userId]
	if visual then
		self:_applyFenceSize(visual, state.tier)
	end

	self:_updateSign(userId)
	self._oilStateService:PushState(userId)
	self:PushState(userId)

	local msg = string.format("Upgraded to tier %d.", state.tier)
	if feedbackPlayer then
		self:_fireWarehouseUpgradeResult(feedbackPlayer, true, "OK", msg, {
			tier = state.tier,
			maxTier = MAX_WAREHOUSE_TIER,
			costSpent = nextCost,
		})
	end
	return true, msg
end

function WarehouseService:SellAll(userId: number)
	-- Deprecated debug stub. Selling is now handled by OilMarketService.
end

function WarehouseService:GetBarrelsByType(userId: number, oilType: string): number
	local state = self._stateByUserId[userId]
	if not state then return 0 end
	return (state.barrels[oilType] or 0) + (state.hitOverflowBarrels[oilType] or 0)
end

function WarehouseService:GetAllBarrels(userId: number)
	local state = self._stateByUserId[userId]
	if not state then return emptyBarrelMap() end
	return {
		HeavyCrude = (state.barrels.HeavyCrude or 0) + (state.hitOverflowBarrels.HeavyCrude or 0),
		LightSweet = (state.barrels.LightSweet or 0) + (state.hitOverflowBarrels.LightSweet or 0),
		PremiumRefined = (state.barrels.PremiumRefined or 0) + (state.hitOverflowBarrels.PremiumRefined or 0),
	}
end

function WarehouseService:GetHitOverflowBarrels(userId: number)
	local state = self._stateByUserId[userId]
	if not state then return emptyBarrelMap() end
	return copyBarrelMap(state.hitOverflowBarrels)
end

-- Remove up to `removals[tier]` whole barrels per tier (market partial sell).
function WarehouseService:TryRemoveBarrelsByCounts(userId: number, removals: { [string]: number }): boolean
	local state = self._stateByUserId[userId]
	if not state then
		return false
	end
	local need = emptyBarrelMap()
	for _, tier in ipairs(TIER_ORDER) do
		need[tier] = math.max(0, math.floor(removals[tier] or 0))
	end
	for _, tier in ipairs(TIER_ORDER) do
		local have = (state.barrels[tier] or 0) + (state.hitOverflowBarrels[tier] or 0)
		if have < need[tier] then
			return false
		end
	end
	for _, tier in ipairs(TIER_ORDER) do
		local left = need[tier]
		local baseHave = state.barrels[tier] or 0
		local takeBase = math.min(baseHave, left)
		state.barrels[tier] = math.max(0, baseHave - takeBase)
		left -= takeBase
		if left > 0 then
			local overflowHave = state.hitOverflowBarrels[tier] or 0
			local takeOverflow = math.min(overflowHave, left)
			state.hitOverflowBarrels[tier] = math.max(0, overflowHave - takeOverflow)
			left -= takeOverflow
		end
	end
	self._dirtyByUserId[userId] = true
	self:_syncBarrelVisuals(userId)
	self:_updateSign(userId)
	self:PushState(userId)
	return true
end

function WarehouseService:RemoveBarrelsByType(userId: number, oilType: string): number
	local state = self._stateByUserId[userId]
	if not state then return 0 end
	local count = (state.barrels[oilType] or 0) + (state.hitOverflowBarrels[oilType] or 0)
	if count <= 0 then return 0 end
	state.barrels[oilType] = 0
	state.hitOverflowBarrels[oilType] = 0
	self._dirtyByUserId[userId] = true
	self:_syncBarrelVisuals(userId)
	self:_updateSign(userId)
	self:PushState(userId)
	return count
end

function WarehouseService:RemoveAllBarrels(userId: number)
	local state = self._stateByUserId[userId]
	if not state then return emptyBarrelMap() end
	local removed = {}
	for _, tier in ipairs(TIER_ORDER) do
		removed[tier] = (state.barrels[tier] or 0) + (state.hitOverflowBarrels[tier] or 0)
		state.barrels[tier] = 0
		state.hitOverflowBarrels[tier] = 0
	end
	self._dirtyByUserId[userId] = true
	self:_syncBarrelVisuals(userId)
	self:_updateSign(userId)
	self:PushState(userId)
	return removed
end

function WarehouseService:GetWarehouseForClient(userId: number)
	local state = self._stateByUserId[userId]
	if not state then return nil end

	return {
		tier = state.tier,
		maxTier = MAX_WAREHOUSE_TIER,
		barrels = {
			HeavyCrude = (state.barrels.HeavyCrude or 0) + (state.hitOverflowBarrels.HeavyCrude or 0),
			LightSweet = (state.barrels.LightSweet or 0) + (state.hitOverflowBarrels.LightSweet or 0),
			PremiumRefined = (state.barrels.PremiumRefined or 0) + (state.hitOverflowBarrels.PremiumRefined or 0),
		},
		hitOverflowBarrels = copyBarrelMap(state.hitOverflowBarrels),
		capacity = WarehouseConfig.GetCapacity(state.tier),
		totalBarrels = totalBarrelsCombined(state.barrels, state.hitOverflowBarrels),
		slotId = state.slotId,
		upgradeCost = WarehouseConfig.GetUpgradeCost(state.tier),
	}
end

function WarehouseService:PushState(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end
	local data = self:GetWarehouseForClient(userId)
	if not data then return end
	local event = self._remoteService:GetEvent(RemoteNames.WarehouseStateUpdate)
	event:FireClient(player, data)
end

-- =================== VISUALS ===================

function WarehouseService:_syncBarrelVisuals(userId: number)
	local state = self._stateByUserId[userId]
	local visual = self._visualByUserId[userId]
	if not state or not visual then return end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return end

	local tierTemplates = {
		HeavyCrude = "Barrel_HeavyCrude",
		LightSweet = "Barrel_LightSweet",
		PremiumRefined = "Barrel_PremiumRefined",
	}

	local maxVisual = WarehouseConfig.BarrelVisuals.MaxPerTier -- 20 per tier total
	local barrelHeight = WarehouseConfig.BarrelVisuals.BarrelHeight

	-- Each tier has 4 stack roots (PileRoot_<tier>_1 through _4) spread across Pile1-Pile4.
	-- Distribute barrels round-robin across the 4 stacks.
	local STACKS_PER_TIER = 4

	for _, tier in ipairs(TIER_ORDER) do
		local actual = state.barrels[tier] or 0
		local desired = math.min(maxVisual, actual)

		-- Find the 4 stack roots for this tier
		local roots = {}
		for i = 1, STACKS_PER_TIER do
			local root = visual:FindFirstChild("PileRoot_" .. tier .. "_" .. i, true)
			if root then
				table.insert(roots, root)
			end
		end
		if #roots == 0 then continue end

		-- Count existing visual barrels for this tier
		local pileName = "WHBarrel_" .. tier .. "_"
		local existing = 0
		for _, child in ipairs(visual:GetDescendants()) do
			if typeof(child.Name) == "string" and child.Name:sub(1, #pileName) == pileName then
				existing += 1
			end
		end

		if desired > existing then
			local templateName = tierTemplates[tier]
			local template = templateName and assetsFolder:FindFirstChild(templateName)
			for i = existing + 1, desired do
				local barrel
				if template then
					barrel = template:Clone()
				else
					barrel = Instance.new("Part")
					barrel.Shape = Enum.PartType.Cylinder
					barrel.Size = Vector3.new(2.2, 2, 2)
					barrel.Material = Enum.Material.Metal
					barrel.Color = Color3.fromRGB(165, 118, 46)
				end
				barrel.Name = pileName .. tostring(i)

				-- Round-robin across the 4 stacks
				local stackIdx = ((i - 1) % #roots) + 1
				local stackLevel = math.floor((i - 1) / #roots)
				local root = roots[stackIdx]
				local baseY = stackLevel * barrelHeight

				if barrel:IsA("Model") then
					-- Model WorldPivot is at bottom — place directly
					local pos = root.Position + Vector3.new(0, baseY, 0)
					barrel:PivotTo(CFrame.new(pos))
				elseif barrel:IsA("BasePart") then
					-- MeshPart position is at center — offset by half height
					local pos = root.Position + Vector3.new(0, baseY + barrel.Size.Y / 2, 0)
					barrel.CFrame = CFrame.new(pos)
					barrel.Anchored = true
					barrel.CanCollide = false
				end
				barrel.Parent = visual
			end
		elseif desired < existing then
			-- Remove from top down
			for i = existing, desired + 1, -1 do
				local name = pileName .. tostring(i)
				local child = visual:FindFirstChild(name, true)
				if child then child:Destroy() end
			end
		end
	end
end

function WarehouseService:_updateSign(userId: number)
	local state = self._stateByUserId[userId]
	local visual = self._visualByUserId[userId]
	if not state or not visual then return end

	local signBoard = visual:FindFirstChild("SignBoard", true)
	if not signBoard then return end
	local gui = signBoard:FindFirstChild("SignGui")
	if not gui then return end

	local tierLabel = gui:FindFirstChild("TierLabel")
	if tierLabel then
		local cap = WarehouseConfig.GetCapacity(state.tier)
		tierLabel.Text = string.format("Tier %d/%d | %d/%d", state.tier, MAX_WAREHOUSE_TIER, totalBarrels(state.barrels), cap)
	end

	local rig = visual:FindFirstChild(WOOD_SIGN_RIG_FOLDER)
	if rig then
		local signModel = rig:FindFirstChild(WOOD_SIGN_MODEL_NAME)
		local signPart = signModel and signModel:FindFirstChild("Sign")
		if signPart and signPart:IsA("BasePart") then
			self:_syncWoodSignGui(signPart, userId)
		end
	end
end

--- Teleport to this player's `WarehouseTemplate` **`WarehouseSpawn`** (finish zone). Returns false if no visual/spawn/character.
function WarehouseService:TryTeleportPlayerToWarehouse(player: Player): boolean
	local visual = self._visualByUserId[player.UserId]
	if not visual then
		return false
	end
	local spawn = visual:FindFirstChild("WarehouseSpawn")
	if not (spawn and spawn:IsA("BasePart")) then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	CharacterTeleport.teleportWithUnseat(character, CFrame.new(spawn.Position + Vector3.new(0, 3, 0)), "RequestTeleportToWarehouse")
	return true
end

function WarehouseService:_teleportToWarehouse(player: Player)
	self:TryTeleportPlayerToWarehouse(player)
end

-- =================== PERSISTENCE ===================

function WarehouseService:_loadProfile(userId: number)
	local key = tostring(userId)
	if self._memoryStore[key] then
		return self._memoryStore[key]
	end
	if not self._dataStore then
		return nil
	end
	local ok, result = pcall(function()
		return self._dataStore:GetAsync(key)
	end)
	if ok and typeof(result) == "table" then
		return result
	end
	if not ok and self._dataStore ~= nil and isDatastoreStudioAccessError(result) then
		if not self._dataStoreStudioFallbackWarned then
			self._dataStoreStudioFallbackWarned = true
			warn(
				"[WarehouseService] Studio cannot access DataStores (Game Settings → Security → Enable Studio Access to API Services). "
					.. "Using in-session memory for warehouse profiles for this server run — no cross-session persistence in Studio until enabled."
			)
		end
		self._dataStore = nil
	elseif not ok then
		warn(string.format("[WarehouseService] Load failed for user %d: %s", userId, tostring(result)))
	end
	return nil
end

--- @param persistRegardlessOfDirty When true (e.g. PlayerRemoving), write even if not dirty.
function WarehouseService:_saveProfile(userId: number, force: boolean?, persistRegardlessOfDirty: boolean?)
	if self._devSkipSaveOnNextDrop[userId] then
		return
	end
	if not persistRegardlessOfDirty and not self._dirtyByUserId[userId] then
		return
	end
	local state = self._stateByUserId[userId]
	if not state then
		self._dirtyByUserId[userId] = nil
		return
	end

	local payload = {
		tier = state.tier,
		barrels = state.barrels,
		hitOverflowBarrels = state.hitOverflowBarrels,
		slotId = state.slotId,
	}

	local key = tostring(userId)
	if not self._dataStore then
		self._memoryStore[key] = payload
		self._dirtyByUserId[userId] = nil
		return
	end

	if not force then
		local last = self._lastWarehouseDataStoreSaveClock[userId]
		if last and (os.clock() - last) < MIN_DATASTORE_SET_INTERVAL_SECONDS then
			return
		end
		DataStoreWriteGate.waitForWriteBudget(2.8)
	end

	local maxAttempts = if persistRegardlessOfDirty then 4 else 1
	local lastErr: any = nil
	for attempt = 1, maxAttempts do
		if attempt > 1 and self._dataStore then
			DataStoreWriteGate.waitForWriteBudget(2.8)
			task.wait(0.45)
		end

		local ok, err = pcall(function()
			self._dataStore:SetAsync(key, payload)
		end)
		lastErr = err
		if ok then
			self._lastWarehouseDataStoreSaveClock[userId] = os.clock()
			self._dirtyByUserId[userId] = nil
			return
		end
		if self._dataStore ~= nil and isDatastoreStudioAccessError(err) then
			if not self._dataStoreStudioFallbackWarned then
				self._dataStoreStudioFallbackWarned = true
				warn(
					"[WarehouseService] Studio cannot access DataStores (Game Settings → Security → Enable Studio Access to API Services). "
						.. "Using in-session memory for warehouse profiles for this server run — no cross-session persistence in Studio until enabled."
				)
			end
			self._dataStore = nil
			self._memoryStore[key] = payload
			self._dirtyByUserId[userId] = nil
			return
		end
	end
	warn(string.format("[WarehouseService] Save failed for user %d after %d attempt(s): %s", userId, maxAttempts, tostring(lastErr)))
end

function WarehouseService:_flushDirty(force: boolean?)
	local ids: { number } = {}
	for userId in pairs(self._dirtyByUserId) do
		table.insert(ids, userId)
	end
	table.sort(ids)
	for i, userId in ipairs(ids) do
		self:_saveProfile(userId, force)
		if not force and i < #ids and self._dataStore then
			task.wait(FLUSH_MULTI_USER_SPACING_SECONDS)
		end
	end
end

--- Studio/dev: next `PlayerRemoving` will not write warehouse profile (after `RemoveAsync`).
function WarehouseService:MarkDevSkipSaveOnNextDrop(userId: number)
	self._devSkipSaveOnNextDrop[userId] = true
end

--- Remove `WarehouseProfiles_v1` entry and in-memory fallback cache. Does not touch live session state.
function WarehouseService:DevRemovePersistedWarehouseProfile(userId: number)
	local key = tostring(userId)
	if self._dataStore then
		pcall(function()
			self._dataStore:RemoveAsync(key)
		end)
	end
	self._memoryStore[key] = nil
end

return WarehouseService
