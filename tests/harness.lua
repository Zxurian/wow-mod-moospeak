-- Tiny test harness for running MooSpeak tests under plain Lua 5.1
-- (the same Lua version the WoW client embeds).

local H = {}

local tests = {}
local failures = 0

function H.test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function fmt(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function H.eq(actual, expected, msg)
	if actual ~= expected then
		error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

function H.truthy(v, msg)
	if not v then
		error(msg or "expected a truthy value", 2)
	end
end

function H.falsy(v, msg)
	if v then
		error((msg or "expected a falsy value") .. ", got " .. fmt(v), 2)
	end
end

function H.run()
	for _, t in ipairs(tests) do
		local ok, err = pcall(t.fn)
		if ok then
			print("  ok    " .. t.name)
		else
			failures = failures + 1
			print("  FAIL  " .. t.name .. "\n        " .. tostring(err))
		end
	end
	print(string.format("%d tests, %d failed", #tests, failures))
	tests = {}
	return failures == 0
end

-- Loads an addon file the way the WoW client does: called with
-- (addonName, addonTable) as its varargs.
function H.loadAddonFile(path, ns)
	local chunk = assert(loadfile(path))
	chunk("MooSpeak", ns)
	return ns
end

return H
