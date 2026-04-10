--!strict
-- Template: Workspace.FXDev.Part — intermittent manual particle bursts (Studio only).
-- Sound object under Part is left untouched; only this Script is Rojo-synced (see default.project.json).

local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local part = script.Parent
if not part or not part:IsA("BasePart") then
	return
end

local emitter = part:FindFirstChild("ParticleEmitter")
if not (emitter and emitter:IsA("ParticleEmitter")) then
	warn("[FXDev PaperBurstTest] Need sibling ParticleEmitter.")
	return
end

local rng = Random.new()

local function burst()
	emitter.Rate = 0
	emitter.Enabled = true
	emitter:Emit(rng:NextInteger(10, 18))
	task.delay(0.08, function()
		emitter.Enabled = false
	end)
end

task.wait(0.65)
burst()
while emitter.Parent and part.Parent do
	local gap = rng:NextNumber(1.35, 2.85)
	if rng:NextNumber() < 0.3 then
		gap += rng:NextNumber(0.55, 1.5)
	end
	task.wait(gap)
	if emitter.Parent == nil then
		break
	end
	burst()
end
