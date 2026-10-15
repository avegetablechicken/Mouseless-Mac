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
  self.canvas:clickActivating(false)
  self.filter = options.filter
  self.tap = h.eventtap.new({h.eventtap.event.types.keyDown, h.eventtap.event.types.flagsChanged,
    h.eventtap.event.types.scrollWheel, h.eventtap.event.types.leftMouseDown,
    h.eventtap.event.types.leftMouseUp}, function(event)
    if not self.active then return false end
    local eventType = event:getType()
    if eventType == h.eventtap.event.types.leftMouseDown or eventType == h.eventtap.event.types.leftMouseUp then
      local point, frame = event:location(), self.canvas:frame()
      local x, y = point.x-frame.x, point.y-frame.y
      local inside = x >= 0 and x < frame.w and y >= 0 and y < frame.h
      local index = inside and self:indexAt(x, y)
      if eventType == h.eventtap.event.types.leftMouseDown then
        self.clickedInside = inside
        self.clickedID = index and self.session[index] or nil
        return inside
      end
      local clickedID, clickedInside = self.clickedID, self.clickedInside
      self.clickedID, self.clickedInside = nil, nil
      if index and clickedID == self.session[index] then
        self.selected = index
        self:finish(true)
      end
      return clickedInside == true
    end
    if event:getType() == h.eventtap.event.types.scrollWheel then
      local properties = h.eventtap.event.properties
      local continuous = event:getProperty(properties.scrollWheelEventIsContinuous) ~= 0
      local delta = continuous and event:getProperty(properties.scrollWheelEventPointDeltaAxis1)
          or event:getProperty(properties.scrollWheelEventDeltaAxis1)*40
      self.scrollDelta = (self.scrollDelta or 0)-delta
      local rows = math.modf(self.scrollDelta/40)
      if rows ~= 0 then self.scrollDelta = self.scrollDelta-rows*40; self:scrollRows(rows) end
      return true
    end
    if event:getType() == h.eventtap.event.types.keyDown then
      local key, flags = event:getKeyCode(), event:getFlags()
      if key == h.keycodes.map.escape then self:finish(false); return true end
      local repeated = event:getProperty(h.eventtap.event.properties.keyboardEventAutorepeat) == 1
      local actions = { [h.keycodes.map.w]='close', [h.keycodes.map.h]='hide',
        [h.keycodes.map.m]='minimize' }
      if actions[key] then
        if not repeated then self:actOnSelection(actions[key]) end
        return true
      end
      if key == self.nextCode or key == self.backCode then
        local direction = key == self.backCode and -1 or 1
        if key == self.nextCode and flags.shift and self.mode ~= 'minimized' then direction = -1 end
        self:cycle(self.mode, direction, repeated, self.modifiers)
        return true
      end
      local arrows = { [h.keycodes.map.left]={-1,0}, [h.keycodes.map.right]={1,0},
        [h.keycodes.map.up]={0,-1}, [h.keycodes.map.down]={0,1} }
      if arrows[key] then self:moveGrid(table.unpack(arrows[key])); return true end
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
  self.pollTimer = h.timer.doEvery(0.05, function()
    if self.active then
      local flags = h.eventtap.checkKeyboardModifiers()
      for _, modifier in ipairs(self.modifiers) do
        if not flags[modifier] then self:finish(true); break end
      end
    end
    self:receiveCaptures()
  end)
  self.refreshTimer = h.timer.doEvery(2, function() self:refreshCaptures() end)
  self.screenWatcher = h.screen.watcher.new(function()
    self.layoutKey = nil
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
    -- Keep surviving windows and the selection stable; append new eligible windows
    -- immediately, then resize the one-page grid to the new count.
    local selectionRow = math.floor((self.selected-1)/self.columns)
    local keepSelectionVisible = selectionRow >= self.scrollRow and selectionRow < self.scrollRow+self.visibleRows
    local selectedID, session, selected = self.session[self.selected], {}, nil
    local allowed = {}
    for _, id in ipairs(lists[self.mode]) do allowed[id] = not self.sessionExcluded[id] end
    for _, id in ipairs(self.session) do
      if allowed[id] then
        session[#session + 1] = id
        if id == selectedID then selected = #session end
        allowed[id] = nil
      end
    end
    for _, id in ipairs(lists[self.mode]) do
      if allowed[id] then session[#session+1] = id end
    end
    self.session = session
    if #session == 0 then self:finish(false)
    else
      self.selected = selected or math.min(self.selected, #session)
      self:layout()
      if keepSelectionVisible or not selected then self:ensureSelectionVisible() end
      self:paint()
    end
  end
  if not self.active then self:layout() end
  self:refreshCaptures()
end

function Engine:indexAt(x, y)
  local first = self.scrollRow*self.columns+1
  local last = math.min(#self.session, first+self.visibleRows*self.columns-1)
  local offset = self.scrollRow*self.cellHeight
  for i = first, last do
    local tile = self.tileFrames[i]
    if x >= tile.x and x < tile.x+tile.w and y >= tile.y-offset
        and y < tile.y-offset+tile.h then return i end
  end
end

function Engine:actOnSelection(action)
  if not self.active then return end
  local record = self.records[self.session[self.selected]]
  if not record then return end
  call(function()
    if action == 'hide' then
      local app = record.win:application()
      if app then
        app:hide()
        for _, item in pairs(self.records) do
          if item.pid == record.pid then self:updateRecord(item.win) end
        end
      end
    elseif action == 'minimize' then
      record.win:minimize()
      self:updateRecord(record.win)
      -- Do not restore this window on modifier release in the minimized mode.
      if record.win:isMinimized() then self.sessionExcluded[record.id] = true end
    elseif action == 'close' then
      record.win:close()
    end
  end)
  if action ~= 'close' then self:rebuild() end
  -- Closing may raise a save dialog; let the window filter confirm destruction.
  stop(self.inventoryTimer)
  self.inventoryTimer = self.h.timer.doAfter(0.02, function() self:rebuild() end)
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
    -- The selected preview gets the highest priority in the native queue.
    local first = (self.scrollRow or 0)*self.columns+1
    local last = math.min(#self.session, first+self.visibleRows*self.columns-1)
    for i = last, first, -1 do
      if i ~= self.selected then self:requestCapture(self.session[i], true) end
    end
    if self.selected >= first and self.selected <= last then self:requestCapture(self.session[self.selected], true) end
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

-- Grow monotonically up to 5x6; larger lists scroll vertically at the same card size.
-- Screen geometry changes card scale only, never the row/column growth order.
function M.gridLayout(count, screen)
  local visibleCount = math.min(count, 30)
  local columns = math.min(4, visibleCount)
  local rows = math.min(3, math.ceil(visibleCount / columns))
  while rows * columns < visibleCount do
    if columns == rows + 1 then columns = columns + 1
    else rows = rows + 1 end
  end
  local scale = math.min(1, (screen.w-72)/(columns*300), (screen.h-90)/(rows*230))
  return {columns=columns, rows=math.ceil(count/columns), visibleRows=rows, scale=scale}
end

function Engine:layout()
  local screen = self.h.screen.mainScreen():frame()
  local count = math.max(1, self.active and #self.session or #(self.lists.minimized or {}))
  local grid = M.gridLayout(count, screen)
  local columns, rows, scale = grid.columns, grid.rows, grid.scale
  local cellWidth, cellHeight, gridY = 300*scale, 230*scale, 16
  local width, height = columns * cellWidth + 24, gridY + grid.visibleRows * cellHeight + 26
  local frame = {x=screen.x+(screen.w-width)/2,y=screen.y+(screen.h-height)/2,w=width,h=height}
  local key = table.concat({count,cellWidth,columns,rows,frame.x,frame.y}, ':')
  if self.layoutKey == key then return end
  self.canvas:frame(frame)
  self.capture.positionGlass(frame.x, frame.y, frame.w, frame.h)
  self.columns, self.rows, self.visibleRows = columns, rows, grid.visibleRows
  self.cellWidth, self.cellHeight, self.scale = cellWidth, cellHeight, scale
  self.scrollRow = math.max(0, math.min(self.scrollRow or 0, rows-grid.visibleRows))
  self.layoutKey = key
  self.slots = math.max(self.slots or 0, math.min(count, 30))
  local elements = {
    {type='rectangle', action='fill', fillColor={white=0.12,alpha=0.08}, roundedRectRadii={xRadius=14,yRadius=14}, frame={x=0,y=0,w=width,h=height}},
    {type='rectangle', action='strokeAndFill', fillColor={red=0.8,green=0.5,blue=0,alpha=0.16}, strokeColor={red=1,green=0.68,blue=0.12,alpha=0.95}, strokeWidth=3, roundedRectRadii={xRadius=10,yRadius=10}, frame={x=12,y=gridY,w=cellWidth-8*scale,h=cellHeight-8*scale}},
  }
  self.tileFrames = {}
  for i = 1, count do
    local row = math.floor((i-1)/columns)
    local rowCount = math.min(columns, math.max(1, count-row*columns))
    local x = (width-rowCount*cellWidth)/2 + ((i-1)%columns)*cellWidth
    local y = gridY + row*cellHeight
    self.tileFrames[i] = {x=x+4*scale,y=y,w=cellWidth-8*scale,h=cellHeight-8*scale}
    if i <= self.slots then
      elements[#elements+1] = {type='image', imageScaling='scaleProportionally', frame={x=x+12*scale,y=y+44*scale,w=cellWidth-24*scale,h=cellHeight-60*scale}}
      elements[#elements+1] = {type='image', imageScaling='scaleProportionally', frame={x=x+12*scale,y=y+10*scale,w=24*scale,h=24*scale}}
      elements[#elements+1] = {type='text',text='',textSize=14*scale,textColor={white=1},textAlignment='left',textLineBreak='truncateTail',frame={x=x+44*scale,y=y+12*scale,w=cellWidth-58*scale,h=22*scale}}
    end
  end
  -- Retained slots beyond the current count stay hidden and remain reusable.
  for _ = count+1, self.slots do
    elements[#elements+1] = {type='image',action='skip'}
    elements[#elements+1] = {type='image',action='skip'}
    elements[#elements+1] = {type='text',text='',action='skip'}
  end
  elements[#elements+1] = {type='text',text='',textSize=11,textColor={white=0.8},textAlignment='center',frame={x=12,y=height-20,w=width-24,h=16}}
  elements[#elements+1] = {type='rectangle',action='skip',fillColor={white=1,alpha=0.12},frame={x=width-7,y=gridY,w=3,h=height-42}}
  elements[#elements+1] = {type='rectangle',action='skip',fillColor={white=1,alpha=0.5},roundedRectRadii={xRadius=1.5,yRadius=1.5},frame={x=width-7,y=gridY,w=3,h=1}}
  self.canvas:replaceElements(table.unpack(elements))
end

function Engine:ensureSelectionVisible()
  local row = math.floor((self.selected-1)/self.columns)
  if row < self.scrollRow then self.scrollRow = row
  elseif row >= self.scrollRow+self.visibleRows then self.scrollRow = row-self.visibleRows+1 end
  self.scrollDelta = 0
end

function Engine:scrollRows(rows)
  if not self.active then return end
  local offset = math.max(0, math.min(self.rows-self.visibleRows, self.scrollRow+rows))
  if offset == self.scrollRow then return end
  self.scrollRow = offset
  self:paint()
  stop(self.afterShow)
  self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
end

function Engine:paint()
  if not self.active then return end
  local record = self.records[self.session[self.selected]]
  if not record then return end
  local first = self.scrollRow*self.columns+1
  local last = math.min(#self.session, first+self.visibleRows*self.columns-1)
  local offset = self.scrollRow*self.cellHeight
  local selected = self.tileFrames[self.selected]
  self.canvas:elementAttribute(2, 'action', self.selected >= first and self.selected <= last and 'strokeAndFill' or 'skip')
  self.canvas:elementAttribute(2, 'frame', {x=selected.x,y=selected.y-offset,w=selected.w,h=selected.h})
  for i = 1, self.slots do
    local index = first+i-1
    local item = index <= last and self.records[self.session[index]] or nil
    local base = 3+(i-1)*3
    for j = base, base+2 do self.canvas:elementAttribute(j, 'action', item and 'strokeAndFill' or 'skip') end
    if item then
      local tile, scale = self.tileFrames[index], self.scale
      local x, y = tile.x-4*scale, tile.y-offset
      self.canvas:elementAttribute(base, 'frame', {x=x+12*scale,y=y+44*scale,w=self.cellWidth-24*scale,h=self.cellHeight-60*scale})
      self.canvas:elementAttribute(base+1, 'frame', {x=x+12*scale,y=y+10*scale,w=24*scale,h=24*scale})
      self.canvas:elementAttribute(base+2, 'frame', {x=x+44*scale,y=y+12*scale,w=self.cellWidth-58*scale,h=22*scale})
      self.canvas:elementAttribute(base, 'image', item.image or item.icon)
      self.canvas:elementAttribute(base+1, 'image', item.icon)
      self.canvas:elementAttribute(base+2, 'text', (item.minimized and '↓ ' or '') .. (item.title ~= '' and item.title or item.appName))
    end
  end
  self.canvas:elementAttribute(3+self.slots*3, 'text', self.selected .. ' / ' .. #self.session .. '   ·   Esc')
  local scrolling = self.rows > self.visibleRows
  for i=4+self.slots*3,5+self.slots*3 do self.canvas:elementAttribute(i,'action',scrolling and 'fill' or 'skip') end
  if scrolling then
    local trackHeight = self.visibleRows*self.cellHeight
    local thumbHeight = trackHeight*self.visibleRows/self.rows
    self.canvas:elementAttribute(5+self.slots*3,'frame',{x=self.columns*self.cellWidth+17,
      y=16+(trackHeight-thumbHeight)*self.scrollRow/(self.rows-self.visibleRows),w=3,h=thumbHeight})
  end
end

function Engine:cycle(mode, direction, repeated, modifiers)
  if self.deleted then return end
  stop(self.focusTimer)
  local started = self.h.timer.absoluteTime()
  if not self.active or (mode == 'browsers') ~= (self.mode == 'browsers') then
    if self.active then self:finish(false) end
    self.sessionExcluded, self.clickedID, self.clickedInside = {}, nil, nil
    self.session = {}; for i, id in ipairs(self.lists[mode]) do self.session[i] = id end
    if #self.session == 0 then return end
    self.active, self.mode, self.modifiers = true, mode, modifiers
    self.scrollRow, self.scrollDelta = 0, 0
    local keys = (self.options.navigationKeys or {})[mode] or {}
    self.nextCode = self.h.keycodes.map[keys.next or 'tab']
    self.backCode = self.h.keycodes.map[keys.back or '`']
    self.selected = direction > 0 and math.min(2, #self.session) or #self.session
    self:layout()
    self:ensureSelectionVisible()
    self.options.onActiveChange(true, mode)
    self.tap:start()
    self:paint()
    self.capture.showGlass()
    self.canvas:show()
    self.metrics.lastShowMs = (self.h.timer.absoluteTime()-started)/1e6
    -- No snapshot, AX query, window enumeration or native request before show().
    stop(self.afterShow)
    self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
  else
    local nextIndex = self.selected + direction
    if repeated and (nextIndex < 1 or nextIndex > #self.session) then return end
    self.selected = ((nextIndex-1) % #self.session)+1
    self:ensureSelectionVisible()
    self:paint()
    stop(self.afterShow)
    self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
  end
end

function Engine:moveGrid(dx, dy)
  if not self.active then return end
  local row = math.floor((self.selected-1)/self.columns)
  local target = self.selected
  if dx ~= 0 then
    target = math.max(row*self.columns+1, math.min((row+1)*self.columns, #self.session, target+dx))
  else
    local nextRow = row+dy
    if nextRow < 0 or nextRow >= self.rows then return end
    local current = self.tileFrames[self.selected]
    local center, distance = current.x+current.w/2, math.huge
    for i = nextRow*self.columns+1, math.min((nextRow+1)*self.columns, #self.session) do
      local frame = self.tileFrames[i]
      local delta = math.abs(frame.x+frame.w/2-center)
      if delta < distance then target, distance = i, delta end
    end
  end
  if target == self.selected then return end
  self.selected = target
  self:ensureSelectionVisible()
  self:paint()
  stop(self.afterShow)
  self.afterShow = self.h.timer.doAfter(0, function() self:refreshCaptures() end)
end

function Engine:finish(commit)
  if not self.active then return end
  local record = self.records[self.session[self.selected]]
  self.active, self.mode, self.session, self.selected = false, nil, {}, 0
  self.clickedID, self.clickedInside = nil, nil
  stop(self.afterShow)
  self.canvas:hide(); self.capture.hideGlass(); self.tap:stop()
  self.options.onActiveChange(false)
  if commit and record then
    -- Let both panel windows finish ordering out before a Space transition starts.
    self.focusTimer = self.h.timer.doAfter(0, function()
      self.focusTimer = nil
      call(function() record.win:unminimize(); record.win:focus() end)
    end)
  end
end

function Engine:delete()
  if self.deleted then return end
  self:finish(false); self.deleted = true
  stop(self.focusTimer)
  stop(self.inventoryTimer); stop(self.pollTimer); stop(self.refreshTimer); stop(self.afterShow)
  self.screenWatcher:stop(); self.tap:stop()
  self.filter:delete(); self.canvas:delete(); self.capture.reset()
  self.records, self.icons, self.lists = {}, {}, {}
end

return M
