-- Modified for ForeverAuras, 2026-11-26.
-- Modifications Copyright (C) 2026 ForeverAuras. Licensed under the GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end

---@class Private
local Private = select(2, ...)

-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame = Private.TimedAPI("LibSpecializationWrapper")
local LibSpec = LibStub("LibSpecialization")

local nameToSpecMap = {}
local nameToTalents = {}
local nameToUnitMap = {}

-- Saved load conditions use the client's specialization ID. On Forever this
-- is one starter spec per class, including before the first talent is spent.
local function PublicId(value)
  return not issecretvalue(value) and type(value) == "number" and value > 0
end

local function PublicRole(value)
  if not issecretvalue(value) and (value == "TANK" or value == "HEALER" or value == "DAMAGER") then
    return value
  end
end

local lastSpec, lastRole
local function PlayerSpec()
  local ok, index = pcall(Private.ExecEnv.GetSpecialization)
  if not ok or not PublicId(index) then return lastSpec, lastRole end
  local infoOK, id, _, _, _, infoRole = pcall(Private.ExecEnv.GetSpecializationInfo, index)
  if not infoOK or not PublicId(id) then return lastSpec, lastRole end
  local getById = C_SpecializationInfo.GetSpecializationInfoByID or GetSpecializationInfoByID
  local role
  if getById then
    local roleOK, _, _, _, _, byIdRole = pcall(getById, id)
    if roleOK then role = PublicRole(byIdRole) end
  end
  lastRole = role or PublicRole(infoRole) or (lastSpec == id and lastRole or nil)
  lastSpec = id
  return id, lastRole
end

local function PublicName(unit)
  if C_Secrets.ShouldUnitIdentityBeSecret(unit) then return end
  if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
    local first, last = UnitNameUnmodified(unit)
    if issecretvalue(first) or issecretvalue(last) or type(first) ~= "string" then return end
    if type(last) == "string" and last ~= "" then return first .. " " .. last end
    return first
  end
  local name = GetUnitName(unit, true)
  if not issecretvalue(name) and type(name) == "string" then return name end
end

-- Map a peer's public class to the same ID offered by the load-condition
-- picker. A client with multiple specializations for that class is ambiguous.
local function PeerSpec(unit, wireSpec)
  if WOW_PROJECT_ID ~= 18 then return wireSpec end
  local _, _, classID = UnitClass(unit)
  if not PublicId(classID) then return end
  local count = Private.ExecEnv.GetNumSpecializationsForClassID(classID)
  if not issecretvalue(count) and count == 1 then
    local id = Private.ExecEnv.GetSpecializationInfoForClassID(classID, 1)
    if PublicId(id) then return id end
  end
end

--- @type function[]
local subscribers = {}

--- @class LibSpecWrapper
--- @field Register fun(callback: fun(unit: string))
--- @field SpecForUnit fun(unit: string): number?
--- @field SpecRolePositionForUnit fun(unit: string): number?, string?, string?
--- @field CheckTalentForUnit fun(unit: string, talentId: number): boolean?

Private.LibSpecWrapper = {
  Register = function(callback) end,
  SpecForUnit = function(unit) end,
  SpecRolePositionForUnit = function(unit) end,
  CheckTalentForUnit = function(unit) end,
}
if LibSpec then
  local unresolved = {}
  local lastResolveTime
  local frame = CreateFrame("Frame")

  local function RememberUnit(unit)
    local name = PublicName(unit)
    if name then
      if nameToUnitMap[name] ~= "player" then nameToUnitMap[name] = unit end
      unresolved[unit] = nil
    else
      unresolved[unit] = true
    end
  end

  local function ResolveUnseen()
    lastResolveTime = GetTime()
    for unit in pairs(unresolved) do RememberUnit(unit) end
    if not next(unresolved) then frame:UnregisterEvent("ADDON_RESTRICTION_STATE_CHANGED") end
  end

  local function Notify(unit)
    for _, f in ipairs(subscribers) do f(unit) end
  end

  local reportedSpec, reportedRole
  local function PlayerChanged()
    local spec, role = PlayerSpec()
    if spec ~= reportedSpec or role ~= reportedRole then
      reportedSpec, reportedRole = spec, role
      Notify("player")
    end
  end

  frame:RegisterEvent("PLAYER_LOGIN")
  frame:RegisterEvent("GROUP_ROSTER_UPDATE")
  frame:SetScript("OnEvent", function(_, event)
    if event == "ADDON_RESTRICTION_STATE_CHANGED" then ResolveUnseen(); return end
    wipe(nameToUnitMap)
    wipe(unresolved)
    lastResolveTime = nil
    if IsInRaid() then
      for i = 1, GetNumGroupMembers() do RememberUnit(WeakAuras.raidUnits[i]) end
    else
      for i = 1, GetNumSubgroupMembers() do RememberUnit(WeakAuras.partyUnits[i]) end
    end
    RememberUnit("player")
    if next(unresolved) then frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
    else frame:UnregisterEvent("ADDON_RESTRICTION_STATE_CHANGED") end
    for name in pairs(nameToSpecMap) do
      if not nameToUnitMap[name] then
        nameToSpecMap[name] = nil
        nameToTalents[name] = nil
      end
    end
    if event == "PLAYER_LOGIN" then PlayerChanged() end
  end)

  local function LibSpecCallback(wireSpec, role, position, sender, talentString)
    if issecretvalue(sender) or type(sender) ~= "string" or not PublicId(wireSpec)
      or issecretvalue(role) or issecretvalue(position) or issecretvalue(talentString) then return end
    local unit = nameToUnitMap[sender]
    -- A public report can arrive before our restriction-change handler.
    -- Retry only the unidentified roster slots, once per frame across senders.
    if not unit and next(unresolved) and lastResolveTime ~= GetTime() then
      ResolveUnseen()
      unit = nameToUnitMap[sender]
    end
    if not unit or unit == "player" or PublicName(unit) ~= sender then return end
    local id = PeerSpec(unit, wireSpec)
    if not id then return end

    local old = nameToSpecMap[sender]
    if old and old[1] == id and old[2] == role and old[3] == position and old[4] == talentString then return end
    nameToSpecMap[sender] = {id, role, position, talentString}
    nameToTalents[sender] = nil
    Notify(unit)
  end

  LibSpec.RegisterGroup(Private.LibSpecWrapper, LibSpecCallback)
  LibSpec.RegisterPlayerSpecChange(Private.LibSpecWrapper, PlayerChanged)

  function Private.LibSpecWrapper.Register(f)
    tinsert(subscribers, f)
  end

  function Private.LibSpecWrapper.SpecRolePositionForUnit(unit)
    if issecretvalue(unit) or type(unit) ~= "string" then return end
    if unit == "player" then return PlayerSpec() end
    local name = PublicName(unit)
    if not name then return end
    if nameToUnitMap[name] == "player" then return PlayerSpec() end
    local data = nameToSpecMap[name]
    if data then return unpack(data, 1, 4) end
  end

  function Private.LibSpecWrapper.SpecForUnit(unit)
    return (Private.LibSpecWrapper.SpecRolePositionForUnit(unit))
  end

  -- Group messages can contain a loadout string. Check its header against
  -- this member's client spec before asking the client for any talent tree.
  local function ReadTalents(data)
    local text = data[4]
    if type(text) ~= "string" or not text:match("^[%w+/]+$") then return false end
    local stream = CreateAndInitFromMixin(ImportDataStreamMixin, text)
    local bits = stream:GetNumberOfBits()
    if bits < 152 then return false end
    local version = stream:ExtractValue(8)
    local spec = stream:ExtractValue(16)
    if spec ~= data[1] or (version ~= 1 and version ~= 2)
      or version ~= C_Traits.GetLoadoutSerializationVersion() then return false end
    for _ = 1, 16 do stream:ExtractValue(8) end
    bits = bits - 152

    local tree = C_ClassTalents.GetTraitTreeForSpec(spec)
    if not PublicId(tree) then return end
    local nodes = C_Traits.GetTreeNodes(tree)
    if not nodes or #nodes == 0 then return end
    local _, _, talents = Private.GetTalentData(spec)
    if not talents or not next(talents) then return end
    local results = {}
    local function read(width)
      bits = bits - width
      if bits >= 0 then return stream:ExtractValue(width) end
    end
    for _, nodeId in ipairs(nodes) do
      local selected = read(1) == 1
      local choice, partialRank = 1, nil
      if selected and (version == 1 or read(1) == 1) then
        if read(1) == 1 then partialRank = read(6) end
        if read(1) == 1 then
          local choiceIndex = read(2)
          if choiceIndex == nil then return false end
          choice = choiceIndex + 1
        end
      end
      if bits < 0 then return false end
      local entries = talents[nodeId]
      if entries then
        for index, entry in pairs(entries) do
          results[entry[1]] = selected and choice == index and (partialRank or entry[5]) or 0
        end
      end
    end
    return results
  end

  function Private.LibSpecWrapper.CheckTalentForUnit(unit, talentId)
    if issecretvalue(unit) or type(unit) ~= "string" then return end
    if unit == "player" then return select(4, WeakAuras.GetTalentById(talentId)) end
    local name = PublicName(unit)
    if not name then return end
    if nameToUnitMap[name] == "player" then return select(4, WeakAuras.GetTalentById(talentId)) end
    local data = nameToSpecMap[name]
    if not data or not data[4] then return end
    if nameToTalents[name] == nil then
      -- A temporarily unavailable client tree can be retried. A malformed
      -- message is remembered until this member supplies another loadout.
      local ok, result = pcall(ReadTalents, data)
      if ok then nameToTalents[name] = result end
    end
    local talents = nameToTalents[name]
    if talents then return talents[talentId] end
  end

end

-- Export for GenericTrigger
WeakAuras.SpecForUnit = Private.LibSpecWrapper.SpecForUnit
WeakAuras.SpecRolePositionForUnit = Private.LibSpecWrapper.SpecRolePositionForUnit
WeakAuras.CheckTalentForUnit = Private.LibSpecWrapper.CheckTalentForUnit

if Private.LibSpecWrapper.CheckGlyphForUnit then
  WeakAuras.CheckGlyphForUnit = Private.LibSpecWrapper.CheckGlyphForUnit
else
  WeakAuras.CheckGlyphForUnit = function() return nil end
end
