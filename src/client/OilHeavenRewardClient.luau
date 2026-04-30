--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeavenRewardConfig = require(Shared:WaitForChild("Config"):WaitForChild("HeavenRewardConfig"))

local getClientRemotes = require(script.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local VeinCrateOpener = require(script.Parent:WaitForChild("UI"):WaitForChild("VeinCrateOpener"))
local ClientPlotGrid = require(script.Parent:WaitForChild("ClientPlotGrid"))

local OilHeavenRewardClient = {}

local started = false
local currentDoubleItemId: string? = nil
--- Controller returned by the most recent `VeinCrateOpener.OpenHeavenReward`.
--- We hold it across the async Robux-prompt round-trip so when the
--- `rewardDoubled` event lands we can call `setDoubled()` on the SAME open
--- lootbox to render the " x2!" suffix + gold stamp on the winner card.
--- Cleared when a new lootbox opens or when the player closes the current one.
local currentLootboxController: { setDoubled: () -> () }? = nil
local allRewards = HeavenRewardConfig.GetAllRewards()

local function setHeavenStatus(message: string, ok: boolean?)
	ClientPlotGrid.setStatus(message, ok)
end

local function setHeavenStatusLocked(message: string, color: Color3, holdSeconds: number)
	ClientPlotGrid.setStatusLocked(message, color, holdSeconds)
end

local function stabilizeHeavenDrillVisual(drill: Model)
	for _, desc in ipairs(drill:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.Massless = true
		elseif desc:IsA("Weld") and desc.Name == "AccessoryWeld" then
			desc.Enabled = false
		end
	end
end

function OilHeavenRewardClient.start()
	if started then
		return
	end
	started = true

	local remotes = getClientRemotes()
	local heavenRewardEvent = remotes.heavenRewardEvent :: RemoteEvent
	local requestPromptRobuxPurchase = remotes.requestPromptRobuxPurchase :: RemoteEvent
	local monetizationResult = remotes.monetizationResult :: RemoteEvent
	local requestHeavenDrill = remotes.requestHeavenDrill :: RemoteEvent

	-- Wire up Rebirth Drill tool activation → fire remote with mouse target
	local player = Players.LocalPlayer
	local function hookRebirthDrill(tool: Tool)
		if tool.Name ~= "Rebirth Drill" then return end
		tool.Activated:Connect(function()
			local mouse = player:GetMouse()
			requestHeavenDrill:FireServer(mouse.Target)
		end)
	end

	local function scanForDrills(container: Instance)
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				hookRebirthDrill(child)
			end
		end
		container.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				hookRebirthDrill(child)
			end
		end)
	end

	local backpack = player:WaitForChild("Backpack")
	scanForDrills(backpack)
	player.CharacterAdded:Connect(function(character)
		scanForDrills(character)
	end)
	if player.Character then
		scanForDrills(player.Character)
	end

	heavenRewardEvent.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		if payload.kind == "drillingStarted" and typeof(payload.position) == "table" then
			local pos = Vector3.new(payload.position.x, payload.position.y, payload.position.z)
			local assets = ReplicatedStorage:FindFirstChild("Assets")
			local template = assets and assets:FindFirstChild("Drill_Rebirth")
			if template then
				local drill = template:Clone()
				drill.Name = "HeavenDrill_Active"
				stabilizeHeavenDrillVisual(drill)

				-- Position drill on top of tile surface (pivot offset from bottom)
				local pivotToBottom = 0
				if drill:IsA("Model") then
					local bbCF, bbSize = drill:GetBoundingBox()
					pivotToBottom = bbCF.Position.Y - (bbCF.Position.Y - bbSize.Y / 2)
					drill:PivotTo(CFrame.new(pos.X, pos.Y + pivotToBottom, pos.Z))
				end
				drill.Parent = workspace

				-- Play drilling sound
				local sfxFolder = assets and assets:FindFirstChild("SFX")
				local drillSound: Sound? = nil
				if sfxFolder then
					for _, c in ipairs(sfxFolder:GetChildren()) do
						if c:IsA("Sound") and string.lower(c.Name) == "drilling" then
							drillSound = c:Clone()
							local host = drill:FindFirstChildWhichIsA("BasePart", true)
							if host then
								drillSound.Parent = host
								drillSound.Looped = true
								drillSound:Play()
							end
							break
						end
					end
				end

				local basePivot = CFrame.new(pos.X, pos.Y + pivotToBottom, pos.Z)
				local startTime = tick()
				local DRILL_DURATION = 3
				local BASE_RAD = 3
				local PEAK_RAD = 40
				local SINK_DEPTH = 5

				local conn: RBXScriptConnection
				conn = RunService.RenderStepped:Connect(function()
					local elapsed = tick() - startTime
					local alpha = math.clamp(elapsed / DRILL_DURATION, 0, 1)
					local spinAngle = elapsed * (BASE_RAD * alpha + PEAK_RAD * alpha * alpha * alpha / 3)
					local sink = SINK_DEPTH * alpha * alpha
					local offset = CFrame.new(0, -sink, 0) * CFrame.Angles(0, spinAngle, 0)
					if drill:IsA("Model") then
						drill:PivotTo(basePivot * offset)
					end
					if alpha >= 1 then
						conn:Disconnect()
						if drillSound then drillSound:Stop() end
						drill:Destroy()
					end
				end)
			end
			return
		end

		if payload.kind == "rewardGranted" and typeof(payload.reward) == "table" then
			currentDoubleItemId = if typeof(payload.doubleItemId) == "string" then payload.doubleItemId else HeavenRewardConfig.DoubleRewardMonetizationItemId
			local buttonText = string.format("2X REWARD - %d ROBUX", tonumber(payload.doublePriceRobux) or HeavenRewardConfig.DoubleRewardRobuxPrice)
			local heavenRewardAck = remotes.heavenRewardAcknowledged :: RemoteEvent
			currentLootboxController = VeinCrateOpener.OpenHeavenReward(payload.reward, allRewards, {
				onNext = function()
					currentLootboxController = nil
					heavenRewardAck:FireServer()
				end,
				onDoubleReward = function()
					if currentDoubleItemId then
						requestPromptRobuxPurchase:FireServer({ itemId = currentDoubleItemId })
					end
				end,
				doubleButtonText = buttonText,
			})
			return
		end

		if payload.kind == "rewardDoubled" and typeof(payload.reward) == "table" then
			-- Reveal lives on the lootbox itself, not the shared shipment-
			-- status banner. The lootbox is still open at this point (the
			-- player paid the Robux prompt while the lootbox sat behind the
			-- modal) — `setDoubled()` appends " x2!" to the winner card text
			-- and plants a gold "x2!" stamp on top. The world tile billboard
			-- separately picks up the suffix via `RefreshUnlocks` on the
			-- server, so the doubled state is visible both transiently
			-- (lootbox) and persistently (world tile).
			currentDoubleItemId = nil
			if currentLootboxController then
				currentLootboxController.setDoubled()
			end
		end
	end)

	monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local data = payload.data
		if typeof(data) ~= "table" then
			return
		end
		if data.itemId ~= HeavenRewardConfig.DoubleRewardMonetizationItemId then
			return
		end
		if payload.ok == true and payload.code == "PROMPT_OPENED" then
			setHeavenStatus("Opening Heaven reward purchase...", true)
			return
		end
		if payload.ok ~= true then
			setHeavenStatus(tostring(payload.message or "Heaven reward purchase failed."), false)
		end
	end)
end

return OilHeavenRewardClient
