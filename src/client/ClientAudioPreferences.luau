--!strict
-- Per-client audio: background music (`BgmPlayer`) and **global SFX mute**.
--
-- SFX off = zero volume on every `Sound` in the live game tree **except** the client BGM clone
-- (`SoundService.OTS_ClientBGM`). Catch-all: no hard-coded asset IDs — new one-shots / spatial /
-- workspace sounds are muted via sweep + listeners while the toggle is off.
--
-- Optional: set attribute `TreatAsBackgroundMusic = true` on a `Sound` to exempt it from SFX mute.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local BgmPlayer = require(script.Parent:WaitForChild("BgmPlayer"))

local BGM_CLONE_NAME = "OTS_ClientBGM"

local musicEnabled = true
local sfxEnabled = true

--- First-seen volume per Sound (non-exempt) for restore when SFX is turned back on.
local originalVolume: { [Sound]: number } = {}

local mutePollAccumulator = 0
local mutePollConn: RBXScriptConnection? = nil
local muteDescConns: { RBXScriptConnection } = {}
local started = false

local POLL_INTERVAL_SEC = 0.12

local function isExcludedFromSfxMute(s: Sound): boolean
	if s.Name == BGM_CLONE_NAME then
		return true
	end
	if s:GetAttribute("TreatAsBackgroundMusic") == true then
		return true
	end
	return false
end

local function rememberOriginal(s: Sound)
	if originalVolume[s] == nil then
		originalVolume[s] = s.Volume
	end
end

local function sweepRoots(): { Instance }
	local roots: { Instance } = {}
	table.insert(roots, SoundService)
	table.insert(roots, Workspace)
	table.insert(roots, game:GetService("Debris"))
	local lp = Players.LocalPlayer
	if lp then
		table.insert(roots, lp)
	end
	local cam = Workspace.CurrentCamera
	if cam then
		table.insert(roots, cam)
	end
	return roots
end

local function muteOneSound(s: Sound)
	if isExcludedFromSfxMute(s) then
		return
	end
	rememberOriginal(s)
	s.Volume = 0
end

--- Apply Volume=0 to all non-BGM sounds under known playback roots (nested `SoundService`, camera FX, etc.).
local function applySfxMuteSweep()
	if sfxEnabled then
		return
	end
	for _, root in ipairs(sweepRoots()) do
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("Sound") then
				muteOneSound(inst :: Sound)
			end
		end
	end
end

local function disconnectMuteHooks()
	for _, c in ipairs(muteDescConns) do
		c:Disconnect()
	end
	table.clear(muteDescConns)
	if mutePollConn then
		mutePollConn:Disconnect()
		mutePollConn = nil
	end
	mutePollAccumulator = 0
end

local function onPossibleSoundAdded(inst: Instance)
	if not inst:IsA("Sound") then
		return
	end
	task.defer(function()
		if sfxEnabled then
			return
		end
		muteOneSound(inst :: Sound)
	end)
end

--- While SFX is off: poll for scripts that bump `Volume`, and catch new instances anywhere under roots.
local function connectMuteHooks()
	disconnectMuteHooks()

	for _, root in ipairs(sweepRoots()) do
		table.insert(muteDescConns, root.DescendantAdded:Connect(onPossibleSoundAdded))
	end

	mutePollConn = RunService.Heartbeat:Connect(function(dt: number)
		if sfxEnabled then
			return
		end
		mutePollAccumulator += dt
		if mutePollAccumulator >= POLL_INTERVAL_SEC then
			mutePollAccumulator = 0
			applySfxMuteSweep()
		end
	end)
end

local function restoreSfxVolumes()
	local dead: { Sound } = {}
	for s, vol in pairs(originalVolume) do
		if s.Parent and not isExcludedFromSfxMute(s) then
			s.Volume = vol
		else
			table.insert(dead, s)
		end
	end
	for _, s in ipairs(dead) do
		originalVolume[s] = nil
	end
end

local function syncPlayerAttribute()
	local lp = Players.LocalPlayer
	if lp then
		lp:SetAttribute("SFXEnabled", sfxEnabled)
	end
end

local function syncBgmIfPresent()
	BgmPlayer.setMusicEnabled(musicEnabled)
end

local ClientAudioPreferences = {}

function ClientAudioPreferences.init()
	if started then
		return
	end
	started = true

	syncPlayerAttribute()

	if SoundService:FindFirstChild(BGM_CLONE_NAME) then
		syncBgmIfPresent()
	end
	SoundService.ChildAdded:Connect(function(ch)
		if ch.Name == BGM_CLONE_NAME and ch:IsA("Sound") then
			syncBgmIfPresent()
		end
	end)
end

function ClientAudioPreferences.setMusicEnabled(enabled: boolean)
	musicEnabled = enabled
	BgmPlayer.setMusicEnabled(enabled)
end

function ClientAudioPreferences.setSfxEnabled(enabled: boolean)
	if sfxEnabled == enabled then
		return
	end
	sfxEnabled = enabled
	syncPlayerAttribute()

	if enabled then
		disconnectMuteHooks()
		restoreSfxVolumes()
	else
		applySfxMuteSweep()
		connectMuteHooks()
	end
end

function ClientAudioPreferences.isMusicEnabled(): boolean
	return musicEnabled
end

function ClientAudioPreferences.isSfxEnabled(): boolean
	return sfxEnabled
end

return ClientAudioPreferences
