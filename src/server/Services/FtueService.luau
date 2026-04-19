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

--- Sets drill / pipe / pump restriction attributes from plot + oil state for the current step.
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
		local pipeCk = self._oilState:GetFtuePipeTutorialCellKeyForPlot(plot, st)
		if typeof(drillCk) == "string" and drillCk ~= "" then
			if not self._oilState:IsFtueDrillTutorialCellDrilled(st, drillCk) then
				player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, drillCk)
				return
			end
		end
		if typeof(pipeCk) == "string" and pipeCk ~= "" then
			if not self._oilState:HasFtueTutorialPipeAt(st, pipeCk) then
				player:SetAttribute(Constants.FtueRestrictPipeCellKeyAttribute, pipeCk)
				return
			end
		end
		if typeof(drillCk) == "string" and drillCk ~= "" then
			if not self._oilState:HasFtueTutorialPumpAt(st, drillCk) then
				player:SetAttribute(Constants.FtueRestrictPumpCellKeyAttribute, drillCk)
			end
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
	player:SetAttribute(Constants.FtueStepAttribute, step)
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
	player:SetAttribute(Constants.FtueRestrictPumpCellKeyAttribute, nil)
	player:SetAttribute(Constants.FtueRestrictPipeCellKeyAttribute, nil)
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
		fireState(player, FtueConfig.Step.Done)
		ftueDbg("SyncFromOilState uid=%d branch=show Done modal -> FtueStateUpdate(Done)", userId)
		return
	end

	local step = stepStr or FtueConfig.Step.Intro
	player:SetAttribute(Constants.FtueStepAttribute, step)
	reapplyFtueRestrictionAttributes(self, player)
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
	if step == FtueConfig.Step.WaitSell and oilStep ~= FtueConfig.Step.WaitSell then
		ftueDbg("onAcknowledge uid=%d reject WaitSell: oil.ftueStep=%s", player.UserId, tostring(oilStep))
		return
	end
	if step == FtueConfig.Step.WaitDocksShipUpgrade and oilStep ~= FtueConfig.Step.WaitDocksShipUpgrade then
		ftueDbg("onAcknowledge uid=%d reject WaitDocksShipUpgrade: oil.ftueStep=%s", player.UserId, tostring(oilStep))
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
	-- Only steps that show **Continue** in `FtueDialogueController` advance here (Intro, WaitSell, docks legs, Done).
	if step == FtueConfig.Step.Intro then
		applyWaitDrillEntry(self, player)
		self:_setStep(player, FtueConfig.Step.WaitDrillOil_WIP)
	elseif step == FtueConfig.Step.WaitSell then
		self:_setStep(player, FtueConfig.Step.WaitDocksShipUpgrade)
	elseif step == FtueConfig.Step.WaitDocksShipUpgrade then
		self:_setStep(player, FtueConfig.Step.WaitDocksHire)
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

--- After the FTUE drill completes on the tutorial tile: clear drill lock, remove starter **front** core pipe so the player can lay the tutorial segment, grant a pipe; stays on **`WaitDrillOil_WIP`**.
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
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot or not st then
		return
	end
	player:SetAttribute(Constants.FtueRestrictDrillCellKeyAttribute, nil)
	local pipeCk = self._oilState:GetFtuePipeTutorialCellKeyForPlot(plot, st)
	if pipeCk then
		local existing = st.pipesByCellKey and st.pipesByCellKey[pipeCk]
		if existing and existing.isCorePipe == true then
			st.pipesByCellKey[pipeCk] = nil
		end
		player:SetAttribute(Constants.FtueRestrictPipeCellKeyAttribute, pipeCk)
	end
	self._equipmentShop:GrantFreeOwnedEquipment(player, FtueConfig.PipeItemId, 1)
	self:SetStep(player, FtueConfig.Step.WaitDrillOil_WIP)
end

--- After the tutorial pipe segment is placed on the locked cell: grant pump, stay on **`WaitDrillOil_WIP`**.
function FtueService:OnFtueTutorialPipePlaced(userId: number, placedCellKey: string)
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
	local step = (st :: any).ftueStep
	if step ~= FtueConfig.Step.WaitDrillOil_WIP then
		return
	end
	local want = player:GetAttribute(Constants.FtueRestrictPipeCellKeyAttribute)
	if typeof(want) ~= "string" or want == "" or want ~= placedCellKey then
		return
	end
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		return
	end
	player:SetAttribute(Constants.FtueRestrictPipeCellKeyAttribute, nil)
	local pumpCk = self._oilState:GetFtueDrillTargetCellKeyForPlot(plot, st, userId)
	if pumpCk then
		player:SetAttribute(Constants.FtueRestrictPumpCellKeyAttribute, pumpCk)
	end
	self._equipmentShop:GrantFreeOwnedEquipment(player, FtueConfig.PumpItemId, 1)
	self:SetStep(player, FtueConfig.Step.WaitDrillOil_WIP)
end

--- After the tutorial pump is placed on the drilled tile: first oil collection leg done → **`WaitPlotShipment`** (cash grant inside `_setStep`).
function FtueService:OnFtueTutorialPumpPlaced(userId: number, placedCellKey: string)
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
	if (st :: any).ftueStep ~= FtueConfig.Step.WaitDrillOil_WIP then
		return
	end
	local want = player:GetAttribute(Constants.FtueRestrictPumpCellKeyAttribute)
	if typeof(want) ~= "string" or want == "" or want ~= placedCellKey then
		return
	end
	player:SetAttribute(Constants.FtueRestrictPumpCellKeyAttribute, nil)
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
end

function FtueService:Stop()
	for _, c in _connections do
		c:Disconnect()
	end
	table.clear(_connections)
end

return FtueService
