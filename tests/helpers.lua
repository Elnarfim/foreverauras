-- Shared helpers for the tests in this directory.
local M = {}

-- Unbuffered, so a Lua error (written to stderr) shows up after the checks
-- that ran before it, also when run.lua reads the output through a pipe.
io.stdout:setvbuf("no")

-- The aura sandbox is built on loadstring and setfenv, which Lua 5.2 removed.
-- The WoW client runs Lua 5.1, so the tests need Lua 5.1 or LuaJIT as well.
if not (loadstring and setfenv) then
  print(("These tests need Lua 5.1 or LuaJIT. %s has no loadstring/setfenv."):format(_VERSION))
  os.exit(2)
end

M.testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
M.repoRoot = M.testsDir .. "/.."

local passes, failures, skips = 0, 0, 0

function M.section(name)
  print("# " .. name)
end

--- Returns the condition so a caller can skip checks that depend on it.
function M.expect(condition, message)
  if condition then
    passes = passes + 1
    print("  ok    " .. message)
  else
    failures = failures + 1
    print("  FAIL  " .. message)
  end
  return condition
end

--- Like expect, but prints both values when they differ.
function M.expectEqual(actual, expected, message)
  local same = actual == expected
  M.expect(same, message)
  if not same then
    print(("        expected %s, got %s"):format(tostring(expected), tostring(actual)))
  end
  return same
end

--- Checks that fn raises an error. Returns the error message.
function M.expectError(fn, message)
  local ok, err = pcall(fn)
  M.expect(not ok, message)
  if ok then
    print("        no error was raised")
  end
  return err
end

--- Checks that fn runs without an error. Returns fn's first result.
function M.expectNoError(fn, message)
  local ok, result = pcall(fn)
  M.expect(ok, message)
  if not ok then
    print("        error: " .. tostring(result))
  end
  return ok and result or nil
end

--- Records a check that could not run, with the reason. A skip does not fail
--- the run, but it is reported so a missing check is never mistaken for a pass.
function M.skip(message, reason)
  skips = skips + 1
  print("  SKIP  " .. message .. " (" .. reason .. ")")
end

function M.finish()
  print(("%d passed, %d failed, %d skipped"):format(passes, failures, skips))
  os.exit(failures > 0 and 1 or 0)
end

--- True when the file exists in the repository.
function M.fileExists(relativePath)
  local handle = io.open(M.repoRoot .. "/" .. relativePath, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
end

--- Loads a repository Lua file the way WoW does: the chunk receives the addon
--- name and the private table as its vararg.
function M.loadAddonFile(relativePath, addonName, privateTable)
  local chunk = assert(loadfile(M.repoRoot .. "/" .. relativePath))
  return chunk(addonName, privateTable)
end

-- The third-party libraries in ForeverAuras/Libs are not in git (see
-- .gitignore); they are only present in a checkout that has them copied in.
M.libsDir = "ForeverAuras/Libs"

--- True when every listed library file is present under ForeverAuras/Libs.
function M.libsAvailable(files)
  for _, file in ipairs(files) do
    if not M.fileExists(M.libsDir .. "/" .. file) then
      return false, M.libsDir .. "/" .. file .. " is missing"
    end
  end
  return true
end

--- Loads a library file from ForeverAuras/Libs with the addon's vararg.
function M.loadLib(file)
  return M.loadAddonFile(M.libsDir .. "/" .. file, "ForeverAuras", {})
end

return M
