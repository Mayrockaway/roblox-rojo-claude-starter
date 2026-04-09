--!strict

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local VisualService = {}

function VisualService:Init()
	local folder = Workspace:FindFirstChild(Constants.WorldVisualsFolderName)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = Constants.WorldVisualsFolderName
		folder.Parent = Workspace
	end
	self._folder = folder
	self._active = {}
end

function VisualService:Start()
	-- no-op
end

function VisualService:Stop()
	for _, visual in pairs(self._active) do
		if visual.part and visual.part.Parent then
			visual.part:Destroy()
		end
	end
	self._active = {}
end

function VisualService:SpawnTanker(shipmentId: string, playerUserId: number, durationSeconds: number)
	if self._active[shipmentId] ~= nil then
		return
	end

	local xOffset = ((playerUserId % 12) - 6) * 8
	local startPosition = Vector3.new(xOffset, 15, -180)
	local endPosition = Vector3.new(xOffset, 15, 180)

	local tanker = Instance.new("Part")
	tanker.Name = "Tanker_" .. shipmentId
	tanker.Anchored = false
	tanker.CanCollide = true
	tanker.Massless = false
	tanker.Size = Vector3.new(14, 4, 8)
	tanker.Color = Color3.fromRGB(47, 79, 120)
	tanker.Material = Enum.Material.Metal
	tanker.Position = startPosition
	tanker.Parent = self._folder

	local tween = TweenService:Create(tanker, TweenInfo.new(math.max(1, durationSeconds), Enum.EasingStyle.Linear), {
		Position = endPosition,
	})
	tween:Play()

	self._active[shipmentId] = {
		part = tanker,
		tween = tween,
	}
end

function VisualService:MarkDamage(shipmentId: string)
	local visual = self._active[shipmentId]
	if visual == nil or visual.part == nil then
		return
	end
	visual.part.Color = Color3.fromRGB(198, 122, 62)
	task.delay(0.4, function()
		if visual.part and visual.part.Parent then
			visual.part.Color = Color3.fromRGB(47, 79, 120)
		end
	end)
end

function VisualService:ResolveShipment(shipmentId: string, destroyed: boolean)
	local visual = self._active[shipmentId]
	if visual == nil then
		return
	end

	if destroyed and visual.part and visual.part.Parent then
		local blast = Instance.new("Part")
		blast.Anchored = true
		blast.CanCollide = false
		blast.Shape = Enum.PartType.Ball
		blast.Material = Enum.Material.Neon
		blast.Color = Color3.fromRGB(255, 128, 45)
		blast.Size = Vector3.new(1, 1, 1)
		blast.Position = visual.part.Position
		blast.Parent = self._folder

		local tween = TweenService:Create(blast, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(20, 20, 20),
			Transparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			blast:Destroy()
		end)
	end

	if visual.tween then
		visual.tween:Cancel()
	end
	if visual.part and visual.part.Parent then
		visual.part:Destroy()
	end
	self._active[shipmentId] = nil
end

return VisualService
