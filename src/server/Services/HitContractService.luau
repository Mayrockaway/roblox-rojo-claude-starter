--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local HitContractConfig = require(Shared:WaitForChild("Config"):WaitForChild("HitContractConfig"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

-- Re-bound for call-site readability; authoritative tuning lives in `HitContractConfig`.
local HIT_COST_CASH = HitContractConfig.Cost

local HitContractService = {}
local PIRATE_HIRE_PROMPT_DISTANCE = 36

local function firstBasePart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			return d
		end
	end
	return nil
end

--- Prefer the **`Pirate`** character model under `PirateHire` (not props / flag).
--- Use a visible upper body part first so the interaction bubble doesn't feel
--- buried inside the NPC's invisible root part.
local function promptHostForPirateHire(npc: Instance): BasePart?
	local pirate = npc:FindFirstChild("Pirate")
	if pirate and pirate:IsA("Model") then
		local head = pirate:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			return head
		end
		local upper = pirate:FindFirstChild("UpperTorso")
		if upper and upper:IsA("BasePart") then
			return upper
		end
		local torso = pirate:FindFirstChild("Torso")
		if torso and torso:IsA("BasePart") then
			return torso
		end
		local hrp = pirate:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp
		end
		return firstBasePart(pirate)
	end
	return firstBasePart(npc)
end

function HitContractService:Init(remoteService, oilStateService, oilShipmentService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._oilShipmentService = oilShipmentService
	self._connections = {}
	self._contractsByVictim = {} :: { [number]: { [string]: any } }
	self._contractsById = {} :: { [string]: { [string]: any } }
	self._freeHitTokens = {} :: { [number]: number }
	self._prompt = nil :: ProximityPrompt?
	--- Once `Workspace.PirateHire` exists, listen for rig/parts streaming in under it.
	self._pirateHireStreamingNpc = nil :: Instance?
end

function HitContractService:_tokenCount(userId: number): number
	return math.max(0, self._freeHitTokens[userId] or 0)
end

function HitContractService:GetFreeHitTokenCount(userId: number): number
	return self:_tokenCount(userId)
end

function HitContractService:_fireOpen(player: Player)
	local ev = self._remoteService:GetEvent(RemoteNames.PirateHireOpen)
	ev:FireClient(player, {
		hitCost = HIT_COST_CASH,
		freeHitTokens = self:_tokenCount(player.UserId),
	})
end

function HitContractService:_fireResult(player: Player, ok: boolean, message: string, data: { [string]: any }?)
	local ev = self._remoteService:GetEvent(RemoteNames.PirateHireResult)
	ev:FireClient(player, {
		ok = ok,
		message = message,
		data = data or {},
	})
end

function HitContractService:_activeContractForVictim(victimUserId: number)
	return self._contractsByVictim[victimUserId]
end

function HitContractService:GrantRefundToken(userId: number, reason: string)
	self._freeHitTokens[userId] = self:_tokenCount(userId) + 1
	local player = Players:GetPlayerByUserId(userId)
	if player then
		self:_fireResult(player, true, "Your hit was refunded. You received a free replacement hit token.", {
			refundReason = reason,
			freeHitTokens = self:_tokenCount(userId),
		})
	end
end

function HitContractService:_consumeToken(userId: number): boolean
	local count = self:_tokenCount(userId)
	if count <= 0 then
		return false
	end
	self._freeHitTokens[userId] = count - 1
	return true
end

function HitContractService:TryCreateHit(contractorUserId: number, victimUserId: number): (boolean, string, { [string]: any }?)
	if contractorUserId == victimUserId then
		return false, "You can't place a hit on yourself.", nil
	end

	local contractor = Players:GetPlayerByUserId(contractorUserId)
	local victim = Players:GetPlayerByUserId(victimUserId)
	if not contractor or not victim then
		return false, "That target is not available.", nil
	end

	if self:_activeContractForVictim(victimUserId) then
		return false, "That target already has an active hit.", nil
	end

	local usedFreeToken = self:_consumeToken(contractorUserId)
	if not usedFreeToken then
		if not self._oilStateService:TrySpendCash(contractorUserId, HIT_COST_CASH) then
			return false, string.format("Need $%d cash to hire a hit.", HIT_COST_CASH), nil
		end
		self._oilStateService:PushState(contractorUserId)
	end

	local contractId = tostring(contractorUserId) .. "_" .. tostring(victimUserId) .. "_" .. tostring(math.floor(workspace:GetServerTimeNow() * 1000))
	local contract = {
		contractId = contractId,
		contractorUserId = contractorUserId,
		victimUserId = victimUserId,
		state = "pending",
		createdAt = workspace:GetServerTimeNow(),
	}

	self._contractsByVictim[victimUserId] = contract
	self._contractsById[contractId] = contract

	-- Telemetry §6.5 `pirate_hire_created` (Sink — only when paid, not
	-- when consuming a free-replacement token). Fires after the contract
	-- row is committed so a `QueueOrInjectForActiveShipment` failure
	-- still records the attempt that took the player's cash.
	pcall(function()
		if not usedFreeToken then
			Telemetry.Economy(contractor, "Sink", HIT_COST_CASH, "cash", "pirate_hire", { kind = "pirate_hire", id = "hire" })
		end
		Telemetry.Track(contractor, "pirate_hire_created", {
			contractId = contractId,
			victimUserId = victimUserId,
			cost = if usedFreeToken then 0 else HIT_COST_CASH,
			usedFreeToken = usedFreeToken,
		})
	end)

	local queued, queueState, shipmentId = self:QueueOrInjectForActiveShipment(victimUserId, contractId)
	if queued then
		contract.state = "attached"
		contract.shipmentId = shipmentId
		return true, "Hit accepted. Pirates are on their way.", {
			victimUserId = victimUserId,
			usedFreeToken = usedFreeToken,
			queueState = queueState,
			freeHitTokens = self:_tokenCount(contractorUserId),
		}
	end

	return true, "Hit accepted. Pirates will strike the next time they set sail.", {
		victimUserId = victimUserId,
		usedFreeToken = usedFreeToken,
		freeHitTokens = self:_tokenCount(contractorUserId),
	}
end

function HitContractService:QueueOrInjectForActiveShipment(
	victimUserId: number,
	contractId: string
): (boolean, string, string?)
	local c = self._contractsById[contractId]
	if not c then
		return false, "NOT_FOUND", nil
	end
	if not self._oilShipmentService or typeof(self._oilShipmentService.QueueOrTriggerForcedPirateHit) ~= "function" then
		return false, "SHIPMENT_SERVICE_UNAVAILABLE", nil
	end
	return self._oilShipmentService:QueueOrTriggerForcedPirateHit(victimUserId, c.contractorUserId, contractId)
end

function HitContractService:PeekPendingForVictim(victimUserId: number)
	local c = self:_activeContractForVictim(victimUserId)
	if not c then
		return nil
	end
	if c.state ~= "pending" then
		return nil
	end
	return c
end

function HitContractService:ConsumePendingForVictim(victimUserId: number)
	local c = self:PeekPendingForVictim(victimUserId)
	if not c then
		return nil
	end
	c.state = "attached"
	return c
end

function HitContractService:MarkContractAttached(contractId: string, shipmentId: string?)
	local c = self._contractsById[contractId]
	if not c then
		return
	end
	c.state = "attached"
	c.shipmentId = shipmentId
end

function HitContractService:MarkContractExecuted(contractId: string)
	local c = self._contractsById[contractId]
	if not c then
		return
	end
	c.state = "executed"
	self._contractsById[contractId] = nil
	if self._contractsByVictim[c.victimUserId] == c then
		self._contractsByVictim[c.victimUserId] = nil
	end
	-- Telemetry §6.5 `pirate_hire_executed`. Per-victim impact rows
	-- (`shipment_pirate_hit` / `_payout`) live in `OilShipmentService`
	-- once the raid actually lands; this row marks the contract
	-- lifecycle close.
	pcall(function()
		local contractor = Players:GetPlayerByUserId(c.contractorUserId)
		Telemetry.Track(contractor, "pirate_hire_executed", {
			contractId = contractId,
			victimUserId = c.victimUserId,
			shipmentId = c.shipmentId,
		})
	end)
end

function HitContractService:RefundContract(contractId: string, reason: string)
	local c = self._contractsById[contractId]
	if not c then
		return
	end
	self._contractsById[contractId] = nil
	if self._contractsByVictim[c.victimUserId] == c then
		self._contractsByVictim[c.victimUserId] = nil
	end
	-- Telemetry §6.5 `pirate_hire_refunded`. Fires on contract teardown
	-- before the refund token grant so we capture every refund regardless
	-- of whether the token landed (e.g. contractor disconnected mid-frame).
	pcall(function()
		local contractor = Players:GetPlayerByUserId(c.contractorUserId)
		Telemetry.Track(contractor, "pirate_hire_refunded", {
			contractId = contractId,
			victimUserId = c.victimUserId,
			reason = reason,
		})
	end)
	self:GrantRefundToken(c.contractorUserId, reason)
end

function HitContractService:_onPirateHirePrompt(player: Player)
	self:_fireOpen(player)
end

function HitContractService:_hookPirateHireStreaming(npc: Instance)
	if self._pirateHireStreamingNpc == npc then
		return
	end
	self._pirateHireStreamingNpc = npc
	table.insert(self._connections, npc.DescendantAdded:Connect(function()
		task.defer(function()
			self:_ensurePrompt()
		end)
	end))
end

function HitContractService:_ensurePrompt()
	local npc = Workspace:FindFirstChild("PirateHire") or Workspace:FindFirstChild("PirateHire", true)
	if not npc then
		return
	end
	self:_hookPirateHireStreaming(npc)
	local host = promptHostForPirateHire(npc)
	if not host then
		return
	end
	local staleAttachment = host:FindFirstChild("PirateHirePromptAttachment")
	if staleAttachment and staleAttachment:IsA("Attachment") then
		staleAttachment:Destroy()
	end
	local prompt = npc:FindFirstChild("PirateHirePrompt", true)
	if prompt and not prompt:IsA("ProximityPrompt") then
		prompt:Destroy()
		prompt = nil
	end
	if prompt then
		prompt.Parent = host
	else
		local p = Instance.new("ProximityPrompt")
		p.Name = "PirateHirePrompt"
		p.ActionText = "Talk"
		p.ObjectText = "Pirate Broker"
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.MaxActivationDistance = PIRATE_HIRE_PROMPT_DISTANCE
		p.RequiresLineOfSight = false
		p.HoldDuration = 0
		p.ClickablePrompt = true
		p.Parent = host
		prompt = p
	end
	prompt.ActionText = "Talk"
	prompt.ObjectText = "Pirate Broker"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = PIRATE_HIRE_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.ClickablePrompt = true
	if self._prompt == prompt then
		return
	end
	self._prompt = prompt :: ProximityPrompt
	table.insert(self._connections, (prompt :: ProximityPrompt).Triggered:Connect(function(player)
		self:_onPirateHirePrompt(player)
	end))
end

function HitContractService:_buildTargetsFor(player: Player): { [number]: { [string]: any } }
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId ~= player.UserId then
			table.insert(out, {
				userId = p.UserId,
				name = p.Name,
				displayName = p.DisplayName,
			})
		end
	end
	table.sort(out, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

function HitContractService:_onRequestAction(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_fireResult(player, false, "Bad pirate request payload.", nil)
		return
	end
	local action = tostring(payload.action or "")
	-- Legacy `action == "ask"` (broker quote easter-egg) was removed when the
	-- client replaced the ask button with a static pitch label. The server no
	-- longer responds to it; only "hire" is valid now.
	if action ~= "hire" then
		self:_fireResult(player, false, "Unknown pirate action.", nil)
		return
	end

	local victimUserId = tonumber(payload.victimUserId)
	if not victimUserId then
		self:_fireResult(player, false, "Choose a valid target.", nil)
		return
	end

	local ok, message, data = self:TryCreateHit(player.UserId, victimUserId)
	self:_fireResult(player, ok, message, data)
end

function HitContractService:Start()
	local requestTargetsFn = self._remoteService:GetFunction(RemoteNames.RequestPirateHireTargets)
	requestTargetsFn.OnServerInvoke = function(player: Player)
		return {
			targets = self:_buildTargetsFor(player),
			freeHitTokens = self:_tokenCount(player.UserId),
			hitCost = HIT_COST_CASH,
		}
	end

	local actionEvent = self._remoteService:GetEvent(RemoteNames.RequestPirateHireAction)
	table.insert(self._connections, actionEvent.OnServerEvent:Connect(function(player, payload)
		self:_onRequestAction(player, payload)
	end))

	self:_ensurePrompt()
	table.insert(self._connections, Workspace.DescendantAdded:Connect(function(inst)
		if inst.Name == "PirateHire" then
			task.defer(function()
				self:_ensurePrompt()
			end)
		end
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		local c = self._contractsByVictim[userId]
		if c then
			self:RefundContract(c.contractId, "target_left")
		end
		self._freeHitTokens[userId] = nil
	end))
end

function HitContractService:Stop()
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	self._connections = {}
	self._prompt = nil
	self._pirateHireStreamingNpc = nil
	self._contractsByVictim = {}
	self._contractsById = {}
	self._freeHitTokens = {}
end

return HitContractService
