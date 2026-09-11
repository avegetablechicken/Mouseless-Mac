-- Reproducible SVG masters, using only Lua. Rasterize at 192 x 192 for the chooser.
-- Usage: lua static/hotkeys/generate.lua OUTPUT_DIRECTORY
local output = assert(arg[1], "output directory required")
local blue, ink, paper = "#3485ff", "#17202c", "#f3f6fa"
local icons, parts = {}, {}
local function emit(s) parts[#parts + 1] = s end
local function rect(x, y, w, h, fill, stroke, radius, width)
  emit(string.format('<rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s" stroke="%s" stroke-width="%g"/>',
      x, y, w, h, radius or 0, fill or "none", stroke or "none", width or 3))
end
local function line(x1, y1, x2, y2, color, width)
  emit(string.format('<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="%g" stroke-linecap="round"/>',
      x1, y1, x2, y2, color or blue, width or 3))
end
local function arrow(x, y, dx, dy, length, color)
  local norm = math.sqrt(dx * dx + dy * dy)
  dx, dy = dx / norm, dy / norm
  local ex, ey = x + dx * length, y + dy * length
  line(x, y, ex, ey, color)
  line(ex, ey, ex - dx * 6 + dy * 5, ey - dy * 6 - dx * 5, color)
  line(ex, ey, ex - dx * 6 - dy * 5, ey - dy * 6 + dx * 5, color)
end
local function text(value, x, y, size, color)
  emit(string.format('<text x="%g" y="%g" font-family="Helvetica" font-weight="bold" font-size="%g" text-anchor="middle" fill="%s">%s</text>',
      x, y, size, color or ink, value))
end
local function window()
  rect(10, 12, 76, 72, paper, ink, 7)
end
local function tile(x, y, w, h)
  window()
  rect(14 + x * 68, 16 + y * 64, w * 68, h * 64, blue, nil, 2)
end
local function monitor(space)
  if space then rect(19, 8, 67, 66, "#dce5f1", ink, 5) end
  rect(12, 14, 72, space and 68 or 60, "#77b0ff", ink, 6, 4)
  if not space then
    rect(43, 76, 10, 8, ink)
    rect(30, 83, 36, 4, ink, nil, 2)
  end
end
local function save(label, draw)
  parts = {}
  draw()
  local slug = label:lower():gsub("[^%w]+", "-"):gsub("-$", "")
  local file = assert(io.open(output .. "/" .. slug .. ".svg", "w"))
  file:write('<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192" viewBox="0 0 96 96">', table.concat(parts), '</svg>')
  file:close()
  icons[#icons + 1] = { label = label, slug = slug }
end
local directions = {
  {"Top-Left", -1, -1}, {"Top", 0, -1}, {"Top-Right", 1, -1},
  {"Left", -1, 0}, {"Right", 1, 0},
  {"Bottom-Left", -1, 1}, {"Bottom", 0, 1}, {"Bottom-Right", 1, 1},
}
for _, d in ipairs(directions) do
  save("Move to " .. d[1], function()
    window()
    rect(34 + d[2] * 19, 34 + d[3] * 17, 28, 28, blue, nil, 3)
  end)
  save("Move towards " .. d[1], function()
    window()
    arrow(48 - d[2] * 10, 48 - d[3] * 9, d[2], d[3], 23)
  end)
end
local tiles = {
  {"Left Half", 0, 0, .5, 1}, {"Right Half", .5, 0, .5, 1},
  {"Top Half", 0, 0, 1, .5}, {"Bottom Half", 0, .5, 1, .5},
  {"Top-Left", 0, 0, .5, .5}, {"Top-Right", .5, 0, .5, .5},
  {"Bottom-Left", 0, .5, .5, .5}, {"Bottom-Right", .5, .5, .5, .5},
  {"Left 1/3", 0, 0, 1/3, 1}, {"Right 1/3", 2/3, 0, 1/3, 1},
  {"Left 2/3", 0, 0, 2/3, 1}, {"Right 2/3", 1/3, 0, 2/3, 1},
}
for _, t in ipairs(tiles) do
  save("Zoom to " .. t[1], function() tile(t[2], t[3], t[4], t[5]) end)
end
save("Center", function() window(); rect(33, 33, 30, 30, blue, nil, 3) end)
save("Fill", function() tile(0, 0, 1, 1) end)
for _, d in ipairs({{"Left", -1, 0}, {"Right", 1, 0}, {"Top", 0, -1}, {"Bottom", 0, 1}}) do
  for _, mode in ipairs({"Expand", "Shrink"}) do
    save(mode .. " " .. d[1] .. " Border", function()
      window()
      if d[2] ~= 0 then line(48 + d[2] * 36, 18, 48 + d[2] * 36, 78, blue, 4)
      else line(17, 48 + d[3] * 34, 79, 48 + d[3] * 34, blue, 4) end
      local sign = mode == "Expand" and 1 or -1
      arrow(48 + d[2] * (sign == 1 and 0 or 22), 48 + d[3] * (sign == 1 and 0 or 22),
          sign * d[2], sign * d[3], 22)
    end)
  end
end
for _, target in ipairs({"Monitor", "Space"}) do
  for _, d in ipairs({{"Previous", -1}, {"Next", 1}}) do
    save("Move to " .. d[1] .. " " .. target, function()
      monitor(target == "Space")
      arrow(48 - d[2] * 13, 45, d[2], 0, 26, ink)
    end)
  end
  for i = 1, 9 do
    save("Move to " .. target .. " " .. i, function()
      monitor(target == "Space")
      rect(35, 31, 26, 28, paper, ink, 13, 2)
      text(i, 48, 53, 22)
    end)
  end
end
local function focusMark()
  -- Four corner brackets distinguish focusing a screen from moving a window.
  for _, d in ipairs({{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) do
    local x, y = 48 + d[1] * 27, 45 + d[2] * 16
    line(x, y, x - d[1] * 7, y, ink, 2)
    line(x, y, x, y - d[2] * 6, ink, 2)
  end
end
for i = 1, 9 do
  save("Focus on Monitor " .. i, function() monitor(); focusMark(); text(i, 48, 53, 22) end)
end
for _, d in ipairs({{"Previous", -1}, {"Next", 1}}) do
  save("Focus on " .. d[1] .. " Screen", function()
    monitor(); focusMark(); arrow(48 - d[2] * 9, 45, d[2], 0, 18, ink)
  end)
end
-- Reference-sheet operations; available even when no matching shortcut is bound.
save("Move to Main Screen", function() monitor(); text("1", 48, 52, 22); line(27, 60, 69, 60, ink, 3) end)
save("Move to Full Screen on This Display", function()
  monitor()
  arrow(39, 45, -1, -1, 13, ink); arrow(57, 45, 1, 1, 13, ink)
end)
save("Shrink Window Border", function()
  window(); arrow(24, 48, 1, 0, 15); arrow(72, 48, -1, 0, 15)
end)
save("Expand Window Border", function()
  window()
  for _, d in ipairs({{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) do
    arrow(48 + d[1] * 12, 48 + d[2] * 7, d[1], d[2], 12)
  end
end)
-- Missing global operations and category fallbacks use the same geometry.
local function search(x, y)
  rect(x - 10, y - 10, 20, 20, paper, blue, 10, 4)
  line(x + 8, y + 8, x + 19, y + 19, blue, 5)
end
local function browser()
  window()
  line(12, 28, 84, 28, ink, 2)
  rect(18, 18, 5, 5, blue, nil, 2)
  rect(28, 18, 5, 5, blue, nil, 2)
end
for _, target in ipairs({"Window", "Browser Window"}) do
  for _, d in ipairs({{"Previous", -1}, {"Next", 1}}) do
    save(d[1] .. " " .. target, function()
      rect(19, 7, 67, 67, "#dce5f1", ink, 6)
      if target == "Window" then window() else browser() end
      arrow(48 - d[2] * 12, target == "Window" and 48 or 53, d[2], 0, 24)
    end)
  end
end
save("Switch to Window", function()
  rect(19, 7, 67, 67, "#dce5f1", ink, 6); window(); search(47, 47)
end)
save("Switch to Tab", function() browser(); search(47, 53) end)
save("Show Info of Current Window", function()
  window(); rect(35, 34, 26, 28, blue, nil, 13); text("i", 48, 55, 23, paper)
end)
local function menu()
  window()
  rect(14, 16, 68, 12, blue, nil, 2)
  for x = 51, 75, 12 do rect(x, 20, 5, 4, paper, nil, 1) end
end
save("Search Menu Bar", function() menu(); search(47, 51) end)
save("Show Proxy Menu", function()
  rect(35, 35, 26, 26, blue, ink, 5)
  for _, p in ipairs({{21, 22}, {75, 22}, {21, 74}, {75, 74}}) do
    line(48, 48, p[1], p[2], ink, 3)
    rect(p[1] - 6, p[2] - 6, 12, 12, paper, ink, 3)
  end
  rect(37, 37, 22, 22, blue, nil, 4)
end)
local function stage(index)
  for y = 14, 66, 26 do rect(10, y, 17, 17, paper, ink, 3, 2) end
  rect(34, 14, 52, 69, "#77b0ff", ink, 6)
  if index then text(index, 60, 57, 25) end
end
save("Stage Manager", function() stage() end)
for i = 1, 9 do save("Stage Manager Window " .. i, function() stage(i) end) end
save("Window", window)
save("Display", function() monitor() end)
save("Menu Bar", menu)
save("Navigation", function()
  rect(12, 12, 72, 72, paper, ink, 7)
  line(48, 27, 48, 69, "#aab7c8", 2)
  line(26, 48, 70, 48, "#aab7c8", 2)
  arrow(34, 62, 1, -1, 34)
end)
save("Application", function()
  rect(12, 12, 72, 72, paper, ink, 12)
  for _, p in ipairs({{29, 29}, {52, 29}, {29, 52}, {52, 52}}) do
    rect(p[1], p[2], 15, 15, blue, nil, 3)
  end
end)
save("Background Action", function()
  rect(23, 10, 61, 64, "#dce5f1", ink, 6)
  rect(12, 22, 61, 64, paper, ink, 6)
  arrow(26, 55, 1, 0, 28)
  line(39, 42, 54, 55, blue, 3)
end)
save("Hotkey", function()
  rect(13, 12, 70, 72, paper, ink, 7)
  for y = 22, 50, 14 do
    for x = 22, 64, 14 do rect(x, y, 10, 10, blue, nil, 2) end
  end
  rect(22, 66, 52, 9, blue, nil, 2)
end)
save("Toggle Hotkeys", function()
  rect(12, 12, 72, 32, blue, ink, 16)
  rect(56, 16, 24, 24, paper, nil, 12)
  rect(12, 52, 72, 32, paper, ink, 16)
  rect(16, 56, 24, 24, "#aab7c8", nil, 12)
end)
save("Reload Hammerspoon", function()
  window()
  line(30, 44, 30, 37, blue, 3); line(30, 37, 64, 37, blue, 3)
  arrow(64, 37, 0, 1, 14)
  line(66, 54, 66, 61, blue, 3); line(66, 61, 32, 61, blue, 3)
  arrow(32, 61, 0, -1, 14)
end)
save("Toggle Hammerspoon Console", function()
  browser()
  line(23, 44, 33, 52, blue, 3); line(33, 52, 23, 60, blue, 3)
  line(43, 60, 61, 60, ink, 3)
end)
save("Show Keybindings", function()
  rect(13, 12, 70, 72, paper, ink, 7)
  for y = 26, 62, 18 do
    rect(27, y, 14, 12, blue, nil, 2)
    line(49, y + 6, 68, y + 6, ink, 3)
  end
end)
save("Search Hotkey", function()
  rect(13, 12, 70, 72, paper, ink, 7)
  for x = 22, 64, 14 do rect(x, 22, 10, 10, blue, nil, 2) end
  for x = 22, 36, 14 do rect(x, 39, 10, 10, blue, nil, 2) end
  rect(22, 66, 18, 9, blue, nil, 2)
  search(56, 55)
end)
local manifest = assert(io.open(output .. "/manifest.tsv", "w"))
for _, icon in ipairs(icons) do manifest:write(icon.slug, "\t", icon.label, "\n") end
manifest:close()
print(string.format("Generated %d SVG masters in %s", #icons, output))
