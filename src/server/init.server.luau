--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local legacyPlotScript = ServerScriptService:FindFirstChild("PlotService")
if legacyPlotScript and legacyPlotScript:IsA("Script") then
	legacyPlotScript:Destroy()
end

for _, child in ipairs(ServerScriptService:GetChildren()) do
	if child:IsA("Script") and child ~= script then
		warn(string.format("[Server] Extra Script in ServerScriptService: %s (can conflict with Rojo services)", child.Name))
	end
end


local serviceFolder = script:WaitForChild("Services")

-- Create `Shared.Remotes` + all RemoteEvent/RemoteFunctions before any other server work so
-- clients never sit on infinite WaitForChild (Studio "Infinite yield possible" / race with LocalScripts).
local RemoteService = require(serviceFolder:WaitForChild("RemoteService"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
RemoteService:Init()

-- Bootstrap Shared.Telemetry (server-authoritative analytics pipeline). The
-- module installs its `Players.PlayerAdded` / `Players.PlayerRemoving` /
-- `game:BindToClose` lifecycle hooks on first `require`, then iterates the
-- already-present players. Required here (early, side-effect only) so the
-- hooks are live before the first PlayerAdded fires; the returned table is
-- consumed by service code that wants to call `Telemetry.Track(...)` etc.
-- We also bind a wallet reader below (after `OilStateService:Init`) so
-- `Telemetry.Economy` can stamp the post-transaction cash balance onto
-- `LogEconomyEvent` — see `docs/features/telemetry/SPEC.md` §13 PR 3 / §9.1.
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local StraitStateService = require(serviceFolder:WaitForChild("StraitStateService"))
local PlotService = require(serviceFolder:WaitForChild("PlotService"))
local OilStateService = require(serviceFolder:WaitForChild("OilStateService"))
local PlotResourceService = require(serviceFolder:WaitForChild("PlotResourceService"))
local OilProductionService = require(serviceFolder:WaitForChild("OilProductionService"))
local ToolService = require(serviceFolder:WaitForChild("ToolService"))
local OilVisualService = require(serviceFolder:WaitForChild("OilVisualService"))
local BoatDockService = require(serviceFolder:WaitForChild("BoatDockService"))
local OilShipmentService = require(serviceFolder:WaitForChild("OilShipmentService"))
local PerfService = require(serviceFolder:WaitForChild("PerfService"))
local ChunkOwnershipService = require(serviceFolder:WaitForChild("ChunkOwnershipService"))
local WarehouseService = require(serviceFolder:WaitForChild("WarehouseService"))
local OilMarketService = require(serviceFolder:WaitForChild("OilMarketService"))
local EquipmentShopService = require(serviceFolder:WaitForChild("EquipmentShopService"))
local OilmanService = require(serviceFolder:WaitForChild("OilmanService"))
local InstantSellService = require(serviceFolder:WaitForChild("InstantSellService"))
local MonetizationService = require(serviceFolder:WaitForChild("MonetizationService"))
local DrillingService = require(serviceFolder:WaitForChild("DrillingService"))
local FtueService = require(serviceFolder:WaitForChild("FtueService"))
local OilTankService = require(serviceFolder:WaitForChild("OilTankService"))
local FighterPlaneWaveService = require(serviceFolder:WaitForChild("FighterPlaneWaveService"))
local HitContractService = require(serviceFolder:WaitForChild("HitContractService"))
local ArmyGeneralService = require(serviceFolder:WaitForChild("ArmyGeneralService"))
local FlotsamService = require(serviceFolder:WaitForChild("FlotsamService"))
local SecurityPersonnelService = require(serviceFolder:WaitForChild("SecurityPersonnelService"))
local CargoHaulerService = require(serviceFolder:WaitForChild("CargoHaulerService"))
local AutoShipService = require(serviceFolder:WaitForChild("AutoShipService"))
local KillZoneService = require(serviceFolder:WaitForChild("KillZoneService"))
local LeaderboardService = require(serviceFolder:WaitForChild("LeaderboardService"))
local GlobalEventService = require(serviceFolder:WaitForChild("GlobalEventService"))
local DailyRewardCalendarService = require(serviceFolder:WaitForChild("DailyRewardCalendarService"))
local OilHeavenPlotService = require(serviceFolder:WaitForChild("OilHeavenPlotService"))
local OilHeavenDrillService = require(serviceFolder:WaitForChild("OilHeavenDrillService"))
local RebirthShopService = require(serviceFolder:WaitForChild("RebirthShopService"))

local DevLog = require(Shared:WaitForChild("DevLog"))

-- Strait waypoint VFX templates live under RS; if any Sound is saved with Playing=true it is audible
-- to everyone from join. Storm/tornado audio is started only from cloned sounds on StormEvent/TornadoEvent.
-- Legacy Workspace.SFX.BGM must stay off: BGM is cloned per-client from ReplicatedStorage.Assets.SFX.BGM.
do
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local straitFx = assets and assets:FindFirstChild("StraitWaypointsFx")
	if straitFx then
		for _, d in ipairs(straitFx:GetDescendants()) do
			if d:IsA("Sound") then
				d.Playing = false
				d:Stop()
			end
		end
	end
	local sfx = workspace:FindFirstChild("SFX")
	local legacyBgm = sfx and sfx:FindFirstChild("BGM")
	if legacyBgm and legacyBgm:IsA("Sound") then
		legacyBgm.Playing = false
		legacyBgm:Stop()
	end
	local legacyDrill = sfx and sfx:FindFirstChild("Drilling")
	if legacyDrill and legacyDrill:IsA("Sound") then
		legacyDrill.Playing = false
		legacyDrill:Stop()
	end
	for _, sfxName in ipairs({ "SetSail", "Kaching", "CollectorBuild", "OceanWaves" }) do
		local s = sfx and sfx:FindFirstChild(sfxName)
		if s and s:IsA("Sound") then
			s.Playing = false
			s:Stop()
		end
	end
end

PerfService:Init()
KillZoneService:Init()
_G.Perf = PerfService   -- global hook so any service can call PerfService:OpenSpan/CloseSpan without wiring
-- Studio-only: mirror server `DevLog.log(...)` to every connected client so
-- the in-Studio Output for Client 1 surfaces server traces alongside client
-- ones (avoids hopping between Studio processes during multi-player Test).
-- Disabled in live builds because (a) players never read it — server logs
-- already go to the place owner's Developer Console — and (b) we'd rather
-- not pay a `FireAllClients` round-trip and serialize string per server log
-- in production. `DevLog.log(...)` itself still calls `print(...)` either
-- way, so server Output continues to work normally on the live shard.
if RunService:IsStudio() then
DevLog.SetBroadcaster(function(msg)
	local ev = RemoteService:GetEvent(RemoteNames.DevLog)
	ev:FireAllClients(msg)
end)
end
LeaderboardService:Init()StraitStateService:Init(RemoteService)PlotService:Init()OilStateService:Init(RemoteService, PlotService)-- Plumb the post-transaction cash balance into `LogEconomyEvent` via the
-- registered wallet reader. Done here (after `OilStateService:Init`, before
-- any service `:Start()` could emit) so every `Telemetry.Economy` call from
-- this point on stamps a real `endingBalance` on the Roblox dashboard
-- instead of the previous hardcoded `0`. Currency parameter is keyed off
-- the caller's `currency` arg; only `"cash"` is wired today.
Telemetry.SetWalletReader(function(player: Player, currency: string): number?
	if currency == "cash" then
		return OilStateService:GetCash(player.UserId)
	end
	if currency == "rebirth_tokens" then
		return OilStateService:GetRebirthTokens(player.UserId)
	end
	return nil
end)
OilVisualService:Init(OilStateService, PlotService)
BoatDockService:Init(RemoteService, OilStateService)
OilShipmentService:Init(RemoteService, OilStateService, PlotService, WarehouseService, StraitStateService, BoatDockService)
BoatDockService:SetOilShipmentService(OilShipmentService)
HitContractService:Init(RemoteService, OilStateService, OilShipmentService)
ArmyGeneralService:Init(RemoteService, OilStateService, OilShipmentService)
FlotsamService:Init(OilStateService)
FlotsamService:SetStraitStateService(StraitStateService)
FlotsamService:SetEquipmentShopService(EquipmentShopService)
FlotsamService:SetWarehouseService(WarehouseService)
FlotsamService:SetRemoteService(RemoteService)
SecurityPersonnelService:Init(OilStateService)
CargoHaulerService:Init(OilStateService)
AutoShipService:Init(RemoteService, OilStateService, WarehouseService, BoatDockService, OilShipmentService, MonetizationService)
OilHeavenPlotService:Init(PlotService, OilStateService)
OilHeavenDrillService:Init(RemoteService, OilStateService, OilHeavenPlotService, PlotService)
RebirthShopService:Init(RemoteService, OilStateService)
RebirthShopService:SetWarehouseService(WarehouseService)
RebirthShopService:SetDrillingService(DrillingService)
RebirthShopService:SetEquipmentShopService(EquipmentShopService)
RebirthShopService:SetOilShipmentService(OilShipmentService)
RebirthShopService:SetOilHeavenPlotService(OilHeavenPlotService)
OilHeavenPlotService:SetHeavenDrillService(OilHeavenDrillService)
OilShipmentService:SetOilHeavenPlotService(OilHeavenPlotService)
OilShipmentService:SetHitContractService(HitContractService)
OilShipmentService:SetLeaderboardService(LeaderboardService)
OilStateService:SetLeaderboardService(LeaderboardService)
OilShipmentService:SetSecurityPersonnelService(SecurityPersonnelService)
OilShipmentService:SetCargoHaulerService(CargoHaulerService)
OilShipmentService:SetAutoShipService(AutoShipService)
ChunkOwnershipService:Init(PlotService, OilStateService)
WarehouseService:Init(RemoteService, OilStateService)
OilMarketService:Init(RemoteService, StraitStateService, WarehouseService, OilStateService)
EquipmentShopService:Init(RemoteService, OilStateService, PlotService)
DailyRewardCalendarService:Init(RemoteService, OilStateService, EquipmentShopService)
OilmanService:Init(RemoteService, OilStateService)
InstantSellService:Init(RemoteService, OilStateService)
MonetizationService:Init(RemoteService, OilStateService, StraitStateService)
-- Inject `MonetizationService` into `OilStateService` so every `AddCash`
-- credit picks up the **DoubleEarnings** GamePass multiplier without each
-- earning service needing to know about the boost (oil sales, FTUE rewards,
-- etc.). Refunds and Robux currency packs explicitly opt out via
-- `AddCash(uid, amt, { skipMultiplier = true })` — see `OilStateService:AddCash`.
OilStateService:SetMonetizationService(MonetizationService)
ArmyGeneralService:SetMonetizationService(MonetizationService)
HitContractService:SetMonetizationService(MonetizationService)
SecurityPersonnelService:SetMonetizationService(MonetizationService)
CargoHaulerService:SetMonetizationService(MonetizationService)
EquipmentShopService:SetMonetizationService(MonetizationService)
OilHeavenDrillService:SetMonetizationService(MonetizationService)
-- GlobalEventService runs the server-wide buff/threat rotation
-- (`cash_frenzy`, `express_convoy`). Inject into the two
-- consumer services AFTER `Init` so the query API is available before
-- `Start`. Effects are pulled at narrow hook sites:
--   * `OilStateService:AddCash` — `GetMultiplier("Cash")` stacks AFTER
--     the `DoubleEarnings` GamePass multiplier (×4 for owners during
--     Cash Frenzy).
--   * `OilShipmentService:_handleDispatch` — `GetShipStatsBoost()`
--     overrides resolved ship stats (Express Convoy = ÷2 travel time +
--     ×1.5 capacity).
--   * `OilShipmentService:_handleStraitWaypointTrigger` —
--     `GetForcedStraitEventId()` replaces the rolled strait event with a
--     forced catalog id when a `ForceStraitEvent` is active (none in the
--     current catalog) AFTER the
--     `eventImmunity` (Security Personnel) and bracket allow-list
--     gates, so defended runs and Open straits stay proportional.
GlobalEventService:Init(RemoteService)
OilStateService:SetGlobalEventService(GlobalEventService)
OilShipmentService:SetGlobalEventService(GlobalEventService)
PlotResourceService:Init(RemoteService, OilStateService, PlotService, OilVisualService, OilShipmentService, ChunkOwnershipService)
--- `RemoteService` second arg lets the production loop fire per-pump
--- `pumpCollected` FX packets via `DrillProgressUpdate` for client-side
--- spatial pump SFX. Optional in the service signature; passing it here
--- keeps the wiring discoverable next to the other service Inits.
OilProductionService:Init(OilStateService, RemoteService)
DrillingService:Init(RemoteService, OilStateService)
FtueService:Init(RemoteService, PlotService, OilStateService, EquipmentShopService, DrillingService, OilShipmentService, OilMarketService, WarehouseService)
OilStateService:SetFtueService(FtueService)
OilShipmentService:SetFtueService(FtueService)
OilMarketService:SetFtueService(FtueService)
EquipmentShopService:SetFtueService(FtueService)
OilStateService:SetStateReadyForTimersCallback(function(userId: number, drillDone: { any })
	DrillingService:ReplayCompletedDrills(userId, drillDone)
	if #drillDone > 0 then
		OilStateService:PushState(userId)
	end
	DrillingService:ResumePendingDrillDelays(userId)
	DrillingService:ReplayUnrevealedTiles(userId)
	--- FTUE rejoin: `RehydrateExpiredTimers` calls `OilStateService:CompleteDrill`
	--- directly (not through `DrillingService:_scheduleDrillCompletion`), so the
	--- normal `OnFtueTutorialDrillFinished` notification that advances `WaitDrillOil_WIP`
	--- → `WaitReveal` is skipped. Replay it here for any drill the player completed
	--- while offline so they don't rejoin stuck on the old drill step + restrict
	--- attribute (which would also keep the old beam + tile highlight active).
	for _, done in ipairs(drillDone) do
		FtueService:OnFtueTutorialDrillFinished(userId, done)
	end
	--- OilHeaven tile visuals (drilled-tile reward labels + locked-section
	--- styling) need to run AFTER state has fully loaded. The `OnPlotAssigned`
	--- listener in `OilHeavenPlotService` also calls `_applyLockState`, but
	--- it fires in parallel with `OilStateService`'s own OnPlotAssigned
	--- (which yields on a DataStore read) — so on rejoin, the heaven visuals
	--- can run before `state.oilHeavenState` is populated, with the result
	--- that previously-drilled tiles render with their default question-mark
	--- visuals until the next refresh (e.g. after a rebirth). Calling
	--- `RefreshUnlocks` here from inside the state-ready callback guarantees
	--- the visual pass runs against a fully-loaded `oilHeavenState`. pcall'd
	--- so a heaven-side bug can't break the regular drill replay above.
	pcall(function()
		OilHeavenPlotService:RefreshUnlocks(userId)
	end)
end)
OilTankService:Init(RemoteService, OilStateService)
ToolService:Init()
FighterPlaneWaveService:Init(RemoteService)

PerfService:Start()
KillZoneService:Start()
RemoteService:Start()
StraitStateService:Start()
PlotService:Start()
OilStateService:Start()
OilVisualService:Start()
BoatDockService:Start()
OilShipmentService:Start()
HitContractService:Start()
ArmyGeneralService:Start()
FlotsamService:Start()
SecurityPersonnelService:Start()
CargoHaulerService:Start()
AutoShipService:Start()
ChunkOwnershipService:Start()
WarehouseService:Start()
OilMarketService:Start()
EquipmentShopService:Start()
DailyRewardCalendarService:Start()
OilmanService:Start()
InstantSellService:Start()
MonetizationService:Start()
PlotResourceService:Start()
OilProductionService:Start()
DrillingService:Start()
FtueService:Start()
OilTankService:Start()
ToolService:Start()
FighterPlaneWaveService:Start()
LeaderboardService:Start()
GlobalEventService:Start()
OilHeavenPlotService:Start()
OilHeavenDrillService:Start()
RebirthShopService:Start()

game:BindToClose(function()
	RebirthShopService:Stop()
	OilHeavenDrillService:Stop()
	OilHeavenPlotService:Stop()
	GlobalEventService:Stop()
	KillZoneService:Stop()
	PerfService:Stop()
	ToolService:Stop()
	OilTankService:Stop()
	FighterPlaneWaveService:Stop()
	LeaderboardService:Stop()
	DrillingService:Stop()
	FtueService:Stop()
	OilProductionService:Stop()
	PlotResourceService:Stop()
	OilMarketService:Stop()
	EquipmentShopService:Stop()
	OilmanService:Stop()
	MonetizationService:Stop()
	InstantSellService:Stop()
	WarehouseService:Stop()
	ChunkOwnershipService:Stop()
	OilShipmentService:Stop()
	ArmyGeneralService:Stop()
	SecurityPersonnelService:Stop()
	CargoHaulerService:Stop()
	HitContractService:Stop()
	BoatDockService:Stop()
	OilVisualService:Stop()
	OilStateService:Stop()
	StraitStateService:Stop()
	PlotService:Stop()
	RemoteService:Stop()
end)

-- Debug chat commands. Available in Studio always; in the live Roblox app only
-- to the game owner (so randoms can't /grant500 themselves). Without this gate
-- moved out of the IsStudio block, TextChatCommand never registers in the app
-- and every slash command silently no-ops.
do
	local Players = game:GetService("Players")
	local isStudio = RunService:IsStudio()

	local function isAuthorizedDev(player: Player): boolean
		if isStudio then return true end
		-- Game.CreatorId works for both user-owned and group-owned places.
		-- For group games we'd need GroupService:GetRankInGroup; simpler check first.
		return player.UserId == game.CreatorId
	end

	local function grantAllPlayersCash(amount: number)
		local okCount = 0
		for _, p in ipairs(Players:GetPlayers()) do
			if OilStateService:AddCash(p.UserId, amount) then
				OilStateService:PushState(p.UserId)
				okCount += 1
			end
		end
		print(string.format("[Dev] grant all cash +$%d → %d player(s) with oil state", amount, okCount))
	end

	-- Studio command bar: `_G.__OTS_DEV_GRANT_ALL_CASH(500)`
	_G.__OTS_DEV_GRANT_ALL_CASH = grantAllPlayersCash

	local DEV_MAX_PLOT_GRANT_CASH = 1000000
	local DEV_TILE_KEYS_IN_PLOT_ORDER = {
		"T11", "T12", "T13", "T14", "T15",
		"T21", "T22", "T23", "T24", "T25",
		"T31", "T32", "T34", "T35",
		"T41", "T42", "T43", "T44", "T45",
		"T51", "T52", "T53", "T54", "T55",
	}

	local function devUnlockAllChunksForPlayer(player: Player): (number, number)
		local state = OilStateService:GetState(player.UserId)
		if not state then
			warn(string.format("[Dev] /unlockplot by %s: no oil state loaded", player.Name))
			return 0, 0
		end

		OilStateService:AddCash(player.UserId, DEV_MAX_PLOT_GRANT_CASH, { skipMultiplier = true })
		OilStateService:PushState(player.UserId)

		local orderedChunks = {}
		for _, chunk in pairs(state.chunksById) do
			table.insert(orderedChunks, chunk)
		end
		table.sort(orderedChunks, function(a, b)
			if a.row == b.row then
				return a.col < b.col
			end
			return a.row < b.row
		end)

		local unlockedNow = 0
		local progressed = true
		while progressed do
			progressed = false
			for _, chunk in ipairs(orderedChunks) do
				if not chunk.unlocked then
					local ok = OilStateService:TryBuyChunk(player.UserId, chunk.chunkId)
					if ok then
						unlockedNow += 1
						progressed = true
					end
				end
			end
		end

		local stillLocked = 0
		for _, chunk in pairs(state.chunksById) do
			if not chunk.unlocked then
				stillLocked += 1
			end
		end

		return unlockedNow, stillLocked
	end

	local function devSeedMaxPlotOilForPlayer(player: Player): number
		local state = OilStateService:GetState(player.UserId)
		if not state then
			warn(string.format("[Dev] /maxplot by %s: no oil state loaded", player.Name))
			return 0
		end

		local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
		local oilCycle = { "DirtOil", "GoodOil", "GoldOil" }
		local streamCycle = { "Dribble", "Stream", "Burst", "Geyser" }
		local veinCounts = {
			{ name = "Single", count = 1 },
			{ name = "Double", count = 2 },
			{ name = "Triple", count = 3 },
		}

		local seeded = 0
		local tileIndex = 0
		local now = workspace:GetServerTimeNow()
		local orderedChunks = {}
		for _, chunk in pairs(state.chunksById) do
			if chunk.unlocked then
				table.insert(orderedChunks, chunk)
			end
		end
		table.sort(orderedChunks, function(a, b)
			if a.row == b.row then
				return a.col < b.col
			end
			return a.row < b.row
		end)

		for _, chunk in ipairs(orderedChunks) do
			if chunk.tiles then
				local groundType = chunk.groundType or chunk.biome or "Bronze"
				for _, tileKey in ipairs(DEV_TILE_KEYS_IN_PLOT_ORDER) do
					local tile = chunk.tiles[tileKey]
					if tile then
						tileIndex += 1
						local veinDef = veinCounts[((tileIndex - 1) % #veinCounts) + 1]
						local veins = {}
						for i = 1, veinDef.count do
							local oilType = oilCycle[((tileIndex + i - 2) % #oilCycle) + 1]
							local streamType = streamCycle[((tileIndex + i - 2) % #streamCycle) + 1]
							table.insert(veins, {
								oilType = oilType,
								streamType = streamType,
							})
						end
						tile.drilled = true
						tile.hasOil = true
						tile.revealPending = nil
						tile.revealedAt = now - 10
						tile.visualsStartedAt = now - 10
						tile.veinTypeId = nil
						tile.veinResult = {
							isDead = false,
							veinCount = veinDef.name,
							veins = veins,
							groundType = groundType,
						}
						tile.oilType = VeinConfig.GetInternalOilName(veins[1].oilType)
						seeded += 1
					end
				end
			end
		end

		OilStateService:_markDirty(player.UserId)
		OilStateService:PushState(player.UserId)
		return seeded
	end

	local function devWipePersistedForUser(userId: number)
		OilStateService:MarkDevSkipSaveOnNextDrop(userId)
		WarehouseService:MarkDevSkipSaveOnNextDrop(userId)
		OilStateService:DevRemovePersistedOilProfile(userId)
		WarehouseService:DevRemovePersistedWarehouseProfile(userId)
	end

	local function devGrantRebirths(player: Player, count: number): number
		local clampedCount = math.clamp(math.floor(count), 1, 99)
		local newCount = OilStateService:GetRebirthCount(player.UserId)
		for _ = 1, clampedCount do
			newCount = OilStateService:IncrementRebirth(player.UserId)
		end
		OilStateService:UnlockOilHeaven(player.UserId)
		OilHeavenPlotService:RefreshUnlocks(player.UserId)
		OilStateService:PushState(player.UserId)
		return newCount
	end

	local function devGiveRebirthDrill(player: Player, count: number?): (number, number)
		local n = if typeof(count) == "number" and count > 0 then math.floor(count) else 1
		local rebirthCount = OilStateService:GetRebirthCount(player.UserId)
		if rebirthCount < 1 then
			rebirthCount = OilStateService:IncrementRebirth(player.UserId)
		end
		OilStateService:UnlockOilHeaven(player.UserId)
		OilHeavenPlotService:RefreshUnlocks(player.UserId)
		OilHeavenDrillService:GrantRebirthDrillTool(player, n)
		OilStateService:PushState(player.UserId)
		local newDrillCount = OilStateService:GetRebirthDrills(player.UserId)
		return rebirthCount, newDrillCount
	end

	local function matchesCommandPrefix(cmd: string, prefix: string): boolean
		return cmd == prefix or cmd:sub(1, #prefix + 1) == prefix .. " "
	end

	-- Studio: wipe DataStore keys + skip leave-save so old state does not re-write after `RemoveAsync`.
	_G.__OTS_DEV_WIPE_PLAYER = function(userId: number)
		devWipePersistedForUser(userId)
		local p = Players:GetPlayerByUserId(userId)
		if p then
			p:Kick("[Dev] Persisted data wiped — rejoin for a fresh profile.")
		end
	end

	local function onDebugChat(player: Player, message: string)
		if not isAuthorizedDev(player) then return end
			local cmd = message:lower():gsub("^%s+", ""):gsub("%s+$", "")
			if cmd == "/missile" then
				OilShipmentService:DebugDispatchMissile(player)
			elseif cmd == "/mine" then
				OilShipmentService:DebugDispatchMine(player)
			elseif cmd == "/pirate" then
				OilShipmentService:DebugDispatchPirate(player)
			elseif cmd == "/storm" then
				OilShipmentService:DebugDispatchStorm(player)
			elseif cmd == "/tornado" then
				OilShipmentService:DebugDispatchTornado(player)
			elseif cmd == "/coastguard" then
				OilShipmentService:DebugDispatchCoastGuard(player)
			elseif cmd == "/slap" then
				OilShipmentService:DebugDispatchUSShipSlap(player)
		elseif cmd == "/nuke" then
			ArmyGeneralService:DebugNuke(player)
		elseif cmd == "/airstrike" then
			ArmyGeneralService:DebugAirstrike(player)
			elseif cmd == "/fighterwave" or cmd == "/fighters" then
				FighterPlaneWaveService:DebugSpawnWave(player.Name)
			elseif cmd == "/fighterhere" or cmd == "/jethere" then
				FighterPlaneWaveService:DebugSpawnOverPlayer(player)
			elseif cmd == "/fighterretarget" or cmd == "/jetretarget" then
				FighterPlaneWaveService:DebugRetargetTemplate(player.Name)
		elseif cmd:sub(1, 9) == "/testvein" then
			-- /testvein <oil> <stream> <veincount>
			-- oil: dirt, good, gold
			-- stream: dribble, stream, burst, geyser
			-- vein: single, double, triple
			-- e.g. /testvein gold geyser triple
			local args = cmd:sub(10):gsub("^%s+", "")
			local oilArg, streamArg, veinArg = args:match("^(%S+)%s+(%S+)%s*(%S*)")
			oilArg = oilArg or "good"
			streamArg = streamArg or "stream"
			veinArg = veinArg or "single"

			local oilMap = { dirt = "DirtOil", good = "GoodOil", gold = "GoldOil" }
			local streamMap = { dribble = "Dribble", stream = "Stream", burst = "Burst", geyser = "Geyser" }
			local veinMap = { single = "Single", double = "Double", triple = "Triple" }

			local oilKey = oilMap[oilArg] or "GoodOil"
			local streamKey = streamMap[streamArg] or "Stream"
			local veinKey = veinMap[veinArg] or "Single"
			local veinCount = ({ Single = 1, Double = 2, Triple = 3 })[veinKey] or 1

			local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
			local internalOil = VeinConfig.GetInternalOilName(oilKey)

			-- Build forced vein result
			local veins = {}
			for i = 1, veinCount do
				table.insert(veins, { streamType = streamKey, oilType = oilKey })
			end
			local forcedResult = {
				isDead = false,
				veinCount = veinKey,
				veins = veins,
				groundType = "Bronze",
			}

			-- Force it onto the player's starter tile T11 in S04_02
			local state = OilStateService:GetState(player.UserId)
			if state then
				local chunk = state.chunksById["S04_02"]
				if chunk and chunk.tiles then
					-- Find first undrilled tile (skip T33 center pump)
					local targetKey = nil
					for _, tk in ipairs({"T11","T12","T13","T14","T15","T21","T22","T23","T24","T25","T31","T32","T34","T35","T41","T42","T43","T44","T45","T51","T52","T53","T54","T55"}) do
						local tile = chunk.tiles[tk]
						if tile and not tile.drilled then
							targetKey = tk
							break
						end
					end
					if targetKey then
						local tile = chunk.tiles[targetKey]
						tile.drilled = true
						tile.hasOil = true
						tile.oilType = internalOil
						tile.veinResult = forcedResult
						tile.revealPending = nil
						OilStateService:PushState(player.UserId)
						print(string.format("[Dev] testvein: %s %s %s on %s (oil=%s)", veinKey, oilKey, streamKey, targetKey, internalOil))
					else
						print("[Dev] testvein: no undrilled tiles left in S04_02")
					end
				end
			end
		elseif cmd:sub(1, 11) == "/givedrills" then
			local args = cmd:sub(12):gsub("^%s+", "")
			local countArg, tierArg = args:match("^(%d+)%s*(%S*)")
			local count = tonumber(countArg) or 10
			local tier = tierArg and tierArg ~= "" and tierArg:lower() or "t3"
			local itemId = "drill_" .. tier
			EquipmentShopService:GrantFreeOwnedEquipment(player, itemId, count)
			print(string.format("[Dev] Gave %s x%d %s drills", player.Name, count, tier:upper()))
		elseif cmd == "/unlockplot" or cmd == "/unlockallchunks" then
			local unlockedNow, stillLocked = devUnlockAllChunksForPlayer(player)
			if stillLocked == 0 then
				print(string.format("[Dev] /unlockplot by %s -> unlocked %d chunk(s), plot fully unlocked", player.Name, unlockedNow))
			else
				warn(string.format("[Dev] /unlockplot by %s -> unlocked %d chunk(s), %d still locked", player.Name, unlockedNow, stillLocked))
			end
		elseif cmd == "/maxplot" or cmd == "/fillplot" then
			local unlockedNow, stillLocked = devUnlockAllChunksForPlayer(player)
			if stillLocked > 0 then
				warn(string.format("[Dev] /maxplot by %s -> chunk unlock incomplete, %d still locked", player.Name, stillLocked))
				return
			end
			local seeded = devSeedMaxPlotOilForPlayer(player)
			print(string.format("[Dev] /maxplot by %s -> unlocked %d chunk(s), seeded %d tile(s)", player.Name, unlockedNow, seeded))
		elseif cmd == "/unlockboats" or cmd == "/unlockallboats" or cmd == "/giveallboats" then
			-- Dev-only: grant every boat in `BoatCatalog` (excluding placeholder
			-- entries — those are filtered server-side by `GrantBoat`) to the
			-- calling player (mirrors what `MonetizationService` does on a
			-- successful Robux receipt for each `ship.*` grant). Use this to
			-- QA each hull's collision / rig under the new
			-- `BoatCollisionContract` without buying every boat. Idempotent —
			-- `OilStateService:GrantBoat` returns `OK_ALREADY_OWNED` for boats
			-- the player already has, so spamming the command is safe.
			-- Re-equip via the in-game Ship Management panel after running.
			local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
			local granted, already = 0, 0
			for boatId, _ in pairs(BoatCatalog.Boats) do
				local ok, code = OilStateService:GrantBoat(player.UserId, boatId)
				if ok then
					granted += 1
				elseif code == "OK_ALREADY_OWNED" then
					already += 1
				else
					warn(string.format("[Dev] /unlockboats GrantBoat(%s) failed: %s", boatId, tostring(code)))
				end
			end
			print(string.format(
				"[Dev] /unlockboats by %s -> granted=%d alreadyOwned=%d (re-equip via Ship Management panel)",
				player.Name, granted, already
			))
		elseif cmd == "/eventlist" or cmd == "/events" then
			-- Dev: list every global event in the catalog with current state
			-- (active, weight, cooldown). Mirrors the pattern other /list-style
			-- commands use; pure read, no side effects.
			local rows = GlobalEventService:DebugListEvents()
			print(string.format("[Dev] /events  (%d in catalog):", #rows))
			for _, r in ipairs(rows) do
				print(string.format(
					"    %s  weight=%d  duration=%ds  cooldown=%ds  active=%s",
					r.id, r.weight, r.durationSeconds, r.cooldownSeconds, tostring(r.active)
				))
			end
		elseif cmd:sub(1, 6) == "/event" then
			-- Dev: activate or end a global event by id, bypassing the
			-- rotation. Usage:
			--   /event <id>              -> activate with default duration
			--   /event <id> <seconds>    -> activate with override duration
			--   /event end <id>          -> force-end an active event
			--   /event endall            -> force-end ALL active events
			-- Examples:
			--   /event cash_frenzy
			--   /event express_convoy 45
			--   /event end cash_frenzy
			-- Same `isAuthorizedDev` gate as the rest of `onDebugChat` — safe
			-- in live builds because randoms can't trigger it.
			local args = cmd:sub(7):gsub("^%s+", "")
			if args == "" then
				warn("[Dev] /event usage: /event <id> [seconds] | /event end <id> | /event endall")
			elseif args == "endall" then
				local rows = GlobalEventService:DebugListEvents()
				local n = 0
				for _, r in ipairs(rows) do
					if r.active and GlobalEventService:ForceEnd(r.id) then
						n += 1
					end
				end
				print(string.format("[Dev] /event endall by %s -> ended %d", player.Name, n))
			else
				local endTarget = args:match("^end%s+(%S+)")
				if endTarget then
					local ok = GlobalEventService:ForceEnd(endTarget)
					print(string.format("[Dev] /event end %s by %s -> %s", endTarget, player.Name, tostring(ok)))
				else
					local id, secStr = args:match("^(%S+)%s*(%S*)")
					id = id or ""
					local secs = tonumber(secStr)
					local ok, code = GlobalEventService:DebugActivate(id, secs)
					print(string.format(
						"[Dev] /event %s%s by %s -> ok=%s code=%s",
						id, secs and (" " .. tostring(secs)) or "",
						player.Name, tostring(ok), tostring(code)
					))
				end
			end
		elseif cmd == "/straitopen" or cmd == "/straitclose" then
			-- Mirrors the `MonetizationService` consumable handlers for the
			-- Robux strait force-open / force-close products without going
			-- through `MarketplaceService`. Same `ForceStateForDuration`
			-- conflict policy applies — second invocation in the same 120s
			-- window is rejected (returns false) so QA can validate the
			-- refund branch by chaining two commands quickly.
			local state = if cmd == "/straitopen" then "Open" else "Closed"
			local ok = StraitStateService:ForceStateForDuration(state, 120, player)
			print(string.format("[Dev] /strait%s by %s -> applied=%s", string.lower(state), player.Name, tostring(ok)))
		elseif cmd == "/grant500" then
			grantAllPlayersCash(500)
		elseif cmd:sub(1, 9) == "/givecash" then
			-- Targets a specific online player by username (case-insensitive
			-- exact match, falling back to a prefix match so `/givecash sen
			-- 1000` works without typing the full handle). Live-build safe:
			-- the `isAuthorizedDev(player)` gate at the top of `onDebugChat`
			-- already restricts every chat command to Studio OR the place
			-- owner's `UserId == game.CreatorId` in production, so randoms
			-- cannot fan cash to themselves or alts.
			--
			-- Usage: `/givecash <username> <amount>`
			-- Behavior:
			--   * Amount must be a positive integer; `OilStateService:AddCash`
			--     uses `floorPositive` and silently no-ops on `<= 0` (we
			--     reject up front so the operator gets feedback instead of a
			--     phantom success line).
			--   * Passes `skipMultiplier = true` so the dev grants exactly
			--     the requested amount even if the target owns the
			--     `DoubleEarnings` gamepass. Mirrors how Robux-purchased
			--     cash bundles in `MonetizationService` skip the multiplier:
			--     "topping up by N" should mean "wallet goes up by N".
			--   * `:PushState` so the open HUD refreshes its cash label
			--     without waiting for the next periodic push.
			local args = cmd:sub(10):gsub("^%s+", "")
			local nameArg, amountArg = args:match("^(%S+)%s+(%-?%d+)%s*$")
			if not nameArg or not amountArg then
				warn(string.format(
					"[Dev] /givecash by %s: bad usage, expected '/givecash <username> <amount>'",
					player.Name
				))
				return
			end
			local amount = tonumber(amountArg)
			if not amount or amount <= 0 then
				warn(string.format(
					"[Dev] /givecash by %s: amount must be a positive integer (got '%s')",
					player.Name, tostring(amountArg)
				))
				return
			end
			local nameLower = nameArg:lower()
			local target: Player? = nil
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name:lower() == nameLower then
					target = p
					break
				end
			end
			if not target then
				for _, p in ipairs(Players:GetPlayers()) do
					if p.Name:lower():sub(1, #nameLower) == nameLower then
						target = p
						break
					end
				end
			end
			if not target then
				warn(string.format(
					"[Dev] /givecash by %s: no online player matches '%s'",
					player.Name, nameArg
				))
				return
			end
			local ok, granted = OilStateService:AddCash(target.UserId, amount, { skipMultiplier = true })
			if ok then
				OilStateService:PushState(target.UserId)
				print(string.format(
					"[Dev] /givecash by %s -> %s +$%d (granted=%d)",
					player.Name, target.Name, amount, granted
				))
			else
				warn(string.format(
					"[Dev] /givecash by %s: AddCash failed for %s (no oil state loaded?)",
					player.Name, target.Name
				))
			end
		elseif cmd == "/security" or cmd:sub(1, 10) == "/security " then
			-- Dev-only: grant N stacks of the Security Personnel run-upgrade
			-- to the calling player without going through Robux. Mirrors the
			-- consumable handler `SecurityPersonnelService:SetMonetizationService`
			-- registers, so the same downstream flow runs (state write +
			-- `PushState`) and the open `ShipOilPanelGui` repaints its
			-- description to "Security Personnel active on next run". Use to
			-- QA the on-deck guard mount + `eventImmunity` short-circuit
			-- without spending Robux while the DevProduct id is still 0.
			-- Usage: `/security`     -> +1 stack
			--        `/security 3`   -> +3 stacks (test stacking copy)
			local arg = cmd:sub(11):gsub("^%s+", "")
			local n = tonumber(arg) or 1
			n = math.clamp(math.floor(n), 1, 99)
			-- Use the OilStateService API directly rather than going through
			-- `SecurityPersonnelService:SetMonetizationService`'s handler —
			-- the handler is keyed off a Roblox receipt, not a chat command.
			-- The consume path on dispatch (`TryConsumeForDispatch`) reads
			-- the same `runUpgradeOwnedByItemId` slot so the grant is fully
			-- equivalent to a Robux purchase from the player's perspective.
			OilStateService:AddRunUpgradeOwned(player.UserId, "security_personnel", n)
			OilStateService:PushState(player.UserId)
			local owned = OilStateService:GetRunUpgradeOwned(player.UserId, "security_personnel") or 0
			print(string.format("[Dev] /security %d -> %s now owns %d stack(s)", n, player.Name, owned))
		elseif cmd == "/wipedata" or cmd == "/dev_wipeme" then
			devWipePersistedForUser(player.UserId)
			player:Kick("[Dev] Persisted data wiped — rejoin for a fresh profile.")
		-- /wipealldata and /dev_wipeall REMOVED — too dangerous, could wipe all players.
		elseif cmd:sub(1, 10) == "/givedrill" then
			-- Usage: /givedrill <username> <tier> <count>
			-- e.g. /givedrill sen t3 5
			local args = cmd:sub(11):gsub("^%s+", "")
			local nameArg, tierArg, countArg = args:match("^(%S+)%s+(%S+)%s*(%d*)")
			if not nameArg or not tierArg then
				warn("[Dev] /givedrill usage: /givedrill <username> <tier> <count>")
				return
			end
			local tier = tierArg:lower()
			local count = tonumber(countArg) or 1
			local itemId = "drill_" .. tier
			local nameLower = nameArg:lower()
			local target: Player? = nil
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name:lower() == nameLower then target = p; break end
			end
			if not target then
				for _, p in ipairs(Players:GetPlayers()) do
					if p.Name:lower():sub(1, #nameLower) == nameLower then target = p; break end
				end
			end
			if not target then
				warn(string.format("[Dev] /givedrill: no online player matches '%s'", nameArg))
				return
			end
			EquipmentShopService:GrantFreeOwnedEquipment(target, itemId, count)
			print(string.format("[Dev] /givedrill by %s -> gave %s x%d %s drills", player.Name, target.Name, count, tier:upper()))
		elseif cmd:sub(1, 9) == "/giveboat" then
			-- Usage: /giveboat <username> <boatId>
			-- e.g. /giveboat sen PirateShip
			local args = cmd:sub(10):gsub("^%s+", "")
			local nameArg, boatIdArg = args:match("^(%S+)%s+(%S+)")
			if not nameArg or not boatIdArg then
				warn("[Dev] /giveboat usage: /giveboat <username> <boatId>")
				return
			end
			local nameLower = nameArg:lower()
			local target: Player? = nil
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name:lower() == nameLower then target = p; break end
			end
			if not target then
				for _, p in ipairs(Players:GetPlayers()) do
					if p.Name:lower():sub(1, #nameLower) == nameLower then target = p; break end
				end
			end
			if not target then
				warn(string.format("[Dev] /giveboat: no online player matches '%s'", nameArg))
				return
			end
			local ok, code = OilStateService:GrantBoat(target.UserId, boatIdArg)
			if ok then
				OilStateService:PushState(target.UserId)
				print(string.format("[Dev] /giveboat by %s -> granted %s boat '%s'", player.Name, target.Name, boatIdArg))
			else
				warn(string.format("[Dev] /giveboat by %s -> failed for %s boat '%s': %s", player.Name, target.Name, boatIdArg, tostring(code)))
			end
		elseif matchesCommandPrefix(cmd, "/giverebirthdrill") or matchesCommandPrefix(cmd, "/rebirthdrill") then
			--- Optional count: `/giverebirthdrill 5` adds 5 drills (defaults to 1).
			--- The dev command also unlocks Oil Heaven if needed (since carrying a
			--- drill without heaven access would be a softlock for QA).
			local prefix = if matchesCommandPrefix(cmd, "/giverebirthdrill") then "/giverebirthdrill" else "/rebirthdrill"
			local arg = cmd:sub(#prefix + 1):gsub("^%s+", "")
			local count = tonumber(arg) or 1
			local rebirthCount, drillCount = devGiveRebirthDrill(player, count)
			print(string.format("[Dev] Rebirth Drill +%d for %s -> rebirthCount=%d drills=%d", count, player.Name, rebirthCount, drillCount))
		elseif matchesCommandPrefix(cmd, "/rebirth") then
			local arg = cmd:sub(9):gsub("^%s+", "")
			local count = tonumber(arg) or 1
			local newCount = devGrantRebirths(player, count)
			print(string.format("[Dev] /rebirth by %s -> rebirthCount=%d", player.Name, newCount))
		elseif matchesCommandPrefix(cmd, "/giverebirth") then
			local arg = cmd:sub(13):gsub("^%s+", "")
			local count = tonumber(arg) or 1
			local newCount = devGrantRebirths(player, count)
			print(string.format("[Dev] /giverebirth by %s -> rebirthCount=%d", player.Name, newCount))
		elseif cmd == "/rebirthnow" then
			--- Forces the rebirth flow for the calling player, bypassing the
			--- panel UX (handy for QA without grinding to $1M cash). Mirrors
			--- exactly what `RebirthShopService:_handleRebirth` does so any
			--- bug in the rebirth path also reproduces here.
			local ok, code, data = OilStateService:Rebirth(player.UserId)
			if not ok then
				warn(string.format("[Dev] /rebirthnow %s -> %s", player.Name, code))
			else
				pcall(function() WarehouseService:ResetForRebirth(player.UserId) end)
				pcall(function() DrillingService:CancelDrillsForUser(player.UserId) end)
				pcall(function() EquipmentShopService:ReconcileForUser(player) end)
				pcall(function() OilShipmentService:CancelShipmentsForUser(player.UserId) end)
				pcall(function() OilHeavenPlotService:RefreshUnlocks(player.UserId) end)
				pcall(function() OilStateService:PushState(player.UserId) end)
				print(string.format(
					"[Dev] /rebirthnow %s -> rebirthCount=%d tokens=%d (+%d) drills=%d",
					player.Name,
					data.rebirthCount, data.rebirthTokens, data.tokensGranted, data.rebirthDrills
				))
			end
		elseif cmd:sub(1, 17) == "/giverebirthtokens" or cmd:sub(1, 7) == "/tokens" then
			--- `/giverebirthtokens N` (alias `/tokens N`) — bumps the wallet that
			--- the rebirth shop spends. Used for QA without needing to wire up
			--- the rebirth flow that converts cash → tokens.
			local prefixLen = if cmd:sub(1, 17) == "/giverebirthtokens" then 18 else 8
			local arg = cmd:sub(prefixLen):gsub("^%s+", "")
			local amount = tonumber(arg) or 10
			amount = math.max(1, math.floor(amount))
			local newTokens = OilStateService:AddRebirthTokens(player.UserId, amount)
			OilStateService:PushState(player.UserId)
			print(string.format("[Dev] Rebirth tokens +%d for %s -> total=%d", amount, player.Name, newTokens))
		elseif cmd == "/unlockoilheaven" or cmd == "/oh" then
			OilStateService:UnlockOilHeaven(player.UserId)
			OilHeavenPlotService:RefreshUnlocks(player.UserId)
			OilStateService:PushState(player.UserId)
			print(string.format("[Dev] Oil Heaven unlocked for %s", player.Name))
		elseif cmd == "/hideui" then
			-- Toggle all client-side UI for marketing footage capture.
			local ev = RemoteService:GetEvent(RemoteNames.DevHideUI)
			ev:FireClient(player)
			print(string.format("[Dev] /hideui toggled for %s", player.Name))
		elseif cmd == "/autoship" or cmd == "/autoship most" or cmd == "/autoship least" then
			-- Dev-only: enable AutoShip bypassing GamePass ownership check.
			-- Usage: /autoship most  (Most Valuable priority)
			--        /autoship least (Least Valuable priority)
			--        /autoship       (toggles off if active, or defaults to MostValuable)
			local entry = AutoShipService._autoShipByUser[player.UserId]
			if entry and entry.enabled and cmd == "/autoship" then
				-- Toggle off
				AutoShipService._autoShipByUser[player.UserId] = nil
				AutoShipService._devBypassUsers[player.UserId] = nil
				AutoShipService:_pushState(player.UserId)
				print(string.format("[Dev] AutoShip disabled for %s", player.Name))
			else
				local priority = "MostValuable"
				if cmd == "/autoship least" then priority = "LeastValuable" end
				AutoShipService._devBypassUsers[player.UserId] = true
				AutoShipService._autoShipByUser[player.UserId] = { enabled = true, priority = priority }
				AutoShipService:_pushState(player.UserId)
				print(string.format("[Dev] AutoShip enabled for %s (priority=%s, devBypass=true)", player.Name, priority))
				if BoatDockService:IsIdle(player.UserId) then
					task.defer(function()
						AutoShipService:_tryAutoDispatch(player.UserId)
					end)
				end
			end
		else
			local grantN = string.match(cmd, "^/giveall%s+(%d+)$")
			if grantN then
				local n = tonumber(grantN)
				if n and n > 0 then
					grantAllPlayersCash(n)
				end
			end
		end
	end

	-- Legacy chat (`Player.Chatted`) works in Studio's classic chat only.
	-- The Roblox app defaults to TextChatService, which does NOT route through
	-- Player.Chatted. Register TextChatCommand instances so slash commands work
	-- in the app too.
	local function hookPlayerChatted(player: Player)
		player.Chatted:Connect(function(message)
			onDebugChat(player, message)
		end)
	end
	Players.PlayerAdded:Connect(hookPlayerChatted)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayerChatted(p)
	end

	local TextChatService = game:GetService("TextChatService")
	local DEV_COMMAND_ALIASES = {
		"/missile", "/mine", "/pirate", "/storm", "/tornado", "/coastguard", "/slap", "/nuke", "/airstrike",
		"/fighterwave", "/fighters", "/fighterhere", "/jethere",
		"/fighterretarget", "/jetretarget",
		"/grant500", "/givecash", "/wipedata", "/dev_wipeme",
		"/giveall", "/testvein", "/givedrills", "/givedrill", "/giveboat",
		"/straitopen", "/straitclose",
		"/unlockplot", "/unlockallchunks", "/maxplot", "/fillplot",
		"/unlockboats", "/unlockallboats", "/giveallboats",
		"/hideui",
		"/autoship",
		"/security",
		"/rebirth", "/giverebirth", "/giverebirthdrill", "/rebirthdrill",
		"/giverebirthtokens", "/tokens",
		"/rebirthnow",
		"/event", "/eventlist", "/events",
		"/unlockoilheaven", "/oh",
	}
	for _, alias in ipairs(DEV_COMMAND_ALIASES) do
		local ok, err = pcall(function()
			local cmd = Instance.new("TextChatCommand")
			cmd.Name = "DevCmd_" .. string.sub(alias, 2)
			cmd.PrimaryAlias = alias
			cmd.AutocompleteVisible = true
			cmd.Triggered:Connect(function(textSource, unfilteredText)
				local p = Players:GetPlayerByUserId(textSource.UserId)
				if p then
					onDebugChat(p, unfilteredText)
				end
			end)
			cmd.Parent = TextChatService
		end)
		if not ok then
			warn("[Dev] TextChatCommand register failed for " .. alias .. ": " .. tostring(err))
		end
	end
end
