-- Computer opponent: runs an economy, builds factories and defenses,
-- produces a mixed army, defends its base and attacks in growing waves.
local D = require("src.defs")
local U = require("src.util")
local Tel = require("src.telemetry")
local Map = require("src.map")

local AI = {}
AI.__index = AI

function AI.new(world, team, level, profileKey)
  local self = setmetatable({}, AI)
  self.world = world
  self.team = team
  world:setKiteSkill(team, level)
  self.rng = love.math.newRandomGenerator(world.map.seed + team * 101)
  -- strength (1-10) and personality are independent
  local d = D.aiLevel(level)
  if profileKey == "Random" then
    local pool = {}
    for _, pp in ipairs(D.profiles) do if not pp.ghost and pp.key ~= "Random" then pool[#pool + 1] = pp.key end end
    profileKey = pool[self.rng:random(1, #pool)]
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
  -- scout hunter packs: fast, fragile squads that pick off exposed constructors and extractors
  if (p.hunters or 0) > 0 and (d.level or 5) >= 3 and self.rng:random() < (p.huntersChance or 1) then
    self.huntersWanted = p.hunters + ((d.level or 5) >= 8 and 1 or 0)
    self.huntersFrom = p.huntersFrom or 180
  end
  self.hunters, self.isHunter = {}, {}
  -- what this computer has actually seen: enemy buildings (they don't move) and which
  -- corners it has checked. Until it finds an enemy base it attacks its best guess.
  self.known, self.cleared, self.foundBase = {}, {}, {}
  self.lastRaid = 0
  self.raiders = {}
  self.timer = 1
  self.armyTimer = 2
  self.waves = 0
  self.wave = {}          -- units currently on an attack
  -- Scouts as artillery spotters: level 5 knows the trick and uses it now and then, level 10 always
  local L0 = (self.diff and self.diff.level) or level or 5
  self.spotChance = L0 >= 5 and math.min(1, 0.35 + 0.13 * (L0 - 5)) or 0
  if p.spotChance then self.spotChance = math.max(self.spotChance, p.spotChance) end
  self.spotters = {}
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
  if not self.foundBase[best] then
    local gx, gy = self:guessBase()
    if gx then self.enemyX, self.enemyY = gx, gy end
  end
  local dx, dy = U.norm(self.enemyX - self.baseX, self.enemyY - self.baseY)
  self.dirX, self.dirY = dx, dy
  self.stageX, self.stageY = self.baseX + dx * 320, self.baseY + dy * 320
  if self.seaSet then self.navalReach = self:navalReachTo(best) end
end

-- corners that could hold an enemy base: not ours, not an ally's, not checked and found empty
function AI:candidateCorners()
  local world = self.world
  local out = {}
  for i, st in ipairs(world.map.starts) do
    local x, y = world.map:center(st.x, st.y)
    local mine = false
    for t = 1, world.np do
      local tm = world.teams[t]
      if not self:isHostile(t) and tm.startX and U.dist2(tm.startX, tm.startY, x, y) < 200 * 200 then mine = true end
    end
    if not mine and not self.cleared[i] then out[#out + 1] = { i = i, x = x, y = y } end
  end
  return out
end

function AI:guessBase()
  local best, bd
  for _, c in ipairs(self:candidateCorners()) do
    local d = U.dist(self.baseX, self.baseY, c.x, c.y)
    if not bd or d < bd then best, bd = c, d end
  end
  if best then return best.x, best.y end
end

-- every couple of seconds: note enemy buildings near any of our units, and check corners
function AI:updateKnowledge()
  local world = self.world
  local t = world.time
  if t < (self.nextKnow or 0) then return end
  self.nextKnow = t + 2
  local mine = self:mine(function(e) return e.alive end)
  local function seenBy(x, y, r)
    local hit = false
    world:query(x, y, r, function(o)
      if not hit and o.alive and o.team == self.team and U.dist2(o.x, o.y, x, y) < r * r then hit = true end
    end)
    return hit
  end
  for _, e in ipairs(world.entities) do
    if e.alive and e.def.building and not self.known[e] and self:isHostile(e.team) and seenBy(e.x, e.y, 420) then
      self.known[e] = true
      local tm = world.teams[e.team]
      if tm.startX and U.dist2(e.x, e.y, tm.startX, tm.startY) < 900 * 900 and not self.foundBase[e.team] then
        self.foundBase[e.team] = true
        if e.team == self.targetTeam then self.retarget = 0 end
      end
    end
  end
  for k in pairs(self.known) do if not k.alive then self.known[k] = nil end end
  for _, c in ipairs(self:candidateCorners()) do
    if seenBy(c.x, c.y, 450) then
      local found = false
      for t2 = 1, world.np do
        local tm = world.teams[t2]
        if self:isHostile(t2) and tm.startX and U.dist2(tm.startX, tm.startY, c.x, c.y) < 200 * 200 then
          found = true
          if not self.foundBase[t2] then self.foundBase[t2] = true; self.retarget = 0 end
        end
      end
      if not found then self.cleared[c.i] = true; self.retarget = 0 end
    end
  end
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
  if tm.dead or (tm.commander and tm.commander.key == "commander" and not tm.commander.alive) then return end
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
      if (e.def.building and self.known[e]) then cands[#cands + 1] = e end
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
  if not c or not c.alive or c.key ~= "commander" then return end
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
  -- better players guard their Commander more carefully: losing him loses the game
  local lvl = self.diff.level or 5
  if lvl >= 5 then retreatAt = math.min(0.8, retreatAt + 0.04 * (lvl - 4)) end
  local distHome = U.dist(c.x, c.y, self.baseX, self.baseY)
  local outgunned = danger > (support + 600) * (style == "aggressive" and 1.5 or 1.0) * (lvl >= 6 and 0.85 or 1)
  local tmS = world.teams[self.team]
  local spawnDist = U.dist(c.x, c.y, tmS.startX, tmS.startY)
  local homeHot = self:strengthNear(tmS.startX, tmS.startY, 550, true) > 0 or (spawnDist < 450 and danger > 0)
  -- the fight is AT home: running "home" would just power him down where he stands.
  -- Winnable (turrets, factories, army around)? Power up and fight. Otherwise slip out
  -- the far side of the base and wait for it to clear.
  local function homeFight()
    if (support + 450 * hpf) >= danger * 0.85 and hpf > 0.25 then
      c.disarmed = nil
      self.cmdMode = "defend"
      self.evading = false
      local tgt = self:enemyNearBase()
      if tgt then world:issue(c, { type = "amove", x = tgt.x, y = tgt.y }) end
      return true
    end
    if self.evading then return false end
    local ex, ey, n = 0, 0, 0
    world:query(c.x, c.y, 600, function(e)
      if e.alive and self:isHostile(e.team) and e.def.weapon then ex, ey, n = ex + e.x, ey + e.y, n + 1 end
    end)
    local ax, ay = -self.dirX, -self.dirY
    if n > 0 then ax, ay = U.norm(c.x - ex / n, c.y - ey / n) end
    local map = world.map
    local tx, ty = map:tileAt(c.x + ax * 700, c.y + ay * 700)
    tx = math.max(1, math.min(map.w - 2, tx)); ty = math.max(1, math.min(map.h - 2, ty))
    local nx, ny = map:nearestTile(tx, ty, function(x, y) return map:passable("land", x, y) end, 12)
    if not nx then return false end
    local fx, fy = map:center(nx, ny)
    self.cmdMode = "retreat"
    self.evading = true
    world:issue(c, { type = "retreat", x = fx, y = fy })
    return true
  end
  -- retreating powers him down, and most raiders are faster than him: only run from fights
  -- he can't win (a few scouts or a lone tank he simply shoots)
  local beatable = danger <= 450 * hpf + support * 0.6
  if self.cmdMode ~= "retreat" and ((hpf < retreatAt and danger > 0 and not beatable) or outgunned
    or hpf < 0.22 or (hpf < 0.4 and distHome > 500 and not beatable)) then
    if homeHot and spawnDist < 650 and homeFight() then return end
    -- flee home at +50% speed; he only repairs at his spawn point, powered down until full
    self.cmdMode = "retreat"
    self.evading = false
    world:issue(c, { type = "retreat", x = tmS.startX, y = tmS.startY })
    return
  end
  if self.cmdMode == "retreat" then
    if hpf < 0.95 then
      -- made it home, but the fight followed him there
      if not world:isFleeing(c) and spawnDist < 450 and danger > 0 and homeFight() then return end
      if #c.orders == 0 and spawnDist > 200 then
        -- don't walk back into the fight that chased him out; wait until home is clear
        if homeHot then return end
        self.evading = false
        world:issue(c, { type = "retreat", x = tmS.startX, y = tmS.startY })
      end
      return
    end
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

  -- 4b. hunt for experience: once the base runs without him, go pick fights he can win on
  -- our side of the map (raiders, scouts, enemy extractors and outposts). Levels make him
  -- far stronger, so every personality but the cautious ones does this.
  -- an XP hunt that runs into real opposition is called off (better players read it sooner)
  if self.cmdMode == "xp" and self.xpTarget and self.xpTarget.alive
    and danger > (support + 450 * hpf) * (lvl >= 5 and 0.7 or 1.0) then
    self.xpTarget = nil
    self.cmdMode = nil
    world:issue(c, { type = "move", x = homeX, y = homeY })
    return
  end
  if self.cmdMode == "xp" and self.xpTarget and (not self.xpTarget.alive or hpf < 0.55) then
    self.xpTarget = nil
    self.cmdMode = nil
    if hpf < 0.55 then world:issue(c, { type = "move", x = homeX, y = homeY }); return end
  end
  if self.cmdMode == "xp" and self.xpTarget then
    if #c.orders == 0 then world:issue(c, { type = "amove", x = self.xpTarget.x, y = self.xpTarget.y }) end
    return
  end
  local helpers = 0
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == self.team and e.def.builds and not e.def.factory and e.key ~= "commander" and e.built >= 1 then helpers = helpers + 1 end
  end
  local huntLevel = (c.clevel or 0) < 5
  local wantsXP = style ~= "cautious" and huntLevel and hpf > 0.75 and world.time > 150 and helpers >= 2
    and (self.diff.level or 5) >= 3 and world.time - (self.lastHunt or -999) > 20
  if wantsXP then
    self.lastHunt = world.time
    local reach = style == "aggressive" and 2400 or 1800
    local fromBase = style == "aggressive" and 2200 or 1400
    if lvl >= 5 then reach, fromBase = math.min(reach, 1800), math.min(fromBase, 1500) end
    local cands = {}
    for _, e in ipairs(world.entities) do
      if e.alive and self:isHostile(e.team) and e.key ~= "commander" and e.def.domain ~= "air"
        and not (e.def.building and e.def.weapon) and e.built >= 1 then
        local d = U.dist(c.x, c.y, e.x, e.y)
        local de = math.huge
        for t2 = 1, world.np do
          local tt = world.teams[t2]
          if self:isHostile(t2) and not tt.dead and tt.startX then de = math.min(de, U.dist(e.x, e.y, tt.startX, tt.startY)) end
        end
        -- anywhere short of an enemy base: our side, the middle, their outlying extractors
        local db = U.dist(e.x, e.y, self.baseX, self.baseY)
        if d < reach and de > 900 and db < fromBase and db < de * 1.6
          and world.map:canReach("land", c.x, c.y, e.x, e.y, 90) then
          cands[#cands + 1] = { e = e, d = d }
        end
      end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    for i = 1, math.min(5, #cands) do
      local e = cands[i].e
      local theirs = self:strengthNear(e.x, e.y, 420, true)
      local ours = self:strengthNear(e.x, e.y, 500, false) + 500 * hpf
      if ours >= theirs * (style == "aggressive" and 1.2 or 1.6) * (lvl >= 5 and 1.4 or 1) then
        self.cmdMode = "xp"
        self.xpTarget = e
        if os.getenv("PA_DEBUG_AI") then print(string.format("XPHUNT t=%d team=%d L%d -> %s d=%d ours=%d theirs=%d", world.time, self.team, c.clevel or 0, e.key, cands[i].d, ours, theirs)) end
        world:issue(c, { type = "amove", x = e.x, y = e.y })
        return
      end
    end
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
    local bold = (self.diff.level or 5) >= 6
    canEscort = hpf > 0.75 and #waveList >= (bold and 6 or 8) and world.time > (bold and 300 or 420)
      and (bold or (c.clevel >= 2 and tough >= 1) or c.clevel >= 3)
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

function AI:nearestFreeDeposit(fromX, fromY, maxDist, layer)
  layer = layer or "land"
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
      -- (offshore metal is for Sea Constructors only)
      local okLayer = (layer == "sea") == (dp.sea == true)
      if okLayer and d <= maxDist and de > 500 and db < de * 1.25 and map:canReach(layer, fromX, fromY, x, y, 90)
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
  local eFuture = eInc + plannedSolar * D.units.solar.income.energy * tm.incomeMul
  local mFuture = mInc + plannedMex * D.units.mex.income.metal * tm.incomeMul
  local enemyAir = self:enemyAirCount()

  -- (a claimed Power Core nobody is building any more - the builder died or gave up - is free again)
  if self.coreClaimed then
    local building = false
    for _, b in ipairs(builders) do
      for _, o in ipairs(b.orders or {}) do if o.type == "build" and o.key == "powercore" then building = true end end
    end
    local cn = world.map.coreNode
    if not building and cn and not world.map.blocked[cn.y * world.map.w + cn.x] then self.coreClaimed = false end
  end
  for _, b in ipairs(builders) do
    if b.def.domain == "sea" then
      if #b.orders == 0 then self:seaBuilderTask(b) end
    elseif #b.orders == 0 and not (b.key == "commander" and self.cmdMode and self.cmdMode ~= "build")
      and not (b.key == "commander" and self.cmdReserved) then -- (v2: the Commander is wanted at the centre)
      local isCmd = b.key == "commander"
      local task = nil
      local bx, by = self:baseTile()

      -- energy keeps pace with metal (factories eat a lot of energy)
      -- energy only when it's actually short: a full energy bank means metal is the bottleneck
      local needEnergy = (eFuture < mFuture * 5.5 + 6 and tm.energy < tm.eStore * 0.85)
        or (tm.energy < tm.eStore * 0.15 and eFuture < mFuture * 10)
      local p = self.profile
      local hasWater = self.waterTX and (self.waterSize or 0) > 120
      -- Turtles fortify continuously: the target grows with the clock, and every other
      -- builder (plus the Commander) works on it before claiming more metal
      -- (a wall that grows a bit slower than it used to, so the economy behind it keeps up)
      local fortCap = p.fortify and math.min(24, self.diff.turrets + math.floor(math.max(0, t - 240) / 100)) or 0
      self.fortToggle = not self.fortToggle
      local fortifyNow = p.fortify and t > (p.fortifyFrom or 90) and factories >= 1 and turrets + aas < fortCap
        and (isCmd or self.fortToggle) and (tm.metal > 40 or mInc > 7) and not needEnergy
      local cn = world.map.coreNode
      local coreFree = cn and not world.map.blocked[cn.y * world.map.w + cn.x] and not self.coreClaimed
      if factories == 0 and mexes >= 2 and solars >= 1 then
        -- everyone opens with a vehicle plant: it's the only source of constructors
        task = "landfac"
      elseif coreFree and t > 45 and not isCmd and (tm.metal > 60 or mInc > 6)
        and self:threatAt((cn.x + 1) * world.T, (cn.y + 1) * world.T, 450) == 0 then
        -- the Power Core in the middle: worth a constructor's trip
        self.coreClaimed = true
        task = { key = "powercore", tx = cn.x, ty = cn.y }
      elseif fortifyNow then
        self.fortN = (self.fortN or 0) + 1
        task = "turret" -- (Defense Towers hit air too)
        self.fortWhere = (self.fortN % 3 == 0) and "outpost" or "ring"
      elseif needEnergy and solars < 60 then
        task = "solar"
      elseif self.facPerIncome and factories >= 1 and factories < math.min(self.facCap or 10, 1 + math.floor(mInc / self.facPerIncome))
        and (self.lastFacOrder or -99) < t - 10 and t > 60 then
        -- (v2) production keeps pace with income: a plant per facPerIncome metal/s, so the
        -- economy turns into an army instead of sitting full in storage
        self.lastFacOrder = t
        local airShare = p.factoryAirShare or 0.3
        task = (landfacs >= 2 and airfacs < math.max(1, math.floor(landfacs * airShare + 0.5))) and "airfac" or "landfac"
      elseif t > 150 and factories < self.diff.maxFactories + 2 and (self.lastFacOrder or -99) < t - 25
        and (tm.metal > tm.mStore * 0.45 or factories < 1 + math.floor(mInc / 12)) then
        -- production keeps pace with income (about one factory per 12 metal/s), and
        -- metal piling up always means another factory
        -- metal is piling up: more production beats another extractor
        self.lastFacOrder = t
        local airShare = p.factoryAirShare or 0.3
        task = (airfacs > 0 and self.rng:random() >= airShare) and "landfac" or (airfacs == 0 and landfacs >= 2 and "airfac" or "landfac")
      else
        local em = self.diff.expandMul
        local range = isCmd and (t < 240 and 950 or 520) or math.min(2800 * em, 900 + t * 4.5 * em)
        local dp = self:nearestFreeDeposit(b.x, b.y, range)
        if dp and (isCmd or mexes < 30 * em) then
          task = { key = "mex", tx = dp.x, ty = dp.y }
        end
      end
      if not task then
        local wantAA = math.min(6, (enemyAir > 2 and 1 + math.floor(enemyAir / 4) or 0) + (t > 300 and self.diff.aaBonus or 0))
        -- (from level 5 the specialists grab land first: their plant comes once the economy runs)
        local lateSpec = (self.diff.level or 5) >= 5 and (t < (self.specFrom or 200) or mFuture < 14)
        if p.navalFirst and hasWater and yards == 0 and factories >= 1 and mFuture > 4 and not lateSpec then task = "shipyard"
        elseif p.airFirst and airfacs == 0 and factories >= 1 and mFuture > 4 and not lateSpec then task = "airfac"
        elseif landfacs == 0 and factories >= 1 and mFuture > 6 then task = "landfac"
        elseif self.yardFrom and yards == 0 and hasWater and landfacs >= 1 and mFuture > 7 and t > self.yardFrom then task = "shipyard" -- (v2: land and sea at once)
        elseif airfacs == 0 and mFuture > 6.5 and t > (self.specFrom and self.specFrom - 50 or 150) then task = "airfac"
        elseif yards == 0 and hasWater and mFuture > 7.5 and t > (self.specFrom or 200) then task = "shipyard"
        elseif p.harbor and yards == 0 and hasWater and mFuture > 6 and t > 180 then task = "shipyard"
        elseif turrets < self.diff.turrets and t > (self.turretFrom or 160) then task = "turret"
        elseif turrets < self.diff.turrets + wantAA and t > 90 then task = "turret" -- (they shoot aircraft too)
        elseif storages == 0 and t > (self.storageFrom or 300) then task = "storage"
        elseif (factories < self.diff.maxFactories and mFuture > (10 + factories * 4) * (p.factoryEcoMul or 1))
          or (factories < self.diff.maxFactories + 2 and tm.metal > tm.mStore * 0.55 and t > 180) then
          local airShare = p.factoryAirShare or 0.4
          if p.navalFirst and hasWater and self.rng:random() < 0.5 then task = "shipyard"
          else task = (self.rng:random() < airShare) and "airfac" or "landfac" end
        elseif needEnergy == false and eFuture < mFuture * 8 and tm.energy < tm.eStore * 0.5 then
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
          elseif (key == "turret" or key == "aaturret") and p.fortify then
            tx, ty = self:fortSite(key, bx, by)
            self.fortWhere = nil
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
        if os.getenv("PA_ECOLOG") then self.taskLog = self.taskLog or {}; local k2 = key .. (tx and "" or "!FAIL"); self.taskLog[k2] = (self.taskLog[k2] or 0) + 1 end
        if tx then
          world:issue(b, { type = "build", key = key, tx = tx, ty = ty })
          -- extractors: chain the next two nearest free deposits so the builder never idles
          if key == "mex" and not isCmd then
            local lx, ly = world.map:center(tx, ty)
            for _ = 1, 2 do
              local nd = self:nearestFreeDeposit(lx, ly, 700)
              if not nd then break end
              world:issue(b, { type = "build", key = "mex", tx = nd.x, ty = nd.y }, true)
              mexes = mexes + 1; mFuture = mFuture + D.units.mex.income.metal * tm.incomeMul
              lx, ly = world.map:center(nd.x, nd.y)
            end
          end
          -- update counters so the next builder doesn't duplicate
          if key == "landfac" then landfacs = landfacs + 1 end
          if key == "airfac" then airfacs = airfacs + 1 end
          if key == "shipyard" then yards = yards + 1 end
          if key == "solar" then solars = solars + 1; eFuture = eFuture + D.units.solar.income.energy * tm.incomeMul end
          if key == "mex" then mexes = mexes + 1; mFuture = mFuture + D.units.mex.income.metal * tm.incomeMul end
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

-- Turtle tower placement: a ring around the whole base (heavier toward the enemy), and
-- every third one guarding an outlying extractor that has no tower near it yet
function AI:fortSite(key, bx, by)
  local world = self.world
  local map = world.map
  if self.fortWhere == "outpost" then
    local towers = self:mine(function(e) return e.key == "turret" or e.key == "aaturret" end)
    local best, bd
    for _, m in ipairs(self:mine(function(e) return e.key == "mex" and e.built >= 1 end)) do
      local d = U.dist(m.x, m.y, self.baseX, self.baseY)
      if d > 500 then
        local covered = false
        for _, tw in ipairs(towers) do if U.dist2(tw.x, tw.y, m.x, m.y) < 260 * 260 then covered = true; break end end
        if not covered and (not bd or d < bd) then best, bd = m, d end
      end
    end
    if best then
      local mtx, mty = map:tileAt(best.x, best.y)
      -- on the side facing the enemy
      local tx, ty = self:findSite(key, math.floor(mtx + self.dirX * 2), math.floor(mty + self.dirY * 2), 1, 5)
      if tx then return tx, ty end
    end
  end
  local base = math.atan2(self.dirY, self.dirX)
  local a = self.rng:random() < 0.65 and base + (self.rng:random() - 0.5) * 3.0 or self.rng:random() * math.pi * 2
  local r = self.rng:random(6, 12)
  return self:findSite(key, math.floor(bx + math.cos(a) * r), math.floor(by + math.sin(a) * r), 0, 6)
end

-- Sea Constructor: claim rich offshore deposits, then add tidal power near home water
function AI:seaBuilderTask(b)
  local world = self.world
  local dp = self:nearestFreeDeposit(b.x, b.y, 4000, "sea")
  if dp then
    world:issue(b, { type = "build", key = "mex", tx = dp.x, ty = dp.y })
    return
  end
  -- a Sea Battery or two guarding our water (and our offshore extractors)
  local bats = self:countPlanned("seabattery")
  local wantBats = math.min(4, 1 + math.floor(world.time / 300)) + (self.profile.navalFirst and 1 or 0)
  if self.waterTX and bats < wantBats and world.teams[self.team].mIncome > 12 then
    local cx, cy = self.waterTX, self.waterTY
    -- prefer a spot near one of our offshore extractors
    local mexes = self:mine(function(e) return e.key == "mex" and e.mods and e.built >= 1 end)
    if #mexes > 0 then
      local m = mexes[self.rng:random(#mexes)]
      cx, cy = world.map:tileAt(m.x, m.y)
    end
    local tx, ty = self:findSite("seabattery", cx, cy, 1, 8)
    if tx then
      world:issue(b, { type = "build", key = "seabattery", tx = tx, ty = ty })
      return
    end
  end
  local tidals = self:countPlanned("tidal")
  if self.waterTX and tidals < math.min(14, 3 + math.floor(world.time / 150)) then
    local tx, ty = self:findSite("tidal", self.waterTX, self.waterTY, 1, 12)
    if tx then
      world:issue(b, { type = "build", key = "tidal", tx = tx, ty = ty })
      return
    end
  end
  local hurt = self:findDamaged(b)
  if hurt then world:issue(b, { type = "assist", target = hurt }) end
end

---------------------------------------------------------------------------
-- Production

function AI:pickUnit(f)
  local world = self.world
  local t = world.time
  local rng = self.rng
  local builders = self:countPlanned("builder") + self:queued("builder")
  -- expand early: a third constructor right away, then one more every 2.5 minutes
  -- (Turtles get extra builders for their walls through builderBonus but expand slowly)
  local lvl = self.diff.level or 5
  -- better players expand much faster (a fourth constructor right away, then one every 100 s)
  local wantBuilders = (lvl >= 5 and 4 + math.floor(t / 100) or 3 + math.floor(t / 150)) + self.diff.builderBonus
  wantBuilders = math.min(wantBuilders, (lvl >= 5 and 8 or 7) + self.diff.builderBonus)
  local enemyAir = self:enemyAirCount()
  local enemySubs = self:enemyCount("sub")
  local enemyShips = self:enemyCount("sea") + enemySubs
  if f.key == "landfac" then
    if builders < wantBuilders and f == self:firstFactory("landfac") then return "builder" end
    -- keep the hunter pack topped up
    if self.huntersWanted and t >= self.huntersFrom - 60 then
      local have = 0
      for _, u in ipairs(self.hunters) do if u.alive then have = have + 1 end end
      if have + self:queued("scout") < self.huntersWanted and self:countPlanned("scout") < self.huntersWanted + 3 then return "scout" end
    end
    -- a Scout to spot for every few artillery (when this player knows the trick)
    if self.spotChance > 0 then
      local arty = self:countPlanned("artillery")
      local want = arty >= 2 and math.ceil(arty / 3) or 0
      local have = 0
      for u in pairs(self.spotters) do if u.alive then have = have + 1 end end
      if have + self:queued("scout") < want and rng:random() < self.spotChance then return "scout" end
    end
    local myFlak = self:countPlanned("flak") + self:queued("flak")
    local w = {
      tank = 50,
      artillery = t > 240 and 18 or 4,
      scout = t < 240 and 14 or 5,
      flak = enemyAir > 0 and math.max(0, enemyAir * 6 - myFlak * 6) or 0,
    }
    -- (v2) a standing share of flak, air or no air: when the gunships come it's too late to start
    if self.flakShare and t > 75 then
      local fighters = self:countPlanned("tank") + self:countPlanned("artillery") + self:countPlanned("scout")
      if myFlak < math.max(1, math.floor(fighters * self.flakShare + 0.5)) then w.flak = math.max(w.flak, 30) end
    end
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
    local seaB = self:countPlanned("seabuilder") + self:queued("seabuilder")
    local wantSeaB = (self.profile.navalFirst and 2 or 1) + (t > 600 and 1 or 0)
    if seaB < wantSeaB then return "seabuilder" end
    local ships = self:countPlanned("boat") + self:countPlanned("destroyer") + self:countPlanned("sub")
      + self:queued("boat") + self:queued("destroyer") + self:queued("sub")
    local bships = self:countPlanned("battleship") + self:queued("battleship")
    local tm = world.teams[self.team]
    local harbor = self.profile.harbor
    local maxBB = harbor and math.min(4, 1 + math.floor(math.max(0, t - 360) / 240)) or (self.profile.navalFirst and 3 or 1)
    local canBB = t > (self.bbFrom or (harbor and 360 or 420)) and tm.mIncome > (self.bbIncome or (harbor and 18 or 24)) and bships < maxBB
      and self.diff.level and self.diff.level >= 3
    -- Turtles turn their home water into a fortress: battleships first, a few escorts against subs
    if harbor and canBB then return "battleship" end
    -- (v2) a fleet sized to what the water can do (see AI2:fleetPlan)
    if self.fleetPlan then return self:fleetPlan(t, canBB) end
    if not self.navalReach and ships >= 5 + enemyShips then
      if canBB and bships == 0 then return "battleship" end -- a harbor guard
      return nil
    end
    local enemyBB = 0
    for _, e in ipairs(world.entities) do
      if e.alive and e.key == "battleship" and self:isHostile(e.team) then enemyBB = enemyBB + 1 end
    end
    return self:pick({
      boat = 35,
      destroyer = 30 + (enemySubs > 0 and 30 or 0),
      sub = (enemyShips > 0 and 35 or 15) + enemyBB * 25,
      battleship = canBB and 14 or 0,
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
-- Battleships: siege from the water nearest the enemy when we have a route and an escort,
-- otherwise guard our own harbor. Up to 3 nearby warships stay with each one.
function AI:thinkBattleships(army)
  local world = self.world
  local ctl = {}
  local bbs = {}
  for _, u in ipairs(army) do if u.key == "battleship" then bbs[#bbs + 1] = u; ctl[u] = true end end
  if #bbs == 0 then return ctl end
  self.bbTimer = (self.bbTimer or 0) - 1
  local reorder = self.bbTimer <= 0
  if reorder then self.bbTimer = 8 end
  for _, b in ipairs(bbs) do
    -- escorts: nearest free destroyers / boats
    local esc = {}
    -- patrol boats first (their flak is what keeps bombers off it), then destroyers
    for _, want in ipairs({ "boat", "destroyer" }) do
      for _, u in ipairs(army) do
        if #esc < 3 and not ctl[u] and u.key == want and not self.wave[u] and not (self.reserved and self.reserved[u])
          and U.dist(u.x, u.y, b.x, b.y) < 1400 then
          esc[#esc + 1] = u; ctl[u] = true
        end
      end
    end
    if reorder then
      local tx, ty
      if b.hp < b.maxhp * 0.4 and self.waterTX then
        tx, ty = world.map:center(self.waterTX, self.waterTY)
        world:issue(b, { type = "retreat", x = tx, y = ty })
      else
        local siege = self.navalReach and (#esc >= 2 or self.profile.navalFirst) and not self.profile.harbor
        if self.bbParkSpot then
          -- (v2) a fixed firing position: its own water nearest the centre
          local px, py = self:bbParkSpot(b)
          if px then tx, ty = px, py; siege = false end
        end
        if siege then
          tx, ty = self:waterNear(self.enemyX, self.enemyY, 30)
        end
        if not tx and self.profile.harbor then
          -- harbor guard: park as close to the base as the water allows, spread out so the
          -- 1300 range covers the base and every approach
          local k = 0
          for i, o in ipairs(bbs) do if o == b then k = i end end
          local a = math.atan2(self.dirY, self.dirX) + (k - 1) * 1.3
          tx, ty = self:waterNear(self.baseX + math.cos(a) * 250, self.baseY + math.sin(a) * 250, 25)
        end
        if not tx then
          tx, ty = self:waterNear(self.baseX + self.dirX * 500, self.baseY + self.dirY * 500, 20)
        end
        if tx and U.dist(b.x, b.y, tx, ty) > 200 then
          world:issue(b, { type = "amove", x = tx, y = ty })
        end
      end
      for i, u in ipairs(esc) do
        if U.dist(u.x, u.y, b.x, b.y) > 220 then
          local a = i * 2.1
          world:issue(u, { type = "amove", x = b.x + math.cos(a) * 110, y = b.y + math.sin(a) * 110 })
        end
      end
    end
  end
  return ctl
end

-- Any enemy battleship near our side is a priority target: send aircraft and subs at it
function AI:huntBattleships(army)
  local world = self.world
  self.huntTimer = (self.huntTimer or 0) - 1
  if self.huntTimer > 0 then return end
  self.huntTimer = 12
  local target, bd
  for _, e in ipairs(world.entities) do
    if e.alive and e.key == "battleship" and self:isHostile(e.team) then
      local d = U.dist(e.x, e.y, self.baseX, self.baseY)
      if d < 3200 and (not bd or d < bd) then target, bd = e, d end
    end
  end
  if not target then return end
  local sent = 0
  for _, u in ipairs(army) do
    if sent >= 10 then break end
    local ok = u.key == "bomber" or u.key == "gunship" or (u.key == "sub" and self.seaSet)
    if ok and not (self.alienSquad and self.alienSquad[u]) and not u.disarmed then
      world:issue(u, { type = "attack", target = target })
      self.wave[u] = true
      sent = sent + 1
    end
  end
end

function AI:pickTarget(domain)
  local world = self.world
  local best, bd, bx, by
  for _, e in ipairs(world.entities) do
    if e.alive and self:isHostile(e.team) and ((e.def.building and self.known[e]) or (domain == "sea" and (e.def.domain == "sea" or e.def.domain == "sub") and self.known[e])) then
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
  -- nothing known yet: go look where the enemy most likely is
  if self.targetTeam and self.foundBase[self.targetTeam] then
    local tm = world.teams[self.targetTeam]
    return tm.startX, tm.startY
  end
  return self:guessBase()
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
    if e.alive and self:isHostile(e.team) and (e.key == "mex" or e.key == "solar") and self.known[e] then
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
  Tel.note(world, "raid", self.team, string.format("raid on a %s with %d units", best.key, #squad))
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

-- Hunter pack: 2-4 scouts that roam for exposed constructors, extractors and power,
-- dodge anything that can fight back, and regroup at home when chased off.
function AI:thinkHunters(army, inWave)
  local want = self.huntersWanted
  local world = self.world
  if not want or world.time < self.huntersFrom then return end
  -- keep the pack: survivors plus fresh scouts
  local pack = {}
  for _, u in ipairs(self.hunters) do if u.alive then pack[#pack + 1] = u else self.isHunter[u] = nil end end
  for _, u in ipairs(army) do
    if #pack >= want then break end
    if u.key == "scout" and not self.isHunter[u] then
      pack[#pack + 1] = u
      self.isHunter[u] = true
      self.wave[u] = nil
    end
  end
  self.hunters = pack
  for _, u in ipairs(pack) do inWave[u] = true end
  if #pack < math.min(2, want) then return end
  local cx, cy, str = 0, 0, 0
  for _, u in ipairs(pack) do cx, cy, str = cx + u.x, cy + u.y, str + 35 * (u.hp / u.maxhp) end
  cx, cy = cx / #pack, cy / #pack
  local t = world.time
  self:updateKnowledge()
  -- chased? run home and regroup
  local danger = self:strengthNear(cx, cy, 380, true)
  if danger > str * 1.3 then
    if not self.huntFlee or t > self.huntFlee then
      self.huntFlee = t + 12
      self.prey = nil
      for _, u in ipairs(pack) do world:issue(u, { type = "move", x = self.stageX + self.rng:random(-60, 60), y = self.stageY + self.rng:random(-60, 60) }) end
    end
    return
  end
  if self.huntFlee and t < self.huntFlee then return end
  -- still a good target?
  local prey = self.prey
  if prey and (not prey.alive or self:strengthNear(prey.x, prey.y, 380, true) > str * 0.8) then prey = nil end
  if not prey and t > (self.nextPreyLook or 0) then
    self.nextPreyLook = t + 2
    local best, bs
    for _, e in ipairs(world.entities) do
      if e.alive and self:isHostile(e.team) and e.key ~= "commander" and e.built >= 1 then
        local v = (e.def.builds and not e.def.factory and not e.def.building and e.def.domain == "land"
            and U.dist2(cx, cy, e.x, e.y) < 900 * 900) and 3
          or (e.key == "mex" and self.known[e] and 2) or (e.key == "solar" and self.known[e] and 1) or nil
        if v and world:layerOf(pack[1]) and world.map:canReach("land", cx, cy, e.x, e.y, 120) then
          local tt = world.teams[e.team]
          local dBase = tt.startX and U.dist(e.x, e.y, tt.startX, tt.startY) or 9999
          if dBase > 650 then
            local score = v * 700 - U.dist(cx, cy, e.x, e.y) * 0.5 + math.min(dBase, 1500) * 0.3
            if (not bs or score > bs) and self:strengthNear(e.x, e.y, 380, true) <= str * 0.6 then best, bs = e, score end
          end
        end
      end
    end
    prey = best
  end
  self.prey = prey
  if prey then
    -- chase: refresh orders as the prey moves
    if t > (self.preyOrderT or 0) then
      self.preyOrderT = t + 1.5
      for _, u in ipairs(pack) do world:issue(u, { type = "amove", x = prey.x + self.rng:random(-20, 20), y = prey.y + self.rng:random(-20, 20) }) end
    end
  else
    -- nothing to hunt: go looking (unchecked corners first, then deposits toward the enemy)
    local idle = true
    for _, u in ipairs(pack) do if #u.orders > 0 then idle = false end end
    if idle then
      local tx, ty
      local cc = self:candidateCorners()
      if #cc > 0 then
        table.sort(cc, function(a, b) return U.dist2(cx, cy, a.x, a.y) < U.dist2(cx, cy, b.x, b.y) end)
        tx, ty = cc[1].x, cc[1].y
      else
        local map = world.map
        for _ = 1, 8 do
          local dp = map.deposits[self.rng:random(#map.deposits)]
          local x, y = map:center(dp.x, dp.y)
          if U.dist(x, y, self.baseX, self.baseY) > U.dist(x, y, self.enemyX, self.enemyY) * 0.8 then tx, ty = x, y; break end
        end
      end
      if tx then
        for _, u in ipairs(pack) do world:issue(u, { type = "amove", x = tx + self.rng:random(-40, 40), y = ty + self.rng:random(-40, 40) }) end
      end
    end
  end
end

-- Raiders on our constructors or extractors away from home: send a few idle units to chase them off
function AI:defendOutposts(army, inWave)
  local world = self.world
  if (self.diff.level or 5) < 4 then return end
  local t = world.time
  if t < (self.nextOutpostCheck or 0) then return end
  self.nextOutpostCheck = t + 2
  self.outpostResp = self.outpostResp or {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == self.team and (e.key == "mex" or e.key == "solar" or (e.def.builds and not e.def.factory and e.key ~= "commander"))
      and U.dist(e.x, e.y, self.baseX, self.baseY) > 450 then
      local key = math.floor(e.x / 400) * 1000 + math.floor(e.y / 400)
      if t > (self.outpostResp[key] or 0) then
        local threat = self:strengthNear(e.x, e.y, 330, true)
        if threat > 0 and threat < 600 then
          -- pick the closest idle ground units, enough to outgun the raiders
          local cands = {}
          for _, u in ipairs(army) do
            if not inWave[u] and not self.isHunter[u] and u.def.domain == "land" and #u.orders <= 1 then
              cands[#cands + 1] = { u = u, d = U.dist(u.x, u.y, e.x, e.y) }
            end
          end
          table.sort(cands, function(a, b) return a.d < b.d end)
          local sent, power = 0, 0
          for _, cnd in ipairs(cands) do
            if power >= threat * 1.5 or sent >= 4 or cnd.d > 1600 then break end
            world:issue(cnd.u, { type = "amove", x = e.x, y = e.y })
            inWave[cnd.u] = true
            sent, power = sent + 1, power + (cnd.u.def.cost and cnd.u.def.cost.metal or 50)
          end
          if sent > 0 then self.outpostResp[key] = t + 15 end
        end
      end
    end
  end
end

-- Artillery only fires at full range on what a friend can see. Spotter Scouts keep the
-- nearest enemy at the edge of their sight, out of its reach, so the guns can shell it.
function AI:thinkSpotters(army, inWave)
  local world = self.world
  for u in pairs(self.spotters) do if not u.alive then self.spotters[u] = nil end end
  if self.spotChance <= 0 then return end
  -- the guns that are out on the attack
  local guns, gx, gy = 0, 0, 0
  for _, u in ipairs(army) do
    if u.key == "artillery" and inWave[u] then guns = guns + 1; gx, gy = gx + u.x, gy + u.y end
  end
  local n = 0
  for _ in pairs(self.spotters) do n = n + 1 end
  -- recruit idle scouts (not hunters) when this wave's guns get spotters
  if guns > 0 and self.waveSpots then
    local want = math.max(1, math.ceil(guns / 3))
    for _, u in ipairs(army) do
      if n >= want then break end
      if u.key == "scout" and not self.spotters[u] and not self.isHunter[u] then
        self.spotters[u] = true; n = n + 1
        self.wave[u] = nil; inWave[u] = nil
      end
    end
  end
  if guns == 0 then
    -- no guns out: spotters wait at the staging point
    for u in pairs(self.spotters) do
      if #u.orders == 0 and U.dist(u.x, u.y, self.stageX, self.stageY) > 300 then
        world:issue(u, { type = "move", x = self.stageX + self.rng:random(-60, 60), y = self.stageY + self.rng:random(-60, 60) })
      end
    end
    return
  end
  gx, gy = gx / guns, gy / guns
  if os.getenv("PA_SPOTDBG") and math.floor(world.time) % 20 == 0 and self.spotDbg ~= math.floor(world.time) then
    self.spotDbg = math.floor(world.time)
    print("SPOT", math.floor(world.time), self.team, "guns", guns, "spotters", n, "waveSpots", tostring(self.waveSpots))
  end
  for u in pairs(self.spotters) do
    u.holdFire = true
    -- the nearest enemy to the guns (anything they could shell)
    local best, bd
    for _, o in ipairs(world.entities) do
      if o.alive and o.team and self:isHostile(o.team) and o.def.domain ~= "air" then
        local d = U.dist(gx, gy, o.x, o.y)
        if d < 900 and (not bd or d < bd) then best, bd = o, d end
      end
    end
    local sight = world:sightOf(u)
    local x, y
    if best then
      -- stand back from it, on the guns' side, just inside our sight and outside its reach
      local reach = best.def.weapon and world:rangeOf(best) or 0
      local stand = math.max(reach + 40, math.min(sight - 40, 380))
      local dx, dy = U.norm(gx - best.x, gy - best.y)
      x, y = best.x + dx * stand, best.y + dy * stand
    else
      -- lead the guns toward their target
      local tx, ty = self:pickTarget("land")
      if tx then
        local dx, dy = U.norm(tx - gx, ty - gy)
        x, y = gx + dx * 220, gy + dy * 220
      end
    end
    if x then
      local o = u.orders[1]
      if not o or o.type ~= "move" or U.dist(o.x, o.y, x, y) > 60 then world:issue(u, { type = "move", x = x, y = y }) end
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
  -- battleships (and their escorts) follow their own orders
  local navalCtl = self:thinkBattleships(army)
  if next(navalCtl) then
    local rest = {}
    for _, u in ipairs(army) do if not navalCtl[u] then rest[#rest + 1] = u end end
    army = rest
  end
  self:huntBattleships(army)
  -- units on a special duty (v2's flak escort for the Commander) stay out of the waves
  if self.reserved and next(self.reserved) then
    local rest = {}
    for _, u in ipairs(army) do if not self.reserved[u] then rest[#rest + 1] = u end end
    army = rest
  end

  -- clean wave set
  local inWave = {}
  for u in pairs(self.wave) do
    if u.alive then inWave[u] = true end
  end
  self.wave = inWave

  self:updateKnowledge()
  self:thinkSpotters(army, inWave)
  self:thinkHunters(army, inWave)
  self:defendOutposts(army, inWave)

  -- scouts wander to find things
  for _, u in ipairs(army) do
    if u.key == "scout" and #u.orders == 0 and not inWave[u] and not self.isHunter[u] and not self.spotters[u] then
      local map = world.map
      local dp = map.deposits[self.rng:random(#map.deposits)]
      local x, y = map:center(dp.x, dp.y)
      -- first find the enemy: the nearest corner nobody has checked yet
      local cc = self:candidateCorners()
      if #cc > 0 then
        table.sort(cc, function(a, b) return U.dist2(u.x, u.y, a.x, a.y) < U.dist2(u.x, u.y, b.x, b.y) end)
        x, y = cc[1].x, cc[1].y
      end
      world:issue(u, { type = "amove", x = x, y = y })
      inWave[u] = true
      self.wave[u] = true
    end
  end

  -- pull badly damaged units home to repair (weapons off, faster)
  if self.diff.retreat then
    for _, u in ipairs(army) do
      local o = u.orders[1]
      -- (v2: how well it pulls hurt units out follows its level - fleeAt scales the threshold,
      -- fleeSkill is the chance a given unit gets noticed at all, rolled once per unit)
      local at = (u.general and 0.5 or 0.3) * (self.fleeAt or 1)
      if u.fleeRoll == nil and self.fleeSkill then u.fleeRoll = self.rng:random() < self.fleeSkill end
      if u.hp < u.maxhp * at and (not o or o.type ~= "retreat") and u.key ~= "scout" and u.fleeRoll ~= false
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
    self.waveSpots = self.rng:random() < self.spotChance
    self.waves = self.waves + 1
    self.lastWave = t
    do
      local comp = {}
      for _, u in ipairs(home) do comp[u.key] = (comp[u.key] or 0) + 1 end
      local ks = {}
      for k, n in pairs(comp) do ks[#ks + 1] = n .. " " .. k end
      table.sort(ks)
      Tel.note(world, "wave", self.team, string.format("wave %d: %d units (%s)%s", self.waves, #home, table.concat(ks, ", "),
        self.waveSpots and ", with spotters" or ""))
    end
    -- better players march the land army together (slowest pace) until first contact
    local march
    if ((world.kiteSkill or {})[self.team] or 0) >= 0.4 then
      for _, u in ipairs(home) do
        if u.def.domain == "land" then
          local sp = world:speedOf(u)
          march = march or { speed = sp }
          march.speed = math.min(march.speed, sp)
        end
      end
    end
    for _, u in ipairs(home) do
      local dom = (u.def.domain == "sea" or u.def.domain == "sub") and "sea" or u.def.domain
      local tx, ty = self:pickTarget(dom)
      if tx then
        local j = dom == "sea" and 20 or 80
        world:issue(u, { type = "amove", x = tx + self.rng:random(-j, j), y = ty + self.rng:random(-j, j),
          march = dom == "land" and march or nil })
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
