--!strict
-- Shipment voyage ocean loop — separate LocalScript so failures here do not block ShipmentProgressHud.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local remotes = Shared:WaitForChild("Remotes")
local shipmentVisualEvent = remotes:WaitForChild(RemoteNames.ShipmentVisualEvent) :: RemoteEvent

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
