-- Runs every MooSpeak test file. From the repo root: lua5.1 tests/run.lua
local files = { "tests/test_codec.lua", "tests/test_core.lua" }
local allOk = true
for _, f in ipairs(files) do
	local fh = io.open(f, "r")
	if fh then
		fh:close()
		print("== " .. f)
		local H = dofile(f)
		allOk = H.run() and allOk
	end
end
os.exit(allOk and 0 or 1)
