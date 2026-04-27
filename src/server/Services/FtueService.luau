--!strict
-- First-time user experience: drives `Player` attributes (`FtueStep`, optional cell keys) and
-- notifies clients via `FtueStateUpdate`. Progress is persisted on `OilStateService` (`ftueStep`).

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local FtueService = {}

-- UserId -> os.clock() at most-recent step entry. Powers `secondsInStep` /
-- `secondsInPreviousStep` for the FTUE funnel telemetry.
local _ftueStepEnteredAtByUserId: { [number]: number } = {}
-- UserId -> true once `ftue_done` has fired this server lifetime, so we
-- don't double-fire if `_setStep(Done)` is reentered (e.g. via Continue
-- fall-through). `Telemetry.SetSession`/`SessionGet` were not shipped in
-- PR 3, so we track first-* idempotency locally.
local _ftueDoneFiredByUserId: { [number]: boolean } = {}
-- UserId -> true once `ftue_started` has fired this server lifetime.
-- Same idempotency reasoning as `_ftueDoneFiredByUserId` above — we do
-- NOT want to record a fresh "started" each time the player respawns or
-- `SyncFromOilState` re-enters the Intro branch on rejoin.
local _ftueStartedFiredByUserId: { [number]: boolean } = {}

local function _ftueOrdinal(stepId: string?): number?
	if typeof(stepId) ~= "string" then
		return nil
	end
	local order = FtueConfig.Order
	if typeof(order) ~= "table" then
		return nil
	end
	for index, name in ipairs(order) do
		if name == stepId then
			return index
		end
	end
	return nil
end

local _remoteService: any = nil
local _connections: { RBXScriptConnection } = {}

local function ftueDbg(fmt: string, ...: any)
	if FtueConfig.DebugTrace ~= true then
		return
	end
	warn("[FTUE] " .. string.format(fmt, ...))
end

local function ftueDumpOilState(oil: any, player: Player, label: string)
	if FtueConfig.DebugTrace ~= true then
		return
	end
	local st = oil and oil:GetState(player.UserId)
	if not st then
		warn("[FTUE] " .. label .. " | no oil state")
		return
	end
	local attr = player:GetAttribute(Constants.FtueStepAttribute)
	warn(
		string.format(
			"[FTUE] %s | uid=%d oil.ftueStep=%s oil.ftueCompleted=%s oil.doneAck=%s player.FtueStepAttr=%s",
			label,
			player.UserId,
			tostring((st :: any).ftueStep),
			tostring((st :: any).ftueCompleted),
			tostring((st :: any).ftueDoneScreenAcknowledged),
			tostring(attr)
		)
	)
end

local function floorPositive(n: number): number
	return math.max(0, math.floor(n))
end

local function fireState(player: Player, step: string?)
	local ev = _remoteService:GetEvent(RemoteNames.FtueStateUpdate)
	ev:FireClient(player, { step = step })
end

--- One-time plot cash when entering **`WaitPlotShipment`** (see `FtueConfig.PlotShipmentStageCashReward`). Server truth; pairs with client `UiSfx.playKaching` on that step.
local function grantPlotShipmentStageCashIfNeeded(self: any, player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local oil = self._oilState
	if not oil then
		return
	end
	local st = oil:GetState(player.UserId)
	if not st then
		return
	end
	-- Belt-and-suspenders: the granted flag is the primary gate, but also bail
	-- if the player has already finished the tutorial entirely so a stale
	-- WaitPlotShipment re-entry on a fully-completed profile can never re-pay.
	if (st :: any).ftueDispatchCashGranted == true
		or (st :: any).ftueCompleted == true
	then
		ftueDbg(
			"grantPlotShipmentStageCashIfNeeded uid=%d skip (granted=%s completed=%s)",
			player.UserId,
			tostring((st :: any).ftueDispatchCashGranted),
			tostring((st :: any).ftueCompleted)
		)
		return
	end
	local amt = floorPositive(tonumber(FtueConfig.PlotShipmentStageCashReward) or 0)
	if amt <= 0 then
		return
	end
	st.ftueDispatchCashGranted = true
	-- Persist the gate **immediately** so a crash/disconnect in the same frame
	-- as the grant (before the next autosave tick) still saves the flag.
	-- `AddCash` also marks dirty, but relying on it alone leaves a small window
	-- where `state.ftueDispatchCashGranted = true` is set but unsaved.
	if typeof((oil :: any)._markDirty) == "function" then
		(oil :: any):_markDirty(player.UserId)
	end
	oil:AddCash(player.UserId, amt)
	oil:PushState(player.UserId)
end

--- One-time cash when entering `Done` (see `FtueConfig.TutorialCompleteCashReward`).
---
--- **Idempotency / rejoin safety:** the player can park on the `Done` modal
--- across sessions (they only finish the tutorial when they click `Complete!`,
--- which fires `_setStep(nil)` — not `_setStep(Done)` — so this function isn't
--- re-entered on the normal rejoin path). Even so, anything that calls
--- `_setStep(Done)` again (e.g. server-side `onSkip` falling through, a future
--- code path that re-arms the modal) must not re-pay the reward. The gates
--- below (granted flag + ftueCompleted + ftueDoneScreenAcknowledged) plus an
--- explicit `_markDirty` immediately after we flip the granted flag make the
--- payout strictly one-shot per profile, even if the player disconnects in the
--- same frame as the grant (`AddCash` also marks dirty, but persisting via
--- `_markDirty` here decouples the gate's durability from `AddCash`).
local function grantTutorialCompleteCashIfNeeded(self: any, player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local oil = self._oilState
	if not oil then
		return
	end
	local st = oil:GetState(player.UserId)
	if not st then
		return
	end
	if (st :: any).ftueTutorialCompleteCashGranted == true
		or (st :: any).ftueCompleted == true
		or (st :: any).ftueDoneScreenAcknowledged == true
	then
		ftueDbg(
			"grantTutorialCompleteCashIfNeeded uid=%d skip (granted=%s completed=%s doneAck=%s)",
			player.UserId,
			tostring((st :: any).ftueTutorialCompleteCashGranted),
			tostring((st :: any).ftueCompleted),
			tostring((st :: any).ftueDoneScreenAcknowledged)
		)
		return
	end
	local amt = floorPositive(tonumber(FtueConfig.TutorialCompleteCashReward) or 0)
	if amt <= 0 then
		return
	end
	;(st :: any).ftueTutorialCompleteCashGranted = true
	if typeof((oil :: any)._markDirty) == "function" then
		(oil :: any):_markDirty(player.UserId)
	end
	oil:AddCash(player.UserId, amt)
	oil:PushState(player.UserId)
	ftueDbg("grantTutorialCompleteCashIfNeeded uid=%d granted amt=%d", player.UserId, amt)
end

--- Forward declaration so `SyncFromOilState` (defined below `reapplyFtueRestrictionAttributes`)
--- can call `applyWaitDrillEntry` even though the function body is assigned further down the
--- file. Lua locals do not hoist, so calling the identifier before the `local function …`
--- statement would resolve to a nil global. The actual implementation assigns into this slot
--- via `applyWaitDrillEntry = function(...)` (no leading `local`) so both `SyncFromOilState`
--- and `onAcknowledge` close over the same upvalue.
local applyWaitDrillEntry: (self: any, player: Player) -> ()

--- Sets the drill restriction attribute from plot + oil state for the current step.
--- The pipe / pump legs are gone — the auto-place center pump collects from drilled tiles
--- so the drill-only highlight is the only restriction needed.
local function reapplyFtueRestrictionAttributes(self: any, player: Player)
	self:_clearRestrictionAttributes(player)
	local plot = self._plotService:GetOwnedPlot(player.UserId)
	local st = self._oilState:GetState(player.UserId)
	if not plot or not st then
		return
	end
	local step = (st :: any).ftueStep
	if step == FtueConfig.Step.WaitDrillOil_WIP then
		-- Chunk-level restriction: allow drilling ANY tile in the starter chunk.
		local starterChunk = self._oilState:GetStarterChunkSectionId()
		if not self._oilState:IsAnyTileInChunkDrilled(st, starterChunk) then
			player:SetAttribute(Constants.FtueRestrictDrillChunkIdAttribute, starterChunk)
		end
	elseif step == FtueConfig.Step.WaitReveal then
		--- Reveal leg: keep the same cell key set so the per-plot beam target
		--- (`FtuePoiBeamConfig` `WaitReveal` rule) and tile highlight resolve to the
		--- post-drill tutorial tile, even after the player rejoins mid-step.
		local drillCk = self._oilState:GetFtueDrillTargetCellKeyForPlot(plot, st, player.UserId)
		if typeof(drillCk) == "string" and drillCk ~= "" then
			player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, drillCk)
		end
	end
end

function FtueService:_setStep(player: Player, step: string?)
	-- Snapshot previous step BEFORE any of the step-entry side effects
	-- mutate the FtueStepAttribute so the outgoing-step telemetry fires
	-- with the correct id.
	local _prevStepRaw = player:GetAttribute(Constants.FtueStepAttribute)
	local _prevStep: string? = if typeof(_prevStepRaw) == "string" then _prevStepRaw else nil
	local _prevEnteredAt = _ftueStepEnteredAtByUserId[player.UserId]
	local _stepEnteredAt = os.clock()
	if typeof(step) == "string" and step == FtueConfig.Step.WaitPlotShipment then
		grantPlotShipmentStageCashIfNeeded(self, player)
	end
	if typeof(step) == "string" and step == FtueConfig.Step.Done then
		--- Clear stale acknowledgement **before** cash grant / `PushState` / `SetFtueProgress`, so any
		--- deferred `SyncFromOilState` sees `ftueDoneScreenAcknowledged == false` while entering Done.
		local oil = self._oilState
		if oil and typeof((oil :: any).GetState) == "function" and typeof((oil :: any).SetFtueDoneScreenAcknowledged) == "function" then
			local pst = (oil :: any):GetState(player.UserId)
			if pst then
				local prev = typeof((pst :: any).ftueStep) == "string" and (pst :: any).ftueStep or ""
				if prev ~= FtueConfig.Step.Done then
					(oil :: any):SetFtueDoneScreenAcknowledged(player.UserId, false)
				end
			end
		end
		grantTutorialCompleteCashIfNeeded(self, player)
	end
	if step == FtueConfig.Step.Done or step == nil then
		self:_clearRestrictionAttributes(player)
	end
	if FtueConfig.Enabled == true and self._oilState and typeof((self._oilState :: any).SetFtueProgress) == "function" then
		(self._oilState :: any):SetFtueProgress(player.UserId, step)
	end
	--- Stamp/clear the BasePart marker (`IsFtueTutorialTile`) for the per-plot
	--- world beam (`FtuePoiBeamConfig` `WaitReveal` rule). Keep the marker live
	--- across both the drill leg and the reveal leg; clear on every other step
	--- so the beam does not point at an old tile after the FTUE moves on.
	--- Stamped **before** `FtueStepAttribute` is replicated so the client's
	--- `PlayerToPoiBeamBootstrap` refresh sees the BasePart attribute on first try.
	if self._oilState and typeof((self._oilState :: any).SetFtueTutorialTileMarker) == "function" then
		-- WaitDrillOil_WIP uses chunk-level highlight (client-side), no single-tile marker.
		-- Only stamp tile marker during WaitReveal (beam/highlight points at the drilled tile).
		local enableMarker = (step == FtueConfig.Step.WaitReveal)
		;(self._oilState :: any):SetFtueTutorialTileMarker(player.UserId, enableMarker)
	end
	player:SetAttribute(Constants.FtueStepAttribute, step)
	-- `WaitDocksUpgradeShip` sub-step attribute clear was deleted by
	-- Step 4 of the boat-progression refactor (the leg + the attribute
	-- + the matching `SetFtueDocksUpgradeSubStep` are gone). The new
	-- `WaitDocksFleetPanel` leg uses `FtueDocksFleetPanelSubStepAttribute`
	-- instead — cleared on every transition out of that step.
	if typeof(step) ~= "string" or step ~= FtueConfig.Step.WaitDocksEquipmentShop then
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
	end
	if typeof(step) ~= "string" or step ~= FtueConfig.Step.WaitDocksFleetPanel then
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
	end
	fireState(player, step)
	--- The sell-leg can't progress unless the player is standing on the
	--- warehouse `WarehouseSpawn` (the proximity prompt + sell terminal both
	--- live there). On every entry into `WaitWarehouseSell` — including the
	--- normal "boat just landed" transition — force-teleport the player to
	--- the warehouse so the leg is reachable no matter where they currently
	--- are (e.g. they jumped off the boat, were knocked off-platform, etc.).
	--- Rejoin / death-respawn cases are covered separately by
	--- `_onCharacterSpawnedDuringFtue`, since `SyncFromOilState` bypasses
	--- `_setStep` and sets the attribute directly.
	if typeof(step) == "string" and step == FtueConfig.Step.WaitWarehouseSell then
		self:_ensureAtWarehouse(player)
	end
	--- FTUE rejoin / death-respawn anchor: every transition **into** an active
	--- FTUE step snapshots the player's HumanoidRootPart `CFrame` ~1s later
	--- (so any step-driven teleport — `_ensureAtWarehouse`, the WaitShipment
	--- boat-deck reseat — has had time to land before we capture). Transition
	--- to `Done` / `nil` clears the anchor immediately so post-FTUE rejoins go
	--- back to the ClaimPad. The `PlayerRemoving` snapshot in
	--- `OilStateService` overrides this with the latest position right before
	--- the flush, so the persisted value is always the most recent of
	--- `step-entry` and `disconnect-time`.
	if FtueConfig.Enabled == true and self._oilState and typeof((self._oilState :: any).SetFtueLastSpawn) == "function" then
		if step == nil or step == FtueConfig.Step.Done then
			(self._oilState :: any):SetFtueLastSpawn(player.UserId, nil)
		else
			local stepAtSchedule = step
			task.delay(1.0, function()
				if not player.Parent then
					return
				end
				if player:GetAttribute(Constants.FtueStepAttribute) ~= stepAtSchedule then
					return
				end
				local oilState = self._oilState
				if not (oilState and typeof((oilState :: any).CaptureFtueSpawnSnapshot) == "function") then
					return
				end
				(oilState :: any):CaptureFtueSpawnSnapshot(player.UserId)
			end)
		end
	end
	ftueDbg(
		"_setStep uid=%d -> FtueStateUpdate(%s) SetAttribute(FtueStep)",
		player.UserId,
		step == nil and "nil" or tostring(step)
	)
	ftueDumpOilState(self._oilState, player, "_setStep after")

	-- Wrap telemetry in pcall so a Telemetry bug can never break the FTUE
	-- transition path (the FtueStepAttribute / FtueStateUpdate above are
	-- already committed, the player must not get stuck mid-transition).
	pcall(function()
		if _prevStep ~= nil and _prevStep ~= step then
			local secondsInStep: number? = nil
			if typeof(_prevEnteredAt) == "number" then
				secondsInStep = os.clock() - _prevEnteredAt
			end
			Telemetry.Track(player, "ftue_step_completed", {
				stepId = _prevStep,
				secondsInStep = secondsInStep,
			})
		end
		if typeof(step) == "string" then
			_ftueStepEnteredAtByUserId[player.UserId] = _stepEnteredAt
			-- Telemetry §6.1 `ftue_started`. Per session, fires once the
			-- first time the player enters any non-nil FTUE step
			-- (typically `Intro`). Idempotent per server lifetime.
			if not _ftueStartedFiredByUserId[player.UserId] then
				_ftueStartedFiredByUserId[player.UserId] = true
				Telemetry.Track(player, "ftue_started", {
					stepId = step,
				})
			end
			local ordinal = _ftueOrdinal(step)
			if ordinal then
				Telemetry.Funnel(player, "ftue", ordinal, step)
			end
			if step == FtueConfig.Step.Done and not _ftueDoneFiredByUserId[player.UserId] then
				_ftueDoneFiredByUserId[player.UserId] = true
				Telemetry.Track(player, "ftue_done", {
					cashGranted = FtueConfig.TutorialCompleteCashReward,
				})
			end
		else
			_ftueStepEnteredAtByUserId[player.UserId] = nil
		end
	end)
end

function FtueService:_clearRestrictionAttributes(player: Player)
	player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, nil)
	player:SetAttribute(Constants.FtueRestrictDrillChunkIdAttribute, nil)
end

--- Public hook for other services (drill complete, dispatch, warehouse sell, …).
function FtueService:SetStep(player: Player, step: string?)
	if FtueConfig.Enabled ~= true then
		return
	end
	self:_setStep(player, step)
end

--- Same as `SetStep` but reads `UserId` (server-only callers).
function FtueService:SetStepForUserId(userId: number, step: string?)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	self:SetStep(player, step)
end

--- Called from `OilStateService` after plot state loads so `Player` attributes match persisted `ftueStep`.
function FtueService:SyncFromOilState(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	if FtueConfig.Enabled ~= true then
		self:_clearRestrictionAttributes(player)
		player:SetAttribute(Constants.FtueStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		fireState(player, nil)
		ftueDbg("SyncFromOilState uid=%d FTUE disabled -> clear UI", userId)
		return
	end
	local st = self._oilState:GetState(userId)
	if not st then
		return
	end
	local doneAck = (st :: any).ftueDoneScreenAcknowledged == true
	local stepStr = typeof((st :: any).ftueStep) == "string" and (st :: any).ftueStep or nil
	local completed = (st :: any).ftueCompleted == true

	ftueDbg(
		"SyncFromOilState uid=%d oil.ftueStep=%s oil.ftueCompleted=%s oil.doneAck=%s",
		userId,
		tostring(stepStr),
		tostring(completed),
		tostring(doneAck)
	)
	ftueDumpOilState(self._oilState, player, "SyncFromOilState enter")

	--- Tutorial fully finished (`SetFtueProgress(nil)` after Complete!): no FTUE UI.
	if completed and stepStr == nil then
		self:_clearRestrictionAttributes(player)
		player:SetAttribute(Constants.FtueStepAttribute, nil)
		--- Clear leg sub-steps too: they should never replicate to the
		--- client past the FTUE itself (stale value would re-show old pointers).
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		fireState(player, nil)
		ftueDbg("SyncFromOilState uid=%d branch=finished (completed+no step) -> FtueStateUpdate(nil)", userId)
		return
	end

	--- `ftueCompleted` but `ftueStep` still set (stale save): re-run completion so persist + perks match.
	if completed == true and typeof(stepStr) == "string" then
		if self._oilState and typeof((self._oilState :: any).SetFtueProgress) == "function" then
			(self._oilState :: any):SetFtueProgress(userId, nil)
		end
		self:_clearRestrictionAttributes(player)
		player:SetAttribute(Constants.FtueStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
		fireState(player, nil)
		ftueDbg(
			"SyncFromOilState uid=%d branch=sanitize ftueCompleted+stale ftueStep -> SetFtueProgress(nil)",
			userId
		)
		return
	end

	--- Legacy row: Complete! acknowledged but `ftueStep` still `"Done"` — finalize oil profile (`ftueCompleted`, nil step).
	if doneAck and stepStr == FtueConfig.Step.Done then
		if self._oilState and typeof((self._oilState :: any).SetFtueProgress) == "function" then
			(self._oilState :: any):SetFtueProgress(userId, nil)
		end
		self:_clearRestrictionAttributes(player)
		player:SetAttribute(Constants.FtueStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
		fireState(player, nil)
		ftueDbg(
			"SyncFromOilState uid=%d branch=legacy doneAck+ftueStep==Done -> SetFtueProgress(nil)+FtueStateUpdate(nil)",
			userId
		)
		return
	end

	--- On final modal: reached Done step, waiting for Complete!
	if stepStr == FtueConfig.Step.Done then
		self:_clearRestrictionAttributes(player)
		player:SetAttribute(Constants.FtueStepAttribute, FtueConfig.Step.Done)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
		fireState(player, FtueConfig.Step.Done)
		ftueDbg("SyncFromOilState uid=%d branch=show Done modal -> FtueStateUpdate(Done)", userId)
		return
	end

	local step = stepStr or FtueConfig.Step.WaitDrillOil_WIP

	--- Rejoin recovery: `OilShipmentService` keeps active voyages in memory only
	--- (`_activeShipmentByOwner` / `_activeShips` — see `OilShipmentService.luau`),
	--- so a player who quit mid-strait rejoins with `ftueStep == WaitShipment`
	--- but no actual ship to wait for (they'd be stranded on a beam to a vessel
	--- that doesn't exist). Drop back to `WaitPlotShipment` so they can re-dispatch.
	if step == FtueConfig.Step.WaitShipment then
		local hasShip = false
		if self._shipment and typeof((self._shipment :: any).HasActiveShipment) == "function" then
			hasShip = (self._shipment :: any):HasActiveShipment(userId) == true
		end
		if not hasShip then
			step = FtueConfig.Step.WaitPlotShipment
			if self._oilState and typeof((self._oilState :: any).SetFtueProgress) == "function" then
				(self._oilState :: any):SetFtueProgress(userId, step)
			end
			ftueDbg(
				"SyncFromOilState uid=%d branch=recover WaitShipment->WaitPlotShipment (no active ship)",
				userId
			)
		end
	end

	-- Telemetry §6.1 `ftue_started`. The rejoin path through
	-- `SyncFromOilState` sets the FtueStepAttribute directly without
	-- going through `_setStep`, so we duplicate the one-shot fire here
	-- so analytics still records the FTUE-active session start for
	-- returning players. Idempotent on `_ftueStartedFiredByUserId`.
	pcall(function()
		if not _ftueStartedFiredByUserId[player.UserId] then
			_ftueStartedFiredByUserId[player.UserId] = true
			Telemetry.Track(player, "ftue_started", {
				stepId = step,
				rejoin = true,
			})
		end
	end)
	reapplyFtueRestrictionAttributes(self, player)
	--- Re-stamp the BasePart marker on rejoin so the per-plot WaitReveal beam and
	--- tile highlight resolve to the correct tile without waiting for a step change.
	if self._oilState and typeof((self._oilState :: any).SetFtueTutorialTileMarker) == "function" then
		local enableMarker = (step == FtueConfig.Step.WaitReveal)
		;(self._oilState :: any):SetFtueTutorialTileMarker(userId, enableMarker)
	end
	--- Fresh-profile entry into the drill leg: `Intro` was removed from
	--- `FtueConfig.Order`, so the old `onAcknowledge` Continue-button path that
	--- granted the starter drill no longer fires for new players. Trigger
	--- `applyWaitDrillEntry` here instead — it's idempotent (drill grant gated
	--- on `equipmentOwnedByItemId[DrillItemId]`) so rejoins mid-step don't
	--- stack extra drills, and the chunk restriction re-set is redundant with
	--- `reapplyFtueRestrictionAttributes` above (kept as a safety net so the
	--- Intro Continue path still works unchanged if the leg is reactivated).
	if step == FtueConfig.Step.WaitDrillOil_WIP then
		applyWaitDrillEntry(self, player)
	end
	player:SetAttribute(Constants.FtueStepAttribute, step)
	--- Re-arm the equipment-shop sub-step on rejoin so the right pointer (`BuyDrill`
	--- vs `ClosePanel`) lights up. `ftueFreeDocksDrillUsed` is the persisted source
	--- of truth for whether the free drill was already purchased.
	if step == FtueConfig.Step.WaitDocksEquipmentShop then
		local alreadyBought = (st :: any).ftueFreeDocksDrillUsed == true
		player:SetAttribute(
			Constants.FtueDocksEquipmentShopSubStepAttribute,
			if alreadyBought then "ClosePanel" else "BuyDrill"
		)
	else
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
	end
	--- Re-arm the fleet-panel sub-step on rejoin. `FleetPanelGui` closes on
	--- disconnect, so we always default to `OpenPanel` (beam to dockman); the
	--- `ProximityPanelOpener` bridge will flip to `ClosePanel` when the player
	--- re-opens the modal. The sub-step itself is intentionally **not**
	--- persisted — there is no useful "halfway" state for this leg.
	if step == FtueConfig.Step.WaitDocksFleetPanel then
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, "OpenPanel")
	else
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
	end
	-- `WaitDocksUpgradeShip` rejoin-recovery block (re-arm sub-step from
	-- persisted `ftueDocksUpgradeSubStep`) was deleted by Step 4 of the
	-- boat-progression refactor along with the leg itself, the
	-- `FtueDocksUpgradeSubStepAttribute`, and `SetFtueDocksUpgradeSubStep`.
	fireState(player, step)
	--- Fresh-join spawn-on-grid trigger. On a brand-new profile the character
	--- spawns (and gets parked at ClaimPad by `PlotService`) **before**
	--- `OilStateService` finishes loading the profile and we set the
	--- `FtueStepAttribute` a few lines above. PlotService's WaitDrillOil_WIP
	--- spawn override therefore reads `nil` for that first teleport and falls
	--- back to ClaimPad. Now that the attribute is set, ask PlotService to
	--- re-run the canonical teleport — the override fires this time and the
	--- player lands on the highlighted drill chunk. `RefreshSpawn` no-ops if
	--- the character does not yet exist; the `CharacterAdded` connection in
	--- `_ensureCharacterAddedConnection` will run the override on its own
	--- once the character spawns (since the attribute is now set).
	if step == FtueConfig.Step.WaitDrillOil_WIP and self._plotService and typeof((self._plotService :: any).RefreshSpawn) == "function" then
		(self._plotService :: any):RefreshSpawn(player)
	end
	ftueDbg("SyncFromOilState uid=%d branch=midFlow -> FtueStateUpdate(%s)", userId, step)
end

applyWaitDrillEntry = function(self: any, player: Player)
	local function tryGrant(): boolean
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		if not plot then
			return false
		end
		local st = self._oilState:GetState(player.UserId)
		if not st then
			return false
		end
		-- Chunk-level restriction: allow drilling ANY tile in the starter chunk.
		local starterChunk = self._oilState:GetStarterChunkSectionId()
		player:SetAttribute(Constants.FtueRestrictDrillChunkIdAttribute, starterChunk)
		--- Drill grant is idempotent on the player's persisted inventory: skip if
		--- they already own the FTUE drill (rejoin mid-WaitDrillOil_WIP, legacy
		--- profile re-migrated, or the post-Intro Continue-button path that
		--- previously ran this — `Intro` was removed from `FtueConfig.Order`
		--- but the `onAcknowledge` branch is still wired in case the leg is
		--- reactivated). Without this, every `SyncFromOilState` while the
		--- player is on this step would stack another drill into the backpack.
		local owned = (st :: any).equipmentOwnedByItemId
		local ownedCount = if typeof(owned) == "table" then owned[FtueConfig.DrillItemId] else nil
		if typeof(ownedCount) ~= "number" or ownedCount < 1 then
			self._equipmentShop:GrantFreeOwnedEquipment(player, FtueConfig.DrillItemId, 1)
		end
		self._oilState:PushState(player.UserId)
		return true
	end
	if tryGrant() then
		return
	end
	task.spawn(function()
		for _ = 1, 80 do
			if tryGrant() then
				return
			end
			task.wait(0.25)
		end
		warn("[FtueService] WaitDrill: timed out waiting for plot/oil state — drill highlight and free drill not applied.")
	end)
end

local function onAcknowledge(self: any, player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local ost = self._oilState and self._oilState:GetState(player.UserId)
	if not ost then
		ftueDbg("onAcknowledge uid=%d abort: no oil state", player.UserId)
		return
	end
	local raw = player:GetAttribute(Constants.FtueStepAttribute)
	local step = ""
	if typeof(raw) == "string" then
		step = (raw :: string):gsub("^%s+", ""):gsub("%s+$", "")
	end
	if step == "" then
		local s = typeof((ost :: any).ftueStep) == "string" and (ost :: any).ftueStep
		if typeof(s) == "string" then
			step = (s :: string):gsub("^%s+", ""):gsub("%s+$", "")
		end
	end
	if step == "" then
		ftueDbg("onAcknowledge uid=%d abort: empty step (attr+oil)", player.UserId)
		return
	end
	local oilStep = typeof((ost :: any).ftueStep) == "string" and (ost :: any).ftueStep or nil
	if step == FtueConfig.Step.Intro and oilStep ~= FtueConfig.Step.Intro then
		ftueDbg("onAcknowledge uid=%d reject Intro: oil.ftueStep=%s", player.UserId, tostring(oilStep))
		return
	end
	--- `WaitDrillOil_WIP` is no longer ackable — the player must complete the
	--- highlighted tutorial drill. Reject any client-fired ack so a modified
	--- client can't skip the leg even though the Continue button is hidden in
	--- `FtueDialogueController.ACK_STEPS`.
	if step == FtueConfig.Step.WaitDrillOil_WIP then
		ftueDbg("onAcknowledge uid=%d reject WaitDrillOil_WIP: drill leg is no longer skippable", player.UserId)
		return
	end
	if step == FtueConfig.Step.WaitSell and oilStep ~= FtueConfig.Step.WaitSell then
		ftueDbg("onAcknowledge uid=%d reject WaitSell: oil.ftueStep=%s", player.UserId, tostring(oilStep))
		return
	end
	if step == FtueConfig.Step.WaitDocksHire and oilStep ~= FtueConfig.Step.WaitDocksHire then
		ftueDbg("onAcknowledge uid=%d reject WaitDocksHire: oil.ftueStep=%s", player.UserId, tostring(oilStep))
		return
	end
	if step == FtueConfig.Step.Done and oilStep ~= FtueConfig.Step.Done then
		ftueDbg("onAcknowledge uid=%d reject Complete!: oil.ftueStep=%s", player.UserId, tostring(oilStep))
		return
	end
	ftueDbg("onAcknowledge uid=%d resolvedStep=%s (Continue/Complete!)", player.UserId, step)
	ftueDumpOilState(self._oilState, player, "onAcknowledge before")
	-- Only steps that show **Continue** in `FtueDialogueController` advance here
	-- (Intro, WaitSell, WaitDocksHire, Done). `WaitDrillOil_WIP` was removed —
	-- the player completes the leg by actually drilling the highlighted tile,
	-- which fires `OnFtueTutorialDrillFinished` from `DrillingService` (live)
	-- or from the offline-rehydrate path in `init.server.luau`.
	if step == FtueConfig.Step.Intro then
		applyWaitDrillEntry(self, player)
		self:_setStep(player, FtueConfig.Step.WaitDrillOil_WIP)
	elseif step == FtueConfig.Step.WaitSell then
		self:_setStep(player, FtueConfig.Step.WaitDocksShipUpgrade)
	elseif step == FtueConfig.Step.WaitDocksHire then
		ftueDbg("onAcknowledge uid=%d WaitDocksHire Continue -> _setStep(Done) (final modal)", player.UserId)
		local oil = self._oilState
		if oil and typeof((oil :: any).SetFtueDoneScreenAcknowledged) == "function" then
			(oil :: any):SetFtueDoneScreenAcknowledged(player.UserId, false)
		end
		self:_setStep(player, FtueConfig.Step.Done)
	elseif step == FtueConfig.Step.Done then
		ftueDbg("onAcknowledge uid=%d Complete! -> doneAck=true + SetFtueProgress(nil) (tutorial finished)", player.UserId)
		local oil = self._oilState
		if oil and typeof((oil :: any).SetFtueDoneScreenAcknowledged) == "function" then
			(oil :: any):SetFtueDoneScreenAcknowledged(player.UserId, true)
		end
		self:_setStep(player, nil)
	else
		ftueDbg("onAcknowledge uid=%d ignored step=%s", player.UserId, step)
		return
	end
	ftueDumpOilState(self._oilState, player, "onAcknowledge after")
end

local function onSkip(self: any, player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local ost = self._oilState and self._oilState:GetState(player.UserId)
	if not ost then
		return
	end
	if (ost :: any).ftueCompleted == true then
		return
	end
	ftueDbg("onSkip uid=%d -> _setStep(Done) (final modal)", player.UserId)
	-- Telemetry §6.2 `ftue_skipped`. Fired BEFORE `_setStep(Done)` so
	-- the row carries the player's last in-progress step (the one they
	-- chose to skip from) rather than `Done`.
	pcall(function()
		local prevStepRaw = player:GetAttribute(Constants.FtueStepAttribute)
		local prevStep: string? = if typeof(prevStepRaw) == "string" then prevStepRaw else nil
		local prevEnteredAt = _ftueStepEnteredAtByUserId[player.UserId]
		local secondsInStep: number? = if typeof(prevEnteredAt) == "number" then os.clock() - prevEnteredAt else nil
		Telemetry.Track(player, "ftue_skipped", {
			stepId = prevStep,
			funnelStep = _ftueOrdinal(prevStep),
			secondsInStep = secondsInStep,
		})
	end)
	self:_clearRestrictionAttributes(player)
	self:_setStep(player, FtueConfig.Step.Done)
end

function FtueService:Init(
	remoteService: any,
	_plotService: any,
	_oilState: any,
	_equipmentShop: any,
	_drilling: any,
	_shipment: any,
	_market: any,
	_warehouse: any?
)
	_remoteService = remoteService
	self._plotService = _plotService
	self._oilState = _oilState
	self._equipmentShop = _equipmentShop
	self._drilling = _drilling
	self._shipment = _shipment
	self._market = _market
	self._warehouse = _warehouse
end

--- After the FTUE drill completes on the tutorial tile: advance to **`WaitReveal`**.
--- The drill restriction cell key is intentionally **kept** on the player so the
--- per-plot world beam (`FtuePoiBeamConfig` `WaitReveal` rule) and tile highlight
--- continue to anchor on the same tile while the player walks up to the shovel.
function FtueService:OnFtueTutorialDrillFinished(userId: number, done: any?)
	if FtueConfig.Enabled ~= true then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local st = self._oilState:GetState(userId)
	if not st then
		return
	end
	local stepAny = (st :: any).ftueStep
	local persistedStep = typeof(stepAny) == "string" and stepAny
	if persistedStep ~= FtueConfig.Step.WaitDrillOil_WIP and player:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitDrillOil_WIP then
		return
	end
	-- Chunk-level restriction: validate drilled tile is in starter chunk.
	local wantChunk = player:GetAttribute(Constants.FtueRestrictDrillChunkIdAttribute)
	if typeof(wantChunk) == "string" and wantChunk ~= "" then
		local drilledChunk = if typeof(done) == "table" then (done :: any).chunkId else nil
		if typeof(drilledChunk) == "string" and drilledChunk ~= wantChunk then
			return
		end
	end
	-- Legacy single-cell check (for backward compat with old profiles mid-FTUE)
	local wantDrill = player:GetAttribute(Constants.FtueRestrictDrillCellKeyAttribute)
	if typeof(wantDrill) == "string" and wantDrill ~= "" then
		local ck = if typeof(done) == "table" then (done :: any).cellKey else nil
		if typeof(ck) == "string" and ck ~= wantDrill then
			return
		end
	end
	-- Clear chunk restriction, set cell key for WaitReveal beam/highlight
	player:SetAttribute(Constants.FtueRestrictDrillChunkIdAttribute, nil)
	local drilledCellKey = if typeof(done) == "table" then (done :: any).cellKey else nil
	if typeof(drilledCellKey) == "string" and drilledCellKey ~= "" then
		player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, drilledCellKey)
	end
	self:SetStep(player, FtueConfig.Step.WaitReveal)
end

--- After the FTUE reveal (lootbox) completes on the tutorial tile: clear the drill
--- restrict cell key + tile marker (handled by `_setStep` -> `SetFtueTutorialTileMarker(false)`)
--- and advance to **`WaitPlotShipment`**.
function FtueService:OnFtueTutorialRevealFinished(userId: number, done: any?)
	if FtueConfig.Enabled ~= true then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local st = self._oilState:GetState(userId)
	if not st then
		return
	end
	local stepAny = (st :: any).ftueStep
	local persistedStep = typeof(stepAny) == "string" and stepAny
	if persistedStep ~= FtueConfig.Step.WaitReveal and player:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitReveal then
		return
	end
	local wantDrill = player:GetAttribute(Constants.FtueRestrictDrillCellKeyAttribute)
	if typeof(wantDrill) == "string" and wantDrill ~= "" then
		local ck = if typeof(done) == "table" then (done :: any).cellKey else nil
		if typeof(ck) == "string" and ck ~= wantDrill then
			return
		end
	end
	player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, nil)
	self:SetStep(player, FtueConfig.Step.WaitPlotShipment)
end

--- After a successful `RequestDispatchShipment` while on **`WaitPlotShipment`**: ship is sailing — show `WaitShipment` copy.
function FtueService:OnDispatchShipmentSuccess(userId: number)
	if FtueConfig.Enabled ~= true then
		return
	end
	local st = self._oilState:GetState(userId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitPlotShipment then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	self:SetStep(player, FtueConfig.Step.WaitShipment)
end

--- After barrels are delivered to the warehouse (`delivered > 0`) while on `WaitShipment`.
function FtueService:OnShipmentDeliveredToWarehouse(userId: number, totalDelivered: number)
	if FtueConfig.Enabled ~= true then
		return
	end
	if totalDelivered <= 0 then
		return
	end
	local st = self._oilState:GetState(userId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitShipment then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	self:SetStep(player, FtueConfig.Step.WaitWarehouseSell)
end

--- After any successful warehouse sale payout while on **`WaitWarehouseSell`** — next step uses Continue (`WaitSell`).
function FtueService:OnFtueWarehouseSaleSuccess(userId: number, payout: number)
	if FtueConfig.Enabled ~= true then
		return
	end
	if payout <= 0 then
		return
	end
	local st = self._oilState:GetState(userId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitWarehouseSell then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	self:SetStep(player, FtueConfig.Step.WaitSell)
end

--- After HUD **Town / Buy** teleports the player to docks while on **`WaitDocksShipUpgrade`**.
--- Routes the player into the **equipment shop** leg first; the dockman / cargo upgrade
--- leg is unlocked by `OnFtueEquipmentShopPanelClosed` once the free Tier 3 drill is
--- bought *and* the player closes the shop modal (so the close-button pointer can
--- trigger that final transition).
function FtueService:OnFtueDocksTownTeleportSuccess(player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local st = self._oilState:GetState(player.UserId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitDocksShipUpgrade then
		return
	end
	self:_setStep(player, FtueConfig.Step.WaitDocksEquipmentShop)
	player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, "BuyDrill")
	fireState(player, FtueConfig.Step.WaitDocksEquipmentShop)
end

--- Server hook: called from `EquipmentShopService:_handlePurchase` after a successful
--- buy. When on **`WaitDocksEquipmentShop`** and the purchased item is the configured
--- free dock drill (`FtueConfig.FtueDocksFreeDrillItemId`), flip the sub-step to
--- `"ClosePanel"` so the close-button pointer lights up. The step itself does **not**
--- advance until the player actually closes the shop modal
--- (`OnFtueDocksProgress("EquipmentShopPanelClosed")`).
function FtueService:OnFtueEquipmentShopPurchase(player: Player, itemId: string)
	if FtueConfig.Enabled ~= true then
		return
	end
	if typeof(itemId) ~= "string" or itemId == "" then
		return
	end
	local st = self._oilState:GetState(player.UserId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitDocksEquipmentShop then
		return
	end
	if itemId ~= FtueConfig.FtueDocksFreeDrillItemId then
		return
	end
	player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, "ClosePanel")
	fireState(player, FtueConfig.Step.WaitDocksEquipmentShop)
end

--- FTUE docks flow (post-Step-4 + fleet-panel leg):
---   `EquipmentShopPanelClosed` (after free drill purchased + panel
---     closed during `WaitDocksEquipmentShop` sub `ClosePanel`) →
---     **`WaitDocksFleetPanel`** + sub `OpenPanel` (world beam to dockman).
---   `FleetPanelOpened` (dockman prox prompt opened `FleetPanelGui` while
---     on `WaitDocksFleetPanel` + sub `OpenPanel`) → keep step, flip sub
---     to `ClosePanel` (lights `CloseButtonPointerRoot` inside `FleetPanelGui`).
---   `FleetPanelClosed` (player closed `FleetPanelGui` while on
---     `WaitDocksFleetPanel` + sub `ClosePanel`) → **`WaitDocksHire`**.
---
--- The new fleet-panel leg replaces the deleted `WaitDocksUpgradeShip`
--- leg (Dockman → free first cargo upgrade → change ship → close panel)
--- but is much simpler — there's no free upgrade hand-out and no sub-
--- step pointer chain inside the modal; the player just needs to learn
--- the panel exists and how to close it.
---
--- Other legacy action ids (`DockmanOpened`, `SelectShipOpened`,
--- `SelectShipClosed`, `ShipPanelClosed`) are still ignored — clients
--- on old builds may continue to fire them; the server silently no-ops.
function FtueService:OnFtueDocksProgress(player: Player, action: any)
	if FtueConfig.Enabled ~= true then
		return
	end
	local a = if typeof(action) == "string" then (action :: string):gsub("^%s+", ""):gsub("%s+$", "") else ""
	local st = self._oilState:GetState(player.UserId)
	if not st then
		return
	end
	local curStep = (st :: any).ftueStep

	if a == "EquipmentShopPanelClosed" then
		if curStep ~= FtueConfig.Step.WaitDocksEquipmentShop then
			return
		end
		local eqSub = player:GetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute)
		if eqSub ~= "ClosePanel" then
			return
		end
		self:_setStep(player, FtueConfig.Step.WaitDocksFleetPanel)
		--- `_setStep` cleared every other leg's sub-step but does not seed
		--- the new leg's `OpenPanel` (the entry attribute), so set it here.
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, "OpenPanel")
		fireState(player, FtueConfig.Step.WaitDocksFleetPanel)
		return
	end

	if a == "FleetPanelOpened" then
		if curStep ~= FtueConfig.Step.WaitDocksFleetPanel then
			return
		end
		local fpSub = player:GetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute)
		if fpSub ~= "OpenPanel" then
			return
		end
		player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, "ClosePanel")
		fireState(player, FtueConfig.Step.WaitDocksFleetPanel)
		return
	end

	if a == "FleetPanelClosed" then
		if curStep ~= FtueConfig.Step.WaitDocksFleetPanel then
			return
		end
		local fpSub = player:GetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute)
		if fpSub ~= "ClosePanel" then
			return
		end
		--- `WaitDocksHire` ("suspicious persons") was removed from
		--- `FtueConfig.Order` — jump straight to `Done`. The step constant,
		--- copy, portrait, and `onAcknowledge` Continue branch are intentionally
		--- left wired so the leg can be reactivated by re-adding the string to
		--- `Order` and routing this branch back to `WaitDocksHire`.
		self:_setStep(player, FtueConfig.Step.Done)
		fireState(player, FtueConfig.Step.Done)
		return
	end
end

-- `OnFtueShipCapacityUpgradeSuccess` was deleted by Step 4 of the boat-
-- progression refactor — the free first cargo upgrade leg is gone (see
-- the comment on `OnFtueDocksProgress` above).

--- Force the player onto their warehouse `WarehouseSpawn` for the
--- `WaitWarehouseSell` leg. The step can't progress unless they reach the
--- warehouse terminal, so we teleport on every entry / respawn / rejoin
--- regardless of where they currently stand.
---
--- Retries for ~5s because the warehouse visual may not be fully replicated
--- right after the boat lands (the dispatch flow tears down the ship while
--- swapping `WaitShipment → WaitWarehouseSell`).
function FtueService:_ensureAtWarehouse(player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	if not self._warehouse or typeof((self._warehouse :: any).TryTeleportPlayerToWarehouse) ~= "function" then
		ftueDbg("WaitWarehouseSell ensure-at-warehouse uid=%d skipped (no warehouse service)", player.UserId)
		return
	end
	task.spawn(function()
		for _ = 1, 12 do
			if not player.Parent then
				return
			end
			if player:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitWarehouseSell then
				return
			end
			if player.Character then
				local ok = (self._warehouse :: any):TryTeleportPlayerToWarehouse(player)
				if ok then
					ftueDbg("WaitWarehouseSell ensure-at-warehouse uid=%d teleport ok", player.UserId)
					return
				end
			end
			task.wait(0.5)
		end
		ftueDbg("WaitWarehouseSell ensure-at-warehouse uid=%d gave up (visual or character never ready)", player.UserId)
	end)
end

--- Safety net for character respawns mid-FTUE.
---
--- * `WaitShipment`: dying mid-voyage strands the player at the default spawn
---   while their boat keeps sailing. Drop them STANDING on the deck (boats no
---   longer have seats — `BoatDockService:TeleportOwnerToSeat` keeps its name
---   for callsite compatibility but resolves a stand CFrame via the rig's
---   `deckAnchor` / `barrelStackRoot`, with the literal seat as last resort).
--- * `WaitWarehouseSell`: dying after the boat lands strands them off-plot
---   with no way to reach the sell terminal. Force-teleport to
---   `WarehouseSpawn`.
---
--- Anti-thrash: if the player has hit this safety net more than a couple of
--- times in the last few seconds (almost always means they keep sliding off
--- the moving deck and dying from the kill plane), back off and let them stay
--- at home. The FTUE bumper UI will still tell them to dispatch again — better
--- a recoverable stuck-at-home than a permanent death loop.
---
--- Hooked on `Player.CharacterAdded` for both joining and existing players,
--- so this also covers rejoin (where `SyncFromOilState` sets the step
--- attribute directly without going through `_setStep`).
local _ftueRespawnReseatHistory = {} :: { [number]: { [number]: number } }
local FTUE_RESEAT_WINDOW_SEC = 8
local FTUE_RESEAT_MAX_IN_WINDOW = 2

--- Tracks whether the **generic else-branch** rejoin restore (mid-FTUE
--- `ftueLastSpawn` snapshot → HRP teleport) has already fired for this
--- player **this server session**. Set once per UserId on the **first**
--- post-PlayerAdded `CharacterAdded`; checked on every subsequent
--- `CharacterAdded` so death-respawns DO NOT re-teleport the player to a
--- stale saved CFrame (which is frequently mid-air over water — boats
--- moved, rafts despawned, etc., causing a permanent death loop where the
--- player drops into the kill plane every respawn). On death-respawn we
--- want `PlotService:_teleportCharacterToOwnedPlot` (home ClaimPad) to be
--- the final word. Cleared per-session only — fresh server = fresh
--- restore. Leak per join is intentional and matches
--- `_ftueRespawnReseatHistory` above.
local _ftueRejoinRestoreDone = {} :: { [number]: boolean }

function FtueService:_onCharacterSpawnedDuringFtue(player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local step = player:GetAttribute(Constants.FtueStepAttribute)
	if step == FtueConfig.Step.WaitShipment then
		if not (self._shipment and typeof((self._shipment :: any).HasActiveShipment) == "function") then
			return
		end
		if (self._shipment :: any):HasActiveShipment(player.UserId) ~= true then
			return
		end
		local boatDock = (self._shipment :: any)._boatDockService
		if not boatDock or typeof(boatDock.TeleportOwnerToSeat) ~= "function" then
			return
		end

		-- Anti-thrash check before the delayed re-teleport.
		local now = os.clock()
		local hist = _ftueRespawnReseatHistory[player.UserId]
		if not hist then
			hist = {}
			_ftueRespawnReseatHistory[player.UserId] = hist
		end
		local kept: { number } = {}
		for _, t in ipairs(hist) do
			if now - t < FTUE_RESEAT_WINDOW_SEC then
				table.insert(kept, t)
			end
		end
		_ftueRespawnReseatHistory[player.UserId] = kept
		if #kept >= FTUE_RESEAT_MAX_IN_WINDOW then
			ftueDbg(
				"WaitShipment respawn safety net BACKING OFF uid=%d (%d re-teleports in last %ds — likely sliding off seatless deck)",
				player.UserId, #kept, FTUE_RESEAT_WINDOW_SEC
			)
			return
		end

		-- Wait briefly for the character to fully spawn (Humanoid + parts ready)
		-- before teleporting; CharacterAdded fires before the model finishes
		-- assembling, and `TeleportOwnerToSeat` requires a live character.
		task.delay(0.25, function()
			if not player.Parent then
				return
			end
			if player:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitShipment then
				return
			end
			if (self._shipment :: any):HasActiveShipment(player.UserId) ~= true then
				return
			end
			local ok, err = boatDock:TeleportOwnerToSeat(player)
			if not ok then
				ftueDbg("WaitShipment respawn safety net failed uid=%d err=%s", player.UserId, tostring(err))
			else
				table.insert(_ftueRespawnReseatHistory[player.UserId], os.clock())
				ftueDbg("WaitShipment respawn safety net teleported uid=%d standing on boat deck", player.UserId)
			end
		end)
	elseif step == FtueConfig.Step.WaitWarehouseSell then
		-- 0.25s lead so the spawned character has a Humanoid + parts before
		-- `TryTeleportPlayerToWarehouse` runs (matches the WaitShipment delay).
		task.delay(0.25, function()
			if not player.Parent then
				return
			end
			self:_ensureAtWarehouse(player)
		end)
	elseif step == FtueConfig.Step.WaitDrillOil_WIP then
		--- Drill-leg respawn: delegate to `PlotService:RefreshSpawn`. The
		--- WaitDrillOil_WIP override inside `PlotService:_teleportCharacterToOwnedPlot`
		--- targets the highlighted starter chunk (instead of ClaimPad), so
		--- death-respawns mid-drill drop the player back on the grid. The
		--- post-teleport drift loop then defends the grid for ~150ms, which
		--- is exactly what we want — no race with our own deferred teleport
		--- (the previous implementation here used a `task.delay(0.5, …)` HRP
		--- move which the drift loop kept yanking back to ClaimPad on fresh
		--- joins where multiple `CharacterAdded` events fired in quick
		--- succession).
		self._plotService:RefreshSpawn(player)
	else
		--- Generic FTUE **rejoin-only** anchor restore. `PlotService`
		--- always teleports the freshly-spawned character to the ClaimPad on
		--- `CharacterAdded`; this handler runs from the same event but with a
		--- 0.5s defer so the ClaimPad teleport (and the 0.3s safety
		--- re-teleport inside `_teleportCharacterToOwnedPlot`) have time to
		--- finish — our re-teleport then wins the final position. Skipped for
		--- `WaitShipment` / `WaitWarehouseSell` (handled by the explicit
		--- branches above with their own destinations) and post-FTUE players
		--- (`GetFtueLastSpawnCFrame` early-outs on `ftueCompleted`).
		---
		--- **Death-respawn safety:** only fires on the FIRST CharacterAdded
		--- for this session (`_ftueRejoinRestoreDone[uid]` flag). On
		--- subsequent respawns (i.e. the player died and is being reloaded),
		--- we let `PlotService` place them at the safe home ClaimPad and do
		--- NOT re-apply the saved `ftueLastSpawn` snapshot — that snapshot is
		--- frequently a now-invalid spot (boat sailed away, raft despawned,
		--- intermediate dock cleared) and re-teleporting there drops the
		--- player into open water → kill plane → die → respawn → loop. The
		--- "rejoin to where I left off mid-FTUE" UX still works on session
		--- start; only the death-loop cycle is broken.
		if _ftueRejoinRestoreDone[player.UserId] then
			return
		end
		local oilState = self._oilState
		if not (oilState and typeof((oilState :: any).GetFtueLastSpawnCFrame) == "function") then
			return
		end
		--- Pass the player's **currently assigned** PlotId so the restore is
		--- rejected if the snapshot was captured on a different plot in a
		--- prior session — without this guard the saved world coordinates can
		--- land the player on someone else's plot after the server reassigns
		--- them on rejoin (plots are not sticky to the same UserId across
		--- server instances).
		local plotIdAttr = player:GetAttribute("PlotId")
		local currentPlotId: number? = if typeof(plotIdAttr) == "number" and plotIdAttr > 0 then plotIdAttr else nil
		local target = (oilState :: any):GetFtueLastSpawnCFrame(player.UserId, currentPlotId)
		if not target then
			return
		end
		local restoreStep = step
		task.delay(0.5, function()
			if not player.Parent then
				return
			end
			if player:GetAttribute(Constants.FtueStepAttribute) ~= restoreStep then
				return
			end
			local char = player.Character
			if not char then
				return
			end
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if not (hrp and hrp:IsA("BasePart")) then
				return
			end
			-- Match `PlotService:_teleportCharacterToOwnedPlot`: assign HRP CFrame
			-- directly (more reliable than PivotTo during character load) and zero
			-- velocities so the player doesn't inherit any momentum from the
			-- intermediate ClaimPad teleport.
			hrp.CFrame = target
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			-- Latch AFTER the teleport actually happens so a failed/cancelled
			-- restore (player left, step changed mid-defer) doesn't burn the
			-- one allowed restore for this session.
			_ftueRejoinRestoreDone[player.UserId] = true
			ftueDbg(
				"FTUE rejoin restore uid=%d step=%s -> (%.1f, %.1f, %.1f) [latched: death-respawns will use ClaimPad]",
				player.UserId, tostring(restoreStep),
				target.Position.X, target.Position.Y, target.Position.Z
			)
		end)
	end
end

function FtueService:_bindCharacterSafetyNet(player: Player)
	-- Cover the existing character (joined mid-voyage rejoin) plus future
	-- spawns (death respawn).
	if player.Character then
		self:_onCharacterSpawnedDuringFtue(player)
	end
	table.insert(
		_connections,
		player.CharacterAdded:Connect(function()
			self:_onCharacterSpawnedDuringFtue(player)
		end)
	)
end

function FtueService:Start()
	if self._drilling and typeof((self._drilling :: any).SetFtueService) == "function" then
		(self._drilling :: any):SetFtueService(self)
	end
	table.insert(_connections, Players.PlayerAdded:Connect(function(player)
		self:_bindCharacterSafetyNet(player)
		task.defer(function()
			-- Attributes are applied when oil profile loads (`OilStateService` plot assign → `SyncFromOilState`).
			if FtueConfig.Enabled ~= true then
				self:_clearRestrictionAttributes(player)
				player:SetAttribute(Constants.FtueStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
				return
			end
			for _ = 1, 160 do
				if not player.Parent then
					return
				end
				local plot = self._plotService:GetOwnedPlot(player.UserId)
				if plot and self._oilState:GetState(player.UserId) then
					self:SyncFromOilState(player.UserId)
					return
				end
				task.wait(0.25)
			end
		end)
	end))

	for _, player in Players:GetPlayers() do
		self:_bindCharacterSafetyNet(player)
		task.defer(function()
			if FtueConfig.Enabled ~= true then
				self:_clearRestrictionAttributes(player)
				player:SetAttribute(Constants.FtueStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute, nil)
				return
			end
			local plot = self._plotService:GetOwnedPlot(player.UserId)
			if plot and self._oilState:GetState(player.UserId) then
				self:SyncFromOilState(player.UserId)
			end
		end)
	end

	local ack = _remoteService:GetEvent(RemoteNames.RequestFtueAcknowledge)
	table.insert(_connections, ack.OnServerEvent:Connect(function(player: Player)
		if not (player and player:IsA("Player")) then
			return
		end
		onAcknowledge(self, player)
	end))

	local skip = _remoteService:GetEvent(RemoteNames.RequestFtueSkip)
	table.insert(_connections, skip.OnServerEvent:Connect(function(player: Player)
		if not (player and player:IsA("Player")) then
			return
		end
		onSkip(self, player)
	end))

	local docksPr = _remoteService:GetEvent(RemoteNames.RequestFtueDocksProgress)
	table.insert(_connections, docksPr.OnServerEvent:Connect(function(player: Player, action: any)
		if not (player and player:IsA("Player")) then
			return
		end
		self:OnFtueDocksProgress(player, action)
	end))

	-- Telemetry §6.2 `ftue_step_abandoned`. On disconnect, if the player
	-- is still mid-FTUE (current step is set and != Done), record the
	-- abandoned step + dwell time. The original "past Intro" guard (to
	-- skip splash-screen quitters) is gone — `Intro` was removed from
	-- `FtueConfig.Order` so every player starts past it by definition.
	-- Also clear the per-server first-fire bookkeeping tables so a
	-- returning player on a different server gets a fresh `ftue_started`
	-- / `ftue_done` / `_ftueStepEnteredAtByUserId` slate (matches the
	-- existing `ftue_done` / `ftue_started` server-lifetime contract).
	table.insert(_connections, Players.PlayerRemoving:Connect(function(player)
		pcall(function()
			if FtueConfig.Enabled == true then
				local stepRaw = player:GetAttribute(Constants.FtueStepAttribute)
				local step: string? = if typeof(stepRaw) == "string" then stepRaw else nil
				local enteredAt = _ftueStepEnteredAtByUserId[player.UserId]
				local stepOrdinal = _ftueOrdinal(step)
				if step ~= nil and step ~= FtueConfig.Step.Done then
					local secondsInStep: number? = if typeof(enteredAt) == "number" then os.clock() - enteredAt else nil
					Telemetry.Track(player, "ftue_step_abandoned", {
						stepId = step,
						funnelStep = stepOrdinal,
						secondsInStep = secondsInStep,
					})
				end
			end
		end)
		_ftueStepEnteredAtByUserId[player.UserId] = nil
		_ftueDoneFiredByUserId[player.UserId] = nil
		_ftueStartedFiredByUserId[player.UserId] = nil
		_ftueRespawnReseatHistory[player.UserId] = nil
		_ftueRejoinRestoreDone[player.UserId] = nil
	end))
end

function FtueService:Stop()
	for _, c in _connections do
		c:Disconnect()
	end
	table.clear(_connections)
end

return FtueService
