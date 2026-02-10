local function focusedWindowExist()
  return hs.window.focusedWindow() ~= nil
end

local function focusedWindowExistWrapper(fn)
  return function()
    if focusedWindowExist() then return fn() end
  end
end

-- Create a window-operation hotkey for screen/space operations.
local function newWindow(spec, message, pressedfn, releasedfn, repeatedfn, ...)
  pressedfn = focusedWindowExistWrapper(pressedfn)
  if releasedfn then
    releasedfn = focusedWindowExistWrapper(releasedfn)
  end
  if repeatedfn then
    repeatedfn = focusedWindowExistWrapper(repeatedfn)
  end
  local hotkey = newHotkeySpec(spec, message, pressedfn, releasedfn, repeatedfn, ...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.WIN_OP
  hotkey.subkind = HK.WIN_OP_.SPACE_SCREEN
  hotkey.condition = focusedWindowExist
  return hotkey
end

-- Bind a window-operation hotkey for screen/space operations.
local function bindWindow(spec, message, pressedfn, releasedfn, repeatedfn, ...)
  pressedfn = focusedWindowExistWrapper(pressedfn)
  if releasedfn then
    releasedfn = focusedWindowExistWrapper(releasedfn)
  end
  if repeatedfn then
    repeatedfn = focusedWindowExistWrapper(repeatedfn)
  end
  local hotkey = bindHotkeySpec(spec, message, pressedfn, releasedfn, repeatedfn, ...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.WIN_OP
  hotkey.subkind = HK.WIN_OP_.SPACE_SCREEN
  hotkey.condition = focusedWindowExist
  return hotkey
end

-- Bind a window screen/space URL handler.
local moveToSpaceFuncs, adjacentSpaceFuncs = {}, {}
local moveToScreenFuncs, adjacentMonitorFuncs = {}, {}
local function bindWindowURL(mode, directionOrIndex, fn)
  if mode == "space" then
    if type(directionOrIndex) == 'number' then
      moveToSpaceFuncs[directionOrIndex] = fn
    else
      adjacentSpaceFuncs[directionOrIndex] = fn
    end
  elseif mode == "screen" then
    if type(directionOrIndex) == 'number' then
      moveToScreenFuncs[directionOrIndex] = fn
    else
      adjacentMonitorFuncs[directionOrIndex] = fn
    end
  end
end

-- Handle window screen/space operations triggered via URL.
hs.urlevent.bind("windowspace", function(eventName, params)
  local fn
  if params["mode"] == "space" then
    if params["index"] then
      fn = moveToSpaceFuncs[tonumber(params["index"])]
    else
      fn = adjacentSpaceFuncs[params["direction"]]
    end
  elseif params["mode"] == "screen" then
    if params["index"] then
      fn = moveToScreenFuncs[tonumber(params["index"])]
    else
      fn = adjacentMonitorFuncs[params["direction"]]
    end
  end
  if fn then fn() end
end)

local ssHK = KeybindingConfigs.hotkeys.global or {}

-- # monitor ops

-- Check whether a window belongs to the given screen.
local function isInScreen(screen, win)
  return win:screen() == screen
end

-- Focus the given screen and move cursor to it.
local function focusScreen(screen)
  -- Get windows within screen, ordered from front to back.
  -- If no windows exist, bring focus to desktop. Otherwise, set focus on
  -- front-most application window.
  local windows = tfilter(hs.window.orderedWindows(), bind(isInScreen, screen))
  local windowToFocus = #windows > 0 and windows[1] or hs.window.desktop()
  windowToFocus:focus()

  -- move cursor to center of screen
  local pt = hs.geometry.rectMidPoint(screen:fullFrame())
  hs.mouse.absolutePosition(pt)
  if (#windows == 0) then
    hs.eventtap.leftClick(pt)
  end

  local screenName = screen:name()
  hs.alert.show("Focus on \"" .. screenName .. "\"")
end

-- Focus the adjacent screen and move cursor accordingly.
local function checkAndMoveCursurToMonitor(monitor)
  if #hs.screen.allScreens() > 1 then
    local monitorToFocus = monitor == "r" and hs.screen.mainScreen():next() or hs.screen.mainScreen():previous()
    focusScreen(monitorToFocus)
  else
    hs.alert.show("Only ONE Monitor")
  end
end

-- move window (along with cursor) to other monitor

-- Move the mouse cursor to the center of the given screen.
local function centerMouse(scrn)
    local rect = scrn:fullFrame()
    local center = hs.geometry.rectMidPoint(rect)
    hs.mouse.absolutePosition(center)
end

-- Move a window to the given screen and keep cursor centered.
local consistencyDelay = 0.9 -- seconds
local function moveToScreen(win, screen)
  if win:isFullScreen() then
    win:setFullScreen(false)
    -- a sleep is required to let the window manager register the new state
    hs.timer.doAfter(consistencyDelay, function()
        win:moveToScreen(screen, false, true)
    end)
    hs.timer.doAfter(consistencyDelay, function()
        win:setFullScreen(true)
    end)
  else
    win:moveToScreen(screen, true, true, 0.0)
  end

  centerMouse(screen)

  local screenName = screen:name()
  hs.alert.show("Move \"" .. win:title() .. "\" to \"" .. screenName .. "\"")
end

-- Move the focused window to the adjacent screen.
local function checkAndMoveWindowToMonitor(monitor)
  local win = hs.window.focusedWindow()
  if win == nil then return end
  if #hs.screen.allScreens() > 1 then
    local monitorToMoveTo = monitor == "r" and win:screen():next() or win:screen():previous()
    moveToScreen(win, monitorToMoveTo)
  else
    hs.alert.show("Only ONE Monitor")
  end
end

-- Register hotkeys for focusing adjacent monitors.
local adjacentMonitorHotkeys = {}

-- Register hotkeys for focusing the next screen.
if ssHK["focusNextScreen"] then
  local hotkey = newHotkeySpec(ssHK["focusNextScreen"], "Focus on Next Screen",
      bind(checkAndMoveCursurToMonitor, "r"))
  hotkey.subkind = HK.WIN_OP_.SPACE_SCREEN
  tinsert(adjacentMonitorHotkeys, hotkey)
end
-- Register hotkeys for focusing the previous screen.
if ssHK["focusPrevScreen"] then
  local hotkey = newHotkeySpec(ssHK["focusPrevScreen"], "Focus on Previous Screen",
      bind(checkAndMoveCursurToMonitor, "l"))
  hotkey.subkind = HK.WIN_OP_.SPACE_SCREEN
  tinsert(adjacentMonitorHotkeys, hotkey)
end

-- Register hotkeys for moving window to the next screen.
if ssHK["moveToNextScreen"] then
  tinsert(adjacentMonitorHotkeys, newWindow(ssHK["moveToNextScreen"], "Move to Next Monitor",
      bind(checkAndMoveWindowToMonitor, "r")))
end
-- Register hotkeys for moving window to the previous screen.
if ssHK["moveToPrevScreen"] then
  tinsert(adjacentMonitorHotkeys, newWindow(ssHK["moveToPrevScreen"], "Move to Previous Monitor",
      bind(checkAndMoveWindowToMonitor, "l")))
end

--  Register hotkeys for focusing or moving windows to indexed screens.
local focusMonitorHotkeys = {}
local moveToScreenHotkeys = {}
local function registerMonitorHotkeys()
  if #moveToScreenHotkeys > 0 or #focusMonitorHotkeys > 0 then
    for _, hotkey in ipairs(focusMonitorHotkeys) do
      hotkey:delete()
    end
    for _, hotkey in ipairs(moveToScreenHotkeys) do
      hotkey:delete()
    end
  end
  focusMonitorHotkeys = {}
  moveToScreenHotkeys = {}

  local nscreens = #hs.screen.allScreens()
  if nscreens <= 1 then
    for _, hotkey in ipairs(adjacentMonitorHotkeys) do
      hotkey:disable()
    end
    return
  end

  for _, hotkey in ipairs(adjacentMonitorHotkeys) do
    hotkey:enable()
  end

  -- move window to screen by idx
  for i=1,nscreens do
    local hotkey
    hotkey = bindWindow(ssHK["moveToScreen" .. i], "Move to Monitor " .. i,
        function()
          local win = hs.window.focusedWindow()
          if win == nil then return end
          if win:screen():id() ~= hs.screen.allScreens()[i]:id() then
            moveToScreen(win, hs.screen.allScreens()[i])
          end
        end)
    tinsert(moveToScreenHotkeys, hotkey)
    hotkey = bindHotkeySpec(ssHK["focusScreen" .. i], "Focus on Monitor " .. i,
        function()
          local win = hs.window.focusedWindow()
          if win == nil then return end
          if win:screen():id() ~= hs.screen.allScreens()[i]:id() then
            focusScreen(hs.screen.allScreens()[i])
          end
        end)
    if hotkey then
      hotkey.subkind = HK.WIN_OP_.SPACE_SCREEN
      tinsert(focusMonitorHotkeys, hotkey)
    end
  end
end
registerMonitorHotkeys()


-- # space ops

-- Collect all user spaces across all screens.
local function getUserSpaces()
  local user_spaces = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    local spaces = hs.spaces.spacesForScreen(screen) or {}
    for _, space in ipairs(spaces) do
      if hs.spaces.spaceType(space) == "user" then
        tinsert(user_spaces, space)
      end
    end
  end
  return user_spaces
end

if OS_VERSION >= OS.Sequoia then
  Drag = hs.loadSpoon("Drag")
end

-- Move the focused window to the adjacent user space.
local function checkAndMoveWindowToSpace(space)
  local user_spaces = getUserSpaces()
  local nspaces = #user_spaces
  if nspaces > 1 then
    local curSpaceID = hs.spaces.focusedSpace()
    local index = tindex(user_spaces, curSpaceID)
    local targetIdx = space == "r" and index + 1 or index - 1
    if 1 <= targetIdx and targetIdx <= nspaces then
      local win = hs.window.focusedWindow()
      if win == nil then return end
      if Drag then
        Drag:focusedWindowToSpace(user_spaces[targetIdx])
        return
      end
      hs.spaces.moveWindowToSpace(win, user_spaces[targetIdx])
      hs.spaces.gotoSpace(user_spaces[targetIdx])
      local screenUUID = hs.spaces.spaceDisplay(user_spaces[targetIdx])
      if win:screen():getUUID() ~= screenUUID then
        focusScreen(hs.screen.find(screenUUID))
      end
      win:focus()
    end
  else
    hs.alert.show("Only ONE User Space")
  end
end

-- Register hotkeys for moving window to adjacent spaces.
local adjacentSpaceHotkeys = {}

-- Register hotkeys for moving window to the next space.
tinsert(adjacentSpaceHotkeys, newWindow(ssHK["moveToNextSpace"], "Move to Next Space",
    bind(checkAndMoveWindowToSpace, "r")))

-- Register hotkeys for moving window to the previous space.
tinsert(adjacentSpaceHotkeys, newWindow(ssHK["moveToPrevSpace"], "Move to Previous Space",
    bind(checkAndMoveWindowToSpace, "l")))

-- Register hotkeys for moving windows to indexed spaces.
local moveToSpaceHotkeys = {}
local function registerMoveToSpaceHotkeys()
    if #moveToSpaceHotkeys > 0 then
    for _, hotkey in ipairs(moveToSpaceHotkeys) do
      hotkey:delete()
    end
  end
  moveToSpaceHotkeys = {}

  local user_spaces = getUserSpaces()
  local nspaces = #user_spaces
  if nspaces <= 1 then
    for _, hotkey in ipairs(adjacentSpaceHotkeys) do
      hotkey:disable()
    end
    return
  end

  for _, hotkey in ipairs(adjacentSpaceHotkeys) do
    hotkey:enable()
  end

  -- move window to space by idx
  for i=1,nspaces do
    local hotkey = bindWindow(ssHK["moveToSpace" .. i], "Move to Space " .. i,
      function()
        local win = hs.window.focusedWindow()
        if win == nil then return end
        local user_spaces = getUserSpaces()
        if Drag then
          Drag:focusedWindowToSpace(user_spaces[i])
          return
        end
        local curSpaceID = hs.spaces.focusedSpace()
        if curSpaceID == user_spaces[i] then return end
        hs.spaces.moveWindowToSpace(win, user_spaces[i])
        hs.spaces.gotoSpace(user_spaces[i])
        local screenUUID = hs.spaces.spaceDisplay(user_spaces[i])
        if win:screen():getUUID() ~= screenUUID then
          focusScreen(hs.screen.find(screenUUID))
        end
        win:focus()
      end)
    if hotkey then
      tinsert(moveToSpaceHotkeys, hotkey)
    end
  end
end
registerMoveToSpaceHotkeys()


-- Refresh screen-related hotkeys on screen configuration changes.
function Screen_monitorChangedCallback()
  registerMonitorHotkeys()
  registerMoveToSpaceHotkeys()
end

-- Monitor user space count changes and refresh space hotkeys.
local workspacePlistPath = hs.fs.pathToAbsolute(os.getenv("HOME")
    ..strfmt("/Library/Preferences/com.apple.spaces.plist"))
WorkspacePlistWatcher = hs.pathwatcher.new(
  workspacePlistPath,
  function()
    local user_spaces = getUserSpaces()
    local nspaces = #user_spaces
    if nspaces ~= #moveToSpaceHotkeys then
      registerMoveToSpaceHotkeys()
    end
  end
):start()
