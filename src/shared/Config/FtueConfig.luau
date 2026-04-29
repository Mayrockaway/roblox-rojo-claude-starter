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

	--- Disconnect-mid-FTUE-shipment recovery cargo. When a player quits during
	--- `WaitShipment` and rejoins, `FtueService.SyncFromOilState` advances them
	--- to `WaitWarehouseSell` (assuming the boat arrived) — see the rejoin
	--- branch in that function. Without crediting cargo to the warehouse on
	--- that path, `OnFtueWarehouseSaleSuccess` would softlock the player at
	--- the sell terminal because it requires `payout > 0`. This manifest is
	--- delivered to `WarehouseService:DeliverBarrels` so the leg can complete.
	--- This is a strict one-shot per profile — `WaitShipment` is hit exactly
	--- once during the FTUE flow and `ftueStep` is cleared after `Done` — so
	--- the value just needs to be enough to make the sale payout non-zero.
	FtueRejoinRecoveryWarehouseCargo = { Crude = 3 } :: { [string]: number },

	--- First FTUE strait shipment: cosmetic + guaranteed safe crossing (see
	--- `OilShipmentService`). The protected dispatch projects the boat to
	--- `ShipUpgradeConfig.MaxSpeedLevel` and divides the resulting
	--- `travelSeconds` by **4** so the new player crosses at **4× the
	--- max-tier speed** (~7.5s base voyage). The "boat teleports to
	--- warehouse mid-strait" bug this used to trigger at high speeds is
	--- now hard-prevented by a guard in `_runShipment` that forces both
	--- failsafe wall checks to `false` whenever
	--- `ftueTutorialSuppressStraitIncidents` is set.
	FtueTutorialShipmentSkinId = "Ducky",

	--- Strait-event showcases fired during the protected tutorial voyage,
	--- keyed by lane waypoint index. Every event in this table runs in
	--- "harmless" mode — no barrel loss, no total loss, purely VFX/SFX
	--- — so the player can see the strait threats without being punished
	--- on their first crossing. Supported event ids:
	---   * `"MineStrike"`           → mines surface around the boat then sink
	---     (`_runFtueTutorialMineShowcase`, `didHit = false`).
	---   * `"CoastGuardInspection"` → coast guard cinematic + boat freeze
	---     (`_runFtueTutorialCoastGuardShowcase`).
	---   * `"Storm"`                → thunderstorm cinematic, no delay /
	---     no barrel loss (`_runFtueTutorialStormShowcase`). Not currently
	---     wired into the live FTUE flow, but the showcase function is
	---     kept around for re-enabling.
	--- The trigger waypoint must be inside the union of bracket allow-lists
	--- (currently `Closed = {2..9}` covers every reasonable choice). Set
	--- the table to `{}` (or `nil`) to skip the showcase entirely.
	FtueTutorialShowcasesByLaneWaypoint = {
		[3] = "CoastGuardInspection",
		[7] = "MineStrike",
	} :: { [number]: string },

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
		--- Legacy "Welcome to town" leg. Removed from `Order` — the live
		--- flow now jumps from `WaitSell` Continue (which already
		--- auto-teleports the player to docks) straight into
		--- `WaitDocksEquipmentShop`. The step id, copy, portrait, and
		--- ack-routing are kept so the leg can be reactivated by
		--- re-adding `"WaitDocksShipUpgrade"` to `Order` and routing
		--- `onAcknowledge`'s `WaitSell` branch back through it.
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
	---
	--- `Intro`, `WaitDocksShipUpgrade` ("welcome to town"), and
	--- `WaitDocksHire` ("suspicious persons") are intentionally omitted:
	--- their step ids, copy, and portraits are kept in the tables below
	--- so the legs can be reactivated by re-adding the strings here,
	--- but the live flow starts directly at `WaitDrillOil_WIP`, jumps
	--- from `WaitSell` Continue straight into `WaitDocksEquipmentShop`
	--- (the Continue handler also auto-teleports the player to docks),
	--- and jumps from `WaitDocksFleetPanel` straight to `Done`. See
	--- `FtueService` — `applyWaitDrillEntry` fires from the initial
	--- `SyncFromOilState` (not the Intro Continue button) and the
	--- `WaitSell` ack now seeds the `BuyDrill` sub-step before
	--- advancing.
	Order = {
		"WaitDrillOil_WIP",
		"WaitReveal",
		"WaitPlotShipment",
		"WaitShipment",
		"WaitWarehouseSell",
		"WaitSell",
		-- `WaitDocksShipUpgrade` removed — `WaitSell` Continue advances
		-- straight to `WaitDocksEquipmentShop` (see `Step` block above).
		"WaitDocksEquipmentShop",
		-- `WaitDocksUpgradeShip` removed by Step 4 of the boat-
		-- progression refactor (see `Step` block above).
		-- `WaitDocksFleetPanel` is its replacement — teaches `FleetPanelGui`.
		"WaitDocksFleetPanel",
		"Done",
	} :: { string },

	--- UI copy for dialogue panel (title + body). `FtueDialogueController` maps these by step id.
	Copy = {
		Intro = {
			title = "CALLING ALL OIL TYCOONS!",
			body = "HEY YOU! Our country is desperate for oil and you look like you can get through the Strait of Hormuz by any means necessary!",
		},
		WaitDrillOil_WIP = {
			title = "DRILL FOR OIL!",
			body = "Put that drill on any tile and get to drilling! Your pump will auto collect for you.",
		},
		WaitReveal = {
			title = "STRUCK GOLD!",
			body = "Drill complete! Grab that shovel to find out what you struck. The deeper the vein, the richer the haul.",
		},
		WaitPlotShipment = {
			title = "SHIP YOUR CARGO!",
			body = "Great work! Head over to the delivery man to dispatch your first haul.",
		},
		WaitShipment = {
			title = "SAIL THE STRAIT!",
			body = "Time to set sea! But be careful, anything can happen on the Strait - keep an eye on the status at all times.",
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
			title = "WELCOME TO TOWN!",
			body = "Welcome to town - here's where you'll buy all your equipment, manage your fleet, and hire some Secret Services.",
		},
		WaitDocksEquipmentShop = {
			title = "WELCOME TO TOWN!",
			body = "Welcome to town - head to the Equipment shop and grab that Advanced Drill - first one's free.",
		},
		-- `WaitDocksUpgradeShip` copy removed by Step 4 of the boat-
		-- progression refactor (see `Step` block above).
		WaitDocksFleetPanel = {
			title = "MIND YOUR FLEET",
			body = "Finally, talk to the dockman to get new, upgraded vessels and swap out your current ship.",
		},
		WaitDocksHire = {
			title = "SUSPICIOUS PERSONS",
			body = "One more thing, there's been some shady personnel around town. If you're curious, find out what they're up to, then hit Continue to move on.",
		},
		Done = {
			title = "CONGRATULATIONS!",
			body = "You're a seasoned veteran of the Strait now. Don't forget to explore the town and here's some cash to get started!",
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
