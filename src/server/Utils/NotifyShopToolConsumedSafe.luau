--!strict
-- Defensive bridge: some Studio copies lag Rojo and lack OilStateService:NotifyShopToolConsumed.

local warnedMissing = false

local function tryCall(oilStateService: any, userId: number, itemId: string, context: string)
	local fn = oilStateService.NotifyShopToolConsumed
	if typeof(fn) == "function" then
		fn(oilStateService, userId, itemId)
		return
	end
	if not warnedMissing then
		warnedMissing = true
		warn(
			"[NotifyShopToolConsumedSafe] OilStateService.NotifyShopToolConsumed missing — sync Rojo / OilStateService. Context: "
				.. context
		)
	end
end

return {
	tryCall = tryCall,
}
