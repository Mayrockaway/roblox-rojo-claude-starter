--!strict
-- One non-spatial BGM per client: clone template into SoundService (Sounds parented there are
-- not emitted from a BasePart, so they play as normal background audio for that client only).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local CLONE_NAME = "OTS_ClientBGM"

local defaultBgmVolume = 0.07

local function templateFromWorkspace(): Sound?
	local sfx = Workspace:FindFirstChild("SFX")
	local bgm = sfx and sfx:FindFirstChild("BGM")
	if bgm and bgm:IsA("Sound") then
		return bgm
	end
	return nil
end

local function waitReplicatedTemplate(): Sound?
	local okAssets, assets = pcall(function()
		return ReplicatedStorage:WaitForChild("Assets", 120)
	end)
	if not okAssets or not assets then
		return nil
	end
	local okSfx, sfx = pcall(function()
		return assets:WaitForChild("SFX", 120)
	end)
	if not okSfx or not sfx then
		return nil
	end
	local okBgm, bgm = pcall(function()
		return sfx:WaitForChild("BGM", 120)
	end)
	if okBgm and bgm and bgm:IsA("Sound") then
		return bgm
	end
	return nil
end

local BgmPlayer = {}

function BgmPlayer.startFromTemplate(template: Sound)
	if SoundService:FindFirstChild(CLONE_NAME) then
		return
	end
	defaultBgmVolume = template.Volume
	local s = template:Clone()
	s.Name = CLONE_NAME
	s.Playing = false
	s.Parent = SoundService
	s:Play()
end

--- Mute/unmute the client BGM clone (`SoundService.OTS_ClientBGM`). Does not delete the sound.
function BgmPlayer.setMusicEnabled(enabled: boolean)
	local s = SoundService:FindFirstChild(CLONE_NAME)
	if not (s and s:IsA("Sound")) then
		return
	end
	if enabled then
		s.Volume = defaultBgmVolume
		s.Playing = true
	else
		s.Volume = 0
		s.Playing = false
	end
end

function BgmPlayer.startAsync()
	task.spawn(function()
		if SoundService:FindFirstChild(CLONE_NAME) then
			return
		end
		local template = waitReplicatedTemplate() or templateFromWorkspace()
		if not template then
			warn("[BgmPlayer] No BGM template (ReplicatedStorage.Assets.SFX.BGM or Workspace.SFX.BGM).")
			return
		end
		BgmPlayer.startFromTemplate(template)
	end)
end

return BgmPlayer
