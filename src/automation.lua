-- Automation (Annihilation): standing orders the player can switch on so the routine stuff runs
-- itself - the same kind of logic the computer players use, surfaced as "controls" in the spirit
-- of AI War. Each rule has an on/off switch and, where it makes sense, a number. The choices are
-- remembered between matches (automation.lua in the save folder).
--
--   flee      combat units below N% health flee to the plant that built them (weapons off
--             until repaired, like pressing F)
--   rejoin    once a unit that fled is fully repaired, it returns to your flag (or to where it
--             was when it fled)
--   builders  keep at least N constructors: if you're short, the next slot of a vehicle plant's
--             queue gets one (what's being built now isn't interrupted, and Repeat won't copy it)
--   repair    idle constructors repair damaged units and buildings near them (repairs cost
--             resources: 30% of the price for a full repair)
local U = require("src.util")
local A = {}

A.FILE = "automation.lua"
A.RULES = {
  { key = "flee", label = "Units flee when hurt", desc = "Combat units below this health flee to the plant that built them.",
    value = "fleePct", min = 10, max = 70, step = 5, unit = "% health" },
  { key = "rejoin", label = "Repaired units rejoin", desc = "Units that fled return to your flag (or where they were) once fully repaired." },
  { key = "builders", label = "Keep constructors", desc = "If you have fewer than this, a vehicle plant builds one next (it doesn't interrupt the current build).",
    value = "builderMin", min = 1, max = 8, step = 1, unit = " minimum" },
  { key = "repair", label = "Idle constructors repair", desc = "Constructors with nothing to do fix damaged things near them (repairs cost resources)." },
}
A.v = { flee = false, fleePct = 30, rejoin = false, builders = false, builderMin = 2, repair = false }
-- per-unit flee thresholds ("Per unit..." on the flee row): 0 = use the general one
A.UNITS = { "scout", "tank", "artillery", "flak", "fighter", "bomber", "gunship", "boat", "destroyer", "sub", "battleship" }
for _, k in ipairs(A.UNITS) do A.v["flee_" .. k] = 0 end
A.view = "main"
function A.fleePctFor(key)
  local p = A.v["flee_" .. key]
  if p and p > 0 then return p end
  return A.v.fleePct
end

local function ser(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = string.format("%s = %s", k, type(v) == "string" and string.format("%q", v) or tostring(v)) end
  return "return { " .. table.concat(parts, ", ") .. " }"
end

function A.load()
  local ok, chunk = pcall(love.filesystem.load, A.FILE)
  if ok and chunk then
    local ok2, t = pcall(chunk)
    if ok2 and type(t) == "table" then
      for k, v in pairs(t) do if A.v[k] ~= nil and type(v) == type(A.v[k]) then A.v[k] = v end end
    end
  end
end
function A.save() pcall(love.filesystem.write, A.FILE, ser(A.v)) end

-- only in Annihilation proper (Commander of Heroes, the Arena and Craft run their own way)
function A.applies(game)
  local w = game.world
  return not (w.squads or w.craft or w.arena or w.heroes or game.arena or game.craft)
end

function A.anyOn()
  return A.v.flee or A.v.rejoin or A.v.builders or A.v.repair
end

local function countBuilders(w, team)
  local n = 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team then
      if e.key == "builder" then n = n + 1 end
      if e.def.factory and e.queue then for _, k in ipairs(e.queue) do if k == "builder" then n = n + 1 end end end
    end
  end
  return n
end

-- where a unit falls back to: the plant that built it, else where it was born, else home
local function homeFor(w, u)
  local f = u.bornFrom
  local x, y
  if f and f.alive then x, y = f.x, f.y + (f.def.h * w.T) / 2 + 40
  elseif u.bornX then x, y = u.bornX, u.bornY
  else local tm = w.teams[u.team]; x, y = tm.startX, tm.startY end
  -- open ground there (a spot taken by a building would count as "arrived" at once)
  local map = w.map
  local layer = (u.def.domain == "sea" or u.def.domain == "sub") and "sea" or "land"
  if u.def.domain ~= "air" then
    local tx, ty = map:tileAt(x + math.random(-50, 50), y + math.random(-30, 30))
    local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable(layer, a, b) and not map.blocked[b * map.w + a] end, 8)
    if nx then return map:center(nx, ny) end
  end
  return x, y
end

function A.update(game, dt)
  if not A.anyOn() or not A.applies(game) then return end
  local w = game.world
  if w.over then return end
  A.timer = (A.timer or 0) - dt
  if A.timer > 0 then return end
  A.timer = 0.5
  local team = game.playerTeam or w.playerTeam or 1
  local v = A.v

  for _, u in ipairs(w.entities) do
    if u.alive and u.team == team and not u.def.building and u.built >= 1 then
      local o = u.orders[1]
      -- 1. fall back when hurt
      if v.flee and u.def.weapon and u.key ~= "commander" and u.key ~= "builder" and not u.disarmed
        and u.hp < u.maxhp * A.fleePctFor(u.key) / 100 and not (o and o.type == "retreat") then
        local hx, hy = homeFor(w, u)
        if U.dist2(u.x, u.y, hx, hy) > 250 * 250 then
          u.autoFled = { x = u.x, y = u.y }
          w:issue(u, { type = "retreat", x = hx, y = hy })
        end
      -- 2. back to the fight once whole
      elseif v.rejoin and u.autoFled and u.hp >= u.maxhp - 0.5 and not u.disarmed and not (o and o.type == "retreat") then
        local tx, ty = u.autoFled.x, u.autoFled.y
        if game.flag then tx, ty = game.flag.x, game.flag.y end
        u.autoFled = nil
        w:issue(u, { type = "amove", x = tx + math.random(-60, 60), y = ty + math.random(-60, 60) })
      end
      -- 4. idle constructors repair what's near them
      if v.repair and u.key == "builder" and #u.orders == 0 then
        local best, bd
        w:query(u.x, u.y, 520, function(e)
          if e.alive and e.team == team and e ~= u and e.built >= 1 and e.hp < e.maxhp * 0.95 and e.key ~= "commander" then
            local d = U.dist2(u.x, u.y, e.x, e.y)
            if d < 500 * 500 and (not bd or d < bd) then best, bd = e, d end
          end
        end)
        if best then w:issue(u, { type = "assist", target = best }) end
      end
    end
  end

  -- 3. keep a minimum number of constructors
  if v.builders and countBuilders(w, team) < v.builderMin then
    local plant
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == team and e.key == "landfac" and e.built >= 1 then
        if not plant or #e.queue < #plant.queue then plant = e end
      end
    end
    if plant then
      -- next in line, after whatever is being built right now
      table.insert(plant.queue, math.min(2, #plant.queue + 1), "builder")
      plant.noRepeat = plant.noRepeat or {}
      plant.noRepeat.builder = (plant.noRepeat.builder or 0) + 1
      if game.notice then game:notice("Auto: a constructor queued at the vehicle plant", 1.5) end
    end
  end
end

---------------------------------------------------------------------------
-- The panel (the Auto button, K, or Menu > Auto)

function A.unitRects()
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local pw, rowH = 640, 44
  local per = math.ceil(#A.UNITS / 2)
  local px = (w - pw) / 2
  local py = h / 2 - (per * rowH) / 2 - 50
  local out = {}
  for i, k in ipairs(A.UNITS) do
    local col, row = (i - 1) >= per and 1 or 0, (i - 1) % per
    local x, y = px + 24 + col * (pw / 2), py + 80 + row * rowH
    out[#out + 1] = { x = x + 128, y = y, w = 30, h = 30, kind = "uminus", unitKey = k }
    out[#out + 1] = { x = x + 246, y = y, w = 30, h = 30, kind = "uplus", unitKey = k }
  end
  out[#out + 1] = { x = px + pw / 2 - 70, y = py + 80 + per * rowH + 6, w = 140, h = 36, kind = "back" }
  return out, px, py, pw, rowH, per
end

function A.rects()
  if A.view == "units" then return A.unitRects() end
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local pw, rowH = 640, 86
  local px = (w - pw) / 2
  local py = h / 2 - (#A.RULES * rowH) / 2 - 40
  local out = {}
  for i, r in ipairs(A.RULES) do
    local y = py + 70 + (i - 1) * rowH
    out[#out + 1] = { x = px + pw - 120, y = y, w = 96, h = 34, kind = "toggle", rule = r }
    if r.value then
      out[#out + 1] = { x = px + pw - 300, y = y, w = 34, h = 34, kind = "minus", rule = r }
      out[#out + 1] = { x = px + pw - 160, y = y, w = 34, h = 34, kind = "plus", rule = r }
    end
    if r.key == "flee" then out[#out + 1] = { x = px + pw - 300, y = y + 40, w = 174, h = 28, kind = "perunit" } end
  end
  out[#out + 1] = { x = px + pw / 2 - 70, y = py + 70 + #A.RULES * rowH, w = 140, h = 36, kind = "close" }
  return out, px, py, pw, rowH
end

local function button(lg, fontFn, b, label, on)
  local mx, my = love.mouse.getPosition()
  local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
  if on then lg.setColor(0.2, 0.5, 0.3) elseif hover then lg.setColor(0.25, 0.3, 0.38) else lg.setColor(0.15, 0.18, 0.23) end
  lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
  lg.setColor(0.45, 0.55, 0.65)
  lg.rectangle("line", b.x, b.y, b.w, b.h, 6)
  lg.setColor(1, 1, 1)
  lg.setFont(fontFn(14))
  lg.printf(label, b.x, b.y + b.h / 2 - 9, b.w, "center")
end

function A.drawUnits(game, fontFn)
  local lg = love.graphics
  local D = require("src.defs")
  local w, h = lg.getDimensions()
  local rects, px, py, pw, rowH, per = A.unitRects()
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 0, 0, w, h)
  local ph = 80 + per * rowH + 56
  lg.setColor(0.07, 0.09, 0.12, 0.97)
  lg.rectangle("fill", px, py, pw, ph, 10)
  lg.setColor(0.4, 0.55, 0.7)
  lg.rectangle("line", px, py, pw, ph, 10)
  lg.setFont(fontFn(22))
  lg.setColor(1, 1, 1)
  lg.print("AUTO - FLEE PER UNIT", px + 24, py + 18)
  lg.setFont(fontFn(13))
  lg.setColor(0.65, 0.72, 0.8)
  lg.print(string.format("Health at which each kind flees. \"Default\" uses the general setting (%d%%).", A.v.fleePct), px + 24, py + 48)
  for i, k in ipairs(A.UNITS) do
    local col, row = (i - 1) >= per and 1 or 0, (i - 1) % per
    local x, y = px + 24 + col * (pw / 2), py + 80 + row * rowH
    lg.setFont(fontFn(15))
    lg.setColor(0.9, 0.92, 0.95)
    lg.print(D.units[k].name, x, y + 6)
    local p = A.v["flee_" .. k]
    lg.setColor(p > 0 and 1 or 0.6, p > 0 and 0.85 or 0.65, p > 0 and 0.4 or 0.7)
    lg.printf(p > 0 and (p .. "%") or "default", x + 158, y + 6, 88, "center")
  end
  for _, b in ipairs(rects) do button(lg, fontFn, b, b.kind == "uminus" and "-" or (b.kind == "uplus" and "+" or "Back")) end
end

function A.draw(game, fontFn)
  if A.view == "units" then return A.drawUnits(game, fontFn) end
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local rects, px, py, pw, rowH = A.rects()
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 0, 0, w, h)
  local ph = 70 + #A.RULES * rowH + 56
  lg.setColor(0.07, 0.09, 0.12, 0.97)
  lg.rectangle("fill", px, py, pw, ph, 10)
  lg.setColor(0.4, 0.55, 0.7)
  lg.rectangle("line", px, py, pw, ph, 10)
  lg.setFont(fontFn(22))
  lg.setColor(1, 1, 1)
  lg.print("AUTO", px + 24, py + 18)
  lg.setFont(fontFn(13))
  lg.setColor(0.65, 0.72, 0.8)
  lg.print("Standing orders for routine jobs. Remembered between matches (Annihilation only).", px + 24, py + 46)
  local mx, my = love.mouse.getPosition()
  for i, r in ipairs(A.RULES) do
    local y = py + 70 + (i - 1) * rowH
    lg.setFont(fontFn(16))
    lg.setColor(A.v[r.key] and 1 or 0.7, A.v[r.key] and 1 or 0.72, A.v[r.key] and 1 or 0.75)
    lg.print(r.label, px + 24, y + 2)
    lg.setFont(fontFn(12))
    lg.setColor(0.6, 0.66, 0.72)
    lg.printf(r.desc, px + 24, y + 26, pw - (r.value and 340 or 170), "left")
    if r.value then
      lg.setFont(fontFn(16))
      lg.setColor(1, 0.85, 0.4)
      local txt = tostring(A.v[r.value]) .. r.unit
      lg.printf(txt, px + pw - 266, y + 8, 106, "center")
    end
  end
  for _, b in ipairs(rects) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    local on = b.kind == "toggle" and A.v[b.rule.key]
    if on then lg.setColor(0.2, 0.5, 0.3) elseif hover then lg.setColor(0.25, 0.3, 0.38) else lg.setColor(0.15, 0.18, 0.23) end
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
    lg.setColor(0.45, 0.55, 0.65)
    lg.rectangle("line", b.x, b.y, b.w, b.h, 6)
    lg.setColor(1, 1, 1)
    lg.setFont(fontFn(15))
    local label = b.kind == "toggle" and (on and "On" or "Off") or (b.kind == "minus" and "-" or (b.kind == "plus" and "+"
      or (b.kind == "perunit" and "Per unit..." or "Done")))
    lg.printf(label, b.x, b.y + b.h / 2 - 9, b.w, "center")
  end
end

-- returns true while the panel should stay open
function A.click(x, y)
  for _, b in ipairs(A.rects()) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      local r = b.rule
      if b.kind == "perunit" then A.view = "units"
      elseif b.kind == "back" then A.view = "main"
      elseif b.kind == "uminus" or b.kind == "uplus" then
        local k = "flee_" .. b.unitKey
        local p = A.v[k]
        if b.kind == "uplus" then p = (p == 0) and 10 or math.min(90, p + 5)
        else p = (p <= 10) and 0 or p - 5 end
        A.v[k] = p
      elseif b.kind == "toggle" then A.v[r.key] = not A.v[r.key]
      elseif b.kind == "minus" then A.v[r.value] = math.max(r.min, A.v[r.value] - r.step)
      elseif b.kind == "plus" then A.v[r.value] = math.min(r.max, A.v[r.value] + r.step)
      elseif b.kind == "close" then A.save(); A.view = "main"; return false end
      A.save()
      return true
    end
  end
  return true
end

return A
