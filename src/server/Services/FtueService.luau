--!strict
-- First-time user experience: drives `Player` attributes (`FtueStep`, optional cell keys) and
-- notifies clients via `FtueStateUpdate`. Progress is persisted on `OilStateService` (`ftueStep`).

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local FtueService = {}

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
	if not st or st.ftueDispatchCashGranted == true then
		return
	end
	local amt = floorPositive(tonumber(FtueConfig.PlotShipmentStageCashReward) or 0)
	if amt <= 0 then
		return
	end
	st.ftueDispatchCashGranted = true
	oil:AddCash(player.UserId, amt)
	oil:PushState(player.UserId)
end

--- One-time cash when entering `Done` (see `FtueConfig.TutorialCompleteCashReward`).
local function grantTutorialCompleteCashIfNeeded(self: any, player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local oil = self._oilState
	if not oil then
		return
	end
	local st = oil:GetState(player.UserId)
	if not st or (st :: any).ftueTutorialCompleteCashGranted == true then
		return
	end
	local amt = floorPositive(tonumber(FtueConfig.TutorialCompleteCashReward) or 0)
	if amt <= 0 then
		return
	end
	(st :: any).ftueTutorialCompleteCashGranted = true
	oil:AddCash(player.UserId, amt)
	oil:PushState(player.UserId)
end

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
		local drillCk = self._oilState:GetFtueDrillTargetCellKeyForPlot(plot, st, player.UserId)
		if typeof(drillCk) == "string" and drillCk ~= "" then
			if not self._oilState:IsFtueDrillTutorialCellDrilled(st, drillCk) then
				player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, drillCk)
			end
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
		local enableMarker = (step == FtueConfig.Step.WaitDrillOil_WIP)
			or (step == FtueConfig.Step.WaitReveal)
		;(self._oilState :: any):SetFtueTutorialTileMarker(player.UserId, enableMarker)
	end
	player:SetAttribute(Constants.FtueStepAttribute, step)
	if typeof(step) ~= "string" or step ~= FtueConfig.Step.WaitDocksUpgradeShip then
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
		--- Mirror the clear into oil state so the persisted sub-step never lingers
		--- past the leg it belongs to (a save flush mid-transition could otherwise
		--- restore a stale value on the next rejoin).
		if self._oilState and typeof((self._oilState :: any).SetFtueDocksUpgradeSubStep) == "function" then
			(self._oilState :: any):SetFtueDocksUpgradeSubStep(player.UserId, nil)
		end
	end
	if typeof(step) ~= "string" or step ~= FtueConfig.Step.WaitDocksEquipmentShop then
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
	end
	fireState(player, step)
	ftueDbg(
		"_setStep uid=%d -> FtueStateUpdate(%s) SetAttribute(FtueStep)",
		player.UserId,
		step == nil and "nil" or tostring(step)
	)
	ftueDumpOilState(self._oilState, player, "_setStep after")
end

function FtueService:_clearRestrictionAttributes(player: Player)
	player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, nil)
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
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
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
		--- Clear both leg sub-steps too: they should never replicate to the
		--- client past the FTUE itself (stale value would re-show old pointers).
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
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
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
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
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
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
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
		player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
		fireState(player, FtueConfig.Step.Done)
		ftueDbg("SyncFromOilState uid=%d branch=show Done modal -> FtueStateUpdate(Done)", userId)
		return
	end

	local step = stepStr or FtueConfig.Step.Intro

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

	reapplyFtueRestrictionAttributes(self, player)
	--- Re-stamp the BasePart marker on rejoin so the per-plot WaitReveal beam and
	--- tile highlight resolve to the correct tile without waiting for a step change.
	if self._oilState and typeof((self._oilState :: any).SetFtueTutorialTileMarker) == "function" then
		local enableMarker = (step == FtueConfig.Step.WaitDrillOil_WIP)
			or (step == FtueConfig.Step.WaitReveal)
		;(self._oilState :: any):SetFtueTutorialTileMarker(userId, enableMarker)
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
	--- Re-arm the dock-ship sub-step on rejoin from the persisted oil-state value
	--- so the player resumes on the same beam (Dockman) / cargo-buy pointer
	--- (`CargoBuy`) / close pointer (`CloseModal`) they last saw. Default to
	--- `Dockman` if the player is in the leg but the persisted sub is missing
	--- (legacy save without the field) so the dockman beam still resolves.
	if step == FtueConfig.Step.WaitDocksUpgradeShip then
		local subAny = (st :: any).ftueDocksUpgradeSubStep
		local sub = if typeof(subAny) == "string" then (subAny :: string) else nil
		if sub ~= "Dockman" and sub ~= "CargoBuy" and sub ~= "CloseModal" then
			sub = "Dockman"
			--- Backfill so the next save round-trip keeps the recovered sub-step.
			if self._oilState and typeof((self._oilState :: any).SetFtueDocksUpgradeSubStep) == "function" then
				(self._oilState :: any):SetFtueDocksUpgradeSubStep(userId, sub)
			end
		end
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, sub)
	else
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
	end
	fireState(player, step)
	ftueDbg("SyncFromOilState uid=%d branch=midFlow -> FtueStateUpdate(%s)", userId, step)
end

local function applyWaitDrillEntry(self: any, player: Player)
	local function tryGrant(): boolean
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		if not plot then
			return false
		end
		local st = self._oilState:GetState(player.UserId)
		if not st then
			return false
		end
		local ck = self._oilState:GetFtueDrillTargetCellKeyForPlot(plot, st, player.UserId)
		if ck then
			player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, ck)
		end
		self._equipmentShop:GrantFreeOwnedEquipment(player, FtueConfig.DrillItemId, 1)
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
	_market: any
)
	_remoteService = remoteService
	self._plotService = _plotService
	self._oilState = _oilState
	self._equipmentShop = _equipmentShop
	self._drilling = _drilling
	self._shipment = _shipment
	self._market = _market
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
	local wantDrill = player:GetAttribute(Constants.FtueRestrictDrillCellKeyAttribute)
	if typeof(wantDrill) == "string" and wantDrill ~= "" then
		local ck = if typeof(done) == "table" then (done :: any).cellKey else nil
		if typeof(ck) == "string" and ck ~= wantDrill then
			return
		end
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

--- FTUE docks sub-leg: `DockmanOpened` → `CargoBuy`; `ShipPanelClosed` (after upgrade + close UI) → **`WaitDocksHire`**.
--- Equipment shop leg: `EquipmentShopPanelClosed` (after free drill purchased) → **`WaitDocksUpgradeShip` (Dockman)`**.
function FtueService:OnFtueDocksProgress(player: Player, action: any)
	if FtueConfig.Enabled ~= true then
		return
	end
	local a = if typeof(action) == "string" then (action :: string):gsub("^%s+", ""):gsub("%s+$", "") else ""
	if a == "" then
		return
	end
	local st = self._oilState:GetState(player.UserId)
	if not st then
		return
	end
	--- Equipment shop close branch lives in its own step; handle and return so the
	--- existing `WaitDocksUpgradeShip` guard below stays untouched.
	if a == "EquipmentShopPanelClosed" then
		if (st :: any).ftueStep ~= FtueConfig.Step.WaitDocksEquipmentShop then
			return
		end
		local eqSub = player:GetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute)
		if eqSub ~= "ClosePanel" then
			return
		end
		self:_setStep(player, FtueConfig.Step.WaitDocksUpgradeShip)
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, "Dockman")
		;(self._oilState :: any):SetFtueDocksUpgradeSubStep(player.UserId, "Dockman")
		fireState(player, FtueConfig.Step.WaitDocksUpgradeShip)
		return
	end
	if (st :: any).ftueStep ~= FtueConfig.Step.WaitDocksUpgradeShip then
		return
	end
	local sub = player:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute)
	if a == "DockmanOpened" then
		if sub ~= "Dockman" then
			return
		end
		player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, "CargoBuy")
		;(self._oilState :: any):SetFtueDocksUpgradeSubStep(player.UserId, "CargoBuy")
		fireState(player, FtueConfig.Step.WaitDocksUpgradeShip)
		--- `OilStateService` snapshot `upgradeShipCapacityCost` reads this attribute; push immediately so
		--- Ship Management's first `InvokeServer` sees **$0** (free FTUE upgrade) instead of a stale price.
		if typeof((self._oilState :: any).PushState) == "function" then
			(self._oilState :: any):PushState(player.UserId)
		end
	elseif a == "ShipPanelClosed" then
		if sub ~= "CloseModal" then
			return
		end
		self:_setStep(player, FtueConfig.Step.WaitDocksHire)
	else
		return
	end
end

--- After first free cargo upgrade succeeds during **`WaitDocksUpgradeShip`** (`CargoBuy` sub-step).
function FtueService:OnFtueShipCapacityUpgradeSuccess(player: Player)
	if FtueConfig.Enabled ~= true then
		return
	end
	local st = self._oilState:GetState(player.UserId)
	if not st or (st :: any).ftueStep ~= FtueConfig.Step.WaitDocksUpgradeShip then
		return
	end
	if player:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute) ~= "CargoBuy" then
		return
	end
	player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, "CloseModal")
	;(self._oilState :: any):SetFtueDocksUpgradeSubStep(player.UserId, "CloseModal")
	fireState(player, FtueConfig.Step.WaitDocksUpgradeShip)
end

function FtueService:Start()
	if self._drilling and typeof((self._drilling :: any).SetFtueService) == "function" then
		(self._drilling :: any):SetFtueService(self)
	end
	table.insert(_connections, Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			-- Attributes are applied when oil profile loads (`OilStateService` plot assign → `SyncFromOilState`).
			if FtueConfig.Enabled ~= true then
				self:_clearRestrictionAttributes(player)
				player:SetAttribute(Constants.FtueStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
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
		task.defer(function()
			if FtueConfig.Enabled ~= true then
				self:_clearRestrictionAttributes(player)
				player:SetAttribute(Constants.FtueStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksUpgradeSubStepAttribute, nil)
				player:SetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute, nil)
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
end

function FtueService:Stop()
	for _, c in _connections do
		c:Disconnect()
	end
	table.clear(_connections)
end

return FtueService
