--!strict

local ErrorCodes = {
	Ok = "OK",
	Unknown = "ERR_UNKNOWN",
	Busy = "ERR_BUSY",
	RateLimited = "ERR_RATE_LIMITED",
	InvalidPayload = "ERR_INVALID_PAYLOAD",
	InvalidShipmentSize = "ERR_INVALID_SHIPMENT_SIZE",
	NoOil = "ERR_NO_OIL",
	CapacityExceeded = "ERR_CAPACITY_EXCEEDED",
	NotEnoughTierOil = "ERR_NOT_ENOUGH_TIER_OIL",
	TooManyShipments = "ERR_TOO_MANY_SHIPMENTS",
	ShipmentNotFound = "ERR_SHIPMENT_NOT_FOUND",
	SettlementDuplicate = "ERR_SETTLEMENT_DUPLICATE",
	StraitNotClosed = "ERR_STRAIT_NOT_CLOSED",
	NoPermission = "ERR_NO_PERMISSION",
	UpgradeNotFound = "ERR_UPGRADE_NOT_FOUND",
	UpgradeMaxed = "ERR_UPGRADE_MAXED",
	NotEnoughCash = "ERR_NOT_ENOUGH_CASH",
}

return ErrorCodes
