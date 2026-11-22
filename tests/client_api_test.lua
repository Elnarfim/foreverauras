-- Restriction state: ClientAPI.lua asks the client whether auras and
-- cooldowns are secret right now, and Secrets.lua tells the rest of the addon
-- when that answer changes. The adapter fails closed: an answer it cannot
-- trust (a missing API, an error, a secret, a non-boolean) counts as
-- restricted, so the addon never reads a value the client protects.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
_G.WeakAuras = stubs.newWeakAuras()
local WeakAuras = _G.WeakAuras
local Private = stubs.newPrivate()

T.loadAddonFile("ForeverAuras/ClientAPI.lua", "ForeverAuras", Private)
local RestrictionsActive = Private.ClientAPI.RestrictionsActive

--- Sets what C_Secrets answers; a function value is called as the API.
local function secrets(aura, cooldown)
  local function api(value)
    if type(value) == "function" then return value end
    return function() return value end
  end
  _G.C_Secrets = { ShouldAurasBeSecret = api(aura), ShouldCooldownsBeSecret = api(cooldown) }
end

T.section("trusted answers")
secrets(false, false)
T.expectEqual(RestrictionsActive(), false, "neither auras nor cooldowns secret: not restricted")
secrets(true, false)
T.expectEqual(RestrictionsActive(), true, "secret auras: restricted")
secrets(false, true)
T.expectEqual(RestrictionsActive(), true, "secret cooldowns: restricted")
secrets(true, true)
T.expectEqual(RestrictionsActive(), true, "both secret: restricted")

T.section("answers that cannot be trusted count as restricted")
_G.C_Secrets = nil
T.expectEqual(RestrictionsActive(), true, "no C_Secrets namespace")
_G.C_Secrets = { ShouldAurasBeSecret = function() return false end }
T.expectEqual(RestrictionsActive(), true, "the cooldown query is missing")
_G.C_Secrets = { ShouldAurasBeSecret = "not a function", ShouldCooldownsBeSecret = function() return false end }
T.expectEqual(RestrictionsActive(), true, "the aura query is not a function")
secrets(function() error("restricted") end, false)
T.expectEqual(T.expectNoError(RestrictionsActive, "an erroring aura query raises no error"), true,
              "an erroring aura query")
secrets(false, function() error("restricted") end)
T.expectEqual(RestrictionsActive(), true, "an erroring cooldown query")
secrets(stubs.secret("aura answer"), false)
T.expectEqual(RestrictionsActive(), true, "a secret aura answer")
secrets(false, stubs.secret("cooldown answer"))
T.expectEqual(RestrictionsActive(), true, "a secret cooldown answer")
secrets(nil, false)
T.expectEqual(RestrictionsActive(), true, "a nil answer")
secrets(0, false)
T.expectEqual(RestrictionsActive(), true, "a number answer")
secrets("false", false)
T.expectEqual(RestrictionsActive(), true, "a string answer")
local savedIsSecret = _G.issecretvalue
_G.issecretvalue = nil
secrets(false, false)
T.expectEqual(RestrictionsActive(), false, "without issecretvalue, plain booleans are still trusted")
_G.issecretvalue = savedIsSecret

T.section("Secrets.lua announces only changes of the restriction state")
local fired, scanned = 0, 0
Private.callbacks = { Fire = function(_, name) if name == "WA_SECRET_STATE_UPDATE" then fired = fired + 1 end end }
Private.ScanEvents = function(name) if name == "WA_SECRET_STATE_UPDATE" then scanned = scanned + 1 end end
local registered = {}
local eventFrame
_G.CreateFrame = function(objectType)
  local frame = stubs.newFrame(objectType)
  function frame:RegisterEvent(event) registered[event] = true end
  eventFrame = frame
  return frame
end
local delayed = {}
_G.C_Timer.After = function(delay, fn) delayed[#delayed + 1] = { delay = delay, fn = fn } end
_G.Enum = { AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 } }

T.loadAddonFile("ForeverAuras/Secrets.lua", "ForeverAuras", Private)
local onEvent = eventFrame and eventFrame:GetScript("OnEvent")
if T.expect(type(onEvent) == "function", "Secrets.lua handles events on its frame") then
  for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ADDON_RESTRICTION_STATE_CHANGED", "PLAYER_IN_COMBAT_CHANGED",
                           "ENCOUNTER_STATE_CHANGED", "CHALLENGE_MODE_START" }) do
    T.expect(registered[event], "it listens to " .. event)
  end
  T.expect(WeakAuras.IsSecretStateActive() == nil, "the state is unknown before the first event")

  secrets(false, false)
  onEvent(eventFrame, "PLAYER_ENTERING_WORLD")
  T.expect(WeakAuras.IsSecretStateActive() == false and fired == 1 and scanned == 1,
           "the first event sets the state and announces it to load and triggers")
  onEvent(eventFrame, "PLAYER_IN_COMBAT_CHANGED", true)
  T.expect(fired == 1 and scanned == 1, "an event that does not change the state announces nothing")

  secrets(true, false)
  onEvent(eventFrame, "PLAYER_IN_COMBAT_CHANGED", true)
  T.expect(WeakAuras.IsSecretStateActive() == true and fired == 2 and scanned == 2, "entering restrictions is announced")
  secrets(false, false)
  onEvent(eventFrame, "ENCOUNTER_STATE_CHANGED")
  T.expect(WeakAuras.IsSecretStateActive() == false and fired == 3, "leaving restrictions is announced")

  T.section("a restriction that is still activating is checked again")
  onEvent(eventFrame, "ADDON_RESTRICTION_STATE_CHANGED", 1, Enum.AddOnRestrictionState.Active)
  T.expect(#delayed == 0, "an active restriction schedules nothing")
  onEvent(eventFrame, "ADDON_RESTRICTION_STATE_CHANGED", 1, Enum.AddOnRestrictionState.Activating)
  T.expect(#delayed == 1 and delayed[1].delay == 0, "an activating restriction schedules a check on the next frame")
  if delayed[1] then
    secrets(true, true)
    delayed[1].fn()
    T.expect(WeakAuras.IsSecretStateActive() == true and fired == 4, "the next-frame check picks up the new state")
  end
end

T.finish()
