local tinsert = table.insert

local log = hs.logger.new('hotkey', 'info')

local module = {}

-- Hyper's key-up can be lost entirely while Lua is blocked, so its physical
-- state is the source of truth.
local keystate = require('modal.keystate') or nil

function module:isHyperHeld()
  return keystate == nil or keystate.keyDown(hs.keycodes.map[self.hyper])
end

-- A Hyper hotkey that fires after Hyper was released is a plain keystroke.
function module:_releaseGuard(mods, key, fn)
  return function(...)
    if self.hyperMode.Entered and not self:isHyperHeld() then
      self:exitHyperMode()
      hs.eventtap.keyStroke(mods, key, 0)
      return
    end
    return fn(...)
  end
end

-- Leave Hyper Mode when Hyper is released.
function module:exitHyperMode()
  self.hyperMode:exit()
  self.hyperMode.Entered = false
  self.hyperKeyDown = false
  if self.hyperWatchdog then
    self.hyperWatchdog:stop()
    self.hyperWatchdog = nil
  end
end

-- `viaTap` means the key tap saw Hyper and dispatches its keys itself; the
-- system hotkeys are registered only when the hotkey trigger is the one that
-- saw Hyper, e.g. while the key tap was disabled.
function module:enterHyperMode(viaTap)
  if self:isEnabled() then return end

  if not viaTap then self.hyperMode:enter() end
  self.hyperMode.Entered = true
  -- The key-up may never be delivered, so also poll the physical state.
  self.hyperWatchdog = hs.timer.doEvery(0.1, function()
    if not self:isHyperHeld() then
      self:exitHyperMode()
    end
  end)
end

function module:pressHyper(viaTap)
  if self.hyperKeyDown then return end
  self.hyperKeyDown = true
  self:enterHyperMode(viaTap)
end

local function keycodeOf(key)
  if type(key) == 'number' then return key end
  if key:sub(1, 1) == '#' then return tonumber(key:sub(2)) end
  return hs.keycodes.map[key:lower()]
end

-- The modifiers a binding requires besides Hyper, as the bit set used by the
-- native key tap.
local function modifierSet(mods)
  local set = 0
  if type(mods) == 'table' then mods = table.concat(mods, '+') end
  mods = (mods or ''):lower()
  for bit, aliases in pairs({ [1] = { 'cmd', 'command', '⌘' }, [2] = { 'alt', 'option', '⌥' },
                              [4] = { 'shift', '⇧' }, [8] = { 'ctrl', 'control', '⌃' } }) do
    for _, alias in ipairs(aliases) do
      if mods:find(alias, 1, true) then set = set | bit break end
    end
  end
  return set
end

-- Remember a key binding for the key tap, alongside its system hotkey.
function module:_register(mods, key, pressedfn, releasedfn, repeatfn)
  local code = keycodeOf(key)
  if code == nil then return end
  local bindings = self.bindings[code] or {}
  self.bindings[code] = bindings
  local set = modifierSet(mods)
  local binding = { key = key, set = set,
    pressed = suspendWrapper(pressedfn, mods, key),
    released = suspendWrapper(releasedfn, mods, key),
    repeated = suspendWrapper(repeatfn, mods, key) }
  tinsert(bindings, binding)
  if self.keyTap then keystate.bindKey(code, set, 1) end
  return function()
    local index = tindex(bindings, binding)
    if index then
      tremove(bindings, index)
      if self.keyTap then keystate.bindKey(code, set, -1) end
    end
  end
end

-- The latest binding wins, as with shadowed system hotkeys.
function module:_binding(code, set)
  local bindings = self.bindings[code] or {}
  for i = #bindings, 1, -1 do
    if bindings[i].set == set then return bindings[i] end
  end
end

-- Run what the native key tap reported. It has already consumed the keys, so
-- a key pressed while Hyper was held fires even if Lua runs late.
local HYPER_DOWN, HYPER_UP, KEY_PRESSED, KEY_RELEASED = 1, 2, 3, 4
function module:_handleKey(kind, code, set)
  if kind == HYPER_DOWN then
    self:pressHyper(true)
  elseif kind == HYPER_UP then
    self.hyperKeyDown = false
    self:exitHyperMode()
  elseif kind == KEY_PRESSED then
    local binding = self:_binding(code, set)
    self.consumed[code] = binding
    if binding and binding.pressed then binding.pressed() end
  else
    local binding = self.consumed[code]
    if kind == KEY_RELEASED then self.consumed[code] = nil end
    local fn = binding and (kind == KEY_RELEASED and binding.released or binding.repeated)
    if fn then fn() end
  end
end

-- FLAGS.SUSPEND is read by the key tap off the main thread; keep the value out
-- of the table so that every assignment reaches it.
function module:_followSuspend(setTrigger)
  local suspended = rawget(FLAGS, "SUSPEND")
  rawset(FLAGS, "SUSPEND", nil)
  local function update(value)
    suspended = value
    if keystate then keystate.setSuspended(value == true) end
    -- The hotkey trigger would consume Hyper before the remote desktop or VM.
    setTrigger(not value)
  end
  setmetatable(FLAGS, {
    __index = function(_, k) if k == "SUSPEND" then return suspended end end,
    __newindex = function(t, k, v)
      if k == "SUSPEND" then update(v) else rawset(t, k, v) end
    end,
  })
  update(suspended)
end

function module:isEnabled()
  return self.hyperMode and self.hyperMode.Entered
end

-- Utility to bind handler to Hyper+modifiers+key
function module:bindNoSuspend(mods, key, message, pressedfn, releasedfn, repeatfn)
  self:_register(mods, key, pressedfn, releasedfn, repeatfn)
  if type(pressedfn) == 'function' then
    pressedfn = self:_releaseGuard(mods, key, pressedfn)
  end
  local hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
  local hyper = self.hyper
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    hyper = Mod.Hyper.Symbol
  end
  hotkey.msg = hyper .. hotkey.idx .. ": " .. message
  tinsert(self.hyperMode.keys, hotkey)
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

function module:bind(mods, key, message, pressedfn, ...)
  local releasedfn, repeatfn = ...
  local unregister = self:_register(mods, key, pressedfn, releasedfn, repeatfn)
  if type(pressedfn) == 'function' then
    pressedfn = self:_releaseGuard(mods, key, pressedfn)
  end
  local hotkey = newHotkey(mods, key, message, pressedfn, ...)
  local originalDelete = hotkey.delete
  hotkey.delete = function(hk)
    local index = tindex(self.hyperMode.keys, hk)
    if index then
      tremove(self.hyperMode.keys, index)
    end
    if unregister then unregister() end
    originalDelete(hk)
  end
  local hyper = self.hyper
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    hyper = Mod.Hyper.Symbol
  end
  hotkey.msg = hyper .. hotkey.msg
  tinsert(self.hyperMode.keys, hotkey)
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

-- Binds the enter/exit functions of the Hyper modal to all combinations of modifiers
function module:_new(hyper)
  local o = {}
  setmetatable(o, self)
  self.__index = self
  o.hyper = hyper
  o.hyperMode = hs.hotkey.modal.new()
  o.hyperMode.Entered = false
  o.hyperKeyDown = false
  o.bindings, o.consumed = {}, {}
  o.trigger = hs.hotkey.new("", o.hyper,
      function() o:pressHyper() end,
      function()
        o.hyperKeyDown = false
        o:exitHyperMode()
      end)
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    o.trigger.msg = "HYPER"
  end
  local logLevel = hs.hotkey.getLogLevel()
  hs.hotkey.setLogLevel('nothing')
  o.trigger:enable()
  hs.hotkey.setLogLevel(logLevel)
  log.f('Enabled modal %s', o.trigger.msg)
  -- Handle Hyper and its keys in a native key tap on a background thread (see
  -- keystate_native.m) instead of system hotkeys. After a lost Hyper key-up,
  -- the system hotkeys think Hyper is still held: they skip the next press and
  -- can miss the key pressed with it. The tap decides which keys to consume
  -- without Lua, so typing never waits for the main thread and no key-up is
  -- lost to a tap timeout. It consumes the keys it handles, so the hotkey
  -- trigger only sees Hyper as a fallback, e.g. under secure input.
  local function setTrigger(enabled)
    if (o.trigger.enabled == true) == enabled then return end
    local logLevel = hs.hotkey.getLogLevel()
    hs.hotkey.setLogLevel('nothing')
    if enabled then o.trigger:enable() else o.trigger:disable() end
    hs.hotkey.setLogLevel(logLevel)
  end
  o.keyTap = keystate and keystate.startKeyTap(hs.keycodes.map[o.hyper],
      function(kind, code, set)
        local ok, err = xpcall(o._handleKey, debug.traceback, o, kind, code, set)
        if not ok then log.e(err) end
      end)
  o:_followSuspend(setTrigger)
  return o
end

function module:enable()
  self.trigger:enable()
  return self
end

function module:disable()
  self.trigger:disable()
  return self
end

function module.install(hotKey)
  return module:_new(hotKey)
end

return module
