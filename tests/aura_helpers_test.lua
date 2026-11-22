-- The text helpers that AuraEnvironment.lua gives custom aura code:
-- WA_Utf8Sub, WeakAuras.PadString and WA_ClassColorName. ForeverAuras changed
-- them to pass secret values (restricted unit and spell names) through
-- untouched, since the client raises an error when Lua reads or indexes one.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
_G.WeakAuras = stubs.newWeakAuras()
_G.ForeverAuras = _G.WeakAuras
local WeakAuras = _G.WeakAuras
local Private = stubs.newPrivate()

-- Units for WA_ClassColorName: unit -> { name, class token }.
local units = {}
_G.UnitExists = function(unit) return units[unit] ~= nil end
WeakAuras.UnitName = function(unit) return units[unit] and units[unit][1] end
_G.UnitClass = function(unit)
  local class = units[unit] and units[unit][2]
  return "Localized", class
end
-- The colour table is guarded: indexing it with a secret class token raises
-- the client's error, which is what the 1.4.6-dev.21 fix avoids.
_G.RAID_CLASS_COLORS = stubs.secretKeyGuard({
  MAGE = { colorStr = "ff3fc7eb" },
  WARRIOR = { colorStr = "ffc69b6d" },
})
local classColorCalls = 0
local classColorFails = false
_G.C_ClassColor = {
  GetClassColor = function(class)
    classColorCalls = classColorCalls + 1
    if classColorFails then
      error("bad argument #1 to 'WrapTextInColor'")
    end
    return { WrapTextInColorCode = function(_, text) return "<colored>" .. tostring(text) end }
  end,
}

T.loadAddonFile("ForeverAuras/AuraEnvironment.lua", "ForeverAuras", Private)

local Utf8Sub = WeakAuras.WA_Utf8Sub
local PadString = WeakAuras.PadString
local ClassColorName = WeakAuras.WA_ClassColorName

T.section("WA_Utf8Sub counts characters, not bytes")
T.expectEqual(Utf8Sub("Warrior", 4), "Warr", "ASCII text is cut at the character count")
T.expectEqual(Utf8Sub("Warrior", 50), "Warrior", "a count longer than the text returns the whole text")
T.expectEqual(Utf8Sub("Warrior", 0), "", "a count of zero returns an empty string")
T.expectEqual(Utf8Sub("Jäger", 2), "Jä", "a two-byte character counts as one")
T.expectEqual(Utf8Sub("Привет", 3), "При", "Cyrillic text is cut at the character count")
T.expectEqual(Utf8Sub("火焰冲击", 2), "火焰", "three-byte characters count as one each")
T.expectEqual(Utf8Sub("a🙂b", 2), "a🙂", "a four-byte character counts as one")
T.expectEqual(Utf8Sub(12345, 3), "123", "a number is cut as its text")
local secretName = stubs.secret("unit name")
T.expect(Utf8Sub(secretName, 3) == secretName, "a secret text is returned whole")

T.section("PadString pads to a length")
T.expectEqual(PadString("ab", "left", 5), "   ab", "left padding adds spaces in front")
T.expectEqual(PadString("ab", "right", 5), "ab   ", "right padding adds spaces after")
T.expectEqual(PadString("abcdef", "left", 3), "abcdef", "a longer text is not cut")
T.expectEqual(PadString("ab", "center", 5), "ab", "an unknown mode leaves the text alone")
T.expectEqual(PadString(42, "left", 4), "  42", "a number is padded as its text")
T.expect(PadString(secretName, "left", 10) == secretName, "a secret text is not padded")

T.section("WA_ClassColorName colours a unit's name")
units.party1 = { "Jaina", "MAGE" }
units.party2 = { "Varian", nil }
units.party3 = { "Garrosh", "DEMONHUNTER" }
T.expectEqual(ClassColorName("party1"), "|cff3fc7ebJaina|r", "a known class colours the name")
T.expectEqual(ClassColorName("party1", 3), "|cff3fc7ebJai|r", "maxlen cuts the name before colouring")
T.expectEqual(ClassColorName("party2"), "Varian", "a unit without a class gives the plain name")
T.expectEqual(ClassColorName("party3"), "Garrosh", "a class without a colour gives the plain name")
T.expectEqual(ClassColorName("nobody"), "", "a missing unit gives an empty string")
T.expectEqual(ClassColorName(nil), "", "no unit gives an empty string")

T.section("WA_ClassColorName with secret values")
-- Reported in dungeons: the class token can be secret while the name is not.
local secretClass = stubs.secret("class token")
units.party4 = { "Thrall", secretClass }
classColorCalls, classColorFails = 0, false
local colored = T.expectNoError(function() return ClassColorName("party4") end,
                                "a secret class token does not index the colour table")
T.expectEqual(colored, "<colored>Thrall", "the client's class colour API colours the name")
T.expect(classColorCalls == 1, "the colour is asked of C_ClassColor")
classColorFails = true
local plain = T.expectNoError(function() return ClassColorName("party4") end,
                              "a refused secret class token does not raise an error")
T.expectEqual(plain, "Thrall", "the plain name is returned when the colour API refuses")
classColorFails = false

local secretUnitName = stubs.secret("restricted name")
units.party5 = { secretUnitName, "WARRIOR" }
local result = T.expectNoError(function() return ClassColorName("party5", 2) end,
                               "a secret name is not cut or measured")
T.expectEqual(result, "<colored>" .. tostring(secretUnitName), "a secret name is coloured by the client API")
units.party6 = { secretUnitName, nil }
T.expect(ClassColorName("party6") == secretUnitName, "a secret name without a class is returned as is")
units.party7 = { secretUnitName, secretClass }
classColorFails = true
T.expect(T.expectNoError(function() return ClassColorName("party7") end,
                         "a secret name with a secret class does not raise an error") == secretUnitName,
         "the secret name is returned when the colour API refuses")
classColorFails = false

T.section("the helpers are the ones custom code sees")
local fn = WeakAuras.LoadFunction("return function() return WA_Utf8Sub, WA_ClassColorName end", "test")
local sandboxUtf8Sub, sandboxClassColorName = fn()
T.expect(sandboxUtf8Sub == Utf8Sub and sandboxClassColorName == ClassColorName,
         "custom code gets the same helpers")

T.finish()
