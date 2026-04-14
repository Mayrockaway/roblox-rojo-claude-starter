--!strict
-- Shipment `ProgressFill` driver — isolated from `init.client.luau` so a main-script error cannot tear down this listener
-- or block startup behind the long remotes chain in `init`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local function resolveClientScriptsFolder(): Instance
	local p = script.Parent
	if p and p:FindFirstChild("UI") then
		return p
	end
	local ps = player:WaitForChild("PlayerScripts", 60)
	local c = ps:WaitForChild("Client", 60)
	return c
end

local clientFolder = resolveClientScriptsFolder()

local ui: Instance?
local okUi, errUi = pcall(function()
	ui = clientFolder:WaitForChild("UI", 120)
end)
if not okUi or not ui then
	warn("[ShipmentProgressBootstrap] FAILED: Client.UI — ", errUi)
	return
end

local modScript: Instance?
local okMs, errMs = pcall(function()
	modScript = ui:WaitForChild("ShipmentProgressHud", 60)
end)
if not okMs or not (modScript and modScript:IsA("ModuleScript")) then
	warn("[ShipmentProgressBootstrap] FAILED: ShipmentProgressHud — ", errMs)
	return
end

local mod = require(modScript :: ModuleScript) :: { init: (PlayerGui) -> (), onVisualPacket: (string, any, Player) -> () }
mod.init(playerGui)

local ActiveManifestController: { start: (PlayerGui) -> (), onVisualPacket: (string, any, Player) -> () }? = nil
local amScript = ui:FindFirstChild("ActiveManifestController")
if amScript and amScript:IsA("ModuleScript") then
	local am = require(amScript :: ModuleScript) :: { start: (PlayerGui) -> (), onVisualPacket: (string, any, Player) -> () }
	am.start(playerGui)
	ActiveManifestController = am
else
	warn("[ShipmentProgressBootstrap] ActiveManifestController ModuleScript missing under Client.UI")
end

local remotesFolder: Instance?
local okR, errR = pcall(function()
	remotesFolder = Shared:WaitForChild("Remotes", 120)
end)
if not okR or not remotesFolder then
	warn("[ShipmentProgressBootstrap] FAILED: Remotes — ", errR)
	return
end

local shipmentVisualEvent: Instance?
local okE, errE = pcall(function()
	shipmentVisualEvent = remotesFolder:WaitForChild(RemoteNames.ShipmentVisualEvent, 60)
end)
if not okE or not (shipmentVisualEvent and shipmentVisualEvent:IsA("RemoteEvent")) then
	warn("[ShipmentProgressBootstrap] FAILED: ShipmentVisualEvent — ", errE)
	return
end
local shipmentVisualEventTyped = shipmentVisualEvent :: RemoteEvent

if RunService:IsStudio() then
	print("[ShipmentProgressBootstrap] ShipmentVisualEvent listener active (oil uses { type, data }; legacy may be flat).")
end

shipmentVisualEventTyped.OnClientEvent:Connect(function(packet: any)
	if typeof(packet) ~= "table" then
		return
	end
	local kind = packet.type
	if typeof(kind) ~= "string" then
		return
	end
	local data = packet.data
	if typeof(data) ~= "table" then
		-- Legacy tanker path: flat payload `{ type = "...", playerUserId = ..., ... }`
		if typeof(packet.playerUserId) == "number" or typeof(packet.ownerUserId) == "number" then
			data = packet
		else
			return
		end
	end
	local uid = data.ownerUserId or data.playerUserId
	local isOwner = typeof(uid) == "number" and uid == player.UserId
	-- ShipmentProgressHud: own bar + optional crowd markers for other players on the same track.
	mod.onVisualPacket(kind, data, player)
	if isOwner and ActiveManifestController then
		ActiveManifestController.onVisualPacket(kind, data, player)
	end
end)
