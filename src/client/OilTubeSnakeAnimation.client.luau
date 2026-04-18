--!strict
-- OilTubeSnakeAnimation: client-side Heartbeat loop that animates all OilTube_ folders
-- with snake-like undulation. Finds tube segments (Seg_0, Seg_1, ...) and applies
-- a traveling sine wave offset to each.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Cache: tubeFolder -> { segments: {Part}, basePositions: {Vector3}, startTime: number }
local tubeCache: { [Instance]: { segments: { BasePart }, basePositions: { Vector3 }, startTime: number, isRainbow: boolean } } = {}

local function discoverTubes()
	-- Find all OilTube_ folders anywhere under Workspace
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Folder") and desc.Name:sub(1, 8) == "OilTube_" and not tubeCache[desc] then
			local segments: { BasePart } = {}
			local basePositions: { Vector3 } = {}
			for i = 0, 99 do
				local seg = desc:FindFirstChild("Seg_" .. i)
				if seg and seg:IsA("BasePart") then
					table.insert(segments, seg)
					table.insert(basePositions, seg.Position)
				end
			end
			if #segments > 0 then
				tubeCache[desc] = {
					segments = segments,
					basePositions = basePositions,
					startTime = math.random() * 10,
					isRainbow = desc:GetAttribute("Rainbow") == true,
				}
			end
		end
	end
	-- Prune destroyed folders
	for folder in pairs(tubeCache) do
		if not folder.Parent then
			tubeCache[folder] = nil
		end
	end
end

-- Discover periodically (new tubes spawn when drills complete)
task.spawn(function()
	while true do
		discoverTubes()
		task.wait(2)
	end
end)

-- Also discover when new descendants are added
Workspace.DescendantAdded:Connect(function(desc)
	if desc:IsA("Folder") and desc.Name:sub(1, 8) == "OilTube_" then
		task.defer(discoverTubes)
	end
end)

-- Animate every frame
local clock = 0
RunService.Heartbeat:Connect(function(dt)
	clock += dt
	for _, data in pairs(tubeCache) do
		local t = clock + data.startTime
		local segs = data.segments
		local bases = data.basePositions

		-- Rainbow color cycling for Gold Oil tubes
		if data.isRainbow then
			for i, seg in ipairs(segs) do
				local hue = (t * 0.3 + (i - 1) * 0.03) % 1
				seg.Color = Color3.fromHSV(hue, 0.8, 1)
			end
		end

		for i, seg in ipairs(segs) do
			local phase = t * 3.5 - (i - 1) * 0.25
			local offsetY = math.sin(phase) * 0.5
			local offsetZ = math.cos(phase * 0.8) * 0.4
			local bp = bases[i]
			local newPos = Vector3.new(bp.X, bp.Y + offsetY, bp.Z + offsetZ)

			local nextI = math.min(i + 1, #segs)
			local nextPhase = t * 3.5 - (nextI - 1) * 0.25
			local nbp = bases[nextI]
			local nextPos = Vector3.new(nbp.X, nbp.Y + math.sin(nextPhase) * 0.5, nbp.Z + math.cos(nextPhase * 0.8) * 0.4)

			if i < #segs then
				seg.CFrame = CFrame.lookAt(newPos, nextPos) * CFrame.Angles(0, math.rad(90), 0)
			else
				seg.CFrame = CFrame.new(newPos) * CFrame.Angles(0, math.rad(90), 0)
			end
		end
	end
end)
