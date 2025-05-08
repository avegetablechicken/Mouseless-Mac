local tinsert  = table.insert
local timer    = require("hs.timer")
local eventtap = require("hs.eventtap")
local events   = eventtap.event.types

local module   = {}

local function getIndex(keycode) -- key for hotkeys table
  if keycode == hs.keycodes.map[HYPER] then return "✧" end
  local key = hs.keycodes.map[keycode]
  key = key and key:upper() or '[#'..keycode..']'
  return key
end

local modifiers = {
  command = "⌘",
  control = "⌃",
  option = "⌥",
  shift = "⇧",
  cmd = "⌘",
  ctrl = "⌃",
  alt = "⌥",
  fn = "🌐︎",
  hyper = "✧"
}

local functionKeycodes = {}
for i=1,20 do
  tinsert(functionKeycodes, hs.keycodes.map['f' .. tostring(i)])
end

function module:_install(mods, key)
  if key == nil or key == "" then
    key = mods
    mods = nil
  end
  if mods == nil or mods == "" then
    if key == 'cmd' or key == 'command' or key == '⌘' then
      self.key = 'cmd'
      self.idx = '⌘⌘'
    elseif key == 'ctrl' or key == 'control' or key == '⌃' then
      self.key = 'ctrl'
      self.idx = '⌃⌃'
    elseif key == 'alt' or key == 'option' or key == '⌥' then
      self.key = 'alt'
      self.idx = '⌥⌥'
    elseif key == 'shift' or key == '⇧' then
      self.key = 'shift'
      self.idx = '⇧⇧'
    else
      self.key = hs.keycodes.map[key]
      local keyRepr = getIndex(self.key)
      self.idx = keyRepr .. keyRepr
      if hs.fnutils.contains(functionKeycodes, self.key) then
        self.mods = { 'fn' }
      end
    end
  else
    if type(mods) == 'string' then mods = { mods } end
    local idx, modsRepr = "", {}
    if hs.fnutils.contains(mods, "command") then
      idx = modifiers.command
      tinsert(modsRepr, 'cmd')
    end
    if hs.fnutils.contains(mods, "control") then
      idx = idx .. modifiers.control
      tinsert(modsRepr, 'ctrl')
    end
    if hs.fnutils.contains(mods, "option") then
      idx = idx .. modifiers.option
      tinsert(modsRepr, 'alt')
    end
    if hs.fnutils.contains(mods, "shift") then
      idx = idx .. modifiers.shift
      tinsert(modsRepr, 'shift')
    end
    if hs.fnutils.contains(functionKeycodes, self.key) then
      tinsert(modsRepr, 'fn')
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
  if hs.fnutils.contains({'cmd', 'ctrl', 'alt', 'shift'}, self.key) then
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

    if hs.fnutils.contains({ 'cmd', 'ctrl', 'alt', 'shift' }, self.key) then
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
  return self
end

function module:disable()
  self.eventWatcher:stop()
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