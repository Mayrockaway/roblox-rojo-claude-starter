--!strict
-- Docks strait leaderboard: **author the UI in Studio** anywhere under `Workspace`. The board is
-- looked up by SurfaceGui name (`StraitLeaderboardGui`) on a `BasePart` parent — it does NOT have
-- to live at `Workspace.DocksLeaderboard.Board` anymore. Putting it under `Workspace.Map.…` is fine.
-- This service only **binds** to TextLabels and updates text / row tint. Alternates every 15s
-- between **this server session** and **global** OrderedDataStore ranks (crossings + barrels delivered).
--
-- Required hierarchy (names matter — these are looked up by exact name):
--   <any BasePart anywhere under Workspace, conventionally Map.DocksLeaderboard.Board>
--     StraitLeaderboardGui (SurfaceGui) — Face = Front, PixelsPerStud as you like
--                                         Adornee is auto-set to the parent part on bind
--       Root (Frame) — full size, transparent or styled in Studio
--         Mode (TextLabel) — server sets "THIS SERVER · SESSION" / "GLOBAL · ALL SERVERS"
--         Timer (TextLabel) — server sets countdown to next view switch
--         CrossingsCol (Frame)
--           Row_1 … Row_8 (TextLabel) — one line per rank (server fills text + highlight)
--         BarrelsCol (Frame)
--           Row_1 … Row_8 (TextLabel)
--
-- Rojo: `Workspace.DocksLeaderboard` is an empty Folder with `$ignoreUnknownInstances` retained for
-- legacy authoring; the new bind by SurfaceGui name lets the user move the board freely without
-- changing the project file.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DataStoreWriteGate = require(script.Parent.Parent.Utils.DataStoreWriteGate)

local ODS_CROSSINGS = "OTS_StraitCrossings_v1"
local ODS_BARRELS = "OTS_StraitBarrelsShipped_v1"

local ROTATE_SECONDS = 15
local ROWS = 8
local TOP_HIGHLIGHT = 3

local GUI_NAME = "StraitLeaderboardGui"
local ROOT_NAME = "Root"

local LeaderboardService = {}

function LeaderboardService:Init()
	self._stop = false
	self._sessionCrossings = {} :: { [number]: number }
	self._sessionBarrels = {} :: { [number]: number }
	self._odsCrossings = nil :: OrderedDataStore?
	self._odsBarrels = nil :: OrderedDataStore?
	self._bound = false
	self._modeLabel = nil :: TextLabel?
	self._timerLabel = nil :: TextLabel?
	self._leftRows = {} :: { TextLabel }
	self._rightRows = {} :: { TextLabel }
	self._nextRotateAt = 0
	self._modeIsGlobal = false
	self._nameCache = {} :: { [number]: string }
	self._globalCrossCache = nil :: { { userId: number, score: number } }?
	self._globalBarrelCache = nil :: { { userId: number, score: number } }?
end

local function openOds(name: string): OrderedDataStore?
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok and store then
		return store
	end
	return nil
end

function LeaderboardService:_tryBindBoard(): boolean
	table.clear(self._leftRows)
	table.clear(self._rightRows)
	self._modeLabel = nil
	self._timerLabel = nil

	-- Find the leaderboard SurfaceGui anywhere under Workspace by its
	-- (unique) name. The header originally promised `Workspace.DocksLeaderboard.Board`
	-- as a top-level folder, but in practice the user moves the board into
	-- `Workspace.Map.DocksLeaderboard.Board` (and other future map slices)
	-- and a top-level `FindFirstChild` returned the empty Rojo placeholder
	-- folder instead. Searching by `StraitLeaderboardGui` SurfaceGui name
	-- works regardless of where the board ends up parented as long as it's
	-- a descendant of `Workspace`. We pick the first valid SurfaceGui whose
	-- parent is a `BasePart` (i.e. an actual sign/board) to avoid binding
	-- to a stale prefab in a Folder.
	local sg: SurfaceGui? = nil
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("SurfaceGui") and d.Name == GUI_NAME then
			local p = d.Parent
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				sg = d
				break
			end
		end
	end
	if not sg then
		return false
	end
	local board = sg.Parent :: BasePart
	if sg.Adornee == nil then
		sg.Adornee = board
	end

	local root = sg:FindFirstChild(ROOT_NAME)
	if not root or not root:IsA("GuiObject") then
		return false
	end

	local mode = root:FindFirstChild("Mode")
	local timer = root:FindFirstChild("Timer")
	if not mode or not mode:IsA("TextLabel") or not timer or not timer:IsA("TextLabel") then
		return false
	end
	self._modeLabel = mode
	self._timerLabel = timer

	local crossings = root:FindFirstChild("CrossingsCol")
	local barrels = root:FindFirstChild("BarrelsCol")
	if not crossings or not barrels then
		return false
	end

	for i = 1, ROWS do
		local name = "Row_" .. tostring(i)
		local lc = crossings:FindFirstChild(name)
		local rc = barrels:FindFirstChild(name)
		if not lc or not lc:IsA("TextLabel") or not rc or not rc:IsA("TextLabel") then
			table.clear(self._leftRows)
			table.clear(self._rightRows)
			return false
		end
		table.insert(self._leftRows, lc)
		table.insert(self._rightRows, rc)
	end

	self._bound = true
	return true
end

function LeaderboardService:Start()
	self._odsCrossings = openOds(ODS_CROSSINGS)
	self._odsBarrels = openOds(ODS_BARRELS)
	if not self._odsCrossings or not self._odsBarrels then
		if not RunService:IsStudio() then
			warn("[LeaderboardService] OrderedDataStores unavailable — global view may be empty.")
		end
	end

	task.spawn(function()
		local ok = false
		for _ = 1, 90 do
			if self._stop then
				return
			end
			if self:_tryBindBoard() then
				ok = true
				break
			end
			task.wait(1)
		end
		if not ok then
			warn(
				"[LeaderboardService] No authored UI under Workspace.DocksLeaderboard — expected Board/"
					.. GUI_NAME
					.. "/"
					.. ROOT_NAME
					.. " with Mode, Timer, CrossingsCol/BarrelsCol and Row_1..Row_8. See LeaderboardService.luau header."
			)
			return
		end

		self._modeIsGlobal = false
		self._nextRotateAt = os.clock() + ROTATE_SECONDS
		self:_prefetchGlobalIfNeeded()
		self:_paintFull()

		while not self._stop do
			local now = os.clock()
			if now >= self._nextRotateAt then
				self._modeIsGlobal = not self._modeIsGlobal
				self._nextRotateAt = now + ROTATE_SECONDS
				self:_prefetchGlobalIfNeeded()
				self:_paintFull()
			else
				self:_paintTimerOnly(self._nextRotateAt - now)
			end
			task.wait(0.2)
		end
	end)
end

function LeaderboardService:Stop()
	self._stop = true
end

function LeaderboardService:OnStraitVoyageSuccess(userId: number, barrelsDelivered: number)
	if userId <= 0 then
		warn(string.format("[LeaderboardService] OnStraitVoyageSuccess ignored: invalid userId=%s", tostring(userId)))
		return
	end
	self._sessionCrossings[userId] = (self._sessionCrossings[userId] or 0) + 1
	local bd = math.max(0, math.floor(barrelsDelivered))
	self._sessionBarrels[userId] = (self._sessionBarrels[userId] or 0) + bd

	print(string.format(
		"[LeaderboardService] strait voyage tracked: userId=%d delivered=%d -> session crossings=%d, session barrels=%d",
		userId,
		bd,
		self._sessionCrossings[userId],
		self._sessionBarrels[userId]
	))

	if not self._bound then
		warn("[LeaderboardService] tracked voyage but UI is not bound yet; rows will update once Studio UI is found.")
	elseif not self._modeIsGlobal then
		self:_paintFull()
	else
		self:_paintTimerOnly(self._nextRotateAt - os.clock())
	end

	local oc = self._odsCrossings
	local ob = self._odsBarrels
	if not oc and not ob then
		warn("[LeaderboardService] no OrderedDataStore handles open — global rows will never persist.")
		return
	end

	task.spawn(function()
		DataStoreWriteGate.waitForWriteBudget(2.5)
		if oc then
			local ok, errOrNew = pcall(function()
				return oc:UpdateAsync(tostring(userId), function(old: number?)
					return (if typeof(old) == "number" then old else 0) + 1
				end)
			end)
			if ok then
				print(string.format(
					"[LeaderboardService] crossings ODS updated: userId=%d new=%s",
					userId,
					tostring(errOrNew)
				))
			else
				warn(string.format(
					"[LeaderboardService] crossings ODS UpdateAsync FAILED for userId=%d: %s",
					userId,
					tostring(errOrNew)
				))
			end
		end
		if ob and bd > 0 then
			local ok, errOrNew = pcall(function()
				return ob:UpdateAsync(tostring(userId), function(old: number?)
					return (if typeof(old) == "number" then old else 0) + bd
				end)
			end)
			if ok then
				print(string.format(
					"[LeaderboardService] barrels ODS updated: userId=%d delta=%d new=%s",
					userId,
					bd,
					tostring(errOrNew)
				))
			else
				warn(string.format(
					"[LeaderboardService] barrels ODS UpdateAsync FAILED for userId=%d delta=%d: %s",
					userId,
					bd,
					tostring(errOrNew)
				))
			end
		end
	end)
end

function LeaderboardService:_resolveName(userId: number): string
	local cached = self._nameCache[userId]
	if cached then
		return cached
	end
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		self._nameCache[userId] = plr.DisplayName
		return plr.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		self._nameCache[userId] = name
		return name
	end
	self._nameCache[userId] = "#" .. tostring(userId)
	return self._nameCache[userId] :: string
end

local function sortTop(map: { [number]: number }, maxN: number): { { userId: number, score: number } }
	local arr: { { userId: number, score: number } } = {}
	for uid, sc in pairs(map) do
		if sc > 0 then
			table.insert(arr, { userId = uid, score = sc })
		end
	end
	table.sort(arr, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.userId < b.userId
	end)
	while #arr > maxN do
		table.remove(arr)
	end
	return arr
end

local function fetchGlobalTop(store: OrderedDataStore?, maxN: number): { { userId: number, score: number } }
	local out: { { userId: number, score: number } } = {}
	if not store then
		return out
	end
	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, maxN)
	end)
	if not ok or not pages then
		return out
	end
	local page = pages:GetCurrentPage()
	for _, entry in ipairs(page) do
		local e = entry :: any
		local key = e.key or e.Key
		local val = e.value or e.Value
		local uid = tonumber(key)
		local sc = tonumber(val)
		if uid and sc and sc > 0 then
			table.insert(out, { userId = uid, score = math.floor(sc) })
		end
	end
	return out
end

function LeaderboardService:_prefetchGlobalIfNeeded()
	if not self._modeIsGlobal then
		self._globalCrossCache = nil
		self._globalBarrelCache = nil
		return
	end
	self._globalCrossCache = fetchGlobalTop(self._odsCrossings, ROWS)
	self._globalBarrelCache = fetchGlobalTop(self._odsBarrels, ROWS)
end

local RANK_COLORS = {
	Color3.fromRGB(255, 215, 0),
	Color3.fromRGB(210, 210, 220),
	Color3.fromRGB(205, 127, 80),
}

function LeaderboardService:_setRowStyle(lbl: TextLabel, rank: number)
	if rank <= TOP_HIGHLIGHT and rank >= 1 then
		lbl.BackgroundColor3 = Color3.fromRGB(40, 44, 58):Lerp(RANK_COLORS[rank], 0.22)
	else
		lbl.BackgroundColor3 = Color3.fromRGB(32, 36, 46)
	end
end

function LeaderboardService:_paintTimerOnly(secondsLeft: number)
	local t = self._timerLabel
	if t then
		t.Text = string.format("Switching view in %ds", math.ceil(math.max(0, secondsLeft)))
	end
end

function LeaderboardService:_paintFull()
	if not self._bound then
		return
	end
	local mode = self._modeLabel
	local timer = self._timerLabel
	if not mode or not timer then
		return
	end

	if self._modeIsGlobal then
		mode.Text = "GLOBAL · ALL SERVERS"
	else
		mode.Text = "THIS SERVER · SESSION"
	end
	self:_paintTimerOnly(self._nextRotateAt - os.clock())

	local crossList: { { userId: number, score: number } }
	local barrelList: { { userId: number, score: number } }

	if self._modeIsGlobal then
		crossList = self._globalCrossCache or {}
		barrelList = self._globalBarrelCache or {}
	else
		crossList = sortTop(self._sessionCrossings, ROWS)
		barrelList = sortTop(self._sessionBarrels, ROWS)
	end

	for i = 1, ROWS do
		local lc = self._leftRows[i]
		local rc = self._rightRows[i]
		if lc and rc then
			local c = crossList[i]
			local b = barrelList[i]
			if c then
				lc.Text = string.format("%d  %s  —  %d", i, self:_resolveName(c.userId), c.score)
				self:_setRowStyle(lc, i)
			else
				lc.Text = "—"
				self:_setRowStyle(lc, 99)
			end
			if b then
				rc.Text = string.format("%d  %s  —  %d", i, self:_resolveName(b.userId), b.score)
				self:_setRowStyle(rc, i)
			else
				rc.Text = "—"
				self:_setRowStyle(rc, 99)
			end
		end
	end
end

return LeaderboardService
