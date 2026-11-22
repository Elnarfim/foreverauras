-- Runs every test in this directory, each in its own interpreter process so
-- that stubbed globals cannot leak from one test into another.
--
-- Usage: luajit tests/run.lua
--    or: lua5.1 tests/run.lua
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
io.stdout:setvbuf("no") -- keep the headers in order with the child output
require("helpers") -- exits with a clear message on an unsupported Lua version

local tests = {
  "aura_environment_test.lua",
  "aura_helpers_test.lua",
  "common_options_test.lua",
  "transmission_test.lua",
  "aura_saved_data_test.lua",
  "client_api_test.lua",
  "subscribable_object_test.lua",
  "duration_text_test.lua",
}

-- The interpreter that runs this file, found before the script name in arg.
local interpreter = arg[-1]
local index = -1
while arg[index - 1] do
  index = index - 1
end
interpreter = arg[index]

local isWindows = package.config:sub(1, 1) == "\\"

local function run(command)
  -- cmd.exe strips the first and last quote of a command that starts with
  -- one, so the whole command is quoted once more on Windows.
  if isWindows then
    command = '"' .. command .. '"'
  end
  local status = os.execute(command)
  -- Lua 5.1 returns the exit code; LuaJIT with 5.2 compatibility returns true.
  return status == 0 or status == true
end

local failed = {}
for _, name in ipairs(tests) do
  print("==> " .. name)
  if not run(string.format('"%s" "%s/%s"', interpreter, testsDir, name)) then
    failed[#failed + 1] = name
  end
  print("")
end

if #failed > 0 then
  print("FAILED: " .. table.concat(failed, ", "))
  os.exit(1)
end
print("All test files passed.")
