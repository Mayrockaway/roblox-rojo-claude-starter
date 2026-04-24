--!strict
--[[
	AutoShipService — server-side auto-dispatch loop for the AutoShip GamePass.

	When a player owns the AutoShip GamePass and enables it, this service
	automatically builds a manifest (greedy-filled by the player's chosen
	priority: Most Valuable or Least Valuable oil first), dispatches via the
	existing OilShipmentService code path, and re-dispatches whenever the
	boat returns to idle.

	State is in-memory only — resets on logout (no offline auto-shipping).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local TIER_MOST_VALUABLE = { "Premium", "Refined", "Crude" }
local TIER_LEAST_VALUABLE = { "Crude", "Refined", "Premium" }

type AutoShipEntry = {
	enabled: boolean,
	priority: string, -- "MostValuable" | "LeastValuable"
}

local AutoShipService = {}

AutoShipService._remoteService = nil :: any
AutoShipService._oilStateService = nil :: any
AutoShipService._warehouseService = nil :: any
AutoShipService._boatDockService = nil :: any
AutoShipService._oilShipmentService = nil :: any
AutoShipService._monetizationService = nil :: any
AutoShipService._autoShipByUser = {} :: { [number]: AutoShipEntry }
AutoShipService._devBypassUsers = {} :: { [number]: boolean }
AutoShipService._connections = {} :: { RBXScriptConnection }

function AutoShipService:Init(
	remoteService: any,
	oilStateService: any,
	warehouseService: any,
	boatDockService: any,
	oilShipmentService: any,
	monetizationService: any
)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._warehouseService = warehouseService
	self._boatDockService = boatDockService
	self._oilShipmentService = oilShipmentService
	self._monetizationService = monetizationService
	self._autoShipByUser = {}
	self._connections = {}
end

function AutoShipService:Start()
	local setEvent = self._remoteService:GetEvent(RemoteNames.RequestSetAutoShip)
	table.insert(self._connections, setEvent.OnServerEvent:Connect(function(player: Player, payload: any)
		self:_onSetAutoShip(player, payload)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		self._autoShipByUser[player.UserId] = nil
	end))

	-- Register the idle callback so we auto-dispatch when a ship returns.
	self._boatDockService:SetOnBoatBecameIdleCallback(function(userId: number)
		self:OnBoatBecameIdle(userId)
	end)
end

function AutoShipService:Stop()
	for _, conn in ipairs(self._connections) do
		pcall(function() conn:Disconnect() end)
	end
	self._connections = {}
	self._autoShipByUser = {}
end

function AutoShipService:_pushState(userId: number, stoppedReason: string?)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end
	local entry = self._autoShipByUser[userId]
	local ev = self._remoteService:GetEvent(RemoteNames.AutoShipStateUpdate)
	ev:FireClient(player, {
		enabled = entry and entry.enabled or false,
		priority = entry and entry.priority or nil,
		stoppedReason = stoppedReason,
	})
end

function AutoShipService:_onSetAutoShip(player: Player, payload: any)
	if typeof(payload) ~= "table" then return end
	local userId = player.UserId

	local wantEnabled = payload.enabled == true

	if not wantEnabled then
		-- Toggle off
		self._autoShipByUser[userId] = nil
		self:_pushState(userId)
		if RunService:IsStudio() then
			print(string.format("[AutoShip] %s disabled AutoShip", player.Name))
		end
		return
	end

	-- Enabling: validate GamePass ownership (dev bypass for /autoship command)
	if not self._devBypassUsers[userId] and not self._monetizationService:HasGamePassEffect(player, "AutoShip") then
		self:_pushState(userId)
		return
	end

	local priority = payload.priority
	if priority ~= "MostValuable" and priority ~= "LeastValuable" then
		return
	end

	self._autoShipByUser[userId] = { enabled = true, priority = priority }
	self:_pushState(userId)
	if RunService:IsStudio() then
		print(string.format("[AutoShip] %s enabled AutoShip (priority=%s)", player.Name, priority))
	end
	-- Telemetry §6.7 `auto_ship_engaged`. Fires only when the toggle
	-- transitions to `enabled = true` AND the gamepass / dev-bypass
	-- gates pass, so we don't log a row for a denied-without-gamepass
	-- click.
	pcall(function()
		Telemetry.Track(player, "auto_ship_engaged", {
			priority = priority,
			devBypass = self._devBypassUsers[userId] == true,
		})
	end)

	-- Immediate dispatch if boat is already idle
	if self._boatDockService:IsIdle(userId) then
		task.defer(function()
			self:_tryAutoDispatch(userId)
		end)
	end
end

function AutoShipService:OnBoatBecameIdle(userId: number)
	local entry = self._autoShipByUser[userId]
	if not entry or not entry.enabled then return end
	-- Small delay so the boat state fully settles after CheckinBoat.
	task.delay(1, function()
		self:_tryAutoDispatch(userId)
	end)
end

function AutoShipService:_buildAutoManifest(userId: number, priority: string): { [string]: number }?
	local state = self._oilStateService:GetState(userId)
	if not state then return nil end

	local oilByTier = state.oilByTier
	if typeof(oilByTier) ~= "table" then return nil end

	-- Ship capacity. Boat progression refactor (Step 2): capacity is read
	-- from the equipped boat's catalog entry via `ResolveForBoat` instead
	-- of the legacy profile `shipCapacityLevel` (which is stat-inert
	-- post-Step 2). This keeps the auto-dispatch capacity check in sync
	-- with the dispatch-time check inside `OilShipmentService._handleDispatch`.
	local boatId = (typeof(state.equippedBoatId) == "string" and BoatCatalog.Boats[state.equippedBoatId] and state.equippedBoatId)
		or "Tier1Boat"
	local stats = ShipStats.ResolveForBoat(boatId)
	local shipCap = stats.capacity

	-- Warehouse remaining room
	local whCap = self._warehouseService:GetCapacity(userId)
	local whTotal = self._warehouseService:GetTotalBarrels(userId)
	local whRoom = math.max(0, whCap - whTotal)

	local effectiveCap = math.min(shipCap, whRoom)
	if effectiveCap <= 0 then return nil end

	local tierOrder = if priority == "LeastValuable" then TIER_LEAST_VALUABLE else TIER_MOST_VALUABLE
	local manifest: { [string]: number } = {}
	local remaining = effectiveCap

	for _, tier in ipairs(tierOrder) do
		local available = math.floor(oilByTier[tier] or 0)
		if available > 0 and remaining > 0 then
			local take = math.min(available, remaining)
			manifest[tier] = take
			remaining -= take
		end
	end

	-- Check total
	local total = 0
	for _, v in pairs(manifest) do total += v end
	if total == 0 then return nil end

	return manifest
end

function AutoShipService:_tryAutoDispatch(userId: number)
	local entry = self._autoShipByUser[userId]
	if not entry or not entry.enabled then return end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		self._autoShipByUser[userId] = nil
		return
	end

	-- Re-check GamePass ownership (in case of refund; dev bypass for /autoship)
	if not self._devBypassUsers[userId] and not self._monetizationService:HasGamePassEffect(player, "AutoShip") then
		self:_stopAutoShip(userId, "NOT_OWNED")
		return
	end

	-- Check boat is idle
	if not self._boatDockService:IsIdle(userId) then
		return -- will retry when OnBoatBecameIdle fires
	end

	-- Check warehouse capacity
	local whCap = self._warehouseService:GetCapacity(userId)
	local whTotal = self._warehouseService:GetTotalBarrels(userId)
	if whTotal >= whCap then
		-- Telemetry §6.7 `auto_ship_skipped` (warehouse full). Fired
		-- before `_stopAutoShip` because the latter clears the entry
		-- and we still want the skip-reason row keyed to the player.
		pcall(function()
			Telemetry.Track(player, "auto_ship_skipped", {
				reason = "WAREHOUSE_FULL",
				priority = entry.priority,
			})
		end)
		self:_stopAutoShip(userId, "WAREHOUSE_FULL")
		return
	end

	-- Build manifest
	local manifest = self:_buildAutoManifest(userId, entry.priority)
	if not manifest then
		pcall(function()
			Telemetry.Track(player, "auto_ship_skipped", {
				reason = "NO_OIL",
				priority = entry.priority,
			})
		end)
		self:_stopAutoShip(userId, "NO_OIL")
		return
	end

	-- Dispatch through the normal code path
	local ok = self._oilShipmentService:DispatchForAutoShip(player, manifest)
	if not ok then
		pcall(function()
			Telemetry.Track(player, "auto_ship_skipped", {
				reason = "DISPATCH_FAILED",
				priority = entry.priority,
			})
		end)
		self:_stopAutoShip(userId, "DISPATCH_FAILED")
		return
	end

	-- Telemetry §6.7 `auto_ship_dispatched`. Fired only after
	-- `DispatchForAutoShip` returns true so we don't double-log a
	-- shipment that the dispatch path itself rejected.
	pcall(function()
		local barrels = 0
		for _, count in pairs(manifest) do
			barrels += count
		end
		Telemetry.Track(player, "auto_ship_dispatched", {
			priority = entry.priority,
			barrels = barrels,
			manifest = manifest,
		})
	end)

	if RunService:IsStudio() then
		print(string.format("[AutoShip] Auto-dispatched for %s (priority=%s)", player.Name, entry.priority))
	end
end

--- Returns true if this user has an active AutoShip session. Used by
--- OilShipmentService to skip the owner-teleport-to-ship during auto-dispatch.
function AutoShipService:IsActive(userId: number): boolean
	local entry = self._autoShipByUser[userId]
	return entry ~= nil and entry.enabled
end

function AutoShipService:_stopAutoShip(userId: number, reason: string)
	self._autoShipByUser[userId] = nil
	self:_pushState(userId, reason)

	local player = Players:GetPlayerByUserId(userId)
	if player then
		local msg
		if reason == "NO_OIL" then
			msg = "AutoShip stopped: no oil available on your plot."
		elseif reason == "WAREHOUSE_FULL" then
			msg = "AutoShip stopped: warehouse is full."
		elseif reason == "DISPATCH_FAILED" then
			msg = "AutoShip stopped: dispatch failed (not enough cash?)."
		elseif reason == "NOT_OWNED" then
			msg = "AutoShip stopped: GamePass no longer owned."
		else
			msg = "AutoShip stopped."
		end
		local ev = self._remoteService:GetEvent(RemoteNames.OilActionResult)
		ev:FireClient(player, { ok = false, code = reason, message = msg })
		if RunService:IsStudio() then
			print(string.format("[AutoShip] Stopped for %s: %s", player.Name, reason))
		end
	end
end

return AutoShipService
