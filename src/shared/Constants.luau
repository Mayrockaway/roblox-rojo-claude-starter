--!strict

local Constants = {
	RemotesFolderName = "OilEmpireRemotes",
	WorldVisualsFolderName = "OilEmpireVisuals",
	MaxConcurrentShipmentsPerPlayer = 30,
	DefaultStorageCapacity = 100,
	DefaultBarrelsPerSecond = 1,
	MinVoyageSeconds = 10,
	MaxVoyageSeconds = 25,
	ProductionTickSeconds = 1,
	AutosaveIntervalSeconds = 30,
	RateLimitWindowSeconds = 10,
	RateLimitDefaultMaxRequests = 25,
	RateLimitShipmentRequests = 50,
	StraitMessagingTopic = "OilEmpireStraitStateV1",
	StraitMemoryStoreMap = "OilEmpireStraitMapV1",
	StraitLeaderLockKey = "leader-lock",
	StraitStateKey = "state",
	StraitLeaderLockSeconds = 12,
	StraitLeaderHeartbeatSeconds = 4,
	StraitFollowerPollSeconds = 6,
	-- Robux strait force-open / force-close hold (`MonetizationService` consumables
	-- `strait_open_2min` / `strait_close_2min` — see `MonetizationCatalog.luau`).
	-- Server-wide: while the lock is active no organic rotation, no other player's
	-- force flip, and no dev UI override can change the strait. Tune carefully —
	-- this is the marketed product duration, not just a UI animation length.
	StraitForceLockSeconds = 120,
	LocalSellMultiplier = 0.5,
	LocalSellFlatBasePerBarrel = 10,
	MaxTotalPayoutMultiplier = 20,

	-- Strait waypoint events (dev / QA). Ship live with both false/nil.
	-- ForceOccurrenceAtWaypoint: every crossing of 3/6/9 still rolls severity only (no 10/50/80% gate).
	-- ForceBracket: use this instead of live StraitStateService for bracket (Open / Restricted / Closed).
	-- LogWaypointTriggers: print strait waypoint diagnostics in ALL environments (including live).
	-- VerboseStraitWaypointLogsInStudio: when true (default), Roblox Studio server also prints (no need to flip LogWaypointTriggers). Set false to silence Studio.
	StraitEventsDebug = {
		ForceOccurrenceAtWaypoint = false,
		ForceBracket = nil :: "Open" | "Restricted" | "Closed" | nil,
		ForceMissileStrike = false, -- if true, every triggered event becomes MissileStrike
		ForceMineStrike = false, -- if true, every triggered event becomes MineStrike
		ForcePirateRaid = false, -- if true, every triggered event becomes PirateRaid
		ForceCoastGuardInspection = false, -- if true, every triggered event becomes CoastGuardInspection
		ForceUSShipSlap = false, -- if true, every triggered event becomes USShipSlap
		CoastGuardCalibrateAnchors = false, -- if true, spawn red/green anchor studs and pause 15s so you can drag them to the right spots
		ForceStorm = false, -- if true, every triggered event becomes Storm
		ForceTornado = false, -- if true, every triggered event becomes Tornado
		ForceNuke = false, -- debug: fire nuke immediately
		ForceAirStrike = false, -- debug: fire airstrike immediately
		LogWaypointTriggers = false,
		VerboseStraitWaypointLogsInStudio = true,
		--- Diagnostic: when true, `OilShipmentService:_freezeShipForStraitEventCinematic`
		--- prints the boat root velocity + the owner character's HRP velocity, SeatPart,
		--- FloorMaterial, attached BodyMovers / movement Constraints, and any external
		--- Welds before/during/after the cinematic freeze. Use to identify what is
		--- pulling the player toward a cosmetic NPC ship.
		LogFreezeCharacterSnapshot = true,
	},

	-- Replicated on shop `Tool` instances: stack size / uses in one slot (`EquipmentShopService`, hotbar UI).
	EquipmentStackCountAttribute = "EquipmentStackCount",

	-- FTUE: set on `Player` while onboarding. Global plot cell key, same format as server (`R{row}C{col}`).
	-- Empty / unset = no restriction. Server + client enforce drill placement to that cell only.
	FtueRestrictDrillCellKeyAttribute = "FtueRestrictDrillCellKey",
	--- Replicated FTUE step id for `FtueDialogueController` (e.g. Intro, WaitDrill). Cleared when done.
	FtueStepAttribute = "FtueStep",
	--- Docks upgrade leg (`WaitDocksUpgradeShip`): `"Dockman"` → talk opens ship UI → `"CargoBuy"` → upgrade → `"CloseModal"`.
	FtueDocksUpgradeSubStepAttribute = "FtueDocksUpgradeSubStep",
	--- Equipment shop leg (`WaitDocksEquipmentShop`): `"BuyDrill"` (purchase the free
	--- Tier 3 drill) → `"ClosePanel"` (close the modal). Closing while in
	--- `ClosePanel` advances FTUE to `WaitDocksUpgradeShip` (Dockman sub-step).
	FtueDocksEquipmentShopSubStepAttribute = "FtueDocksEquipmentShopSubStep",

	-- After Humanoid.Died: seconds before `LoadCharacter()` (PlotService; CharacterAutoLoads=false).
	-- Lower = faster respawn. Ignores `Players.RespawnTime` so tuning is explicit.
	RespawnDelayAfterDeathSeconds = 1.5,

	-- Server-spawned under-map kill plane (`KillZoneService`): horizontal box, anchored, non-colliding.
	KillZoneUnderMapCenterY = -280,
	KillZoneUnderMapThicknessY = 100,
	KillZoneUnderMapHorizontalHalfExtent = 4000,

	-- Dev strait UI (3 buttons). Server accepts only in Studio unless this is true.
	StraitDevUiEnabled = false,
	-- After dev UI sets strait, delay automatic state rolls this many seconds (testing).
	StraitDevStateHoldSeconds = 86400,
}

return Constants
