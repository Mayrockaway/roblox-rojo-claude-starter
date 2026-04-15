--!strict
-- ClientPerf: measures client-side frame time (FPS), memory, and hitches every 5s.
-- Logs `[ClientPerf]` to the client console — visible via playtest logs + piped
-- as "[SRV] [ClientPerf]" to the server if dev-log broadcasting is active. Separate
-- from server PerfService so we see what the *player* actually feels.

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Players = game:GetService("Players")

local REPORT_INTERVAL = 5
local HITCH_THRESHOLD_MS = 33 -- anything >33ms is a visible stutter at 30fps

local windowStart = os.clock()
local frameCount = 0
local frameTimeTotalMs = 0
local frameTimeMaxMs = 0
local hitches = 0
local lastFrameClock = os.clock()

local function reportNow()
	local elapsed = os.clock() - windowStart
	if elapsed < 0.1 or frameCount == 0 then
		windowStart = os.clock()
		frameCount = 0
		frameTimeTotalMs = 0
		frameTimeMaxMs = 0
		hitches = 0
		return
	end
	local fps = frameCount / elapsed
	local avgMs = frameTimeTotalMs / frameCount
	local maxMs = frameTimeMaxMs

	-- Roblox client Stats
	local okMem, totalMem = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
	local okInst, instMem = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Instances) end)
	local okGfx, gfxMem = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Graphics) end)
	local okParticles, partMem = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsParticles) end)
	local okSounds, sndMem = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Sounds) end)
	local okPrim, primitives = pcall(function() return Stats.PrimitivesCount end)
	local okMoving, moving = pcall(function() return Stats.MovingPrimitivesCount end)

	print(string.format(
		"[ClientPerf] fps=%.1f avgFrame=%.1fms max=%.1fms hitches>=%dms=%d",
		fps, avgMs, maxMs, HITCH_THRESHOLD_MS, hitches
	))
	print(string.format(
		"[ClientPerf]   memory: total=%.1fMB instances=%.1fMB graphics=%.1fMB particles=%.1fMB sounds=%.1fMB",
		okMem and totalMem or -1,
		okInst and instMem or -1,
		okGfx and gfxMem or -1,
		okParticles and partMem or -1,
		okSounds and sndMem or -1
	))
	print(string.format(
		"[ClientPerf]   physics: primitives=%d moving=%d",
		okPrim and primitives or -1,
		okMoving and moving or -1
	))

	-- Top 6 memory-eating categories.
	local cats = {}
	for _, tag in pairs(Enum.DeveloperMemoryTag:GetEnumItems()) do
		local ok, mb = pcall(function() return Stats:GetMemoryUsageMbForTag(tag) end)
		if ok and mb and mb > 0.2 then
			table.insert(cats, { name = tag.Name, mb = mb })
		end
	end
	table.sort(cats, function(a, b) return a.mb > b.mb end)
	for i, cat in ipairs(cats) do
		if i > 6 then break end
		print(string.format("[ClientPerf]   mem.%s=%.1fMB", cat.name, cat.mb))
	end

	-- Luau restricts collectgarbage; we can only read current allocation (no forced collect).
	local kb = collectgarbage("count")
	print(string.format("[ClientPerf]   luaHeap: %.1fMB (Luau doesn't expose forced GC; see mem.LuaHeap above for engine view)",
		kb / 1024))

	windowStart = os.clock()
	frameCount = 0
	frameTimeTotalMs = 0
	frameTimeMaxMs = 0
	hitches = 0
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	local frameMs = (now - lastFrameClock) * 1000
	lastFrameClock = now
	frameCount += 1
	frameTimeTotalMs += frameMs
	if frameMs > frameTimeMaxMs then
		frameTimeMaxMs = frameMs
	end
	if frameMs > HITCH_THRESHOLD_MS then
		hitches += 1
	end
	if (now - windowStart) >= REPORT_INTERVAL then
		reportNow()
	end
end)
