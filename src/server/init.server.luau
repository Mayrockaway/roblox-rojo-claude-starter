--!strict

local ServerScriptService = game:GetService("ServerScriptService")

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
local PlotService = require(serviceFolder:WaitForChild("PlotService"))
local OilStateService = require(serviceFolder:WaitForChild("OilStateService"))
local PlotResourceService = require(serviceFolder:WaitForChild("PlotResourceService"))
local OilProductionService = require(serviceFolder:WaitForChild("OilProductionService"))
local ToolService = require(serviceFolder:WaitForChild("ToolService"))
local OilVisualService = require(serviceFolder:WaitForChild("OilVisualService"))
local OilShipmentService = require(serviceFolder:WaitForChild("OilShipmentService"))
local ChunkOwnershipService = require(serviceFolder:WaitForChild("ChunkOwnershipService"))
local PipeNetworkService = require(serviceFolder:WaitForChild("PipeNetworkService"))

RemoteService:Init()
PlotService:Init()
OilStateService:Init(RemoteService, PlotService)
OilVisualService:Init(OilStateService, PlotService)
OilShipmentService:Init(RemoteService, OilStateService, PlotService)
ChunkOwnershipService:Init(PlotService, OilStateService)
PipeNetworkService:Init()
PlotResourceService:Init(RemoteService, OilStateService, PlotService, OilVisualService, OilShipmentService, ChunkOwnershipService)
OilProductionService:Init(OilStateService, PipeNetworkService)
ToolService:Init()

RemoteService:Start()
PlotService:Start()
OilStateService:Start()
OilVisualService:Start()
OilShipmentService:Start()
ChunkOwnershipService:Start()
PipeNetworkService:Start()
PlotResourceService:Start()
OilProductionService:Start()
ToolService:Start()

game:BindToClose(function()
	ToolService:Stop()
	OilProductionService:Stop()
	PlotResourceService:Stop()
	PipeNetworkService:Stop()
	ChunkOwnershipService:Stop()
	OilShipmentService:Stop()
	OilVisualService:Stop()
	OilStateService:Stop()
	PlotService:Stop()
	RemoteService:Stop()
end)

print("[Server] Oil mining mode active: chunked plot + free-placed drills")
