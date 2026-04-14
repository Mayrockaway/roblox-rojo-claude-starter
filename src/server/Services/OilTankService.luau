--!strict
-- OilTankService: wires the upgrade path for per-plot OilTanks rigs.
-- Two entry points:
--   * RemoteEvent RequestUpgradeOilTank — for future HUD panels.
--   * ProximityPrompt "TankUpgradePrompt" authored on each tube's Union — player walks up
--     to their own tank and presses E.
-- Both route to OilStateService:TryUpgradeTank, which enforces ownership/cost/tier cap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilTankService = {}

local function plotOwnerOf(instance: Instance): number?
	local cur: Instance? = instance
	while cur do
		if cur:IsA("Model") and cur.Name:match("^Plot_") then
			local owner = cur:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" then return owner end
			return nil
		end
		cur = cur.Parent
	end
	return nil
end

local function oilTypeOfPrompt(prompt: ProximityPrompt): string?
	local tube = prompt.Parent and prompt.Parent.Parent
	if tube and tube:IsA("Model") then
		local t = tube:GetAttribute("OilType")
		if typeof(t) == "string" then return t end
	end
	return nil
end

function OilTankService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
end

function OilTankService:_upgrade(player: Player, oilType: string)
	local ok, code, message, data = self._oilStateService:TryUpgradeTank(player.UserId, oilType)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "UpgradeOilTank",
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function OilTankService:_hookPrompt(prompt: ProximityPrompt)
	table.insert(self._connections, prompt.Triggered:Connect(function(player)
		local oilType = oilTypeOfPrompt(prompt)
		if not oilType then return end
		local ownerUserId = plotOwnerOf(prompt)
		if ownerUserId and ownerUserId ~= player.UserId then
			self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
				action = "UpgradeOilTank",
				ok = false,
				code = "NOT_OWNER",
				message = "This is not your plot.",
			})
			return
		end
		self:_upgrade(player, oilType)
	end))
end

function OilTankService:Start()
	local upgradeEvent = self._remoteService:GetEvent(RemoteNames.RequestUpgradeOilTank)
	table.insert(self._connections, upgradeEvent.OnServerEvent:Connect(function(player, payload)
		local oilType = typeof(payload) == "table" and tostring(payload.oilType) or nil
		if not oilType then return end
		self:_upgrade(player, oilType)
	end))

	-- Hook all existing TankUpgradePrompts + any added later (plot clones, re-spawns).
	local function scan(root: Instance)
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "TankUpgradePrompt" then
				self:_hookPrompt(d)
			end
		end
	end
	scan(workspace)
	table.insert(self._connections, workspace.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") and d.Name == "TankUpgradePrompt" then
			self:_hookPrompt(d)
		end
	end))
end

function OilTankService:Stop()
	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._connections = {}
end

return OilTankService
