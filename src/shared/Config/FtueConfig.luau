--!strict
-- First-time user experience (FTUE) — copy keys + economy knobs. Dialogue strings live here
-- (and in Studio placeholder text); `FtueDialogueController` maps step ids to title/body.

local FtuePortraitAssets = require(script.Parent:WaitForChild("FtuePortraitAssets"))

local FtueConfig = {
	--- Master switch. When false, FtueService no-ops and existing profiles unchanged.
	Enabled = true,

	--- Server-only: `warn` a full trace of FTUE transitions and oil FTUE fields (spammy; disable for prod).
	DebugTrace = false,

	--- If true, `Copy.title` is applied to the UI slot we resolve as **Body** and `Copy.body` to **Title**
	--- (common when the large paragraph box is named `Title` and the headline is `Body` in Studio).
	DialogueSwapTitleBodySlots = true,

	--- Persisted profile version that first wrote FTUE fields (migration). Oil profile `version` tracks similarly.
	PersistVersion = 10,

	--- Fresh profile (no DataStore row) starts with this oil cash when FTUE is enabled.
	StartingCash = 0,

	--- One-time plot cash when entering **`WaitPlotShipment`** (plot shipment terminal leg). Server truth; pairs with client `UiSfx.playKaching` on that step.
	PlotShipmentStageCashReward = 50,

	--- Granted when the player reaches the final **Done** step (before Complete!). See `OilStateService.SetFtueProgress`.
	TutorialCompleteCashReward = 500,

	--- First FTUE strait shipment: cosmetic + guaranteed safe crossing (see `OilShipmentService`).
	FtueTutorialShipmentSkinId = "Ship5Skin",
	--- Multiplier on resolved `travelSeconds` for that first shipment only (`0.5` = 2× faster crossing than max-speed baseline).
	FtueTutorialShipmentTravelTimeScale = 0.5,

	DrillItemId = "drill_t1",
	PumpItemId = "pump_t1",
	PipeItemId = "pipe",

	--- Drill duration (seconds) on the FTUE highlighted tile during the drill leg of **`WaitDrillOil_WIP`**. Overrides biome `drillSeconds` / tier divisor.
	FtueTutorialDrillSeconds = 5,

	--- When the player hits **Continue** on `WaitDrillOil_WIP` (skips drill/pipe/pump leg), grant this many **HeavyCrude**
	--- refinery barrels (capped by tank space) then advance to `WaitPlotShipment`. Set to **0** to disable the skip grant.
	FtueTestGrantRefineryHeavyCrudeBarrels = 10,

	--- Canonical step ids (also used for `Player` attribute `FtueStep`).
	Step = {
		Intro = "Intro",
		--- Placeholder bucket: drill + oil setup through **first oil collection** (exact gates TBD when drill/pipe systems land).
		WaitDrillOil_WIP = "WaitDrillOil_WIP",
		--- Walk to **plot** shipment terminal and fulfill a shipment (no Ship Oil HUD pointer).
		WaitPlotShipment = "WaitPlotShipment",
		WaitShipment = "WaitShipment",
		--- Land at warehouse; sell at **warehouse** terminal (Sell Oil UI pointers may still apply).
		WaitWarehouseSell = "WaitWarehouseSell",
		WaitSell = "WaitSell",
		--- Go to Town: complete this leg by using the HUD **Buy** (teleport to docks), not Continue.
		WaitDocksShipUpgrade = "WaitDocksShipUpgrade",
		--- Dockman → free first **cargo** upgrade → close ship panel (sub-steps on `FtueDocksUpgradeSubStep`).
		WaitDocksUpgradeShip = "WaitDocksUpgradeShip",
		WaitDocksHire = "WaitDocksHire",
		Done = "Done",
	},

	--- Ordered server-driven flow (see `FtueService` + gameplay hooks).
	Order = {
		"Intro",
		"WaitDrillOil_WIP",
		"WaitPlotShipment",
		"WaitShipment",
		"WaitWarehouseSell",
		"WaitSell",
		"WaitDocksShipUpgrade",
		"WaitDocksUpgradeShip",
		"WaitDocksHire",
		"Done",
	} :: { string },

	--- UI copy for dialogue panel (title + body). `FtueDialogueController` maps these by step id.
	Copy = {
		Intro = {
			title = "CALLING ALL OIL TYCOONS!",
			body = "HEY YOU! Looking to make a quick buck? Our country is desperate for oil and you look like you can get through the Strait of Hormuz by any means necessary!",
		},
		WaitDrillOil_WIP = {
			title = "FIRST STRIKE",
			body = "On your plot: use the **free drill** on the **highlighted tile**, lay the **pipe** along the guided path, then place the **collector** on that same tile. When oil is moving, we'll get you ready to ship.\n\nNeed to move faster? **Continue** skips ahead with starter crude in your refinery.",
		},
		WaitPlotShipment = {
			title = "SHIP YOUR CARGO",
			body = "Walk to the **shipment terminal** on your plot and **dispatch** a load. This leg uses the plot board—no need for the Ship Oil HUD button.",
		},
		WaitShipment = {
			title = "ACROSS THE STRAIT",
			body = "Your cargo is underway. Keep an eye on **Strait status**—things can get lively out there. When the run finishes, we'll guide you to the warehouse.",
		},
		WaitWarehouseSell = {
			title = "SELL AT THE WAREHOUSE",
			body = "Head to the **warehouse** and use the **sell** flow there to cash in your barrels.",
		},
		WaitSell = {
			title = "WATCH THE MARKET",
			body = "Oil prices move. Next time you sell, glance at the **market readout** (top-left) so you don't leave money on the table.",
		},
		WaitDocksShipUpgrade = {
			title = "HEAD TO THE DOCKS",
			body = "Open **Town** from the HUD and take the trip to the **docks**. You'll upgrade your operation where the big ships tie up—no **Continue** here; the leg finishes when you arrive.",
		},
		WaitDocksUpgradeShip = {
			title = "VISIT THE DOCKMAN",
			body = "Find the **dockman** by the water and use them to open **ship management**. Your **first cargo upgrade is on the house** during this tutorial—buy capacity, then **close** the panel when you're done.",
		},
		WaitDocksHire = {
			title = "HIRE CREW",
			body = "Follow the line to the **hire** spot and meet your next contact. When you're ready, tap **Continue**.",
		},
		Done = {
			title = "WELCOME TO TOWN",
			body = "You're cleared for the open economy. There's a **cash bonus** waiting in your account—spend it wisely, and good luck on the Strait.",
		},
	} :: { [string]: { title: string, body: string } },

	WrongTileDrill = "Drill only the highlighted tile.",
	WrongTilePipe = "Place the pipe on the highlighted tile.",
	WrongTilePump = "Place the collector on the highlighted tile.",

	--- Shipment HUD `Hint` line when placement is blocked to wrong cell (see `init.client` setStatus).
	ClientHintPlaceDrillOnTile = "Place the drill on the marked tile.",
	ClientHintPlacePumpOnTile = "Place the collector on the marked tile.",
	ClientHintPlacePipeOnTile = "Place the pipe on the marked tile.",
	--- `FtueDialogueController`: label on Continue when step is Done.
	DoneContinueButtonText = "Complete!",

	--- Optional portrait images for the dialogue panel (`PortraitFrame` / `PortraitImage` in FTUEDialogueGui).
	--- Keys are `Step` ids. Asset ids are defined once in `FtuePortraitAssets` (Asset Manager import names).
	PortraitImageByStep = {
		Intro = FtuePortraitAssets.OilManOilHead,
		WaitDrillOil_WIP = FtuePortraitAssets.OilmanDrilling,
		WaitPlotShipment = FtuePortraitAssets.OilmanSalute,
		WaitShipment = FtuePortraitAssets.OilmanBurger,
		WaitWarehouseSell = FtuePortraitAssets.OilManOilHead,
		WaitSell = FtuePortraitAssets.OilmanPointAngry,
		WaitDocksShipUpgrade = FtuePortraitAssets.OilmanSalute,
		WaitDocksUpgradeShip = FtuePortraitAssets.OilmanDrilling,
		WaitDocksHire = FtuePortraitAssets.OilmanCelebrate,
		Done = FtuePortraitAssets.OilmanCelebrate,
	} :: { [string]: string },
}

return FtueConfig
