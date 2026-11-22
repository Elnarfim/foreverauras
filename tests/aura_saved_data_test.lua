-- aura_env.saved: custom code stores data there, and AuraEnvironment.lua
-- writes it to the aura's information.saved when the environment is cleared
-- (at logout, on edits) and restores it the next time the aura activates.
-- ForeverAuras serializes with its own copy of LibSerialize, because another
-- addon's registered copy broke on the number 0 on this client. These checks
-- use the real libraries from ForeverAuras/Libs and are skipped without them.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

local libFiles = { "LibStub/LibStub.lua", "LibDeflate/LibDeflate.lua", "LibSerialize/LibSerialize.lua" }
local available, missing = T.libsAvailable(libFiles)
if not available then
  T.skip("aura_env.saved round trip", missing)
  T.finish()
end

stubs.install()
_G.LibStub = nil
T.loadLib("LibStub/LibStub.lua")
T.loadLib("LibDeflate/LibDeflate.lua")
local LibStub = _G.LibStub
-- Another addon loaded first and registered a newer LibSerialize that fails
-- on the number 0, like the copy the ForeverAuras comment describes.
local hostile = LibStub:NewLibrary("LibSerialize", 999)
local hostileUsed = false
function hostile:SerializeEx() hostileUsed = true error("attempt to perform arithmetic: divide by zero") end
function hostile:Serialize() hostileUsed = true error("attempt to perform arithmetic: divide by zero") end
function hostile:Deserialize() hostileUsed = true return false, "hostile copy" end
T.loadLib("LibSerialize/LibSerialize.lua")
T.expect(_G.ForeverAurasLibSerialize ~= nil and _G.ForeverAurasLibSerialize ~= hostile,
         "the addon builds its own LibSerialize next to another addon's newer copy")
LibStub:NewLibrary("LibCustomGlow-1.0-foreverauras", 1)
LibStub:NewLibrary("LibGetFrame-1.0", 1)

_G.WeakAuras = stubs.newWeakAuras()
_G.ForeverAuras = _G.WeakAuras
local WeakAuras = _G.WeakAuras
local Private, warnings = stubs.newPrivate()

local db = {
  Counter = { id = "Counter", uid = "counter-uid", config = {}, information = {}, actions = {} },
  Other = { id = "Other", uid = "other-uid", config = {}, information = {}, actions = {} },
}
WeakAuras.GetData = function(id) return db[id] end
Private.UIDtoID = function(uid)
  for id, data in pairs(db) do
    if data.uid == uid then return id end
  end
end

T.loadAddonFile("ForeverAuras/AuraEnvironment.lua", "ForeverAuras", Private)

local function deepEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not deepEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

--- Activates the aura, runs body as its custom code, and deactivates it.
local function runAs(id, body)
  Private.ActivateAuraEnvironment(id, nil, {}, {})
  local fn = assert(WeakAuras.LoadFunction("return function()\n" .. body .. "\nend", id))
  local result = fn()
  Private.ActivateAuraEnvironment()
  return result
end

T.section("aura_env.saved survives a reload")
local stored = {
  kills = 0, best = -3, ratio = 0.25, flags = { true, false },
  names = { "Thrall", "Jäger" }, byName = { Thrall = { 0, 0, 0 } },
}
local fn = assert(WeakAuras.LoadFunction("return function(value) aura_env.saved = value end", "Counter"))
Private.ActivateAuraEnvironment("Counter", nil, {}, {})
fn(stored)
Private.ActivateAuraEnvironment()
hostileUsed = false
stubs.clearWarnings(warnings)
local ok, err = pcall(Private.ClearAuraEnvironment, "Counter")
T.expect(ok, "clearing the environment saves without an error")
if not ok then print("        error: " .. tostring(err)) end
T.expect(not hostileUsed, "the other addon's LibSerialize is not used")
T.expect(not stubs.warned(warnings, "CustomSavedData"), "a small amount of saved data raises no size warning")
T.expect(type(db.Counter.information.saved) == "string" and #db.Counter.information.saved > 0,
         "the data is stored as text in information.saved")
local restored = runAs("Counter", "return aura_env.saved")
T.expect(deepEqual(restored, stored), "the next activation restores the same values, zeros included")
T.expect(restored ~= stored, "the restored data is a new table")

T.section("only what can be serialized is saved")
Private.ActivateAuraEnvironment("Counter", nil, {}, {})
fn({ count = 2, callback = function() end, frame = newproxy(false) })
Private.ActivateAuraEnvironment()
ok = pcall(Private.ClearAuraEnvironment, "Counter")
T.expect(ok, "functions and userdata in saved data do not raise an error")
restored = runAs("Counter", "return aura_env.saved")
T.expect(type(restored) == "table" and restored.count == 2 and restored.callback == nil and restored.frame == nil,
         "functions and userdata are dropped, the rest is kept")

T.section("clearing saved data")
Private.ClearAuraEnvironmentSavedData("Counter")
Private.ClearAuraEnvironment("Counter")
T.expect(db.Counter.information.saved == nil, "Clear Saved Data removes the stored text")
T.expect(runAs("Counter", "return aura_env.saved") == nil, "the next activation has no saved data")

T.section("an aura that never ran keeps its stored data")
db.Other.information.saved = db.Counter.information.saved
local before = db.Other.information.saved
Private.ClearAuraEnvironment("Other")
T.expect(db.Other.information.saved == before, "clearing an environment that was never activated changes nothing")

T.section("renaming moves the environment")
Private.ActivateAuraEnvironment("Counter", nil, {}, {})
fn({ marker = "moved" })
Private.ActivateAuraEnvironment()
db.Renamed = db.Counter
db.Counter = nil
db.Renamed.id = "Renamed"
Private.RenameAuraEnvironment("Counter", "Renamed")
Private.ClearAuraEnvironment("Renamed")
restored = runAs("Renamed", "return aura_env.saved")
T.expect(type(restored) == "table" and restored.marker == "moved", "saved data follows the aura to its new id")

T.finish()
