--!strict
-- Oilman NPC (`Workspace.Oilman.RodgerDodger`) — walk up + E/click to open
-- a dialogue modal, sell local `oilByTier` barrels at cheap OilmanConfig
-- prices. Atomic batch commit; mirrors the warehouse-sell plumbing but
-- targets plot tanks instead of warehouse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilmanConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilmanConfig"))
local ErrorCodes = require(Shared:WaitForChild("Net"):WaitForChild("ErrorCodes"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local OilmanService = {}

local REQUEST_ID_TTL_SECONDS = 2.0

local function floorPositive(n: number): number
	return math.max(0, math.floor(n))
end

function OilmanService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._running = false
	self._connections = {}
	self._prompt = nil :: ProximityPrompt?
	-- Per-userId idempotency cache for `RequestOilmanSell` (same shape as
	-- EquipmentShopService's guard).
	self._recentRequestIds = {} :: { [number]: { [string]: number } }
end

local function isDuplicateRequestId(self, userId: number, requestId: string): boolean
	local now = os.clock()
	local byUser = self._recentRequestIds[userId]
	if not byUser then
		byUser = {}
		self._recentRequestIds[userId] = byUser
	end
	for id, expires in pairs(byUser) do
		if expires <= now then
			byUser[id] = nil
		end
	end
	if byUser[requestId] then
		return true
	end
	byUser[requestId] = now + REQUEST_ID_TTL_SECONDS
	return false
end

--- Find a sensible anchor part on the Oilman rig to parent the prompt to.
--- Order: HumanoidRootPart (preferred — NPC's root) → Head → Torso → any BasePart.
local function findPromptHost(oilmanFolder: Instance): BasePart?
	local npc = oilmanFolder:FindFirstChild("RodgerDodger")
	if not npc then
		return nil
	end
	local candidates = { "HumanoidRootPart", "Head", "Torso" }
	for _, name in ipairs(candidates) do
		local part = npc:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return npc:FindFirstChildWhichIsA("BasePart", true)
end

function OilmanService:_attachPrompt()
	local oilmanFolder = Workspace:FindFirstChild("Oilman")
	if not oilmanFolder then
		warn("[OilmanService] Workspace.Oilman folder missing; prompt disabled.")
		return
	end

	local host = findPromptHost(oilmanFolder)
	if not host then
		warn("[OilmanService] Could not locate RodgerDodger root/Head/Torso; prompt disabled.")
		return
	end

	-- Clean up any stale prompt from a previous run/hot-reload.
	local existing = host:FindFirstChild("OilmanDialoguePrompt")
	if existing then
		existing:Destroy()
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OilmanDialoguePrompt"
	prompt.ActionText = OilmanConfig.Prompt.ActionText
	prompt.ObjectText = OilmanConfig.Prompt.ObjectText
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.ClickablePrompt = true
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = OilmanConfig.Prompt.MaxActivationDistance
	prompt.HoldDuration = 0
	prompt.Parent = host

	self._prompt = prompt

	-- Server-side trigger is purely diagnostic — the client bootstrap opens
	-- the modal locally for zero-latency UX.
	table.insert(self._connections, prompt.Triggered:Connect(function(player)
		DevLog.log(string.format("[Oilman] prompt triggered by %s", player.Name))
	end))

	DevLog.log(string.format("[Oilman] prompt attached to %s", host:GetFullName()))
end

function OilmanService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data: any?)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function OilmanService:_handleSell(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.InvalidPayload, "Missing payload.")
		return
	end

	-- Idempotency: silently drop duplicate same-requestId retries.
	if typeof(payload.requestId) == "string" and payload.requestId ~= "" then
		if isDuplicateRequestId(self, player.UserId, payload.requestId) then
			return
		end
	end

	local quantities = payload.quantities
	if typeof(quantities) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.InvalidPayload, "Missing quantities.")
		return
	end

	local state = self._oilStateService:GetState(player.UserId)
	if not state or typeof(state.oilByTier) ~= "table" then
		self:_sendActionResult(player, false, ErrorCodes.Unknown, "Your state isn't ready yet.")
		return
	end

	-- Clamp each tier's request to available stock, compute per-tier payout.
	local consumeManifest = {} :: { [string]: number }
	local lines = {}
	local totalBarrels = 0
	local totalPayout = 0
	for _, tier in ipairs(OilmanConfig.TierOrder) do
		local requested = floorPositive(tonumber(quantities[tier]) or 0)
		local have = floorPositive(tonumber(state.oilByTier[tier]) or 0)
		local take = math.min(requested, have)
		if take > 0 then
			local pricePer = OilmanConfig.pricePerBarrel(tier)
			local payout = take * pricePer
			consumeManifest[tier] = take
			totalBarrels += take
			totalPayout += payout
			table.insert(lines, {
				tier = tier,
				quantity = take,
				pricePerBarrel = pricePer,
				payout = payout,
			})
		end
	end

	if totalBarrels <= 0 then
		self:_sendActionResult(player, false, ErrorCodes.NoOil, "Nothing to sell.")
		return
	end

	-- Atomic commit via existing consume + add-cash plumbing.
	local consumed = self._oilStateService:ConsumeManifest(player.UserId, consumeManifest)
	if not consumed then
		self:_sendActionResult(player, false, ErrorCodes.Unknown, "Sell failed — please retry.")
		return
	end
	self._oilStateService:AddCash(player.UserId, totalPayout)
	self._oilStateService:PushState(player.UserId)

	DevLog.log(string.format(
		"[Oilman] %s sold %d barrels for $%d",
		player.Name,
		totalBarrels,
		totalPayout
	))

	self:_sendActionResult(player, true, ErrorCodes.Ok,
		string.format("Sold %d barrels for $%d.", totalBarrels, totalPayout),
		{ lines = lines, totalBarrels = totalBarrels, totalPayout = totalPayout })
end

function OilmanService:Start()
	if self._running then
		return
	end
	self._running = true

	self:_attachPrompt()

	local sellEvent = self._remoteService:GetEvent(RemoteNames.RequestOilmanSell)
	table.insert(self._connections, sellEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleSell(player, payload)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		self._recentRequestIds[player.UserId] = nil
	end))
end

function OilmanService:Stop()
	self._running = false
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
	if self._prompt and self._prompt.Parent then
		self._prompt:Destroy()
	end
	self._prompt = nil
end

return OilmanService
