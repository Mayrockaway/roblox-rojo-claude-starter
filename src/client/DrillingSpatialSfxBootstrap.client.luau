--!strict

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local drillProgressUpdate = getClientRemotes().drillProgressUpdate

local DrillingSpatialSfx = require(script.Parent:WaitForChild("DrillingSpatialSfx"))
DrillingSpatialSfx.start(drillProgressUpdate)
