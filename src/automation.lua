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
--
-- Idle constructors (never overrides an order you gave - only constructors with nothing to do,
-- never the Commander). One list, in the order you choose (drag to reorder): an idle constructor
-- does the first job that's switched on and has something to do.
--   repair    fix damaged units and buildings near it (repairs cost resources)
--   expand    claim the nearest free metal deposit (land; none with enemies next to it)
--   power     energy running low: a solar collector at home
local U = require("src.util")
local A = {}

A.FILE = "automation.lua"
A.RULES = {
  { key = "flee", label = "Units flee when hurt", desc = "Combat units below this health flee to your flag (or, with no flag, the plant that built them) and leave your selection.",
    value = "fleePct", min = 10, max = 70, step = 5, unit = "% health" },
  { key = "rejoin", label = "Repaired units rejoin", desc = "Units that fled go back to where they fled from once fully repaired." },
  { key = "builders", label = "Keep constructors", desc = "If you have fewer than this, a vehicle plant builds one next (it doesn't interrupt the current build).",
    value = "builderMin", min = 1, max = 8, step = 1, unit = " minimum" },
}
A.JOBS = {
  repair = { label = "Repair", desc = "Fix damaged units and buildings near it (costs resources)." },
  expand = { label = "Expand", desc = "Claim the nearest free metal deposit (skips ones with enemies near)." },
  power = { label = "Power", desc = "Energy running low: build a solar collector at home." },
}
A.v = { flee = false, fleePct = 30, rejoin = false, builders = false, builderMin = 2, repair = false, expand = false, power = false,
  idleOrder = "repair,expand,power" }
function A.jobOrder()
  local out, seen = {}, {}
  for k in A.v.idleOrder:gmatch("[^,]+") do if A.JOBS[k] and not seen[k] then out[#out + 1] = k; seen[k] = true end end
  for _, k in ipairs({ "repair", "expand", "power" }) do if not seen[k] then out[#out + 1] = k end end
  return out
end
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
  return A.v.flee or A.v.rejoin or A.v.builders or A.v.repair or A.v.expand or A.v.power
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
  local ship = u.def.domain == "sea" or u.def.domain == "sub"
  if ship and not (f and f.alive) then
    -- its own yard is gone: the nearest shipyard we still have
    local bd
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == u.team and e.key == "shipyard" and e.built >= 1 then
        local d = U.dist2(u.x, u.y, e.x, e.y)
        if not bd or d < bd then f, bd = e, d end
      end
    end
  end
  if f and f.alive then x, y = f.x, f.y + (f.def.h * w.T) / 2 + 40
  elseif u.bornX then x, y = u.bornX, u.bornY
  else local tm = w.teams[u.team]; x, y = tm.startX, tm.startY end
  -- open ground there (a spot taken by a building would count as "arrived" at once)
  local map = w.map
  local layer = (u.def.domain == "sea" or u.def.domain == "sub") and "sea" or "land"
  if u.def.domain ~= "air" then
    local tx, ty = map:tileAt(x + math.random(-50, 50), y + math.random(-30, 30))
    local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable(layer, a, b) and not map.blocked[b * map.w + a] end, ship and 40 or 8)
    if nx then return map:center(nx, ny) end
  end
  return x, y
end

A.homeFor = homeFor

-- can this unit use the flag? Ships only when it's on (or right by) water they can reach -
-- a flag on land would leave them stuck at the shore, far from any repairs. Ships otherwise go
-- back to the shipyard that built them (it repairs them like a plant repairs tanks)
function A.flagFor(w, flag, u)
  if not flag then return nil end
  if u.def.domain ~= "sea" and u.def.domain ~= "sub" then return flag.x, flag.y end
  local map = w.map
  local tx, ty = map:tileAt(flag.x, flag.y)
  local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("sea", a, b) and not map.blocked[b * map.w + a] end, 3)
  if nx then return map:center(nx, ny) end
  return nil
end

-- the idle jobs: each returns true if it gave the constructor something to do
A.doJob = {}
function A.doJob.repair(game, w, team, u)
  local best, bd
  w:query(u.x, u.y, 520, function(e)
    if e.alive and e.team == team and e ~= u and e.built >= 1 and e.hp < e.maxhp * 0.95 and e.key ~= "commander" then
      local d = U.dist2(u.x, u.y, e.x, e.y)
      if d < 500 * 500 and (not bd or d < bd) then best, bd = e, d end
    end
  end)
  if best then w:issue(u, { type = "assist", target = best }); return true end
end

-- deposits our constructors are already on their way to
local function claimed(w, team)
  local c = {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team and e.orders then
      for _, o in ipairs(e.orders) do if o.type == "build" and o.key == "mex" then c[o.ty * w.map.w + o.tx] = true end end
    end
  end
  return c
end

function A.doJob.expand(game, w, team, u)
  local map = w.map
  local taken = claimed(w, team)
  local best, bd
  -- the closest by the walk, not as the crow flies: a deposit just across the water can be the
  -- longest trip on the map
  local utx, uty = map:tileAt(u.x, u.y)
  local walk = map:walkDistances("land", utx, uty, math.floor(2400 / w.T))
  local function walkTo(tx, ty)
    local m
    for dy = -1, 1 do for dx = -1, 1 do
      local d = walk[(ty + dy) * map.w + tx + dx]
      if d and (not m or d < m) then m = d end
    end end
    return m
  end
  for _, dp in ipairs(map.deposits) do
    if not dp.sea and not taken[dp.y * map.w + dp.x] and w:canPlace("mex", dp.x, dp.y, team, "land") then
      local x, y = map:center(dp.x, dp.y)
      local wd = walkTo(dp.x, dp.y)
      local d = wd and (wd * w.T) ^ 2 or nil
      if d and d < 2400 * 2400 and (not bd or d < bd) then
        -- nobody hostile and armed standing next to it
        local danger = false
        w:query(x, y, 450, function(e)
          if not danger and e.alive and e.team and e.team > 0 and w:hostile(e.team, team) and e.def.weapon then danger = true end
        end)
        if not danger then best, bd = dp, d end
      end
    end
  end
  if best then w:issue(u, { type = "build", key = "mex", tx = best.x, ty = best.y }); return true end
end

function A.doJob.power(game, w, team, u)
  local tm = w.teams[team]
  if not (tm.energy < tm.eStore * 0.3 or (tm.stalled and (tm.eRatio or 1) < 0.95)) then return end
  -- one solar at a time
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team then
      if e.key == "solar" and (e.built or 1) < 1 then return end
      for _, o in ipairs(e.orders or {}) do if o.type == "build" and o.key == "solar" then return end end
    end
  end
  local map = w.map
  local sx, sy = map:tileAt(tm.startX, tm.startY)
  for r = 3, 16 do
    for dy = -r, r do
      for dx = -r, r do
        if (math.abs(dx) == r or math.abs(dy) == r) and w:canPlace("solar", sx + dx, sy + dy, team, "land") then
          w:issue(u, { type = "build", key = "solar", tx = sx + dx, ty = sy + dy })
          return true
        end
      end
    end
  end
end

-- one line saying which standing orders are on (shown when a match starts)
function A.summary()
  local parts = {}
  if A.v.flee then parts[#parts + 1] = "flee at " .. A.v.fleePct .. "%" end
  if A.v.rejoin then parts[#parts + 1] = "rejoin" end
  if A.v.builders then parts[#parts + 1] = A.v.builderMin .. " constructors" end
  local jobs = {}
  for _, j in ipairs(A.jobOrder()) do if A.v[j] then jobs[#jobs + 1] = A.JOBS[j].label:lower() end end
  if #jobs > 0 then parts[#parts + 1] = "idle: " .. table.concat(jobs, " > ") end
  return table.concat(parts, ", ")
end

function A.update(game, dt)
  if not A.anyOn() or not A.applies(game) then return end
  if not game.autoAnnounced then
    game.autoAnnounced = true
    if game.notice then
      game:notice("Auto is on from last time - the Auto button (or K) changes it", 8)
      game:notice("Auto: " .. A.summary(), 8)
    end
  end
  local w = game.world
  if w.over then return end
  local team = game.playerTeam or w.playerTeam or 1
  local v = A.v
  -- the flee check runs ten times a second (a scout can lose half its health in a single
  -- artillery or destroyer volley), the rest twice a second
  A.fleeTimer = (A.fleeTimer or 0) - dt
  local fleeNow = v.flee and A.fleeTimer <= 0
  if fleeNow then A.fleeTimer = 0.1 end
  A.timer = (A.timer or 0) - dt
  local slow = A.timer <= 0
  if slow then A.timer = 0.5 end
  if not fleeNow and not slow then return end

  for _, u in ipairs(w.entities) do
    if u.alive and u.team == team and not u.def.building and u.built >= 1 then
      local o = u.orders[1]
      -- how fast it's losing health: compare with where it stood about a second ago
      local losing = 0
      if fleeNow then
        local now = w.time
        if not u.autoHpT or now - u.autoHpT >= 1 then u.autoHpT, u.autoHpWas = now, u.hp end
        if u.autoHpWas and u.autoHpWas > u.hp then losing = (u.autoHpWas - u.hp) / math.max(0.2, now - u.autoHpT) end
      end
      -- 1. fall back when hurt - or about to be: under heavy fire, it goes a second early
      local line = u.maxhp * A.fleePctFor(u.key) / 100
      if fleeNow and u.def.weapon and u.key ~= "commander" and u.key ~= "builder" and not u.disarmed
        and (u.hp < line or (u.hp < line * 1.5 and u.hp - losing * 1.0 < line)) and not (o and o.type == "retreat") then
        -- to your flag if you've set one (put it where you want the line to fall back to - near a
        -- plant, for repairs), else to the plant that built it
        local hx, hy
        local flx, fly = A.flagFor(w, game.flag, u)
        if flx then
          hx, hy = flx + math.random(-50, 50), fly + math.random(-50, 50)
          if u.def.domain == "sea" or u.def.domain == "sub" then hx, hy = flx, fly end
        else
          hx, hy = homeFor(w, u)
        end
        -- (even when it's already near the flag: it still ceases fire, steps back to the flag
        -- itself and waits there for repairs, instead of fighting on until it dies)
        do
          u.autoFled = { x = u.x, y = u.y }
          w:issue(u, { type = "retreat", x = hx, y = hy })
          -- out of your selection, so the next attack-move doesn't drag it back unarmed (select it
          -- again on purpose to use it)
          if game.selected then game.selected[u] = nil end
        end
      -- 2. back to the fight once whole
      elseif slow and v.rejoin and u.autoFled and u.hp >= u.maxhp - 0.5 and not u.disarmed and not (o and o.type == "retreat") then
        -- back to where it fled from (the front)
        local tx, ty = u.autoFled.x, u.autoFled.y
        u.autoFled = nil
        w:issue(u, { type = "amove", x = tx + math.random(-60, 60), y = ty + math.random(-60, 60) })
      end
      -- 4. idle constructors: the first job (in the player's order) that has something to do
      if slow and u.key == "builder" and #u.orders == 0 and (v.repair or v.expand or v.power) then
        for _, job in ipairs(A.jobOrder()) do
          if v[job] and A.doJob[job](game, w, team, u) then break end
        end
      end
    end
  end

  -- 3. keep a minimum number of constructors
  if slow and v.builders and countBuilders(w, team) < v.builderMin then
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

local JOB_H = 50
local function idleTop(py, rowH) return py + 70 + #A.RULES * rowH + 54 end

function A.rects()
  if A.view == "units" then return A.unitRects() end
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local pw, rowH = 640, 80
  local px = (w - pw) / 2
  local total = 70 + #A.RULES * rowH + 54 + 3 * JOB_H + 60
  local py = math.max(40, h / 2 - total / 2)
  local out = {}
  local iy = idleTop(py, rowH)
  for i, job in ipairs(A.jobOrder()) do
    local y = iy + (i - 1) * JOB_H
    out[#out + 1] = { x = px + 18, y = y + 6, w = 30, h = 34, kind = "handle", job = job, idx = i }
    out[#out + 1] = { x = px + pw - 120, y = y + 6, w = 96, h = 34, kind = "jobtoggle", job = job }
  end
  for i, r in ipairs(A.RULES) do
    local y = py + 70 + (i - 1) * rowH
    out[#out + 1] = { x = px + pw - 120, y = y, w = 96, h = 34, kind = "toggle", rule = r }
    if r.value then
      out[#out + 1] = { x = px + pw - 300, y = y, w = 34, h = 34, kind = "minus", rule = r }
      out[#out + 1] = { x = px + pw - 160, y = y, w = 34, h = 34, kind = "plus", rule = r }
    end
    if r.key == "flee" then out[#out + 1] = { x = px + pw - 300, y = y + 40, w = 174, h = 28, kind = "perunit" } end
  end
  out[#out + 1] = { x = px + pw / 2 - 70, y = iy + 3 * JOB_H + 14, w = 140, h = 36, kind = "close" }
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
  local iy = idleTop(py, rowH)
  local ph = iy - py + 3 * JOB_H + 64
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
  -- idle constructors: the priority list
  lg.setColor(0.3, 0.38, 0.48)
  lg.line(px + 18, iy - 50, px + pw - 18, iy - 50)
  lg.setFont(fontFn(16))
  lg.setColor(1, 1, 1)
  lg.print("When a constructor is idle", px + 24, iy - 44)
  lg.setFont(fontFn(12))
  lg.setColor(0.6, 0.66, 0.72)
  lg.print("Never overrides your orders: it does the first job that's on and has work. Drag to reorder.",
    px + 24, iy - 22)
  local order = A.jobOrder()
  for i, job in ipairs(order) do
    local y = iy + (i - 1) * JOB_H
    local J = A.JOBS[job]
    local dragging = A.drag and A.drag.job == job
    if dragging then
      lg.setColor(0.2, 0.26, 0.34, 0.9)
      lg.rectangle("fill", px + 12, my - JOB_H / 2, pw - 24, JOB_H - 4, 6)
    elseif i % 2 == 1 then
      lg.setColor(1, 1, 1, 0.03)
      lg.rectangle("fill", px + 12, y + 2, pw - 24, JOB_H - 4, 6)
    end
    local ry = dragging and (my - JOB_H / 2) or y
    lg.setFont(fontFn(16))
    lg.setColor(1, 0.85, 0.4)
    lg.print(tostring(i), px + 58, ry + 13)
    lg.setColor(A.v[job] and 1 or 0.7, A.v[job] and 1 or 0.72, A.v[job] and 1 or 0.75)
    lg.print(J.label, px + 80, ry + 4)
    lg.setFont(fontFn(12))
    lg.setColor(0.6, 0.66, 0.72)
    lg.print(J.desc, px + 80, ry + 26)
  end
  for _, b in ipairs(rects) do
    local hover = mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
    local on = (b.kind == "toggle" and A.v[b.rule.key]) or (b.kind == "jobtoggle" and A.v[b.job])
    if b.kind == "handle" then
      -- three grip lines
      lg.setColor(hover and 0.85 or 0.55, hover and 0.9 or 0.6, hover and 0.95 or 0.66)
      local hy = (A.drag and A.drag.job == b.job) and (my - JOB_H / 2 + 6) or b.y
      for k = 0, 2 do lg.rectangle("fill", b.x + 6, hy + 10 + k * 7, 18, 3, 1) end
      goto continue
    end
    if on then lg.setColor(0.2, 0.5, 0.3) elseif hover then lg.setColor(0.25, 0.3, 0.38) else lg.setColor(0.15, 0.18, 0.23) end
    lg.rectangle("fill", b.x, b.y, b.w, b.h, 6)
    lg.setColor(0.45, 0.55, 0.65)
    lg.rectangle("line", b.x, b.y, b.w, b.h, 6)
    lg.setColor(1, 1, 1)
    lg.setFont(fontFn(15))
    local label = (b.kind == "toggle" or b.kind == "jobtoggle") and (on and "On" or "Off") or (b.kind == "minus" and "-" or (b.kind == "plus" and "+"
      or (b.kind == "perunit" and "Per unit..." or "Done")))
    lg.printf(label, b.x, b.y + b.h / 2 - 9, b.w, "center")
    ::continue::
  end
end

-- dropping a dragged job: it takes the slot under the mouse
function A.release(x, y)
  if not A.drag then return end
  local _, px, py, pw, rowH = A.rects()
  local iy = idleTop(py, rowH)
  local order = A.jobOrder()
  local to = math.max(1, math.min(#order, math.floor((y - iy) / JOB_H) + 1))
  local job = A.drag.job
  for i = #order, 1, -1 do if order[i] == job then table.remove(order, i) end end
  table.insert(order, to, job)
  A.v.idleOrder = table.concat(order, ",")
  A.drag = nil
  A.save()
end

-- returns true while the panel should stay open
function A.click(x, y)
  for _, b in ipairs(A.rects()) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      local r = b.rule
      if b.kind == "handle" then A.drag = { job = b.job, from = b.idx }; return true
      elseif b.kind == "jobtoggle" then A.v[b.job] = not A.v[b.job]
      elseif b.kind == "perunit" then A.view = "units"
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
