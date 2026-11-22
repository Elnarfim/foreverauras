-- The options panel compiles stored aura code to show errors under the code
-- box, and AceConfig evaluates the name and hidden callbacks of that label on
-- every render. That evaluation must stay inside the sandbox: an imported aura
-- must not run with the real global table just because its options are open.
-- Ported from the WeakAuras2 test of the same name.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
local realG = _G
_G.WeakAuras = stubs.permissive(stubs.newWeakAuras())
_G.ForeverAuras = _G.WeakAuras
local Private, warnings = stubs.newPrivate()

T.loadAddonFile("ForeverAuras/AuraEnvironment.lua", "ForeverAuras", Private)
local OptionsPrivate = stubs.permissive({ Private = Private })
T.loadAddonFile("ForeverAurasOptions/CommonOptions.lua", "ForeverAurasOptions", OptionsPrivate)

-- Custom Variables is registered without encloseInFunction and with a
-- validator, so its text is evaluated as an expression on every render.
local maliciousCode = table.concat({
  "(function()",
  "  _G.OWNED_FROM_OPTIONS = true",
  "  _G.SEEN_ENUMERATE = EnumerateFrames()",
  "  _G.SEEN_QUIT = Quit()",
  "  return {}",
  "end)()",
}, "\n")

local function buildErrorLabel(addCodeOption, code, validator, encloseInFunction)
  local data = { id = "victim", customVariables = code }
  local args = {}
  addCodeOption(args, data, "Custom Variables", "custom_variables", "https://example.invalid/wiki", 11,
                function() return false end, { "customVariables" }, encloseInFunction, { validator = validator })
  return args["custom_variables_customError"]
end

local addCodeOption = OptionsPrivate.commonOptions and OptionsPrivate.commonOptions.AddCodeOption
if T.expect(type(addCodeOption) == "function", "CommonOptions.lua exports AddCodeOption") then
  T.section("AddCodeOption: rendering the error label runs stored code only inside the sandbox")

  local validatedWith
  local label = buildErrorLabel(addCodeOption, maliciousCode, function(value)
    validatedWith = value
    return nil
  end)
  if T.expect(label and type(label.hidden) == "function" and type(label.name) == "function",
              "the error label has name and hidden callbacks") then
    for _, callback in ipairs({ "hidden", "name" }) do
      realG.OWNED_FROM_OPTIONS = nil
      realG.SEEN_ENUMERATE = nil
      realG.SEEN_QUIT = nil
      validatedWith = nil
      label[callback]()
      T.expect(realG.OWNED_FROM_OPTIONS == nil, callback .. ": the stored code does not write the real global table")
      T.expect(realG.SEEN_ENUMERATE ~= "REAL_EnumerateFrames", callback .. ": the stored code does not reach the real EnumerateFrames")
      T.expect(realG.SEEN_QUIT ~= "REAL_Quit", callback .. ": the stored code does not reach the real Quit")
      T.expect(type(validatedWith) == "table", callback .. ": the code was still evaluated and its result reached the validator")
    end
  end

  T.section("AddCodeOption: code wrapped in a function is only compiled, not run")
  realG.OWNED_FROM_OPTIONS = nil
  local wrapped = buildErrorLabel(addCodeOption, "_G.OWNED_FROM_OPTIONS = true", nil, true)
  wrapped.hidden()
  wrapped.name()
  T.expect(realG.OWNED_FROM_OPTIONS == nil, "a function body is not executed to render the label")
  T.expect(wrapped.hidden() == true, "valid code hides the label")

  T.section("AddCodeOption: the error label still reports problems")
  local broken = buildErrorLabel(addCodeOption, "{ this is not lua", function() return nil end)
  T.expect(broken.hidden() == false, "a syntax error shows the label")
  T.expect(type(broken.name()) == "string" and broken.name():find("|cFFFF0000", 1, true) ~= nil,
           "a syntax error is reported in red")
  local rejected = buildErrorLabel(addCodeOption, "{}", function() return "Not what I wanted" end)
  T.expect(rejected.name():find("Not what I wanted", 1, true) ~= nil, "a validator message is reported")
  local empty = buildErrorLabel(addCodeOption, "   ", function() return "unused" end)
  T.expect(empty.hidden() == true and empty.name() == "", "empty code shows no label")
end

T.expect(#warnings > 0, "the sandbox raised warnings while evaluating the malicious code")

T.finish()
