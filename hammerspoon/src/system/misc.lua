-- Caffeine menubar.
--
-- Provides a simple menubar toggle to control display sleep state
-- via hs.caffeinate.
local caffeine = hs.menubar.new(true, "CAFFEINE")

-- Update caffeine menubar title according to display sleep state
local function setCaffeineDisplay(state)
  if state then
    caffeine:setTitle("AWAKE")
  else
    caffeine:setTitle("SLEEPY")
  end
end

-- Toggle display idle sleep and update caffeine menubar
local function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end

local builtinMonitor = "Built-in Retina Display"

function SystemMisc_monitorChangedCallback()
  local screens = hs.screen.allScreens()
  local builtinMonitorEnable = any(screens, function(screen)
    return screen:name() == builtinMonitor
  end)

  if (builtinMonitorEnable and #screens > 1)
      or (not builtinMonitorEnable and #screens > 0) then
    hs.caffeinate.set("displayIdle", true)
    setCaffeineDisplay(true)
  elseif builtinMonitorEnable and #screens == 1 then
    hs.caffeinate.set("displayIdle", false)
    setCaffeineDisplay(false)
  end
end

function SystemMisc_batteryChangedCallback()
  local percent = hs.battery.percentage()
  if percent <= 10 then
    if not hs.battery.isCharging() then
      hs.alert.show("Battery is low, please charge your laptop!", 3)
    end

    if hs.caffeinate.get("displayIdle") then
      hs.caffeinate.set("displayIdle", false)
      setCaffeineDisplay(false)
    end
    if hs.caffeinate.get("systemIdle") then
      hs.caffeinate.set("systemIdle", false)
    end
  end
end

SystemCaffeineMenubar = caffeine
SystemCaffeineClicked = caffeineClicked
