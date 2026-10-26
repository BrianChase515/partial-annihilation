-- Player settings: window size, camera speeds, volumes. Saved to settings.lua in the save
-- folder and applied at launch. (The mouse pointer's own speed belongs to the OS / Steam Input.)
local Set = {}

Set.FILE = "settings.lua"
Set.v = { res = "Auto", pan = 1, zoom = 1, scroll = 1, edge = true, music = 0.55, sfx = 0.5, padCursor = 1, padHints = true, cohAI = "classic", annAI = "classic", legacyAI = false }

Set.RES = { "Auto", "1280x720", "1280x800", "1440x900", "1600x900", "1920x1080", "2560x1440", "Fullscreen" }

local function ser(t)
  local out = {}
  for k, v in pairs(t) do
    out[#out + 1] = string.format("[%q]=%s", k, type(v) == "string" and string.format("%q", v) or tostring(v))
  end
  return "return {" .. table.concat(out, ",") .. "}"
end

function Set.load()
  local ok, chunk = pcall(love.filesystem.load, Set.FILE)
  if ok and chunk then
    local ok2, t = pcall(chunk)
    if ok2 and type(t) == "table" then
      for k, v in pairs(t) do if Set.v[k] ~= nil and type(v) == type(Set.v[k]) then Set.v[k] = v end end
    end
  end
end

function Set.save() pcall(love.filesystem.write, Set.FILE, ser(Set.v)) end

-- sizes this screen can show in a window
function Set.resList()
  local dw, dh = love.window.getDesktopDimensions()
  local out = {}
  for _, r in ipairs(Set.RES) do
    local w, h = r:match("(%d+)x(%d+)")
    if not w or (tonumber(w) <= (dw or 99999) and tonumber(h) <= (dh or 99999)) then out[#out + 1] = r end
  end
  return out
end

function Set.applyWindow()
  local r = Set.v.res
  if love.system.getOS() == "Web" or r == "Auto" then return end
  if r == "Fullscreen" then
    love.window.setFullscreen(true, "desktop")
    return
  end
  local w, h = r:match("(%d+)x(%d+)")
  if w then
    local _, _, flags = love.window.getMode()
    flags.fullscreen = false
    love.window.setMode(tonumber(w), tonumber(h), flags)
  end
end

function Set.applySound()
  require("src.music").volume = Set.v.music
  require("src.sfx").volume = Set.v.sfx
end

---------------------------------------------------------------------------
-- The panel (shared by the title screen and the pause menu)

local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

local ROWS = {
  { key = "res", label = "Window", show = function(v) return v end },
  { key = "pan", label = "Camera scroll speed (arrows, screen edge)", min = 0.5, max = 2.5, step = 0.25, show = pct },
  { key = "zoom", label = "Zoom speed (mouse wheel)", min = 0.5, max = 2, step = 0.25, show = pct },
  { key = "scroll", label = "Trackpad pan speed (Option/Alt + two-finger scroll)", min = 0.5, max = 3, step = 0.25, show = pct },
  { key = "edge", label = "Edge scrolling", show = function(v) return v and "On" or "Off" end },
  { key = "music", label = "Music volume", min = 0, max = 1, step = 0.1, show = pct },
  { key = "sfx", label = "Effects volume", min = 0, max = 1, step = 0.1, show = pct },
  { key = "padCursor", label = "Controller cursor speed (left stick)", min = 0.5, max = 2.5, step = 0.25, show = pct },
  { key = "padHints", label = "Controller button hints", show = function(v) return v and "On" or "Off" end },
}

function Set.rects()
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local pw, ph = 640, 120 + #ROWS * 44 + 70
  local x, y = (w - pw) / 2, (h - ph) / 2
  local r = { panel = { x = x, y = y, w = pw, h = ph }, rows = {} }
  for i, row in ipairs(ROWS) do
    local yy = y + 64 + (i - 1) * 44
    r.rows[i] = { row = row, y = yy,
      minus = { x = x + pw - 230, y = yy, w = 34, h = 32 },
      val = { x = x + pw - 192, y = yy, w = 138, h = 32 },
      plus = { x = x + pw - 50, y = yy, w = 34, h = 32 } }
  end
  r.close = { x = x + pw / 2 - 90, y = y + ph - 56, w = 180, h = 40 }
  return r
end

function Set.draw()
  local lg = love.graphics
  local R = require("src.render")
  local w, h = lg.getDimensions()
  lg.setColor(0, 0, 0, 0.6)
  lg.rectangle("fill", 0, 0, w, h)
  local rr = Set.rects()
  local p = rr.panel
  lg.setColor(0.06, 0.08, 0.11, 0.98)
  lg.rectangle("fill", p.x, p.y, p.w, p.h, 10)
  lg.setColor(0.35, 0.45, 0.58)
  lg.rectangle("line", p.x + 0.5, p.y + 0.5, p.w - 1, p.h - 1, 10)
  lg.setFont(R.font(22))
  lg.setColor(1, 1, 1)
  lg.print("Settings", p.x + 20, p.y + 16)
  local mx, my = love.mouse.getPosition()
  local function btn(b, label, active)
    local hov = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    lg.setColor(active and 0.2 or (hov and 0.22 or 0.14), active and 0.45 or (hov and 0.3 or 0.2), active and 0.65 or (hov and 0.4 or 0.27))
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
    lg.setColor(0.4, 0.55, 0.7)
    lg.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, 6)
    lg.setFont(R.font(14))
    lg.setColor(1, 1, 1)
    lg.print(label, b.x + b.w / 2 - R.font(14):getWidth(label) / 2, b.y + b.h / 2 - 9)
  end
  for _, rw in ipairs(rr.rows) do
    lg.setFont(R.font(14))
    lg.setColor(0.82, 0.86, 0.92)
    lg.print(rw.row.label, p.x + 20, rw.y + 7)
    btn(rw.minus, "<")
    btn(rw.val, rw.row.show(Set.v[rw.row.key]))
    btn(rw.plus, ">")
  end
  lg.setFont(R.font(12))
  lg.setColor(0.55, 0.62, 0.7)
  lg.printf("The pointer's own speed is set by your system: macOS System Settings > Mouse / Trackpad; "
    .. "Steam Deck: the controller settings for this game in Steam.", p.x + 20, rr.close.y - 42, p.w - 40)
  btn(rr.close, "Done")
end

-- true when the click was the panel's; sets Set.open = false on Done / outside
function Set.click(x, y, b)
  local rr = Set.rects()
  local function inb(q) return x >= q.x and x <= q.x + q.w and y >= q.y and y <= q.y + q.h end
  if inb(rr.close) then Set.open = false; Set.save(); return true end
  local p = rr.panel
  if not inb(p) then Set.open = false; Set.save(); return true end
  for _, rw in ipairs(rr.rows) do
    local d = inb(rw.minus) and -1 or ((inb(rw.plus) or inb(rw.val)) and (b == 2 and -1 or 1)) or nil
    if d then
      local row, k = rw.row, rw.row.key
      if k == "res" then
        local list = Set.resList()
        local i = 1
        for j, r in ipairs(list) do if r == Set.v.res then i = j end end
        Set.v.res = list[(i - 1 + d) % #list + 1]
        if Set.v.res ~= "Fullscreen" and love.window.getFullscreen() and Set.v.res ~= "Auto" then love.window.setFullscreen(false) end
        Set.applyWindow()
        if Set.onWindow then Set.onWindow() end
      elseif k == "annAI" then
        Set.v.annAI = Set.v.annAI == "v2" and "classic" or "v2"
      elseif k == "cohAI" then
        Set.v.cohAI = Set.v.cohAI == "v2" and "classic" or "v2"
      elseif k == "padHints" then
        Set.v.padHints = not Set.v.padHints
      elseif k == "edge" then
        Set.v.edge = not Set.v.edge
        if Set.onEdge then Set.onEdge(Set.v.edge) end
      else
        Set.v[k] = math.max(row.min, math.min(row.max, math.floor((Set.v[k] + d * row.step) * 100 + 0.5) / 100))
        Set.applySound()
      end
      Set.save()
      return true
    end
  end
  return true
end

return Set
