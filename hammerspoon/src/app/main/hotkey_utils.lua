---@diagnostic disable: lowercase-global

function getKeybinding(appid, hkID, defaultCommon)
  -- prefer properties specified in configuration file than in code
  local userCfgs = KeybindingConfigs.hotkeys[appid] or {}
  local config = AppHotKeyCallbacks[appid][hkID]
  local keybinding = userCfgs[hkID] or { mods = config.mods, key = config.key }
  local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
  if hasKey == false and defaultCommon then
    local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
        or CommonKeybindings[hkID]
    if kbShared ~= nil then
      keybinding.mods = kbShared.mods
      keybinding.key = kbShared.key
    end
  end
  return keybinding
end

local function bindable(obj, cond)
  if cond == nil then return true end
  if type(cond) == 'boolean' then return cond end
  return cond(obj)
end

local runningAppHotKeys = {}
-- hotkeys for background apps
function registerRunningAppHotKeys(appid, app)
  if AppHotKeyCallbacks[appid] == nil then return end

  if runningAppHotKeys[appid] == nil then
    runningAppHotKeys[appid] = {}
  end

  local hasNotPersistentBackgroundHotkey = false
  local running = true
  -- do not support "condition" property currently
  for hkID, cfg in pairs(AppHotKeyCallbacks[appid]) do
    local keybinding = getKeybinding(appid, hkID)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isPersistent = keybinding.persist ~= nil
        and keybinding.persist or cfg.persist
    local isBackground = isPersistent or (keybinding.background ~= nil
        and keybinding.background or cfg.background)
    if runningAppHotKeys[appid][hkID] ~= nil then
      runningAppHotKeys[appid][hkID]:enable()
      if not isPersistent and isBackground then
        hasNotPersistentBackgroundHotkey = true
      end
      goto L_CONTINUE
    end
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local bindableEx
    if isPersistent then
      bindableEx = function()
        return installed(appid) and bindable(appid, cfg.enabled)
      end
    else
      bindableEx = function()
        if not running then return false end
        if app == nil then
          if FLAGS["LOADING"] then
            app = LoadBuf.runningApplications[appid]
          else
            app = find(appid)
          end
        end
        running = app ~= nil
        return app and bindable(app, cfg.enabled)
      end
    end
    if hasKey and isBackground and not isForWindow and bindableEx() then
      local fn
      if isPersistent then
        fn = function()
          if find(appid) then
            cfg.fn(find(appid))
          else
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, A_HotkeyWrapper(function()
              local newApp = find(appid)
              if newApp then
                if cfg.onLaunch then
                  A_CommonCallback = cfg.fn
                  cfg.onLaunch(newApp)
                  A_CommonCallback = nil
                else
                  cfg.fn(newApp)
                end
              end
            end))
          end
        end
      else
        fn = bind(cfg.fn, app)
      end
      local repeatable = keybinding.repeatable ~= nil
          and keybinding.repeatable or cfg.repeatable
      local repeatedFn = repeatable and fn or nil
      local msg
      if type(cfg.message) == 'string' then
        msg = cfg.message
      elseif not isPersistent then
        msg = cfg.message(app)
      else
        msg = cfg.message(appid)
      end
      if msg ~= nil then
        local hotkey = bindHotkeySpec(keybinding, msg, fn, nil, repeatedFn)
        if isPersistent then
          hotkey.persist = true
        end
        hotkey.kind = cfg.kind or HK.BACKGROUND
        hotkey.appid = appid
        runningAppHotKeys[appid][hkID] = hotkey
        hasNotPersistentBackgroundHotkey = hasNotPersistentBackgroundHotkey
            or (not isPersistent and isBackground)
      end
    end
    ::L_CONTINUE::
  end

  if hasNotPersistentBackgroundHotkey then
    Evt.OnTerminated(appid, bind(unregisterRunningAppHotKeys, appid))
  end
end

function unregisterRunningAppHotKeys(appid, force)
  if AppHotKeyCallbacks[appid] == nil
      or runningAppHotKeys[appid] == nil then return end

  for hkID, hotkey in pairs(runningAppHotKeys[appid]) do
    if force or not hotkey.persist then
      hotkey:delete()
      runningAppHotKeys[appid][hkID] = nil
    end
  end
  if next(runningAppHotKeys[appid]) == nil then
    runningAppHotKeys[appid] = nil
  end
end

------------------------------------------------------------
-- Context-aware hotkey registration
--
-- This section implements a unified hotkey system that supports:
--
--   - App-scoped hotkeys (active application)
--   - Window-scoped hotkeys (focused window, with filters)
--   - Background (daemon) app hotkeys
--   - Menu bar–scoped hotkeys
--
-- A hotkey may be registered:
--   - eagerly or lazily
--   - conditionally (runtime UI / menu / focus state)
--   - chained with other hotkeys sharing the same key binding
--
-- The core idea is:
--   hotkey = keybinding + condition + execution context
--
-- All hotkeys are dynamically enabled / disabled based on:
--   - app lifecycle
--   - window focus changes
--   - menu open / close state
------------------------------------------------------------

-- Check whether an application owns menu bar status items.
--
-- This is used to determine whether we should register
-- menu bar observers for hotkey validity tracking.
local function hasStatusItems(app)
  local appid = app:bundleID() or app:name()
  local errorReadingDefaults = false
  local plistPath, defaults
  local prefix = "NSStatusItem Preferred Position "
  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Containers/%s/Data/Library/Preferences/%s.plist", appid, appid))
  if plistPath ~= nil then
    defaults = hs.plist.read(plistPath)
    if defaults then
      local prefix_len = #prefix
      for k, v in pairs(defaults) do
        if k:sub(1, prefix_len) == prefix then
          return true
        end
      end
    else
      errorReadingDefaults = true
    end
  end
  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Preferences/%s.plist", appid))
  if plistPath ~= nil then
    defaults = hs.plist.read(plistPath)
    if defaults then
      local prefix_len = #prefix
      for k, v in pairs(defaults) do
        if k:sub(1, prefix_len) == prefix then
          return true
        end
      end
    else
      errorReadingDefaults = true
    end
  end
  if errorReadingDefaults then
    local records, ok = hs.execute(strfmt([[
      defaults read %s | grep '"%s'
    ]], appid, prefix))
    return ok == true
  end
  return false
end

-- Register observers to track menu bar selection state for hotkey validity.
--
-- Purpose:
--   When a right-side menu bar item is expanded, certain hotkeys
--   should be disabled or redirected to avoid interfering with menu input.
--
-- This observer:
--   - Tracks menu open / close events
--   - Sets FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"]
--
-- Note:
--   This process is expensive and is registered per-app only once.
local menuBarMenuSelectedObservers = {}
function registerMenuBarObserverForHotkeyValidity(app)
  local appid = app:bundleID() or app:name()
  if menuBarMenuSelectedObservers[appid] then
    menuBarMenuSelectedObservers[appid]:stop()
    menuBarMenuSelectedObservers[appid] = nil
  end
  if hs.window.filter.ignoreAlways[appid]
      or hs.window.filter.ignoreAlways[app:name()]
      or app:kind() < 0 then
    return
  end
  if hasStatusItems(app) then
    local appUI = toappui(app)
    local menuBarItems = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem) or {}
    if #menuBarItems > 0 then
      local observer = uiobserver.new(app:pid())
      observer:addWatcher(appUI, uinotifications.menuOpened)
      observer:addWatcher(appUI, uinotifications.menuClosed)
      observer:callback(function(_, menu, notification)
        if notification == uinotifications.menuClosed then
          -- When a menu is closed, assume no menu bar item is selected
          FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = false
        else
          -- Determine whether the opened menu belongs to the right side
          -- of the menu bar (i.e. status items instead of app menus)
          local elem = menu.AXParent
          while elem and elem.AXRole ~= AX.MenuBar do
            elem = elem.AXParent
          end
          if elem and elem.AXPosition.x ~= hs.screen.mainScreen():fullFrame().x then
            FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = true
          end
        end
      end)
      observer:start()
      menuBarMenuSelectedObservers[appid] = observer
      Evt.StopOnTerminated(app, observer, function()
        menuBarMenuSelectedObservers[appid] = nil
      end)

      if FLAGS["LOADING"] then
        tinsert(LoadBuf.menubarSelectedObserverStarted, appid)
      end
      return menuBarItems
    end
  end
end
-- Performance hack:
-- Expose menuBarMenuSelectedObservers for registering right menu bar observers
-- for settings menu item
_G.MenuBarMenuSelectedObservers = menuBarMenuSelectedObservers

local windowCreatedSinceFilter = hs.window.filter.new(true)
local windowCreatedSinceTime = {}

-- Redirect hotkey execution to the system-focused UI element if needed.
--
-- This wrapper handles cases where:
--   - the hotkey target is not the frontmost app/window
--   - a menu bar item is currently expanded
--
-- It ensures that:
--   - hotkeys do not interfere with menu interaction
--   - fallback keystrokes are sent to the correct UI context
local function resendToFocusedUIElement(cond, nonFrontmostWindow)
  return function(obj)
    local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
    -- Lazily initialize RIGHT_MENUBAR_ITEM_SELECTED if unknown
    if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] == nil and focusedApp == nil then
      local apps = hs.application.runningApplications()
      local appMenuBarItems = tmap(apps, function(app)
        return registerMenuBarObserverForHotkeyValidity(app)
      end)
      hs.timer.doAfter(2, function()
        for appid, _ in pairs(menuBarMenuSelectedObservers) do
          local app = find(appid)
          registerObserverForRightMenuBarSettingsMenuItem(app)
        end
      end)
      FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = any(appMenuBarItems, function(items)
        return any(items, function(item) return item.AXSelected end)
      end)
    end
    if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] and focusedApp == nil then
      return false, CF.rightMenubarItemSelected
    end

    if nonFrontmostWindow then
      local frontWin = hs.window.frontmostWindow()
      if frontWin ~= nil then
        if frontWin:role() == AX.Sheet or frontWin:role() == AX.Popover then
          return false, CF.uIElementNotFocused
        end
        for wino, _ in pairs(windowCreatedSinceFilter.windows) do
          if wino.id == frontWin:id() then
            if wino.timeCreated > windowCreatedSinceTime[obj:id()] then
              return false, CF.uIElementNotFocused
            end
            break
          end
        end
      end
    elseif focusedApp then  -- supposed to be non-null
      local app = obj.application ~= nil and obj:application() or obj
      if focusedApp:asHSApplication() ~= app then
        if not (app:bundleID() == "com.apple.Safari" and
            focusedApp:asHSApplication():bundleID()
                == "com.apple.Safari.SandboxBroker") then
          return false, CF.uIElementNotFocused
        end
      end
    end
    return cond(obj)
  end
end

-- Disable hotkeys when a left-side menu bar menu is expanded.
--
-- This prevents hotkeys without modifiers from interfering
-- with normal menu navigation.
local function noSelectedLeftMenuBarItemFunc(fn)
  return function(obj)
    local app = obj.application ~= nil and obj:application() or obj
    for i, menuBarItem in ipairs(getMenuBarItems(app, false, false) or {}) do
      if i > 1 and menuBarItem.AXSelected then
        return false, CF.leftMenubarItemSelected
      end
    end
    return fn(obj)
  end
end

-- Disable hotkeys when a non-empty text field is focused.
--
-- This avoids breaking text input by unmodified hotkeys.
local function noFocusedNonEmptyTextFieldFunc(fn)
  return function(obj)
    local focused = hs.axuielement.systemWideElement().AXFocusedUIElement
    if focused and focused.AXRole == AX.TextField and focused.AXValue ~= nil then
      return false, CF.nonEmptyTextFieldFocused
    end
    return fn(obj)
  end
end

local KEY_MODE = {
  PRESS = 1,
  REPEAT = 2,
}

ActivatedAppConditionChain = {}
local daemonAppConditionChain = {}

-- Append a conditional hotkey into a per-app condition chain.
--
-- Multiple hotkeys may share the same key binding.
-- They are stored as a linked list and evaluated in order:
--   newest → oldest
--
-- The first satisfied condition wins.
local function appendConditionChain(app, config, pressedfn, repeatedfn, cond)
  local appid = app:bundleID() or app:name()
  local mods, key = config.mods, config.key
  local message = config.message
  local chain = config.background and daemonAppConditionChain
      or ActivatedAppConditionChain

  if chain[appid] == nil then
    chain[appid] = {}
  end
  local hkIdx = hotkeyIdx(mods, key)
  local prevHotkeyInfo = chain[appid][hkIdx]
  chain[appid][hkIdx] = {
    pressedfn = pressedfn,
    repeatedfn = repeatedfn,
    condition = cond,
    message = message,
    enabled = true,
    previous = prevHotkeyInfo,
    _chainRef = chain[appid],
  }
  if prevHotkeyInfo then
    prevHotkeyInfo.next = chain[appid][hkIdx]
  end
  return chain[appid][hkIdx]
end

local function enableConditionInChain(hotkey)
  if hotkey._chainedCond == nil then return end
  hotkey._chainedCond.enabled = true
end

local function disableConditionInChain(hotkey, delete)
  if hotkey._chainedCond == nil then return end
  hotkey._chainedCond.enabled = false
  if delete or hotkey.deleteOnDisable then
    if hotkey._chainedCond.previous then
      hotkey._chainedCond.previous.next = hotkey._chainedCond.next
    end
    if hotkey._chainedCond.next then
      hotkey._chainedCond.next.previous = hotkey._chainedCond.previous
    else
      local chainRef = hotkey._chainedCond._chainRef
      assert(chainRef)
      chainRef[hotkey.idx] = hotkey._chainedCond.previous
    end
  end
end

local function CtxEnable(hotkey)
  hotkey:enable()
  enableConditionInChain(hotkey)
end

local function CtxDisable(hotkey)
  hotkey:disable()
  disableConditionInChain(hotkey)
  if hotkey.deleteOnDisable then
    hotkey:delete()
  end
end

local function CtxDelete(hotkey)
  disableConditionInChain(hotkey, true)
  hotkey:delete()
end

-- Execute a chain of conditional hotkeys sharing the same key binding.
--
-- Evaluation order:
--   1. Try the current hotkey
--   2. Walk backward through the condition chain
--   3. If no condition matches, fall back to:
--        - menu item selection (if available)
--        - raw keystroke delivery
local function wrapConditionChain(app, fn, mode, config)
  return function()
    local succ, result = fn()
    if succ then return end
    local menuItemNotFound = result == CF.noMenuItemMatchKeybinding
    local hkIdx = hotkeyIdx(config.mods, config.key)
    local chain = config.background and daemonAppConditionChain
        or ActivatedAppConditionChain
    local cb = chain[app:bundleID() or app:name()][hkIdx]
    while cb do
      if cb.enabled then
        local f = mode == KEY_MODE.PRESS and cb.pressedfn or cb.repeatedfn
        A_Message = cb.message
        succ, result = f()
        if succ then return end
        menuItemNotFound = menuItemNotFound
            or result == CF.noMenuItemMatchKeybinding
      end
      cb = cb.previous
    end
    local mods, key = config.mods, config.key
    if not menuItemNotFound then
      -- most of the time, directly selecting menu item costs less time than key strokes
      local menuItemPath, enabled = findMenuItemByKeyBinding(app, mods, key)
      if menuItemPath ~= nil and enabled then
        app:selectMenuItem(menuItemPath)
        return
      end
    end
    hs.eventtap.keyStroke(mods, key, nil, app)
  end
end

-- Wrap a hotkey callback with condition evaluation and fallback logic.
--
-- This function:
--   - Evaluates the user-defined condition
--   - Handles focus / menu / text-field edge cases
--   - Decides whether to:
--       * execute the callback
--       * resend keystrokes
--       * abort execution
--
-- It returns:
--   wrappedFn, wrappedCondition
local daemonAppFocusedWindowHotkeys
local function wrapCondition(obj, config, mode)
  local mods, key = config.mods, config.key
  local callback = mode == KEY_MODE.REPEAT and config.repeatedfn or config.fn
  local cond = function(o)
    local condition = config.condition
    if condition == nil then return true end
    if o.application then
      condition = injectWindowState(condition)
    end
    local satisfied, result = condition(o)
    if not satisfied then result = CF.userConditionFail end
    return satisfied, result
  end

  local app
  if obj.focusedWindow then  -- AppBind
    app = obj
  elseif obj.application then  -- WinBind or AppWinBind
    app = obj:application()
    if not config.background then obj = nil end
  end

  if obj == nil or obj.asHSApplication == nil then
    -- if a menu is extended, hotkeys with no modifiers or only 'shift' are disabled
    -- currently allow hotkeys with 'option' or 'shift'+'option' as modifiers
    if mods == nil or #mods == 0
        or (type(mods) == 'string' and mods:lower() == Mod.Shift.Long)
        or (type(mods) == 'table' and #mods == 1 and mods[1]:lower() == Mod.Shift.Long) then
      cond = noFocusedNonEmptyTextFieldFunc(noSelectedLeftMenuBarItemFunc(cond))
    end
    -- send key strokes to system focused UI element instead of this obj
    cond = resendToFocusedUIElement(cond, config.nonFrontmost)
  end
  local oldCond = cond
  cond = function(o)
    o = o or obj or app:focusedWindow()
    if config.background and obj.application then
      local isWindowAlive = CondBuf:get("isAlive", function()
        local wid = o:id()
        if hs.window.get(wid) == nil then
          for _, hotkey in pairs(daemonAppFocusedWindowHotkeys[wid] or {}) do
            if hotkey.idx ~= nil then
              CtxDelete(hotkey)
            end
          end
          daemonAppFocusedWindowHotkeys[wid] = nil
          return false
        end
        return true
      end)
      if not isWindowAlive then return false end
    end
    return oldCond(o)
  end
  -- Final execution wrapper that unifies:
  --   condition checking, fallback routing, and callback invocation
  local fn = function()
    local o = obj or app:focusedWindow()
    local satisfied, result, url = cond(o)
    if satisfied then
      local func = callback
      if result ~= nil then  -- condition function can pass result to callback function
        func = bind(func, result)
        if url ~= nil then
          func = bind(func, url)
        end
      end
      if o.application then
        func = injectWindowState(func)
      end
      func(o)
      return true
    elseif result == CF.rightMenubarItemSelected then
      safeGlobalKeyStroke(mods, key)
      return true
    elseif result == CF.leftMenubarItemSelected
        or result == CF.nonEmptyTextFieldFocused then
      hs.eventtap.keyStroke(mods, key, nil, app)
      return true
    elseif result == CF.uIElementNotFocused then
      local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
      hs.eventtap.keyStroke(mods, key, nil, focusedApp:asHSApplication())
      return true
    end
    return false, result
  end
  return fn, cond
end

-- in current version of Hammerspoon, if a callback lasts kind of too long,
-- keeping pressing a hotkey may lead to unexpected repeated triggering of callback function
-- a workaround is to check if callback function is executing, if so, do nothing
-- note that this workaround may not work when the callback lasts really too long
FLAGS["CALLBACK_IS_EXECUTING"] = false
local function callBackExecutingWrapper(fn, hasWinBuf)
  return function()
    if FLAGS["CALLBACK_IS_EXECUTING"] then return end
    local wrapper = hasWinBuf and A_WinHotkeyWrapper or A_HotkeyWrapper
    hs.timer.doAfter(0, wrapper(function()
      FLAGS["CALLBACK_IS_EXECUTING"] = true
      fn()
      FLAGS["CALLBACK_IS_EXECUTING"] = false
    end))
  end
end

-- Bind a hotkey with full contextual awareness.
--
-- This is the central assembly point that combines:
--   - key binding
--   - condition logic
--   - execution context (app / window / menu)
--   - repeat handling
--   - condition chaining
--
-- All higher-level bind helpers (AppBind / WinBind / MenuBarBind)
-- eventually delegate here.
local function bindContextual(obj, config, ...)
  if config.spec ~= nil then
    config.mods = config.spec.mods
    config.key = config.spec.key
    config.spec = nil
  end
  local pressedfn, cond = wrapCondition(obj, config, KEY_MODE.PRESS)
  local tbl = { message = config.message }
  cond = injectHotkeyState(cond, tbl)
  if config.repeatedfn == nil and config.condition ~= nil then
    -- if hotkey condition is not satisfied, holding event should be passed to the app
    -- so callback for holding event must always be registered
    config.repeatedfn = function() end
  end
  local repeatedfn = config.repeatedfn
  if repeatedfn ~= nil then
    repeatedfn = wrapCondition(obj, config, KEY_MODE.REPEAT)
  end

  if config.condition ~= nil then
    -- multiple conditioned hotkeys may share a common keybinding
    -- they are cached in a linked list.
    -- each condition will be tested until one is satisfied
    local app
    if obj.application ~= nil then
      app = obj:application()
    elseif obj.asHSApplication ~= nil then
      app = getAppFromDescendantElement(obj)
    else
      app = obj
    end
    cond = appendConditionChain(app, config, pressedfn, repeatedfn, cond)
    pressedfn = wrapConditionChain(app, pressedfn, KEY_MODE.PRESS, config)
    if repeatedfn ~= nil then
      repeatedfn = wrapConditionChain(app, repeatedfn, KEY_MODE.REPEAT, config)
    end
  end

  if config.condition ~= nil then  -- executing condition may take too much time
    pressedfn = callBackExecutingWrapper(pressedfn, obj.application ~= nil)
    if repeatedfn ~= nil then
      repeatedfn = callBackExecutingWrapper(repeatedfn, obj.application ~= nil)
    end
  end
  local hotkey = bindHotkeySpec(config, config.message,
                                pressedfn, nil, repeatedfn, ...)
  hotkey.deleteOnDisable = config.deleteOnDisable
  tbl.hotkey = hotkey
  if type(cond) == 'table' then
    hotkey._chainedCond = cond
  else
    hotkey.condition = cond
  end
  return hotkey
end

-- Bind a hotkey scoped to the active application.
function AppBind(app, config, ...)
  local hotkey = bindContextual(app, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.APP
  return hotkey
end

-- Register hotkeys for an active application.
--
-- Hotkeys are:
--   - enabled on activation
--   - disabled or deleted on deactivation / termination
local inAppHotKeys = {}

function registerInAppHotKeys(app)
  local appid = app:bundleID() or app:name()

  if not inAppHotKeys[appid] then
    inAppHotKeys[appid] = {}
  end
  for hkID, cfg in pairs(AppHotKeyCallbacks[appid] or {}) do
    if type(hkID) == 'number' then break end
    if inAppHotKeys[appid][hkID] ~= nil then
      local hotkey = inAppHotKeys[appid][hkID]
      CtxEnable(hotkey)
    else
      local keybinding = getKeybinding(appid, hkID, true)
      local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
      local isBackground = keybinding.background ~= nil
          and keybinding.background or cfg.background
      local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
      local isMenuBarMenu = keybinding.menubarFilter ~= nil
          or cfg.menubarFilter ~= nil
      if hasKey and not isBackground and not isForWindow
          and not isMenuBarMenu and bindable(app, cfg.enabled) then
        local msg = type(cfg.message) == 'string'
            and cfg.message or cfg.message(app)
        if msg ~= nil then
          local config = tcopy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          if keybinding.repeatable ~= nil then
            config.repeatable = keybinding.repeatable
          end
          config.repeatedfn = config.repeatable and config.fn or nil
          inAppHotKeys[appid][hkID] = AppBind(app, config)
        end
      end
    end
  end

  Evt.OnDeactivated(app, function()
    unregisterInAppHotKeys(appid)
  end)
  Evt.OnTerminated(app, function()
    unregisterInAppHotKeys(appid, true)
    ActivatedAppConditionChain[appid] = nil
  end)
end

function unregisterInAppHotKeys(appid, delete)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  if inAppHotKeys[appid] == nil then return end

  if delete then
    for hkID, hotkey in pairs(inAppHotKeys[appid]) do
      CtxDelete(hotkey)
      inAppHotKeys[appid][hkID] = nil
    end
  else
    for hkID, hotkey in pairs(inAppHotKeys[appid]) do
      if hotkey.deleteOnDisable then
        inAppHotKeys[appid][hkID] = nil
      end
      CtxDisable(hotkey)
    end
  end
  if next(inAppHotKeys[appid]) == nil then
    inAppHotKeys[appid] = nil
  end
end

-- Bind a hotkey scoped to a specific window of the active application.
function AppWinBind(win, config, ...)
  local hotkey = bindContextual(win, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.WINDOW
  return hotkey
end

-- hotkeys for focused window of active app

-- check if a window filter is the same as another
-- if a value is a list, the order of elements matters
local function sameFilter(a, b)
  if type(a) ~= "table" then return a == b end
  if a == b then return true end
  for k, av in pairs(a) do
    local bv = b[k]
    if av ~= bv then
      if type(av) == 'table' then
        if type(bv) ~= 'table' then return false end
        for i=1,#av do
          if av[i].equals then
            if not av[i]:equals(bv[i]) then return false end
          else
            if av[i] ~= bv[i] then return false end
        end
      end
      elseif type(av) == 'function' or type(av) == 'boolean' then
        return false
      else
        if av.equals then
          if not av:equals(bv) then return false end
        else
          if av ~= bv then return false end
        end
      end
    end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Register hotkeys for a focused window matching a filter.
--
-- Window-scoped hotkeys are dynamically managed based on:
--   - window focus
--   - window title / role / URL
local inWinHotKeys = {}

local function getTabUrl(app)
  local ok, url
  if app:bundleID() == "com.apple.Safari" then
    ok, url = hs.osascript.applescript([[
      tell application id "com.apple.Safari" to get URL of front document
    ]])
  else  -- assume chromium-based browsers
    ok, url = hs.osascript.applescript(strfmt([[
      tell application id "%s" to get URL of active tab of front window
    ]], app:bundleID()))
  end
  if ok and url then
    if url:sub(-2) == '//' then url = url:sub(1, -2) end
    return url
  end
end

function registerInWinHotKeys(win, filter)
  local app = win and win:application()
  if app == nil then return end
  local appid = app:bundleID() or app:name()
  if AppHotKeyCallbacks[appid] == nil then return end

  if not inWinHotKeys[appid] then
    inWinHotKeys[appid] = {}
  end
  if not inWinHotKeys[appid][filter] then
    inWinHotKeys[appid][filter] = {}
  end
  local hotkeys = inWinHotKeys[appid][filter]
  local needCloseWatcher = true
  local url
  for hkID, cfg in pairs(AppHotKeyCallbacks[appid]) do
    if hotkeys[hkID] == nil then
      local keybinding = getKeybinding(appid, hkID, true)
      local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      local isForWindow = windowFilter ~= nil
      local isBackground = keybinding.background ~= nil
          and keybinding.background or cfg.background
      if hasKey and isForWindow and not isBackground
          and bindable(app, cfg.enabled)
          and sameFilter(windowFilter, filter) then
        local msg, fallback
        if type(cfg.message) == 'string' then msg = cfg.message
        else msg, fallback = injectWindowState(cfg.message)(win) end
        if msg ~= nil and hotkeys[hkID] == nil then
          -- double check for website-specific hotkeys
          local config = tcopy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          if keybinding.repeatable ~= nil then
            config.repeatable = keybinding.repeatable
          end
          config.background = false
          if type(windowFilter) == 'table' and windowFilter.allowURLs then
            url = url or getTabUrl(app)
            config.fn = bind(config.fn, url)
          end
          config.repeatedfn = config.repeatable and config.fn or nil
          if config.deleteOnDisable == nil
              and type(windowFilter) == 'table' and windowFilter.allowSheet then
            config.deleteOnDisable = true
          end
          config.deleteOnDisable = config.deleteOnDisable or fallback
          hotkeys[hkID] = AppWinBind(win, config)
        end
      end
    else
      needCloseWatcher = false
      CtxEnable(hotkeys[hkID])
    end
  end

  if needCloseWatcher then
    Evt.OnDestroy(towinui(win),
      function() unregisterInWinHotKeys(appid, true, filter) end,
      hs.application.watcher.deactivated, true
    )
  end
end

function unregisterInWinHotKeys(appid, delete, filter)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  local hotkeys = get(inWinHotKeys, appid, filter)
  if AppHotKeyCallbacks[appid] == nil or hotkeys == nil then
    return
  end

  if delete then
    for hkID, hotkey in pairs(hotkeys) do
      CtxDelete(hotkey)
      hotkeys[hkID] = nil
    end
  else
    for hkID, hotkey in pairs(hotkeys) do
      if hotkey.deleteOnDisable then
        hotkeys[hkID] = nil
      end
      CtxDisable(hotkey)
    end
  end
  if next(hotkeys) == nil then
    inWinHotKeys[appid][filter] = nil
  end
end

local function normalizeWindowFilter(filter)
  local normal, extended = nil, {}
  if type(filter) == 'table' then
    if filter.allowSheet or filter.allowPopover then
      normal = false
    else
      normal = tcopy(filter)
      normal.allowSheet, normal.allowPopover, normal.fn, normal.allowURLs = nil, nil, nil, nil
      if next(normal) == nil then normal = nil end
    end
    extended = {
      allowSheet = filter.allowSheet,
      allowPopover = filter.allowPopover,
      condition = filter.fn,
      allowURLs = filter.allowURLs,
    }
  elseif filter == false then
    normal = false
  end

  return normal, extended
end

local function isWebsiteAllowed(win, allowURLs)
  if not win:isStandard() then
    return false
  end
  local app = win:application()
  if app:bundleID() == "com.apple.Safari" then
    if not MenuItem.isEnabled({ "View", "Show Sidebar" },
                              { "View", "Hide Sidebar" })(app) then
    return false end
  end
  local url = getTabUrl(app)
  if url ~= nil then
    if type(allowURLs) == 'string' then
      allowURLs = { allowURLs }
    end
    for _, v in ipairs(allowURLs) do
      if url:match(v) ~= nil then
        return true
      end
    end
  end
  return false
end

function isWindowAllowed(win, filter)
  if win == nil then return false end
  local normal, extended = normalizeWindowFilter(filter)
  if win:role() == AX.Sheet then
    if not extended.allowSheet then return false end
  elseif win:role() == AX.Popover then
    if not extended.allowPopover then return false end
  elseif win:application() then
    local windowFilter = hs.window.filter.new(false)
        :setAppFilter(win:application():name(), normal)
    if not windowFilter:isWindowAllowed(win) then
      return false
    end
  end
  return (extended.allowURLs == nil or isWebsiteAllowed(win, extended.allowURLs))
      and (extended.condition == nil or injectWindowState(extended.condition)(win))
end

local focusedWindowObservers = {}
local function registerSingleWinFilterForApp(app, filter, retry)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(focusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
  end

  local appUI = toappui(app)
  if not tcontain(appUI:attributeNames() or {}, "AXFocusedWindow") then
    retry = retry and retry + 1 or 1
    if not FLAGS["Loading"] and retry <= 3 then
      hs.timer.doAfter(1,
          bind(registerSingleWinFilterForApp, app, filter, retry))
    end
    return
  end

  local win = app:focusedWindow()
  if isWindowAllowed(win, filter) then
    registerInWinHotKeys(win, filter)
  end

  local normal, extended = normalizeWindowFilter(filter)
  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  observer:addWatcher(appUI, uinotifications.windowMiniaturized)
  if extended.allowPopover then
    observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  end
  if win and (extended.allowURLs or
      (normal and (normal.allowTitles or normal.rejectTitles))) then
    observer:addWatcher(towinui(win), uinotifications.titleChanged)
  end
  observer:callback(function(_, element, notification)
    win = app:focusedWindow()
    if win == nil then return end
    if notification == uinotifications.focusedUIElementChanged
        and win:role() ~= AX.Popover then
      return
    end
    if notification == uinotifications.focusedWindowChanged
        and win and (extended.allowURLs
            or (normal and (normal.allowTitles or normal.rejectTitles))) then
      observer:addWatcher(towinui(win), uinotifications.titleChanged)
    end
    if notification == uinotifications.windowMiniaturized then
      observer:removeWatcher(element, uinotifications.titleChanged)
    end
    if not element:isValid() then return end

    -- "hs.window.filter" waits for stop of changing title,
    -- affecting the return of "hs.window.filter.isWindowAllowed"
    -- we have to workaround it
    local ignoreTitleChange = false
    if notification == uinotifications.titleChanged
        and normal and (normal.allowTitles or normal.rejectTitles) then
      local function matchTitles(titles, t)
        if type(titles) == 'string' then
          titles = { titles }
        end
        for _, title in ipairs(titles) do
          if t:match(title) then return true end
        end
      end
      local allowTitles, rejectTitles = normal.allowTitles, normal.rejectTitles
      if allowTitles then
        if type(allowTitles) == 'number' then
          if #win:title() <= allowTitles then
            unregisterInWinHotKeys(appid, false, filter)
            return
          end
        elseif not matchTitles(allowTitles, win:title()) then
          unregisterInWinHotKeys(appid, false, filter)
          return
        end
      end
      if rejectTitles and matchTitles(rejectTitles, win:title()) then
        unregisterInWinHotKeys(appid, false, filter)
        return
      end
      ignoreTitleChange = true
    end

    local f = filter
    if ignoreTitleChange then
      f = tcopy(f)
      f.allowTitles, f.rejectTitles = nil, nil
      if next(f) == nil then f = nil end
    end
    if isWindowAllowed(win, f) then
      registerInWinHotKeys(win, filter)
    else
      unregisterInWinHotKeys(appid, false, filter)
    end
  end)
  observer:start()
  if focusedWindowObservers[appid] == nil then
    focusedWindowObservers[appid] = {}
  end
  focusedWindowObservers[appid][filter] = observer
  Evt.StopOnDeactivated(app, observer, function()
    focusedWindowObservers[appid][filter] = nil
  end)
end

function registerWinFiltersForApp(app)
  local appid = app:bundleID() or app:name()
  for hkID, cfg in pairs(AppHotKeyCallbacks[appid] or {}) do
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    if hasKey and isForWindow and not isBackground
        and bindable(app, cfg.enabled) then
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      registerSingleWinFilterForApp(app, windowFilter)
    end
  end
end

-- Bind a hotkey scoped to a focused window.
local function WinBind(win, config, ...)
  local hotkey = bindContextual(win, config, ...)
  hotkey.kind = HK.IN_WIN
  return hotkey
end

-- hotkeys for focused window belonging to daemon app
-- the window is frontmost unless specified "nonFrontmost"
local daemonAppFocusedWindowObservers = {}
daemonAppFocusedWindowHotkeys = {}
function registerDaemonAppInWinHotkeys(win, appid, filter)
  local winUI = towinui(win)
  local wid = win:id()
  if daemonAppFocusedWindowHotkeys[wid] == nil then
    daemonAppFocusedWindowHotkeys[wid] = {}
  end

  local observed = false
  for hkID, cfg in pairs(AppHotKeyCallbacks[appid]) do
    local app = find(appid)
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    local windowFilter = keybinding.windowFilter or cfg.windowFilter
    local isForWindow = windowFilter ~= nil
    if hasKey and isForWindow and isBackground
        and bindable(app, cfg.enabled)
        and sameFilter(windowFilter, filter) then
      local msg = type(cfg.message) == 'string'
          and cfg.message or injectWindowState(cfg.message)(win)
      if msg ~= nil then
        local config = tcopy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        if keybinding.repeatable ~= nil then
          config.repeatable = keybinding.repeatable
        end
        config.background = true
        if keybinding.nonFrontmost ~= nil then
          config.nonFrontmost = keybinding.nonFrontmost
        end
        config.repeatedfn = config.repeatable and config.fn or nil
        local hotkey = WinBind(win, config)
        daemonAppFocusedWindowHotkeys[wid][hkID] = hotkey

        if config.nonFrontmost then
          if type(windowFilter) == 'table' and windowFilter.allowRoles then
            local allowRoles = windowFilter.allowRoles
            if type(allowRoles) == 'string' then allowRoles = { allowRoles } end
            local extraRoles = tfilter(allowRoles, function(role)
                return hs.window.filter.allowedWindowRoles[role] == nil end)
            if #extraRoles > 0 then
              windowCreatedSinceFilter:setAppFilter(app:name(), {
                allowRoles = extraRoles,
              })
            end
          end
          if windowCreatedSinceTime[wid] == nil then
            -- tell "hs.window.filter" to record time of windows to be created
            -- if no subscriptions have been made then this is necessary
            -- windowCreatedSinceFilter:subscribe(
            --     hs.window.filter.windowCreated, function() end)
            windowCreatedSinceTime[wid] = hs.timer.secondsSinceEpoch()
          end
        end

        if not observed then
          Evt.OnDestroy(winUI, function()
            if daemonAppFocusedWindowHotkeys[wid] ~= nil then
              for _, hotkey in pairs(daemonAppFocusedWindowHotkeys[wid]) do
                if hotkey.idx ~= nil then
                  CtxDelete(hotkey)
                end
              end
              daemonAppFocusedWindowHotkeys[wid] = nil
            end
            -- windowCreatedSinceFilter:unsubscribeAll()
            windowCreatedSinceTime[wid] = nil
          end,
          hs.application.watcher.terminated, true)
          observed = true
        end
      end
    end
  end
end

local function registerSingleWinFilterForDaemonApp(app, filter, retry)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(daemonAppFocusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
  end

  local appUI = toappui(app)
  if not tcontain(appUI:attributeNames() or {}, "AXFocusedWindow") then
    retry = retry and retry + 1 or 1
    if not FLAGS["Loading"] and retry <= 3 then
      hs.timer.doAfter(1,
          bind(registerSingleWinFilterForDaemonApp, app, filter, retry))
    end
    return
  end

  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.windowCreated)
  if type(filter) == 'table' and filter.allowSheet then
    observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  end
  if type(filter) == 'table' and filter.allowPopover then
    observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  end
  observer:callback(function(_, element, notification)
    if not element:isValid() then return end
    if notification == uinotifications.focusedWindowChanged
        and element.AXRole ~= AX.Sheet then
      return
    end
    if notification == uinotifications.focusedUIElementChanged then
      local elem = element
      while elem and elem.AXRole ~= AX.Popover do
        elem = elem.AXParent
      end
      if elem == nil then return end
    end

    local win = element:asHSWindow()
    if isWindowAllowed(win, filter) then
      registerDaemonAppInWinHotkeys(win, appid, filter)
    end
  end)
  observer:start()
  if daemonAppFocusedWindowObservers[appid] == nil then
    daemonAppFocusedWindowObservers[appid] = {}
  end
  daemonAppFocusedWindowObservers[appid][filter] = observer
  Evt.StopOnTerminated(app, observer, function()
    daemonAppFocusedWindowObservers[appid][filter] = nil
  end)

  if FLAGS["LOADING"] then
    if LoadBuf.daemonAppFocusedWindowFilters[appid] == nil then
      LoadBuf.daemonAppFocusedWindowFilters[appid] = {}
    end
    tinsert(LoadBuf.daemonAppFocusedWindowFilters[appid], filter)
  end
end

function registerWinFiltersForDaemonApp(app, appConfig)
  local appid = app:bundleID() or app:name()
  for hkID, cfg in pairs(appConfig) do
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    if hasKey and isForWindow and isBackground
        and bindable(app, cfg.enabled) then
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      registerSingleWinFilterForDaemonApp(app, windowFilter)
    end
  end
end

-- Bind a hotkey scoped to an open menu bar menu.
function MenuBarBind(menu, config)
  local hotkey = bindContextual(menu, config)
  hotkey.kind = HK.MENUBAR
  return hotkey
end

local menuBarMenuHotkeys = {}
function registerInMenuHotkeys(app)
  local appid = app:bundleID() or app:name()
  local appUI = toappui(app)
  local appConfig = AppHotKeyCallbacks[appid]
  if menuBarMenuHotkeys[appid] == nil then
    menuBarMenuHotkeys[appid] = {}
  end

  local observed = false
  for hkID, cfg in pairs(appConfig) do
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local menubarFilter = keybinding.menubarFilter or cfg.menubarFilter
    if hasKey and menubarFilter and bindable(app, cfg.enabled) then
      local menu
      if type(menubarFilter) == 'table' then
        if menubarFilter.allowIndices then
          local t = menubarFilter.allowIndices
          if type(t) ~= 'table' then t = { t } end
          for _, idx in ipairs(t) do
            local item = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, idx)
            if item.AXSelected then
              menu = getc(item, AX.Menu, 1) break
            end
          end
          if menu == nil then
            for _, idx in ipairs(t) do
              menu = getc(appUI, AX.MenuBar, -1, AX.Menu, idx)
              if menu then break end
            end
          end
        elseif menubarFilter.allowTitles then
          local t = menubarFilter.allowTitles
          if type(t) ~= 'table' then t = { t } end
          local map = loadStatusItemsAutosaveName(app)
          for _, title in ipairs(t) do
            local idx = tindex(map, title)
            if idx then
              local item = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, idx)
              if item.AXSelected then
                menu = getc(item, AX.Menu, 1) break
              end
            end
          end
          if menu == nil then
            for _, title in ipairs(t) do
              local idx = tindex(map, title)
              if idx then
                menu = getc(appUI, AX.MenuBar, -1, AX.Menu, idx)
                if menu then break end
              end
            end
          end
        end
      elseif menubarFilter == true then
        local mbItem = tfind(getc(appUI, AX.MenuBar, -1, AX.MenuBarItem),
            function(item) return item.AXSelected end)
        if mbItem then
          menu = getc(mbItem, AX.Menu, 1)
        end
      end
      if menu == nil then return end
      local msg = type(cfg.message) == 'string'
          and cfg.message or cfg.message(menu)
      if msg ~= nil then
        local config = tcopy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        config.background = true
        if keybinding.repeatable ~= nil then
          config.repeatable = keybinding.repeatable
        end
        config.repeatedfn = config.repeatable and config.fn or nil
        tinsert(menuBarMenuHotkeys[appid], MenuBarBind(menu, config))
        if not observed then
          Evt.OnDestroy(menu, function()
            if menuBarMenuHotkeys[appid] ~= nil then
              for i, hotkey in ipairs(menuBarMenuHotkeys[appid]) do
                if hotkey.idx ~= nil then
                  CtxDelete(hotkey)
                  menuBarMenuHotkeys[appid][i] = nil
                end
              end
              if #menuBarMenuHotkeys[appid] == 0 then
                menuBarMenuHotkeys[appid] = nil
              end
            end
          end, hs.application.watcher.terminated, true)
          observed = true
        end
      end
    end
  end
end

local menuBarMenuObservers = {}
function registerObserversForMenuBarMenu(app, appConfig)
  local appid = app:bundleID() or app:name()

  for hkID, cfg in pairs(appConfig) do
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isMenuBarMenu = keybinding.menubarFilter ~= nil
        or cfg.menubarFilter ~= nil
    if hasKey and isMenuBarMenu and bindable(app, cfg.enabled) then
      local observer = menuBarMenuObservers[appid]
      if observer == nil then
        local appUI = toappui(app)
        observer = uiobserver.new(app:pid())
        if not appUI:isValid() then return end
        observer:addWatcher(appUI, uinotifications.menuOpened)
        observer:callback(function(obs, menu)
          if menu.AXParent.AXRole == AX.MenuBar then
            registerInMenuHotkeys(app)
          end
        end)
        observer:start()
        menuBarMenuObservers[appid] = observer
        Evt.StopOnTerminated(app, observer, function()
          menuBarMenuObservers[appid] = nil
        end)
      end
      break
    end
  end

  if FLAGS["LOADING"] and menuBarMenuObservers[appid] then
    tinsert(LoadBuf.menubarObserverStarted, appid)
  end
end


-- Read-only helpers for inspecting runtime hotkey state.
--
-- This inspector is mainly used by misc.lua when rendering the global
-- hotkey list: it resolves the current condition-chain entry behind a
-- displayed hotkey so misc.lua can test whether that hotkey is actually
-- valid and show the effective message.
HotkeyInspector = {}
_G.HotkeyInspector = HotkeyInspector

function HotkeyInspector.findConditionHotkeyInfo(entry)
  if entry.kind == HK.IN_APP then
    local app = hs.application.frontmostApplication()
    if app == nil then return nil end
    local appid = app:bundleID() or app:name()
    if entry.subkind == HK.IN_APP_.MENU
        and appid == "com.valvesoftware.steam.helper" then
      appid = "com.valvesoftware.steam"
    end
    return get(ActivatedAppConditionChain, appid, entry.idx)
  elseif entry.kind == HK.IN_WIN or entry.kind == HK.MENUBAR then
    for _, appCfg in pairs(daemonAppConditionChain) do
      local hotkeyInfo = appCfg[entry.idx]
      if hotkeyInfo then
        return hotkeyInfo
      end
    end
  end
  return nil
end

-- Hotkey lifecycle helpers for custom, manually managed hotkeys.
--
-- Use this registry whenever a hotkey is managed outside the standard
-- register*/unregister* flows and still needs consistent enable / disable /
-- delete behavior (including chained-condition cleanup).
--
-- Exception:
--   Creating a new hotkey binding still goes through the bind helpers
--   such as AppBind / AppWinBind / WinBind / MenuBarBind.
HotkeyRegistry = {}
_G.HotkeyRegistry = HotkeyRegistry

function HotkeyRegistry.get(appid, hkID, usePattern)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  if not usePattern then
    return get(inAppHotKeys, appid, hkID)
  end

  local matched = {}
  for id, hotkey in pairs(inAppHotKeys[appid] or {}) do
    if id:match(hkID) then
      matched[id] = hotkey
    end
  end
  return matched
end

function HotkeyRegistry.enableHotkey(hotkey)
  CtxEnable(hotkey)
end

function HotkeyRegistry.disableHotkey(hotkey)
  CtxDisable(hotkey)
end

function HotkeyRegistry.deleteHotkey(hotkey)
  CtxDelete(hotkey)
end

function HotkeyRegistry.clearHotkey(appid, hkID)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  local hotkeys = inAppHotKeys[appid]
  if hotkeys == nil then return end
  local hotkey = hotkeys[hkID]
  if hotkey == nil then return end
  CtxDelete(hotkey)
  hotkeys[hkID] = nil
  if next(hotkeys) == nil then
    inAppHotKeys[appid] = nil
  end
end

function HotkeyRegistry.deleteWindowHotkeys(appid, predicate)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  local appWinHotkeys = inWinHotKeys[appid]
  if appWinHotkeys == nil then return end

  for filter, hotkeys in pairs(appWinHotkeys) do
    for hkID, hotkey in pairs(hotkeys) do
      if predicate == nil or predicate(filter, hkID, hotkey) then
        CtxDelete(hotkey)
        hotkeys[hkID] = nil
      end
    end
    if next(hotkeys) == nil then
      appWinHotkeys[filter] = nil
    end
  end

  if next(appWinHotkeys) == nil then
    inWinHotKeys[appid] = nil
  end
end

function HotkeyRegistry.clearWindowHotkeys(appid, clearObservers)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  HotkeyRegistry.deleteWindowHotkeys(appid)
  if clearObservers then
    foreach(focusedWindowObservers[appid] or {},
        function(observer) observer:stop() end)
    focusedWindowObservers[appid] = nil
  end
end

function HotkeyRegistry.register(appid, hkID, hotkey)
  if inAppHotKeys[appid] == nil then
    inAppHotKeys[appid] = {}
  end
  inAppHotKeys[appid][hkID] = hotkey
  return hotkey
end
