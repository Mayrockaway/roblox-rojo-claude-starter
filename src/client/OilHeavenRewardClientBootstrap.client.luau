--!strict
-- Entry: Oil Heaven reward drill opener and 2x reward purchase flow.

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
	error("[OilHeavenRewardClientBootstrap] Missing ResolveClientModule under PlayerScripts (sync Rojo `src/client`).")
end
local resolveClientModule = require(resolveClientModuleScript)
local OilHeavenRewardClient = require(resolveClientModule(script, "OilHeavenRewardClient"))
OilHeavenRewardClient.start()
