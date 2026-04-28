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
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local ArmyGeneralService = {}

local AIRSTRIKE_COST = StraitEventCatalog.AirStrikeConfig.Cost
local AIRSTRIKE_SAME_TARGET_COOLDOWN = StraitEventCatalog.AirStrikeConfig.SameTargetCooldownSeconds or 120
local NUKE_COOLDOWN = StraitEventCatalog.NukeConfig.CooldownSeconds

--- Build the canonical key for a (contractor, victim) airstrike pair so we
--- can dedupe cooldown stamps regardless of which order the userIds were
--- collected. Mirrors `HitContractService._pairCooldownKey`.
local function _airstrikePairKey(contractorUserId: number, victimUserId: number): string
	return tostring(contractorUserId) .. ":" .. tostring(victimUserId)
end

function ArmyGeneralService:Init(remoteService, oilStateService, oilShipmentService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._oilShipmentService = oilShipmentService
	-- `_monetizationService` is wired by `init.server.luau:SetMonetizationService` after both
	-- services exist. Until then nuke purchases route through the Studio-only debug path.
	self._monetizationService = nil
	self._connections = {}
	self._lastNukeTime = 0
	self._hookedPrompts = {}
	--- Models we attached `DescendantAdded` to so we retry when rig parts stream in.
	self._armyGeneralStreamingHooked = {} :: { [Model]: boolean }
	--- Per-contractor "what target did they just click Robux-airstrike on?" stamp.
	--- Same role as `HitContractService._pendingRobuxTargets`: the consumable
	--- handler signature only carries `(userId, quantity)`, so the intended
	--- victim has to be threaded through this side-channel staged at prompt
	--- time and cleared when the receipt lands or expires.
	self._pendingRobuxAirstrikeTargets = {} :: { [number]: { victimUserId: number, stampedAt: number } }
	--- Per-(contractor, victim) cooldown for **cash** airstrikes. Mirrors
	--- `HitContractService._hireCooldownEndsAtByPair` exactly: stamped after
	--- a successful cash airstrike, checked before the next one. Robux
	--- airstrikes neither check nor stamp — the Robux purchase is the
	--- "skip the cooldown" feature by design.
	self._airstrikeCooldownEndsAtByPair = {} :: { [string]: number }
end

function ArmyGeneralService:_airstrikeCooldownRemainingSeconds(contractorUserId: number, victimUserId: number): number
	local endsAt = self._airstrikeCooldownEndsAtByPair[_airstrikePairKey(contractorUserId, victimUserId)]
	if not endsAt then
		return 0
	end
	local rem = endsAt - workspace:GetServerTimeNow()
	return if rem > 0 then math.ceil(rem) else 0
end

function ArmyGeneralService:_stampAirstrikeCooldown(contractorUserId: number, victimUserId: number)
	self._airstrikeCooldownEndsAtByPair[_airstrikePairKey(contractorUserId, victimUserId)] =
		workspace:GetServerTimeNow() + AIRSTRIKE_SAME_TARGET_COOLDOWN
end

--- TTL for `_pendingRobuxAirstrikeTargets` entries. Same value + reasoning as
--- `HitContractService._PENDING_ROBUX_TARGET_TTL_SECONDS` (90s) — long
--- enough to cover the Roblox prompt being closed and reopened, short
--- enough that a stamp can't bleed into a much-later receipt.
local _PENDING_ROBUX_AIRSTRIKE_TTL_SECONDS = 90

--- Inject `MonetizationService` from `init.server.luau` and register both
--- the pre-prompt cooldown gate AND the `"nuke"` consumable receipt
--- handler.
---
--- Why split: previously the cooldown was checked at receipt time, which
--- meant a stale client snapshot (or a same-window second buyer) could
--- pay Robux only to have the receipt return `NotProcessedYet` — the
--- player saw nothing happen. The cooldown is now enforced via
--- `SetPromptPrecondition`, BEFORE `MarketplaceService:PromptProductPurchase`
--- runs, so the player gets an "on cooldown" toast and Roblox is never
--- asked to charge them. The receipt handler always grants — once the
--- prompt opened, the player paid, the nuke MUST fire.
function ArmyGeneralService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end

	-- Pre-prompt cooldown gate: the dialog won't open if a nuke is on
	-- cooldown, so the player can't be charged for one they can't have.
	monetizationService:SetPromptPrecondition("consumable.nuke_x1", function(_player: Player)
		local now = workspace:GetServerTimeNow()
		local elapsed = now - self._lastNukeTime
		if elapsed < NUKE_COOLDOWN then
			local remaining = math.ceil(NUKE_COOLDOWN - elapsed)
			return false, "ERR_NUKE_COOLDOWN", string.format("Nuke is on cooldown for %ds.", remaining)
		end
		return true, nil, nil
	end)

	-- Receipt handler: always grants (the cooldown gate above already ran
	-- before the prompt opened). The only failure modes left are "buyer
	-- left between prompt and receipt" — which Roblox auto-refunds on
	-- the next session via `NotProcessedYet`.
	monetizationService:SetConsumableHandler("nuke", function(userId: number, _quantity: number): (boolean, string?)
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			return false, "ERR_NUKE_BUYER_OFFLINE"
		end
		-- Stamp the cooldown synchronously. `_executeNuke` re-stamps at its
		-- top (same value, harmless) but reserving here means a Roblox-side
		-- replay of the same receipt won't sneak past the prompt gate.
		self._lastNukeTime = workspace:GetServerTimeNow()
		-- The actual nuke runs `task.wait(NukeConfig.CountdownSeconds)` and
		-- must NOT block the `ProcessReceipt` callback. Spawn it so the
		-- receipt returns `PurchaseGranted` immediately and Roblox finalises
		-- the Robux charge while the countdown plays.
		task.spawn(function()
			self:_executeNuke(player)
		end)
		return true, nil
	end)

	-- =================== AIRSTRIKE — Robux variant ===================
	-- Mirrors `HitContractService:SetMonetizationService` for `pirate_hire`:
	-- the per-target intent is staged on `_pendingRobuxAirstrikeTargets` by
	-- the `promptAirstrikeRobux` action below, the precondition re-validates
	-- the target before Roblox is asked to charge, and the receipt handler
	-- runs `_handleAirstrike` with `paymentMethod = "robux"` so the cash
	-- spend / refund branches are skipped.
	monetizationService:SetPromptPrecondition("consumable.airstrike_x1", function(player: Player)
		local pending = self._pendingRobuxAirstrikeTargets[player.UserId]
		if not pending then
			return false, "ERR_NO_TARGET", "Pick a target in the Army General dialog first."
		end
		if (os.clock() - pending.stampedAt) > _PENDING_ROBUX_AIRSTRIKE_TTL_SECONDS then
			self._pendingRobuxAirstrikeTargets[player.UserId] = nil
			return false, "ERR_TARGET_STALE", "That target selection expired — pick again."
		end
		if pending.victimUserId == player.UserId then
			return false, "ERR_AIRSTRIKE_SELF", "Can't airstrike yourself."
		end
		if not self._oilShipmentService:HasActiveShipment(pending.victimUserId) then
			return false, "ERR_AIRSTRIKE_NO_SHIPMENT", "Target has no active shipment."
		end
		return true, nil, nil
	end)

	monetizationService:SetConsumableHandler("airstrike", function(userId: number, _quantity: number): (boolean, string?)
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			return false, "ERR_AIRSTRIKE_BUYER_OFFLINE"
		end
		local pending = self._pendingRobuxAirstrikeTargets[userId]
		self._pendingRobuxAirstrikeTargets[userId] = nil
		if not pending then
			-- Stale receipt or pending stamp evaporated — surface to the
			-- player but mark the receipt granted so Roblox stops retrying.
			local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)
			resultEvent:FireClient(player, {
				ok = false,
				message = "Couldn't find the target you picked. Try again.",
			})
			return true, nil
		end
		-- The airstrike's jet animation runs synchronously inside
		-- `_handleAirstrike` (no `task.wait`), but `airStrikeEvent:FireAllClients`
		-- is the only side effect that takes time and that's a non-yielding
		-- Roblox API call. Run inline so the result toast lands on the same
		-- player session.
		task.spawn(function()
			self:_handleAirstrike(player, { victimUserId = pending.victimUserId }, { paymentMethod = "robux" })
		end)
		return true, nil
	end)
end

--- Stamp `_pendingRobuxAirstrikeTargets[contractorUserId]` and open the
--- Robux purchase prompt for `consumable.airstrike_x1`. Wired from the
--- existing `RequestArmyGeneralAction` remote when the client clicks the
--- per-target Robux button (`action = "promptAirstrikeRobux"`). The actual
--- airstrike executes inside the consumable handler once the receipt
--- lands.
function ArmyGeneralService:_handlePromptAirstrikeRobux(player: Player, payload)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)
	if not self._monetizationService then
		resultEvent:FireClient(player, { ok = false, message = "Robux purchases not available." })
		return
	end
	local victimUserId = tonumber(payload.victimUserId)
	if not victimUserId then
		resultEvent:FireClient(player, { ok = false, message = "Invalid target." })
		return
	end
	if victimUserId == player.UserId then
		resultEvent:FireClient(player, { ok = false, message = "Can't airstrike yourself." })
		return
	end
	if not self._oilShipmentService:HasActiveShipment(victimUserId) then
		resultEvent:FireClient(player, { ok = false, message = "Target has no active shipment." })
		return
	end
	self._pendingRobuxAirstrikeTargets[player.UserId] = {
		victimUserId = victimUserId,
		stampedAt = os.clock(),
	}
	-- Routes through `MonetizationService:_handlePromptRequest`, which runs
	-- the registered `consumable.airstrike_x1` precondition (defense in
	-- depth) and then opens `MarketplaceService:PromptProductPurchase`.
	-- Result/error toast lands on the client via `MonetizationResult`.
	self._monetizationService:PromptPurchase(player, "consumable.airstrike_x1")
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
		elseif action == "promptAirstrikeRobux" then
			-- Stage the per-target intent on `_pendingRobuxAirstrikeTargets`
			-- and open the Roblox prompt; the actual airstrike runs in the
			-- consumable handler registered in `SetMonetizationService`.
			self:_handlePromptAirstrikeRobux(player, payload)
		end
	end))

	-- Drop pending Robux-airstrike stamps + same-target cooldown stamps on
	-- player leave so a stale entry can't bleed into a future receipt for
	-- the same user (server kept running, player rejoined as a new
	-- character but with the same UserId).
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self._pendingRobuxAirstrikeTargets[player.UserId] = nil
		local userId = player.UserId
		local toClear = {}
		for key, _ in pairs(self._airstrikeCooldownEndsAtByPair) do
			local leftStr, rightStr = string.match(key, "^(%d+):(%d+)$")
			local left = leftStr and tonumber(leftStr)
			local right = rightStr and tonumber(rightStr)
			if left == userId or right == userId then
				table.insert(toClear, key)
			end
		end
		for _, key in ipairs(toClear) do
			self._airstrikeCooldownEndsAtByPair[key] = nil
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
	self._hookedPrompts = {}
	self._armyGeneralStreamingHooked = {}
	self._pendingRobuxAirstrikeTargets = {}
	self._airstrikeCooldownEndsAtByPair = {}
end

-- =================== NPC PROMPT ===================

function ArmyGeneralService:_hookArmyGeneral()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "Army General" and d:IsA("Model") and not self._hookedPrompts[d] then
			-- Find a part to attach prompt to
			local attachPart = d:FindFirstChild("HumanoidRootPart")
				or d:FindFirstChild("UpperTorso")
				or d:FindFirstChild("Torso")
				or d:FindFirstChild("Head")
				or d:FindFirstChildWhichIsA("BasePart")
			if not attachPart then
				-- Was: marked hooked before this check — rig never got a prompt. Retry when parts stream.
				if not self._armyGeneralStreamingHooked[d] then
					self._armyGeneralStreamingHooked[d] = true
					table.insert(self._connections, d.DescendantAdded:Connect(function()
						task.defer(function()
							self:_hookArmyGeneral()
						end)
					end))
				end
				continue
			end

			self._hookedPrompts[d] = true

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
			prompt.MaxActivationDistance = 20
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
				-- Same-target cooldown remaining for the *cash* airstrike
				-- path. Robux airstrikes ignore this — the client uses the
				-- field to disable the cash row's per-target click + paint
				-- a countdown but leaves the Robux row clickable.
				airstrikeCooldownRemainingSeconds = self:_airstrikeCooldownRemainingSeconds(requestingPlayer.UserId, player.UserId),
			})
		end
	end
	return {
		targets = targets,
		airstrikeCost = AIRSTRIKE_COST,
		airstrikeCooldownSeconds = AIRSTRIKE_SAME_TARGET_COOLDOWN,
	}
end

-- =================== NUKE ===================

--- Legacy direct-action path. Production buyers go through the
--- `MonetizationService` consumable handler (`SetMonetizationService`); this
--- one is kept as a Studio-only debug shortcut so designers can test the nuke
--- without spending Robux. In live servers it surfaces a "Nuke purchase not
--- yet available" toast — clients should be calling `RequestPromptRobuxPurchase`
--- with `consumable.nuke_x1` instead.
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

	if not RunService:IsStudio() then
		resultEvent:FireClient(player, {
			ok = false,
			message = "Nuke must be purchased via Robux.",
		})
		return
	end

	self:_executeNuke(player)
end

--- Actual nuke execution: marks cooldown, fires countdown to all clients,
--- waits, then destroys every active shipment. Shared between the Robux
--- receipt handler (`SetMonetizationService`) and the Studio debug path
--- (`_handleNuke`). Caller is responsible for the cooldown check; this
--- function unconditionally fires.
function ArmyGeneralService:_executeNuke(player: Player)
	local now = workspace:GetServerTimeNow()
	self._lastNukeTime = now

	local countdownEvent = self._remoteService:GetEvent(RemoteNames.NukeCountdownEvent)
	local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)
	local cfg = StraitEventCatalog.NukeConfig
	countdownEvent:FireAllClients({
		detonateAt = now + cfg.CountdownSeconds,
		launchedBy = player.Name,
	})

	DevLog.log(string.format("[ArmyGeneralService] NUKE launched by %s! Detonating in %ds", player.Name, cfg.CountdownSeconds))

	task.wait(cfg.CountdownSeconds)

	local detonateEvent = self._remoteService:GetEvent(RemoteNames.NukeDetonateEvent)

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

	self._oilShipmentService._nukeActive = true
	for _, info in ipairs(shipmentPositions) do
		self._oilShipmentService:ForceDestroyShipment(info.shipmentId, "Nuclear strike")
	end

	-- Telemetry §6.5 `nuke_fired`. Fires after detonation FX broadcast
	-- + ship destruction so analytics records actual blast impact, not
	-- the click that may still bail (cooldown gate already covered above).
	pcall(function()
		Telemetry.Track(player, "nuke_fired", {
			affectedShipments = #shipmentPositions,
			cooldownSeconds = NUKE_COOLDOWN,
		})
	end)
	task.delay(10, function()
		self._oilShipmentService._nukeActive = false
	end)

	if player.Parent then
		resultEvent:FireClient(player, {
			ok = true,
			message = string.format("NUKE DETONATED! %d boats destroyed.", #shipmentPositions),
		})
	end
end

-- =================== AIRSTRIKE ===================

--- `opts.paymentMethod`:
---   * `"cash"` (default) — debit `AIRSTRIKE_COST` via `OilStateService:TrySpendCash`
---     and refund on every "target became invalid mid-flight" branch below.
---   * `"robux"` — receipt handler in `SetMonetizationService` already paid
---     the player in Robux. Skip the cash spend AND skip every refund
---     branch (there's nothing to refund — the Robux purchase is final at
---     `ProcessReceipt`). If the airstrike can't fire (target left, etc.)
---     the player gets the same error toast but no cash motion. This is
---     a deliberate trade-off: we accept that a stale-target Robux
---     airstrike "wastes" the purchase rather than trying to refund Robux
---     (which Roblox doesn't expose a clean API for and would force a
---     receipt failure → retry storm).
function ArmyGeneralService:_handleAirstrike(player: Player, payload, opts: { paymentMethod: string? }?)
	local paymentMethod = (opts and opts.paymentMethod) or "cash"
	local resultEvent = self._remoteService:GetEvent(RemoteNames.ArmyGeneralResult)

	-- Refund helper: only debits a cash refund on the cash path. The Robux
	-- path is no-op so a "target invalid" branch doesn't accidentally pay
	-- the player back in cash for a Robux purchase.
	local function refundIfCash()
		if paymentMethod == "cash" then
			self._oilStateService:AddCash(player.UserId, AIRSTRIKE_COST, { skipMultiplier = true })
			self._oilStateService:PushState(player.UserId)
		end
	end

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

	-- Same-target cooldown — cash path only. Robux purchases bypass this
	-- gate entirely (paying Robux is the "skip cooldowns" feature, per
	-- the dialog's flavor text). Mirrors `HitContractService`.
	if paymentMethod == "cash" then
		local cdRem = self:_airstrikeCooldownRemainingSeconds(player.UserId, victimUserId)
		if cdRem > 0 then
			local m = math.floor(cdRem / 60)
			local s = cdRem % 60
			resultEvent:FireClient(player, {
				ok = false,
				message = string.format("Wait %d:%02d before airstriking that player again.", m, s),
			})
			return
		end
	end

	-- Charge cash (only on cash path; Robux path already paid via receipt).
	if paymentMethod == "cash" then
		if not self._oilStateService:TrySpendCash(player.UserId, AIRSTRIKE_COST) then
			resultEvent:FireClient(player, {
				ok = false,
				message = string.format("Not enough cash. Need $%d.", AIRSTRIKE_COST),
			})
			return
		end
		self._oilStateService:PushState(player.UserId)
	end

	-- Get victim's boat position
	local victimShipment = self._oilShipmentService:GetActiveShipmentForUser(victimUserId)
	if not victimShipment then
		refundIfCash()
		resultEvent:FireClient(player, { ok = false, message = "Target's shipment ended." })
		return
	end

	local boat = self._oilShipmentService:GetActiveBoat(victimShipment.shipmentId)
	if not boat then
		refundIfCash()
		resultEvent:FireClient(player, { ok = false, message = "Target boat not found." })
		return
	end

	local root = boat:IsA("Model") and boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
	if not root then
		refundIfCash()
		resultEvent:FireClient(player, { ok = false, message = "Target boat error." })
		return
	end

	-- Security Personnel immunity: if the victim's shipment has eventImmunity,
	-- the airstrike is deflected. Refund the attacker (cash path only).
	if (victimShipment :: any).eventImmunity == true then
		refundIfCash()
		local message: string
		if paymentMethod == "cash" then
			message = "Target has Security Personnel — airstrike deflected! Cash refunded."
		else
			message = "Target has Security Personnel — airstrike deflected!"
		end
		resultEvent:FireClient(player, { ok = false, message = message })
		return
	end

	-- Cash airstrike committed — every refund branch above has already
	-- returned, so we know the cash path is going through. Stamp the
	-- per-target cooldown so the next cash airstrike on this victim
	-- waits the configured window. Robux skips: the user's design is
	-- "Robux has no cooldowns", so neither check nor stamp on this path.
	if paymentMethod == "cash" then
		self:_stampAirstrikeCooldown(player.UserId, victimUserId)
	end

	-- General airstrike = GUARANTEED HIT (instakill).
	--- The branches below (log line, post-animation `if hit then ForceDestroyShipment`)
	--- read a local `hit`. Without this it was nil → falsy → ship was never actually
	--- destroyed and the victim's client got `outcome="hit"` (which hides the local
	--- character via `Transparency = 1`) while the server kept them alive. End result:
	--- "invisible alive player on a still-intact boat" until they slipped off and hit
	--- the under-map kill plane.
	local hit = true
	local cfg = StraitEventCatalog.AirStrikeConfig
	local rng = Random.new()

	-- Calculate jet flight path over the boat
	local boatPos = root.Position
	local jetAlt = cfg.JetAltitude
	local jetDir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit
	local jetStart = boatPos + jetDir * 600 + Vector3.new(0, jetAlt, 0)
	local jetEnd = boatPos - jetDir * 600 + Vector3.new(0, jetAlt, 0)

	local victimPlayer = Players:GetPlayerByUserId(victimUserId)

	-- Telemetry §6.5 `airstrike_fired` (Sink). Fires after `TrySpendCash`
	-- success (or the Robux receipt) and the early-return refund branches
	-- above (so refunds for "shipment ended / boat not found / boat error"
	-- do NOT show up as a fired airstrike). `outcome` is fixed to "hit" —
	-- General airstrikes guarantee a hit. The cash-Sink fires only on the
	-- cash path; the Robux path is reported by `MonetizationService` via
	-- `Telemetry.Purchase` so we don't double-count revenue.
	pcall(function()
		if paymentMethod == "cash" then
			Telemetry.Economy(player, "Sink", AIRSTRIKE_COST, "cash", "airstrike", { kind = "airstrike", id = "general" })
		end
		Telemetry.Track(player, "airstrike_fired", {
			victimUserId = victimUserId,
			cost = if paymentMethod == "cash" then AIRSTRIKE_COST else 0,
			outcome = "hit",
			paymentMethod = paymentMethod,
		})
	end)

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
	self:_executeNuke(player)
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
