--!strict
--- SecurityPersonnelService
---
--- Owns the "Security Personnel" Robux-gated **run upgrade**: a single-use
--- crewmate hire that grants the player **complete event immunity on their
--- next dispatched shipment**. Stacking is allowed — buying N times protects
--- the next N dispatches.
---
--- Responsibilities:
---   1. **Receipt grant** — register the `security_personnel` consumable
---      handler with `MonetizationService`. A successful Robux receipt for
---      `consumable.security_personnel_x1` lands here → +1 stack on the
---      player's run-upgrade inventory in `OilStateService` → push state
---      so any open `ShipOilPanelGui` shows the new owned count.
---   2. **Dispatch consume** — `OilShipmentService:_handleDispatch` calls
---      `:TryConsumeForDispatch(userId)` after the shipment table is built.
---      We decrement one stack atomically and return `true` so the caller
---      stamps `shipment.eventImmunity = true`. The strait waypoint handler
---      and the forced contract pirate path read that flag and short-circuit
---      every event roll for the rest of the voyage.
---
--- This service intentionally has **no remote events** — there is nothing
--- the client can ask it to do directly. The buy CTA is just a Robux prompt
--- routed through `MonetizationService`; consumption is server-driven on
--- dispatch. That keeps the surface tiny and unspoofable.
---
--- Refund policy mirrors `ArmyGeneralService`: returning `false` from the
--- consumable handler leaves the receipt unfinished, Roblox auto-refunds on
--- next session. The only failure path here is "no oil state" (player left
--- between purchase confirmation and receipt) which is rare and recoverable.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SecurityPersonnelService = {}

--- Asset paths for the visible "guard on the deck" mount that signals to the
--- player (and anyone watching) that their next-run immunity is armed.
---
--- Author contract:
---   * `ReplicatedStorage.Assets.SecurityPersonnel` is an R15 character Model
---     with `PrimaryPart = HumanoidRootPart`. We clone it, neutralize its
---     physics + AI (see `neutralizeMountedPersonnel`), and `WeldConstraint`
---     its HRP to the boat's per-ship anchor part so the rig joins the
---     boat's single physics assembly and rides the hull rigidly with no
---     per-frame replication cost.
---   * Each ship template under `ReplicatedStorage.Assets.<ShipName>` exposes
---     a Part named `NPC_POSITION` (typically a 2x2x2 cube) sitting on the
---     deck so its **BOTTOM FACE marks where the guard's feet should land**
---     — i.e. the cube's footprint IS the NPC's footprint. Authoring
---     guidance: place the cube flush on the deck (bottom touching deck
---     surface) and rotate it so its +Z faces the direction the guard
---     should look. The mount code reads `npcPos.Size.Y/2` (down to the
---     bottom face) plus the cloned rig's own bounding-box-derived
---     HRP-above-feet, so this works for any `NPC_POSITION` size and any
---     future SP rig (R6, R15, custom) without code changes. If a guard
---     ends up half-buried in the deck, the cube was placed too low; if
---     floating, too high — nudge the cube in Studio.
local SECURITY_PERSONNEL_TEMPLATE_NAME = "SecurityPersonnel"
local NPC_POSITION_PART_NAME = "NPC_POSITION"
local MOUNT_MODEL_NAME = "SecurityPersonnelMount"

--- Distance from the cloned SP rig's bounding-box bottom (feet) up to its
--- pivot (HRP center). Computed per-clone in `MountForShipment` because a
--- future SP swap (different costume, R6, custom mesh) would have a
--- different value — hard-coding 3.0 here would silently regress. Kept as
--- a helper so the math is named and unit-testable in isolation if we ever
--- pull the mount code out for headless tests.
local function computeHrpAboveFeetStuds(model: Model): number
	if not model.PrimaryPart then
		return 0
	end
	local cf, sz = model:GetBoundingBox()
	local bboxBottomY = cf.Position.Y - sz.Y * 0.5
	return model.PrimaryPart.Position.Y - bboxBottomY
end

--- Resolve the SP template from `ReplicatedStorage.Assets`. Done lazily on
--- the first mount so a missing asset only warns when an immunity run
--- actually fires (rather than spamming on every server boot when running
--- against a stripped place file).
local function findSecurityPersonnelTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local tpl = assets:FindFirstChild(SECURITY_PERSONNEL_TEMPLATE_NAME)
	if tpl and tpl:IsA("Model") then
		return tpl
	end
	return nil
end

--- Find the per-ship anchor part. Templates author this as `NPC_POSITION`
--- (anchored, mostly transparent) and `_setupShip` weld-binds it to the
--- hull root so it moves with the boat in a rigid assembly.
local function findNpcPositionPart(boat: Instance): BasePart?
	local p = boat:FindFirstChild(NPC_POSITION_PART_NAME, true)
	if p and p:IsA("BasePart") then
		return p
	end
	return nil
end

--- Make the cloned SP rig safe to weld into the boat's physics assembly.
--- We deliberately do NOT anchor: anchored sub-parts can't be in the
--- boat's assembly, which means they'd need their CFrame re-replicated
--- every frame and the client sees ~16 individually-streamed CFrame
--- updates per Heartbeat — visibly out of sync with the boat's single
--- physics-replicated CFrame, so the rig appears to slide / glitch
--- side-to-side relative to the deck. Welding into the boat assembly
--- (see `MountForShipment`) means the rig moves rigidly with the hull
--- via one CFrame replication path. No per-frame cost either.
---
---   * Anchored = false      (eligible for the boat assembly)
---   * Massless = true       (rig adds zero mass to the boat — important;
---                            a default R15 weighs ~14 mass units which
---                            would skew AlignPosition response)
---   * CanCollide = false    (player walks through; doesn't shove HRP)
---   * CanTouch  = false     (no Touched events into shipment logic)
---   * CanQuery  = false     (raycasts in `OilShipmentService` skip it,
---                            e.g. the barrel-stack raycast at line ~220)
---   * Humanoid kept ALIVE   (Roblox renders `Shirt`/`Pants`/`BodyColors`
---                            only when a Humanoid is present in the
---                            character model — destroying it strips the
---                            cosmetic clothing). We make it as inert as
---                            possible: PlatformStand stops state-machine
---                            physics, walk/jump = 0, AutoRotate off, all
---                            HumanoidStateTypes disabled, no nameplate.
---                            Health/MaxHealth stays default — nothing
---                            damages the rig (CanTouch=false), so it
---                            won't die.
local function neutralizeMountedPersonnel(model: Model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			-- Stamp so any future descendant iterators (raycast filters,
			-- collision contracts, debug dumps) can opt to skip this rig
			-- without name-matching every body part individually.
			d:SetAttribute("IsSecurityPersonnelMountPart", true)
		end
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.NameDisplayDistance = 0
		hum.HealthDisplayDistance = 0
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		-- Disable every state so the humanoid never tries to take a
		-- physics step (FreeFalling, Running, GettingUp etc.). Wrapped
		-- in pcall because some `HumanoidStateType` values are not
		-- togglable on every Roblox version (Dead is the historical
		-- offender). Failing to disable a single state is harmless —
		-- PlatformStand already prevents state-driven physics.
		for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
			pcall(function()
				hum:SetStateEnabled(state, false)
			end)
		end
		-- Animator left in place (no animations are loaded server-side
		-- for the template, so it stays in default pose). Removing the
		-- Animator can break R15 cosmetics on some clients.
	end
end

--- Stable id used by both `MonetizationCatalog` (`grant.consumable.id`) and
--- `OilStateService:Add/Get/ConsumeRunUpgradeOwned`. Renaming invalidates
--- outstanding receipts — same caveat as every other id in the monetization
--- pipeline; treat as permanent once products go live.
local CONSUMABLE_ID = "security_personnel"
local RUN_UPGRADE_ID = "security_personnel"

function SecurityPersonnelService:Init(oilStateService)
	self._oilStateService = oilStateService
	-- Wired by `init.server.luau:SetMonetizationService` after both services
	-- exist. Until then the consumable id has no handler, which causes
	-- `_processReceipt` to return `NotProcessedYet` (auto-refund). That's the
	-- correct "fail safe" behavior during half-wired bring-up.
	self._monetizationService = nil
	self._running = false

	-- Active visual mounts keyed by `shipmentId`. Each entry holds the
	-- cloned guard Model (welded into the boat assembly via a single
	-- `WeldConstraint` on the HumanoidRootPart). `conn` is reserved for a
	-- future tracking connection if we ever need one (currently always
	-- `nil` because the weld does the work). Cleared by
	-- `UnmountForShipment` (called from `OilShipmentService:_teardownShip`
	-- before `BoatDockService:CheckinBoat` destroys the boat — the boat
	-- destruction also kills the welded clone since it's parented under
	-- the boat).
	self._mountsByShipmentId = {} :: { [string]: { model: Model, conn: RBXScriptConnection? } }
end

--- Inject `MonetizationService` and register the `security_personnel`
--- consumable handler. The handler is the *only* path that grants run-upgrade
--- inventory — no admin command, no FTUE freebie. Adding either later means
--- calling `OilStateService:AddRunUpgradeOwned(userId, "security_personnel", n)`
--- + `:PushState(userId)` directly.
function SecurityPersonnelService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end
	monetizationService:SetConsumableHandler(CONSUMABLE_ID, function(userId: number, quantity: number): (boolean, string?)
		local n = quantity
		if typeof(n) ~= "number" or n <= 0 then
			n = 1
		end
		-- `AddRunUpgradeOwned` is a no-op when state hasn't loaded yet
		-- (player left mid-receipt). Treat as "not granted" so Roblox
		-- retries on next session and the player gets their stack — same
		-- pattern `_grantShip` uses for `OK_ALREADY_OWNED`.
		if not self._oilStateService then
			return false, "ERR_NO_OIL_STATE"
		end
		local before = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
		self._oilStateService:AddRunUpgradeOwned(userId, RUN_UPGRADE_ID, math.floor(n))
		local after = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
		if after <= before then
			-- State write silently dropped (no profile loaded). Refund.
			return false, "ERR_GRANT_FAILED"
		end
		pcall(function()
			self._oilStateService:PushState(userId)
		end)
		return true, nil
	end)
end

function SecurityPersonnelService:Start()
	if self._running then
		return
	end
	self._running = true
end

function SecurityPersonnelService:Stop()
	self._running = false
end

--- Server-only entry point called by `OilShipmentService:_handleDispatch`
--- after the `shipment` table is built and before `_runShipment` spawns.
---
--- Returns `true` when one stack was consumed and the caller should stamp
--- `shipment.eventImmunity = true`. Returns `false` when the player owned
--- nothing (do nothing — normal voyage rolls events as usual).
---
--- Pushes oil state on a successful consume so the open `ShipOilPanelGui`
--- updates the owned count badge in the same frame as the dispatch.
function SecurityPersonnelService:TryConsumeForDispatch(userId: number): boolean
	if not self._oilStateService then
		return false
	end
	local owned = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
	if owned <= 0 then
		return false
	end
	local consumed = self._oilStateService:ConsumeRunUpgradeOwned(userId, RUN_UPGRADE_ID, 1)
	if not consumed then
		return false
	end
	-- Best-effort push so the panel "x N" badge tracks the consume. Wrapped
	-- in pcall: if PushState throws (e.g. mid-shutdown) the dispatch must
	-- still proceed because we already decremented the stack.
	pcall(function()
		self._oilStateService:PushState(userId)
	end)
	if Players:GetPlayerByUserId(userId) then
		-- Optional debug breadcrumb; no DevLog import to keep this file dep-free.
		-- print(string.format("[SecurityPersonnel] Consumed 1 stack for userId=%d (was %d).", userId, owned))
	end
	return true
end

--- Read-only owned count. Useful for tests / future dev commands; the live
--- UI should read `runUpgradeOwnedByItemId.security_personnel` from the oil
--- state snapshot rather than calling this from the client (which can't).
function SecurityPersonnelService:GetOwnedCount(userId: number): number
	if not self._oilStateService then
		return 0
	end
	return self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
end

------------------------------------------------------------------------
-- Visual mount: anchored guard rig that rides the boat for the run.
------------------------------------------------------------------------
--- Spawn a `SecurityPersonnel` clone on `boat` at its `NPC_POSITION` anchor
--- and `WeldConstraint` it into the boat's assembly so it rides the hull
--- rigidly. Called by `OilShipmentService:_runShipment` *only* when
--- `shipment.eventImmunity == true` (i.e. `TryConsumeForDispatch` already
--- deducted a stack), so the presence of the guard on deck is the
--- player-facing confirmation that their next-run protection is live.
---
--- Idempotent: a second call for the same `shipmentId` tears down the prior
--- mount first (defensive — the dispatch path only invokes us once per
--- voyage today, but the cost of being safe is one extra `Destroy`).
---
--- Failure modes are *non-fatal* — the run-upgrade has already been
--- consumed and the immunity flag is set on `shipment`. We warn loudly so
--- a missing `NPC_POSITION` on a new ship template surfaces in Output, but
--- the voyage continues with full event protection regardless.
function SecurityPersonnelService:MountForShipment(shipmentId: string, boat: Instance)
	if typeof(shipmentId) ~= "string" or shipmentId == "" or not boat then
		return
	end
	-- Tear down any prior mount under this id before re-spawning. Avoids
	-- the heartbeat-leak case if a future caller mounts twice.
	self:UnmountForShipment(shipmentId)

	local template = findSecurityPersonnelTemplate()
	if not template then
		warn(string.format(
			"[SecurityPersonnel] No `ReplicatedStorage.Assets.%s` model found — guard will not appear on shipmentId=%s.",
			SECURITY_PERSONNEL_TEMPLATE_NAME,
			shipmentId
		))
		return
	end

	local npcPos = findNpcPositionPart(boat)
	if not npcPos then
		warn(string.format(
			"[SecurityPersonnel] Boat %q is missing `%s` part — author one in Studio for this ship template (hip-height, +Z = facing dir). Guard will not appear on shipmentId=%s.",
			tostring((boat :: any).Name),
			NPC_POSITION_PART_NAME,
			shipmentId
		))
		return
	end

	local clone = template:Clone()
	clone.Name = MOUNT_MODEL_NAME
	-- Tag for any future dump / audit script. Mirrors the convention
	-- `_addPlayerFlag` uses for stamping the boat with shipment metadata.
	clone:SetAttribute("ShipmentId", shipmentId)

	-- Neutralize physics + AI BEFORE parenting / pivoting so the rig never
	-- has a frame where it could fall, ragdoll, or push the player.
	neutralizeMountedPersonnel(clone)

	clone.Parent = boat

	-- Compute the local-space lift that puts the rig's feet on the
	-- NPC_POSITION's BOTTOM face. The contract is documented above
	-- (cube's footprint = NPC's footprint, cube sits flush on deck):
	--   * `-npcPos.Size.Y / 2` lowers the target from the part's CENTER
	--     (where `npcPos.CFrame.Position` sits) down to its BOTTOM FACE,
	--     i.e. the deck surface.
	--   * `+hrpAboveFeet` then raises the HRP from feet-on-bottom-face up
	--     to the height the rig's pivot expects (PrimaryPart = HRP,
	--     sitting ~half the bounding-box height above the feet for R15).
	-- Doing the lift in the part's LOCAL Y means a tilted `NPC_POSITION`
	-- (e.g. a stern-leaning deck) still places the guard upright relative
	-- to that part — useful if a future ship template authors the anchor
	-- with non-zero pitch/roll.
	local hrpAboveFeet = computeHrpAboveFeetStuds(clone)
	local mountLocalLift = CFrame.new(0, -npcPos.Size.Y * 0.5 + hrpAboveFeet, 0)

	local hrp = clone.PrimaryPart
	if not hrp then
		warn(string.format(
			"[SecurityPersonnel] Cloned `%s` has no PrimaryPart (HumanoidRootPart) — cannot weld into boat assembly. shipmentId=%s",
			SECURITY_PERSONNEL_TEMPLATE_NAME,
			shipmentId
		))
		clone:Destroy()
		return
	end

	pcall(function()
		clone:PivotTo(npcPos.CFrame * mountLocalLift)
	end)

	-- Weld the rig's HumanoidRootPart to NPC_POSITION (which is itself
	-- WeldConstraint'd to the boat root in `OilShipmentService:_setupShip`).
	-- Net effect: the SP rig joins the boat's single physics assembly, so
	-- it moves rigidly with the hull via one CFrame replication path
	-- (the boat root's). This eliminates the side-to-side glitch we saw
	-- with anchored parts + per-Heartbeat PivotTo, where each of the ~16
	-- body parts streamed independent CFrame updates and visibly drifted
	-- relative to the deck on the client.
	--
	-- The rest of the body parts ride along via the template's existing
	-- Motor6Ds (Hip, Neck, Shoulder, ...). Those joints hold the default
	-- pose because no Animator tracks are loaded server-side. If a future
	-- SP costume floppy-rigs (e.g. a long coat with extra Motor6D-attached
	-- parts), add `WeldConstraint`s here from each body part to `hrp` to
	-- fully rigidify — for the current 15-part R15 rig, Motor6Ds suffice.
	local mountWeld = Instance.new("WeldConstraint")
	mountWeld.Name = "SecurityPersonnelMountWeld"
	mountWeld.Part0 = hrp
	mountWeld.Part1 = npcPos
	mountWeld.Parent = hrp

	self._mountsByShipmentId[shipmentId] = { model = clone, conn = nil }
end

--- Drop the cached mount entry and destroy the guard clone for
--- `shipmentId`. Safe to call when no mount exists (no-op). Called from
--- `OilShipmentService:_teardownShip` before `BoatDockService:CheckinBoat`
--- destroys the boat — the boat destruction would also kill the welded
--- clone (parented under the boat), but explicit cleanup keeps the table
--- bookkeeping accurate and lets us add tracking connections later
--- without revisiting every call site. The `entry.conn` Disconnect path
--- below is dormant today (mount uses a weld, not a Heartbeat) but stays
--- so a future revision that adds a connection has a working teardown.
function SecurityPersonnelService:UnmountForShipment(shipmentId: string)
	if typeof(shipmentId) ~= "string" or shipmentId == "" then
		return
	end
	local entry = self._mountsByShipmentId[shipmentId]
	if not entry then
		return
	end
	self._mountsByShipmentId[shipmentId] = nil
	if entry.conn then
		pcall(function()
			(entry.conn :: RBXScriptConnection):Disconnect()
		end)
	end
	if entry.model and entry.model.Parent then
		pcall(function()
			entry.model:Destroy()
		end)
	end
end

return SecurityPersonnelService
