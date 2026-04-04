--[[

	Ported LZAV version 5.8 (data format 3)

	LZAV in-memory data compression and decompression algorithms.

	Original C++/C source: https://github.com/avaneev/lzav
	Credits everything to the original author Aleksey Vaneev
	
	Usage:

		local input = buffer.fromstring('ABCABCABCABCABCBABCABCABCABC')
		
		local original_size = buffer.len(input)

		local compressed = compress(input)
		local decompressed = decompress(compressed, original_size)

		print('Original size:', original_size, 'bytes')
		print('Compressed size:', buffer.len(compressed), 'bytes')
	
]]

--!native
--!optimize 2
--!strict

local LZAV_LIT_FIN = 9
local LZAV_OFS_MIN = 8

local LZAV_OFS_TH1 = 1023
local LZAV_OFS_TH2 = 32767
local LZAV_MR5_THR = 262144
local LZAV_WIN_LEN = 2097152

local oms = table.freeze{0, 0x3FF, 0x7FFF, 0x1FFFFF}
local ocs = table.freeze{0, 0, 3, 5}
local cvs = table.freeze{0, 0, 7, 31}

local function lzav_match_len_r1(src: buffer, pointer1: number, pointer2: number, maximal: number): number
	if maximal == 1 then return 1 end

	local p1s = pointer1
	local p1e = pointer1 - maximal + 1

	pointer1 -= 1
	pointer2 -= 1

	while pointer1 > p1e do
		local v1 = buffer.readu16(src, pointer1 - 2)
		local v2 = buffer.readu16(src, pointer2 - 2)
		local vd = bit32.bxor(v1, v2)

		if vd ~= 0 then
			if bit32.btest(vd, 0xFF00) then
				return p1s - pointer1
			else
				return p1s - pointer1 + 1
			end
		end

		pointer1 -= 2
		pointer2 -= 2
	end

	if pointer1 == p1e and buffer.readu8(src, pointer1 - 1) ~= buffer.readu8(src, pointer2 - 1) then
		return p1s - pointer1
	end

	return maximal
end

local function compress(src: buffer): buffer
	local srclen = buffer.len(src)

	local l2 = srclen // 21

	local bounds = if srclen <= 0 then 16 else (srclen - l2 * 5 + 15) // 16 * 2 - l2 + srclen + 16

	local dst = buffer.create(bounds)
	local mref = if srclen < LZAV_MR5_THR then 5 else 6 

	buffer.writeu8(dst, 0, bit32.bor(0x30, mref))
	local op = 1

	if srclen < 16 then
		buffer.writeu8(dst, op, srclen)
		op += 1

		buffer.copy(dst, op, src, 0, srclen)
		op += srclen

		local r = buffer.create(op)
		buffer.copy(r, 0, dst, 0, op)

		return r
	end

	local htsize = 2048
	while htsize < (srclen * 4) and htsize < 1048576 do htsize *= 2 end

	local ht = buffer.create(htsize)

	local initv = buffer.readu32(src, 1)
	local filled = 0

	while filled < 16 and filled < htsize do
		buffer.writeu32(ht, filled, initv)
		buffer.writeu32(ht, filled + 4, 1)
		filled += 8
	end

	while filled < htsize do
		buffer.copy(ht, filled, ht, 0, filled)
		filled *= 2
	end

	local hmask = bit32.bxor(htsize - 1, 15)
	local ip = 1
	local ipe = srclen - LZAV_LIT_FIN
	local ipet = ipe - 15 + LZAV_LIT_FIN

	local ipa = 0

	local cbp = op
	local csh = 0

	local mavg = 100 * 131072

	local mref5 = mref == 5

	while ip < ipet do
		local iw1 = buffer.readu32(src, ip)
		local iw2 = if mref5 then buffer.readu8(src, ip + 4) else buffer.readu16(src, ip + 4)

		local Seed1 = bit32.bxor(0x243F6A88, iw1)
		local hval = bit32.bxor(0x85A308D3, iw2)

		local ah, al = hval // 65536, bit32.band(hval, 0xFFFF)
		local bh, bl = Seed1 // 65536, bit32.band(Seed1, 0xFFFF)

		hval = bit32.band(al * bl + (al * bh + ah * bl) * 65536, 0xFFFFFFFF)
		hval = bit32.rshift(hval, 12)

		local hp_offset = bit32.band(hval, hmask)

		local hw1 = buffer.readu32(ht, hp_offset)
		local wpo = -1
		local matched = false

		if iw1 ~= hw1 then
			if iw1 == buffer.readu32(ht, hp_offset + 8) then
				wpo = buffer.readu32(ht, hp_offset + 12)
				local ww2 = if mref5 then buffer.readu8(src, wpo + 4) else buffer.readu16(src, wpo + 4)
				if iw2 == ww2 then
					matched = true
				end
			end
		else
			wpo = buffer.readu32(ht, hp_offset + 4)
			local ww2 = if mref5 then buffer.readu8(src, wpo + 4) else buffer.readu16(src, wpo + 4)
			if iw2 == ww2 then
				matched = true
			else
				if iw1 == buffer.readu32(ht, hp_offset + 8) then
					wpo = buffer.readu32(ht, hp_offset + 12)
					ww2 = if mref5 then buffer.readu8(src, wpo + 4) else buffer.readu16(src, wpo + 4)
					if iw2 == ww2 then
						matched = true
					end
				end
			end
		end

		local is_oob = false

		if matched then
			local d = ip - wpo
			local ml = ipe - ip

			if d < LZAV_OFS_MIN then
				is_oob = true
			else
				if d > 31 then
					if iw1 == hw1 then
						buffer.writeu32(ht, hp_offset + 4, ip)
					else
						buffer.writeu32(ht, hp_offset + 8, hw1)
						buffer.writeu32(ht, hp_offset + 12, buffer.readu32(ht, hp_offset + 4))
						buffer.writeu32(ht, hp_offset, iw1)
						buffer.writeu32(ht, hp_offset + 4, ip)
					end
				end

				local rc = ml
				local match_offset = 0
				local found_diff = false

				while match_offset + 3 < ml do
					local v1 = buffer.readu32(src, ip + match_offset)
					local v2 = buffer.readu32(src, wpo + match_offset)
					local vd = bit32.bxor(v1, v2)
					if vd ~= 0 then
						rc = match_offset + bit32.countrz(vd) // 8
						found_diff = true
						break
					end
					match_offset += 4
				end

				if not found_diff then
					while match_offset < ml do
						if buffer.readu8(src, ip + match_offset) ~= buffer.readu8(src, wpo + match_offset) then
							rc = match_offset
							break
						end
						match_offset += 1
					end
				end

				local ip0 = ip
				local lc = ip - ipa

				if lc ~= 0 and buffer.readu8(src, ip - 1) == buffer.readu8(src, wpo - 1) then
					local bl = if lc > wpo then wpo else lc
					local mlb = lzav_match_len_r1(src, ip, wpo, bl)
					lc -= mlb
					rc += mlb
					ip -= mlb
				end

				local win_limit = LZAV_WIN_LEN * bit32.lshift(1, csh)
				if lc ~= 0 then win_limit *= 4 end

				if d < win_limit then
					local iw1n = buffer.readu32(src, ip0 + 2)
					local iw2n = if mref5 then buffer.readu8(src, ip0 + 6) else buffer.readu16(src, ip0 + 6)

					local S1n, hvn = bit32.bxor(0x243F6A88, iw1n), bit32.bxor(0x85A308D3, iw2n)
					local ahn, aln, bhn, bln = bit32.rshift(hvn, 16), bit32.band(hvn, 0xFFFF), bit32.rshift(S1n, 16), bit32.band(S1n, 0xFFFF)

					hvn = bit32.band((aln * bln) + bit32.lshift(aln * bhn + ahn * bln, 16), 0xFFFFFFFF)
					hvn = bit32.rshift(hvn, 12)

					local hpn = bit32.band(hvn, hmask)

					mavg -= mavg // 1024

					buffer.writeu32(ht, hpn + 8, buffer.readu32(ht, hpn))
					buffer.writeu32(ht, hpn + 12, buffer.readu32(ht, hpn + 4))
					buffer.writeu32(ht, hpn, iw1n)
					buffer.writeu32(ht, hpn + 4, ip0 + 2)

					ip += rc

					local rc_w = rc + 1 - mref
					local dc = bit32.band(bit32.rshift(bit32.lshift(d, 8), csh), 0xFF)
					local d_w = bit32.rshift(d, csh)

					buffer.writeu8(dst, cbp, bit32.bor(buffer.readu8(dst, cbp), dc))

					if lc ~= 0 then
						local cv = bit32.lshift(d_w, 6)
						d_w = bit32.rshift(d_w, 2)

						if lc < 9 then
							buffer.writeu8(dst, op, bit32.bor(bit32.band(cv, 0xFF), lc))
							buffer.copy(dst, op + 1, src, ipa, 8)
							op += lc + 1
						elseif lc < 16 then
							buffer.writeu8(dst, op, bit32.bor(bit32.band(cv, 0xFF), lc))
							buffer.copy(dst, op + 1, src, ipa, 16)
							op += lc + 1
						elseif lc < 33 then
							local ov = bit32.bor(bit32.lshift(lc - 16, 8), bit32.band(cv, 0xFF))
							buffer.writeu16(dst, op, ov)
							buffer.copy(dst, op + 2, src, ipa, 16)
							buffer.copy(dst, op + 18, src, ipa + 16, 16)
							op += lc + 2
						else
							buffer.writeu8(dst, op, bit32.band(cv, 0xFF))
							local lcw = lc - 16
							while lcw > 127 do
								buffer.writeu8(dst, op + 1, bit32.bor(0x80, bit32.band(lcw, 0x7F)))
								lcw = bit32.rshift(lcw, 7)
								op += 1
							end
							buffer.writeu8(dst, op + 1, lcw)
							op += 2
							buffer.copy(dst, op, src, ipa, lc)
							op += lc
						end
					end

					local bt = 1
					if d_w > LZAV_OFS_TH1 then bt += 1 end
					if d_w > LZAV_OFS_TH2 then bt += 1 end

					local ov = bit32.bor(bit32.lshift(d_w, 6), bit32.lshift(bt, 4))
					local opbt = op + bt

					csh = ocs[bt + 1]
					cbp = opbt

					if rc_w < 16 then
						buffer.writeu32(dst, op, bit32.bor(ov, rc_w))
						op = opbt + 1
					else
						rc_w -= 16
						buffer.writeu32(dst, op, ov)

						if rc_w < 128 then
							buffer.writeu8(dst, opbt + 1, rc_w)
							op = opbt + 2
						else
							repeat
								buffer.writeu8(dst, opbt + 1, bit32.bor(0x80, bit32.band(rc_w, 0x7F)))
								rc_w = bit32.rshift(rc_w, 7)
								opbt += 1
							until rc_w <= 127

							buffer.writeu8(dst, opbt + 1, rc_w)
							op = opbt + 2
						end
					end

					ipa = ip
					mavg += rc * 128

					continue
				else
					ip = ip0
					is_oob = true
				end
			end
		end

		if is_oob then
			ip += 1
			continue
		end

		local wp = ip
		buffer.writeu32(ht, hp_offset + 8, iw1)
		mavg -= mavg // 2048
		ip += 1
		buffer.writeu32(ht, hp_offset + 12, ip - 1)

		if mavg < 204800 and wp ~= ipa then
			ip += 1 + bit32.band(ip - 1, 1)
			if mavg < 133120 then
				ip += 1
				if mavg < 102400 then
					ip += 100 - (mavg // 1024)
				end
			end
		end
	end

	local lc = srclen - ipa

	local lcw = lc
	if lc > 15 then
		buffer.writeu8(dst, op, 0)
		op += 1
		lcw -= 16
		while lcw > 127 do
			buffer.writeu8(dst, op, bit32.bor(0x80, bit32.band(lcw, 0x7F)))
			lcw = bit32.rshift(lcw, 7)
			op += 1
		end
	end

	buffer.writeu8(dst, op, lcw)
	op += 1

	buffer.copy(dst, op, src, ipa, lc)
	op += lc

	local result = buffer.create(op)
	buffer.copy(result, 0, dst, 0, op)
	return result
end

local function decompress(src: buffer, dstlen: number): buffer
	assert(type(src) == 'buffer' and type(dstlen) == 'number', 'PARAMS: Incorrect function parameters.')

	local srclen = buffer.len(src)
	assert(srclen >= 10, 'SRCOOB: Source buffer out-of-bounds error.')

	local dst = buffer.create(dstlen)

	local prefix = buffer.readu8(src, 0)
	local fmt = bit32.rshift(prefix, 4)
	local mref = bit32.band(prefix, 15)

	local ip = 1
	local op = 0

	assert(fmt == 3 and (mref == 5 or mref == 6), 'UNKFMT: Unknown data format or mref error.')

	local mref1 = mref - 1
	local cv = 0
	local csh = 0

	local ipet = srclen - 9
	local ipe = srclen

	local bh = buffer.readu8(src, ip)

	while ip < ipet do
		if bit32.btest(bh, 0x30) then
			local btype = bit32.band(bit32.rshift(bh, 4), 3)
			ip += 1
			local bv = buffer.readu32(src, ip)

			local bt8 = btype * 8
			local ncsh = ocs[btype + 1]

			local x = bit32.band(bit32.bor(bit32.rshift(bh, 6), bit32.lshift(bv, 2)), oms[btype + 1])
			local d = bit32.bor(bit32.lshift(x, csh), cv)
			cv = bit32.band(bit32.rshift(bv, bt8 - ncsh), cvs[btype + 1])
			csh = ncsh
			ip += btype

			bv = bit32.rshift(bv, bt8)

			local rc = bit32.band(bh, 15)
			if rc ~= 0 then
				bh = bit32.band(bv, 0xFF)
			else
				bh = bit32.band(bv, 0xFF)
				ip += 1
				rc = 16 + bit32.band(bh, 0x7F)
				if bit32.btest(bh, 0x80) then
					local sh = 7
					repeat
						bh = buffer.readu8(src, ip)
						ip += 1
						rc += bit32.lshift(bit32.band(bh, 0x7F), sh)
						sh += 7
					until not bit32.btest(bh, 0x80)
				end
				bh = buffer.readu8(src, ip)
			end

			local cc = rc + mref1
			local ipd_offset = op - d

			if ipd_offset < 0 or op + cc > dstlen then
				return error'DSTOOB: Destination buffer out-of-bounds error.'
			end

			if d >= cc then
				buffer.copy(dst, op, dst, ipd_offset, cc)
			elseif d >= 8 then
				buffer.copy(dst, op, dst, ipd_offset, d)
				local written = d
				while written < cc do
					local n = if cc - written < written then cc - written else written
					buffer.copy(dst, op + written, dst, op, n)
					written += n
				end
			elseif d == 1 then
				buffer.fill(dst, op, buffer.readu8(dst, ipd_offset), cc)
			else
				for k = 0, cc - 1 do
					buffer.writeu8(dst, op + k, buffer.readu8(dst, ipd_offset + k))
				end
			end
			op += cc
		else
			local ncv = bit32.rshift(bh, 6)
			ip += 1
			local cc = bit32.band(bh, 15)

			cv = bit32.bor(cv, bit32.lshift(ncv, csh))
			csh += 2

			if cc == 0 then
				bh = buffer.readu8(src, ip)
				ip += 1
				cc = bit32.band(bh, 0x7F)
				if bit32.btest(bh, 0x80) then
					local sh = 7
					repeat
						bh = buffer.readu8(src, ip)
						ip += 1
						cc += bit32.lshift(bit32.band(bh, 0x7F), sh)
						sh += 7
					until not bit32.btest(bh, 0x80)
				end
				cc += 16
			end

			if op + cc > dstlen then
				error'DSTOOB: Destination buffer out-of-bounds error.'
			end

			buffer.copy(dst, op, src, ip, cc)
			op += cc
			ip += cc

			if ip < ipe then
				bh = buffer.readu8(src, ip)
			end
		end
	end

	assert(op == dstlen, 'DSTLEN: Decompressed length mismatch error.')

	return dst
end

return {
	compress = compress,
	decompress = decompress,
}