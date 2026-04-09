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
	LocalSellMultiplier = 0.5,
	LocalSellFlatBasePerBarrel = 10,
	MaxTotalPayoutMultiplier = 20,
}

return Constants
