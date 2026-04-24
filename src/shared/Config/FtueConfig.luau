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
	FtueTutorialShipmentSkinId = "Ducky",
	--- Multiplier on resolved `travelSeconds` for that first shipment only (`0.5` = 2× faster crossing than max-speed baseline).
	FtueTutorialShipmentTravelTimeScale = 0.5,

	DrillItemId = "drill_t1",

	--- Equipment shop FTUE leg (`WaitDocksEquipmentShop`): the player gets **one** free
	--- drill of this id from the dock equipment shop. `EquipmentShopService` reads this
	--- to (a) override that row's cost to **$0** in the catalog snapshot, (b) bypass the
	--- rotation stock check, and (c) advance the FTUE on a successful purchase. After
	--- the one-shot fires, `ftueFreeDocksDrillUsed` is set so the discount can never
	--- be replayed.
	FtueDocksFreeDrillItemId = "drill_t3",

	--- Drill duration (seconds) on the FTUE highlighted tile during the drill leg of **`WaitDrillOil_WIP`**. Overrides biome `drillSeconds` / tier divisor.
	FtueTutorialDrillSeconds = 5,

	--- Canonical step ids (also used for `Player` attribute `FtueStep`).
	Step = {
		Intro = "Intro",
		--- Placeholder bucket: drill + oil setup through **first oil collection** (exact gates TBD when drill/pipe systems land).
		WaitDrillOil_WIP = "WaitDrillOil_WIP",
		--- After the FTUE drill completes: prompt the player to interact with the shovel
		--- on the just-drilled tile. The lootbox sequence plays (locked to exactly **Rare**
		--- on this first FTUE roll only — see `OilStateService:CompleteDrill`).
		WaitReveal = "WaitReveal",
		--- Walk to **plot** shipment terminal and fulfill a shipment (no Ship Oil HUD pointer).
		WaitPlotShipment = "WaitPlotShipment",
		WaitShipment = "WaitShipment",
		--- Land at warehouse; sell at **warehouse** terminal (Sell Oil UI pointers may still apply).
		WaitWarehouseSell = "WaitWarehouseSell",
		WaitSell = "WaitSell",
		--- Go to Town: complete this leg by using the HUD **Buy** (teleport to docks), not Continue.
		WaitDocksShipUpgrade = "WaitDocksShipUpgrade",
		--- Visit the **Dock Equipment Shop** prox prompt → buy the free Tier 3 drill
		--- (`FtueDocksFreeDrillItemId`). `EquipmentShopService` advances the FTUE on
		--- successful purchase. No Continue button — the leg finishes only on purchase.
		WaitDocksEquipmentShop = "WaitDocksEquipmentShop",
		-- `WaitDocksUpgradeShip` (Dockman → free first cargo upgrade →
		-- close ship panel) was deleted by Step 4 of the boat-
		-- progression refactor along with the per-player speed/capacity
		-- upgrade ladder. The replacement leg below (`WaitDocksFleetPanel`)
		-- teaches the new single-modal `FleetPanelGui` (boat picker +
		-- buy + equip) introduced after the refactor.
		--- Dock fleet panel leg: world beam to the **Dockman**, prox prompt
		--- (`ManageShipPrompt.OpensPanel = "FleetPanelGui"`) opens the new
		--- `FleetPanelGui` modal, then UI pointer points at its `CloseButton`.
		--- Step advances to `WaitDocksHire` once the modal is closed.
		--- Sub-step (`Constants.FtueDocksFleetPanelSubStepAttribute`):
		---   `OpenPanel`  → beam to dockman, no UI pointer.
		---   `ClosePanel` → modal open, `CloseButtonPointerRoot` lit inside `FleetPanelGui`.
		WaitDocksFleetPanel = "WaitDocksFleetPanel",
		WaitDocksHire = "WaitDocksHire",
		Done = "Done",
	},

	--- Ordered server-driven flow (see `FtueService` + gameplay hooks).
	Order = {
		"Intro",
		"WaitDrillOil_WIP",
		"WaitReveal",
		"WaitPlotShipment",
		"WaitShipment",
		"WaitWarehouseSell",
		"WaitSell",
		"WaitDocksShipUpgrade",
		"WaitDocksEquipmentShop",
		-- `WaitDocksUpgradeShip` removed by Step 4 of the boat-
		-- progression refactor (see `Step` block above).
		-- `WaitDocksFleetPanel` is its replacement — teaches `FleetPanelGui`.
		"WaitDocksFleetPanel",
		"WaitDocksHire",
		"Done",
	} :: { string },

	--- UI copy for dialogue panel (title + body). `FtueDialogueController` maps these by step id.
	Copy = {
		Intro = {
			title = "CALLING ALL OIL TYCOONS!",
			body = "HEY YOU! Our country is desperate for oil and you look like you can get through the Strait of Hormuz by any means necessary!",
		},
		WaitDrillOil_WIP = {
			title = "FIRST STRIKE!",
			body = "Here's your first drill on the house - slap that drill on any tile over there and get to drilling! Your pump will automatically collect it for you.",
		},
		WaitReveal = {
			title = "STRUCK GOLD!",
			body = "Drill complete! Grab that shovel to find out what you struck. The deeper the vein, the richer the haul.",
		},
		WaitPlotShipment = {
			title = "SHIP YOUR CARGO!",
			body = "Great work! Head over to the delivery man to dispatch your first haul - each barrel costs a fee, but here's some cash to get started.",
		},
		WaitShipment = {
			title = "SAIL THE STRAIT!",
			body = "Time to set sea! I'll give you a speed boost so you can cross undisturbed. But be careful, that won't always be the case. Keep an eye on the status of the Strait!",
		},
		WaitWarehouseSell = {
			title = "TIME TO CASH IN!",
			body = "You've landed at your warehouse! Your cargo will automatically deposit here each run. Head to the terminal to sell your first barrel.",
		},
		WaitSell = {
			title = "WATCH THE MARKET!",
			body = "Watch out! Oil prices move in real time, so make sure you check the market to get a good price before you sell.",
		},
		WaitDocksShipUpgrade = {
			title = "TO THE DOCKS!",
			body = "Now head to the town - that's where you'll buy all your equipment, manage your fleet, and hire some Secret Services.",
		},
		WaitDocksEquipmentShop = {
			title = "GEAR UP!",
			body = "First stop, the Equipment Shop - here's where you'll find all your drilling gear. Step up to the counter and grab that Advanced Drill - first one's free.",
		},
		-- `WaitDocksUpgradeShip` copy removed by Step 4 of the boat-
		-- progression refactor (see `Step` block above).
		WaitDocksFleetPanel = {
			title = "MIND YOUR FLEET",
			body = "Next, talk to the dockman to get new, upgraded vessels and swap out your current ship.",
		},
		WaitDocksHire = {
			title = "SUSPICIOUS PERSONS",
			body = "One more thing, there's been some shady personnel around town. If you're curious, find out what they're up to, then hit Continue to move on.",
		},
		Done = {
			title = "WELCOME TO TOWN",
			body = "That's it! You're a seasoned veteran of the Strait now. Here's some cash to get started. Don't forget to check the store often and explore. Now get to drilling!",
		},
	} :: { [string]: { title: string, body: string } },

	WrongTileDrill = "Place the drill in the highlighted area.",

	--- Shipment HUD `Hint` line when placement is blocked to wrong cell (see `init.client` setStatus).
	ClientHintPlaceDrillOnTile = "Place the drill in the highlighted area.",
	--- `FtueDialogueController`: label on Continue when step is Done.
	DoneContinueButtonText = "Complete!",

	--- Optional portrait images for the dialogue panel (`PortraitFrame` / `PortraitImage` in FTUEDialogueGui).
	--- Keys are `Step` ids. Asset ids are defined once in `FtuePortraitAssets` (Asset Manager import names).
	PortraitImageByStep = {
		Intro = FtuePortraitAssets.OilManOilHead,
		WaitDrillOil_WIP = FtuePortraitAssets.OilmanDrilling,
		WaitReveal = FtuePortraitAssets.OilmanCelebrate,
		WaitPlotShipment = FtuePortraitAssets.OilmanSalute,
		WaitShipment = FtuePortraitAssets.OilmanBurger,
		WaitWarehouseSell = FtuePortraitAssets.OilManOilHead,
		WaitSell = FtuePortraitAssets.OilmanPointAngry,
		WaitDocksShipUpgrade = FtuePortraitAssets.OilmanSalute,
		WaitDocksEquipmentShop = FtuePortraitAssets.OilmanDrilling,
		-- `WaitDocksUpgradeShip` portrait removed by Step 4 of the boat-
		-- progression refactor (see `Step` block above).
		WaitDocksFleetPanel = FtuePortraitAssets.OilmanSalute,
		WaitDocksHire = FtuePortraitAssets.OilmanCelebrate,
		Done = FtuePortraitAssets.OilmanCelebrate,
	} :: { [string]: string },
}

return FtueConfig
