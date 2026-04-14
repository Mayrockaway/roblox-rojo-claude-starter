--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local legacyPlotScript = ServerScriptService:FindFirstChild("PlotService")
if legacyPlotScript and legacyPlotScript:IsA("Script") then
	legacyPlotScript:Destroy()
end

for _, child in ipairs(ServerScriptService:GetChildren()) do
	if child:IsA("Script") and child ~= script then
		warn(string.format("[Server] Extra Script in ServerScriptService: %s (can conflict with Rojo services)", child.Name))
	end
end


local serviceFolder = script:WaitForChild("Services")

local RemoteService = require(serviceFolder:WaitForChild("RemoteService"))
local TelemetryService = require(serviceFolder:WaitForChild("TelemetryService"))
local StraitStateService = require(serviceFolder:WaitForChild("StraitStateService"))
local PlotService = require(serviceFolder:WaitForChild("PlotService"))
local OilStateService = require(serviceFolder:WaitForChild("OilStateService"))
local PlotResourceService = require(serviceFolder:WaitForChild("PlotResourceService"))
local OilProductionService = require(serviceFolder:WaitForChild("OilProductionService"))
local ToolService = require(serviceFolder:WaitForChild("ToolService"))
local OilVisualService = require(serviceFolder:WaitForChild("OilVisualService"))
local OilShipmentService = require(serviceFolder:WaitForChild("OilShipmentService"))
local ChunkOwnershipService = require(serviceFolder:WaitForChild("ChunkOwnershipService"))
local PipeNetworkService = require(serviceFolder:WaitForChild("PipeNetworkService"))
local WarehouseService = require(serviceFolder:WaitForChild("WarehouseService"))
local OilMarketService = require(serviceFolder:WaitForChild("OilMarketService"))
local EquipmentShopService = require(serviceFolder:WaitForChild("EquipmentShopService"))
local DrillingService = require(serviceFolder:WaitForChild("DrillingService"))
local ProspectingService = require(serviceFolder:WaitForChild("ProspectingService"))
local FighterPlaneWaveService = require(serviceFolder:WaitForChild("FighterPlaneWaveService"))

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevLog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevLog"))
local RemoteNames = require(ReplicatedStorage.Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

RemoteService:Init()
DevLog.SetBroadcaster(function(msg)
	local ev = RemoteService:GetEvent(RemoteNames.DevLog)
	ev:FireAllClients(msg)
end)
TelemetryService:Init()
StraitStateService:Init(RemoteService, TelemetryService)
PlotService:Init()
OilStateService:Init(RemoteService, PlotService)
OilVisualService:Init(OilStateService, PlotService)
OilShipmentService:Init(RemoteService, OilStateService, PlotService, WarehouseService, StraitStateService)
ChunkOwnershipService:Init(PlotService, OilStateService)
PipeNetworkService:Init()
WarehouseService:Init(RemoteService, OilStateService)
OilMarketService:Init(RemoteService, StraitStateService, WarehouseService, OilStateService)
EquipmentShopService:Init(RemoteService, OilStateService)
PlotResourceService:Init(RemoteService, OilStateService, PlotService, OilVisualService, OilShipmentService, ChunkOwnershipService)
OilProductionService:Init(OilStateService, PipeNetworkService)
DrillingService:Init(RemoteService, OilStateService)
ProspectingService:Init(RemoteService, OilStateService)
ToolService:Init()
FighterPlaneWaveService:Init(RemoteService)

RemoteService:Start()
StraitStateService:Start()
PlotService:Start()
OilStateService:Start()
OilVisualService:Start()
OilShipmentService:Start()
ChunkOwnershipService:Start()
PipeNetworkService:Start()
WarehouseService:Start()
OilMarketService:Start()
EquipmentShopService:Start()
PlotResourceService:Start()
OilProductionService:Start()
DrillingService:Start()
ProspectingService:Start()
ToolService:Start()
FighterPlaneWaveService:Start()

game:BindToClose(function()
	ToolService:Stop()
	ProspectingService:Stop()
	FighterPlaneWaveService:Stop()
	DrillingService:Stop()
	OilProductionService:Stop()
	PlotResourceService:Stop()
	PipeNetworkService:Stop()
	OilMarketService:Stop()
	EquipmentShopService:Stop()
	WarehouseService:Stop()
	ChunkOwnershipService:Stop()
	OilShipmentService:Stop()
	OilVisualService:Stop()
	OilStateService:Stop()
	StraitStateService:Stop()
	PlotService:Stop()
	RemoteService:Stop()
end)

-- Debug chat commands (Studio only)
if RunService:IsStudio() then
	game:GetService("Players").PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(message)
			local cmd = message:lower():gsub("^%s+", ""):gsub("%s+$", "")
			if cmd == "/missile" then
				OilShipmentService:DebugDispatchMissile(player)
			elseif cmd == "/mine" then
				OilShipmentService:DebugDispatchMine(player)
			elseif cmd == "/pirate" then
				OilShipmentService:DebugDispatchPirate(player)
			elseif cmd == "/storm" then
				OilShipmentService:DebugDispatchStorm(player)
			elseif cmd == "/tornado" then
				OilShipmentService:DebugDispatchTornado(player)
			elseif cmd == "/coastguard" then
				OilShipmentService:DebugDispatchCoastGuard(player)
			elseif cmd == "/slap" then
				OilShipmentService:DebugDispatchUSShipSlap(player)
			elseif cmd == "/fighterwave" or cmd == "/fighters" then
				FighterPlaneWaveService:DebugSpawnWave(player.Name)
			elseif cmd == "/fighterhere" or cmd == "/jethere" then
				FighterPlaneWaveService:DebugSpawnOverPlayer(player)
			elseif cmd == "/fighterretarget" or cmd == "/jetretarget" then
				FighterPlaneWaveService:DebugRetargetTemplate(player.Name)
			end
		end)
	end)
end

print("[Server] Oil mining mode active: chunked plot + free-placed drills")
