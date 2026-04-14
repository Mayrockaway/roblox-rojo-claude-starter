--!strict
-- Dev-only: grants free starter tools for local testing. For launch, replace this
-- with the real economy path (e.g. EquipmentShopService purchases) so tools
-- come from the shop / progression, not unconditional grants.

local Players = game:GetService("Players")

local ToolService = {}

-- Dev grants: 3 drill tiers + 3 pump tiers + pipe. Each tool carries attributes the
-- client inspects when placing: ToolKind = "Drill" | "Pump" | "Pipe", Tier = "T1"|"T2"|"T3"
-- Order matters: first entry lands in slot 1. Hammer is always slot 1.
local STARTER_TOOLS = {
	{ name = "Hammer",     kind = "Hammer",     tier = nil },
	{ name = "Drill_T1",   kind = "Drill",      tier = "T1" },
	{ name = "Drill_T2",   kind = "Drill",      tier = "T2" },
	{ name = "Drill_T3",   kind = "Drill",      tier = "T3" },
	{ name = "Pump_T1",    kind = "Pump",       tier = "T1" },
	{ name = "Pump_T2",    kind = "Pump",       tier = "T2" },
	{ name = "Pump_T3",    kind = "Pump",       tier = "T3" },
	{ name = "Prospector", kind = "Prospector", tier = nil },
	{ name = "Pipe",       kind = "Pipe",       tier = nil },
}

-- Build a simple hammer out of two Parts welded to a Handle
local function buildHammerHandle(): Part
	-- Handle (wood shaft) — this is the Part that auto-grips in the player's hand
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = Enum.PartType.Cylinder
	handle.Size = Vector3.new(1.6, 0.35, 0.35)
	handle.Material = Enum.Material.Wood
	handle.Color = Color3.fromRGB(110, 70, 40)
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.CanCollide = false

	-- Hammer head (steel)
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Block
	head.Size = Vector3.new(0.7, 0.8, 0.45)
	head.Material = Enum.Material.Metal
	head.Color = Color3.fromRGB(175, 175, 180)
	head.Reflectance = 0.15
	head.CanCollide = false

	-- Weld head to the end of the handle
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = head
	weld.Parent = head
	head.CFrame = handle.CFrame * CFrame.new(0.75, 0.4, 0)

	head.Parent = handle
	return handle
end

local function ensureTool(container: Instance, info: { name: string, kind: string, tier: string? })
	local existing = container:FindFirstChild(info.name)
	if existing and existing:IsA("Tool") then
		existing:SetAttribute("ToolKind", info.kind)
		existing:SetAttribute("Tier", info.tier)
		return
	end
	if existing and not existing:IsA("Tool") then
		existing:Destroy()
	end

	local tool = Instance.new("Tool")
	tool.Name = info.name
	tool.CanBeDropped = false
	tool:SetAttribute("ToolKind", info.kind)
	tool:SetAttribute("Tier", info.tier)

	if info.kind == "Hammer" then
		tool.RequiresHandle = true
		local handle = buildHammerHandle()
		handle.Parent = tool
		-- Grip so the hammer sits naturally pointing forward in the character's hand
		tool.Grip = CFrame.new(0, 0, 0.2) * CFrame.Angles(0, math.rad(90), 0)
	else
		tool.RequiresHandle = false
	end

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
	"Drill", -- old single-drill name, replaced by Drill_T1/T2/T3
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
		for _, info in ipairs(STARTER_TOOLS) do
			ensureTool(backpack, info)
		end
	end

	local starterGear = player:FindFirstChild("StarterGear")
	if not starterGear then
		starterGear = player:WaitForChild("StarterGear", 10)
	end
	if starterGear then
		purgeLegacyTools(starterGear)
		for _, info in ipairs(STARTER_TOOLS) do
			ensureTool(starterGear, info)
		end
	end

	local character = player.Character
	if character then
		purgeLegacyTools(character)
	end
end

return ToolService
