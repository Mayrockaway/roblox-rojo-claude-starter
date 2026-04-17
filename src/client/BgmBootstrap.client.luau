--!strict
-- Entry: per-client BGM from Rojo template `ReplicatedStorage.Assets.SFX.BGM`.

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local resolveClientModuleScript: ModuleScript? = nil
for _ = 1, 300 do
	local r = playerScripts:FindFirstChild("ResolveClientModule", true)
	if r and r:IsA("ModuleScript") then
		resolveClientModuleScript = r
		break
	end
	task.wait(0.05)
end
if not resolveClientModuleScript then
	error("[BgmBootstrap] Missing ResolveClientModule under PlayerScripts (sync Rojo `src/client`).")
end
local resolveClientModule = require(resolveClientModuleScript)
local BgmPlayer = require(resolveClientModule(script, "BgmPlayer"))
-- `ClientAudioPreferences.init()` runs from `init.client.luau` before other audio hooks.
BgmPlayer.startAsync()
