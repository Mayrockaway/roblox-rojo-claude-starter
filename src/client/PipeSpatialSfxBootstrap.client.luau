--!strict

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local pipePlacedFx = getClientRemotes().pipePlacedFx

local PipeSpatialSfx = require(script.Parent:WaitForChild("PipeSpatialSfx"))
PipeSpatialSfx.start(pipePlacedFx)
