-- World simulation: entities, orders, movement, economy, construction, combat, fog.
local D = require("src.defs")
local U = require("src.util")
local Path = require("src.path")
local Map = require("src.map")

local W = {}
W.__index = W

local CELL = 96

function W.new(opts)
  local self = setmetatable({}, W)
  self.map = Map.generate(opts)
  self.T = self.map.T
  self.entities = {}
  self.byId = {}
  self.nextId = 1
  self.projectiles = {}
  self.effects = {}
  self.time = 0
  self.pathCount = 0
  self.playerTeam = opts.playerTeam or 1
  self.over = nil
  self.events = {}          -- notifications for the HUD ({text, t, x, y})
  -- players: list indexed by player id, each { ally = allianceNumber }
  local players = opts.players or { { ally = 1 }, { ally = 2 } }
  self.np = #players
  self.ally = {}
  for i, p in ipairs(players) do self.ally[i] = p.ally or i end
  self.teams = {}
  for t = 1, self.np do
    self.teams[t] = {
      id = t, metal = 600, energy = 2500, mStore = 0, eStore = 0,
      mIncome = 0, eIncome = 0, mSpend = 0, eSpend = 0,
      mSpendAcc = 0, eSpendAcc = 0, stall = 1, incomeMul = 1,
      mDemand = 0, eDemand = 0, mRatio = 1, eRatio = 1,
      lastAttacked = -100,
    }
  end
  if opts.aiIncome then
    for t, mul in pairs(opts.aiIncome) do self.teams[t].incomeMul = mul end
  end
  self.spendTimer = 0

  -- fog of war for the player team
  local n = self.map.w * self.map.h
  self.visible = {}
  self.explored = {}
  for i = 0, n - 1 do self.visible[i] = 0; self.explored[i] = false end
  self.fogTimer = 0
  self.noFog = opts.noFog

  -- commanders
  for t = 1, self.np do
    local s = self.map.starts[t]
    local x, y = self.map:center(s.x, s.y)
    local c = self:spawn("commander", t, x, y)
    c.homeX, c.homeY = x, y
    self.teams[t].commander = c
    self.teams[t].startX, self.teams[t].startY = x, y
  end
  self:recomputeEconomy()
  self.grid = {}
  self:rebuildGrid()
  self:updateFog(true)
  return self
end

---------------------------------------------------------------------------
-- Entity management

function W:spawn(key, team, x, y, built)
  local d = D.units[key]
  local e = {
    id = self.nextId, key = key, def = d, team = team,
    x = x, y = y, angle = math.atan2(self.map.h * self.map.T / 2 - y, self.map.w * self.map.T / 2 - x),
    hp = d.hp, maxhp = d.hp, built = built or 1,
    orders = {}, reload = 0, scanTimer = math.random() * 0.3,
    alive = true, seen = {}, flash = 0,
  }
  e.homeX, e.homeY = x, y
  self.nextId = self.nextId + 1
  if d.building then
    e.tx = math.floor(x / self.T - d.w / 2 + 0.5)
    e.ty = math.floor(y / self.T - d.h / 2 + 0.5)
    e.x = (e.tx + d.w / 2) * self.T
    e.y = (e.ty + d.h / 2) * self.T
    for yy = e.ty, e.ty + d.h - 1 do
      for xx = e.tx, e.tx + d.w - 1 do
        self.map.blocked[self.map:idx(xx, yy)] = e
      end
    end
    if d.factory then
      e.queue = {}
      e.progress = 0
      e.rally = nil
    end
    e.angle = 0
    -- nudge any ground/sea units standing on the footprint out of the way
    if self.grid then
      local half = d.w * self.T / 2
      self:query(e.x, e.y, half + 30, function(u)
        if u.alive and not u.def.building and u.def.domain ~= "air" then
          if math.abs(u.x - e.x) < half + 2 and math.abs(u.y - e.y) < half + 2 then
            local layer = self:layerOf(u)
            local tx, ty = self.map:tileAt(u.x, u.y)
            local nx, ny = self.map:nearestTile(tx, ty, function(x, y) return self.map:passable(layer, x, y) end, 6)
            if nx then u.x, u.y = self.map:center(nx, ny); u.path = nil end
          end
        end
      end)
    end
  end
  if e.built < 1 then e.hp = math.max(1, d.hp * 0.05) end
  self.entities[#self.entities + 1] = e
  self.byId[e.id] = e
  return e
end

function W:remove(e)
  e.alive = false
  self.byId[e.id] = nil
  if e.def.building then
    local d = e.def
    for yy = e.ty, e.ty + d.h - 1 do
      for xx = e.tx, e.tx + d.w - 1 do
        local i = self.map:idx(xx, yy)
        if self.map.blocked[i] == e then self.map.blocked[i] = nil end
      end
    end
  end
end

function W:layerOf(e)
  local dom = e.def.domain
  if dom == "land" then return "land" end
  if dom == "sea" or dom == "sub" then return "sea" end
  return nil -- air or building
end

function W:hostile(t1, t2) return self.ally[t1] ~= self.ally[t2] end
function W:allied(t1, t2) return self.ally[t1] == self.ally[t2] end
function W:isEnemy(a, b) return self.ally[a.team] ~= self.ally[b.team] end

---------------------------------------------------------------------------
-- Spatial grid

function W:rebuildGrid()
  local g = {}
  for _, e in ipairs(self.entities) do
    if e.alive then
      local cx, cy = math.floor(e.x / CELL), math.floor(e.y / CELL)
      local k = cy * 1000 + cx
      local c = g[k]
      if not c then c = {}; g[k] = c end
      c[#c + 1] = e
    end
  end
  self.grid = g
end

function W:query(x, y, r, fn)
  local x0, x1 = math.floor((x - r) / CELL), math.floor((x + r) / CELL)
  local y0, y1 = math.floor((y - r) / CELL), math.floor((y + r) / CELL)
  for cy = y0, y1 do
    for cx = x0, x1 do
      local c = self.grid[cy * 1000 + cx]
      if c then
        for i = 1, #c do fn(c[i]) end
      end
    end
  end
end

function W:entityAt(x, y, filter)
  local best, bd
  self:query(x, y, 40, function(e)
    if e.alive and (not filter or filter(e)) then
      local r = e.def.building and e.def.radius or (e.def.radius + 4)
      local d
      if e.def.building then
        local half = self.T * e.def.w / 2
        if math.abs(x - e.x) <= half and math.abs(y - e.y) <= self.T * e.def.h / 2 then d = 0 end
      else
        local dd = U.dist(x, y, e.x, e.y)
        if dd <= r then d = dd end
      end
      if d and (not bd or d < bd) then best, bd = e, d end
    end
  end)
  return best
end

---------------------------------------------------------------------------
-- Economy

function W:recomputeEconomy()
  for t = 1, self.np do
    local tm = self.teams[t]
    tm.mIncome, tm.eIncome, tm.mStore, tm.eStore = 0, 0, 0, 0
  end
  for _, e in ipairs(self.entities) do
    if e.alive and e.built >= 1 then
      local tm = self.teams[e.team]
      local inc = e.def.income
      if inc then
        tm.mIncome = tm.mIncome + (inc.metal or 0) * tm.incomeMul
        tm.eIncome = tm.eIncome + (inc.energy or 0) * tm.incomeMul
      end
      local st = e.def.storage
      if st then
        tm.mStore = tm.mStore + st.metal
        tm.eStore = tm.eStore + st.energy
      end
    end
  end
  for t = 1, self.np do
    local tm = self.teams[t]
    tm.mStore = math.max(tm.mStore, 200)
    tm.eStore = math.max(tm.eStore, 1000)
  end
  self.economyDirty = false
end

-- Try to spend for `power` worth of work on def cost over dt. Returns fraction achieved (0..1).
-- Resources are shared proportionally: if total demand exceeds what's available,
-- every consumer is slowed by the same factor (computed from last tick's demand).
function W:spend(team, cost, power, dt)
  local tm = self.teams[team]
  local f = power * dt / cost.work
  local m, en = cost.metal * f, cost.energy * f
  tm.mDemand = tm.mDemand + m
  tm.eDemand = tm.eDemand + en
  local ratio = 1
  if m > 0 then ratio = math.min(ratio, tm.mRatio) end
  if en > 0 then ratio = math.min(ratio, tm.eRatio) end
  if m > 0 and tm.metal < m * ratio then ratio = tm.metal / m end
  if en > 0 and tm.energy < en * ratio then ratio = math.min(ratio, tm.energy / en) end
  ratio = math.max(0, ratio)
  tm.metal = tm.metal - m * ratio
  tm.energy = tm.energy - en * ratio
  tm.mSpendAcc = tm.mSpendAcc + m * ratio
  tm.eSpendAcc = tm.eSpendAcc + en * ratio
  if ratio < 0.999 then tm.stalled = true end
  return f * ratio
end

---------------------------------------------------------------------------
-- Placement

function W:canPlace(key, tx, ty, team)
  local d = D.units[key]
  local map = self.map
  for yy = ty, ty + d.h - 1 do
    for xx = tx, tx + d.w - 1 do
      if not map:inBounds(xx, yy) then return false end
      local i = map:idx(xx, yy)
      if map.blocked[i] then return false end
      local t = map.terrain[i]
      if d.place == "water" then
        if t ~= Map.WATER then return false end
      elseif d.place == "deposit" then
        if not map.deposit[i] or t ~= Map.LAND then return false end
      else
        if t ~= Map.LAND then return false end
      end
    end
  end
  -- don't place on top of units (land/sea)
  local cx, cy = (tx + d.w / 2) * self.T, (ty + d.h / 2) * self.T
  local half = d.w * self.T / 2
  local blockedByUnit = false
  self:query(cx, cy, half + 20, function(e)
    if e.alive and not e.def.building and e.def.domain ~= "air" and self:hostile(e.team, team) then
      if math.abs(e.x - cx) < half + e.def.radius and math.abs(e.y - cy) < half + e.def.radius then
        blockedByUnit = true
      end
    end
  end)
  return not blockedByUnit
end

-- tile origin for a building centered at world point
function W:footprintAt(key, wx, wy)
  local d = D.units[key]
  return math.floor(wx / self.T - d.w / 2 + 0.5), math.floor(wy / self.T - d.h / 2 + 0.5)
end

---------------------------------------------------------------------------
-- Orders

function W:issue(e, order, queue)
  if not e.alive then return end
  if e.def.building and not e.def.factory then return end
  if e.def.factory then
    -- factories only take rally points
    if order.type == "move" or order.type == "amove" or order.type == "patrol" then
      e.rally = { x = order.x, y = order.y, type = order.type }
    end
    return
  end
  if not queue then
    e.orders = {}
    e.path = nil
    e.chase = nil
  end
  e.orders[#e.orders + 1] = order
end

function W:currentOrder(e) return e.orders[1] end

function W:popOrder(e)
  local o = table.remove(e.orders, 1)
  e.path = nil
  e.chase = nil
  if o and o.type == "patrol" then
    -- patrol loops forever
    e.orders[#e.orders + 1] = { type = "patrol", x = o.fromX, y = o.fromY, fromX = o.x, fromY = o.y }
  end
  if #e.orders == 0 then e.homeX, e.homeY = e.x, e.y end
end

---------------------------------------------------------------------------
-- Movement

function W:setDest(e, x, y)
  local layer = self:layerOf(e)
  if not layer then
    e.path = { { x = x, y = y } }
    e.pathI = 1
    e.destX, e.destY = x, y
    return
  end
  if e.destX and e.path and U.dist2(e.destX, e.destY, x, y) < 24 * 24 then return end
  -- spread expensive searches over frames: past the per-tick cap, head straight
  -- for the goal briefly and search again shortly
  if self.pathCount >= 6 then
    e.path = { { x = x, y = y } }
    e.pathI = 1
    e.destX, e.destY = nil, nil
    e.repathAt = self.time + 0.15
    return
  end
  self.pathCount = self.pathCount + 1
  e.path = Path.find(self.map, layer, e.x, e.y, x, y)
  e.pathI = 1
  e.destX, e.destY = x, y
  e.repathAt = self.time + 4
end

-- Move along path. Returns true when arrived (or stuck at path end).
function W:followPath(e, dt, arriveDist)
  if not e.path or #e.path == 0 then return true end
  local p = e.path[e.pathI]
  if not p then return true end
  local dx, dy = p.x - e.x, p.y - e.y
  local nx, ny, len = U.norm(dx, dy)
  local last = e.pathI >= #e.path
  local thresh = last and (arriveDist or 6) or 14
  if len <= thresh then
    if last then return true end
    e.pathI = e.pathI + 1
    return false
  end
  local speed = self:speedOf(e)
  if e.def.domain == "land" then
    local tx, ty = self.map:tileAt(e.x, e.y)
    if self.map:terrainAt(tx, ty) == Map.HILL then speed = speed * 0.8 end
  end
  local step = math.min(len, speed * dt)
  local mx, my = nx * step, ny * step
  self:tryMove(e, mx, my)
  -- facing
  local target = math.atan2(ny, nx)
  local diff = (target - e.angle + math.pi) % (math.pi * 2) - math.pi
  e.angle = e.angle + U.clamp(diff, -8 * dt, 8 * dt)
  e.moving = true
  return false
end

function W:tryMove(e, mx, my)
  local layer = self:layerOf(e)
  if not layer then
    e.x = U.clamp(e.x + mx, 0, self.map.w * self.T)
    e.y = U.clamp(e.y + my, 0, self.map.h * self.T)
    return
  end
  local map = self.map
  local nx, ny = e.x + mx, e.y + my
  local tx, ty = map:tileAt(nx, ny)
  if map:passable(layer, tx, ty) then
    e.x, e.y = nx, ny
  else
    -- slide along axes
    local ax, ay = map:tileAt(e.x + mx, e.y)
    if map:passable(layer, ax, ay) then
      e.x = e.x + mx
    else
      local bx, by = map:tileAt(e.x, e.y + my)
      if map:passable(layer, bx, by) then e.y = e.y + my end
    end
  end
end

-- Push overlapping units apart
function W:separate(dt)
  for _, e in ipairs(self.entities) do
    if e.alive and not e.def.building then
      local air = e.def.domain == "air"
      local r1 = e.def.radius
      local px, py = 0, 0
      self:query(e.x, e.y, r1 + 20, function(o)
        if o ~= e and o.alive and not o.def.building and (o.def.domain == "air") == air then
          local dx, dy = e.x - o.x, e.y - o.y
          local d2 = dx * dx + dy * dy
          local rr = r1 + o.def.radius
          if d2 < rr * rr then
            local d = math.sqrt(d2)
            if d < 0.01 then dx, dy, d = math.random() - 0.5, math.random() - 0.5, 0.5 end
            local push = (rr - d) / rr
            px = px + dx / d * push
            py = py + dy / d * push
          end
        end
      end)
      if px ~= 0 or py ~= 0 then
        local k = (air and 60 or 90) * dt
        self:tryMove(e, px * k, py * k)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Elimination: a player whose Commander dies is out; their forces self-destruct.
-- The game ends when only one alliance has a Commander left.

function W:eliminate(team)
  local tm = self.teams[team]
  if tm.dead then return end
  tm.dead = true
  tm.deadTime = self.time
  for _, e in ipairs(self.entities) do
    if e.alive and e.team == team then e.doom = self.time + 0.5 + math.random() * 3.5 end
  end
  if self.onEliminate then self.onEliminate(team) end
  local alive = {}
  local n = 0
  for t = 1, self.np do
    if not self.teams[t].dead and not alive[self.ally[t]] then
      alive[self.ally[t]] = true
      n = n + 1
    end
  end
  if n <= 1 and not self.over then
    local winner = next(alive)
    self.over = { winnerAlly = winner, time = self.time }
  end
end

---------------------------------------------------------------------------
-- Combat

---------------------------------------------------------------------------
-- Veterancy: units earn experience from damage dealt and kills, up to level 5.

W.MAX_LEVEL = 5

function W:xpForLevel(e, L)
  -- cumulative xp needed to reach level L
  return e.def.hp * 0.7 * L * (L + 1) / 2
end

function W:rangeOf(e)
  return e.def.weapon.range * (1 + 0.04 * (e.level or 0))
end

function W:speedOf(e)
  return e.def.speed * (1 + 0.04 * (e.level or 0)) * (e.retreating and 1.25 or 1)
end

-- Units out of combat near their Commander or a factory slowly repair
function W:repairZones()
  local healers = {}
  for _, e in ipairs(self.entities) do
    if e.alive and e.built >= 1 and (e.key == "commander" or e.def.factory) then healers[#healers + 1] = e end
  end
  for _, u in ipairs(self.entities) do
    if u.alive and not u.def.building and u.hp < u.maxhp and self.time - (u.lastHit or -99) > 4 then
      for _, h in ipairs(healers) do
        if h.team == u.team and U.dist2(u.x, u.y, h.x, h.y) < 380 * 380 then
          u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.04 * 0.5)
          u.healing = 0.6
          break
        end
      end
    end
  end
end

function W:gainXP(e, amount)
  if not e or not e.alive or not e.def.weapon then return end
  e.xp = (e.xp or 0) + amount
  local L = e.level or 0
  while L < W.MAX_LEVEL and e.xp >= self:xpForLevel(e, L + 1) do
    L = L + 1
    local oldMax = e.maxhp
    e.maxhp = math.floor(e.def.hp * (1 + 0.10 * L))
    e.hp = math.min(e.maxhp, e.hp + (e.maxhp - oldMax) + e.maxhp * 0.25) -- level-up heals a bit
    e.level = L
    self.effects[#self.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 0.9, size = e.def.radius + 10 }
    if self.onLevel then self.onLevel(e) end
  end
end

function W:canTarget(e, o)
  if not o.alive or self.ally[o.team] == self.ally[e.team] then return false end
  return D.canHit(e.def.weapon, o.def.domain)
end

function W:findTarget(e, range)
  local best, bd, bestIsUnit
  local w = e.def.weapon
  self:query(e.x, e.y, range + 48, function(o)
    if self:canTarget(e, o) then
      local d = U.dist(e.x, e.y, o.x, o.y) - (o.def.building and o.def.radius * 0.7 or o.def.radius)
      if d <= range and d >= w.minRange then
        -- prefer armed units, then units, then buildings
        local isUnit = not o.def.building
        local score = d - (isUnit and 150 or 0) - (o.def.weapon and 100 or 0)
        if not bd or score < bd then best, bd = o, score end
      end
    end
  end)
  return best
end

function W:inRange(e, o, extra)
  local w = e.def.weapon
  local d = U.dist(e.x, e.y, o.x, o.y) - (o.def.building and o.def.radius * 0.7 or o.def.radius)
  return d <= self:rangeOf(e) + (extra or 0) and d >= w.minRange
end

function W:fire(e, o)
  local w = e.def.weapon
  local tx, ty = o.x, o.y
  if w.ballistic and not o.def.building then
    -- slight inaccuracy for artillery and bombs
    tx = tx + (math.random() - 0.5) * 24
    ty = ty + (math.random() - 0.5) * 24
  end
  local L = e.level or 0
  self.projectiles[#self.projectiles + 1] = {
    x = e.x, y = e.y, tx = tx, ty = ty, target = (not w.ballistic) and o or nil,
    speed = w.speed, damage = w.damage * (1 + 0.15 * L), splash = w.splash, team = e.team,
    weapon = w, sx = e.x, sy = e.y, source = e,
  }
  e.reload = w.reload / (1 + 0.08 * L)
  e.flash = 0.08
  if self.onFire then self.onFire(e, o) end
  if not e.def.building then
    e.turret = math.atan2(o.y - e.y, o.x - e.x)
  else
    e.angle = math.atan2(o.y - e.y, o.x - e.x)
  end
end

function W:damage(o, amount, attacker)
  if not o.alive then return end
  if attacker and self:hostile(attacker.team, o.team) then
    local dealt = math.min(amount, math.max(0, o.hp))
    local xp = dealt * (o.def.building and 0.5 or 1)
    if o.hp - amount <= 0 then xp = xp + o.maxhp * 0.3 end -- kill bonus
    self:gainXP(attacker, xp)
  end
  o.hp = o.hp - amount
  o.hitTimer = 0.15
  o.lastHit = self.time
  self.teams[o.team].lastAttacked = self.time
  self.teams[o.team].lastAttackX, self.teams[o.team].lastAttackY = o.x, o.y
  if attacker and attacker.alive and not o.def.building and #o.orders == 0 and o.def.weapon and not o.retaliate and not o.disarmed then
    o.retaliate = attacker
  end
  if o.hp <= 0 then self:kill(o, attacker) end
end

function W:kill(o, attacker)
  if not o.alive then return end
  self:remove(o)
  if self.onKill then self.onKill(o, attacker) end
  local size = o.def.building and o.def.radius * 1.4 or o.def.radius * 2
  self.effects[#self.effects + 1] = { kind = "boom", x = o.x, y = o.y, t = 0, life = 0.6, size = size }
  if o.built >= 1 and (o.def.income or o.def.storage) then self.economyDirty = true end
  if o.key == "commander" then
    self.effects[#self.effects + 1] = { kind = "boom", x = o.x, y = o.y, t = 0, life = 1.4, size = 160 }
    -- commander death blast
    self:query(o.x, o.y, 200, function(v)
      if v.alive and v ~= o and v.def.domain ~= "air" then
        local d = U.dist(o.x, o.y, v.x, v.y)
        if d < 160 then self:damage(v, 1200 * (1 - d / 160)) end
      end
    end)
    self:eliminate(o.team)
  end
end

function W:updateProjectiles(dt)
  local keep = {}
  for _, p in ipairs(self.projectiles) do
    if p.target and p.target.alive then p.tx, p.ty = p.target.x, p.target.y end
    local dx, dy = p.tx - p.x, p.ty - p.y
    local nx, ny, len = U.norm(dx, dy)
    local step = p.speed * dt
    if len <= step then
      -- impact
      if p.splash > 0 then
        self:query(p.tx, p.ty, p.splash + 30, function(o)
          if o.alive and self:hostile(o.team, p.team) and D.canHit(p.weapon, o.def.domain) then
            local d = U.dist(p.tx, p.ty, o.x, o.y) - o.def.radius * 0.5
            if d < p.splash then
              local f = 1 - math.max(0, d) / p.splash * 0.6
              self:damage(o, p.damage * f, p.source)
            end
          end
        end)
        self.effects[#self.effects + 1] = { kind = "splash", x = p.tx, y = p.ty, t = 0, life = 0.35, size = p.splash }
      elseif p.target and p.target.alive then
        self:damage(p.target, p.damage, p.source)
        self.effects[#self.effects + 1] = { kind = "hit", x = p.tx, y = p.ty, t = 0, life = 0.15, size = 6 }
      end
    else
      p.x, p.y = p.x + nx * step, p.y + ny * step
      keep[#keep + 1] = p
    end
  end
  self.projectiles = keep
end

---------------------------------------------------------------------------
-- Per-entity update

function W:updateWeapon(e, dt, focus)
  local w = e.def.weapon
  if not w or e.built < 1 then return end
  if e.disarmed then
    if e.hp >= e.maxhp then e.disarmed = nil else return end
  end
  e.reload = math.max(0, e.reload - dt)
  e.scanTimer = e.scanTimer - dt
  local tgt = nil
  if focus and focus.alive and self:canTarget(e, focus) and self:inRange(e, focus) then
    tgt = focus
  else
    if e.autoTarget and (not e.autoTarget.alive or not self:inRange(e, e.autoTarget, 10)) then
      e.autoTarget = nil
    end
    if not e.autoTarget and e.scanTimer <= 0 then
      e.scanTimer = 0.25
      e.autoTarget = self:findTarget(e, self:rangeOf(e))
    end
    tgt = e.autoTarget
  end
  if tgt then
    e.turret = math.atan2(tgt.y - e.y, tgt.x - e.x)
    if e.reload <= 0 then
      if w.bomb then
        -- bombers must be nearly overhead
        if U.dist(e.x, e.y, tgt.x, tgt.y) <= w.range then self:fire(e, tgt) end
      else
        self:fire(e, tgt)
      end
    end
  end
end

-- Look for an enemy to chase within sight
function W:findChaseTarget(e)
  local w = e.def.weapon
  if not w or e.disarmed then return nil end
  local best, bd
  local layer = self:layerOf(e)
  self:query(e.x, e.y, e.def.sight + 40, function(o)
    if self:canTarget(e, o) then
      local d = U.dist(e.x, e.y, o.x, o.y)
      if d <= e.def.sight and (not layer or d <= self:rangeOf(e) or self.map:canReach(layer, e.x, e.y, o.x, o.y, w.range * 0.9)) then
        local score = d - (o.def.weapon and 120 or 0) - (o.def.building and 0 or 60)
        if not bd or score < bd then best, bd = o, score end
      end
    end
  end)
  return best
end

function W:approach(e, o, dt)
  -- move toward a target until inside weapon range
  local w = e.def.weapon
  if self:inRange(e, o, -8) then
    e.path = nil
    e.destX = nil
    return true
  end
  if not e.path or not e.destX or U.dist2(e.destX, e.destY, o.x, o.y) > 60 * 60 or (e.repathAt and self.time > e.repathAt) then
    self:setDest(e, o.x, o.y)
  end
  self:followPath(e, dt, w and self:rangeOf(e) * 0.6 or 20)
  return false
end

function W:updateUnit(e, dt)
  e.moving = false
  e.retreating = false
  if e.def.regen and e.hp < e.maxhp then e.hp = math.min(e.maxhp, e.hp + e.def.regen * dt) end
  local o = e.orders[1]
  local focus = nil

  if not o then
    -- idle: retaliate / defend area, then return home
    if e.def.weapon then
      local t = e.chase
      if t and (not t.alive or U.dist(e.homeX, e.homeY, t.x, t.y) > e.def.sight + 220) then t = nil end
      if not t and e.retaliate and e.retaliate.alive and self:canTarget(e, e.retaliate) then t = e.retaliate end
      e.retaliate = nil
      if not t then
        e.idleScan = (e.idleScan or 0) - dt
        if e.idleScan <= 0 then
          e.idleScan = 0.5
          t = self:findChaseTarget(e)
          if t and U.dist(e.homeX, e.homeY, t.x, t.y) > e.def.sight + 120 then t = nil end
        end
      end
      e.chase = t
      if t then
        focus = t
        self:approach(e, t, dt)
      elseif U.dist2(e.x, e.y, e.homeX, e.homeY) > 40 * 40 then
        if not e.path then self:setDest(e, e.homeX, e.homeY) end
        if self:followPath(e, dt, 20) then
          e.path = nil
          -- couldn't get all the way back: this is home now
          if e.destX then e.homeX, e.homeY = e.x, e.y end
        end
      elseif e.def.domain == "air" then
        -- hover gently
      end
    end
  elseif o.type == "move" then
    if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
    if self:followPath(e, dt, o.arrive or 8) then self:popOrder(e) end
  elseif o.type == "amove" or o.type == "patrol" then
    local t = e.chase
    if t and (not t.alive or U.dist(e.x, e.y, t.x, t.y) > e.def.sight + 160) then t = nil; e.path = nil end
    if not t and e.def.weapon then
      e.amScan = (e.amScan or 0) - dt
      if e.amScan <= 0 then
        e.amScan = 0.4
        t = self:findChaseTarget(e)
        if t then e.path = nil end
      end
    end
    e.chase = t
    if t then
      focus = t
      self:approach(e, t, dt)
    else
      if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
      if self:followPath(e, dt, o.arrive or 10) then self:popOrder(e) end
    end
  elseif o.type == "attack" then
    local t = o.target
    if not t or not t.alive then
      self:popOrder(e)
    elseif not e.def.weapon or not self:canTarget(e, t) then
      self:popOrder(e)
    else
      focus = t
      self:approach(e, t, dt)
    end
  elseif o.type == "retreat" then
    -- weapons off, +25% speed, straight home; stays disarmed until fully repaired
    e.retreating = true
    if e.def.weapon then e.disarmed = true end
    if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
    if self:followPath(e, dt, 40) then
      e.retreating = false
      self:popOrder(e)
    end
    return
  elseif o.type == "build" then
    self:updateBuildOrder(e, o, dt)
  elseif o.type == "assist" then
    self:updateAssist(e, o, dt)
  else
    self:popOrder(e)
  end

  self:updateWeapon(e, dt, focus)
end

---------------------------------------------------------------------------
-- Construction

function W:builderInRange(e, b)
  local reach = e.def.buildRange + (b.def.radius or 0)
  return U.dist2(e.x, e.y, b.x, b.y) <= reach * reach
end

function W:updateBuildOrder(e, o, dt)
  local d = D.units[o.key]
  if o.ent then
    local b = o.ent
    if not b.alive or b.built >= 1 then self:popOrder(e); return end
    if not self:builderInRange(e, b) then
      if not e.path or e.destX ~= b.x then self:setDest(e, b.x, b.y) end
      self:followPath(e, dt, e.def.buildRange * 0.5)
      return
    end
    e.path = nil
    e.buildTarget = b
    self:applyBuild(e, b, e.def.buildPower, dt)
    return
  end
  -- frame not placed yet: walk there and place it
  local cx, cy = (o.tx + d.w / 2) * self.T, (o.ty + d.h / 2) * self.T
  local reach = e.def.buildRange + d.w * self.T * 0.5
  if U.dist2(e.x, e.y, cx, cy) > reach * reach then
    if not e.path or e.destX ~= cx then self:setDest(e, cx, cy) end
    if self:followPath(e, dt, e.def.buildRange * 0.6) then
      -- could not get close enough; check again next frame (path ends nearest reachable)
      if U.dist2(e.x, e.y, cx, cy) > reach * reach * 1.6 then
        o.fail = (o.fail or 0) + 1
        e.path = nil
        if o.fail > 3 then self:popOrder(e) end
      end
    end
    return
  end
  e.path = nil
  -- is there already a friendly frame of the same type here? then help it
  local existing = self.map.blocked[self.map:idx(o.tx, o.ty)]
  if existing and existing.alive and existing.team == e.team and existing.key == o.key and existing.built < 1 then
    o.ent = existing
    return
  end
  if not self:canPlace(o.key, o.tx, o.ty, e.team) then
    self:popOrder(e)
    return
  end
  local b = self:spawn(o.key, e.team, cx, cy, 0)
  b.builder = e
  o.ent = b
end

function W:applyBuild(e, b, power, dt)
  local frac = self:spend(e.team, b.def.cost, power, dt)
  local before = b.built
  b.built = math.min(1, b.built + frac)
  b.hp = math.min(b.maxhp, b.hp + b.maxhp * (b.built - before))
  e.nanoTarget = b
  e.nanoTimer = 0.1
  if b.built >= 1 then
    b.hp = math.min(b.maxhp, math.max(b.hp, b.maxhp * 0.98))
    self.economyDirty = true
    if b.def.factory and not b.rally then
      b.rally = nil
    end
  end
end

function W:updateAssist(e, o, dt)
  local b = o.target
  if not b or not b.alive or b.team ~= e.team then self:popOrder(e); return end
  local needsBuild = b.built < 1
  local needsRepair = b.built >= 1 and b.hp < b.maxhp
  local factoryHelp = b.def.factory and b.built >= 1 and #b.queue > 0
  if not needsBuild and not needsRepair and not factoryHelp then
    if not o.persist then self:popOrder(e) end
    return
  end
  if not self:builderInRange(e, b) then
    if not e.path or e.destX ~= b.x then self:setDest(e, b.x, b.y) end
    self:followPath(e, dt, e.def.buildRange * 0.5)
    return
  end
  e.path = nil
  if needsBuild then
    self:applyBuild(e, b, e.def.buildPower, dt)
  elseif needsRepair then
    b.hp = math.min(b.maxhp, b.hp + b.maxhp * e.def.buildPower * dt / ((b.def.cost and b.def.cost.work or 200) * 1.5))
    e.nanoTarget = b; e.nanoTimer = 0.1
  elseif factoryHelp then
    b.assistPower = (b.assistPower or 0) + e.def.buildPower
    e.nanoTarget = b; e.nanoTimer = 0.1
  end
end

function W:updateFactory(e, dt)
  local power = e.def.buildPower + (e.assistPower or 0)
  e.assistPower = 0
  local key = e.queue[1]
  if not key then e.progress = 0; return end
  local d = D.units[key]
  local frac = self:spend(e.team, d.cost, power, dt)
  e.progress = e.progress + frac
  e.nanoTimer = 0.1
  if e.progress >= 1 then
    e.progress = 0
    local done = table.remove(e.queue, 1)
    if e.repeatMode then e.queue[#e.queue + 1] = done end
    self:produce(e, done)
  end
end

function W:produce(f, key)
  local d = D.units[key]
  local T = self.T
  local x, y
  if d.domain == "air" then
    x, y = f.x, f.y
  else
    local layer = (d.domain == "land") and "land" or "sea"
    -- exit below the factory, else nearest free tile
    local ex, ey = f.tx + math.floor(f.def.w / 2), f.ty + f.def.h
    local nx, ny = self.map:nearestTile(ex, ey, function(tx, ty) return self.map:passable(layer, tx, ty) end, 8)
    if not nx then return end
    x, y = self.map:center(nx, ny)
  end
  local u = self:spawn(key, f.team, x, y)
  u.homeX, u.homeY = x, y
  if f.rally then
    self:issue(u, { type = f.rally.type == "amove" and "amove" or "move", x = f.rally.x + math.random(-30, 30), y = f.rally.y + math.random(-30, 30) })
  elseif d.domain ~= "air" then
    self:issue(u, { type = "move", x = x + math.random(-40, 40), y = y + 40 + math.random(0, 30) })
  else
    self:issue(u, { type = "move", x = x + math.random(-60, 60), y = y + 70 })
  end
  if self.onProduce then self.onProduce(u, f) end
end

---------------------------------------------------------------------------
-- Fog of war

function W:updateFog(force)
  local map = self.map
  local vis, exp = self.visible, self.explored
  local w, h = map.w, map.h
  for i = 0, w * h - 1 do vis[i] = 0 end
  local T = self.T
  for _, e in ipairs(self.entities) do
    if e.alive and self.ally[e.team] == self.ally[self.playerTeam] then
      local r = (e.built >= 1 and e.def.sight or 80) / T
      local cx, cy = e.x / T, e.y / T
      local x0, x1 = math.max(0, math.floor(cx - r)), math.min(w - 1, math.floor(cx + r))
      local y0, y1 = math.max(0, math.floor(cy - r)), math.min(h - 1, math.floor(cy + r))
      local r2 = r * r
      for ty = y0, y1 do
        local dy = ty + 0.5 - cy
        local row = ty * w
        for tx = x0, x1 do
          local dx = tx + 0.5 - cx
          if dx * dx + dy * dy <= r2 then
            vis[row + tx] = 1
            exp[row + tx] = true
          end
        end
      end
    end
  end
  -- remember enemy buildings that have been seen
  for _, e in ipairs(self.entities) do
    if e.alive and self:hostile(e.team, self.playerTeam) and e.def.building and self:isVisible(e) then
      e.seen[self.playerTeam] = true
    end
  end
  self.fogChanged = true
end

function W:isVisible(e)
  if self.noFog then return true end
  if self.ally[e.team] == self.ally[self.playerTeam] then return true end
  local tx, ty = math.floor(e.x / self.T), math.floor(e.y / self.T)
  if not self.map:inBounds(tx, ty) then return false end
  return self.visible[ty * self.map.w + tx] == 1
end

function W:tileVisible(tx, ty)
  if self.noFog then return true end
  if not self.map:inBounds(tx, ty) then return false end
  return self.visible[ty * self.map.w + tx] == 1
end

---------------------------------------------------------------------------
-- Main tick

function W:update(dt)
  if self.over and self.time > self.over.time + 3 then
    -- keep effects animating only
    self:updateEffects(dt)
    return
  end
  self.time = self.time + dt
  self.pathCount = 0

  if self.economyDirty then self:recomputeEconomy() end
  for t = 1, self.np do
    local tm = self.teams[t]
    tm.metal = math.min(tm.mStore, tm.metal + tm.mIncome * dt)
    tm.energy = math.min(tm.eStore, tm.energy + tm.eIncome * dt)
    tm.stalled = false
    local md, ed = tm.mDemand or 0, tm.eDemand or 0
    tm.mRatio = md > 0 and math.min(1, tm.metal / md) or 1
    tm.eRatio = ed > 0 and math.min(1, tm.energy / ed) or 1
    tm.mDemand, tm.eDemand = 0, 0
  end

  self:rebuildGrid()

  for _, e in ipairs(self.entities) do
    if e.alive then
      e.flash = math.max(0, (e.flash or 0) - dt)
      if e.hitTimer then e.hitTimer = e.hitTimer - dt; if e.hitTimer <= 0 then e.hitTimer = nil end end
      if e.healing then e.healing = e.healing - dt; if e.healing <= 0 then e.healing = nil end end
      if e.doom and self.time >= e.doom then self:kill(e) end
      if e.nanoTimer then e.nanoTimer = e.nanoTimer - dt; if e.nanoTimer <= 0 then e.nanoTimer = nil; e.nanoTarget = nil end end
      if not e.alive then
        -- just self-destructed
      elseif e.def.building then
        if e.built >= 1 then
          if e.def.factory then self:updateFactory(e, dt) end
          if e.def.weapon then self:updateWeapon(e, dt) end
        end
      else
        self:updateUnit(e, dt)
      end
    end
  end

  self.repairTimer = (self.repairTimer or 0) - dt
  if self.repairTimer <= 0 then
    self.repairTimer = 0.5
    self:repairZones()
  end

  self:separate(dt)
  self:updateProjectiles(dt)
  self:updateEffects(dt)

  -- compact dead entities
  local alive = {}
  for _, e in ipairs(self.entities) do if e.alive then alive[#alive + 1] = e end end
  self.entities = alive

  self.spendTimer = self.spendTimer + dt
  if self.spendTimer >= 1 then
    for t = 1, self.np do
      local tm = self.teams[t]
      tm.mSpend = tm.mSpendAcc / self.spendTimer
      tm.eSpend = tm.eSpendAcc / self.spendTimer
      tm.mSpendAcc, tm.eSpendAcc = 0, 0
    end
    self.spendTimer = 0
  end

  self.fogTimer = self.fogTimer - dt
  if self.fogTimer <= 0 then
    self.fogTimer = 0.15
    self:updateFog()
  end
end

function W:updateEffects(dt)
  local keep = {}
  for _, fx in ipairs(self.effects) do
    fx.t = fx.t + dt
    if fx.t < fx.life then keep[#keep + 1] = fx end
  end
  self.effects = keep
end

-- Helpers for UI / AI
function W:teamEntities(team, pred)
  local out = {}
  for _, e in ipairs(self.entities) do
    if e.alive and e.team == team and (not pred or pred(e)) then out[#out + 1] = e end
  end
  return out
end

function W:count(team, key, includeFrames)
  local n = 0
  for _, e in ipairs(self.entities) do
    if e.alive and e.team == team and e.key == key and (includeFrames or e.built >= 1) then n = n + 1 end
  end
  return n
end

return W
