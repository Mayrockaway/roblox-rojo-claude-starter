--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WarehouseConfig = require(Shared:WaitForChild("Config"):WaitForChild("WarehouseConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local WarehouseService = {}

local TIER_ORDER = { "HeavyCrude", "StandardCrude", "LightSweet", "PremiumRefined" }
local SAVE_INTERVAL = 20

local function emptyBarrelMap()
	return { HeavyCrude = 0, StandardCrude = 0, LightSweet = 0, PremiumRefined = 0 }
end

local function totalBarrels(barrels)
	local t = 0
	for _, tier in ipairs(TIER_ORDER) do
		t += barrels[tier] or 0
	end
	return t
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
	self._memoryOnly = RunService:IsStudio()

	if self._memoryOnly then
		self._dataStore = nil
	else
		local ok, storeOrErr = pcall(function()
			return DataStoreService:GetDataStore(WarehouseConfig.DataStoreName)
		end)
		self._dataStore = ok and storeOrErr or nil
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
		self:TryUpgrade(player.UserId)
		self:PushState(player.UserId)
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
			barrels = emptyBarrelMap(),
			capacity = WarehouseConfig.GetCapacity(1),
			totalBarrels = 0,
			slotId = nil,
			upgradeCost = WarehouseConfig.GetUpgradeCost(1),
		}
	end

	-- Autosave
	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL)
			self:_flushDirty()
		end
	end)

	-- Catch up with existing players
	for _, player in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(player)
	end
end

function WarehouseService:Stop()
	self:_flushDirty()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	self._connections = {}
end

function WarehouseService:_onPlayerAdded(player: Player)
	local userId = player.UserId
	local persisted = self:_loadProfile(userId)

	local state = {
		tier = 1,
		barrels = emptyBarrelMap(),
		slotId = nil,
	}

	if persisted then
		state.tier = math.clamp(persisted.tier or 1, 1, #WarehouseConfig.Tiers)
		if typeof(persisted.barrels) == "table" then
			for _, tier in ipairs(TIER_ORDER) do
				state.barrels[tier] = math.max(0, math.floor(tonumber(persisted.barrels[tier]) or 0))
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
	self:_saveProfile(userId)

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
	return totalBarrels(state.barrels)
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

function WarehouseService:TryUpgrade(userId: number): (boolean, string)
	local state = self._stateByUserId[userId]
	if not state then return false, "No state" end

	local nextCost = WarehouseConfig.GetUpgradeCost(state.tier)
	if not nextCost then return false, "Already max tier" end

	if not self._oilStateService:TrySpendCash(userId, nextCost) then
		return false, "Not enough cash" end

	state.tier += 1
	self._dirtyByUserId[userId] = true

	-- Expand the visual fence
	local visual = self._visualByUserId[userId]
	if visual then
		self:_applyFenceSize(visual, state.tier)
	end

	self:_updateSign(userId)
	self._oilStateService:PushState(userId)
	return true, "Upgraded to tier " .. state.tier
end

function WarehouseService:SellAll(userId: number)
	-- Deprecated debug stub. Selling is now handled by OilMarketService.
end

function WarehouseService:GetBarrelsByType(userId: number, oilType: string): number
	local state = self._stateByUserId[userId]
	if not state then return 0 end
	return state.barrels[oilType] or 0
end

function WarehouseService:GetAllBarrels(userId: number)
	local state = self._stateByUserId[userId]
	if not state then return emptyBarrelMap() end
	return {
		HeavyCrude = state.barrels.HeavyCrude or 0,
		StandardCrude = state.barrels.StandardCrude or 0,
		LightSweet = state.barrels.LightSweet or 0,
		PremiumRefined = state.barrels.PremiumRefined or 0,
	}
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
		local have = state.barrels[tier] or 0
		if have < need[tier] then
			return false
		end
	end
	for _, tier in ipairs(TIER_ORDER) do
		state.barrels[tier] = math.max(0, (state.barrels[tier] or 0) - need[tier])
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
	local count = state.barrels[oilType] or 0
	if count <= 0 then return 0 end
	state.barrels[oilType] = 0
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
		removed[tier] = state.barrels[tier] or 0
		state.barrels[tier] = 0
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
		barrels = {
			HeavyCrude = state.barrels.HeavyCrude or 0,
			StandardCrude = state.barrels.StandardCrude or 0,
			LightSweet = state.barrels.LightSweet or 0,
			PremiumRefined = state.barrels.PremiumRefined or 0,
		},
		capacity = WarehouseConfig.GetCapacity(state.tier),
		totalBarrels = totalBarrels(state.barrels),
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
		StandardCrude = "Barrel_StandardCrude",
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
		tierLabel.Text = string.format("Tier %d | %d/%d", state.tier, totalBarrels(state.barrels), cap)
	end
end

function WarehouseService:_teleportToWarehouse(player: Player)
	local visual = self._visualByUserId[player.UserId]
	if not visual then return end
	local spawn = visual:FindFirstChild("WarehouseSpawn")
	if not spawn then return end
	local character = player.Character
	if not character then return end
	character:PivotTo(CFrame.new(spawn.Position + Vector3.new(0, 3, 0)))
end

-- =================== PERSISTENCE ===================

function WarehouseService:_loadProfile(userId: number)
	local key = tostring(userId)
	if self._memoryStore[key] then return self._memoryStore[key] end
	if not self._dataStore then return nil end
	local ok, result = pcall(function() return self._dataStore:GetAsync(key) end)
	return ok and typeof(result) == "table" and result or nil
end

function WarehouseService:_saveProfile(userId: number)
	if not self._dirtyByUserId[userId] then return end
	local state = self._stateByUserId[userId]
	if not state then self._dirtyByUserId[userId] = nil; return end

	local payload = {
		tier = state.tier,
		barrels = state.barrels,
		slotId = state.slotId,
	}

	local key = tostring(userId)
	if not self._dataStore then
		self._memoryStore[key] = payload
		self._dirtyByUserId[userId] = nil
		return
	end

	local ok = pcall(function() self._dataStore:SetAsync(key, payload) end)
	if ok then self._dirtyByUserId[userId] = nil end
end

function WarehouseService:_flushDirty()
	for userId in pairs(self._dirtyByUserId) do
		self:_saveProfile(userId)
	end
end

return WarehouseService
