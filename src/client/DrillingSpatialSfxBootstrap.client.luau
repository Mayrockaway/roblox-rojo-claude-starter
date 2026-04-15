--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local remotes = Shared:WaitForChild("Remotes")
local drillProgressUpdate = remotes:WaitForChild(RemoteNames.DrillProgressUpdate) :: RemoteEvent

local DrillingSpatialSfx = require(script.Parent:WaitForChild("DrillingSpatialSfx"))
DrillingSpatialSfx.start(drillProgressUpdate)
