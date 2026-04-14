--!strict
-- Dev-only: grants free starter tools for local testing. For launch, replace this
-- with the real economy path (e.g. EquipmentShopService purchases) so tools
-- come from the shop / progression, not unconditional grants.

local Players = game:GetService("Players")

local ToolService = {}

local STARTER_TOOL_NAMES = {
	"Drill",
	"Pipe",
}

local function ensureTool(container: Instance, toolName: string)
	local existing = container:FindFirstChild(toolName)
	if existing and existing:IsA("Tool") then
		return
	end
	if existing and not existing:IsA("Tool") then
		existing:Destroy()
	end

	local tool = Instance.new("Tool")
	tool.Name = toolName
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.Parent = container
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

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_setupPlayer(player)
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		self:_setupPlayer(player)
	end
end

function ToolService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function ToolService:_setupPlayer(player: Player)
	table.insert(self._connections, player.CharacterAdded:Connect(function()
		self:_grantStarterTools(player)
	end))

	self:_grantStarterTools(player)
end

local LEGACY_TOOL_NAMES = {
	"LandSurveyor",
}

local function purgeLegacyTools(container: Instance)
	for _, name in ipairs(LEGACY_TOOL_NAMES) do
		local existing = container:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end

function ToolService:_grantStarterTools(player: Player)
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		backpack = player:WaitForChild("Backpack", 10)
	end
	if backpack then
		purgeLegacyTools(backpack)
		for _, toolName in ipairs(STARTER_TOOL_NAMES) do
			ensureTool(backpack, toolName)
		end
	end

	local starterGear = player:FindFirstChild("StarterGear")
	if not starterGear then
		starterGear = player:WaitForChild("StarterGear", 10)
	end
	if starterGear then
		purgeLegacyTools(starterGear)
		for _, toolName in ipairs(STARTER_TOOL_NAMES) do
			ensureTool(starterGear, toolName)
		end
	end

	local character = player.Character
	if character then
		purgeLegacyTools(character)
	end
end

return ToolService
