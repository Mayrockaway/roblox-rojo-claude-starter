--!strict
-- `ShipOilPanel` / `SellOilPanel` notify `FtueUiPointers` when modal visibility or barrel selections change
-- (no dependency cycle: panel → this module → deferred subscribers only).

local listeners: { () -> () } = {}

local FtueDispatchPointerSignals = {}

function FtueDispatchPointerSignals.subscribeRefresh(fn: () -> ())
	table.insert(listeners, fn)
end

local function notify()
	for _, f in ipairs(listeners) do
		task.defer(f)
	end
end

function FtueDispatchPointerSignals.fireDispatchShipOilUiChanged()
	notify()
end

function FtueDispatchPointerSignals.fireSellOilUiChanged()
	notify()
end

return FtueDispatchPointerSignals
