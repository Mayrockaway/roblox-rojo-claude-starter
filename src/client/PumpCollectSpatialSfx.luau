--!strict
-- Continuous spatial pump-collect SFX.
--
-- Listens for `DrillProgressUpdate { kind = "pumpCollected", ownerUserId,
-- pumpId }` packets fired by `OilProductionService:_runTick` (one per
-- successfully-producing pump per tick). The first ping for a pump creates a
-- single looped, spatial `Sound` parented to the pump model under
-- `Workspace.Map.Plots.<plot>.OilVisuals.Drills.Drill_<pumpId>`. Subsequent
-- pings refresh a "last seen" timestamp; a Heartbeat-driven sweep tears the
-- Sound down if the pump stops producing (no ping for `LIVENESS_TIMEOUT_SEC`),
-- e.g. tank full, no drilled tiles, plot unloaded, pump destroyed.
--
-- Net effect: audio plays continuously while a pump is producing (as soon as
-- the first tile is hooked up) and stops when production stops. No START/STOP
-- remote needed -- the existing per-tick stream doubles as a heartbeat.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PUMP_COLLECT_SOUND_ID = "rbxassetid://110594239472526"
local VOLUME = 0.3
--- Tight rolloff so the spatial fall-off is obvious -- audible while standing
--- on top of the pump, gone by the time you walk to a neighboring rig.
local ROLLOFF_MAX = 60
local ROLLOFF_MIN = 8
local EMITTER_SIZE = 8
local ROLLOFF_MODE = Enum.RollOffMode.InverseTapered

--- If we don't get a ping for this long, the pump has stopped producing
--- (tank full, no drilled tiles, etc.) -- stop and destroy the loop. The
--- production tick is ~1s, so 2.5s tolerates one missed tick from a server
--- hitch without flickering the audio off.
local LIVENESS_TIMEOUT_SEC = 2.5
local SWEEP_INTERVAL_SEC = 0.5

type Active = {
	sound: Sound,
	host: Instance,
	lastPingAt: number,
}

local active: { [string]: Active } = {}

local function pumpKey(ownerUserId: number, pumpId: number): string
	return tostring(ownerUserId) .. ":" .. tostring(pumpId)
end

local function isSfxEnabled(): boolean
	local ok, result = pcall(function()
		local prefs = require(script.Parent:WaitForChild("ClientAudioPreferences", 5)) :: any
		if prefs and typeof(prefs.isSfxEnabled) == "function" then
			return prefs.isSfxEnabled() == true
		end
		return true
	end)
	if not ok then return true end
	return result
end

local function findPlotForOwner(ownerUserId: number): Model?
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, p in ipairs(plots:GetChildren()) do
		if p:IsA("Model") and p:GetAttribute("OwnerUserId") == ownerUserId then
			return p
		end
	end
	return nil
end

local function findPumpModel(ownerUserId: number, pumpId: number): Instance?
	local plot = findPlotForOwner(ownerUserId)
	if not plot then
		return nil
	end
	local vis = plot:FindFirstChild("OilVisuals")
	local folder = vis and vis:FindFirstChild("Drills")
	if not folder then
		return nil
	end
	return folder:FindFirstChild("Drill_" .. tostring(pumpId))
end

local function findSpatialHost(model: Instance): Instance?
	if model:IsA("Model") then
		local pp = model.PrimaryPart
		if pp and pp:IsA("BasePart") then
			return pp
		end
		local part = model:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
		return model:FindFirstChildWhichIsA("Attachment", true)
	elseif model:IsA("BasePart") then
		return model
	end
	return nil
end

local function stopAndClear(key: string)
	local entry = active[key]
	if not entry then return end
	active[key] = nil
	if entry.sound then
		pcall(function()
			entry.sound:Stop()
			entry.sound:Destroy()
		end)
	end
end

local function ensureLoop(ownerUserId: number, pumpId: number)
	local key = pumpKey(ownerUserId, pumpId)
	local now = os.clock()
	local entry = active[key]

	--- Existing entry: refresh ping, repair if model/sound got destroyed
	--- behind our back (e.g. plot reloaded). If the sound's host is still
	--- valid we just bump lastPingAt and return.
	if entry then
		entry.lastPingAt = now
		if entry.sound and entry.sound.Parent and entry.host and entry.host.Parent then
			if not entry.sound.IsPlaying then
				pcall(function() entry.sound:Play() end)
			end
			return
		end
		stopAndClear(key)
	end

	local model = findPumpModel(ownerUserId, pumpId)
	if not model then
		return
	end
	local host = findSpatialHost(model)
	if not host then
		return
	end

	local snd = Instance.new("Sound")
	snd.Name = "PumpCollectSpatialSfx"
	snd.SoundId = PUMP_COLLECT_SOUND_ID
	snd.Volume = VOLUME
	snd.Looped = true
	snd.RollOffMode = ROLLOFF_MODE
	snd.RollOffMaxDistance = ROLLOFF_MAX
	snd.RollOffMinDistance = ROLLOFF_MIN
	snd.EmitterSize = EMITTER_SIZE
	snd.Parent = host
	snd:Play()

	active[key] = {
		sound = snd,
		host = host,
		lastPingAt = now,
	}
end

local function startSweep()
	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < SWEEP_INTERVAL_SEC then
			return
		end
		accum = 0
		local now = os.clock()
		for key, entry in pairs(active) do
			local stale = (now - entry.lastPingAt) > LIVENESS_TIMEOUT_SEC
			local hostGone = not (entry.host and entry.host.Parent)
			local soundGone = not (entry.sound and entry.sound.Parent)
			if stale or hostGone or soundGone then
				stopAndClear(key)
			end
		end
	end)
end

local PumpCollectSpatialSfx = {}

function PumpCollectSpatialSfx.start(drillProgressUpdate: RemoteEvent)
	startSweep()
	drillProgressUpdate.OnClientEvent:Connect(function(data: any)
		if typeof(data) ~= "table" or data.kind ~= "pumpCollected" then
			return
		end
		local ownerUserId = tonumber(data.ownerUserId)
		local pumpId = tonumber(data.pumpId)
		if not ownerUserId or not pumpId then
			return
		end
		--- SFX-disabled: tear down any active loops for this packet's pump
		--- so the user actually goes silent the moment they toggle SFX off
		--- mid-session, not just on the next sweep cycle.
		if not isSfxEnabled() then
			stopAndClear(pumpKey(ownerUserId, pumpId))
			return
		end
		ensureLoop(ownerUserId, pumpId)
	end)
end

return PumpCollectSpatialSfx
