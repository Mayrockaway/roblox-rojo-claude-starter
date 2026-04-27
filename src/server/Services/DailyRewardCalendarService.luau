--!strict
-- Server-authoritative 7-day daily reward calendar (`StarterGui.Daily` panel).
--
-- Wire model:
--   * Persistence + getters live on `OilStateService` (dailyRewardClaimedCount,
--     dailyRewardLastClaimAt). This service is stateless beyond service-injection
--     refs — every claim reads/writes through the canonical state.
--   * Cooldown + per-slot grant rules live in `DailyRewardCalendarConfig`.
--   * Client renders state from `DailyRewardUpdate` snapshots; server pushes
--     once on join and again after every successful claim.
--
-- Non-goals here:
--   * No ChunkAdded / death-respawn coupling — daily rewards are independent
--     of FTUE / plot lifecycle.
--   * No deterministic rolling — each slot's reward is fixed in
--     `DailyRewardCalendarConfig.Rewards` (unlike `DailyDrillConfig`, which
--     rolls a random drill per UTC cycle).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DailyRewardCalendarConfig = require(Shared:WaitForChild("Config"):WaitForChild("DailyRewardCalendarConfig"))
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))

local DailyRewardCalendarService = {}

function DailyRewardCalendarService:Init(
	remoteService: any,
	oilStateService: any,
	equipmentShopService: any
)
	self._remoteService = remoteService
	self._oilState = oilStateService
	self._equipmentShop = equipmentShopService
	self._connections = {} :: { RBXScriptConnection }
	self._running = false
end

--- Build the snapshot that goes over `DailyRewardUpdate`. Pure function of
--- the player's persisted state + the config — no side effects, safe to
--- call from anywhere.
---
--- `slot2BoatId` / `slot2BoatIcon` carry the rolled hull for the random-
--- boat reward (Slot 2). They are `nil` until the player claims slot 2, at
--- which point the server stamps both fields on every subsequent push so a
--- panel re-open after rejoin still paints the rolled hull's icon.
local function buildSnapshot(claimedCount: number, lastClaimAt: number?, slot2BoatId: string?)
	local total = DailyRewardCalendarConfig.TotalRewards
	local secondsUntilNext: number
	if claimedCount >= total then
		--- All claimed — no next slot, no countdown. Future "wrap" / reset
		--- behavior is intentionally TBD; for now the panel will paint every
		--- slot as Claimed and the Claim button stays disabled.
		secondsUntilNext = 0
	else
		secondsUntilNext = DailyRewardCalendarConfig.SecondsUntilNext(lastClaimAt)
	end
	local slot2BoatIcon: string? = nil
	if typeof(slot2BoatId) == "string" and slot2BoatId ~= "" then
		local entry = BoatCatalog.Boats and BoatCatalog.Boats[slot2BoatId]
		if entry and typeof(entry.icon) == "string" and entry.icon ~= "" then
			slot2BoatIcon = entry.icon
		end
	end
	return {
		claimedCount = math.max(0, math.min(total, claimedCount)),
		secondsUntilNext = secondsUntilNext,
		totalRewards = total,
		cooldownSeconds = DailyRewardCalendarConfig.CooldownSeconds,
		slot2BoatId = slot2BoatId,
		slot2BoatIcon = slot2BoatIcon,
	}
end

function DailyRewardCalendarService:_pushState(player: Player)
	if not self._updateRemote then
		return
	end
	local count, lastAt = self._oilState:GetDailyRewardProgress(player.UserId)
	local slot2BoatId = self._oilState:GetDailyRewardSlot2BoatId(player.UserId)
	self._updateRemote:FireClient(player, buildSnapshot(count, lastAt, slot2BoatId))
end

--- Dispatch the actual reward grant. Each branch is a thin shim over the
--- canonical grant path on the corresponding service so this service does
--- not become a parallel grant ledger. Unknown / unwired kinds log a TODO
--- and return success — the player still progresses through the calendar
--- so the flow is testable end-to-end while gameplay-side rewards are
--- being wired.
function DailyRewardCalendarService:_grantReward(player: Player, reward: any): (boolean, string)
	local kind = (reward and reward.kind) or "noop"
	local payload = (reward and reward.payload) or {}
	local userId = player.UserId

	if kind == "cash" then
		local amount = tonumber(payload.amount or 0) or 0
		if amount <= 0 then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): cash reward has non-positive amount=%s — granting nothing",
				reward.id or "?", player.Name, tostring(payload.amount)
			))
			return true, "OK_NO_OP"
		end
		local ok = self._oilState:AddCash(userId, amount, { skipMultiplier = true })
		if ok then
			self._oilState:PushState(userId)
			return true, "OK"
		end
		return false, "ERR_ADD_CASH_FAILED"

	elseif kind == "boat" then
		local boatId = payload.boatId
		if typeof(boatId) ~= "string" or boatId == "" then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): boat reward has no boatId — TODO: wire BoatCatalog id, granting nothing",
				reward.id or "?", player.Name
			))
			return true, "OK_TODO_BOAT_ID"
		end
		if not BoatCatalog.IsBoatPurchasable(boatId) then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): boat reward boatId=%q not in BoatCatalog — granting nothing",
				reward.id or "?", player.Name, boatId
			))
			return true, "OK_BAD_BOAT_ID"
		end
		local granted, code = self._oilState:GrantBoat(userId, boatId)
		if granted or code == "OK_ALREADY_OWNED" then
			self._oilState:PushState(userId)
			return true, code or "OK"
		end
		return false, code or "ERR_GRANT_BOAT"

	elseif kind == "boatPool" then
		--- Random-boat slot. Pick uniformly from the named pool, persist
		--- the rolled `boatId` so the panel can swap the slot's icon to
		--- the actual hull on every future open (the icon swap doubles
		--- as the "this is what you got" reveal — no popup needed).
		---
		--- Duplicate guard: filter the pool to boats the player does NOT
		--- already own before rolling, so a long-tenured player still gets
		--- a guaranteed-new hull as long as any pool entry is unowned. If
		--- they own EVERY boat in the pool, fall back to a cash payout
		--- (`BOAT_POOL_CASH_FALLBACK`) so the slot doesn't degrade into a
		--- cosmetic-only reward. The slot's icon stays as the previously-
		--- rolled boat (or unset) in that case — no rolled id is written
		--- on the cash fallback so a future re-claim with new boats unlocked
		--- can still surface a fresh hull cleanly.
		---
		--- Persistence note: the rolled id is stored on a slot-specific
		--- field (`dailyRewardSlot2BoatId`) because today only slot 2 is a
		--- `boatPool` reward. If a future slot also becomes `boatPool`,
		--- generalize to a `{ [slotIndex] = boatId }` map on
		--- `OilStateService` rather than adding `dailyRewardSlotNBoatId`
		--- one-by-one.
		local poolKey = payload.poolKey
		if typeof(poolKey) ~= "string" or poolKey == "" then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): boatPool reward has no poolKey — granting nothing",
				reward.id or "?", player.Name
			))
			return true, "OK_BAD_POOL_KEY"
		end
		local pool = DailyRewardCalendarConfig.BoatPools and DailyRewardCalendarConfig.BoatPools[poolKey]
		if typeof(pool) ~= "table" or #pool == 0 then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): boatPool poolKey=%q is empty/missing",
				reward.id or "?", player.Name, poolKey
			))
			return true, "OK_EMPTY_POOL"
		end
		--- Filter: only consider pool entries the player doesn't already own
		--- AND that are still purchasable in the catalog (defends against
		--- a pool entry being deprecated mid-season without breaking the
		--- claim flow). Built as a flat array so `math.random(1, #unowned)`
		--- is a clean uniform pick.
		local unowned: { string } = {}
		for _, boatId in ipairs(pool) do
			if BoatCatalog.IsBoatPurchasable(boatId) and not self._oilState:OwnsBoat(userId, boatId) then
				table.insert(unowned, boatId)
			end
		end

		if #unowned == 0 then
			--- All pool boats already owned — cash consolation. Roughly
			--- mid-pool unlock-cost (T2 $1k, T3 $5k, T4 $15k, T5 $50k →
			--- average ≈ $17.7k); $25k is intentionally a touch above the
			--- average so the duplicate fallback feels rewarding rather
			--- than a downgrade. `skipMultiplier = true` keeps it as a
			--- gift (DoubleEarnings / cash buffs don't double-dip).
			local fallbackAmount = 25000
			local cashOk = self._oilState:AddCash(userId, fallbackAmount, { skipMultiplier = true })
			if not cashOk then
				return false, "ERR_ADD_CASH_FAILED"
			end
			--- Do NOT touch `dailyRewardSlot2BoatId` here — leave any prior
			--- rolled id intact so the panel keeps showing the last hull
			--- the player actually unlocked from this slot (rather than
			--- blanking to the placeholder).
			self._oilState:PushState(userId)
			if RunService:IsStudio() then
				print(string.format(
					"[DailyRewardCalendar] %s rolled boatPool %q with all owned -> cash fallback $%d",
					player.Name, poolKey, fallbackAmount
				))
			end
			return true, "OK_CASH_FALLBACK"
		end

		local rolled = unowned[math.random(1, #unowned)]
		local granted, code = self._oilState:GrantBoat(userId, rolled)
		--- Stamp the rolled id on the player's profile so the panel icon
		--- swaps to the rolled hull on every subsequent open. We only get
		--- here when the boat was unowned, so `OK_ALREADY_OWNED` should
		--- not fire — but treat it as success defensively.
		self._oilState:SetDailyRewardSlot2BoatId(userId, rolled)
		if granted or code == "OK_ALREADY_OWNED" then
			self._oilState:PushState(userId)
			return true, code or "OK"
		end
		return false, code or "ERR_GRANT_BOAT"

	elseif kind == "equipment" then
		local itemId = payload.itemId
		local qty = tonumber(payload.qty or 1) or 1
		if typeof(itemId) ~= "string" or itemId == "" or qty < 1 then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): equipment reward bad payload (itemId=%s, qty=%s) — granting nothing",
				reward.id or "?", player.Name, tostring(itemId), tostring(qty)
			))
			return true, "OK_BAD_EQUIPMENT_PAYLOAD"
		end
		if not (self._equipmentShop and typeof(self._equipmentShop.GrantFreeOwnedEquipment) == "function") then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): EquipmentShopService unavailable — cannot grant %dx %s",
				reward.id or "?", player.Name, qty, itemId
			))
			return false, "ERR_NO_EQUIPMENT_SHOP"
		end
		self._equipmentShop:GrantFreeOwnedEquipment(player, itemId, math.floor(qty))
		--- `GrantFreeOwnedEquipment` already pushes state internally, so no
		--- explicit `PushState` here.
		return true, "OK"

	elseif kind == "runUpgrade" then
		local itemId = payload.itemId
		local qty = tonumber(payload.qty or 1) or 1
		if typeof(itemId) ~= "string" or itemId == "" or qty < 1 then
			warn(string.format(
				"[DailyRewardCalendar] %s (%s): runUpgrade reward bad payload (itemId=%s, qty=%s) — granting nothing",
				reward.id or "?", player.Name, tostring(itemId), tostring(qty)
			))
			return true, "OK_BAD_RUN_UPGRADE_PAYLOAD"
		end
		self._oilState:AddRunUpgradeOwned(userId, itemId, math.floor(qty))
		self._oilState:PushState(userId)
		return true, "OK"
	end

	--- "noop" or unknown kind: explicit no-grant slot.
	return true, "OK_NOOP"
end

--- Validate + grant the next claimable reward. Called from the client's
--- `RequestClaimDailyReward` fire. Server is authoritative — the client
--- payload is intentionally empty (no slot index argument), the server
--- always grants `claimedCount + 1`.
function DailyRewardCalendarService:_handleClaim(player: Player)
	if not self._running then
		return
	end
	local userId = player.UserId
	local resultEvent = self._remoteService:GetEvent(RemoteNames.OilActionResult)

	local count, lastAt = self._oilState:GetDailyRewardProgress(userId)
	local total = DailyRewardCalendarConfig.TotalRewards

	if count >= total then
		resultEvent:FireClient(player, {
			action = "ClaimDailyReward",
			ok = false,
			code = "ERR_ALL_CLAIMED",
			message = "You've claimed every daily reward!",
		})
		return
	end

	local secondsUntilNext = DailyRewardCalendarConfig.SecondsUntilNext(lastAt)
	if secondsUntilNext > 0 then
		resultEvent:FireClient(player, {
			action = "ClaimDailyReward",
			ok = false,
			code = "ERR_COOLDOWN",
			message = "Reward not available yet.",
			data = { secondsUntilNext = secondsUntilNext },
		})
		--- Re-push state so a tampered client can't silently desync — the
		--- snapshot here is fresh, which keeps the panel honest.
		self:_pushState(player)
		return
	end

	local nextIndex = count + 1
	local reward = DailyRewardCalendarConfig.Rewards[nextIndex]
	if not reward then
		warn(string.format(
			"[DailyRewardCalendar] %s claim aborted: no reward at index %d (config has %d entries)",
			player.Name, nextIndex, total
		))
		resultEvent:FireClient(player, {
			action = "ClaimDailyReward",
			ok = false,
			code = "ERR_BAD_INDEX",
			message = "Reward configuration error.",
		})
		return
	end

	local ok, code = self:_grantReward(player, reward)
	if not ok then
		warn(string.format(
			"[DailyRewardCalendar] %s claim grant failed at index %d (id=%s, code=%s)",
			player.Name, nextIndex, tostring(reward.id), tostring(code)
		))
		resultEvent:FireClient(player, {
			action = "ClaimDailyReward",
			ok = false,
			code = code or "ERR_GRANT",
			message = "Failed to grant reward.",
		})
		return
	end

	--- Advance state. Use `os.time()` for the persisted timestamp (server-side
	--- wall clock); the client receives `secondsUntilNext` from the upcoming
	--- push and ticks locally, so client clock skew never enters the gating.
	local now = os.time()
	self._oilState:SetDailyRewardProgress(userId, nextIndex, now)

	resultEvent:FireClient(player, {
		action = "ClaimDailyReward",
		ok = true,
		code = "OK",
		message = "Daily reward claimed!",
		data = { rewardIndex = nextIndex, rewardId = reward.id, grantCode = code },
	})

	self:_pushState(player)

	if RunService:IsStudio() then
		print(string.format(
			"[DailyRewardCalendar] %s claimed slot %d (id=%s, kind=%s, code=%s)",
			player.Name, nextIndex, tostring(reward.id), tostring(reward.kind), tostring(code)
		))
	end
end

function DailyRewardCalendarService:Start()
	if self._running then
		return
	end
	self._running = true

	local claimRemote = self._remoteService:GetEvent(RemoteNames.RequestClaimDailyReward)
	local updateRemote = self._remoteService:GetEvent(RemoteNames.DailyRewardUpdate)
	self._claimRemote = claimRemote
	self._updateRemote = updateRemote

	table.insert(self._connections, claimRemote.OnServerEvent:Connect(function(player: Player)
		self:_handleClaim(player)
	end))

	--- Push initial state to every joiner. The defer mirrors `EquipmentShopService:_startDailyDrill`:
	--- we want `OilStateService` to have finished `_applyPersistedIntoState`
	--- before we read `GetDailyRewardProgress`, so we wait briefly. The state
	--- is also re-pushed automatically after every claim, so any fresh
	--- player whose initial push raced the load will resync on first action.
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player: Player)
		task.defer(function()
			task.wait(3)
			if not player.Parent then
				return
			end
			self:_pushState(player)
		end)
	end))

	--- Cover players already in the server when the service starts (single-
	--- player Studio playtest, hot-reload during dev, etc.).
	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			if not player.Parent then
				return
			end
			self:_pushState(player)
		end)
	end
end

function DailyRewardCalendarService:Stop()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self._running = false
end

return DailyRewardCalendarService
