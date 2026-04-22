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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Responsive scaler (per-viewport `Size` rescale, shared across the game's
-- runtime BillboardGuis — pump label, drill timer, plot owner plate, refinery
-- tank holos, tile hover focus). The Ship Oil marker now opts in too so
-- mobile gets a smaller pixel footprint; distance scaling below stays on a
-- separate `UIScale` child so the two systems don't race over `Size`.
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ResponsiveBillboard = require(Shared:WaitForChild("Utils"):WaitForChild("ResponsiveBillboard"))

-- Resolve HudPanelRouter (same path the previous dialogue used for the "Ship
-- Oil" choice — keeps panel-open behavior 1:1 with that branch).
local playerScripts = player:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client", 30)
local uiFolder = clientFolder and clientFolder:WaitForChild("UI", 10)
local HudPanelRouter = uiFolder and require(uiFolder:WaitForChild("HudPanelRouter"))
-- Ship Oil marker is plot-local: visible while the player is on/near their
-- own plot and the immediate docks approach, hidden once they sail out onto
-- the strait or wander into other zones (warehouse / shop / armies). Range
-- chosen to comfortably cover one plot footprint + the dock walk-up but
-- *not* be visible across the strait — there's no point pointing at a
-- dispatch NPC the player can't actually walk to from where they are.
--
-- Two layers of culling, both keyed off this same constant so they stay in
-- lockstep:
--   1. `BillboardGui.MaxDistance` (engine-native, camera-based) — the GPU
--      stops rendering the billboard once the camera is past this many
--      studs. Cheapest possible cull.
--   2. The Heartbeat `inRange` check below (character-based) — covers the
--      "camera flying around" / scriptable camera case where camera distance
--      is misleading vs where the character actually is. We also use this
--      gate to skip the per-frame distance-scale write when out of range.
local MARKER_VISIBLE_DISTANCE = 260

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
				-- Design-target pixel size at the reference viewport
				-- (1366 wide). The shared client controller rescales this
				-- per-viewport so phones, 1080p, and 4K all read at the same
				-- on-screen proportion. Distance falloff (1.0× near → 2.0×
				-- across the plot/docks) is applied below via a `UIScale`
				-- child instead of mutating Size, so the two systems stay
				-- orthogonal (Size = viewport, UIScale = camera distance).
				ResponsiveBillboard.Mark(bb, 200, 110)
				bb.StudsOffset = Vector3.new(0, 10, 0)
				bb.AlwaysOnTop = true
				bb.LightInfluence = 0
				-- Engine-native distance cull: once the camera is more than
				-- `MARKER_VISIBLE_DISTANCE` studs from the head this stops
				-- being submitted for rendering at all. Pairs with the
				-- character-distance `inRange` gate in the Heartbeat loop;
				-- whichever fires first hides the marker.
				bb.MaxDistance = MARKER_VISIBLE_DISTANCE
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

	-- Bob animation + distance-aware scaling. The marker is now plot-local
	-- (culled past `MARKER_VISIBLE_DISTANCE`), so the previous "shrinks to
	-- 0.6× from the strait" tail is gone — within the visible range we lerp
	-- the icon UP slightly with distance so it reads as a landmark from
	-- across the plot, then clamps at the upper end of the range:
	--   Close (< 20 studs):   1.0x base size
	--   Plot / docks walk:    1.0x → 2.0x lerp across (20 → MARKER_VISIBLE_DISTANCE)
	--   At cull boundary:     2.0x (then engine MaxDistance hides it)
	-- Distance scale is applied through a child `UIScale` so the responsive
	-- controller (which writes `Size` per viewport) and this loop don't fight
	-- over the same property. Final on-screen size = viewport-rescaled `Size`
	-- × `UIScale.Scale`.
	local DISTANCE_SCALE_NAME = "ShipOilDistanceScale"
	local function ensureDistanceScale(billboard: BillboardGui): UIScale
		local existing = billboard:FindFirstChild(DISTANCE_SCALE_NAME)
		if existing and existing:IsA("UIScale") then
			return existing
		end
		if existing then
			existing:Destroy()
		end
		local s = Instance.new("UIScale")
		s.Name = DISTANCE_SCALE_NAME
		s.Scale = 1
		s.Parent = billboard
		return s
	end
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
					else
						-- Lerp 1x → 2x across the visible range so the
						-- marker grows into a landmark as the player walks
						-- their plot. Capped at 2x once the camera reaches
						-- the cull boundary; beyond that the engine
						-- `MaxDistance` hides the billboard entirely so we
						-- never need a "shrink past X" tail anymore.
						local span = math.max(1, MARKER_VISIBLE_DISTANCE - 20)
						local t = math.clamp((dist - 20) / span, 0, 1)
						scale = 1.0 + t
					end
					local s = ensureDistanceScale(markerGui)
					if math.abs(s.Scale - scale) > 0.005 then
						s.Scale = scale
					end
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
