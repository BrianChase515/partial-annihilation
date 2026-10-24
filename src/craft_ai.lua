-- Commander Craft computer player: works its economy like a Warcraft player (workers on
-- gold and wood, farms ahead of food, a hall that climbs the tiers), builds an army that
-- fits its race and tier, creeps with its heroes for experience, defends its base,
-- expands to the middle mine and attacks when it is strong enough. Difficulty changes how
-- fast it thinks and reacts, how tight its build is, how big its army gets before
-- attacking and how well its heroes use their skills.
local D = require("src.defs")
local U = require("src.util")
local C = require("src.craft")
local ARENA = require("src.arena")
local ArenaAI = require("src.arena_ai")

local AI = {}
AI.__index = AI
local DBG = os.getenv("PA_CRAFTDBG")

-- hero brains reuse the Arena AI's skill logic, pointed at Craft buildings
local HeroBrain = setmetatable({}, { __index = ArenaAI })
HeroBrain.__index = HeroBrain
function HeroBrain:nearestEnemyStructure(c)
  local w = self.world
  local best, bd
  for _, s in ipairs(w.entities) do
    if s.alive and s.def.building and s.team and s.team > 0 and w:hostile(s.team, self.team) then
      local d = U.dist(c.x, c.y, s.x, s.y)
      if not bd or d < bd then best, bd = s, d end
    end
  end
  return best, bd
end

local COMP = {
  vanguard = { { "footman", 3 }, { "rifleman", 2.8 }, { "knight", 3, 3 }, { "cleric", 1, 2, 3 }, { "magus", 0.8, 2, 2 },
    { "mortar", 0.9, 2, 3 }, { "gryphon", 1.4, 3 } },
  warband = { { "grunt", 3 }, { "headhunter", 2.2 }, { "raider", 2, 2 }, { "shaman", 1, 2, 3 }, { "mystic", 0.8, 2, 2 },
    { "demolisher", 0.8, 2, 2 }, { "ironhide", 2.2, 3 }, { "wyvern", 1.3, 3 } },
}

-- Everything difficulty changes, in one place. The big levers:
--   act      - how reliably it does each chore on a given think (idle workers, empty production,
--              the next building): low levels forget things the way a busy human does
--   workers  - how many workers it keeps over the "right" number
--   tiers    - when it techs up;  expand - when it takes a second mine
--   smart    - attacks when it's actually stronger (instead of at a fixed army size)
function AI.params(L)
  return {
    think = math.max(0.3, 1.6 - 0.13 * L),
    act = math.min(1, 0.25 + 0.075 * L),
    workers = ({ -6, -5, -3, -2, -1, 0, 1, 1, 1, 1 })[L],
    tier2At = 420 - 24 * L, tier3At = 900 - 45 * L,
    expandAt = 600 - 25 * L,
    attackFood = L <= 3 and (10 + 2 * L) or (20 + L),
    smart = L >= 4, attackRatio = 1.7 - 0.05 * L,
    towers = L >= 6 and 2 or (L >= 4 and 1 or 0),
    research = 0.1 + 0.08 * L,
    creep = L >= 3, creepRatio = 1.8 - 0.06 * L,
    focusHero = L >= 5, skillChance = 0.25 + 0.07 * L,
    heroRetreat = 0.2 + 0.02 * L,
    regroupRatio = 1.05 + 0.05 * L,
    goldMul = L >= 8 and (1 + 0.1 * (L - 7)) or nil,
  }
end

-- the frozen yardstick every level is measured against (level 5 as of 0.13.0); tuning the
-- real levels never moves it
AI.BENCH = {
  think = 0.9, act = 1, workers = 0, tier2At = 240, tier3At = 550, expandAt = 405,
  attackFood = 18, smart = true, attackRatio = 1.4, towers = 1, research = 0.55,
  creep = true, creepRatio = 1.4, focusHero = true, skillChance = 0.65, heroRetreat = 0.32, regroupRatio = 1.35,
  legacy = true, -- keeps the 0.13.0 army habits (trickle attacks, thin spending) so the yardstick doesn't move
}

function AI.new(world, team, level, opts)
  local self = setmetatable({}, AI)
  self.world, self.team = world, team
  self.level = math.max(1, math.min(10, level or 5))
  local L = self.level
  local P = (opts and opts.bench) and AI.BENCH or AI.params(L)
  self.P = P
  self.rng = love.math.newRandomGenerator(world.map.seed + team * 313)
  self.thinkEvery = P.think
  self.think = 0.5
  self.race = C.raceOf(world, team)
  self.profileName = "Craft " .. self.race.name .. ((opts and opts.bench) and " (bench)" or "")
  self.brain = setmetatable({ world = world, team = team, level = L, rng = self.rng, skillChance = P.skillChance }, HeroBrain)
  self.tier2At, self.tier3At = P.tier2At, P.tier3At
  self.attackFood = P.attackFood
  self.workerGoal = 11
  self.mode = "build"
  local tm = world.teams[team]
  tm.goldMul = P.goldMul -- the top difficulties mine faster (the menu says so)
  for _, h in ipairs(C.heroesOf(world, team, true)) do h.aiLevel = L end
  return self
end

---------------------------------------------------------------------------
-- helpers

function AI:mine(pred)
  local out = {}
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and pred(e) then out[#out + 1] = e end
  end
  return out
end

function AI:count(key, includeQueued)
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team then
      if e.key == key then n = n + 1 end
      if includeQueued and e.queue then for _, k in ipairs(e.queue) do if k == key then n = n + 1 end end end
      if includeQueued and e.orders then
        for _, o in ipairs(e.orders) do if o.type == "build" and o.key == key and not o.ent then n = n + 1 end end
      end
    end
  end
  return n
end

function AI:hall()
  local best
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.def.hall and e.built >= 1 then
      if not best or (e.home and not best.home) then best = e end
    end
  end
  return best
end

-- a free spot for a building near (cx, cy) that doesn't block the mining path or wall in a door
function AI:findSite(key, cx, cy, minR, maxR)
  local w = self.world
  local d = D.units[key]
  local map = w.map
  local ctx, cty = map:tileAt(cx, cy)
  local hall = self:hall()
  local mine = hall and C.nearestMine(w, hall.x, hall.y)
  local tries = {}
  for r = minR or 3, maxR or 14 do
    for dy = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then tries[#tries + 1] = { ctx + dx, cty + dy } end
      end
    end
    if #tries > 0 then
      -- shuffle a little within the ring so bases don't grow as perfect squares
      for i = #tries, 2, -1 do local j = self.rng:random(i); tries[i], tries[j] = tries[j], tries[i] end
      for _, t in ipairs(tries) do
        local tx, ty = t[1] - math.floor(d.w / 2), t[2] - math.floor(d.h / 2)
        if w:canPlace(key, tx, ty, self.team) then
          local ok = true
          -- keep a one-tile ring free around it (no walls)
          for yy = ty - 1, ty + d.h do
            for xx = tx - 1, tx + d.w do
              if (xx < tx or yy < ty or xx >= tx + d.w or yy >= ty + d.h) then
                local i = map:idx(xx, yy)
                if map.blocked[i] then ok = false end
              end
            end
          end
          -- stay off the hall-mine walkway
          if ok and hall and mine then
            local bx, by = (tx + d.w / 2) * w.T, (ty + d.h / 2) * w.T
            local ax, ay, qx, qy = hall.x, hall.y, mine.x, mine.y
            local vx, vy = qx - ax, qy - ay
            local len2 = vx * vx + vy * vy
            local tt = math.max(0, math.min(1, ((bx - ax) * vx + (by - ay) * vy) / len2))
            local px, py = ax + vx * tt, ay + vy * tt
            if U.dist(bx, by, px, py) < 3.5 * w.T + d.w * w.T * 0.5 then ok = false end
          end
          if ok and hall then
            local bx, by = (tx + d.w / 2) * w.T, (ty + d.h / 2) * w.T
            if not map:canReach("land", hall.x, hall.y + hall.def.h * w.T * 0.5 + 20, bx, by, d.w * w.T) then ok = false end
          end
          if ok then return tx, ty end
        end
      end
      tries = {}
    end
  end
end

function AI:pickBuilder(x, y)
  local best, bs
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.def.worker and not e.inMine then
      local o = e.orders[1]
      local busy = o and o.type == "build"
      if not busy then
        local s = U.dist(e.x, e.y, x, y)
        if o and o.type == "harvest" and o.kind == "gold" then s = s + 900 end -- prefer wood workers
        if e.carry then s = s + 300 end
        if not bs or s < bs then best, bs = e, s end
      end
    end
  end
  return best
end

function AI:build(key, cx, cy, minR, maxR)
  local tm = self.world.teams[self.team]
  local rg, rw = self:reserved()
  local d = D.units[key]
  if tm.gold - rg < (d.cost.gold or 0) or tm.wood - rw < (d.cost.wood or 0) then return false end
  local ok, why = C.canOrder(self.world, self.team, key)
  if not ok then if DBG then print("BUILDFAIL", self.team, key, why) end return false end
  local tx, ty = self:findSite(key, cx, cy, minR, maxR)
  if not tx then if DBG then print("BUILDFAIL", self.team, key, "nosite") end return false end
  local b = self:pickBuilder((tx + 1) * self.world.T, (ty + 1) * self.world.T)
  if not b then if DBG then print("BUILDFAIL", self.team, key, "nobuilder") end return false end
  if DBG then print("BUILD", math.floor(self.world.time), self.team, key) end
  self.world:issue(b, { type = "build", key = key, tx = tx, ty = ty })
  self.world:issue(b, { type = "harvest", kind = "wood" }, true)
  self.lastBuild = self.world.time
  return true
end

-- gold and wood promised to buildings whose workers are still walking to the site
function AI:reserved()
  local g, wd = 0, 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.def.worker then
      for _, o in ipairs(e.orders) do
        if o.type == "build" and not o.ent then
          local d = D.units[o.key]
          g, wd = g + (d.cost.gold or 0), wd + (d.cost.wood or 0)
        end
      end
    end
  end
  return g, wd
end

function AI:queue(f, key)
  if not f or not f.alive or f.built < 1 or #f.queue >= 2 then return false end
  local tm = self.world.teams[self.team]
  local rg, rw = self:reserved()
  local g, wd = C.price(self.world, self.team, key)
  if tm.gold - rg < g or tm.wood - rw < wd then return false end
  return C.enqueue(self.world, f, key)
end

---------------------------------------------------------------------------
-- main loop

function AI:update(dt)
  local w = self.world
  if DBG and w.time > 150 and not self.dumped then
    self.dumped = true
    for _, e in ipairs(w.entities) do
      if e.team == self.team and (e.def.worker or (e.def.building and e.built < 1)) then
        local o = e.orders and e.orders[1]
        print("DUMP", self.team, e.key, math.floor(e.x), math.floor(e.y), e.built, o and o.type, o and (o.key or o.kind), o and o.ent and o.ent.key, e.inMine and "inmine" or "",
          o and o.tx, o and o.ty, o and o.fail, e.path and #e.path, o and o.tx and w:canPlace(o.key, o.tx, o.ty, e.team))
      end
    end
  end
  if w.over or w.teams[self.team].dead then return end
  self.think = self.think - dt
  if self.think > 0 then return end
  self.think = self.thinkEvery * (0.8 + self.rng:random() * 0.4)
  local tm = w.teams[self.team]
  for _, h in ipairs(C.heroesOf(w, self.team, false)) do
    h.aiLevel = self.level
    if h.offers and #h.offers > 0 then self.brain:pickOffer(h) end
  end
  self:economy(tm)
  if self.rng:random() < self.P.act then self:buildings(tm) end
  if self.rng:random() < self.P.act then self:production(tm) end
  local before = self.mode
  self:army(tm)
  if DBG and self.mode ~= before then print(string.format("MODE t=%d T%d %s -> %s", w.time, self.team, before, self.mode)) end
end

-- workers: keep the hall training them, everyone busy, about five on each mine
function AI:economy(tm)
  local w = self.world
  local hall = self:hall()
  local workers = self:mine(function(e) return e.def.worker end)
  local halls = self:mine(function(e) return e.def.hall and e.built >= 1 end)
  -- mines next to our halls
  local myMines = {}
  for _, h in ipairs(halls) do
    local m, d = C.nearestMine(w, h.x, h.y)
    if m and d < 600 then myMines[#myMines + 1] = m end
  end
  local woodWant = 2 + (tm.tier or 1) + math.min(1, #halls - 1)
  if tm.wood > 700 then woodWant = 1 elseif tm.wood > 400 then woodWant = 2 end
  local goal = math.max(4, 5 * #myMines + woodWant + 1 + self.P.workers)
  if hall and #workers < goal and self.rng:random() < self.P.act then
    for _, h in ipairs(halls) do
      if #h.queue == 0 and #workers + self:count(self.race.worker, true) - #workers < goal then self:queue(h, self.race.worker) end
    end
  end
  -- idle or lost workers go back to work; balance gold vs wood
  local onGold, onWood, woodList = {}, 0, {}
  for _, e in ipairs(workers) do
    local o = e.orders[1]
    if o and o.type == "harvest" then
      if o.kind == "gold" then
        local m = o.target
        if m then onGold[m] = (onGold[m] or 0) + 1 end
      else onWood = onWood + 1; woodList[#woodList + 1] = e end
    elseif e.inMine then
      onGold[e.inMine] = (onGold[e.inMine] or 0) + 1
    end
  end
  local function needy()
    for _, m in ipairs(myMines) do if (onGold[m] or 0) < 5 then return m end end
  end
  for _, e in ipairs(workers) do
    if #e.orders == 0 and not e.inMine and self.rng:random() < self.P.act then
      local target = needy()
      if target and onWood >= math.min(2, woodWant) then
        w:issue(e, { type = "harvest", kind = "gold", target = target })
        onGold[target] = (onGold[target] or 0) + 1
      else
        local tx, ty = w.map:tileAt(e.x, e.y)
        local tr = C.nearestTree(w, tx, ty, 20)
        if tr then w:issue(e, { type = "harvest", kind = "wood", tree = tr }); onWood = onWood + 1 end
      end
    end
  end
  -- too many on wood while a mine is short: move one over (or when wood is piling up)
  local target = needy()
  if target and (onWood > woodWant or tm.wood > 800) and #woodList > 0 then
    local e = woodList[#woodList]
    if not e.carry then w:issue(e, { type = "harvest", kind = "gold", target = target }) end
  end
end

-- the build order: farms ahead of food, then production and tech
function AI:buildings(tm)
  local w = self.world
  local r = self.race
  local hall = self:hall()
  if not hall then
    -- lost the hall: rebuild one at the nearest mine if we can
    local anyWorker = self:mine(function(e) return e.def.worker end)[1]
    if anyWorker and self:count(r.hall, true) == 0 then
      local m = C.nearestMine(w, anyWorker.x, anyWorker.y)
      if m then self:build(r.hall, m.x, m.y + 200, 3, 10) end
    end
    return
  end
  -- unfinished foundations whose builder died or wandered off: send someone to finish them
  for _, b in ipairs(w.entities) do
    if b.alive and b.team == self.team and b.def.building and b.built < 1 then
      local busy = false
      for _, e in ipairs(w.entities) do
        if e.alive and e.team == self.team and e.def.worker then
          local o = e.orders[1]
          if o and ((o.type == "build" and o.ent == b) or (o.type == "assist" and o.target == b)) then busy = true; break end
        end
      end
      if not busy then
        local wk = self:pickBuilder(b.x, b.y)
        if wk then
          w:issue(wk, { type = "assist", target = b })
          w:issue(wk, { type = "harvest", kind = "wood" }, true)
        end
      end
    end
  end
  if (self.lastBuild or -99) > w.time - 1.5 then return end
  local t = w.time
  local L = self.level
  local hx, hy = hall.x, hall.y
  local function have(k) return self:count(k, true) end
  -- 1. food: stay ahead (two farms at a time once production is running)
  local spare = (tm.foodCap or 0) - (tm.foodUsed or 0)
  local farmsBuilding = 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team and e.key == r.farm and e.built < 1 then farmsBuilding = farmsBuilding + 1 end
  end
  local prod = self:count(r.barracks) + (tm.tier >= 2 and 1 or 0)
  local farmLimit = prod >= 2 and 2 or 1
  if (tm.foodCap or 0) < D.CRAFT.FOOD_CAP and spare < 3 + prod * 3 and farmsBuilding + self:pendingBuild(r.farm) < farmLimit then
    if self:build(r.farm, hx, hy, 4, 13) then return end
  end
  -- 2. expand: the closest free mine whose guards are dead, once the main runs low or on schedule
  local exp = self:expansionMine()
  if DBG and math.floor(t) % 60 == 0 and self.lastExpDbg ~= math.floor(t) then
    self.lastExpDbg = math.floor(t)
    local cs = {}
    for i, cp in ipairs(w.craft.camps) do local n = 0; for _, u in ipairs(cp.units) do if u.alive then n = n + 1 end end; cs[#cs + 1] = i .. ":" .. n end
    print("EXP", math.floor(t), self.team, exp and math.floor(exp.x) .. "," .. math.floor(exp.y) or "none", table.concat(cs, " "))
  end
  local main = C.nearestMine(w, hx, hy)
  local halls = self:count(r.hall, true)
  local mainLow = not main or U.dist(main.x, main.y, hx, hy) > 700 or main.gold < 2500
  self.savingHall = nil
  if exp and halls < 3 and (mainLow or (halls < 2 and t > self.P.expandAt)) and not self:pendingBuildAny(r.hall) then
    local sx, sy = self:hallSpotNear(exp)
    if sx and self:build(r.hall, sx, sy, 0, 5) then self.expanding = exp; return end
    if tm.gold < D.units[r.hall].cost.gold then self.savingHall = true; return end
  end

  -- 3. the core buildings, in order
  local order = {
    { r.barracks, 1, 20 },
    { r.altar, 1, 75 },
    { r.mill, 1, 110 },
    { r.forge, 1, 150 },
  }
  if self.P.towers >= 1 then order[#order + 1] = { r.tower, 1, 200 } end
  if tm.tier >= 2 then
    for _, k in ipairs(D.units[r.worker].builds) do
      local d = D.units[k]
      if d.tier == 2 and d.factory then order[#order + 1] = { k, 1, 0 } end
    end
    order[#order + 1] = { r.barracks, 2, 0 }
  end
  if tm.tier >= 3 then
    for _, k in ipairs(D.units[r.worker].builds) do
      local d = D.units[k]
      if d.tier == 3 and d.factory then order[#order + 1] = { k, 1, 0 } end
    end
    if self.P.towers >= 2 then order[#order + 1] = { r.tower, 2, 0 } end
  end
  local armyOk = self.P.legacy or self:armyFood() >= 14 or tm.gold > 450
  for i, o in ipairs(order) do
    local k, want, from = o[1], o[2], o[3]
    -- the core four always; anything past them (tier buildings, a second barracks) only with an army in the field
    if t >= from * (L <= 3 and 1.4 or 1) and have(k) < want and (from > 0 or armyOk) then
      local near = k == r.mill and self:woodSpot(hall) or nil
      if near then
        if self:build(k, near[1], near[2], 2, 8) then return end
      elseif k == r.tower then
        local m = C.nearestMine(w, hx, hy)
        if self:build(k, m and (m.x + hx) / 2 or hx, m and (m.y + hy) / 2 or hy, 3, 9) then return end
      elseif self:build(k, hx, hy, 5, 14) then return end
      if tm.gold < D.units[k].cost.gold then return end -- saving up for it
    end
  end
end

function AI:pendingBuildAny(key)
  if self:pendingBuild(key) > 0 then return true end
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.key == key and e.built < 1 then return true end
  end
  return false
end

-- mines nobody has a hall at, nearest our base, whose creep camp is cleared
function AI:expansionMine()
  local w = self.world
  local base = self:hall()
  if not base then return nil end
  local best, bd
  for _, m in ipairs(w.craft.mines) do
    if m.alive and m.gold > 1500 then
      local taken = false
      for _, e in ipairs(w.entities) do
        if e.alive and e.def.hall and U.dist(e.x, e.y, m.x, m.y) < 500 then taken = true end
      end
      local guarded = false
      for _, cp in ipairs(w.craft.camps) do
        for _, u in ipairs(cp.units) do if u.alive and U.dist(u.x, u.y, m.x, m.y) < 520 then guarded = true end end
      end
      if not taken and not guarded then
        local d = U.dist(base.x, base.y, m.x, m.y)
        if not bd or d < bd then best, bd = m, d end
      end
    end
  end
  return best
end

-- a hall goes about five tiles from its mine, toward open ground
function AI:hallSpotNear(m)
  local w = self.world
  local map = w.map
  local best, bs
  for a = 0, 15 do
    local ang = a / 16 * math.pi * 2
    local x, y = m.x + math.cos(ang) * 200, m.y + math.sin(ang) * 200
    local tx, ty = map:tileAt(x, y)
    local open = 0
    for dy = -3, 3 do for dx = -3, 3 do if map:passable("land", tx + dx, ty + dy) then open = open + 1 end end end
    if not bs or open > bs then best, bs = { x, y }, open end
  end
  if best then return best[1], best[2] end
end

function AI:pendingBuild(key)
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.orders then
      for _, o in ipairs(e.orders) do if o.type == "build" and o.key == key and not o.ent then n = n + 1 end end
    end
  end
  return n
end

-- where the wood line is: the nearest tree to the hall, pulled back toward the hall
function AI:woodSpot(hall)
  local w = self.world
  local tx, ty = w.map:tileAt(hall.x, hall.y)
  local tr = C.nearestTree(w, tx, ty, 18)
  if not tr then return nil end
  local x, y = (tr.x + 0.5) * w.T, (tr.y + 0.5) * w.T
  local dx, dy = U.norm(hall.x - x, hall.y - y)
  return { x + dx * 110, y + dy * 110 }
end

-- what to train and research
function AI:production(tm)
  local w = self.world
  local r = self.race
  local t = w.time
  local L = self.level
  local hall = self:hall()
  -- tier upgrades (they take priority: save for them)
  local saving = false
  if hall and tm.tier == 1 and t > self.tier2At and self:count(r.barracks) > 0 and #hall.queue == 0 then
    if not self:queue(hall, r.tiers[1]) then saving = true end
  elseif hall and tm.tier == 2 and t > self.tier3At and #hall.queue == 0 and not tm.research[r.tiers[2]] then
    local ok = C.canOrder(w, self.team, r.tiers[2])
    if ok then self:queue(hall, r.tiers[2]) elseif t > self.tier3At + 60 then saving = true end
  end
  -- more heroes
  local altar = self:mine(function(e) return e.def.altar and e.built >= 1 end)[1]
  if altar and #altar.queue == 0 then
    local n = #C.heroesOf(w, self.team, true)
    if n < 3 and tm.tier >= n + 1 and (n == 0 or self.P.legacy or self:armyFood() >= 12 + 4 * n) then
      local pool = {}
      for _, k in ipairs(r.heroes) do
        local ok, why = C.canOrder(w, self.team, "hero_" .. k)
        if ok or (why and why:match("^Not enough")) then pool[#pool + 1] = k end
      end
      if #pool > 0 then
        if not self:queue(altar, "hero_" .. pool[self.rng:random(#pool)]) then saving = true end
      end
    end
  end
  if (saving or self.savingHall) and tm.gold < 500 then return end
  -- research at the forge and the unit buildings, when there's spare
  local spareGold = tm.gold - (tm.tier < 3 and 250 or 100)
  -- research is for an army we already have, not instead of one
  if spareGold > 0 and t > 200 and (self.P.legacy or self:armyFood() >= 12 or tm.gold > 700) then
    for _, f in ipairs(self:mine(function(e) return e.def.factory and e.built >= 1 and #e.queue == 0 and not e.def.hall and not e.def.altar end)) do
      for _, k in ipairs(f.def.builds) do
        local d = D.units[k]
        if d.research and C.canOrder(w, self.team, k) then
          local useful = d.stat or d.flag
          if d.unitMods then for uk in pairs(d.unitMods) do if self:count(uk) >= 3 then useful = true end end end
          if useful and self.rng:random() < self.P.research then self:queue(f, k); break end
        end
      end
    end
  end
  -- units: weighted by race and tier, casters and siege capped
  local comp = COMP[r.key]
  for _, f in ipairs(self:mine(function(e) return e.def.factory and e.built >= 1 and not e.def.hall and not e.def.altar end)) do
    if #f.queue < (tm.gold > 600 and 2 or 1) then
      -- decide what this building makes next (by weight, newest tier favoured), then wait until we can pay
      local want = f.aiWant
      if want and not (tm.tier >= (D.units[want].tier or 1)) then want = nil end
      if not want then
        local opts, total = {}, 0
        for _, c in ipairs(comp) do
          local k, wgt, tier, cap = c[1], c[2], c[3] or 1, c[4]
          if U.contains(f.def.builds, k) and tm.tier >= tier and (not cap or self:count(k, true) < cap) then
            if tier == tm.tier and tier > 1 then wgt = wgt * 1.6 end
            opts[#opts + 1] = { k, wgt }; total = total + wgt
          end
        end
        local pick = self.rng:random() * total
        for _, o in ipairs(opts) do
          pick = pick - o[2]
          if pick <= 0 then want = o[1]; break end
        end
        f.aiWant = want
      end
      if want then
        local ok, why = C.canOrder(w, self.team, want)
        if ok then
          if self:queue(f, want) then f.aiWant = nil end
        elseif why and not why:match("^Not enough gold") and not why:match("^Not enough wood") then
          f.aiWant = nil -- food or a cap: pick something else next time
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- the army: defend, creep, attack

function AI:armyUnits()
  local list = {}
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and not e.def.building and not e.def.worker and e.def.weapon and not e.summon then
      list[#list + 1] = e
    end
  end
  return list
end

-- food in fighting units (heroes count 4): how big the army really is
function AI:armyFood()
  local f = 0
  for _, u in ipairs(self:armyUnits()) do f = f + (u.key == "commander" and 4 or (u.def.cost.food or 0)) end
  return f
end

function AI:enemyNear(x, y, r)
  local w = self.world
  local best, bd, n = nil, nil, 0
  w:query(x, y, r + 40, function(o)
    if o.alive and not o.dormant and not o.neutral and o.team and o.team > 0 and w:hostile(o.team, self.team) and not o.def.building then
      local d = U.dist(x, y, o.x, o.y)
      if d < r then
        n = n + 1
        if not bd or d < bd then best, bd = o, d end
      end
    end
  end)
  return best, n
end

local function strength(list)
  local s = 0
  for _, u in ipairs(list) do s = s + u.hp * ((u.def.weapon and u.def.weapon.damage or 5) / (u.def.weapon and u.def.weapon.reload or 1)) end
  return s
end

function AI:army(tm)
  local w = self.world
  local t = w.time
  local units = self:armyUnits()
  local hall = self:hall()
  local heroes = C.heroesOf(w, self.team, false)
  -- hero skills and escapes, whatever the army does
  for _, h in ipairs(heroes) do
    local foe, n = self:enemyNear(h.x, h.y, 600)
    local eh
    for _, o in ipairs(w.entities) do
      if o.alive and o.key == "commander" and w:hostile(o.team, self.team) and U.dist(o.x, o.y, h.x, h.y) < 650 then eh = o end
    end
    local danger = n >= 4 or (eh ~= nil)
    if foe or eh or (h.chase and h.chase.alive) then self.brain:useSkills(h, eh, danger) end
    -- a hurt hero goes home to heal (better players do it earlier)
    if h.hp < h.maxhp * self.P.heroRetreat and not w:isFleeing(h) and hall and U.dist(h.x, h.y, hall.x, hall.y) > 500 then
      w:issue(h, { type = "retreat", x = hall.x, y = hall.y + 120 })
      h.aiHealing = true
    end
    if h.aiHealing and h.hp > h.maxhp * 0.85 then h.aiHealing = nil end
  end
  local fighters = {}
  for _, u in ipairs(units) do if not u.aiHealing and not w:isFleeing(u) then fighters[#fighters + 1] = u end end
  if DBG and t > 1500 and (self.dbgT or 0) < t - 30 then
    self.dbgT = t
    local o1 = fighters[1] and fighters[1].orders[1]
    print("ARMY", math.floor(t), self.team, self.mode, #units, #fighters, o1 and o1.type, o1 and o1.x and math.floor(o1.x), o1 and o1.y and math.floor(o1.y),
      fighters[1] and math.floor(fighters[1].x), fighters[1] and math.floor(fighters[1].y))
  end
  if #fighters == 0 then return end
  -- 1. defend: anything hostile near our buildings pulls the whole army back
  local threat
  if self.level >= 2 then
    for _, b in ipairs(w.entities) do
      if b.alive and b.team == self.team and b.def.building then
        local foe = self:enemyNear(b.x, b.y, 650)
        if foe then threat = foe; break end
      end
    end
  end
  if threat then
    self.mode = "defend"
    self.target = nil
    for _, u in ipairs(fighters) do
      if not (u.orders[1] and u.orders[1].type == "amove" and U.dist(u.orders[1].x, u.orders[1].y, threat.x, threat.y) < 300) then
        w:issue(u, { type = "amove", x = threat.x, y = threat.y })
      end
    end
    -- workers fight back in a pinch against a small raid (they're cheap to replace later)
    return
  end
  local food = 0
  for _, u in ipairs(fighters) do food = food + (u.key == "commander" and 4 or (u.def.cost.food or 0)) end
  local cx, cy = 0, 0
  for _, u in ipairs(fighters) do cx, cy = cx + u.x, cy + u.y end
  cx, cy = cx / #fighters, cy / #fighters
  -- 2. attacking: keep going while we're winning, fall back when beaten
  -- out of gold income for a minute and a half: stop waiting
  if (tm.goldRate or 1) >= 50 or t < 600 then self.brokeSince = nil else self.brokeSince = self.brokeSince or t end
  local broke = self.brokeSince and t - self.brokeSince > 90
  if self.mode == "attack" then
    local near = {}
    for _, o in ipairs(w.entities) do
      if o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and not o.def.building and o.def.weapon and U.dist(o.x, o.y, cx, cy) < 700 then near[#near + 1] = o end
    end
    if not broke and (strength(near) > strength(fighters) * self.P.regroupRatio or food < self.attackFood * 0.35) then
      self.mode = "regroup"
      self.regroupUntil = t + 30
      -- that wave failed: the next one waits for a bigger army instead of trickling in
      if not self.P.legacy then self.failedWaves = math.min(3, (self.failedWaves or 0) + 1) end
    else
      local tgt = self:attackTarget(cx, cy)
      if DBG and t > 1500 and math.floor(t) % 30 == 0 then
        print("ATK", math.floor(t), self.team, tgt and tgt.key, tgt and math.floor(tgt.x), tgt and math.floor(tgt.y), math.floor(cx), math.floor(cy), #fighters)
      end
      if tgt then
        -- the main body: the fighter with the most friends around it. Stragglers (a freshly revived
        -- hero, new units from the barracks) walk to it instead of marching alone into the enemy
        local lead, ln = nil, -1
        for _, u in ipairs(fighters) do
          local n = 0
          for _, v in ipairs(fighters) do if U.dist2(u.x, u.y, v.x, v.y) < 400 * 400 then n = n + 1 end end
          if n > ln then lead, ln = u, n end
        end
        for _, u in ipairs(fighters) do
          local o = u.orders[1]
          local far = not self.P.legacy and ln >= 3 and U.dist(u.x, u.y, lead.x, lead.y) > 700
          if far then
            if not (o and o.type == "move" and o.join and U.dist(o.x, o.y, lead.x, lead.y) < 300) then
              w:issue(u, { type = "move", x = lead.x, y = lead.y, join = true })
            end
          elseif not o or (o.type == "amove" and U.dist(o.x, o.y, tgt.x, tgt.y) > 250) or o.type == "move" then
            w:issue(u, { type = "amove", x = tgt.x, y = tgt.y })
          end
        end
        -- better players focus a hurt enemy hero
        if self.P.focusHero then
          for _, o in ipairs(near) do
            if o.key == "commander" and o.hp < o.maxhp * 0.5 then
              for _, u in ipairs(fighters) do if U.dist(u.x, u.y, o.x, o.y) < 450 then w:issue(u, { type = "attack", target = o }) end end
              break
            end
          end
        end
      end
      return
    end
  end
  if self.mode == "regroup" and t < (self.regroupUntil or 0) then
    local hx, hy = self:rallyPoint()
    for _, u in ipairs(fighters) do
      if U.dist(u.x, u.y, hx, hy) > 300 and not (u.orders[1] and u.orders[1].type == "move") then
        w:issue(u, { type = "move", x = hx + self.rng:random(-80, 80), y = hy + self.rng:random(-80, 80) })
      end
    end
    return
  end
  -- 3. creeping: with the hero and a few units, clear camps for experience and the middle mine
  local camp = self.P.creep and self:creepTarget(fighters, food)
  if camp then
    self.mode = "creep"
    for _, u in ipairs(fighters) do
      local o = u.orders[1]
      if not o or (o.type == "amove" and U.dist(o.x, o.y, camp.x, camp.y) > 200) then
        w:issue(u, { type = "amove", x = camp.x, y = camp.y })
      end
    end
    return
  end
  -- 4. strong enough: attack
  local need = math.min(self.attackFood + math.floor(t / 300) * 4 + 4 * (self.failedWaves or 0), 40)
  if t > 1200 then need = math.min(need, 18) end -- late game: no more turtling
  -- better players attack when they're actually stronger, not at a fixed army size
  if self.P.smart and food >= (self.P.legacy and 10 or math.max(12, self.attackFood * 0.7) + 3 * (self.failedWaves or 0)) then
    local mine = strength(fighters)
    local theirs = 0
    for _, o in ipairs(w.entities) do
      if o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and o.def.weapon and not o.def.worker then
        local s = o.hp * (o.def.weapon.damage / o.def.weapon.reload)
        if o.def.building then s = s * (self.P.legacy and 0.9 or 1.25) end -- towers fight from where they stand: right where we'd attack
        theirs = theirs + s
      end
    end
    if mine > theirs * self.P.attackRatio then need = 0 end
  end
  -- out of gold for good: no point waiting, go and finish it
  if food >= need or (tm.foodUsed or 0) >= D.CRAFT.FOOD_CAP - 6 or broke then
    self.mode = "attack"
    return
  end
  -- 5. otherwise: gather at the rally point
  self.mode = "gather"
  local hx, hy = self:rallyPoint()
  for _, u in ipairs(fighters) do
    if U.dist(u.x, u.y, hx, hy) > 350 and #u.orders == 0 then
      w:issue(u, { type = "amove", x = hx + self.rng:random(-90, 90), y = hy + self.rng:random(-90, 90) })
    end
  end
end

function AI:rallyPoint()
  local hall = self:hall()
  if not hall then return self.world.teams[self.team].startX, self.world.teams[self.team].startY end
  -- in front of the hall, toward the middle of the map (the way out of the base)
  local w = self.world
  local mx, my = w.map.w * w.T / 2, w.map.h * w.T / 2
  local dx, dy = U.norm(mx - hall.x, my - hall.y)
  local x, y = hall.x + dx * 380, hall.y + dy * 380
  local tx, ty = w.map:tileAt(x, y)
  local nx, ny = w.map:nearestTile(tx, ty, function(a, b) return w.map:passable("land", a, b) end, 8)
  if nx then x, y = w.map:center(nx, ny) end
  return x, y
end

-- the nearest living creep camp we can take: small ones with the hero early, the
-- middle one (with its boss) once the army is a real one
function AI:creepTarget(fighters, food)
  local w = self.world
  local heroes = C.heroesOf(w, self.team, false)
  if #heroes == 0 then return nil end
  local h = heroes[1]
  local best, bd
  for _, cp in ipairs(w.craft.camps) do
    local hp, alive = 0, 0
    for _, u in ipairs(cp.units) do if u.alive then hp = hp + u.hp; alive = alive + 1 end end
    if alive > 0 then
      local myHp = 0
      for _, u in ipairs(fighters) do myHp = myHp + u.hp end
      if myHp > hp * self.P.creepRatio then
        local d = U.dist(h.x, h.y, cp.x, cp.y)
        -- the enemy's side of the map is off limits for creeping
        local enemyHall
        for _, e in ipairs(w.entities) do
          if e.alive and e.def.hall and w:hostile(e.team, self.team) and U.dist(e.x, e.y, cp.x, cp.y) < 1700 then enemyHall = true end
        end
        if not enemyHall and (not bd or d < bd) then best, bd = cp, d end
      end
    end
  end
  return best
end

-- what to march on: the nearest enemy building (their expansion first), else their units
function AI:attackTarget(cx, cy)
  local w = self.world
  local best, bd
  for _, e in ipairs(w.entities) do
    if e.alive and e.team and e.team > 0 and w:hostile(e.team, self.team) and (e.def.building or e.key == "commander") then
      local d = U.dist(cx, cy, e.x, e.y)
      if e.def.weapon and e.def.building then d = d * 0.9 end
      if not bd or d < bd then best, bd = e, d end
    end
  end
  return best
end

return AI
