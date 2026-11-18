-- Immediate text expansion with a bounded buffer for backspace corrections.
local M = {}

function M.start(shared, overrides)
  shared, overrides = shared or {}, overrides or {}
  local enabled = overrides.enabled
  if enabled == nil then enabled = shared.enabled end
  if enabled == false then return end
  local rules, orderedRules = {}, {}
  for _, config in ipairs({shared, overrides}) do
    assert(config.prefix == nil and config.entries == nil,
        "snippet prefixes and entries must be configured in snippets.rules")
    local sourceRules = config.rules or {}
    assert(type(sourceRules) == "table", "snippets.rules must be a list")
    for index in pairs(sourceRules) do
      assert(type(index) == "number" and index % 1 == 0
          and index >= 1 and index <= #sourceRules, "snippets.rules must be a list")
    end
    for _, source in ipairs(sourceRules) do
      assert(type(source) == "table", "each snippet rule must be an object")
      local prefix = source.prefix
      assert(type(prefix) == "string" and prefix:match("^[!-~]+$"),
          "snippet rule prefixes must contain printable ASCII characters without spaces")
      assert(source.sound == nil, "snippet sound must be configured globally in snippets.sound")
      local rule = rules[prefix]
      if not rule then
        rule = {prefix = prefix, entries = {}}
        rules[prefix] = rule
        orderedRules[#orderedRules + 1] = rule
      end
      if source.enabled ~= nil then rule.enabled = source.enabled end
      for name, value in pairs(source.entries or {}) do rule.entries[name] = value end
    end
  end
  local replacements = {}
  local bufferLimit = 64
  for _, rule in ipairs(orderedRules) do
    if rule.enabled ~= false then
      for name, value in pairs(rule.entries) do
        assert(type(name) == "string" and name:match("^[!-~]+$"),
            "snippet names must contain printable ASCII characters without spaces")
        assert(value == false or (type(value) == "string" and utf8.len(value)),
            "snippet values must be UTF-8 strings or false")
        if value ~= false then
          local trigger = rule.prefix .. name
          assert(replacements[trigger] == nil, "snippet rules produce duplicate triggers")
          bufferLimit = math.max(bufferLimit, #trigger + 64)
          replacements[trigger] = value
        end
      end
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

  -- A click resets the buffer. Count clicks with the native listen-only tap so
  -- that they never wait for this callback; observe them here only without it.
  local loaded, keystate = pcall(require, "modal.keystate")
  keystate = loaded and keystate or nil
  local mouseDowns = keystate and keystate.mouseDownCount()
  local eventTypes = {types.keyDown}
  if mouseDowns == nil then
    eventTypes = {types.keyDown, types.leftMouseDown, types.rightMouseDown, types.otherMouseDown}
  end

  -- The native tap reports keys after they were delivered, so typing never
  -- waits for this callback.
  local tap, native
  tap, native = require("modal.keytap").new({listen = eventTypes}, function(ev, keyDowns)
    if ev:getProperty(properties.eventSourceUserData) == marker then
      return false
    end
    if ev:getType() ~= types.keyDown then
      buffer = ""
      return false
    end
    if mouseDowns ~= nil then
      local count = keystate.mouseDownCount()
      if count ~= mouseDowns then mouseDowns, buffer = count, "" end
    end
    local flags = ev:getFlags()
    -- The frontmost application, not the focused element: asking the app over
    -- Accessibility here held every keystroke until that app answered.
    local app = hs.application.frontmostApplication()
    local focus = app and app:pid()
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
    while candidate ~= "" and replacements[candidate] == nil do candidate = candidate:sub(2) end
    local replacement = replacements[candidate]
    if replacement == nil then return false end

    local events = {}
    -- The last physical key is suppressed, so only erase earlier characters.
    -- A native tap reported it after it was delivered: erase it too, unless
    -- more keys followed, which the replacement would be mixed with.
    local erase = #candidate - 1
    if native then
      if keyDowns ~= keystate.keyDownCount() then
        buffer = ""
        return false
      end
      erase = #candidate
    end
    for _ = 1, erase do keyEvents(events, "delete") end
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
    if native then
      for _, e in ipairs(events) do e:post() end
      return false
    end
    return true, events
  end)
  return tap:start()
end

return M
