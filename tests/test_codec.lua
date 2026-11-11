-- Codec tests: run from the repo root with `lua5.1 tests/run.lua`.

local H = dofile("tests/harness.lua")
local ns = H.loadAddonFile("MooSpeak/Codec.lua", {})
local Codec = ns.Codec

-- Replaces every moo group in a line with "X" so punctuation layout
-- can be compared directly.
local function shape(line)
	local s = line:gsub("[MmOo]+", "X")
	local n
	repeat
		s, n = s:gsub("X X", "X")
	until n == 0
	return s
end

-- Every word of every moo group must be 1-4 M's then 2-6 O's.
local function assertMooWords(line)
	local stripped = line:gsub("|c%x%x%x%x%x%x%x%x|H.-|h.-|h|r", ""):gsub("{[^}]*}", "")
	for word in stripped:gmatch("%a+") do
		local m, o = word:match("^([Mm]+)([Oo]+)$")
		H.truthy(m, "not a moo word: " .. word .. " in " .. line)
		H.truthy(#m >= 1 and #m <= 4, "bad M run in " .. word)
		H.truthy(#o >= 2 and #o <= 6, "bad O run in " .. word)
	end
end

local function roundTrip(text)
	local lines = Codec.Encode(text)
	H.truthy(lines and #lines >= 1, "no lines for: " .. text)
	local parts = {}
	for i, line in ipairs(lines) do
		H.truthy(#line <= 255, "line too long (" .. #line .. ")")
		assertMooWords(line)
		local decoded = Codec.Decode(line)
		H.truthy(decoded, "line " .. i .. " did not decode: " .. line)
		parts[#parts + 1] = decoded
	end
	return table.concat(parts, " "), lines
end

H.test("round-trips a simple sentence", function()
	H.eq(roundTrip("hello there"), "hello there")
end)

H.test("round-trips mixed case, digits and caps words", function()
	local text = "LFG Deadmines need 2 DPS and a Tank, PST"
	H.eq(roundTrip(text), text)
end)

H.test("output contains only moo words", function()
	local _, lines = roundTrip("anyone want to run Deadmines with me tonight")
	for _, line in ipairs(lines) do
		H.falsy(line:find("[^MmOo ]"), "unexpected character in " .. line)
	end
end)

H.test("keeps punctuation in place", function()
	local _, lines = roundTrip("Hey, anyone want to run Deadmines? I'll tank!")
	H.eq(#lines, 1)
	H.eq(shape(lines[1]), "X, X? X!")
end)

H.test("keeps leading, repeated and bracketing punctuation", function()
	local text = "...what?! (really) \"yes\" - ok; fine: 50% ~cool~"
	local decoded, lines = roundTrip(text)
	H.eq(decoded, text)
	H.eq(shape(lines[1]), "...X?! (X) \"X\" - X; X: X% ~X~")
end)

H.test("apostrophes and hyphens inside words are hidden", function()
	local text = "I'll re-run it, don't worry"
	local decoded, lines = roundTrip(text)
	H.eq(decoded, text)
	H.eq(shape(lines[1]), "X, X")
end)

H.test("item links and raid markers pass through untouched", function()
	local link = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
	local text = "look at my " .. link .. " {skull} first!"
	local decoded, lines = roundTrip(text)
	H.eq(decoded, text)
	H.truthy(lines[1]:find(link, 1, true), "link missing from output")
	H.truthy(lines[1]:find("{skull}", 1, true), "raid marker missing from output")
end)

H.test("round-trips non-ASCII text", function()
	local text = "Привет, café über naïve"
	H.eq(roundTrip(text), text)
end)

H.test("text with nothing to hide is not encoded", function()
	H.falsy(Codec.Encode("?!"))
	H.falsy(Codec.Encode("   "))
	H.falsy(Codec.Encode(""))
end)

H.test("trims surrounding whitespace", function()
	H.eq(roundTrip("  hi there  "), "hi there")
end)

H.test("long messages split into several decodable lines", function()
	local text = string.rep("the quick brown fox jumps over the lazy dog, ", 5)
		.. "and that is the end of this extremely long message!"
	local decoded, lines = roundTrip(text)
	H.truthy(#lines >= 2, "expected several lines, got " .. #lines)
	H.eq(decoded, text)
end)

H.test("a maximal 255-byte message round-trips", function()
	local text = string.rep("abcdefghij klmnopqrst uvwxyz0123 ", 8)
	text = text:sub(1, 255):gsub("%s+$", "")
	H.eq(roundTrip(text), text)
end)

H.test("a single very long word splits mid-word and rejoins exactly", function()
	local text = string.rep("x", 200) .. "!"
	local lines = Codec.Encode(text)
	H.truthy(#lines >= 2, "expected the word to be split")
	local parts = {}
	for _, line in ipairs(lines) do
		H.truthy(#line <= 255, "line too long")
		parts[#parts + 1] = Codec.Decode(line)
	end
	H.eq(table.concat(parts), text)
end)

H.test("splitting never breaks a UTF-8 character", function()
	local text = string.rep("ж", 120)
	local parts = {}
	for _, line in ipairs(Codec.Encode(text)) do
		parts[#parts + 1] = Codec.Decode(line)
	end
	H.eq(table.concat(parts), text)
end)

H.test("encoding is deterministic", function()
	local a = Codec.Encode("same input, same output")
	local b = Codec.Encode("same input, same output")
	H.eq(table.concat(a, "\n"), table.concat(b, "\n"))
end)

H.test("ordinary chat does not decode", function()
	H.falsy(Codec.Decode("hello there"))
	H.falsy(Codec.Decode("lol moo"))
	H.falsy(Codec.Decode(""))
end)

H.test("hand-typed moos do not decode", function()
	local samples = {
		"moo", "moo moo", "Moo moo moo", "MOO", "moooo mooo!", "Moo? Moo!",
		"mooo moo mooooo moo Moo mooo", "MOOOOO", "moo moo moo moo moo moo",
	}
	for _, s in ipairs(samples) do
		H.falsy(Codec.Decode(s), "decoded hand-typed moo: " .. s)
	end
end)

H.test("random moo-shaped lines almost never decode", function()
	-- Seeded so the test is repeatable.
	math.randomseed(1234)
	local hits = 0
	local trials = 3000
	for _ = 1, trials do
		local words = {}
		for w = 1, math.random(1, 8) do
			local m = string.rep(math.random() < 0.5 and "m" or "M", math.random(1, 2))
			local o = ""
			for _ = 1, math.random(2, 6) do
				o = o .. (math.random() < 0.3 and "O" or "o")
			end
			words[w] = m .. o
		end
		if Codec.Decode(table.concat(words, " ")) then
			hits = hits + 1
		end
	end
	H.truthy(hits <= 3, "too many false decodes: " .. hits .. "/" .. trials)
end)

H.test("a tampered line fails to decode", function()
	local line = Codec.Encode("meet me at the bank")[1]
	-- Flip the case of one letter in the middle.
	local i = math.floor(#line / 2)
	while not line:sub(i, i):find("[MmOo]") do i = i + 1 end
	local c = line:sub(i, i)
	local flipped = c == c:upper() and c:lower() or c:upper()
	H.falsy(Codec.Decode(line:sub(1, i - 1) .. flipped .. line:sub(i + 1)))
end)

H.test("encoded output already in moo form is recognized", function()
	local line = Codec.Encode("hi")[1]
	H.truthy(Codec.Decode(line))
end)

H.test("capacity: a typical 80-character message fits on one line", function()
	local text = "Hey, anyone want to run Deadmines? I'll tank, just need a healer and some dps."
	local _, lines = roundTrip(text)
	H.eq(#lines, 1, "lines used")
end)

return H
