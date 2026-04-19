--!strict
-- Shipment voyage ocean loop — separate LocalScript so failures here do not block ShipmentProgressHud.

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local shipmentVisualEvent = getClientRemotes().shipmentVisualEvent

local ShipmentOceanWavesSfx = require(script.Parent:WaitForChild("ShipmentOceanWavesSfx"))

shipmentVisualEvent.OnClientEvent:Connect(function(packet: any)
	if typeof(packet) ~= "table" then
		return
	end
	local kind = packet.type
	if typeof(kind) ~= "string" then
		return
	end
	local data = packet.data
	if typeof(data) ~= "table" then
		if typeof(packet.ownerUserId) == "number" or typeof(packet.playerUserId) == "number" then
			data = packet
		else
			return
		end
	end
	ShipmentOceanWavesSfx.onVisualPacket(kind, data)
end)
