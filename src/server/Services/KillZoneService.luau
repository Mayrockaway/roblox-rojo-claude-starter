--!strict

-- Large non-colliding volume under the map: any player character that touches it dies (Health = 0).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))

local KillZoneService = {}

function KillZoneService:Init()
	self._running = false
	self._touchConn = nil :: RBXScriptConnection?
	self._folder = nil :: Folder?
end

function KillZoneService:Start()
	if self._running then
		return
	end
	self._running = true

	local map = Workspace:WaitForChild("Map", 20) or Workspace

	local folder = Instance.new("Folder")
	folder.Name = "ServerKillZones"
	folder.Parent = map

	local half = Constants.KillZoneUnderMapHorizontalHalfExtent
	local thick = Constants.KillZoneUnderMapThicknessY
	local cy = Constants.KillZoneUnderMapCenterY

	local zone = Instance.new("Part")
	zone.Name = "UnderMapKillZone"
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanQuery = false
	zone.CanTouch = true
	zone.Transparency = 1
	zone.Size = Vector3.new(half * 2, thick, half * 2)
	zone.CFrame = CFrame.new(0, cy, 0)
	zone.Parent = folder

	self._folder = folder

	self._touchConn = zone.Touched:Connect(function(hit: BasePart)
		if not hit then
			return
		end
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local player = Players:GetPlayerFromCharacter(model)
		if not player then
			return
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return
		end
		hum.Health = 0
	end)
end

function KillZoneService:Stop()
	self._running = false
	if self._touchConn then
		self._touchConn:Disconnect()
		self._touchConn = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

return KillZoneService
