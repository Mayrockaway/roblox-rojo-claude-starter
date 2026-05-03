--!strict
--- Shows a hovering "FREE LOOT!" arrow pointing at the nearest ocean crate.
--- Only appears after FTUE is complete and until the player opens their first crate.
--- Persisted via OilState datastore — once a crate is claimed, never shows again.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local LocalPlayer = Players.LocalPlayer
local FTUE_STEP_ATTR = Constants.FtueStepAttribute

local function waitForFtueComplete()
	if FtueConfig.Enabled ~= true then return end
	while true do
		local step = LocalPlayer:GetAttribute(FTUE_STEP_ATTR)
		if step == nil or step == FtueConfig.Step.Done then
			return
		end
		LocalPlayer:GetAttributeChangedSignal(FTUE_STEP_ATTR):Wait()
	end
end

--- Fetch the persisted flag from the OilState snapshot.
local function isPointerDone(): boolean
	local remotes = Shared:WaitForChild("Remotes", 10)
	if not remotes then return false end
	local requestOilSnapshot = remotes:FindFirstChild(RemoteNames.RequestOilSnapshot)
	if not requestOilSnapshot or not requestOilSnapshot:IsA("RemoteFunction") then return false end
	local ok, snap = pcall(function()
		return requestOilSnapshot:InvokeServer()
	end)
	if ok and typeof(snap) == "table" and typeof((snap :: any).state) == "table" then
		return (snap :: any).state.flotsamCratePointerDone == true
	end
	return false
end

local function findNearestCrate(): Model?
	local folder = Workspace:FindFirstChild("RuntimeFlotsam")
	if not folder then return nil end
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return nil end

	local bestDist = math.huge
	local bestCrate: Model? = nil
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local primary = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
			if primary then
				local dist = (primary.Position - hrp.Position).Magnitude
				if dist < bestDist then
					bestDist = dist
					bestCrate = child
				end
			end
		end
	end
	return bestCrate
end

local function createPointerGui(): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = "CrateLootPointer"
	bb.Size = UDim2.fromOffset(120, 80)
	bb.StudsOffset = Vector3.new(0, 8, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 300
	bb.ResetOnSpawn = false

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 0, 35)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(255, 255, 50)
	label.Text = "FREE LOOT!"
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Parent = bb

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.Size = UDim2.new(1, 0, 0, 40)
	arrow.Position = UDim2.new(0, 0, 0, 32)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = 36
	arrow.TextColor3 = Color3.fromRGB(255, 255, 50)
	arrow.Text = "▼"
	arrow.TextStrokeTransparency = 0
	arrow.TextStrokeColor3 = Color3.new(0, 0, 0)
	arrow.Parent = bb

	return bb
end

task.spawn(function()
	-- Check persisted flag first
	if isPointerDone() then return end

	-- Wait for FTUE
	waitForFtueComplete()
	task.wait(3)

	-- Re-check after FTUE (snapshot may have updated)
	if isPointerDone() then return end

	-- Wait for crates to exist
	local folder = Workspace:WaitForChild("RuntimeFlotsam", 30)
	if not folder then return end
	while #folder:GetChildren() == 0 do
		folder.ChildAdded:Wait()
	end

	if isPointerDone() then return end

	local destroyed = false
	local activePointers: { [Model]: BillboardGui } = {}
	local MAX_POINTER_DIST = 250 -- only show on crates within visible range

	local function refreshPointers()
		if destroyed then return end
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then return end

		local seen: { [Model]: boolean } = {}

		for _, child in folder:GetChildren() do
			if not child:IsA("Model") then continue end
			local part = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
			if not part then continue end

			local dist = (part.Position - hrp.Position).Magnitude
			if dist <= MAX_POINTER_DIST then
				seen[child] = true
				if not activePointers[child] then
					local gui = createPointerGui()
					gui.Adornee = part
					gui.Parent = part
					activePointers[child] = gui
				end
			end
		end

		-- Remove pointers for crates that are gone or out of range
		for crate, gui in pairs(activePointers) do
			if not seen[crate] or not crate.Parent then
				gui:Destroy()
				activePointers[crate] = nil
			end
		end
	end

	refreshPointers()

	-- Update every 2 seconds
	task.spawn(function()
		while not destroyed do
			refreshPointers()
			task.wait(2)
		end
	end)

	-- Bob animation for all active pointers
	local bobConn = RunService.Heartbeat:Connect(function()
		local bob = math.sin(os.clock() * 3) * 1.5
		for _, gui in pairs(activePointers) do
			gui.StudsOffset = Vector3.new(0, 8 + bob, 0)
		end
	end)

	-- Listen for first crate claim to remove pointer
	local remotes = require(script.Parent:WaitForChild("GetClientRemotes"))()
	if remotes and remotes.flotsamCrateReward then
		remotes.flotsamCrateReward.OnClientEvent:Once(function()
			destroyed = true
			bobConn:Disconnect()
			for _, gui in pairs(activePointers) do
				gui:Destroy()
			end
			table.clear(activePointers)
		end)
	end
end)
