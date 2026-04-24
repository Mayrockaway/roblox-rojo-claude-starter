--!strict
-- PerfService: lightweight per-service CPU + network + workspace instrumentation
-- that prints a `[Perf]` summary every 5 seconds. Use `PerfService:Time(label, fn)`
-- to wrap a hot call, or `PerfService:OpenSpan(label)` + `:CloseSpan(h)` for manual
-- bracketing. Counters and totals reset each report window.

local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PerfService = {}

local REPORT_INTERVAL_SECONDS = 5

function PerfService:Init()
	self._running = false
	self._windowStart = os.clock()
	self._spanTotals = {} :: { [string]: number }   -- label -> total ms in window
	self._spanCalls = {} :: { [string]: number }    -- label -> call count
	self._spanMax = {} :: { [string]: number }      -- label -> worst single sample (ms)
	self._counters = {} :: { [string]: number }     -- cumulative counters, reset on report
	self._thread = nil :: thread?
end

function PerfService:OpenSpan(label: string): number
	return os.clock()
end

function PerfService:CloseSpan(label: string, startClock: number)
	local elapsedMs = (os.clock() - startClock) * 1000
	self._spanTotals[label] = (self._spanTotals[label] or 0) + elapsedMs
	self._spanCalls[label] = (self._spanCalls[label] or 0) + 1
	local cur = self._spanMax[label]
	if cur == nil or elapsedMs > cur then
		self._spanMax[label] = elapsedMs
	end
end

-- Convenience: run `fn` and record its cost under `label`.
function PerfService:Time(label: string, fn: () -> any): any
	local h = self:OpenSpan(label)
	local ok, resultOrErr = pcall(fn)
	self:CloseSpan(label, h)
	if not ok then
		error(resultOrErr, 0)
	end
	return resultOrErr
end

function PerfService:Count(label: string, n: number?)
	self._counters[label] = (self._counters[label] or 0) + (n or 1)
end

local function snapshot(t: { [string]: number }): { [string]: number }
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in pairs(t) do table.insert(out, k) end
	table.sort(out)
	return out
end

function PerfService:_countWorkspaceObjects(): { [string]: number }
	local counts = {
		IdleBoats = 0,
		ActiveShipmentBoat = 0,
		Drills = 0,
		Pipes = 0,
		Drums = 0,
		Barrels = 0,
		OilSprays = 0,
		Plots = 0,
	}
	local docks = Workspace:FindFirstChild("dOCKS") or Workspace:FindFirstChild("Docks")
	local boatsFolder = docks and docks:FindFirstChild("Boats")
	if boatsFolder then
		for _, c in ipairs(boatsFolder:GetChildren()) do
			if string.sub(c.Name, 1, 9) == "IdleBoat_" then counts.IdleBoats += 1 end
		end
	end
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	if plots then
		for _, plot in ipairs(plots:GetChildren()) do
			counts.Plots += 1
			local v = plot:FindFirstChild("OilVisuals")
			if v then
				for _, child in ipairs(v:GetChildren()) do
					if child.Name == "ActiveShipmentBoat" then counts.ActiveShipmentBoat += 1 end
					if child.Name == "Drills" then counts.Drills += #child:GetChildren() end
					if child.Name == "Pipes" then counts.Pipes += #child:GetChildren() end
					if child.Name == "Drums" then counts.Drums += #child:GetChildren() end
					if child.Name == "Barrels" then counts.Barrels += #child:GetChildren() end
					if child.Name == "OilSprays" then counts.OilSprays += #child:GetChildren() end
				end
			end
		end
	end
	return counts
end

local function memoryByTag()
	-- Roblox exposes per-category memory via Stats:GetMemoryUsageMbForTag.
	-- Returns the top 6 heaviest categories so the report stays readable.
	local categories = {}
	for _, tag in pairs(Enum.DeveloperMemoryTag:GetEnumItems()) do
		local ok, mb = pcall(function()
			return Stats:GetMemoryUsageMbForTag(tag)
		end)
		if ok and mb and mb > 0.1 then
			table.insert(categories, { name = tag.Name, mb = mb })
		end
	end
	table.sort(categories, function(a, b) return a.mb > b.mb end)
	return categories
end

function PerfService:_report()
	local elapsed = os.clock() - self._windowStart
	if elapsed < 0.1 then return end

	-- Roblox Stats snapshot
	local okHeartbeat, heartbeatMs = pcall(function()
		return Stats.HeartbeatTimeMs
	end)
	local okPhysics, physicsMs = pcall(function()
		return Stats.PhysicsStepTimeMs
	end)
	local okSend, sendKbps = pcall(function()
		return Stats.DataSendKbps
	end)
	local okRecv, recvKbps = pcall(function()
		return Stats.DataReceiveKbps
	end)
	local okTotalMem, totalMemMb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	local okPrim, primitives = pcall(function() return Stats.PrimitivesCount end)
	local okMoving, movingPrim = pcall(function() return Stats.MovingPrimitivesCount end)
	local okContacts, contacts = pcall(function() return Stats.ContactsCount end)
	local okInst, instancesMb = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Instances) end)

	local playerCount = #Players:GetPlayers()
	local objCounts = self:_countWorkspaceObjects()

	-- Top spans by total ms.
	local spanEntries = {}
	for label, total in pairs(self._spanTotals) do
		table.insert(spanEntries, {
			label = label,
			totalMs = total,
			calls = self._spanCalls[label] or 0,
			maxMs = self._spanMax[label] or 0,
		})
	end
	table.sort(spanEntries, function(a, b) return a.totalMs > b.totalMs end)

	if RunService:IsStudio() then
		print(string.format(
			"[Perf] window=%.2fs players=%d | heartbeat=%.2fms physics=%.2fms | netSend=%.1fkbps netRecv=%.1fkbps",
			elapsed,
			playerCount,
			okHeartbeat and heartbeatMs or -1,
			okPhysics and physicsMs or -1,
			okSend and sendKbps or -1,
			okRecv and recvKbps or -1
		))
		print(string.format(
			"[Perf]   physics: primitives=%d moving=%d contacts=%d",
			okPrim and primitives or -1,
			okMoving and movingPrim or -1,
			okContacts and contacts or -1
		))
		print(string.format(
			"[Perf]   memory: total=%.1fMB instances=%.1fMB",
			okTotalMem and totalMemMb or -1,
			okInst and instancesMb or -1
		))
		local memCats = memoryByTag()
		for i, cat in ipairs(memCats) do
			if i > 6 then break end
			print(string.format("[Perf]   mem.%s=%.1fMB", cat.name, cat.mb))
		end
		print(string.format(
			"[Perf]   objs: plots=%d idleBoats=%d activeBoats=%d drills=%d pipes=%d drums=%d barrels=%d sprays=%d",
			objCounts.Plots, objCounts.IdleBoats, objCounts.ActiveShipmentBoat,
			objCounts.Drills, objCounts.Pipes, objCounts.Drums,
			objCounts.Barrels, objCounts.OilSprays
		))
		for i, entry in ipairs(spanEntries) do
			if i > 8 then break end
			local avg = entry.calls > 0 and entry.totalMs / entry.calls or 0
			print(string.format(
				"[Perf]   %s: total=%.1fms calls=%d avg=%.2fms max=%.1fms",
				entry.label, entry.totalMs, entry.calls, avg, entry.maxMs
			))
		end
		for _, k in ipairs(sortedKeys(self._counters)) do
			print(string.format("[Perf]   counter %s=%d", k, self._counters[k]))
		end
	end

	self._windowStart = os.clock()
	self._spanTotals = {}
	self._spanCalls = {}
	self._spanMax = {}
	self._counters = {}
end

function PerfService:Start()
	if self._running then return end
	self._running = true
	self._windowStart = os.clock()
	self._thread = task.spawn(function()
		while self._running do
			task.wait(REPORT_INTERVAL_SECONDS)
			if not self._running then break end
			local ok, err = pcall(function() self:_report() end)
			if not ok then
				warn("[PerfService] report error: " .. tostring(err))
			end
		end
	end)
end

function PerfService:Stop()
	self._running = false
	self._thread = nil
end

return PerfService
