--!strict
-- Strait status + oil market HUD replication: warehouse snapshot, `globalStateUpdate`, `marketPriceUpdate`,
-- initial market snapshot. Wired from `init.client` with injected `getHudUiFolder` + `playEventSFX`.

export type StraitMarketHudDeps = {
	player: Player,
	playerGui: PlayerGui,
	getHudUiFolder: () -> Instance?,
	playEventSFX: (sfxName: string, volume: number?) -> (),
}

export type StraitMarketRemotes = {
	warehouseStateUpdate: RemoteEvent,
	requestWarehouseSnapshot: RemoteFunction,
	globalStateUpdate: RemoteEvent,
	marketPriceUpdate: RemoteEvent,
	requestMarketSnapshot: RemoteFunction,
}

local MARKET_TYPE_MULS = { Crude = 0.8, Refined = 1.4, Premium = 2.0 }

local warehouseState: any = nil

local marketState = {
	basePrice = 10,
	prices = {} :: { [string]: number },
	trend = "stable",
	straitState = "Open",
	nextChangeAt = 0,
	globalBaseMin = 8,
	globalBaseMax = 80,
	typeMultipliers = MARKET_TYPE_MULS,
}

local straitStatusHudModule: { refresh: (PlayerGui, string) -> () }? = nil
local straitStatusChangeFxModule: { trigger: (PlayerGui, string) -> () }? = nil
local oilPriceHudModule: { refresh: (PlayerGui, any) -> () }? = nil

local function getStraitStatusHud(deps: StraitMarketHudDeps): { refresh: (PlayerGui, string) -> () }?
	if straitStatusHudModule then
		return straitStatusHudModule
	end
	local ui = deps.getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("StraitStatusHud")
	if m and m:IsA("ModuleScript") then
		straitStatusHudModule = require(m) :: { refresh: (PlayerGui, string) -> () }
	end
	return straitStatusHudModule
end

local function getStraitStatusChangeFx(deps: StraitMarketHudDeps): { trigger: (PlayerGui, string) -> () }?
	if straitStatusChangeFxModule then
		return straitStatusChangeFxModule
	end
	local ui = deps.getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("StraitStatusChangeFx")
	if m and m:IsA("ModuleScript") then
		straitStatusChangeFxModule = require(m) :: { trigger: (PlayerGui, string) -> () }
	end
	return straitStatusChangeFxModule
end

local function getOilPriceHud(deps: StraitMarketHudDeps): { refresh: (PlayerGui, any) -> () }?
	if oilPriceHudModule then
		return oilPriceHudModule
	end
	local ui = deps.getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("OilPriceHud")
	if m and m:IsA("ModuleScript") then
		oilPriceHudModule = require(m) :: { refresh: (PlayerGui, any) -> () }
	end
	return oilPriceHudModule
end

local function updateWarehouseUi()
	_ = warehouseState
end

local function updateMarketUi(deps: StraitMarketHudDeps)
	local h = getStraitStatusHud(deps)
	if h then
		h.refresh(deps.playerGui, tostring(marketState.straitState or "Open"))
	end
	local op = getOilPriceHud(deps)
	if op then
		op.refresh(deps.playerGui, marketState)
	end
	_ = warehouseState
end

local StraitMarketHudClient = {}

function StraitMarketHudClient.connect(deps: StraitMarketHudDeps, remotes: StraitMarketRemotes)
	local playEventSFX = deps.playEventSFX

	remotes.warehouseStateUpdate.OnClientEvent:Connect(function(data)
		warehouseState = data
		updateWarehouseUi()
		updateMarketUi(deps)
	end)

	task.defer(function()
		local ok, data = pcall(function()
			return remotes.requestWarehouseSnapshot:InvokeServer()
		end)
		if ok and typeof(data) == "table" and typeof(data.barrels) == "table" then
			warehouseState = data
			updateWarehouseUi()
			updateMarketUi(deps)
		end
	end)

	remotes.globalStateUpdate.OnClientEvent:Connect(function(snapshot)
		if typeof(snapshot) ~= "table" then
			return
		end
		if typeof(snapshot.state) == "string" then
			local prev = marketState.straitState
			marketState.straitState = snapshot.state
			updateMarketUi(deps)
			if prev and prev ~= snapshot.state then
				local fx = getStraitStatusChangeFx(deps)
				if fx then
					fx.trigger(deps.playerGui, snapshot.state)
				end
				print("[StraitSFX] State changed: " .. tostring(prev) .. " -> " .. tostring(snapshot.state))
				local newState = snapshot.state
				if newState == "Closed" then
					playEventSFX("StraitClosed")
				elseif newState == "Open" then
					playEventSFX("StraitOpen")
				else
					playEventSFX("StraitRestricted")
				end
			end
		end
	end)

	remotes.marketPriceUpdate.OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		marketState.basePrice = data.basePrice or marketState.basePrice
		marketState.prices = data.prices or marketState.prices
		marketState.trend = data.trend or marketState.trend
		marketState.straitState = data.straitState or marketState.straitState
		marketState.nextChangeAt = data.nextChangeAt or marketState.nextChangeAt
		marketState.globalBaseMin = data.globalBaseMin or marketState.globalBaseMin
		marketState.globalBaseMax = data.globalBaseMax or marketState.globalBaseMax
		if data.typeMultipliers then
			marketState.typeMultipliers = data.typeMultipliers
		end
		updateMarketUi(deps)
	end)

	task.spawn(function()
		local snapshot = remotes.requestMarketSnapshot:InvokeServer()
		if typeof(snapshot) == "table" then
			marketState.basePrice = snapshot.basePrice or 10
			marketState.prices = snapshot.prices or {}
			marketState.trend = snapshot.trend or "stable"
			marketState.straitState = snapshot.straitState or "Open"
			marketState.nextChangeAt = snapshot.nextChangeAt or 0
			marketState.globalBaseMin = snapshot.globalBaseMin or 8
			marketState.globalBaseMax = snapshot.globalBaseMax or 80
			if snapshot.typeMultipliers then
				marketState.typeMultipliers = snapshot.typeMultipliers
			end
			updateMarketUi(deps)
		end
	end)

	task.defer(function()
		task.wait(0.5)
		updateMarketUi(deps)
	end)
end

return StraitMarketHudClient
