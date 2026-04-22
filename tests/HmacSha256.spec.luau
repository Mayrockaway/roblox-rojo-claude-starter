--!strict
--[[
    Unit tests for `ReplicatedStorage.Shared.Vendor.HmacSha256`.

    Test vectors: RFC 4231 cases 1 and 2 (canonical HMAC-SHA256).

    -------------------------------------------------------------------------
    HOW TO RUN
    -------------------------------------------------------------------------
    `tests/` is NOT mapped into Studio by the current `default.project.json`
    (only `src/shared/`, `src/server/`, `src/client/`, `src/replicated_first/`
    sync). So you cannot `require` this file directly through Rojo. Two
    options:

      A. Paste this file's contents into the Studio Command Bar wholesale
         and hit enter — it self-executes and prints `[HmacSha256] OK`
         on success or `error()`s on failure.

      B. Drop this file into the place as a ModuleScript at, e.g.,
         `ServerStorage.Tests.HmacSha256_spec`, then in the Command Bar:

             require(game:GetService("ServerStorage")
                 :WaitForChild("Tests"):WaitForChild("HmacSha256_spec"))

    Either way, `HmacSha256` itself is loaded from its synced location:
    `ReplicatedStorage.Shared.Vendor.HmacSha256`.

    Note: this file is intentionally self-contained and idempotent — it
    runs all assertions on require and returns `true` on success.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HmacSha256 = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Vendor"):WaitForChild("HmacSha256")
) :: {
	HmacHex: (key: string, message: string) -> string,
	HmacBase64: (key: string, message: string) -> string,
}

local function expect(actual: string, expected: string, label: string)
	if actual ~= expected then
		error(
			string.format(
				"[HmacSha256] %s mismatch:\n  expected: %s\n  actual:   %s",
				label,
				expected,
				actual
			),
			0
		)
	end
end

-- -------------------------------------------------------------------------
-- RFC 4231 test case 1 — 20 bytes of 0x0b keying "Hi There".
-- -------------------------------------------------------------------------
do
	local key = string.rep(string.char(0x0b), 20)
	local data = "Hi There"
	local expectedHex = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
	local expectedB64 = "sDRMYdjbOFNcqK/OrwvxK4gdwgDJgz2nJuk3bC4yz/c="

	expect(HmacSha256.HmacHex(key, data), expectedHex, "RFC 4231 case 1 hex")
	expect(HmacSha256.HmacBase64(key, data), expectedB64, "RFC 4231 case 1 base64")
end

-- -------------------------------------------------------------------------
-- RFC 4231 test case 2 — short key path ("Jefe" is 4 bytes, exercises the
-- right-pad-with-zeros branch in the HMAC construction).
-- -------------------------------------------------------------------------
do
	local key = "Jefe"
	local data = "what do ya want for nothing?"
	local expectedHex = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
	-- Note: the canonical base64 of the case-2 digest starts "W9zB..." (the
	-- raw first byte is 0x5b → 6-bit group 010110 → 'W'). Cross-checked
	-- against Python's stdlib `hmac` / `base64` for both RFC 4231 vectors.
	local expectedB64 = "W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM="

	expect(HmacSha256.HmacHex(key, data), expectedHex, "RFC 4231 case 2 hex")
	expect(HmacSha256.HmacBase64(key, data), expectedB64, "RFC 4231 case 2 base64")
end

print("[HmacSha256] OK — RFC 4231 cases 1 and 2 pass (hex + base64).")

return true
