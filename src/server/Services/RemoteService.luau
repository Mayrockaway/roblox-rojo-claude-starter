--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local RemoteService = {}

local remoteFunctionNames = {
	[RemoteNames.RequestOilSnapshot] = true,
	[RemoteNames.RequestMarketSnapshot] = true,
	[RemoteNames.RequestWarehouseSnapshot] = true,
	[RemoteNames.RequestEquipmentShopCatalog] = true,
	[RemoteNames.RequestPirateHireTargets] = true,
	[RemoteNames.RequestArmyGeneralTargets] = true,
	[RemoteNames.RequestMonetizationCatalog] = true,
	[RemoteNames.RequestCurrencyPackPreview] = true,
	[RemoteNames.RequestRebirthShopSnapshot] = true,
}

function RemoteService:Init()
	local remotesFolder = Shared:FindFirstChild("Remotes")
	if remotesFolder == nil then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = Shared
	end

	self._folder = remotesFolder

	for _, remoteName in pairs(RemoteNames) do
		if remoteFunctionNames[remoteName] then
			if remotesFolder:FindFirstChild(remoteName) == nil then
				local remoteFn = Instance.new("RemoteFunction")
				remoteFn.Name = remoteName
				remoteFn.Parent = remotesFolder
			end
		else
			if remotesFolder:FindFirstChild(remoteName) == nil then
				local remoteEvent = Instance.new("RemoteEvent")
				remoteEvent.Name = remoteName
				remoteEvent.Parent = remotesFolder
			end
		end
	end
end

function RemoteService:Start()
	-- no-op
end

function RemoteService:Stop()
	-- no-op
end

function RemoteService:GetEvent(name: string): RemoteEvent
	assert(self._folder ~= nil, "RemoteService not initialized.")
	local remote = self._folder:FindFirstChild(name)
	assert(remote and remote:IsA("RemoteEvent"), string.format("RemoteEvent '%s' is missing.", name))
	return remote
end

function RemoteService:GetFunction(name: string): RemoteFunction
	assert(self._folder ~= nil, "RemoteService not initialized.")
	local remote = self._folder:FindFirstChild(name)
	assert(remote and remote:IsA("RemoteFunction"), string.format("RemoteFunction '%s' is missing.", name))
	return remote
end

return RemoteService
