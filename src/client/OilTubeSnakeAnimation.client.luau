--!strict
-- OilTubeSnakeAnimation: client-side animation for oil tubes.
-- Reveal timing comes from server-authored attributes so rejoins and upgrades stay deterministic.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TUBE_VISIBLE_TRANSPARENCY = 0.25
local BEAM_VISIBLE_TRANSPARENCY = 0.1

type TubeEntry = {
	segments: { BasePart },
	basePositions: { Vector3 },
	startTime: number,
	isRainbow: boolean,
	prevAnimTangent: Vector3?,
	prevAnimRot: CFrame?,
}

type BeamEntry = {
	anchor: BasePart,
	beam: Beam,
	isRainbow: boolean,
}

local tubeCache: { [Instance]: TubeEntry } = {}
local beamCache: { [Instance]: BeamEntry } = {}

local function getRevealProgress(source: Instance): number
	local startedAt = source:GetAttribute("RevealStartedAt")
	if typeof(startedAt) ~= "number" then
		return 1
	end
	local duration = source:GetAttribute("RevealDuration")
	if typeof(duration) ~= "number" or duration <= 0 then
		return 1
	end
	return math.clamp((Workspace:GetServerTimeNow() - startedAt) / duration, 0, 1)
end

local function applyTubeReveal(folder: Instance, entry: TubeEntry): number
	local progress = getRevealProgress(folder)
	local segCount = math.max(1, #entry.segments)
	for index, seg in ipairs(entry.segments) do
		if progress >= 1 or ((index - 1) / segCount) <= progress then
			seg.Transparency = TUBE_VISIBLE_TRANSPARENCY
		else
			seg.Transparency = 1
		end
	end
	return progress
end

local function applyBeamReveal(source: Instance, beam: Beam)
	local progress = getRevealProgress(source)
	if progress <= 0 then
		beam.Transparency = NumberSequence.new(1)
		return
	end
	if progress >= 1 then
		beam.Transparency = NumberSequence.new(BEAM_VISIBLE_TRANSPARENCY)
		return
	end
	local fadeEdge = math.clamp(progress, 0.01, 0.99)
	local fadeWidth = 0.08
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, BEAM_VISIBLE_TRANSPARENCY),
		NumberSequenceKeypoint.new(math.max(0.001, fadeEdge - fadeWidth), BEAM_VISIBLE_TRANSPARENCY),
		NumberSequenceKeypoint.new(math.min(0.999, fadeEdge + fadeWidth), 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function tryRegisterTubeFolder(desc: Instance)
	if not (desc:IsA("Folder") and desc.Name:sub(1, 8) == "OilTube_") then
		return
	end
	local segments: { BasePart } = {}
	local basePositions: { Vector3 } = {}
	for i = 0, 99 do
		local seg = desc:FindFirstChild("Seg_" .. i)
		if seg and seg:IsA("BasePart") then
			table.insert(segments, seg)
			table.insert(basePositions, seg.Position)
		end
	end
	if #segments == 0 then
		tubeCache[desc] = nil
		return
	end
	local existing = tubeCache[desc]
	if existing and #existing.segments == #segments then
		return
	end
	local entry: TubeEntry = {
		segments = segments,
		basePositions = basePositions,
		startTime = if existing then existing.startTime else math.random() * 10,
		isRainbow = desc:GetAttribute("Rainbow") == true,
		prevAnimTangent = if existing then existing.prevAnimTangent else nil,
		prevAnimRot = if existing then existing.prevAnimRot else nil,
	}
	tubeCache[desc] = entry
	applyTubeReveal(desc, entry)
end

local function tryRegisterOilStreamBeam(desc: Instance)
	if not (desc:IsA("Beam") and desc.Name == "OilStream") or beamCache[desc] then
		return
	end
	local anchor = desc.Parent
	if anchor and anchor:IsA("BasePart") then
		beamCache[desc] = {
			anchor = anchor,
			beam = desc,
			isRainbow = anchor:GetAttribute("Rainbow") == true,
		}
		applyBeamReveal(anchor, desc)
	end
end

--- One-time join / late-load sweep only (replaces the old **every 2s** `Workspace:GetDescendants` poll).
local function scanWorkspaceForTubesAndBeamsOnce()
	for _, desc in ipairs(Workspace:GetDescendants()) do
		tryRegisterTubeFolder(desc)
		tryRegisterOilStreamBeam(desc)
	end
end

local function pruneCaches()
	for folder in pairs(tubeCache) do
		if not folder.Parent then
			tubeCache[folder] = nil
		end
	end
	for beam in pairs(beamCache) do
		if not beam.Parent then
			beamCache[beam] = nil
		end
	end
end

task.defer(scanWorkspaceForTubesAndBeamsOnce)

Workspace.DescendantAdded:Connect(function(desc)
	if desc:IsA("Folder") and desc.Name:sub(1, 8) == "OilTube_" then
		task.defer(function()
			tryRegisterTubeFolder(desc)
		end)
	elseif desc:IsA("BasePart") and desc.Name:sub(1, 4) == "Seg_" then
		local p = desc.Parent
		if p and p:IsA("Folder") and p.Name:sub(1, 8) == "OilTube_" then
			task.defer(function()
				tryRegisterTubeFolder(p)
			end)
		end
	elseif desc:IsA("Beam") and desc.Name == "OilStream" then
		task.defer(function()
			tryRegisterOilStreamBeam(desc)
		end)
	end
end)

local clock = 0
RunService.Heartbeat:Connect(function(dt)
	clock += dt
	pruneCaches()

	for folder, data in pairs(tubeCache) do
		local progress = applyTubeReveal(folder, data)
		if progress <= 0 then
			continue
		end

		local t = clock + data.startTime
		local segs = data.segments
		local bases = data.basePositions

		if data.isRainbow then
			for i, seg in ipairs(segs) do
				local hue = (t * 0.3 + (i - 1) * 0.03) % 1
				seg.Color = Color3.fromHSV(hue, 0.8, 1)
			end
		end

		data.prevAnimRot = nil
		data.prevAnimTangent = nil
		for i, seg in ipairs(segs) do
			local endFade = 1
			if i <= 2 then
				endFade = (i - 1) / 2
			elseif i >= #segs - 2 then
				endFade = (#segs - i) / 3
			end
			endFade = math.clamp(endFade, 0, 1)

			local phase = t * 3.5 - (i - 1) * 0.25
			local offsetY = math.sin(phase) * 0.5 * endFade
			local offsetZ = math.cos(phase * 0.8) * 0.4 * endFade
			local bp = bases[i]
			local newPos = Vector3.new(bp.X, bp.Y + offsetY, bp.Z + offsetZ)

			local nextI = math.min(i + 1, #segs)
			local nextEndFade = 1
			if nextI <= 2 then
				nextEndFade = (nextI - 1) / 2
			elseif nextI >= #segs - 2 then
				nextEndFade = (#segs - nextI) / 3
			end
			nextEndFade = math.clamp(nextEndFade, 0, 1)

			local nextPhase = t * 3.5 - (nextI - 1) * 0.25
			local nbp = bases[nextI]
			local nextPos = Vector3.new(
				nbp.X,
				nbp.Y + math.sin(nextPhase) * 0.5 * nextEndFade,
				nbp.Z + math.cos(nextPhase * 0.8) * 0.4 * nextEndFade
			)

			local dir = nextPos - newPos
			if dir.Magnitude > 0.05 then
				local tangent = dir.Unit
				if i == 1 or not data.prevAnimTangent then
					seg.CFrame = CFrame.lookAt(newPos, nextPos) * CFrame.Angles(0, math.rad(90), 0)
					data.prevAnimRot = seg.CFrame - seg.CFrame.Position
				else
					local prevTangent = data.prevAnimTangent
					local prevRot = data.prevAnimRot
					if prevTangent and prevRot then
						local dot = math.clamp(prevTangent:Dot(tangent), -1, 1)
						local angle = math.acos(dot)
						local axis = prevTangent:Cross(tangent)
						if angle > 0.0001 and axis.Magnitude > 0.0001 then
							prevRot = CFrame.fromAxisAngle(axis.Unit, angle) * prevRot
						end
						data.prevAnimRot = prevRot
						seg.CFrame = CFrame.new(newPos) * prevRot
					end
				end
				data.prevAnimTangent = tangent
			end
		end
	end

	for _, entry in pairs(beamCache) do
		applyBeamReveal(entry.anchor, entry.beam)
		if entry.isRainbow then
			local hue = (clock * 0.3) % 1
			local hue2 = (clock * 0.3 + 0.3) % 1
			entry.beam.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, 0.8, 1)),
				ColorSequenceKeypoint.new(0.5, Color3.fromHSV((hue + 0.33) % 1, 0.8, 1)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(hue2, 0.8, 1)),
			})
		end
	end
end)
