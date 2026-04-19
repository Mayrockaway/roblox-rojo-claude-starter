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
		WaitDocksShipUpgrade = "WaitDocksShipUpgrade",
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
		"WaitDocksHire",
		"Done",
	} :: { string },

	--- UI copy for dialogue panel (title + body). Placeholders until each leg is finalized.
	Copy = {
		Intro = {
			title = "CALLING ALL OIL TYCOONS!",
			body = "SOS! Our country is desperate for oil and we need you to get through the Strait of Hormuz by any means!",
		},
		WaitDrillOil_WIP = {
			title = "DRILL & COLLECT (WIP)",
			body = "Placeholder: new drill flow goes here through your first oil collection. Details TBD.",
		},
		WaitPlotShipment = {
			title = "SHIP YOUR CARGO",
			body = "Placeholder: walk to the shipment terminal on your plot and send your cargo. No HUD Ship Oil button for this leg.",
		},
		WaitShipment = {
			title = "ACROSS THE STRAIT",
			body = "Placeholder: wait for your shipment to finish. Check Strait status while you wait.",
		},
		WaitWarehouseSell = {
			title = "SELL AT THE WAREHOUSE",
			body = "Placeholder: land at the warehouse and use the terminal there to sell your oil.",
		},
		WaitSell = {
			title = "WATCH THE MARKET",
			body = "Placeholder: next time, check the oil market (top-left) before you sell.",
		},
		WaitDocksShipUpgrade = {
			title = "UPGRADE YOUR SHIP",
			body = "Placeholder: head to the docks and upgrade speed or cargo.",
		},
		WaitDocksHire = {
			title = "HIRE CREW",
			body = "Placeholder: at the docks, review the hire contract at the NPC.",
		},
		Done = {
			title = "WELCOME TO TOWN",
			body = "Placeholder: FTUE completes in town — here's startup cash. Full script TBD.",
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
		WaitDocksHire = FtuePortraitAssets.OilmanCelebrate,
		Done = FtuePortraitAssets.OilmanCelebrate,
	} :: { [string]: string },
}

return FtueConfig
