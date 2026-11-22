-- Stand-ins for the WoW globals that the loaded addon files touch. This is not
-- a WoW API emulation: each stub does the least a loaded file needs, and the
-- few that model a client rule (secret values) say which rule they model.
local M = {}

local function strsplit(delimiter, text)
  local out = {}
  local escaped = delimiter:gsub("%p", "%%%0")
  for piece in (text .. delimiter):gmatch("([^" .. escaped .. "]*)" .. escaped) do
    out[#out + 1] = piece
  end
  return unpack(out)
end

local function strtrim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function CopyTable(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = type(value) == "table" and CopyTable(value) or value
  end
  return copy
end

-- Secret values. On the Forever client (and retail 12.x) some API results are
-- "secret" while restrictions are active: addon code can pass them on but
-- cannot read, compare or index with them. issecretvalue tells them apart.
-- A stub secret is an opaque userdata; the stubs that model the indexing rule
-- (see secretKeyGuard) raise the client's error when one is used as a key.
local secrets = setmetatable({}, { __mode = "k" })

--- Returns a new secret value. label only shows up in tostring.
function M.secret(label)
  local value = newproxy(true)
  getmetatable(value).__tostring = function() return "secret(" .. tostring(label) .. ")" end
  secrets[value] = true
  return value
end

local function issecretvalue(value)
  return secrets[value] == true
end

local function hasanysecretvalues(...)
  for i = 1, select("#", ...) do
    if secrets[(select(i, ...))] then
      return true
    end
  end
  return false
end

--- Wraps a table so that indexing it with a secret value raises the error the
--- client raises ("attempted to index a table that cannot be indexed with
--- secret keys"). Plain keys behave as usual.
function M.secretKeyGuard(input)
  return setmetatable({}, {
    __index = function(_, key)
      if secrets[key] then
        error("attempted to index a table that cannot be indexed with secret keys", 2)
      end
      return input[key]
    end,
  })
end

-- Lua 5.1 has no bit library; WoW and LuaJIT do. Only what the loaded files use.
local bitFallback = {
  band = function(a, b)
    local result, bitValue = 0, 1
    while a > 0 and b > 0 do
      if a % 2 == 1 and b % 2 == 1 then result = result + bitValue end
      a, b, bitValue = math.floor(a / 2), math.floor(b / 2), bitValue * 2
    end
    return result
  end,
  lshift = function(a, n) return a * 2 ^ n end,
  rshift = function(a, n) return math.floor(a / 2 ^ n) end,
}

--- A frame object with the methods the loaded files call on frames they make.
function M.newFrame(objectType)
  local scripts = {}
  local shown = true
  local frame = {}
  function frame:SetScript(script, fn) scripts[script] = fn end
  function frame:GetScript(script) return scripts[script] end
  function frame:HookScript(script, fn) scripts[script] = fn end
  function frame:Show() shown = true end
  function frame:Hide() shown = false end
  function frame:IsShown() return shown end
  function frame:SetAllPoints() end
  function frame:SetPoint() end
  function frame:RegisterEvent() end
  function frame:UnregisterEvent() end
  function frame:UnregisterAllEvents() end
  function frame:IsProtected() return false end
  function frame:IsForbidden() return false end
  function frame:IsObjectType(kind)
    if kind == "Frame" then
      return objectType == nil or objectType == "Frame" or objectType == "Button"
    end
    return kind == objectType
  end
  return frame
end

--- Sensitive globals return a marker string so a test can tell the real
--- function from a sandbox stub.
M.sensitiveFunctions = {
  "EnumerateFrames", "RunScript", "SendMail", "securecall",
  -- Blocked by ForeverAuras on top of the WeakAuras list.
  "Quit", "ForceQuit", "Logout", "ConsoleExec", "GuildInvite", "GuildUninvite",
  "GuildPromote", "GuildDemote", "GuildDisband", "GuildSetLeader", "GuildSetMOTD",
  "GuildLeave", "SetGuildInfoText", "DepositGuildBankMoney", "WithdrawGuildBankMoney",
  "PickupGuildBankMoney", "SetGuildBankWithdrawGoldLimit", "DeleteCursorItem",
  "CreateMacro", "EditMacro", "SetBindingMacro", "ChatEdit_SendText",
  "GetFrameMetatable", "GetButtonMetatable",
}

function M.install()
  _G.strsplit = strsplit
  _G.strtrim = strtrim
  -- WoW adds trim to the string library, so code can call ("x"):trim()
  rawset(string, "trim", strtrim)
  _G.tinsert = table.insert
  _G.tremove = table.remove
  _G.ceil = math.ceil
  _G.floor = math.floor
  -- WoW's global aliases of the string library.
  _G.strmatch, _G.strfind, _G.strsub, _G.strlen = string.match, string.find, string.sub, string.len
  _G.strbyte, _G.strchar, _G.strrep, _G.format = string.byte, string.char, string.rep, string.format
  _G.strlower, _G.strupper, _G.gsub = string.lower, string.upper, string.gsub
  _G.sort, _G.tconcat = table.sort, table.concat
  _G.wipe = function(t)
    for key in pairs(t) do
      t[key] = nil
    end
    return t
  end
  _G.CopyTable = CopyTable
  _G.tIndexOf = function(t, value)
    for index, entry in ipairs(t) do
      if entry == value then return index end
    end
  end
  _G.TableHasAnyEntries = function(t) return next(t) ~= nil end
  _G.time = os.time
  _G.debugprofilestop = function() return os.clock() * 1000 end
  _G.bit = _G.bit or bitFallback

  _G.issecretvalue = issecretvalue
  _G.hasanysecretvalues = hasanysecretvalues
  _G.issecrettable = function() return false end

  _G.GetUnitName = function() return "Tester" end
  _G.UnitGUID = function() return "Player-1-1" end
  _G.UnitAura = function() return nil end
  _G.IsInRaid = function() return false end
  _G.UnitExists = function() return false end
  _G.C_Timer = { After = function() end, NewTimer = function() end, NewTicker = function() end }
  _G.C_EncodingUtil = {
    EncodeBase64 = function(text) return text end,
    DecodeBase64 = function(text) return text end,
  }
  _G.EventRegistry = { RegisterCallback = function() end }
  _G.CreateFrame = function(objectType) return M.newFrame(objectType) end
  _G.hooksecurefunc = function() end
  _G.UIParent = M.newFrame()

  -- A child frame without a name, as the frame chooser produces it
  _G.PlayerFrame = M.newFrame()
  _G.PlayerFrame.healthbar = M.newFrame()

  for _, name in ipairs(M.sensitiveFunctions) do
    _G[name] = function() return "REAL_" .. name end
  end
  _G.SlashCmdList = {}
  _G.DEFAULT_CHAT_FRAME = {}
  _G.ForeverAurasSaved = { displays = {} }
  _G.ForeverAurasOptions = {}
  _G.ForeverAurasOptionsSaved = {}
  _G.WeakAurasSaved = _G.ForeverAurasSaved

  local libs = {
    LibSerialize = {},
    LibDeflate = {},
    ["LibCustomGlow-1.0-foreverauras"] = { ButtonGlow_Start = function() end, ButtonGlow_Stop = function() end },
    ["LibGetFrame-1.0"] = { GetUnitFrame = function() end, GetUnitNameplate = function() end },
  }
  _G.LibStub = setmetatable({ GetLibrary = function(_, name) return libs[name] end }, {
    __call = function(_, name) return libs[name] end,
  })
end

--- Answers any unknown key with a no-op function.
function M.permissive(table)
  return setmetatable(table or {}, {
    __index = function() return function() end end,
  })
end

--- The WeakAuras functions that ForeverAuras hides from custom aura code
--- (FakeWeakAurasMixin.blockedFunctions in AuraEnvironment.lua).
M.blockedWeakAurasFunctions = {
  "Add", "Delete", "HideOptions", "Rename", "NewAura", "Import", "PreAdd",
  "RegisterRegionOptions", "RegisterSubRegionOptions", "RegisterSubRegionType",
  "RegisterRegionType", "RegisterTriggerSystem", "RegisterTriggerSystemOptions",
  "ShowOptions", "OpenOptions", "PickDisplay", "Toggle", "ToggleOptions",
  "FillOptions", "ClearAndUpdateOptions", "NewDisplayButton", "UpdateThumbnail",
}

function M.newWeakAuras()
  local WeakAuras = {
    IsLibsOK = function() return true end,
    IsOptionsOpen = function() return false end,
    L = setmetatable({}, { __index = function(_, key) return key end }),
    GetData = function() return nil end,
    GetRegion = function() return nil end,
    UnitName = function(unit) return _G.UnitName and _G.UnitName(unit) end,
    doubleWidth = 2,
    normalWidth = 1,
    halfWidth = 0.5,
  }
  for _, name in ipairs(M.blockedWeakAurasFunctions) do
    WeakAuras[name] = function() return "REAL_" .. name end
  end
  return WeakAuras
end

--- Sandbox warnings are appended to the returned list as { uid, key, severity, message }.
function M.newPrivate()
  local warnings = {}
  local Private = {
    ExecEnv = {},
    clones = {},
    regions = {},
    db = {},
    multiUnitUnits = { nameplate = {} },
    AuraWarnings = {
      UpdateWarning = function(uid, key, severity, message)
        -- A call without a severity clears a warning.
        if severity then
          warnings[#warnings + 1] = { uid = uid, key = key, severity = severity, message = message }
        end
      end,
    },
    UIDtoID = function() return nil end,
    DebugLog = { Print = function() end },
    customActionsFunctions = {},
    GetErrorHandlerId = function() return function() end end,
    EnsureRegion = function() return nil end,
    ActivateAuraEnvironmentLifecycle = function() end,
    DeactivateAuraEnvironmentLifecycle = function() end,
    AuraEnvironmentWrappedSystem = { Get = function() return _G.C_Timer end },
    -- Private.TimedAPI (Init.lua) hands each file wrapped CreateFrame,
    -- hooksecurefunc, HookScript and C_Timer; here they are the plain globals.
    TimedAPI = function()
      return _G.CreateFrame, _G.hooksecurefunc, function(frame, script, fn) return frame:HookScript(script, fn) end,
             _G.C_Timer
    end,
    timedAPIRequests = {},
    -- Private.dataGeneration and InvalidateDataCopies live in ForeverAuras.lua.
    dataGeneration = 0,
  }
  Private.AuraTimedAPI = function(id)
    Private.timedAPIRequests[#Private.timedAPIRequests + 1] = id
    return { CreateFrame = _G.CreateFrame, hooksecurefunc = _G.hooksecurefunc }
  end
  Private.InvalidateDataCopies = function()
    Private.dataGeneration = Private.dataGeneration + 1
  end
  return Private, warnings
end

--- Empties a warnings list returned by newPrivate.
function M.clearWarnings(warnings)
  for i = #warnings, 1, -1 do
    warnings[i] = nil
  end
end

--- True when a warning with this key was raised, optionally for this uid.
function M.warned(warnings, key, uid)
  for _, warning in ipairs(warnings) do
    if warning.key == key and (uid == nil or warning.uid == uid) then
      return true
    end
  end
  return false
end

return M
