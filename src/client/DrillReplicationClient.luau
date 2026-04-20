--!strict
--[[
	DrillReplicationClient
	Handles drillProgressUpdate OnClientEvent: spawns the DrillComplete model with
	the E-press reveal prompt, then runs the vein reveal spinner / oil burst FX.
	Extracted from init.client.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))

export type Deps = {
	player: Player,
	playerGui: PlayerGui,
	setStatus: (msg: string, isError: boolean) -> (),
	drillProgressUpdate: RemoteEvent,
	requestRevealTile: RemoteEvent,
	VeinCrateOpener: any?, -- module with .Open(veinTypeId, groundType, callback)
}

local M = {}

function M.connect(deps: Deps)
	local player = deps.player
	local playerGui = deps.playerGui
	local setStatus = deps.setStatus
	local drillProgressUpdate = deps.drillProgressUpdate
	local requestRevealTile = deps.requestRevealTile
	local VeinCrateOpener = deps.VeinCrateOpener

	drillProgressUpdate.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then return end
		if data.kind == "started" and data.ownerUserId == player.UserId then
			setStatus(string.format("Drilling (%s) â€” %.1fs", tostring(data.tier or "?"), tonumber(data.duration) or 0), false)
		elseif data.kind == "completed" and data.ownerUserId == player.UserId then
			-- Spawn DrillComplete model on the tile with ProximityPrompt
			setStatus("Drill complete! Press E to reveal what's underneath.", false)
			local pos = if typeof(data.position) == "table"
				then Vector3.new(tonumber(data.position.x) or 0, tonumber(data.position.y) or 0, tonumber(data.position.z) or 0)
				else Vector3.new(0, 0, 0)
			local dcTemplate = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("DrillComplete")
			print("[DrillReplay] pos=", pos, "mag=", pos.Magnitude, "template=", dcTemplate ~= nil)
			if dcTemplate and pos.Magnitude > 0 then
				task.spawn(function()
					local dc = dcTemplate:Clone()
					dc.Name = "DrillComplete_" .. tostring(data.chunkId) .. "_" .. tostring(data.tileKey)
					for _, d in ipairs(dc:GetDescendants()) do
						if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
					end
					dc:PivotTo(CFrame.new(pos + Vector3.new(0, 4, 0)))
					dc.Parent = Workspace

					local prompt = Instance.new("ProximityPrompt")
					prompt.Name = "RevealPrompt"
					prompt.ActionText = "Reveal"
					prompt.ObjectText = "Drill Complete"
					prompt.KeyboardKeyCode = Enum.KeyCode.E
					prompt.MaxActivationDistance = 12
					prompt.RequiresLineOfSight = false
					prompt.HoldDuration = 0
					local root = dc:FindFirstChildWhichIsA("BasePart")
					if root then prompt.Parent = root end

					prompt.Triggered:Connect(function(trigPlayer)
						if trigPlayer ~= player then return end
						requestRevealTile:FireServer({
							chunkId = data.chunkId,
							tileKey = data.tileKey,
						})
						-- Remove prompt immediately so you can't double-press
						prompt:Destroy()
					end)
				end)
			end

		elseif data.kind == "revealed" and data.ownerUserId == player.UserId then
			-- Remove DrillComplete model
			local dcName = "DrillComplete_" .. tostring(data.chunkId) .. "_" .. tostring(data.tileKey)
			local dcModel = Workspace:FindFirstChild(dcName)
			if dcModel then dcModel:Destroy() end

			local veinResult = data.veinResult
			if not veinResult then return end

			-- Open crate spinner UI â€” ground type determines the card pool
			local veinTypeId = data.veinTypeId or "item-1"
			local groundType = data.groundType or "Bronze"
			local veinType = VeinCrateConfig.GetById(veinTypeId)
			if VeinCrateOpener then
				VeinCrateOpener.Open(veinTypeId, groundType, function()
					requestRevealTile:FireServer({
						chunkId = data.chunkId,
						tileKey = data.tileKey,
						stage = "startVisuals",
					})
				end)
			else
				requestRevealTile:FireServer({
					chunkId = data.chunkId,
					tileKey = data.tileKey,
					stage = "startVisuals",
				})
			end

			-- Find the tile Part in workspace by position
			local displayName = veinType and veinType.displayName or VeinConfig.BuildDisplayName(veinResult)
			local oddsText = "ROW POOL"
			local rarity = {
				name = veinType and string.upper(veinType.rarity) or "ROW POOL",
				color = veinType and VeinCrateConfig.GetRarityTextColor(veinType.rarity) or Color3.fromRGB(255, 255, 255),
			}

			-- Slot spin animation on the tile
			-- Find tile part by searching owned plot sections
			local tilePart = nil
			local ownedPlot = Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("Plots")
			if ownedPlot then
				for _, plot in ipairs(ownedPlot:GetChildren()) do
					local pg = plot:FindFirstChild("PlotGround")
					if not pg then continue end
					for _, section in ipairs(pg:GetChildren()) do
						if not section:IsA("Model") then continue end
						local tp = section:FindFirstChild(tostring(data.tileKey))
						if tp and tp:IsA("BasePart") then
							tilePart = tp
							break
						end
					end
					if tilePart then break end
				end
			end

			task.spawn(function()
				-- Billboard above tile showing spinning results
				local billboard = nil
				local nameLabel = nil
				local oddsLabel = nil
				if tilePart then
					billboard = Instance.new("BillboardGui")
					billboard.Name = "VeinRevealBillboard"
					billboard.Size = UDim2.fromOffset(300, 100)
					billboard.StudsOffset = Vector3.new(0, 8, 0)
					billboard.AlwaysOnTop = true
					billboard.Adornee = tilePart
					billboard.Parent = playerGui

					nameLabel = Instance.new("TextLabel")
					nameLabel.Size = UDim2.fromScale(1, 0.6)
					nameLabel.Position = UDim2.fromScale(0, 0)
					nameLabel.BackgroundTransparency = 1
					nameLabel.Font = Enum.Font.LuckiestGuy
					nameLabel.TextSize = 28
					nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
					nameLabel.TextStrokeTransparency = 0
					nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
					nameLabel.Text = ""
					nameLabel.Parent = billboard

					oddsLabel = Instance.new("TextLabel")
					oddsLabel.Size = UDim2.fromScale(1, 0.4)
					oddsLabel.Position = UDim2.fromScale(0, 0.6)
					oddsLabel.BackgroundTransparency = 1
					oddsLabel.Font = Enum.Font.LuckiestGuy
					oddsLabel.TextSize = 22
					oddsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
					oddsLabel.TextStrokeTransparency = 0
					oddsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
					oddsLabel.Text = ""
					oddsLabel.Parent = billboard
				end

				-- Spin through random combos for 3 seconds
				local spinDur = 3
				local spinT0 = os.clock()
				local spinRng = Random.new(os.clock() * 1000)
				local allStreams = VeinConfig.StreamOrder
				local allOils = VeinConfig.OilOrder
				local originalColor = tilePart and tilePart.Color or Color3.fromRGB(254, 224, 180)

				while true do
					local elapsed = os.clock() - spinT0
					if elapsed >= spinDur then break end
					-- Ease: start fast, slow down
					local progress = elapsed / spinDur
					local interval = 0.06 + 0.4 * (progress * progress * progress)
					-- Pick random combo to display
					local randStream = allStreams[spinRng:NextInteger(1, #allStreams)]
					local randOil = allOils[spinRng:NextInteger(1, #allOils)]
					local streamDef = VeinConfig.Streams[randStream]
					local oilDef = VeinConfig.OilTypes[randOil]

					if tilePart then
						tilePart.Color = oilDef.color
					end
					if nameLabel then
						nameLabel.Text = oilDef.displayName .. " " .. streamDef.name
						nameLabel.TextColor3 = streamDef.color
					end
					if oddsLabel then
						local fakeProbInverse = spinRng:NextInteger(2, 5000)
						oddsLabel.Text = "1/" .. tostring(fakeProbInverse)
					end

					task.wait(interval)
				end

				-- Land on the real result
				if tilePart then
					if veinResult.isDead then
						tilePart.Color = Color3.fromRGB(72, 50, 30)
						tilePart.Material = Enum.Material.Ground
					else
						local firstOil = VeinConfig.OilTypes[veinResult.veins[1].oilType]
						if firstOil then
							tilePart.Color = firstOil.color
						end
					end
				end
				if nameLabel then
					nameLabel.Text = displayName
					nameLabel.TextColor3 = rarity.color
					if rarity.name == "LEGENDARY" or rarity.name == "EPIC" then
						nameLabel.TextSize = 34
					end
				end
				if oddsLabel then
					oddsLabel.Text = oddsText .. " - " .. rarity.name
					oddsLabel.TextColor3 = rarity.color
				end

				-- Toast popup
				local toast = Instance.new("ScreenGui")
				toast.Name = "VeinToast"
				toast.IgnoreGuiInset = true
				toast.DisplayOrder = 100
				toast.Parent = playerGui

				local toastLabel = Instance.new("TextLabel")
				toastLabel.Size = UDim2.new(0.6, 0, 0, 60)
				toastLabel.Position = UDim2.new(0.2, 0, 0.15, 0)
				toastLabel.BackgroundTransparency = 0.3
				toastLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				toastLabel.Font = Enum.Font.LuckiestGuy
				toastLabel.TextSize = 30
				toastLabel.TextColor3 = rarity.color
				toastLabel.TextStrokeTransparency = 0
				toastLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				toastLabel.Text = displayName .. "  " .. (veinType and veinType.rarity or oddsText)
				toastLabel.Parent = toast
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(0, 12)
				corner.Parent = toastLabel

				-- Oil burst if not dead
				if not veinResult.isDead and data.hasOil then
					local veinCount = VeinConfig.VeinCounts[veinResult.veinCount]
					local count = veinCount and veinCount.count or 1
					for i, vein in ipairs(veinResult.veins) do
						local internalOil = VeinConfig.GetInternalOilName(vein.oilType)
						local sprayName = "OilSpray_" .. internalOil
						local sprayTemplate = ReplicatedStorage.Assets:FindFirstChild(sprayName)
						if sprayTemplate and tilePart then
							local spray = sprayTemplate:Clone()
							for _, d in ipairs(spray:GetDescendants()) do
								if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
							end
							local offset = Vector3.new((i - 1) * 2 - (count - 1), 0.5, 0)
							spray:PivotTo(CFrame.new(tilePart.Position + offset + Vector3.new(0, 0.3, 0)))
							spray.Parent = Workspace
							-- Burst: emit extra particles
							for _, d in ipairs(spray:GetDescendants()) do
								if d:IsA("ParticleEmitter") then
									local streamDef = VeinConfig.Streams[vein.streamType]
									local mult = streamDef and streamDef.particleMult or 1
									d:Emit(math.floor(100 * mult))
								end
							end
							Debris:AddItem(spray, 5) -- server spray takes over
						end
					end
				end

				-- Fade billboard + toast after 3s
				task.wait(3)
				if billboard then billboard:Destroy() end
				task.wait(1)
				if toast and toast.Parent then toast:Destroy() end
			end)

		end
	end)
end

return M
