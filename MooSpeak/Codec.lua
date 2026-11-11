--[[
MooSpeak codec: hides text inside "moo" words.

Pure Lua 5.1 with no WoW API use, so it runs unchanged in every client
flavor and in the offline test suite.

Pipeline for one chat line:

  1. The text is split into SEGMENTS (runs of letters/digits/UTF-8 and the
     spaces, apostrophes and hyphens between them) and SEPARATORS
     (punctuation, links, raid markers). Separators are copied to the
     output untouched, so punctuation stays where the player typed it.
  2. Each segment is compressed to bits with a fixed Huffman code over
     letters, digits, common chat words and a few control symbols.
     The first segment also carries a 12-bit checksum of the whole line.
  3. The bits are spent on moo words. Each word is 1-4 M's followed by
     2-6 O's, and the letter count and the case pattern of each run are
     read from the bits with prefix codes that make lowercase and short
     runs the most likely, so the output still reads like mooing.

Decoding reverses this, then re-encodes the result and requires an exact
match, plus a matching checksum. That rejects hand-typed moos and
anything altered in transit.

Changing ANY table in this file changes the wire format; bump
VERSION_SEED when you do so old and new clients reject each other's
lines instead of showing garbage.
]]

local _, ns = ...
ns = ns or {}

local Codec = {}
ns.Codec = Codec

local byte, char, sub, find, lower, upper, gmatch =
	string.byte, string.char, string.sub, string.find, string.lower, string.upper, string.gmatch
local floor = math.floor
local concat = table.concat

Codec.MAX_LINE_BYTES = 255
local CHECK_BITS = 12
local VERSION_SEED = "MooSpeak/1"

---------------------------------------------------------------------------
-- Text model: symbols and their relative frequencies
---------------------------------------------------------------------------

local symbols = {} -- index -> { text = string|nil, weight = number }

local function addSymbol(text, weight)
	symbols[#symbols + 1] = { text = text, weight = weight }
	return #symbols
end

local EOS = addSymbol(nil, 30)   -- end of segment
local SHIFT = addSymbol(nil, 20) -- invert the case of the next letter
local CAPS = addSymbol(nil, 4)   -- toggle caps lock
local ESC = addSymbol(nil, 2)    -- next 8 bits are a raw byte

local charSymbol = {} -- single character -> symbol index

local CHAR_WEIGHTS = {
	{ " ", 170 },
	{ "e", 95 }, { "t", 70 }, { "a", 65 }, { "o", 65 }, { "i", 60 }, { "n", 55 },
	{ "s", 52 }, { "r", 48 }, { "h", 45 }, { "l", 33 }, { "d", 33 }, { "u", 25 },
	{ "c", 22 }, { "m", 22 }, { "y", 18 }, { "w", 18 }, { "f", 17 }, { "g", 17 },
	{ "p", 15 }, { "b", 12 }, { "k", 8 }, { "v", 8 }, { "j", 2 }, { "x", 2 },
	{ "q", 1 }, { "z", 1 },
	{ "0", 4 }, { "1", 4 }, { "2", 3 }, { "3", 2 }, { "4", 2 },
	{ "5", 2 }, { "6", 1 }, { "7", 1 }, { "8", 1 }, { "9", 1 },
	{ "'", 4 }, { "-", 2 },
}
for _, cw in ipairs(CHAR_WEIGHTS) do
	charSymbol[cw[1]] = addSymbol(cw[1], cw[2])
end

-- Common chat words get their own symbols. Lowercase only; case is
-- applied from the caps/shift state when decoding.
local COMMON_WORDS = {
	"the", "you", "to", "and", "is", "it", "that", "for", "in", "of", "me",
	"my", "i'm", "we", "can", "need", "lfg", "tank", "heal", "dps", "run",
	"want", "just", "what", "this", "are", "have", "with", "anyone", "ok",
	"lol",
}
local OTHER_WORDS = {
	"on", "be", "do", "don't", "i'll", "it's", "can't", "but", "get", "got",
	"so", "if", "no", "yes", "thanks", "thx", "please", "pls", "now", "here",
	"there", "they", "them", "all", "one", "out", "up", "how", "why", "who",
	"where", "when", "like", "know", "going", "will", "would", "could",
	"should", "about", "from", "your", "has", "had", "some", "more", "time",
	"good", "nice", "back", "guild", "dungeon", "raid", "boss", "quest",
	"gold", "sell", "buy", "wts", "wtb", "invite", "inv", "whisper", "level",
	"gear", "drop", "help", "sorry", "brb", "afk", "ty", "np", "gg", "hello",
	"hey", "hi", "gonna", "still", "then", "than", "been", "also", "only",
	"really", "think", "see", "go", "too", "at", "or", "as", "by", "an", "he",
	"she", "his", "her", "our", "us", "moo", "lfm", "healer", "group", "not",
	"was", "any", "tonight", "today", "right", "wait", "ready", "pull",
	"thank", "kill", "mob", "mobs", "mana", "need", "greed", "loot",
}

local wordSymbol = {} -- word -> symbol index
local function addWords(list, weight)
	for _, w in ipairs(list) do
		if not wordSymbol[w] then
			wordSymbol[w] = addSymbol(w, weight)
		end
	end
end
addWords(COMMON_WORDS, 12)
addWords(OTHER_WORDS, 5)

-- Candidate words grouped by first letter, longest first.
local wordsByFirst = {}
for w in pairs(wordSymbol) do
	local first = sub(w, 1, 1)
	wordsByFirst[first] = wordsByFirst[first] or {}
	table.insert(wordsByFirst[first], w)
end
for _, list in pairs(wordsByFirst) do
	table.sort(list, function(a, b)
		if #a ~= #b then return #a > #b end
		return a < b
	end)
end

---------------------------------------------------------------------------
-- Canonical Huffman code (deterministic: ties break on symbol order)
---------------------------------------------------------------------------

local codes = {}     -- symbol index -> array of bits
local decodeTree = {} -- binary trie: node[0], node[1], node.sym

do
	local nodes = {}
	for i, s in ipairs(symbols) do
		nodes[i] = { w = s.weight, order = i, sym = i }
	end
	local nextOrder = #symbols
	local function lighter(a, b)
		if a.w ~= b.w then return a.w < b.w end
		return a.order < b.order
	end
	while #nodes > 1 do
		table.sort(nodes, lighter)
		local a = table.remove(nodes, 1)
		local b = table.remove(nodes, 1)
		nextOrder = nextOrder + 1
		nodes[#nodes + 1] = { w = a.w + b.w, order = nextOrder, left = a, right = b }
	end

	local lengths = {}
	local function walk(node, depth)
		if node.sym then
			lengths[node.sym] = depth > 0 and depth or 1
		else
			walk(node.left, depth + 1)
			walk(node.right, depth + 1)
		end
	end
	walk(nodes[1], 0)

	local order = {}
	for i = 1, #symbols do order[i] = i end
	table.sort(order, function(x, y)
		if lengths[x] ~= lengths[y] then return lengths[x] < lengths[y] end
		return x < y
	end)

	local code, prevLen = 0, lengths[order[1]]
	for k, s in ipairs(order) do
		local len = lengths[s]
		if k > 1 then
			code = (code + 1) * 2 ^ (len - prevLen)
		end
		prevLen = len
		local bits, c = {}, code
		for j = len, 1, -1 do
			bits[j] = c % 2
			c = floor(c / 2)
		end
		codes[s] = bits

		local node = decodeTree
		for j = 1, len do
			local b = bits[j]
			node[b] = node[b] or {}
			node = node[b]
		end
		node.sym = s
	end
end

---------------------------------------------------------------------------
-- Bit helpers
---------------------------------------------------------------------------

local function pushBits(out, bits)
	for i = 1, #bits do
		out[#out + 1] = bits[i]
	end
end

local function pushNumber(out, value, width)
	for j = width - 1, 0, -1 do
		out[#out + 1] = floor(value / 2 ^ j) % 2
	end
end

local function readNumber(bits, pos, width)
	local v = 0
	for i = pos, pos + width - 1 do
		local b = bits[i]
		if b == nil then return nil end
		v = v * 2 + b
	end
	return v, pos + width
end

---------------------------------------------------------------------------
-- Text <-> bits
---------------------------------------------------------------------------

local function isUpper(c) return c >= "A" and c <= "Z" end
local function isLetter(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") end

local function emit(out, sym)
	pushBits(out, codes[sym])
end

-- Bits needed to spell `piece` letter by letter in the given caps mode.
local function spellCost(piece, caps)
	local cost = 0
	for j = 1, #piece do
		local c = sub(piece, j, j)
		if isLetter(c) then
			cost = cost + #codes[charSymbol[lower(c)]]
			if isUpper(c) ~= caps then
				cost = cost + #codes[SHIFT]
			end
		else
			cost = cost + #codes[charSymbol[c]]
		end
	end
	return cost
end

-- If `piece` can be produced by a word symbol in this caps mode, returns
-- whether a SHIFT is needed in front of it; otherwise nil.
local function wordShift(piece, caps)
	local shift = isUpper(sub(piece, 1, 1)) ~= caps
	for j = 2, #piece do
		local c = sub(piece, j, j)
		if isLetter(c) and isUpper(c) ~= caps then
			return nil
		end
	end
	return shift
end

local function encodeText(s, out)
	local caps = false
	local i, n = 1, #s
	while i <= n do
		local c = sub(s, i, i)
		if isLetter(c) then
			-- Caps lock only changes at the start of a run of letters.
			if i == 1 or not isLetter(sub(s, i - 1, i - 1)) then
				local runEnd = select(2, find(s, "^%a+", i))
				local run = sub(s, i, runEnd)
				if not caps and #run >= 2 and not find(run, "%l") then
					emit(out, CAPS)
					caps = true
				elseif caps and find(run, "%l") then
					emit(out, CAPS)
					caps = false
				end
			end

			local bestWord, bestShift, bestSaving = nil, nil, 0
			local candidates = wordsByFirst[lower(c)]
			if candidates then
				for _, w in ipairs(candidates) do
					local piece = sub(s, i, i + #w - 1)
					if #piece == #w and lower(piece) == w then
						local shift = wordShift(piece, caps)
						if shift ~= nil then
							local cost = #codes[wordSymbol[w]] + (shift and #codes[SHIFT] or 0)
							local saving = spellCost(piece, caps) - cost
							if saving > bestSaving then
								bestWord, bestShift, bestSaving = w, shift, saving
							end
						end
					end
				end
			end

			if bestWord then
				if bestShift then emit(out, SHIFT) end
				emit(out, wordSymbol[bestWord])
				i = i + #bestWord
			else
				if isUpper(c) ~= caps then emit(out, SHIFT) end
				emit(out, charSymbol[lower(c)])
				i = i + 1
			end
		else
			local sym = charSymbol[c]
			if sym then
				emit(out, sym)
			else
				emit(out, ESC)
				pushNumber(out, byte(c), 8)
			end
			i = i + 1
		end
	end
	emit(out, EOS)
end

-- Decodes one segment starting at bits[pos]. Returns text, nextPos or nil.
local function decodeText(bits, pos)
	local caps, shift = false, false
	local out = {}
	while true do
		local node = decodeTree
		while node.sym == nil do
			local b = bits[pos]
			if b == nil then return nil end
			node = node[b]
			pos = pos + 1
		end
		local sym = node.sym

		if sym == EOS then
			if shift then return nil end
			return concat(out), pos
		elseif sym == SHIFT then
			if shift then return nil end
			shift = true
		elseif sym == CAPS then
			if shift then return nil end
			caps = not caps
		elseif sym == ESC then
			if shift then return nil end
			local v
			v, pos = readNumber(bits, pos, 8)
			if not v then return nil end
			out[#out + 1] = char(v)
		else
			local text = symbols[sym].text
			local first = sub(text, 1, 1)
			if shift and not isLetter(first) then return nil end
			for j = 1, #text do
				local c = sub(text, j, j)
				if isLetter(c) then
					local up = caps
					if shift then
						up = not up
						shift = false
					end
					c = up and upper(c) or c
				end
				out[#out + 1] = c
			end
		end
	end
end

---------------------------------------------------------------------------
-- Moo words <-> bits
---------------------------------------------------------------------------

-- Prefix codes for run lengths. Shorter runs are more likely.
local M_COUNT = { { "0", 1 }, { "10", 2 }, { "110", 3 }, { "111", 4 } }
local O_COUNT = { { "00", 2 }, { "01", 3 }, { "10", 4 }, { "110", 5 }, { "111", 6 } }
local MAX_RUN = 6

-- casePatterns[n][k] = ascending list of n-bit masks with k bits set;
-- maskIndex[n][mask] = zero-based position of mask in its list.
local casePatterns, maskIndex = {}, {}
for n = 1, MAX_RUN do
	casePatterns[n], maskIndex[n] = {}, {}
	for k = 0, n do casePatterns[n][k] = {} end
	for mask = 0, 2 ^ n - 1 do
		local k, m = 0, mask
		while m > 0 do
			k = k + m % 2
			m = floor(m / 2)
		end
		local list = casePatterns[n][k]
		list[#list + 1] = mask
		maskIndex[n][mask] = #list - 1
	end
end

-- Reads bits, yielding zeros once the real bits run out (padding).
local function newReader(bits)
	local r = { bits = bits, pos = 1 }
	function r.read()
		local b = r.bits[r.pos] or 0
		r.pos = r.pos + 1
		return b
	end
	return r
end

local function readPrefix(r, tbl)
	local s = ""
	while true do
		s = s .. r.read()
		for _, entry in ipairs(tbl) do
			if entry[1] == s then return entry[2] end
		end
	end
end

local function writePrefix(out, tbl, value)
	for _, entry in ipairs(tbl) do
		if entry[2] == value then
			for j = 1, #entry[1] do
				out[#out + 1] = byte(entry[1], j) - 48
			end
			return true
		end
	end
	return false
end

-- Truncated binary code: a complete prefix code for m equally likely values.
local function tbParams(m)
	local k = 0
	while 2 ^ (k + 1) <= m do k = k + 1 end
	return k, 2 ^ (k + 1) - m
end

local function tbRead(r, m)
	if m == 1 then return 0 end
	local k, u = tbParams(m)
	local x = 0
	for _ = 1, k do x = x * 2 + r.read() end
	if x < u then return x end
	return x * 2 + r.read() - u
end

local function tbWrite(out, x, m)
	if m == 1 then return end
	local k, u = tbParams(m)
	if x < u then
		pushNumber(out, x, k)
	else
		pushNumber(out, x + u, k + 1)
	end
end

-- Case pattern of an n-letter run: number of capitals in truncated
-- unary (0 is most likely), then which letters.
local function readMask(r, n)
	local k = 0
	while k < n and r.read() == 1 do
		k = k + 1
	end
	local list = casePatterns[n][k]
	return list[tbRead(r, #list) + 1]
end

local function writeMask(out, run)
	local n, mask, k = #run, 0, 0
	for j = 1, n do
		if isUpper(sub(run, j, j)) then
			mask = mask + 2 ^ (j - 1)
			k = k + 1
		end
	end
	for _ = 1, k do out[#out + 1] = 1 end
	if k < n then out[#out + 1] = 0 end
	tbWrite(out, maskIndex[n][mask], #casePatterns[n][k])
end

local function renderRun(n, mask, letter)
	local t = {}
	for j = 0, n - 1 do
		t[j + 1] = (floor(mask / 2 ^ j) % 2 == 1) and upper(letter) or letter
	end
	return concat(t)
end

local function bitsToMoo(bits)
	local r = newReader(bits)
	local words = {}
	repeat
		local a = readPrefix(r, M_COUNT)
		local mMask = readMask(r, a)
		local b = readPrefix(r, O_COUNT)
		local oMask = readMask(r, b)
		words[#words + 1] = renderRun(a, mMask, "m") .. renderRun(b, oMask, "o")
	until r.pos > #bits
	return concat(words, " ")
end

local function mooWordToBits(word, out)
	local m, o = word:match("^([Mm]+)([Oo]+)$")
	if not m then return false end
	if not writePrefix(out, M_COUNT, #m) then return false end
	writeMask(out, m)
	if not writePrefix(out, O_COUNT, #o) then return false end
	writeMask(out, o)
	return true
end

---------------------------------------------------------------------------
-- Checksum
---------------------------------------------------------------------------

local function checksum(texts)
	local s = VERSION_SEED .. "\0" .. concat(texts, "\0")
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + byte(s, i)) % 4294967296
	end
	return (h + floor(h / 4096) + floor(h / 16777216)) % 2 ^ CHECK_BITS
end

---------------------------------------------------------------------------
-- Tokenizing
---------------------------------------------------------------------------

-- Tokens copied through verbatim: item/spell/quest links, textures,
-- atlases and {raid markers}.
local PASSTHROUGH = {
	"^|c[^|]*|H.-|h.-|h|r",
	"^|H.-|h.-|h",
	"^|T.-|t",
	"^|A.-|a",
	"^{[^}]*}",
}

local function passthroughEnd(s, i)
	for _, p in ipairs(PASSTHROUGH) do
		local _, e = find(s, p, i)
		if e then return e end
	end
end

local function isWordByte(b)
	return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b >= 128)
end

local function isMooByte(b)
	return b == 77 or b == 109 or b == 79 or b == 111 -- M m O o
end

-- Splits plain text into { s = segment } and { sep = true, s = text } items.
local function tokenizeText(s)
	local items = {}
	local i, n = 1, #s
	local sepStart
	local function flushSep(j)
		if sepStart and j >= sepStart then
			items[#items + 1] = { sep = true, s = sub(s, sepStart, j) }
		end
		sepStart = nil
	end
	while i <= n do
		local e = passthroughEnd(s, i)
		if e then
			sepStart = sepStart or i
			i = e + 1
		elseif isWordByte(byte(s, i)) then
			flushSep(i - 1)
			local j = i
			while j < n do
				local k = j + 1
				local b = byte(s, k)
				if isWordByte(b) then
					j = k
				elseif (b == 39 or b == 45) and isWordByte(byte(s, k + 1)) then
					j = k + 1 -- apostrophe or hyphen inside a word
				elseif b == 32 then
					local q = k
					while byte(s, q) == 32 do q = q + 1 end
					if isWordByte(byte(s, q)) then j = q else break end
				else
					break
				end
			end
			items[#items + 1] = { s = sub(s, i, j) }
			i = j + 1
		else
			sepStart = sepStart or i
			i = i + 1
		end
	end
	flushSep(n)
	return items
end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------

local function segmentBits(text, sum)
	local bits = {}
	if sum then pushNumber(bits, sum, CHECK_BITS) end
	encodeText(text, bits)
	return bits
end

-- Encodes text as a single moo line, or nil if it has nothing to hide.
local function encodeLine(text)
	local items = tokenizeText(text)
	local texts = {}
	for _, it in ipairs(items) do
		if not it.sep then texts[#texts + 1] = it.s end
	end
	if #texts == 0 then return nil end

	local sum = checksum(texts)
	local parts, first = {}, true
	for _, it in ipairs(items) do
		if it.sep then
			parts[#parts + 1] = it.s
		else
			parts[#parts + 1] = bitsToMoo(segmentBits(it.s, first and sum or nil))
			first = false
		end
	end
	return concat(parts)
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Smallest pieces a too-long word may be split into: whole passthrough
-- tokens or whole UTF-8 characters.
local function atoms(s)
	local list = {}
	local i, n = 1, #s
	while i <= n do
		local e = passthroughEnd(s, i)
		if not e then
			e = i
			while e < n do
				local b = byte(s, e + 1)
				if b < 128 or b >= 192 then break end
				e = e + 1
			end
		end
		list[#list + 1] = sub(s, i, e)
		i = e + 1
	end
	return list
end

-- Splits on spaces that are not inside a passthrough token.
local function units(s)
	local list, current = {}, {}
	for _, atom in ipairs(atoms(s)) do
		if atom == " " then
			list[#list + 1] = concat(current)
			current = {}
		else
			current[#current + 1] = atom
		end
	end
	list[#list + 1] = concat(current)
	return list
end

local function lineFor(text)
	return encodeLine(text) or text
end

local function fits(text)
	return #lineFor(text) <= Codec.MAX_LINE_BYTES
end

--- Encodes a chat message into one or more moo lines (each at most
--- MAX_LINE_BYTES). Returns nil when there is nothing to encode.
--- Lines split at spaces decode to pieces that rejoin with " ";
--- a single word too long for one line is split with no space.
function Codec.Encode(text)
	if type(text) ~= "string" then return nil end
	text = trim(text)
	if text == "" or not encodeLine(text) then return nil end
	if fits(text) then return { lineFor(text) } end

	local lines, chunk = {}, nil
	local function flush()
		if chunk and chunk ~= "" then
			lines[#lines + 1] = lineFor(chunk)
		end
		chunk = nil
	end

	for _, u in ipairs(units(text)) do
		local candidate = chunk and (chunk .. " " .. u) or u
		if fits(candidate) then
			chunk = candidate
		else
			flush()
			if fits(u) then
				chunk = u
			else
				for _, atom in ipairs(atoms(u)) do
					local c = (chunk or "") .. atom
					if fits(c) then
						chunk = c
					else
						flush()
						chunk = atom
					end
				end
			end
		end
	end
	flush()
	return lines
end

--- Decodes one moo line. Returns the original text, or nil when the line
--- is not a valid MooSpeak encoding.
function Codec.Decode(line)
	if type(line) ~= "string" or line == "" then return nil end

	local items = {}
	local i, n = 1, #line
	local sepStart
	local function flushSep(j)
		if sepStart and j >= sepStart then
			items[#items + 1] = { s = sub(line, sepStart, j) }
		end
		sepStart = nil
	end

	while i <= n do
		local e = passthroughEnd(line, i)
		local b = byte(line, i)
		if e then
			sepStart = sepStart or i
			i = e + 1
		elseif isMooByte(b) then
			flushSep(i - 1)
			local j = i
			while true do
				local _, we = find(line, "^[MmOo]+", j)
				j = we
				if byte(line, j + 1) == 32 and isMooByte(byte(line, j + 2)) then
					j = j + 2
				else
					break
				end
			end
			items[#items + 1] = { group = sub(line, i, j) }
			i = j + 1
		elseif isWordByte(b) then
			return nil
		else
			sepStart = sepStart or i
			i = i + 1
		end
	end
	flushSep(n)

	local texts, sum = {}, nil
	for _, it in ipairs(items) do
		if it.group then
			local bits = {}
			for word in gmatch(it.group, "%S+") do
				if not mooWordToBits(word, bits) then return nil end
			end
			local pos = 1
			local isFirst = sum == nil
			if isFirst then
				sum, pos = readNumber(bits, 1, CHECK_BITS)
				if not sum then return nil end
			end
			local text = decodeText(bits, pos)
			if not text or text == "" then return nil end
			-- Only the exact output of our own encoder is accepted.
			if bitsToMoo(segmentBits(text, isFirst and sum or nil)) ~= it.group then
				return nil
			end
			it.s = text
			texts[#texts + 1] = text
		end
	end

	if #texts == 0 or checksum(texts) ~= sum then return nil end

	local out = {}
	for _, it in ipairs(items) do
		out[#out + 1] = it.s
	end
	return concat(out)
end

--- True when the line is a valid MooSpeak encoding.
function Codec.IsMoo(line)
	return Codec.Decode(line) ~= nil
end

return Codec
