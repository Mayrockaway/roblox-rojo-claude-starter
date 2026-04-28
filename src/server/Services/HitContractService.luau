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
	--- `"<contractorUserId>:<victimUserId"` → workspace clock when hire cooldown ends.
	self._hireCooldownEndsAtByPair = {} :: { [string]: number }
	self._freeHitTokens = {} :: { [number]: number }
	self._prompt = nil :: ProximityPrompt?
	--- Once `Workspace.PirateHire` exists, listen for rig/parts streaming in under it.
	self._pirateHireStreamingNpc = nil :: Instance?
	--- Per-contractor "what target did they just click Robux-hire on?" stamp.
	--- Set when the client fires `action == "promptHireRobux"`, read by the
	--- registered `SetPromptPrecondition` (defense-in-depth gate before the
	--- Robux dialog opens) and again by the `SetConsumableHandler` once the
	--- receipt lands. `stampedAt` is `os.clock()`; entries older than
	--- `_PENDING_ROBUX_TARGET_TTL_SECONDS` are treated as stale and rejected.
	self._pendingRobuxTargets = {} :: { [number]: { victimUserId: number, stampedAt: number } }
	self._monetizationService = nil :: any
end

--- Time window during which a Robux-hire stamp on `_pendingRobuxTargets` is
--- treated as "live". Long enough to cover the player closing the Roblox
--- prompt and re-opening it once, short enough that a player can't keep an
--- old target stamp alive across long idle periods.
local _PENDING_ROBUX_TARGET_TTL_SECONDS = 90

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

local function _pairCooldownKey(contractorUserId: number, victimUserId: number): string
	return tostring(contractorUserId) .. ":" .. tostring(victimUserId)
end

function HitContractService:_hireCooldownRemainingSeconds(contractorUserId: number, victimUserId: number): number
	local endsAt = self._hireCooldownEndsAtByPair[_pairCooldownKey(contractorUserId, victimUserId)]
	if not endsAt then
		return 0
	end
	local now = workspace:GetServerTimeNow()
	local rem = endsAt - now
	return if rem > 0 then math.ceil(rem) else 0
end

function HitContractService:_stampHireCooldown(contractorUserId: number, victimUserId: number)
	self._hireCooldownEndsAtByPair[_pairCooldownKey(contractorUserId, victimUserId)] =
		workspace:GetServerTimeNow() + HitContractConfig.SameTargetHireCooldownSeconds
end

--- `opts.paymentMethod` selects how the hire was paid for:
---   * `"cash"` (default) — debit `HIT_COST_CASH` via `OilStateService:TrySpendCash`,
---     unless a free-replacement token covers the cost.
---   * `"robux"` — caller is the Robux receipt handler in
---     `SetMonetizationService`. The player already paid in Robux at the
---     `MarketplaceService:Prompt*Purchase` step, so we skip the cash spend
---     entirely AND skip the free-token consume (Robux is a separate
---     currency rail; we don't want a Robux purchase to silently consume a
---     refund-replacement token instead). Telemetry's `Telemetry.Economy
---     ("Sink", ..., "pirate_hire")` only fires on the cash path so the
---     soft-currency dashboard isn't double-counted; the Robux path is
---     reported by `MonetizationService` via `Telemetry.Purchase`.
function HitContractService:TryCreateHit(
	contractorUserId: number,
	victimUserId: number,
	opts: { paymentMethod: string? }?
): (boolean, string, { [string]: any }?)
	local paymentMethod = (opts and opts.paymentMethod) or "cash"

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

	-- Robux purchases bypass the same-target cooldown — that's the whole
	-- point of paying Robux from the player's perspective. Cash hires
	-- continue to enforce the anti-spam window.
	if paymentMethod ~= "robux" then
		local cdRem = self:_hireCooldownRemainingSeconds(contractorUserId, victimUserId)
		if cdRem > 0 then
			local m = math.floor(cdRem / 60)
			local s = cdRem % 60
			return false, string.format("Wait %d:%02d before hiring pirates on that player again.", m, s), {
				cooldownRemainingSeconds = cdRem,
				victimUserId = victimUserId,
			}
		end
	end

	local usedFreeToken = false
	if paymentMethod == "cash" then
		usedFreeToken = self:_consumeToken(contractorUserId)
		if not usedFreeToken then
			if not self._oilStateService:TrySpendCash(contractorUserId, HIT_COST_CASH) then
				return false, string.format("Need $%d cash to hire a hit.", HIT_COST_CASH), nil
			end
			self._oilStateService:PushState(contractorUserId)
		end
	end
	-- `paymentMethod == "robux"` falls through with `usedFreeToken = false`
	-- and no cash debit — receipt handler already paid in Robux.

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

	-- Stamp the same-target cooldown only on cash hires. Robux purchases
	-- bypass the cooldown gate AND don't stamp it themselves — paying Robux
	-- is the "no cooldowns" feature, so a cash hire 30s after a Robux hire
	-- on the same victim is fine. Per design (`HitContractConfig`).
	if paymentMethod ~= "robux" then
		self:_stampHireCooldown(contractorUserId, victimUserId)
	end

	-- Telemetry §6.5 `pirate_hire_created` (Sink — only when paid in cash, not
	-- when consuming a free-replacement token, and not when paid in Robux —
	-- Robux is reported separately by `MonetizationService:_processReceipt`
	-- via `Telemetry.Purchase`). Fires after the contract row is committed so
	-- a `QueueOrInjectForActiveShipment` failure still records the attempt.
	pcall(function()
		if paymentMethod == "cash" and not usedFreeToken then
			Telemetry.Economy(contractor, "Sink", HIT_COST_CASH, "cash", "pirate_hire", { kind = "pirate_hire", id = "hire" })
		end
		local cost: number
		if paymentMethod == "robux" or usedFreeToken then
			cost = 0
		else
			cost = HIT_COST_CASH
		end
		Telemetry.Track(contractor, "pirate_hire_created", {
			contractId = contractId,
			victimUserId = victimUserId,
			cost = cost,
			usedFreeToken = usedFreeToken,
			paymentMethod = paymentMethod,
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
				hireCooldownRemainingSeconds = self:_hireCooldownRemainingSeconds(player.UserId, p.UserId),
			})
		end
	end
	table.sort(out, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

--- Common pre-payment validation: target must exist online, not be the
--- contractor, not already have an active contract, and (for cash hires) the
--- (contractor, victim) cooldown must be expired.
---
--- `opts.skipCooldown = true` bypasses the same-target cooldown gate. This
--- is the Robux escape hatch — paying Robux is the "skip the cooldown"
--- feature, so the precondition + receipt handler pass it. Cash hires
--- (`TryCreateHit({ paymentMethod = "cash" })`, the default) pass nil/false
--- and continue to enforce anti-spam.
function HitContractService:_validateHireTarget(
	contractorUserId: number,
	victimUserId: number,
	opts: { skipCooldown: boolean? }?
): (boolean, string, { [string]: any }?)
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
	local skipCooldown = (opts ~= nil) and (opts :: any).skipCooldown == true
	if not skipCooldown then
		local cdRem = self:_hireCooldownRemainingSeconds(contractorUserId, victimUserId)
		if cdRem > 0 then
			local m = math.floor(cdRem / 60)
			local s = cdRem % 60
			return false, string.format("Wait %d:%02d before hiring pirates on that player again.", m, s), {
				cooldownRemainingSeconds = cdRem,
				victimUserId = victimUserId,
			}
		end
	end
	return true, "", nil
end

--- Stamp `_pendingRobuxTargets[contractorUserId] = { victimUserId, ... }`
--- and open the Robux purchase prompt for `consumable.pirate_hire_x1`.
--- Wired from `_onRequestAction` when the client clicks the per-target
--- Robux button (`action = "promptHireRobux"`). The actual hire executes
--- inside the `SetMonetizationService` consumable handler once the receipt
--- lands.
function HitContractService:_handlePromptHireRobux(player: Player, payload: any)
	if not self._monetizationService then
		self:_fireResult(player, false, "Robux purchases not available.", nil)
		return
	end
	local victimUserId = tonumber(payload.victimUserId)
	if not victimUserId then
		self:_fireResult(player, false, "Choose a valid target.", nil)
		return
	end
	-- Robux variant skips the same-target cooldown — paying Robux is the
	-- "skip the cooldown" path. The other validation gates (self-hire,
	-- target online, no active contract) still apply.
	local ok, message, data = self:_validateHireTarget(player.UserId, victimUserId, { skipCooldown = true })
	if not ok then
		self:_fireResult(player, false, message, data)
		return
	end
	self._pendingRobuxTargets[player.UserId] = {
		victimUserId = victimUserId,
		stampedAt = os.clock(),
	}
	-- Routes through `MonetizationService:_handlePromptRequest`, which runs
	-- the registered `consumable.pirate_hire_x1` precondition (defense in
	-- depth) and then opens `MarketplaceService:PromptProductPurchase`.
	-- Result/error toast lands on the client via `MonetizationResult`.
	self._monetizationService:PromptPurchase(player, "consumable.pirate_hire_x1")
end

function HitContractService:_onRequestAction(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_fireResult(player, false, "Bad pirate request payload.", nil)
		return
	end
	local action = tostring(payload.action or "")
	-- `"hire"` — cash payment path (legacy default).
	-- `"promptHireRobux"` — Robux payment path: stamp pending target +
	-- open Roblox prompt; the consumable receipt handler runs the hire.
	if action == "hire" then
		local victimUserId = tonumber(payload.victimUserId)
		if not victimUserId then
			self:_fireResult(player, false, "Choose a valid target.", nil)
			return
		end
		local ok, message, data = self:TryCreateHit(player.UserId, victimUserId)
		self:_fireResult(player, ok, message, data)
		return
	elseif action == "promptHireRobux" then
		self:_handlePromptHireRobux(player, payload)
		return
	end
	self:_fireResult(player, false, "Unknown pirate action.", nil)
end

--- Wire the Robux variant of pirate hire into `MonetizationService`. Mirrors
--- the pattern `ArmyGeneralService:SetMonetizationService` uses for the nuke:
--- a pre-prompt precondition rejects the dialog before the player is charged
--- if the target is no longer attackable, and the receipt handler runs the
--- hire grant once Roblox confirms the purchase. Storing the intended
--- `victimUserId` in `_pendingRobuxTargets` lets us thread per-action context
--- through the consumable handler's `(userId, quantity)` signature.
function HitContractService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end

	-- Defense-in-depth gate: the action handler already validated the target
	-- when stamping the pending target, but state can shift between the
	-- click and the prompt opening (target leaves, target gets hit by
	-- someone else, cooldown stamp lands). Re-validate here so the player
	-- isn't charged for a hire that can no longer execute.
	monetizationService:SetPromptPrecondition("consumable.pirate_hire_x1", function(player: Player)
		local pending = self._pendingRobuxTargets[player.UserId]
		if not pending then
			return false, "ERR_NO_TARGET", "Pick a target in the Pirate Broker dialog first."
		end
		if (os.clock() - pending.stampedAt) > _PENDING_ROBUX_TARGET_TTL_SECONDS then
			self._pendingRobuxTargets[player.UserId] = nil
			return false, "ERR_TARGET_STALE", "That target selection expired — pick again."
		end
		-- Same `skipCooldown` rule as `_handlePromptHireRobux`: Robux purchases
		-- never gate on the same-target cooldown. The other validations still
		-- run (self-hire, target online, no active contract).
		local ok, message = self:_validateHireTarget(player.UserId, pending.victimUserId, { skipCooldown = true })
		if not ok then
			-- Leave the stamp in place so the player can re-prompt after the
			-- transient condition clears (e.g. target rejoining) without
			-- having to re-click the target row.
			return false, "ERR_PIRATE_HIRE_BLOCKED", message
		end
		return true, nil, nil
	end)

	-- Receipt handler. Always resolves to a grant attempt — the prompt gate
	-- above already ran before Roblox charged the player. If the pending
	-- target evaporated between prompt and receipt (target left, etc.) we
	-- still return `true` from the handler so Roblox finalizes the receipt
	-- and the player isn't double-prompted on next session; `TryCreateHit`'s
	-- internal validation will also return false in that case and we report
	-- it via `_fireResult` so the player sees what happened.
	monetizationService:SetConsumableHandler("pirate_hire", function(userId: number, _quantity: number): (boolean, string?)
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			-- Buyer left between prompt and receipt — Roblox auto-handles
			-- via NotProcessedYet on next session.
			return false, "ERR_PIRATE_HIRE_BUYER_OFFLINE"
		end
		local pending = self._pendingRobuxTargets[userId]
		self._pendingRobuxTargets[userId] = nil
		if not pending then
			self:_fireResult(player, false, "Couldn't find the target you picked. Try again.", nil)
			return true, nil
		end
		-- `paymentMethod = "robux"` skips the cash debit branch in
		-- `TryCreateHit`. We run it inline (not inside `task.spawn`) because
		-- the work is bounded and we want to surface the result to the
		-- player on the same `MonetizationResult` toast pipeline; if any
		-- step yields, ProcessReceipt's outer pcall handles it.
		local ok, message, data = self:TryCreateHit(userId, pending.victimUserId, { paymentMethod = "robux" })
		self:_fireResult(player, ok, message, data)
		return true, nil
	end)
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
		self._pendingRobuxTargets[userId] = nil
		local keysToClear = {}
		for key, _ in pairs(self._hireCooldownEndsAtByPair) do
			local leftStr, rightStr = string.match(key, "^(%d+):(%d+)$")
			local left = leftStr and tonumber(leftStr)
			local right = rightStr and tonumber(rightStr)
			if left == userId or right == userId then
				table.insert(keysToClear, key)
			end
		end
		for _, key in ipairs(keysToClear) do
			self._hireCooldownEndsAtByPair[key] = nil
		end
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
	self._hireCooldownEndsAtByPair = {}
	self._freeHitTokens = {}
	self._pendingRobuxTargets = {}
end

return HitContractService
