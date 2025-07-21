local tinsert = table.insert
local tremove = table.remove

local log = hs.logger.new('hotkey', 'info')

local This = {}
This.keys = {}
This.eventtapper = nil

local trackpad = {
  ["top-left"] = "⌜",
  ["top-right"] = "⌝",
  ["bottom-left"] = "⌞",
  ["bottom-right"] = "⌟",
}

local params = KeybindingConfigs["parameters"] or {}
This.CORNER_SIZE = params.trackpadCornerSize or 0.25
if This.CORNER_SIZE <= 0 then This.CORNER_SIZE = 0.1 end
if This.CORNER_SIZE >= 0.5 then This.CORNER_SIZE = 0.4 end

local function getModsCode(mods)
  local modsCode = 0
  if type(mods) == 'table' then
    for i = #mods, 1, -1 do
      if mods[i] == "top-left" then
        modsCode = modsCode + 1
        tremove(mods, i)
      elseif mods[i] == "top-right" then
        modsCode = modsCode + 2
        tremove(mods, i)
      elseif mods[i] == "bottom-left" then
        modsCode = modsCode + 4
        tremove(mods, i)
      elseif mods[i] == "bottom-right" then
        modsCode = modsCode + 8
        tremove(mods, i)
      end
    end
  elseif mods == "top-left" then
    modsCode = 1
    mods = ""
  elseif mods == "top-right" then
    modsCode = 2
    mods = ""
  elseif mods == "bottom-left" then
    modsCode = 4
    mods = ""
  elseif mods == "bottom-right" then
    modsCode = 8
    mods = ""
  else
    if mods:find("⌜") then
      modsCode = modsCode + 1
      mods = mods:gsub("⌜", "")
    end
    if mods:find("⌝") then
      modsCode = modsCode + 2
      mods = mods:gsub("⌝", "")
    end
    if mods:find("⌞") then
      modsCode = modsCode + 4
      mods = mods:gsub("⌞", "")
    end
    if mods:find("⌟") then
      modsCode = modsCode + 8
      mods = mods:gsub("⌟", "")
    end
  end
  return modsCode
end

local function getModsRepr(modsCode)
  local modsRepr = ""
  if (modsCode // 8) % 2 == 1 then modsRepr = trackpad["bottom-right"] end
  if (modsCode // 4) % 2 == 1 then modsRepr = trackpad["bottom-left"] .. modsRepr end
  if (modsCode // 2) % 2 == 1 then modsRepr = trackpad["top-right"] .. modsRepr end
  if modsCode % 2 == 1 then modsRepr = trackpad["top-left"] .. modsRepr end
  return modsRepr
end

function This._startEventTapper()
  if This.eventtapper == nil then
    This.eventtapper = hs.eventtap.new({hs.eventtap.event.types.gesture},
    function(ev)
      local touches = ev:getTouches()
      local modsCodeInvoked = 0
      if touches ~= nil and hs.fnutils.every(touches,
          function(t) return t.touching == true and t.type == 'indirect' end) then
        for _, t in ipairs(touches) do
          local tpos = t.normalizedPosition
          local s1, s2 = This.CORNER_SIZE, 1 - This.CORNER_SIZE
          if tpos.x < s1 and tpos.y > s2 then
            modsCodeInvoked = modsCodeInvoked + 1
          elseif tpos.x > s2 and tpos.y > s2 then
            modsCodeInvoked = modsCodeInvoked + 2
          elseif tpos.x < s1 and tpos.y < s1 then
            modsCodeInvoked = modsCodeInvoked + 4
          elseif tpos.x > s2 and tpos.y < s1 then
            modsCodeInvoked = modsCodeInvoked + 8
          else
            modsCodeInvoked = 0
            break
          end
        end
      end
      for k, hotkeys in pairs(This.keys) do
        if k == modsCodeInvoked then
          for _, hk in ipairs(hotkeys) do
            hk:enable()
          end
        else
          for _, hk in ipairs(hotkeys) do
            hk:disable()
          end
        end
      end
      return false
    end):start()
  end
end

function This.bindNoSuspend(mods, ...)
  local modsCode = getModsCode(mods)
  if This.keys[modsCode] == nil then
    This.keys[modsCode] = {}
  end
  local hotkey = newHotkeyImpl(mods, ...)
  local modsRepr = getModsRepr(modsCode)
  hotkey.msg = modsRepr .. hotkey.msg
  tinsert(This.keys[modsCode], hotkey)
  This._startEventTapper()
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

function This.bind(mods, ...)
  local modsCode = getModsCode(mods)
  if This.keys[modsCode] == nil then
    This.keys[modsCode] = {}
  end
  local hotkey = newHotkey(mods, ...)
  local modsRepr = getModsRepr(modsCode)
  hotkey.msg = modsRepr .. hotkey.msg
  tinsert(This.keys[modsCode], hotkey)
  This._startEventTapper()
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

return This
