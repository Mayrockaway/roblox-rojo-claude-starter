--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local remotes = Shared:WaitForChild("Remotes", 60)
if not remotes then
	error("[CollectorBuildSpatialSfxBootstrap] Shared.Remotes missing.", 0)
end
local drillProgressUpdate = remotes:WaitForChild(RemoteNames.DrillProgressUpdate, 60) :: RemoteEvent
if not drillProgressUpdate then
	error("[CollectorBuildSpatialSfxBootstrap] DrillProgressUpdate remote missing.", 0)
end

local CollectorBuildSpatialSfx = require(script.Parent:WaitForChild("CollectorBuildSpatialSfx"))
CollectorBuildSpatialSfx.start(drillProgressUpdate)
