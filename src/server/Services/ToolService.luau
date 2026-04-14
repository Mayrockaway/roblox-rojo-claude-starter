--!strict
-- Strips obsolete dev-only tools from Backpack / StarterGear / Character on join and respawn.
-- Oil equipment is granted only via `EquipmentShopService` (clones `ServerStorage.EquipmentShopTemplates` → `Player.Backpack`).

local Players = game:GetService("Players")

local ToolService = {}

-- Do not list shop template names (Drill_T1, Pump_T1, …) — those may be legitimate purchases.
local LEGACY_TOOL_NAMES = {
	"LandSurveyor",
	"Drill", -- pre–tiered single drill
	"Hammer", -- removed until a new teardown flow ships
}

local function purgeLegacyByName(container: Instance)
	for _, name in ipairs(LEGACY_TOOL_NAMES) do
		local inst = container:FindFirstChild(name)
		if inst then
			inst:Destroy()
		end
	end
end

local function cleanupPlayerContainers(player: Player)
	local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 10)
	if backpack then
		purgeLegacyByName(backpack)
	end
	local starterGear = player:FindFirstChild("StarterGear") or player:WaitForChild("StarterGear", 10)
	if starterGear then
		purgeLegacyByName(starterGear)
	end
	local character = player.Character
	if character then
		purgeLegacyByName(character)
	end
end

function ToolService:Init()
	self._connections = {}
	self._running = false
end

function ToolService:Start()
	if self._running then
		return
	end
	self._running = true

	local function hookPlayer(player: Player)
		table.insert(
			self._connections,
			player.CharacterAdded:Connect(function()
				cleanupPlayerContainers(player)
			end)
		)
		cleanupPlayerContainers(player)
	end

	table.insert(self._connections, Players.PlayerAdded:Connect(hookPlayer))
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
end

function ToolService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
end

return ToolService
