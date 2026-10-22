-- Computer opponent: runs an economy, builds factories and defenses,
-- produces a mixed army, defends its base and attacks in growing waves.
local D = require("src.defs")
local U = require("src.util")
local Map = require("src.map")

local AI = {}
AI.__index = AI

function AI.new(world, team, level, profileKey)
  local self = setmetatable({}, AI)
  self.world = world
  self.team = team
  self.rng = love.math.newRandomGenerator(world.map.seed + team * 101)
  -- strength (1-10) and personality are independent
  local d = D.aiLevel(level)
  if profileKey == "Random" then
    profileKey = D.profiles[self.rng:random(1, #D.profiles - 1)].key
  end
  local p = D.profile(profileKey)
  self.profile = p
  self.profileName = p.key
  d.firstWave = math.floor(d.firstWave * (p.firstWaveMul or 1))
  d.waveBase = math.max(3, math.floor(d.waveBase * (p.waveMul or 1) + 0.5))
  d.turrets = math.floor(d.turrets * (p.turretMul or 1) + 0.5) + (p.turretBonus or 0)
  d.aaBonus = p.aaBonus or 0
  d.builderBonus = d.builderBonus + (p.builderBonus or 0)
  d.expandMul = p.expandMul or 1
  d.raidEvery = p.raidEvery or (d.raids and 150 or nil)
  self.diff = d
  self.weights = p.weights or {}
  self.lastRaid = 0
  self.raiders = {}
  self.timer = 1
  self.armyTimer = 2
  self.waves = 0
  self.wave = {}          -- units currently on an attack
  self.lastWave = -999
  local tm = world.teams[team]
  self.baseX, self.baseY = tm.startX, tm.startY
  self.navalCache = {}
  self:chooseTarget()
  self:findWater()
  return self
end

function AI:isHostile(team)
  if team == 0 then return false end -- the neutral, dormant alien walker
  return self.world:hostile(self.team, team)
end

-- Focus on the nearest hostile player that is still alive
function AI:chooseTarget()
  local world = self.world
  local best, bd
  for t = 1, world.np do
    local tm = world.teams[t]
    if t ~= self.team and self:isHostile(t) and not tm.dead then
      local d = U.dist(self.baseX, self.baseY, tm.startX, tm.startY)
      if not bd or d < bd then best, bd = t, d end
    end
  end
  if not best then return end
  self.targetTeam = best
  local et = world.teams[best]
  self.enemyX, self.enemyY = et.startX, et.startY
  local dx, dy = U.norm(self.enemyX - self.baseX, self.enemyY - self.baseY)
  self.dirX, self.dirY = dx, dy
  self.stageX, self.stageY = self.baseX + dx * 320, self.baseY + dy * 320
  if self.seaSet then self.navalReach = self:navalReachTo(best) end
end

function AI:navalReachTo(team)
  if not self.seaSet then return false end
  if self.navalCache[team] ~= nil then return self.navalCache[team] end
  local map = self.world.map
  local tm = self.world.teams[team]
  local ex, ey = map:tileAt(tm.startX, tm.startY)
  local reach = false
  for y = ey - 12, ey + 12 do
    for x = ex - 12, ex + 12 do
      if map:inBounds(x, y) and self.seaSet[y * map.w + x] then reach = true end
    end
  end
  self.navalCache[team] = reach
  return reach
end

-- Is there navigable water reasonably close to the base?
function AI:findWater()
  local map = self.world.map
  local tx, ty = map:tileAt(self.baseX, self.baseY)
  local wx, wy = map:nearestTile(tx, ty, function(x, y)
    if map:terrainAt(x, y) ~= Map.WATER then return false end
    -- want open water (a 5x5 block)
    for yy = y - 2, y + 2 do
      for xx = x - 2, x + 2 do
        if map:terrainAt(xx, yy) ~= Map.WATER then return false end
      end
    end
    return true
  end, 26)
  if wx then
    self.waterTX, self.waterTY = wx, wy
    -- flood the whole body of water so we know where our ships can go
    local seen, stack, n = {}, { { wx, wy } }, 0
    seen[wy * map.w + wx] = true
    while #stack > 0 do
      local p = table.remove(stack)
      n = n + 1
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local x, y = p[1] + d[1], p[2] + d[2]
        if map:inBounds(x, y) and not seen[y * map.w + x] and map:terrainAt(x, y) == Map.WATER then
          seen[y * map.w + x] = true
          stack[#stack + 1] = { x, y }
        end
      end
    end
    self.waterSize = n
    self.seaSet = seen
    -- does this water reach within striking distance of the enemy start?
    self.navalReach = self.targetTeam and self:navalReachTo(self.targetTeam) or false
  end
end

-- Nearest tile of our water body next to a world point (for ship attacks)
function AI:waterNear(x, y, maxR)
  if not self.seaSet then return nil end
  local map = self.world.map
  local tx, ty = map:tileAt(x, y)
  local nx, ny = map:nearestTile(tx, ty, function(xx, yy) return self.seaSet[yy * map.w + xx] == true end, maxR or 8)
  if nx then return map:center(nx, ny) end
  return nil
end

---------------------------------------------------------------------------

function AI:update(dt)
  local world = self.world
  if world.over then return end
  local tm = world.teams[self.team]
  if not tm.commander.alive then return end
  self.timer = self.timer - dt
  if self.timer <= 0 then
    self.timer = self.diff.think
    self:thinkEconomy()
    self:thinkProduction()
  end
  self.armyTimer = self.armyTimer - dt
  if self.armyTimer <= 0 then
    self.armyTimer = 1.0
    self:thinkArmy()
    self:thinkCommander()
  end
end

---------------------------------------------------------------------------
-- Commander: a super unit that loses the game if it dies. It levels up from
-- its own kills, so it should fight - but only when the odds are good.

local function cost(e) return (e.def.cost and e.def.cost.metal) or (e.key == "commander" and 400) or 50 end

-- armed strength (metal value) of a side within r of a point
function AI:strengthNear(x, y, r, hostileSide)
  local s = 0
  self.world:query(x, y, r, function(e)
    if e.alive and e.def.weapon and e.built >= 1 and U.dist2(x, y, e.x, e.y) < r * r then
      local isHostile = self:isHostile(e.team)
      if isHostile == hostileSide and (hostileSide or self.world:allied(e.team, self.team)) then
        s = s + cost(e) * (e.disarmed and 0 or 1)
      end
    end
  end)
  return s
end

function AI:pickUpgrade(c, offer)
  local world = self.world
  local style = self.profile.commander or "normal"
  local enemyAir = self:enemyAirCount()
  local army = #self:mine(function(e) return not e.def.building and e.def.weapon end)
  local t = world.time
  local base = {
    hull = 6, shield = 6, regen = 5, secondwind = 6, recall = 5, cannon = 5, loader = 5, barrel = 4,
    treads = 3, engineer = 3, nanolathe = 2, siphon = 4, storage = 1, flakmount = enemyAir > 2 and 7 or 1,
    splash = 4, eye = 1, healaura = 4, rally = army > 15 and 5 or 3, salvage = 3, reinforce = t < 600 and 6 or 4,
  }
  local mul = {}
  if style == "aggressive" then
    mul = { cannon = 2, loader = 2, splash = 2, barrel = 1.6, treads = 1.6, salvage = 1.5, secondwind = 1.5, reinforce = 1.4 }
  elseif style == "cautious" then
    mul = { nanolathe = 2.5, engineer = 2, shield = 2, recall = 2, healaura = 1.5, cannon = 0.6, treads = 0.5 }
  end
  if self.profileName == "Boomer" then mul.siphon = 3; mul.engineer = 2; mul.storage = 2 end
  if self.profileName == "Air" then mul.flakmount = 0.5 end
  local best, bs
  for i, u in ipairs(offer) do
    local sc = (base[u.key] or 3) * (mul[u.key] or 1) + self.rng:random() * 1.5
    if not bs or sc > bs then best, bs = i, sc end
  end
  return best or 1
end

-- Where to drop the nuke: most enemy value, least friendly value. Commanders are immune.
function AI:bestNukeTarget()
  local world = self.world
  local CMD = require("src.commander")
  local R = CMD.NUKE_RADIUS
  local cands = {}
  for _, e in ipairs(world.entities) do
    if e.alive and self:isHostile(e.team) and not world.teams[e.team].dead then
      if e.def.building or (e.def.weapon and e.key ~= "commander") then cands[#cands + 1] = e end
    end
  end
  local best, bx, by
  local step = math.max(1, math.floor(#cands / 120))
  for i = 1, #cands, step do
    local p = cands[i]
    local score = 0
    world:query(p.x, p.y, R + 40, function(o)
      if o.alive and o.key ~= "commander" and U.dist2(p.x, p.y, o.x, o.y) < R * R then
        local v = cost(o) * (o.def.building and 1 or 0.5)
        if o.def.factory then v = v + 300 end
        if self:isHostile(o.team) then score = score + v
        else score = score - v * 2.5 end
      end
    end)
    if not best or score > best then best, bx, by = score, p.x, p.y end
  end
  return bx, by, best or 0
end

-- The safest nearby spot: where our guns (towers, army, factory repair zones)
-- most outweigh the enemy's. Running into the open just gets him caught.
function AI:escapePoint(c)
  local world = self.world
  local cands = { { self.baseX - self.dirX * 220, self.baseY - self.dirY * 220 } }
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == self.team and e.built >= 1 and (e.def.factory or (e.def.building and e.def.weapon)) then
      cands[#cands + 1] = { e.x, e.y }
    end
  end
  local best, bx, by
  for _, p in ipairs(cands) do
    local d = U.dist(c.x, c.y, p[1], p[2])
    if d < 1400 then
      local score = self:strengthNear(p[1], p[2], 450, false) - 1.5 * self:strengthNear(p[1], p[2], 450, true) - d * 0.4
      if not best or score > best then best, bx, by = score, p[1], p[2] end
    end
  end
  if not bx then bx, by = cands[1][1], cands[1][2] end
  return bx, by
end

function AI:thinkCommander()
  local world = self.world
  world.cmdModes = world.cmdModes or {}
  world.cmdModes[self.team] = self.cmdMode
  local c = world.teams[self.team].commander
  if not c or not c.alive then return end
  local style = self.profile.commander or "normal"
  -- 1. spend level-ups
  while #c.offers > 0 do world:chooseUpgrade(c, self:pickUpgrade(c, c.offers[1])) end
  -- 2. nuke when it's worth it
  if world:canNuke(c) then
    local x, y, score = self:bestNukeTarget()
    if x and score >= (style == "aggressive" and 350 or 600) then world:launchNuke(c, x, y) end
  end

  local hpf = c.hp / c.maxhp
  local tk = c.taken
  local tough = (tk.hull and 1 or 0) + (tk.shield and 1 or 0) + (tk.regen and 1 or 0) + (tk.secondwind and 1 or 0)
    + (tk.recall and 1 or 0) + (tk.healaura and 1 or 0)
  local homeX, homeY = self.baseX - self.dirX * 220, self.baseY - self.dirY * 220
  local danger = self:strengthNear(c.x, c.y, 450, true)
  local support = self:strengthNear(c.x, c.y, 450, false)

  -- 3. retreat: hurt and under fire, or badly outgunned away from home
  -- he is slower than most attackers, so he has to leave early
  local retreatAt = style == "aggressive" and 0.5 or (style == "cautious" and 0.75 or 0.6)
  local distHome = U.dist(c.x, c.y, self.baseX, self.baseY)
  local outgunned = danger > (support + 600) * (style == "aggressive" and 1.5 or 1.0)
  if (hpf < retreatAt and danger > 0) or outgunned then
    self.cmdMode = "retreat"
    local rx, ry = self:escapePoint(c)
    world:issue(c, { type = "move", x = rx, y = ry })
    return
  end
  if self.cmdMode == "retreat" then
    -- once nothing is chasing him, go back to work (he repairs near factories while building)
    if danger > 0 then return end
    self.cmdMode = nil
  end

  -- 4. defend home when we can win the fight (and earn XP doing it)
  local threat = self:enemyNearBase()
  local leash = style == "aggressive" and 900 or (style == "cautious" and 450 or 650)
  if threat and U.dist(threat.x, threat.y, self.baseX, self.baseY) < leash then
    local theirs = self:strengthNear(threat.x, threat.y, 450, true)
    local ours = self:strengthNear(threat.x, threat.y, 600, false) + 400 -- the commander himself
    if ours >= theirs * (style == "aggressive" and 0.8 or (style == "cautious" and 1.6 or 1.25)) and hpf > retreatAt + 0.15 then
      self.cmdMode = "defend"
      world:issue(c, { type = "amove", x = threat.x, y = threat.y })
      return
    end
  end
  if self.cmdMode == "defend" and distHome > leash then
    self.cmdMode = nil
    world:issue(c, { type = "move", x = homeX, y = homeY })
    return
  end

  -- 5. escort a strong attack wave from the back
  local waveList, cx, cy = {}, 0, 0
  for u in pairs(self.wave) do
    if u.alive and u.def.domain == "land" and u.key ~= "scout" then
      waveList[#waveList + 1] = u
      cx, cy = cx + u.x, cy + u.y
    end
  end
  local canEscort
  if style == "aggressive" then canEscort = hpf > 0.75 and #waveList >= 6
  elseif style == "normal" then
    canEscort = hpf > 0.8 and #waveList >= 8 and world.time > 480 and ((c.clevel >= 2 and tough >= 1) or c.clevel >= 3)
  else canEscort = false end
  if canEscort then
    cx, cy = cx / #waveList, cy / #waveList
    -- trail behind the army, toward home
    local bx, by = U.norm(self.baseX - cx, self.baseY - cy)
    self.cmdMode = "escort"
    world:issue(c, { type = "amove", x = cx + bx * 140, y = cy + by * 140 })
    return
  end

  -- 6. Warlord: ride along with raiding parties to pick off extractors
  if style == "aggressive" and hpf > 0.75 and self.raidSquad then
    local n, rx, ry = 0, 0, 0
    for _, u in ipairs(self.raidSquad) do
      if u.alive and u.def.domain == "land" then n = n + 1; rx, ry = rx + u.x, ry + u.y end
    end
    if n >= 3 then
      self.cmdMode = "hunt"
      local bx, by = U.norm(self.baseX - rx / n, self.baseY - ry / n)
      world:issue(c, { type = "amove", x = rx / n + bx * 100, y = ry / n + by * 100 })
      return
    end
  end

  -- 7. otherwise: back to base duty (the economy code hands out build jobs)
  if self.cmdMode and self.cmdMode ~= "build" then
    if U.dist(c.x, c.y, self.baseX, self.baseY) > 300 then
      world:issue(c, { type = "move", x = homeX, y = homeY })
    end
  end
  self.cmdMode = "build"
end

function AI:mine(pred)
  return self.world:teamEntities(self.team, pred)
end

-- count completed + frames + planned builds of a type
function AI:countPlanned(key)
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team then
      if e.key == key then n = n + 1 end
      for _, o in ipairs(e.orders or {}) do
        if o.type == "build" and o.key == key and not o.ent then n = n + 1 end
      end
    end
  end
  return n
end

function AI:enemyAirCount()
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and self:isHostile(e.team) and e.def.domain == "air" then n = n + 1 end
  end
  return n
end

function AI:enemyCount(domain)
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and self:isHostile(e.team) and e.def.domain == domain then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------
-- Placement

function AI:siteFree(key, tx, ty)
  local world = self.world
  local map = world.map
  local d = D.units[key]
  if not world:canPlace(key, tx, ty, self.team) then return false end
  if key == "mex" then return true end
  -- keep a 1-tile walkway around buildings and never cover a deposit
  for yy = ty - 1, ty + d.h do
    for xx = tx - 1, tx + d.w do
      if not map:inBounds(xx, yy) then return false end
      local i = map:idx(xx, yy)
      if map.blocked[i] then return false end
      if map.deposit[i] then return false end
    end
  end
  -- factories need a clear exit row below
  if d.factory and key ~= "shipyard" then
    for xx = tx, tx + d.w - 1 do
      for yy = ty + d.h, ty + d.h + 1 do
        if not map:passable("land", xx, yy) then return false end
      end
    end
  end
  -- don't plan two builds on the same spot
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team then
      for _, o in ipairs(e.orders or {}) do
        if o.type == "build" and not o.ent then
          local od = D.units[o.key]
          if tx < o.tx + od.w + 1 and tx + d.w + 1 > o.tx and ty < o.ty + od.h + 1 and ty + d.h + 1 > o.ty then
            return false
          end
        end
      end
    end
  end
  return true
end

-- Spiral search around (cx,cy) tile for a free site
function AI:findSite(key, cx, cy, minR, maxR)
  local map = self.world.map
  minR, maxR = minR or 2, maxR or 22
  local d = D.units[key]
  local candidates = {}
  for r = minR, maxR do
    for dy = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then
          local tx, ty = cx + dx - math.floor(d.w / 2), cy + dy - math.floor(d.h / 2)
          if self:siteFree(key, tx, ty) then candidates[#candidates + 1] = { tx, ty } end
        end
      end
    end
    if #candidates > 0 then
      return unpack(candidates[self.rng:random(#candidates)])
    end
  end
  return nil
end

function AI:baseTile()
  return self.world.map:tileAt(self.baseX, self.baseY)
end

function AI:nearestFreeDeposit(fromX, fromY, maxDist)
  local world = self.world
  local map = world.map
  local claimed = {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == self.team then
      for _, o in ipairs(e.orders or {}) do
        if o.type == "build" and o.key == "mex" then claimed[o.ty * map.w + o.tx] = true end
      end
    end
  end
  local best, bd
  for _, dp in ipairs(map.deposits) do
    local i = dp.y * map.w + dp.x
    if not map.blocked[i] and not claimed[i] then
      local x, y = map:center(dp.x, dp.y)
      local d = U.dist(fromX, fromY, x, y)
      -- stay on our half-ish of the map, avoid enemy base
      local de = U.dist(self.enemyX, self.enemyY, x, y)
      local db = U.dist(self.baseX, self.baseY, x, y)
      if d <= maxDist and de > 500 and db < de * 1.25 and map:canReach("land", fromX, fromY, x, y, 90)
        and self:threatAt(x, y, 350) == 0 then
        if not bd or d < bd then best, bd = dp, d end
      end
    end
  end
  return best
end

-- Enemy armed units near a point
function AI:threatAt(x, y, r)
  local n = 0
  self.world:query(x, y, r, function(e)
    if e.alive and self:isHostile(e.team) and e.def.weapon and U.dist(x, y, e.x, e.y) < r then
      n = n + (e.def.building and 2 or 1)
    end
  end)
  return n
end

---------------------------------------------------------------------------
-- Economy

function AI:thinkEconomy()
  local world = self.world
  local tm = world.teams[self.team]
  local t = world.time
  local builders = self:mine(function(e) return e.def.builds and not e.def.factory and e.built >= 1 end)

  local landfacs = self:countPlanned("landfac")
  local airfacs = self:countPlanned("airfac")
  local yards = self:countPlanned("shipyard")
  local mexes = self:countPlanned("mex")
  local solars = self:countPlanned("solar")
  local turrets = self:countPlanned("turret")
  local aas = self:countPlanned("aaturret")
  local storages = self:countPlanned("storage")
  local factories = landfacs + airfacs + yards
  local mInc, eInc = tm.mIncome, tm.eIncome
  -- planned solars count toward energy
  local plannedSolar = solars - world:count(self.team, "solar")
  local plannedMex = mexes - world:count(self.team, "mex")
  local eFuture = eInc + plannedSolar * 14 * tm.incomeMul
  local mFuture = mInc + plannedMex * 1.6 * tm.incomeMul
  local enemyAir = self:enemyAirCount()

  for _, b in ipairs(builders) do
    if #b.orders == 0 and not (b.key == "commander" and self.cmdMode and self.cmdMode ~= "build") then
      local isCmd = b.key == "commander"
      local task = nil
      local bx, by = self:baseTile()

      -- energy keeps pace with metal (factories eat a lot of energy)
      local needEnergy = eFuture < mFuture * 9 + 8 or (tm.energy < tm.eStore * 0.15 and eFuture < mFuture * 14)
      local p = self.profile
      local hasWater = self.waterTX and (self.waterSize or 0) > 120
      if factories == 0 and mexes >= (p.airFirst and 3 or 2) and solars >= (p.airFirst and 2 or 1) then
        task = p.airFirst and "airfac" or "landfac"
      elseif needEnergy and solars < 60 then
        task = "solar"
      else
        local em = self.diff.expandMul
        local range = isCmd and 520 or math.min(2600 * em, 700 + t * 3 * em)
        local dp = self:nearestFreeDeposit(b.x, b.y, range)
        if dp and (isCmd or mexes < 30 * em) then
          task = { key = "mex", tx = dp.x, ty = dp.y }
        end
      end
      if not task then
        local wantAA = math.min(6, (enemyAir > 2 and 1 + math.floor(enemyAir / 4) or 0) + (t > 300 and self.diff.aaBonus or 0))
        if p.navalFirst and hasWater and yards == 0 and factories >= 1 and mFuture > 4 then task = "shipyard"
        elseif landfacs == 0 and factories >= 1 and mFuture > 6 then task = "landfac"
        elseif airfacs == 0 and mFuture > 6.5 and t > 150 then task = "airfac"
        elseif yards == 0 and hasWater and mFuture > 7.5 and t > 200 then task = "shipyard"
        elseif turrets < self.diff.turrets and t > 160 then task = "turret"
        elseif aas < wantAA then task = "aaturret"
        elseif storages == 0 and t > 300 then task = "storage"
        elseif factories < self.diff.maxFactories and mFuture > (10 + factories * 4) * (p.factoryEcoMul or 1) then
          local airShare = p.factoryAirShare or 0.4
          if p.navalFirst and hasWater and self.rng:random() < 0.5 then task = "shipyard"
          else task = (self.rng:random() < airShare) and "airfac" or "landfac" end
        elseif needEnergy == false and eFuture < mFuture * 12 then
          task = "solar"
        end
      end

      if task then
        local key, tx, ty
        if type(task) == "table" then
          key, tx, ty = task.key, task.tx, task.ty
        else
          key = task
          if key == "shipyard" then
            tx, ty = self:findSite(key, self.waterTX, self.waterTY, 0, 10)
          elseif key == "turret" or key == "aaturret" then
            local cx = math.floor(bx + self.dirX * self.rng:random(5, 9) + self.rng:random(-4, 4))
            local cy = math.floor(by + self.dirY * self.rng:random(5, 9) + self.rng:random(-4, 4))
            tx, ty = self:findSite(key, cx, cy, 0, 8)
          elseif key == "solar" or key == "storage" then
            -- behind the base, away from the enemy
            local cx = math.floor(bx - self.dirX * 4)
            local cy = math.floor(by - self.dirY * 4)
            tx, ty = self:findSite(key, cx, cy, 1, 18)
          else
            tx, ty = self:findSite(key, bx, by, 3, 20)
          end
        end
        if tx then
          world:issue(b, { type = "build", key = key, tx = tx, ty = ty })
          -- update counters so the next builder doesn't duplicate
          if key == "landfac" then landfacs = landfacs + 1 end
          if key == "airfac" then airfacs = airfacs + 1 end
          if key == "shipyard" then yards = yards + 1 end
          if key == "solar" then solars = solars + 1; eFuture = eFuture + 14 * tm.incomeMul end
          if key == "mex" then mexes = mexes + 1; mFuture = mFuture + 1.6 * tm.incomeMul end
          if key == "turret" then turrets = turrets + 1 end
          if key == "aaturret" then aas = aas + 1 end
          if key == "storage" then storages = storages + 1 end
        end
      else
        -- nothing to build: repair something damaged nearby, else help a factory
        local hurt = self:findDamaged(b)
        local facs = self:mine(function(e) return e.def.factory and e.built >= 1 and #e.queue > 0 end)
        if hurt then
          world:issue(b, { type = "assist", target = hurt })
        elseif #facs > 0 then
          local f = facs[self.rng:random(#facs)]
          world:issue(b, { type = "assist", target = f })
        elseif not isCmd and U.dist(b.x, b.y, self.baseX, self.baseY) > 400 then
          world:issue(b, { type = "move", x = self.baseX + self.rng:random(-120, 120), y = self.baseY + self.rng:random(-120, 120) })
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Production

function AI:pickUnit(f)
  local world = self.world
  local t = world.time
  local rng = self.rng
  local builders = self:countPlanned("builder") + self:queued("builder")
  local wantBuilders = 2 + math.floor(t / 240) + self.diff.builderBonus
  wantBuilders = math.min(wantBuilders, 6 + self.diff.builderBonus)
  local enemyAir = self:enemyAirCount()
  local enemySubs = self:enemyCount("sub")
  local enemyShips = self:enemyCount("sea") + enemySubs
  if f.key == "landfac" then
    if builders < wantBuilders and f == self:firstFactory("landfac") then return "builder" end
    local myFlak = self:countPlanned("flak") + self:queued("flak")
    local w = {
      tank = 50,
      artillery = t > 240 and 18 or 4,
      scout = t < 240 and 14 or 5,
      flak = enemyAir > 0 and math.max(0, enemyAir * 6 - myFlak * 6) or 0,
    }
    return self:pick(w)
  elseif f.key == "airfac" then
    local myFighters = self:countPlanned("fighter") + self:queued("fighter")
    return self:pick({
      fighter = enemyAir > myFighters and 60 or 10,
      bomber = 35,
      gunship = 35,
    })
  elseif f.key == "shipyard" then
    -- without a sea route to the enemy, keep only a small home-defense fleet
    local ships = self:countPlanned("boat") + self:countPlanned("destroyer") + self:countPlanned("sub")
      + self:queued("boat") + self:queued("destroyer") + self:queued("sub")
    if not self.navalReach and ships >= 5 + enemyShips then return nil end
    return self:pick({
      boat = 35,
      destroyer = 30 + (enemySubs > 0 and 30 or 0),
      sub = enemyShips > 0 and 35 or 15,
    })
  end
end

-- weighted pick, adjusted by the personality's unit preferences
function AI:pick(w)
  local adj = {}
  for k, v in pairs(w) do adj[k] = v * (self.weights[k] or 1) end
  return U.weightedPick(self.rng, adj)
end

-- a damaged friendly unit or building near this builder / our base worth repairing
function AI:findDamaged(b)
  local best, bd
  self.world:query(b.x, b.y, 600, function(e)
    if e.alive and e.team == self.team and e ~= b and e.built >= 1 and e.hp < e.maxhp * 0.7 then
      local d = U.dist(b.x, b.y, e.x, e.y)
      if d < 600 and self:threatAt(e.x, e.y, 300) == 0 and (not bd or d < bd) then best, bd = e, d end
    end
  end)
  return best
end

function AI:queued(key)
  local n = 0
  for _, f in ipairs(self:mine(function(e) return e.def.factory end)) do
    for _, k in ipairs(f.queue) do if k == key then n = n + 1 end end
  end
  return n
end

function AI:firstFactory(key)
  local best
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and e.key == key and e.built >= 1 then
      if not best or e.id < best.id then best = e end
    end
  end
  return best
end

function AI:thinkProduction()
  local world = self.world
  local tm = world.teams[self.team]
  for _, f in ipairs(self:mine(function(e) return e.def.factory and e.built >= 1 end)) do
    -- rally point
    if not f.rally then
      if f.key == "shipyard" then
        local map = world.map
        local tx, ty = map:tileAt(f.x + self.dirX * 200, f.y + self.dirY * 200)
        local nx, ny = map:nearestTile(tx, ty, function(x, y) return map:passable("sea", x, y) end, 10)
        if nx then
          local x, y = map:center(nx, ny)
          f.rally = { x = x, y = y, type = "move" }
        end
      else
        f.rally = { x = self.stageX + self.rng:random(-80, 80), y = self.stageY + self.rng:random(-80, 80), type = "move" }
      end
    end
    -- keep a short queue; don't over-queue while stalled
    local limit = (tm.metal > tm.mStore * 0.5) and 3 or 2
    if tm.stalled and tm.metal < 50 then limit = 1 end
    while #f.queue < limit do
      local k = self:pickUnit(f)
      if not k then break end
      f.queue[#f.queue + 1] = k
    end
  end
end

---------------------------------------------------------------------------
-- Army

function AI:enemyNearBase()
  local world = self.world
  local best, bd
  for _, e in ipairs(world.entities) do
    if e.alive and self:isHostile(e.team) and not e.def.building then
      local d = U.dist(e.x, e.y, self.baseX, self.baseY)
      if d < 900 and (not bd or d < bd) then best, bd = e, d end
    end
  end
  -- also anything attacking our structures
  local tm = world.teams[self.team]
  if not best and world.time - tm.lastAttacked < 3 and tm.lastAttackX then
    if U.dist(tm.lastAttackX, tm.lastAttackY, self.baseX, self.baseY) < 1400 then
      return { x = tm.lastAttackX, y = tm.lastAttackY }
    end
  end
  return best
end

-- Choose an attack point: the enemy structure closest to our base, else their commander.
-- Returns x, y (for ships: a water tile next to a reachable target) or nil.
function AI:pickTarget(domain)
  local world = self.world
  local best, bd, bx, by
  for _, e in ipairs(world.entities) do
    if e.alive and self:isHostile(e.team) and (e.def.building or (domain == "sea" and (e.def.domain == "sea" or e.def.domain == "sub"))) then
      local d = U.dist(e.x, e.y, self.baseX, self.baseY) + (e.team == self.targetTeam and 0 or 700)
      if self.world.teams[e.team].dead then d = d + 5000 end
      local px, py = e.x, e.y
      local ok = true
      if domain == "sea" then
        px, py = self:waterNear(e.x, e.y, 7)
        ok = px ~= nil
      end
      if ok and (not bd or d < bd) then best, bd, bx, by = e, d, px, py end
    end
  end
  if best then return bx, by end
  if domain == "sea" then return nil end
  local c = self.targetTeam and world.teams[self.targetTeam].commander
  if c and c.alive then return c.x, c.y end
  return nil
end

-- Alien Tech: send a strong group to take and hold the landing zone
function AI:thinkAlien(army, inWave)
  local a = self.world.alien
  local world = self.world
  local active = a and ((a.state == "announced" and world.time >= a.arriveAt - 25) or a.state == "dormant")
  if not active then
    if self.alienSquad then
      for u in pairs(self.alienSquad) do self.wave[u] = nil end -- back to the home army
      self.alienSquad = nil
    end
    return
  end
  self.alienSquad = self.alienSquad or {}
  local n = 0
  for u in pairs(self.alienSquad) do
    if u.alive then n = n + 1 else self.alienSquad[u] = nil end
  end
  -- personality: aggressive types commit more
  local share = (self.profile.commander == "aggressive" or self.profileName == "Aggressive") and 0.8
    or (self.profileName == "Turtle" and 0.4 or 0.6)
  local avail = {}
  for _, u in ipairs(army) do
    if not inWave[u] and not self.alienSquad[u] and u.key ~= "scout" and not u.disarmed
      and (u.def.domain == "land" or u.def.domain == "air") then avail[#avail + 1] = u end
  end
  local want = math.max(4, math.floor((#avail + n) * share))
  for _, u in ipairs(avail) do
    if n >= want then break end
    self.alienSquad[u] = true
    self.wave[u] = true
    inWave[u] = true
    n = n + 1
  end
  -- keep the squad parked inside the zone (attack-move so they fight for it)
  for u in pairs(self.alienSquad) do
    if #u.orders == 0 and U.dist2(u.x, u.y, a.x, a.y) > 180 * 180 then
      world:issue(u, { type = "amove", x = a.x + self.rng:random(-120, 120), y = a.y + self.rng:random(-120, 120) })
    end
  end
end

function AI:launchRaid(army, inWave)
  local world = self.world
  local map = world.map
  -- target: the enemy extractor/solar farthest from their start
  local best, bd
  for _, e in ipairs(world.entities) do
    if e.alive and self:isHostile(e.team) and (e.key == "mex" or e.key == "solar") then
      local d = U.dist(e.x, e.y, self.enemyX, self.enemyY)
      if not bd or d > bd then best, bd = e, d end
    end
  end
  if not best then return end
  local fast = { scout = true, gunship = true, bomber = true, boat = true, tank = true }
  local squad = {}
  for _, u in ipairs(army) do
    if not inWave[u] and fast[u.key] and #squad < 6 then
      local layer = world:layerOf(u)
      if not layer or map:canReach(layer, u.x, u.y, best.x, best.y, u.def.weapon.range) then
        squad[#squad + 1] = u
      end
    end
  end
  if #squad < 3 then return end
  self.lastRaid = world.time
  self.raidSquad = squad
  for _, u in ipairs(squad) do
    local tx, ty = best.x, best.y
    if u.def.domain == "sea" then tx, ty = self:waterNear(best.x, best.y, 8) end
    if tx then
      world:issue(u, { type = "amove", x = tx + self.rng:random(-30, 30), y = ty + self.rng:random(-30, 30) })
      self.wave[u] = true
      inWave[u] = true
    end
  end
end

function AI:thinkArmy()
  local world = self.world
  self.retarget = (self.retarget or 0) - 1
  if not self.targetTeam or world.teams[self.targetTeam].dead or self.retarget <= 0 then
    self.retarget = 30
    self:chooseTarget()
  end
  local army = self:mine(function(e)
    return not e.def.building and e.def.weapon and e.key ~= "commander" and e.built >= 1
  end)

  -- clean wave set
  local inWave = {}
  for u in pairs(self.wave) do
    if u.alive then inWave[u] = true end
  end
  self.wave = inWave

  -- scouts wander to find things
  for _, u in ipairs(army) do
    if u.key == "scout" and #u.orders == 0 and not inWave[u] then
      local map = world.map
      local dp = map.deposits[self.rng:random(#map.deposits)]
      local x, y = map:center(dp.x, dp.y)
      world:issue(u, { type = "amove", x = x, y = y })
      inWave[u] = true
      self.wave[u] = true
    end
  end

  -- pull badly damaged units home to repair (weapons off, faster)
  if self.diff.retreat then
    for _, u in ipairs(army) do
      local o = u.orders[1]
      if u.hp < u.maxhp * 0.3 and (not o or o.type ~= "retreat") and u.key ~= "scout"
        and U.dist(u.x, u.y, self.baseX, self.baseY) > 600 and self:threatAt(u.x, u.y, 350) > 0 then
        world:issue(u, { type = "retreat", x = self.baseX + self.rng:random(-150, 150), y = self.baseY + self.rng:random(-150, 150) })
        self.wave[u] = nil
        inWave[u] = nil
      end
    end
  end

  -- hit-and-run raids on outlying extractors
  local t0 = world.time
  if self.diff.raidEvery and t0 - self.lastRaid > self.diff.raidEvery and t0 > self.diff.firstWave * 0.6 then
    self:launchRaid(army, inWave)
  end

  -- defend
  local threat = self:enemyNearBase()
  if threat then
    for _, u in ipairs(army) do
      if not inWave[u] or U.dist(u.x, u.y, self.baseX, self.baseY) < 700 then
        if #u.orders == 0 or (u.orders[1].type == "move") then
          world:issue(u, { type = "amove", x = threat.x + self.rng:random(-40, 40), y = threat.y + self.rng:random(-40, 40) })
        end
      end
    end
    return
  end

  -- units in a wave that went idle push on to the next target
  self:thinkAlien(army, inWave)
  for u in pairs(self.wave) do
    if #u.orders == 0 and u.key ~= "scout" and not (self.alienSquad and self.alienSquad[u]) then
      local dom = (u.def.domain == "sea" or u.def.domain == "sub") and "sea" or u.def.domain
      local tx, ty = self:pickTarget(dom)
      if tx then
        local j = dom == "sea" and 20 or 60
        world:issue(u, { type = "amove", x = tx + self.rng:random(-j, j), y = ty + self.rng:random(-j, j) })
      else
        self.wave[u] = nil -- nothing reachable: go home
        world:issue(u, { type = "move", x = u.homeX, y = u.homeY })
      end
    end
  end

  -- gather idle home army; launch a wave when big enough
  local home = {}
  for _, u in ipairs(army) do
    local naval = u.def.domain == "sea" or u.def.domain == "sub"
    if not inWave[u] and u.key ~= "scout" and not u.disarmed and (not naval or self.navalReach) then home[#home + 1] = u end
  end
  local waveSize = math.min(40, self.diff.waveBase + self.waves * self.diff.waveGrow)
  local t = world.time
  local launch = #home >= waveSize
  -- don't wait forever when the army is big but slow to grow
  if not launch and #home >= math.max(5, waveSize * 0.6) and t - self.lastWave > 240 then launch = true end
  if launch and t > (self.diff.firstWave or 200) then
    self.waves = self.waves + 1
    self.lastWave = t
    for _, u in ipairs(home) do
      local dom = (u.def.domain == "sea" or u.def.domain == "sub") and "sea" or u.def.domain
      local tx, ty = self:pickTarget(dom)
      if tx then
        local j = dom == "sea" and 20 or 80
        world:issue(u, { type = "amove", x = tx + self.rng:random(-j, j), y = ty + self.rng:random(-j, j) })
        self.wave[u] = true
      end
    end
  else
    -- fighters guard the base; others hold at staging
    for _, u in ipairs(home) do
      if #u.orders == 0 and U.dist(u.x, u.y, self.stageX, self.stageY) > 500 and u.def.domain ~= "sea" and u.def.domain ~= "sub" then
        world:issue(u, { type = "move", x = self.stageX + self.rng:random(-120, 120), y = self.stageY + self.rng:random(-120, 120) })
      end
    end
  end
end

return AI
