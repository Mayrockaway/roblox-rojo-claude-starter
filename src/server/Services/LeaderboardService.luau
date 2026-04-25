--!strict
-- Docks strait leaderboard: **author the UI in Studio** anywhere under `Workspace`. The board is
-- looked up by SurfaceGui name (`StraitLeaderboardGui`) on a `BasePart` parent — it does NOT have
-- to live at `Workspace.DocksLeaderboard.Board` anymore. Putting it under `Workspace.Map.…` is fine.
-- Use **at most one** such board in the place; `scripts/mcp_docks_leaderboard_board.luau` can remove
-- extras when you run it in Studio.
-- This service only **binds** to TextLabels and updates text / row tint. Rotates every 15s
-- through three view sets:
--   1) THIS SERVER · session — **Successful Crossings** | **Barrels Shipped**
--   2) GLOBAL (all servers)  — same two columns, OrderedDataStore ranks
--   3) LIFETIME CASH EARNED  — **This server · session** | **All-time (all servers)** (cash leaderboards)
--
-- Required hierarchy (names matter — these are looked up by exact name):
--   <any BasePart anywhere under Workspace, conventionally Map.DocksLeaderboard.Board>
--     StraitLeaderboardGui (SurfaceGui) — not ScreenGui; Face = Front, PixelsPerStud as you like
--                                         Adornee forced to the parent part on bind; `AlwaysOnTop` off
--                                         so the sign draws with normal world depth (flush on the board)
--       Root (Frame) — full size, transparent or styled in Studio
--         Mode (TextLabel) — server sets the active view name + scope
--         Timer (TextLabel) — server sets countdown to next view switch
--         Header (Frame, optional) — if present, `CrossingsHeader` / `BarrelsHeader` each with
--           `LeftHeader` and `RightHeader` (TextLabels); column titles update per view
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
local ODS_LIFETIME_CASH = "OTS_StraitLifetimeCashEarned_v1"

local ROTATE_SECONDS = 15
local ROWS = 8
local TOP_HIGHLIGHT = 3

-- pageIndex: 0 = session crossings+barrels, 1 = global c+b, 2 = session cash | global cash
local PAGE_SESSION_CB = 0
local PAGE_GLOBAL_CB = 1
local PAGE_CASH = 2
local PAGE_COUNT = 3

local GUI_NAME = "StraitLeaderboardGui"
local ROOT_NAME = "Root"

export type BoardDisplay = {
	mode: TextLabel,
	timer: TextLabel,
	leftRows: { TextLabel },
	rightRows: { TextLabel },
	hdrCrossLeft: TextLabel?,
	hdrCrossRight: TextLabel?,
	hdrBarrelLeft: TextLabel?,
	hdrBarrelRight: TextLabel?,
}

local LeaderboardService = {}

function LeaderboardService:Init()
	self._stop = false
	self._sessionCrossings = {} :: { [number]: number }
	self._sessionBarrels = {} :: { [number]: number }
	self._sessionCashEarned = {} :: { [number]: number }
	self._odsCrossings = nil :: OrderedDataStore?
	self._odsBarrels = nil :: OrderedDataStore?
	self._odsLifetimeCash = nil :: OrderedDataStore?
	self._bound = false
	--- At most one in-world `StraitLeaderboardGui` (place should not contain duplicates).
	self._board = nil :: BoardDisplay?
	self._nextRotateAt = 0
	self._pageIndex = 0
	self._nameCache = {} :: { [number]: string }
	self._globalCrossCache = nil :: { { userId: number, score: number } }?
	self._globalBarrelCache = nil :: { { userId: number, score: number } }?
	self._globalCashCache = nil :: { { userId: number, score: number } }?
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

local function formatMoney(n: number): string
	local v = math.floor(n)
	if v < 0 then
		v = 0
	end
	local s = tostring(v)
	-- insert thousands separators
	local k = 0
	repeat
		s, k = s:gsub("(%d)(%d%d%d)$", "%1,%2")
	until k == 0
	return "$" .. s
end

-- Build a `BoardDisplay` from a SurfaceGui, or return nil if the hierarchy does not match the contract.
function LeaderboardService:_buildDisplayFromSurfaceGui(sg: SurfaceGui): BoardDisplay?
	if sg.Parent == nil or not sg.Parent:IsA("BasePart") then
		return nil
	end
	-- Pin the face to this part; normal depth (not over avatars) so the board reads as a physical sign.
	if sg.Parent and sg.Parent:IsA("BasePart") then
		sg.Adornee = sg.Parent
	end
	sg.AlwaysOnTop = false
	local root = sg:FindFirstChild(ROOT_NAME)
	if not root or not root:IsA("GuiObject") then
		return nil
	end
	local mode = root:FindFirstChild("Mode")
	local timer = root:FindFirstChild("Timer")
	if not mode or not mode:IsA("TextLabel") or not timer or not timer:IsA("TextLabel") then
		return nil
	end
	local hdrCL: TextLabel? = nil
	local hdrCR: TextLabel? = nil
	local hdrBL: TextLabel? = nil
	local hdrBR: TextLabel? = nil
	local h = root:FindFirstChild("Header")
	if h and h:IsA("GuiObject") then
		local cx = h:FindFirstChild("CrossingsHeader")
		local br = h:FindFirstChild("BarrelsHeader")
		if
			cx
			and cx:IsA("GuiObject")
			and br
			and br:IsA("GuiObject")
		then
			local cxL = cx:FindFirstChild("LeftHeader")
			local cxR = cx:FindFirstChild("RightHeader")
			local bL = br:FindFirstChild("LeftHeader")
			local bR = br:FindFirstChild("RightHeader")
			if
				cxL and cxL:IsA("TextLabel")
				and cxR and cxR:IsA("TextLabel")
				and bL and bL:IsA("TextLabel")
				and bR and bR:IsA("TextLabel")
			then
				hdrCL = cxL
				hdrCR = cxR
				hdrBL = bL
				hdrBR = bR
			end
		end
	end
	local crossings = root:FindFirstChild("CrossingsCol")
	local barrels = root:FindFirstChild("BarrelsCol")
	if not crossings or not barrels then
		return nil
	end
	local leftRows: { TextLabel } = {}
	local rightRows: { TextLabel } = {}
	for i = 1, ROWS do
		local name = "Row_" .. tostring(i)
		local lc = crossings:FindFirstChild(name)
		local rc = barrels:FindFirstChild(name)
		if not lc or not lc:IsA("TextLabel") or not rc or not rc:IsA("TextLabel") then
			return nil
		end
		table.insert(leftRows, lc)
		table.insert(rightRows, rc)
	end
	return {
		mode = mode,
		timer = timer,
		leftRows = leftRows,
		rightRows = rightRows,
		hdrCrossLeft = hdrCL,
		hdrCrossRight = hdrCR,
		hdrBarrelLeft = hdrBL,
		hdrBarrelRight = hdrBR,
	}
end

function LeaderboardService:_tryBindBoard(): boolean
	self._board = nil
	self._bound = false

	-- Collect `StraitLeaderboardGui` under Workspace (parent = `BasePart`). Sort so
	-- `DocksLeaderboard` / `Map` paths are tried before random legacy parts, then **bind only the
	-- first** that passes validation. The place should only contain one board; duplicate copies
	-- should be removed in Studio (see `mcp_docks_leaderboard_board.luau`).
	local cands: { SurfaceGui } = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("SurfaceGui") and d.Name == GUI_NAME then
			if d.Parent and d.Parent:IsA("BasePart") then
				table.insert(cands, d)
			end
		end
	end
	if #cands == 0 then
		return false
	end
	table.sort(cands, function(a, b)
		local ap = a:GetFullName()
		local bp = b:GetFullName()
		local function pri(s: string): number
			if s:find("DocksLeaderboard", 1, true) or s:find(".Map.", 1, true) or s:find("Map.Docks", 1, true) then
				return 0
			end
			return 1
		end
		local ad, bd = pri(ap), pri(bp)
		if ad ~= bd then
			return ad < bd
		end
		return ap < bp
	end)
	for _, sg in ipairs(cands) do
		local built = self:_buildDisplayFromSurfaceGui(sg)
		if built then
			self._board = built
			self._bound = true
			if RunService:IsStudio() then
				print(("[LeaderboardService] bound to %s (/%d candidate(s), using first valid)"):format(sg:GetFullName(), #cands))
			end
			return true
		end
	end
	if RunService:IsStudio() then
		warn(("[LeaderboardService] no valid %s: tried %d instance(s) — first was %s"):format(GUI_NAME, #cands, cands[1] and cands[1]:GetFullName() or "nil"))
	end
	return false
end

function LeaderboardService:Start()
	self._odsCrossings = openOds(ODS_CROSSINGS)
	self._odsBarrels = openOds(ODS_BARRELS)
	self._odsLifetimeCash = openOds(ODS_LIFETIME_CASH)
	if not self._odsCrossings or not self._odsBarrels or not self._odsLifetimeCash then
		if not RunService:IsStudio() then
			warn("[LeaderboardService] One or more OrderedDataStores unavailable — some views may be empty.")
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

		self._pageIndex = 0
		self._nextRotateAt = os.clock() + ROTATE_SECONDS
		self:_prefetchGlobalForPage()
		self:_paintFull()

		while not self._stop do
			local now = os.clock()
			if now >= self._nextRotateAt then
				self._pageIndex = (self._pageIndex + 1) % PAGE_COUNT
				self._nextRotateAt = now + ROTATE_SECONDS
				self:_prefetchGlobalForPage()
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

	if RunService:IsStudio() then
		print(string.format(
			"[LeaderboardService] strait voyage tracked: userId=%d delivered=%d -> session crossings=%d, session barrels=%d",
			userId,
			bd,
			self._sessionCrossings[userId],
			self._sessionBarrels[userId]
		))
	end

	if not self._bound then
		warn("[LeaderboardService] tracked voyage but UI is not bound yet; rows will update once Studio UI is found.")
	elseif self._pageIndex == PAGE_SESSION_CB then
		self:_paintFull()
	else
		self:_paintTimerOnly(self._nextRotateAt - os.clock())
	end

	local oc = self._odsCrossings
	local ob = self._odsBarrels
	if not oc and not ob then
		warn("[LeaderboardService] no OrderedDataStore handles for crossings/barrels open — global rows will never persist.")
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
				if RunService:IsStudio() then
					print(string.format(
						"[LeaderboardService] crossings ODS updated: userId=%d new=%s",
						userId,
						tostring(errOrNew)
					))
				end
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
				if RunService:IsStudio() then
					print(string.format(
						"[LeaderboardService] barrels ODS updated: userId=%d delta=%d new=%s",
						userId,
						bd,
						tostring(errOrNew)
					))
				end
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

function LeaderboardService:OnCashEarned(userId: number, amount: number)
	if userId <= 0 then
		return
	end
	local add = math.max(0, math.floor(amount))
	if add <= 0 then
		return
	end
	self._sessionCashEarned[userId] = (self._sessionCashEarned[userId] or 0) + add

	if not self._bound then
		-- still persist global total below
	elseif self._pageIndex == PAGE_CASH then
		self:_paintFull()
	else
		self:_paintTimerOnly(self._nextRotateAt - os.clock())
	end

	local store = self._odsLifetimeCash
	if not store then
		if not RunService:IsStudio() then
			warn("[LeaderboardService] lifetime cash ODS closed — global cash leaderboard will not update.")
		end
		return
	end

	task.spawn(function()
		DataStoreWriteGate.waitForWriteBudget(1.0)
		local ok, errOrNew = pcall(function()
			return store:UpdateAsync(tostring(userId), function(old: number?)
				return (if typeof(old) == "number" then old else 0) + add
			end)
		end)
		if ok then
			if RunService:IsStudio() then
				print(string.format(
					"[LeaderboardService] lifetime cash ODS updated: userId=%d +%d new=%s",
					userId,
					add,
					tostring(errOrNew)
				))
			end
		else
			warn(
				string.format(
					"[LeaderboardService] lifetime cash ODS UpdateAsync FAILED for userId=%d: %s",
					userId,
					tostring(errOrNew)
				)
			)
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

function LeaderboardService:_prefetchGlobalForPage()
	if self._pageIndex == PAGE_GLOBAL_CB then
		self._globalCrossCache = fetchGlobalTop(self._odsCrossings, ROWS)
		self._globalBarrelCache = fetchGlobalTop(self._odsBarrels, ROWS)
		self._globalCashCache = nil
	elseif self._pageIndex == PAGE_CASH then
		self._globalCrossCache = nil
		self._globalBarrelCache = nil
		self._globalCashCache = fetchGlobalTop(self._odsLifetimeCash, ROWS)
	else
		self._globalCrossCache = nil
		self._globalBarrelCache = nil
		self._globalCashCache = nil
	end
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

function LeaderboardService:_applyColumnHeaderTexts(
	d: BoardDisplay,
	leftLeft: string,
	leftRight: string,
	rightLeft: string,
	rightRight: string
)
	local a = d.hdrCrossLeft
	local b = d.hdrCrossRight
	local c = d.hdrBarrelLeft
	local r = d.hdrBarrelRight
	if a then
		a.Text = leftLeft
	end
	if b then
		b.Text = leftRight
	end
	if c then
		c.Text = rightLeft
	end
	if r then
		r.Text = rightRight
	end
end

function LeaderboardService:_paintTimerOnly(secondsLeft: number)
	local b = self._board
	if b then
		b.timer.Text = string.format("Switching view in %ds", math.ceil(math.max(0, secondsLeft)))
	end
end

function LeaderboardService:_paintOneColumnMoney(
	rows: { TextLabel },
	entries: { { userId: number, score: number } }?,
	money: boolean
)
	for i = 1, ROWS do
		local lb = rows[i]
		if lb then
			local e = if entries then entries[i] else nil
			if e then
				if money then
					lb.Text = string.format(
						"%d  %s  —  %s",
						i,
						self:_resolveName(e.userId),
						formatMoney(e.score)
					)
				else
					lb.Text = string.format("%d  %s  —  %d", i, self:_resolveName(e.userId), e.score)
				end
				self:_setRowStyle(lb, i)
			else
				lb.Text = "—"
				self:_setRowStyle(lb, 99)
			end
		end
	end
end

function LeaderboardService:_paintFull()
	local d = self._board
	if not self._bound or d == nil then
		return
	end

	local modeText: string
	local ll: string
	local lR: string
	local rl: string
	local rR: string
	if self._pageIndex == PAGE_SESSION_CB then
		modeText = "THIS SERVER · SESSION"
		ll, lR, rl, rR = "Player", "Successful Crossings", "Player", "Barrels Shipped"
	elseif self._pageIndex == PAGE_GLOBAL_CB then
		modeText = "GLOBAL · ALL SERVERS"
		ll, lR, rl, rR = "Player", "Successful Crossings", "Player", "Barrels Shipped"
	else
		modeText = "LIFETIME CASH EARNED"
		ll, lR, rl, rR = "Player", "This server · session", "Player", "All servers · all-time"
	end
	d.mode.Text = modeText
	self:_applyColumnHeaderTexts(d, ll, lR, rl, rR)

	if self._pageIndex == PAGE_SESSION_CB then
		self:_paintOneColumnMoney(d.leftRows, sortTop(self._sessionCrossings, ROWS), false)
		self:_paintOneColumnMoney(d.rightRows, sortTop(self._sessionBarrels, ROWS), false)
	elseif self._pageIndex == PAGE_GLOBAL_CB then
		self:_paintOneColumnMoney(d.leftRows, self._globalCrossCache or {}, false)
		self:_paintOneColumnMoney(d.rightRows, self._globalBarrelCache or {}, false)
	else
		self:_paintOneColumnMoney(d.leftRows, sortTop(self._sessionCashEarned, ROWS), true)
		self:_paintOneColumnMoney(d.rightRows, self._globalCashCache or {}, true)
	end
	self:_paintTimerOnly(self._nextRotateAt - os.clock())
end

return LeaderboardService
