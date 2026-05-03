--!strict
--- Single-script replacement for 88 individual conveyor while-true loops.
--- Updates all conveyor belt velocities in one Heartbeat connection.
--- Each ConveyorFill_*/Conveyor part gets Velocity = lookVector * SPEED.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SPEED = 120
local UPDATE_INTERVAL = 0.1 -- match original script timing

local map = Workspace:WaitForChild("Map", 30)
if not map then
	warn("[ConveyorManager] No Workspace.Map found.")
	return
end

local function collectConveyorParts(folder: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, model in folder:GetChildren() do
		local conv = model:FindFirstChild("Conveyor")
		if conv and conv:IsA("BasePart") then
			table.insert(parts, conv)
		end
	end
	return parts
end

local allConveyors: { BasePart } = {}

local forward = map:FindFirstChild("ConveyorBeltForward")
if forward then
	for _, p in collectConveyorParts(forward) do
		table.insert(allConveyors, p)
	end
end

local backward = map:FindFirstChild("ConveyorBeltBackward")
if backward then
	for _, p in collectConveyorParts(backward) do
		table.insert(allConveyors, p)
	end
end

print("[ConveyorManager] Managing " .. #allConveyors .. " conveyor parts in 1 script.")

-- Disable any inline conveyor scripts (belt-and-suspenders in case MCP disable didn't persist)
for _, part in allConveyors do
	for _, child in part:GetChildren() do
		if child:IsA("Script") and child.Enabled then
			child.Enabled = false
		end
	end
end

-- Single update loop for all conveyors
local elapsed = 0
RunService.Heartbeat:Connect(function(dt)
	elapsed += dt
	if elapsed < UPDATE_INTERVAL then return end
	elapsed = 0

	for _, part in allConveyors do
		if part.Parent then
			part.Velocity = part.CFrame.LookVector * SPEED
		end
	end
end)
