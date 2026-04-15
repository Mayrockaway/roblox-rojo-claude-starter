--!strict
-- Non-spatial UI one-shots: clone from ReplicatedStorage.Assets.SFX (or Workspace.SFX fallback)
-- and play under SoundService (same pattern as BgmPlayer).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

export type UiSfxApi = {
	playSetSail: () -> (),
	playKaching: () -> (),
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
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
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
}

return UiSfx
