--!strict
-- Nuke countdown/detonation FX, airstrike sequence, Army General panel (`armyGeneralOpenEvent` / result).
-- Wired from `init.client` with `playEventSFX`, `setStatus`, and boat chunk FX from `StraitWaypointWorldFx`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type StrategicStrikeDeps = {
	player: Player,
	playerGui: PlayerGui,
	setStatus: (message: string, ok: boolean?) -> (),
	playEventSFX: (sfxName: string, volume: number?) -> (),
	explodeBoatIntoPieces: (boat: Instance, epicenter: Vector3?) -> (),
}

export type StrategicStrikeRemotes = {
	nukeCountdownEvent: RemoteEvent,
	nukeDetonateEvent: RemoteEvent,
	airStrikeEvent: RemoteEvent,
}

export type ArmyGeneralEarlyDeps = {
	-- `player` is required for the auto-close-on-walk-away heartbeat that
	-- watches `player.Character.HumanoidRootPart`. Without it the heartbeat
	-- inside `armyGeneralOpenEvent.OnClientEvent` indexes a `nil` upvalue
	-- every frame the panel is open and spams `attempt to index nil with 'Character'`.
	player: Player,
	playerGui: PlayerGui,
	setStatus: (message: string, ok: boolean?) -> (),
}

export type ArmyGeneralEarlyRemotes = {
	armyGeneralOpenEvent: RemoteEvent,
	armyGeneralResultEvent: RemoteEvent,
	requestArmyGeneralAction: RemoteEvent,
	requestArmyGeneralTargets: RemoteFunction,
	-- `requestPromptRobuxPurchase` routes the Launch-Nuke button through the
	-- Robux purchase funnel (`MonetizationCatalog.consumable.nuke_x1`) instead
	-- of firing `RequestArmyGeneralAction { action = "nuke" }` directly. The
	-- legacy direct action is still wired server-side as a Studio debug shortcut.
	requestPromptRobuxPurchase: RemoteEvent,
}

local StrategicStrikeClient = {}

--- Subscribe to `ArmyGeneralOpen` / result as soon as `setStatus` exists (same race as Pirate Hire).
function StrategicStrikeClient.connectArmyGeneralEarly(deps: ArmyGeneralEarlyDeps, remotes: ArmyGeneralEarlyRemotes)
	local player = deps.player
	local playerGui = deps.playerGui
	local setStatus = deps.setStatus
	local armyGeneralOpenEvent = remotes.armyGeneralOpenEvent
	local armyGeneralResultEvent = remotes.armyGeneralResultEvent
	local requestArmyGeneralAction = remotes.requestArmyGeneralAction
	local requestArmyGeneralTargets = remotes.requestArmyGeneralTargets
	local requestPromptRobuxPurchase = remotes.requestPromptRobuxPurchase

	-- =================== ARMY GENERAL PANEL UI ===================
	-- Army General dialogue — same visual style as Oilman (LuckiestGuy blocky text)
	armyGeneralOpenEvent.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end

		local existing = playerGui:FindFirstChild("ArmyGeneralGui")
		if existing then existing:Destroy() end

		local airstrikeCost = tonumber(data.airstrikeCost) or 10000
		local nukeCooldownRemaining = tonumber(data.nukeCooldownRemaining) or 0

		local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
		local COLOR_HOVER = Color3.fromRGB(255, 205, 80)

		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "ArmyGeneralGui"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 60
		screenGui.Parent = playerGui

		-- Auto-close when walking away
		local generalModel = Workspace:FindFirstChild("Army General", true)
		local autoCloseConn
		autoCloseConn = RunService.Heartbeat:Connect(function()
			if not screenGui.Parent then
				if autoCloseConn then autoCloseConn:Disconnect() end
				return
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and generalModel then
				if (hrp.Position - generalModel:GetPivot().Position).Magnitude > 12 then
					screenGui:Destroy()
					if autoCloseConn then autoCloseConn:Disconnect() end
				end
			end
		end)

		-- Root frame — center-right like Oilman
		local root = Instance.new("Frame")
		root.Name = "Root"
		root.BackgroundTransparency = 1
		root.BorderSizePixel = 0
		root.Active = false
		root.AnchorPoint = Vector2.new(0.5, 0.5)
		root.Position = UDim2.fromScale(0.68, 0.55)
		root.Size = UDim2.fromOffset(500, 320)
		root.Parent = screenGui

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = root

		local function blockyLine(name, text, order, isButton)
			local obj
			if isButton then
				obj = Instance.new("TextButton")
				obj.AutoButtonColor = false
				obj.Active = true
				obj.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				obj.BackgroundTransparency = 0.99
				obj.MouseEnter:Connect(function()
					obj.TextColor3 = COLOR_HOVER
					obj.BackgroundTransparency = 0.35
				end)
				obj.MouseLeave:Connect(function()
					obj.TextColor3 = COLOR_IDLE
					obj.BackgroundTransparency = 0.99
				end)
				local c = Instance.new("UICorner")
				c.CornerRadius = UDim.new(0, 6)
				c.Parent = obj
			else
				obj = Instance.new("TextLabel")
				obj.BackgroundTransparency = 1
			end
			obj.Name = name
			obj.Text = text
			obj.Size = UDim2.new(1, 0, 0, 42)
			obj.LayoutOrder = order
			obj.BorderSizePixel = 0
			obj.Font = Enum.Font.LuckiestGuy
			obj.TextSize = 34
			obj.TextColor3 = COLOR_IDLE
			obj.TextStrokeTransparency = 0
			obj.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			obj.TextXAlignment = Enum.TextXAlignment.Left
			obj.TextYAlignment = Enum.TextYAlignment.Center
			return obj
		end

		-- Header
		local header = blockyLine("Header", "Army General:", 1, false)
		header.Size = UDim2.new(1, 0, 0, 50)
		header.TextSize = 44
		header.Parent = root

		-- Launch Nuke (Robux purchase via `MonetizationCatalog.consumable.nuke_x1`)
		local nukeOnCooldown = nukeCooldownRemaining > 0
		local nukeText = if nukeOnCooldown
			then string.format("Nuke (cooldown %ds)", math.ceil(nukeCooldownRemaining))
			else "Launch Nuke (R$)"
		local nukeBtn = blockyLine("NukeButton", nukeText, 2, true)
		nukeBtn.Parent = root
		if nukeOnCooldown then
			nukeBtn.TextColor3 = Color3.fromRGB(140, 140, 140)
			nukeBtn.AutoButtonColor = false
		end

		-- Call Airstrike
		local airBtn = blockyLine("AirstrikeButton", string.format("Call Airstrike ($%d)", airstrikeCost), 3, true)
		airBtn.Parent = root

		-- Back
		local backBtn = blockyLine("BackButton", "back", 4, true)
		backBtn.TextSize = 28
		backBtn.TextColor3 = Color3.fromRGB(210, 210, 210)
		backBtn.MouseLeave:Connect(function()
			backBtn.TextColor3 = Color3.fromRGB(210, 210, 210)
		end)
		backBtn.Parent = root

		-- Close on back
		backBtn.MouseButton1Click:Connect(function()
			screenGui:Destroy()
		end)

		-- Nuke click — opens the Robux purchase prompt for `consumable.nuke_x1`.
		-- A successful receipt routes server-side through
		-- `MonetizationService` → `ArmyGeneralService:_executeNuke`.
		nukeBtn.MouseButton1Click:Connect(function()
			if nukeOnCooldown then
				return
			end
			requestPromptRobuxPurchase:FireServer({ itemId = "consumable.nuke_x1" })
			screenGui:Destroy()
		end)

		-- Airstrike click — show target list as additional blocky lines
		airBtn.MouseButton1Click:Connect(function()
			-- Remove existing target buttons
			for _, c in ipairs(root:GetChildren()) do
				if c.Name:find("Target_") then c:Destroy() end
			end

			-- Fetch targets
			local result = requestArmyGeneralTargets:InvokeServer()
			if typeof(result) ~= "table" or typeof(result.targets) ~= "table" then return end

			-- Replace the options with target list
			header.Text = "Pick Target:"
			nukeBtn.Visible = false
			airBtn.Visible = false

			local order = 5
			for _, target in ipairs(result.targets) do
				local label = target.displayName
				if not target.hasShipment then
					label = label .. " (no ship)"
				end
				local tBtn = blockyLine("Target_" .. tostring(target.userId), label, order, true)
				tBtn.TextSize = 28
				if not target.hasShipment then
					tBtn.TextColor3 = Color3.fromRGB(100, 100, 100)
				end
				tBtn.Parent = root
				order += 1

				if target.hasShipment then
					tBtn.MouseButton1Click:Connect(function()
						requestArmyGeneralAction:FireServer({ action = "airstrike", victimUserId = target.userId })
						screenGui:Destroy()
					end)
				end
			end

			if #result.targets == 0 then
				local noTargets = blockyLine("NoTargets", "No ships on the strait", 5, false)
				noTargets.TextSize = 28
				noTargets.TextColor3 = Color3.fromRGB(180, 80, 80)
				noTargets.Parent = root
			end

			-- Back returns to main menu
			backBtn.MouseButton1Click:Connect(function()
				screenGui:Destroy()
			end)
		end)
	end)

	-- Army General result messages
	armyGeneralResultEvent.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end
		setStatus(tostring(data.message or "?"), data.ok == true)
	end)
end

function StrategicStrikeClient.connect(deps: StrategicStrikeDeps, remotes: StrategicStrikeRemotes)
	local player = deps.player
	local playerGui = deps.playerGui
	local setStatus = deps.setStatus
	local playEventSFX = deps.playEventSFX
	local explodeBoatIntoPieces = deps.explodeBoatIntoPieces

	local nukeCountdownEvent = remotes.nukeCountdownEvent
	local nukeDetonateEvent = remotes.nukeDetonateEvent
	local airStrikeEvent = remotes.airStrikeEvent

	-- =================== NUKE COUNTDOWN ===================
	nukeCountdownEvent.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end
		local detonateAt = tonumber(data.detonateAt) or 0

		-- Play nuke SFX for ALL players immediately — audio is 12+ seconds long
		-- 0-2s: siren/buildup (nuke symbol shown, no countdown yet)
		-- 2s-12s: countdown plays over the audio
		-- 12s: detonation syncs with the audio explosion
		playEventSFX("TacNuke", 1.0)

		task.spawn(function()
			-- Full-screen countdown overlay
			local screenGui = Instance.new("ScreenGui")
			screenGui.Name = "NukeCountdown"
			screenGui.DisplayOrder = 100
			screenGui.ResetOnSpawn = false
			screenGui.Parent = playerGui

			-- No dark overlay — keep the game visible during countdown

			-- Nuke symbol
			local symbol = Instance.new("TextLabel")
			symbol.Size = UDim2.fromOffset(120, 120)
			symbol.Position = UDim2.new(0.5, -60, 0.3, -60)
			symbol.BackgroundTransparency = 1
			symbol.Text = "\xe2\x98\xa2" -- ☢
			symbol.TextColor3 = Color3.fromRGB(255, 50, 50)
			symbol.TextSize = 80
			symbol.Font = Enum.Font.Merriweather
			symbol.Parent = screenGui

			-- Warning text
			local warning = Instance.new("TextLabel")
			warning.Size = UDim2.new(0.8, 0, 0, 40)
			warning.Position = UDim2.new(0.1, 0, 0.45, 0)
			warning.BackgroundTransparency = 1
			warning.Text = "NUKE INCOMING"
			warning.TextColor3 = Color3.fromRGB(255, 50, 50)
			warning.TextSize = 40
			warning.Font = Enum.Font.Merriweather
			warning.TextStrokeTransparency = 0
			warning.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			warning.Parent = screenGui

			local subtext = Instance.new("TextLabel")
			subtext.Size = UDim2.new(0.8, 0, 0, 24)
			subtext.Position = UDim2.new(0.1, 0, 0.52, 0)
			subtext.BackgroundTransparency = 1
			subtext.Text = "ALL BOATS ON STRAIT AT RISK OF DESTRUCTION"
			subtext.TextColor3 = Color3.fromRGB(255, 200, 100)
			subtext.TextSize = 18
			subtext.Font = Enum.Font.Merriweather
			subtext.TextStrokeTransparency = 0.3
			subtext.Parent = screenGui

			local countdown = Instance.new("TextLabel")
			countdown.Size = UDim2.new(0.5, 0, 0, 80)
			countdown.Position = UDim2.new(0.25, 0, 0.6, 0)
			countdown.BackgroundTransparency = 1
			countdown.Text = ""
			countdown.TextColor3 = Color3.fromRGB(255, 255, 255)
			countdown.TextSize = 72
			countdown.Font = Enum.Font.Merriweather
			countdown.TextStrokeTransparency = 0
			countdown.Visible = false
			countdown.Text = ""
			countdown.Parent = screenGui

			-- First 2 seconds: just nuke symbol + audio playing, no countdown visible
			task.delay(2, function()
				if countdown.Parent then countdown.Visible = true end
			end)

			-- Flash warning text red/white
			task.spawn(function()
				while screenGui.Parent do
					warning.TextColor3 = Color3.fromRGB(255, 50, 50)
					task.wait(0.3)
					if not screenGui.Parent then break end
					warning.TextColor3 = Color3.fromRGB(255, 255, 255)
					task.wait(0.3)
				end
			end)

			-- Countdown timer
			while workspace:GetServerTimeNow() < detonateAt do
				local remaining = math.max(0, math.ceil(detonateAt - workspace:GetServerTimeNow()))
				countdown.Text = tostring(remaining)
				task.wait(0.1)
			end

			screenGui:Destroy()
		end)
	end)

	-- =================== NUKE DETONATION ===================
	nukeDetonateEvent.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end

		-- IMMEDIATELY clone the player's head BEFORE the server dismembers the character
		local nukeHeadClone = nil
		local nukeHeadStartPos = nil
		local localChar = player.Character
		local origHead = localChar and localChar:FindFirstChild("Head")
		if origHead and origHead:IsA("BasePart") then
			nukeHeadClone = origHead:Clone()
			nukeHeadClone.Name = "NukeDeathHead"
			nukeHeadClone.Anchored = false
			nukeHeadClone.CanCollide = false
			nukeHeadClone.CanQuery = false
			nukeHeadClone.CanTouch = false
			nukeHeadStartPos = origHead.Position
		end

		task.spawn(function()
			local Debris = game:GetService("Debris")

			-- WHITE FLASH: full screen overlay
			local flashGui = Instance.new("ScreenGui")
			flashGui.Name = "NukeFlash"
			flashGui.DisplayOrder = 200
			flashGui.Parent = playerGui
			local flash = Instance.new("Frame")
			flash.Size = UDim2.fromScale(1, 1)
			flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			flash.BackgroundTransparency = 0
			flash.BorderSizePixel = 0
			flash.Parent = flashGui

			-- Fade out the flash over 1.5 seconds
			task.spawn(function()
				local dur = 1.5
				local t0 = os.clock()
				while os.clock() - t0 < dur do
					local a = (os.clock() - t0) / dur
					flash.BackgroundTransparency = a
					task.wait()
				end
				flashGui:Destroy()
			end)

			-- MUSHROOM CLOUD: use the pre-positioned and pre-scaled template from Assets
			local assets = ReplicatedStorage:FindFirstChild("Assets")
			local cloudTemplate = assets and assets:FindFirstChild("MushroomCloud")
			if cloudTemplate then
				local cloud = cloudTemplate:Clone()
				for _, d in ipairs(cloud:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
					end
				end
				-- Template already has correct position and scale baked in
				if cloud:IsA("Model") then
					cloud:PivotTo(cloud:GetPivot())
				end
				cloud.Parent = workspace
				Debris:AddItem(cloud, 8)

				-- FADE OUT: cloud appears instantly, fades out before Debris kills it
				local cloudParts = {}
				local cloudOrigTrans = {}
				for _, p in ipairs(cloud:GetDescendants()) do
					if p:IsA("BasePart") then
						table.insert(cloudParts, p)
						cloudOrigTrans[p] = p.Transparency
					end
				end
				task.spawn(function()
					task.wait(5) -- visible for 5 seconds, then fade out over 3
					local fadeOutDur = 4
					local fo0 = os.clock()
					while os.clock() - fo0 < fadeOutDur do
						local a = math.min((os.clock() - fo0) / fadeOutDur, 1)
						for _, p in ipairs(cloudParts) do
							if p.Parent then
								local orig = cloudOrigTrans[p] or 0
								p.Transparency = orig + a * (1 - orig)
							end
						end
						task.wait()
					end
				end)
			end

			-- SCREEN SHAKE: massive
			local camera = workspace.CurrentCamera
			if camera then
				task.spawn(function()
					local intensity = 8
					local duration = 2
					local elapsed = 0
					local shakeRng = Random.new()
					while elapsed < duration do
						local dt = task.wait()
						elapsed += dt
						local fade = 1 - (elapsed / duration)
						camera.CFrame *= CFrame.new(
							shakeRng:NextNumber(-intensity, intensity) * fade,
							shakeRng:NextNumber(-intensity, intensity) * fade,
							0
						)
					end
				end)
			end

			-- BOATS FLY OFF: find all active shipment boats and fling them
			local shipments = data.shipments
			if typeof(shipments) == "table" then
				for _, info in ipairs(shipments) do
					task.spawn(function()
						local boat = nil
						for _, d in ipairs(workspace:GetDescendants()) do
							if d:IsA("Model") and d.Name == "ActiveShipmentBoat" and d:GetAttribute("ShipmentId") == info.shipmentId then
								boat = d
								break
							end
						end
						if not boat then return end

						local root = boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
						if not root then return end

						-- Calculate fly-off direction (away from strait center)
						local straitCenter = Vector3.new(-72, 3, 253)
						local flyDir = (root.Position - straitCenter)
						flyDir = Vector3.new(flyDir.X, 0, flyDir.Z)
						if flyDir.Magnitude < 1 then flyDir = Vector3.new(1, 0, 0) end
						flyDir = flyDir.Unit

						local startPos = root.Position
						local endPos = startPos + flyDir * 1500 + Vector3.new(0, -200, 0)
						local startCF = boat:GetPivot()

						-- Fly the boat off with arc
						local flyDur = 2.5
						local arcH = 200
						local ft0 = os.clock()
						while os.clock() - ft0 < flyDur do
							local a = math.min((os.clock() - ft0) / flyDur, 1)
							local e = a * a * (3 - 2 * a)
							local pos = startPos:Lerp(endPos, e)
							pos = pos + Vector3.new(0, arcH * math.sin(e * math.pi), 0)
							-- Add spin
							local spin = CFrame.Angles(e * 3, e * 5, e * 2)
							if boat:IsA("Model") then
								boat:PivotTo(CFrame.new(pos) * spin)
							end
							if a >= 1 then break end
							task.wait()
						end

						Debris:AddItem(boat, 1)
					end)
				end
			end

			-- NUKE DEATH CAM: two cases
			-- Case 1: player on land → do nothing, free cam sees explosion naturally
			-- Case 2: player on boat → head flies away from nuke, camera follows head
			local onBoat = false
			local localChar = player.Character
			local localHRP = localChar and localChar:FindFirstChild("HumanoidRootPart")
			if localHRP and localHRP:IsA("BasePart") then
				for _, d in ipairs(workspace:GetDescendants()) do
					if d:IsA("Model") and d.Name == "ActiveShipmentBoat" then
						local root = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
						if root and (root.Position - localHRP.Position).Magnitude < 80 then
							onBoat = true
							break
						end
					end
				end
			end

			if onBoat and nukeHeadClone then
				local camera = workspace.CurrentCamera
				if camera then
					task.spawn(function()
						-- Hide original character
						if localChar then
							for _, part in ipairs(localChar:GetDescendants()) do
								if part:IsA("BasePart") then part.Transparency = 1 end
							end
						end

						local cloudCenter = Vector3.new(25.9, 789.8, 179.9)
						local headStartPos = nukeHeadStartPos or localHRP.Position

						-- Direction AWAY from the nuke
						local awayDir = Vector3.new(headStartPos.X - cloudCenter.X, 0, headStartPos.Z - cloudCenter.Z)
						if awayDir.Magnitude < 1 then awayDir = Vector3.new(100, 0, 0) end
						awayDir = awayDir.Unit

						-- Head path: starts at player, SOARS way above the mushroom cloud
						-- Cloud is at Y=789, top at ~Y=1600. Head needs to go ABOVE that.
						local headStart = headStartPos + Vector3.new(0, 20, 0)
						local headEnd = headStart + awayDir * 1500 + Vector3.new(0, 2000, 0)

						-- Place head — BIG, ANCHORED, moved by CFrame only
						nukeHeadClone.Size = nukeHeadClone.Size * 4 -- 4x bigger
						nukeHeadClone.Anchored = true
						nukeHeadClone.CanCollide = false
						nukeHeadClone.CFrame = CFrame.new(headStart)
						nukeHeadClone.Parent = workspace
						-- Add glow so head is always visible
						local glow = Instance.new("PointLight")
						glow.Brightness = 3
						glow.Range = 30
						glow.Color = Color3.fromRGB(255, 200, 150)
						glow.Parent = nukeHeadClone
						Debris:AddItem(nukeHeadClone, 12)

						-- Lock camera
						camera.CameraType = Enum.CameraType.Scriptable
						local flyDur = 7
						local nukeCamDone = false

						local respawnConn
						respawnConn = player.CharacterAdded:Connect(function()
							nukeCamDone = true
							camera.CameraType = Enum.CameraType.Custom
							if respawnConn then respawnConn:Disconnect() end
						end)

						local tt0 = os.clock()
						while os.clock() - tt0 < flyDur and not nukeCamDone do
							local a = math.min((os.clock() - tt0) / flyDur, 1)
							local e = a * a * (3 - 2 * a)

							-- Move head along path (anchored, CFrame only)
							local headPos = headStart:Lerp(headEnd, e)
							local spin = CFrame.Angles(a * 12, a * 8, a * 6)
							nukeHeadClone.CFrame = CFrame.new(headPos) * spin

							-- Camera BEHIND the head, LOOKING AT the head
							-- Far enough back to see head + nuke behind it
							local camPos = headPos + awayDir * 25 + Vector3.new(0, 8, 0)
							camera.CFrame = CFrame.lookAt(camPos, headPos)

							task.wait()
						end

						if not nukeCamDone then
							camera.CameraType = Enum.CameraType.Custom
						end
						if respawnConn then respawnConn:Disconnect() end
					end)
				end
			end

			task.delay(6, function()
				setStatus("NUCLEAR STRIKE! All boats in the strait destroyed!", false)
				playEventSFX("ShipDestroyed")
			end)
		end)
	end)

	-- =================== AIRSTRIKE ===================
	airStrikeEvent.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end

		task.spawn(function()
			local Debris = game:GetService("Debris")
			local outcome = tostring(data.outcome or "miss")
			local victimName = tostring(data.victimName or "Unknown")
			local isVictim = data.victimUserId == player.UserId

			-- Parse positions
			local jetStart = data.jetStart and Vector3.new(data.jetStart.x, data.jetStart.y, data.jetStart.z)
			local jetEnd = data.jetEnd and Vector3.new(data.jetEnd.x, data.jetEnd.y, data.jetEnd.z)
			local targetPos = data.targetPosition and Vector3.new(data.targetPosition.x, data.targetPosition.y, data.targetPosition.z)
			if not (jetStart and jetEnd and targetPos) then return end

			local jetSpeed = tonumber(data.jetSpeed) or 700
			local bombFallDur = tonumber(data.bombFallDuration) or 2

			-- Play airstrike SFX for affected player
			if isVictim then playEventSFX("Airstrike") end

			-- WARNING SCREEN: "AIRSTRIKE INCOMING" for 2 seconds before jet arrives
			local warningGui = Instance.new("ScreenGui")
			warningGui.Name = "AirstrikeWarning"
			warningGui.DisplayOrder = 90
			warningGui.Parent = playerGui

			local warningLabel = Instance.new("TextLabel")
			warningLabel.Size = UDim2.new(0.8, 0, 0, 50)
			warningLabel.Position = UDim2.new(0.1, 0, 0.3, 0)
			warningLabel.BackgroundTransparency = 1
			warningLabel.Text = "AIRSTRIKE INCOMING"
			warningLabel.TextColor3 = Color3.fromRGB(255, 80, 50)
			warningLabel.Font = Enum.Font.Merriweather
			warningLabel.TextSize = 42
			warningLabel.TextStrokeTransparency = 0
			warningLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			warningLabel.Parent = warningGui

			local targetLabel = Instance.new("TextLabel")
			targetLabel.Size = UDim2.new(0.8, 0, 0, 30)
			targetLabel.Position = UDim2.new(0.1, 0, 0.37, 0)
			targetLabel.BackgroundTransparency = 1
			targetLabel.Text = isVictim and "YOUR SHIP IS THE TARGET!" or string.format("Target: %s", victimName)
			targetLabel.TextColor3 = isVictim and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 200, 100)
			targetLabel.Font = Enum.Font.Merriweather
			targetLabel.TextSize = 20
			targetLabel.TextStrokeTransparency = 0.3
			targetLabel.Parent = warningGui

			-- Flash the warning text
			task.spawn(function()
				while warningGui.Parent do
					warningLabel.TextColor3 = Color3.fromRGB(255, 80, 50)
					task.wait(0.25)
					if not warningGui.Parent then break end
					warningLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
					task.wait(0.25)
				end
			end)

			-- Wait 2 seconds for warning, then remove and start jet
			task.wait(2)
			warningGui:Destroy()

			-- Slow jet speed so player can see it approach (halved)
			jetSpeed = jetSpeed * 0.5

			-- Clone jet
			local assets = ReplicatedStorage:FindFirstChild("Assets")
			local jetTemplate = assets and assets:FindFirstChild("Jet")
			local jet
			if jetTemplate then
				jet = jetTemplate:Clone()
			else
				jet = Instance.new("Part")
				jet.Name = "Jet"
				jet.Size = Vector3.new(4, 2, 10)
				jet.Material = Enum.Material.Metal
				jet.Color = Color3.fromRGB(80, 80, 80)
			end

			if jet:IsA("Model") then
				for _, d in ipairs(jet:GetDescendants()) do
					if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
				end
				jet:PivotTo(CFrame.lookAt(jetStart, jetEnd))
			elseif jet:IsA("BasePart") then
				jet.Anchored = true; jet.CanCollide = false
				jet.CFrame = CFrame.lookAt(jetStart, jetEnd)
			end
			jet.Parent = workspace

			-- Attach jet engine sound (same as ambient flyover jets)
			local jetSoundHost = jet:IsA("Model") and (jet.PrimaryPart or jet:FindFirstChildWhichIsA("BasePart")) or jet
			if jetSoundHost and jetSoundHost:IsA("BasePart") then
				local snd = Instance.new("Sound")
				snd.Name = "JetEngineFlyover"
				snd.SoundId = "rbxassetid://131368895404825"
				snd.Volume = 0.5
				snd.Looped = true
				snd.RollOffMode = Enum.RollOffMode.Inverse
				snd.RollOffMinDistance = 360
				snd.RollOffMaxDistance = 3000
				snd.EmitterSize = 140
				snd.Parent = jetSoundHost
				snd:Play()
			end

			-- Fly jet from start to end
			local distance = (jetEnd - jetStart).Magnitude
			local flightDur = distance / jetSpeed
			local bombDropped = false
			local bombDropAlpha = 0.5 -- drop at midpoint

			local ft0 = os.clock()
			while true do
				local a = math.min((os.clock() - ft0) / flightDur, 1)
				local pos = jetStart:Lerp(jetEnd, a)
				local cf = CFrame.lookAt(pos, jetEnd)
				if jet:IsA("Model") then jet:PivotTo(cf) else jet.CFrame = cf end

				-- Drop bomb barrage at midpoint
				if not bombDropped and a >= bombDropAlpha then
					bombDropped = true
					local totalBombs = tonumber(data.bombCount) or 1
					for bombIdx = 1, totalBombs do
					task.spawn(function()
						-- Stagger each bomb slightly
						if bombIdx > 1 then task.wait((bombIdx - 1) * 0.15) end
						-- Create bomb
						local bombTemplate = assets and assets:FindFirstChild("Bomb")
						local bomb
						if bombTemplate then
							bomb = bombTemplate:Clone()
						else
							bomb = Instance.new("Part")
							bomb.Size = Vector3.new(1, 1, 3)
							bomb.Material = Enum.Material.Metal
							bomb.Color = Color3.fromRGB(40, 40, 40)
						end
						if bomb:IsA("BasePart") then
							bomb.Anchored = true; bomb.CanCollide = false
						end
						bomb.Parent = workspace

						-- Each bomb targets the boat's LIVE position
						local bombRng = Random.new(os.clock() * 1000 + bombIdx)
						local jetPos = if jet:IsA("Model") then jet:GetPivot().Position else jet.Position
						local bombStart = jetPos + Vector3.new(bombRng:NextNumber(-5, 5), 0, bombRng:NextNumber(-5, 5))
						-- Find victim boat's CURRENT position
						local liveTarget = targetPos
						local vBoat = nil
						local vShipId = data.victimShipmentId
						if vShipId then
							for _, inst in ipairs(workspace:GetDescendants()) do
								if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" and inst:GetAttribute("ShipmentId") == vShipId then
									vBoat = inst
									break
								end
							end
						end
						if vBoat then
							local vRoot = vBoat.PrimaryPart or vBoat:FindFirstChildWhichIsA("BasePart")
							if vRoot then liveTarget = vRoot.Position end
						end
						local bombEnd = liveTarget + Vector3.new(bombRng:NextNumber(-15, 15), 0, bombRng:NextNumber(-15, 15))
						if outcome == "miss" then
							bombEnd = liveTarget + Vector3.new(bombRng:NextNumber(-40, 40), 0, bombRng:NextNumber(-40, 40))
						end

						-- Bomb falls
						local bt0 = os.clock()
						while true do
							local ba = math.min((os.clock() - bt0) / bombFallDur, 1)
							local be = ba * ba -- accelerating fall
							local bpos = bombStart:Lerp(bombEnd, be)
							if bomb:IsA("BasePart") then
								bomb.CFrame = CFrame.lookAt(bpos, bombEnd)
							elseif bomb:IsA("Model") then
								bomb:PivotTo(CFrame.lookAt(bpos, bombEnd))
							end
							if ba >= 1 then break end
							task.wait()
						end

						-- Impact
						bomb:Destroy()

						if outcome == "hit" then
							-- Explode the boat into pieces
							local victimBoat = nil
							local victimShipId = data.victimShipmentId
							if victimShipId then
								for _, inst in ipairs(workspace:GetDescendants()) do
									if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" and inst:GetAttribute("ShipmentId") == victimShipId then
										victimBoat = inst
										break
									end
								end
							end
							if victimBoat then
								task.delay(0.2, function()
									explodeBoatIntoPieces(victimBoat, bombEnd)
								end)
							end

							-- Big explosion
							local explosion = Instance.new("Part")
							explosion.Size = Vector3.new(1, 1, 1)
							explosion.Position = bombEnd
							explosion.Anchored = true; explosion.CanCollide = false
							explosion.Transparency = 1
							explosion.Parent = workspace

							-- Flash
							local flash = Instance.new("PointLight")
							flash.Brightness = 12; flash.Range = 140
							flash.Color = Color3.fromRGB(255, 200, 80)
							flash.Parent = explosion
							task.delay(0.15, function() if flash.Parent then flash.Brightness = 5 end end)
							task.delay(0.5, function() if flash.Parent then flash:Destroy() end end)

							-- Fireball
							local fb = Instance.new("ParticleEmitter")
							fb.Rate = 0; fb.Lifetime = NumberRange.new(0.5, 1.5)
							fb.Speed = NumberRange.new(25, 60); fb.SpreadAngle = Vector2.new(180, 180)
							fb.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 10), NumberSequenceKeypoint.new(0.3, 18), NumberSequenceKeypoint.new(1, 0)})
							fb.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1)})
							fb.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 200)), ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 150, 40)), ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 20, 5))})
							fb.LightEmission = 1; fb.Parent = explosion
							fb:Emit(80)

							-- Smoke
							local smoke = Instance.new("ParticleEmitter")
							smoke.Rate = 0; smoke.Lifetime = NumberRange.new(3, 6)
							smoke.Speed = NumberRange.new(8, 20); smoke.SpreadAngle = Vector2.new(180, 180)
							smoke.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(0.5, 20), NumberSequenceKeypoint.new(1, 30)})
							smoke.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.3, 0.3), NumberSequenceKeypoint.new(1, 1)})
							smoke.Color = ColorSequence.new(Color3.fromRGB(25, 25, 25))
							smoke.Parent = explosion; smoke:Emit(50)

							-- Screen shake
							local camera = workspace.CurrentCamera
							if camera then
								task.spawn(function()
									local shakeRng = Random.new()
									local elapsed = 0
									while elapsed < 1 do
										local dt = task.wait()
										elapsed += dt
										local fade = 1 - elapsed
										camera.CFrame *= CFrame.new(shakeRng:NextNumber(-4, 4) * fade, shakeRng:NextNumber(-4, 4) * fade, 0)
									end
								end)
							end

							Debris:AddItem(explosion, 10)
						else
							-- Water splash for miss
							local splash = Instance.new("Part")
							splash.Size = Vector3.new(1, 1, 1); splash.Position = bombEnd
							splash.Anchored = true; splash.CanCollide = false; splash.Transparency = 1
							splash.Parent = workspace
							local water = Instance.new("ParticleEmitter")
							water.Rate = 0; water.Lifetime = NumberRange.new(0.8, 2)
							water.Speed = NumberRange.new(25, 50); water.SpreadAngle = Vector2.new(50, 50)
							water.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(0.5, 5), NumberSequenceKeypoint.new(1, 0)})
							water.Color = ColorSequence.new(Color3.fromRGB(100, 180, 255))
							water.Parent = splash; water:Emit(50)
							Debris:AddItem(splash, 4)
						end
					end)
					end -- for bombIdx
				end

				if a >= 1 then break end
				task.wait()
			end

			Debris:AddItem(jet, 2)

			-- Status message
			if isVictim then
				if outcome == "hit" then
					task.delay(5, function()
						setStatus("YOUR SHIP WAS BOMBED! Cargo destroyed!", false)
						playEventSFX("ShipDestroyed")
					end)

					-- DEATH CAM: head flies away from explosion, camera follows
					local localChar = player.Character
					local origHead = localChar and localChar:FindFirstChild("Head")
					if origHead and origHead:IsA("BasePart") then
						local airCam = workspace.CurrentCamera
						if airCam then
							task.spawn(function()
								-- Clone head before server dismembers
								local flyHead = origHead:Clone()
								flyHead.Name = "AirstrikeDeathHead"
								flyHead.Size = flyHead.Size * 3
								flyHead.Anchored = true
								flyHead.CanCollide = false
								flyHead.CFrame = CFrame.new(origHead.Position)
								flyHead.Parent = workspace

								local glow = Instance.new("PointLight")
								glow.Brightness = 2
								glow.Range = 20
								glow.Parent = flyHead

								-- Hide character
								if localChar then
									for _, p in ipairs(localChar:GetDescendants()) do
										if p:IsA("BasePart") then p.Transparency = 1 end
									end
								end

								-- Fly head away from bomb impact
								local impactPos = targetPos
								local headStartP = origHead.Position + Vector3.new(0, 10, 0)
								local awayD = Vector3.new(headStartP.X - impactPos.X, 0, headStartP.Z - impactPos.Z)
								if awayD.Magnitude < 1 then awayD = Vector3.new(50, 0, 0) end
								awayD = awayD.Unit
								local headEndP = headStartP + awayD * 150 + Vector3.new(0, 80, 0)

								airCam.CameraType = Enum.CameraType.Scriptable
								local camDone = false
								local rConn
								rConn = player.CharacterAdded:Connect(function()
									camDone = true
									airCam.CameraType = Enum.CameraType.Custom
									if rConn then rConn:Disconnect() end
								end)

								local at0 = os.clock()
								local aDur = 2
								while os.clock() - at0 < aDur and not camDone do
									local aa = math.min((os.clock() - at0) / aDur, 1)
									local ae = aa * aa * (3 - 2 * aa)
									local hPos = headStartP:Lerp(headEndP, ae)
									local spin = CFrame.Angles(aa * 10, aa * 7, aa * 5)
									flyHead.CFrame = CFrame.new(hPos) * spin
									local cPos = hPos + awayD * 20 + Vector3.new(0, 5, 0)
									airCam.CFrame = CFrame.lookAt(cPos, hPos)
									task.wait()
								end

								if not camDone then
									airCam.CameraType = Enum.CameraType.Custom
								end
								if rConn then rConn:Disconnect() end
								Debris:AddItem(flyHead, 1)
							end)
						end
					end
				else
					setStatus("Airstrike missed your ship!", true)
				end
			else
				if outcome == "hit" then
					setStatus(string.format("Airstrike hit %s's ship!", victimName), true)
				else
					setStatus(string.format("Airstrike missed %s's ship.", victimName), true)
				end
			end
		end)
	end)

end

return StrategicStrikeClient
