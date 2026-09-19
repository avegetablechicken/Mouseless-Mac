-- Immediate text expansion with a bounded buffer for backspace corrections.
local M = {}

function M.start(shared, overrides)
  shared, overrides = shared or {}, overrides or {}
  local enabled = overrides.enabled
  if enabled == nil then enabled = shared.enabled end
  if enabled == false then return end
  local prefix = overrides.prefix or shared.prefix or "!!"
  assert(type(prefix) == "string" and prefix:match("^[!-~]+$"),
      "snippets.prefix must contain printable ASCII characters without spaces")
  local entries = {}
  for name, value in pairs(shared.entries or {}) do entries[name] = value end
  for name, value in pairs(overrides.entries or {}) do entries[name] = value end
  local replacements, prefixes = {}, {}
  local bufferLimit = 64
  for name, value in pairs(entries) do
    assert(type(name) == "string" and name:match("^[!-~]+$"),
        "snippet names must contain printable ASCII characters without spaces")
    assert(value == false or (type(value) == "string" and utf8.len(value)),
        "snippet values must be UTF-8 strings or false")
    if value ~= false then
      local trigger = prefix .. name
      bufferLimit = math.max(bufferLimit, #trigger + 64)
      replacements[trigger] = value
      for i = 1, #trigger do prefixes[trigger:sub(1, i)] = true end
    end
  end
  if next(replacements) == nil then return end
  local sound = overrides.sound
  if sound == nil then sound = shared.sound end
  if sound == nil then sound = "Pop" end
  assert(sound == false or (type(sound) == "string" and sound ~= ""),
      "snippets.sound must be a system sound name or false")
  local expansionSound = sound ~= false and hs.sound.getByName(sound) or nil

  local event = hs.eventtap.event
  local types, properties = event.types, event.properties
  local marker = 0x534E4950
  local buffer, previousFocus, previousSource = "", nil, nil
  local function keyEvents(events, key, text)
    for _, down in ipairs({true, false}) do
      local ev = event.newKeyEvent({}, key, down)
      if text then ev:setUnicodeString(text) end
      ev:setProperty(properties.eventSourceUserData, marker)
      events[#events + 1] = ev
    end
  end

  return hs.eventtap.new({types.keyDown, types.leftMouseDown,
      types.rightMouseDown, types.otherMouseDown}, function(ev)
    if ev:getProperty(properties.eventSourceUserData) == marker then
      return false
    end
    if ev:getType() ~= types.keyDown then
      buffer = ""
      return false
    end
    local flags = ev:getFlags()
    local focus = hs.uielement.focusedElement()
    local source = hs.keycodes.currentSourceID()
    if focus ~= previousFocus or source ~= previousSource then buffer = "" end
    previousFocus, previousSource = focus, source
    if not focus or flags.cmd or flags.ctrl or flags.alt or flags.fn
        or hs.eventtap.isSecureInputEnabled() then
      buffer = ""
      return false
    end
    local key = ev:getKeyCode()
    if key == hs.keycodes.map.delete then
      buffer = buffer:sub(1, -2)
      return false
    end
    local char = ev:getCharacters()
    if not char or not char:match("^[!-~]$") then
      buffer = ""
      return false
    end
    buffer = (buffer .. char):sub(-bufferLimit)
    local candidate = buffer
    while candidate ~= "" and not prefixes[candidate] do candidate = candidate:sub(2) end
    local replacement = replacements[candidate]
    if replacement == nil then return false end

    local events = {}
    -- The last physical key is suppressed, so only erase earlier characters.
    for _ = 1, #candidate - 1 do keyEvents(events, "delete") end
    for _, code in utf8.codes(replacement) do
      if code == 10 or code == 13 then
        keyEvents(events, "return")
      elseif code == 9 then
        keyEvents(events, "tab")
      else
        keyEvents(events, "a", utf8.char(code))
      end
    end
    buffer = ""
    if expansionSound then expansionSound:play() end
    return true, events
  end):start()
end

return M
