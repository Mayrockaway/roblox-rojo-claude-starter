--!strict
--[[
    HmacSha256 — pure-Luau SHA-256 + HMAC-SHA256.

    Why this lives in a Vendor/ folder (which is otherwise discouraged in
    this repo):
      Roblox ships no native HMAC-SHA256, and `HttpService:GetSecret`'s
      `Secret` userdata is intentionally non-extractable so it cannot be
      fed into HMAC. The GameAnalytics REST v2 protocol mandates an
      HMAC-SHA256 signature over the request body in the `Authorization`
      header — see `docs/features/telemetry/SPEC.md` §4.6.3. The repo's
      standard "no third-party code" pattern explicitly carves out a
      `src/shared/Vendor/` exception for cases like this; see SPEC §3.3.

    Where it's used:
      Required by `Shared.Telemetry.GameAnalyticsAdapter` (PR 4 of the
      telemetry SPEC) to sign POST bodies sent to
      `https://api.gameanalytics.com/v2/<game_key>/events`. Do not
      `require` this module from any other consumer — keep the blast
      radius small.

    Implementation:
      Original implementation against FIPS 180-4 (SHA-256) and RFC 2104
      (HMAC). Pure Luau — only depends on the Roblox-provided `bit32`
      library (no Roblox-specific globals, so it stays unit-testable).
      Verified against RFC 4231 test vectors 1 and 2 — see
      `tests/HmacSha256.spec.luau`.

    Public API:
      HmacSha256.HmacBase64(key: string, message: string): string
        Standard base64 (NOT URL-safe), `=`-padded. The form
        GameAnalytics expects in the `Authorization` header.

      HmacSha256.HmacHex(key: string, message: string): string
        Lowercase hex. Convenient for unit tests and debugging.
]]

local HmacSha256 = {}

-- =========================================================================
-- internal: SHA-256 (FIPS 180-4)
-- =========================================================================

-- Round constants K[0..63] — first 32 bits of the fractional parts of the
-- cube roots of the first 64 primes. Stored 1-indexed for Lua ergonomics.
local K: { number } = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Initial hash values H0..H7 — first 32 bits of the fractional parts of
-- the square roots of the first 8 primes.
local H_INIT: { number } = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local BLOCK_SIZE = 64 -- bytes (512 bits) per SHA-256 / HMAC block
local DIGEST_SIZE = 32 -- bytes (256 bits) of SHA-256 output
local MASK32 = 0xffffffff

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local rrotate = bit32.rrotate

local function readUInt32BE(s: string, offset: number): number
	-- offset is 1-based; reads 4 bytes starting at offset, big-endian.
	local b1, b2, b3, b4 = string.byte(s, offset, offset + 3)
	return bor(
		lshift((b1 :: number), 24),
		lshift((b2 :: number), 16),
		lshift((b3 :: number), 8),
		(b4 :: number)
	)
end

local function uint32ToBytesBE(n: number): string
	return string.char(
		band(rshift(n, 24), 0xff),
		band(rshift(n, 16), 0xff),
		band(rshift(n, 8), 0xff),
		band(n, 0xff)
	)
end

local function preprocess(message: string): string
	-- FIPS 180-4 §5.1.1: append 0x80, then zero-pad so that the final
	-- length (after the 8-byte length suffix) is a multiple of 64 bytes.
	local L = #message
	local bitLen = L * 8

	local zeros = (56 - (L + 1) % 64) % 64
	-- 64-bit big-endian message length in bits.
	-- Roblox/Luau numbers are doubles; messages > 2^53 bits aren't a
	-- realistic input here, but we still split high/low correctly.
	local high = math.floor(bitLen / 0x100000000)
	local low = bitLen - high * 0x100000000

	return message
		.. string.char(0x80)
		.. string.rep("\0", zeros)
		.. uint32ToBytesBE(high)
		.. uint32ToBytesBE(low)
end

local function sha256_block(W: { number }, H: { number })
	-- Extend the first 16 words of the message schedule into 64 words.
	for t = 17, 64 do
		local w15 = W[t - 15]
		local w2 = W[t - 2]
		local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
		local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
		W[t] = band(W[t - 16] + s0 + W[t - 7] + s1, MASK32)
	end

	local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

	for t = 1, 64 do
		local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
		local ch = bxor(band(e, f), band(bnot(e), g))
		local temp1 = band(h + S1 + ch + K[t] + W[t], MASK32)
		local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
		local maj = bxor(band(a, b), band(a, c), band(b, c))
		local temp2 = band(S0 + maj, MASK32)

		h = g
		g = f
		f = e
		e = band(d + temp1, MASK32)
		d = c
		c = b
		b = a
		a = band(temp1 + temp2, MASK32)
	end

	H[1] = band(H[1] + a, MASK32)
	H[2] = band(H[2] + b, MASK32)
	H[3] = band(H[3] + c, MASK32)
	H[4] = band(H[4] + d, MASK32)
	H[5] = band(H[5] + e, MASK32)
	H[6] = band(H[6] + f, MASK32)
	H[7] = band(H[7] + g, MASK32)
	H[8] = band(H[8] + h, MASK32)
end

local function sha256_raw(message: string): string
	local padded = preprocess(message)
	local H = table.clone(H_INIT)
	local W: { number } = table.create(64, 0)

	local n = #padded
	for blockStart = 1, n, BLOCK_SIZE do
		for i = 1, 16 do
			W[i] = readUInt32BE(padded, blockStart + (i - 1) * 4)
		end
		sha256_block(W, H)
	end

	return uint32ToBytesBE(H[1])
		.. uint32ToBytesBE(H[2])
		.. uint32ToBytesBE(H[3])
		.. uint32ToBytesBE(H[4])
		.. uint32ToBytesBE(H[5])
		.. uint32ToBytesBE(H[6])
		.. uint32ToBytesBE(H[7])
		.. uint32ToBytesBE(H[8])
end

-- =========================================================================
-- internal: HMAC (RFC 2104)
-- =========================================================================

local function hmac_sha256_raw(key: string, message: string): string
	-- Per RFC 2104: keys longer than the block size are first hashed.
	if #key > BLOCK_SIZE then
		key = sha256_raw(key)
	end
	-- Right-pad with zero bytes to BLOCK_SIZE (the short-key path —
	-- RFC 4231 test case 2 ("Jefe") exercises this branch).
	if #key < BLOCK_SIZE then
		key = key .. string.rep("\0", BLOCK_SIZE - #key)
	end

	local ipadBytes: { string } = table.create(BLOCK_SIZE)
	local opadBytes: { string } = table.create(BLOCK_SIZE)
	for i = 1, BLOCK_SIZE do
		local b = string.byte(key, i) :: number
		ipadBytes[i] = string.char(bxor(b, 0x36))
		opadBytes[i] = string.char(bxor(b, 0x5c))
	end
	local ipad = table.concat(ipadBytes)
	local opad = table.concat(opadBytes)

	local inner = sha256_raw(ipad .. message)
	return sha256_raw(opad .. inner)
end

-- =========================================================================
-- internal: hex + base64 encoders
-- =========================================================================

local function hex_encode(s: string): string
	local out: { string } = table.create(#s)
	for i = 1, #s do
		out[i] = string.format("%02x", string.byte(s, i) :: number)
	end
	return table.concat(out)
end

-- Standard base64 alphabet (RFC 4648 §4) — NOT the URL-safe variant.
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(s: string): string
	local n = #s
	local out: { string } = {}
	local outIndex = 0
	local i = 1
	while i <= n do
		local b1 = string.byte(s, i) or 0
		local b2 = string.byte(s, i + 1) or 0
		local b3 = string.byte(s, i + 2) or 0

		local n1 = rshift(b1, 2)
		local n2 = bor(lshift(band(b1, 0x03), 4), rshift(b2, 4))
		local n3 = bor(lshift(band(b2, 0x0f), 2), rshift(b3, 6))
		local n4 = band(b3, 0x3f)

		outIndex += 1
		out[outIndex] = string.sub(BASE64_ALPHABET, n1 + 1, n1 + 1)
		outIndex += 1
		out[outIndex] = string.sub(BASE64_ALPHABET, n2 + 1, n2 + 1)
		outIndex += 1
		out[outIndex] = if i + 1 > n then "=" else string.sub(BASE64_ALPHABET, n3 + 1, n3 + 1)
		outIndex += 1
		out[outIndex] = if i + 2 > n then "=" else string.sub(BASE64_ALPHABET, n4 + 1, n4 + 1)

		i += 3
	end
	return table.concat(out)
end

-- =========================================================================
-- public surface
-- =========================================================================

function HmacSha256.HmacHex(key: string, message: string): string
	local raw = hmac_sha256_raw(key, message)
	assert(#raw == DIGEST_SIZE, "internal: HMAC digest length mismatch")
	return hex_encode(raw)
end

function HmacSha256.HmacBase64(key: string, message: string): string
	local raw = hmac_sha256_raw(key, message)
	assert(#raw == DIGEST_SIZE, "internal: HMAC digest length mismatch")
	return base64_encode(raw)
end

return HmacSha256
