-- Native gamepad support (Xbox-style pads, the Steam Deck's built-in controls, PlayStation pads).
-- Purely additive: keyboard and mouse work exactly as before. The pad drives the real mouse
-- pointer (left stick), presses the same keys the game already listens for, and holds Shift /
-- Ctrl as virtual modifiers, so every existing code path just works. Each mode has its own
-- face-button scheme; hold Y for a command wheel with the rest.
--
--   Left stick  pointer            Right stick  pan camera       LT / RT  zoom out / in
--   A           left click (hold to box-select)   B  right click (orders)
--   LB / RB     hold = Shift / Ctrl (Arena: skills E / R)
--   D-pad       1-4 (groups / squads; with RB = save group, with LB = add)
--   Start       menu (Esc)       X, Y, View, L3, R3   per mode (see the hint bar)
--   Y (hold)    command wheel: tilt the left stick at an entry, let go of Y to use it
local P = { active = false, hints = {}, vheld = {}, vmouse = {} }

local DEAD = 0.18
local WHEEL_HOLD = 0.22

local ctx            -- { state = fn, game = fn }
local pad            -- the joystick in use
local cx, cy         -- pointer position (float)
local yDown, yT, wheel
local wheelPick

---------------------------------------------------------------------------
-- Virtual keys and buttons, seen by love.keyboard.isDown / love.mouse.isDown

function P.install(c)
  ctx = c
  if P.installed then return end
  P.installed = true
  local kd, md = love.keyboard.isDown, love.mouse.isDown
  love.keyboard.isDown = function(...)
    for i = 1, select("#", ...) do if P.vheld[select(i, ...)] then return true end end
    return kd(...)
  end
  love.mouse.isDown = function(...)
    for i = 1, select("#", ...) do if P.vmouse[select(i, ...)] then return true end end
    return md(...)
  end
end

local function game()
  local g = ctx and ctx.state() == "game" and ctx.game()
  return g or nil
end

local function cursor()
  if not cx then cx, cy = love.mouse.getPosition() end
  return cx, cy
end

local function tap(key, mods)
  for _, m in ipairs(mods or {}) do P.vheld[m] = true end
  love.keypressed(key, key, false)
  if love.keyreleased then love.keyreleased(key, key) end
  for _, m in ipairs(mods or {}) do P.vheld[m] = nil end
end

local function click(b, down)
  local x, y = cursor()
  if down then
    P.vmouse[b] = true
    love.mousepressed(x, y, b, false, 1)
  else
    P.vmouse[b] = nil
    love.mousereleased(x, y, b, false, 1)
  end
end

---------------------------------------------------------------------------
-- Schemes

local function fleeActive(g)
  local sq = g:activeSquad()
  if sq then g:fleeSquad(sq) else tap("f") end
end

local function modeOf(g)
  if not g then return "menu" end
  if g.world.squads then return "coh" end
  if g.arena then return "arena" end
  if g.craft then return "craft" end
  return "rts"
end

-- per mode: what X, Y (tap), View, L3, R3 do, the hint bar and the wheel
local SCHEMES = {
  rts = {
    x = { key = "a", label = "Attack-move" }, y = { key = "s", label = "Stop" },
    back = { key = "tab", label = "Idle builder" }, l3 = { key = "space", label = "Commander" },
    r3 = { key = "f", label = "Retreat" },
    wheel = {
      { label = "Attack-move", key = "a" }, { label = "Patrol", key = "p" }, { label = "Stop", key = "s" },
      { label = "Retreat", key = "f" }, { label = "Select army", key = "a", mods = { "lctrl" } },
      { label = "Idle builder", key = "tab" }, { label = "Repeat build", key = "g" }, { label = "Nuke", key = "n" },
      { label = "Build menu", key = "b" }, { label = "Speed +", key = "=" }, { label = "Speed -", key = "-" },
      { label = "Pause", key = "f3" },
    },
  },
  coh = {
    x = { key = "q", label = "Skill 1" }, y = { key = "w", label = "Skill 2" },
    back = { key = "c", label = "Next squad" }, l3 = { key = "5", label = "Squad 5" },
    r3 = { fn = fleeActive, label = "Flee squad" },
    wheel = {
      { label = "Attack-move", key = "a" }, { label = "Stop", key = "s" }, { label = "Flee squad", fn = fleeActive },
      { label = "Retreat all", key = "f" }, { label = "Squad 5", key = "5" }, { label = "Next squad", key = "c" },
      { label = "Jump to fight", key = "space" }, { label = "Speed +", key = "=" }, { label = "Speed -", key = "-" },
      { label = "Help", key = "f1" }, { label = "Pause", key = "f3" },
    },
  },
  arena = {
    x = { key = "q", label = "Skill Q" }, y = { key = "w", label = "Skill W" },
    lb = { key = "e", label = "Skill E" }, rb = { key = "r", label = "Skill R" },
    back = { key = "f", label = "Go home" }, l3 = { key = "space", label = "Center" },
    r3 = { key = "s", label = "Stop" },
    wheel = {
      { label = "Upgrade 1", key = "z" }, { label = "Upgrade 2", key = "x" }, { label = "Go home", key = "f" },
      { label = "Attack-move", key = "a" }, { label = "Stop", key = "s" }, { label = "Center", key = "space" },
      { label = "Help", key = "f1" }, { label = "Pause", key = "f3" },
    },
  },
  craft = {
    x = { key = "q", label = "Skill / slot 1" }, y = { key = "w", label = "Skill / slot 2" },
    back = { key = "tab", label = "Idle worker" }, l3 = { key = "c", label = "Next hero" },
    r3 = { key = "space", label = "Center" },
    wheel = {
      { label = "Skill / slot 3", key = "e" }, { label = "Skill / slot 4", key = "r" }, { label = "Slot 5", key = "t" },
      { label = "Train worker", key = "q", mods = { "lshift" } }, { label = "Attack-move", key = "a" },
      { label = "Stop", key = "s" }, { label = "Idle worker", key = "tab" }, { label = "Next hero", key = "c" },
      { label = "Speed +", key = "=" }, { label = "Speed -", key = "-" }, { label = "Pause", key = "f3" },
    },
  },
}
P.SCHEMES = SCHEMES

local function run(act, g)
  if not act then return end
  if act.fn then if g then act.fn(g) end
  else tap(act.key, act.mods) end
end

-- the game is showing a screen of its own (pause menu, settings, the result) - plain clicks there
local function overlay(g)
  return not g or g.menuOpen or g.naming or require("src.settings").open or (g.world.over and g.overShown)
end

---------------------------------------------------------------------------
-- Events

local DPAD = { dpup = "1", dpright = "2", dpdown = "3", dpleft = "4" }
local MENU_DPAD = { dpup = "up", dpright = "right", dpdown = "down", dpleft = "left" }

function P.pressed(j, b)
  pad = j
  P.active = true
  local g = game()
  local sch = SCHEMES[modeOf(g)]
  if b == "a" then return click(1, true) end
  if b == "b" then return click(2, true) end
  if b == "start" then return tap("escape") end
  if not g or overlay(g) then
    if b == "back" then return tap("escape") end
    if MENU_DPAD[b] then return tap(MENU_DPAD[b]) end
    return
  end
  if b == "leftshoulder" then
    if sch.lb then return run(sch.lb, g) end
    P.vheld.lshift = true; return
  end
  if b == "rightshoulder" then
    if sch.rb then return run(sch.rb, g) end
    P.vheld.lctrl = true; return
  end
  if DPAD[b] then return tap(DPAD[b]) end
  if b == "x" then return run(sch.x, g) end
  if b == "y" then yDown, yT, wheel, wheelPick = true, 0, false, nil; return end
  if b == "back" then return run(sch.back, g) end
  if b == "leftstick" then return run(sch.l3, g) end
  if b == "rightstick" then return run(sch.r3, g) end
end

function P.released(j, b)
  local g = game()
  if b == "a" and P.vmouse[1] then return click(1, false) end
  if b == "b" and P.vmouse[2] then return click(2, false) end
  if b == "leftshoulder" then P.vheld.lshift = nil end
  if b == "rightshoulder" then P.vheld.lctrl = nil end
  if b == "y" and yDown then
    yDown = false
    local sch = SCHEMES[modeOf(g)]
    if wheel then
      if wheelPick and sch.wheel[wheelPick] then run(sch.wheel[wheelPick], g) end
      wheel = false
    elseif g and not overlay(g) then
      run(sch.y, g)
    end
  end
end

function P.added(j)
  if j:isGamepad() and not pad then pad = j end
end

function P.removed(j)
  if j == pad then
    pad = nil
    P.vheld, P.vmouse, wheel, yDown = {}, {}, false, false
  end
end

---------------------------------------------------------------------------
-- Sticks and triggers

local function stick(ax, ay)
  local x, y = pad:getGamepadAxis(ax), pad:getGamepadAxis(ay)
  local m = math.sqrt(x * x + y * y)
  if m < DEAD then return 0, 0, 0 end
  local s = (math.min(1, m) - DEAD) / (1 - DEAD)
  return x / m * s, y / m * s, s
end

function P.update(dt)
  if not pad or not pad:isConnected() then
    pad = nil
    for _, j in ipairs(love.joystick and love.joystick.getJoysticks() or {}) do
      if j:isGamepad() then pad = j; break end
    end
    if not pad then return end
  end
  local g = game()
  local w, h = love.graphics.getDimensions()
  -- pointer: follow the real mouse when it moves (trackpad, mouse), else the left stick
  local mx, my = love.mouse.getPosition()
  if not cx or math.abs(mx - math.floor(cx + 0.5)) > 1 or math.abs(my - math.floor(cy + 0.5)) > 1 then cx, cy = mx, my end
  local lx, ly, lm = stick("leftx", "lefty")
  if yDown then
    yT = yT + dt
    if not wheel and yT >= WHEEL_HOLD and g and not overlay(g) then wheel = true end
  end
  if wheel then
    -- the left stick picks a wheel entry instead of moving the pointer
    local items = SCHEMES[modeOf(g)].wheel
    if lm > 0.5 then
      local a = math.atan2(lx, -ly) % (2 * math.pi)
      wheelPick = math.floor(a / (2 * math.pi) * #items + 0.5) % #items + 1
    end
  elseif lm > 0 then
    P.active = true
    local sp = 1100 * (h / 800) * require("src.settings").v.padCursor * (0.25 + 0.75 * lm * lm)
    cx = math.max(0, math.min(w - 1, cx + lx * sp * dt))
    cy = math.max(0, math.min(h - 1, cy + ly * sp * dt))
    love.mouse.setPosition(math.floor(cx + 0.5), math.floor(cy + 0.5))
    if love.mousemoved then love.mousemoved(cx, cy, lx * sp * dt, ly * sp * dt, false) end
  end
  if not g or overlay(g) or g.paused then return end
  -- camera: right stick pans, triggers zoom around the pointer
  local rx, ry, rm = stick("rightx", "righty")
  if rm > 0 then
    P.active = true
    local pan = 1300 / g.cam.zoom * dt * require("src.settings").v.pan
    g.follow = nil
    g.cam.x = g.cam.x + rx * pan
    g.cam.y = g.cam.y + ry * pan
    g:clampCam()
  end
  local zin, zout = pad:getGamepadAxis("triggerright"), pad:getGamepadAxis("triggerleft")
  local z = (zin > 0.1 and zin or 0) - (zout > 0.1 and zout or 0)
  if z ~= 0 then
    P.active = true
    g:zoomAt(cx, cy, math.exp(z * dt * 1.8 * require("src.settings").v.zoom))
  end
end

---------------------------------------------------------------------------
-- Drawing: the hint bar and the wheel

local COL = { a = { 0.3, 0.75, 0.3 }, b = { 0.85, 0.3, 0.28 }, x = { 0.3, 0.5, 0.9 }, y = { 0.9, 0.75, 0.2 } }

local function glyph(lg, R, name, x, y)
  local f = R.font(11)
  lg.setFont(f)
  local c = COL[name:lower()]
  if c then
    lg.setColor(c[1], c[2], c[3])
    lg.circle("fill", x + 9, y + 9, 9)
    lg.setColor(1, 1, 1)
    lg.print(name, x + 9 - f:getWidth(name) / 2, y + 2)
    return 20
  end
  local tw = f:getWidth(name) + 10
  lg.setColor(0.32, 0.36, 0.42)
  lg.rectangle("fill", x, y + 1, tw, 16, 4)
  lg.setColor(1, 1, 1)
  lg.print(name, x + 5, y + 2)
  return tw + 2
end

function P.hintList(g)
  local sch = SCHEMES[modeOf(g)]
  if not g or overlay(g) then
    return { { "LS", "Pointer" }, { "A", "Click" }, { "B", "Back" }, { "Start", "Menu" } }
  end
  local t = { { "A", "Select" }, { "B", "Order" }, { "X", sch.x.label }, { "Y", sch.y.label .. " / hold: wheel" } }
  t[#t + 1] = { "LB", sch.lb and sch.lb.label or "Shift" }
  t[#t + 1] = { "RB", sch.rb and sch.rb.label or "Ctrl" }
  t[#t + 1] = { "D-pad", modeOf(g) == "coh" and "Squads 1-4" or "Groups 1-4" }
  t[#t + 1] = { "View", sch.back.label }
  t[#t + 1] = { "L3", sch.l3.label }
  t[#t + 1] = { "R3", sch.r3.label }
  t[#t + 1] = { "RS", "Pan" }
  t[#t + 1] = { "LT RT", "Zoom" }
  return t
end

function P.draw()
  if not P.active or not pad then return end
  local lg = love.graphics
  local R = require("src.render")
  local UI = require("src.ui")
  local g = game()
  local w, h = lg.getDimensions()
  lg.push("all")
  lg.origin()
  if require("src.settings").v.padHints then
    local list = P.hintList(g)
    local f = R.font(11)
    local total = 0
    for _, it in ipairs(list) do
      total = total + (COL[it[1]:lower()] and 20 or f:getWidth(it[1]) + 12) + 3 + f:getWidth(it[2]) + 9
    end
    local x = math.floor((w - total) / 2)
    local y = g and (h - UI.PANEL_H - UI.ORDERS_H - 26) or (h - 28)
    lg.setColor(0, 0, 0, 0.55)
    lg.rectangle("fill", x - 8, y - 3, total + 6, 24, 6)
    for _, it in ipairs(list) do
      x = x + glyph(lg, R, it[1], x, y) + 3
      lg.setFont(f)
      lg.setColor(0.9, 0.92, 0.95)
      lg.print(it[2], x, y + 2)
      x = x + f:getWidth(it[2]) + 9
    end
  end
  if wheel and g then
    local items = SCHEMES[modeOf(g)].wheel
    local rad = math.max(170, #items * 19)
    local ox, oy = w / 2, h / 2 - 40
    lg.setColor(0, 0, 0, 0.6)
    lg.circle("fill", ox, oy, rad + 70)
    lg.setColor(0.9, 0.75, 0.2, 0.5)
    lg.setLineWidth(2)
    lg.circle("line", ox, oy, rad + 70)
    local f = R.font(14)
    lg.setFont(f)
    for i, it in ipairs(items) do
      local a = (i - 1) / #items * 2 * math.pi
      local x, y = ox + math.sin(a) * rad, oy - math.cos(a) * rad
      local on = i == wheelPick
      local tw = f:getWidth(it.label) + 20
      lg.setColor(on and 0.9 or 0.14, on and 0.72 or 0.18, on and 0.2 or 0.24, 0.95)
      lg.rectangle("fill", x - tw / 2, y - 14, tw, 28, 8)
      lg.setColor(on and 0.1 or 0.92, on and 0.08 or 0.94, on and 0.02 or 0.97)
      lg.print(it.label, x - tw / 2 + 10, y - 9)
    end
    local hint = wheelPick and items[wheelPick].label or "Tilt the left stick"
    lg.setColor(0, 0, 0, 0.75)
    lg.rectangle("fill", ox - f:getWidth(hint) / 2 - 10, oy - 14, f:getWidth(hint) + 20, 28, 8)
    lg.setColor(0.9, 0.92, 0.95)
    lg.print(hint, ox - f:getWidth(hint) / 2, oy - 9)
  end
  lg.pop()
end

-- dev / test hook: pretend a pad is attached and (optionally) hold the wheel open
function P.fake(opts)
  pad = { isConnected = function() return true end, isGamepad = function() return true end,
    getGamepadAxis = function(_, a) return (opts.axes or {})[a] or 0 end }
  P.active = true
  if opts.wheel then yDown, yT, wheel, wheelPick = true, 1, true, opts.wheel end
end

return P
