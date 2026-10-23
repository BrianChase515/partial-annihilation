-- Computer Commanders in the Arena: hold a lane behind the creep wave, stay out of
-- enemy tower range unless creeps are tanking, go home to heal, dive weak enemy
-- Commanders (with allies), push towers, and use skills sensibly.
local U = require("src.util")
local Map = require("src.map")
local ARENA = require("src.arena")

local AI = {}
AI.__index = AI

function AI.new(world, team, level, opts)
  local self = setmetatable({}, AI)
  self.world = world
  self.team = team
  self.level = math.max(1, math.min(10, level or 5))
  self.rng = love.math.newRandomGenerator(team * 977 + (world.map.seed % 100000))
  self.think = 0
  -- reaction time and boldness by difficulty
  self.thinkEvery = math.max(0.25, 1.1 - self.level * 0.08)
  self.skillChance = 0.35 + self.level * 0.065
  self.brave = 0.8 + self.level * 0.04
  local st = world.arena
  self.side = st.teamSide[team]
  -- lane: spread the side's Commanders over the lanes
  local idx = 1
  for i, t in ipairs(st.sideTeams[self.side]) do if t == team then idx = i end end
  if st.ffa then
    self:pickLane()
  else
    local order = #st.sideTeams[self.side] == 1 and { "mid" } or { "top", "bot", "mid" }
    if world.map.jungleT and not world.map.lanesByName.mid then
      order = #st.sideTeams[self.side] == 1 and { "top" } or { "top", "bot" }
      if idx == 3 then self.role = "jungle" end
    end
    local name = opts and opts.lane or order[(idx - 1) % #order + 1]
    self.laneObj = world.map.lanesByName[name] or world.map.lanes[(idx - 1) % #world.map.lanes + 1]
    self.lane = self.laneObj.id
  end
  self.profileName = "Arena " .. (world.teams[team].commander.class or "")
  self.mode = "lane"
  return self
end

function AI:commander() return self.world.teams[self.team].commander end

-- free-for-all: push the lane toward a living rival, preferring the one with the fewest towers left
function AI:pickLane()
  local w = self.world
  local st = w.arena
  local best, bs
  for _, L in ipairs(w.map.lanes) do
    if L.a == self.side or L.b == self.side then
      local other = L.a == self.side and L.b or L.a
      if not st.sideDead[other] then
        local towers = 0
        for _, sx in ipairs(st.structures) do if sx.alive and sx.side == other then towers = towers + 1 end end
        local score = towers + self.rng:random() * 2.5
        if not bs or score < bs then best, bs = L, score end
      end
    end
  end
  self.laneObj = best or self.laneObj or w.map.lanes[1]
  self.lane = self.laneObj.id
  self.lanePicked = w.time
end

-- lane route from our base toward the enemy
function AI:route()
  local L = self.laneObj
  local r = {}
  if L.a == self.side then for i = 1, #L.pts do r[i] = L.pts[i] end
  else for i = #L.pts, 1, -1 do r[#r + 1] = L.pts[i] end end
  return r
end

-- how far along our lane (0..1) a world point is
function AI:laneProgress(x, y)
  local map = self.world.map
  local r = self:route()
  local best, bf = nil, 0
  for f = 0, 1, 0.02 do
    local px, py = Map.polyAt(r, f)
    local wx, wy = map:center(px, py)
    local d = U.dist(wx, wy, x, y)
    if not best or d < best then best, bf = d, f end
  end
  return bf, best
end

function AI:lanePoint(f)
  local map = self.world.map
  local px, py = Map.polyAt(self:route(), math.max(0, math.min(1, f)))
  return map:center(px, py)
end

function AI:pickOffer(c)
  local offer = c.offers[1]
  if not offer then return end
  -- prefer damage/defense skills; otherwise random
  local pick = 1
  if #offer == 2 then
    local function val(u)
      if u.skill then
        local s = ARENA.SKILLS[u.key]
        local v = 1
        for _, tg in ipairs(s.tags) do if tg == "dmg" or tg == "cc" then v = v + 1 end end
        return v + self.rng:random()
      end
      return 1 + self.rng:random()
    end
    pick = val(offer[1]) >= val(offer[2]) and 1 or 2
  end
  self.world:chooseUpgrade(c, pick)
end

-- strength of armed things around a point (hp-weighted)
function AI:strength(x, y, r, hostile)
  local w = self.world
  local s = 0
  w:query(x, y, r + 30, function(o)
    if o.alive and not o.neutral and o.def.weapon and U.dist(x, y, o.x, o.y) < r
      and not (o.passive and not (o.aggro and next(o.aggro))) then
      local isHostile = w:hostile(o.team, self.team)
      if isHostile == hostile then
        local v = o.hp / 100
        if o.key == "commander" then v = v * 2.2 end
        if o.def.building then v = v * 1.6 end
        s = s + v
      end
    end
  end)
  return s
end

function AI:nearestEnemyStructure(c)
  local w = self.world
  local best, bd
  for _, s in ipairs(w.arena.structures) do
    if s.alive and w:hostile(s.team, self.team) then
      local d = U.dist(c.x, c.y, s.x, s.y)
      if not bd or d < bd then best, bd = s, d end
    end
  end
  return best, bd
end

function AI:towerThreat(x, y)
  local w = self.world
  for _, s in ipairs(w.arena.structures) do
    if s.alive and w:hostile(s.team, self.team) and U.dist(x, y, s.x, s.y) < s.def.weapon.range + 40 then return s end
  end
  return nil
end

function AI:creepsNear(x, y, r, hostile)
  local w = self.world
  local n = 0
  w:query(x, y, r + 20, function(o)
    if o.alive and (o.creep or o.summon) and U.dist(x, y, o.x, o.y) < r and (w:hostile(o.team, self.team) == hostile) then n = n + 1 end
  end)
  return n
end

-- best point to drop an area skill: the densest enemy cluster within reach
function AI:clusterTarget(c, reach, radius)
  local w = self.world
  local best, bn, bx, by = nil, 0, nil, nil
  local list = ARENA.hostiles(w, c, c.x, c.y, reach, false)
  for _, o in ipairs(list) do
    local n = 0
    for _, p in ipairs(list) do
      if U.dist(o.x, o.y, p.x, p.y) < radius then n = n + (p.key == "commander" and 3 or 1) end
    end
    if n > bn then best, bn, bx, by = o, n, o.x, o.y end
  end
  return bx, by, bn
end

function AI:useSkills(c, enemyC, danger)
  local w = self.world
  if self.rng:random() > self.skillChance then return end
  for slot = 1, 4 do
    local sk = c.skills[slot]
    if sk and w.time >= sk.readyAt then
      local def = ARENA.SKILLS[sk.key]
      local tags = {}
      for _, tg in ipairs(def.tags) do tags[tg] = true end
      local tx, ty, go
      local hpf = c.hp / c.maxhp
      if tags.escape and danger and hpf < 0.4 then
        local hx, hy = c.respawnX, c.respawnY
        tx, ty, go = hx, hy, true
      elseif tags.heal and hpf < 0.55 then
        go = true
      elseif tags.defend and danger then
        local ex, ey, n = self:clusterTarget(c, 260, 160)
        go = n >= 2 or (enemyC and U.dist(c.x, c.y, enemyC.x, enemyC.y) < 260)
        tx, ty = ex, ey
      elseif tags.buff and (danger or (enemyC and U.dist(c.x, c.y, enemyC.x, enemyC.y) < 500)) then
        go = true
      elseif tags.summon then
        local _, _, n = self:clusterTarget(c, 500, 200)
        go = n >= 2 or tags.siege
        tx, ty = self:clusterTarget(c, 450, 200)
        if not tx then tx, ty = c.x, c.y end
      elseif tags.cc and enemyC and U.dist(c.x, c.y, enemyC.x, enemyC.y) < (def.range > 0 and def.range or 220) then
        tx, ty, go = enemyC.x, enemyC.y, true
      elseif tags.dmg then
        local reach = def.aim == "self" and def.range or def.range
        local ex, ey, n = self:clusterTarget(c, reach, def.aim == "self" and reach or 150)
        local need = tags.ult and 4 or 2
        if enemyC and U.dist(c.x, c.y, enemyC.x, enemyC.y) < reach then
          ex, ey, n = enemyC.x, enemyC.y, need
        end
        if ex and n >= need then tx, ty, go = ex, ey, true end
        -- siege ultimates also go on towers when pushing
        if not go and tags.siege then
          local s, d = self:nearestEnemyStructure(c)
          if s and d < reach and not s.protected then tx, ty, go = s.x, s.y, true end
        end
      end
      if go and not (tags.move and not tags.escape and def.aim == "point" and not tx) then
        if ARENA.useSkill(w, c, slot, tx or c.x, ty or c.y) then return end
      end
    end
  end
end

-- Jungle maps: take shrines, gang up on the Colossus, farm camps (the jungler lives there)
function AI:enemyCommandersNear(x, y, r)
  local w, n = self.world, 0
  for t = 1, w.np do
    local o = w.teams[t].commander
    if o and o.alive and w:hostile(t, self.team) and U.dist(o.x, o.y, x, y) < r then n = n + 1 end
  end
  return n
end

function AI:campToFarm(c, reach)
  local j = self.world.arena.jungle
  local best, bd
  for _, cp in ipairs(j.camps) do
    local alive = 0
    for _, u in ipairs(cp.units) do if u.alive then alive = alive + 1 end end
    if alive > 0 then
      local d = U.dist(c.x, c.y, cp.x, cp.y)
      -- big camps once we can take them
      if cp.kind == "big" and (c.clevel or 0) < 4 then d = d + 2000 end
      if d < reach and self:enemyCommandersNear(cp.x, cp.y, 600) == 0 and (not bd or d < bd) then best, bd = cp, d end
    end
  end
  return best
end

function AI:jungleThink(c, hpf, enemyC, danger)
  local w = self.world
  local st = w.arena
  local j = st.jungle
  local t = w.time
  -- 1. the Colossus: when the side is strong enough, everyone nearby piles on
  local boss = j.boss
  if boss and boss.alive then
    j.bossCall = j.bossCall or {}
    local lv, n = 0, 0
    for _, tt in ipairs(st.sideTeams[self.side]) do
      local a = w.teams[tt].commander
      if a and a.alive then lv = lv + (a.clevel or 0); n = n + 1 end
    end
    if not j.bossCall[self.side] and n >= 2 and lv >= 6 * n and lv >= 12 and self.level >= 4 then j.bossCall[self.side] = t end
    local call = j.bossCall[self.side]
    if call and t - call < 60 and hpf > 0.5 and U.dist(c.x, c.y, boss.x, boss.y) < 2400 then
      if not (c.orders[1] and c.orders[1].type == "attack" and c.orders[1].target == boss) then
        w:issue(c, { type = "attack", target = boss })
      end
      self.mode = "boss"
      return true
    end
  elseif j.bossCall then j.bossCall[self.side] = nil end
  -- 2. shrines nobody is contesting
  for _, sh in ipairs(j.shrines) do
    local d = U.dist(c.x, c.y, sh.x, sh.y)
    local reach = self.role == "jungle" and 1400 or 750
    sh.claim = sh.claim or {}
    local cl = sh.claim[self.side]
    local mine = not cl or cl.team == self.team or t - cl.t > 6
    if sh.owner ~= self.side and t >= sh.lockUntil - 5 and d < reach and hpf > 0.5 and not danger and mine
      and self:enemyCommandersNear(sh.x, sh.y, 650) == 0 then
      sh.claim[self.side] = { team = self.team, t = t }
      if d > 90 then w:issue(c, { type = "move", x = sh.x + self.rng:random(-40, 40), y = sh.y + self.rng:random(-40, 40), arrive = 40 }) end
      self.mode = "shrine"
      return true
    end
  end
  -- 3. camps: the jungler's job; laners grab one now and then when it's close
  local farm = self.role == "jungle" or (self.rng:random() < 0.25 and hpf > 0.7)
  if farm and hpf > 0.45 then
    local cp = self:campToFarm(c, self.role == "jungle" and 3000 or 650)
    if cp then
      local tgt
      for _, u in ipairs(cp.units) do if u.alive and (not tgt or u.hp < tgt.hp) then tgt = u end end
      if tgt and not (c.orders[1] and c.orders[1].type == "attack" and c.orders[1].target == tgt) then
        w:issue(c, { type = "attack", target = tgt })
      end
      self.mode = "camp"
      return true
    end
  end
  if self.role == "jungle" then
    -- nothing to farm: help the lane with the closest enemy Commander
    if enemyC then return false end
    local L = w.map.lanes[self.rng:random(#w.map.lanes)]
    local x, y = Map.polyAt(L.pts, 0.5)
    local wx, wy = w.map:center(x, y)
    if #c.orders == 0 then w:issue(c, { type = "amove", x = wx, y = wy, arrive = 80 }) end
    return true
  end
  return false
end

function AI:update(dt)
  local w = self.world
  if w.over then return end
  local c = self:commander()
  if not c then return end
  self.think = self.think - dt
  if self.think > 0 then return end
  self.think = self.thinkEvery * (0.8 + self.rng:random() * 0.4)
  if not c.alive then self.mode = "lane"; return end
  if w.arena.ffa then
    local other = self.laneObj.a == self.side and self.laneObj.b or self.laneObj.a
    if w.arena.sideDead[other] or w.time - (self.lanePicked or 0) > 90 then self:pickLane() end
  end
  if #c.offers > 0 then self:pickOffer(c) end

  local hpf = c.hp / c.maxhp
  local core = w.arena["core" .. self.side]
  local homeX, homeY = core.x, core.y
  local atHome = U.dist(c.x, c.y, homeX, homeY) < ARENA.FOUNTAIN_R - 40

  -- nearest visible enemy Commander
  local enemyC, ed
  for t = 1, w.np do
    local o = w.teams[t].commander
    if o and o.alive and w:hostile(t, self.team) and not (o.fadeUntil and w.time < o.fadeUntil) then
      local d = U.dist(c.x, c.y, o.x, o.y)
      if d < 900 and (not ed or d < ed) then enemyC, ed = o, d end
    end
  end
  local mine = self:strength(c.x, c.y, 500, false)
  local theirs = self:strength(c.x, c.y, 500, true)
  local danger = theirs > mine * 1.3 or (enemyC and ed < 450)
  local tower = self:towerThreat(c.x, c.y)

  self:useSkills(c, enemyC, danger)

  -- go home to heal
  if self.mode == "heal" then
    if hpf > 0.95 then self.mode = "lane"
    else
      if not atHome and (#c.orders == 0 or c.orders[1].type ~= "move") then
        w:issue(c, { type = "move", x = homeX, y = homeY, arrive = 120 })
      end
      return
    end
  end
  if hpf < 0.3 or (hpf < 0.5 and danger and theirs > mine * 2) then
    self.mode = "heal"
    w:issue(c, { type = "move", x = homeX, y = homeY, arrive = 120 })
    return
  end

  -- dive a weak enemy Commander that isn't sitting under its own tower
  if enemyC then
    local ehp = enemyC.hp / enemyC.maxhp
    local theirTower = self:towerThreat(enemyC.x, enemyC.y)
    local odds = (mine + 1) / (theirs + 1)
    if (ehp < 0.35 * self.brave or (ehp < hpf * 0.7 and odds > 0.9)) and (not theirTower or ehp < 0.15) and hpf > 0.35 then
      w:issue(c, { type = "attack", target = enemyC })
      -- allies close by join in
      for _, t in ipairs(w.arena.sideTeams[self.side]) do
        local ally = w.teams[t].commander
        if ally and ally ~= c and ally.alive and not (w.humanTeams or {})[t] and U.dist(ally.x, ally.y, enemyC.x, enemyC.y) < 800 then
          w:issue(ally, { type = "attack", target = enemyC })
        end
      end
      return
    end
  end

  -- deny: finish off our own dying creep before an enemy lands the last hit. Better
  -- computer players do it more often (it starves enemy creeps of veterancy too)
  if self.level >= 4 and hpf > 0.3 and self.rng:random() < 0.3 + 0.1 * (self.level - 4) then
    local best
    local r = w:rangeOf(c) + 30
    w:query(c.x, c.y, r + 40, function(o)
      if o.alive and o.creep and w:canDeny(c, o) and o.lastHit and w.time - o.lastHit < 1.5
        and U.dist(c.x, c.y, o.x, o.y) < r and (not best or o.hp < best.hp) then best = o end
    end)
    if best then
      w:issue(c, { type = "attack", target = best })
      return
    end
  end

  if w.arena.jungle and self:jungleThink(c, hpf, enemyC, danger) then return end

  -- lane: stand a little behind our frontmost creep, fight what's in range
  local front = 0.12
  for _, e in ipairs(w.entities) do
    if e.alive and e.creep and e.lane == self.lane and e.team ~= nil and not w:hostile(e.team, self.team) then
      local f = self:laneProgress(e.x, e.y)
      if f > front then front = f end
    end
  end
  local wantF = front - 0.035
  -- don't stand in enemy tower range unless our creeps are there to soak it
  local tx, ty = self:lanePoint(wantF)
  local tw = self:towerThreat(tx, ty)
  if tw and self:creepsNear(tw.x, tw.y, tw.def.weapon.range, false) < 2 then
    for k = 1, 12 do
      tx, ty = self:lanePoint(wantF - 0.025 * k)
      if not self:towerThreat(tx, ty) then break end
    end
  end
  if tower and self:creepsNear(tower.x, tower.y, tower.def.weapon.range, false) < 2 and not (enemyC and enemyC.hp < enemyC.maxhp * 0.2) then
    -- standing under an enemy tower with no creeps: back off now
    w:issue(c, { type = "move", x = tx, y = ty, arrive = 40 })
    return
  end
  -- push: an unprotected enemy structure with our creeps under it (or nobody defending) gets hit
  local s, sd = self:nearestEnemyStructure(c)
  if s and not s.protected and sd < 900 and hpf > 0.45 then
    local soak = self:creepsNear(s.x, s.y, s.def.weapon.range + 20, false)
    local defenders = 0
    for t = 1, w.np do
      local o = w.teams[t].commander
      if o and o.alive and w:hostile(t, self.team) and U.dist(o.x, o.y, s.x, s.y) < 700 then defenders = defenders + 1 end
    end
    if soak >= 2 or (defenders == 0 and soak >= 1) or (defenders == 0 and hpf > 0.8 and (c.clevel or 0) >= 6) then
      if not (c.orders[1] and c.orders[1].type == "attack" and c.orders[1].target == s) then
        w:issue(c, { type = "attack", target = s })
      end
      return
    end
  end
  if U.dist(c.x, c.y, tx, ty) > 140 then
    w:issue(c, { type = "amove", x = tx, y = ty, arrive = 60 })
  elseif #c.orders == 0 then
    -- in position: hit the best thing in range (structures when unprotected and creeps tank)
    local s, sd = self:nearestEnemyStructure(c)
    if s and not s.protected and sd < w:rangeOf(c) + 60 and self:creepsNear(s.x, s.y, s.def.weapon.range, false) >= 2 then
      w:issue(c, { type = "attack", target = s })
    end
  end
end

return AI
