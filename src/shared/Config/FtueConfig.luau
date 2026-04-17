--!strict
-- First-time user experience (FTUE) — copy keys + economy knobs. Dialogue strings live here
-- (and in Studio placeholder text); `FtueDialogueController` maps step ids to title/body.

local FtueConfig = {
	--- Master switch. When false, FtueService no-ops and existing profiles unchanged.
	Enabled = true,

	--- Server-only: `warn` a full trace of FTUE transitions and oil FTUE fields (spammy; disable for prod).
	DebugTrace = false,

	--- If true, `Copy.title` is applied to the UI slot we resolve as **Body** and `Copy.body` to **Title**
	--- (common when the large paragraph box is named `Title` and the headline is `Body` in Studio).
	DialogueSwapTitleBodySlots = true,

	--- Persisted profile version that first wrote FTUE fields (migration). Oil profile `version` tracks similarly.
	PersistVersion = 9,

	--- Fresh profile (no DataStore row) starts with this oil cash when FTUE is enabled.
	StartingCash = 0,

	--- Cash granted when entering the Dispatch step (after pump on tutorial tile). **Only** this amount at that stage.
	DispatchStageCashReward = 50,

	--- Granted when the player reaches the final **Done** step (before Complete!). See `OilStateService.SetFtueProgress`.
	TutorialCompleteCashReward = 500,

	--- First FTUE strait shipment: cosmetic + guaranteed safe crossing (see `OilShipmentService`).
	FtueTutorialShipmentSkinId = "Ship5Skin",
	--- Multiplier on resolved `travelSeconds` for that first shipment only (`0.5` = 2× faster crossing than max-speed baseline).
	FtueTutorialShipmentTravelTimeScale = 0.5,

	DrillItemId = "drill_t1",
	PumpItemId = "pump_t1",
	PipeItemId = "pipe",

	--- Drill duration (seconds) on the FTUE highlighted tile during `WaitDrill`. Overrides biome `drillSeconds` / tier divisor.
	FtueTutorialDrillSeconds = 5,

	--- Canonical step ids (also used for `Player` attribute `FtueStep`).
	Step = {
		Intro = "Intro",
		WaitDrill = "WaitDrill",
		WaitPipe = "WaitPipe",
		WaitPump = "WaitPump",
		Dispatch = "Dispatch",
		WaitShipment = "WaitShipment",
		Sell = "Sell",
		WaitSell = "WaitSell",
		Done = "Done",
	},

	--- Ordered flow after intro acknowledge (server-driven transitions elsewhere).
	Order = {
		"Intro",
		"WaitDrill",
		"WaitPipe",
		"WaitPump",
		"Dispatch",
		"WaitShipment",
		"Sell",
		"WaitSell",
		"Done",
	} :: { string },

	--- UI copy for dialogue panel (title + body). Keep under ~400 chars body for mobile.
	Copy = {
		Intro = {
			title = "CALLING ALL OIL TYCOONS!",
			body = "SOS! Our great country is desperate for oil and we need you to get through the Strait of Hormuz by any means!",
		},
		WaitDrill = {
			title = "DRILL BABY DRILL!",
			body = "I'll give you your first free drill - equip it from your backpack. Drill the highlighted tile.",
		},
		WaitPipe = {
			title = "LAY SOME PIPE!",
			body = "Great! Here's a free pipe segment — place it on the highlighted tile to connect the oil well to your refinery.",
		},
		WaitPump = {
			title = "COLLECT THAT OIL!",
			body = "Now place your collector on the drilled tile so oil flows through the pipe into your refinery storage. Don't forget to upgrade storage later!",
		},
		Dispatch = {
			title = "SHIP YOUR OIL!",
			body = "Great work! Open the Ship Oil panel to dispatch your cargo. I'll let you borrow my super yacht this one time so nobody bothers you. Here's $50 toward your dispatch fee; after this, crossing won't be so easy.",
		},
		WaitShipment = {
			title = "SAIL THE STRAIT OF HORMUZ!",
			body = "While you're sailing, you can teleport home or back to your ship. Sit back and relax - you'll land near your warehouse. Check out the Strait statuses in the meantime!",
		},
		Sell = {
			title = "TIME TO CASH IN!",
			body = "Great work sailing the Strait! Now use the Sell Oil panel to cash in.",
		},
		WaitSell = {
			title = "GET A GOOD PRICE!",
			body = "Watch out! Next time, remember to check the oil market on the top left of your screen for good prices before you sell.",
		},
		Done = {
			title = "FIRST VOYAGE COMPLETE!",
			body = "Our great nation thanks you for your service. Here's some extra cash to get you started. Remember to upgrade your equipment, explore the docks for some Secret Services, and always watch the status of the Strait. Now drill baby drill!",
		},
	} :: { [string]: { title: string, body: string } },

	WrongTileDrill = "Drill only the highlighted tile.",
	WrongTilePipe = "Place the pipe on the highlighted tile.",
	WrongTilePump = "Place the pump on the highlighted tile.",

	--- Shipment HUD `Hint` line when placement is blocked to wrong cell (see `init.client` setStatus).
	ClientHintPlaceDrillOnTile = "Place the drill on the marked tile.",
	ClientHintPlacePumpOnTile = "Place the collector on the marked tile.",
	ClientHintPlacePipeOnTile = "Place the pipe on the marked tile.",
	--- `FtueDialogueController`: label on Continue when step is Done.
	DoneContinueButtonText = "Complete!",
}

return FtueConfig
