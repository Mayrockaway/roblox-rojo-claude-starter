--!strict
-- IdleBoatBob: gently rocks any Model tagged with attribute `IsIdleBob = true`
-- sitting under (currently) `workspace.Map.MapDecor.dOCKS.Boats`. Runs fully
-- client-side — no network cost. When the attribute clears (CheckoutBoat)
-- or the boat is destroyed, the loop stops.
--
-- Resolution mirrors the server's `BoatDockService.getDocksRoot`: try the
-- legacy direct-child names first (in case authoring moves the folder
-- back under Workspace), then fall back to a recursive descendant search
-- (which is how it currently lives at `Workspace.Map.MapDecor.dOCKS`).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BOB_Y_AMPLITUDE = 0.2
local BOB_Y_RATE = 1.2
local PITCH_AMPLITUDE = 0.02
local PITCH_RATE = 0.7
local ROLL_AMPLITUDE = 0.03
local ROLL_RATE = 0.9

local tracked: { [Model]: { RBXScriptConnection } } = {}

local function stopTracking(boat: Model)
	local conns = tracked[boat]
	if not conns then return end
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	tracked[boat] = nil
end

local function startTracking(boat: Model)
	if tracked[boat] then return end
	local base = boat:GetAttribute("DockCFrame")
	if typeof(base) ~= "CFrame" then return end
	local phase = (boat:GetAttribute("SlotIndex") or 0) * 0.53
	local conns = {} :: { RBXScriptConnection }
	tracked[boat] = conns

	-- Stop if IsIdleBob is cleared (e.g. checkout into sailing state).
	table.insert(conns, boat:GetAttributeChangedSignal("IsIdleBob"):Connect(function()
		if not boat:GetAttribute("IsIdleBob") then
			stopTracking(boat)
		end
	end))
	-- Stop on destroy.
	table.insert(conns, boat.AncestryChanged:Connect(function(_, parent)
		if not parent then stopTracking(boat) end
	end))
	-- Per-frame bob.
	table.insert(conns, RunService.Heartbeat:Connect(function()
		if not boat.Parent then stopTracking(boat); return end
		local t = os.clock() + phase
		local cf = base
			* CFrame.new(0, math.sin(t * BOB_Y_RATE) * BOB_Y_AMPLITUDE, 0)
			* CFrame.Angles(
				math.sin(t * PITCH_RATE) * PITCH_AMPLITUDE,
				0,
				math.cos(t * ROLL_RATE) * ROLL_AMPLITUDE
			)
		boat:PivotTo(cf)
	end))
end

local function considerInstance(inst: Instance)
	if not inst:IsA("Model") then return end
	if inst:GetAttribute("IsIdleBob") then
		startTracking(inst)
	else
		-- Sometimes the model appears before the attribute is set; listen for it.
		local c
		c = inst:GetAttributeChangedSignal("IsIdleBob"):Connect(function()
			if inst:GetAttribute("IsIdleBob") then
				startTracking(inst)
			end
		end)
		-- GC when the boat leaves.
		inst.AncestryChanged:Connect(function(_, parent)
			if not parent and c then
				pcall(function() c:Disconnect() end)
			end
		end)
	end
end

local function watchBoats(folder: Instance)
	for _, child in ipairs(folder:GetChildren()) do
		considerInstance(child)
	end
	folder.ChildAdded:Connect(considerInstance)
end

--- Try the cheap direct-child names first, then a single recursive
--- descendant search. Returns nil if nothing matched.
local function findDocksNow(): Instance?
	return Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
		or Workspace:FindFirstChild("dOCKS", true) -- e.g. Workspace.Map.MapDecor.dOCKS
		or Workspace:FindFirstChild("Docks", true)
		or Workspace:FindFirstChild("DOCKS", true)
end

--- Poll `findDocksNow` for up to `timeoutSeconds`. Polling (vs `WaitForChild`)
--- because `WaitForChild` doesn't accept recursive lookups, and the folder
--- has been re-parented under `Map.MapDecor` so a direct-child wait would
--- never resolve.
local function waitForDocks(timeoutSeconds: number): Instance?
	local deadline = os.clock() + timeoutSeconds
	while true do
		local docks = findDocksNow()
		if docks then
			return docks
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(0.5)
	end
end

local function waitForBoatsFolder()
	local docks = waitForDocks(30)
	if not docks then
		warn("[IdleBoatBob] dOCKS folder not found in workspace after 30s; boats will not rock.")
		return
	end
	local boats = docks:FindFirstChild("Boats")
	if boats then
		watchBoats(boats)
		return
	end
	-- Wait for the folder to appear (server creates on first spawn).
	docks.ChildAdded:Connect(function(c)
		if c.Name == "Boats" and c:IsA("Folder") then
			watchBoats(c)
		end
	end)
end

waitForBoatsFolder()
