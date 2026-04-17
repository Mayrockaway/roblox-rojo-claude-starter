--!strict
-- Per-client audio preferences: background music (`BgmPlayer`) and global SFX mute (all other `Sound` instances).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local BgmPlayer = require(script.Parent:WaitForChild("BgmPlayer"))

local BGM_CLONE_NAME = "OTS_ClientBGM"

local musicEnabled = true
local sfxEnabled = true

--- First-seen volume per Sound (non-BGM) for restore when SFX is turned back on.
local originalVolume: { [Sound]: number } = {}

local sfxHeartbeat: RBXScriptConnection? = nil
local started = false

local function isBgmClone(s: Sound): boolean
	return s.Name == BGM_CLONE_NAME
end

local function rememberOriginal(s: Sound)
	if originalVolume[s] == nil then
		originalVolume[s] = s.Volume
	end
end

local function applySfxMutePass()
	if sfxEnabled then
		return
	end
	local function visit(s: Sound)
		if isBgmClone(s) then
			return
		end
		rememberOriginal(s)
		s.Volume = 0
	end
	for _, ch in ipairs(SoundService:GetChildren()) do
		if ch:IsA("Sound") then
			visit(ch)
		end
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Sound") then
			visit(inst)
		end
	end
	local plr = Players.LocalPlayer
	if plr then
		for _, inst in ipairs(plr:GetDescendants()) do
			if inst:IsA("Sound") then
				visit(inst)
			end
		end
	end
end

local function restoreSfxVolumes()
	for s, vol in pairs(originalVolume) do
		if s.Parent and not isBgmClone(s) then
			s.Volume = vol
		end
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
	if enabled then
		if sfxHeartbeat then
			sfxHeartbeat:Disconnect()
			sfxHeartbeat = nil
		end
		restoreSfxVolumes()
	else
		if sfxHeartbeat then
			sfxHeartbeat:Disconnect()
		end
		sfxHeartbeat = RunService.Heartbeat:Connect(applySfxMutePass)
		applySfxMutePass()
	end
end

function ClientAudioPreferences.isMusicEnabled(): boolean
	return musicEnabled
end

function ClientAudioPreferences.isSfxEnabled(): boolean
	return sfxEnabled
end

return ClientAudioPreferences
