-- Runs every test in this directory, each in its own interpreter process so
-- that stubbed globals cannot leak from one test into another. The output of
-- each file is shown as it runs, and a summary of every failed and skipped
-- check is printed at the end.
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
local index = -1
while arg[index - 1] do
  index = index - 1
end
local interpreter = arg[index]

local isWindows = package.config:sub(1, 1) == "\\"

--- Runs one test file, echoing its output. Returns its result: the counts
--- from its summary line (nil if it never printed one, for example after a
--- Lua error), its failed checks with their detail lines, its skipped checks,
--- and the last lines it printed.
local function runFile(name)
  local command = string.format('"%s" "%s/%s" 2>&1', interpreter, testsDir, name)
  -- cmd.exe strips the first and last quote of a command that starts with
  -- one, so the whole command is quoted once more on Windows.
  if isWindows then
    command = '"' .. command .. '"'
  end
  local result = { name = name, failures = {}, skips = {}, tail = {} }
  local handle = assert(io.popen(command, "r"))
  local lastFailure
  for line in handle:lines() do
    line = line:gsub("\r$", "")
    print(line)
    local passed, failed, skipped = line:match("^(%d+) passed, (%d+) failed, (%d+) skipped$")
    if passed then
      result.passed, result.failed, result.skipped = tonumber(passed), tonumber(failed), tonumber(skipped)
    end
    local failure = line:match("^  FAIL  (.*)$")
    local skip = line:match("^  SKIP  (.*)$")
    if failure then
      lastFailure = { check = failure, details = {} }
      result.failures[#result.failures + 1] = lastFailure
    elseif skip then
      result.skips[#result.skips + 1] = skip
      lastFailure = nil
    elseif lastFailure and line:match("^        ") then
      -- expectEqual and expectNoError print what went wrong under the check.
      lastFailure.details[#lastFailure.details + 1] = line
    else
      lastFailure = nil
    end
    -- The interpreter prefixes an uncaught error with its own name.
    if not result.errorLine and line:find(interpreter .. ":", 1, true) == 1 then
      result.errorLine = line
    end
    result.tail[#result.tail + 1] = line
    if #result.tail > 5 then
      table.remove(result.tail, 1)
    end
  end
  -- Lua 5.1's popen gives no exit status; helpers.finish prints the summary
  -- line and exits non-zero exactly when a check failed.
  handle:close()
  result.ok = result.failed == 0
  return result
end

local results = {}
for _, name in ipairs(tests) do
  print("==> " .. name)
  results[#results + 1] = runFile(name)
  print("")
end

local totalPassed, totalFailed, totalSkipped = 0, 0, 0
local failedFiles, crashed = {}, {}
local anyFailures = false
for _, result in ipairs(results) do
  totalPassed = totalPassed + (result.passed or 0)
  totalFailed = totalFailed + (result.failed or 0)
  totalSkipped = totalSkipped + (result.skipped or 0)
  -- A file that crashed can still have printed failed checks before it stopped.
  anyFailures = anyFailures or #result.failures > 0
  if not result.ok then
    failedFiles[#failedFiles + 1] = result.name
  end
  if result.passed == nil then
    crashed[#crashed + 1] = result
  end
end

print(string.rep("=", 72))
print("Summary")
local anySkipped = false
for _, result in ipairs(results) do
  for _, skip in ipairs(result.skips) do
    if not anySkipped then
      print("")
      print("Skipped:")
      anySkipped = true
    end
    print(("  [%s] %s"):format(result.name, skip))
  end
end
if anyFailures then
  print("")
  print("Failed checks:")
  for _, result in ipairs(results) do
    for _, failure in ipairs(result.failures) do
      print(("  [%s] %s"):format(result.name, failure.check))
      for _, detail in ipairs(failure.details) do
        print("    " .. detail)
      end
    end
  end
end
if #crashed > 0 then
  print("")
  print("Did not finish (a Lua error stopped the file, see its output above):")
  for _, result in ipairs(crashed) do
    if result.errorLine then
      print(("  [%s] %s"):format(result.name, result.errorLine))
    else
      print(("  [%s] its last lines:"):format(result.name))
      for _, line in ipairs(result.tail) do
        print("    " .. line)
      end
    end
  end
end
print("")
print(("%d passed, %d failed, %d skipped in %d files"):format(totalPassed, totalFailed, totalSkipped, #results))
if #failedFiles > 0 then
  print("FAILED: " .. table.concat(failedFiles, ", "))
  os.exit(1)
end
print("All test files passed.")
