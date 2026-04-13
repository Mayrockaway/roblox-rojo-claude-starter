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
	-- When true, first server `StraitStateService:Start` publishes Open and bumps version past any stale MemoryStore snapshot (temporary until live strait cycles ship).
	StraitForceOpenAtLaunch = true,
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
		LogWaypointTriggers = false,
		VerboseStraitWaypointLogsInStudio = true,
	},

	-- Dev strait UI (3 buttons). Server accepts only in Studio unless this is true.
	StraitDevUiEnabled = false,
	-- After dev UI sets strait, delay automatic state rolls this many seconds (testing).
	StraitDevStateHoldSeconds = 86400,
}

return Constants
