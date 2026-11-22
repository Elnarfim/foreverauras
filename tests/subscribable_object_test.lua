-- SubscribableObject.lua: the publish/subscribe object that regions, sub
-- regions and the options use to pass events around. Subscribers are called
-- in order, high-priority ones first; the status callback fires when an event
-- gains its first or loses its last subscriber; the ForeverAuras "changed"
-- callback fires on every add and remove.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

stubs.install()
_G.WeakAuras = stubs.newWeakAuras()
local Private = stubs.newPrivate()
T.loadAddonFile("ForeverAuras/SubscribableObject.lua", "ForeverAuras", Private)

local calls = {}
local function subscriber(name)
  return {
    name = name,
    Update = function(self, ...)
      calls[#calls + 1] = self.name .. "(" .. table.concat({ ... }, ",") .. ")"
    end,
  }
end
local function takeCalls()
  local result = table.concat(calls, " ")
  calls = {}
  return result
end

T.section("subscribers are notified in order")
local object = Private.CreateSubscribableObject()
local a, b, c = subscriber("a"), subscriber("b"), subscriber("c")
object:AddSubscriber("Update", a)
object:AddSubscriber("Update", b)
object:AddSubscriber("Update", c, true)
object:Notify("Update", 1, 2)
T.expectEqual(takeCalls(), "c(1,2) a(1,2) b(1,2)", "a high-priority subscriber goes first, the rest in order")
object:AddSubscriber("Update", a)
object:Notify("Update")
T.expectEqual(takeCalls(), "c() a() b()", "subscribing twice does not call twice")
object:RemoveSubscriber("Update", a)
object:Notify("Update")
T.expectEqual(takeCalls(), "c() b()", "a removed subscriber is not called")
T.expectNoError(function()
  object:RemoveSubscriber("Update", a)
  object:RemoveSubscriber("Missing", a)
end, "removing a subscriber that is not there is harmless")
object:Notify("NobodyListens", 1)
T.expectEqual(takeCalls(), "", "an event without subscribers calls nobody")

T.section("a subscriber needs a handler for the event")
local printed = 0
local realPrint = print
print = function() printed = printed + 1 end
object:AddSubscriber("Other", a)
print = realPrint
T.expect(printed == 1 and not object:HasSubscribers("Other"), "a subscriber without the handler is refused with a message")

T.section("callbacks")
local status, changed = 0, 0
local watched = Private.CreateSubscribableObject()
watched:SetOnSubscriptionStatusChanged("Update", function() status = status + 1 end)
watched:SetOnSubscriberChanged("Update", function() changed = changed + 1 end)
T.expect(not watched:HasSubscribers("Update"), "a new object has no subscribers")
watched:AddSubscriber("Update", a)
T.expect(status == 1 and changed == 1 and watched:HasSubscribers("Update"), "the first subscriber fires both callbacks")
watched:AddSubscriber("Update", b)
T.expect(status == 1 and changed == 2, "a second subscriber fires only the changed callback")
watched:AddSubscriber("Update", b)
T.expect(changed == 2, "a repeated subscription fires nothing")
watched:RemoveSubscriber("Update", a)
T.expect(status == 1 and changed == 3, "removing one of two fires only the changed callback")
watched:RemoveSubscriber("Update", b)
T.expect(status == 2 and changed == 4 and not watched:HasSubscribers("Update"),
         "removing the last subscriber fires both callbacks")
watched:ClearCallbacks()
watched:AddSubscriber("Update", a)
T.expect(status == 2 and changed == 4, "cleared callbacks are not called")
watched:ClearSubscribers()
T.expect(not watched:HasSubscribers("Update"), "ClearSubscribers removes everyone")

T.section("objects are independent")
local first, second = Private.CreateSubscribableObject(), Private.CreateSubscribableObject()
first:AddSubscriber("Update", a)
T.expect(not second:HasSubscribers("Update"), "subscribing to one object does not subscribe to another")
second:Notify("Update", "x")
T.expectEqual(takeCalls(), "", "notifying another object does not reach the first one's subscribers")

T.finish()
