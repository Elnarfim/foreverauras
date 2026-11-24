-- Custom aura code runs through WeakAuras.LoadFunction and must not reach the
-- real global table, the blocked WoW functions, or the data-changing
-- ForeverAuras API. Each check probes the boundary the way an aura author would.
-- Ported from the WeakAuras2 sandbox tests and extended with the routes that
-- ForeverAuras adds or changes (the ForeverAuras alias, its saved variables,
-- the extra blocked API, anchors, the GetData copy cache).
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
-- Only in this file: upstream WeakAuras blocks these, so they get markers too.
for _, name in ipairs({ "DeleteMacro", "AbandonSkill", "PetAbandon" }) do
  _G[name] = function() return "REAL_" .. name end
end
local realG = _G
_G.WeakAuras = stubs.newWeakAuras()
_G.ForeverAuras = _G.WeakAuras
local WeakAuras = _G.WeakAuras
local Private, warnings = stubs.newPrivate()

local auraData = { id = "test", uid = "test-uid", config = { size = 3 }, information = {}, actions = {} }
WeakAuras.GetData = function(id)
  if id == "test" then
    return auraData
  end
end
Private.UIDtoID = function(uid)
  if uid == "test-uid" then
    return "test"
  end
end

T.loadAddonFile("ForeverAuras/AuraEnvironment.lua", "ForeverAuras", Private)

--- Runs code the way a custom trigger runs it.
local function runCustom(body)
  local fn, err = WeakAuras.LoadFunction("return function()\n" .. body .. "\nend", "test")
  assert(fn, err)
  return fn()
end

--- Runs code through the loader for generated code and options validation.
local function runBuiltin(body)
  local fn, err = Private.LoadFunction("return function()\n" .. body .. "\nend", "test", true)
  assert(fn, err)
  return fn()
end

local function warned(key)
  return stubs.warned(warnings, key)
end

local function clearWarnings()
  stubs.clearWarnings(warnings)
end

local function expectBlockedFunction(name)
  clearWarnings()
  local got = runCustom("return " .. name)
  T.expect(type(got) == "function" and got ~= realG[name] and got() ~= "REAL_" .. name,
           name .. " is replaced by a stub")
  T.expect(warned("SandboxForbidden"), name .. " raises a SandboxForbidden warning")
end

T.section("blocked Lua functions are not reachable from custom code")
for _, name in ipairs({ "loadstring", "getfenv", "setfenv", "pcall", "xpcall" }) do
  expectBlockedFunction(name)
end

T.section("blocked WoW functions are not reachable from custom code")
for _, name in ipairs(stubs.sensitiveFunctions) do
  expectBlockedFunction(name)
end

T.section("destructive functions that upstream WeakAuras also blocks")
for _, name in ipairs({ "DeleteMacro", "AbandonSkill", "PetAbandon" }) do
  expectBlockedFunction(name)
end

T.section("blocked tables are replaced by empty tables")
for _, name in ipairs({ "SlashCmdList", "DEFAULT_CHAT_FRAME", "debug",
                        "ForeverAurasSaved", "ForeverAurasOptions", "ForeverAurasOptionsSaved",
                        "WeakAurasSaved" }) do
  clearWarnings()
  local got = runCustom("return " .. name)
  T.expect(type(got) == "table" and got ~= realG[name] and next(got) == nil,
           name .. " is replaced by an empty table")
  T.expect(warned("SandboxForbidden"), name .. " raises a SandboxForbidden warning")
end

T.section("_G and getglobal resolve to the sandbox")
T.expect(runCustom("return _G") ~= realG, "_G is not the real global table")
T.expect(runCustom("return getglobal('_G')") ~= realG, "getglobal('_G') is not the real global table")
T.expect(runCustom("return _G._G._G") ~= realG, "nested _G stays inside the sandbox")
T.expect(runCustom("return _G.loadstring") ~= loadstring, "_G.loadstring is the stub")
T.expect(runCustom("return getmetatable(_G)") == false, "the sandbox metatable cannot be read")
T.expect(runCustom("return getmetatable(WeakAuras)") == false, "the WeakAuras proxy metatable cannot be read")
T.expect(runCustom("return getmetatable(ForeverAuras)") == false, "the ForeverAuras proxy metatable cannot be read")

T.section("dotted names resolve through the sandbox")
-- The frame chooser produces names like PlayerFrame.healthbar, so the sandbox
-- resolves dotted keys. The first segment must go through the sandbox, or
-- these names would return the real, blocked values.
local probes = {
  { '_G["_G.loadstring"]', loadstring },
  { 'getglobal("_G.pcall")', pcall },
  { '_G["_G.EnumerateFrames"]', realG.EnumerateFrames },
  { '_G["WeakAuras.Add"]', WeakAuras.Add },
  { '_G["ForeverAuras.Add"]', WeakAuras.Add },
  { 'getglobal("ForeverAuras.PreAdd")', WeakAuras.PreAdd },
  { '_G["_G.ForeverAuras.HideOptions"]', WeakAuras.HideOptions },
  { '_G["_G.ForeverAurasSaved"]', realG.ForeverAurasSaved },
  { '_G["_G.WeakAurasSaved"]', realG.WeakAurasSaved },
  { '_G["_G._G._G.loadstring"]', loadstring },
  { '_G["_G.debug"]', realG.debug },
}
for _, probe in ipairs(probes) do
  local got = runCustom("return " .. probe[1])
  T.expect(got ~= probe[2], probe[1] .. " does not return the real value")
end
T.expect(runCustom('return getglobal("getglobal.anything")') == nil,
         "a dotted name that passes through a function returns nil instead of erroring")

T.section("custom code cannot obtain a loader with the real environment")
local leaked = runCustom([[
  local candidates = { loadstring, _G["_G.loadstring"], getglobal("_G.loadstring"), _G._G.loadstring,
                       ForeverAuras.LoadFunction, WeakAuras.LoadFunction }
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "function" then
      local chunk = candidate("return _G")
      if type(chunk) == "function" then
        return chunk()
      elseif type(chunk) == "table" then
        return chunk
      end
    end
  end
]])
T.expect(leaked ~= realG, "no candidate loader compiles code against the real global table")
local viaDebug = runCustom([[
  local d = debug
  return d and d.getregistry and d.getregistry()
]])
T.expect(viaDebug == nil, "the debug library is not reachable")

T.section("the WeakAuras and ForeverAuras tables are guarded proxies")
T.expect(runCustom("return WeakAuras") ~= WeakAuras, "custom code sees a proxy, not the real WeakAuras table")
T.expect(runCustom("return ForeverAuras") ~= WeakAuras, "custom code sees a proxy, not the real ForeverAuras table")
T.expect(runCustom("return ForeverAuras == WeakAuras"), "both names give the same proxy")
for _, name in ipairs(stubs.blockedWeakAurasFunctions) do
  for _, global in ipairs({ "WeakAuras", "ForeverAuras" }) do
    clearWarnings()
    local got = runCustom("return " .. global .. "." .. name)
    T.expect(got ~= WeakAuras[name], global .. "." .. name .. " is blocked")
    T.expect(warned("SandboxForbidden"), global .. "." .. name .. " raises a SandboxForbidden warning")
  end
end
for _, name in ipairs({ "ModelPaths", "spellCache", "loaded" }) do
  clearWarnings()
  WeakAuras[name] = WeakAuras[name] or { marker = true }
  local got = runCustom("return ForeverAuras." .. name)
  T.expect(type(got) == "table" and got ~= WeakAuras[name], "ForeverAuras." .. name .. " is replaced by an empty table")
end
clearWarnings()
runCustom("WeakAuras.Injected = true")
T.expect(WeakAuras.Injected == nil, "writing to WeakAuras does not change the real table")
T.expect(warned("FakeWeakAurasSet"), "writing to WeakAuras raises a warning")
clearWarnings()
runCustom("ForeverAuras.Add = function() end")
T.expect(WeakAuras.Add() == "REAL_Add", "writing to ForeverAuras does not replace a real function")
T.expect(warned("FakeWeakAurasSet"), "writing to ForeverAuras raises a warning")
T.expect(runCustom("return WeakAuras.IsLibsOK") == WeakAuras.IsLibsOK, "allowed WeakAuras functions pass through")

T.section("global writes from custom code stay inside the sandbox")
clearWarnings()
runCustom("BrandNewGlobal = 1")
T.expect(realG.BrandNewGlobal == nil, "a new global is not created in the real environment")
T.expect(runCustom("return BrandNewGlobal") == 1, "the aura still sees its own global")
runCustom("UnitExists = nil")
T.expect(type(realG.UnitExists) == "function", "overwriting an existing global does not change the real one")
T.expect(warned("OverridingGlobal"), "overwriting an existing global raises a warning")
clearWarnings()
runCustom("aura_env = {}")
T.expect(warned("OverridingAuraEnv"), "overwriting aura_env raises a warning")
runCustom("_G.loadstring = 1")
T.expect(realG.loadstring ~= 1, "writing through _G does not reach the real global table")

T.section("aura code gets a copy of aura data")
Private.ActivateAuraEnvironment("test", nil, {}, {})
local env = runCustom("return aura_env")
T.expect(type(env) == "table" and env.id == "test", "aura_env is the environment of the active aura")
T.expect(type(env) == "table" and env.config ~= auraData.config and env.config.size == 3,
         "aura_env.config is a copy of the aura's config")
local seen = runCustom("local d = WeakAuras.GetData('test'); d.actions.tampered = true; return d")
T.expect(seen ~= auraData, "WeakAuras.GetData returns a copy")
T.expect(auraData.actions.tampered == nil, "writes to the copy do not reach the stored data")

T.section("the GetData copy is reused until an aura changes")
-- AuraEnvironment.lua keeps one copy per aura until Private.dataGeneration
-- changes, and copies on every call while the options window is open.
local first = runCustom("return ForeverAuras.GetData('test')")
local second = runCustom("return ForeverAuras.GetData('test')")
T.expect(first == second, "a second call returns the cached copy")
T.expect(second.actions.tampered == true, "the aura sees its own edits to the cached copy")
Private.InvalidateDataCopies()
local third = runCustom("return ForeverAuras.GetData('test')")
T.expect(third ~= first and third.actions.tampered == nil, "a data change hands out a fresh copy")
WeakAuras.IsOptionsOpen = function() return true end
local inOptionsA = runCustom("return ForeverAuras.GetData('test')")
local inOptionsB = runCustom("return ForeverAuras.GetData('test')")
T.expect(inOptionsA ~= inOptionsB and inOptionsA ~= auraData, "with the options open every call copies")
WeakAuras.IsOptionsOpen = function() return false end
T.expect(runCustom("return ForeverAuras.GetData('missing')") == nil, "an unknown id gives nil")

T.section("only copying GetData calls count towards the slow-function warning")
Private.InvalidateDataCopies()
clearWarnings()
for _ = 1, 150 do
  runCustom("return ForeverAuras.GetData('test')")
end
T.expect(not warned("FakeWeakAurasGetData"), "cached calls do not raise the GetData warning")
WeakAuras.IsOptionsOpen = function() return true end
for _ = 1, 100 do
  runCustom("return ForeverAuras.GetData('test')")
end
T.expect(warned("FakeWeakAurasGetData"), "a hundred copying calls raise the GetData warning")
WeakAuras.IsOptionsOpen = function() return false end
Private.ActivateAuraEnvironment()

T.section("frames and hooks made by custom code are attributed to the aura")
Private.ActivateAuraEnvironment("test", nil, {}, {})
local before = #Private.timedAPIRequests
runCustom("return CreateFrame, hooksecurefunc")
T.expect(#Private.timedAPIRequests == before + 2 and Private.timedAPIRequests[before + 1] == "test",
         "CreateFrame and hooksecurefunc come from the aura's timed API")
Private.ActivateAuraEnvironment()
before = #Private.timedAPIRequests
T.expect(runCustom("return CreateFrame") == realG.CreateFrame and #Private.timedAPIRequests == before,
         "without an active aura CreateFrame is the client's")

T.section("legitimate lookups keep working")
T.expect(Private.GetSanitizedGlobal("PlayerFrame") == realG.PlayerFrame, "a named frame resolves")
T.expect(Private.GetSanitizedGlobal("PlayerFrame.healthbar") == realG.PlayerFrame.healthbar,
         "a child frame without a name resolves through its parent")
T.expect(Private.GetSanitizedGlobal("PlayerFrame.missing") == nil, "an unknown child resolves to nil")
T.expect(runCustom("return UnitExists") == realG.UnitExists, "allowed API functions pass through")
T.expect(runCustom("return WA_Utf8Sub") == WeakAuras.WA_Utf8Sub, "WeakAuras helper functions are available")
T.expect(runCustom("return string.format") == string.format, "the string library is available")

T.section("anchor targets resolve only to usable frames")
-- Private.GetSanitizedFrame feeds SetPoint/SetParent for anchors chosen in the
-- options. It returns the frame, or nil plus true when the target may appear later.
_G.ForbiddenFrame = stubs.newFrame()
function _G.ForbiddenFrame:IsForbidden() return true end
_G.SomeTexture = stubs.newFrame("Texture")
_G.SomeFontString = stubs.newFrame("FontString")
_G.PlainTable = { a = 1 }
T.expect(Private.GetSanitizedFrame("PlayerFrame") == realG.PlayerFrame, "a frame resolves")
T.expect(Private.GetSanitizedFrame("PlayerFrame.healthbar") == realG.PlayerFrame.healthbar, "a child frame resolves")
local missing, retry = Private.GetSanitizedFrame("NotCreatedYet")
T.expect(missing == nil and retry == true, "a missing frame asks to be retried")
for _, key in ipairs({ "_G", "_G.PlayerFrame", "getglobal", "SlashCmdList", "ForeverAurasSaved",
                       "EnumerateFrames", "debug" }) do
  local frame, again = Private.GetSanitizedFrame(key)
  T.expect(frame == nil and again == nil, key .. " is refused without a retry")
end
T.expect(Private.GetSanitizedFrame("ForbiddenFrame") == nil, "a forbidden frame is refused")
T.expect(Private.GetSanitizedFrame("PlainTable") == nil, "a table that is not a frame is refused")
T.expect(Private.GetSanitizedFrame("SomeTexture") == nil, "a texture is refused as a parent")
T.expect(Private.GetSanitizedFrame("SomeTexture", false) == realG.SomeTexture, "a texture is allowed as a position anchor")
T.expect(Private.GetSanitizedFrame("SomeFontString", false) == realG.SomeFontString, "a font string is allowed as a position anchor")
for _, key in ipairs({ "", 42, false }) do
  T.expect(Private.GetSanitizedFrame(key) == nil, "the key " .. tostring(key) .. " (" .. type(key) .. ") is refused")
end
T.expect(Private.GetSanitizedFrame(stubs.secret("frame name")) == nil, "a secret key is refused")

T.section("the builtin environment has the same boundary")
for _, name in ipairs({ "loadstring", "getfenv", "setfenv", "EnumerateFrames", "Quit", "ConsoleExec" }) do
  T.expect(runBuiltin("return " .. name) ~= realG[name], "builtin: " .. name .. " is a stub")
end
for _, name in ipairs({ "ForeverAurasSaved", "debug" }) do
  T.expect(runBuiltin("return " .. name) ~= realG[name], "builtin: " .. name .. " is an empty table")
end
T.expect(runBuiltin("return _G") ~= realG, "builtin: _G is not the real global table")
T.expect(runBuiltin("return ForeverAuras") ~= WeakAuras, "builtin: ForeverAuras is the proxy")
local builtinPrivate = runBuiltin("return Private")
T.expect(type(builtinPrivate) == "table" and builtinPrivate.ExecEnv == Private.ExecEnv
         and builtinPrivate.LoadFunction == nil, "builtin: Private exposes only ExecEnv")

T.section("a broken chunk reports an error instead of loading")
local fn, err = Private.LoadFunction("return function( end", "test", true)
T.expect(fn == nil and type(err) == "string", "a syntax error returns nil and the message")

T.finish()
