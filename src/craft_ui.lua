-- Commander Craft: HUD pieces (resource bar, build card prices, orders bar, sidebar)
-- and world decorations (trees, gold mines, what workers carry).
local D = require("src.defs")
local U = require("src.util")
local R = require("src.render")
local C = require("src.craft")
local ARENA = require("src.arena")

local CU = {}
local lg = love.graphics
local function font(n) return R.font(n) end

---------------------------------------------------------------------------
-- World

function CU.drawWorld(world, x0, y0, x1, y1, list)
  local map = world.map
  if map.mmDirty and map.minimap and map.mmData then
    map.minimap:replacePixels(map.mmData)
    map.mmDirty = false
  end
  C.drawGround(world, x0, y0, x1, y1)
end

-- drawn after the units: mine gold, worker loads
function CU.drawOver(world, cam, list)
  local T = world.T
  for _, e in ipairs(list) do
    if e.key == "goldmine" and e.alive then
      local half = e.def.w * T * 0.5
      local f = math.max(0, e.gold / e.goldMax)
      lg.setColor(0, 0, 0, 0.6)
      lg.rectangle("fill", e.x - half, e.y + half + 4, half * 2, 7, 2)
      lg.setColor(1, 0.82, 0.25)
      lg.rectangle("fill", e.x - half, e.y + half + 4, half * 2 * f, 7, 2)
      if cam.zoom > 0.5 then
        lg.setFont(font(11))
        local s = 1 / math.max(cam.zoom, 0.7)
        local txt = U.fmt(math.floor(e.gold)) .. " gold"
        lg.setColor(1, 0.9, 0.5)
        lg.print(txt, e.x - font(11):getWidth(txt) * s / 2, e.y + half + 12, 0, s, s)
      end
    elseif e.carry and e.alive then
      if e.carry.kind == "gold" then lg.setColor(1, 0.82, 0.25) else lg.setColor(0.55, 0.36, 0.18) end
      lg.circle("fill", e.x + 7, e.y - 7, 4)
      lg.setColor(0, 0, 0, 0.7)
      lg.circle("line", e.x + 7, e.y - 7, 4)
    elseif e.chopping and e.alive and e.orders[1] and e.orders[1].type == "harvest" then
      local k = math.sin(world.time * 12 + e.id) * 0.5 + 0.5
      lg.setColor(0.9, 0.85, 0.7, 0.8)
      lg.setLineWidth(2)
      lg.line(e.x + math.cos(e.angle) * 6, e.y + math.sin(e.angle) * 6,
        e.x + math.cos(e.angle + k) * 14, e.y + math.sin(e.angle + k) * 14)
    end
  end
end

---------------------------------------------------------------------------
-- Top bar: gold, wood, food, upkeep, tier

function CU.drawTop(game)
  local w = game.world
  local tm = w.teams[1]
  local r = C.raceOf(w, 1)
  local x = 14
  local function chip(label, value, col, sub)
    lg.setFont(font(13))
    lg.setColor(col[1], col[2], col[3])
    lg.print(label, x, 10)
    x = x + font(13):getWidth(label) + 6
    lg.setFont(font(15))
    lg.setColor(1, 1, 1)
    lg.print(value, x, 8)
    x = x + font(15):getWidth(value) + 6
    if sub then
      lg.setFont(font(11))
      lg.setColor(0.6, 0.7, 0.8)
      lg.print(sub, x, 12)
      x = x + font(11):getWidth(sub)
    end
    x = x + 20
  end
  chip("GOLD", tostring(math.floor(tm.gold)), { 1, 0.82, 0.25 }, tm.goldRate and string.format("+%d/min", tm.goldRate) or nil)
  chip("WOOD", tostring(math.floor(tm.wood)), { 0.6, 0.85, 0.45 }, tm.woodRate and string.format("+%d/min", tm.woodRate) or nil)
  local full = (tm.foodUsed or 0) >= (tm.foodCap or 0)
  lg.setFont(font(13))
  lg.setColor(0.95, 0.6, 0.45)
  lg.print("FOOD", x, 10)
  x = x + font(13):getWidth("FOOD") + 6
  lg.setFont(font(15))
  if full then lg.setColor(1, 0.4, 0.35) else lg.setColor(1, 1, 1) end
  local ft = string.format("%d/%d", tm.foodUsed or 0, tm.foodCap or 0)
  lg.print(ft, x, 8)
  x = x + font(15):getWidth(ft) + 10
  local mul, txt, lvl = C.upkeep(tm)
  lg.setFont(font(12))
  if lvl == 1 then lg.setColor(0.5, 0.9, 0.5) elseif lvl == 2 then lg.setColor(1, 0.8, 0.3) else lg.setColor(1, 0.45, 0.35) end
  lg.print(txt, x, 11)
  x = x + font(12):getWidth(txt) + 18
  lg.setColor(0.85, 0.75, 0.5)
  lg.print(r.tierNames[tm.tier or 1], x, 11)
  game.craftTopRight = x + font(12):getWidth(r.tierNames[tm.tier or 1])
end

---------------------------------------------------------------------------
-- Command card: prices and greyed-out buttons

function CU.drawCardButton(game, b)
  local w = game.world
  local d = D.units[b.key]
  local ok, why = C.canOrder(w, 1, b.key)
  local mx, my = love.mouse.getPosition()
  local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
  local active = game.mode == "build" and game.buildKey == b.key
  -- a tier lock is a different grey from "can't afford yet"
  local locked = why and (why:match("^Needs") or why:match("^Hero #") or why:match("^Already") or why:match("three heroes"))
  lg.setColor(0.12, 0.15, 0.2)
  if hover then lg.setColor(0.18, 0.24, 0.3) end
  if active then lg.setColor(0.15, 0.32, 0.22) end
  lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
  lg.setColor(0.3, 0.38, 0.46)
  lg.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, 6)
  local iconKey = b.key
  if d.heroRecruit then iconKey = "cls_" .. d.heroRecruit end
  if d.research or d.heroRecruit then
    require("src.icons").draw(iconKey, b.x + b.w / 2, b.y + b.h / 2 - 6, 34)
    if not require("src.icons").has(iconKey) then
      lg.setFont(font(14)); lg.setColor(1, 0.9, 0.6)
      lg.print(d.short, b.x + b.w / 2 - font(14):getWidth(d.short) / 2, b.y + b.h / 2 - 14)
    end
  else
    require("src.ui").drawIcon(b.key, b.x + b.w / 2, b.y + b.h / 2 - 6, 40, 1)
  end
  if locked then
    lg.setColor(0.05, 0.06, 0.08, 0.72)
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
    lg.setFont(font(10))
    lg.setColor(0.8, 0.7, 0.5)
    local tierN = d.tier and ("T" .. d.tier) or "--"
    lg.print(tierN, b.x + b.w - font(10):getWidth(tierN) - 4, b.y + 3)
  elseif not ok then
    lg.setColor(0.25, 0.05, 0.05, 0.35)
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
  end
  local g, wd = C.price(w, 1, b.key)
  lg.setFont(font(11))
  lg.setColor(1, 0.82, 0.25)
  lg.print(tostring(g), b.x + 4, b.y + b.h - 16)
  if wd > 0 then
    lg.setColor(0.6, 0.85, 0.45)
    local t = tostring(wd)
    lg.print(t, b.x + b.w - font(11):getWidth(t) - 4, b.y + b.h - 16)
  end
  lg.setColor(1, 1, 1, 0.75)
  lg.print(string.upper(b.hotkey or ""), b.x + 5, b.y + 3)
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
  return hover
end

function CU.tooltip(game, b)
  local w = game.world
  local d = D.units[b.key]
  local g, wd, food = C.price(w, 1, b.key)
  local lines = { d.name }
  if d.heroRecruit then
    local cls = ARENA.byClass[d.heroRecruit]
    lines[1] = "Hero: " .. cls.name
    lines[#lines + 1] = cls.tag
  end
  local cost = string.format("Cost: %d gold", g)
  if wd > 0 then cost = cost .. string.format(", %d wood", wd) end
  if food > 0 then cost = cost .. string.format(", %d food", food) end
  lines[#lines + 1] = cost .. string.format("   (%ds)", math.ceil(d.cost.work / 10))
  if d.weapon and not d.research then
    lines[#lines + 1] = string.format("%s: %d damage, range %d%s", d.melee and "Melee" or "Ranged", d.weapon.damage, d.weapon.range,
      d.weapon.targets.air and ", hits air" or "")
  end
  if d.hp and d.hp > 1 and not d.research then lines[#lines + 1] = string.format("Health %d", d.hp) end
  if d.food and d.building then lines[#lines + 1] = string.format("Provides %d food", d.food) end
  lines[#lines + 1] = d.desc or ""
  local ok, why = C.canOrder(w, 1, b.key)
  if not ok and why then lines[#lines + 1] = "[" .. why .. "]" end
  if b.kind == "factory" and not d.research and not d.heroRecruit then lines[#lines + 1] = "Click = 1, Shift-click = 5, right-click removes (refunds)" end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Orders bar

CU.ORDERS = {
  { "amove", "Attack", "A", "Attack-move: click a spot; units fight anything on the way." },
  { "stop", "Stop", "S", "Stop: cancel orders and hold position." },
  { "hold", "Hold", "D", "Hold fire while D is held (or click to toggle)." },
  { "patrol", "Patrol", "P", "Patrol back and forth to a spot." },
  { "flee", "Flee", "F", "Selected units retreat to your flag (+25% speed, weapons off until healed). A hero flees to your hall at +50%." },
  { "skill1", nil, "Q" }, { "skill2", nil, "W" }, { "skill3", nil, "E" }, { "skill4", nil, "R" },
  { "army", "Army", "Ctrl+A", "Select every fighting unit (not workers)." },
  { "builder", "Worker", "Tab", "Jump to the next idle worker. Shift+Q trains one at your hall from anywhere." },
  { "cmd", "Hero", "C", "Jump between your heroes." },
  { "follow", "Follow", "L", "Camera follows the selection." },
  { "help", "Help", "F1", "All controls and tips." },
}

function CU.orderButtons(game)
  local w, h = lg.getDimensions()
  local UI = require("src.ui")
  local hero = require("src.craft_game").activeHero(game)
  local heroSel = hero and game.selected[hero]
  local mobile = #game:selectedMobile() > 0
  local n = #game:selectedList()
  local enabled = { amove = mobile, stop = mobile, hold = n > 0, patrol = mobile, flee = mobile, army = true, builder = true,
    cmd = true, follow = n > 0, help = true }
  local list, gap, total = {}, 4, 0
  for _, o in ipairs(CU.ORDERS) do total = total + (o[1]:match("^skill") and 96 or 60) + gap end
  total = total - gap
  local x = math.floor(w / 2 - total / 2)
  local y = h - UI.PANEL_H - UI.ORDERS_H
  for _, o in ipairs(CU.ORDERS) do
    local slot = tonumber(o[1]:match("^skill(%d)"))
    local bw = slot and 96 or 60
    local b = { x = x, y = y + 3, w = bw, h = UI.ORDERS_H - 6, action = o[1], key = o[3], on = enabled[o[1]] }
    if slot then
      local sk = hero and hero.skills and hero.skills[slot]
      if sk then
        local def = ARENA.SKILLS[sk.key]
        b.label, b.tip, b.skill = def.name, def.desc .. (heroSel and "" or "  (select the hero to use Q W E R from the keyboard)"), sk
        b.cd = math.max(0, sk.readyAt - game.world.time)
        b.cdMax = def.cd * ((hero.mods and hero.mods.cdr) or 1)
        b.on = hero.alive
      else
        b.label = slot == 4 and "Ultimate" or "Skill " .. slot
        b.tip = slot == 4 and "Your hero unlocks the ultimate at level 6." or "Learn more skills at levels 2 and 4."
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

---------------------------------------------------------------------------
-- Sidebar: production buildings and heroes (workers are counted, not listed)

function CU.sidebarLists(game)
  local facs, heroes = {}, {}
  for _, e in ipairs(game.world.entities) do
    if e.alive and e.team == 1 and e.built >= 1 then
      if e.def.factory then facs[#facs + 1] = e
      elseif e.key == "commander" then heroes[#heroes + 1] = e end
    end
  end
  table.sort(facs, function(a, b) return a.id < b.id end)
  table.sort(heroes, function(a, b) return a.id < b.id end)
  return facs, heroes
end

---------------------------------------------------------------------------
-- Help

CU.HELP = [[
COMMANDER CRAFT - CONTROLS                         (a Warcraft-style mode)

Goal: destroy every enemy building. Lose all of yours and you're out (no hall left = your base is revealed).

Economy
  Workers (Peasants / Peons): right-click a GOLD MINE to mine (one worker inside at a time, ~5 per mine),
  right-click a TREE to chop wood. They carry it to your hall (wood also to a Lumber Mill / War Mill).
  New workers start gathering by themselves. Tab = next idle worker, Shift+Q = train a worker from anywhere. Mines run dry: the middle mine is the big one,
  guarded by creeps - kill them for gold and hero experience.
  Everything is paid in full when you order it (right-click a queued unit to cancel and get it back).
  FOOD: every unit uses food; Farms / Burrows and halls provide it (max 80).
  UPKEEP: above 40 food your gold income drops 30%, above 60 food it drops 60%. Big armies cost you.

Building and tiers
  Select a worker, then Q W E R T Y U I O P (or click) to place a building.
  Halls upgrade: Town Hall -> Keep -> Castle (Vanguard), Great Hall -> Stronghold -> Fortress (Warband).
  Higher tiers unlock units, buildings, research and your 2nd (tier 2) and 3rd (tier 3) hero.
  Units never level up: every improvement is bought - weapons and armor at the Blacksmith / War Mill,
  and each production building researches upgrades for the units it trains.

Heroes
  You start with one hero (your class), with one skill. Every level: +6% health, +5% damage and a card
  (Z / X): skills at 2 and 4, the ultimate at 6, upgrades otherwise. Experience comes from enemy units
  and creeps dying near your heroes (shared between them).
  Select a hero: Q W E R cast his skills at the mouse.  C = next hero.  F = flee to your hall (+50% speed).
  Heroes heal fast next to your halls. Fallen heroes rise at your altar (or hall) after a short wait, for 80 + 30 x level gold.

Melee units (swords, axes, cavalry) must reach their target; ranged units and towers hit from afar and can
shoot flyers. Siege (Mortars, Demolishers) wrecks buildings. Casters heal, slow or bloodlust on their own.

  Right-click = move / attack / gather.  A = attack-move,  G = group move,  S = stop,  hold D = hold fire,  Ctrl+A = army
  Ctrl+1..9 groups, 1..9 recall.  Space = last attack.  Esc = menu,  F3 = pause,  + / - = game speed
]]

return CU
