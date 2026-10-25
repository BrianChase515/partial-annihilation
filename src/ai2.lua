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
  { name = "Skyborne", weights = { aggression = 1.1, patience = 1.1, raid = 1.2, hold = 0.8, weakness = 1.2, hunt = 1.2, guns = 0.7, air = 2.0, risk = 1.0 } },
}
AI2.ARCHETYPES = ARCHETYPES

function AI2.new(world, team, level, profileKey)
  local self = AI.new(world, team, level, profileKey)
  setmetatable(self, AI2)
  self.version = 2
  self.rng = love.math.newRandomGenerator(os.time() + team * 7919 + math.floor(love.math.random() * 1e6))
  self.p = B.personality(ARCHETYPES, self.rng, os.getenv("PA_ARCH"))
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
  self.profileName = (self.profileName or "?") .. " v2 (" .. self.p.name .. ")"
  self.announced = false
  return self
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

function AI2:thinkArmy()
  if not self.announced and self.world.tel then
    self.announced = true
    Tel.note(self.world, "personality", self.team, string.format("%s, level %d%s", self.p.name, self.level,
      self.omniscient and ", sees everything" or ""))
  end
  self:thinkPosture()
  self.tgtPick = nil -- a fresh target choice for any wave launched this think
  return AI.thinkArmy(self)
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
  }
  local adj = {}
  for key, v in pairs(wts) do adj[key] = v * (mul[key] or 1) end
  return AI.pick(self, adj)
end

return AI2
