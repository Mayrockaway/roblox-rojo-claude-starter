--!strict
-- Temporary full-screen title for strait waypoint playtests; replace with real UI later.
--
-- Two-line banner: required `title` (large headline) plus an optional
-- `opts.subtitle` (smaller body, used by the contractor pirate-hit victim path
-- in `PirateHireClient` to show "You got raided by X and lost 50% of your
-- barrels to them!"). When no `opts.subtitle` is provided the banner renders
-- exactly as before so existing callers (`ShipmentVisualClient` and the
-- legacy/contractor `PirateHireClient` paths) are untouched.

local TweenService = game:GetService("TweenService")

export type ShowOpts = {
	--- Tint applied to both the title and (if present) subtitle. Black stroke
	--- stays at full opacity for legibility against bright Workspace lighting.
	color: Color3?,
	--- Smaller body line rendered under the title. Wraps onto multiple rows
	--- automatically; callers don't need to size it.
	subtitle: string?,
	--- How long the banner sits at full opacity before it fades out (seconds).
	--- Defaults to `DEFAULT_HOLD_SECONDS` so existing one-arg callers behave
	--- exactly as before. Bumped on the victim path so the message survives
	--- post-raid camera/UI flurries.
	holdSeconds: number?,
}

local StraitEventPlaytestBanner = {}

local GUI_NAME = "StraitEventPlaytestBanner"
local DEFAULT_HOLD_SECONDS = 3.8
local FADE_SECONDS = 0.45

function StraitEventPlaytestBanner.show(playerGui: PlayerGui, title: string, opts: ShowOpts?)
	if title == "" then
		return
	end

	local color = (opts and opts.color) or Color3.fromRGB(255, 255, 255)
	local subtitle = (opts and opts.subtitle) or nil
	local holdSeconds = (opts and opts.holdSeconds) or DEFAULT_HOLD_SECONDS

	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 200_000
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.AnchorPoint = Vector2.new(0.5, 0.35)
	label.Position = UDim2.new(0.5, 0, 0.28, 0)
	label.Size = UDim2.new(0.92, 0, 0, 96)
	label.BackgroundTransparency = 1
	label.Text = title
	label.TextColor3 = color
	label.Font = Enum.Font.Merriweather
	label.TextSize = 52
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Parent = label

	-- Optional secondary line ("body"). Sits directly under the title, smaller
	-- font + wraps so a long sentence (e.g. "You got raided by ABCDEFGHIJKLMNOP
	-- and lost 50% of your barrels to them!") fits without overflowing the
	-- viewport on phones.
	local subtitleLabel: TextLabel? = nil
	local subtitleStroke: UIStroke? = nil
	if subtitle and subtitle ~= "" then
		local sl = Instance.new("TextLabel")
		sl.Name = "Subtitle"
		sl.AnchorPoint = Vector2.new(0.5, 0)
		sl.Position = UDim2.new(0.5, 0, 0.36, 0)
		sl.Size = UDim2.new(0.78, 0, 0, 92)
		sl.BackgroundTransparency = 1
		sl.Text = subtitle
		sl.TextColor3 = color
		sl.Font = Enum.Font.Merriweather
		sl.TextSize = 30
		sl.TextWrapped = true
		sl.TextXAlignment = Enum.TextXAlignment.Center
		sl.TextYAlignment = Enum.TextYAlignment.Top
		sl.Parent = root
		subtitleLabel = sl

		local ss = Instance.new("UIStroke")
		ss.Thickness = 3
		ss.Color = Color3.fromRGB(0, 0, 0)
		ss.Parent = sl
		subtitleStroke = ss
	end

	task.delay(holdSeconds, function()
		if not gui.Parent then
			return
		end
		local fadeInfo = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local t = TweenService:Create(label, fadeInfo, { TextTransparency = 1 })
		local t2 = TweenService:Create(stroke, fadeInfo, { Transparency = 1 })
		t:Play()
		t2:Play()
		if subtitleLabel then
			TweenService:Create(subtitleLabel, fadeInfo, { TextTransparency = 1 }):Play()
		end
		if subtitleStroke then
			TweenService:Create(subtitleStroke, fadeInfo, { Transparency = 1 }):Play()
		end
		t.Completed:Wait()
		gui:Destroy()
	end)
end

return StraitEventPlaytestBanner
