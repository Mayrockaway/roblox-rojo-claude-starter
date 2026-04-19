--!strict
-- Cached `require(PlayerScripts.Client.ClientRemotes)` so any module under `Client` (or nested `UI`)
-- does not depend on fragile `script.Parent^n` paths to the remotes table.
-- Rojo: `src/client/GetClientRemotes.luau` → `StarterPlayer.StarterPlayerScripts.Client.GetClientRemotes`.

local Players = game:GetService("Players")

local cached: any = nil

local function getClientRemotes(): any
	if cached ~= nil then
		return cached
	end
	local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
	local clientFolder = playerScripts:WaitForChild("Client")
	local mod = clientFolder:WaitForChild("ClientRemotes")
	cached = require(mod)
	return cached
end

return getClientRemotes
