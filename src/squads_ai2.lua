-- Commander of Heroes AI v2 (experimental; Settings > Commander of Heroes AI). Builds on v1's
-- tactics (formations by role, skills, kiting, healing, breaking) and replaces how it decides
-- WHAT to do: options scored by the situation and a per-game personality, chosen through the
-- shared brain (src/brain.lua) - usually the best, sometimes a nearly-best one, more sharply at
-- higher levels. Every choice is written to the match log with the runners-up.
local U = require("src.util")
local B = require("src.brain")
local Tel = require("src.telemetry")
local S = require("src.squads")

local AI2 = setmetatable({}, { __index = S.AI })
AI2.__index = AI2

-- personalities. Weights (1 = neutral):
--   aggression  attack enemy groups rather than ground      cohesion  keep the force together
--   patience    tolerate long walks / holding                guns      lean on the battery
--   flank       go for points away from the enemy's strength raid      send scouts off on their own
--   risk        take fights at worse odds                   hold      sit on good ground
--   weakness    go where you're thin                        hunt      chase artillery and leaders
local ARCHETYPES = {
  { name = "Blitz", weights = { aggression = 1.5, cohesion = 0.8, patience = 0.6, guns = 0.8, flank = 1.0, raid = 1.0, risk = 1.4, hold = 0.5, weakness = 1.0, hunt = 1.0 } },
  { name = "Siege", weights = { aggression = 0.8, cohesion = 1.4, patience = 1.4, guns = 1.6, flank = 0.7, raid = 0.6, risk = 0.7, hold = 1.2, weakness = 0.9, hunt = 0.8 } },
  { name = "Raider", weights = { aggression = 0.9, cohesion = 0.6, patience = 0.8, guns = 0.9, flank = 1.6, raid = 1.7, risk = 1.0, hold = 0.6, weakness = 1.4, hunt = 1.0 } },
  { name = "Fortress", weights = { aggression = 0.6, cohesion = 1.3, patience = 1.6, guns = 1.2, flank = 0.6, raid = 0.7, risk = 0.6, hold = 1.7, weakness = 0.8, hunt = 0.9 } },
  { name = "Hunter", weights = { aggression = 1.3, cohesion = 1.0, patience = 1.0, guns = 1.0, flank = 1.1, raid = 1.0, risk = 1.1, hold = 0.7, weakness = 1.1, hunt = 1.8 } },
  { name = "Opportunist", weights = { aggression = 1.0, cohesion = 0.9, patience = 1.0, guns = 1.0, flank = 1.3, raid = 1.2, risk = 0.9, hold = 0.9, weakness = 1.8, hunt = 1.1 } },
}
AI2.ARCHETYPES = ARCHETYPES

local VALUE = { armor = 1.0, battery = 0.9, recon = 0.45, aa = 0.6, air = 1.1 }

function AI2.new(world, team, level)
  local self = S.newAIv1(world, team, level)
  setmetatable(self, AI2)
  -- its own dice, different every game (v1's are fixed by the map seed)
  self.rng = love.math.newRandomGenerator(os.time() + team * 7919 + math.floor(love.math.random() * 1e6))
  self.p = B.personality(ARCHETYPES, self.rng, os.getenv("PA_ARCH"))
  self.profileName = "Heroes v2 (" .. self.p.name .. ")"
  self.version = 2
  self.state = { grouping = {}, obj = {} }
  self.mem = {}   -- enemy units it knows about: [unit] = { x, y, t }
  -- how much it knows: the best see everything you do (AI War's omniscience), the rest only what
  -- their side has seen
  self.omniscient = self.level >= 8
  self.announced = false
  return self
end

---------------------------------------------------------------------------
-- Knowledge

local function strengthOf(u)
  local v = VALUE[u.squad and u.squad.type or ""] or 0.7
  return v * (u.hp / u.maxhp) * (u.squadLeader and 1.5 or 1)
end

-- the enemy as this AI knows it: clusters with a position and a strength
function AI2:knownEnemy()
  local w = self.world
  local now = w.time
  for _, o in ipairs(w.entities) do
    if o.alive and o.squad and w:hostile(o.team, self.team) and not o.broken then
      if self.omniscient or S.sees(w, self.team, o.x, o.y) then self.mem[o] = { x = o.x, y = o.y, t = now } end
    end
  end
  local list = {}
  for o, m in pairs(self.mem) do
    if not o.alive or now - m.t > 40 then self.mem[o] = nil
    else list[#list + 1] = { u = o, x = m.x, y = m.y, s = strengthOf(o) } end
  end
  -- cluster (single linkage, 400)
  local groups, used = {}, {}
  for i = 1, #list do
    if not used[i] then
      local g = { x = 0, y = 0, s = 0, n = 0, types = {} }
      local stack = { i }
      used[i] = true
      while #stack > 0 do
        local a = list[table.remove(stack)]
        g.x, g.y, g.s, g.n = g.x + a.x, g.y + a.y, g.s + a.s, g.n + 1
        local ty = a.u.squad and a.u.squad.type
        if ty then g.types[ty] = (g.types[ty] or 0) + 1 end
        for j = 1, #list do
          if not used[j] and U.dist2(a.x, a.y, list[j].x, list[j].y) < 400 * 400 then used[j] = true; stack[#stack + 1] = j end
        end
      end
      g.x, g.y = g.x / g.n, g.y / g.n
      groups[#groups + 1] = g
    end
  end
  return groups
end

local function threatNear(groups, x, y, r)
  local s = 0
  for _, g in ipairs(groups) do
    local d = U.dist(x, y, g.x, g.y)
    if d < r then s = s + g.s * (1 - 0.5 * d / r) end
  end
  return s
end

---------------------------------------------------------------------------
-- Strategy: how to split the force

local function squadsStrength(list)
  local s = 0
  for _, sq in ipairs(list) do for _, u in ipairs(sq.members) do if u.alive then s = s + strengthOf(u) end end end
  return s
end

function AI2:groupingOptions(active, enemy)
  local w, P = self.world, self.p.w
  local n = #active
  local recon, rest = 0, 0
  for _, sq in ipairs(active) do if sq.type == "recon" then recon = recon + 1 else rest = rest + 1 end end
  local ours = squadsStrength(active)
  local theirs = 0
  for _, g in ipairs(enemy) do theirs = theirs + g.s end
  local ratio = ours / math.max(0.1, ours + theirs)
  -- behind on points or tickets: spread out to take more ground
  local behind = 0
  if w.capPoints then
    local me = w.ally[self.team]
    local mine, them = 0, 0
    for _, p in ipairs(w.capPoints) do if p.owner == me then mine = mine + 1 elseif p.owner then them = them + 1 end end
    behind = math.max(0, them - mine) * 0.12
  end
  local opts = {}
  opts[#opts + 1] = { key = "one", label = "one force", score = 0.7 * P.cohesion * (1.3 - ratio * 0.5) }
  if rest >= 3 or (rest >= 2 and n >= 3) then
    opts[#opts + 1] = { key = "two", label = "two forces", score = (0.45 + behind) * (2 - P.cohesion) * (0.6 + ratio) * (n >= 4 and 1 or 0.6) * (w.wih and 0.5 or 1) }
  end
  if recon > 0 and not w.wih then
    opts[#opts + 1] = { key = "raid", label = "scouts raid, rest together", score = (0.5 + behind) * P.raid * (0.8 + 0.4 * ratio) }
    if rest >= 3 then
      opts[#opts + 1] = { key = "tworaid", label = "scouts raid + two forces", score = (0.32 + behind) * P.raid * P.flank * (2 - P.cohesion) * (n >= 5 and 1 or 0.5) * (0.6 + ratio) }
    end
  end
  return opts
end

-- the squads in each group for a grouping choice
local function assign(active, kind, rng)
  local groups = { main = {}, flank = nil, raid = {} }
  local list = {}
  for _, sq in ipairs(active) do list[#list + 1] = sq end
  local raid = kind == "raid" or kind == "tworaid"
  local split = kind == "two" or kind == "tworaid"
  local body = {}
  for _, sq in ipairs(list) do
    if raid and sq.type == "recon" then groups.raid[#groups.raid + 1] = sq else body[#body + 1] = sq end
  end
  if split then
    groups.flank = {}
    -- the guns stay with the main body (and some armor); the rest go with the second group,
    -- in an order that changes from game to game
    local armorKept = false
    for i = #body, 2, -1 do local j = rng:random(i); body[i], body[j] = body[j], body[i] end
    for _, sq in ipairs(body) do
      local t = sq.type
      if t == "battery" or (t == "aa" and #groups.main < 3) or (t == "armor" and not armorKept) then
        groups.main[#groups.main + 1] = sq
        if t == "armor" then armorKept = true end
      else
        groups.flank[#groups.flank + 1] = sq
      end
    end
    if #groups.flank == 0 then groups.flank = nil end
  else
    groups.main = body
  end
  return groups
end

---------------------------------------------------------------------------
-- Operations: what each group goes for

function AI2:objectiveOptions(gname, list, enemy, claimed, ax, ay)
  local w, P = self.world, self.p.w
  local me = w.ally[self.team]
  local ours = squadsStrength(list)
  local opts = {}
  local diag = math.sqrt((w.map.w * w.T) ^ 2 + (w.map.h * w.T) ^ 2)
  local function odds(threat)
    -- how we'd fare: our strength against what's there (personality: risk)
    local r = ours / math.max(0.05, ours + threat)
    return math.max(0.05, r) ^ (1 / math.max(0.4, P.risk))
  end
  local function walk(d)
    return 1 - 0.55 * math.min(1, d / (diag * 0.6)) / math.max(0.5, P.patience)
  end
  -- capture points
  if w.capPoints then
    local tick = w.squads.tickets
    local myT, theirT = tick[me] or 0, 0
    for a, v in pairs(tick) do if a ~= me then theirT = v end end
    local urgency = myT < theirT and 1.15 or 1
    -- a stalemate (no point has changed hands for a while) makes taking their ground matter more
    local snap = ""
    for _, p in ipairs(w.capPoints) do snap = snap .. tostring(p.owner or 0) end
    if snap ~= self.ownSnap then self.ownSnap, self.ownSnapT = snap, w.time end
    local stale = math.max(0, (w.time - (self.ownSnapT or 0)) - 90) / 120
    for i, p in ipairs(w.capPoints) do
      local v
      local slipping = p.owner == me and (p.contested or (p.capBy and p.capBy ~= me and p.amt > 0))
      if p.owner == me and not slipping then v = 0
      elseif slipping then v = 1.25
      elseif p.owner then v = 1.0 + math.min(0.8, stale * 0.5)
      else v = 0.9 end
      if v > 0 then
        local threat = threatNear(enemy, p.x, p.y, 500)
        local s = v * urgency * walk(U.dist(ax, ay, p.x, p.y)) * odds(threat)
        if threat < 0.2 then s = s * (1 + 0.25 * (P.weakness - 1) + 0.15) end
        -- far from where their strength is: a flank
        local far = 0
        for _, g in ipairs(enemy) do far = math.max(far, g.s) end
        if claimed[i] and claimed[i] ~= gname then s = s * 0.45 end
        opts[#opts + 1] = { key = "p" .. i, label = (p.name or ("point " .. i)) .. (p.owner == me and " (defend)" or ""), score = s, x = p.x, y = p.y, point = i }
      end
    end
  end
  -- known enemy groups: attack
  for k, g in ipairs(enemy) do
    local d = U.dist(ax, ay, g.x, g.y)
    if d < diag * 0.55 then
      local s = 0.65 * P.aggression * odds(g.s) * walk(d) * (1 + math.min(0.5, (self.staleK or 0)))
      if (g.types.battery or 0) > 0 then s = s * (1 + 0.35 * (P.hunt - 1) + 0.15) end
      -- an answer to what they brought: no AA there and we have air, etc.
      local have = {}
      for _, sq in ipairs(list) do have[sq.type] = true end
      if have.air and not g.types.aa then s = s * 1.25 end
      if have.battery and (g.types.armor or 0) > 0 and not g.types.recon then s = s * 1.1 end
      if w.wih then s = s * 1.3 end
      opts[#opts + 1] = { key = string.format("e%d_%d", math.floor(g.x / 300), math.floor(g.y / 300)), label = string.format("attack %d men", g.n), score = s, x = g.x, y = g.y }
    end
  end
  -- hold good ground near us (the bunker or hill nearest the anchor)
  local best, bd
  for _, b in ipairs(w.bunkers or {}) do
    local d = U.dist(ax, ay, b.x, b.y)
    if d < 900 and (not bd or d < bd) then best, bd = b, d end
  end
  local hs = 0.3 * P.hold * (1.2 - odds(threatNear(enemy, ax, ay, 900)))
  if w.wih then hs = hs * 1.4 end
  if best then opts[#opts + 1] = { key = "hold", label = "hold the bunker", score = hs, x = best.x, y = best.y, hold = true } end
  -- War is Hell with nothing seen: sweep a sector
  if w.wih and #enemy == 0 then
    self.sectors = self.sectors or {}
    for k = 1, 3 do
      local sec = self.sectors[k]
      if not sec or U.dist(ax, ay, sec.x, sec.y) < 300 then
        local W, H = w.map.w * w.T, w.map.h * w.T
        sec = { x = self.rng:random(250, W - 250), y = self.rng:random(250, H - 250) }
        self.sectors[k] = sec
      end
      local d = U.dist(ax, ay, sec.x, sec.y)
      opts[#opts + 1] = { key = "s" .. k, label = "sweep", score = 0.45 * walk(d) * (0.7 + 0.6 * P.aggression), x = sec.x, y = sec.y }
    end
  end
  return opts
end

local function groupPlanFor(list, obj)
  local by, cx, cy, n = {}, 0, 0, 0
  for _, sq in ipairs(list) do
    by[sq.type] = by[sq.type] or sq
    cx, cy, n = cx + sq.leader.x, cy + sq.leader.y, n + 1
  end
  local A = by.armor and by.armor.leader
  local ax, ay = A and A.x or cx / n, A and A.y or cy / n
  local dx, dy = U.norm(obj.x - ax, obj.y - ay)
  if dx == 0 and dy == 0 then dx = 1 end
  return { by = by, ax = ax, ay = ay, obj = obj, dx = dx, dy = dy }
end

local function anchorOf(list)
  local cx, cy, n = 0, 0, 0
  for _, sq in ipairs(list) do
    if sq.type == "armor" then return sq.leader.x, sq.leader.y end
    cx, cy, n = cx + sq.leader.x, cy + sq.leader.y, n + 1
  end
  return cx / n, cy / n
end

function AI2:makePlan(mine)
  local w = self.world
  if not self.announced and w.tel then
    self.announced = true
    local names = {}
    for _, sq in ipairs(mine) do names[#names + 1] = sq.type end
    Tel.note(w, "personality", self.team, string.format("%s, level %d%s; army %s", self.p.name, self.level,
      self.omniscient and ", sees everything" or "", table.concat(names, "+")))
  end
  local active = {}
  for _, sq in ipairs(mine) do
    if sq.leader and sq.leader.alive and not sq.broken and not sq.healing then active[#active + 1] = sq end
  end
  if #active == 0 then return nil end
  local enemy = self:knownEnemy()
  -- strategy (re-decided now and then)
  local gopts = self:groupingOptions(active, enemy)
  local g, changed = B.commit(self.state.grouping, gopts, self.level, self.rng, w.time, { reconsider = 60, minHold = 25, margin = 1.3 })
  if changed then Tel.note(w, "strategy", self.team, B.explain(gopts, g)) end
  local groups = assign(active, g and g.key or "one", self.rng)
  local plan = { of = {} }
  local claimed = {}
  for _, gname in ipairs({ "main", "flank" }) do
    local list = groups[gname]
    if list and #list > 0 then
      local ax, ay = anchorOf(list)
      local opts = self:objectiveOptions(gname, list, enemy, claimed, ax, ay)
      self.state.obj[gname] = self.state.obj[gname] or {}
      local o, ch = B.commit(self.state.obj[gname], opts, self.level, self.rng, w.time, { reconsider = 40, minHold = 10 })
      if o then
        if o.point then claimed[o.point] = gname end
        if ch then Tel.note(w, "objective", self.team, string.format("%s (%d squads): %s", gname, #list, B.explain(opts, o))) end
        local gp = groupPlanFor(list, { x = o.x, y = o.y, hold = o.hold, point = o.point })
        gp.stance = self:chooseStance(gname, list, enemy, gp)
        for _, sq in ipairs(list) do plan.of[sq] = gp end
      end
    end
  end
  -- scouts on a raid: each picks a point (weighted, not just the nearest)
  for _, sq in ipairs(groups.raid) do
    local opts = {}
    local me = w.ally[self.team]
    for i, p in ipairs(w.capPoints or {}) do
      if not (p.owner == me and not p.contested) then
        local threat = threatNear(enemy, p.x, p.y, 450)
        local s = (p.owner and 1 or 0.9) / (1 + threat * 2) * (1 - 0.5 * math.min(1, U.dist(sq.leader.x, sq.leader.y, p.x, p.y) / 2500))
        if claimed[i] then s = s * 0.4 end
        opts[#opts + 1] = { key = "p" .. i, label = p.name or ("point " .. i), score = s, x = p.x, y = p.y, point = i }
      end
    end
    sq.v2raid = sq.v2raid or {}
    local o, ch = B.commit(sq.v2raid, opts, self.level, self.rng, w.time, { reconsider = 35, minHold = 8 })
    if o then
      claimed[o.point] = "raid"
      if ch then Tel.note(w, "raid", self.team, string.format("scouts (squad %d): %s", sq.idx, B.explain(opts, o))) end
      plan.of[sq] = { raid = true, obj = { x = o.x, y = o.y } }
    end
  end
  return plan
end

---------------------------------------------------------------------------
-- Tactics: how a group fights once it's in contact. Push into them, hold where it is (and let
-- them come onto the guns), fall back to the guns, or swing round the side

function AI2:chooseStance(gname, list, enemy, gp)
  local w, P = self.world, self.p.w
  local threat, near = 0, nil
  for _, g in ipairs(enemy) do
    local d = U.dist(gp.ax, gp.ay, g.x, g.y)
    if d < 650 then threat = threat + g.s; if not near or d < near.d then near = { g = g, d = d } end end
  end
  self.state.stance = self.state.stance or {}
  local st = self.state.stance[gname] or {}
  self.state.stance[gname] = st
  if not near then st.choice = nil; return nil end
  local ours = squadsStrength(list)
  local odds = ours / math.max(0.05, ours + threat)
  local have = {}
  for _, sq in ipairs(list) do have[sq.type] = true end
  local inBunker = false
  for _, b in ipairs(w.bunkers or {}) do if U.dist(gp.ax, gp.ay, b.x, b.y) < b.r + 40 then inBunker = true end end
  local opts = {
    { key = "push", label = "push", score = 0.6 * P.aggression * (0.4 + odds) * (P.risk ^ 0.5) },
    { key = "hold", label = "hold", score = 0.45 * P.hold * (have.battery and 1.3 or 0.9) * (inBunker and 1.5 or 1) * (1.2 - 0.4 * odds) },
    { key = "fallback", label = "fall back to the guns", score = (have.battery and 0.5 or 0.25) * P.guns * (1.3 - odds) / math.max(0.5, P.risk) },
    { key = "flank", label = "flank", score = 0.38 * P.flank * (0.5 + odds) * ((have.air or have.recon) and 1.3 or 1) },
  }
  local o, ch = B.commit(st, opts, self.level, self.rng, w.time, { reconsider = 18, minHold = 6, margin = 1.35 })
  if ch and o then Tel.note(w, "stance", self.team, string.format("%s vs %d men: %s", gname, near.g.n, B.explain(opts, o))) end
  if not o then return nil end
  local stance = { key = o.key, fx = near.g.x, fy = near.g.y }
  if o.key == "flank" then
    -- swing round the side away from the rest of their force (or a side picked by the dice)
    local dx, dy = U.norm(near.g.x - gp.ax, near.g.y - gp.ay)
    st.side = st.side or (self.rng:random() < 0.5 and 1 or -1)
    stance.x, stance.y = near.g.x - dx * 120 + (-dy) * st.side * 260, near.g.y - dy * 120 + dx * st.side * 260
  end
  return stance
end

-- v1's role tactics, bent by the group's stance while in contact
function AI2:roleGoal(sq, plan, foe, fd, fighting)
  local gp = plan and plan.of and plan.of[sq]
  local g = S.AI.roleGoal(self, sq, plan, foe, fd, fighting)
  local st = gp and gp.stance
  if not st or not g or gp.raid then return g end
  local L = sq.leader
  local t = sq.type
  if t == "battery" or t == "aa" or t == "recon" then return g end
  if st.key == "hold" then
    if foe and fd < 150 then return g end -- (something's on top of us: fight it)
    return { role = true, x = L.x, y = L.y }
  elseif st.key == "fallback" then
    local bat = gp.by.battery and gp.by.battery.leader
    if bat and U.dist(L.x, L.y, bat.x, bat.y) > 160 then
      return { role = true, x = bat.x + (L.x - bat.x) * 0.3, y = bat.y + (L.y - bat.y) * 0.3, move = U.dist(L.x, L.y, bat.x, bat.y) > 350 }
    end
    return { role = true, x = L.x, y = L.y }
  elseif st.key == "flank" and st.x then
    if U.dist(L.x, L.y, st.x, st.y) > 140 then return { role = true, x = st.x, y = st.y, move = fd and fd > 260 } end
    return g
  end
  return g -- push: v1's own (straight at them)
end

---------------------------------------------------------------------------
-- Army: chosen against yours (AI War's waves aimed at what you lack)

local COUNTER = {
  air = function(o) return 0.35 + ((o.aa or 0) == 0 and 0.9 or -0.45 * (o.aa or 0)) - 0.15 * (o.recon or 0) end,
  aa = function(o) return (o.air or 0) > 0 and 0.9 * (o.air or 0) or -0.4 end,
  battery = function(o) return 0.45 + 0.15 * (o.armor or 0) - 0.2 * (o.recon or 0) - 0.15 * (o.air or 0) end,
  armor = function(o) return 0.55 + 0.12 * (o.recon or 0) + 0.1 * (o.battery or 0) end,
  recon = function(o) return 0.3 + 0.2 * (o.battery or 0) end,
}

function AI2.pickArmy(world, rng, n, oppTypes, level)
  local opp = {}
  for _, t in ipairs(oppTypes) do opp[t] = (opp[t] or 0) + 1 end
  local opts = {}
  for k = 1, 12 do
    local d = S.randomSquads(rng, n)
    local s, have = 0, {}
    for _, ds in ipairs(d) do
      s = s + (COUNTER[ds.type] or function() return 0.3 end)(opp)
      have[ds.type] = (have[ds.type] or 0) + 1
    end
    -- some variety in itself is worth something; three of one kind rarely is
    for _, c in pairs(have) do if c >= 3 then s = s - 0.4 end end
    local names = {}
    for _, ds in ipairs(d) do names[#names + 1] = ds.type end
    opts[#opts + 1] = { key = "c" .. k, label = table.concat(names, "+"), score = math.max(0.05, s), designs = d }
  end
  local pick = B.pick(opts, level, rng, 0.6)
  return pick and pick.designs or S.randomSquads(rng, n)
end

return AI2
