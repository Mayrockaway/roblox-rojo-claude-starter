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

local TelemetryService = require(serviceFolder:WaitForChild("TelemetryService"))
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
local PipeNetworkService = require(serviceFolder:WaitForChild("PipeNetworkService"))
local WarehouseService = require(serviceFolder:WaitForChild("WarehouseService"))
local OilMarketService = require(serviceFolder:WaitForChild("OilMarketService"))
local EquipmentShopService = require(serviceFolder:WaitForChild("EquipmentShopService"))
local OilmanService = require(serviceFolder:WaitForChild("OilmanService"))
local InstantSellService = require(serviceFolder:WaitForChild("InstantSellService"))
local DrillingService = require(serviceFolder:WaitForChild("DrillingService"))
local FtueService = require(serviceFolder:WaitForChild("FtueService"))
local ProspectingService = require(serviceFolder:WaitForChild("ProspectingService"))
local OilTankService = require(serviceFolder:WaitForChild("OilTankService"))
local FighterPlaneWaveService = require(serviceFolder:WaitForChild("FighterPlaneWaveService"))
local HitContractService = require(serviceFolder:WaitForChild("HitContractService"))
local ArmyGeneralService = require(serviceFolder:WaitForChild("ArmyGeneralService"))
local KillZoneService = require(serviceFolder:WaitForChild("KillZoneService"))

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
	local legacyPipe = sfx and sfx:FindFirstChild("Pipe")
	if legacyPipe and legacyPipe:IsA("Sound") then
		legacyPipe.Playing = false
		legacyPipe:Stop()
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
DevLog.SetBroadcaster(function(msg)
	local ev = RemoteService:GetEvent(RemoteNames.DevLog)
	ev:FireAllClients(msg)
end)
TelemetryService:Init()
StraitStateService:Init(RemoteService, TelemetryService)
PlotService:Init()
OilStateService:Init(RemoteService, PlotService)
OilVisualService:Init(OilStateService, PlotService)
BoatDockService:Init(RemoteService, OilStateService)
OilShipmentService:Init(RemoteService, OilStateService, PlotService, WarehouseService, StraitStateService, BoatDockService)
HitContractService:Init(RemoteService, OilStateService, OilShipmentService)
ArmyGeneralService:Init(RemoteService, OilStateService, OilShipmentService)
OilShipmentService:SetHitContractService(HitContractService)
ChunkOwnershipService:Init(PlotService, OilStateService)
PipeNetworkService:Init()
WarehouseService:Init(RemoteService, OilStateService)
OilMarketService:Init(RemoteService, StraitStateService, WarehouseService, OilStateService)
EquipmentShopService:Init(RemoteService, OilStateService, PlotService)
OilmanService:Init(RemoteService, OilStateService)
InstantSellService:Init(RemoteService, OilStateService)
PlotResourceService:Init(RemoteService, OilStateService, PlotService, OilVisualService, OilShipmentService, ChunkOwnershipService)
OilProductionService:Init(OilStateService, PipeNetworkService)
DrillingService:Init(RemoteService, OilStateService)
FtueService:Init(RemoteService, PlotService, OilStateService, EquipmentShopService, DrillingService, OilShipmentService, OilMarketService)
OilStateService:SetFtueService(FtueService)
OilStateService:SetPipeNetworkService(PipeNetworkService)
OilShipmentService:SetFtueService(FtueService)
OilMarketService:SetFtueService(FtueService)
ProspectingService:Init(RemoteService, OilStateService)
OilStateService:SetStateReadyForTimersCallback(function(userId: number, drillDone: { any }, prospectDone: { any })
	DrillingService:ReplayCompletedDrills(userId, drillDone)
	ProspectingService:ReplayCompletedProspects(userId, prospectDone)
	if #drillDone > 0 or #prospectDone > 0 then
		OilStateService:PushState(userId)
	end
	DrillingService:ResumePendingDrillDelays(userId)
	DrillingService:ReplayUnrevealedTiles(userId)
	ProspectingService:ResumePendingProspects(userId)
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
ChunkOwnershipService:Start()
PipeNetworkService:Start()
WarehouseService:Start()
OilMarketService:Start()
EquipmentShopService:Start()
OilmanService:Start()
InstantSellService:Start()
PlotResourceService:Start()
OilProductionService:Start()
DrillingService:Start()
FtueService:Start()
ProspectingService:Start()
OilTankService:Start()
ToolService:Start()
FighterPlaneWaveService:Start()

game:BindToClose(function()
	KillZoneService:Stop()
	PerfService:Stop()
	ToolService:Stop()
	OilTankService:Stop()
	ProspectingService:Stop()
	FighterPlaneWaveService:Stop()
	DrillingService:Stop()
	FtueService:Stop()
	OilProductionService:Stop()
	PlotResourceService:Stop()
	PipeNetworkService:Stop()
	OilMarketService:Stop()
	EquipmentShopService:Stop()
	OilmanService:Stop()
	WarehouseService:Stop()
	ChunkOwnershipService:Stop()
	OilShipmentService:Stop()
	ArmyGeneralService:Stop()
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

	local function devWipePersistedForUser(userId: number)
		OilStateService:MarkDevSkipSaveOnNextDrop(userId)
		WarehouseService:MarkDevSkipSaveOnNextDrop(userId)
		OilStateService:DevRemovePersistedOilProfile(userId)
		WarehouseService:DevRemovePersistedWarehouseProfile(userId)
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
		elseif cmd == "/grant500" then
			grantAllPlayersCash(500)
		elseif cmd == "/wipedata" or cmd == "/dev_wipeme" then
			devWipePersistedForUser(player.UserId)
			player:Kick("[Dev] Persisted data wiped — rejoin for a fresh profile.")
		elseif cmd == "/wipealldata" or cmd == "/dev_wipeall" then
			for _, p in ipairs(Players:GetPlayers()) do
				devWipePersistedForUser(p.UserId)
				p:Kick("[Dev] Persisted data wiped — rejoin for a fresh profile.")
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
		"/grant500", "/wipedata", "/dev_wipeme", "/wipealldata", "/dev_wipeall",
		"/giveall", "/testvein", "/givedrills",
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

print("[Server] Oil mining mode active: chunked plot + free-placed drills")
