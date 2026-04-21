--!strict

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local drillProgressUpdate = getClientRemotes().drillProgressUpdate

local PumpCollectSpatialSfx = require(script.Parent:WaitForChild("PumpCollectSpatialSfx"))
PumpCollectSpatialSfx.start(drillProgressUpdate)
