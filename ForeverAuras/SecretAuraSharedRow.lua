-- One Blizzard container per compatible horizontal row. Each member keeps
-- its own filter, native sorting and independent button initializer.
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
local Display = Private.BlizzardAuraDisplay
local _, _, HookMember = Private.TimedAPI("shared rows")
local rows, owners, hosts, retiring, byAncestor = {}, {}, {}, {}, {}
local blockedGroups, waiting = {}, {}
local watched = setmetatable({}, {__mode = "k"})
local excluded = setmetatable({}, {__mode = "k"})
local suspended, events = false, nil
local constructing = 0
local scaleEvents, buildEvents, recoveryEvents = false, false, false
local Stop, Commit, UpdateEvents
local nameWatchers, pendingRankUpdates = {}, {}
local updateScheduled = false
local worldEvents, watchWorld = false, false
local worldReadyAt, firstRepair, lastRepair, repairTimer
local settle = 0.6

local function Restricted()
  return InCombatLockdown() or (C_Secrets and C_Secrets.ShouldAurasBeSecret())
end

local function IsLive(owner)
  local id = owner.data.id
  local entry = Private.regions[id]
  return entry and entry.region == owner.region and Private.loaded[id] == true and WeakAuras.GetData(id) == owner.data
end

local function ExplicitlyShown(region)
  local ok, shown = pcall(region.IsShown, region)
  return ok and not issecretvalue(shown) and shown
end

local function HasOrdinary(region)
  local ordinary = region and region.blizzardAuraDisplay
  return ordinary and ordinary.instances and next(ordinary.instances) ~= nil
end

local function WatchPendingNames(owner, groupKey, ids)
  local names = Private.PendingAuraSpellNames(ids)
  if not names then return end
  assert(Private.OnSameNameScanned, "rank update listener unavailable")
  owner.pendingNames, owner.rankIDs, owner.groupKey = names, ids, groupKey
  for name in pairs(names) do
    local watchers = nameWatchers[name] or {}
    watchers[owner] = true
    nameWatchers[name] = watchers
  end
end

local function ForgetPendingNames(owner)
  pendingRankUpdates[owner] = nil
  if not owner.pendingNames then return end
  for name in pairs(owner.pendingNames) do
    local watchers = nameWatchers[name]
    watchers[owner] = nil
    if not next(watchers) then nameWatchers[name] = nil end
  end
  owner.pendingNames, owner.rankIDs, owner.groupKey = nil, nil, nil
end

local function SameIDs(a, b)
  for id in pairs(a) do if not b[id] then return false end end
  for id in pairs(b) do if not a[id] then return false end end
  return true
end

local function RefreshRankFilter(owner)
  local row = owner.row
  local entry = Private.regions[owner.data.id]
  assert(owners[owner.region] == owner and entry and entry.region == owner.region
    and WeakAuras.GetData(owner.data.id) == owner.data, "rank filter owner changed")
  local filters = Display.RawCandidateFilters(owner.data)
  if not SameIDs(owner.rankIDs, filters.includeSpellIDs) then
    row.container:SetAuraGroupCandidateFilters(owner.groupKey, filters)
    owner.rankIDs = filters.includeSpellIDs
  end
  if not next(owner.pendingNames) then owner.pendingNames, owner.rankIDs, owner.groupKey = nil, nil, nil end
  if not row.complete then Commit(row) end
end

local function RunRankUpdate()
  updateScheduled = false
  if not Restricted() then
    local owner = next(pendingRankUpdates)
    if owner then
      pendingRankUpdates[owner] = nil
      if not owner.row.dead and not pcall(RefreshRankFilter, owner) then Stop(owner.row) end
    end
    if next(pendingRankUpdates) then
      updateScheduled = true
      C_Timer.After(0, RunRankUpdate)
    end
  end
  UpdateEvents()
end

local function ScheduleRankUpdate()
  if not updateScheduled and next(pendingRankUpdates) and not Restricted() then
    -- One native filter setter can refresh an entire container. Bound a
    -- large batch of discovered names to one member per rendered frame.
    updateScheduled = true
    C_Timer.After(0, RunRankUpdate)
  end
end

local function RankNamesReady(names)
  if not next(nameWatchers) then return end
  for name in pairs(names) do
    local watchers = nameWatchers[name]
    if watchers then
      nameWatchers[name] = nil
      for owner in pairs(watchers) do
        owner.pendingNames[name] = nil
        pendingRankUpdates[owner] = true
      end
    end
  end
  if next(pendingRankUpdates) then
    ScheduleRankUpdate()
    UpdateEvents()
  end
end
if Private.OnSameNameScanned then Private.OnSameNameScanned(RankNamesReady) end

-- Pace physical list refreshes across rows. Row removal unlinks the pending
-- job immediately, including while combat or a loading screen has paused it.
local function CancelRepair(row)
  if not row.repairDue then return end
  if row.repairPrev then row.repairPrev.repairNext = row.repairNext else firstRepair = row.repairNext end
  if row.repairNext then row.repairNext.repairPrev = row.repairPrev else lastRepair = row.repairPrev end
  row.repairPrev, row.repairNext, row.repairDue = nil, nil, nil
end

local QueueRepairTimer

local function RunRepair()
  repairTimer = nil
  local row = firstRepair
  if row and worldReadyAt and not Restricted() and GetTime() >= math.max(row.repairDue, worldReadyAt) then
    CancelRepair(row)
    if not row.dead and row.complete then
      local ok, accepted = pcall(Display.RequestBoundAuraRefresh, row.container, "player", "player", true, true)
      if not ok or accepted ~= 1 then Stop(row) end
    end
  end
  QueueRepairTimer()
  UpdateEvents()
end

QueueRepairTimer = function()
  if not repairTimer and firstRepair and worldReadyAt and not Restricted() then
    local delay = math.max(0.05, math.max(firstRepair.repairDue, worldReadyAt) - GetTime())
    repairTimer = C_Timer.NewTimer(delay, RunRepair)
  end
end

local function QueueRepair(row)
  row.repairDue, row.repairPrev = GetTime() + settle, lastRepair
  if lastRepair then lastRepair.repairNext = row else firstRepair = row end
  lastRepair = row
  QueueRepairTimer()
end

local function FinishRetirement(row)
  -- A refused Hide and a refused disable can coincide in combat. Keep
  -- ownership until one of them succeeds, so stock cannot overlap the row.
  local hidden = not row.viewport or pcall(row.viewport.Hide, row.viewport)
  local disabled = not row.container or pcall(row.container.SetEnabled, row.container, false)
  if hidden or disabled then
    if blockedGroups[row.id] == row then blockedGroups[row.id] = nil end
    local restore = row.members
    row.members = nil
    if restore then
      for region, owner in pairs(restore) do
        if owners[region] == owner then owners[region] = nil end
      end
      for _, owner in pairs(restore) do
        if not owner.released and IsLive(owner) then Display.SharedRowRestore(owner.region, owner.data) end
      end
    end
    for region, request in pairs(row.waiting or {}) do
      waiting[region] = nil
      if IsLive(request) then Display.SharedRowRestore(region, request.data) end
    end
    row.waiting = nil
  else
    blockedGroups[row.id] = row
  end
  if disabled and row.container and pcall(Display.RetireFrame, row.container) then row.container = nil end
  if hidden and not row.container and row.viewport and pcall(Display.RetireFrame, row.viewport) then row.viewport = nil end
  if not row.container and not row.viewport then retiring[row] = nil end
end

Stop = function(row, skip)
  if not row then return end
  local owner = skip and owners[skip]
  if owner and owner.row == row then owner.released = true end
  if row.dead then return end
  row.dead = true
  CancelRepair(row)
  for _, owner in pairs(row.members) do ForgetPendingNames(owner) end
  if not row.complete then constructing = constructing - 1 end
  if row.host and hosts[row.host] == row then
    row.host.faSharedAuraRowMembers = nil
    hosts[row.host] = nil
  end
  row.host = nil
  rows[row.id] = nil
  excluded[row.group] = true
  for _, id in ipairs(row.ancestors) do
    local children = byAncestor[id]
    children[row] = nil
    if not next(children) then byAncestor[id] = nil end
  end
  for _, context in ipairs(row.callbacks) do
    for _, native in ipairs(context.buttons) do native.previewRowOwner = nil end
    context.row, context.region, context.data, context.style, context.buttons = nil, nil, nil, nil, nil
  end
  row.callbacks, row.indices, row.group, row.plan, row.ancestors = nil, nil, nil, nil, nil
  if row.timeout then row.timeout:Cancel(); row.timeout = nil end
  retiring[row] = true
  FinishRetirement(row)
  UpdateEvents()
end

local function OnEvent(_, event)
  if event == "PLAYER_ENTERING_WORLD" then
    worldReadyAt = GetTime() + settle
    QueueRepairTimer()
  elseif event == "PLAYER_LEAVING_WORLD" then
    worldReadyAt = nil
  elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
    for _, row in pairs(rows) do Stop(row) end
  elseif Restricted() then
    for _, row in pairs(rows) do if not row.complete then Stop(row) end end
  else
    for row in pairs(retiring) do FinishRetirement(row) end
    ScheduleRankUpdate()
    QueueRepairTimer()
  end
  UpdateEvents()
end

UpdateEvents = function()
  local needScale = next(rows) ~= nil
  local needBuild = constructing > 0
  local needRecovery = next(retiring) ~= nil or next(pendingRankUpdates) ~= nil or firstRepair ~= nil
  if scaleEvents == needScale and buildEvents == needBuild and recoveryEvents == needRecovery and worldEvents == watchWorld then return end
  if not events then
    events = CreateFrame("Frame")
    events:SetScript("OnEvent", OnEvent)
  end
  local function listen(name, enabled)
    if enabled then events:RegisterEvent(name) else events:UnregisterEvent(name) end
  end
  if worldEvents ~= watchWorld then
    listen("PLAYER_ENTERING_WORLD", watchWorld)
    listen("PLAYER_LEAVING_WORLD", watchWorld)
    worldEvents = watchWorld
  end
  if scaleEvents ~= needScale then
    listen("UI_SCALE_CHANGED", needScale)
    listen("DISPLAY_SIZE_CHANGED", needScale)
  end
  if buildEvents ~= needBuild then listen("PLAYER_REGEN_DISABLED", needBuild) end
  if recoveryEvents ~= needRecovery then listen("PLAYER_REGEN_ENABLED", needRecovery) end
  if (buildEvents or recoveryEvents) ~= (needBuild or needRecovery) then
    listen("ADDON_RESTRICTION_STATE_CHANGED", needBuild or needRecovery)
  end
  scaleEvents, buildEvents, recoveryEvents = needScale, needBuild, needRecovery
end

local function Geometry(group, region, data)
  local width, height = Display.Dimensions(data)
  local px = Display.CarrierPixelScale(region)
  assert(px and px > 0, "row scale unavailable")
  local w, h = Display.CarrierIconDimensions(region, width, height)
  local spacing = Display.FlowSpacing(group, region, width) + width - w
  local limit = Display.FlowLimit(data)
  assert(limit and limit >= 1 and w > 0 and h > 0 and w + spacing > 0, "unsupported row geometry")
  return w, h, spacing, limit, px, height
end

local function Configure(row, region, data)
  local w, h, spacing, limit, px, height = Geometry(row.group, region, data)
  row.centred = Display.FlowGrowthKey(row.group) == "CENTER_HORIZONTAL"
  if row.centred then
    -- The stock capped row switches to a fixed rounded left edge once it
    -- overflows. A wrapped native line has the same width both at and above
    -- the cap. Share only if both starts cover the same physical pixels.
    local gapPx = math.floor(spacing * px + 0.5)
    local stepPx = math.floor((w + spacing) * px + 0.5)
    local width = Display.Dimensions(data)
    local capLengthPx = (limit - 1) * stepPx + width * px
    local nativeLeft = math.floor(0.25 + math.floor(gapPx / 2) - limit * stepPx / 2 + 0.5)
    assert(nativeLeft == -math.floor(capLengthPx / 2 + 0.501), "centred overflow would shift a pixel")
  end
  row.width, row.height, row.spacing, row.limit, row.px, row.authoredHeight = w, h, spacing, limit, px, height
  local parent = Private.regions[row.group.id]
  local viewport = CreateFrame("Frame", nil, parent and parent.region or UIParent, "DisableUntrustedLayoutScriptsTemplate")
  row.viewport = viewport
  viewport:Hide()
  viewport:EnableMouse(false)
  if viewport.SetRoundLayoutToNearestPixel then viewport:SetRoundLayoutToNearestPixel(false) end
  viewport:SetClipsChildren(true)
  local container, accepted = Display.CreateAuraContainer(viewport, data, true, "shared row")
  row.container = container
  assert(accepted, "native layout template refused")
  container:SetEnabled(false)
  container.faOwnerId = row.group.id
  if container.SetRoundLayoutToNearestPixel then container:SetRoundLayoutToNearestPixel(false) end
  container:SetAuraProcessingPolicy(CustomAuraContainerAuraProcessingPolicy.None)
  container:SetUnit("player")
  container:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
  container:SetFlowLayoutAnchorPoint("TOPLEFT")
  container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right, AnchorUtil.FlowDirection.Down)
  container:SetFlowLayoutPadding(0, 0, 0, 0)
  local span = w + (limit - 1) * (w + spacing)
  container:SetFlowLayoutMaximumLineSize(span + (w + spacing) / 2)
end

local function CheckGeometry(row, region, data)
  local w, h, spacing, limit, px, authoredHeight = Geometry(row.group, region, data)
  assert(w == row.width and h == row.height and spacing == row.spacing and limit == row.limit
    and px == row.px and authoredHeight == row.authoredHeight, "mixed row geometry")
end

local function BuildButton(context, button)
  local container = context.row.container
  button:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
  local native = Display.BuildNativeButton(container, button, false)
  native.previewRowOwner = context.region
  context.buttons[#context.buttons + 1] = native
  context.style(native, context.data, context.region)
end

local function Install(row, region, data, index, style)
  if not row.container then Configure(row, region, data) else CheckGeometry(row, region, data) end
  local trigger = Display.GetTrigger(data)
  local method, direction = Display.SortOrder(data, trigger)
  if row.centred and not row.hasBorder then
    for _, element in ipairs(data.subRegions or {}) do
      if element.type == "subborder" and element.border_visible ~= false and (element.border_alpha or 1) > 0
          and (not element.border_color or (element.border_color[4] or 1) > 0) then
        row.hasBorder = true
        break
      end
    end
  end
  local cap = Display.MaxAuras(data)
  assert(cap >= 1 and cap <= 10, "display exceeds the preallocated batch")
  local context = {row = row, region = region, data = data, style = style, buttons = {}}
  row.callbacks[#row.callbacks + 1] = context
  local lineGap = Display.SharedRowWrapSpacing
  local groupKey = "member"..index
  local filters = Display.RawCandidateFilters(data)
  row.container:AddAuraGroup(groupKey, Display.FilterString(trigger), {
    candidateFilters = filters, maxFrameCount = cap,
    sortMethod = method, sortDirection = direction,
    layout = {layoutIndex = index, elementWidth = row.width, elementHeight = row.height,
      elementSpacing = row.spacing, groupSpacing = 0, lineSpacing = lineGap, groupLineSpacing = lineGap},
    initializeFrame = function(button)
      if not context.row or context.failed then return end
      -- A native callback refusal need not propagate through AddAuraGroup.
      if not pcall(BuildButton, context, button) then context.failed = true end
    end,
  })
  assert(not context.failed and #context.buttons >= cap, "incomplete native group")
  if Display.UsesRankSpellIDs(trigger) then
    WatchPendingNames(row.members[region], groupKey, filters.includeSpellIDs)
  end
end

Commit = function(row)
  if row.dead or row.complete or row.count < #row.group.controlledChildren then return end
  assert(not Restricted(), "row commit restricted")
  local group = row.group
  assert(WeakAuras.GetData(group.id) == group, "group replaced during construction")
  for index, id in ipairs(group.controlledChildren) do
    local member = row.indices[index]
    assert(member and member.data.id == id and not HasOrdinary(member.region), "row membership changed")
    if pendingRankUpdates[member] or not IsLive(member) or not ExplicitlyShown(member.region) then return end
    CheckGeometry(row, member.region, member.data)
  end
  local first = row.indices[1]
  local parent = Private.regions[group.id]
  assert(parent and parent.region, "group frame unavailable")
  assert(not hosts[parent.region], "group frame already owned")
  local origin, point, x, y = Display.SharedRowOrigin(group, first.region, row.authoredHeight)
  assert(origin and point, "group anchor unavailable")
  if row.plan.anchorID or row.plan.externalFrameName then
    local target
    if row.plan.anchorID then
      local entry = Private.regions[row.plan.anchorID]
      target = entry and entry.region
    else
      -- Share only a real frame that the ordinary resolver accepts. The
      -- ordinary path also handles named textures, font strings and targets
      -- that are still loading. Keep the host's existing position-only anchor.
      target = Private.GetSanitizedFrame(row.plan.externalFrameName, true)
    end
    local _, relative = origin:GetPoint(1)
    assert(target and not issecretvalue(relative) and relative == target,
      "selected row anchor is still pending")
  end
  if row.viewport:GetParent() ~= parent.region then row.viewport:SetParent(parent.region) end
  assert(Display.SharedRowClip(row.viewport, group, first.region, first.data), "row clip unavailable")
  row.container:SetPoint(row.centred and "TOP" or "TOPLEFT", origin, point, x, y)
  row.container:SetEnabled(true)
  row.container:Show()
  row.viewport:Show()
  row.complete = true
  row.host = parent.region
  hosts[row.host] = row
  row.host.faSharedAuraRowMembers = row.count
  if row.hasBorder then QueueRepair(row) end
  constructing = constructing - 1
  if row.timeout then row.timeout:Cancel(); row.timeout = nil end
  UpdateEvents()
end

local function OnMemberHide(region)
  local owner = owners[region]
  if owner and owner.row.complete and not ExplicitlyShown(region) then Stop(owner.row) end
end

local function OnMemberShow(region)
  local owner = owners[region]
  if not owner or owner.row.dead or owner.row.complete then return end
  local row = owner.row
  if row.count < #row.group.controlledChildren or row.commitQueued then return end
  row.commitQueued = true
  C_Timer.After(0, function()
    row.commitQueued = nil
    if not pcall(Commit, row) then Stop(row) end
  end)
end

local function Add(row, region, data, index, style)
  local owner = {row = row, region = region, data = data}
  owners[region], row.members[region], row.indices[index] = owner, owner, owner
  Install(row, region, data, index, style)
  if not watched[region] then
    HookMember(region, "OnHide", OnMemberHide)
    HookMember(region, "OnShow", OnMemberShow)
    watched[region] = true
  end
  row.count = row.count + 1
  Commit(row)
  -- The last owner's load flag can be published after its build returns.
  if not row.complete then OnMemberShow(region) end
end

local function HoldWhileRetiring(region, data)
  local owner = owners[region]
  if owner and owner.row.dead then
    -- A region may already have been reassigned by the time the client
    -- permits retirement. Wake the current live request when it does.
    owner.released, owner.data = false, data
    return true
  end
  local row = waiting[region] or data and blockedGroups[data.parent]
  if row then
    -- Release and re-acquire may also supply a replacement region object.
    -- An old shared copy can still be on screen until restrictions clear.
    row.waiting = row.waiting or {}
    row.waiting[region] = {region = region, data = data}
    waiting[region] = row
    return true
  end
  return false
end

function Display.SharedRowTry(region, data, style)
  local owner = owners[region]
  if HoldWhileRetiring(region, data) then return true end
  if suspended or not data then return false end
  if owner then
    local row = owner.row
    if owner.data ~= data or row.group.id ~= data.parent or HasOrdinary(region) then
      Stop(row, region)
    elseif pcall(Commit, row) then
      return true
    else
      Stop(row, region)
    end
    return HoldWhileRetiring(region, data)
  end
  local group = data.parent and WeakAuras.GetData(data.parent)
  if not group or excluded[group] then return false end
  local row = rows[group.id]
  local eligible, index, plan
  if not Restricted() and not HasOrdinary(region) then
    eligible, index, plan = Display.SharedRowMatch(data, row and row.plan)
  end
  if eligible ~= group or not index then
    if row then Stop(row) end
    excluded[group] = true
    return HoldWhileRetiring(region, data)
  end
  if not row then
    -- A restricted or ordinary build may already own a sibling. Avoid
    -- replacing a working native renderer with a second one mid-session.
    for _, id in ipairs(group.controlledChildren) do
      local entry = Private.regions[id]
      if entry and HasOrdinary(entry.region) then excluded[group] = true; return false end
    end
    row = {group = group, id = group.id, plan = plan, ancestors = {}, callbacks = {}, members = {}, indices = {}, count = 0}
    local ancestor = group.parent
    while ancestor do
      local dependents = byAncestor[ancestor] or {}
      if dependents[row] then break end
      dependents[row] = true
      byAncestor[ancestor] = dependents
      row.ancestors[#row.ancestors + 1] = ancestor
      local config = WeakAuras.GetData(ancestor)
      ancestor = config and config.parent
    end
    for _, id in ipairs(plan.anchorAncestors or {}) do
      local dependents = byAncestor[id] or {}
      if not dependents[row] then
        dependents[row] = true
        byAncestor[id] = dependents
        row.ancestors[#row.ancestors + 1] = id
      end
    end
    rows[group.id] = row
    constructing = constructing + 1
    UpdateEvents()
    row.timeout = C_Timer.NewTimer(15, function()
      row.timeout = nil
      if not row.dead and not row.complete then Stop(row) end
    end)
  end
  if row.group ~= group or row.indices[index] or row.complete then
    Stop(row)
    return HoldWhileRetiring(region, data)
  end
  if not pcall(Add, row, region, data, index, style) then
    Stop(row, region)
    return HoldWhileRetiring(region, data)
  end
  return true
end

function Display.SharedRowFallback(region, data, keepCommitted)
  local owner = owners[region]
  if keepCommitted and owner and owner.row.complete and not owner.row.dead and owner.data == data
    and owner.row.id == data.parent then return true end
  local row = owner and owner.row or data and data.parent and rows[data.parent]
  if row then Stop(row, region) end
  return HoldWhileRetiring(region, data)
end

function Display.SharedRowRelease(region)
  local pending = waiting[region]
  if pending then
    pending.waiting[region], waiting[region] = nil, nil
    return true
  end
  local owner = owners[region]
  if not owner then return false end
  Stop(owner.row, region)
  return true
end

function Display.SharedRowBeforeEdit(data)
  if not data or not next(rows) then return end
  -- The editor may already have changed data.parent in the saved table.
  -- The region still identifies the row that rendered the old parent.
  local entry = Private.regions[data.id]
  local owner = entry and owners[entry.region]
  if owner then Stop(owner.row) end
  local row = rows[data.id] or (data.parent and rows[data.parent])
  if row then Stop(row) end
  -- Pixel-rounded dimensions also depend on the effective scale inherited
  -- from ordinary enclosing groups. Only retire their own descendants.
  local children = byAncestor[data.id]
  if children then for child in pairs(children) do Stop(child) end end
end

function Display.SharedRowSuspend()
  suspended, watchWorld, worldReadyAt = true, false, nil
  if repairTimer then repairTimer:Cancel(); repairTimer = nil end
  for _, row in pairs(rows) do Stop(row) end
  UpdateEvents()
end

function Display.SharedRowLogin(inCombat)
  -- Paced construction can continue after combat ends. A combat login
  -- leaves all startup rows with their existing ordinary builder.
  if inCombat then
    Display.SharedRowSuspend()
  else
    watchWorld = true
    UpdateEvents()
  end
end
