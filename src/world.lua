-- World simulation: entities, orders, movement, economy, construction, combat, fog.
local D = require("src.defs")
local U = require("src.util")
local Path = require("src.path")
local Map = require("src.map")
local CMD = require("src.commander")
local MODS = require("src.mods")
local ARENA -- loaded lazily (src.arena requires this module's siblings)
local CRAFT -- Commander Craft, loaded lazily too

local W = {}
W.__index = W

local CELL = 96

function W.new(opts)
  local self = setmetatable({}, W)
  if opts.craft then
    ARENA = ARENA or require("src.arena")
    CRAFT = CRAFT or require("src.craft")
    self.craft = true
    self.map = require("src.craft_map").generate(opts)
  elseif opts.arena then
    ARENA = ARENA or require("src.arena")
    self.map = Map.generateArena(opts)
  else
    self.map = Map.generate(opts)
  end
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
  self.coh = opts.coh -- Commander of Heroes (squads, points, tickets)
  self.noKite = (os.getenv("PA_NOKITE") or "") ~= "" -- test harness: switch kiting off to compare

  self.nukes = {}
  self.rngCmd = love.math.newRandomGenerator((opts.seed or 1) + 777)
  MODS.init(self, opts.mods)
  if opts.experimental then self.official = false end -- odd map / format mixes don't score
  -- random starting corners. On four-corner maps every player gets a random corner, so
  -- the enemy may be next to you or across the map; teammates get neighbouring corners.
  -- heroes with skills and level-up cards: the Arena and Commander Craft
  self.heroes = opts.arena or opts.craft or nil
  if not opts.arena and not opts.craft and not opts.fixedStarts then
    if love.math.random() < 0.5 then self.map:flipX() end
    local sites = self.map.starts
    if #sites >= 4 and self.np <= #sites then
      local perms = {}
      local function permute(cur, used)
        if #cur == self.np then perms[#perms + 1] = { unpack(cur) }; return end
        for i = 1, #sites do
          if not used[i] then used[i] = true; cur[#cur + 1] = i; permute(cur, used); cur[#cur] = nil; used[i] = nil end
        end
      end
      permute({}, {})
      -- keep the layouts where teammates sit closest together
      local best, pool = math.huge, {}
      for _, pm in ipairs(perms) do
        local cost = 0
        for a = 1, self.np do
          for b = a + 1, self.np do
            if self.ally[a] == self.ally[b] then
              local sa, sb = sites[pm[a]], sites[pm[b]]
              cost = cost + math.floor(U.dist(sa.x, sa.y, sb.x, sb.y))
            end
          end
        end
        if cost < best then best, pool = cost, { pm } elseif cost == best then pool[#pool + 1] = pm end
      end
      local pick = pool[love.math.random(#pool)]
      local chosen = {}
      for t = 1, self.np do chosen[t] = { x = sites[pick[t]].x, y = sites[pick[t]].y } end
      -- the remaining corners stay listed after the players (empty bases to expand into)
      local taken = {}
      for t = 1, self.np do taken[pick[t]] = true end
      for i = 1, #sites do if not taken[i] then chosen[#chosen + 1] = { x = sites[i].x, y = sites[i].y } end end
      self.map.starts = chosen
      if os.getenv("PA_DEBUG_AI") then
        local t = {}
        for i = 1, self.np do t[#t + 1] = string.format("P%d(ally%d)@%d,%d", i, self.ally[i], chosen[i].x, chosen[i].y) end
        print("STARTS " .. table.concat(t, " "))
      end
    else
      local syms = self.map.syms
      local f = syms[love.math.random(#syms)]
      for t, st in ipairs(self.map.starts) do
        local x, y = f(st.x, st.y)
        self.map.starts[t] = { x = x, y = y }
      end
    end
  end
  -- Commander Craft 1v1: the two (mirror-image) bases swap sides at random
  if opts.craft and not opts.fixedStarts and not opts.autotest and love.math.random() < 0.5 then
    local st = self.map.starts
    if self.np == 2 then st[1], st[2] = st[2], st[1]
    elseif self.np == 4 then st[1], st[2], st[3], st[4] = st[2], st[1], st[4], st[3] end -- 2v2: the teams swap east and west
  end
  -- commanders
  for t = 1, self.np do
    local s = self.map.starts[t]
    local x, y = self.map:center(s.x, s.y)
    if self.mods.squads and not opts.arena and not opts.craft then
      -- Squad Tactics: no Commander - the HQ and the squads are placed after this loop
      self.teams[t].startX, self.teams[t].startY = x, y
      goto continue
    end
    if self.mods.apoc and not opts.arena and not opts.craft then
      -- Post-Apocalypse: no Commander, just one Constructor to rebuild from
      local b = self:spawn("builder", t, x, y)
      b.homeX, b.homeY = x, y
      b.mods, b.taken, b.upgrades, b.offers = b.mods or {}, {}, {}, {}
      b.cxp, b.clevel = 0, 0
      -- it stands in as the side's "leader" for the camera and HUD, but losing it isn't losing
      self.teams[t].commander = b
      self.teams[t].startX, self.teams[t].startY = x, y
      goto continue
    end
    do
    local c = self:spawn("commander", t, x, y)
    c.homeX, c.homeY = x, y
    c.mods, c.taken, c.upgrades, c.offers = {}, {}, {}, {}
    c.cxp, c.clevel = 0, 0
    self.teams[t].commander = c
    self.teams[t].startX, self.teams[t].startY = x, y
    end
    ::continue::
  end
  if opts.arena then
    ARENA.setup(self, opts)
    self.parTime = ARENA.par(self)
  elseif opts.craft then
    CRAFT.setup(self, opts)
    self.parTime = CRAFT.par(self)
  end
  self:recomputeEconomy()
  self.grid = {}
  self:rebuildGrid()
  -- Sandbox armies, Squad Tactics HQs and squads (need the grid to place buildings)
  if MODS.afterSpawn(self, opts) then self:rebuildGrid() end
  self:recomputeEconomy()
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
    -- extractor on a rich offshore deposit
    local dp = d.place == "deposit" and self.map.deposit[self.map:idx(e.tx, e.ty)]
    if dp and (dp.sea or dp.rich) then e.mods = { income = { metal = 1.0, energy = 0 } } end
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
    tm.convoyIncome = 0
  end
  for _, e in ipairs(self.entities) do
    if e.alive and e.built >= 1 then
      local tm = self.teams[e.team]
      local inc = (e.mods and e.mods.income) and {
        metal = (e.def.income and e.def.income.metal or 0) + e.mods.income.metal,
        energy = (e.def.income and e.def.income.energy or 0) + e.mods.income.energy } or e.def.income
      if inc then
        local m = (inc.metal or 0) * tm.incomeMul
        -- Metal Alert: extractors fill up for the ore trucks (worth three times as much) instead of
        -- paying straight in; mIncome still counts it so the HUD and the computer can plan
        if self.mods and self.mods.convoy and e.def.place == "deposit" then
          m = m * 3
          tm.convoyIncome = tm.convoyIncome + m
        end
        tm.mIncome = tm.mIncome + m
        tm.eIncome = tm.eIncome + (inc.energy or 0) * tm.incomeMul
      end
      local st = (e.mods and e.mods.storage) and {
        metal = (e.def.storage and e.def.storage.metal or 0) + e.mods.storage.metal,
        energy = (e.def.storage and e.def.storage.energy or 0) + e.mods.storage.energy } or e.def.storage
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
  if self.craft then return power * dt / cost.work end
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
        local dp = map.deposit[i]
        if not dp or (t ~= Map.LAND and not (dp.sea and t == Map.WATER)) then return false end
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
  -- a flee can't be cancelled: the speed boost has to be paid for by actually leaving
  local cur = e.orders[1]
  -- Annihilation: a Commander who fled stays at his drop point until fully repaired
  if cur and cur.type == "retreat" and cur.holdHome and e.hp < e.maxhp - 0.5 then return end
  if cur and cur.type == "retreat" and self.time - (cur.issued or self.time) < 45
    and not (self.arena and e.hp >= e.maxhp - 0.5) then return end -- (Arena: healed up on the way? back to the fight)
  order.issued = order.issued or self.time
  if order.type == "retreat" then
    order.issued = self.time
    local tm = self.teams[e.team]
    if e.key == "commander" and not self.arena and not self.craft and tm and tm.startX
      and U.dist2(order.x, order.y, tm.startX, tm.startY) < 250 * 250 then order.holdHome = true end
  end
  if not queue then
    e.orders = {}
    e.path = nil
    e.chase = nil
  end
  e.orders[#e.orders + 1] = order
end

function W:isFleeing(e)
  local o = e.orders and e.orders[1]
  if o and o.type == "retreat" and o.holdHome then return e.hp < e.maxhp - 0.5 end
  if o and o.type == "retreat" and self.arena and e.hp >= e.maxhp - 0.5 then return false end
  return o and o.type == "retreat" and self.time - (o.issued or self.time) < 45
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
  -- the spot is taken: a friendly unit is standing on (or right next to) the destination and
  -- we're as close as we can get - that counts as arriving (rather than shoving at it forever)
  if last and len < 90 and e.def.domain ~= "air" then
    local taken = false
    self:query(p.x, p.y, 40, function(o)
      if not taken and o ~= e and o.alive and not o.def.building and o.def.domain ~= "air" and o.team and e.team
        and self.ally[o.team] == self.ally[e.team] and U.dist(o.x, o.y, p.x, p.y) < o.def.radius + e.def.radius
        and len < e.def.radius + o.def.radius * 2 + 22 then taken = true end
    end)
    if taken then return true end
  end
  local speed = self:speedOf(e)
  if e.def.domain == "land" then
    local tx, ty = self.map:tileAt(e.x, e.y)
    if self.map:terrainAt(tx, ty) == Map.HILL then speed = speed * 0.8 end
  end
  local step = math.min(len, speed * dt)
  -- a friendly unit standing right in the way: steer round it instead of pushing into it head-on
  -- (on the side it's already leaning to, so it doesn't dither)
  if e.def.domain ~= "air" then
    local r1 = e.def.radius
    local bx, by, bd
    self:query(e.x, e.y, r1 + 34, function(o)
      if o ~= e and o.alive and not o.def.building and o.def.domain ~= "air" and o.team and e.team
        and self.ally[o.team] == self.ally[e.team] and self:layerOf(o) == self:layerOf(e) then
        local ox, oy = o.x - e.x, o.y - e.y
        local d = math.sqrt(ox * ox + oy * oy)
        if d > 0.01 and d < r1 + o.def.radius + 14 and (ox * nx + oy * ny) / d > 0.55 and (not bd or d < bd) then bx, by, bd = ox, oy, d end
      end
    end)
    if bx then
      local side = (nx * by - ny * bx) > 0 and -1 or 1
      if e.sideStepT and self.time - e.sideStepT < 0.6 then side = e.sideStep end
      e.sideStep, e.sideStepT = side, self.time
      local px, py = -ny * side, nx * side
      nx, ny = U.norm(nx * 0.45 + px, ny * 0.45 + py)
    end
  end
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
        -- (a unit fleeing slips past enemies instead of shoving through them)
        if o ~= e and o.alive and not o.def.building and (o.def.domain == "air") == air
          and not ((e.retreating or o.retreating) and o.team and e.team and self.ally[o.team] ~= self.ally[e.team]) then
          local dx, dy = e.x - o.x, e.y - o.y
          local d2 = dx * dx + dy * dy
          local rr = r1 + o.def.radius
          if d2 < rr * rr then
            local d = math.sqrt(d2)
            if d < 0.01 then dx, dy, d = math.random() - 0.5, math.random() - 0.5, 0.5 end
            local push = (rr - d) / rr
            -- standing still next to a friend who's on the move: step aside for him
            if #e.orders == 0 and #o.orders > 0 and o.team and e.team and self.ally[o.team] == self.ally[e.team] then push = push * 1.8 end
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
-- Commander progression (see src/commander.lua)

function W:commanderXP(e, amount)
  if self.heroes then return ARENA.commanderXP(self, e, amount) end
  e.cxp = (e.cxp or 0) + amount
  while (e.clevel or 0) < CMD.MAX_LEVEL and e.cxp >= CMD.THRESHOLDS[(e.clevel or 0) + 1] do
    e.clevel = (e.clevel or 0) + 1
    self.effects[#self.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 1.2, size = 46 }
    MODS.onCommanderLevel(self, e)
    if e.clevel >= CMD.MAX_LEVEL then
      e.nukeReady = self.time   -- unlocked
      if self.onCommanderLevel then self.onCommanderLevel(e, nil) end
    else
      local offer = CMD.offer(self.rngCmd, e)
      e.offers[#e.offers + 1] = offer
      if self.onCommanderLevel then self.onCommanderLevel(e, offer) end
    end
  end
end

-- Take one of the two offered upgrades (index 1 or 2) from the oldest pending offer
function W:chooseUpgrade(e, i)
  local offer = e.offers[1]
  if not offer or not offer[i] then return nil end
  table.remove(e.offers, 1)
  local u = offer[i]
  e.taken[u.key] = true
  e.upgrades[#e.upgrades + 1] = u
  u.apply(self, e)
  -- heroes: cards still waiting were dealt before this pick; redeal any that offer something now taken
  if self.heroes then
    local keep = {}
    for _, off in ipairs(e.offers) do
      local stale = false
      for _, card in ipairs(off) do if e.taken[card.key] then stale = true end end
      if stale then
        local fresh = ARENA.offer(self, e, off[1] and off[1].skill and "skill" or "passive")
        if #fresh > 0 then keep[#keep + 1] = fresh end
      else
        keep[#keep + 1] = off
      end
    end
    e.offers = keep
  end
  return u
end

function W:reinforce(e)
  local layer = "land"
  local tx, ty = self.map:tileAt(e.x, e.y)
  for k = 1, 4 do
    local nx, ny = self.map:nearestTile(tx + (k % 2 == 0 and 2 or -2), ty + (k > 2 and 2 or -2),
      function(x, y) return self.map:passable(layer, x, y) end, 8)
    if nx then
      local x, y = self.map:center(nx, ny)
      local u = self:spawn("tank", e.team, x, y)
      u.homeX, u.homeY = x, y
      self:gainXP(u, self:xpForLevel(u, 2))
    end
  end
end

-- The Nuke: unlimited range, slow visible flight, 10 minute cooldown
function W:canNuke(e)
  return e and e.alive and e.nukeReady and self.time >= e.nukeReady
end

function W:launchNuke(e, x, y)
  if not self:canNuke(e) then return false end
  e.nukeReady = self.time + CMD.NUKE_COOLDOWN
  self.nukeCount = (self.nukeCount or 0) + 1
  local n = { x = e.x, y = e.y, sx = e.x, sy = e.y, tx = x, ty = y, team = e.team, t = 0, src = e }
  self.nukes[#self.nukes + 1] = n
  if self.onNuke then self.onNuke(e, x, y) end
  return true
end

function W:updateNukes(dt)
  local keep = {}
  for _, n in ipairs(self.nukes) do
    local dx, dy, len = U.norm(n.tx - n.x, n.ty - n.y)
    local step = CMD.NUKE_SPEED * dt
    if len <= step then
      self:detonate(n)
    else
      n.x, n.y = n.x + dx * step, n.y + dy * step
      keep[#keep + 1] = n
    end
  end
  self.nukes = keep
end

function W:detonate(n)
  local R = CMD.NUKE_RADIUS
  self.effects[#self.effects + 1] = { kind = "nuke", x = n.tx, y = n.ty, t = 0, life = 2.2, size = R }
  local victims = {}
  self:query(n.tx, n.ty, R + 60, function(o)
    if o.alive and o.key ~= "commander" and not o.dormant and not o.neutral then
      local d = U.dist(n.tx, n.ty, o.x, o.y)
      if d <= R + (o.def.building and o.def.radius * 0.5 or 0) then victims[#victims + 1] = o end
    end
  end)
  for _, o in ipairs(victims) do
    if o.alive then
      if o.def.building then
        self:kill(o, n.src)
      else
        local before = o.hp
        o.hp = o.hp - o.maxhp * 0.5
        o.hitTimer = 0.3
        o.lastHit = self.time
        if o.hp <= 0 then self:kill(o, n.src) end
      end
    end
  end
  if self.onDetonate then self.onDetonate(n) end
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

local NOMODS = {}
function W:modsOf(e) return e.mods or NOMODS end

-- timed buff value (Arena skills), or nil
function W:bv(e, key)
  local v
  local b = e.buffs and e.buffs[key]
  if b and b[2] > self.time then v = b[1] end
  -- standing bonuses from the Arena jungle (shrines, the Colossus Crest)
  local z = e.zoneMul and e.zoneMul[key]
  if z then v = (v or 1) * z end
  -- the Spiritcaller's stance
  local sm = e.stanceMul and e.stanceMul[key]
  if sm then v = (v or 1) * sm end
  return v
end

function W:rangeOf(e)
  return e.def.weapon.range * (1 + 0.04 * (e.level or 0)) * (self:modsOf(e).range or 1) * (self:bv(e, "range") or 1)
end
function W:buildRangeOf(e) return (e.def.buildRange or 0) * (self:modsOf(e).buildRange or 1) end
function W:buildPowerOf(e) return (e.def.buildPower or 0) * (self:modsOf(e).build or 1) end
function W:sightOf(e) return e.def.sight * (self:modsOf(e).sight or 1) * (e.sqSight or 1) * (self.sightMul or 1) end
-- how far a unit hunts for targets: its sight, or for artillery (spotted fire) its range
function W:lookOf(e)
  if e.def.needsSpotter then return math.max(self:sightOf(e), self:rangeOf(e)) end
  return self:sightOf(e)
end

function W:speedOf(e)
  local flee = e.retreating and (e.key == "commander" and 1.5 or 1.25) or 1
  local sp = e.def.speed * (1 + 0.04 * (e.level or 0)) * flee * (self:modsOf(e).speed or 1)
  if self.heroes then
    sp = sp * (self:bv(e, "speed") or 1)
    if e.slowUntil and self.time < e.slowUntil then sp = sp * 0.6 end
  end
  local o = e.orders[1]
  if o and o.groupSpeed and not e.retreating then sp = math.min(sp, o.groupSpeed) end
  if o and o.march and not o.march.contact and not e.retreating and (o.formed or not o.formX) then sp = math.min(sp, o.march.speed) end
  -- squad skills (Sprint, Hull Down...) scale the whole squad, after it has matched pace
  return sp * (e.sqSpeed or 1)
end

-- Units out of combat near their Commander or a factory slowly repair
function W:repairZones()
  if self.craft then return end -- Commander Craft: healing comes from Clerics, skills and time
  -- Repair Aura: heals everything near the Commander, even mid-fight
  for t = 1, self.np do
    local c = self.teams[t].commander
    if c and c.alive and c.mods and c.mods.healAura then
      self:query(c.x, c.y, 320, function(u)
        if u.alive and u.team == t and u ~= c and u.hp < u.maxhp and U.dist2(u.x, u.y, c.x, c.y) < 300 * 300 then
          u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.03 * 0.5)
          u.healing = 0.6
        end
      end)
    end
  end
  local healers = {}
  for _, e in ipairs(self.entities) do
    if e.alive and e.built >= 1 and (e.key == "commander" or e.def.factory) then healers[#healers + 1] = e end
  end
  for _, u in ipairs(self.entities) do
    if u.alive and not u.def.building and u.hp < u.maxhp and self.time - (u.lastHit or -99) > 4
      and (u.key ~= "commander" or self.arena) then
      -- Generals patch themselves up anywhere once out of the fight
      if u.general then u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.012); u.healing = 0.6 end
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
  if self.craft then return end -- Commander Craft: units only improve through research
  if e.key == "commander" or e.creep then return end
  -- Squad Tactics: small maps and nonstop fighting - veterancy comes slower (artillery slowest:
  -- its splash would otherwise make Generals of a whole battery in a minute)
  if self.mods and self.mods.squads then amount = amount * (e.key == "artillery" and 0.2 or 0.35) end
  e.xp = (e.xp or 0) + amount
  local L = e.level or 0
  while L < W.MAX_LEVEL and e.xp >= self:xpForLevel(e, L + 1) do
    L = L + 1
    local oldMax = e.maxhp
    e.maxhp = math.floor(e.def.hp * (1 + 0.10 * L) * (e.hpMul or 1))
    if e.arenaTower then
      e.hp = e.hp + (e.maxhp - oldMax) -- towers just grow; ranking up never repairs them
    else
      e.hp = math.min(e.maxhp, e.hp + (e.maxhp - oldMax) + e.maxhp * 0.25) -- level-up heals a bit
    end
    e.level = L
    self.effects[#self.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 0.9, size = e.def.radius + 10 }
    if self.onLevel then self.onLevel(e) end
  end
  if L >= W.MAX_LEVEL and not e.general and not self.arena and not e.summon then self:promoteGeneral(e) end
end

---------------------------------------------------------------------------
-- Generals (RTS): a unit that reaches the top veterancy level is promoted to a named
-- General - tougher, faster, and his presence makes units of his type hit 25% harder.
W.MAX_GENERALS = 3
W.GENERAL_AURA = 320
local G_FIRST = { "Vasquez", "Okafor", "Lindqvist", "Tanaka", "Moreau", "Kowalski", "Adeyemi", "Reyes", "Novak",
  "Haddad", "Brennan", "Ivanova", "Castillo", "Mbeki", "Sorensen", "Petrov", "Nakamura", "Duarte", "Kessler", "Abara",
  "Whitlock", "Szabo", "Ferro", "Calloway", "Rask", "Oyelaran", "Marchetti", "Holt", "Varga", "Quinlan" }
local G_NICK = { "Ironside", "the Anvil", "Longshot", "Rustbucket", "the Wall", "Hammerfall", "Steady", "Blackpowder",
  "Old Treads", "the Fox", "Thunder", "Gravel", "the Bulwark", "Deadeye", "Scrapper", "Lucky", "Firebrand", "the Mule" }

function W:promoteGeneral(e)
  self.generals = self.generals or {}
  local list = self.generals[e.team] or {}
  self.generals[e.team] = list
  local n = 0
  for i = #list, 1, -1 do if list[i].alive then n = n + 1 else table.remove(list, i) end end
  if n >= W.MAX_GENERALS then return end
  local rng = self.rngCmd
  e.general = true
  e.genName = "Gen. " .. G_FIRST[rng:random(#G_FIRST)] .. (rng:random() < 0.6 and (' "' .. G_NICK[rng:random(#G_NICK)] .. '"') or "")
  -- his own copy of the modifiers (unit mods tables can be shared)
  local m = {}
  for k, v in pairs(e.mods or {}) do m[k] = v end
  m.dmg = (m.dmg or 1) * 1.25
  m.speed = (m.speed or 1) * 1.1
  e.mods = m
  e.maxhp = math.floor(e.maxhp * 1.6)
  e.hp = e.maxhp
  list[#list + 1] = e
  self.effects[#self.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 1.6, size = e.def.radius + 40 }
  if self.onGeneral then self.onGeneral(e, "promoted") end
end

-- a General nearby: same-type units hit 25% harder
function W:generalBoost(e)
  local list = self.generals and self.generals[e.team]
  if not list then return 1 end
  for _, g in ipairs(list) do
    if g.alive and g ~= e and g.key == e.key and U.dist2(g.x, g.y, e.x, e.y) < W.GENERAL_AURA * W.GENERAL_AURA then return 1.25 end
  end
  return 1
end

-- Arena creep veterancy: a creep that lands killing blows ranks up (max 3): +12% health
-- and damage per rank, shown as gold pips. Veterans are worth more experience.
W.CREEP_VET_MAX = 3
function W:creepVeterancy(e, victim)
  if not e.alive or (e.vet or 0) >= W.CREEP_VET_MAX then return end
  e.vetXP = (e.vetXP or 0) + victim.maxhp * 0.5 * (1 + 0.3 * (victim.vet or 0)) + (victim.key == "commander" and 2000 or 0)
  local need = { 0.7, 2.1, 4.2 }
  while (e.vet or 0) < W.CREEP_VET_MAX and e.vetXP >= e.def.hp * need[(e.vet or 0) + 1] do
    e.vet = (e.vet or 0) + 1
    local old = e.maxhp
    e.maxhp = math.floor(e.maxhp * 1.12)
    e.hp = math.min(e.maxhp, e.hp + (e.maxhp - old) + e.maxhp * 0.2)
    e.dmgMul = (e.dmgMul or 1) * 1.12
    if os.getenv("PA_DEBUG_AI") then print(string.format("VET t=%d team%d %s -> %d", self.time, e.team, e.key, e.vet)) end
    self.effects[#self.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 0.8, size = e.def.radius + 12 }
  end
end

-- Arena denial: a Commander (or his summons) may finish off his own side's badly hurt creep
function W:canDeny(e, o)
  return self.arena and o.alive and o.creep and self.ally[o.team] == self.ally[e.team]
    and o.hp < o.maxhp * 0.35 and (e.key == "commander" or e.owner) and e.def.weapon ~= nil
end

function W:canTarget(e, o)
  if not o.alive or o.dormant or o.neutral or self.ally[o.team] == self.ally[e.team] then return false end
  if o.passive and (e.creep or e.arenaTower) then return false end
  if e.passive and not (e.aggro and e.aggro[o] and self.time < e.aggro[o]) then return false end
  if o.fadeUntil and self.time < o.fadeUntil then return false end
  -- War is Hell: broken men running for cover aren't chased down until someone finds them
  if o.broken and not o.surrendered then return false end
  -- Squad Tactics smoke: hidden from anything further than point-blank
  if o.smoked and U.dist2(e.x, e.y, o.x, o.y) > 90 * 90 then return false end
  if o.def.domain == "air" and e.mods and e.mods.hitsAir then return true end
  return D.canHit(e.def.weapon, o.def.domain)
end

-- can e's side see o? (its own eyes, or any friendly unit or building close enough to o)
function W:spotted(e, o)
  if U.dist2(e.x, e.y, o.x, o.y) <= self:sightOf(e) ^ 2 then return true end
  for _, v in ipairs(self.visionSources or {}) do
    if v.ally == self.ally[e.team] and U.dist2(v.x, v.y, o.x, o.y) <= v.r * v.r then return true end
  end
  local seen = false
  self:query(o.x, o.y, 480, function(f)
    if not seen and f.alive and f ~= e and f.team and self.ally[f.team] == self.ally[e.team] and f.def.sight
      and U.dist2(f.x, f.y, o.x, o.y) <= self:sightOf(f) ^ 2 then seen = true end
  end)
  return seen
end

function W:findTarget(e, range)
  local best, bd, bestIsUnit
  local w = e.def.weapon
  self:query(e.x, e.y, range + 48, function(o)
    -- nobody shoots into the fog: past its own sight a unit needs a friend's eyes on the target
    if self:canTarget(e, o) and self:spotted(e, o) then
      local d = U.dist(e.x, e.y, o.x, o.y) - (o.def.building and o.def.radius * 0.7 or o.def.radius)
      if d <= range and d >= w.minRange then
        -- prefer armed units, then units, then buildings
        local isUnit = not o.def.building
        -- armed units first, but only those that can actually hurt us (a Flak truck is no threat to a tank)
        local threat = o.def.weapon and D.canHit(o.def.weapon, e.def.domain)
        local score = d - (isUnit and 150 or 0) - (threat and 100 or (o.def.weapon and 30 or 0)) - (o.key == "battleship" and 400 or 0)
        if o.decoy or o.key == "decoy" then score = score - 600 end
        if e.creep and e.key == "artillery" and o.def.building then score = score - 400 end -- siege creeps go for towers
        if e.arenaTower and o.key == "commander" and not (o.towerAggro and self.time < o.towerAggro) then score = score + 900 end
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
  local m = self:modsOf(e)
  local dmg = w.damage * (1 + 0.15 * L) * (m.dmg or 1)
  -- Inspiring Presence: allies near a Commander with the aura hit harder
  local c = self.teams[e.team].commander
  if c and c ~= e and c.alive and c.mods and c.mods.dmgAura and U.dist2(c.x, c.y, e.x, e.y) < 350 * 350 then
    dmg = dmg * 1.25
  end
  if self.generals and not self.arena then dmg = dmg * self:generalBoost(e) end
  if self.craft then dmg = dmg * CRAFT.damageMul(self, e, o) end
  if m.airDmg and o.def.domain == "air" then dmg = dmg * m.airDmg end -- light anti-air guns
  if self.heroes then
    dmg = dmg * (self:bv(e, "dmg") or 1) * (e.dmgMul or 1)
    if o.def.building and m.breaker then dmg = dmg * m.breaker end
    if m.crit and math.random() < m.crit then dmg = dmg * 2 end
  end
  local wpn = w
  if m.hitsAir or m.splash then
    -- per-commander weapon copy so upgrades don't leak to other units
    e.wpnCopy = e.wpnCopy or setmetatable({}, { __index = w })
    wpn = e.wpnCopy
  end
  self.projectiles[#self.projectiles + 1] = {
    x = e.x, y = e.y, tx = tx, ty = ty, target = (not w.ballistic) and o or nil,
    speed = w.speed, damage = dmg, splash = math.max(w.splash, m.splash or 0), team = e.team,
    weapon = wpn, sx = e.x, sy = e.y, source = e, hitsAir = m.hitsAir,
  }
  -- Commander of Heroes: direct fire can miss. Firing on the move, at a fast mover, or into a
  -- bunker is harder; veterans and leaders shoot straighter. (So two scouts trading shots isn't
  -- a coin toss decided by who saw whom first: the one standing still usually wins)
  if self.squads and not w.ballistic and w.splash == 0 and not o.def.building then
    local hit = 0.88
    if e.moving then hit = hit * 0.78 end
    if o.moving and (o.def.speed or 0) >= 120 then hit = hit * 0.88 end
    if o.inBunker then hit = hit * 0.85 end
    hit = hit + 0.02 * L + (e.squadLeader and 0.05 or 0)
    if math.random() > U.clamp(hit, 0.4, 0.97) then
      local p = self.projectiles[#self.projectiles]
      local a, r = math.random() * math.pi * 2, o.def.radius + 6 + math.random() * 14
      p.target, p.tx, p.ty, p.miss = nil, o.x + math.cos(a) * r, o.y + math.sin(a) * r, true
    end
  end
  e.reload = w.reload / (1 + 0.08 * L) / (m.rof or 1) / (self.heroes and (self:bv(e, "rof") or 1) or 1) / (e.sqRof or 1)
  if self.heroes and (m.chill or e.stanceChill) then self.projectiles[#self.projectiles].chill = true end
  if self.heroes and e.stancePoison then self.projectiles[#self.projectiles].poison = e.stancePoison end
  -- melee fighters (Ascetic) strike instead of shoot: the blow lands at once and leaves no trail
  if self.heroes and (m.melee or e.def.melee) then
    local p = self.projectiles[#self.projectiles]
    p.melee, p.speed = true, 4000
  end
  -- Ranger's Volley: two extra arrows per shot, at other enemies in range when there are any
  if e.volleyUntil and self.time < e.volleyUntil then
    local main = self.projectiles[#self.projectiles]
    local r = self:rangeOf(e)
    local others = {}
    self:query(e.x, e.y, r, function(x)
      if x ~= o and x.alive and self:hostile(x.team, e.team) and D.canHit(w, x.def.domain)
        and U.dist(e.x, e.y, x.x, x.y) <= r and not (x.fadeUntil and x.fadeUntil > self.time) then
        others[#others + 1] = x
      end
    end)
    table.sort(others, function(a, b) return U.dist2(e.x, e.y, a.x, a.y) < U.dist2(e.x, e.y, b.x, b.y) end)
    for k = 1, 2 do
      local t2 = others[k] or o
      self.projectiles[#self.projectiles + 1] = {
        x = e.x, y = e.y, tx = t2.x, ty = t2.y, target = t2, speed = main.speed * (0.92 + 0.08 * k),
        damage = main.damage * 0.5, splash = main.splash, team = e.team,
        weapon = main.weapon, sx = e.x, sy = e.y, source = e, hitsAir = main.hitsAir, chill = main.chill,
      }
    end
  end
  e.flash = 0.08
  if self.onFire then self.onFire(e, o) end
  if not e.def.building then
    e.turret = math.atan2(o.y - e.y, o.x - e.x)
  else
    e.angle = math.atan2(o.y - e.y, o.x - e.x)
  end
end

function W:damage(o, amount, attacker)
  if not o.alive or o.dormant or o.neutral then return end
  -- War is Hell: hits draw blood (and the badly hurt cry out)
  if self.wih and o.squad and self.onBlood then self.onBlood(o, amount) end
  if attacker and attacker.x and (self.wih or o.key == "commander") then o.hitFrom = { x = attacker.x, y = attacker.y, t = self.time } end
  -- Commander of Heroes: an HQ can't be hurt while its side still holds a capture point
  if o.key == "hq" and self.squads and self.capPoints then
    for _, p in ipairs(self.capPoints) do if p.owner == self.ally[o.team] then return end end
  end
  if o.sqTaken then amount = amount * o.sqTaken end -- Squad Tactics: Entrench
  if self.craft then amount = amount * CRAFT.armorMul(self, o, attacker) end
  if self.heroes then
    if o.protected then return end
    -- early towers are fortified: half damage for 2:30, then 25% less until 5:00
    if o.arenaTower and o.key ~= "core" then
      if self.time < 150 then amount = amount * 0.5 elseif self.time < 300 then amount = amount * 0.75 end
    end
    -- the Core is fortified early on: a lone lane pushed in the first minutes can't end the game
    if o.key == "core" then
      if self.time < 480 then amount = amount * 0.5 elseif self.time < 720 then amount = amount * 0.75 end
    end
    if o.ampUntil and self.time < o.ampUntil then amount = amount * 1.5 end
    if o.sanctuaryUntil and self.time < o.sanctuaryUntil then amount = amount * 0.5 end
    amount = amount * (self:bv(o, "armor") or 1)
    if o.mods and o.mods.dodge and math.random() < o.mods.dodge then return end
    if o.absorb then
      local take = math.min(o.absorb, amount)
      o.absorb = o.absorb - take
      amount = amount - take
      if o.absorb <= 0 then o.absorb, o.absorbUntil = nil, nil end
      if amount <= 0 then o.hitTimer = 0.1; return end
    end
    local ls = ((attacker and attacker.mods and attacker.mods.lifesteal) or 0) + ((attacker and attacker.stanceLifesteal) or 0)
    if attacker and attacker.alive and ls > 0 then
      attacker.hp = math.min(attacker.maxhp, attacker.hp + math.min(amount, o.hp) * ls)
    end
    -- a Commander who hits an enemy Commander draws tower fire for a few seconds
    if attacker and attacker.key == "commander" and o.key == "commander" then attacker.towerAggro = self.time + 3 end
  end
  local m = o.mods
  if m then
    if o.invulnUntil and self.time < o.invulnUntil then return end
    amount = amount * (m.armor or 1)
  end
  if attacker and attacker.key == "commander" and self:hostile(attacker.team, o.team) then
    -- remember that this Commander had a hand in it; he gets the kill if it dies soon
    o.cmdHit = o.cmdHit or {}
    o.cmdHit[attacker] = self.time
  elseif attacker and self:hostile(attacker.team, o.team) then
    if self.arena and attacker.creep then
      -- Arena creeps level as a side (see ARENA.onKill), not one by one
    else
      local dealt = math.min(amount, math.max(0, o.hp))
      local xp = dealt * (o.def.building and 0.5 or 1)
      if o.hp - amount <= 0 then xp = xp + o.maxhp * 0.3 end -- kill bonus
      -- Arena towers learn from fighting Commanders; shooting creeps barely counts, so an
      -- undefended tower doesn't rank up in the middle of your push
      if attacker.arenaTower and o.key ~= "commander" then xp = xp * 0.12 end
      self:gainXP(attacker, xp)
    end
  end
  -- armed bases: towers (and every armed structure) hit a Commander hard - in Annihilation
  local tvc = D.towerVsCmd or D.TOWER_VS_COMMANDER
  if tvc and o.key == "commander" and attacker and attacker.def and attacker.def.building and not self.heroes and not self.craft and not self.squads then
    amount = amount * tvc
  end
  if self.tel then self.tel:damage(o, amount, attacker) end
  o.hp = o.hp - amount
  o.hitTimer = 0.15
  o.lastHit = self.time
  if o.passive and attacker and attacker.alive and attacker.team ~= o.team then
    o.aggro = o.aggro or {}
    o.aggro[attacker] = self.time + 8
    if self.onProvoke then self.onProvoke(o, attacker) end
  end
  -- Craft creep camps fight as one: hitting a creep, or being hit by one, wakes the whole camp
  if self.onCampAlert and attacker and attacker.alive then
    if o.creepCamp and attacker.team ~= o.team then self.onCampAlert(o.creepCamp, attacker)
    elseif attacker.creepCamp and o.team ~= attacker.team then self.onCampAlert(attacker.creepCamp, o) end
  end
  self.teams[o.team].lastAttacked = self.time
  self.teams[o.team].lastAttackX, self.teams[o.team].lastAttackY = o.x, o.y
  if attacker and attacker.alive and not o.def.building and #o.orders == 0 and o.def.weapon and not o.retaliate and not o.disarmed then
    o.retaliate = attacker
  end
  if m then
    -- Second Wind: survive one killing blow
    if o.hp <= 0 and m.secondWind and not o.secondWindUsed then
      o.secondWindUsed = true
      o.hp = 1
      o.invulnUntil = self.time + 6
      self.effects[#self.effects + 1] = { kind = "levelup", x = o.x, y = o.y, t = 0, life = 1.5, size = 60 }
      if self.onCommanderEvent then self.onCommanderEvent(o, "Second Wind!") end
    end
    -- Emergency Recall: jump home when badly hurt
    if o.hp > 0 and m.recall and o.hp < o.maxhp * 0.25 and self.time >= (o.recallReady or 0) then
      o.recallReady = self.time + 120
      local tm = self.teams[o.team]
      self.effects[#self.effects + 1] = { kind = "levelup", x = o.x, y = o.y, t = 0, life = 0.8, size = 40 }
      o.x, o.y = tm.startX, tm.startY
      o.orders, o.path, o.chase = {}, nil, nil
      o.homeX, o.homeY = o.x, o.y
      self.effects[#self.effects + 1] = { kind = "levelup", x = o.x, y = o.y, t = 0, life = 0.8, size = 40 }
      if self.onCommanderEvent then self.onCommanderEvent(o, "Emergency Recall!") end
    end
  end
  if o.hp <= 0 then self:kill(o, attacker) end
end

function W:kill(o, attacker)
  if not o.alive then return end
  if self.tel then self.tel:kill(o, attacker) end
  self:remove(o)
  if self.craft then
    CRAFT.onKill(self, o, attacker)
    if self.onKill then self.onKill(o, attacker) end
    MODS.onKill(self, o, attacker)
    local size = o.def.building and o.def.radius * 1.4 or o.def.radius * 2
    self.effects[#self.effects + 1] = { kind = "boom", x = o.x, y = o.y, t = 0, life = 0.6, size = size }
    return
  end
  if self.arena then
    ARENA.onKill(self, o, attacker)
    if o.key == "commander" then
      if self.onKill then self.onKill(o, attacker) end
      MODS.onKill(self, o, attacker)
      ARENA.commanderDied(self, o, attacker)
      return
    end
  end
  -- Commander XP: metal value of anything he damaged in the last 6 seconds before it died
  if o.cmdHit and not self.arena then
    for c, t in pairs(o.cmdHit) do
      if c.alive and self.time - t <= 6 then
        self:commanderXP(c, (o.def.cost and o.def.cost.metal) or 400)
      end
    end
  end
  if self.debugDeaths and attacker and attacker.key == "scout" and os.getenv("PA_DEBUG_AI") then
    print(string.format("SCOUTKILL t=%d team%d scout killed team%d %s", self.time, attacker.team, o.team, o.key))
  end
  if o.key == "commander" and self.debugDeaths then
    local tm = self.teams[o.team]
    print(string.format("CMDDEATH team %d t=%d mode=%s distHome=%d killer=%s lvl=%d", o.team, self.time,
      tostring(self.cmdModes and self.cmdModes[o.team]), U.dist(o.x, o.y, tm.startX, tm.startY),
      attacker and attacker.key or "?", o.clevel or 0))
  end
  -- Salvager refund
  if attacker and attacker.mods and attacker.mods.salvage and o.def.cost and self:hostile(attacker.team, o.team) then
    local tm = self.teams[attacker.team]
    tm.metal = math.min(tm.mStore, tm.metal + o.def.cost.metal * attacker.mods.salvage)
  end
  if self.onKill then self.onKill(o, attacker) end
  MODS.onKill(self, o, attacker)
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
        if p.target and p.target.alive and not self:hostile(p.target.team, p.team) then
          self:damage(p.target, p.damage, p.source) -- a deny shot
        end
        self:query(p.tx, p.ty, p.splash + 30, function(o)
          if o.alive and self:hostile(o.team, p.team) and (D.canHit(p.weapon, o.def.domain) or (p.hitsAir and o.def.domain == "air")) then
            local d = U.dist(p.tx, p.ty, o.x, o.y) - o.def.radius * 0.5
            if d < p.splash then
              local f = 1 - math.max(0, d) / p.splash * 0.6
              self:damage(o, p.damage * f, p.source)
            end
          end
        end)
        self.effects[#self.effects + 1] = { kind = "splash", x = p.tx, y = p.ty, t = 0, life = 0.35, size = p.splash }
        if self.onImpact then self.onImpact(p) end
      elseif p.target and p.target.alive then
        if p.chill then p.target.slowUntil = math.max(p.target.slowUntil or 0, self.time + 1) end
        if p.poison and self.heroes then require("src.arena").dot(self, p.source, p.target, p.poison, 3) end
        self:damage(p.target, p.damage, p.source)
        self.effects[#self.effects + 1] = { kind = "hit", x = p.tx, y = p.ty, t = 0, life = p.melee and 0.22 or 0.15, size = p.melee and 13 or 6 }
      elseif p.miss then
        self.effects[#self.effects + 1] = { kind = "hit", x = p.tx, y = p.ty, t = 0, life = 0.12, size = 3 }
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
  if not w or e.built < 1 or e.neutral then return end
  if e.disarmed then
    if e.hp >= e.maxhp then e.disarmed = nil else return end
  end
  e.reload = math.max(0, e.reload - dt)
  e.scanTimer = e.scanTimer - dt
  local tgt = nil
  if e.holdFire then return end
  if focus and focus.alive and (self:canTarget(e, focus) or self:canDeny(e, focus)) and self:inRange(e, focus)
    and (focus.team == nil or not self:hostile(focus.team, e.team) or self:spotted(e, focus)) then
    tgt = focus
  else
    if e.autoTarget and (not e.autoTarget.alive or not self:inRange(e, e.autoTarget, 10)
      or (e.autoTarget.smoked and not self:canTarget(e, e.autoTarget))
      or (e.scanTimer <= 0 and not self:spotted(e, e.autoTarget))) then
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
  if not w or e.disarmed or e.neutral then return nil end
  local best, bd
  local layer = self:layerOf(e)
  -- artillery looks as far as it can shoot, but only at what a friend can see for it
  local look = self:lookOf(e)
  self:query(e.x, e.y, look + 40, function(o)
    if self:canTarget(e, o) and (not e.def.needsSpotter or self:spotted(e, o)) then
      local d = U.dist(e.x, e.y, o.x, o.y)
      if d <= look and (not layer or d <= self:rangeOf(e) or self.map:canReach(layer, e.x, e.y, o.x, o.y, w.range * 0.9)) then
        local threat = o.def.weapon and D.canHit(o.def.weapon, e.def.domain)
        local score = d - (threat and 120 or (o.def.weapon and 40 or 0)) - (o.def.building and 0 or 60)
        if o.decoy or o.key == "decoy" then score = score - 600 end
        if not bd or score < bd then best, bd = o, score end
      end
    end
  end)
  return best
end

function W:approach(e, o, dt)
  -- move toward a target until inside weapon range
  local w = e.def.weapon
  if self:inRange(e, o, -8) and (not o.team or not self:hostile(o.team, e.team) or self:spotted(e, o)) then
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

---------------------------------------------------------------------------
-- Kiting: a ranged unit fighting (attack, attack-move, patrol, guard or idle) steps back from
-- a shorter-ranged enemy closing in, keeps shooting (weapons fire on the move), then re-engages.
-- Plain moves and group moves never kite. Computer players kite by difficulty (W:setKiteSkill);
-- people's units always do.

local KITE_ORDERS = { amove = true, patrol = true, attack = true, guard = true }

function W:setKiteSkill(team, level)
  self.kiteSkill = self.kiteSkill or {}
  self.kiteSkill[team] = U.clamp(((level or 5) - 3) / 5, 0, 1)
end

function W:canKite(e, o)
  if not e.def.weapon or e.def.building or e.creep or e.neutral or e.passive or e.disarmed or e.holdFire then return false end
  if e.def.domain == "air" or e.def.weapon.bomb or e.def.worker or e.stunUntil and self.time < e.stunUntil then return false end
  local m = self:modsOf(e)
  if m.melee or e.def.melee then return false end
  if o and not KITE_ORDERS[o.type] then return false end
  if self.noKite then return false end
  return true
end

-- the nearest hostile fighter that is out-ranged by e and closing on it
function W:kiteThreat(e)
  local myR = self:rangeOf(e)
  -- anti-air only (Flak): it also backs away from ground attackers it can't shoot, toward friends
  local tg = e.def.weapon.targets
  local aaOnly = tg and tg.air and not tg.land and not tg.sea
  local best, bd
  self:query(e.x, e.y, myR + 40, function(o)
    -- Arena: a Commander kites enemy Commanders only (backing off from creep waves would starve him)
    if o.alive and o ~= e and o.team and not o.def.building and o.def.weapon and not o.neutral and not o.disarmed
      and not (self.arena and e.key == "commander" and o.key ~= "commander")
      and self:hostile(o.team, e.team) and self:canTarget(o, e) and (self:canTarget(e, o) or aaOnly) then
      local theirR = (o.mods and o.mods.melee or o.def.melee) and math.min(self:rangeOf(o), 100) or self:rangeOf(o)
      -- no point running from something much faster (a Scout swarm on artillery): stand and fight
      if theirR + 40 < myR and self:speedOf(o) < self:speedOf(e) * 1.7 then
        local d = U.dist(e.x, e.y, o.x, o.y)
        local minR = e.def.weapon.minRange or 0
        -- the band: out of its reach, inside ours. Only step back when it is about to reach us;
        -- never so far that we can't shoot it any more
        local danger = theirR + e.def.radius
        local reach = self:canTarget(e, o) and (myR + o.def.radius - 10) or (danger + 140)
        if reach - danger >= 30 then
          local trigger = danger + math.min(40, (reach - danger) / 2)
          local edge = d - danger
          if (d < trigger or d < minR + 30) and (not bd or edge < bd) then best, bd = o, edge end
        end
      end
    end
  end)
  return best
end

-- where to step: away from the threat, leaning home, on passable ground, out of enemy tower reach
function W:kitePoint(e, threat)
  local theirR = (threat.mods and threat.mods.melee or threat.def.melee) and math.min(self:rangeOf(threat), 100) or self:rangeOf(threat)
  local d = U.dist(e.x, e.y, threat.x, threat.y)
  local danger = theirR + e.def.radius
  local reach = self:canTarget(e, threat) and (self:rangeOf(e) + threat.def.radius - 10) or (danger + 140)
  local want = math.min(danger + 70, reach)
  local step = U.clamp(want - d, 20, 150)
  local ax, ay = U.norm(e.x - threat.x, e.y - threat.y)
  if ax == 0 and ay == 0 then ax = 1 end
  local tm = self.teams[e.team]
  local hx, hy = e.respawnX or (tm and tm.startX) or e.x, e.respawnY or (tm and tm.startY) or e.y
  local bx, by = U.norm(hx - e.x, hy - e.y)
  local layer = self:layerOf(e)
  local base = math.atan2(ay, ax)
  local best, bs
  for _, off in ipairs({ 0, 0.55, -0.55, 1.1, -1.1, 1.6, -1.6 }) do
    local a = base + off
    local cx, cy = math.cos(a), math.sin(a)
    local px, py = e.x + cx * step, e.y + cy * step
    local ok = true
    if layer then
      for f = 0.5, 1, 0.5 do
        local tx, ty = self.map:tileAt(e.x + cx * step * f, e.y + cy * step * f)
        if not self.map:passable(layer, tx, ty) then ok = false; break end
      end
    else
      ok = px > 0 and py > 0 and px < self.map.w * self.T and py < self.map.h * self.T
    end
    if ok then
      -- never back into an enemy tower or defence
      self:query(px, py, 480, function(b)
        if ok and b.alive and b.def.building and b.def.weapon and b.team and self:hostile(b.team, e.team)
          and not b.neutral and b.built >= 1 and U.dist(px, py, b.x, b.y) < self:rangeOf(b) + e.def.radius + 10 then ok = false end
      end)
    end
    if ok then
      local s = (cx * ax + cy * ay) + 0.35 * (cx * bx + cy * by)
      if not bs or s > bs then best, bs = { px, py }, s end
    end
  end
  return best
end

-- returns true while e is busy stepping back
function W:updateKite(e, dt, o)
  if e.kite then
    local k = e.kite
    if self.time > k.untilT or not self:canKite(e, o) or (o and o ~= k.order) then
      e.kite = nil
      e.path, e.destX = nil, nil
      e.kiteScan = 0 -- still chased? look again at once
      return false
    end
    -- an idle unit that stepped back stays where it is now (no walking back into the enemy)
    if not o then e.homeX, e.homeY = e.x, e.y end
    local dx, dy = k.x - e.x, k.y - e.y
    local nx, ny, len = U.norm(dx, dy)
    if len < 10 then e.kite = nil; e.path, e.destX = nil, nil; return false end
    local stepLen = math.min(len, self:speedOf(e) * dt)
    local x0, y0 = e.x, e.y
    self:tryMove(e, nx * stepLen, ny * stepLen)
    if U.dist2(x0, y0, e.x, e.y) < 0.01 then e.kite = nil; e.path, e.destX = nil, nil; return false end
    e.angle = math.atan2(ny, nx)
    e.moving = true
    return true
  end
  e.kiteScan = (e.kiteScan or 0) - dt
  if e.kiteScan > 0 then return false end
  local skill = self.kiteSkill and self.kiteSkill[e.team] or 1
  e.kiteScan = 0.15 + (1 - skill) * 0.6 -- sharper players react faster
  if not self:canKite(e, o) then return false end
  if skill <= 0 or (skill < 1 and math.random() > skill) then return false end
  local threat = self:kiteThreat(e)
  if not threat then return false end
  local p = self:kitePoint(e, threat)
  if not p then return false end
  e.kite = { x = p[1], y = p[2], untilT = self.time + 0.6, order = o, threat = threat }
  e.kites = (e.kites or 0) + 1
  return true
end

function W:updateUnit(e, dt)
  e.moving = false
  e.retreating = false
  if e.stunUntil and self.time < e.stunUntil then return end
  local regen = (e.mods and e.mods.regen) or e.def.regen
  if e.key == "commander" and not self.heroes then
    -- the Commander only repairs himself at his spawn point (his "base"); the Nano
    -- Regeneration upgrade works anywhere
    local tm = self.teams[e.team]
    local atBase = U.dist2(e.x, e.y, tm.startX or e.x, tm.startY or e.y) < 450 * 450
    regen = (e.mods and e.mods.regen) or 0
    if atBase then regen = regen + e.def.regen + (self.time - (e.lastHit or -99) > 3 and e.maxhp * 0.03 or 0) end
    e.atBase = atBase
  end
  if regen and regen > 0 and e.hp < e.maxhp then e.hp = math.min(e.maxhp, e.hp + regen * dt); if e.key == "commander" and e.atBase then e.healing = 0.3 end end
  local o = e.orders[1]
  local focus = nil

  if self:updateKite(e, dt, o) then
    -- stepping back: keep shooting what we were fighting (or whatever is in range)
    local t = (o and o.type == "attack" and o.target) or e.chase or e.kite.threat
    self:updateWeapon(e, dt, t)
    return
  end

  if not o then
    -- idle: retaliate / defend area, then return home
    if e.def.weapon then
      local t = e.chase
      if t and (not t.alive or U.dist(e.homeX, e.homeY, t.x, t.y) > self:lookOf(e) + 220 or (t.smoked and not self:canTarget(e, t))) then t = nil end
      if not t and e.retaliate and e.retaliate.alive and self:canTarget(e, e.retaliate) then t = e.retaliate end
      e.retaliate = nil
      if not t then
        e.idleScan = (e.idleScan or 0) - dt
        if e.idleScan <= 0 then
          e.idleScan = 0.5
          t = self:findChaseTarget(e)
          if t and U.dist(e.homeX, e.homeY, t.x, t.y) > self:lookOf(e) + 120 then t = nil end
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
    if t and (not t.alive or U.dist(e.x, e.y, t.x, t.y) > self:lookOf(e) + 160 or (t.smoked and not self:canTarget(e, t))) then t = nil; e.path = nil end
    if not t and e.def.weapon then
      e.amScan = (e.amScan or 0) - dt
      if e.amScan <= 0 then
        e.amScan = 0.4
        t = self:findChaseTarget(e)
        if t then e.path = nil end
      end
    end
    e.chase = t
    -- attack-move march: the first one to find a fight (or take a hit) breaks ranks for all
    if o.march and not o.march.contact and (t or (e.lastHit and o.issued and e.lastHit > o.issued)) then
      o.march.contact = true
    end
    local m = o.march
    if t then
      focus = t
      self:approach(e, t, dt)
    elseif m and not m.contact and o.formX and not o.formed then
      -- form up: take our place in the ranks where the army stands
      m.formUntil = m.formUntil or self.time + 6
      if not e.path or e.destX ~= o.formX or e.destY ~= o.formY then self:setDest(e, o.formX, o.formY) end
      if self:followPath(e, dt, 12) or self.time > m.formUntil then
        o.formed = true
        e.path = nil
        m.ready = (m.ready or 0) + 1
      end
    elseif m and not m.contact and o.formX and (m.ready or 0) < m.n and self.time < (m.formUntil or 0) then
      e.path = nil -- in place: wait for the rest of the ranks
    else
      if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
      if self:followPath(e, dt, o.arrive or 10) then self:popOrder(e) end
    end
  elseif o.type == "guard" then
    -- stay with a friendly unit; fight anything that comes near it
    local g = o.target
    if not g or not g.alive then
      self:popOrder(e)
    else
      local t = e.chase
      if t and (not t.alive or U.dist(g.x, g.y, t.x, t.y) > 420) then t = nil; e.path = nil end
      if not t and e.def.weapon then
        e.amScan = (e.amScan or 0) - dt
        if e.amScan <= 0 then
          e.amScan = 0.5
          t = self:findChaseTarget(e)
          if t and U.dist(g.x, g.y, t.x, t.y) > 380 then t = nil end
        end
      end
      e.chase = t
      if t then
        focus = t
        self:approach(e, t, dt)
      else
        local a = (e.id % 8) / 8 * math.pi * 2
        local gx, gy = g.x + math.cos(a) * 70, g.y + math.sin(a) * 70
        if U.dist(e.x, e.y, gx, gy) > 60 then
          if not e.path or not e.guardRepath or self.time > e.guardRepath then
            e.guardRepath = self.time + 1
            self:setDest(e, gx, gy)
          end
          self:followPath(e, dt, 30)
        else
          e.path = nil
        end
        e.homeX, e.homeY = e.x, e.y
      end
    end
  elseif o.type == "attack" then
    local t = o.target
    if not t or not t.alive then
      self:popOrder(e)
    elseif not e.def.weapon or not (self:canTarget(e, t) or self:canDeny(e, t)) then
      self:popOrder(e)
    else
      focus = t
      self:approach(e, t, dt)
    end
  elseif o.type == "retreat" then
    -- weapons off, +25% speed, straight home; stays disarmed until fully repaired
    e.retreating = true
    if e.def.weapon then e.disarmed = true end
    if o.holdHome then
      -- the Commander: home, then he waits there (powered down) until he's whole again
      if o.home or U.dist2(e.x, e.y, o.x, o.y) < 60 * 60 then
        o.home = true
        e.path = nil
        e.retreating = false
        if e.hp >= e.maxhp - 0.5 then e.disarmed = nil; self:popOrder(e) end
        return
      end
      if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
      if self:followPath(e, dt, 40) then o.home = true end
      return
    end
    if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
    if self:followPath(e, dt, 40) or self.time - (o.issued or self.time) > 45 then
      e.retreating = false
      -- Commander Craft: a hero who made it home fights again at once (the hall heals him)
      if self.craft then e.disarmed = nil end
      self:popOrder(e)
    end
    return
  elseif o.type == "build" then
    self:updateBuildOrder(e, o, dt)
  elseif o.type == "harvest" then
    CRAFT.updateHarvest(self, e, o, dt)
  elseif o.type == "repairzone" then
    self:updateRepairZone(e, o, dt)
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
  local reach = self:buildRangeOf(e) + (b.def.radius or 0)
  return U.dist2(e.x, e.y, b.x, b.y) <= reach * reach
end

function W:updateBuildOrder(e, o, dt)
  local d = D.units[o.key]
  if o.ent then
    local b = o.ent
    if not b.alive or b.built >= 1 then self:popOrder(e); return end
    if not self:builderInRange(e, b) then
      if not e.path or e.destX ~= b.x then self:setDest(e, b.x, b.y) end
      self:followPath(e, dt, self:buildRangeOf(e) * 0.5)
      return
    end
    e.path = nil
    e.buildTarget = b
    self:applyBuild(e, b, self:buildPowerOf(e), dt)
    return
  end
  -- frame not placed yet: walk there and place it
  local cx, cy = (o.tx + d.w / 2) * self.T, (o.ty + d.h / 2) * self.T
  local reach = self:buildRangeOf(e) + d.w * self.T * 0.5
  -- someone built over the spot while we walked there: give up (unless it's our own frame of it)
  o.checkT = (o.checkT or 0) - dt
  if o.checkT <= 0 then
    o.checkT = 1
    local ex = self.map.blocked[self.map:idx(o.tx, o.ty)]
    local mineFrame = ex and ex.alive and ex.team == e.team and ex.key == o.key and ex.built < 1
    if not mineFrame and not self:canPlace(o.key, o.tx, o.ty, e.team) then self:popOrder(e); return end
  end
  if U.dist2(e.x, e.y, cx, cy) > reach * reach then
    if not e.path or e.destX ~= cx then self:setDest(e, cx, cy) end
    if self:followPath(e, dt, self:buildRangeOf(e) * 0.6) then
      -- could not get close enough; check again next frame (path ends nearest reachable)
      if U.dist2(e.x, e.y, cx, cy) > reach * reach then
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
  -- Commander Craft: the full price is paid when the foundation goes down
  if self.craft and not CRAFT.payFor(self, e.team, o.key, e) then
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
    MODS.onBuilt(self, b)
    if self.onBuilt then self.onBuilt(b) end
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
    self:followPath(e, dt, self:buildRangeOf(e) * 0.5)
    return
  end
  e.path = nil
  if needsBuild then
    self:applyBuild(e, b, self:buildPowerOf(e), dt)
  elseif needsRepair then
    b.hp = math.min(b.maxhp, b.hp + b.maxhp * self:buildPowerOf(e) * dt / ((b.def.cost and b.def.cost.work or 200) * 1.5))
    e.nanoTarget = b; e.nanoTimer = 0.1
  elseif factoryHelp then
    b.assistPower = (b.assistPower or 0) + self:buildPowerOf(e)
    e.nanoTarget = b; e.nanoTimer = 0.1
  end
end

-- Repair zone: a constructor stays inside a circle and fixes anything of ours in it
-- (damaged units and buildings, unfinished buildings). The Commander comes first.
function W:updateRepairZone(e, o, dt)
  local r2 = (o.r + 24) * (o.r + 24)
  local function needs(b)
    return b.alive and b ~= e and b.team == e.team and (b.built < 1 or b.hp < b.maxhp - 0.5)
      and U.dist2(b.x, b.y, o.x, o.y) <= r2
  end
  if not (o.target and needs(o.target)) then
    o.target = nil
    o.scanT = (o.scanT or 0) - dt
    if o.scanT <= 0 then
      o.scanT = 0.5
      local best, bs
      self:query(o.x, o.y, o.r + 24, function(b)
        if needs(b) then
          local sc = U.dist2(e.x, e.y, b.x, b.y)
          if b.key == "commander" then sc = sc * 0.1 end
          if not bs or sc < bs then best, bs = b, sc end
        end
      end)
      o.target = best
    end
  end
  if o.target then
    o.sub = o.sub or { persist = true }
    o.sub.target = o.target
    self:updateAssist(e, o.sub, dt)
    return
  end
  -- nothing to fix: wait near the middle
  if U.dist(e.x, e.y, o.x, o.y) > o.r * 0.35 then
    if not e.path or e.destX ~= o.x or e.destY ~= o.y then self:setDest(e, o.x, o.y) end
    self:followPath(e, dt, o.r * 0.25)
  else
    e.path = nil
  end
end

function W:updateFactory(e, dt)
  local power = self:buildPowerOf(e) + (e.assistPower or 0)
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
    if e.repeatMode and not self.craft then e.queue[#e.queue + 1] = done end
    self:produce(e, done)
    -- Commander Craft: repeat re-orders (and pays again) if it can
    if e.repeatMode and self.craft and not D.units[done].research and not D.units[done].heroRecruit then CRAFT.enqueue(self, e, done) end
  end
end

function W:produce(f, key)
  if self.craft and CRAFT.produce(self, f, key) then return end
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
  if self.craft then CRAFT.onSpawn(self, u) end
  if self.onProduced then self.onProduced(u) end
  local rt = f.rally and f.rally.type == "guard" and f.rally.target
  if rt and rt.alive and self:layerOf(rt) == self:layerOf(u) or (rt and rt.alive and d.domain == "air") then
    -- rally onto a unit: new units join it and follow it around
    self:issue(u, { type = "guard", target = rt })
  elseif f.rally and f.rally.x then
    self:issue(u, { type = f.rally.type == "amove" and "amove" or "move", x = f.rally.x + math.random(-30, 30), y = f.rally.y + math.random(-30, 30) })
  elseif d.domain ~= "air" then
    self:issue(u, { type = "move", x = x + math.random(-40, 40), y = y + 40 + math.random(0, 30) })
  else
    self:issue(u, { type = "move", x = x + math.random(-60, 60), y = y + 70 })
  end
  if self.craft and u.def.worker then CRAFT.autoGather(self, u, f.rally) end
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
      local r = (e.built >= 1 and self:sightOf(e) or 80) / T
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
  -- flares and other lights (Commander of Heroes)
  for _, v in ipairs(self.visionSources or {}) do
    if v.ally == self.ally[self.playerTeam] then
      local r = v.r / T
      local cx, cy = v.x / T, v.y / T
      for ty = math.max(0, math.floor(cy - r)), math.min(h - 1, math.floor(cy + r)) do
        for tx = math.max(0, math.floor(cx - r)), math.min(w - 1, math.floor(cx + r)) do
          local dx, dy = tx + 0.5 - cx, ty + 0.5 - cy
          if dx * dx + dy * dy <= r * r then vis[ty * w + tx] = 1; exp[ty * w + tx] = true end
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
  if self.tel then self.tel:update() end
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
    tm.metal = math.min(tm.mStore, tm.metal + (tm.mIncome - (tm.convoyIncome or 0)) * dt)
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
      if not e.alive or e.dormant then
        -- just self-destructed, or the dormant alien walker
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
  self:updateNukes(dt)
  if self.arena then ARENA.update(self, dt) end
  if self.craft then CRAFT.update(self, dt) end
  MODS.updateConvoy(self, dt)
  if self.squads then require("src.squads").update(self, dt) end
  MODS.updateApoc(self, dt)
  MODS.updateAlien(self, dt)
  MODS.updateDrops(self, dt)
  MODS.updateScore(self, dt)
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
