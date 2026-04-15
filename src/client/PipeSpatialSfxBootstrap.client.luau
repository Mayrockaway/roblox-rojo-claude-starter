--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local remotes = Shared:WaitForChild("Remotes")
local pipePlacedFx = remotes:WaitForChild(RemoteNames.PipePlacedFx) :: RemoteEvent

local PipeSpatialSfx = require(script.Parent:WaitForChild("PipeSpatialSfx"))
PipeSpatialSfx.start(pipePlacedFx)
