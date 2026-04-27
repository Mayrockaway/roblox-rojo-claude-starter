--!strict
-- Entry: Oil Heaven ambient controller (music crossfade on world transition).

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
	error("[OilHeavenAmbientBootstrap] Missing ResolveClientModule under PlayerScripts (sync Rojo `src/client`).")
end
local resolveClientModule = require(resolveClientModuleScript)
local OilHeavenAmbient = require(resolveClientModule(script, "OilHeavenAmbient"))
OilHeavenAmbient.start()
