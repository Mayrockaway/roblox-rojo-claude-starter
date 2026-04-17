--!strict
-- ArmyGeneralService: Army General NPC interaction for Nuke + Airstrike purchases.
-- Nuke: Robux purchase, 5-min cooldown, destroys ALL boats in strait.
-- Airstrike: $10,000 cash, targets a specific player's boat with a jet bombing run.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local StraitEventCatalog = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local ArmyGeneralService = {}

local AIRSTRIKE_COST = StraitEventCatalog.AirStrikeConfig.Cost
local NUKE_COOLDOWN = StraitEventCatalog.NukeConfig.CooldownSeconds

function ArmyGeneralService:Init(remoteService, oilStateService, oilShipmentService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._oilShipmentService = oilShipmentService
	self._connections = {}
	self._lastNukeTime = 0
	self._hookedPrompts = {}
end

function ArmyGeneralService:Start()
	-- Wire remotes
	local actionEvent = self._remoteService:GetEvent(RemoteNames.RequestArmyGeneralAction)
	table.insert(self._connections, actionEvent.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "table" then return end
		local action = payload.action
		if action == "nuke" then
			self:_handleNuke(player)
		elseif action == "airstrike" then
			self:_handleAirstrike(player, payload)
		end
	end))

	-- Target list (RemoteFunction)
	local targetsFn = self._remoteService:GetFunction(RemoteNames.RequestArmyGeneralTargets)
	targetsFn.OnServerInvoke = function(player)
		return self:_getTargets(player)
	end

	-- Find and hook Army General NPC
	self:_hookArmyGeneral()

	-- Hook any late-spawned Army General
	table.insert(self._connections, workspace.DescendantAdded:Connect(function(d)
		if d.Name == "Army General" and d:IsA("Model") then
			task.defer(function() self:_hookArmyGeneral() end)
		end
	end))
end

function ArmyGeneralService:Stop()
	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._connections = {}
end

-- =================== NPC PROMPT ===================

function ArmyGeneralService:_hookArmyGeneral()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "Army General" and d:IsA("Model") and not self._hookedPrompts[d] then
			self._hookedPrompts[d] = true

			-- Find a part to attach prompt to
			local attachPart = d:FindFirstChild("HumanoidRootPart")
				or d:FindFirstChild("UpperTorso")
				or d:FindFirstChild("Torso")
				or d:FindFirstChild("Head")
				or d:FindFirstChildWhichIsA("BasePart")
			if not attachPart then continue end

			-- Remove existing prompts
			for _, child in ipairs(attachPart:GetChildren()) do
				if child:IsA("ProximityPrompt") and child.Name == "ArmyGeneralPrompt" then
					child:Destroy()
				end
			end

			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "ArmyGeneralPrompt"
			prompt.ActionText = "Talk"
			prompt.ObjectText = "Army General"
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.MaxActivationDistance = 10
			prompt.RequiresLineOfSight = false
			prompt.HoldDuration = 0
			prompt.Parent = attachPart

			table.insert(self._connections, prompt.Triggered:Connect(function(player)
				local openEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralOpen)
				local nukeCooldownRemaining = math.max(0, NUKE_COOLDOWN - (workspace:GetServerTimeNow() - self._lastNukeTime))
				openEvent:FireClient(player, {
					airstrikeCost = AIRSTRIKE_COST,
					nukeCooldownRemaining = nukeCooldownRemaining,
				})
			end))

			DevLog.log("[ArmyGeneralService] Hooked prompt on " .. d:GetFullName())
		end
	end
end

-- =================== TARGET LIST ===================

function ArmyGeneralService:_getTargets(requestingPlayer: Player)
	local targets = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId ~= requestingPlayer.UserId then
			-- Check if player has an active shipment
			local hasShipment = self._oilShipmentService:HasActiveShipment(player.UserId)
			table.insert(targets, {
				userId = player.UserId,
				name = player.Name,
				displayName = player.DisplayName,
				hasShipment = hasShipment,
			})
		end
	end
	return {
		targets = targets,
		airstrikeCost = AIRSTRIKE_COST,
	}
end

-- =================== NUKE ===================

function ArmyGeneralService:_handleNuke(player: Player)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)
	local now = workspace:GetServerTimeNow()

	-- Cooldown check
	if now - self._lastNukeTime < NUKE_COOLDOWN then
		local remaining = math.ceil(NUKE_COOLDOWN - (now - self._lastNukeTime))
		resultEvent:FireClient(player, {
			ok = false,
			message = string.format("Nuke on cooldown! %d seconds remaining.", remaining),
		})
		return
	end

	-- TODO: Robux purchase via MarketplaceService:PromptProductPurchase
	-- For now, allow it freely in Studio for testing
	if not RunService:IsStudio() then
		resultEvent:FireClient(player, {
			ok = false,
			message = "Nuke purchase not yet available.",
		})
		return
	end

	self._lastNukeTime = now

	-- Fire countdown to ALL clients
	local countdownEvent = self._remoteService:GetEvent(RemoteNames.NukeCountdownEvent)
	local cfg = StraitEventCatalog.NukeConfig
	countdownEvent:FireAllClients({
		detonateAt = now + cfg.CountdownSeconds,
		launchedBy = player.Name,
	})

	DevLog.log(string.format("[ArmyGeneralService] NUKE launched by %s! Detonating in %ds", player.Name, cfg.CountdownSeconds))

	-- Wait for countdown
	task.wait(cfg.CountdownSeconds)

	-- Detonate: destroy all active shipments
	local detonateEvent = self._remoteService:GetEvent(RemoteNames.NukeDetonateEvent)

	-- Collect all active shipment positions for client visuals
	local shipmentPositions = {}
	local activeShipments = self._oilShipmentService:GetAllActiveShipments()
	if activeShipments then
		for _, shipment in pairs(activeShipments) do
			local boat = self._oilShipmentService:GetActiveBoat(shipment.shipmentId)
			if boat then
				local root = boat:IsA("Model") and boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
				if root then
					table.insert(shipmentPositions, {
						shipmentId = shipment.shipmentId,
						ownerUserId = shipment.ownerUserId,
						position = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z },
					})
				end
			end
		end
	end

	detonateEvent:FireAllClients({
		launchedBy = player.Name,
		shipments = shipmentPositions,
	})

	-- Mark all active shipments as total loss (with extended respawn delay for nuke cinematic)
	self._oilShipmentService._nukeActive = true
	for _, info in ipairs(shipmentPositions) do
		self._oilShipmentService:ForceDestroyShipment(info.shipmentId, "Nuclear strike")
	end
	task.delay(10, function()
		self._oilShipmentService._nukeActive = false
	end)

	resultEvent:FireClient(player, {
		ok = true,
		message = string.format("NUKE DETONATED! %d boats destroyed.", #shipmentPositions),
	})
end

-- =================== AIRSTRIKE ===================

function ArmyGeneralService:_handleAirstrike(player: Player, payload)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)
	local victimUserId = tonumber(payload.victimUserId)
	if not victimUserId then
		resultEvent:FireClient(player, { ok = false, message = "Invalid target." })
		return
	end

	if victimUserId == player.UserId then
		resultEvent:FireClient(player, { ok = false, message = "Can't airstrike yourself." })
		return
	end

	-- Check victim has active shipment
	if not self._oilShipmentService:HasActiveShipment(victimUserId) then
		resultEvent:FireClient(player, { ok = false, message = "Target has no active shipment." })
		return
	end

	-- Charge cash
	if not self._oilStateService:TrySpendCash(player.UserId, AIRSTRIKE_COST) then
		resultEvent:FireClient(player, {
			ok = false,
			message = string.format("Not enough cash. Need $%d.", AIRSTRIKE_COST),
		})
		return
	end
	self._oilStateService:PushState(player.UserId)

	-- Get victim's boat position
	local victimShipment = self._oilShipmentService:GetActiveShipmentForUser(victimUserId)
	if not victimShipment then
		-- Refund
		self._oilStateService:AddCash(player.UserId, AIRSTRIKE_COST)
		self._oilStateService:PushState(player.UserId)
		resultEvent:FireClient(player, { ok = false, message = "Target's shipment ended." })
		return
	end

	local boat = self._oilShipmentService:GetActiveBoat(victimShipment.shipmentId)
	if not boat then
		self._oilStateService:AddCash(player.UserId, AIRSTRIKE_COST)
		self._oilStateService:PushState(player.UserId)
		resultEvent:FireClient(player, { ok = false, message = "Target boat not found." })
		return
	end

	local root = boat:IsA("Model") and boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
	if not root then
		self._oilStateService:AddCash(player.UserId, AIRSTRIKE_COST)
		self._oilStateService:PushState(player.UserId)
		resultEvent:FireClient(player, { ok = false, message = "Target boat error." })
		return
	end

	-- General airstrike = GUARANTEED HIT (instakill)
	local cfg = StraitEventCatalog.AirStrikeConfig
	local rng = Random.new()

	-- Calculate jet flight path over the boat
	local boatPos = root.Position
	local jetAlt = cfg.JetAltitude
	local jetDir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit
	local jetStart = boatPos + jetDir * 600 + Vector3.new(0, jetAlt, 0)
	local jetEnd = boatPos - jetDir * 600 + Vector3.new(0, jetAlt, 0)

	local victimPlayer = Players:GetPlayerByUserId(victimUserId)

	-- Fire airstrike event to ALL clients — always hit, barrage of bombs
	local airstrikeEvent = self._remoteService:GetEvent(RemoteNames.AirStrikeEvent)
	airstrikeEvent:FireAllClients({
		contractorUserId = player.UserId,
		contractorName = player.Name,
		victimUserId = victimUserId,
		victimName = victimPlayer and victimPlayer.Name or "Unknown",
		victimShipmentId = victimShipment.shipmentId,
		outcome = "hit", -- always hit when purchased through General
		bombCount = 8, -- barrage of bombs
		jetStart = { x = jetStart.X, y = jetStart.Y, z = jetStart.Z },
		jetEnd = { x = jetEnd.X, y = jetEnd.Y, z = jetEnd.Z },
		targetPosition = { x = boatPos.X, y = boatPos.Y, z = boatPos.Z },
		jetSpeed = cfg.JetSpeed,
		bombFallDuration = cfg.BombFallDuration,
	})

	DevLog.log(string.format("[ArmyGeneralService] AIRSTRIKE by %s on %s — %s",
		player.Name, victimPlayer and victimPlayer.Name or tostring(victimUserId),
		hit and "HIT" or "MISS"))

	-- Wait for animation
	task.wait(cfg.SequenceDuration)

	if hit then
		self._oilShipmentService:ForceDestroyShipment(victimShipment.shipmentId, "Airstrike hit")
		resultEvent:FireClient(player, {
			ok = true,
			message = string.format("AIRSTRIKE HIT! %s's shipment destroyed.", victimPlayer and victimPlayer.Name or "Target"),
		})
	else
		resultEvent:FireClient(player, {
			ok = true,
			message = string.format("Airstrike missed %s's shipment.", victimPlayer and victimPlayer.Name or "Target"),
		})
	end
end

-- =================== DEBUG ===================

function ArmyGeneralService:DebugNuke(player: Player)
	self._lastNukeTime = 0 -- Reset cooldown
	self:_handleNuke(player)
end

function ArmyGeneralService:DebugAirstrike(player: Player, victimUserId: number?)
	-- If no victim specified, pick the first other player with a shipment
	local targetId = victimUserId
	if not targetId then
		for _, p in ipairs(Players:GetPlayers()) do
			if p.UserId ~= player.UserId and self._oilShipmentService:HasActiveShipment(p.UserId) then
				targetId = p.UserId
				break
			end
		end
	end
	if not targetId then
		-- Airstrike own shipment for testing
		targetId = player.UserId
	end

	-- Bypass cash check for debug
	local cfg = StraitEventCatalog.AirStrikeConfig
	local victimShipment = self._oilShipmentService:GetActiveShipmentForUser(targetId)
	if not victimShipment then
		warn("[ArmyGeneralService] Debug airstrike: no active shipment for target")
		return
	end

	local boat = self._oilShipmentService:GetActiveBoat(victimShipment.shipmentId)
	if not boat then
		warn("[ArmyGeneralService] Debug airstrike: no boat found")
		return
	end

	local root = boat:IsA("Model") and boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
	if not root then return end

	local rng = Random.new()
	local boatPos = root.Position
	local jetDir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit
	local jetStart = boatPos + jetDir * 600 + Vector3.new(0, cfg.JetAltitude, 0)
	local jetEnd = boatPos - jetDir * 600 + Vector3.new(0, cfg.JetAltitude, 0)

	local airstrikeEvent = self._remoteService:GetEvent(RemoteNames.AirStrikeEvent)
	airstrikeEvent:FireAllClients({
		contractorUserId = player.UserId,
		contractorName = player.Name,
		victimUserId = targetId,
		victimName = Players:GetPlayerByUserId(targetId) and Players:GetPlayerByUserId(targetId).Name or "Debug",
		victimShipmentId = victimShipment.shipmentId,
		outcome = "hit",
		jetStart = { x = jetStart.X, y = jetStart.Y, z = jetStart.Z },
		jetEnd = { x = jetEnd.X, y = jetEnd.Y, z = jetEnd.Z },
		targetPosition = { x = boatPos.X, y = boatPos.Y, z = boatPos.Z },
		jetSpeed = cfg.JetSpeed,
		bombFallDuration = cfg.BombFallDuration,
	})

	task.wait(cfg.SequenceDuration)
	self._oilShipmentService:ForceDestroyShipment(victimShipment.shipmentId, "Debug airstrike")
end

return ArmyGeneralService
