-- Annihilation AI v2 (beta; Settings > Annihilation AI). Everything the classic AI does - its
-- economy, building, defenses, hunters, spotters, nukes, Commander - stays; v2 takes over three
-- decisions through the shared brain (src/brain.lua), with a personality drawn per game:
--   * its posture: strike now, mass up first, harass, or dig in (sets when waves go)
--   * where a wave goes: their base, an outlying expansion, the least defended spot, their army,
--     an exposed Commander
--   * what it builds: the classic mix, tilted to answer what you've got (no AA? more air)
-- Like AI War, it takes the best option more often the higher its level (63% at 5, 95% at 10);
-- level 8+ knows everything you have. Every choice goes in the match log.
local U = require("src.util")
local B = require("src.brain")
local Tel = require("src.telemetry")
local AI = require("src.ai")

local AI2 = setmetatable({}, { __index = AI })
AI2.__index = AI2

local ARCHETYPES = {
  { name = "Blitz", weights = { aggression = 1.6, patience = 0.6, raid = 1.0, hold = 0.5, weakness = 1.0, hunt = 1.1, guns = 0.8, air = 1.0, risk = 1.4 } },
  { name = "Siege", weights = { aggression = 0.9, patience = 1.4, raid = 0.6, hold = 1.1, weakness = 0.9, hunt = 0.8, guns = 1.7, air = 0.8, risk = 0.8 } },
  { name = "Raider", weights = { aggression = 1.0, patience = 0.9, raid = 1.8, hold = 0.6, weakness = 1.5, hunt = 1.0, guns = 0.8, air = 1.3, risk = 1.0 } },
  { name = "Fortress", weights = { aggression = 0.6, patience = 1.7, raid = 0.6, hold = 1.8, weakness = 0.8, hunt = 0.9, guns = 1.2, air = 0.9, risk = 0.6 } },
  { name = "Hunter", weights = { aggression = 1.3, patience = 1.0, raid = 1.1, hold = 0.7, weakness = 1.1, hunt = 1.9, guns = 1.0, air = 1.2, risk = 1.1 } },
  { name = "Opportunist", weights = { aggression = 1.1, patience = 1.0, raid = 1.3, hold = 0.9, weakness = 1.9, hunt = 1.1, guns = 1.0, air = 1.1, risk = 0.9 } },
  { name = "Admiral", weights = { aggression = 1.1, patience = 1.1, raid = 1.1, hold = 0.9, weakness = 1.1, hunt = 1.0, guns = 0.9, air = 0.9, risk = 1.0, navy = 2.0 } },
  { name = "Skyborne", weights = { aggression = 1.1, patience = 1.1, raid = 1.2, hold = 0.8, weakness = 1.2, hunt = 1.2, guns = 0.7, air = 2.0, risk = 1.0 } },
}
AI2.ARCHETYPES = ARCHETYPES

function AI2.new(world, team, level, profileKey)
  -- its economy runs two levels up (see Game.new); its judgement at the level picked
  local self = AI.new(world, team, math.min(10, (level or 5) + 2), profileKey)
  setmetatable(self, AI2)
  self.diff.level = level or 5
  self.version = 2
  self.rng = love.math.newRandomGenerator(os.time() + team * 7919 + math.floor(love.math.random() * 1e6))
  -- read the map first (terrain isn't hidden, only units): it decides which personalities fit
  self:readMap()
  self.p = self:pickPersonality(os.getenv("PA_ARCH"))
  self.level = self.diff.level or level or 5
  self.omniscient = self.level >= 8
  self.baseWave, self.baseGrow, self.baseRaid = self.diff.waveBase, self.diff.waveGrow, self.diff.raidEvery
  -- tempo: v2 plays faster than the classic AI at the same level - it thinks more often, builds
  -- its second and third plants much sooner, stops making constructors earlier, and gets its
  -- first army out the door (its own copy of the profile, so classic games aren't touched)
  local prof = {}
  for k, v in pairs(self.profile) do prof[k] = v end
  self.profile = prof
  local lv = self.level
  self.diff.think = math.max(0.35, self.diff.think * 0.6)
  self.diff.maxFactories = self.diff.maxFactories + 1 + math.floor(lv / 4)
  prof.factoryEcoMul = (prof.factoryEcoMul or 1) * (0.75 - 0.03 * lv)
  self.diff.builderBonus = self.diff.builderBonus - (lv >= 4 and 1 or 0)
  self.diff.firstWave = math.floor(self.diff.firstWave * 0.75)
  self.diff.waveBase = math.max(4, self.diff.waveBase - 1)
  -- and it puts its early metal into land, plants and army, not into specialist plants, towers
  -- and storage it doesn't need yet (Fortress / naval / air personalities aside)
  self.specFrom = (prof.navalFirst or prof.airFirst) and 200 or 300
  self.turretFrom = 300
  self.storageFrom = 480
  -- personality shapes the opening
  local P = self.p.w
  self.diff.firstWave = math.floor(self.diff.firstWave * (1.25 - 0.3 * P.aggression + 0.15 * P.patience))
  self.diff.turrets = math.max(1, math.floor(self.diff.turrets * (0.6 + 0.45 * P.hold) + 0.5))
  if P.hold >= 1.4 then self.turretFrom = 170 end
  if P.raid >= 1.3 and not self.diff.raidEvery and self.level >= 4 then self.diff.raidEvery = 170 end
  if P.raid >= 1.3 and not self.huntersWanted and self.level >= 3 then self.huntersWanted, self.huntersFrom = 2, 200 end
  self.posture = { }
  self.tgtState = {}
  self:applyMapPlan()
  self.profileName = (self.profileName or "?") .. " v2 (" .. self.p.name .. ")"
  self.announced = false
  return self
end


---------------------------------------------------------------------------
-- Reading the map: what kind of game this ground makes

function AI2:readMap()
  local w = self.world
  local map = w.map
  local T = w.T
  local W, H = map.w * T, map.h * T
  local diag = math.sqrt(W * W + H * H)
  local cx, cy = W / 2, H / 2
  local me = w.teams[self.team]
  local ex, ey = self.enemyX or cx, self.enemyY or cy
  local cR = diag * 0.17
  local tot, inC, out = 0, 0, 0
  local sea = 0
  for _, d in ipairs(map.deposits) do
    local x, y = (d.x + 0.5) * T, (d.y + 0.5) * T
    local v = d.rich and 2.5 or 1
    tot = tot + v
    if d.sea then sea = sea + v end
    local dc = U.dist(x, y, cx, cy)
    if dc < cR then inC = inC + v
    else
      -- outlying: far from both bases and off the centre - raiding ground
      local dm, de = U.dist(x, y, me.startX, me.startY), U.dist(x, y, ex, ey)
      if dm > diag * 0.22 and de > diag * 0.22 then out = out + v end
    end
  end
  tot = math.max(1, tot)
  -- water near the centre and a sea route to their base: a navy can attack here
  local seaC = 0
  if self.seaSet then
    local tx, ty = map:tileAt(cx, cy)
    local best
    for y = 0, map.h - 1, 2 do
      for x = 0, map.w - 1, 2 do
        if self.seaSet[y * map.w + x] then
          local d = math.sqrt((x - tx) ^ 2 + (y - ty) ^ 2) * T
          if not best or d < best then best = d end
        end
      end
    end
    if best then seaC = math.max(0, 1 - best / (diag * 0.3)) end
  end
  local base = U.dist(me.startX, me.startY, ex, ey)
  self.mapRead = {
    center = math.min(1, inC / tot * 2.2),                     -- how much of the metal sits in the middle
    raid = math.min(1, out / tot * 1.2 * math.min(1.3, diag / 3800) * (1 - 0.45 * math.min(1, inC / tot * 2.2))), -- outlying metal, room to reach it, and a centre that doesn't eat everything
    naval = math.min(1, (self.navalReach and 0.45 or 0) + 0.55 * seaC + 0.4 * (sea / tot)),
    rush = math.max(0, 1 - base / (diag * 0.8)),                -- bases close together
    cx = cx, cy = cy, cR = cR, diag = diag,
  }
end

-- personalities that suit the map are more likely (never certain)
function AI2:pickPersonality(forced)
  local m = self.mapRead
  local fit = {
    Blitz = 0.8 + 0.6 * m.rush + 0.4 * m.center, Siege = 0.7 + 0.6 * m.center,
    Raider = 0.3 + 1.4 * m.raid, Fortress = 0.7 + 0.3 * (1 - m.rush),
    Hunter = 0.8 + 0.3 * m.center, Opportunist = 0.6 + 0.5 * m.raid + 0.3 * m.center,
    Admiral = m.naval > 0.55 and (0.2 + 1.6 * m.naval) or 0.02, Skyborne = 0.7,
  }
  local opts = {}
  for _, a in ipairs(ARCHETYPES) do opts[#opts + 1] = { key = a.name, label = a.name, score = fit[a.name] or 0.5, a = a } end
  local pick
  if forced then for _, o in ipairs(opts) do if o.key == forced then pick = o end end end
  if not pick then
    local tot = 0
    for _, o in ipairs(opts) do tot = tot + o.score end
    local r = self.rng:random() * tot
    for _, o in ipairs(opts) do r = r - o.score; if r <= 0 and not pick then pick = o end end
    pick = pick or opts[1]
  end
  local p = { name = pick.a.name, w = {} }
  for k, v in pairs(pick.a.weights) do p.w[k] = v * (0.8 + self.rng:random() * 0.4) end
  p.w.navy = p.w.navy or 1
  return p
end

-- turn the map read + personality into a plan for the game
function AI2:applyMapPlan()
  local m, P, prof = self.mapRead, self.p.w, self.profile
  -- where the army waits between waves: out toward the centre when the centre is the game
  self.stageK = math.min(0.75, (0.2 + 0.55 * m.center) * (0.7 + 0.3 * P.aggression) * (1.15 - 0.35 * (P.hold - 1)))
  -- a navy when the water allows it (Admirals above all)
  if P.navy > 1.3 or (m.naval > 0.7 and self.rng:random() < m.naval * 0.6) then
    prof.navalFirst = true
    self.specFrom = 150
    self.navyPlan = true
  end
  -- raiding: how often, and how small a party it will send at unguarded metal
  local rp = m.raid * P.raid
  if rp > 0.35 then
    self.diff.raidEvery = math.floor(180 - 110 * math.min(1, rp))
    self.smallRaids = true
  elseif rp < 0.15 then
    self.diff.raidEvery = nil -- nothing out there worth the trip: everything goes to the centre
  end
  -- the Commander: aggressive personalities send it out to level up
  -- (it levels up by riding with the army - see thinkCommander - not by going off alone)
end

-- the staging point follows the posture and the map
function AI2:updateStage()
  local m = self.mapRead
  local k = self.stageK or 0.3
  local pk = self.posture.choice and self.posture.choice.key
  if pk == "dig" then k = math.min(k, 0.2) elseif pk == "strike" then k = math.min(0.85, k + 0.1) end
  -- don't park the army out there before it's an army
  local n = 0
  for _, e in ipairs(self.world.entities) do
    if e.alive and e.team == self.team and not e.def.building and e.def.weapon and e.key ~= "builder" and e.key ~= "commander" and e.def.domain == "land" then n = n + 1 end
  end
  if n < 5 then k = math.min(k, 0.15) end
  local sx, sy = self.baseX + (m.cx - self.baseX) * k, self.baseY + (m.cy - self.baseY) * k
  self.stageX, self.stageY = sx, sy
end

-- raids: small parties at metal nobody is guarding
function AI2:launchRaid(army, inWave)
  if not self.smallRaids then return AI.launchRaid(self, army, inWave) end
  local world = self.world
  local units, buildings = self:enemyUnits()
  local opts = {}
  for _, e in ipairs(buildings) do
    if e.key == "mex" or e.key == "solar" then
      local guard = 0
      for _, b in ipairs(buildings) do if b.def.weapon and U.dist2(b.x, b.y, e.x, e.y) < 420 * 420 then guard = guard + 1 end end
      for _, u in ipairs(units) do if u.def.weapon and U.dist2(u.x, u.y, e.x, e.y) < 500 * 500 then guard = guard + 1 end end
      local far = U.dist(e.x, e.y, self.enemyX, self.enemyY) / self.mapRead.diag
      opts[#opts + 1] = { key = tostring(e), label = e.key, e = e, guard = guard,
        score = (0.3 + far) / (1 + guard * 1.5) * (e.key == "mex" and 1.2 or 1) }
    end
  end
  local o = B.pick(opts, self.level, self.rng)
  if not o then return end
  local fast = { scout = true, gunship = true, bomber = true }
  local want = o.guard == 0 and self.rng:random(1, 2) or 4
  local squad = {}
  for _, u in ipairs(army) do
    if not inWave[u] and fast[u.key] and #squad < want and not u.disarmed and not (self.isHunter and self.isHunter[u]) and not (self.spotters and self.spotters[u]) then
      local layer = world:layerOf(u)
      if not layer or world.map:canReach(layer, u.x, u.y, o.e.x, o.e.y, u.def.weapon.range) then squad[#squad + 1] = u end
    end
  end
  if #squad < math.min(want, o.guard == 0 and 1 or 3) then return end
  self.lastRaid = world.time
  self.raidSquad = squad
  Tel.note(world, "raid", self.team, string.format("%d %s at a %s (%s)", #squad, #squad == 1 and "raider" or "raiders", o.e.key,
    o.guard == 0 and "unguarded" or "guarded"))
  for _, u in ipairs(squad) do
    world:issue(u, { type = "amove", x = o.e.x + self.rng:random(-30, 30), y = o.e.y + self.rng:random(-30, 30) })
    self.wave[u] = true
    inWave[u] = true
  end
end

-- the Commander: the classic logic first (spending upgrades, nukes, retreating when hurt,
-- hunting for XP...). If that leaves it on build duty, a v2 Commander that isn't timid goes up
-- behind the army at the staging point - it levels up by fighting there, and the base can spare
-- it once a few constructors are running
function AI2:thinkCommander()
  -- (the classic code sends a Commander that isn't on build duty straight home; at the front is
  -- where we want it, so it goes in looking like build duty)
  if self.cmdMode == "front" then self.cmdMode = "build" end
  local before = self.cmdMode
  local w = self.world
  local c = w.teams[self.team].commander
  -- while it's handling a fight at home (or getting out of shellfire) the classic logic would
  -- flip it back and forth every second; let v2 see that through
  if (self.cmdMode == "homefight" or self.cmdMode == "evade") and c and c.alive and w.time < (self.cmdHoldUntil or 0) then
    self:guardCommander(c, before)
    self:goForTheKill()
    return
  end
  AI.thinkCommander(self)
  if c and c.alive and c.key == "commander" then
    self:guardCommander(c, before)
    self:goForTheKill()
  end
  if not c or not c.alive or c.key ~= "commander" or self.cmdMode ~= "build" then return end
  local P = self.p.w
  if P.hold > 1.4 or w.time < 150 or c.hp < c.maxhp * 0.7 then return end
  local builders, army = 0, 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team then
      if e.key == "builder" then builders = builders + 1
      elseif e.def.weapon and not e.def.building and e.key ~= "commander" and U.dist2(e.x, e.y, self.stageX, self.stageY) < 500 * 500 then army = army + 1 end
    end
  end
  if builders < 3 then return end
  -- ride with an attack wave (from behind), or wait with the army at the staging point
  local wl, wx, wy = 0, 0, 0
  for u in pairs(self.wave) do
    if u.alive and u.def.domain == "land" and u.key ~= "scout" then wl, wx, wy = wl + 1, wx + u.x, wy + u.y end
  end
  local tx, ty, why
  if wl >= 5 then
    wx, wy = wx / wl, wy / wl
    local bx, by = U.norm(self.baseX - wx, self.baseY - wy)
    tx, ty, why = wx + bx * 150, wy + by * 150, "with the wave"
  elseif army >= 3 then
    local bx, by = U.norm(self.baseX - self.stageX, self.baseY - self.stageY)
    tx, ty, why = self.stageX + bx * 120, self.stageY + by * 120, "at the staging point"
  else
    return
  end
  -- danger there (more than our side can handle): stay home
  if self:strengthNear(tx, ty, 600, true) > self:strengthNear(tx, ty, 600, false) * 1.3 + 400 then return end
  if self.cmdMode ~= "front" and not self.frontNoted then
    self.frontNoted = true
    Tel.note(w, "commander", self.team, "goes forward " .. why .. " to fight and level up")
  end
  self.cmdMode = "front"
  if #c.orders == 0 or U.dist(c.x, c.y, tx, ty) > 260 then
    w:issue(c, { type = "amove", x = tx, y = ty })
  end
end

-- losing the Commander loses the game. When it's in trouble: nearby units turn to cover it, and
-- if our army is closer and strong enough, it falls back behind the army (guns still up)
-- instead of powering down for the long run home
function AI2:guardCommander(c, before)
  local w = self.world
  local danger = self:strengthNear(c.x, c.y, 500, true)
  local hpf = c.hp / c.maxhp
  local tm = w.teams[self.team]
  -- being hit by something it can't see (artillery out in the fog): get out early
  local hf = c.hitFrom
  local unseen = hf and w.time - hf.t < 2 and self:strengthNear(c.x, c.y, 450, true) <= 0
  if c.lastHit and w.time - c.lastHit < 2 and hpf < 0.62 and self.cmdMode ~= "retreat" and self.cmdMode ~= "covered"
    and self.cmdMode ~= "homefight" and self.cmdMode ~= "evade" then
    if unseen then
      -- shelled from out of sight (artillery): get out of its reach, sideways and back - running
      -- home in a straight line can mean running down the guns' line of fire. Guns stay up
      local ax, ay = U.norm(c.x - hf.x, c.y - hf.y)
      local hx, hy = U.norm(tm.startX - c.x, tm.startY - c.y)
      local dx, dy = U.norm(ax * 0.7 + hx * 0.5, ay * 0.7 + hy * 0.5)
      local map = w.map
      local tx, ty = map:tileAt(c.x + dx * 420, c.y + dy * 420)
      local nx, ny = map:nearestTile(math.max(1, math.min(map.w - 2, tx)), math.max(1, math.min(map.h - 2, ty)),
        function(x, y) return map:passable("land", x, y) end, 10)
      if nx then
        local fx, fy = map:center(nx, ny)
        c.disarmed = nil
        self.cmdMode, self.cmdHoldUntil = "evade", w.time + 6
        w:issue(c, { type = "move", x = fx, y = fy })
        Tel.note(w, "commander", self.team, string.format("shelled from out of sight at %d%%: moves out of range", math.floor(hpf * 100)))
      end
    else
      self.cmdMode = "retreat"
      w:issue(c, { type = "retreat", x = tm.startX, y = tm.startY })
      Tel.note(w, "commander", self.team, string.format("taking fire at %d%%: pulls out", math.floor(hpf * 100)))
    end
  end
  if self.cmdMode == "evade" and w.time >= (self.cmdHoldUntil or 0) then self.cmdMode = nil end
  -- home, but the fight followed it there: sitting powered down at the spawn is death. Fight
  -- with the base if that's a fight it can win, otherwise slip away (guns up) and come back
  local spawnD = U.dist(c.x, c.y, tm.startX, tm.startY)
  if (self.cmdMode == "retreat" or self.cmdMode == "homefight") and spawnD < 260 and danger > 0 then
    local support = self:strengthNear(c.x, c.y, 550, false)
    c.disarmed = nil
    local th = self:enemyNearBase()
    self.cmdHoldUntil = w.time + 5
    if support + 500 * hpf >= danger * 0.75 and th then
      self.cmdMode = "homefight"
      w:issue(c, { type = "amove", x = th.x, y = th.y })
    else
      local ex, ey, n = 0, 0, 0
      w:query(c.x, c.y, 650, function(e)
        if e.alive and self:isHostile(e.team) and e.def.weapon then ex, ey, n = ex + e.x, ey + e.y, n + 1 end
      end)
      local ax, ay = -self.dirX, -self.dirY
      if n > 0 then ax, ay = U.norm(c.x - ex / n, c.y - ey / n) end
      local fx, fy = self:escapePoint(c)
      if U.dist(fx, fy, c.x, c.y) < 300 then fx, fy = c.x + ax * 600, c.y + ay * 600 end
      self.cmdMode = "homefight"
      w:issue(c, { type = "move", x = fx, y = fy })
    end
    if not self.homeNoted then
      self.homeNoted = true
      Tel.note(w, "commander", self.team, "the fight followed it home: powers up instead of waiting to be killed")
    end
  elseif self.cmdMode == "homefight" and danger <= 0 then
    self.cmdMode = nil
  end
  if danger <= 0 then return end
  local trouble = self.cmdMode == "retreat" or hpf < 0.7
  if not trouble then return end
  -- bodyguard: the nearest fighting units (not the hunters or spotters) go to it
  local near = {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team and e.def.weapon and not e.def.building and e.key ~= "commander" and e.key ~= "builder"
      and not e.disarmed and e.def.domain ~= "sea" and e.def.domain ~= "sub" and not (self.isHunter and self.isHunter[e]) then
      local d = U.dist(e.x, e.y, c.x, c.y)
      if d < 900 then near[#near + 1] = { e = e, d = d } end
    end
  end
  table.sort(near, function(a, b) return a.d < b.d end)
  for i = 1, math.min(8, #near) do
    local e = near[i].e
    local o = e.orders[1]
    if not (o and o.guardCmd) then w:issue(e, { type = "amove", x = c.x, y = c.y, guardCmd = true }) end
    self.wave[e] = nil
  end
  if #near > 0 and not self.guardNoted then
    self.guardNoted = true
    Tel.note(w, "commander", self.team, string.format("in trouble: %d units cover it", math.min(8, #near)))
  end
  -- just started a retreat, but our army nearby is the safer place: fall back to it, armed
  if self.cmdMode == "retreat" and before ~= "retreat" and hpf > 0.3 then
    local ax, ay, n, str = 0, 0, 0, 0
    for i = 1, math.min(12, #near) do ax, ay, n = ax + near[i].e.x, ay + near[i].e.y, n + 1 end
    if n >= 4 then
      ax, ay = ax / n, ay / n
      str = self:strengthNear(ax, ay, 500, false)
      local home = U.dist(c.x, c.y, self.baseX, self.baseY)
      if str > danger * 1.2 and U.dist(c.x, c.y, ax, ay) < home * 0.6 then
        local bx, by = U.norm(ax - c.x, ay - c.y)
        c.disarmed = nil
        self.cmdMode = "covered"
        w:issue(c, { type = "move", x = ax + bx * 120, y = ay + by * 120 })
      end
    end
  end
end

-- go for the kill: their Commander, hurt or running, within reach of our units -> chase it down
-- (how reliably it seizes the moment grows with level)
function AI2:goForTheKill()
  local w = self.world
  if w.time < (self.nextKill or 0) then return end
  self.nextKill = w.time + 2
  local units = self:enemyUnits()
  for _, e in ipairs(units) do
    if e.key == "commander" and e.alive then
      local weak = e.hp / e.maxhp < 0.55 or w:isFleeing(e) or e.disarmed
      if weak and self.rng:random() < B.sharpness(self.level) then
        local hunters = {}
        for _, u in ipairs(w.entities) do
          if u.alive and u.team == self.team and u.def.weapon and not u.def.building and u.key ~= "commander" and u.key ~= "builder"
            and not u.disarmed and U.dist2(u.x, u.y, e.x, e.y) < 800 * 800 and w:canTarget(u, e) then
            hunters[#hunters + 1] = u
          end
        end
        if #hunters >= 2 then
          for i = 1, math.min(10, #hunters) do
            w:issue(hunters[i], { type = "attack", target = e })
            self.wave[hunters[i]] = true
          end
          if w.time - (self.killNoted or -99) > 20 then
            self.killNoted = w.time
            Tel.note(w, "kill", self.team, string.format("their Commander is %s: %d units go for it",
              (w:isFleeing(e) or e.disarmed) and "running" or "hurt", math.min(10, #hunters)))
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- What it knows about you

function AI2:enemyUnits()
  local w = self.world
  if self.euCache and w.time - self.euCache.t < 1 then return self.euCache.u, self.euCache.b end
  local out, buildings = {}, {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.team and self:isHostile(e.team) then
      if e.def.building then
        if self.omniscient or self.known[e] then buildings[#buildings + 1] = e end
      elseif self.omniscient or self:sees(e) then
        out[#out + 1] = e
      end
    end
  end
  self.euCache = { t = w.time, u = out, b = buildings }
  return out, buildings
end

-- does this AI's side see the unit right now (a unit or building of ours within sight)?
function AI2:sees(e)
  local w = self.world
  local hit = false
  w:query(e.x, e.y, 480, function(o)
    if not hit and o.alive and o.team == self.team and o.def.sight and U.dist2(o.x, o.y, e.x, e.y) <= w:sightOf(o) ^ 2 then hit = true end
  end)
  return hit
end

local function value(e)
  local c = e.def.cost
  return c and (c.metal + c.energy / 10) or 50
end

---------------------------------------------------------------------------
-- Posture: when waves go

function AI2:thinkPosture()
  local w = self.world
  local P = self.p.w
  local t = w.time
  if t < (self.nextPosture or 0) then return end
  self.nextPosture = t + 12
  local units = self:enemyUnits()
  local theirs = 0
  for _, e in ipairs(units) do if e.def.weapon then theirs = theirs + value(e) end end
  local ours, home = 0, 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team and not e.def.building and e.def.weapon and e.key ~= "builder" then
      ours = ours + value(e)
      if U.dist(e.x, e.y, self.baseX, self.baseY) < 900 then home = home + value(e) end
    end
  end
  local odds = ours / math.max(1, ours + theirs * (self.omniscient and 1 or 1.3))
  local threat = self:enemyNearBase() and 1 or 0
  local since = t - (self.lastWave or -999)
  self:balanceArmy(ours)
  local opts = {
    { key = "strike", label = "strike now", score = 0.55 * P.aggression * (0.3 + odds) * (P.risk ^ 0.5) * (since > 90 and 1.2 or 0.7) },
    { key = "mass", label = "mass up first", score = 0.5 * P.patience * (1.25 - odds) },
    { key = "harass", label = "harass", score = 0.42 * P.raid * (0.6 + 0.4 * odds) },
    { key = "dig", label = "dig in", score = 0.35 * P.hold * (0.6 + threat) * (1.3 - odds) },
  }
  local o, ch = B.commit(self.posture, opts, self.level, self.rng, t, { reconsider = 70, minHold = 30, margin = 1.3 })
  if not o then return end
  if ch then Tel.note(w, "posture", self.team, B.explain(opts, o)) end
  local d = self.diff
  if o.key == "strike" then
    d.waveBase, d.waveGrow, d.raidEvery = math.max(4, math.floor(self.baseWave * 0.65)), self.baseGrow, self.baseRaid
  elseif o.key == "mass" then
    d.waveBase, d.waveGrow, d.raidEvery = math.floor(self.baseWave * 1.4 + 0.5), self.baseGrow + 1, self.baseRaid
  elseif o.key == "harass" then
    d.waveBase, d.waveGrow, d.raidEvery = self.baseWave, self.baseGrow, 90
  else
    d.waveBase, d.waveGrow, d.raidEvery = math.floor(self.baseWave * 1.7 + 0.5), self.baseGrow + 1, self.baseRaid
  end
end

-- an economy is only worth what it fields. Past 2:30, a standing army worth about 25 seconds of
-- income (more for aggressive personalities) is the floor; below it, v2 stops expanding, stops
-- adding specialist plants and constructors, and puts everything into units until it's back
function AI2:balanceArmy(ours)
  local w = self.world
  local tm = w.teams[self.team]
  if not self.baseEco then self.baseEco = { expand = self.diff.expandMul, spec = self.specFrom, builders = self.diff.builderBonus } end
  if w.time < 150 then return end
  local want = tm.mIncome * 25 * (0.8 + 0.25 * self.p.w.aggression)
  local short = ours < want
  if short and not self.arming then
    self.arming = true
    self.diff.expandMul = self.baseEco.expand * 0.35
    self.specFrom = 99999
    self.diff.builderBonus = self.baseEco.builders - 2
    self.navyPaused = true
    Tel.note(w, "economy", self.team, string.format("army %d is thin for %.0f metal/s (wants %d): stops expanding, builds units", math.floor(ours), tm.mIncome, math.floor(want)))
  elseif self.arming and ours > want * 1.15 then
    self.arming = false
    self.diff.expandMul, self.specFrom, self.diff.builderBonus = self.baseEco.expand, self.baseEco.spec, self.baseEco.builders
    self.navyPaused = false
    Tel.note(w, "economy", self.team, string.format("army %d is enough: back to growing", math.floor(ours)))
  end
end

function AI2:thinkArmy()
  if not self.announced and self.world.tel then
    self.announced = true
    Tel.note(self.world, "personality", self.team, string.format("%s, level %d%s", self.p.name, self.level,
      self.omniscient and ", sees everything" or ""))
    local m = self.mapRead
    Tel.note(self.world, "map read", self.team, string.format("centre %.2f, raiding %.2f, navy %.2f%s (water %d tiles), rush %.2f -> stage %.0f%% of the way to the centre%s",
      m.center, m.raid, m.naval, self.navalReach and " (sea route to their base)" or "", self.waterSize or 0, m.rush, (self.stageK or 0) * 100,
      self.navyPlan and ", building a navy" or ""))
  end
  self:thinkPosture()
  self:updateStage()
  self.tgtPick = nil -- a fresh target choice for any wave launched this think
  local r = AI.thinkArmy(self)
  self:sendHurtHome()
  self:defendHome()
  return r
end

-- a unit that ran from a fight is powered down until it's repaired. The classic code can still
-- pick it up for the next push (it's idle, it's in the wave list); v2 keeps it home instead
function AI2:sendHurtHome()
  local w = self.world
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team and e.disarmed and not e.def.building and e.key ~= "commander" then
      self.wave[e] = nil
      if self.raidSquad then for i = #self.raidSquad, 1, -1 do if self.raidSquad[i] == e then table.remove(self.raidSquad, i) end end end
      local o = e.orders[1]
      local home = U.dist(e.x, e.y, self.baseX, self.baseY)
      if (not o or (o.type ~= "retreat" and o.type ~= "move")) and home > 350 then
        w:issue(e, { type = "retreat", x = self.baseX + self.rng:random(-120, 120), y = self.baseY + self.rng:random(-120, 120) })
      elseif o and o.type == "move" and U.dist(o.x, o.y, self.baseX, self.baseY) > 450 and not w:isFleeing(e) then
        w:issue(e, { type = "retreat", x = self.baseX + self.rng:random(-120, 120), y = self.baseY + self.rng:random(-120, 120) })
      end
    end
  end
end

-- the army is out at the centre and they're in our base: bring it home (the staged army first;
-- the wave too, if home is badly outmatched). The Commander's life is the game
function AI2:defendHome()
  local w = self.world
  local th = self:enemyNearBase()
  if not th then self.homeAlarm = nil; return end
  local theirs = self:strengthNear(self.baseX, self.baseY, 900, true)
  local ours = self:strengthNear(self.baseX, self.baseY, 900, false)
  if theirs <= ours * 0.8 then return end
  local deficit = theirs - ours * 0.8
  local pulled, need = 0, deficit
  local cands = {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == self.team and e.def.weapon and not e.def.building and e.key ~= "commander" and e.key ~= "builder"
      and not e.disarmed and (e.def.domain == "land" or e.def.domain == "air") and not (self.isHunter and self.isHunter[e]) then
      local d = U.dist(e.x, e.y, self.baseX, self.baseY)
      if d > 600 and d < 3000 then
        -- the wave only comes back when home is badly outmatched
        if not self.wave[e] or theirs > ours * 1.8 + 600 then cands[#cands + 1] = { e = e, d = d } end
      end
    end
  end
  table.sort(cands, function(a, b) return a.d < b.d end)
  for _, c in ipairs(cands) do
    if need <= 0 then break end
    local e = c.e
    local o = e.orders[1]
    if not (o and o.homeDef) then w:issue(e, { type = "amove", x = th.x, y = th.y, homeDef = true }) end
    self.wave[e] = nil
    local cost = e.def.cost
    need = need - (cost and (cost.metal + cost.energy / 10) or 80)
    pulled = pulled + 1
  end
  if pulled > 0 and w.time - (self.homeAlarm or -99) > 30 then
    self.homeAlarm = w.time
    Tel.note(w, "defend", self.team, string.format("base under attack (theirs %d vs ours %d): %d units come home", math.floor(theirs), math.floor(ours), pulled))
  end
end

---------------------------------------------------------------------------
-- Where a wave goes

function AI2:pickTarget(domain)
  if domain == "sea" then return AI.pickTarget(self, domain) end
  local w = self.world
  if self.tgtPick and w.time - self.tgtPick.t < 1.5 then return self.tgtPick.x, self.tgtPick.y end
  local P = self.p.w
  local units, buildings = self:enemyUnits()
  if #buildings == 0 and #units == 0 then return AI.pickTarget(self, domain) end
  -- cluster their buildings (an expansion, the main base...) and weigh each
  local clusters, used = {}, {}
  for i, b in ipairs(buildings) do
    if not used[i] then
      local c = { x = 0, y = 0, n = 0, val = 0, def = 0, eco = 0, fac = 0 }
      for j, b2 in ipairs(buildings) do
        if not used[j] and U.dist2(b.x, b.y, b2.x, b2.y) < 450 * 450 then
          used[j] = true
          c.x, c.y, c.n = c.x + b2.x, c.y + b2.y, c.n + 1
          c.val = c.val + value(b2)
          if b2.def.weapon then c.def = c.def + value(b2) end
          if b2.key == "mex" or b2.key == "solar" then c.eco = c.eco + 1 end
          if b2.def.factory then c.fac = c.fac + 1 end
        end
      end
      c.x, c.y = c.x / c.n, c.y / c.n
      clusters[#clusters + 1] = c
    end
  end
  local defOf = function(x, y)
    local s = 0
    for _, e in ipairs(units) do if e.def.weapon and U.dist2(e.x, e.y, x, y) < 600 * 600 then s = s + value(e) end end
    return s
  end
  local diag = math.sqrt((w.map.w * w.T) ^ 2 + (w.map.h * w.T) ^ 2)
  local opts = {}
  for k, c in ipairs(clusters) do
    local guard = c.def + defOf(c.x, c.y)
    local soft = 1 / (1 + guard / 600)
    local d = U.dist(self.baseX, self.baseY, c.x, c.y)
    local s = (0.4 + 0.1 * math.min(6, c.n)) * (1 - 0.4 * d / diag / math.max(0.5, P.patience))
    s = s * (soft ^ (1 / math.max(0.5, P.risk))) * (1 + (P.weakness - 1) * soft)
    if c.eco > 0 and c.fac == 0 then s = s * (1 + 0.4 * (P.raid - 1) + 0.15) end      -- an outlying expansion
    if c.fac > 0 then s = s * (1 + 0.3 * (P.aggression - 1) + 0.2) end                -- their production
    opts[#opts + 1] = { key = string.format("b%d_%d", math.floor(c.x / 400), math.floor(c.y / 400)),
      label = (c.fac > 0 and "their base" or (c.eco > 0 and "an expansion" or "buildings")) .. string.format(" (%d)", c.n),
      score = s, x = c.x, y = c.y }
  end
  -- their army in the field, if it's where we can hit it
  local ax, ay, an, av = 0, 0, 0, 0
  for _, e in ipairs(units) do
    if e.def.weapon and e.def.domain == "land" and e.key ~= "commander" then ax, ay, an, av = ax + e.x, ay + e.y, an + 1, av + value(e) end
  end
  if an >= 4 then
    ax, ay = ax / an, ay / an
    opts[#opts + 1] = { key = "army", label = string.format("their army (%d)", an), x = ax, y = ay,
      score = 0.45 * P.aggression * (P.risk ^ 0.7) * (1 - 0.3 * U.dist(self.baseX, self.baseY, ax, ay) / diag) }
  end
  -- the centre itself, when the map is about the centre
  local m = self.mapRead
  if m and m.center > 0.25 then
    local guard = defOf(m.cx, m.cy)
    local mine = 0
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == self.team and e.def.weapon and not e.def.building and U.dist2(e.x, e.y, m.cx, m.cy) < m.cR * m.cR then mine = mine + 1 end
    end
    local s = 0.75 * m.center * (0.8 + 0.4 * P.aggression) / (1 + guard / 900) * (mine >= 6 and 0.5 or 1)
    opts[#opts + 1] = { key = "centre", label = "take the centre", score = s, x = m.cx + self.rng:random(-80, 80), y = m.cy + self.rng:random(-80, 80) }
  end
  -- an exposed Commander
  for _, e in ipairs(units) do
    if e.key == "commander" and e.alive then
      local guard = defOf(e.x, e.y) - value(e)
      local s = 0.5 * P.hunt * (1 / (1 + math.max(0, guard) / 500)) * (e.hp / e.maxhp < 0.6 and 1.3 or 1)
      opts[#opts + 1] = { key = "cmd", label = "their Commander", score = s, x = e.x, y = e.y }
    end
  end
  local o, ch = B.commit(self.tgtState, opts, self.level, self.rng, w.time, { reconsider = 60, minHold = 20, margin = 1.3 })
  if not o then return AI.pickTarget(self, domain) end
  if ch then Tel.note(w, "target", self.team, B.explain(opts, o)) end
  self.tgtPick = { x = o.x, y = o.y, t = w.time }
  return o.x, o.y
end

---------------------------------------------------------------------------
-- What it builds: the classic mix, tilted to answer you (and by personality)

function AI2:pick(wts)
  local units = self:enemyUnits()
  local c = {}
  for _, e in ipairs(units) do c[e.key] = (c[e.key] or 0) + 1 end
  local air = (c.gunship or 0) + (c.bomber or 0) + (c.fighter or 0)
  local aa = (c.flak or 0) + (c.fighter or 0)
  local tanks = c.tank or 0
  local guns = c.artillery or 0
  local P = self.p.w
  -- how hard it leans into the answer grows with level
  local k = B.sharpness(self.level)
  local mul = {
    gunship = (aa == 0 and 1 + 0.8 * k or 1 / (1 + 0.2 * aa)) * P.air,
    bomber = (aa == 0 and 1 + 0.6 * k or 1 / (1 + 0.2 * aa)) * P.air * (tanks > 6 and 1.2 or 1),
    fighter = air > 0 and 1 + 0.5 * k or 0.8,
    flak = air > 2 and 1 + 0.6 * k or 1,
    artillery = (1 + 0.04 * k * tanks) * P.guns,
    tank = (1 + 0.03 * k * guns) * (0.8 + 0.2 * P.aggression),
    scout = (guns > 2 and 1 + 0.4 * k or 1) * (0.7 + 0.3 * P.raid),
    boat = (self.navyPlan and not self.navyPaused) and 1.4 or 1, destroyer = (self.navyPlan and not self.navyPaused) and 1.4 or 1,
    battleship = (self.navyPlan and not self.navyPaused) and 1.6 or 1, sub = (self.navyPlan and not self.navyPaused) and 1.2 or 1,
  }
  local adj = {}
  for key, v in pairs(wts) do adj[key] = v * (mul[key] or 1) end
  return AI.pick(self, adj)
end

return AI2
