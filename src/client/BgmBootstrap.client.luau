--!strict
-- Per-client background music: clone authored `Workspace.SFX.BGM` into SoundService once.
-- Keep the workspace template with Playing = false so the server does not drive one shared
-- world loop; each client owns a non-spatial Sound under SoundService (not parented to a BasePart).

local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local CLONE_NAME = "OTS_ClientBGM"

local function tryStartBgm()
	if SoundService:FindFirstChild(CLONE_NAME) then
		return
	end

	local sfx = Workspace:FindFirstChild("SFX")
	local template = sfx and sfx:FindFirstChild("BGM")
	if not (template and template:IsA("Sound")) then
		return
	end

	local s = template:Clone()
	s.Name = CLONE_NAME
	s.Playing = false
	s.Parent = SoundService
	s:Play()
end

task.spawn(function()
	if SoundService:FindFirstChild(CLONE_NAME) then
		return
	end
	local okSfx, sfx = pcall(function()
		return Workspace:WaitForChild("SFX", 120)
	end)
	if not okSfx or not (sfx and sfx:IsA("Folder")) then
		warn("[BgmBootstrap] Workspace.SFX not found — BGM disabled.")
		return
	end
	local okBgm, bgm = pcall(function()
		return sfx:WaitForChild("BGM", 120)
	end)
	if not okBgm or not (bgm and bgm:IsA("Sound")) then
		warn("[BgmBootstrap] Workspace.SFX.BGM missing or not a Sound — BGM disabled.")
		return
	end
	tryStartBgm()
end)
