--!strict

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local drillProgressUpdate = getClientRemotes().drillProgressUpdate

local CollectorBuildSpatialSfx = require(script.Parent:WaitForChild("CollectorBuildSpatialSfx"))
CollectorBuildSpatialSfx.start(drillProgressUpdate)
