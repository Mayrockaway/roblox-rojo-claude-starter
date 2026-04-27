--!strict
--- Client-side tile glow effect for Oil Heaven. Tweens each tile between
--- two colors per section in a staggered wave. Only active while the player
--- is in Oil Heaven. Uses Color3 tweens on Neon parts — zero particles,
--- zero lights, basically free on performance.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local LocalPlayer = Players.LocalPlayer

--- Two colors per section: tiles pulse between colorA and colorB.
local SECTION_COLORS: { [string]: { colorA: Color3, colorB: Color3, outlineA: Color3, outlineB: Color3 } } = {
	S1 = { colorA = Color3.fromRGB(255, 215, 0),   colorB = Color3.fromRGB(255, 255, 150), outlineA = Color3.fromRGB(255, 255, 100), outlineB = Color3.fromRGB(255, 200, 0) },   -- gold
	S2 = { colorA = Color3.fromRGB(255, 50, 0),    colorB = Color3.fromRGB(255, 150, 50),  outlineA = Color3.fromRGB(255, 150, 50),  outlineB = Color3.fromRGB(255, 0, 0) },      -- red
	S3 = { colorA = Color3.fromRGB(0, 200, 255),   colorB = Color3.fromRGB(150, 255, 255), outlineA = Color3.fromRGB(100, 255, 255), outlineB = Color3.fromRGB(0, 150, 255) },    -- cyan
	S4 = { colorA = Color3.fromRGB(50, 255, 50),   colorB = Color3.fromRGB(180, 255, 100), outlineA = Color3.fromRGB(150, 255, 150), outlineB = Color3.fromRGB(0, 200, 0) },      -- green
	S5 = { colorA = Color3.fromRGB(180, 0, 255),   colorB = Color3.fromRGB(220, 130, 255), outlineA = Color3.fromRGB(220, 100, 255), outlineB = Color3.fromRGB(130, 0, 200) },    -- purple
}

local CYCLE_DURATION = 2.5 -- seconds per full A→B→A pulse
local ROW_STAGGER = 0.08 -- seconds delay per row for wave effect

local OilHeavenTileGlow = {}

local activeTweens: { Tween } = {}
local running = false

local function stopAllTweens()
	for _, tween in ipairs(activeTweens) do
		tween:Cancel()
	end
	table.clear(activeTweens)
	running = false
end

local function updateSectionLabels(plot: Model)
	local labels = plot:FindFirstChild("SectionLabels")
	if not labels then return end

	local rebirthCount = LocalPlayer:GetAttribute("RebirthCount") or 0

	for _, anchor in ipairs(labels:GetChildren()) do
		if not anchor:IsA("BasePart") then continue end
		local required = anchor:GetAttribute("RebirthRequired") or 999
		local gui = anchor:FindFirstChild("HologramGui")
		if not gui then continue end

		local title = gui:FindFirstChild("Title") :: TextLabel?
		local rebirthLabel = gui:FindFirstChild("RebirthLabel") :: TextLabel?
		if not title or not rebirthLabel then continue end

		if rebirthCount >= required then
			title.Text = "✅ UNLOCKED"
			title.TextColor3 = Color3.fromRGB(100, 255, 100)
			rebirthLabel.Text = ""
		else
			title.Text = "🔒 UNLOCKS AT"
			title.TextColor3 = Color3.fromRGB(255, 255, 255)
			rebirthLabel.Text = string.format("Rebirth %d", required)
		end
	end
end

local function startGlowOnPlot(plot: Model)
	if running then return end
	running = true

	-- Update hologram labels based on rebirth count
	updateSectionLabels(plot)

	-- Rainbow cycle on "?" meshes inside each tile
	local RAINBOW = {
		Color3.fromRGB(255, 0, 0),
		Color3.fromRGB(255, 150, 0),
		Color3.fromRGB(255, 255, 0),
		Color3.fromRGB(0, 255, 0),
		Color3.fromRGB(0, 200, 255),
		Color3.fromRGB(100, 0, 255),
		Color3.fromRGB(255, 0, 200),
	}
	local RAINBOW_SPEED = 2 -- seconds per color transition

	task.spawn(function()
		local colorIndex = 1
		while running do
			local nextIndex = (colorIndex % #RAINBOW) + 1
			local fromColor = RAINBOW[colorIndex]
			local toColor = RAINBOW[nextIndex]

			-- Find all QMark mesh parts
			local qmarks = {}
			local tg = plot:FindFirstChild("TileGrid")
			if tg then
				for _, tile in ipairs(tg:GetChildren()) do
					local qm = tile:FindFirstChild("QMark")
					if qm then
						for _, part in ipairs(qm:GetChildren()) do
							if part:IsA("BasePart") then
								table.insert(qmarks, part)
							end
						end
					end
				end
			end

			-- Tween all ? parts together
			local elapsed = 0
			while elapsed < RAINBOW_SPEED and running do
				elapsed += task.wait()
				local alpha = math.min(elapsed / RAINBOW_SPEED, 1)
				local c = fromColor:Lerp(toColor, alpha)
				for _, part in ipairs(qmarks) do
					if part.Parent then
						part.Color = c
					end
				end
			end

			colorIndex = nextIndex
		end
	end)

	-- Per-section outline color pulse
	task.spawn(function()
		local OUTLINE_SPEED = 2
		local tg = plot:FindFirstChild("TileGrid")
		if not tg then return end

		-- Group highlights by section
		local highlightsBySec: { [string]: { Highlight } } = {}
		for _, tile in ipairs(tg:GetChildren()) do
			local h = tile:FindFirstChild("RainbowHighlight")
			local sec = tile:GetAttribute("Section")
			if h and h:IsA("Highlight") and sec then
				if not highlightsBySec[sec] then highlightsBySec[sec] = {} end
				table.insert(highlightsBySec[sec], h)
			end
		end

		local forward = true
		while running do
			local elapsed = 0
			while elapsed < OUTLINE_SPEED and running do
				elapsed += task.wait()
				local alpha = math.min(elapsed / OUTLINE_SPEED, 1)
				if not forward then alpha = 1 - alpha end
				for sec, highlights in pairs(highlightsBySec) do
					local colors = SECTION_COLORS[sec]
					if colors then
						local c = colors.outlineA:Lerp(colors.outlineB, alpha)
						for _, h in ipairs(highlights) do
							if h.Parent then
								h.OutlineColor = c
							end
						end
					end
				end
			end
			forward = not forward
		end
	end)

	local tileGrid = plot:FindFirstChild("TileGrid")
	if not tileGrid then return end

	for _, tile in ipairs(tileGrid:GetChildren()) do
		if tile:IsA("BasePart") then
			local sectionId = tile:GetAttribute("Section")
			local colors = SECTION_COLORS[sectionId]
			if not colors then continue end

			local row = tile:GetAttribute("Row") or 1
			local delay = (row - 1) * ROW_STAGGER
			local halfCycle = CYCLE_DURATION / 2

			-- Set initial color
			tile.Color = colors.colorA

			-- Staggered start
			task.delay(delay, function()
				if not running then return end

				-- Forward tween: A → B
				local tweenA = TweenService:Create(tile, TweenInfo.new(
					halfCycle,
					Enum.EasingStyle.Sine,
					Enum.EasingDirection.InOut,
					-1, -- infinite repeat
					true, -- reverses (B → A after reaching B)
					0
				), { Color = colors.colorB })

				tweenA:Play()
				table.insert(activeTweens, tweenA)
			end)
		end
	end
end

function OilHeavenTileGlow.start()
	local function onWorldChanged()
		local world = LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute)

		if world == Constants.WorldOilHeaven then
			-- Find the player's Oil Heaven plot
			task.delay(0.5, function() -- small delay to let the plot stream in
				local plotName = string.format("OilHeavenPlot_%d", LocalPlayer.UserId)
				local plot = Workspace:FindFirstChild(plotName)
				if plot then
					startGlowOnPlot(plot)
				end
			end)
		else
			stopAllTweens()
		end
	end

	LocalPlayer:GetAttributeChangedSignal(Constants.CurrentWorldAttribute):Connect(onWorldChanged)
	onWorldChanged()
end

return OilHeavenTileGlow
