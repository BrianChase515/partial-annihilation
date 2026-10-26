-- HUD: top resource bar, bottom panel (minimap, selection info, command card), overlays.
local D = require("src.defs")
local U = require("src.util")
local R = require("src.render")

local UI = {}
UI.TOP_H = 38
UI.PANEL_H = 200

local BTN = 74
local COLS = 4
local CU -- Commander Craft HUD (loaded on demand)
local function craftUI() CU = CU or require("src.craft_ui"); return CU end
UI.CRAFT_KEYS = { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" }

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
  for _, r in ipairs(game.world.squads and game.squadRows or {}) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then return true end
  end
  local hb = game.craft and game.heroBar
  if hb and x >= hb.x and x <= hb.x + hb.w and y >= hb.y and y <= hb.y + hb.h then return true end
  if game.orderBtns and y >= h - UI.PANEL_H - UI.ORDERS_H then
    local b1, bn = game.orderBtns[1], game.orderBtns[#game.orderBtns]
    if b1 and x >= b1.x - 6 and x <= bn.x + bn.w + 6 then return true end
  end
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
  if D.units[key] and D.units[key].heroRecruit then key = "cls_" .. D.units[key].heroRecruit end
  local d = D.units[key] or (key:match("^cls_") and D.units.commander)
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
  if d.building then lg.setColor(1, 1, 1) else lg.setColor(0, 0, 0, 0.9) end
  local ICONS = require("src.icons")
  if ICONS.has(key) then
    ICONS.draw(key, x, y + (d.domain == "air" and 2 or 0), s * (d.building and 0.62 or (d.domain == "air" and 0.42 or 0.5)))
    return
  end
  local f = font(d.building and 13 or 12)
  lg.setFont(f)
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

function UI.drawArenaTop(game)
  local A = require("src.arena")
  local w = game.world
  local st = w.arena
  local c = w.teams[1].commander
  local cls = A.byClass[c.class]
  lg.setFont(font(14))
  lg.setColor(0.95, 0.85, 0.5)
  local L = c.clevel or 0
  lg.print(string.format("%s  Lv %d", cls and cls.name or "?", L), 14, 10)
  -- XP bar
  local x0 = 150
  local lo = L > 0 and A.THRESHOLDS[L] or 0
  local hi = A.THRESHOLDS[L + 1]
  lg.setColor(0.15, 0.18, 0.24)
  lg.rectangle("fill", x0, 12, 160, 14, 3)
  if hi then
    lg.setColor(0.55, 0.45, 1)
    lg.rectangle("fill", x0, 12, 160 * math.max(0, math.min(1, ((c.cxp or 0) - lo) / (hi - lo))), 14, 3)
  else
    lg.setColor(1, 0.85, 0.3)
    lg.rectangle("fill", x0, 12, 160, 14, 3)
  end
  lg.setFont(font(11))
  lg.setColor(1, 1, 1)
  local xt = hi and string.format("XP %d / %d", c.cxp or 0, hi) or "MAX LEVEL"
  lg.print(xt, x0 + 80 - font(11):getWidth(xt) / 2, 12)
  -- kills, towers, next wave
  local mine, theirs = 0, 0
  for _, s in ipairs(st.structures) do
    if s.alive and s.key ~= "core" then if s.side == 1 then mine = mine + 1 else theirs = theirs + 1 end end
  end
  local deaths = 0
  for _, t in ipairs(st.sideTeams[1]) do deaths = deaths + (st.deaths[t] or 0) end
  lg.setFont(font(14))
  lg.setColor(0.85, 0.9, 0.95)
  local txt = string.format("Kills %d  Deaths %d   Towers %d vs %d%s   Wave in %ds", st.kills[1], deaths, mine, theirs,
    st.ffa and string.format("  (%d rivals left)", (function() local n = 0; for sd = 2, st.nSides do if not st.sideDead[sd] then n = n + 1 end end; return n end)()) or "",
    math.max(0, math.ceil(st.waveAt - w.time)))
  if not c.alive and c.respawnAt then
    txt = txt .. string.format("     RESPAWN IN %ds", math.ceil(c.respawnAt - w.time))
  end
  lg.print(txt, 330, 10)
end

function UI.drawTop(game)
  local w = lg.getWidth()
  local tm = game.world.teams[1]
  lg.setColor(0.06, 0.08, 0.11, 0.94)
  lg.rectangle("fill", 0, 0, w, UI.TOP_H)
  lg.setColor(0.25, 0.32, 0.4, 0.8)
  lg.line(0, UI.TOP_H, w, UI.TOP_H)
  if game.craft then
    craftUI().drawTop(game)
  elseif game.arena then
    UI.drawArenaTop(game)
  elseif game.world.squads then
    -- Commander of Heroes: no economy - the mode's name and the ticket race instead
    local st = game.world.squads
    local me = game.world.ally[1]
    local foe
    for a in pairs(st.tickets) do if a ~= me then foe = a end end
    lg.setFont(font(14))
    local SQ = require("src.squads")
    if game.world.wih then
      lg.setColor(0.9, 0.35, 0.25)
      lg.print("WAR IS HELL", 14, 10)
      local mineN, seenN = 0, 0
      for _, e in ipairs(game.world.entities) do
        if e.alive and e.squad then
          if e.team == 1 then mineN = mineN + 1 elseif game.world:isVisible(e) then seenN = seenN + 1 end
        end
      end
      lg.setColor(0.85, 0.9, 0.96)
      lg.print(string.format("Your men  %d      Enemy in sight  %d", mineN, seenN), 160, 10)
    else
      lg.setColor(0.95, 0.85, 0.5)
      lg.print("COMMANDER OF HEROES", 14, 10)
      lg.setColor(0.85, 0.9, 0.96)
      lg.print(string.format("Tickets  %d  vs  %d      Points  %d - %d", math.max(0, math.floor(st.tickets[me] or 0)),
        math.max(0, math.floor(foe and st.tickets[foe] or 0)), SQ.held(game.world, me), foe and SQ.held(game.world, foe) or 0), 230, 10)
    end
  else
  resourceBar(14, 7, "METAL", tm.metal, tm.mStore, tm.mIncome, tm.mSpend, { 0.82, 0.86, 0.95 })
  resourceBar(370, 7, "ENERGY", tm.energy, tm.eStore, tm.eIncome, tm.eSpend, { 1, 0.85, 0.3 })
  end
  if tm.stalled and not game.arena and not game.craft and not game.world.squads then
    -- under the bar, centered, so it never collides with the bar's contents
    lg.setFont(font(13))
    local msg = "LOW RESOURCES - building slowed"
    local mw = font(13):getWidth(msg) + 20
    lg.setColor(0.08, 0.04, 0.04, 0.8)
    lg.rectangle("fill", w / 2 - mw / 2, UI.TOP_H + 4, mw, 22, 4)
    lg.setColor(1, 0.4, 0.3, 0.6 + 0.4 * math.sin(love.timer.getTime() * 6))
    lg.print(msg, w / 2 - mw / 2 + 10, UI.TOP_H + 7)
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
  -- Auto: standing orders (flee when hurt, keep constructors...) - green while any is on
  if require("src.automation").applies(game) then addBtn("Auto", "auto", 52) end
  addBtn(game.paused and "Resume" or "Pause", "pause", 70)
  addBtn("+", "faster", 26)
  addBtn(game.speed >= 5 and string.format("%dx", game.speed) or string.format("%.1fx", game.speed), "speed1", 46)
  addBtn("-", "slower", 26)
  for _, b in ipairs(btns) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    local active = (b.action == "pause" and game.paused)
    if b.action == "auto" and require("src.automation").anyOn() then
      lg.setColor(hover and 0.25 or 0.16, hover and 0.55 or 0.42, hover and 0.32 or 0.24) -- green: standing orders are on
    else
      lg.setColor(active and 0.45 or (hover and 0.22 or 0.13), hover and 0.3 or 0.17, hover and 0.38 or 0.22)
    end
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
  -- player chips sit just left of the clock; measure first, then draw
  do
    local world = game.world
    local seen, groups = {}, 0
    for i = 1, world.np do if not seen[world.ally[i]] then seen[world.ally[i]] = true; groups = groups + 1 end end
    local cw = world.np * 20 + groups * 4 + (groups > 1 and (font(12):getWidth("vs") + 6) or 0) + math.max(0, groups - 2) * 6
    game.chipsX = math.floor(x - font(13):getWidth(s) - 4 - 18 - cw)
  end
  -- player chips grouped by side: YOUR TEAM [you][allies]  VS  [enemy team] [enemy team]...
  do
    local world = game.world
    local cx = game.chipsX or 726
    local function chip(i)
      local cr, cg, cb = R.teamColor(i)
      local dead = world.teams[i].dead
      lg.setColor(cr, cg, cb, dead and 0.3 or 1)
      lg.rectangle("fill", cx, 11, 16, 16, 3)
      if dead then
        lg.setColor(1, 1, 1)
        lg.setLineWidth(2)
        lg.line(cx, 11, cx + 16, 27); lg.line(cx + 16, 11, cx, 27)
      end
      if i == 1 then
        lg.setColor(1, 1, 1, 0.9)
        lg.setLineWidth(1.5)
        lg.rectangle("line", cx - 1.5, 9.5, 19, 19, 3)
      end
      cx = cx + 20
    end
    local groups, order = {}, {}
    for i = 1, world.np do
      local a = world.ally[i]
      if not groups[a] then groups[a] = {}; order[#order + 1] = a end
      table.insert(groups[a], i)
    end
    table.sort(order, function(a, b)
      if a == world.ally[1] then return true elseif b == world.ally[1] then return false end
      return a < b end)
    lg.setFont(font(10))
    for gi, a in ipairs(order) do
      local mine = a == world.ally[1]
      local g = groups[a]
      local x0 = cx
      if gi == 2 then
        lg.setFont(font(12))
        lg.setColor(1, 0.45, 0.35)
        lg.print("vs", cx, 12)
        cx = cx + font(12):getWidth("vs") + 6
        x0 = cx
      elseif gi > 2 then
        cx = cx + 6
        x0 = cx
      end
      for _, i in ipairs(g) do chip(i) end
      -- underline each side: green for yours, red for each enemy side
      if mine then lg.setColor(0.35, 1, 0.45, 0.9) else lg.setColor(1, 0.35, 0.3, 0.9) end
      lg.setLineWidth(2)
      lg.line(x0 - 1, 31, cx - 3, 31)
      cx = cx + 4
    end
    game.chipsRight = cx
  end
end

---------------------------------------------------------------------------
-- Score mode leaderboard

UI.SCORE_W = 268

function UI.drawLeaderboard(game)
  local world = game.world
  if not world.score then return end
  local MOD = require("src.mods")
  local w = lg.getWidth()
  -- grouped by side (yours first), so rows don't jump around and teammates sit together
  local rows = MOD.ranking(world)
  local mine = world.ally[1]
  table.sort(rows, function(a, b)
    local am, bm = a.ally == mine, b.ally == mine
    if am ~= bm then return am end
    if a.ally ~= b.ally then return a.ally < b.ally end
    return a.team < b.team
  end)
  local bw, rh = UI.SCORE_W, 24
  local x, y = w - bw - 10, UI.TOP_H + 8
  local seps = 0
  for i = 2, #rows do if rows[i].ally ~= rows[i - 1].ally then seps = seps + 1 end end
  local bh = 34 + #rows * rh + seps * 8
  panelBox(x, y, bw, bh, 0.86)
  game.scoreBottom = y + bh
  lg.setFont(font(13))
  lg.setColor(1, 0.85, 0.35)
  local t, par = world.time, world.parTime
  lg.print(world.official and "SCORE" or "SCORE*", x + 10, y + 8)
  if t <= par then lg.setColor(0.5, 1, 0.55) else lg.setColor(1, 0.55, 0.35) end
  lg.print(string.format("%d:%02d / par %d:%02d", math.floor(t / 60), math.floor(t % 60), math.floor(par / 60), math.floor(par % 60)), x + 92, y + 8)
  local yy = y + 30
  for i, r in ipairs(rows) do
    if i > 1 and r.ally ~= rows[i - 1].ally then
      lg.setColor(0.4, 0.45, 0.5, 0.6)
      lg.line(x + 10, yy + 3, x + bw - 10, yy + 3)
      yy = yy + 8
    end
    local friend = r.ally == mine
    -- side stripe: green = your team, red = enemy
    if friend then lg.setColor(0.35, 1, 0.45, r.dead and 0.35 or 0.9) else lg.setColor(1, 0.35, 0.3, r.dead and 0.35 or 0.9) end
    lg.rectangle("fill", x + 4, yy + 2, 3, 16)
    local cr, cg, cb = R.teamColor(r.team)
    lg.setColor(cr, cg, cb, r.dead and 0.35 or 1)
    lg.rectangle("fill", x + 10, yy + 3, 14, 14, 3)
    lg.setColor(1, 1, 1, r.dead and 0.4 or 1)
    local name = r.team == 1 and "You" or D.teamName[r.team]
    if r.team ~= 1 then name = name .. (friend and " (ally)" or "") end
    lg.print(name, x + 30, yy + 2)
    -- Commander level: colored by how far ahead (red) or behind (dim) of yours an enemy is
    local c = world.teams[r.team].commander
    local me = world.teams[1].commander
    if c then
      local L, myL = c.clevel or 0, me and me.clevel or 0
      local d = L - myL
      if friend then lg.setColor(0.75, 0.85, 1, r.dead and 0.4 or 0.95)
      elseif d >= 2 then lg.setColor(1, 0.35, 0.3)
      elseif d == 1 then lg.setColor(1, 0.7, 0.3)
      elseif d == 0 then lg.setColor(1, 1, 1, 0.9)
      else lg.setColor(0.6, 0.65, 0.7) end
      lg.print("L" .. L, x + 128, yy + 2)
    end
    lg.setColor(1, 1, 1, r.dead and 0.4 or 1)
    lg.print(U.fmt(r.pts), x + 160, yy + 2)
    if r.mult > 1 then
      local pulse = 0.6 + 0.4 * math.sin(love.timer.getTime() * 8)
      lg.setColor(1, 0.6, 0.2, pulse)
      lg.print(string.format("x%.2f", r.mult), x + 214, yy + 2)
    end
    yy = yy + rh
  end
end

---------------------------------------------------------------------------
-- Commander card (top right, under the scoreboard): health, level, XP, status.
-- Click it to jump to him.

-- Commander of Heroes: tickets and points on top, then one row per squad - its type, health,
-- who's left and its two skills (click a skill = cast; aimed ones then want a click on the map)
function UI.drawSquadPanel(game)
  local world = game.world
  local SQ = require("src.squads")
  local list = SQ.squadsOf(world, 1)
  local w = lg.getWidth()
  local bw = UI.SCORE_W
  local rh = 58
  local x, y = w - bw - 10, (world.score and game.scoreBottom or UI.TOP_H) + 6
  local st = world.squads
  -- tickets
  local me = world.ally[1]
  local foe
  for a in pairs(st.tickets) do if a ~= me then foe = a end end
  local th = world.wih and 4 or 44 -- (War is Hell has no tickets)
  local bh = th + #list * rh + 8
  panelBox(x, y, bw, bh, 0.9)
  local cols = (world.mods and world.mods.groovy) and D.groovyColor or D.teamColor
  local function allyCol(a) for t = 1, world.np do if world.ally[t] == a then return cols[t] end end return { 1, 1, 1 } end
  local function bar(bx, by, frac, c, right)
    lg.setColor(0.12, 0.14, 0.18)
    lg.rectangle("fill", bx, by, (bw - 30) / 2, 9, 2)
    lg.setColor(c[1], c[2], c[3])
    local ww = (bw - 30) / 2 * math.max(0, frac)
    lg.rectangle("fill", right and (bx + (bw - 30) / 2 - ww) or bx, by, ww, 9, 2)
  end
  lg.setFont(font(12))
  if not world.wih then
  local mt, ft = math.max(0, math.floor(st.tickets[me] or 0)), math.max(0, math.floor(foe and st.tickets[foe] or 0))
  local mc, fc = allyCol(me), allyCol(foe)
  lg.setColor(mc[1], mc[2], mc[3]); lg.print(tostring(mt), x + 10, y + 5)
  local ft_s = tostring(ft)
  lg.setColor(fc[1], fc[2], fc[3]); lg.print(ft_s, x + bw - 10 - font(12):getWidth(ft_s), y + 5)
  local pm, pf = SQ.held(world, me), foe and SQ.held(world, foe) or 0
  local mid = string.format("Points %d - %d", pm, pf)
  lg.setColor(0.85, 0.88, 0.92); lg.print(mid, x + bw / 2 - font(12):getWidth(mid) / 2, y + 5)
  local full = st.full or {}
  st.full = full
  full[me] = math.max(full[me] or 0, mt); if foe then full[foe] = math.max(full[foe] or 0, ft) end
  bar(x + 10, y + 24, mt / math.max(1, full[me]), mc, true)
  bar(x + 20 + (bw - 30) / 2, y + 24, ft / math.max(1, foe and full[foe] or 1), fc, false)
  end
  game.squadRows = { { x = x, y = y, w = bw, h = th, header = true } }
  local mx, my = love.mouse.getPosition()
  local t = world.time
  for i, sq in ipairs(list) do
    local ry = y + th + (i - 1) * rh
    local alive, hp, max = 0, 0, 0
    for _, u in ipairs(sq.members) do
      max = max + u.maxhp
      if u.alive then alive = alive + 1; hp = hp + u.hp end
    end
    local L = sq.leader
    local up = L and L.alive
    local chosen = false
    for _, u in ipairs(sq.members) do if u.alive and game.selected[u] then chosen = true; break end end
    local isActive = chosen and sq == game:activeSquad()
    if chosen then
      local c = isActive and { 1, 0.8, 0.25 } or { 0.45, 0.7, 1 }
      lg.setColor(c[1], c[2], c[3], isActive and 0.14 or 0.07)
      lg.rectangle("fill", x + 3, ry - 2, bw - 6, rh - 2, 5)
      lg.setColor(c[1], c[2], c[3], isActive and 0.95 or 0.6)
      lg.setLineWidth(2)
      lg.rectangle("line", x + 3, ry - 2, bw - 6, rh - 2, 5)
      lg.setLineWidth(1)
    end
    lg.setFont(font(12))
    lg.setColor(up and 1 or 0.55, up and 0.92 or 0.55, up and 0.6 or 0.55)
    local nm = string.format("%d  %s  (%d)", i, SQ.byType[sq.type].name, alive)
    local inc = SQ.coming(sq)
    if inc > 0 then nm = nm .. string.format("  +%d coming", inc) end
    if not up and sq.respawnAt then nm = nm .. string.format("  leader %ds", math.max(0, math.ceil(sq.respawnAt - t))) end
    lg.print(nm, x + 10, ry + 2)
    local frac = max > 0 and hp / max or 0
    lg.setColor(0.12, 0.14, 0.18)
    lg.rectangle("fill", x + 10, ry + 19, bw - 20, 6, 2)
    lg.setColor(0.2 + (1 - frac) * 0.8, 0.3 + frac * 0.6, 0.15)
    lg.rectangle("fill", x + 10, ry + 19, (bw - 20) * frac, 6, 2)
    local abs = {}
    local bwid = (bw - 26) / 2
    for slot, sk in ipairs(sq.skills) do
      local def = SQ.SKILLS[sk.key]
      local bx, by = x + 10 + (slot - 1) * (bwid + 6), ry + 30
      local hov = mx >= bx and mx <= bx + bwid and my >= by and my <= by + 22
      local ready = up and t >= sk.readyAt
      local active = up and t < sk.untilT
      if active then lg.setColor(0.2, 0.5, 0.3)
      elseif ready then lg.setColor(hov and 0.24 or 0.17, hov and 0.3 or 0.22, hov and 0.4 or 0.3)
      else lg.setColor(0.1, 0.11, 0.14) end
      lg.rectangle("fill", bx, by, bwid, 22, 4)
      if up and not ready then
        -- cooldown fill
        local f = 1 - (sk.readyAt - t) / def.cd
        lg.setColor(0.3, 0.36, 0.46, 0.5)
        lg.rectangle("fill", bx, by, bwid * U.clamp(f, 0, 1), 22, 4)
      end
      local label = (slot == 1 and "Q " or "W ") .. def.name
      if up and not ready and not active then label = label .. string.format(" %d", math.ceil(sk.readyAt - t)) end
      lg.setFont(font(11))
      lg.setColor(1, 1, 1, up and (ready or active) and 1 or 0.55)
      lg.print(label, bx + bwid / 2 - font(11):getWidth(label) / 2, by + 5)
      abs[slot] = { x = bx, y = by, w = bwid, h = 22 }
      if hov then game.sqHoverSkill = def end
    end
    game.squadRows[#game.squadRows + 1] = { sq = sq, x = x, y = ry, w = bw, h = rh, abs = abs }
  end
  -- a skill's description when hovering its button
  local hs = game.sqHoverSkill
  if hs then
    lg.setFont(font(12))
    local tw = 260
    local _, lines = font(12):getWrap(hs.name .. ": " .. hs.desc, tw - 16)
    local hh = #lines * 15 + 12
    local hx, hy = x - tw - 8, math.min(my, lg.getHeight() - hh - 10)
    lg.setColor(0.04, 0.05, 0.08, 0.95)
    lg.rectangle("fill", hx, hy, tw, hh, 6)
    lg.setColor(0.9, 0.92, 0.96)
    lg.printf(hs.name .. ": " .. hs.desc, hx + 8, hy + 6, tw - 16)
  end
  game.sqHoverSkill = nil
  game.cardBottom = y + bh
end

function UI.squadPanelClick(game, x, y)
  local SQ = require("src.squads")
  for _, r in ipairs(game.squadRows or {}) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      if r.header then return true end
      for slot, b in ipairs(r.abs or {}) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
          local def = SQ.SKILLS[r.sq.skills[slot].key]
          if def.aim == "point" then
            game.mode, game.sqAim = "sqskill", { sq = r.sq, slot = slot }
            game:notice(def.name .. ": click the spot (Esc cancels)", 1.6)
          else
            game:squadSkill(slot, r.sq)
          end
          return true
        end
      end
      local g = {}
      for _, u in ipairs(r.sq.members) do if u.alive then g[#g + 1] = u end end
      game:select(g)
      if r.sq.leader and r.sq.leader.alive then game:centerOn(r.sq.leader.x, r.sq.leader.y) end
      return true
    end
  end
  return false
end

function UI.drawCommanderCard(game)
  if game.craft then return craftUI().drawHeroBar(game) end
  if game.world.squads then return UI.drawSquadPanel(game) end
  local world = game.world
  local c = world.teams[1].commander
  if not c or c.key ~= "commander" then return end -- (Post-Apocalypse has no Commander)
  local w = lg.getWidth()
  local bw, bh = UI.SCORE_W, 58
  local x, y = w - bw - 10, (world.score and game.scoreBottom or UI.TOP_H) + 6
  game.cmdCard = { x = x, y = y, w = bw, h = bh }
  local hitRecently = c.alive and world.time - (c.lastHit or -99) < 1.2
  panelBox(x, y, bw, bh, 0.86)
  if hitRecently then
    lg.setColor(1, 0.2, 0.15, 0.25 + 0.25 * math.sin(love.timer.getTime() * 14))
    lg.rectangle("fill", x, y, bw, bh, 6)
  end
  lg.setFont(font(13))
  lg.setColor(0.95, 0.85, 0.5)
  local A = world.heroes and require("src.arena")
  local cls = A and c.class and A.byClass[c.class]
  local L = c.clevel or 0
  lg.print(string.format("%s  Lv %d", cls and cls.name or "COMMANDER", L), x + 10, y + 6)
  -- status on the right
  local status, sc = nil, { 0.7, 0.8, 0.9 }
  if not c.alive then
    status = c.respawnAt and string.format("respawn %ds", math.max(0, math.ceil(c.respawnAt - world.time))) or "DESTROYED"
    sc = { 1, 0.4, 0.35 }
  elseif world:isFleeing(c) then status, sc = "fleeing", { 1, 0.75, 0.3 }
  elseif c.disarmed then status, sc = "powered down", { 1, 0.75, 0.3 }
  elseif c.healing and c.healing > 0 and c.hp < c.maxhp then status, sc = "repairing", { 0.5, 1, 0.6 }
  elseif hitRecently then status, sc = "UNDER FIRE", { 1, 0.4, 0.35 }
  elseif c.stance then
    status = (c.stance == "avatar" and "AVATAR" or c.stance:upper()) .. " stance"
    sc = { 0.95, 0.8, 0.45 }
  end
  if status then
    lg.setFont(font(11))
    lg.setColor(sc[1], sc[2], sc[3])
    lg.print(status, x + bw - 10 - font(11):getWidth(status), y + 8)
  end
  -- health
  local frac = c.alive and c.hp / c.maxhp or 0
  lg.setColor(0.12, 0.14, 0.18)
  lg.rectangle("fill", x + 10, y + 26, bw - 20, 12, 3)
  lg.setColor(0.2 + (1 - frac) * 0.8, 0.3 + frac * 0.6, 0.15)
  lg.rectangle("fill", x + 10, y + 26, (bw - 20) * frac, 12, 3)
  lg.setFont(font(10))
  lg.setColor(1, 1, 1)
  local ht = c.alive and string.format("%d / %d", math.floor(c.hp), c.maxhp) or "-"
  lg.print(ht, x + bw / 2 - font(10):getWidth(ht) / 2, y + 26)
  game.cardBottom = y + bh
  -- XP
  local xf, _, max = R.cmdXP(c)
  lg.setColor(0.1, 0.08, 0.2)
  lg.rectangle("fill", x + 10, y + 43, bw - 20, 6, 2)
  if max then lg.setColor(1, 0.85, 0.3) else lg.setColor(0.65, 0.55, 1) end
  lg.rectangle("fill", x + 10, y + 43, (bw - 20) * xf, 6, 2)
end

-- Arena jungle maps: who holds which shrine and what it's worth, the Crest, and the Colossus
-- Arena: each side's creep level (creeps level together from enemy creeps they kill; a deny
-- keeps that kill from the enemy), progress to the next level, and denies
function UI.drawLanePanel(game)
  local world = game.world
  local st = world.arena
  if not st or not st.nSides then return end
  local A = require("src.arena")
  local w = lg.getWidth()
  local mySide = st.teamSide[1]
  local bw = UI.SCORE_W
  local bh = 26 + st.nSides * 22 + 2
  local x = w - bw - 10
  local y = game.jungleRect and (game.jungleRect.y + game.jungleRect.h + 6) or ((game.cardBottom or (UI.TOP_H + 200)) + 6)
  panelBox(x, y, bw, bh, 0.86)
  lg.setFont(font(12))
  lg.setColor(0.95, 0.85, 0.5)
  lg.print("CREEPS", x + 10, y + 6)
  lg.setColor(0.6, 0.66, 0.74)
  local hd = "level        denies"
  lg.print(hd, x + bw - 10 - font(12):getWidth(hd), y + 6)
  local yy = y + 26
  for side = 1, st.nSides do
    local cr, cg, cb = R.teamColor(st.sideOwner[side])
    lg.setColor(cr, cg, cb)
    lg.rectangle("fill", x + 10, yy + 3, 10, 10, 2)
    lg.setColor(side == mySide and 1 or 0.8, side == mySide and 1 or 0.8, side == mySide and 1 or 0.8)
    lg.print(side == mySide and "Your side" or (st.ffa and D.teamName[st.sideOwner[side]] or "Enemy"), x + 26, yy)
    -- level and a bar toward the next one
    local L = (st.creepLvl and st.creepLvl[side]) or 0
    local bar = (st.creepBar and st.creepBar[side]) or 0
    local bx, bwid = x + 112, 74
    lg.setColor(1, 0.85, 0.35)
    lg.print("Lv " .. L, bx, yy)
    lg.setColor(0.15, 0.17, 0.22)
    lg.rectangle("fill", bx + 34, yy + 5, bwid - 34, 6, 2)
    local f = L >= A.CREEP_MAX and 1 or math.min(1, bar / A.creepNeed(L))
    lg.setColor(1, 0.8, 0.3)
    lg.rectangle("fill", bx + 34, yy + 5, (bwid - 34) * f, 6, 2)
    local d = st.denies and st.denies[side]
    local dt = tostring(d and d.n or 0)
    lg.setColor(0.75, 0.9, 1)
    lg.print(dt, x + bw - 10 - font(12):getWidth(dt), yy)
    yy = yy + 22
  end
end

function UI.drawJunglePanel(game)
  local world = game.world
  local st = world.arena
  local j = st and st.jungle
  if not j then return end
  local J = require("src.jungle")
  local w = lg.getWidth()
  local t = world.time
  local mySide = st.teamSide[1]
  -- one line per side that holds something, then the Colossus
  local lines = {}
  for side = 1, st.nSides do
    local held = 0
    for _, sh in ipairs(j.shrines) do if sh.owner == side then held = held + 1 end end
    local crest = j.crest[side] and t < j.crest[side] and (j.crest[side] - t) or nil
    if held > 0 or crest or side == mySide then
      lines[#lines + 1] = { side = side, held = held, crest = crest }
    end
  end
  local bw = UI.SCORE_W
  local crests = 0
  for _, l in ipairs(lines) do if l.crest then crests = crests + 1 end end
  local bh = 26 + #lines * 20 + crests * 18 + 20
  local x, y = w - bw - 10, (game.cardBottom or (UI.TOP_H + 200)) + 6
  panelBox(x, y, bw, bh, 0.86)
  lg.setFont(font(12))
  lg.setColor(0.72, 0.42, 1)
  lg.print("JUNGLE", x + 10, y + 6)
  lg.setColor(0.6, 0.66, 0.74)
  local free = 0
  for _, sh in ipairs(j.shrines) do if not sh.owner then free = free + 1 end end
  local note = t < J.SHRINE_FIRST and string.format("shrines open in %ds", math.ceil(J.SHRINE_FIRST - t))
    or (free > 0 and (free .. " shrine" .. (free > 1 and "s" or "") .. " unclaimed") or "")
  lg.print(note, x + bw - 10 - font(12):getWidth(note), y + 6)
  local yy = y + 26
  for _, l in ipairs(lines) do
    local friend = l.side == mySide
    local cr, cg, cb = R.teamColor(st.sideOwner[l.side])
    lg.setColor(cr, cg, cb)
    lg.rectangle("fill", x + 10, yy + 3, 10, 10, 2)
    lg.setColor(1, 1, 1, 0.92)
    lg.print(friend and "Your side" or (st.ffa and D.teamName[st.sideOwner[l.side]] or "Enemy"), x + 26, yy)
    local bx = x + 100
    for k = 1, l.held do
      lg.setColor(cr, cg, cb)
      lg.polygon("fill", bx + 5, yy + 1, bx + 10, yy + 8, bx + 5, yy + 15, bx, yy + 8)
      bx = bx + 13
    end
    local txt = l.held > 0 and string.format("+%d%% speed & dmg", math.floor(J.SHRINE_BONUS * 100 * l.held + 0.5)) or "no shrines"
    if l.held > 0 then lg.setColor(0.85, 0.9, 0.95) else lg.setColor(0.55, 0.6, 0.66) end
    lg.print(txt, math.max(bx + 4, x + 128), yy)
    yy = yy + 20
    if l.crest then
      lg.setColor(1, 0.8, 0.35)
      lg.setFont(font(11))
      lg.print(string.format("Crest %d:%02d: +20%% dmg, tougher creeps", math.floor(l.crest / 60), math.floor(l.crest % 60)), x + 26, yy - 1)
      lg.setFont(font(12))
      yy = yy + 18
    end
  end
  -- the Colossus
  local ctext
  if j.boss and j.boss.alive then ctext = string.format("Colossus AWAKE  %d%%", math.floor(j.boss.hp / j.boss.maxhp * 100 + 0.5))
  elseif #j.pits > 0 then
    local left = math.max(0, j.bossAt - t)
    ctext = string.format("Colossus %s %d:%02d", j.boss == nil and t < J.BOSS_FIRST and "wakes in" or "returns in", math.floor(left / 60), math.floor(left % 60))
  end
  if ctext then
    lg.setColor(1, 0.6, 0.45)
    lg.print(ctext, x + 10, yy)
  end
  game.jungleRect = { x = x, y = y, w = bw, h = bh }
end

function UI.cmdCardClick(game, x, y)
  if game.craft then return craftUI().heroBarClick(game, x, y) end
  if game.world.squads then return UI.squadPanelClick(game, x, y) end
  local r = game.cmdCard
  if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
    local c = game.world.teams[1].commander
    if c and c.alive then game:centerOn(c.x, c.y); game:select({ c }) end
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Sidebar: every factory and builder, one click away

UI.SIDE_W = 132
local TILE = 58

function UI.sidebarItems(game)
  if game.arena then return {} end
  local facs, blds = {}, {}
  if game.craft then
    facs, blds = craftUI().sidebarLists(game)
  else
  for _, e in ipairs(game.world.entities) do
    if e.alive and e.team == 1 and e.built >= 1 then
      if e.def.factory then facs[#facs + 1] = e
      elseif e.def.builds then blds[#blds + 1] = e end
    end
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
  if game.arena then return end
  if not game.showSidebar then return end
  local items, nf, nb = UI.sidebarItems(game)
  if nf + nb == 0 then return end
  local mx, my = love.mouse.getPosition()
  lg.setFont(font(11))
  lg.setColor(0.6, 0.66, 0.74)
  lg.print(game.craft and "MAKE" or "PLANTS", 8, UI.TOP_H + 6)
  lg.print(game.craft and "HEROES" or "BUILD", 6 + TILE + 8, UI.TOP_H + 6)
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
        local ik = e.key
        if e.key == "commander" and e.class and require("src.icons").has("cls_" .. e.class) then ik = "cls_" .. e.class end
        UI.drawIcon(ik, it.x + it.w / 2, it.y + 24, 34, 1)
        lg.setFont(font(10))
        local o = e.orders[1]
        local txt = idle and "idle" or (o.type == "build" and D.units[o.key].short or (o.type == "repairzone" and "zone" or o.type))
        lg.setColor(idle and 1 or 0.7, idle and 0.65 or 0.8, idle and 0.2 or 0.86)
        lg.print(txt, it.x + it.w / 2 - font(10):getWidth(txt) / 2, it.y + it.h - 15)
        -- health sliver
        lg.setColor(0.3, 0.9, 0.4)
        lg.rectangle("fill", it.x + 4, it.y + it.h - 4, (it.w - 8) * e.hp / e.maxhp, 2)
        if e.key == "commander" then
          -- level and XP toward the next upgrade
          local frac, L, max = R.cmdXP(e)
          lg.setColor(0.15, 0.15, 0.25)
          lg.rectangle("fill", it.x + 4, it.y + it.h - 1, it.w - 8, 2)
          if max then lg.setColor(1, 0.85, 0.3) else lg.setColor(0.6, 0.5, 1) end
          lg.rectangle("fill", it.x + 4, it.y + it.h - 1, (it.w - 8) * frac, 2)
          lg.setFont(font(10))
          lg.setColor(1, 0.85, 0.4)
          lg.print("Lv" .. L, it.x + 4, it.y + 2)
        end
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
  -- the Power Core node
  if map.coreNode then
    lg.setColor(0.4, 0.85, 1, 0.95)
    local cx, cy = mm.x + (map.coreNode.x + 1) * s, mm.y + (map.coreNode.y + 1) * s
    lg.polygon("fill", cx, cy - 4, cx + 4, cy, cx, cy + 4, cx - 4, cy)
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
          if e.key == "commander" then
            local c = R.REL_COLOR[R.relation(e.team)]
            lg.setColor(c[1], c[2], c[3], 0.95)
            lg.setLineWidth(1.5)
            lg.circle("line", px, py, 5.5)
          end
        end
      end
    end
  end
  if world.arena and world.arena.jungle then require("src.jungle").drawMinimap(world, mm, s) end
  -- Commander of Heroes: the active squad's leader in gold
  if world.squads then
    local act = game:activeSquad()
    local L = act and act.leader
    if L and L.alive then
      local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 5)
      lg.setColor(1, 0.82, 0.25, 0.7 + 0.3 * pulse)
      lg.setLineWidth(2)
      lg.circle("line", mm.x + L.x / T * s, mm.y + L.y / T * s, 6 + pulse * 1.5)
      lg.setLineWidth(1)
    end
  end
  -- Commander of Heroes: capture points as flags in their owner's color
  for _, p in ipairs(world.capPoints or {}) do
    local c = { 0.85, 0.85, 0.85 }
    if p.owner then for t = 1, world.np do if world.ally[t] == p.owner then c = { R.teamColor(t) }; break end end end
    local px, py = mm.x + p.x / T * s, mm.y + p.y / T * s
    lg.setColor(0, 0, 0, 0.8)
    lg.circle("fill", px, py, 5)
    lg.setColor(c[1], c[2], c[3])
    lg.circle("fill", px, py, 3.6)
    if p.contested then lg.setColor(1, 1, 1, 0.5 + 0.5 * math.sin(love.timer.getTime() * 8)); lg.circle("line", px, py, 6.5) end
  end
  local a = world.alien
  if a and (a.state == "announced" or a.state == "dormant") then
    local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 4)
    lg.setColor(0.8, 0.45, 1, 0.6 + 0.4 * pulse)
    lg.setLineWidth(2)
    lg.circle("line", mm.x + a.x / T * s, mm.y + a.y / T * s, 6 + pulse * 2)
  end
  for _, n in ipairs(world.nukes or {}) do
    lg.setColor(1, 0.2, 0.1, 0.9)
    lg.circle("line", mm.x + n.tx / T * s, mm.y + n.ty / T * s, 7)
  end
  -- pings: expanding rings and a blinking cross for ~5 seconds
  if game.mmPings then
    local now = love.timer.getTime()
    local keep = {}
    for _, p in ipairs(game.mmPings) do
      local age = now - p.t0
      if age < 5 then
        keep[#keep + 1] = p
        local px, py = mm.x + p.x / T * s, mm.y + p.y / T * s
        local c = p.col
        lg.setLineWidth(2)
        for k = 0, 1 do
          local f = ((age + k * 0.5) % 1)
          lg.setColor(c[1], c[2], c[3], (1 - f) * (1 - age / 5))
          lg.circle("line", px, py, 4 + f * 16)
        end
        if math.floor(age * 4) % 2 == 0 then
          lg.setColor(1, 1, 1, 0.95)
          lg.line(px - 5, py - 5, px + 5, py + 5)
          lg.line(px - 5, py + 5, px + 5, py - 5)
        end
      end
    end
    game.mmPings = keep
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

-- Commander of Heroes: every squad as a card along the bottom. Selected squads are outlined;
-- the ACTIVE one (gold) is the one Q / W fire for - C cycles it within the selection.
-- Hover a skill for what it does; click it to cast (aimed skills then want a click on the map).
local function skillState(sq, slot, t)
  local SQ = require("src.squads")
  local sk = sq.skills[slot]
  local def = SQ.SKILLS[sk.key]
  local up = sq.leader and sq.leader.alive
  if not up then return def, "leader down", false, false end
  if t < sk.untilT then return def, string.format("on %ds", math.ceil(sk.untilT - t)), true, true end
  if t < sk.readyAt then return def, string.format("%ds", math.ceil(sk.readyAt - t)), false, false end
  return def, "ready", true, false
end

-- Commander of Heroes: what the ground under the mouse does
function UI.drawTerrainHover(game)
  local world = game.world
  if not world.squads then return end
  local mx, my = love.mouse.getPosition()
  if UI.overPanel(game, mx, my) then return end
  local wx, wy = game:screenToWorld(mx, my)
  local SQ = require("src.squads")
  local text, col
  if SQ.inBunker(world, wx, wy) then
    text, col = string.format("BUNKER: units inside take %d%% less damage, but see %d%% less", math.floor((1 - SQ.BUNKER_TAKEN) * 100 + 0.5), math.floor((1 - SQ.BUNKER_SIGHT) * 100 + 0.5)), { 0.7, 0.85, 0.6 }
  else
    local tx, ty = world.map:tileAt(wx, wy)
    if world.map:inBounds(tx, ty) and world.map:terrainAt(tx, ty) == 2 and (world.noFog or world.explored[ty * world.map.w + tx]) then
      text, col = string.format("HIGH GROUND: units here see %d%% further, but take %d%% more damage", math.floor((SQ.HILL_SIGHT - 1) * 100 + 0.5), math.floor((SQ.HILL_TAKEN - 1) * 100 + 0.5)), { 0.86, 0.68, 0.38 }
    end
  end
  if not text then return end
  lg.setFont(font(12))
  local tw = font(12):getWidth(text) + 16
  local x, y = math.min(mx + 18, lg.getWidth() - tw - 6), my + 20
  lg.setColor(0.04, 0.05, 0.08, 0.88)
  lg.rectangle("fill", x, y, tw, 22, 5)
  lg.setColor(col[1], col[2], col[3])
  lg.print(text, x + 8, y + 4)
end

function UI.drawSquadInfo(game, L)
  local SQ = require("src.squads")
  local world = game.world
  local t = world.time
  local list = SQ.squadsOf(world, 1)
  local x, y = L.infoX, L.panelY + 10
  local w = lg.getWidth() - x - 14
  local sel = {}
  for _, sq in ipairs(game:selectedSquads()) do sel[sq] = true end
  local active = game:activeSquad()
  local n = math.max(#list, 1)
  local gap = 8
  local cw = math.min(210, (w - gap * (n - 1)) / n)
  local ch = UI.PANEL_H - 22
  game.sqInfoBtns, game.sqCards = {}, {}
  local mx, my = love.mouse.getPosition()
  local tip
  for i, sq in ipairs(list) do
    local cx = x + (i - 1) * (cw + gap)
    local isA, isS = sq == active, sel[sq]
    local up = sq.leader and sq.leader.alive
    -- the card
    if isA then lg.setColor(0.24, 0.19, 0.07) elseif isS then lg.setColor(0.1, 0.16, 0.24) else lg.setColor(0.09, 0.11, 0.14) end
    lg.rectangle("fill", cx, y, cw, ch, 6)
    if isA then lg.setColor(1, 0.8, 0.25); lg.setLineWidth(2.5)
    elseif isS then lg.setColor(0.45, 0.7, 1); lg.setLineWidth(1.5)
    else lg.setColor(0.25, 0.3, 0.38); lg.setLineWidth(1) end
    lg.rectangle("line", cx + 0.5, y + 0.5, cw - 1, ch - 1, 6)
    lg.setLineWidth(1)
    -- name, count, who's coming
    local ty = SQ.byType[sq.type]
    local alive = 0
    local hp, max = 0, 0
    for _, u in ipairs(sq.members) do
      max = max + u.maxhp
      if u.alive then alive = alive + 1; hp = hp + u.hp end
    end
    lg.setFont(font(14))
    lg.setColor(isA and 1 or 0.92, isA and 0.85 or 0.92, isA and 0.4 or 0.95)
    lg.print(string.format("%d  %s", i, ty.name), cx + 8, y + 6)
    -- flee just this squad (Alt+number does the same)
    if alive > 0 then
      local fb = { x = cx + cw - 50, y = y + 5, w = 44, h = 20 }
      local fh = mx >= fb.x and mx <= fb.x + fb.w and my >= fb.y and my <= fb.y + fb.h
      lg.setColor(fh and 0.5 or 0.3, fh and 0.22 or 0.14, 0.12)
      lg.rectangle("fill", fb.x, fb.y, fb.w, fb.h, 4)
      lg.setFont(font(11))
      lg.setColor(1, 0.85, 0.75)
      lg.print("Flee", fb.x + fb.w / 2 - font(11):getWidth("Flee") / 2, fb.y + 3)
      game.sqInfoBtns[#game.sqInfoBtns + 1] = { x = fb.x, y = fb.y, w = fb.w, h = fb.h, sq = sq, flee = true }
      if fh then tip = { text = string.format("Flee: squad %d falls back to the HQ (heals there); weapons off until repaired. Alt+%d does the same. Your selection stays as it is.", i, i), x = fb.x } end
    end
    lg.setFont(font(11))
    lg.setColor(0.75, 0.8, 0.88)
    local un = D.units[ty.unit].name
    local sub = string.format("%d / %d %s", alive, ty.size, un .. (un:match("y$") and "" or "s"))
    local inc = SQ.coming(sq)
    if inc > 0 then sub = sub .. string.format("  +%d", inc) end
    lg.print(sub, cx + 8, y + 26)
    local frac = max > 0 and hp / max or 0
    lg.setColor(0.12, 0.14, 0.18)
    lg.rectangle("fill", cx + 8, y + 43, cw - 16, 6, 2)
    lg.setColor(0.2 + (1 - frac) * 0.8, 0.3 + frac * 0.6, 0.15)
    lg.rectangle("fill", cx + 8, y + 43, (cw - 16) * frac, 6, 2)
    if not up and sq.respawnAt then
      lg.setColor(1, 0.55, 0.45)
      lg.print(string.format("leader back in %ds", math.max(0, math.ceil(sq.respawnAt - t))), cx + 8, y + 52)
    else
      -- the ground they're on: high ground (+sight, +damage taken) or a bunker (-damage, -sight)
      local nh, nb = 0, 0
      for _, u in ipairs(sq.members) do if u.alive then if u.onHill then nh = nh + 1 elseif u.inBunker then nb = nb + 1 end end end
      lg.setFont(font(10))
      local tx = cx + 8
      if nh > 0 then
        lg.setColor(0.86, 0.68, 0.38); lg.print(string.format("^ %d high ground", nh), tx, y + 51); tx = tx + 92
      end
      if nb > 0 then
        lg.setColor(0.7, 0.85, 0.6); lg.print(string.format("# %d in bunker", nb), tx, y + 51)
      end
    end
    -- the two skills
    for slot = 1, 2 do
      local def, st, ok, on = skillState(sq, slot, t)
      -- side by side, so the crew's names fit underneath
      local half = (cw - 18) / 2
      local bx, by, bw, bh = cx + 6 + (slot - 1) * (half + 6), y + 66, half, 30
      local hov = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
      if on then lg.setColor(0.2, 0.48, 0.3)
      elseif ok then lg.setColor(hov and 0.26 or 0.17, hov and 0.33 or 0.22, hov and 0.46 or 0.3)
      else lg.setColor(0.08, 0.09, 0.12) end
      lg.rectangle("fill", bx, by, bw, bh, 5)
      if up and not ok and not on then
        lg.setColor(0.3, 0.36, 0.46, 0.45)
        lg.rectangle("fill", bx, by, bw * U.clamp(1 - (sq.skills[slot].readyAt - t) / def.cd, 0, 1), bh, 5)
      end
      lg.setColor(hov and 1 or 0.45, hov and 0.85 or 0.55, hov and 0.4 or 0.68, 0.9)
      lg.rectangle("line", bx + 0.5, by + 0.5, bw - 1, bh - 1, 5)
      lg.setFont(font(11))
      lg.setColor(1, 1, 1, (ok or on) and 1 or 0.55)
      local key = isA and (slot == 1 and "Q " or "W ") or ""
      local label = key .. def.name
      while #label > 4 and font(11):getWidth(label) > bw - 8 do label = label:sub(1, -2) end
      lg.print(label, bx + 5, by + 2)
      lg.setFont(font(10))
      lg.setColor(on and 0.6 or 0.8, on and 1 or 0.85, on and 0.6 or 0.9, (ok or on) and 1 or 0.6)
      lg.print(st, bx + 5, by + 16)
      game.sqInfoBtns[#game.sqInfoBtns + 1] = { x = bx, y = by, w = bw, h = bh, sq = sq, slot = slot }
      if hov then tip = { def = def, x = bx, y = by, sq = sq } end
    end
    -- the crew by name: the living first (leader starred), then the fallen
    local rows = {}
    for _, u in ipairs(sq.roster or {}) do if u.alive then rows[#rows + 1] = u end end
    for k = #(sq.roster or {}), 1, -1 do local u = sq.roster[k]; if not u.alive then rows[#rows + 1] = u end end
    lg.setFont(font(10))
    for k = 1, math.min(5, #rows) do
      local u = rows[k]
      local ry = y + 100 + (k - 1) * 11.5
      local nm = (u == sq.leader and u.alive and "* " or "  ") .. (u.callsign or u.def.name)
      if u.alive then
        lg.setColor(u == sq.leader and 1 or 0.85, u == sq.leader and 0.85 or 0.88, u == sq.leader and 0.4 or 0.92)
        lg.print(nm, cx + 8, ry)
        if u.onHill then lg.setColor(0.86, 0.68, 0.38); lg.print("^", cx + cw - 58, ry)
        elseif u.inBunker then lg.setColor(0.7, 0.85, 0.6); lg.print("#", cx + cw - 58, ry) end
        local f = u.hp / u.maxhp
        lg.setColor(0.12, 0.14, 0.18)
        lg.rectangle("fill", cx + cw - 46, ry + 3, 38, 5, 1)
        lg.setColor(0.2 + (1 - f) * 0.8, 0.3 + f * 0.6, 0.15)
        lg.rectangle("fill", cx + cw - 46, ry + 3, 38 * f, 5, 1)
      else
        lg.setColor(0.6, 0.3, 0.28, 0.85)
        lg.print(nm .. "  KIA", cx + 8, ry)
      end
    end
    game.sqCards[#game.sqCards + 1] = { x = cx, y = y, w = cw, h = ch, sq = sq }
  end
  -- a skill's tooltip, above the panel
  if tip then
    local d = tip.def
    local text = tip.text or (d.name .. (d.aim == "point" and "  (aimed: click the map, or Q/W at the mouse)" or "  (around the leader)")
      .. "\n" .. d.desc .. string.format("\nCooldown %ds", d.cd))
    lg.setFont(font(12))
    local tw = 300
    local _, lines = font(12):getWrap(text, tw - 16)
    local th = #lines * 15 + 14
    local tx = U.clamp(tip.x, 8, lg.getWidth() - tw - 8)
    local ty2 = L.panelY - UI.ORDERS_H - th - 8
    lg.setColor(0.04, 0.05, 0.08, 0.96)
    lg.rectangle("fill", tx, ty2, tw, th, 6)
    lg.setColor(1, 0.8, 0.25, 0.8)
    lg.rectangle("line", tx + 0.5, ty2 + 0.5, tw - 1, th - 1, 6)
    lg.setColor(0.92, 0.94, 0.97)
    lg.printf(text, tx + 8, ty2 + 7, tw - 16)
  end
end

function UI.drawInfo(game, L)
  local list = game:selectedList()
  local x, y, w = L.infoX, L.panelY + 12, L.infoW
  local foreign = false
  game.sqInfoBtns = nil
  if game.world.squads and not (#list == 0 and game:inspectValid()) then return UI.drawSquadInfo(game, L) end
  if #list == 0 and game:inspectValid() then list = { game.inspect }; foreign = true end
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
    UI.drawIcon((e.key == "commander" and e.class and require("src.icons").has("cls_" .. e.class)) and ("cls_" .. e.class) or e.key, x + 32, y + 32, 56, 1)
    lg.setFont(font(17))
    lg.setColor(1, 1, 1)
    local title = d.name
    if e.key == "commander" and e.class and game.world.heroes then
      -- heroes go by their class (Craft and Arena), not "Commander"
      title = (require("src.arena").byClass[e.class] or { name = e.class }).name
    end
    lg.print(title, x + 72, y + 2)
    if foreign then
      local wld = game.world
      local who = e.key == "goldmine" and "Neutral" or (e.team == 0 and "Neutral creep" or
        ((wld:hostile(e.team, 1) and "Enemy" or "Ally") .. " - " .. (D.teamName[e.team] or ("team " .. e.team))))
      local tw = font(17):getWidth(title)
      lg.setFont(font(13))
      local hc = e.team == 0 and { 0.95, 0.8, 0.4 } or (wld:hostile(e.team, 1) and { 1, 0.45, 0.4 } or { 0.5, 1, 0.6 })
      lg.setColor(hc)
      lg.print("(" .. who .. ")", x + 82 + tw, y + 5)
    end
    lg.setFont(font(12))
    lg.setColor(0.75, 0.8, 0.86)
    local hpTxt = string.format("HP %d / %d", math.max(0, e.hp), e.maxhp)
    if e.built < 1 then hpTxt = hpTxt .. string.format("    Under construction %d%%", e.built * 100) end
    if e.disarmed then hpTxt = hpTxt .. "    WEAPONS OFFLINE until fully repaired" end
    if e.key == "commander" and game.world.heroes then
      e.arenaDesc = true
      local A = require("src.arena")
      local L = e.clevel or 0
      local cls = A.byClass[e.class]
      hpTxt = hpTxt .. string.format("    %s  level %d", cls and cls.name or "", L)
      if L < A.MAX_LEVEL then hpTxt = hpTxt .. string.format("   XP %d / %d", e.cxp or 0, A.THRESHOLDS[L + 1]) end
      if e.atBase == nil and e.respawnAt then hpTxt = hpTxt .. "   (respawning)" end
    elseif e.key == "commander" then
      local CMD = require("src.commander")
      local L = e.clevel or 0
      if L >= CMD.MAX_LEVEL then hpTxt = hpTxt .. "    Commander level 5 (max)"
      else hpTxt = hpTxt .. string.format("    Commander level %d   XP %d / %d (earn it with his own kills)", L, e.cxp or 0, CMD.THRESHOLDS[L + 1]) end
    elseif game.craft then
      if e.key == "goldmine" then hpTxt = string.format("%d / %d gold left", e.gold, e.goldMax) end
      if e.carry then hpTxt = hpTxt .. string.format("    carrying %d %s", e.carry.amount, e.carry.kind) end
      if d.food and d.building then hpTxt = hpTxt .. string.format("    +%d food", d.food) end
    elseif d.weapon and e.built >= 1 then
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
    local desc = d.desc or ""
    local arenaCmd = game.world.heroes and e.key == "commander"
    if arenaCmd then
      local cls = require("src.arena").byClass[e.class]
      desc = cls and (cls.name .. ": " .. cls.tag .. (game.craft and "  Rises again at your altar when slain." or "  He respawns at your Core when destroyed.")) or desc
    end
    lg.printf(desc, x + 72, y + 44, w - 80)
    local info = {}
    if d.weapon then
      local tg = {}
      for k in pairs(d.weapon.targets) do tg[#tg + 1] = k end
      table.sort(tg)
      if arenaCmd then
        local m = e.mods or {}
        local dmg = d.weapon.damage * (m.dmg or 1)
        info[#info + 1] = string.format("%s: %d dmg, range %d", m.melee and "Melee" or "Ranged", dmg, game.world:rangeOf(e))
      else
        if game.craft then
          local m = e.mods or {}
          info[#info + 1] = string.format("%s: %d dmg, range %d%s", d.melee and "Melee" or (d.weapon.ballistic and "Siege" or "Ranged"),
            d.weapon.damage * (m.craftDmg or 1), game.world:rangeOf(e), d.weapon.targets.air and ", hits air" or "")
        else
        info[#info + 1] = string.format("Weapon: %d dmg, range %d, hits %s", d.weapon.damage, d.weapon.range, table.concat(tg, "/"))
        if d.aaWeapon then info[#info + 1] = string.format("Anti-air: %d dmg, range %d", d.aaWeapon.damage, d.aaWeapon.range) end
        end
      end
    end
    if d.income and not arenaCmd then
      info[#info + 1] = string.format("Produces %s%s", d.income.metal and string.format("%.1f metal/s ", d.income.metal) or "",
        d.income.energy and string.format("%d energy/s", d.income.energy) or "")
    end
    if d.speed then info[#info + 1] = string.format("Speed %d   Sight %d", d.speed, d.sight) end
    lg.setColor(0.55, 0.75, 0.95)
    lg.print(table.concat(info, "     "), x + 72, y + 84)
    if e.key == "commander" and e.upgrades and game.world.heroes then
      local names = {}
      for _, u in ipairs(e.upgrades) do names[#names + 1] = u.name end
      lg.setFont(font(13))
      lg.setColor(0.95, 0.85, 0.5)
      lg.print("Upgrades: " .. (#names > 0 and table.concat(names, ", ") or "none yet"), x + 72, y + 126)
    elseif e.key == "commander" and e.upgrades then
      local names = {}
      for _, u in ipairs(e.upgrades) do names[#names + 1] = u.name end
      local nuke = ""
      if e.nukeReady then
        local left = e.nukeReady - game.world.time
        nuke = left <= 0 and "    NUKE READY (N)" or string.format("    Nuke recharging %d:%02d", math.floor(left / 60), math.floor(left % 60))
      end
      lg.setColor(1, 0.85, 0.35)
      lg.print("Upgrades: " .. (#names > 0 and table.concat(names, ", ") or "none yet") .. nuke, x + 72, y + 126)
    end
    -- factory queue
    if d.factory and e.built >= 1 and not foreign then
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
    elseif e.orders and #e.orders > 0 and not foreign then
      local o = e.orders[1]
      local names = { move = "Moving", amove = "Attack-moving", attack = "Attacking", patrol = "Patrolling", build = "Building", assist = "Assisting", retreat = "Retreating (weapons off)", repairzone = "On repair-zone duty" }
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
  if ctx and game.craft then
    -- Commander Craft: a 5 x 3 grid of smaller buttons
    local bs, cols = 56, 5
    local cx = L.cardX + L.cardW - cols * (bs + 5) + 5
    for i, key in ipairs(list) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      btns[#btns + 1] = { x = cx + col * (bs + 5), y = L.cardY - 4 + row * (bs + 5), w = bs, h = bs,
        kind = ctx, key = key, slot = i, hotkey = UI.CRAFT_KEYS[i] }
    end
    return btns
  end
  if ctx then
    -- nine buttons (the Refinery with Metal Alert on) get a fifth column instead of a third row
    local cols = #list > 2 * COLS and COLS + 1 or COLS
    local cx0 = L.cardX - (cols - COLS) * (BTN + 6)
    for i, key in ipairs(list) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      btns[#btns + 1] = {
        x = cx0 + col * (BTN + 6), y = L.cardY + row * (BTN + 6), w = BTN, h = BTN,
        kind = ctx, key = key, slot = i, hotkey = D.hotkeys[i],
      }
    end
  end
  return btns
end

---------------------------------------------------------------------------
-- Orders bar: every order as a visible button just above the bottom panel, so nobody
-- has to find the keyboard shortcuts first. Hover for what it does.

local ORDERS = {
  { "amove", "Attack", "A", "Attack-move: click a spot; units fight anything on the way." },
  { "stop", "Stop", "S", "Stop: cancel orders and hold position." },
  { "hold", "Hold", "D", "Hold fire: selected units stop shooting while you hold D (or until you click again), so you can time the killing shot." },
  { "patrol", "Patrol", "P", "Patrol: walk back and forth to a spot, fighting what they meet. Constructors: drag a circle to make a repair zone - they stay and fix everything of yours inside it." },
  { "flee", "Flee", "F", "Retreat to your flag at +25% speed - or, with no flag set, back to the plant that built each unit. Weapons stay OFF until fully repaired." },
  { "fleecmd", "To Cmdr", "Shift+F", "Retreat to the Commander (+25% speed, weapons off until repaired)." },
  { "flag", "Flag", "Ctrl+F", "Plant the retreat flag: click where fleeing units should go." },
  { "destroy", "Destroy", "Del", "Self-destruct the selection. Unfinished buildings refund. Commander needs 2 presses." },
  { "army", "Army", "Ctrl+A", "Select every combat unit you have." },
  { "half", "Half", "H", "Keep half the selection (same mix, nearest the mouse). Shift-click: the other half." },
  { "builder", "Builder", "Tab", "Jump to the next idle constructor." },
  { "cmd", "Cmdr", "C", "Jump to and select your Commander." },
  { "follow", "Follow", "L", "Camera follows the selection. Shift-click: cinematic camera." },
  { "repeat", "Repeat", "G", "Factory repeats its build queue forever." },
  { "nuke", "NUKE", "N", "Commander level 5: launch the Nuke, then click a target." },
  { "help", "Help", "F1", "All controls and tips." },
}
UI.ORDERS_H = 38

local ARENA_ORDERS = {
  { "amove", "Attack", "A", "Attack-move: click a spot; your Commander fights anything on the way." },
  { "stop", "Stop", "S", "Stop and hold position." },
  { "hold", "Hold", "D", "Hold fire while D is held (or click to toggle) - time your last hits. Right-click your own creep under 35% health to deny it: nobody gets its XP." },
  { "home", "Flee", "F", "Flee to your Core at +50% speed: no shooting, and it can't be cancelled. The Core heals you fast." },
  { "skill1", nil, "Q" }, { "skill2", nil, "W" }, { "skill3", nil, "E" }, { "skill4", nil, "R" },
  { "cmd", "Cmdr", "C", "Jump to and select your Commander." },
  { "follow", "Follow", "L", "Camera follows your Commander. Shift-click: cinematic camera." },
  { "help", "Help", "F1", "All controls and tips." },
}

function UI.orderButtons(game)
  local w, h = lg.getDimensions()
  if game.craft then return craftUI().orderButtons(game) end
  if game.arena then
    local A = require("src.arena")
    local c = game.world.teams[1].commander
    local list = {}
    local gap = 4
    local total = 0
    for _, o in ipairs(ARENA_ORDERS) do
      local bw = o[1]:match("^skill") and 104 or 66
      total = total + bw + gap
    end
    total = total - gap
    local x = math.floor(w / 2 - total / 2)
    local y = h - UI.PANEL_H - UI.ORDERS_H
    for _, o in ipairs(ARENA_ORDERS) do
      local slot = tonumber(o[1]:match("^skill(%d)"))
      local bw = slot and 104 or 66
      local b = { x = x, y = y + 3, w = bw, h = UI.ORDERS_H - 6, action = o[1], key = o[3], on = c.alive }
      if slot then
        local sk = c.skills and c.skills[slot]
        if sk then
          local def = A.SKILLS[sk.key]
          b.label, b.tip, b.skill = def.name, def.desc, sk
          b.cd = math.max(0, sk.readyAt - game.world.time)
          b.cdMax = def.cd * ((c.mods and c.mods.cdr) or 1)
        else
          b.label = slot == 4 and "Ultimate" or "Skill " .. slot
          b.tip = slot == 4 and "Unlocks at level 6." or "Learn a skill at level " .. ({ 2, 4, 8 })[slot] .. "."
          b.on = false
        end
      else
        b.label, b.tip = o[2], o[4]
      end
      list[#list + 1] = b
      x = x + bw + gap
    end
    return list, list[1].x - 6, y, total + 12
  end
  local mobile = #game:selectedMobile() > 0
  local n = #game:selectedList()
  local mine = false
  for _, e in ipairs(game:selectedList()) do if e.team == 1 then mine = true end end
  local myc = game:myCommander()
  local enabled = {
    amove = mobile, stop = mobile, patrol = mobile, hold = n > 0, flee = mobile, fleecmd = mobile, flag = true,
    destroy = mine, army = true, half = n >= 2, builder = true, cmd = true, follow = n > 0,
    ["repeat"] = #game:selectedFactories() > 0, nuke = myc and game.selected[myc] and myc.nukeReady and true or false, help = true,
  }
  local bw, gap = 66, 4
  local list = {}
  -- Commander of Heroes: no building, no Commander - just the squad orders
  local cohSkip = { fleecmd = true, destroy = true, half = true, builder = true, ["repeat"] = true, nuke = true }
  local cohText = {
    flee = { "Flee", "Pull the selection back to your HQ (or your flag, if planted) at +25% speed. Weapons stay off until repaired - the HQ heals fast." },
    cmd = { "Squad", "C: with several squads selected, the next one becomes ACTIVE (gold - Q / W fire its skills). Otherwise: jump to the next squad." },
  }
  for _, o in ipairs(ORDERS) do
    if game.world.squads then
      if not cohSkip[o[1]] then
        local t = cohText[o[1]]
        list[#list + 1] = t and { o[1], t[1], o[3], t[2] } or o
      end
    elseif o[1] ~= "nuke" or (myc and (myc.clevel or 0) >= 5) then list[#list + 1] = o end
  end
  local total = #list * bw + (#list - 1) * gap
  local x0 = math.floor(w / 2 - total / 2)
  local y = h - UI.PANEL_H - UI.ORDERS_H
  local btns = {}
  for i, o in ipairs(list) do
    btns[#btns + 1] = { x = x0 + (i - 1) * (bw + gap), y = y + 3, w = bw, h = UI.ORDERS_H - 6,
      action = o[1], label = o[2], key = o[3], tip = o[4], on = enabled[o[1]] }
  end
  return btns, x0 - 6, y, total + 12
end

function UI.drawOrders(game)
  local btns, bx, by, bw = UI.orderButtons(game)
  game.orderBtns = btns
  panelBox(bx, by, bw, UI.ORDERS_H + 6, 0.88)
  local mx, my = love.mouse.getPosition()
  local hover
  for _, b in ipairs(btns) do
    local hv = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    if hv then hover = b end
    local active = game.mode == b.action or (b.action == "flee" and false)
    if b.action == "repeat" then
      for _, f in ipairs(game:selectedFactories()) do if f.repeatMode then active = true end end
    end
    if b.action == "follow" and game.follow then active = true end
    if b.action == "help" and game.showHelp then active = true end
    if b.action == "hold" and game.holdingFire then active = true end
    local a = b.on and 1 or 0.35
    if active then lg.setColor(0.18, 0.4, 0.28, a)
    elseif hv and b.on then lg.setColor(0.22, 0.3, 0.4, a)
    else lg.setColor(0.13, 0.17, 0.22, a) end
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 5)
    lg.setColor(0.32, 0.42, 0.52, a)
    lg.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, 5)
    if b.cd and b.cd > 0 then
      lg.setColor(0, 0, 0, 0.55)
      lg.rectangle("fill", b.x, b.y, b.w * math.min(1, b.cd / math.max(0.1, b.cdMax or 1)), b.h, 5)
    end
    local warn = b.action == "destroy" or b.action == "nuke" or b.action == "skill4"
    lg.setFont(font(12))
    if warn then lg.setColor(1, 0.55, 0.45, a) else lg.setColor(0.92, 0.95, 1, a) end
    lg.print(b.label, b.x + b.w / 2 - font(12):getWidth(b.label) / 2, b.y + 3)
    lg.setFont(font(10))
    lg.setColor(0.65, 0.72, 0.8, a * 0.9)
    local sub = b.key
    if b.cd and b.cd > 0 then sub = b.key .. "  " .. math.ceil(b.cd) .. "s" end
    lg.print(sub, b.x + b.w / 2 - font(10):getWidth(sub) / 2, b.y + 18)
  end
  if hover then
    local text = hover.label .. "  (" .. hover.key .. ")  -  " .. hover.tip .. (hover.on and "" or "   [select units first]")
    lg.setFont(font(13))
    local tw = math.min(640, font(13):getWidth(text) + 20)
    local _, lines = font(13):getWrap(text, tw - 20)
    local th = #lines * 16 + 12
    local tx = math.max(8, math.min(lg.getWidth() - tw - 8, hover.x + hover.w / 2 - tw / 2))
    panelBox(tx, by - th - 6, tw, th, 0.96)
    lg.setColor(1, 1, 1)
    lg.printf(text, tx + 10, by - th, tw - 20)
  end
end

function UI.drawCard(game, L)
  local btns = UI.cardButtons(game, L)
  local mx, my = love.mouse.getPosition()
  local tm = game.world.teams[1]
  game.hoverBtn = nil
  for _, b in ipairs(btns) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    if hover then game.hoverBtn = b end
    if game.craft and b.key then
      craftUI().drawCardButton(game, b)
    elseif b.kind == "cmd" then
      local active = (b.action == game.mode)
      if b.action == "repeat" then
        for _, f in ipairs(game:selectedFactories()) do if f.repeatMode then active = true end end
      end
      lg.setColor(active and 0.2 or 0.13, active and 0.35 or 0.17, active and 0.25 or 0.22)
      if hover then lg.setColor(0.22, 0.3, 0.38) end
      lg.rectangle("fill", b.x, b.y, b.w, b.h, 4)
      lg.setColor(b.action == "nuke" and 1 or 0.85, b.action == "nuke" and 0.55 or 0.9, b.action == "nuke" and 0.4 or 0.95)
      local fs = b.w < 60 and 11 or 12
      lg.setFont(font(fs))
      lg.print(b.label, b.x + b.w / 2 - font(fs):getWidth(b.label) / 2, b.y + 6)
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
      if b.hotkey then lg.print(string.upper(b.hotkey), b.x + 5, b.y + 3) end
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
    if game.craft then text = craftUI().tooltip(game, b) end
    if not game.craft then
    local power = b.kind == "factory" and 10 or 12
    text = text .. string.format("\nBuild time ~%ds", math.ceil(d.cost.work / power))
    if d.weapon then text = text .. string.format("\nDamage %d, range %d", d.weapon.damage, d.weapon.range) end
    text = text .. "\n" .. (d.desc or "")
    if b.kind == "factory" then text = text .. "\nClick = 1, Shift-click = 5, right-click removes" end
    end
    lg.setFont(font(13))
    local tw = 290
    local _, lines = font(13):getWrap(text, tw)
    local th = #lines * font(13):getHeight() + 16
    local tx, ty = math.min(mx + 14, lg.getWidth() - tw - 24), math.max(UI.TOP_H + 4, math.min(my, b.y or my) - th - 6)
    -- drawn last (see UI.draw) so the order bar and other panels can't cover it
    game.pendingTip = { text = text, x = tx, y = ty, w = tw, h = th }
  end
end

function UI.drawPendingTip(game)
  local t = game.pendingTip
  if not t then return end
  game.pendingTip = nil
  lg.setFont(font(13))
  panelBox(t.x, t.y, t.w + 16, t.h, 0.97)
  lg.setColor(0.9, 0.93, 0.97)
  lg.printf(t.text, t.x + 8, t.y + 8, t.w)
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
  Shift+C ................... cycle your Generals (units promoted at level 5)

Control groups
  Ctrl+1..9 ................. save selection as a group
  Shift+1..9 ................ add selection to group
  1..9 ...................... recall group (tap twice to jump to it)

Orders (hold Shift to queue)
  Right-click ground ........ move (units spread in formation)
  Right-click enemy ......... attack
  Right-click own unfinished/damaged/factory with constructors .. help build / repair / assist
  Right-click a friendly unit with army selected .. guard it (follow and protect)
  Right-click a friendly unit with a factory selected .. new units join it and follow it
  A then click .............. attack-move (fight anything on the way)
  P then click .............. patrol
  Hold G + click ............ group move (everyone keeps the slowest unit's pace)
  S ......................... stop
  Hold D .................... hold fire (selected units stop shooting until you let go)
  F ......................... retreat to your flag (+25% speed, weapons OFF until fully repaired; can't be cancelled)
  Shift+F ................... retreat to the Commander
  Ctrl+F .................... plant the retreat flag at the mouse
  F on the Commander ........ he flees home (+50% speed), weapons off until fully repaired.
                              He only repairs at his starting spot - that is his base
                              Units out of combat near your Commander or a factory slowly repair
  Delete .................... SELF-DESTRUCT selected units/buildings (unfinished ones refund)
                              Commander alone: press twice (you lose the game)
  Shift+Delete .............. drop the last queued order
  Constructors: right-click the retreat flag ... repair everything within 350 of it (fleeing units rearm faster there)

Building
  Select a constructor, press Q W E R T Y U I (or click), then click the map
  Shift-click places several; drag a box to fill an area (extractors: every deposit in the box)
  Select a factory: Q W E R T queue units (Shift = 5), right-click a button removes
  Right-click the ground with a factory selected = rally point,  G = repeat queue
  Constructors: P then DRAG a circle = repair zone (they stay and fix everything of yours in it)
  Option+1..9 with a factory selected = its new units join that group (Option+0 clears)

Camera
  Scroll = zoom,  middle-drag = pan,  arrow keys / screen edge = pan
  Option+scroll = pan (trackpad),  minimap click = jump,  Space = jump to last attack
  L = lock camera on selection,  Shift+L = cinematic follow (zooms to frame them)
  F9 = keep mouse inside window (on by default, for edge panning),  F8 = edge panning on/off

Game  (icons: game-icons.net, CC BY 3.0)
  Esc = menu / cancel,  F3 = pause,  + / - = game speed,  M = sound effects,  Shift+M = music,  V = announcer
  K or the Auto button = standing orders (flee when hurt, keep constructors, idle constructors repair / expand / power)
  F11 or Ctrl+Cmd+F = fullscreen / windowed (also in the Esc menu),  F1 = this help

Commander: levels up from HIS OWN kills. Levels 1-4 offer 2 random upgrades out of 20
  (Z / X or click a card). Level 5 = NUKE (N): destroys every building in the circle,
  halves units, Commanders immune, 10 minute recharge. Risk him to grow him - lose him, lose the game.
Goal: destroy the enemy Commanders. Lose yours and you're out.
Veterancy: units level up (gold chevrons, max 5) from damage and kills: more damage, HP, fire rate, range.
Economy: Metal Extractors on yellow deposits, Solar for energy. Everything costs both.
Rich deposits (+3.9 metal, normal +2.4): gold rings near the map center, teal rings offshore (offshore metal needs a Sea Constructor). The Power Core node in the middle (blue pad) gives +10 metal and +150 energy to whoever builds on it.
The sea: Shipyards build Sea Constructors for them and
  for Tidal Generators (+36 energy). Patrol Boats scout and carry flak, Destroyers hit hard at 420 with a spotter, Battleships (shipyard 4) shell anything you can see across the map - but need boats around them.
]]

local ARENA_HELP = [[
COMMANDER ARENA - CONTROLS

Goal: destroy the enemy Core (in free-for-all: be the last Core standing). Each lane has towers per side:
  outer first, then middle (Long Road / Gauntlet), then inner, then the Core (shielded ones glow blue).
  Towers shoot creeps first - and you, if you attack an enemy Commander under them.
  A lane whose enemy towers are down sends super creeps. Cores are fortified: half damage until 8:00, -25% until 12:00.
Jungle (Treeline / Battlefield maps): neutral camps give XP (they only fight back); stand on a shrine to
  capture it (+8% speed and damage per shrine); the Colossus wakes at 7:00 - kill it for the Crest (2 min of
  stronger Commanders and creeps); green relics heal 35%.

Your Commander
  Right-click ............... move / attack        A then click ... attack-move
  S ......................... stop                 F .............. flee home (+50% speed, can't be cancelled)
  Hold D .................... hold fire, to time last hits.  Right-click your own creep under 35% health: DENY it
  Creeps level up as a side (up to 5) from enemy creeps they kill - a deny keeps that kill from the enemy.
  The CREEPS panel (right) shows each side's creep level, the bar to the next, and its denies.
  Q W E ..................... your skills, cast at the mouse (or click the button, then the map)
  R ......................... your ultimate (unlocks at level 6)
  Z / X ..................... choose a level-up card
  C / Space ................. jump to your Commander      L ... follow camera

Leveling
  Experience comes from creeps (the full value if your Commander or his summons land the killing shot,
  a smaller share if you're just nearby; denied creeps give nothing),
  enemy Commanders and towers. Every level: +6% health, +5% damage and a card:
  levels 2, 4, 8 offer a class skill; level 6 unlocks the class ultimate; the rest offer upgrades.
  When your Commander dies he respawns at your Core after a timer that grows with level and time.

Classes
  Ranger ....... longest range: Volley, Piercing Lance, Evade, Decoy, Frost Arrow. Ult: Chain Storm
  Elementalist . fragile caster: Teleport, Frost Nova, Fireball, Chain Lightning, Energy Shield. Ult: Meteor
  Reclaimer .... raises wrecked creeps as drones: Raise, Amplify, Corpse Burst, Bone Spear, Decrepify. Ult: Rise
  Juggernaut ... melee brawler: Leap Slam, War Cry, Whirlwind, Battle Orders, Iron Shout. Ult: Berserk
  Warden ....... auras and holy strikes: Charge, Holy Shield, Spinning Hammers, Smite, Prayer. Ult: Judgment
  Shifter ...... wolves and storms: Summon Wolves, Bear Form, Cyclone, Firestorm, Spirit of the Oak. Ult: Cataclysm
  Infiltrator .. traps and stealth: Lightning Sentry, Mind Blast, Fade, Shadow Clone, Dragon Talon. Ult: Sentry Swarm
  Ascetic ...... melee monk: Flurry, Dashing Strike, Mantra, Breath of Heaven, Whirling Pull. Ult: Sanctuary
  Hexer ........ poison and ghouls: Plague Dart, Raise Ghouls, Grasp, Sacrifice, Soul Harvest. Ult: Gargantuan
  Spiritcaller . one stance at a time: Jaguar, Gorilla, Eagle, Centipede, Rushing Claw. Ult: Spirit Avatar

  Esc = menu / cancel,  F3 = pause,  + / - = game speed,  M = sound effects,  Shift+M = music,  V = announcer
]]

local COH_HELP = [[
COMMANDER OF HEROES - CONTROLS

  Left-click a unit ......... selects its whole squad (Alt-click: just that unit)
  1 - 5 ..................... select that squad (Shift adds it; twice jumps to its leader)
  Bottom panel .............. every squad as a card: click to select (Shift adds),
                              hover a skill to learn it, click a skill to use it
  ACTIVE SQUAD (gold) ....... the one Q / W fire for. With several squads selected,
  C ......................... moves "active" to the next selected squad
                              (nothing or one selected: C steps to the next squad)
  Right-click ............... move (each squad keeps its own pace) / attack a target
  A then click .............. attack-move: the squad forms ranks, marches, then fights and kites
  Q / W ..................... the ACTIVE squad's two skills, aimed at the mouse
  F ......................... flee: back to your HQ, weapons off until repaired
  Alt+1-5 / card's Flee ..... just that squad flees (your selection stays as it is)
  S / D ..................... stop / hold fire       + / - ... game speed

HOW TO WIN
  Squad units are 60% tougher than in Annihilation: fights last long enough to use skills.
  Five capture points. Ground units standing on a point take it - aircraft can't.
  Hold more points than the enemy and their tickets drain; every unit lost costs tickets.
  Run them out of tickets, or destroy their HQ. An HQ under a blue dome is shielded (its side
  holds a point); a flashing red ring means it can be hurt.
  Units heal fast at your HQ. Fallen members are replaced there - faster the more points
  you hold. A fallen leader returns after 45 seconds (his squad has no skills meanwhile).

TERRAIN
  Hills (brown ground): +30% sight, but +15% damage taken.  Bunkers (sandbag rings): -40% damage, -30% sight.
  Tanks carry a light anti-air machine gun; Recon's guns hit aircraft hard.

WAR IS HELL
  No HQ, no points, no reinforcements: when they die, they die. Deep fog, rough ground. Find the
  enemy and destroy every unit. A fallen leader's best survivor takes command. F flees toward your drop zone.

SQUAD TYPES (each squad is one kind of unit; the leader is a veteran of it)
  Armor - 4 Tanks .............. Hull Down, Smoke Screen
  Battery - 3 Artillery ........ Barrage, Rapid Fire
  Recon - 5 Scouts (light AA) .. Flare, Sprint
  Air Defense - 3 Flak Trucks .. Flak Barrage, Field Repair
  Gunships - 3 (one a side) .... Strafing Run, Afterburner

  Esc = menu,  F3 = pause,  M = sound,  Shift+M = music,  F1 = close this]]
UI.COH_HELP = COH_HELP

function UI.drawHelp(arena)
  local w, h = lg.getDimensions()
  local text = arena == "craft" and craftUI().HELP or (arena == "coh" and COH_HELP) or (arena and ARENA_HELP or HELP)
  local f = font(12)
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local need = #lines * f:getHeight() + 36
  local bh = math.min(h - 20, math.max(need, 300))
  if need <= h - 20 then
    local bw = 780
    local x, y = (w - bw) / 2, (h - bh) / 2
    panelBox(x, y, bw, bh, 0.97)
    lg.setFont(f)
    lg.setColor(0.9, 0.93, 0.97)
    lg.print(text, x + 24, y + 18)
    return
  end
  -- too tall for the screen (Steam Deck): two columns, split at a section break near the middle
  local split = math.floor(#lines / 2)
  for k = 0, 12 do
    if lines[split + k] == "" then split = split + k; break end
    if lines[split - k] == "" then split = split - k; break end
  end
  local left = table.concat(lines, "\n", 1, split)
  local right = table.concat(lines, "\n", split + 1, #lines)
  local bw = math.min(w - 20, 1260)
  local x, y = (w - bw) / 2, (h - bh) / 2
  panelBox(x, y, bw, bh, 0.97)
  lg.setFont(font(10))
  lg.setColor(0.9, 0.93, 0.97)
  lg.print(left, x + 16, y + 14)
  lg.print(right, x + bw / 2 - 10, y + 14)
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

-- only Annihilation's own maps can be saved (Arena, Craft and Commander of Heroes build theirs)
local function canSaveMap(game)
  return game and not game.arena and not game.craft and not game.world.squads
end

function UI.menuRects(game)
  local w, h = lg.getDimensions()
  local bw = 280
  local x = (w - bw) / 2
  local y = h / 2 - 138
  local fs = love.window.getFullscreen()
  local items = {
    { label = "Resume", action = "resume" },
    { label = "Restart (same map)", action = "restart" },
    { label = "Controls (F1)", action = "help" },
    require("src.automation").applies(game) and { label = "Auto (K)", action = "automation" } or false,
    { label = "Settings", action = "settings" },
    { label = fs and "Windowed (Ctrl+Cmd+F)" or "Fullscreen (Ctrl+Cmd+F)", action = "fullscreen" },
    canSaveMap(game) and { label = "Save this map...", action = "savemap" } or false,
    { label = "Surrender & return to title", action = "quit" },
    { label = "Exit game", action = "exit" },
  }
  for i = #items, 1, -1 do if not items[i] then table.remove(items, i) end end
  local gap = h < 760 and 48 or 54
  y = h / 2 - (#items * gap) / 2 + 30
  for i, it in ipairs(items) do it.x, it.y, it.w, it.h = x, y + (i - 1) * gap, bw, gap - 10 end
  return items
end

function UI.drawMenu(game)
  local w, h = lg.getDimensions()
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 0, 0, w, h)
  local rects = UI.menuRects(game)
  local last = rects[#rects]
  panelBox(rects[1].x - 30, rects[1].y - 70, rects[1].w + 60, last.y + last.h - rects[1].y + 94, 0.97)
  lg.setFont(font(22))
  lg.setColor(1, 1, 1)
  lg.print("Paused", w / 2 - font(22):getWidth("Paused") / 2, rects[1].y - 52)
  for _, r in ipairs(rects) do button(r.x, r.y, r.w, r.h, r.label) end
end

function UI.menuClick(game, x, y, button_)
  if button_ ~= 1 then return end
  for _, r in ipairs(UI.menuRects(game)) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      if r.action == "resume" then game.menuOpen = false
      elseif r.action == "help" then game.menuOpen = false; game.showHelp = true
      elseif r.action == "automation" then game.menuOpen = false; game.autoOpen = true
      elseif r.action == "restart" then game.playAgain, game.restartSame = true, true
      elseif r.action == "settings" then require("src.settings").open = true
      elseif r.action == "fullscreen" then
        love.window.setFullscreen(not love.window.getFullscreen(), "desktop")
        game:clampCam()
      elseif r.action == "savemap" then if game.arena then game:notice("Arena maps can't be saved", 1.5) else game:startNaming() end
      elseif r.action == "quit" then game.quitToTitle = true
      elseif r.action == "exit" then love.event.quit() end
    end
  end
end

local OVER_W, OVER_H = 940, 600

function UI.overRects(game)
  local w, h = lg.getDimensions()
  local by = h / 2 + OVER_H / 2 - 64
  local list = {
    { label = "Play again", action = "again" },
  }
  if canSaveMap(game) then list[#list + 1] = { label = "Save this map...", action = "savemap" } end
  local f = game and game.finalScore
  if f and f.official and require("src.online").enabled() then
    list[#list + 1] = { label = game.submitted and "Score submitted" or "Submit score online", action = "submit" }
  end
  list[#list + 1] = { label = "Title screen", action = "title" }
  local bw, gap = 200, 14
  local x0 = w / 2 - (#list * bw + (#list - 1) * gap) / 2
  for i, r in ipairs(list) do
    r.x, r.y, r.w, r.h = x0 + (i - 1) * (bw + gap), by, bw, 44
  end
  return list
end

local function mmss(t) return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60)) end

function UI.drawOver(game)
  local w, h = lg.getDimensions()
  local world = game.world
  local o = world.over
  local k = math.min(1, (love.timer.getTime() - (game.overTime or 0)) / 1.5)
  o.winner = (o.winnerAlly == world.ally[1]) and 1 or 2
  lg.setColor(0, 0, 0, 0.6 * k)
  lg.rectangle("fill", 0, 0, w, h)
  if k < 1 then return end
  local win = o.winner == 1
  local px, py = w / 2 - OVER_W / 2, h / 2 - OVER_H / 2
  panelBox(px, py, OVER_W, OVER_H, 0.97)
  -- the fifth finished Annihilation game: introduce Mirror and Nemesis
  if game.ghostUnlocked then
    local GH = require("src.ghost")
    local bw = math.min(w - 40, OVER_W)
    local _, lines = font(14):getWrap(GH.UNLOCK_TEXT, bw - 28)
    local bh = #lines * font(14):getHeight() + 22
    local by = math.max(8, py - bh - 10)
    panelBox(w / 2 - bw / 2, by, bw, bh, 0.97)
    lg.setColor(1, 0.85, 0.35, 0.9)
    lg.setLineWidth(2)
    lg.rectangle("line", w / 2 - bw / 2 + 1, by + 1, bw - 2, bh - 2, 6)
    lg.setFont(font(14))
    lg.setColor(1, 0.92, 0.7)
    lg.printf(GH.UNLOCK_TEXT, w / 2 - bw / 2 + 14, by + 11, bw - 28)
  elseif game.ghostProgress and not require("src.ghost").unlocked() then
    lg.setFont(font(13))
    lg.setColor(0.8, 0.85, 0.95)
    local t = string.format("Finished Annihilation games: %d / %d - two opponents that learn from you unlock at %d.",
      game.ghostProgress, require("src.ghost").NEEDED, require("src.ghost").NEEDED)
    lg.print(t, w / 2 - font(13):getWidth(t) / 2, py - 22)
  end
  local title = win and "VICTORY" or "DEFEAT"
  lg.setFont(font(44))
  if win then lg.setColor(0.4, 1, 0.5) else lg.setColor(1, 0.4, 0.35) end
  lg.print(title, w / 2 - font(44):getWidth(title) / 2, py + 14)
  lg.setFont(font(14))
  lg.setColor(0.7, 0.76, 0.84)
  local sub = win and "Every enemy Commander has been annihilated. Partially." or "Your side has been annihilated. Completely."
  if world.arena then sub = win and "The enemy Core is rubble." or "Your Core has fallen." end
  if world.craft then sub = win and "Not one enemy building is left standing." or "Your last building has fallen." end
  if world.wih then
    if not win then sub = "Every one of your men is gone."
    elseif world.mercyChoice == "spare" then sub = string.format("%d prisoner%s taken. The war is over for them.", world.captives or 0, (world.captives or 0) == 1 and "" or "s")
    elseif world.mercyChoice == "kill" then sub = "No quarter given. Not one of them walked away."
    elseif world.mercyChoice == "mixed" then sub = string.format("%d prisoner%s taken. Some of them were shown no mercy.", world.captives or 0, (world.captives or 0) == 1 and "" or "s")
    else sub = "The last of them is dead." end
  end
  lg.print(sub, w / 2 - font(14):getWidth(sub) / 2, py + 68)

  local f = game.finalScore
  local sc = world.score and world.score[1]
  local st = game.stats

  -- left column: what happened
  local lx, ly = px + 30, py + 104
  local function head(x, y, text)
    lg.setFont(font(13)); lg.setColor(1, 0.85, 0.35); lg.print(text, x, y)
  end
  local function row(x, y, label, value, wid, col)
    lg.setFont(font(14))
    lg.setColor(0.72, 0.78, 0.86); lg.print(label, x, y)
    lg.setColor(col and col[1] or 1, col and col[2] or 1, col and col[3] or 1)
    lg.print(value, x + wid - font(14):getWidth(value), y)
  end
  head(lx, ly, "THE MATCH")
  local rows
  if world.craft then
    local C = require("src.craft")
    local cst = world.craft
    local tm = world.teams[1]
    local hs = {}
    for _, h in ipairs(C.heroesOf(world, 1, true)) do hs[#hs + 1] = (require("src.arena").byClass[h.class] or {}).name .. " L" .. (h.clevel or 0) end
    rows = {
      { "Game time", mmss(world.time) .. "   (par " .. mmss(world.parTime) .. ")" },
      { "Opponents", f and f.lineup or "" },
      { "Your race", C.raceOf(world, 1).name .. "  (" .. C.raceOf(world, 1).tierNames[tm.tier or 1] .. ")" },
      { "Heroes", table.concat(hs, ", ") },
      { "Enemies killed", tostring(cst.kills[1] or 0) },
      { "Your losses", tostring(cst.lost[1] or 0) },
      { "Units trained", tostring(st.built) },
      { "Research done", tostring((function() local n = 0; for _ in pairs(tm.research or {}) do n = n + 1 end; return n end)()) },
      { "Best kill streak", sc and (sc.bestStreak .. " kills  (x" .. string.format("%.1f", sc.bestMult) .. ")") or "-" },
    }
  elseif world.arena then
    local ast = world.arena
    local towersDown = 0
    for _, s2 in ipairs(ast.structures) do if not s2.alive and s2.side ~= 1 and s2.key ~= "core" then towersDown = towersDown + 1 end end
    local c = world.teams[1].commander
    rows = {
      { "Game time", mmss(world.time) .. "   (par " .. mmss(world.parTime) .. ")" },
      { "Opponents", f and f.lineup or "" },
      { "Your class", (require("src.arena").byClass[c.class] or {}).name or "?" },
      { "Commander level", tostring(c.clevel or 0) },
      { "Enemy Commanders killed", tostring(ast.kills[1]) },
      { "Your deaths", tostring(ast.deaths[1] or 0) },
      { "Enemy towers destroyed", tostring(towersDown) },
      { "Creeps and summons destroyed", tostring(sc and sc.kills or 0) },
      { "Creep waves", tostring(ast.wave) },
      { "Best kill streak", sc and (sc.bestStreak .. " kills  (x" .. string.format("%.1f", sc.bestMult) .. ")") or "-" },
    }
  else rows = {
    { "Game time", mmss(world.time) .. (world.parTime and ("   (par " .. mmss(world.parTime) .. ")") or "") },
    { "Opponents", f and f.lineup or "" },
    { "Units built", tostring(st.built) },
    { "Buildings built", tostring(sc and sc.built or 0) },
    { "Enemy units destroyed", tostring(sc and sc.kills or st.killed) },
    { "Enemy buildings destroyed", tostring(sc and sc.bldKills or 0) },
    { "Enemy Commanders killed", tostring(sc and sc.cmdKills or 0) },
    { "Your losses", tostring(st.lost) },
    { "Commander level", tostring(st.cmdLevel or 0) .. ((st.nukes or 0) > 0 and ("   nukes launched " .. st.nukes) or "") },
    { "Best kill streak", sc and (sc.bestStreak .. " kills  (x" .. string.format("%.1f", sc.bestMult) .. ")") or "-" },
  } end
  -- rows; a value too long for one line (3v3 opponent lists) wraps underneath in a smaller font
  local yy = ly + 30
  -- split "ally ..." entries of the lineup into their own row
  for i, r in ipairs(rows) do
    if r[1] == "Opponents" and r[2]:find("ally ") then
      local opp, al = {}, {}
      for part in (r[2] .. ", "):gmatch("(.-), ") do
        if part:sub(1, 5) == "ally " then al[#al + 1] = part:sub(6) else opp[#opp + 1] = part end
      end
      r[2] = table.concat(opp, ", ")
      table.insert(rows, i + 1, { "Allies", table.concat(al, ", ") })
      break
    end
  end
  for _, r in ipairs(rows) do
    local lw = font(14):getWidth(r[1])
    if font(14):getWidth(r[2]) <= 410 - lw - 14 then
      row(lx, yy, r[1], r[2], 410)
      yy = yy + 24
    else
      row(lx, yy, r[1], "", 410)
      lg.setFont(font(12)); lg.setColor(1, 1, 1)
      local _, wr = font(12):getWrap(r[2], 410 - 20)
      lg.printf(r[2], lx + 20, yy + 20, 410 - 20)
      yy = yy + 22 + #wr * (font(12):getHeight() + 1) + 4
    end
  end
  -- everyone's points
  if world.score then
    local parts = {}
    for _, r in ipairs(require("src.mods").ranking(world)) do
      parts[#parts + 1] = (r.team == 1 and "You" or D.teamName[r.team]) .. " " .. U.fmt(r.pts)
    end
    lg.setFont(font(12)); lg.setColor(0.6, 0.66, 0.74)
    lg.printf("Points (before multipliers): " .. table.concat(parts, "   "), lx, math.max(yy + 4, ly + 6 + 11 * 24 + 4), 410)
  end

  -- right column: how the score was made
  local rx, ry, rw = px + 490, py + 104, 420
  head(rx, ry, "YOUR SCORE")
  if f and sc then
    local y = ry + 30
    local function line(label, value, col)
      row(rx, y, label, value, rw, col); y = y + 24
    end
    line("Kills  (value of what you destroyed; towers x1.5)", U.fmt(sc.killPts))
    line(string.format("Kill-streak bonus  (best x%.1f)", sc.bestMult), "+" .. U.fmt(sc.streakPts), { 1, 0.7, 0.3 })
    if not world.arena then line("Construction  (10% of metal you built)", U.fmt(sc.buildPts)) end
    line(world.arena and "Level-ups" or "Commander promotions", U.fmt(sc.cmdPts))
    lg.setColor(0.4, 0.48, 0.58); lg.line(rx, y + 2, rx + rw, y + 2); y = y + 8
    line("Points", U.fmt(f.pts))
    line(string.format("x %.2f  difficulty  (enemies avg. level %.1f)", f.diffMul, f.avgLevel), "", nil)
    local oppText
    if f.enemies <= 1 then oppText = "1 enemy"
    elseif f.enemyTeams == 1 then oppText = f.enemies .. " enemies teamed up"
    else oppText = f.enemies .. " enemies, " .. f.enemyTeams .. " sides (they fight each other too)" end
    if f.allies > 0 then oppText = oppText .. ", " .. f.allies .. (f.allies == 1 and " ally" or " allies") end
    line(string.format("x %.2f  opposition  (%s)", f.oppMul, oppText), "")
    local tt
    if f.won then
      local pct = math.floor(math.abs(f.dev) * 100 + 0.5)
      tt = string.format("won in %s vs par %s, %d%% %s", mmss(world.time), mmss(world.parTime), pct, f.dev >= 0 and "faster" or "slower")
    else tt = "a loss is a flat x0.75" end
    line(string.format("x %.2f  time  (%s)", f.timeMul, tt), "")
    lg.setColor(0.4, 0.48, 0.58); lg.line(rx, y + 2, rx + rw, y + 2); y = y + 12
    lg.setFont(font(26)); lg.setColor(1, 0.85, 0.35)
    lg.print("FINAL", rx, y)
    local ft = U.fmt(f.total)
    lg.print(ft, rx + rw - font(26):getWidth(ft), y)
    y = y + 40
    lg.setFont(font(13))
    if f.official then
      lg.setColor(0.5, 0.9, 0.55)
      lg.print(game.highRank and ("Official score  -  #" .. game.highRank .. " on your high-score table (season " .. D.SEASON .. ")")
        or "Official score", rx, y)
    else
      lg.setColor(1, 0.6, 0.35)
      lg.printf("Unofficial: Alien Tech / Dropships were on, so this doesn't go on the high-score table.", rx, y, rw)
    end
    if game.submitMsg then
      lg.setColor(0.7, 0.8, 0.95)
      lg.printf(game.submitMsg, rx, y + 20, rw)
    end
  end
  lg.setFont(font(12))
  lg.setColor(0.55, 0.62, 0.7)
  local how = world.arena and ("How Arena scoring works: points come from what your Commander and his summons destroy (creeps by their metal cost, "
    .. "Commanders 800, towers 450, the Core 1125) plus 150 x level for each level-up. Kill streaks multiply them up to x3. Then the total is scaled "
    .. "by enemy difficulty, how many enemies you faced, and how fast you won: par time divided by your time (up to x3).") or nil
  if world.craft then
    how = "How Craft scoring works: every enemy you destroy is worth its gold + wood cost (a hero 900), plus 10% of what you build "
      .. "and 150 x level for each hero level-up. Kill streaks multiply them up to x3. Then the total is scaled by enemy difficulty "
      .. "and how fast you won: par (16:00) divided by your time, up to x3."
  end
  if how then lg.printf(how, px + 30, py + OVER_H - 150, OVER_W - 60) else
  lg.printf("How scoring works: every enemy you destroy is worth its metal cost (a Commander is 3000, veterans more). "
    .. "Each kill soon after the last raises your multiplier by 0.1, up to x3; it resets after 10 seconds without an enemy death "
    .. "(the window shrinks to 5s as the streak grows). "
    .. "Building earns 10% of the metal spent and each Commander promotion pays 150 x level. Then the total is scaled by "
    .. "how strong the enemies were, how many there were (and whether they were teamed up against you), and how fast you won: "
    .. "par time divided by your time, so winning in half the par time doubles the score (up to x3). Games with Alien Tech or Dropships don't count as official.",
    px + 30, py + OVER_H - 150, OVER_W - 60)
  end
  for _, r in ipairs(UI.overRects(game)) do button(r.x, r.y, r.w, r.h, r.label) end
  -- a ten-second rating, saved in the match log (how we check the AI's variety and difficulty)
  local rr = UI.rateRects(game)
  if #rr > 0 then
    lg.setFont(font(12))
    lg.setColor(0.75, 0.8, 0.88)
    local q = "How did that feel?"
    lg.print(q, rr[1].x - font(12):getWidth(q) - 12, rr[1].y + 6)
    local mx, my = love.mouse.getPosition()
    for _, r in ipairs(rr) do
      local on = game.rating and game.rating[r.group] == r.value
      local hov = mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
      lg.setColor(on and 0.25 or (hov and 0.2 or 0.12), on and 0.5 or (hov and 0.26 or 0.16), on and 0.3 or (hov and 0.34 or 0.22), 0.95)
      lg.rectangle("fill", r.x, r.y, r.w, r.h, 5)
      lg.setColor(1, 1, 1, on and 1 or 0.8)
      lg.print(r.label, r.x + r.w / 2 - font(12):getWidth(r.label) / 2, r.y + 6)
    end
  end
end

function UI.rateRects(game)
  if not game.log then return {} end
  local w, h = lg.getDimensions()
  -- inside the panel, in the gap under the two columns (above the scoring note)
  local y = h / 2 - OVER_H / 2 + 412
  local items = {
    { group = "felt", value = "fresh", label = "Fresh" }, { group = "felt", value = "samey", label = "Samey" },
    { group = "difficulty", value = "too easy", label = "Too easy" }, { group = "difficulty", value = "about right", label = "About right" },
    { group = "difficulty", value = "too hard", label = "Too hard" },
  }
  local bw, gap, x = 92, 6, w / 2 - (5 * 92 + 4 * 6 + 20) / 2 + 66
  for i, it in ipairs(items) do
    it.x, it.y, it.w, it.h = x, y, bw, 26
    x = x + bw + gap + (i == 2 and 20 or 0)
  end
  return items
end

-- War is Hell: the enemy's last men have thrown down their arms. Before you decide, the names
-- of everyone you lost getting here
function UI.mercyRects(game)
  local w, h = lg.getDimensions()
  local nf = game.mercy and #game.mercy.fallen or 0
  local pw = math.min(w - 40, 820)
  local ph = math.min(h - 40, 250 + math.max(1, nf) * 19)
  local px, py = w / 2 - pw / 2, h / 2 - ph / 2
  return { panel = { x = px, y = py, w = pw, h = ph },
    spare = { x = w / 2 - 250, y = py + ph - 66, w = 240, h = 46, action = "spare" },
    kill = { x = w / 2 + 10, y = py + ph - 66, w = 240, h = 46, action = "kill" } }
end

function UI.drawMercy(game)
  local m = game.mercy
  if not m or m.choice then return end
  local w, h = lg.getDimensions()
  local k = math.min(1, (love.timer.getTime() - m.t) / 0.6)
  lg.setColor(0.08, 0, 0, 0.72 * k)
  lg.rectangle("fill", 0, 0, w, h)
  local r = UI.mercyRects(game)
  local p = r.panel
  panelBox(p.x, p.y, p.w, p.h, 0.97 * k)
  lg.setColor(0.75, 0.15, 0.12, k)
  lg.setLineWidth(2)
  lg.rectangle("line", p.x + 1, p.y + 1, p.w - 2, p.h - 2, 6)
  local n = 0
  for _, u in ipairs(m.units) do if u.alive then n = n + 1 end end
  lg.setFont(font(30))
  lg.setColor(0.96, 0.94, 0.88, k)
  local title = "THEY'RE BEGGING FOR MERCY"
  lg.print(title, w / 2 - font(30):getWidth(title) / 2, p.y + 18)
  lg.setFont(font(14))
  lg.setColor(0.8, 0.78, 0.74, k)
  local sub = string.format("You found them: %d enemy soldier%s who ran from the fight, unarmed, on their knees. You've lost %d %s.", n, n == 1 and "" or "s",
    #m.fallen, #m.fallen == 1 and "man" or "men")
  lg.printf(sub, p.x + 20, p.y + 64, p.w - 40, "center")
  -- the fallen, by name, and who they leave behind
  lg.setColor(0.75, 0.2, 0.16, k)
  lg.setFont(font(12))
  lg.printf("IN MEMORY OF", p.x + 20, p.y + 96, p.w - 40, "center")
  local top, bottom = p.y + 118, r.spare.y - 46
  local rowH = 19
  local rows = math.max(1, math.floor((bottom - top) / rowH))
  for i, f in ipairs(m.fallen) do
    if i > rows then break end
    local y = top + (i - 1) * rowH
    if i == rows and #m.fallen > rows then
      lg.setFont(font(13))
      lg.setColor(0.7, 0.68, 0.64, k)
      lg.printf(string.format("... and %d more", #m.fallen - rows + 1), p.x + 30, y, p.w - 60, "center")
      break
    end
    local nm = f.age and string.format("%s, %d", f.name, f.age) or f.name
    lg.setFont(font(13))
    lg.setColor(0.95, 0.92, 0.86, k)
    lg.print(nm, p.x + 34, y)
    lg.setFont(font(12))
    lg.setColor(0.68, 0.66, 0.62, k)
    local lx = p.x + 34 + math.max(170, font(13):getWidth(nm) + 14)
    local txt = f.line or ""
    local maxW = p.x + p.w - 30 - lx
    while font(12):getWidth(txt) > maxW and #txt > 4 do txt = txt:sub(1, -6) .. "..." end
    lg.print(txt, lx, y + 1)
  end
  if #m.fallen == 0 then
    lg.setColor(0.6, 0.7, 0.6, k)
    lg.printf("Not one of your men fell.", p.x + 20, top + 10, p.w - 40, "center")
  end
  lg.setFont(font(13))
  lg.setColor(0.7, 0.68, 0.64, k)
  lg.printf("Take them prisoner and the battle is won. Or finish it yourself.", p.x + 20, bottom + 8, p.w - 40, "center")
  local mx, my = love.mouse.getPosition()
  for _, b in ipairs({ r.spare, r.kill }) do
    local hov = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    if b.action == "spare" then lg.setColor(hov and 0.3 or 0.2, hov and 0.42 or 0.3, hov and 0.3 or 0.22, k)
    else lg.setColor(hov and 0.6 or 0.42, hov and 0.12 or 0.08, hov and 0.1 or 0.06, k) end
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
    lg.setColor(1, 1, 1, 0.5 * k)
    lg.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, 6)
    lg.setFont(font(17))
    lg.setColor(1, 1, 1, k)
    local lbl = b.action == "spare" and "Have mercy" or "Kill 'em all"
    lg.print(lbl, b.x + b.w / 2 - font(17):getWidth(lbl) / 2, b.y + 12)
  end
end

function UI.mercyClick(game, x, y, b)
  if b ~= 1 or love.timer.getTime() - game.mercy.t < 0.6 then return end
  local r = UI.mercyRects(game)
  for _, q in ipairs({ r.spare, r.kill }) do
    if x >= q.x and x <= q.x + q.w and y >= q.y and y <= q.y + q.h then game:decideMercy(q.action) end
  end
end

function UI.overClick(game, x, y, b)
  if b ~= 1 then return end
  for _, r in ipairs(UI.rateRects(game)) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      game.rating = game.rating or {}
      game.rating[r.group] = r.value
      if game.log then
        game.log:raw(string.format("RATING: %s = %s", r.group, r.value))
        game.log:flush()
      end
      return
    end
  end
  for _, r in ipairs(UI.overRects(game)) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      if r.action == "again" then game.playAgain = true
      elseif r.action == "savemap" then game:startNaming()
      elseif r.action == "submit" then game:submitScore()
      else game.quitToTitle = true end
    end
  end
end

---------------------------------------------------------------------------

-- Arena: hover any Commander to read his class, level and the skills he has learned
function UI.drawCommanderHover(game)
  local world = game.world
  if not world.heroes then return end
  local mx, my = love.mouse.getPosition()
  local w, h = lg.getDimensions()
  if my < UI.TOP_H or my > h - UI.PANEL_H - UI.ORDERS_H then return end
  local wx, wy = game:screenToWorld(mx, my)
  local c = world:entityAt(wx, wy, function(o) return o.key == "commander" and (o.team == 1 or world:isVisible(o)) end)
  if not c then return end
  local A = require("src.arena")
  local cls = A.byClass[c.class]
  local lines = { string.format("%s  -  %s  Lv %d", c.team == 1 and "You" or D.teamName[c.team], cls and cls.name or "Commander", c.clevel or 0) }
  for slot = 1, 4 do
    local sk = c.skills and c.skills[slot]
    if sk then
      local def = A.SKILLS[sk.key]
      if def then lines[#lines + 1] = (def.ult and "ULT  " or "") .. def.name .. ": " .. def.desc:gsub("^ULTIMATE: ", "") end
    end
  end
  if #lines == 1 then lines[#lines + 1] = "No skills yet" end
  local f = font(12)
  local bw = 0
  for _, l in ipairs(lines) do bw = math.max(bw, f:getWidth(l)) end
  bw = math.min(bw + 20, 560)
  local lh = f:getHeight() + 3
  local bh = 0
  for _, l in ipairs(lines) do local _, wr = f:getWrap(l, bw - 20); bh = bh + #wr * lh end
  bh = bh + 14
  local x, y = math.min(mx + 18, w - bw - 8), math.max(UI.TOP_H + 4, my - bh - 12)
  panelBox(x, y, bw, bh, 0.92)
  lg.setFont(f)
  local yy = y + 7
  for i, l in ipairs(lines) do
    if i == 1 then lg.setColor(1, 0.85, 0.45) else lg.setColor(0.88, 0.92, 0.97) end
    lg.printf(l, x + 10, yy, bw - 20)
    local _, wr = f:getWrap(l, bw - 20)
    yy = yy + #wr * lh
  end
end

-- "Music: Ashfall" for a few seconds whenever the soundtrack changes
function UI.drawMusicLabel(x, y, alignRight, always)
  local MUSIC = require("src.music")
  if MUSIC.muted or not MUSIC.suite then return end
  local age = love.timer.getTime() - (MUSIC.changedAt or -99)
  if not always and age > 5 then return end
  local a = always and 1 or math.min(1, (5 - age) * 1.5)
  local text = "Music: " .. (MUSIC.NAMES[MUSIC.suite] or "?")
  lg.setFont(font(12))
  local tx = alignRight and (x - font(12):getWidth(text)) or x
  lg.setColor(0.55, 0.62, 0.72, 0.85 * a)
  lg.print(text, tx, y)
end

function UI.draw(game)
  local w, h = lg.getDimensions()
  local L = layout(w, h)
  UI.drawSidebar(game)
  UI.drawTop(game)
  UI.drawLeaderboard(game)
  UI.drawCommanderCard(game)
  UI.drawJunglePanel(game)
  if game.arena then UI.drawLanePanel(game) end
  UI.drawCommanderHover(game)
  UI.drawMusicLabel(w - 12, L.panelY - UI.ORDERS_H - 24, true)
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
  UI.drawOrders(game)
  UI.drawTerrainHover(game)

  -- mode hint
  local hint
  if game.mode == "build" then hint = "Placing " .. D.units[game.buildKey].name .. " - click to place, drag for an area, Shift for more, right-click/Esc cancels"
  elseif game.mode == "amove" then hint = "Attack-move: click a destination (Shift queues)"
  elseif not game.mode and game:groupHeld() then hint = "Group move (holding G): click a destination - everyone moves at the slowest unit's pace. Shift queues; let go of G for normal moves"
  elseif game.mode == "patrol" then hint = game:hasSelectedConstructor() and "Patrol: click a destination, or DRAG a circle to make a repair zone" or "Patrol: click a destination (Shift queues)"
  elseif game.mode == "flag" then hint = "Retreat flag: click where fleeing units should regroup"
  elseif game.mode == "skill" then hint = "Click where to use the skill (Esc cancels). Tip: Q W E R cast straight at the mouse."
  elseif game.mode == "nuke" then hint = "NUKE: click the target. Buildings in the circle are destroyed, units lose half their health. Esc cancels" end
  if hint then
    lg.setFont(font(14))
    local tw = font(14):getWidth(hint)
    panelBox(w / 2 - tw / 2 - 12, UI.TOP_H + 8, tw + 24, 30, 0.85)
    lg.setColor(1, 1, 1)
    lg.print(hint, w / 2 - tw / 2, UI.TOP_H + 14)
  end

  -- Commander upgrade choice (non-blocking)
  game.offerBtns = nil
  local myc = game:myCommander()
  if myc and myc.offers and #myc.offers > 0 then
    local offer = myc.offers[1]
    local cw, ch = 330, 96
    local total = #offer * cw + (#offer - 1) * 14
    local ox = w / 2 - total / 2
    local oy = L.panelY - ch - 34 - UI.ORDERS_H
    lg.setFont(font(15))
    -- heroes go by their class name (Ranger level 3!), the RTS Commander by his title
    local who = "Commander"
    if myc.class and game.world.heroes then
      local cls = require("src.arena").byClass[myc.class]
      who = cls and cls.name or who
    end
    local head = string.format("%s level %d!  Choose an upgrade%s", who, myc.clevel - #myc.offers + 1,
      #myc.offers > 1 and string.format("  (%d more waiting)", #myc.offers - 1) or "")
    lg.setColor(0, 0, 0, 0.6)
    lg.rectangle("fill", w / 2 - font(15):getWidth(head) / 2 - 10, oy - 28, font(15):getWidth(head) + 20, 24, 5)
    lg.setColor(1, 0.85, 0.35)
    lg.print(head, w / 2 - font(15):getWidth(head) / 2, oy - 25)
    game.offerBtns = {}
    local mx, my = love.mouse.getPosition()
    for i, u in ipairs(offer) do
      local bx = ox + (i - 1) * (cw + 14)
      local hover = mx >= bx and mx <= bx + cw and my >= oy and my <= oy + ch
      local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 4)
      lg.setColor(0.08, 0.1, 0.14, 0.96)
      if hover then lg.setColor(0.14, 0.18, 0.24, 0.98) end
      lg.rectangle("fill", bx, oy, cw, ch, 8)
      lg.setColor(1, 0.8, 0.3, 0.5 + 0.4 * pulse)
      lg.setLineWidth(2)
      lg.rectangle("line", bx + 1, oy + 1, cw - 2, ch - 2, 8)
      lg.setFont(font(13))
      lg.setColor(1, 0.85, 0.35)
      lg.print(i == 1 and "Z" or "X", bx + 12, oy + 10)
      lg.setFont(font(17))
      lg.setColor(1, 1, 1)
      lg.print(u.name, bx + 34, oy + 8)
      lg.setFont(font(13))
      lg.setColor(0.75, 0.82, 0.9)
      lg.printf(u.desc, bx + 12, oy + 38, cw - 24)
      game.offerBtns[#game.offerBtns + 1] = { x = bx, y = oy, w = cw, h = ch, i = i }
    end
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

  -- dropship coin flip
  local flip = game.flips and game.flips[1]
  if flip then
    local MOD = require("src.mods")
    local t = flip.t
    local done = t >= MOD.FLIP_TIME
    lg.setColor(0, 0, 0, 0.35)
    lg.rectangle("fill", 0, 0, w, h)
    panelBox(w / 2 - 230, h / 2 - 150, 460, 270, 0.97)
    lg.setFont(font(20))
    lg.setColor(0.85, 0.6, 1)
    local head = "Alien drop crew encountered!"
    lg.print(head, w / 2 - font(20):getWidth(head) / 2, h / 2 - 135)
    lg.setFont(font(14))
    lg.setColor(0.7, 0.76, 0.84)
    local sub = "Heads they join you. Tails they attack."
    lg.print(sub, w / 2 - font(14):getWidth(sub) / 2, h / 2 - 104)
    -- the coin: spins fast, slows down, lands
    local spin = done and 0 or (t * t * 3 + t * 18)
    local face
    if done then face = flip.sq.result == "join" and "heads" or "tails"
    else face = (math.floor(spin / math.pi) % 2 == 0) and "heads" or "tails" end
    local sx = done and 1 or math.abs(math.cos(spin))
    local cx, cy, r = w / 2, h / 2 + 5, 58
    local hop = done and 0 or math.sin(math.min(1, t / MOD.FLIP_TIME) * math.pi) * 40
    lg.push()
    lg.translate(cx, cy - hop)
    lg.scale(math.max(0.06, sx), 1)
    if face == "heads" then lg.setColor(0.95, 0.8, 0.3) else lg.setColor(0.75, 0.75, 0.8) end
    lg.circle("fill", 0, 0, r)
    lg.setColor(0.3, 0.22, 0.05)
    lg.setLineWidth(4)
    lg.circle("line", 0, 0, r - 6)
    lg.setFont(font(22))
    local lbl = face == "heads" and "JOIN" or "ATTACK"
    lg.print(lbl, -font(22):getWidth(lbl) / 2, -14)
    lg.pop()
    if done then
      lg.setFont(font(22))
      local res = flip.sq.result == "join" and "They join you!" or "They attack!"
      if flip.sq.result == "join" then lg.setColor(0.4, 1, 0.5) else lg.setColor(1, 0.4, 0.35) end
      lg.print(res, w / 2 - font(22):getWidth(res) / 2, h / 2 + 80)
    end
  end

  if not game.showHelp and not game.menuOpen then UI.drawPendingTip(game) else game.pendingTip = nil end
  if not game.menuOpen then UI.drawMercy(game) end
  if game.showHelp then UI.drawHelp(game.craft and "craft" or (game.world.squads and "coh") or game.arena) end
  if game.menuOpen then UI.drawMenu(game) end
  if game.autoOpen then require("src.automation").draw(game, font) end
  if require("src.settings").open then require("src.settings").draw() end
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
  if b == 1 and UI.cmdCardClick(game, x, y) then return true end
  for _, ob in ipairs(game.offerBtns or {}) do
    if x >= ob.x and x <= ob.x + ob.w and y >= ob.y and y <= ob.y + ob.h then
      game:pickUpgrade(ob.i)
      return true
    end
  end
  if y <= UI.TOP_H then
    for _, tb in ipairs(game.topBtns or {}) do
      if x >= tb.x and x <= tb.x + tb.w and y >= tb.y and y <= tb.y + tb.h then
        if tb.action == "menu" then game.menuOpen = true
        elseif tb.action == "help" then game.showHelp = true
        elseif tb.action == "auto" then game.autoOpen = true
        elseif tb.action == "pause" then game.paused = not game.paused
        elseif tb.action == "faster" then game:stepSpeed(1)
        elseif tb.action == "slower" then game:stepSpeed(-1)
        elseif tb.action == "speed1" then game:setSpeed(1) end
      end
    end
    return true
  end
  -- orders bar
  for _, btn in ipairs(game.orderBtns or {}) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      if b == 1 and btn.on then game:orderAction(btn.action, love.keyboard.isDown("lshift", "rshift")) end
      return true
    end
  end
  if y < L.panelY then return UI.sidebarClick(game, x, y, b) end
  -- minimap
  local wx, wy = UI.minimapToWorld(game, x, y)
  if wx then
    if b == 1 then
      if not game.mode and game:groupHeld() then
        game:commandMove(wx, wy, "gmove", love.keyboard.isDown("lshift", "rshift"))
      elseif game.mode == "amove" or game.mode == "patrol" then
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
        elseif btn.action == "nuke" then game:startNuke()
        elseif btn.action == "retreat" then game:retreat(shift and "commander" or "flag")
        elseif btn.action == "repeat" then
          for _, f in ipairs(game:selectedFactories()) do f.repeatMode = not f.repeatMode end
        else game.mode = btn.action end
      elseif btn.kind == "builder" then
        if b == 1 then
          local ok, why = true, nil
          if game.craft then ok, why = require("src.craft").canOrder(game.world, 1, btn.key) end
          if ok then game.mode = "build"; game.buildKey = btn.key
          else game:notice(why, 1.6) end
        end
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
  -- Commander of Heroes: skill buttons and squad cards in the bottom panel
  for _, sb in ipairs(game.sqInfoBtns or {}) do
    if sb.flee and x >= sb.x and x <= sb.x + sb.w and y >= sb.y and y <= sb.y + sb.h then
      game:fleeSquad(sb.sq)
      return true
    end
  end
  for _, sb in ipairs(game.sqInfoBtns or {}) do
    if not sb.flee and x >= sb.x and x <= sb.x + sb.w and y >= sb.y and y <= sb.y + sb.h then
      local def = require("src.squads").SKILLS[sb.sq.skills[sb.slot].key]
      if def.aim == "point" then
        game.mode, game.sqAim = "sqskill", { sq = sb.sq, slot = sb.slot }
        game:notice(def.name .. ": click the spot (Esc cancels)", 1.6)
      else
        game:squadSkill(sb.slot, sb.sq)
      end
      return true
    end
  end
  for _, c in ipairs(game.sqCards or {}) do
    if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then
      game:pickSquad(c.sq, love.keyboard.isDown("lshift", "rshift"))
      return true
    end
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
