--!strict
-- Find a `ModuleScript` that lives next to a bootstrap script **or** anywhere under
-- `PlayerScripts` (e.g. Rojo `StarterPlayerScripts.Client.*` while the LocalScript is
-- mistakenly parented directly under `PlayerScripts`).

local Players = game:GetService("Players")

local function resolve(scriptRef: LuaSourceContainer, moduleName: string): ModuleScript
	local root = scriptRef.Parent
	local m = root:FindFirstChild(moduleName)
	if m and m:IsA("ModuleScript") then
		return m
	end
	local ps = Players.LocalPlayer:WaitForChild("PlayerScripts")
	m = ps:FindFirstChild(moduleName, true)
	if m and m:IsA("ModuleScript") then
		return m
	end
	for _ = 1, 300 do
		m = root:FindFirstChild(moduleName) or ps:FindFirstChild(moduleName, true)
		if m and m:IsA("ModuleScript") then
			return m
		end
		task.wait(0.05)
	end
	error(("[ResolveClientModule] Missing ModuleScript %q under PlayerScripts"):format(moduleName))
end

return resolve
