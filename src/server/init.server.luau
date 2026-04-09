--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[OilEmpire] SERVER_BOOT_V2")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
if sharedFolder:FindFirstChild("Remotes") == nil then
	local remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = sharedFolder
end

local serviceFolder = script:WaitForChild("Services")
local testsFolder = script:WaitForChild("Tests")

local RemoteService = require(serviceFolder:WaitForChild("RemoteService"))
local RateLimitService = require(serviceFolder:WaitForChild("RateLimitService"))
local IdempotencyService = require(serviceFolder:WaitForChild("IdempotencyService"))
local TelemetryService = require(serviceFolder:WaitForChild("TelemetryService"))
local PersistenceService = require(serviceFolder:WaitForChild("PersistenceService"))
local VisualService = require(serviceFolder:WaitForChild("VisualService"))
local StraitStateService = require(serviceFolder:WaitForChild("StraitStateService"))
local PlayerStateService = require(serviceFolder:WaitForChild("PlayerStateService"))
local UpgradeService = require(serviceFolder:WaitForChild("UpgradeService"))
local ShipmentService = require(serviceFolder:WaitForChild("ShipmentService"))
local AdminService = require(serviceFolder:WaitForChild("AdminService"))
local DeterministicShipmentEngineSelfTest = require(testsFolder:WaitForChild("DeterministicShipmentEngineSelfTest"))

RemoteService:Init()
RateLimitService:Init()
IdempotencyService:Init()
TelemetryService:Init()
PersistenceService:Init(TelemetryService)
VisualService:Init()
StraitStateService:Init(RemoteService, TelemetryService)
PlayerStateService:Init(RemoteService, PersistenceService, TelemetryService)
UpgradeService:Init(RemoteService, PlayerStateService, RateLimitService, TelemetryService)
ShipmentService:Init(
	RemoteService,
	StraitStateService,
	PlayerStateService,
	UpgradeService,
	RateLimitService,
	IdempotencyService,
	TelemetryService,
	VisualService
)
AdminService:Init(RemoteService, StraitStateService, RateLimitService, TelemetryService)

local selfTestOk, selfTestErr = pcall(function()
	DeterministicShipmentEngineSelfTest.Run()
end)
if not selfTestOk then
	warn("[Server] Deterministic shipment self-test failed:", selfTestErr)
end

RemoteService:Start()
RateLimitService:Start()
IdempotencyService:Start()
TelemetryService:Start()
PersistenceService:Start()
VisualService:Start()
StraitStateService:Start()
PlayerStateService:Start()
UpgradeService:Start()
ShipmentService:Start()
AdminService:Start()

game:BindToClose(function()
	AdminService:Stop()
	ShipmentService:Stop()
	UpgradeService:Stop()
	PlayerStateService:Stop()
	StraitStateService:Stop()
	VisualService:Stop()
	PersistenceService:Stop()
	TelemetryService:Stop()
	IdempotencyService:Stop()
	RateLimitService:Stop()
	RemoteService:Stop()
end)

print("[Server] Oil Empire MVP systems started")
