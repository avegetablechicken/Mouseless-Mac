-- Persistent window inventory and canvas. The summon path uses only cached records;
-- captures arrive asynchronously and never gate showing or keyboard navigation.
local M = {}
local Engine = {}; Engine.__index = Engine

local function stop(timer) if timer then timer:stop() end end
local function call(fn, ...)
  local ok, value = pcall(fn, ...)
  return ok and value or nil
end

function M.new(options, runtime)
  local h = runtime or hs
  local self = setmetatable({ h = h, options = options, records = {}, lists = {},
    icons = {}, serial = 0, active = false, mode = nil, selected = 0,
    session = {}, metrics = {}, captureErrors = 0 }, Engine)
  self.capture = options.capture or require('window.capture').new(h)
  self.canvas = h.canvas.new({x = 0, y = 0, w = 1, h = 1})
      :level(h.canvas.windowLevels.overlay):behavior({ 'canJoinAllSpaces', 'fullScreenAuxiliary' })
  self.filter = options.filter
  self.tap = h.eventtap.new({h.eventtap.event.types.keyDown, h.eventtap.event.types.flagsChanged}, function(event)
    if not self.active then return false end
    if event:getType() == h.eventtap.event.types.keyDown then
      if event:getKeyCode() == h.keycodes.map.escape then self:finish(false); return true end
      return false
    end
    local flags = event:getFlags()
    for _, modifier in ipairs(self.modifiers) do
      if not flags[modifier] then self:finish(true); break end
    end
    return false
  end)
  local wf = h.window.filter
  self.filter:subscribe({wf.windowsChanged, wf.windowFocused, wf.windowTitleChanged,
    wf.windowMinimized, wf.windowUnminimized, wf.windowHidden, wf.windowUnhidden,
    wf.windowMoved}, function(win)
      if win then self:updateRecord(win) end
      stop(self.inventoryTimer)
      self.inventoryTimer = h.timer.doAfter(0.02, function() self:rebuild() end)
  end)
  self:rebuild()
  self:layout()
  self.pollTimer = h.timer.doEvery(0.05, function() self:receiveCaptures() end)
  self.refreshTimer = h.timer.doEvery(2, function() self:refreshCaptures() end)
  self.screenWatcher = h.screen.watcher.new(function()
    self.slots = nil
    if self.active then self:layout(); self:paint() end
  end):start()
  return self
end

function Engine:updateRecord(win)
  local id = call(function() return win:id() end)
  if not id then return end
  local record = call(function()
    local app = win:application()
    if not app then return end
    local old = self.records[id]
    local pid, bundle = app:pid(), app:bundleID()
    local same = old and old.pid == pid
    if not same then self.serial = self.serial + 1 end
    local iconKey = bundle or ('pid:' .. pid)
    if not self.icons[iconKey] then self.icons[iconKey] = (bundle and self.h.image.imageFromAppBundle(bundle))
        or self.h.image.imageFromName('NSApplicationIcon') end
    return { id = id, win = win, pid = pid, bundle = bundle, title = win:title() or '',
      appName = app:name(), icon = self.icons[iconKey], token = same and old.token or self.serial,
      image = same and old.image or nil, capturedAt = same and old.capturedAt or nil,
      requestedAt = same and old.requestedAt or nil, retryAt = same and old.retryAt or nil,
      visible = win:isVisible(), minimized = win:isMinimized(), hidden = app:isHidden() }
  end)
  if record then self.records[id] = record end
  return record
end

function Engine:rebuild()
  if self.deleted then return end
  local lists = { normal = {}, minimized = {}, browsers = {} }
  local retained = {}
  for _, win in ipairs(self.filter:getWindows(self.h.window.filter.sortByFocusedLast)) do
    local id = call(function() return win:id() end)
    local record = id and (self.records[id] or self:updateRecord(win))
    if record then
      retained[id] = record
      if not record.hidden then
        if record.visible then
          lists.normal[#lists.normal + 1] = id
          if self.options.browsers[record.bundle] then lists.browsers[#lists.browsers + 1] = id end
        end
        if record.visible or record.minimized then lists.minimized[#lists.minimized + 1] = id end
      end
    end
  end
  self.records, self.lists = retained, lists
  if self.active then
    -- Preserve order while cycling; remove closed/hidden windows without moving selection
    -- to a different surviving window. Newly opened windows appear next session.
    local selectedID, session, selected = self.session[self.selected], {}, nil
    local allowed = {}; for _, id in ipairs(lists[self.mode]) do allowed[id] = true end
    for _, id in ipairs(self.session) do
      if allowed[id] then
        session[#session + 1] = id
        if id == selectedID then selected = #session end
      end
    end
    self.session = session
    if #session == 0 then self:finish(false)
    else
      self.selected = selected or math.min(self.selected, #session)
      self:paint()
    end
  end
  self:refreshCaptures()
end

function Engine:requestCapture(id, priority)
  local record, now = self.records[id], self.h.timer.secondsSinceEpoch()
  if not record or record.hidden or (record.retryAt and now < record.retryAt) then return end
  if record.requestedAt and now - record.requestedAt < 2 then return end
  if record.capturedAt and now - record.capturedAt < (priority and 1 or 10) then return end
  if self.capture.request(id, record.token, priority) then record.requestedAt = now end
end

function Engine:refreshCaptures()
  if self.deleted then return end
  if self.active then
    local first = math.floor((self.selected - 1) / self.slots) * self.slots + 1
    -- The selected preview gets the highest priority in the native queue.
    for i = math.min(#self.session, first + self.slots - 1), first, -1 do
      if i ~= self.selected then self:requestCapture(self.session[i], true) end
    end
    self:requestCapture(self.session[self.selected], true)
  else
    for i, id in ipairs(self.lists.minimized or {}) do
      if i == 1 or not self.records[id].image then self:requestCapture(id, false) end
    end
  end
end

function Engine:receiveCaptures()
  if self.deleted then return end
  local changed = false
  for _, result in ipairs(self.capture.poll()) do
    local record = self.records[result.id]
    if record and record.token == result.token then
      record.requestedAt = nil
      if result.image then
        local image = self.h.image.imageFromURL(result.image)
        if image then record.image, record.capturedAt = image, self.h.timer.secondsSinceEpoch(); changed = true end
      else
        self.captureErrors = self.captureErrors + 1
        self.lastCaptureError = result.error
        -- Preserve a valid older image when an offscreen/minimized capture fails.
        record.retryAt = self.h.timer.secondsSinceEpoch() + 10
      end
    end
  end
  if changed and self.active then self:paint() end
end

function Engine:layout()
  local screen = self.h.screen.mainScreen():frame()
  local slots = math.max(1, math.min(10, math.floor((screen.w - 48) / 148)))
  local width, height = slots * 148 + 24, 430
  self.canvas:frame({ x = screen.x + (screen.w - width) / 2,
    y = screen.y + (screen.h - height) / 2, w = width, h = height })
  if self.slots == slots then return end
  self.slots = slots
  local elements = {
    {type='rectangle', action='fill', fillColor={white=0.3,alpha=1}, roundedRectRadii={xRadius=14,yRadius=14}, frame={x=0,y=0,w=width,h=height}},
    {type='image', imageScaling='scaleProportionally', frame={x=(width-384)/2,y=14,w=384,h=240}},
    {type='text', text='', textSize=19, textColor={white=1}, textAlignment='center', textLineBreak='truncateTail', frame={x=12,y=260,w=width-24,h=28}},
    {type='rectangle', action='fill', fillColor={red=0.8,green=0.5,blue=0,alpha=1}, roundedRectRadii={xRadius=8,yRadius=8}, frame={x=12,y=298,w=144,h=106}},
  }
  for i = 1, slots do
    local x = 16 + (i-1)*148
    elements[#elements+1] = {type='image', imageScaling='scaleProportionally', frame={x=x,y=302,w=136,h=76}}
    elements[#elements+1] = {type='image', imageScaling='scaleProportionally', frame={x=x+104,y=350,w=28,h=28}}
    elements[#elements+1] = {type='text',text='',textSize=12,textColor={white=1},textAlignment='center',textLineBreak='truncateTail',frame={x=x,y=382,w=136,h=20}}
  end
  elements[#elements+1] = {type='text',text='',textSize=11,textColor={white=0.7},textAlignment='center',frame={x=12,y=410,w=width-24,h=16}}
  self.canvas:replaceElements(table.unpack(elements))
end

function Engine:paint()
  if not self.active then return end
  local record = self.records[self.session[self.selected]]
  if not record then return end
  local first = math.floor((self.selected-1)/self.slots)*self.slots+1
  self.canvas:elementAttribute(2, 'image', record.image or record.icon)
  self.canvas:elementAttribute(3, 'text', record.title ~= '' and record.title or record.appName)
  self.canvas:elementAttribute(4, 'frame', {x=12+(self.selected-first)*148,y=298,w=144,h=106})
  for i = 1, self.slots do
    local item = self.records[self.session[first+i-1]]
    local base = 5+(i-1)*3
    for j = base, base+2 do self.canvas:elementAttribute(j, 'action', item and 'strokeAndFill' or 'skip') end
    if item then
      self.canvas:elementAttribute(base, 'image', item.image or item.icon)
      self.canvas:elementAttribute(base+1, 'image', item.icon)
      self.canvas:elementAttribute(base+2, 'text', (item.minimized and '↓ ' or '') .. (item.title ~= '' and item.title or item.appName))
    end
  end
  self.canvas:elementAttribute(5+self.slots*3, 'text', self.selected .. ' / ' .. #self.session .. '   ·   Esc')
end

function Engine:cycle(mode, direction, repeated, modifiers)
  if self.deleted then return end
  local started = self.h.timer.absoluteTime()
  if not self.active or (mode == 'browsers') ~= (self.mode == 'browsers') then
    if self.active then self:finish(false) end
    self.session = {}; for i, id in ipairs(self.lists[mode]) do self.session[i] = id end
    if #self.session == 0 then return end
    self.active, self.mode, self.modifiers = true, mode, modifiers
    self.selected = direction > 0 and math.min(2, #self.session) or #self.session
    self:layout()
    self.options.onActiveChange(true, mode)
    self.tap:start()
    self:paint()
    self.canvas:show()
    self.metrics.lastShowMs = (self.h.timer.absoluteTime()-started)/1e6
    -- No snapshot, AX query, window enumeration or native request before show().
    stop(self.afterShow)
    self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
  else
    local nextIndex = self.selected + direction
    if repeated and (nextIndex < 1 or nextIndex > #self.session) then return end
    self.selected = ((nextIndex-1) % #self.session)+1
    self:paint()
    stop(self.afterShow)
    self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
  end
end

function Engine:finish(commit)
  if not self.active then return end
  local record = self.records[self.session[self.selected]]
  self.active, self.mode, self.session, self.selected = false, nil, {}, 0
  stop(self.afterShow)
  self.canvas:hide(); self.tap:stop()
  self.options.onActiveChange(false)
  if commit and record then
    call(function() record.win:unminimize(); record.win:focus() end)
  end
end

function Engine:delete()
  if self.deleted then return end
  self:finish(false); self.deleted = true
  stop(self.inventoryTimer); stop(self.pollTimer); stop(self.refreshTimer); stop(self.afterShow)
  self.screenWatcher:stop(); self.tap:stop()
  self.filter:delete(); self.canvas:delete(); self.capture.reset()
  self.records, self.icons, self.lists = {}, {}, {}
end

return M
