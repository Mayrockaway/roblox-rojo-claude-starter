--!strict
--[[
	DrillReplicationClient
	Handles drillProgressUpdate OnClientEvent: spawns the DrillComplete model with
	the E-press reveal prompt, then runs the vein reveal spinner / oil burst FX.
	Extracted from init.client.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
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

					--- "Ready to reveal" glow: subtle green Highlight on the shovel
					--- model so finished drills are easy to spot at a glance without
					--- being visually loud. `AlwaysOnTop` so the cue is findable
					--- through the dirt mound / surrounding props (this is the
					--- whole point of the indicator). A gentle outline-transparency
					--- pulse via TweenService creates the "glowing" sensation with
					--- a tight amplitude so it stays in the background of the FX
					--- mix and doesn't compete with the DrillComplete model itself
					--- or the proximity prompt.
					local hl = Instance.new("Highlight")
					hl.Name = "ReadyToRevealHighlight"
					hl.FillColor = Color3.fromRGB(80, 255, 130)
					hl.FillTransparency = 0.88
					hl.OutlineColor = Color3.fromRGB(140, 255, 170)
					hl.OutlineTransparency = 0.35
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.Parent = dc

					task.spawn(function()
						local tween = TweenService:Create(
							hl,
							TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
							{ OutlineTransparency = 0.1 }
						)
						tween:Play()
					end)

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

			-- Tile color flicker + oil burst (below) only. The post-spin
			-- world-anchored `VeinRevealBillboard` (rarity title above the
			-- tile) and the screen `VeinToast` (rarity-colored "Double Cache
			-- COMMON" banner) were both removed at user request — the lootbox
			-- spinner already announces the tile name + rarity, so any
			-- post-resolve banner here is redundant.

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
				-- Tile-color slot spin (3s). The world-anchored billboard
				-- that used to label the spin was removed; only the visual
				-- color flicker on the tile + final landed color remain.
				local spinDur = 3
				local spinT0 = os.clock()
				local spinRng = Random.new(os.clock() * 1000)
				local allOils = VeinConfig.OilOrder

				while true do
					local elapsed = os.clock() - spinT0
					if elapsed >= spinDur then break end
					-- Ease: start fast, slow down
					local progress = elapsed / spinDur
					local interval = 0.06 + 0.4 * (progress * progress * progress)
					local randOil = allOils[spinRng:NextInteger(1, #allOils)]
					local oilDef = VeinConfig.OilTypes[randOil]

					if tilePart and oilDef then
						tilePart.Color = oilDef.color
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

				-- Screen toast (`VeinToast`) removed at user request — the
				-- lootbox spinner already announces the tile name + rarity, so
				-- the on-top "Double Cache COMMON" status banner that fired
				-- here was redundant. Tile color flicker + landed color +
				-- oil burst (below) remain.

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

			end)

		end
	end)
end

return M
