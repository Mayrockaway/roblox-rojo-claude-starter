--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))

local AdminService = {}

local FORCE_CLOSE_COOLDOWN_SECONDS = 120
local FORCE_CLOSE_DEFAULT_DURATION_SECONDS = 90

function AdminService:Init(remoteService, straitStateService, rateLimitService)
	self._remoteService = remoteService
	self._straitStateService = straitStateService
	self._rateLimitService = rateLimitService
	self._connections = {}
	self._lastForceCloseAt = 0
end

function AdminService:Start()
	local requestAdmin = self._remoteService:GetEvent(RemoteNames.RequestAdminForceClose)
	table.insert(self._connections, requestAdmin.OnServerEvent:Connect(function(player, payload)
		self:_onRequestForceClose(player, payload)
	end))
end

function AdminService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function AdminService:_onRequestForceClose(player: Player, payload)
	if not self._rateLimitService:Allow(player.UserId, "force_close", 6) then
		self:_sendActionResult(player, false, ErrorCodes.RateLimited, "Too many force-close requests.")
		return
	end

	if not self:_isAuthorized(player) then
		self:_sendActionResult(player, false, ErrorCodes.NoPermission, "You do not have permission.")
		return
	end

	local now = workspace:GetServerTimeNow()
	if now - self._lastForceCloseAt < FORCE_CLOSE_COOLDOWN_SECONDS then
		self:_sendActionResult(player, false, ErrorCodes.Busy, "Force close cooldown active.")
		return
	end

	local duration = FORCE_CLOSE_DEFAULT_DURATION_SECONDS
	if typeof(payload) == "table" and tonumber(payload.durationSeconds) ~= nil then
		duration = math.clamp(math.floor(tonumber(payload.durationSeconds)), 20, 600)
	end

	self._lastForceCloseAt = now
	self._straitStateService:ForceCloseForDuration(duration)
	-- `admin_force_close` was a dev-only event not in the SPEC §6 catalog;
	-- the resulting state change is already captured by
	-- `strait_force_lock` (fired from `StraitStateService:ForceStateForDuration`
	-- via `ForceCloseForDuration`), so we don't double-fire here.
	self:_sendActionResult(player, true, ErrorCodes.Ok, "Strait force-closed.", {
		durationSeconds = duration,
	})
end

function AdminService:_isAuthorized(player: Player): boolean
	-- Creator in team test or studio owner account is allowed.
	if game.CreatorType == Enum.CreatorType.User and game.CreatorId == player.UserId then
		return true
	end
	if player.UserId < 0 then
		return true
	end
	return false
end

function AdminService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.ActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

return AdminService
