--[[
	scripts/mcp_author_loading_screen.luau

	Authors the canonical `ReplicatedFirst.LoadingScreenGui` shell in Studio.

	Run ONCE via MCP `execute_luau` (or paste in the Studio Command Bar), then
	**Save** the place. After that:
	  * `default.project.json` lists `ReplicatedFirst` with
	    `$ignoreUnknownInstances = true`, so this Studio-authored ScreenGui
	    survives Rojo sync.
	  * `src/replicated_first/init.client.luau` (Rojo target
	    `ReplicatedFirst.LoadingBootstrap`) reparents this ScreenGui to
	    `PlayerGui` on join, plays BGM, runs `ContentProvider:PreloadAsync`
	    against every reachable instance with a live progress callback that
	    drives `BottomBar.ProgressTrack.ProgressFill` and the
	    `BottomBar.LoadingLabel`, then fades + destroys the cover.

	Hierarchy authored:
	    LoadingScreenGui [ScreenGui]
	    └─ Canvas [Frame, scale (1,1), centered]
	       ├─ Cover [ImageLabel, scale (1,1), ScaleType = Crop]
	       └─ BottomBar [Frame, scale (0.6, 0.08), bottom-center]
	          ├─ ProgressTrack [Frame, scale (1, 0.35), top]
	          │  ├─ UICorner (pill)
	          │  ├─ UIStroke
	          │  └─ ProgressFill [Frame, scale (0, 1), anchor (0, 0.5)]
	          │     └─ UICorner (pill)
	          └─ LoadingLabel [TextLabel, scale (1, 0.55), bottom; TextScaled]
	             └─ UITextSizeConstraint

	Scaling contract (matches `.cursor/rules/ui-scaling-responsive.mdc` +
	`startergui-viewport-shell.mdc`):
	  * `Canvas` viewport-root: `Size` scale `(1, 1)`, `AnchorPoint (0.5, 0.5)`,
	    `Position` scale `(0.5, 0.5)`. Scales like every other HUD root.
	  * `Cover` `ImageLabel`: `Size` scale `(1, 1)`, full bleed, `ScaleType =
	    Crop` so the asset fills phone / desktop / console aspect with no bars
	    and no stretch.
	  * `BottomBar` and bar / label children: scale-based `Size` so the bar
	    shrinks proportionally on phone instead of disappearing off the edge.
	  * `LoadingLabel`: `TextScaled = true` + `UITextSizeConstraint` (min 12,
	    max 28).
	  * No `UIAspectRatioConstraint` on the cover (it MUST cover the viewport,
	    not letterbox).
]]

local ReplicatedFirst = game:GetService("ReplicatedFirst")

local COVER_ASSET = "rbxassetid://94495457583750"

local existing = ReplicatedFirst:FindFirstChild("LoadingScreenGui")
if existing then
	-- Idempotent: wipe the old shell so re-running this script after a tweak
	-- gives a clean canonical layout. Studio Save afterwards persists it.
	existing:Destroy()
end

local screen = Instance.new("ScreenGui")
screen.Name = "LoadingScreenGui"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 1_000_000
screen.Enabled = true

local canvas = Instance.new("Frame")
canvas.Name = "Canvas"
canvas.AnchorPoint = Vector2.new(0.5, 0.5)
canvas.Position = UDim2.fromScale(0.5, 0.5)
canvas.Size = UDim2.fromScale(1, 1)
canvas.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
canvas.BackgroundTransparency = 0
canvas.BorderSizePixel = 0
canvas.Parent = screen

local cover = Instance.new("ImageLabel")
cover.Name = "Cover"
cover.AnchorPoint = Vector2.new(0.5, 0.5)
cover.Position = UDim2.fromScale(0.5, 0.5)
cover.Size = UDim2.fromScale(1, 1)
cover.BackgroundTransparency = 1
cover.Image = COVER_ASSET
cover.ScaleType = Enum.ScaleType.Crop
cover.Parent = canvas

local bottomBar = Instance.new("Frame")
bottomBar.Name = "BottomBar"
bottomBar.AnchorPoint = Vector2.new(0.5, 1)
bottomBar.Position = UDim2.fromScale(0.5, 0.94)
bottomBar.Size = UDim2.fromScale(0.6, 0.08)
bottomBar.BackgroundTransparency = 1
bottomBar.Parent = canvas

local track = Instance.new("Frame")
track.Name = "ProgressTrack"
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.fromScale(0.5, 0)
track.Size = UDim2.fromScale(1, 0.35)
track.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
track.BackgroundTransparency = 0.45
track.BorderSizePixel = 0
track.ClipsDescendants = true
track.Parent = bottomBar

local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track

local trackStroke = Instance.new("UIStroke")
trackStroke.Color = Color3.fromRGB(255, 255, 255)
trackStroke.Thickness = 1
trackStroke.Transparency = 0.4
trackStroke.Parent = track

local fill = Instance.new("Frame")
fill.Name = "ProgressFill"
fill.AnchorPoint = Vector2.new(0, 0.5)
fill.Position = UDim2.fromScale(0, 0.5)
-- Width starts at 0 (empty bar). The bootstrap tweens X-scale from 0 → 1 as
-- ContentProvider:PreloadAsync resolves assets.
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
fill.BorderSizePixel = 0
fill.Parent = track

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local label = Instance.new("TextLabel")
label.Name = "LoadingLabel"
label.AnchorPoint = Vector2.new(0.5, 1)
label.Position = UDim2.fromScale(0.5, 1)
label.Size = UDim2.fromScale(1, 0.55)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
label.TextStrokeTransparency = 0.4
label.TextScaled = true
label.TextWrapped = true
label.Text = "Loading…"
label.Parent = bottomBar

local sizeCap = Instance.new("UITextSizeConstraint")
sizeCap.MinTextSize = 12
sizeCap.MaxTextSize = 28
sizeCap.Parent = label

screen.Parent = ReplicatedFirst

print(
	"[mcp_author_loading_screen] Authored ReplicatedFirst.LoadingScreenGui"
		.. " (Canvas / Cover / BottomBar.ProgressTrack.ProgressFill / LoadingLabel)"
		.. " — Save the place to persist."
)
