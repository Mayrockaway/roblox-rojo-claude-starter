--!strict
--- Tunables for **rolling-session economics** and **dynamic Robux cash packs**.
--- Rolling rate = sum(netOrganic over last N sessions) / sum(sessionSeconds).

local SessionEconomicsConfig = {}

--- How many finished sessions we keep server-side (`economicsSessions` column).
SessionEconomicsConfig.MAX_SESSION_ROWS = 10

--- Rows shorter than this (seconds) are dropped — avoids join/leave flicker spam.
SessionEconomicsConfig.MIN_SESSION_SECONDS_TO_RECORD = 45

--- If we have fewer than this many **total tracked seconds** in history, blend
--- toward static fallbacks (`FALLBACK_NET_CASH_PER_HOUR` × blend with cash hint).
SessionEconomicsConfig.MIN_TOTAL_HISTORY_SECONDS_FOR_TRUSTED_RATE = (12 * 60)

--- Synthetic $/hour when profile has **no usable session rows** yet (fresh account).
SessionEconomicsConfig.FALLBACK_NET_CASH_PER_HOUR = 15_000

--- Floor / ceiling on the derived $/hour before pack math (sanity clamp).
SessionEconomicsConfig.MIN_NET_PER_HOUR = 1_500
SessionEconomicsConfig.MAX_NET_PER_HOUR = 2_500_000

--- Rough “wallet hint” multiplier so total cash nudges packs for players with
--- no history without letting pure balance dominate (exploit-resistant).
SessionEconomicsConfig.CASH_HINT_FRACTION = 0.00012
SessionEconomicsConfig.CASH_HINT_MAX = 420_000

--- Target **minutes-of-grind equivalency** per pack tier once $/hour is known.
--- Tuned alongside shop **R$49 / 149 / 299** (medium/large bumped vs prior 50/180 min).
SessionEconomicsConfig.PACK_TARGET_MINUTES = {
	small = 12,
	medium = 54,
	large = 200,
}

--- Final grant rounds to nearest `ROUND_TO` (must be ≥ 50 for Luau ints).
SessionEconomicsConfig.ROUND_TO = 500

SessionEconomicsConfig.PACK_HARD_MIN = {
	small = 3_500,
	medium = 15_000,
	large = 75_000,
}

SessionEconomicsConfig.PACK_HARD_MAX = {
	small = 175_000,
	medium = 750_000,
	large = 4_250_000,
}

return SessionEconomicsConfig
