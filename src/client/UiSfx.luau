--!strict
-- Non-spatial UI one-shots: clone from ReplicatedStorage.Assets.SFX (or Workspace.SFX fallback)
-- and play under SoundService (same pattern as BgmPlayer).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

export type UiSfxApi = {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
	--- FTUE dialogue panel opens for a new step (`FtueDialogueController`).
	playFtueDialogueOpen: () -> (),
}

local function findTemplate(canonicalName: string): Sound?
	local key = string.lower(canonicalName)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rsSfx = assets and assets:FindFirstChild("SFX")
	if rsSfx then
		for _, c in ipairs(rsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == key then
				return c
			end
		end
	end
	local wsSfx = Workspace:FindFirstChild("SFX")
	if wsSfx then
		for _, c in ipairs(wsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == key then
				return c
			end
		end
	end
	-- Studio / alternate hierarchy: any Sound under ReplicatedStorage with matching name.
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d:IsA("Sound") and string.lower(d.Name) == key then
			return d
		end
	end
	return nil
end

local function playOneShot(canonicalName: string)
	local template = findTemplate(canonicalName)
	if not template then
		return
	end
	local s = template:Clone()
	s.Name = "UiSfx_" .. canonicalName
	s.Looped = false
	s.Playing = false
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	pcall(function()
		s.TimePosition = 0
	end)
	s:Play()
end

--- UI error / deny (does not rely on `ReplicatedStorage` template instances).
local UI_DENIED_SOUND_ID = "rbxassetid://80835117736204"
--- FTUE: new dialogue step panel (`FtueDialogueController`).
local FTUE_DIALOGUE_OPEN_SOUND_ID = "rbxassetid://117079675822991"
local FTUE_DIALOGUE_OPEN_VOLUME = 0.2

local function playOneShotByAssetId(assetId: string, volume: number)
	local s = Instance.new("Sound")
	s.Name = "UiSfx_Asset"
	s.SoundId = assetId
	s.Volume = volume
	s.Looped = false
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	pcall(function()
		s.TimePosition = 0
	end)
	s:Play()
end

local UiSfx: UiSfxApi = {
	playSetSail = function()
		playOneShot("SetSail")
	end,
	playKaching = function()
		playOneShot("Kaching")
	end,
	playUiDenied = function()
		playOneShotByAssetId(UI_DENIED_SOUND_ID, 0.325)
	end,
	playFtueDialogueOpen = function()
		playOneShotByAssetId(FTUE_DIALOGUE_OPEN_SOUND_ID, FTUE_DIALOGUE_OPEN_VOLUME)
	end,
}

return UiSfx
