local tinsert  = table.insert
local tcontain = hs.fnutils.contains
local timer    = require("hs.timer")
local eventtap = require("hs.eventtap")
local events   = eventtap.event.types

local log = hs.logger.new('hotkey', 'info')

local module   = {}

local modsShort = { Mod.Cmd.Short, Mod.Ctrl.Short, Mod.Alt.Short, Mod.Shift.Short }

local function getIndex(keycode) -- key for hotkeys table
  if Mod.Hyper and keycode == hs.keycodes.map[Mod.Hyper.Long] then
    return Mod.Hyper.Symbol
  end
  local key = hs.keycodes.map[keycode]
  key = key and key:upper() or '[#'..keycode..']'
  return key
end

function module:_install(mods, key)
  if key == nil or key == "" then
    key = mods
    mods = nil
  end
  if mods == nil or mods == "" then
    for _, mod in ipairs(modsShort) do
      if key == mod or key == tolong(mod) or key == tosymbol(mod) then
        self.key = mod
        self.idx = tosymbol(mod) .. tosymbol(mod)
        return
      end
    end
    self.key = hs.keycodes.map[key]
    local keyRepr = getIndex(self.key)
    self.idx = keyRepr .. keyRepr
    if key:lower():match('^f%d+$') then
      self.mods = { Mod.Fn.Long }
    end
  else
    local idx, modsRepr = "", {}
    if type(mods) == 'string' and utf8.len(mods) ~= mods:len() then
      for _, mod in ipairs(modsShort) do
        if mods:find(tosymbol(mod)) then
          idx = idx .. mod
          tinsert(modsRepr, mod)
        end
      end
    else
      if type(mods) == 'string' then mods = { mods } end
      for _, mod in ipairs(modsShort) do
        if tcontain(mods, mod) or tcontain(mods, tolong(mod)) then
          idx = idx .. mod
          tinsert(modsRepr, mod)
        end
      end
    end
    if key:lower():match('^f%d+$') then
      tinsert(modsRepr, Mod.Fn.Long)
    end
    self.key = hs.keycodes.map[key]
    self.mods = modsRepr
    local keyRepr = getIndex(self.key)
    self.idx = idx .. keyRepr .. keyRepr
  end
end


-- Synopsis:

-- what we're looking for is 4 events within a set time period and no intervening other key events:
--  flagsChanged with only **KEY** = true
--  flagsChanged with all = false
--  flagsChanged with only **KEY** = true
--  flagsChanged with all = false

-- verify that no keyboard flags are being pressed
local function noFlags(ev)
  return ev:getFlags():containExactly({})
end

-- verify that *only* the **KEY** key flag is being pressed
function module:_onlyTargetKey(ev)
  if tcontain(modsShort, self.key) then
    return ev:getFlags():containExactly({self.key})
  else
    return ev:getFlags():containExactly(self.mods) and ev:getKeyCode() == self.key
  end
end

function module:_new(mods, key, msg, func)
  self:_install(mods, key)
  if func == nil then
    func = msg
    msg = nil
  end
  self.action = func
  if msg then self.msg = self.idx .. ": " .. msg end

  -- the actual workhorse
  self.eventWatcher = eventtap.new({ events.flagsChanged, events.keyDown, events.keyUp }, function(ev)
    -- if it's been too long; previous state doesn't matter
    if (timer.secondsSinceEpoch() - self.timeFirstKeyDown) > self.timeFrame then
      self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
    end

    if tcontain(modsShort, self.key) then
      if ev:getType() == events.flagsChanged then
        if noFlags(ev) and self.firstDown and self.secondDown then -- **KEY** up and we've seen two, so do action
          if self.action then self.action() end
          self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
        elseif self:_onlyTargetKey(ev) and not self.firstDown then -- **KEY** down and it's a first
          self.firstDown = true
          self.timeFirstKeyDown = timer.secondsSinceEpoch()
        elseif self:_onlyTargetKey(ev) and self.firstDown then -- **KEY** down and it's the second
          self.secondDown = true
        elseif not noFlags(ev) then                            -- otherwise reset and start over
          self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
        end
      else -- it was a key press, so not a lone **KEY** char -- we don't care about it
        self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
      end
    else
      if ev:getType() == events.flagsChanged then -- it was a flag change, so not a lone **KEY** char -- we don't care about it
        self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
      else
        if ev:getType() == events.keyDown and self:_onlyTargetKey(ev) and not self.firstDown then -- **KEY** down and it's a first
          self.firstDown = true
          self.timeFirstKeyDown = timer.secondsSinceEpoch()
        elseif ev:getType() == events.keyDown and self:_onlyTargetKey(ev) and self.firstDown then -- **KEY** down and it's the second
          self.secondDown = true
        elseif ev:getType() == events.keyUp and self:_onlyTargetKey(ev) and self.firstDown and self.secondDown then
          -- **KEY** up and we've seen two, so do action
          if self.action then self.action() end
          self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
        elseif not (ev:getType() == events.keyUp and self.firstDown) then -- otherwise reset and start over
          self.timeFirstKeyDown, self.firstDown, self.secondDown = 0, false, false
        end
      end
    end
    return false
  end):start()

  return self
end

function module:_bind(mods, key, msg, func)
  self:_new(mods, key, msg, func)
  self:enable()
end

function module:enable()
  self.eventWatcher:start()
  log.f('Enabled hotkey %s', self.msg or self.idx)
  return self
end

function module:disable()
  self.eventWatcher:stop()
  log.f('Disabled hotkey %s', self.msg or self.idx)
  return self
end

function module:isEnabled()
  return self.eventWatcher:isEnabled()
end

function module:_newInstance()
  local o = {}
  setmetatable(o, self)
  self.__index = self

  -- double tap this key to trigger the action
  o.key = nil
  o.mods = {}
  o.idx = nil

  -- how quickly must the two single **KEY** taps occur?
  o.timeFrame = 0.5

  -- what to do when the double tap of **KEY** occurs
  o.action = nil

  -- status
  o.timeFirstKeyDown, o.firstDown, o.secondDown = 0, false, false

  return o
end

function module.newNoSuspend(mods, key, msg, func)
  local hotkey = module:_newInstance()
  hotkey:_new(mods, key, msg, func)
  return hotkey
end

function module.new(mods, key, msg, func)
  if func == nil then
    func = msg msg = nil
  end
  func = suspendWrapper(func)
  local hotkey = module.newNoSuspend(mods, key, msg, func)
  hotkey.suspendable = true
  return hotkey
end

function module.bindNoSuspend(mods, key, msg, func)
  local hotkey = module.newNoSuspend(mods, key, msg, func)
  hotkey:enable()
  return hotkey
end

function module.bind(mods, key, msg, func)
  local hotkey = module.new(mods, key, msg, func)
  hotkey:enable()
  return hotkey
end

return module