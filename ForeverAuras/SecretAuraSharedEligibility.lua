-- Copyright (C) 2026 ForeverAuras. GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
local Display = Private.BlizzardAuraDisplay
-- Stock registers every modern icon with Masque when the library is loaded.
-- An external skin may draw beyond the artwork-sized first-line viewport.
local masque = LibStub and LibStub("Masque", true)

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function denseLength(list)
  if type(list) ~= "table" then return end
  local count, last = 0, 0
  for index in pairs(list) do
    if not finite(index) or index < 1 or index ~= math.floor(index) then return end
    count = count + 1
    last = math.max(last, index)
  end
  if count == last then return count end
end

local function staticIDs(list)
  if not list then return 0 end
  local count = denseLength(list)
  if not count then return end
  for i = 1, count do
    local id = tonumber(list[i])
    if not finite(id) or id < 1 or id >= 2147483647 or id ~= math.floor(id) then return end
  end
  return count
end

local function numberIDs(enabled, list)
  if not enabled then return 0 end
  return staticIDs(list)
end

-- Compare only supported active load predicates. Picker payloads left by the
-- editor have no effect when their use_ flag is absent. More complex predicates
-- can depend on auxiliary fields; leave those rows with the ordinary builder.
local emptyLoad = {}
local stateLoads = {
  use_combat=true, use_alive=true, use_encounter=true, use_warmode=true, use_pvpmode=true,
  use_petbattle=true, use_vehicle=true, use_vehicleUi=true, use_mounted=true,
  use_addonRestrictionsActive=true,
}
local pickerLoads = {
  use_class="class", use_class_and_spec="class_and_spec", use_race="race",
  use_faction="faction", use_role="role", use_ingroup="ingroup",
}

local function validChoice(value)
  return type(value) == "string" or finite(value)
end

local function pickerMatches(single, left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  if single then return validChoice(left.single) and left.single == right.single end
  local a, b = left.multi, right.multi
  if type(a) ~= "table" or type(b) ~= "table" or not next(a) then return false end
  for key, value in pairs(a) do
    if not validChoice(key) or type(value) ~= "boolean" or b[key] ~= value then return false end
  end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

-- The selected member must carry every active condition of its containing
-- group. Comparing both directions for siblings also checks extra conditions.
local function includesLoad(member, required)
  if member == nil then member = emptyLoad end
  if required == nil then required = emptyLoad end
  if type(member) ~= "table" or type(required) ~= "table" then return false end
  for key, value in pairs(required) do
    if type(key) == "string" and key:sub(1, 4) == "use_" and not (key == "use_never" and value == false) then
      if type(value) ~= "boolean" or member[key] ~= value then return false end
      local picker = pickerLoads[key]
      if picker then
        if not pickerMatches(value, member[picker], required[picker]) then return false end
      elseif not stateLoads[key] then
        return false
      end
    end
  end
  return true
end

local function effects(data)
  if data.conditions and (type(data.conditions) ~= "table" or next(data.conditions)) then return true end
  if data.actions and type(data.actions) ~= "table" then return true end
  for _, action in pairs(data.actions or {}) do
    if type(action) ~= "table" then return true end
    for key, enabled in pairs(action) do
      if type(key) == "string" and key:sub(1, 3) == "do_" and enabled then return true end
    end
  end
  if data.animation and type(data.animation) ~= "table" then return true end
  for _, anim in pairs(data.animation or {}) do
    if type(anim) ~= "table" or (anim.type and anim.type ~= "none") then return true end
  end
  return false
end

-- The ordinary and shared first-line windows have room above and below each
-- cell. Admit bounded, single-line native countdowns and stack counts. Other
-- text can run custom code or project onto a second line outside that window.
local textPoints = {CENTER=true, LEFT=true, RIGHT=true, TOP=true, BOTTOM=true,
  TOPLEFT=true, TOPRIGHT=true, BOTTOMLEFT=true, BOTTOMRIGHT=true}
local textAnchorPoints = {}
for point in pairs(textPoints) do
  textAnchorPoints[point], textAnchorPoints["INNER_"..point], textAnchorPoints["OUTER_"..point] = true, true, true
end
local textOffsetKeys = {"anchorXOffset", "anchorYOffset", "text_anchorXOffset", "text_anchorYOffset",
  "text_shadowXOffset", "text_shadowYOffset"}
local function boundedText(element)
  if element.text_visible == false then return true end
  if element.secretAuraDetached then return false end
  local text = element.text_text
  if text ~= "%p" and text ~= "%s" then return false end
  if element.rotateText and element.rotateText ~= "NONE" then return false end
  if element.anchor_point and not textAnchorPoints[element.anchor_point] then return false end
  if element.text_selfPoint and element.text_selfPoint ~= "AUTO" and not textPoints[element.text_selfPoint] then return false end
  if element.text_automaticWidth and element.text_automaticWidth ~= "Auto" then return false end
  local size = element.text_fontSize or 18
  if not finite(size) or size <= 0 or size > 32 then return false end
  for _, key in ipairs(textOffsetKeys) do
    local offset = element[key] or 0
    if not finite(offset) or math.abs(offset) > 32 then return false end
  end
  return true
end

local function simpleAppearance(data)
  local settings = data.blizzardAuraDisplay or {}
  if type(settings) ~= "table" or settings.glow or settings.unitGlow
    or (not settings.actionSounds and settings.soundMode and settings.soundMode ~= "none")
    or Display.AuraAnimation(data, "start") ~= "none" or Display.AuraAnimation(data, "main") ~= "none"
    or (data.alpha ~= nil and data.alpha ~= 1) or (data.frameStrata ~= nil and data.frameStrata ~= 1)
    or data.frameLevel ~= nil or (data.scale ~= nil and data.scale ~= 1) or data.useTooltip
    or (data.anchorFrameType and data.anchorFrameType ~= "SCREEN") or data.anchorFrameParent
    or tonumber(data.xOffset or 0) ~= 0 or tonumber(data.yOffset or 0) ~= 0 then return false end
  local elements = data.subRegions
  if elements == nil then return true end
  local count = denseLength(elements)
  if not count then return false end
  for i = 1, count do
    local element = elements[i]
    if type(element) ~= "table" then return false end
    if element.type == "subborder" then
      if element.border_visible ~= false and (not finite(element.border_offset or 0) or (element.border_offset or 0) > 0) then return false end
    elseif element.type ~= "subbackground" and not (element.type == "subglow" and not element.glow)
      and not (element.type == "subtext" and boundedText(element)) then
      -- A glyph/shadow/texture that extends beyond the artwork needs its own
      -- viewport parity proof, even if its anchor is inside the icon.
      return false
    end
  end
  return true
end

local function plainMember(data)
  if type(data) ~= "table" or data.regionType ~= "icon"
    or effects(data) or type(data.triggers) ~= "table" then return false end
  if (data.width ~= nil and not finite(data.width)) or (data.height ~= nil and not finite(data.height))
    or (data.progressSource and (type(data.progressSource) ~= "table" or not finite(data.progressSource[1])))
    or (data.triggers.activeTriggerMode and not finite(data.triggers.activeTriggerMode)) then return false end
  for key in pairs(data.triggers) do
    if type(key) == "number" and key ~= 1 then return false end
  end
  local entry = data.triggers[1]
  if type(entry) ~= "table" or type(entry.trigger) ~= "table" then return false end
  local trigger = Display.GetSavedTrigger(data)
  if trigger ~= entry.trigger or trigger.type ~= "secretAura" or trigger.unit ~= "player" or trigger.debuffType ~= "HELPFUL"
    or Display.ShowOn(trigger) ~= "showOnActive" or Display.IsSingle(trigger, data) or Display.UsesSpellList(trigger)
    or trigger.secretUseTotal or trigger.secretUseStacks or trigger.secretGained or trigger.secretTracking
    or trigger.ignoreDead or trigger.ignoreSelf or trigger.ignoreDisconnected or trigger.ignoreInvisible
    or trigger.useUnitNames or trigger.useUnitRoles or trigger.useUnitClass or trigger.useHostility
    or trigger.unitExists or (trigger.auraTracking and trigger.auraTracking ~= "native") then return false end
  if (trigger.auraspellids and type(trigger.auraspellids) ~= "table")
    or (trigger.excludedAuraSpellIDs and type(trigger.excludedAuraSpellIDs) ~= "table")
    or (trigger.nativeFilters and type(trigger.nativeFilters) ~= "table")
    or (trigger.includeDispelTypes and type(trigger.includeDispelTypes) ~= "table")
    or (trigger.excludeDispelTypes and type(trigger.excludeDispelTypes) ~= "table")
    or Display.HasAdditionalFilters(trigger) or not simpleAppearance(data) then return false end
  local exact = numberIDs(Display.UsesSpellIDs(trigger), trigger.auraspellids)
  -- The authored selection must be numeric. Its expanded ranks can change
  -- after a name scan; the shared renderer listens for its completion.
  local ranks = numberIDs(Display.UsesRankSpellIDs(trigger), trigger.auraRankSpellIDs)
  return exact and ranks and exact + ranks > 0
end

local function screenAncestors(group, load, anchorAncestors, rowID)
  local seen
  while group.parent do
    seen = seen or {}
    if seen[group] then return false end
    seen[group] = true
    group = WeakAuras.GetData(group.parent)
    if not group or group.id == rowID or group.regionType ~= "group" or group.blizzardFlow or group.anchorFrameParent
      or (group.anchorFrameType and group.anchorFrameType ~= "SCREEN")
      or not includesLoad(load, group.load) or effects(group) then return false end
    if anchorAncestors then anchorAncestors[#anchorAncestors + 1] = group.id end
  end
  return true
end

-- A plan contains only public saved configurations. Its owner discards it on
-- edits, retirement or roster changes. No aura assignment or live geometry is read.
function Display.SharedRowPlan(group)
  if masque or type(group) ~= "table" or group.regionType ~= "group" or not group.blizzardFlow or not Display.FlowGroupOwned(group)
    or Display.FlowGrid(group) or group.blizzardFlowFrames ~= nil
    or group.anchorFrameParent or Display.FlowSortMode(group) ~= "none"
    or not group.blizzardFlowUseLimit or effects(group) then return end
  local growth = Display.FlowGrowthKey(group)
  if growth ~= "RIGHT" and growth ~= "CENTER_HORIZONTAL" then return end
  local anchorID, target, externalFrameName
  if group.anchorFrameType and group.anchorFrameType ~= "SCREEN" then
    if group.anchorFrameType ~= "SELECTFRAME" or group.anchorFrameParent ~= false or not Private.AuraFrameTarget then return end
    anchorID = Private.AuraFrameTarget(group.anchorFrameFrame)
    if anchorID then
      target = WeakAuras.GetData(anchorID)
      if not target or target.id ~= anchorID or target == group
        or (target.regionType ~= "group" and target.regionType ~= "dynamicgroup")
        or target.blizzardFlow or target.anchorFrameParent
        or (target.anchorFrameType and target.anchorFrameType ~= "SCREEN") or effects(target) then return end
    else
      -- The ordinary anchor resolver validates the actual object at commit.
      -- A dotted path, custom expression, or unavailable resolver stays ordinary.
      local name = group.anchorFrameFrame
      if not Private.GetSanitizedFrame or type(name) ~= "string" or not name:match("^[%a_][%w_]*$")
        or name == "_G" or name == "getglobal" then return end
      externalFrameName = name
    end
  end
  local cap = tonumber(group.blizzardFlowLimit or 5)
  local space = tonumber(group.blizzardFlowSpacing or 2)
  if not finite(cap) or cap < 1 or cap > 10 or cap ~= math.floor(cap) or not finite(space) or space < 0 then return end
  local count = denseLength(group.controlledChildren)
  if not count or count < 2 then return end
  local members, indices, width, height, memberLoad, anchorAncestors = {}, {}
  for i, id in ipairs(group.controlledChildren) do
    if type(id) ~= "string" or indices[id] then return end
    local child = WeakAuras.GetData(id)
    if not child or child.id ~= id or child.parent ~= group.id or not plainMember(child) then return end
    if i == 1 then
      memberLoad = child.load
      if not includesLoad(memberLoad, memberLoad) or not includesLoad(memberLoad, group.load)
        or not screenAncestors(group, memberLoad) then return end
      if target then
        anchorAncestors = {anchorID}
        if not includesLoad(memberLoad, target.load)
          or not screenAncestors(target, memberLoad, anchorAncestors, group.id) then return end
      end
    elseif not includesLoad(memberLoad, child.load) or not includesLoad(child.load, memberLoad) then
      return
    end
    local w, h = Display.Dimensions(child)
    if not finite(w) or not finite(h) or (width and (w ~= width or h ~= height)) then return end
    width, height = w, h
    members[i], indices[id] = child, i
  end
  return {group=group, members=members, indices=indices, anchorID=anchorID, anchorAncestors=anchorAncestors, externalFrameName=externalFrameName}
end

function Display.SharedRowMatch(data, plan)
  local group = Display.FlowGroup(data)
  if not group then return end
  plan = plan or Display.SharedRowPlan(group)
  if not plan or plan.group ~= group then return end
  local index = plan.indices[data.id]
  if index and plan.members[index] == data then return group, index, plan end
end
