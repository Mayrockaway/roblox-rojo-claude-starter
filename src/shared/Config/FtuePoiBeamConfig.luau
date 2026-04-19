--!strict
-- FTUE rig → world **`Beam`** targets by step. Edit **`Rules`** to add steps or POIs.
--
-- Each **target** resolves in order:
-- 1) **`GuiObject`** named **`pointerGuiName`** under the **search root** (under **`BillboardGui` / `SurfaceGui`**:
--    `Adornee` / parent **`BasePart`**, else nearest **`BasePart` / `Model`** ancestor).
-- 2) Else first descendant under the **search root** with attribute **`attributeName = true`**.
-- 3) Else first **`Model`** named **`modelName`** under the **search root** (`PrimaryPart` or any **`BasePart`**).
--
-- **`searchScope`** picks the search root:
-- * `"Workspace"` (default): whole `Workspace` (use for shared NPCs like `Dockman`, `PirateHire`, `ArmyGeneral`).
-- * `"OwnedPlot"`: only the local player's plot (`Workspace.Map.Plots.<myPlot>`). Use for cloned per-plot decor
--   like `PlotDispatch` so the beam points at **your** copy, not another player's.
-- * `"OwnedWarehouse"`: only the local player's warehouse visual
--   (`Workspace.Map.FinishPlot.Warehouse_<myUserId>`). Use for the warehouse terminal / sell prompt anchor.
--
-- **`docksSubStep`**: when set, the rule applies only if `Player:GetAttribute("FtueDocksUpgradeSubStep")` matches
-- (e.g. `"Dockman"` during docks ship leg). Omit for all substeps of that step.

local FtueConfig = require(script.Parent:WaitForChild("FtueConfig"))

export type PoiBeamStyle = {
	texture: string?,
	textureMode: Enum.TextureMode?,
	textureSpeed: number?,
	textureLength: number?,
	width0: number?,
	width1: number?,
	color: ColorSequence?,
	transparency: NumberSequence?,
	lightEmission: number?,
	faceCamera: boolean?,
	zOffset: number?,
	curveSize0: number?,
	curveSize1: number?,
	segments: number?,
	characterAttachOffset: Vector3?,
	targetAttachOffset: Vector3?,
}

export type PoiBeamSearchScope = "Workspace" | "OwnedPlot" | "OwnedWarehouse"

export type PoiBeamTarget = {
	--- Unique id for this beam channel (letters/digits/underscore).
	id: string,
	pointerGuiName: string?,
	attributeName: string?,
	modelName: string?,
	searchScope: PoiBeamSearchScope?,
	style: PoiBeamStyle?,
}

export type PoiBeamStepRule = {
	ftueStep: string,
	docksSubStep: string?,
	targets: { PoiBeamTarget },
}

local FtuePoiBeamConfig = {
	Rules = {
		{
			ftueStep = FtueConfig.Step.WaitPlotShipment,
			docksSubStep = nil,
			targets = {
				{
					id = "PlotDispatch",
					pointerGuiName = "FtuePlotDispatchWorldPointerRoot",
					modelName = "PlotDispatch",
					searchScope = "OwnedPlot",
					style = nil,
				},
			},
		},
		{
			ftueStep = FtueConfig.Step.WaitDocksUpgradeShip,
			docksSubStep = "Dockman",
			targets = {
				{
					id = "Dockman",
					pointerGuiName = "FtueDockmanWorldPointerRoot",
					modelName = "Dockman",
					style = nil,
				},
			},
		},
		{
			ftueStep = FtueConfig.Step.WaitWarehouseSell,
			docksSubStep = nil,
			targets = {
				{
					id = "WarehouseTerminal",
					attributeName = "IsWarehouseTerminal",
					--- Per-player template's terminal Model is **`UpgradeTerminal`** (see `WarehouseTemplate.UpgradeTerminal`);
					--- attribute resolves first, this is the name fallback.
					modelName = "UpgradeTerminal",
					searchScope = "OwnedWarehouse",
					style = nil,
				},
			},
		},
		{
			ftueStep = FtueConfig.Step.WaitDocksHire,
			docksSubStep = nil,
			targets = {
				{
					id = "PirateHire",
					pointerGuiName = "FtuePirateHireWorldPointerRoot",
					modelName = "PirateHire",
					style = {
						--- Offset left so the two dock-hire beams don't overlap.
						characterAttachOffset = Vector3.new(-0.5, 1.4, 0.2),
					},
				},
				{
					id = "ArmyGeneral",
					pointerGuiName = "FtueArmyGeneralWorldPointerRoot",
					modelName = "ArmyGeneral",
					style = {
						--- Offset right so the two dock-hire beams don't overlap.
						characterAttachOffset = Vector3.new(0.5, 1.4, 0.2),
					},
				},
			},
		},
	} :: { PoiBeamStepRule },
}

function FtuePoiBeamConfig.collectStreamingWatchNames(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function add(n: string?)
		if not n or n == "" or seen[n] then
			return
		end
		seen[n] = true
		table.insert(out, n)
	end
	for _, rule in FtuePoiBeamConfig.Rules do
		for _, t in rule.targets do
			add(t.pointerGuiName)
			add(t.modelName)
		end
	end
	return out
end

return FtuePoiBeamConfig
