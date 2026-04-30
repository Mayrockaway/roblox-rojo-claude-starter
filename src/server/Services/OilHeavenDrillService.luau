--!strict

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local HeavenRewardConfig = require(Shared:WaitForChild("Config"):WaitForChild("HeavenRewardConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilHeavenDrillService = {}

local PROMPT_NAME = "HeavenDrillPrompt"
local REBIRTH_DRILL_TOOL_NAME = "Rebirth Drill"
local REBIRTH_DRILL_TEMPLATE = "Drill_Rebirth"
--- Hotbar (`EquipmentHotbarController`) keys stack-count display off these
--- exact attributes — without `EquipmentShopConsumable=true` AND a non-empty
--- `EquipmentItemId`, `stackCountForTool` returns 1 and no badge renders.
--- The id namespace is shared with `EquipmentCatalog` ids; `rebirth_drill`
--- is unique to this consumable and not a regular shop tier.
local REBIRTH_DRILL_EQUIPMENT_ITEM_ID = "rebirth_drill"

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
	self._drillAttrConns = {} :: { [Player]: RBXScriptConnection }
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
		-- Re-paint the world tile billboard against the cumulative reward
		-- now stored in `tileRewards` (see `ConsumePendingOilHeavenDoubleReward`).
		-- Without this the world tile keeps showing the original "+5.5%"
		-- until the next refresh path runs (rebirth, plot reassign, state-
		-- ready callback).
		if self._oilHeavenPlotService and typeof(self._oilHeavenPlotService.RefreshUnlocks) == "function" then
			pcall(function()
				self._oilHeavenPlotService:RefreshUnlocks(userId)
			end)
		end
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

--- Locates the player's existing Rebirth Drill Tool (if any) across both
--- Backpack and Character. Used by `_syncDrillToolForPlayer` to decide
--- whether to add or remove the tool when the count changes.
local function findExistingRebirthDrillTool(player: Player): Tool?
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and child.Name == REBIRTH_DRILL_TOOL_NAME then
				return child :: Tool
			end
		end
	end
	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and child.Name == REBIRTH_DRILL_TOOL_NAME then
				return child :: Tool
			end
		end
	end
	return nil
end

--- Reconciles Backpack tool presence + stack-count badge with
--- `OilStateService.rebirthDrills`:
---   * count > 0 and no tool → clone the template into the player's Backpack,
---     stamping the EquipmentShop-stack attributes so the hotbar renders a
---     badge identical to other consumable drills.
---   * count > 0 and tool exists → only refresh `EquipmentStackCount` (the
---     hotbar's `GetAttributeChangedSignal(STACK_ATTR)` listener picks this up
---     and repaints the badge live).
---   * count == 0 and tool present → destroy the tool.
--- Called whenever the mirrored attribute changes, on character respawn, on
--- plot assignment, and on every `GrantRebirthDrillTool`.
function OilHeavenDrillService:_syncDrillToolForPlayer(player: Player)
	if not self._oilStateService then return end
	local count = self._oilStateService:GetRebirthDrills(player.UserId)
	local existing = findExistingRebirthDrillTool(player)

	if count <= 0 then
		if existing then
			existing:Destroy()
		end
		return
	end

	if existing then
		-- Refresh stack badge live without re-cloning the tool (avoids
		-- snatching it out of the player's hands mid-equip).
		existing:SetAttribute(Constants.EquipmentStackCountAttribute, count)
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
	-- Stack-display contract — `EquipmentHotbarController.stackCountForTool`
	-- requires both flags set before it'll read the count attribute.
	tool:SetAttribute("EquipmentShopConsumable", true)
	tool:SetAttribute("EquipmentItemId", REBIRTH_DRILL_EQUIPMENT_ITEM_ID)
	tool:SetAttribute(Constants.EquipmentStackCountAttribute, count)
	tool.Parent = backpack
end

--- Public grant API: bumps the rebirth-drill count by 1 (or `count` if given)
--- and syncs the Backpack tool. Used by the `/giverebirthdrill` dev command
--- and any future direct-grant code path; the rebirth shop bumps the count
--- itself via `OilStateService:AddRebirthDrills` and relies on the attribute
--- watcher in `Start()` to sync the tool, so it doesn't go through here.
function OilHeavenDrillService:GrantRebirthDrillTool(player: Player, count: number?)
	if not self._oilStateService then return end
	local n = if typeof(count) == "number" and count > 0 then math.floor(count) else 1
	self._oilStateService:AddRebirthDrills(player.UserId, n)
	self:_syncDrillToolForPlayer(player)
end

--- Hooks per-player attribute change tracking so any update to
--- `Constants.RebirthDrillsAttribute` (set by `OilStateService:Add/Consume`)
--- immediately re-syncs the Backpack tool. This is what links the rebirth
--- shop's purchase (which only mutates state, not tools) to the visible
--- player inventory. Idempotent — keyed by `player` in `_drillAttrConns`.
function OilHeavenDrillService:_attachDrillAttrWatcher(player: Player)
	if self._drillAttrConns[player] then
		return
	end
	self._drillAttrConns[player] = player:GetAttributeChangedSignal(Constants.RebirthDrillsAttribute):Connect(function()
		self:_syncDrillToolForPlayer(player)
	end)
end

function OilHeavenDrillService:Start()
	if self._running then
		return
	end
	self._running = true
	self._drillAttrConns = self._drillAttrConns or ({} :: { [Player]: RBXScriptConnection })

	-- Sync drill tool to count for players already in-game.
	for _, player in ipairs(Players:GetPlayers()) do
		self:_syncDrillToolForPlayer(player)
		self:_attachDrillAttrWatcher(player)
	end

	-- Re-sync on respawn (the new Character starts with an empty Backpack;
	-- if `rebirthDrills > 0` we re-clone the tool, else we leave it empty).
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player: Player)
		self:_attachDrillAttrWatcher(player)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_syncDrillToolForPlayer(player)
			end)
		end)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_syncDrillToolForPlayer(player)
			end)
		end)
	end

	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, _plot: Model)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			self:_syncDrillToolForPlayer(player)
		end
		self:RefreshAllPrompts()
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		local conn = self._drillAttrConns[player]
		if conn then
			conn:Disconnect()
			self._drillAttrConns[player] = nil
		end
		task.defer(function()
			self:RefreshAllPrompts()
		end)
	end))

	-- Listen for tool activation remote
	local drillRemote = self._remoteService:GetEvent(RemoteNames.RequestHeavenDrill)
	table.insert(self._connections, drillRemote.OnServerEvent:Connect(function(player: Player, target: any)
		self:_handleToolActivation(player, target)
	end))

	-- Lootbox dismissed → now safe to show the tile reward visual.
	local ackRemote = self._remoteService:GetEvent(RemoteNames.HeavenRewardAcknowledged)
	table.insert(self._connections, ackRemote.OnServerEvent:Connect(function(player: Player)
		pcall(function()
			self._oilHeavenPlotService:RefreshUnlocks(player.UserId)
		end)
	end))

end

function OilHeavenDrillService:Stop()
	self._running = false
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
	if self._drillAttrConns then
		for _, conn in pairs(self._drillAttrConns) do
			conn:Disconnect()
		end
		table.clear(self._drillAttrConns)
	end
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

	--- Consume the drill at *scheduling* time, not at the post-delay reward
	--- claim, so the player can't fire `RequestHeavenDrill` against tile A then
	--- tile B during the 3s window with a single drill in inventory. The
	--- attribute-change watcher (`_attachDrillAttrWatcher`) syncs the Backpack
	--- tool — when this drops the count to 0 the Tool is removed mid-animation,
	--- which is fine because the active drill is keyed off the server-side
	--- `_activeDrills` set, not tool presence.
	if not self._oilStateService:ConsumeRebirthDrill(player.UserId) then
		self:_sendActionResult(player, false, "ERR_HEAVEN_NO_DRILL", "You don't have a Rebirth Drill.", nil)
		return
	end
	self._activeDrills[drillKey] = true

	-- Tell client to spawn the drill visual + spin animation
	local tileTop = tilePart.Position.Y + tilePart.Size.Y / 2
	local rebirthRequired = tilePart:GetAttribute("RebirthRequired")
	self._rewardEvent:FireClient(player, {
		kind = "drillingStarted",
		tileId = tilePart.Name,
		position = { x = tilePart.Position.X, y = tileTop, z = tilePart.Position.Z },
	})

	-- 3-second drill time, then claim reward
	task.delay(3, function()
		self._activeDrills[drillKey] = nil

		local ok, code, message, reward = self._oilStateService:ClaimOilHeavenRewardTile(player.UserId, tilePart.Name, rebirthRequired)
		if not ok or not reward then
			--- Refund the drill we debited at scheduling time. Realistically
			--- only `ERR_HEAVEN_TILE_CLAIMED` can fire here (a race with
			--- another path claiming the same tile, e.g. dev tools) — every
			--- other failure mode in `ClaimOilHeavenRewardTile` was checked
			--- upfront. Refunding keeps the player whole on these edge cases.
			self._oilStateService:AddRebirthDrills(player.UserId, 1)
			self:_sendActionResult(player, false, code, message, nil)
			return
		end

		self._oilStateService:PushState(player.UserId)
		-- NOTE: RefreshUnlocks is deliberately NOT called here. The tile
		-- reward visual (number + effect on the tile) must stay hidden until
		-- the lootbox spinner is dismissed — otherwise the player sees the
		-- 1× value on the tile before deciding whether to pay for 2×.
		-- The client fires `HeavenRewardAcknowledged` from the lootbox
		-- `onNext` callback, which triggers `RefreshUnlocks` at that point.

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
