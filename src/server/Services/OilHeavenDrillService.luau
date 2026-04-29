--!strict

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeavenRewardConfig = require(Shared:WaitForChild("Config"):WaitForChild("HeavenRewardConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilHeavenDrillService = {}

local PROMPT_NAME = "HeavenDrillPrompt"
local REBIRTH_DRILL_TOOL_NAME = "Rebirth Drill"
local REBIRTH_DRILL_TEMPLATE = "Drill_Rebirth"

local function isSkyPlotModel(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Model") and string.match(instance.Name, "^OilHeavenPlot_%d%d$") ~= nil
end

local function getOwningSkyPlot(instance: Instance): Model?
	local cursor: Instance? = instance
	while cursor do
		if isSkyPlotModel(cursor) then
			return cursor :: Model
		end
		cursor = cursor.Parent
	end
	return nil
end

local function getTileGrid(plot: Model): Folder?
	local specialPlot = plot:FindFirstChild("SpecialPlot")
	local tileGrid = specialPlot and specialPlot:FindFirstChild("TileGrid")
	if tileGrid and tileGrid:IsA("Folder") then
		return tileGrid
	end
	return nil
end

function OilHeavenDrillService:Init(remoteService, oilStateService, oilHeavenPlotService, plotService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._oilHeavenPlotService = oilHeavenPlotService
	self._plotService = plotService
	self._connections = {}
	self._running = false
	self._activeDrills = {} :: { [string]: boolean }
	self._rewardEvent = remoteService:GetEvent(RemoteNames.HeavenRewardEvent)
	self._actionResultEvent = remoteService:GetEvent(RemoteNames.OilActionResult)
	self._monetizationService = nil :: any
end

function OilHeavenDrillService:SetMonetizationService(monetizationService: any)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end

	monetizationService:SetPromptPrecondition(HeavenRewardConfig.DoubleRewardMonetizationItemId, function(player: Player)
		local pending = self._oilStateService:GetPendingOilHeavenDoubleReward(player.UserId)
		if not pending then
			return false, "ERR_NO_PENDING_HEAVEN_REWARD", "No Heaven reward is available to double right now."
		end
		return true
	end)

	monetizationService:SetConsumableHandler("heaven_reward_x2", function(userId: number, quantity: number): (boolean, string?)
		local lastReward = nil
		for _ = 1, math.max(1, quantity) do
			local ok, code, reward = self._oilStateService:ConsumePendingOilHeavenDoubleReward(userId)
			if not ok or not reward then
				return false, code or "ERR_NO_PENDING_HEAVEN_REWARD"
			end
			lastReward = reward
		end
		self._oilStateService:PushState(userId)
		local player = Players:GetPlayerByUserId(userId)
		if player and lastReward then
			self._rewardEvent:FireClient(player, {
				kind = "rewardDoubled",
				reward = lastReward,
			})
		end
		return true, nil
	end)
end

--- Returns the heaven tile BasePart if `target` (or an ancestor) is a tile
--- inside a TileGrid under an OilHeavenPlot. Otherwise nil.
local function resolveHeavenTile(target: Instance?): BasePart?
	if not target then return nil end
	local cursor: Instance? = target
	while cursor do
		if cursor:IsA("BasePart") and cursor.Parent and cursor.Parent:IsA("Folder") and cursor.Parent.Name == "TileGrid" then
			local plot = getOwningSkyPlot(cursor)
			if plot then
				return cursor :: BasePart
			end
		end
		cursor = cursor.Parent
	end
	return nil
end

local function playerHasRebirthDrill(player: Player): boolean
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and child.Name == REBIRTH_DRILL_TOOL_NAME then
				return true
			end
		end
	end
	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and child.Name == REBIRTH_DRILL_TOOL_NAME then
				return true
			end
		end
	end
	return false
end

function OilHeavenDrillService:GrantRebirthDrillTool(player: Player)
	if playerHasRebirthDrill(player) then
		return
	end
	local folder = ServerStorage:FindFirstChild("EquipmentShopTemplates")
	if not folder then return end
	local template = folder:FindFirstChild(REBIRTH_DRILL_TEMPLATE)
	if not template or not template:IsA("Tool") then return end
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then return end

	local tool = template:Clone()
	tool.Name = REBIRTH_DRILL_TOOL_NAME
	tool:SetAttribute("ToolKind", "RebirthDrill")
	tool:SetAttribute("RebirthDrillPermanent", true)
	tool.Parent = backpack
end

function OilHeavenDrillService:Start()
	if self._running then
		return
	end
	self._running = true

	-- Grant rebirth drill to players who already have heaven unlocked
	for _, player in ipairs(Players:GetPlayers()) do
		if self._oilStateService:IsOilHeavenUnlocked(player.UserId) then
			self:GrantRebirthDrillTool(player)
		end
	end

	-- Re-grant on respawn
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				if self._oilStateService:IsOilHeavenUnlocked(player.UserId) then
					self:GrantRebirthDrillTool(player)
				end
			end)
		end)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.defer(function()
				if self._oilStateService:IsOilHeavenUnlocked(player.UserId) then
					self:GrantRebirthDrillTool(player)
				end
			end)
		end)
	end

	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, _plot: Model)
		local player = Players:GetPlayerByUserId(userId)
		if player and self._oilStateService:IsOilHeavenUnlocked(userId) then
			self:GrantRebirthDrillTool(player)
		end
		self:RefreshAllPrompts()
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(_player: Player)
		task.defer(function()
			self:RefreshAllPrompts()
		end)
	end))

	-- Listen for tool activation remote
	local drillRemote = self._remoteService:GetEvent(RemoteNames.RequestHeavenDrill)
	table.insert(self._connections, drillRemote.OnServerEvent:Connect(function(player: Player, target: any)
		self:_handleToolActivation(player, target)
	end))

end

function OilHeavenDrillService:Stop()
	self._running = false
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

function OilHeavenDrillService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data: any?)
	self._actionResultEvent:FireClient(player, {
		action = "HeavenDrill",
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function OilHeavenDrillService:RefreshPlayerPrompts(_userId: number)
	-- No-op: tool activation replaced ProximityPrompts
end

function OilHeavenDrillService:RefreshAllPrompts()
	-- No-op: tool activation replaced ProximityPrompts
end

function OilHeavenDrillService:_handleToolActivation(player: Player, target: any)
	if not self._running then return end
	if typeof(target) ~= "Instance" then
		self:_sendActionResult(player, false, "ERR_HEAVEN_INVALID", "Rebirth Drill can only be used on Heaven tiles!", nil)
		return
	end

	local tilePart = resolveHeavenTile(target)
	if not tilePart then
		self:_sendActionResult(player, false, "ERR_HEAVEN_INVALID", "Rebirth Drill can only be used on Heaven tiles!", nil)
		return
	end

	local plot = getOwningSkyPlot(tilePart)
	if not plot then
		self:_sendActionResult(player, false, "ERR_HEAVEN_INVALID", "Rebirth Drill can only be used on Heaven tiles!", nil)
		return
	end

	local ownerUserId = plot:GetAttribute("OwnerUserId")
	if typeof(ownerUserId) ~= "number" or ownerUserId ~= player.UserId then
		self:_sendActionResult(player, false, "ERR_HEAVEN_NOT_OWNER", "This is not your Heaven plot.", nil)
		return
	end
	if tilePart:GetAttribute("Locked") == true then
		self:_sendActionResult(player, false, "ERR_HEAVEN_TILE_LOCKED", "That Heaven tile is still locked.", nil)
		return
	end
	if self._oilStateService:IsOilHeavenTileDrilled(player.UserId, tilePart.Name) then
		self:_sendActionResult(player, false, "ERR_HEAVEN_TILE_CLAIMED", "That Heaven tile was already claimed.", nil)
		return
	end

	-- Prevent double-drilling the same tile
	local drillKey = tostring(player.UserId) .. "_" .. tilePart.Name
	if self._activeDrills[drillKey] then
		self:_sendActionResult(player, false, "ERR_HEAVEN_DRILLING", "Already drilling this tile!", nil)
		return
	end
	self._activeDrills[drillKey] = true

	-- Tell client to spawn the drill visual + spin animation
	local tileTop = tilePart.Position.Y + tilePart.Size.Y / 2
	self._rewardEvent:FireClient(player, {
		kind = "drillingStarted",
		tileId = tilePart.Name,
		position = { x = tilePart.Position.X, y = tileTop, z = tilePart.Position.Z },
	})

	-- 3-second drill time, then claim reward
	task.delay(3, function()
		self._activeDrills[drillKey] = nil

		local ok, code, message, reward = self._oilStateService:ClaimOilHeavenRewardTile(player.UserId, tilePart.Name)
		if not ok or not reward then
			self:_sendActionResult(player, false, code, message, nil)
			return
		end

		self._oilStateService:PushState(player.UserId)
		pcall(function()
			self._oilHeavenPlotService:RefreshUnlocks(player.UserId)
		end)

		self._rewardEvent:FireClient(player, {
			kind = "rewardGranted",
			tileId = tilePart.Name,
			reward = reward,
			doubleItemId = HeavenRewardConfig.DoubleRewardMonetizationItemId,
			doublePriceRobux = HeavenRewardConfig.DoubleRewardRobuxPrice,
		})
		self:_sendActionResult(player, true, "OK", reward.displayText, {
			tileId = tilePart.Name,
			reward = reward,
		})
	end)
end


return OilHeavenDrillService
