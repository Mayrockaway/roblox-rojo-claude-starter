--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local UpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("UpgradeConfig"))

local PersistenceService = {}

local DATASTORE_NAME = "OilEmpireProfiles_v1"

local function deepCopy(value)
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end

local function defaultProfile()
	return {
		version = 1,
		lastSeenAt = os.time(),
		cash = 0,
		capacity = Constants.DefaultStorageCapacity,
		oilByTier = {
			HeavyCrude = 0,
			StandardCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		upgrades = deepCopy(UpgradeConfig.DefaultLevels),
		activeShipments = {},
		pendingPayout = 0,
	}
end

function PersistenceService:Init(telemetryService)
	self._telemetryService = telemetryService
	self._store = nil
	self._cache = {}
	self._dirty = {}
	self._running = false
	self._saveThread = nil

	if not RunService:IsStudio() then
		local ok, storeOrErr = pcall(function()
			return DataStoreService:GetDataStore(DATASTORE_NAME)
		end)
		if ok then
			self._store = storeOrErr
		else
			warn("[PersistenceService] DataStore unavailable, memory-only mode:", storeOrErr)
		end
	else
		self._store = nil
	end
end

function PersistenceService:Start()
	if self._running then
		return
	end
	self._running = true
	self._saveThread = task.spawn(function()
		while self._running do
			task.wait(Constants.AutosaveIntervalSeconds)
			self:FlushDirty()
		end
	end)
end

function PersistenceService:Stop()
	self._running = false
	self:FlushDirty()
end

function PersistenceService:LoadProfile(userId: number)
	local key = tostring(userId)
	if self._cache[key] ~= nil then
		return deepCopy(self._cache[key])
	end

	local profile = nil
	if self._store ~= nil then
		local ok, valueOrErr = pcall(function()
			return self._store:GetAsync(key)
		end)
		if ok and typeof(valueOrErr) == "table" then
			profile = valueOrErr
		elseif not ok then
			self._telemetryService:Track("profile_load_failed", {
				userId = userId,
				error = tostring(valueOrErr),
			})
		end
	end

	if profile == nil then
		profile = defaultProfile()
	end

	profile = self:_normalizeProfile(profile)
	self._cache[key] = deepCopy(profile)
	return deepCopy(profile)
end

function PersistenceService:SetProfile(userId: number, profile)
	local key = tostring(userId)
	self._cache[key] = self:_normalizeProfile(deepCopy(profile))
	self._dirty[key] = true
end

function PersistenceService:UpdateProfile(userId: number, mutator)
	local profile = self:LoadProfile(userId)
	mutator(profile)
	self:SetProfile(userId, profile)
end

function PersistenceService:FlushUser(userId: number)
	local key = tostring(userId)
	if not self._dirty[key] then
		return
	end
	if self._store == nil then
		self._dirty[key] = nil
		return
	end

	local profile = self._cache[key]
	if profile == nil then
		self._dirty[key] = nil
		return
	end

	profile.lastSeenAt = os.time()
	local payload = deepCopy(profile)

	local ok, saveErr = pcall(function()
		self._store:SetAsync(key, payload)
	end)
	if ok then
		self._dirty[key] = nil
	else
		self._telemetryService:Track("profile_save_failed", {
			userId = userId,
			error = tostring(saveErr),
		})
	end
end

function PersistenceService:FlushDirty()
	for key, _ in pairs(self._dirty) do
		local userId = tonumber(key)
		if userId ~= nil then
			self:FlushUser(userId)
		end
	end
end

function PersistenceService:_normalizeProfile(profile)
	local normalized = defaultProfile()

	if typeof(profile.cash) == "number" then
		normalized.cash = math.max(0, math.floor(profile.cash))
	end
	if typeof(profile.capacity) == "number" then
		normalized.capacity = math.max(1, math.floor(profile.capacity))
	end

	if typeof(profile.oilByTier) == "table" then
		for tier, _ in pairs(normalized.oilByTier) do
			local raw = profile.oilByTier[tier]
			if typeof(raw) == "number" then
				normalized.oilByTier[tier] = math.max(0, math.floor(raw))
			end
		end
	end

	if typeof(profile.upgrades) == "table" then
		for upgradeId, defaultLevel in pairs(UpgradeConfig.DefaultLevels) do
			local rawLevel = profile.upgrades[upgradeId]
			if typeof(rawLevel) == "number" then
				normalized.upgrades[upgradeId] = math.max(0, math.floor(rawLevel))
			else
				normalized.upgrades[upgradeId] = defaultLevel
			end
		end
	end

	if typeof(profile.pendingPayout) == "number" then
		normalized.pendingPayout = math.max(0, math.floor(profile.pendingPayout))
	end

	if typeof(profile.activeShipments) == "table" then
		local packed = {}
		for _, shipment in pairs(profile.activeShipments) do
			if typeof(shipment) == "table" and typeof(shipment.shipmentId) == "string" then
				table.insert(packed, shipment)
			end
		end
		normalized.activeShipments = packed
	end

	normalized.lastSeenAt = os.time()
	return normalized
end

return PersistenceService
