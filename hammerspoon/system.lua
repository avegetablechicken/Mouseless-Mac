require "utils"
local strfmt = string.format
local tinsert = table.insert
local tremove = table.remove
local tcontain = hs.fnutils.contains
local tfind = hs.fnutils.find
local tifilter = hs.fnutils.ifilter
local foreach = hs.fnutils.each
local bind = hs.fnutils.partial
local toappui = hs.axuielement.applicationElement
local towinui = hs.axuielement.windowElement
local uiobserver = hs.axuielement.observer
local uinotifications = hs.axuielement.observer.notifications

-- menubar for caffeine
local caffeine = hs.menubar.new()
caffeine:autosaveName("CAFFEINE")

local function setCaffeineDisplay(state)
  if state then
    caffeine:setTitle("AWAKE")
  else
    caffeine:setTitle("SLEEPY")
  end
end

local function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end

-- system proxy helpers
local curNetworkService
local function refreshNetworkService()
  local interfacev4, interfacev6 = hs.network.primaryInterfaces()
  if interfacev4 then
    local networkservice, status = hs.execute([[
        networksetup -listallhardwareports \
        | awk "/]] .. interfacev4 .. [[/ {print prev} {prev=\$0;}" \
        | awk -F: '{print $2}' | awk '{$1=$1};1']])
    curNetworkService = '"' .. networkservice:gsub("\n", "") .. '"'
  else
    curNetworkService = nil
  end
end

local function getCurNetworkService()
  return curNetworkService
end

local function proxy_info(networkservice)
  if networkservice == nil then
    networkservice = getCurNetworkService()
  end
  local autodiscovery = hs.execute("networksetup -getproxyautodiscovery " .. networkservice)
  local autoproxyurl = hs.execute("networksetup -getautoproxyurl " .. networkservice)
  local webproxy = hs.execute("networksetup -getwebproxy " .. networkservice)
  local securewebproxy = hs.execute("networksetup -getsecurewebproxy " .. networkservice)
  local socksproxy = hs.execute("networksetup -getsocksfirewallproxy " .. networkservice)
  return { autodiscovery, autoproxyurl, webproxy, securewebproxy, socksproxy }
end

local function disable_proxy(networkservice)
  if networkservice == nil then
    networkservice = getCurNetworkService()
  end
  hs.execute("networksetup -setproxyautodiscovery " .. networkservice .. ' off')
  hs.execute("networksetup -setautoproxystate " .. networkservice .. ' off')
  hs.execute("networksetup -setwebproxystate " .. networkservice .. ' off')
  hs.execute("networksetup -setsecurewebproxystate " .. networkservice .. ' off')
  hs.execute("networksetup -setsocksfirewallproxystate " .. networkservice .. ' off')
end

local function enable_proxy_PAC(client, networkservice, location)
  if networkservice == nil then
    networkservice = getCurNetworkService()
  end
  hs.execute("networksetup -setproxyautodiscovery " .. networkservice .. ' off')
  hs.execute("networksetup -setwebproxystate " .. networkservice .. ' off')
  hs.execute("networksetup -setsecurewebproxystate " .. networkservice .. ' off')
  hs.execute("networksetup -setsocksfirewallproxystate " .. networkservice .. ' off')

  if client ~= nil then
    local PACFile
    if location == nil then
      PACFile = ProxyConfigs[client].PAC
    else
      PACFile = ProxyConfigs[client][location].PAC
    end
    hs.execute("networksetup -setautoproxyurl " .. networkservice .. ' ' .. PACFile)
  end
  hs.execute("networksetup -setautoproxystate " .. networkservice .. ' on')
end

local function enable_proxy_global(client, networkservice, location)
  if networkservice == nil then
    networkservice = getCurNetworkService()
  end
  hs.execute("networksetup -setproxyautodiscovery " .. networkservice .. ' off')
  hs.execute("networksetup -setautoproxystate " .. networkservice .. ' off')

  if client ~= nil then
    local addrs
    if location == nil then
      addrs = ProxyConfigs[client].global
    else
      addrs = ProxyConfigs[client][location].global
    end
    hs.execute("networksetup -setwebproxy " .. networkservice .. ' ' .. addrs[1] .. ' ' .. addrs[2])
    hs.execute("networksetup -setsecurewebproxy " .. networkservice .. ' ' .. addrs[3] .. ' ' .. addrs[4])
    hs.execute("networksetup -setsocksfirewallproxy " .. networkservice .. ' ' .. addrs[5] .. ' ' .. addrs[6])
  end

  hs.execute("networksetup -setwebproxystate " .. networkservice .. ' on')
  hs.execute("networksetup -setsecurewebproxystate " .. networkservice .. ' on')
  hs.execute("networksetup -setsocksfirewallproxystate " .. networkservice .. ' on')
end

local proxyAppBundleIDs = {
  V2RayX = "cenmrev.V2RayX",
  V2rayU = "net.yanue.V2rayU",
  MonoCloud = "com.MonoCloud.MonoProxyMac",
}

-- toggle connect/disconnect VPN using `V2RayX`
local function toggleV2RayX(enable, alert)
  local appid = proxyAppBundleIDs.V2RayX
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
  if menu == nil then
    if alert then
      hs.alert("Error occurred while loading/unloading V2ray core in \"V2RayX\"")
    end
    return false
  end

  local set
  if enable == true then
    local load = getc(menu, AX.MenuItem, "Load core")
    if load ~= nil then
      load:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload ~= nil then
      unload:performAction(AX.Press)
      set = false
    end
  else
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload ~= nil then
      unload:performAction(AX.Press)
      set = false
    else
      local load = getc(menu, AX.MenuItem, "Load core")
      load:performAction(AX.Press)
      set = true
    end
  end

  if enable == true or set then
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload == nil then
      if alert then
        hs.alert("Error occurred while loading V2ray core in \"V2RayX\"")
      end
      return false
    end
  end

  if alert then
    if set == 0 then
      hs.alert("V2Ray core loaded in \"V2RayX\"")
    else
      hs.alert("V2Ray core unloaded in \"V2RayX\"")
    end
  end

  return true
end

-- toggle connect/disconnect VPN using `V2rayU`
local function toggleV2RayU(enable, alert)
  local appid = proxyAppBundleIDs.V2rayU
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
  if menu == nil then
    if alert then
      hs.alert("Error occurred while loading/unloading V2ray core in \"V2rayU\"")
    end
    return false
  end

  local set
  local turnOnTitle = localizedString("Turn v2ray-core On", appid)
  local turnOffTitle = localizedString("Turn v2ray-core Off", appid)
  if enable == true then
    local turnOn = getc(menu, AX.MenuItem, turnOnTitle)
    if turnOn ~= nil then
      turnOn:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff ~= nil then
      turnOff:performAction(AX.Press)
      set = false
    end
  else
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff ~= nil then
      turnOff:performAction(AX.Press)
      set = false
    else
      local turnOn = getc(menu, AX.MenuItem, turnOnTitle)
      turnOn:performAction(AX.Press)
      set = true
    end
  end

  if enable == true or set then
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff == nil then
      if alert then
        hs.alert("Error occurred while loading V2ray core in \"V2rayU\"")
      end
      return false
    end
  end

  if alert then
    if set then
      hs.alert("V2Ray core loaded in \"V2rayU\"")
    else
      hs.alert("V2Ray core unloaded in \"V2rayU\"")
    end
  end

  return true
end

-- toggle connect/disconnect VPN using `MonoCloud`(`MonoProxyMac`)
local function toggleMonoCloud(enable, alert)
  local appid = proxyAppBundleIDs.MonoCloud
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menuItem = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
      AX.Menu, 1, AX.MenuItem, "Set As System Proxy")
  if menuItem == nil then
    if alert then
      hs.alert("Error occurred. Please retry")
    end
    return false
  end

  local ticked = menuItem.AXMenuItemMarkChar
  local set
  if enable == true then
    if ticked ~= "✓" then
      menuItem:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    if ticked == "✓" then
      menuItem:performAction(AX.Press)
      set = false
    end
  else
    menuItem:performAction(AX.Press)
    set = ticked ~= "✓"
  end

  if alert then
    if set then
      hs.alert("Set MonoCloud as system proxy")
    else
      hs.alert("Unset MonoCloud as system proxy")
    end
  end

  return true
end

local proxyActivateFuncs = {
  V2RayX = {
    global = function()
      if toggleV2RayX(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2RayX, "Global Mode") then
          enable_proxy_global("V2RayX")
        end
      end
    end,
    pac = function()
      if toggleV2RayX(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2RayX, "PAC Mode") then
          enable_proxy_PAC("V2RayX")
        end
      end
    end
  },

  V2rayU = {
    global = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Global Mode") then
          enable_proxy_global("V2rayU")
        end
      end
    end,
    pac = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Pac Mode") then
          enable_proxy_PAC("V2rayU")
        end
      end
    end
  },

  MonoCloud = {
    global = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 2 }) then
          enable_proxy_global("MonoCloud")
        end
      end
    end,
    pac = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 3 }) then
          enable_proxy_global("MonoCloud")
        end
      end
    end
  }
}

-- menubar for proxy
local proxy = hs.menubar.new()
proxy:setTitle("PROXY")
proxy:autosaveName("PROXY")
local proxyMenu = {}

-- load proxy configs
ProxyConfigs = {}

local function parseProxyConfigurations(configs)
  for name, config in pairs(configs) do
    ProxyConfigs[name] = {}
    if config.condition ~= nil then
      local shell_command = config.condition.shell_command
      if shell_command ~= nil then
        ProxyConfigs[name].condition = function()
          local _, _, _, rc = hs.execute(shell_command)
          if rc == 0 then return true
          elseif rc == 1 then return false
          else return nil
          end
        end
        ProxyConfigs[name].locations = config.locations
        for _, loc in ipairs(config.locations) do
          ProxyConfigs[name][loc] = {}
          local spec = config[loc]
          ProxyConfigs[name][loc]["PAC"] = spec.pac
          if spec.global ~= nil then
            local httpIp, httpPort = spec.global.http:match("(.+):(%d+)")
            local httpsIp, httpsPort = spec.global.https:match("(.+):(%d+)")
            local socksIp, socksPort = spec.global.socks5:match("(.+):(%d+)")
            ProxyConfigs[name][loc]["global"] = {
              httpIp, httpPort, httpsIp, httpsPort, socksIp, socksPort
            }
          end
        end
      else
        ProxyConfigs[name] = nil
      end
    else
      local spec = config
      ProxyConfigs[name]["PAC"] = spec.pac
      if spec.global ~= nil then
        local httpIp, httpPort = spec.global.http:match("(.+):(%d+)")
        local httpsIp, httpsPort = spec.global.https:match("(.+):(%d+)")
        local socksIp, socksPort = spec.global.socks5:match("(.+):(%d+)")
        ProxyConfigs[name]["global"] = {
          httpIp, httpPort, httpsIp, httpsPort, socksIp, socksPort
        }
      end
    end
  end
end

local proxyConfigs
if exists("config/proxy.json") then
  proxyConfigs = hs.json.read("config/proxy.json")
end
if proxyConfigs ~= nil then
  parseProxyConfigurations(proxyConfigs)
end

local privateProxyConfigs
if exists("config/private-proxy.json") then
  privateProxyConfigs = hs.json.read("config/private-proxy.json")
end
if privateProxyConfigs ~= nil then
  parseProxyConfigurations(privateProxyConfigs)
end

local proxyMenuItemCandidates =
{
  {
    appname = "V2RayX",
    shortcut = 'x',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.V2RayX.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.V2RayX.pac
      }
    }
  },

  {
    appname = "V2rayU",
    shortcut = 'u',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.V2rayU.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.V2rayU.pac
      }
    }
  },

  {
    appname = "MonoCloud",
    shortcut = 'm',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.MonoCloud.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.MonoCloud.pac
      }
    }
  },
}

local function updateProxyWrapper(wrapped, appname)
  local fn = function(mod, item)
    wrapped.fn(mod, item)
    local newProxyMenu = {}
    for _, _item in ipairs(proxyMenu) do
      _item.checked = false
      item.checked = true
      if not _item.title:find("Proxy:")
          and not _item.title:find("PAC File:")then
        tinsert(newProxyMenu, _item)
      end
      if _item.title == appname then
        local networkservice = getCurNetworkService()
        if item.title:match("PAC") then
          local PACFile = hs.execute("networksetup -getautoproxyurl " .. networkservice
                                     .. " | grep URL: | awk '{print $2}'")
          tinsert(newProxyMenu, { title = "PAC File: " .. PACFile, disabled = true })
        else
          local httpAddr = hs.execute("networksetup -getwebproxy " .. networkservice
                                      .. " | grep Server: | awk '{print $2}'")
          local httpPort = hs.execute("networksetup -getwebproxy " .. networkservice
                                      .. " | grep Port: | awk '{print $2}'")
          local socksAddr = hs.execute("networksetup -getsocksfirewallproxy " .. networkservice
                                       .. " | grep Server: | awk '{print $2}'")
          local socksPort = hs.execute("networksetup -getsocksfirewallproxy " .. networkservice
                                       .. " | grep Port: | awk '{print $2}'")
          tinsert(newProxyMenu, { title = "HTTP Proxy: " .. httpAddr .. ":" .. httpPort, disabled = true })
          tinsert(newProxyMenu, { title = "SOCKS5 Proxy: " .. socksAddr .. ":" .. socksPort, disabled = true })
        end
      end
    end
    proxyMenu = newProxyMenu
    proxy:setMenu(proxyMenu)
  end

  return {
    title = wrapped.title,
    fn = fn,
    shortcut = wrapped.shortcut,
    checked = wrapped.checked,
  }
end

local function registerProxyMenuEntry(name, enabled, mode, proxyMenuIdx)
  local config, loc
  if ProxyConfigs[name].condition == nil then
    config = ProxyConfigs[name]
  else
    local locations = ProxyConfigs[name].locations
    local fullfilled = ProxyConfigs[name].condition()
    if fullfilled == nil then return proxyMenuIdx end
    loc = fullfilled and locations[1] or locations[2]
    config = ProxyConfigs[name][loc]
  end
  if config ~= nil then
    tinsert(proxyMenu, { title = "-" })
    tinsert(proxyMenu, { title = name, disabled = true })
    if enabled and mode ~= nil then
      if mode == "PAC" then
        local PACFile = config.PAC
        tinsert(proxyMenu, {
          title = "PAC File: " .. PACFile,
          disabled = true
        })
      else
        local addr = config.global
        tinsert(proxyMenu, {
          title = "HTTP Proxy: " .. addr[1] .. ":" .. addr[2],
          disabled = true
        })
        tinsert(proxyMenu, {
          title = "SOCKS5 Proxy: " .. addr[5] .. ":" .. addr[6],
          disabled = true
        })
      end
    end
    if config.global ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    Global Mode",
        fn = function() enable_proxy_global(name, nil, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "Global"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
    if config.PAC ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    PAC Mode",
        fn = function() enable_proxy_PAC(name, nil, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "PAC"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
  end
  return proxyMenuIdx
end

local function parseProxyInfo(info, require_mode)
  if require_mode == nil then require_mode = true end
  local enabledProxy = ""
  local mode = nil
  if info[2]:match("Enabled: Yes") then
    for appname, config in pairs(ProxyConfigs) do
      if config.condition == nil then
        if config.PAC ~= nil and info[2]:match(config.PAC) then
          enabledProxy = appname
          mode = "PAC"
        end
      else
        for _, loc in ipairs(config.locations) do
          local spec = config[loc]
          if spec.PAC ~= nil and info[2]:match(spec.PAC) then
            enabledProxy = appname
            mode = "PAC"
            break
          end
        end
      end
      if mode ~= nil then break end
    end
  elseif info[3]:match("Enabled: Yes") then
    for appname, config in pairs(ProxyConfigs) do
      if config.condition == nil then
        if config.global ~= nil and info[3]:match(config.global[1])
            and info[3]:match(tostring(config.global[2])) then
          enabledProxy = appname
        end
      else
        for _, loc in pairs(config.locations) do
          local spec = config[loc]
          if spec.global ~= nil and info[3]:match(spec.global[1])
              and info[3]:match(tostring(spec.global[2])) then
            enabledProxy = appname
            break
          end
        end
      end
      if enabledProxy ~= "" then
        if enabledProxy ~= "MonoCloud" then
          mode = "Global"
        elseif require_mode then
          local appid = proxyAppBundleIDs.MonoCloud
          if find(appid) ~= nil then
            local appUI = toappui(find(appid))
            local outboundModeMenu = getc(appUI, AX.MenuBar, -1,
                AX.MenuBarItem, 1, AX.Menu, 1,
                AX.MenuItem, "Outbound Mode", AX.Menu, 1)
            if outboundModeMenu ~= nil then
              if getc(outboundModeMenu, AX.MenuItem, 2)
                  .AXMenuItemMarkChar == "✓" then
                mode = "Global"
              elseif getc(outboundModeMenu, AX.MenuItem, 3)
                  .AXMenuItemMarkChar == "✓" then
                mode = "PAC"
              end
            end
          end
        end
        break
      end
    end
  end
  if require_mode then
    return enabledProxy, mode
  else
    return enabledProxy
  end
end

local function registerProxySettingsEntry(menu)
  tinsert(menu, { title = "-" })
  tinsert(menu, {
    title = "Proxy Settings",
    fn = function()
      local app = hs.application.open("com.apple.systempreferences", 2, true)
      local action = function()
        if OS_VERSION < OS.Ventura then
          local ok = hs.osascript.applescript([[
            tell application id "com.apple.systempreferences"
              set current pane to pane "com.apple.preference.network"
              repeat until anchor "Proxies" of current pane exists
                delay 0.1
              end repeat
              reveal anchor "Proxies" of current pane
            end tell
          ]])
          if not ok then return end
        else
          local ok = hs.osascript.applescript([[
            tell application id "com.apple.systempreferences"
              reveal anchor "Proxies" of pane ¬
                  id "com.apple.Network-Settings.extension"
            end tell
          ]])
          if not ok then return end
        end
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.sheetCreated)
        observer:callback(function(obs, sheet)
          local record
          hs.timer.waitUntil(function()
            local rows
            if OS_VERSION < OS.Ventura then
              rows = getc(sheet, AX.TabGroup, 1,
                AX.Group, 1, AX.SrollArea, 1, AX.Table, 1, AX.Row)
            else
              rows = getc(sheet, AX.Group, 1,
                AX.SplitGroup, 1, AX.Group, 2, AX.SrollArea, 1, AX.Group)
            end
            record = tfind(rows, function(r)
              return getc(r, AX.CheckBox, 1).AXValue == 1
            end)
            return record ~= nil
          end,
          function()
            local position = getc(record, AX.TextField, 1).AXPosition
            local size = getc(record, AX.TextField, 1).AXSize
            leftClickAndRestore({ position.x + size.w - 1, position.y },
                                app:name())
          end)
          obs:stop()
          obs = nil
        end)
        observer:start()
      end

      if app:focusedWindow():role() == AX.Sheet then
        hs.eventtap.keyStroke("", "Escape")
        hs.timer.waitUntil(function()
          return app:focusedWindow():role() ~= AX.Sheet
        end, action)
      else
        action()
      end
    end,
    shortcut = 'p'
  })
end

local function registerProxyMenuImpl()
  local enabledProxy, mode = parseProxyInfo(proxy_info())

  proxyMenu =
  {
    {
      title = "Information",
      fn = function()
        local info = proxy_info()
        local enabled, m = parseProxyInfo(proxy_info())
        local header
        if enabled ~= "" then
          header = "Enabled: " .. enabled
          if m ~= nil then
            header = header .. " (" .. m .. ")"
          end
        else
          header = "No Proxy Enabled"
        end
        header = header .. [[


          Details:

          ]] .. info[1] .. [[

          Auto Proxy:
          ]] .. info[2] .. [[

          HTTP Proxy:
          ]] .. info[3] .. [[

          HTTPS Proxy:
          ]] .. info[4] .. [[

          SOCKS Proxy:
          ]] .. info[5]
        hs.focus()
        hs.dialog.blockAlert("Proxy Configuration", header)
      end,
      shortcut = 'i',
    },

    updateProxyWrapper({
      title = "Disable",
      fn = function() disable_proxy() end,
      shortcut = '0',
      checked = enabledProxy == ""
    }),
  }

  local proxyMenuIdx = 1
  local otherProxies = {}
  for name, _ in pairs(ProxyConfigs) do
    if tfind(proxyMenuItemCandidates,
          function(item)
            return item.appname == name
          end) == nil then
      if name == "System" then
        proxyMenuIdx = registerProxyMenuEntry('System',
            enabledProxy == "System", mode, proxyMenuIdx)
      else
        tinsert(otherProxies, name)
      end
    end
  end

  for _, candidate in ipairs(proxyMenuItemCandidates) do
    local appid = proxyAppBundleIDs[candidate.appname]
    if ProxyConfigs[candidate.appname] ~= nil
        and hs.application.pathForBundleID(appid) ~= nil
        and hs.application.pathForBundleID(appid) ~= "" then
      tinsert(proxyMenu, { title = "-" })
      tinsert(proxyMenu, {
        title = candidate.appname,
        fn = function()
          local actionFunc = function()
            clickRightMenuBarItem(appid)
          end
          if find(appid) == nil then
            hs.application.launchOrFocusByBundleID(appid)
            hs.timer.waitUntil(
              function() return find(appid) ~= nil end,
              actionFunc)
          else
            actionFunc()
          end
        end,
        shortcut = candidate.shortcut
      })
      if candidate.appname == enabledProxy and mode ~= nil then
        if mode == "PAC" and
            ProxyConfigs[candidate.appname]["PAC"] ~= nil then
          local PACFile = ProxyConfigs[candidate.appname]["PAC"]
          tinsert(proxyMenu, {
            title = "PAC File: " .. PACFile,
            disabled = true,
          })
        elseif ProxyConfigs[candidate.appname]["global"] ~= nil then
          local addr = ProxyConfigs[candidate.appname]["global"]
          tinsert(proxyMenu, {
            title = "HTTP Proxy: " .. addr[1] .. ":" .. addr[2],
            disabled = true,
          })
          tinsert(proxyMenu, {
            title = "SOCKS5 Proxy: " .. addr[5] .. ":" .. addr[6],
            disabled = true,
          })
        end
      end

      for _, menuItem in ipairs(candidate.items) do
        menuItem.shortcut = tostring(proxyMenuIdx)
        local checked = (candidate.appname == enabledProxy)
            and mode and menuItem.title:match(mode) ~= nil
        menuItem.checked = checked
        tinsert(proxyMenu, updateProxyWrapper(menuItem, candidate.appname))
        proxyMenuIdx = proxyMenuIdx + 1
      end
    end
  end

  for _, name in ipairs(otherProxies) do
    proxyMenuIdx = registerProxyMenuEntry(
        name, enabledProxy == name,
        mode, proxyMenuIdx)
  end

  registerProxySettingsEntry(proxyMenu)
  proxy:setMenu(proxyMenu)
end

local function registerProxyMenu(retry)
  refreshNetworkService()
  if not getCurNetworkService() then
    local menu = {{
      title = "No Network Access",
      disabled = true
    }}
    registerProxySettingsEntry(menu)
    proxy:setMenu(menu)
    if not retry then
      return false
    else
      hs.timer.waitUntil(
        function()
          refreshNetworkService()
          return getCurNetworkService() ~= nil
        end,
        function() registerProxyMenu(false) end,
        3
      )
      return false
    end
  elseif getCurNetworkService() == '"iPhone USB"' then
    local menu = {{
      title = "Proxy Configured on iPhone",
      disabled = true
    }}
    proxy:setMenu(menu)
    return true
  else
    registerProxyMenuImpl()
    return true
  end
end

local proxySettings
if exists("config/misc.json") then
  proxySettings = hs.json.read("config/misc.json").proxy
  for _, cfg in ipairs(proxySettings) do
    if cfg.condition ~= nil then
      local shell_command = cfg.condition["shell_command"]
      if shell_command ~= nil then
        cfg.condition = function()
          local _, _, _, rc = hs.execute(shell_command)
          return rc == 0
        end
      end
    end
  end
end

local lastIpv4State
local function registerProxyMenuWrapper(storeObj, changedKeys)
  for i = #NetworkMonitorKeys, 1, -1 do
    local netID = NetworkMonitorKeys[i]
        :match("Setup:/Network/Service/(.-)/Proxies")
    if netID ~= nil then
      tremove(NetworkMonitorKeys, i)
    end
  end
  local Ipv4State = NetworkWatcher
      :contents("State:/Network/Global/IPv4")
      ["State:/Network/Global/IPv4"]
  if Ipv4State ~= nil then
    local curNetID = Ipv4State["PrimaryService"]
    tinsert(NetworkMonitorKeys, "Setup:/Network/Service/" .. curNetID .. "/Proxies")
    if lastIpv4State == nil and proxySettings ~= nil then
      refreshNetworkService()
      disable_proxy()
      for _, cfg in ipairs(proxySettings) do
        if cfg.condition ~= nil and cfg.condition() then
          for _, candidate in ipairs(cfg.candidates or {}) do
            local name, mode = candidate.name, candidate.mode
            if ProxyConfigs[name] ~= nil then
              local config, loc
              if ProxyConfigs[name].condition == nil then
                config = ProxyConfigs[name]
              else
                local locations = ProxyConfigs[name].locations
                local fullfilled = ProxyConfigs[name].condition()
                if fullfilled ~= nil then
                  loc = fullfilled and locations[1] or locations[2]
                  config = ProxyConfigs[name][loc]
                end
              end
              if config ~= nil then
                for n, actFuncs in pairs(proxyActivateFuncs) do
                  if n == name and actFuncs[mode] ~= nil then
                    actFuncs[mode]()
                    goto L_PROXY_SET
                  end
                end
                if mode == "global" then
                  enable_proxy_global(name, nil, loc)
                elseif mode == "pac" then
                  enable_proxy_PAC(name, nil, loc)
                end
                goto L_PROXY_SET
              end
            end
          end
        end
      end
    end
  end
  ::L_PROXY_SET::
  NetworkWatcher:monitorKeys(NetworkMonitorKeys)
  registerProxyMenu(true)
  lastIpv4State = Ipv4State
end
registerProxyMenuWrapper()


local menubarHK = KeybindingConfigs.hotkeys.global

local proxyHotkey = bindHotkeySpec(menubarHK["showProxyMenu"], "Show Proxy Menu",
    bind(clickRightMenuBarItem, {"org.hammerspoon.Hammerspoon", proxy:title()}))
proxyHotkey.kind = HK.MENUBAR
proxyHotkey.icon = hs.image.imageFromAppBundle("com.apple.systempreferences")

-- toggle system proxy
local function toggleSystemProxy(networkservice)
  if networkservice == nil then
    networkservice = getCurNetworkService()
  end
  local autodiscovery = hs.execute("networksetup -getproxyautodiscovery " .. networkservice)
  local autoproxyurl = hs.execute("networksetup -getautoproxyurl " .. networkservice)
  local webproxy = hs.execute("networksetup -getwebproxy " .. networkservice)
  local securewebproxy = hs.execute("networksetup -getsecurewebproxy " .. networkservice)
  local socksproxy = hs.execute("networksetup -getsocksfirewallproxy " .. networkservice)

  if autodiscovery:match("On")
    or webproxy:match("Yes")
    or securewebproxy:match("Yes")
    or socksproxy:match("Yes") then
    disable_proxy(networkservice)
    hs.alert("System proxy disabled")
  elseif autoproxyurl:match("Yes") then
    enable_proxy_global(nil, networkservice)
    hs.alert("System proxy enabled (global mode)")
  else
    enable_proxy_PAC(nil, networkservice)
    hs.alert("System proxy enabled (auto mode)")
    end
end

-- assume `Control Center` window is always frontmost
-- so not necessary to call "inAppHotKeysWrapper"
local function newControlCenter(...)
  local hotkey = newHotkey(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

local function bindControlCenter(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

local controlCenterIdentifiers = hs.json.read("static/controlcenter-identifies.json")
local controlCenterSubPanelIdentifiers = controlCenterIdentifiers.subpanel
local controlCenterMenuBarItemIdentifiers = controlCenterIdentifiers.menubar
local controlCenterAccessibiliyIdentifiers = controlCenterIdentifiers.accessibility
local defaultMusicAppForControlCenter
defaultMusicAppForControlCenter = ApplicationConfigs["defaultMusicAppForControlCenter"]

local function controlCenterLocalized(panel, key)
  if key == nil then
    key = panel
  end
  if panel == "Users" and key == "Users" then
    key = "User"
  end
  panel = panel:gsub(" ", ""):gsub("‑", "")
  local result = localizedString(key, "com.apple.controlcenter", panel)
  if result == nil and panel == "Focus" then
    result = localizedString(key, "com.apple.controlcenter",
        { framework = "DoNotDisturb.framework" }, true)
    if result == nil then
      result = localizedString(key, "com.apple.controlcenter",
          { framework = "DoNotDisturbKit.framework" }, true)
    end
  end
  return result
end

local function popupControlCenterSubPanel(panel, allowReentry)
  local ident = controlCenterSubPanelIdentifiers[panel]
  local app = find("com.apple.controlcenter")
  local win = app:mainWindow()
  local pane =
      (OS_VERSION < OS.Ventura and "window 1" or "group 1 of window 1")
      .. ' of application process "ControlCenter"'

  local enter = nil
  local enterTemplate = [[
    set panelFound to false
    set totalDelay to 0.0
    repeat until totalDelay > 0.9
      repeat with ele in (every %s of pane)
        if (exists attribute "AXIdentifier" of ele) ¬
            and (the value of attribute "AXIdentifier" ¬
                 of ele contains "%s") then
          set panelFound to true
          perform action %d of ele
          exit repeat
        end if
      end repeat
      if panelFound then
        exit repeat
      else
        delay 0.1
        set totalDelay to totalDelay + 0.1
      end if
    end repeat
  ]]
  if tcontain({ "Wi‑Fi", "Focus",
                "Bluetooth", "AirDrop",
                "Music Recognition" }, panel) then
    enter = strfmt(enterTemplate, "checkbox", ident, 2)
  elseif panel == "Screen Mirroring" then
    if OS_VERSION < OS.Ventura then
      enter = strfmt(enterTemplate, "checkbox", ident, 2)
    else
      enter = strfmt(enterTemplate, "button", ident, 1)
    end
  elseif panel == "Display" then
    enter = strfmt(enterTemplate, OS_VERSION < OS.Ventura
        and "static text" or "group", ident, 1)
  elseif panel == "Sound" then
    enter = strfmt(enterTemplate, "static text", ident, 1)
  elseif tcontain({ "Accessibility Shortcuts",
                    "Battery", "Hearing", "Users",
                    "Keyboard Brightness" }, panel) then
    enter = strfmt(enterTemplate, "button", ident, 1)
  elseif panel == "Now Playing" then
    enter = [[
      set panelFound to true
      perform action 1 of last image of pane
    ]]
  end

  local ok, result
  if win == nil then
    local foundInMenuBar = false
    for _, item in ipairs(getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem)) do
      if item.AXIdentifier:find(controlCenterMenuBarItemIdentifiers[panel]) then
        if find("com.surteesstudios.Bartender") ~= nil then
          local menuBarPanel = panel == "Focus" and "Focus Modes" or panel
          ok, result = hs.osascript.applescript(strfmt([[
            tell application id "com.surteesstudios.Bartender"
              activate "com.apple.controlcenter-%s"
            end tell
          ]], menuBarPanel:gsub(" ", ""):gsub("‑", "")))
        else
          item:performAction(AX.Press)
        end
        foundInMenuBar = true
        break
      end
    end
    if not foundInMenuBar then
      local delayCmd = menuBarVisible() and "" or "delay 0.3"
      ok, result = hs.osascript.applescript([[
        tell application "System Events"
          set controlitems to menu bar 1 ¬
              of application process "ControlCenter"
          set controlcenter to (first menu bar item whose ¬
              value of attribute "AXIdentifier" ¬
              contains "controlcenter") of controlitems
          perform action 1 of controlcenter

          ]] .. delayCmd .. [[

          set pane to ]]..pane..[[ 
          ]] .. enter .. [[
          if panelFound then
            return 1
          else
            return 0
          end if
        end tell
      ]])
    end
  else
    local already = nil
    local alreadyTemplate = [[
      repeat with ele in (every %s of pane)
        if (exists attribute "AXIdentifier" of ele) ¬
            and (the value of attribute "AXIdentifier" of ele ¬
                 contains "%s") then
          set already to true
          exit repeat
        end if
      end repeat
    ]]
    if tcontain({ "Wi‑Fi", "Focus", "Bluetooth", "AirDrop",
                  "Keyboard Brightness", "Screen Mirroring",
                  "Accessibility Shortcuts", "Battery" }, panel) then
      already = strfmt(alreadyTemplate, "static text", ident)
    elseif panel == "Display" then
      already = [[
        if exists scroll area 1 of pane then
      ]] .. strfmt(alreadyTemplate, "slider of scroll area 1", ident) .. [[
        end if
      ]]
    elseif panel == "Sound" then
      already = strfmt(alreadyTemplate, "slider", ident)
    elseif panel == "Music Recognition" then
      already = strfmt(alreadyTemplate, "group", ident)
    elseif panel == "Hearing" then
      already = [[
        if value of attribute "AXRole" of ui element 1 of pane is "AXScrollArea" then
      ]] .. strfmt(alreadyTemplate, "static text of scroll area 1 ",
                   controlCenterMenuBarItemIdentifiers[panel], panel) .. [[ 
        else
      ]] .. strfmt(alreadyTemplate, "static text ",
                   controlCenterMenuBarItemIdentifiers[panel], panel) .. [[ 
        end if
      ]]
    elseif panel == "Now Playing" then
      if OS_VERSION < OS.Ventura then
        local mayLocalize = bind(controlCenterLocalized, "Now Playing")
        already = [[
          if (exists button "]] .. mayLocalize("rewind") .. [[" of pane) or  ¬
              (exists button "]] .. mayLocalize("previous") .. [[" of pane) or ¬
              (number of (buttons of pane whose title is "]] .. mayLocalize("play") .. [[" or ¬
                  title is "]] .. mayLocalize("pause") .. [[") > 1)
            set already to true
          end if
        ]]
      else
        already = [[
          set already to ((exists image of pane) and ¬
              (number of buttons of pane > 2))
        ]]
      end
    end

    if allowReentry == nil then
      allowReentry = false
    end
    allowReentry = tostring(allowReentry)
    ok, result = hs.osascript.applescript([[
      tell application "System Events"
        set pane to ]]..pane..[[ 
        set wifi to false
        set bluetooth to false
        repeat with ele in (every checkbox of pane)
          if (exists attribute "AXIdentifier" of ele) then
            if (the value of attribute "AXIdentifier" of ele contains ¬
                "]] .. controlCenterSubPanelIdentifiers["Wi‑Fi"] .. [[") then
              set wifi to true
            else if (the value of attribute "AXIdentifier" of ele contains ¬
                "]] .. controlCenterSubPanelIdentifiers["Bluetooth"] .. [[") then
              set bluetooth to true
            end if
          end if
        end repeat
        if wifi and bluetooth then
          ]] .. enter .. [[ 
          return 1
        else
          set already to false
          ]] .. already .. [[ 
          if already and not ]] .. allowReentry .. [[ then
            return 0
          else
            set controlitems to menu bar 1 ¬
                of application process "ControlCenter"
            set controlcenter to (first menu bar item whose ¬
                value of attribute "AXIdentifier" ¬
                contains "controlcenter") of controlitems
            perform action 1 of controlcenter

            delay 0.5
            set pane to ]]..pane..[[ 
            ]] .. enter .. [[ 
            if panelFound then
              return -1
            else
              return 0
            end if
          end if
        end if
      end tell
    ]])
  end

  if ok and result ~= 0 then
    registerControlCenterHotKeys(panel)
  end
end

local controlCenterHotKeys = nil
local controlCenterSubPanelWatcher = nil

local function checkAndRegisterControlCenterHotKeys(hotkey)
  if controlCenterHotKeys == nil then
    hotkey:delete()
    return false
  else
    hotkey:enable()
    tinsert(controlCenterHotKeys, hotkey)
    return true
  end
end

local hotkeyMainForward, hotkeyMainBack
local hotkeyShow, hotkeyHide
local backgroundSoundsHotkeys
local selectNetworkHotkeys, selectNetworkWatcher
---@diagnostic disable-next-line: lowercase-global
function registerControlCenterHotKeys(panel)
  local appUI = toappui(find('com.apple.controlcenter'))
  local paneUI = getc(appUI, AX.Window, 1)
  if OS_VERSION >= OS.Ventura then
    paneUI = getc(paneUI, AX.Group, 1)
    if panel == "Hearing" then
      while #paneUI == 0 do
        hs.timer.usleep(0.05 * 1000000)
      end
      if #paneUI == 1 and paneUI[1].AXRole == AX.ScrollArea then
        paneUI = paneUI[1]
      end
    end
  end
  local pane =
      (OS_VERSION < OS.Ventura and "window 1" or "group 1 of window 1")
      .. ' of application process "ControlCenter"'

  local function mayLocalize(value)
    return controlCenterLocalized(panel, value)
  end

  if controlCenterHotKeys ~= nil then
    for _, hotkey in ipairs(controlCenterHotKeys) do
      hotkey:delete()
    end
  end
  controlCenterHotKeys = {}
  if hotkeyShow ~= nil then
    hotkeyShow:delete()
    hotkeyShow = nil
  end
  if hotkeyHide ~= nil then
    hotkeyHide:delete()
    hotkeyHide = nil
  end
  if backgroundSoundsHotkeys ~= nil then
    for _, hotkey in ipairs(backgroundSoundsHotkeys) do
      hotkey:delete()
    end
    backgroundSoundsHotkeys = nil
  end

  -- back to main panel
  hotkeyMainBack = newControlCenter("⌘", "[", "Back",
    function()
      assert(hotkeyMainBack) hotkeyMainBack:disable()
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = {}
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      if backgroundSoundsHotkeys ~= nil then
        for _, hotkey in ipairs(backgroundSoundsHotkeys) do
          hotkey:delete()
        end
        backgroundSoundsHotkeys = nil
      end
      if controlCenterSubPanelWatcher ~= nil then
        controlCenterSubPanelWatcher:unsubscribeAll()
        controlCenterSubPanelWatcher = nil
      end

      local ident = controlCenterMenuBarItemIdentifiers["Control Center"]
      local menuBarItem = tfind(getc(appUI, AX.MenuBar, -1, AX.MenuBarItem),
        function(item)
          return item.AXIdentifier:find(ident) ~= nil
        end)
      menuBarItem:performAction(AX.Press)
      hotkeyMainForward = newControlCenter("⌘", "]", "Forward",
        function()
          assert(hotkeyMainForward) hotkeyMainForward:disable()
          popupControlCenterSubPanel(panel)
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkeyMainForward) then
        return
      end
    end)
  if not checkAndRegisterControlCenterHotKeys(hotkeyMainBack) then
    return
  end

  -- jump to related panel in `System Preferences`
  if tcontain({ "Wi‑Fi", "Bluetooth", "Focus", "Keyboard Brightness",
                "Screen Mirroring", "Display", "Sound",
                "Accessibility Shortcuts", "Battery",
                "Hearing", "Users", }, panel) then
    if OS_VERSION < OS.Ventura then
      local button
      repeat
        hs.timer.usleep(0.05 * 1000000)
        local buttons = getc(paneUI, AX.Button)
        for i = #buttons, 1, -1 do
          if buttons[i].AXTitle:find("…") then
            button = buttons[i]
            break
          end
        end
      until button or not paneUI:isValid()
      if button then
        local hotkey = newControlCenter("⌘", ",", result,
            function() button:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    else
      local searchPanel = panel
      local btnName
      if panel == "Screen Mirroring" then
        btnName = "Display"
      elseif panel == "Keyboard Brightness" then
        btnName = "Keyboard"
      elseif panel == "Accessibility Shortcuts" then
        btnName = "Accessibility"
      elseif panel == "Hearing" then
        searchPanel = "Accessibility Shortcuts"
        btnName = "Accessibility"
      elseif panel == "Users" then
        btnName = "Users & Groups"
      else
        btnName = panel
      end
      btnName = btnName .. " Settings…"
      btnName = controlCenterLocalized(searchPanel, btnName)
      local hotkey = newControlCenter("⌘", ",", btnName,
        function()
          local button = getc(paneUI, AX.Button, -1)
          if button then
            button:performAction(AX.Press)
          end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- pandel with a switch-off button
  if tcontain({"Wi‑Fi", "Bluetooth", "AirDrop"}, panel) then
    local checkbox = tfind(getc(appUI, AX.Window, 1, AX.CheckBox), function(cb)
      return cb.AXIdentifier and cb.AXIdentifier:find("%-header")
    end)
    if checkbox == nil then
      checkbox = tfind(getc(appUI, AX.Window, 1, AX.Group, 1, AX.CheckBox), function(cb)
        return cb.AXIdentifier and cb.AXIdentifier:find("%-header")
      end)
    end
    if checkbox then
      local hotkey = newControlCenter("", "Space",
        "Toggle " .. controlCenterLocalized(panel),
        function() checkbox:performAction(AX.Press) end
      )
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- panel with a slider
  if tcontain({"Display", "Sound", "Keyboard Brightness"}, panel) then
    local name = panel == "Sound" and "Volume" or "Brightness"
    local actions = {{ '=', 'Up'}, {'-', 'Down'}, {'[', 'Min'}, {']', 'Max'}}
    local enabledSliders
    repeat
      hs.timer.usleep(0.05 * 1000000)
      if panel == "Display" then
        local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
        enabledSliders = getc(paneUI, role, 1, AX.Slider)
      else
        enabledSliders = getc(paneUI, AX.Slider)
      end
    until enabledSliders and #enabledSliders > 0 or not paneUI:isValid()
    if #enabledSliders == 1 then
      for _, spec in ipairs(actions) do
        local key = spec[1]
        local msg = name .. ' ' .. spec[2]
        local slid = enabledSliders[1]
        local hotkey = newControlCenter("", key, msg,
          function()
            if key == '=' then
              slid:performAction(AX.Increment)
            elseif key == '-' then
              slid:performAction(AX.Decrement)
            elseif key == '[' then
              slid.AXValue = 0
            else
              slid.AXValue = 100
            end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  -- panel with a list of devices
  if tcontain({"Bluetooth", "Sound", "Screen Mirroring"}, panel) then
    local cbs
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      cbs = tifilter(getc(paneUI, AX.ScrollArea, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      if #cbs == 0 and panel == "Screen Mirroring" then
        cbs = tifilter(getc(paneUI, AX.ScrollArea, 1,
            AX.Group, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      end
    until #cbs > 0 or totalDelay > 1 or not paneUI:isValid()
    if #cbs > 0 then
      for i=1, math.min(#cbs, 10) do
        local enabled = cbs[i].AXValue
        local name
        if OS_VERSION < OS.Ventura then
          name = cbs[i].AXTitle
        else
          name = cbs[i].AXIdentifier
          local _, nameIdx = name:find("device-", 1, true)
          name = name:sub(nameIdx + 1, -1)
        end
        local msg = "Connect to " .. name
        if enabled == nil or enabled == 1 then
          local newName = name:match("(.-), %d+%%$")
          if newName ~= nil then name = newName end
          msg = "Disconnect to " .. name
        end
        local hotkey = newControlCenter("", tostring(i%10), msg,
            function()
              cbs[i]:performAction(AX.Press)
            end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  local registerHotkeyForTraingleDisclosure = function(actionFunc, msg, enabled)
    if enabled == 0 then
      hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
        function()
          assert(hotkeyShow) hotkeyShow:disable()
          actionFunc()
          if hotkeyHide == nil then
            hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
              function()
                assert(hotkeyHide) hotkeyHide:disable()
                assert(hotkeyShow) hotkeyShow:enable()
                actionFunc()
              end)
          end
          assert(hotkeyHide) hotkeyHide:enable()
        end)
      assert(hotkeyShow) hotkeyShow:enable()
    else
      hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
        function()
          assert(hotkeyHide) hotkeyHide:disable()
          actionFunc()
          if hotkeyShow == nil then
            hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
              function()
                assert(hotkeyShow) hotkeyShow:disable()
                hotkeyHide:enable()
                actionFunc()
              end)
          end
          assert(hotkeyShow) hotkeyShow:enable()
        end)
      assert(hotkeyHide) hotkeyHide:enable()
    end
  end

  if panel == "Wi‑Fi" then
    local triangle
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local sa = getc(paneUI, AX.ScrollArea, 1)
      if sa and sa[1] and sa[1].AXRole == "AXOpaqueProviderGroup" then
        sa = sa[1]
      end
      triangle = getc(sa, AX.DisclosureTriangle, 1)
    until triangle or totalDelay > 0.5 or not paneUI:isValid()
    if triangle then
      local actionFunc = function()
        local actions = triangle:actionNames()
        triangle:performAction(actions[#actions])
      end
      local localizedOtherNetworks = mayLocalize("Other Networks")
      registerHotkeyForTraingleDisclosure(actionFunc,
          localizedOtherNetworks, triangle.AXValue)
    end

    -- select network
    selectNetworkHotkeys = {}
    local availableNetworksString = ""
    local selectNetworkActionFunc = function()
      local sa
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        sa = getc(paneUI, AX.ScrollArea, 1)
        if sa and sa[1] and sa[1].AXRole == "AXOpaqueProviderGroup" then
          sa = sa[1]
        end
      until sa or totalDelay > 0.5 or not paneUI:isValid()
      if sa then
        local availableNetworks = {}
        for idx, cb in ipairs(getc(sa, AX.CheckBox)) do
          local ft = OS_VERSION < OS.Ventura and cb.AXTitle or cb.AXIdentifier
          if idx > 10 then break end
          local title
          if OS_VERSION < OS.Ventura then
            title = ft:match("([^,]+)")
          else
            title = ft:sub(string.len("wifi-network-") + 1, -1)
          end
          tinsert(availableNetworks, title)
        end
        local newAvailableNetworksString = table.concat(availableNetworks, "|")
        if newAvailableNetworksString ~= availableNetworksString then
          availableNetworksString = newAvailableNetworksString
          for _, hotkey in ipairs(selectNetworkHotkeys) do
            hotkey:delete()
          end
          selectNetworkHotkeys = {}
          for idx, title in ipairs(availableNetworks) do
            local selected = getc(sa, AX.CheckBox, idx).AXValue
            local msg = "Connect to " .. title
            if selected == nil or selected == 1 then
              msg = "Disconnect to " .. title
            end
            local hotkey = newControlCenter("", tostring(idx % 10), msg,
              function()
                local cb = getc(sa, AX.CheckBox, idx)
                local actions = cb:actionNames()
                cb:performAction(actions[#actions])
              end)
            assert(hotkey) hotkey:enable()
            tinsert(selectNetworkHotkeys, hotkey)
          end
        end
      else
        if selectNetworkHotkeys ~= nil then
          for _, hotkey in ipairs(selectNetworkHotkeys) do
            hotkey:delete()
          end
          selectNetworkHotkeys = {}
        end
      end
    end
    selectNetworkActionFunc()
    selectNetworkWatcher = ExecContinuously(selectNetworkActionFunc)
  elseif panel == "AirDrop" then
    local cb
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb = getc(paneUI, AX.CheckBox, 3)
    until cb or not paneUI:isValid()
    if cb then
      local cbs = { getc(paneUI, AX.CheckBox, 2), cb }
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = { cbs[1].AXTitle, cbs[2].AXTitle }
      else
        local toggleIdents = { cbs[1].AXIdentifier, cbs[2].AXIdentifier }
        toggleNames = {}
        foreach(toggleIdents, function(ele)
          for k, v in pairs(controlCenterAccessibiliyIdentifiers["AirDrop"]) do
            if v == ele then
              tinsert(toggleNames, mayLocalize(k))
              break
            end
          end
        end)
      end
      for i=1,2 do
        local hotkey = newControlCenter("", tostring(i), toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  elseif panel == "Focus" then
    local cb
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb = getc(paneUI, AX.CheckBox, 2)
    until cb or not paneUI:isValid()
    if cb then
      local cbs = { getc(paneUI, AX.CheckBox, 1), getc(paneUI, AX.CheckBox, -1) }
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = { cbs[1].AXTitle, cbs[2].AXTitle }
      else
        local toggleIdents = { cbs[1].AXIdentifier, cbs[2].AXIdentifier }
        toggleNames = {}
        foreach(toggleIdents, function(ele)
          for k, v in pairs(controlCenterAccessibiliyIdentifiers[panel]) do
            if v == ele then
              tinsert(toggleNames, mayLocalize(k) or k)
              break
            end
          end
        end)
      end
      for i=1,2 do
        local hotkey = newControlCenter("", tostring(i),
            "Toggle " .. toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
      for i=2,3 do
        local hotkey = newControlCenter("⌘", tostring(i - 1),
          toggleNames[1] .. " " .. i - 1,
          function()
            local _cbs = getc(paneUI, AX.CheckBox)
            if #_cbs > 2 then
              _cbs[i]:performAction(AX.Press)
            end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  elseif panel == "Display" then
    local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
    local sa1
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      sa1 = getc(paneUI, role, 1)
    until sa1 or totalDelay > 0.5 or not paneUI:isValid()
    local i, j
    for m, sa in ipairs(getc(paneUI, role)) do
      for nn =1,#sa do
        local n = #sa - nn + 1
        if sa[n].AXRole == AX.DisclosureTriangle then
          i, j = m, n
          break
        end
      end
    end
    if i and j then
      local elem = getc(paneUI, role, i, nil, j)
      if elem then
        local hotkey = newControlCenter("", "Space",
            "Toggle Showing Display Presets",
            function() elem:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end

    local area = getc(appUI, AX.Window, 1,
        OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group, 1)
    local cb3
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb3 = getc(area, AX.CheckBox, 3)
    until cb3 or not paneUI:isValid()
    if cb3 == nil then return end
    local cbs = getc(area, AX.CheckBox)
    local cbIdents = hs.fnutils.map(cbs, function (cb)
      return cb.AXIdentifier
    end)
    local enableds = hs.fnutils.map(cbs, function (cb)
      return cb.AXValue
    end)
    for i=1,3 do
      local cbIdent = cbIdents[i]
      local checkbox = tfind({"Dark Mode", "Night Shift", "True Tone"},
        function(ele)
          return cbIdent == controlCenterAccessibiliyIdentifiers["Display"][ele]
        end)
      local op = enableds[i] == 0 and "Enable" or "Disable"
      local hotkey = newControlCenter("", tostring(i),
        op .. " " .. mayLocalize(checkbox),
        function()
          local cb = getc(area, AX.CheckBox, cbIdent)
          if not cb then return end
          cb:performAction(AX.Press)
          enableds[i] = 1 - enableds[i]

          if checkbox == "Dark Mode" then
            local appid = hs.application.frontmostApplication():bundleID()
            if tcontain({"com.google.Chrome",
                         "com.microsoft.edgemac",
                         "com.microsoft.edgemac.Dev"}, appid) then
              local scheme = appid == "com.google.Chrome" and "chrome" or "edge"
              local ok = hs.osascript.applescript(strfmt([[
                tell application id "%s"
                  set tabCount to count of tabs of front window
                  set tabFound to false
                  repeat with i from 1 to tabCount
                    set tabURL to URL of tab i of front window
                    if tabURL contains "%s://flags/#enable-force-dark" then
                      set tabFound to true
                      exit repeat
                    end if
                  end repeat
                  if tabFound is false then
                    tell front window
                      set newTab to make new tab at the end of tabs ¬
                          with properties {URL:"%s://flags/#enable-force-dark"}
                      delay 0.5
                    end tell
                  else
                    tell front window
                      set active tab index to i
                    end tell
                  end if
                end tell
              ]], appid, scheme, scheme))
              if ok then
                local app = find(appid)
                local appUI = toappui(app)
                local winUI = towinui(app:focusedWindow())
                local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
                    AX.Group, 1, AX.Group, 1, AX.WebArea, 1)
                local list, button
                if appid == "com.google.Chrome" then
                  list = getc(webarea, AX.Group, 2, AX.Group, 1,
                              AX.Group, 4, AX.Group, 1)
                else
                  list = getc(webarea, AX.Group, 1, AX.Group, 2,
                              AX.Group, 1, AX.Group, 3, AX.Group, 1)
                end
                if list ~= nil then
                  for _, c in ipairs(list) do
                    if c[1].AXTitle:find("Auto Dark Mode") then
                      button = getc(c, AX.Group, 2, AX.PopupButton, 1)
                    end
                  end
                else
                  list = tfind(getc(webarea, AX.Group, 4).AXChildren,
                    function(elem)
                      return elem.AXSubrole == "AXTabPanel"
                    end)
                  if list == nil then
                    list = tfind(webarea.AXChildren, function(elem)
                      return elem.AXSubrole == "AXTabPanel"
                    end)
                  end
                  for c = 1, #list / 4 do
                    if list[c*4-3].AXTitle:find("Auto Dark Mode") then
                      button = getc(list[c * 4], AX.PopupButton, 1)
                    end
                  end
                end
                leftClickAndRestore(uicenter(button),
                    getMenuBarItems(app)[1].AXTitle)

                local darkMode = enableds[i] == 1 and "Enabled" or "Disabled"
                local menuItem = getc(winUI, AX.Group, 1, AX.Group, 1,
                    AX.Group, 1, AX.Group, 1, AX.Menu, 1, AX.MenuItem, darkMode)
                menuItem:performAction(AX.Press)
                local hotkey, observer
                hotkey = AppWinBind(app, {
                  mods = "⌘", key = "Return",
                  message = "Relaunch",
                  fn = function()
                    local button = getc(webarea, AX.Group, 4, AX.Group, -1,
                        AX.Group, 2, AX.Button, 1)
                    if button == nil then
                      button = getc(webarea, AX.Group, 7, AX.Button, 1)
                    end
                    leftClickAndRestore(uicenter(button),
                        getMenuBarItems(app)[1].AXTitle)
                    if hotkey ~= nil then
                      hotkey:delete()
                      hotkey = nil
                    end
                    if observer ~= nil then
                      observer:stop()
                      observer = nil
                    end
                  end,
                })
                observer = uiobserver.new(app:pid())
                observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
                observer:addWatcher(winUI, uinotifications.titleChanged)
                observer:addWatcher(appUI, uinotifications.applicationDeactivated)
                observer:callback(function()
                  local frontWinBundleID = hs.window.frontmostWindow()
                      :application():bundleID()
                  local ok, url = hs.osascript.applescript(strfmt([[
                    tell application id "%s" to get URL of active tab of front window
                  ]], appid))
                  if frontWinBundleID ~= appid or not ok
                      or url ~= scheme .. "://flags/#enable-force-dark" then
                    if hotkey ~= nil then
                      hotkey:delete()
                      hotkey = nil
                    end
                    if observer ~= nil then
                      observer:stop()
                      observer = nil
                    end
                  end
                end)
                observer:start()
              end
            end
          end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
    for i=4,#cbs do
      if i - 3 > 10 then break end
      local _, nameIdx = cbIdents[i]:find("device-", 1, true)
      local device = cbIdents[i]:sub(nameIdx + 1, -1)
      local msg
      if result[2][i] == 0 then
        msg = "Connect to " .. device
      else
        msg = "Disconnect to " .. device
      end
      local hotkey = newControlCenter("⌘", tostring((i-3)%10), msg,
        function()
          local cb = getc(area, AX.CheckBox, i)
          if cb then cb:performAction(AX.Press) end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  elseif panel == "Music Recognition" then
    local hotkey = newControlCenter("", "Space", "Toggle Listening",
      function()
        local cb = getc(paneUI, AX.Group, 1, AX.CheckBox, 1)
        if cb then cb:performAction(AX.Press) end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end
  elseif panel == "Hearing" then
    local hearingFunc
    hearingFunc = function()
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      for _, hotkey in ipairs(backgroundSoundsHotkeys or {}) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
      local slid
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        slid = getc(paneUI, AX.Slider, 1)
      until slid or totalDelay > 1 or not paneUI:isValid()
      if slid == nil then
        local triangle = getc(paneUI, AX.DisclosureTriangle, 1)
        if triangle == nil then
          return
        end
      end

      local actionFunc
      local triangle = getc(paneUI, AX.DisclosureTriangle, 1)
      if triangle then
        actionFunc = function()
          local actions = triangle:actionNames()
          triangle:performAction(actions[2])
          hearingFunc()
        end
      else
        triangle = getc(paneUI, AX.DisclosureTriangle, 1)
        actionFunc = function()
          local actions = triangle:actionNames()
          triangle:performAction(actions[1])
          hearingFunc()
        end
      end
      registerHotkeyForTraingleDisclosure(actionFunc, "Sounds",
                                          slid and 1 or 0)
      if slid == nil then return end

      local sliders = getc(paneUI, AX.Slider)
          or getc(paneUI, AX.Slider)
      local enabledSliders = tifilter(sliders,
          function(slid) return slid.AXEnabled end)
      if #enabledSliders == 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        local actions = {{ '=', 'Up'}, {'-', 'Down'}, {'[', 'Min'}, {']', 'Max'}}
        for _, spec in pairs(actions) do
          local key = spec[1]
          local slid = enabledSliders[1]
          local hotkey = newControlCenter("", key, "Volume " .. spec[2],
            function()
              if key == '=' then
                slid:performAction(AX.Increment)
              elseif key == '-' then
                slid:performAction(AX.Decrement)
              elseif key == '[' then
                slid.AXValue = 0
              else
                slid.AXValue = 100
              end
            end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end

      local cbs
      repeat
        hs.timer.usleep(0.05 * 1000000)
        cbs = getc(paneUI, AX.CheckBox)
        if cbs == nil then
          cbs = tifilter(getc(paneUI, AX.CheckBox) or {}, function(cb)
            return cb.AXIdentifier and cb.AXIdentifier:find("button%-identifier") end)
        end
      until #cbs > 0
      if #cbs > 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        for i=1,#cbs do
          local msg
          if cbs[i].AXIdentifier ~= nil then
            local name = cbs[i].AXIdentifier:match("hearing%-(.+)%-button%-identifier")
            if name then
              msg = "Play " .. name
            end
          end
          if msg == nil then
            msg = "Play No." .. i .. " Sound"
          end
          local hotkey = newControlCenter("", tostring(i % 10), msg,
              function() cbs[i]:performAction(AX.Press) end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end
    end

    local hotkey = newControlCenter("", "Space",
      "Toggle " .. mayLocalize("Background Sounds"),
      function()
        backgroundSoundsHotkeys = nil
        local cb = getc(paneUI, AX.DisclosureTriangle, 1)
            or getc(paneUI, AX.CheckBox, 1)
        if cb then
          cb:performAction(AX.Press)
          hearingFunc()
        end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end

    hearingFunc()
  elseif panel == "Now Playing" then
    local result
    local button3
    repeat
      hs.timer.usleep(0.05 * 1000000)
      button3 = getc(paneUI, AX.Button, 3)
    until button3 or not paneUI:isValid()
    if button3 then
      if OS_VERSION < OS.Ventura then
        result = hs.fnutils.map(getc(paneUI, AX.Button),
            function(bt) return bt.AXTitle end)
      else
        result = #getc(paneUI, AX.Button)
      end
      if (type(result) == "number" and result == 3)
          or (type(result) == "table" and #result == 3) then
        if result == 3 then
          result = {
            mayLocalize("previous"),
            mayLocalize("play") .. "/" .. mayLocalize("pause"),
            mayLocalize("next")
          }
        end
        local hotkey
        hotkey = newControlCenter("", "Space", result[2],
          function()
            if defaultMusicAppForControlCenter ~= nil then
              local appname = displayName('com.apple.Music')
              local appTitle = getc(paneUI, AX.StaticText, 1)
              if appTitle and appTitle.AXValue == appname .. '.app' then
                if type(defaultMusicAppForControlCenter) == 'string' then
                  defaultMusicAppForControlCenter =
                      { defaultMusicAppForControlCenter }
                end
                for _, appid in ipairs(defaultMusicAppForControlCenter) do
                  local appPath = hs.application.pathForBundleID(appid)
                  if appPath ~= nil and appPath ~= "" then
                    hs.application.launchOrFocusByBundleID(appid)
                    return
                  end
                end
              end
            end
            local button = getc(paneUI, AX.Button, 2)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
        hotkey = newControlCenter("", "Left", result[1],
          function()
            local button = getc(paneUI, AX.Button, 1)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
        hotkey = newControlCenter("", "Right", result[3],
          function()
            local button = getc(paneUI, AX.Button, 3)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      elseif (type(result) == "number" and result > 3)
          or (type(result) == "table" and #result > 3) then
        local nEntries
        if type(result) == "number" then
          nEntries = result / 2
        else
          nEntries = #result / 2
        end
        local hotkey
        for i = 1, nEntries do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          hotkey = newControlCenter("", tostring(i),
            type(result) == "number" and buttonLabel or result[2*i-1],
            function()
              local button = getc(paneUI, AX.Button, 2 * i - 1)
              if button then button:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      end
    end
  end
end

local controlCenterPanelConfigs = KeybindingConfigs.hotkeys.controlcenter
local localizedControlCenter = find("com.apple.controlcenter"):name()
for panel, spec in pairs(controlCenterPanelConfigs) do
  local localizedPanel = controlCenterLocalized(panel)
  bindControlCenter(spec, localizedControlCenter .. " > " .. localizedPanel,
      bind(popupControlCenterSubPanel, panel))
end

local function getActiveControlCenterPanel()
  local pane =
      (OS_VERSION < OS.Ventura and "window 1" or "group 1 of window 1")
      .. ' of application process "ControlCenter"'

  local function mayLocalize(value)
    return controlCenterLocalized("Now Playing", value)
  end

  local alreadyTemplate = [[
    repeat with ele in (every %s of pane)
      if (exists attribute "AXIdentifier" of ele) ¬
          and (the value of attribute "AXIdentifier" ¬
               of ele contains "%s") then
        return "%s"
      end if
    end repeat
  ]]
  local script = [[
    tell application "System Events"
      set pane to ]]..pane..[[ 
  ]]
  for panel, ident in pairs(controlCenterSubPanelIdentifiers) do
    local already = nil
    if tcontain({ "Wi‑Fi", "Focus", "Bluetooth", "AirDrop",
          "Keyboard Brightness", "Screen Mirroring",
          "Accessibility Shortcuts", "Battery" }, panel) then
      already = strfmt(alreadyTemplate, "static text", ident, panel)
    elseif panel == "Display" then
      already = [[
        if exists scroll area 1 of pane then
      ]] .. strfmt(alreadyTemplate,
            "slider of scroll area 1", ident, panel) .. [[ 
        end if
      ]]
    elseif panel == "Sound" then
      already = strfmt(alreadyTemplate, "slider", ident, panel)
    elseif panel == "Music Recognition" then
      already = strfmt(alreadyTemplate, "group", ident, panel)
    elseif panel == "Hearing" then
      already = [[
        if value of attribute "AXRole" of ui element 1 of pane is "AXScrollArea" then
      ]] .. strfmt(alreadyTemplate, "static text of scroll area 1 ",
                   controlCenterMenuBarItemIdentifiers[panel], panel) .. [[ 
        else
      ]] .. strfmt(alreadyTemplate, "static text ",
                   controlCenterMenuBarItemIdentifiers[panel], panel) .. [[ 
        end if
      ]]
    end
    if already then
      script = script .. [[
        ]] .. already .. [[
      ]]
    end
  end
  local already
  if OS_VERSION < OS.Ventura then
    already = [[
      if (exists button "]] .. mayLocalize("rewind") .. [[" of pane) or  ¬
          (exists button "]] .. mayLocalize("previous") .. [[" of pane) or ¬
          (number of (buttons of pane whose title ¬
              is "]] .. mayLocalize("play") .. [[" ¬
              or title is "]] .. mayLocalize("pause") .. [[") > 1) then
        return "Now Playing"
      end if
    ]]
  else
    already = [[
      if ((exists image of pane) and ¬
          (number of buttons of pane > 2)) then
        return "Now Playing"
      end if
    ]]
  end
  script = script .. [[
    ]] .. already .. [[
  ]]

  script = script .. [[
    end tell
  ]]
  local ok, panel = hs.osascript.applescript(script)
  return panel
end

if hs.window.focusedWindow() ~= nil
    and hs.window.focusedWindow():application():bundleID()
        == "com.apple.controlcenter"
    and hs.window.focusedWindow():subrole()
        == AX.SystemDialog then
  registerControlCenterHotKeys(getActiveControlCenterPanel())
end

local tapperForExtraInfo
local controlCenterPanelHotKeys = {}
local controlCenter = find("com.apple.controlcenter")
ControlCenterObserver = uiobserver.new(controlCenter:pid())
ControlCenterObserver:addWatcher(
  toappui(controlCenter),
  uinotifications.windowCreated
)
local function controlCenterObserverCallback()
  for panel, spec in pairs(controlCenterPanelConfigs) do
    local localizedPanel = controlCenterLocalized(panel)
    local hotkey = bindControlCenter({ mods = "", key = spec.key },
        localizedControlCenter .. " > " .. localizedPanel,
        bind(popupControlCenterSubPanel, panel))
    tinsert(controlCenterPanelHotKeys, hotkey)
    local timeTapperForExtraInfo = os.time()
    tapperForExtraInfo = hs.eventtap.new(
      {hs.eventtap.event.types.flagsChanged},
      function(event)
        if event:getFlags():containExactly({"alt"})
            and os.time() - timeTapperForExtraInfo > 2 then
          timeTapperForExtraInfo = os.time()
          local panel = getActiveControlCenterPanel()
          if panel == "Wi‑Fi" or panel == "Bluetooth" then
            popupControlCenterSubPanel(panel, true)
          end
        end
        return false
      end):start()
  end
  local controlCenterDestroyObserver =
      uiobserver.new(controlCenter:pid())
  controlCenterDestroyObserver:addWatcher(
    towinui(controlCenter:focusedWindow()),
    uinotifications.uIElementDestroyed
  )
  controlCenterDestroyObserver:callback(function()
    tapperForExtraInfo:stop()
    tapperForExtraInfo = nil
    for _, hotkey in ipairs(controlCenterPanelHotKeys) do
      hotkey:delete()
    end
    controlCenterPanelHotKeys = {}
    if selectNetworkWatcher ~= nil then
      StopExecContinuously(selectNetworkWatcher)
      selectNetworkWatcher = nil
    end
    if selectNetworkHotkeys ~= nil then
      for _, hotkey in ipairs(selectNetworkHotkeys) do
        hotkey:delete()
      end
      selectNetworkHotkeys = nil
    end
    if controlCenterHotKeys ~= nil then
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = nil
    end
    hotkeyMainBack = nil
    hotkeyMainForward = nil
    if hotkeyShow ~= nil then
      hotkeyShow:delete()
      hotkeyShow = nil
    end
    if hotkeyHide ~= nil then
      hotkeyHide:delete()
      hotkeyHide = nil
    end
    if backgroundSoundsHotkeys ~= nil then
      for _, hotkey in ipairs(backgroundSoundsHotkeys) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
    end
    controlCenterDestroyObserver:stop()
    controlCenterDestroyObserver = nil
  end)
  controlCenterDestroyObserver:start()
end
ControlCenterObserver:callback(controlCenterObserverCallback)
ControlCenterObserver:start()
ExecContinuously(function()
  if not controlCenter:isRunning() then
    hs.timer.doAfter(2, function()
      ControlCenterObserver:stop()
      controlCenter = find("com.apple.controlcenter")
      ControlCenterObserver = uiobserver.new(controlCenter:pid())
      ControlCenterObserver:addWatcher(
        toappui(controlCenter),
        uinotifications.windowCreated)
      ControlCenterObserver:callback(controlCenterObserverCallback)
      ControlCenterObserver:start()
    end)
  end
end)

-- # callbacks

-- application event callbacks
function System_applicationCallback(appname, eventType, app)
  if eventType == hs.application.watcher.deactivated then
    if appname == nil and getCurNetworkService() ~= nil then
      local enabledProxy = parseProxyInfo(proxy_info(), false)
      for _, proxyApp in ipairs(proxyMenuItemCandidates) do
        if enabledProxy == proxyApp.appname then
          local appid = proxyAppBundleIDs[enabledProxy]
          if find(appid) == nil then
            disable_proxy()
          end
          break
        end
      end
    end
  end
end

-- application installation/uninstallation callbacks
function System_applicationInstalledCallback(files, flagTables)
  for i=1,#files do
    if files[i]:match("V2RayX")
      or files[i]:match("V2rayU")
      or files[i]:match("MonoProxyMac") then
      if flagTables[i].itemCreated
          or flagTables[i].itemRemoved then
        registerProxyMenu(true)
      end
    end
  end
end

-- monitor callbacks

local builtinMonitor = "Built-in Retina Display"

function System_monitorChangedCallback()
  local screens = hs.screen.allScreens()

  -- only for built-in monitor
  local builtinMonitorEnable = hs.fnutils.some(screens,
    function(screen)
      return screen:name() == builtinMonitor
    end)

  -- for external monitors
  if (builtinMonitorEnable and #screens > 1)
    or (not builtinMonitorEnable and #screens > 0) then
    hs.caffeinate.set("displayIdle", true)
    caffeine:setTitle("AWAKE")
  elseif builtinMonitorEnable and #screens == 1 then
    hs.caffeinate.set("displayIdle", false)
    caffeine:setTitle("SLEEPY")
  end
end

function System_networkChangedCallback(storeObj, changedKeys)
  registerProxyMenuWrapper(storeObj, changedKeys)
end

-- battery callbacks

function System_batteryChangedCallback()
  local percent = hs.battery.percentage()
  if percent <= 10 then
    if not hs.battery.isCharging() then
      hs.alert.show("Battery is low, please charge your laptop!", 3)
    end

    if hs.caffeinate.get("displayIdle") then
      hs.caffeinate.set("displayIdle", false)
      caffeine:setTitle("SLEEPY")
    end
    if hs.caffeinate.get("systemIdle") then
      hs.caffeinate.set("systemIdle", false)
    end
  end
end
