--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local remotes = Shared:WaitForChild("Remotes", 60)
if not remotes then
	error("[PipeSpatialSfxBootstrap] Shared.Remotes missing.", 0)
end
local pipePlacedFx = remotes:WaitForChild(RemoteNames.PipePlacedFx, 60) :: RemoteEvent
if not pipePlacedFx then
	error("[PipeSpatialSfxBootstrap] PipePlacedFx remote missing.", 0)
end

local PipeSpatialSfx = require(script.Parent:WaitForChild("PipeSpatialSfx"))
PipeSpatialSfx.start(pipePlacedFx)
