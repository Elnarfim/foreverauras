-- DurationText.lua: timer text for cooldowns and casts whose times the client
-- can hand out only as duration objects, which Lua cannot read in combat.
-- Remaining Time conditions that colour or hide such a text cannot run in Lua,
-- so DurationTextStyle turns them into a style the client's numeric formatter
-- draws by itself, and TimerConditionHandled tells the condition engine which
-- conditions that covers.
--
-- The client formatter is a stub that records its breakpoints. The checks read
-- them the way DurationText.lua's own Styled function does: a breakpoint
-- applies from its threshold up to the next breakpoint's threshold.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
_G.WeakAuras = stubs.newWeakAuras()
local WeakAuras = _G.WeakAuras
WeakAuras.IsDurationObject = function(value) return type(value) == "table" and value.isDuration == true end
_G.Enum = {
  NumericRuleFormatRounding = { Down = 0, Up = 1, Nearest = 2 },
  DurationTimeModifier = { RealTime = 0, BaseTime = 1 },
}
local created = 0
_G.C_StringUtil = {
  CreateNumericRuleFormatter = function()
    created = created + 1
    local formatter = {}
    function formatter:SetBreakpoints(rules) self.rules = rules end
    return formatter
  end,
}
local Private = stubs.newPrivate()
T.loadAddonFile("ForeverAuras/DurationText.lua", "ForeverAuras", Private)

--- The breakpoint that formats this many seconds of remaining time.
local function ruleAt(formatter, seconds)
  local found
  for _, rule in ipairs(formatter.rules) do
    if rule.threshold <= seconds then found = rule end
  end
  return found
end

local RED, YELLOW = { 1, 0, 0, 1 }, { 1, 1, 0, 1 }
local function remaining(op, value, changes, trigger)
  return { check = { variable = "expirationTime", trigger = trigger or 1, op = op, value = tostring(value) },
           changes = changes }
end
local function spellAura(extra)
  local data = { regionType = "icon", triggers = { { trigger = { type = "spell" } } }, conditions = {} }
  for key, value in pairs(extra or {}) do data[key] = value end
  return data
end

T.section("which triggers have restricted timers")
local mixed = { triggers = { { trigger = { type = "spell" } }, { trigger = { type = "aura2" } },
                             { trigger = { type = "event", event = "Cast" } }, { trigger = "broken" } } }
T.expect(Private.RestrictedTimerTrigger(mixed, 1), "a spell cooldown trigger is restricted")
T.expect(not Private.RestrictedTimerTrigger(mixed, 2), "an aura trigger is not")
T.expect(Private.RestrictedTimerTrigger(mixed, 3), "a cast trigger is restricted")
T.expect(not Private.RestrictedTimerTrigger(mixed, 4), "a malformed trigger entry is not")
T.expect(not Private.RestrictedTimerTrigger(mixed, 9), "a missing trigger is not")
T.expect(not Private.RestrictedTimerTrigger({}, 1), "an aura without triggers is not")

T.section("a Remaining Time colour condition becomes a text style")
local data = spellAura({ regionType = "text", displayText = "%p" })
data.conditions = { remaining("<=", 5, { { property = "color", value = RED } }) }
local style = Private.DurationTextStyle(data)
if T.expect(style and #style.conds == 1, "one condition gives one styled range") then
  local cond = style.conds[1]
  T.expect(cond[1] == -math.huge and cond[2] > 5 and cond[2] < 5.001, "<= 5 covers everything up to and including 5 seconds")
  T.expectEqual(cond[3], "|cffff0000", "the colour becomes a colour code")
  T.expect(style.baseVisible == true and not style.usesVisible, "a colour change leaves the text visible")
end
data.conditions = { remaining(">", 10, { { property = "color", value = YELLOW } }) }
style = Private.DurationTextStyle(data)
T.expect(style and style.conds[1][1] > 10 and style.conds[1][2] == math.huge and style.conds[1][3] == "|cffffff00",
         "> 10 covers everything above 10 seconds")
data.conditions = { remaining("<=", 5, { { property = "color", value = RED } }) }
data.conditions[1].linked = true
T.expect(Private.DurationTextStyle(data) == nil, "a linked condition is left to the condition engine")
data.conditions = { remaining("<=", 5, { { property = "alpha", value = 0.5 } }) }
T.expect(Private.DurationTextStyle(data) == nil, "a condition that changes no text colour gives no style")
data.conditions = { remaining("<=", 5, { { property = "color", value = RED } }, 2) }
T.expect(Private.DurationTextStyle(data) == nil, "a condition on another trigger's timer gives no style")
T.expect(Private.DurationTextStyle(spellAura({ regionType = "text", displayText = 42 })) == nil,
         "a text that is not a string gives no style")

T.section("another condition on the same colour keeps it in the condition engine")
data = spellAura({ regionType = "text", displayText = "%p" })
data.conditions = {
  remaining("<=", 5, { { property = "color", value = RED } }),
  { check = { variable = "stacks", trigger = 1, op = ">", value = "2" }, changes = { { property = "color", value = YELLOW } } },
}
T.expect(Private.DurationTextStyle(data) == nil, "a stacks condition on the colour turns the style off")

T.section("which trigger a text's timer reads")
local twoSpells = { regionType = "text", displayText = "%2.p",
                    triggers = { { trigger = { type = "spell" } }, { trigger = { type = "spell" } } },
                    conditions = { remaining("<=", 3, { { property = "color", value = RED } }, 2) } }
T.expect(Private.DurationTextStyle(twoSpells) ~= nil, "%2.p reads the second trigger")
twoSpells.displayText = "%{2.p}"
T.expect(Private.DurationTextStyle(twoSpells) ~= nil, "%{2.p} reads the second trigger")
twoSpells.displayText = "%p"
T.expect(Private.DurationTextStyle(twoSpells) == nil, "%p with two timer triggers is ambiguous")
twoSpells.triggers.activeTriggerMode = 2
T.expect(Private.DurationTextStyle(twoSpells) ~= nil, "%p follows a fixed active trigger")
local oneTimer = { regionType = "text", displayText = "%p",
                   triggers = { { trigger = { type = "aura2" } }, { trigger = { type = "spell" } } },
                   conditions = { remaining("<=", 3, { { property = "color", value = RED } }, 2) } }
T.expect(Private.DurationTextStyle(oneTimer) ~= nil, "%p reads the only trigger with a restricted timer")

T.section("sub texts can also be hidden when the timer is the whole text")
data = spellAura()
local element = { type = "subtext", text_text = "%p", text_visible = true }
data.subRegions = { { type = "subbackground" }, element }
data.conditions = { remaining(">", 10, { { property = "sub.2.text_visible", value = false } }) }
style = Private.DurationTextStyle(data, element, 2)
T.expect(style and style.usesVisible and style.conds[1][4] == false, "a visibility change becomes part of the style")
element.text_text = "%p left"
T.expect(Private.DurationTextStyle(data, element, 2) == nil, "hiding is not drawn when the text has more than the timer")
element.text_text = "%p"
data.conditions[1].changes = { { property = "sub.1.text_visible", value = false } }
T.expect(Private.DurationTextStyle(data, element, 2) == nil, "a change to another sub text does not count")
element.text_visible = false
data.conditions = { remaining("<=", 5, { { property = "sub.2.text_color", value = RED } }) }
style = Private.DurationTextStyle(data, element, 2)
T.expect(style and style.baseVisible == false, "a sub text that is hidden by default stays hidden outside the ranges")

T.section("the styled formatter colours each stretch of remaining time")
data = spellAura({ regionType = "text", displayText = "%p" })
data.conditions = {
  remaining("<=", 10, { { property = "color", value = YELLOW } }),
  remaining("<=", 3, { { property = "color", value = RED } }),
}
style = Private.DurationTextStyle(data)
local formatter = Private.GetDurationTextFormatter(0, 0, 0, false, nil, style)
T.expect(ruleAt(formatter, 2).format:find("|cffff0000", 1, true) == 1, "2s: the later, narrower condition wins (red)")
T.expect(ruleAt(formatter, 5).format:find("|cffffff00", 1, true) == 1, "5s: only the 10s condition covers it (yellow)")
T.expect(ruleAt(formatter, 20).format:find("|c", 1, true) == nil, "20s: no condition, no colour")
T.expect(ruleAt(formatter, 120).format == "%d:%02d", "120s: minutes and seconds, no colour")
T.expect(ruleAt(formatter, 0).format == "", "0s: no text")
for _, rule in ipairs(formatter.rules) do
  if rule.format:find("|c", 1, true) then
    T.expect(rule.format:sub(-2) == "|r", "a coloured breakpoint at " .. rule.threshold .. " closes its colour")
  end
end

data = spellAura()
element = { type = "subtext", text_text = "%p" }
data.subRegions = { element }
data.conditions = { remaining(">", 10, { { property = "sub.1.text_visible", value = false } }) }
formatter = Private.GetDurationTextFormatter(0, 0, 0, false, nil, Private.DurationTextStyle(data, element, 1))
T.expect(ruleAt(formatter, 30).format == "" and ruleAt(formatter, 30).components == nil, "30s: hidden above 10 seconds")
T.expect(ruleAt(formatter, 4).format ~= "", "4s: shown at or below 10 seconds")

T.section("formatters")
local before = created
local f1 = Private.GetDurationTextFormatter(0, 3, 1, false)
local f2 = Private.GetDurationTextFormatter(0, 3, 1, false)
T.expect(f1 == f2 and created == before + 1, "the same settings reuse one client formatter")
T.expect(Private.GetDurationTextFormatter(0, 3, 2, false) ~= f1, "other settings get their own formatter")
T.expect(ruleAt(f1, 2).format == "%.1f" and ruleAt(f1, 5).format == "%d", "below the threshold, decimals with the chosen precision")
T.expectEqual(ruleAt(Private.GetDurationTextFormatter(99, 0, 0, false), 5).rounding, Enum.NumericRuleFormatRounding.Up,
              "format 99 rounds whole seconds up, like the countdown")
T.expectEqual(ruleAt(Private.GetDurationTextFormatter(98, 0, 0, false), 5).rounding, Enum.NumericRuleFormatRounding.Nearest,
              "format 98 rounds to the nearest second")
T.expectEqual(ruleAt(Private.GetDurationTextFormatter(0, 0, 0, false), 5).rounding, Enum.NumericRuleFormatRounding.Down,
              "other formats round down")
T.expect(ruleAt(Private.GetDurationTextFormatter(0, 0, 0, true), 600).format == "%d", "seconds only never shows minutes")
T.expect(ruleAt(Private.GetDurationTextFormatter(0, 0, 0, false, -3), 7200).format == "%dh", "the short style shows hours")
T.expect(ruleAt(Private.GetDurationTextFormatter(0, 0, 0, false, -4), 3700).format == "%dh %dm", "the modern style shows hours and minutes")

T.section("which Remaining Time conditions still work in combat")
data = spellAura()
local function handled(condition) return Private.TimerConditionHandled(data, condition) end
T.expect(handled(remaining("<=", 5, { { property = "alpha", value = 0.5 } })), "an alpha change is handled")
T.expect(handled(remaining("<", 5, { { property = "color", value = RED } })), "a main colour change is handled")
T.expect(handled(remaining(">=", 5, { { property = "sub.3.text_color", value = RED },
                                      { property = "sub.3.text_visible", value = false } })),
         "sub text colour and visibility changes are handled")
T.expect(handled(remaining(">", 5, { { property = "barColor", value = RED } })), "a bar colour change is handled")
T.expect(not handled(remaining("<=", 5, { { property = "alpha", value = 0.5 }, { property = "glow", value = true } })),
         "a change the formatter cannot draw keeps the whole condition in Lua")
T.expect(not handled(remaining("==", 5, { { property = "alpha", value = 0.5 } })), "an equality check is not handled")
T.expect(not handled(remaining("<=", "soon", { { property = "alpha", value = 0.5 } })), "a non-numeric value is not handled")
T.expect(not handled(remaining("<=", 5, {})), "a condition without changes is not handled")
local linked = remaining("<=", 5, { { property = "alpha", value = 0.5 } })
linked.linked = true
T.expect(not handled(linked), "a linked condition is not handled")
data.triggers[1].trigger.type = "aura2"
T.expect(not handled(remaining("<=", 5, { { property = "alpha", value = 0.5 } })), "a condition on an aura timer is not handled")
T.expect(not Private.TimerConditionHandled(data, nil), "no condition is not handled")

T.section("when the timer text is hidden")
local duration = { isDuration = true }
T.expect(not Private.ShouldHideDurationText(nil), "no state: not hidden")
T.expect(not Private.ShouldHideDurationText({ progressType = "timed" }), "a plain timed state: not hidden")
T.expect(Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmGCDOnly = true }), "a GCD-only state with GCD text off: hidden")
T.expect(not Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmGCDOnly = true, cdmTextPreview = true }),
         "the options preview still shows its sample text")
T.expect(Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmTextDurationRequired = true }),
         "a required GCD-free duration that is missing: hidden")
T.expect(not Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmTextDurationRequired = true,
                                              cdmTextDurationObject = duration }),
         "a GCD-free duration that is present: shown")
T.expect(not Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmTextDurationRequired = true,
                                              progressType = "timed", expirationTime = 10, duration = 5 }),
         "a readable timed state needs no duration object: shown")
T.expect(Private.ShouldHideDurationText({ cdmHideGCDText = true, cdmTextDurationRequired = true,
                                          progressType = "timed", expirationTime = stubs.secret("end"), duration = 5 }),
         "a timed state with a secret time is not readable: hidden")
T.expect(Private.GetTextDuration({ cdmTextDurationObject = 1, durationObject = 2 }) == 1,
         "the GCD-free text duration is preferred over the swipe's")
T.expect(Private.UsesDurationText({ progressType = "durationObject", durationObject = duration }),
         "a duration-object state uses duration text")
T.expect(not Private.UsesDurationText({ progressType = "timed", durationObject = duration }), "a timed state does not")

T.finish()
