-- HUD: top resource bar, bottom panel (minimap, selection info, command card), overlays.
local D = require("src.defs")
local U = require("src.util")
local R = require("src.render")

local UI = {}
UI.TOP_H = 38
UI.PANEL_H = 200

local BTN = 74
local COLS = 4

local function layout(w, h)
  local L = {}
  L.panelY = h - UI.PANEL_H
  L.mm = { x = 10, y = L.panelY + 10, s = UI.PANEL_H - 20 }
  L.cardW = COLS * (BTN + 6) - 6
  L.cardX = w - L.cardW - 12
  L.cardY = L.panelY + 12
  L.cmdY = L.cardY + 2 * (BTN + 6)
  L.infoX = L.mm.x + L.mm.s + 16
  L.infoW = L.cardX - L.infoX - 16
  return L
end

function UI.overPanel(game, x, y)
  local w, h = love.graphics.getDimensions()
  if y >= h - UI.PANEL_H or y <= UI.TOP_H then return true end
  if game.showSidebar then
    for _, it in ipairs(UI.sidebarItems(game)) do
      if not it.more and x >= it.x and x <= it.x + it.w and y >= it.y and y <= it.y + it.h then return true end
    end
  end
  return false
end

local lg = love.graphics
local font = R.font

local function panelBox(x, y, w, h, alpha)
  lg.setColor(0.07, 0.09, 0.12, alpha or 0.92)
  lg.rectangle("fill", x, y, w, h, 6)
  lg.setColor(0.25, 0.32, 0.4, 0.8)
  lg.setLineWidth(1)
  lg.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 6)
end

-- Draw a little icon of a unit/building type centered at x,y fitting size s
function UI.drawIcon(key, x, y, s, team)
  local d = D.units[key]
  local cr, cg, cb = R.teamColor(team or 1)
  lg.setLineWidth(1.5)
  if d.building then
    local k = s * 0.8
    lg.setColor(cr * 0.55, cg * 0.55, cb * 0.55)
    lg.rectangle("fill", x - k / 2, y - k / 2, k, k, 4)
    lg.setColor(cr * 0.85, cg * 0.85, cb * 0.85)
    lg.rectangle("fill", x - k / 2 + 4, y - k / 2 + 4, k - 8, k - 8, 3)
    lg.setColor(0, 0, 0)
    lg.rectangle("line", x - k / 2, y - k / 2, k, k, 4)
    lg.setColor(1, 1, 1)
  elseif d.domain == "air" then
    local r = s * 0.36
    local a = -math.pi / 2
    local pts = {
      x + math.cos(a) * r * 1.3, y + math.sin(a) * r * 1.3,
      x + math.cos(a + 2.5) * r, y + math.sin(a + 2.5) * r,
      x + math.cos(a - 2.5) * r, y + math.sin(a - 2.5) * r }
    lg.setColor(cr, cg, cb)
    lg.polygon("fill", pts)
    lg.setColor(0, 0, 0)
    lg.polygon("line", pts)
  elseif d.domain == "sea" or d.domain == "sub" then
    lg.setColor(cr, cg, cb, d.domain == "sub" and 0.65 or 1)
    lg.circle("fill", x, y, s * 0.36)
    lg.setColor(0, 0, 0)
    lg.circle("line", x, y, s * 0.36)
  else
    local k = s * (key == "commander" and 0.7 or 0.6)
    lg.setColor(cr, cg, cb)
    lg.rectangle("fill", x - k / 2, y - k / 2, k, k, 4)
    lg.setColor(0, 0, 0)
    lg.rectangle("line", x - k / 2, y - k / 2, k, k, 4)
  end
  local f = font(d.building and 13 or 12)
  lg.setFont(f)
  if d.building then lg.setColor(1, 1, 1) else lg.setColor(0, 0, 0) end
  lg.print(d.short, x - f:getWidth(d.short) / 2, y - f:getHeight() / 2 + (d.domain == "air" and 3 or 0))
end

---------------------------------------------------------------------------
-- Top bar

local function resourceBar(x, y, label, amount, store, income, spend, col)
  local w = 300
  lg.setFont(font(13))
  lg.setColor(col[1], col[2], col[3])
  lg.print(label, x, y + 4)
  local bx = x + 62
  lg.setColor(0, 0, 0, 0.6)
  lg.rectangle("fill", bx, y + 6, 130, 12, 3)
  lg.setColor(col[1], col[2], col[3], 0.85)
  lg.rectangle("fill", bx, y + 6, 130 * U.clamp(amount / store, 0, 1), 12, 3)
  lg.setColor(1, 1, 1)
  lg.setFont(font(12))
  local txt = U.fmt(amount) .. " / " .. U.fmt(store)
  lg.print(txt, bx + 65 - font(12):getWidth(txt) / 2, y + 5)
  lg.setFont(font(13))
  lg.setColor(0.5, 1, 0.5)
  lg.print("+" .. string.format("%.1f", income), bx + 138, y + 4)
  lg.setColor(1, 0.55, 0.45)
  lg.print("-" .. string.format("%.1f", spend), bx + 195, y + 4)
  return w
end

function UI.drawTop(game)
  local w = lg.getWidth()
  local tm = game.world.teams[1]
  lg.setColor(0.06, 0.08, 0.11, 0.94)
  lg.rectangle("fill", 0, 0, w, UI.TOP_H)
  lg.setColor(0.25, 0.32, 0.4, 0.8)
  lg.line(0, UI.TOP_H, w, UI.TOP_H)
  resourceBar(14, 7, "METAL", tm.metal, tm.mStore, tm.mIncome, tm.mSpend, { 0.82, 0.86, 0.95 })
  resourceBar(370, 7, "ENERGY", tm.energy, tm.eStore, tm.eIncome, tm.eSpend, { 1, 0.85, 0.3 })
  if tm.stalled then
    lg.setFont(font(13))
    lg.setColor(1, 0.4, 0.3, 0.6 + 0.4 * math.sin(love.timer.getTime() * 6))
    lg.print("LOW RESOURCES - building slowed", 732 + game.world.np * 22, 11)
  end
  -- player chips: color, alliance, and a cross if eliminated
  do
    local cx = 726
    lg.setFont(font(12))
    for i = 1, game.world.np do
      local c = D.teamColor[i]
      local dead = game.world.teams[i].dead
      lg.setColor(c[1], c[2], c[3], dead and 0.3 or 1)
      lg.rectangle("fill", cx, 11, 16, 16, 3)
      lg.setColor(0, 0, 0)
      local lab = tostring(game.world.ally[i])
      lg.print(lab, cx + 8 - font(12):getWidth(lab) / 2, 12)
      if dead then
        lg.setColor(1, 1, 1)
        lg.setLineWidth(2)
        lg.line(cx, 11, cx + 16, 27); lg.line(cx + 16, 11, cx, 27)
      end
      if i == 1 then
        lg.setColor(1, 1, 1, 0.8)
        lg.rectangle("line", cx - 1.5, 9.5, 19, 19, 3)
      end
      cx = cx + 22
    end
  end
  -- right side: clickable controls (speed, pause, help, menu), then time and unit count
  local t = game.world.time
  local units = 0
  for _, e in ipairs(game.world.entities) do if e.team == 1 and not e.def.building then units = units + 1 end end
  local mx, my = love.mouse.getPosition()
  local btns = {}
  local x = w - 10
  local function addBtn(label, action, bw)
    lg.setFont(font(13))
    bw = bw or (font(13):getWidth(label) + 18)
    x = x - bw
    btns[#btns + 1] = { x = x, y = 6, w = bw, h = UI.TOP_H - 12, label = label, action = action }
    x = x - 6
  end
  addBtn("Menu", "menu")
  addBtn("Help", "help")
  addBtn(game.paused and "Resume" or "Pause", "pause", 70)
  addBtn("+", "faster", 26)
  addBtn(string.format("%.1fx", game.speed), "speed1", 46)
  addBtn("-", "slower", 26)
  for _, b in ipairs(btns) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    local active = (b.action == "pause" and game.paused)
    lg.setColor(active and 0.45 or (hover and 0.22 or 0.13), hover and 0.3 or 0.17, hover and 0.38 or 0.22)
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 4)
    lg.setColor(0.85, 0.9, 0.95)
    lg.setFont(font(13))
    lg.print(b.label, b.x + b.w / 2 - font(13):getWidth(b.label) / 2, b.y + 4)
  end
  game.topBtns = btns
  local s = string.format("%d:%02d    Units %d    Speed", math.floor(t / 60), math.floor(t % 60), units)
  if game.paused then s = "PAUSED    " .. s end
  lg.setFont(font(13))
  lg.setColor(0.8, 0.85, 0.9)
  lg.print(s, x - font(13):getWidth(s) - 4, 11)
end

---------------------------------------------------------------------------
-- Sidebar: every factory and builder, one click away

UI.SIDE_W = 132
local TILE = 58

function UI.sidebarItems(game)
  local facs, blds = {}, {}
  for _, e in ipairs(game.world.entities) do
    if e.alive and e.team == 1 and e.built >= 1 then
      if e.def.factory then facs[#facs + 1] = e
      elseif e.def.builds then blds[#blds + 1] = e end
    end
  end
  table.sort(facs, function(a, b) return a.id < b.id end)
  table.sort(blds, function(a, b)
    if (a.key == "commander") ~= (b.key == "commander") then return a.key == "commander" end
    return a.id < b.id
  end)
  local h = lg.getHeight()
  local maxRows = math.floor((h - UI.PANEL_H - UI.TOP_H - 30) / (TILE + 4))
  local items = {}
  local function col(list, cx)
    for i, e in ipairs(list) do
      if i > maxRows then
        items[#items + 1] = { more = #list - maxRows, x = cx, y = UI.TOP_H + 26 + maxRows * (TILE + 4) }
        break
      end
      items[#items + 1] = { e = e, x = cx, y = UI.TOP_H + 24 + (i - 1) * (TILE + 4), w = TILE, h = TILE }
    end
  end
  col(facs, 6)
  col(blds, 6 + TILE + 6)
  return items, #facs, #blds
end

function UI.drawSidebar(game)
  if not game.showSidebar then return end
  local items, nf, nb = UI.sidebarItems(game)
  if nf + nb == 0 then return end
  local mx, my = love.mouse.getPosition()
  lg.setFont(font(11))
  lg.setColor(0.6, 0.66, 0.74)
  lg.print("PLANTS", 8, UI.TOP_H + 6)
  lg.print("BUILD", 6 + TILE + 8, UI.TOP_H + 6)
  for _, it in ipairs(items) do
    if it.more then
      lg.setColor(0.6, 0.66, 0.74)
      lg.print("+" .. it.more .. " more", it.x, it.y)
    else
      local e = it.e
      local hover = mx >= it.x and mx <= it.x + it.w and my >= it.y and my <= it.y + it.h
      local idle = (e.def.factory and #e.queue == 0) or (not e.def.factory and #e.orders == 0)
      lg.setColor(0.07, 0.09, 0.12, 0.88)
      if hover then lg.setColor(0.16, 0.2, 0.26, 0.95) end
      lg.rectangle("fill", it.x, it.y, it.w, it.h, 5)
      if game.selected[e] then
        lg.setColor(0.3, 1, 0.4)
      elseif idle then
        lg.setColor(1, 0.65, 0.2, 0.9)
      else
        lg.setColor(0.3, 0.38, 0.46)
      end
      lg.setLineWidth(game.selected[e] and 2 or 1)
      lg.rectangle("line", it.x + 0.5, it.y + 0.5, it.w - 1, it.h - 1, 5)
      if e.def.factory then
        local k = e.queue[1] or e.key
        UI.drawIcon(k, it.x + it.w / 2, it.y + 24, 32, 1)
        lg.setFont(font(10))
        lg.setColor(0.75, 0.8, 0.86)
        lg.print(e.def.short, it.x + 4, it.y + 2)
        if #e.queue > 0 then
          lg.setColor(0.3, 1, 0.4)
          lg.rectangle("fill", it.x + 4, it.y + it.h - 9, (it.w - 8) * e.progress, 4)
          lg.setColor(1, 1, 1)
          lg.print(tostring(#e.queue), it.x + it.w - 14, it.y + 2)
        else
          lg.setColor(1, 0.65, 0.2)
          lg.print("idle", it.x + it.w / 2 - 9, it.y + it.h - 15)
        end
        if e.assignGroup then
          lg.setColor(0.5, 0.85, 1)
          lg.print("G" .. e.assignGroup, it.x + 4, it.y + it.h - 15)
        end
      else
        UI.drawIcon(e.key, it.x + it.w / 2, it.y + 24, 34, 1)
        lg.setFont(font(10))
        local o = e.orders[1]
        local txt = idle and "idle" or (o.type == "build" and D.units[o.key].short or o.type)
        lg.setColor(idle and 1 or 0.7, idle and 0.65 or 0.8, idle and 0.2 or 0.86)
        lg.print(txt, it.x + it.w / 2 - font(10):getWidth(txt) / 2, it.y + it.h - 15)
        -- health sliver
        lg.setColor(0.3, 0.9, 0.4)
        lg.rectangle("fill", it.x + 4, it.y + it.h - 4, (it.w - 8) * e.hp / e.maxhp, 2)
      end
    end
  end
end

function UI.sidebarClick(game, x, y, b)
  if not game.showSidebar then return false end
  local items = UI.sidebarItems(game)
  for _, it in ipairs(items) do
    if not it.more and x >= it.x and x <= it.x + it.w and y >= it.y and y <= it.y + it.h then
      local e = it.e
      local shift = love.keyboard.isDown("lshift", "rshift")
      local now = love.timer.getTime()
      if game.lastSideClick and game.lastSideClick.e == e and now - game.lastSideClick.t < 0.35 then
        game:centerOn(e.x, e.y)
      end
      game.lastSideClick = { e = e, t = now }
      if b == 2 then
        game:centerOn(e.x, e.y)
      elseif shift and game.selected[e] then
        game.selected[e] = nil
      else
        game:select({ e }, shift)
      end
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Minimap

function UI.drawMinimap(game, L)
  local world = game.world
  local map = world.map
  local mm = L.mm
  local s = mm.s / map.w
  lg.setColor(0, 0, 0)
  lg.rectangle("fill", mm.x - 2, mm.y - 2, mm.s + 4, mm.s + 4)
  lg.setColor(1, 1, 1)
  lg.draw(map.minimap, mm.x, mm.y, 0, s, s)
  -- deposits
  lg.setColor(0.95, 0.85, 0.35, 0.8)
  for _, dp in ipairs(map.deposits) do
    lg.rectangle("fill", mm.x + dp.x * s, mm.y + dp.y * s, math.max(1.5, s), math.max(1.5, s))
  end
  -- fog
  if not world.noFog then
    lg.setColor(1, 1, 1)
    lg.draw(R.fogImage, mm.x, mm.y, 0, s, s)
  end
  local T = D.TILE
  for _, e in ipairs(world.entities) do
    if e.alive then
      local show = e.team == 1 or world:isVisible(e) or (e.def.building and e.seen[1])
      if e.def.domain == "sub" and world:hostile(e.team, 1) and not world.noFog then show = show and game:subRevealed(e) end
      if show then
        local cr, cg, cb = R.teamColor(e.team)
        if game.selected[e] then cr, cg, cb = 0.5, 1, 0.5 end
        lg.setColor(cr, cg, cb)
        local px, py = mm.x + e.x / T * s, mm.y + e.y / T * s
        if e.def.building then
          local bw = math.max(2.5, e.def.w * s)
          lg.rectangle("fill", px - bw / 2, py - bw / 2, bw, bw)
        else
          local r = e.key == "commander" and 3 or 1.6
          lg.rectangle("fill", px - r, py - r, r * 2, r * 2)
        end
      end
    end
  end
  -- camera rectangle
  local cam = game.cam
  lg.setColor(1, 1, 1, 0.85)
  lg.setLineWidth(1)
  local x0, y0 = cam.wx0 / T * s, cam.wy0 / T * s
  local x1, y1 = cam.wx1 / T * s, cam.wy1 / T * s
  lg.setScissor(mm.x, mm.y, mm.s, mm.s)
  lg.rectangle("line", mm.x + x0, mm.y + y0, x1 - x0, y1 - y0)
  lg.setScissor()
end

function UI.minimapToWorld(game, x, y)
  local w, h = lg.getDimensions()
  local L = layout(w, h)
  local mm = L.mm
  if x < mm.x or y < mm.y or x > mm.x + mm.s or y > mm.y + mm.s then return nil end
  local map = game.world.map
  local fx, fy = (x - mm.x) / mm.s, (y - mm.y) / mm.s
  return fx * map.w * D.TILE, fy * map.h * D.TILE
end

function UI.minimapDrag(game, x, y)
  local w, h = lg.getDimensions()
  local L = layout(w, h)
  local mm = L.mm
  x = U.clamp(x, mm.x, mm.x + mm.s)
  y = U.clamp(y, mm.y, mm.y + mm.s)
  local wx, wy = UI.minimapToWorld(game, x, y)
  if wx then game:centerOn(wx, wy) end
end

---------------------------------------------------------------------------
-- Selection info

function UI.drawInfo(game, L)
  local list = game:selectedList()
  local x, y, w = L.infoX, L.panelY + 12, L.infoW
  if #list == 0 then
    lg.setFont(font(14))
    lg.setColor(0.6, 0.66, 0.74)
    lg.print("Nothing selected.", x, y + 6)
    lg.setFont(font(12))
    lg.setColor(0.5, 0.55, 0.62)
    lg.printf("Left-drag to select.  Right-click to move / attack.  A = attack-move, S = stop, P = patrol.\n" ..
      "Ctrl+1-9 saves a group, 1-9 recalls it (tap twice to jump there).  Tab = next idle constructor.\n" ..
      "Space = jump to commander / last attack.  Scroll to zoom, middle-drag or arrow keys to pan.  F1 for all controls.",
      x, y + 34, w)
    return
  end
  if #list == 1 then
    local e = list[1]
    local d = e.def
    UI.drawIcon(e.key, x + 32, y + 32, 56, 1)
    lg.setFont(font(17))
    lg.setColor(1, 1, 1)
    lg.print(d.name, x + 72, y + 2)
    lg.setFont(font(12))
    lg.setColor(0.75, 0.8, 0.86)
    local hpTxt = string.format("HP %d / %d", math.max(0, e.hp), e.maxhp)
    if e.built < 1 then hpTxt = hpTxt .. string.format("    Under construction %d%%", e.built * 100) end
    if e.disarmed then hpTxt = hpTxt .. "    WEAPONS OFFLINE until fully repaired" end
    if d.weapon and e.built >= 1 then
      local L = e.level or 0
      if L >= game.world.MAX_LEVEL then
        hpTxt = hpTxt .. string.format("    Level %d (max)", L)
      else
        local need = game.world:xpForLevel(e, L + 1)
        hpTxt = hpTxt .. string.format("    Level %d   XP %d / %d", L, e.xp or 0, need)
      end
    end
    lg.print(hpTxt, x + 72, y + 26)
    lg.setColor(0.62, 0.68, 0.75)
    lg.printf(d.desc or "", x + 72, y + 44, w - 80)
    local info = {}
    if d.weapon then
      local tg = {}
      for k in pairs(d.weapon.targets) do tg[#tg + 1] = k end
      table.sort(tg)
      info[#info + 1] = string.format("Weapon: %d dmg, range %d, hits %s", d.weapon.damage, d.weapon.range, table.concat(tg, "/"))
    end
    if d.income then
      info[#info + 1] = string.format("Produces %s%s", d.income.metal and string.format("%.1f metal/s ", d.income.metal) or "",
        d.income.energy and string.format("%d energy/s", d.income.energy) or "")
    end
    if d.speed then info[#info + 1] = string.format("Speed %d   Sight %d", d.speed, d.sight) end
    lg.setColor(0.55, 0.75, 0.95)
    lg.print(table.concat(info, "     "), x + 72, y + 84)
    -- factory queue
    if d.factory and e.built >= 1 then
      local qx, qy = x, y + 112
      -- "new units join group" control
      local gx, gy, gw = x + w - 190, y + 2, 190
      local gl = "New units join: " .. (e.assignGroup and ("group " .. e.assignGroup) or "no group")
      local mx2, my2 = love.mouse.getPosition()
      local hov = mx2 >= gx and mx2 <= gx + gw and my2 >= gy and my2 <= gy + 24
      lg.setColor(hov and 0.2 or 0.13, hov and 0.28 or 0.18, hov and 0.36 or 0.24)
      lg.rectangle("fill", gx, gy, gw, 24, 4)
      lg.setColor(0.85, 0.9, 0.95)
      lg.setFont(font(12))
      lg.print(gl, gx + 8, gy + 5)
      lg.setColor(0.5, 0.56, 0.62)
      lg.print("click to cycle, or Option+1-9", gx + 8, gy + 28)
      game.groupBtn = { x = gx, y = gy, w = gw, h = 24, f = e }
      lg.setColor(0.7, 0.75, 0.8)
      lg.print("Queue" .. (e.repeatMode and "  (repeat ON - G)" or "  (G toggles repeat)") .. ":", qx, qy)
      local shown = 0
      local runs = {}
      for _, k in ipairs(e.queue) do
        local last = runs[#runs]
        if last and last.key == k then last.n = last.n + 1 else runs[#runs + 1] = { key = k, n = 1 } end
      end
      for i, run in ipairs(runs) do
        if i > 10 then break end
        local ix = qx + (i - 1) * 46 + 22
        UI.drawIcon(run.key, ix, qy + 42, 34, 1)
        if i == 1 then
          lg.setColor(0.3, 1, 0.4)
          lg.rectangle("fill", ix - 18, qy + 62, 36 * e.progress, 3)
        end
        if run.n > 1 then
          lg.setFont(font(12)); lg.setColor(1, 1, 1)
          lg.print("x" .. run.n, ix + 6, qy + 50)
        end
      end
      if #runs == 0 then
        lg.setColor(0.5, 0.55, 0.6)
        lg.print("Empty. Click a unit on the right or press its key (Shift = 5, right-click removes).", qx, qy + 20)
      end
    elseif e.orders and #e.orders > 0 then
      local o = e.orders[1]
      local names = { move = "Moving", amove = "Attack-moving", attack = "Attacking", patrol = "Patrolling", build = "Building", assist = "Assisting", retreat = "Retreating (weapons off)" }
      lg.setColor(0.6, 0.85, 0.6)
      local s = names[o.type] or o.type
      if o.type == "build" then s = s .. " " .. D.units[o.key].name end
      if #e.orders > 1 then s = s .. string.format("   (+%d queued)", #e.orders - 1) end
      lg.print(s, x + 72, y + 104)
    end
    return
  end
  -- multiple: grouped icons with counts
  local counts, order = {}, {}
  for _, e in ipairs(list) do
    if not counts[e.key] then counts[e.key] = 0; order[#order + 1] = e.key end
    counts[e.key] = counts[e.key] + 1
  end
  lg.setFont(font(14))
  lg.setColor(1, 1, 1)
  lg.print(#list .. " selected   (click a type to select only those)", x, y)
  game.infoButtons = {}
  for i, k in ipairs(order) do
    local col = (i - 1) % 9
    local row = math.floor((i - 1) / 9)
    local ix, iy = x + col * 62, y + 26 + row * 70
    lg.setColor(0.12, 0.15, 0.2)
    lg.rectangle("fill", ix, iy, 56, 62, 5)
    UI.drawIcon(k, ix + 28, iy + 26, 40, 1)
    lg.setFont(font(12))
    lg.setColor(1, 1, 1)
    lg.print("x" .. counts[k], ix + 30, iy + 44)
    game.infoButtons[#game.infoButtons + 1] = { x = ix, y = iy, w = 56, h = 62, key = k }
  end
end

---------------------------------------------------------------------------
-- Command card

function UI.cardButtons(game, L)
  local btns = {}
  local ctx, list = game:commandContext()
  if ctx then
    for i, key in ipairs(list) do
      local col = (i - 1) % COLS
      local row = math.floor((i - 1) / COLS)
      btns[#btns + 1] = {
        x = L.cardX + col * (BTN + 6), y = L.cardY + row * (BTN + 6), w = BTN, h = BTN,
        kind = ctx, key = key, slot = i, hotkey = D.hotkeys[i],
      }
    end
  end
  local cmds = {}
  if #game:selectedMobile() > 0 then
    cmds = { { "Attack A", "amove" }, { "Stop S", "stop" }, { "Patrol P", "patrol" }, { "Retreat F", "retreat" } }
  end
  if #game:selectedFactories() > 0 then cmds[#cmds + 1] = { "Repeat G", "repeat" } end
  local n = #game:selectedList()
  if n >= 2 then cmds[#cmds + 1] = { "Half H", "half" } end
  cmds[#cmds + 1] = { "All army", "all" }
  local per = math.max(4, #cmds)
  local cw = (L.cardW - 6 * (per - 1)) / per
  for i, c in ipairs(cmds) do
    btns[#btns + 1] = { x = L.cardX + (i - 1) * (cw + 6), y = L.cmdY + 2, w = cw, h = 26, kind = "cmd", label = c[1], action = c[2] }
  end
  return btns
end

function UI.drawCard(game, L)
  local btns = UI.cardButtons(game, L)
  local mx, my = love.mouse.getPosition()
  local tm = game.world.teams[1]
  game.hoverBtn = nil
  for _, b in ipairs(btns) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    if hover then game.hoverBtn = b end
    if b.kind == "cmd" then
      local active = (b.action == game.mode)
      if b.action == "repeat" then
        for _, f in ipairs(game:selectedFactories()) do if f.repeatMode then active = true end end
      end
      lg.setColor(active and 0.2 or 0.13, active and 0.35 or 0.17, active and 0.25 or 0.22)
      if hover then lg.setColor(0.22, 0.3, 0.38) end
      lg.rectangle("fill", b.x, b.y, b.w, b.h, 4)
      lg.setColor(0.85, 0.9, 0.95)
      lg.setFont(font(12))
      lg.print(b.label, b.x + b.w / 2 - font(12):getWidth(b.label) / 2, b.y + 6)
    else
      local d = D.units[b.key]
      local active = game.mode == "build" and game.buildKey == b.key
      lg.setColor(0.12, 0.15, 0.2)
      if hover then lg.setColor(0.18, 0.24, 0.3) end
      if active then lg.setColor(0.15, 0.32, 0.22) end
      lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
      lg.setColor(0.3, 0.38, 0.46)
      lg.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, 6)
      UI.drawIcon(b.key, b.x + b.w / 2, b.y + b.h / 2 - 6, 40, 1)
      lg.setFont(font(11))
      local afford = tm.metal >= d.cost.metal * 0.2
      lg.setColor(0.8, 0.85, 0.95)
      lg.print(d.cost.metal .. "m", b.x + 4, b.y + b.h - 16)
      lg.setColor(1, 0.85, 0.35)
      local et = U.fmt(d.cost.energy) .. "e"
      lg.print(et, b.x + b.w - font(11):getWidth(et) - 4, b.y + b.h - 16)
      lg.setColor(1, 1, 1, 0.75)
      lg.print(string.upper(b.hotkey), b.x + 5, b.y + 3)
      -- queued count on factory buttons
      if b.kind == "factory" then
        local n = 0
        for _, f in ipairs(game:selectedFactories()) do
          for _, k in ipairs(f.queue) do if k == b.key then n = n + 1 end end
        end
        if n > 0 then
          lg.setFont(font(15))
          lg.setColor(0.4, 1, 0.5)
          lg.print(tostring(n), b.x + b.w - font(15):getWidth(tostring(n)) - 5, b.y + 2)
        end
      end
    end
  end
  game.cardBtns = btns
  -- tooltip
  local b = game.hoverBtn
  if b and b.key then
    local d = D.units[b.key]
    local text = d.name .. "\n" .. string.format("Cost: %d metal, %d energy", d.cost.metal, d.cost.energy)
    local power = b.kind == "factory" and 10 or 12
    text = text .. string.format("\nBuild time ~%ds", math.ceil(d.cost.work / power))
    if d.weapon then text = text .. string.format("\nDamage %d, range %d", d.weapon.damage, d.weapon.range) end
    text = text .. "\n" .. (d.desc or "")
    if b.kind == "factory" then text = text .. "\nClick = 1, Shift-click = 5, right-click removes" end
    lg.setFont(font(13))
    local tw = 290
    local _, lines = font(13):getWrap(text, tw)
    local th = #lines * font(13):getHeight() + 16
    local tx, ty = math.min(mx + 14, lg.getWidth() - tw - 24), my - th - 10
    panelBox(tx, ty, tw + 16, th, 0.97)
    lg.setColor(0.9, 0.93, 0.97)
    lg.printf(text, tx + 8, ty + 8, tw)
  end
end

---------------------------------------------------------------------------
-- Overlays

local HELP = [[
PARTIAL ANNIHILATION - CONTROLS

Selecting
  Left-click / drag box ..... select (Shift adds)
  Double-click a unit ....... select all of that type on screen
  Ctrl+A (or Cmd+A) ......... select all combat units
  H ......................... select half (keeps the half nearest the mouse, same unit mix)
  Shift+H ................... switch to the other half
  Ctrl+B .................... select all constructors
  Tab ....................... cycle idle constructors
  Left sidebar .............. all factories & builders (orange = idle). Click selects,
                              double/right-click jumps there.  B toggles the sidebar
  C / Home .................. select & jump to your Commander

Control groups
  Ctrl+1..9 ................. save selection as a group
  Shift+1..9 ................ add selection to group
  1..9 ...................... recall group (tap twice to jump to it)

Orders (hold Shift to queue)
  Right-click ground ........ move (units spread in formation)
  Right-click enemy ......... attack
  Right-click own unfinished/damaged/factory with constructors .. help build / repair / assist
  A then click .............. attack-move (fight anything on the way)
  P then click .............. patrol
  S ......................... stop
  F ......................... retreat to your flag (+25% speed, weapons OFF until fully repaired)
  Shift+F ................... retreat to the Commander
  Ctrl+F .................... plant the retreat flag at the mouse
                              Units out of combat near your Commander or a factory slowly repair
  Backspace ................. drop the last queued order

Building
  Select a constructor, press Q W E R T Y U I (or click), then click the map
  Shift-click places several; drag a box to fill an area (extractors: every deposit in the box)
  Select a factory: Q W E R T queue units (Shift = 5), right-click a button removes
  Right-click the ground with a factory selected = rally point,  G = repeat queue
  Option+1..9 with a factory selected = its new units join that group (Option+0 clears)

Camera
  Scroll = zoom,  right-drag or middle-drag = pan,  arrow keys / screen edge = pan
  Option+scroll = pan (trackpad),  minimap click = jump,  Space = jump to last attack
  L = lock camera on selection,  Shift+L = cinematic follow (zooms to frame them)
  F9 = keep mouse inside window (on by default, for edge panning),  F8 = edge panning on/off

Game
  Esc = menu / cancel,  F3 = pause,  + / - = game speed,  M = sound on/off
  F11 = fullscreen,  F1 = this help

Goal: destroy the enemy Commander. Lose yours and it's over.
Veterancy: units level up (gold chevrons, max 5) from damage and kills: more damage, HP, fire rate, range.
Economy: Metal Extractors on yellow deposits, Solar for energy. Everything costs both.
]]

function UI.drawHelp()
  local w, h = lg.getDimensions()
  local bw, bh = 760, math.min(h - 20, 690)
  local x, y = (w - bw) / 2, (h - bh) / 2
  panelBox(x, y, bw, bh, 0.97)
  lg.setFont(font(14))
  lg.setColor(0.9, 0.93, 0.97)
  lg.print(HELP, x + 24, y + 18)
end

local function button(x, y, w, h, label, hot)
  local mx, my = love.mouse.getPosition()
  local hover = mx >= x and mx <= x + w and my >= y and my <= y + h
  lg.setColor(hover and 0.22 or 0.14, hover and 0.32 or 0.2, hover and 0.42 or 0.27)
  lg.rectangle("fill", x, y, w, h, 6)
  lg.setColor(0.4, 0.55, 0.7)
  lg.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 6)
  lg.setFont(font(16))
  lg.setColor(1, 1, 1)
  lg.print(label, x + w / 2 - font(16):getWidth(label) / 2, y + h / 2 - 10)
  return hover
end
UI.button = button

function UI.menuRects()
  local w, h = lg.getDimensions()
  local bw = 280
  local x = (w - bw) / 2
  local y = h / 2 - 110
  return {
    { x = x, y = y, w = bw, h = 44, label = "Resume", action = "resume" },
    { x = x, y = y + 56, w = bw, h = 44, label = "Controls (F1)", action = "help" },
    { x = x, y = y + 112, w = bw, h = 44, label = "Save this map...", action = "savemap" },
    { x = x, y = y + 168, w = bw, h = 44, label = "Surrender & return to title", action = "quit" },
    { x = x, y = y + 224, w = bw, h = 44, label = "Exit game", action = "exit" },
  }
end

function UI.drawMenu()
  local w, h = lg.getDimensions()
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 0, 0, w, h)
  local rects = UI.menuRects()
  panelBox(rects[1].x - 30, rects[1].y - 70, rects[1].w + 60, 366, 0.97)
  lg.setFont(font(22))
  lg.setColor(1, 1, 1)
  lg.print("Paused", w / 2 - font(22):getWidth("Paused") / 2, rects[1].y - 52)
  for _, r in ipairs(rects) do button(r.x, r.y, r.w, r.h, r.label) end
end

function UI.menuClick(game, x, y, button_)
  if button_ ~= 1 then return end
  for _, r in ipairs(UI.menuRects()) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      if r.action == "resume" then game.menuOpen = false
      elseif r.action == "help" then game.menuOpen = false; game.showHelp = true
      elseif r.action == "savemap" then game:startNaming()
      elseif r.action == "quit" then game.quitToTitle = true
      elseif r.action == "exit" then love.event.quit() end
    end
  end
end

function UI.overRects()
  local w, h = lg.getDimensions()
  return {
    { x = w / 2 - 345, y = h / 2 + 70, w = 220, h = 46, label = "Play again", action = "again" },
    { x = w / 2 - 110, y = h / 2 + 70, w = 220, h = 46, label = "Save this map...", action = "savemap" },
    { x = w / 2 + 125, y = h / 2 + 70, w = 220, h = 46, label = "Title screen", action = "title" },
  }
end

function UI.drawOver(game)
  local w, h = lg.getDimensions()
  local o = game.world.over
  local k = math.min(1, (love.timer.getTime() - (game.overTime or 0)) / 1.5)
  o.winner = (o.winnerAlly == game.world.ally[1]) and 1 or 2
  lg.setColor(0, 0, 0, 0.6 * k)
  lg.rectangle("fill", 0, 0, w, h)
  if k < 1 then return end
  local win = o.winner == 1
  local title = win and "VICTORY" or "DEFEAT"
  panelBox(w / 2 - 370, h / 2 - 150, 740, 290, 0.97)
  lg.setFont(font(48))
  if win then lg.setColor(0.4, 1, 0.5) else lg.setColor(1, 0.4, 0.35) end
  lg.print(title, w / 2 - font(48):getWidth(title) / 2, h / 2 - 130)
  lg.setFont(font(16))
  lg.setColor(0.85, 0.9, 0.95)
  local t = o.time
  local s = string.format("Game time %d:%02d     Built %d     Destroyed %d     Lost %d", math.floor(t / 60), math.floor(t % 60),
    game.stats.built, game.stats.killed, game.stats.lost)
  lg.print(s, w / 2 - font(16):getWidth(s) / 2, h / 2 - 50)
  local sub = win and "Every enemy Commander has been annihilated. Partially." or "Your side has been annihilated. Completely."
  local ais = {}
  for i, p in ipairs(game.players) do
    if not p.human then
      local rel = game.world:hostile(i, 1) and "enemy" or "ally"
      ais[#ais + 1] = string.format("%s: %s lvl %d (%s)", D.teamName[i], p.profileName or p.profile, p.level, rel)
    end
  end
  local who = table.concat(ais, "    ")
  lg.setFont(font(13))
  lg.setColor(0.6, 0.68, 0.76)
  lg.print(who, w / 2 - font(13):getWidth(who) / 2, h / 2 + 10)
  lg.setFont(font(16))
  lg.setColor(0.85, 0.9, 0.95)
  lg.print(sub, w / 2 - font(16):getWidth(sub) / 2, h / 2 - 20)
  for _, r in ipairs(UI.overRects()) do button(r.x, r.y, r.w, r.h, r.label) end
end

function UI.overClick(game, x, y, b)
  if b ~= 1 then return end
  for _, r in ipairs(UI.overRects()) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      if r.action == "again" then game.playAgain = true
      elseif r.action == "savemap" then game:startNaming()
      else game.quitToTitle = true end
    end
  end
end

---------------------------------------------------------------------------

function UI.draw(game)
  local w, h = lg.getDimensions()
  local L = layout(w, h)
  UI.drawSidebar(game)
  UI.drawTop(game)
  -- bottom panel
  lg.setColor(0.06, 0.08, 0.11, 0.95)
  lg.rectangle("fill", 0, L.panelY, w, UI.PANEL_H)
  lg.setColor(0.25, 0.32, 0.4, 0.8)
  lg.line(0, L.panelY, w, L.panelY)
  UI.drawMinimap(game, L)
  game.infoButtons = nil
  game.groupBtn = nil
  UI.drawInfo(game, L)
  UI.drawCard(game, L)

  -- mode hint
  local hint
  if game.mode == "build" then hint = "Placing " .. D.units[game.buildKey].name .. " - click to place, drag for an area, Shift for more, right-click/Esc cancels"
  elseif game.mode == "amove" then hint = "Attack-move: click a destination (Shift queues)"
  elseif game.mode == "patrol" then hint = "Patrol: click a destination (Shift queues)" end
  if hint then
    lg.setFont(font(14))
    local tw = font(14):getWidth(hint)
    panelBox(w / 2 - tw / 2 - 12, UI.TOP_H + 8, tw + 24, 30, 0.85)
    lg.setColor(1, 1, 1)
    lg.print(hint, w / 2 - tw / 2, UI.TOP_H + 14)
  end

  -- notices
  local ny = UI.TOP_H + 46
  for _, nt in ipairs(game.notices) do
    local a = math.min(1, (nt.life - nt.t) * 2)
    lg.setFont(font(16))
    local tw = font(16):getWidth(nt.text)
    lg.setColor(0, 0, 0, 0.6 * a)
    lg.rectangle("fill", w / 2 - tw / 2 - 10, ny, tw + 20, 28, 5)
    lg.setColor(1, 0.9, 0.6, a)
    lg.print(nt.text, w / 2 - tw / 2, ny + 4)
    ny = ny + 32
  end

  if game.showHelp then UI.drawHelp() end
  if game.menuOpen then UI.drawMenu() end
  if game.world.over and game.overShown then UI.drawOver(game) end
  if game.naming then
    lg.setColor(0, 0, 0, 0.5)
    lg.rectangle("fill", 0, 0, w, h)
    panelBox(w / 2 - 260, h / 2 - 80, 520, 160, 0.98)
    lg.setFont(font(18))
    lg.setColor(1, 1, 1)
    lg.print("Name this map", w / 2 - 240, h / 2 - 62)
    lg.setColor(0.04, 0.05, 0.07)
    lg.rectangle("fill", w / 2 - 240, h / 2 - 26, 480, 40, 5)
    lg.setColor(0.95, 0.97, 1)
    local caret = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "_" or ""
    lg.print(game.naming.text .. caret, w / 2 - 230, h / 2 - 17)
    lg.setFont(font(13))
    lg.setColor(0.6, 0.66, 0.74)
    lg.print(string.format("Seed %d, %s, %d-way symmetric.   Enter = save, Esc = cancel", game.world.map.seed,
      ({ [72] = "small", [96] = "medium", [128] = "large" })[game.world.map.w] or "custom", game.world.map.four and 4 or 2), w / 2 - 240, h / 2 + 30)
  end
end

-- Returns true if the click was consumed by the HUD
function UI.click(game, x, y, b)
  local w, h = lg.getDimensions()
  local L = layout(w, h)
  if game.showHelp then game.showHelp = false; return true end
  if y <= UI.TOP_H then
    for _, tb in ipairs(game.topBtns or {}) do
      if x >= tb.x and x <= tb.x + tb.w and y >= tb.y and y <= tb.y + tb.h then
        if tb.action == "menu" then game.menuOpen = true
        elseif tb.action == "help" then game.showHelp = true
        elseif tb.action == "pause" then game.paused = not game.paused
        elseif tb.action == "faster" then game:setSpeed(game.speed + 0.5)
        elseif tb.action == "slower" then game:setSpeed(game.speed - 0.5)
        elseif tb.action == "speed1" then game:setSpeed(1) end
      end
    end
    return true
  end
  if y < L.panelY then return UI.sidebarClick(game, x, y, b) end
  -- minimap
  local wx, wy = UI.minimapToWorld(game, x, y)
  if wx then
    if b == 1 then
      if game.mode == "amove" or game.mode == "patrol" then
        game:commandMove(wx, wy, game.mode, love.keyboard.isDown("lshift", "rshift"))
        game.mode = nil
      else
        game:centerOn(wx, wy)
        game.minimapDrag = true
      end
    elseif b == 2 then
      game:rightClick(wx, wy, love.keyboard.isDown("lshift", "rshift"))
    end
    return true
  end
  -- card buttons
  for _, btn in ipairs(game.cardBtns or {}) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      local shift = love.keyboard.isDown("lshift", "rshift")
      if btn.kind == "cmd" then
        if btn.action == "stop" then game:stop()
        elseif btn.action == "half" then
          if shift then game:selectOtherHalf() else game:selectHalf() end
        elseif btn.action == "all" then game:selectAllArmy()
        elseif btn.action == "retreat" then game:retreat(shift and "commander" or "flag")
        elseif btn.action == "repeat" then
          for _, f in ipairs(game:selectedFactories()) do f.repeatMode = not f.repeatMode end
        else game.mode = btn.action end
      elseif btn.kind == "builder" then
        if b == 1 then game.mode = "build"; game.buildKey = btn.key end
      elseif btn.kind == "factory" then
        game:queueUnit(btn.key, shift and 5 or 1, b == 2)
      end
      return true
    end
  end
  -- factory "join group" cycle button
  local gb = game.groupBtn
  if gb and gb.f.alive and x >= gb.x and x <= gb.x + gb.w and y >= gb.y and y <= gb.y + gb.h then
    local nextG = ((gb.f.assignGroup or 0) + (b == 2 and 9 or 1)) % 10
    for _, f in ipairs(game:selectedFactories()) do f.assignGroup = nextG > 0 and nextG or nil end
    return true
  end
  -- info type buttons (narrow selection)
  for _, ib in ipairs(game.infoButtons or {}) do
    if x >= ib.x and x <= ib.x + ib.w and y >= ib.y and y <= ib.y + ib.h then
      local keep = {}
      for _, e in ipairs(game:selectedList()) do if e.key == ib.key then keep[#keep + 1] = e end end
      game:select(keep)
      return true
    end
  end
  return true
end

return UI
