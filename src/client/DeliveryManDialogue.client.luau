--!strict
-- DeliveryManDialogue (legacy filename): the on-NPC dialogue (Ship Oil / Sell
-- Locally / back) was removed once `ShipOilPanelGui` grew its own inline
-- "Sell" + "Dispatch" actions — there is no longer anything to choose between
-- before opening the manifest.
--
-- This script now does just two things:
--   1. Opens `ShipOilPanelGui` directly when the per-plot `DeliveryManPrompt`
--      (cloned from `ReplicatedStorage.Assets.PlotDispatch.Model.
--      StarterCharacter.HumanoidRootPart`) is triggered.
--   2. Spawns the floating "Ship Oil" billboard marker over the player's own
--      DeliveryMan head so the dispatch point is still discoverable from
--      across the plot.
--
-- Filename intentionally kept (1:1 with the rojo entry under
-- `StarterPlayerScripts.Client`) so renaming does not risk breaking other
-- bootstrap order assumptions.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Resolve HudPanelRouter (same path the previous dialogue used for the "Ship
-- Oil" choice — keeps panel-open behavior 1:1 with that branch).
local playerScripts = player:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client", 30)
local uiFolder = clientFolder and clientFolder:WaitForChild("UI", 10)
local HudPanelRouter = uiFolder and require(uiFolder:WaitForChild("HudPanelRouter"))
-- Ship Oil marker is visible from the entire beach/docks area and remains
-- visible (but smaller) when on the strait or at the warehouse.
local MARKER_VISIBLE_DISTANCE = 9999

-- Floating "Ship Oil" marker — client-side only, on the player's own plot.
-- Bobs gently above the DeliveryMan's head so the dispatch point is visible
-- from across the plot before the player walks into prompt range.
task.spawn(function()
	local markerGui: BillboardGui? = nil
	local markerHead: BasePart? = nil

	local function tryCreateMarker()
		if markerGui and markerGui.Parent then
			markerGui:Destroy()
		end
		markerGui = nil
		markerHead = nil

		local plotId = player:GetAttribute("PlotId")
		if not plotId then
			return
		end
		local map = Workspace:FindFirstChild("Map")
		local plots = map and map:FindFirstChild("Plots")
		if not plots then
			return
		end
		for _, plot in ipairs(plots:GetChildren()) do
			local id = plot:GetAttribute("PlotId") or tonumber(plot.Name:match("%d+"))
			if id == plotId then
				local dispatch = plot:FindFirstChild("PlotDispatch")
				if not dispatch then
					continue
				end
				local sc = dispatch:FindFirstChild("StarterCharacter", true)
				local head = sc and sc:FindFirstChild("Head")
				if not head then
					continue
				end

				local bb = Instance.new("BillboardGui")
				bb.Name = "ShipOilMarkerGui"
				bb.Size = UDim2.fromOffset(200, 110)
				bb.StudsOffset = Vector3.new(0, 10, 0)
				bb.AlwaysOnTop = true
				bb.LightInfluence = 0
				bb.Adornee = head
				bb.Parent = playerGui

				local arrow = Instance.new("TextLabel")
				arrow.Name = "Arrow"
				arrow.Size = UDim2.new(1, 0, 0.5, 0)
				arrow.Position = UDim2.fromScale(0, 0.5)
				arrow.BackgroundTransparency = 1
				arrow.Font = Enum.Font.LuckiestGuy
				arrow.TextScaled = true
				arrow.Text = "▼"
				arrow.TextColor3 = Color3.fromRGB(50, 220, 80)
				arrow.TextTransparency = 0.4
				arrow.TextStrokeTransparency = 0.6
				arrow.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				arrow.Parent = bb

				local label = Instance.new("TextLabel")
				label.Name = "Text"
				label.Size = UDim2.new(1, 0, 0.5, 0)
				label.Position = UDim2.fromScale(0, 0)
				label.BackgroundTransparency = 1
				label.Font = Enum.Font.LuckiestGuy
				label.TextScaled = true
				label.Text = "Ship Oil"
				label.TextColor3 = Color3.fromRGB(50, 220, 80)
				label.TextTransparency = 0.4
				label.TextStrokeTransparency = 0.6
				label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				label.Parent = bb

				markerGui = bb
				markerHead = head
				break
			end
		end
	end

	player:GetAttributeChangedSignal("PlotId"):Connect(tryCreateMarker)
	task.delay(3, tryCreateMarker)

	-- Bob animation + distance-aware scaling:
	--   Close (< 20 studs):   1x base size
	--   Beach/docks (20-150): scales UP to 2x so it's a landmark from the docks
	--   Far (> 300, strait/warehouse): shrinks to 0.6x — still visible, just smaller
	local MARKER_BASE_W = 200
	local MARKER_BASE_H = 110
	local t = 0
	RunService.Heartbeat:Connect(function(dt)
		t = t + dt
		if markerGui and markerGui.Parent then
			local offset = math.sin(t * 2) * 0.8
			markerGui.StudsOffset = Vector3.new(0, 10 + offset, 0)
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local inRange = false
			if hrp and hrp:IsA("BasePart") and markerHead and markerHead.Parent then
				inRange = (hrp.Position - markerHead.Position).Magnitude <= MARKER_VISIBLE_DISTANCE
			end
			markerGui.Enabled = inRange
			if inRange then
				local cam = Workspace.CurrentCamera
				if cam and markerHead and markerHead.Parent then
					local dist = (cam.CFrame.Position - markerHead.Position).Magnitude
					local scale: number
					if dist < 20 then
						scale = 1.0
					elseif dist < 150 then
						-- Lerp from 1x → 2x across the beach/docks range
						scale = 1.0 + (dist - 20) / (150 - 20)
					elseif dist < 300 then
						-- Lerp from 2x → 0.6x as you sail away
						scale = 2.0 - 1.4 * (dist - 150) / (300 - 150)
					else
						scale = 0.6
					end
					markerGui.Size = UDim2.new(0, math.round(MARKER_BASE_W * scale), 0, math.round(MARKER_BASE_H * scale))
				end
			end
		end
	end)
end)

-- DeliveryManPrompt → open `ShipOilPanelGui` directly. The panel already owns
-- both "instant sell" and "dispatch shipment" actions, so there is no
-- intermediate choice to present. Prompt's `ActionText` is authored as
-- "Ship Oil" on the template to match this behavior.
ProximityPromptService.PromptTriggered:Connect(function(prompt, trigPlayer)
	if trigPlayer ~= player then
		return
	end
	if prompt.Name ~= "DeliveryManPrompt" then
		return
	end
	if HudPanelRouter then
		HudPanelRouter.openScreen("ShipOilPanelGui")
	end
end)
