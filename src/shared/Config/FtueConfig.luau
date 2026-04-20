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

	--- Drill duration (seconds) on the FTUE highlighted tile during the drill leg of **`WaitDrillOil_WIP`**. Overrides biome `drillSeconds` / tier divisor.
	FtueTutorialDrillSeconds = 5,

	--- When the player hits **Continue** on `WaitDrillOil_WIP` (skips the drill leg), grant this many **Crude**
	--- refinery barrels (capped by tank space) then advance to `WaitPlotShipment`. Set to **0** to disable the skip grant.
	FtueTestGrantRefineryCrudeBarrels = 10,

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
			body = "On your plot: use the **free drill** on the **highlighted tile**. The **pump** at the chunk center will start collecting oil automatically. When the first barrels show up, we'll get you ready to ship.\n\nNeed to move faster? **Continue** skips ahead with starter crude in your refinery.",
		},
		WaitPlotShipment = {
			title = "SHIP YOUR CARGO!",
			body = "Great work! Head over to the delivery man to dispatch your first haul.",
		},
		WaitShipment = {
			title = "SAIL THE STRAIT!",
			body = "Time to set sea! I'll give you my best ship so nobody should bother you this time. But be careful, that won't always be the case. Keep an eye on the status of the Strait!",
		},
		WaitWarehouseSell = {
			title = "TIME TO CASH IN!",
			body = "You've landed at your warehouse! Here you'll store all your oil that's successfully crossed the Strait. Head to the terminal to sell your first barrel.",
		},
		WaitSell = {
			title = "WATCH THE MARKET!",
			body = "Watch out! Oil prices move in real time, so make sure you check the market to get a good price before you sell.",
		},
		WaitDocksShipUpgrade = {
			title = "TO THE DOCKS!",
			body = "Now head to the town - that's where you'll buy all your equipment, upgrade your ship, and hire some Secret Services.",
		},
		WaitDocksUpgradeShip = {
			title = "VISIT THE DOCKMAN",
			body = "Find the Dockman to upgrade your ship - your first upgrade is on the house! Close the panel when you're done to proceed.",
		},
		WaitDocksHire = {
			title = "SUSPICIOUS PERSONS",
			body = "One more thing, there's been some shady personnel around town. If you're curious, find out what they're up to.",
		},
		Done = {
			title = "WELCOME TO TOWN",
			body = "That's it! You're a seasoned veteran of the Strait now. Don't forget to check the store often and explore. Now get to drilling!",
		},
	} :: { [string]: { title: string, body: string } },

	WrongTileDrill = "Drill only the highlighted tile.",

	--- Shipment HUD `Hint` line when placement is blocked to wrong cell (see `init.client` setStatus).
	ClientHintPlaceDrillOnTile = "Place the drill on the marked tile.",
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
