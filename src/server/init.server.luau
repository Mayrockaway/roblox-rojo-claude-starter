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
local BoatDockService = require(serviceFolder:WaitForChild("BoatDockService"))
local OilShipmentService = require(serviceFolder:WaitForChild("OilShipmentService"))
local PerfService = require(serviceFolder:WaitForChild("PerfService"))
local ChunkOwnershipService = require(serviceFolder:WaitForChild("ChunkOwnershipService"))
local PipeNetworkService = require(serviceFolder:WaitForChild("PipeNetworkService"))
local WarehouseService = require(serviceFolder:WaitForChild("WarehouseService"))
local OilMarketService = require(serviceFolder:WaitForChild("OilMarketService"))
local EquipmentShopService = require(serviceFolder:WaitForChild("EquipmentShopService"))
local DrillingService = require(serviceFolder:WaitForChild("DrillingService"))
local ProspectingService = require(serviceFolder:WaitForChild("ProspectingService"))
local OilTankService = require(serviceFolder:WaitForChild("OilTankService"))
local FighterPlaneWaveService = require(serviceFolder:WaitForChild("FighterPlaneWaveService"))

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevLog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevLog"))
local RemoteNames = require(ReplicatedStorage.Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

-- Strait waypoint VFX templates live under RS; if any Sound is saved with Playing=true it is audible
-- to everyone from join. Storm/tornado audio is started only from cloned sounds on StormEvent/TornadoEvent.
-- Legacy Workspace.SFX.BGM must stay off: BGM is cloned per-client from ReplicatedStorage.Assets.SFX.BGM.
do
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local straitFx = assets and assets:FindFirstChild("StraitWaypointsFx")
	if straitFx then
		for _, d in ipairs(straitFx:GetDescendants()) do
			if d:IsA("Sound") then
				d.Playing = false
				d:Stop()
			end
		end
	end
	local sfx = workspace:FindFirstChild("SFX")
	local legacyBgm = sfx and sfx:FindFirstChild("BGM")
	if legacyBgm and legacyBgm:IsA("Sound") then
		legacyBgm.Playing = false
		legacyBgm:Stop()
	end
	local legacyDrill = sfx and sfx:FindFirstChild("Drilling")
	if legacyDrill and legacyDrill:IsA("Sound") then
		legacyDrill.Playing = false
		legacyDrill:Stop()
	end
	local legacyPipe = sfx and sfx:FindFirstChild("Pipe")
	if legacyPipe and legacyPipe:IsA("Sound") then
		legacyPipe.Playing = false
		legacyPipe:Stop()
	end
	for _, sfxName in ipairs({ "SetSail", "Kaching", "CollectorBuild", "OceanWaves" }) do
		local s = sfx and sfx:FindFirstChild(sfxName)
		if s and s:IsA("Sound") then
			s.Playing = false
			s:Stop()
		end
	end
end

PerfService:Init()
_G.Perf = PerfService   -- global hook so any service can call PerfService:OpenSpan/CloseSpan without wiring
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
BoatDockService:Init(RemoteService, OilStateService)
OilShipmentService:Init(RemoteService, OilStateService, PlotService, WarehouseService, StraitStateService, BoatDockService)
ChunkOwnershipService:Init(PlotService, OilStateService)
PipeNetworkService:Init()
WarehouseService:Init(RemoteService, OilStateService)
OilMarketService:Init(RemoteService, StraitStateService, WarehouseService, OilStateService)
EquipmentShopService:Init(RemoteService, OilStateService, PlotService)
PlotResourceService:Init(RemoteService, OilStateService, PlotService, OilVisualService, OilShipmentService, ChunkOwnershipService)
OilProductionService:Init(OilStateService, PipeNetworkService)
DrillingService:Init(RemoteService, OilStateService)
ProspectingService:Init(RemoteService, OilStateService)
OilTankService:Init(RemoteService, OilStateService)
ToolService:Init()
FighterPlaneWaveService:Init(RemoteService)

PerfService:Start()
RemoteService:Start()
StraitStateService:Start()
PlotService:Start()
OilStateService:Start()
OilVisualService:Start()
BoatDockService:Start()
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
OilTankService:Start()
ToolService:Start()
FighterPlaneWaveService:Start()

game:BindToClose(function()
	PerfService:Stop()
	ToolService:Stop()
	OilTankService:Stop()
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
	BoatDockService:Stop()
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
