-- Import and export strings (Transmission.lua). ForeverAuras exports in the
-- WeakAuras "!WA:2!" format and must keep reading every format WeakAuras ever
-- wrote, since players paste old WeakAuras strings into the import box. A
-- string that is not an aura must come back as an error message, never as a
-- Lua error. These checks use the real compression and serialization
-- libraries from ForeverAuras/Libs and are skipped when those are missing.
local testsDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = testsDir .. "/?.lua;" .. package.path
local T = require("helpers")
local stubs = require("wow_stubs")

local libFiles = {
  "LibStub/LibStub.lua",
  "LibDeflate/LibDeflate.lua",
  "LibSerialize/LibSerialize.lua",
  "AceSerializer-3.0/AceSerializer-3.0.lua",
  "LibCompress/LibCompress.lua",
}
local available, missing = T.libsAvailable(libFiles)
if not available then
  T.skip("import and export strings", missing)
  T.finish()
end

stubs.install()
_G.LibStub = nil
for _, file in ipairs(libFiles) do
  T.loadLib(file)
end
local LibStub = _G.LibStub
-- Chat transfer libraries: Transmission.lua only registers handlers at load.
LibStub:NewLibrary("AceComm-3.0", 1).RegisterComm = function() end
LibStub:NewLibrary("Chomp", 1).RegisterAddonPrefix = function() end
local LibDeflate = LibStub("LibDeflate")
local LibSerialize = _G.ForeverAurasLibSerialize
local AceSerializer = LibStub("AceSerializer-3.0")
local LibCompress = LibStub("LibCompress")

_G.ChatFrame_AddMessageEventFilter = function() end
_G.StaticPopupDialogs = {}
_G.WeakAuras = stubs.newWeakAuras()
_G.ForeverAuras = _G.WeakAuras
local WeakAuras = _G.WeakAuras
WeakAuras.versionString = "1.4.6-test"
WeakAuras.BuildInfo = 16001
local Private = stubs.newPrivate()

-- The stored auras of this test, by id.
local db = {}
WeakAuras.GetData = function(id) return db[id] end

-- Same walk as Traverse in ForeverAuras.lua: a group, then each child in
-- order, depth first.
local function traverse(data, includeSelf, includeGroups, includeLeafs)
  local isGroup = data.controlledChildren ~= nil
  if includeSelf and ((isGroup and includeGroups) or (not isGroup and includeLeafs)) then
    coroutine.yield(data)
  end
  for _, child in ipairs(data.controlledChildren or {}) do
    traverse(db[child], true, includeGroups, includeLeafs)
  end
end
Private.TraverseSubGroups = function(data)
  return coroutine.wrap(function() traverse(data, false, true, false) end)
end
Private.TraverseAllChildren = function(data)
  return coroutine.wrap(function() traverse(data, false, true, true) end)
end
-- A map of the test's own, so the checks do not depend on which fields
-- Types.lua lists today.
Private.non_transmissable_fields = { controlledChildren = true, parent = true, localOnly = true,
                                     information = { saved = true } }
Private.non_transmissable_fields_v2000 = { localOnly = true, information = { saved = true } }

T.loadAddonFile("ForeverAuras/Transmission.lua", "ForeverAuras", Private)

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

local function aura(id, extra)
  local data = {
    id = id,
    uid = id .. "-uid",
    regionType = "icon",
    triggers = { { trigger = { type = "aura2", auranames = { "Power Word: Fortitude" } }, untrigger = {} } },
    information = {},
  }
  for key, value in pairs(extra or {}) do
    data[key] = value
  end
  db[id] = data
  return data
end

T.section("an exported aura imports back unchanged")
local payload = {
  zero = 0, negative = -12.5, big = 2 ^ 40, small = 1e-7, yes = true, no = false,
  text = "pipes |cffff0000red|r, a newline\nand unicode: 火焰冲击 Jäger",
  list = { 1, 2, 3, { nested = "deep" } },
  sparse = { [1] = "a", [5] = "e" },
}
aura("Fortitude", { payload = payload, localOnly = "do not share", information = { saved = "SAVED", url = "x" } })
for _, forChat in ipairs({ true, false }) do
  local how = forChat and "chat" or "addon channel"
  local exported = Private.DisplayToString("Fortitude", forChat)
  T.expect(type(exported) == "string" and exported:sub(1, 6) == "!WA:2!", how .. ": the export uses the !WA:2! format")
  local imported = Private.StringToTable(exported, forChat)
  if T.expect(type(imported) == "table", how .. ": the export decodes to a table") then
    T.expectEqual(imported.m, "d", how .. ": the message is a display")
    T.expectEqual(imported.d and imported.d.id, "Fortitude", how .. ": the aura id survives")
    T.expectEqual(imported.d and imported.d.uid, "Fortitude-uid", how .. ": the aura uid survives")
    T.expectEqual(imported.s, "1.4.6-test", how .. ": the exporting version is recorded")
    T.expectEqual(imported.d and imported.d.tocversion, 16001, how .. ": the client build is recorded")
    T.expect(imported.d and deepEqual(imported.d.payload, payload), how .. ": numbers, booleans, text and nested tables survive")
    T.expect(imported.d and imported.d.localOnly == nil, how .. ": a non-transmissable field is left out")
    T.expect(imported.d and imported.d.information.saved == nil and imported.d.information.url == "x",
             how .. ": a nested non-transmissable field is left out, its siblings stay")
  end
end
T.expect(db.Fortitude.localOnly == "do not share" and db.Fortitude.information.saved == "SAVED",
         "the stored aura keeps its non-transmissable fields")
T.expect(Private.DisplayToString("does not exist", true) == "", "exporting an unknown id gives an empty string")

T.section("leftover custom code is only exported for custom triggers")
aura("Custom", {
  triggers = {
    { trigger = { type = "custom", custom = "function() return true end" }, untrigger = { custom = "function() end" } },
    { trigger = { type = "aura2", custom = "function() return 1 end", customName = "function() end" },
      untrigger = { custom = "function() end" } },
  },
})
local custom = Private.StringToTable(Private.DisplayToString("Custom", true), true)
if T.expect(type(custom) == "table" and custom.d, "the aura with custom code exports") then
  local triggers = custom.d.triggers
  T.expect(triggers[1].trigger.custom ~= nil and triggers[1].untrigger.custom ~= nil, "a custom trigger keeps its code")
  T.expect(triggers[2].trigger.custom == nil and triggers[2].trigger.customName == nil
           and triggers[2].untrigger.custom == nil, "a built-in trigger drops unused custom code")
end

T.section("a group exports with its children")
aura("A", { parent = "Root", uid = "same-uid" })
aura("C", { parent = "Sub" })
aura("B", { parent = "Root", uid = "same-uid" })
aura("Sub", { parent = "Root", regionType = "group", controlledChildren = { "C" } })
aura("Root", { regionType = "group", controlledChildren = { "A", "Sub", "B" } })
local group = Private.StringToTable(Private.DisplayToString("Root", true), true)
if T.expect(type(group) == "table" and type(group.c) == "table", "the group export lists its children") then
  T.expectEqual(group.v, 2000, "a group with a subgroup uses the nested-group version")
  local ids = {}
  for index, child in ipairs(group.c) do ids[index] = child.id end
  T.expectEqual(table.concat(ids, ","), "A,Sub,C,B", "children come after their group, in order")
  T.expect(group.c[1].uid ~= group.c[4].uid, "children that shared a uid are exported with distinct uids")
  T.expect(group.c[2].parent == "Root" and group.c[3].parent == "Sub", "nested groups keep their parent links")
end
local excluded = Private.StringToTable(Private.DisplayToString("Root", true, { Sub = true }), true)
if T.expect(type(excluded) == "table" and type(excluded.c) == "table", "a group exports with a child left out") then
  local ids = {}
  for index, child in ipairs(excluded.c) do ids[index] = child.id end
  T.expectEqual(table.concat(ids, ","), "A,B", "an excluded subgroup takes its children with it")
  T.expectEqual(table.concat(excluded.d.controlledChildren, ","), "A,B", "the group no longer lists the excluded child")
end
T.expectEqual(table.concat(db.Root.controlledChildren, ","), "A,Sub,B", "the stored group keeps all its children")

aura("Leaf1", { parent = "Flat" })
aura("Flat", { regionType = "dynamicgroup", controlledChildren = { "Leaf1" } })
local flat = Private.StringToTable(Private.DisplayToString("Flat", true), true)
T.expect(type(flat) == "table" and flat.v == 1421 and flat.d.controlledChildren == nil and flat.c[1].parent == nil,
         "a group without subgroups uses the older version, without parent links")

T.section("strings in the formats WeakAuras wrote are read")
local transmit = { m = "d", d = { id = "Old Aura", regionType = "text", displayText = "Hi |cff00ff00there|r" }, v = 1421 }
local function encodeV2(prefix, forChat)
  local compressed = LibDeflate:CompressDeflate(LibSerialize:Serialize(transmit), { level = 9 })
  local encoded = forChat and LibDeflate:EncodeForPrint(compressed) or LibDeflate:EncodeForWoWAddonChannel(compressed)
  return prefix .. encoded
end
-- Version 0: the inverse of decodeB64 in Transmission.lua.
local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()"
local function encodeB64(text)
  local out, bitfield, bitCount = {}, 0, 0
  for i = 1, #text do
    bitfield = bitfield + text:byte(i) * 2 ^ bitCount
    bitCount = bitCount + 8
    while bitCount >= 6 do
      local index = bitfield % 64
      out[#out + 1] = alphabet:sub(index + 1, index + 1)
      bitfield = math.floor(bitfield / 64)
      bitCount = bitCount - 6
    end
  end
  if bitCount > 0 then
    out[#out + 1] = alphabet:sub(bitfield + 1, bitfield + 1)
  end
  return table.concat(out)
end
local formats = {
  { "!WA:2! (WeakAuras 3+)", encodeV2("!WA:2!", true), true },
  { "!FA:2! (ForeverAuras prefix)", encodeV2("!FA:2!", true), true },
  { "!WA:2! over the addon channel", encodeV2("!WA:2!", false), false },
  { "! prefix (version 1, AceSerializer)",
    "!" .. LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(AceSerializer:Serialize(transmit))), true },
  { "no prefix (version 0, LibCompress)", encodeB64(LibCompress:Compress(AceSerializer:Serialize(transmit))), true },
}
for _, format in ipairs(formats) do
  local decoded = Private.StringToTable(format[2], format[3])
  T.expect(type(decoded) == "table" and deepEqual(decoded, transmit), format[1] .. " decodes to the original table")
end
local padded = "  \n" .. encodeV2("!WA:2!", true) .. "\t \n"
T.expect(deepEqual(Private.StringToTable(padded, true), transmit), "whitespace around a pasted string is ignored")

T.section("strings that are not auras give an error message")
local validPrint = LibDeflate:EncodeForPrint("this was never deflated")
local notSerialized = LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate("plain text, not LibSerialize"))
local rejects = {
  { "an empty string", "" },
  { "plain chat text", "hello, can you send me your aura?" },
  { "a URL", "https://example.invalid/foreverauras" },
  { "a prefix with nothing after it", "!WA:2!" },
  { "invalid characters after the prefix", "!WA:2!@@@@####" },
  { "encoded text that is not compressed", "!WA:2!" .. validPrint },
  { "compressed text that is not serialized", "!WA:2!" .. notSerialized },
  { "a truncated export", encodeV2("!WA:2!", true):sub(1, 40) },
  { "a version 1 string that is not compressed", "!" .. validPrint },
}
for _, reject in ipairs(rejects) do
  local ok, result = pcall(Private.StringToTable, reject[2], true)
  T.expect(ok, reject[1] .. ": no Lua error")
  if not ok then print("        error: " .. tostring(result)) end
  T.expect(ok and type(result) == "string", reject[1] .. ": an error message is returned")
end

T.section("random pasted text never raises a Lua error")
math.randomseed(20261121)
local raised = 0
local firstError
for round = 1, 300 do
  local length = math.random(0, 120)
  local chars = {}
  for i = 1, length do
    chars[i] = string.char(math.random(32, 126))
  end
  local prefix = ({ "", "!", "!WA:2!", "!FA:2!", "!WA:1!" })[round % 5 + 1]
  for _, fromChat in ipairs({ true, false }) do
    local ok, err = pcall(Private.StringToTable, prefix .. table.concat(chars), fromChat)
    if not ok then
      raised = raised + 1
      firstError = firstError or (prefix .. table.concat(chars) .. " -> " .. tostring(err))
    end
  end
end
T.expectEqual(raised, 0, "600 random strings decode or return an error message")
if firstError then print("        first: " .. firstError) end

T.finish()
