-- Commander of Heroes: Company of Heroes rules on Annihilation's units. No economy, no
-- Commander. Each side has a Field HQ and two or three squads designed before the match. Every
-- squad is led by a veteran of its type (an Armor squad by a Tank, a Battery by an Artillery
-- piece...) who carries two skills on cooldowns (Q / W). Capture points on the map: hold more of
-- them than the enemy and their tickets drain. Losses cost tickets too. Fallen squad members are
-- replaced at the HQ (faster the more points you hold); a fallen leader returns after 45 s.
-- Win when the enemy's tickets run out or their HQ falls.
local U = require("src.util")
local D = require("src.defs")

local S = {}

-- Squads are all one kind of unit, led by a veteran of that kind: a tank squad is all tanks.
-- size counts the leader. Aircraft can't take points; only one air squad a side.
S.SLOTS = 5             -- squads you can field (at least 2)
S.MAX_AIR = 1
S.TYPES = {
  { key = "armor", name = "Armor", unit = "tank", size = 4, skills = { "hulldown", "smoke" },
    desc = "Four Tanks. Holds ground, soaks fire, takes points." },
  { key = "battery", name = "Battery", unit = "artillery", size = 3, skills = { "barrage", "spotter" },
    desc = "Three Artillery pieces. Breaks up anything your side can see - keep them behind the tanks." },
  { key = "recon", name = "Recon", unit = "scout", size = 5, skills = { "flare", "sprint" },
    desc = "Five Scouts. Fast, sees far, and carries light anti-air guns: spotting, flanking and grabbing empty points." },
  { key = "aa", name = "Air Defense", unit = "flak", size = 3, skills = { "flakburst", "repair" },
    desc = "Three Flak Trucks. Shuts down aircraft; Field Repair patches up whoever stands nearby." },
  { key = "air", name = "Gunships", unit = "gunship", size = 3, skills = { "strafe", "afterburner" },
    desc = "Three Gunships. Hit anywhere fast - but they can't take points (one air squad a side)." },
}
for _, t in ipairs(S.TYPES) do t.leader = t.unit end
S.byType = {}
for _, t in ipairs(S.TYPES) do S.byType[t.key] = t end

-- aim: "self" (around the leader) or "point" (at the mouse, within range of the leader)
S.SKILLS = {
  hulldown = { name = "Hull Down", aim = "self", dur = 12, cd = 35,
    desc = "12 s: the squad digs in - 35% less damage taken, half speed." },
  smoke = { name = "Smoke Screen", aim = "self", dur = 8, cd = 40,
    desc = "8 s: smoke hides the squad - nothing further than 90 away can target it, and whatever was shooting at it loses it." },
  barrage = { name = "Barrage", aim = "point", range = 950, cd = 45, needSight = true,
    desc = "Six shells on a spot your side can see (within 950 of the leader)." },
  spotter = { name = "Spotter Drone", aim = "self", dur = 15, cd = 35,
    desc = "15 s: the squad sees 60% further - artillery reaches everything it sees." },
  flare = { name = "Flare", aim = "point", range = 1200, dur = 10, cd = 30,
    desc = "10 s: lights up a wide area anywhere within 1200 - fog lifted for your side." },
  sprint = { name = "Sprint", aim = "self", dur = 6, cd = 30,
    desc = "6 s: the squad moves 50% faster." },
  flakburst = { name = "Flak Barrage", aim = "point", range = 600, cd = 30,
    desc = "A storm of flak at a spot within 600: heavy damage to every aircraft there." },
  repair = { name = "Field Repair", aim = "self", dur = 10, cd = 40,
    desc = "10 s: the squad around the leader repairs 3% a second." },
  strafe = { name = "Strafing Run", aim = "point", range = 450, cd = 30,
    desc = "The leader rakes a line toward the mouse: damage to everything on the ground along it." },
  afterburner = { name = "Afterburner", aim = "self", dur = 6, cd = 30,
    desc = "6 s: the squad moves 60% faster and fires 30% faster." },
}

S.RADIUS = 280          -- skills reach squad members this close to their leader
S.HQ_HEAL = 0.05        -- per second, near your HQ
S.HQ_RANGE = 320
S.FIELD_HEAL = 0.006    -- per second anywhere, after 6 s without being hit
S.LEADER_RESPAWN = 45
S.REINFORCE = 30        -- a fallen member is replaced at the HQ this long after (less when holding points)
S.TICKETS = 1000
S.DRAIN = 0.4         -- tickets a second per point of difference
S.CAP_R = 160           -- capture radius
S.CAP_TIME = 14         -- seconds for one unit to take a neutral point
S.HQ_HP = 16000
S.HP_MUL = 1.6          -- squad units are this much tougher than in Annihilation

-- saved setups from older versions (mixed squads) keep only their type
function S.fixDesign(ds)
  if not S.byType[ds.type or ""] then ds.type = "armor" end
  ds.units = nil
  return ds
end

function S.defaults()
  return {
    { on = true, type = "armor" },
    { on = true, type = "armor" },
    { on = true, type = "battery" },
    { on = true, type = "recon" },
    { on = true, type = "aa" },
  }
end

-- anything in this setup that can shoot aircraft?
function S.hasAntiAir(list)
  for _, ds in ipairs(list or {}) do
    if ds.on and (ds.type == "aa" or ds.type == "recon" or ds.type == "air") then return true end
  end
  return false
end

-- the setup is legal: 2-5 squads, at most one air squad
function S.validSetup(list)
  local n, air = 0, 0
  for _, ds in ipairs(list or {}) do
    if ds.on then n = n + 1; if ds.type == "air" then air = air + 1 end end
  end
  return n >= 2 and air <= S.MAX_AIR, n, air
end

-- the computer's squads: a tank core, then a mix (an air squad now and then, flak if we fly)
function S.randomSquads(rng, n)
  local out = { { type = "armor" } }
  local pool = { "armor", "armor", "battery", "recon", "battery", "aa", "air" }
  local air = false
  while #out < n do
    local k = pool[rng:random(#pool)]
    if k == "air" and air then k = "armor" end
    if k == "air" then air = true end
    out[#out + 1] = { type = k }
  end
  return out
end

---------------------------------------------------------------------------
-- Setup

local function place(world, x, y, layer)
  local map = world.map
  local tx, ty = map:tileAt(x, y)
  if not layer then return x, y end
  local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable(layer, a, b) end, 14)
  if nx then return map:center(nx, ny) end
  return x, y
end

-- every squad unit: tougher than in Annihilation (fights last long enough to use skills), Recon
-- carries light anti-air guns, and the leader is a veteran
local function prep(u, sq, leader)
  u.squad = sq
  u.hpMul = S.HP_MUL * (leader and 1.75 or 1)
  u.maxhp = math.floor(u.def.hp * (1 + 0.10 * (u.level or 0)) * u.hpMul); u.hp = u.maxhp
  u.mods = u.mods or {}
  if leader then u.mods.dmg = 1.25 end
  if sq.type == "recon" then u.mods.hitsAir = true end
end

local function makeLeader(world, sq, t, x, y)
  local ty = S.byType[sq.type]
  local L = world:spawn(ty.leader, t, x, y)
  L.homeX, L.homeY = x, y
  L.squad, L.squadLeader = sq, true
  L.genName = ty.name .. " Leader"
  prep(L, sq, true)
  sq.leader = L
  sq.members[#sq.members + 1] = L
  return L
end

-- capture points: one in front of each base, the middle, and the two flanks
local function setupPoints(world)
  local map = world.map
  local ax, ay, an, bx, by, bn = 0, 0, 0, 0, 0, 0
  for t = 1, world.np do
    local tm = world.teams[t]
    if world.ally[t] == world.ally[1] then ax, ay, an = ax + tm.startX, ay + tm.startY, an + 1
    else bx, by, bn = bx + tm.startX, by + tm.startY, bn + 1 end
  end
  ax, ay, bx, by = ax / an, ay / an, bx / math.max(1, bn), by / math.max(1, bn)
  local dx, dy, len = U.norm(bx - ax, by - ay)
  local px, py = -dy, dx
  local W = math.min(map.w, map.h) * world.T
  local allyB
  for t = 1, world.np do if world.ally[t] ~= world.ally[1] then allyB = world.ally[t] end end
  local spec = {
    { f = 0.24, s = 0, owner = world.ally[1], name = "A" },
    { f = 0.5, s = -0.3, name = "B" },
    { f = 0.5, s = 0, name = "C" },
    { f = 0.5, s = 0.3, name = "D" },
    { f = 0.76, s = 0, owner = allyB, name = "E" },
  }
  world.capPoints = {}
  for _, sp in ipairs(spec) do
    local x = ax + dx * len * sp.f + px * W * sp.s
    local y = ay + dy * len * sp.f + py * W * sp.s
    x = U.clamp(x, 300, map.w * world.T - 300)
    y = U.clamp(y, 300, map.h * world.T - 300)
    x, y = place(world, x, y, "land")
    world.capPoints[#world.capPoints + 1] = { x = x, y = y, owner = sp.owner, capBy = nil, amt = 0, name = sp.name }
  end
end

function S.setup(world, opts)
  local map = world.map
  world.squads = { list = {}, tickets = {}, pending = {} }
  world.visionSources = world.visionSources or {}
  local rng = love.math.newRandomGenerator((map.seed or 1) + 911)
  for t = 1, world.np do
    local tm = world.teams[t]
    -- each side's pool grows with its size (2v2: twice the squads, half again the tickets)
    local size = 0
    for t2 = 1, world.np do if world.ally[t2] == world.ally[t] then size = size + 1 end end
    world.squads.tickets[world.ally[t]] = S.TICKETS * (1 + 0.5 * (size - 1))
    -- the HQ where the Commander would stand
    local tx, ty = map:tileAt(tm.startX, tm.startY)
    local hq
    for r = 0, 8 do
      for a = 0, 7 do
        if hq then break end
        local x, y = math.floor(tx + math.cos(a * 0.785) * r) - 1, math.floor(ty + math.sin(a * 0.785) * r) - 1
        if world:canPlace("hq", x, y, t) then hq = world:spawn("hq", t, (x + 1.5) * world.T, (y + 1.5) * world.T) end
      end
      if hq then break end
    end
    if hq then hq.maxhp = S.HQ_HP; hq.hp = S.HQ_HP end
    tm.hq = hq
    -- squads: the human's own designs, the computer's at random (as many as the human fields)
    local designs = {}
    local human = opts.players and opts.players[t] and opts.players[t].human
    local nOn = 0
    for _, s in ipairs(opts.squadSetup or {}) do if s.on then nOn = nOn + 1 end end
    if human and opts.squadSetup then
      for _, sq in ipairs(opts.squadSetup) do if sq.on then designs[#designs + 1] = S.fixDesign(sq) end end
    else
      designs = S.randomSquads(rng, math.max(2, nOn > 0 and nOn or 4))
      -- facing air (the human's setup is known): make sure something here shoots it down
      local enemyAir = false
      for _, ds in ipairs(opts.squadSetup or {}) do if ds.on and ds.type == "air" then enemyAir = true end end
      if enemyAir and not S.hasAntiAir(designs) then designs[#designs].type = "aa" end
    end
    -- toward the middle of the map: that's where the squads stand ready
    local mx, my = map.w * world.T / 2, map.h * world.T / 2
    local dx, dy = U.norm(mx - tm.startX, my - tm.startY)
    local px, py = -dy, dx
    for i, ds in ipairs(designs) do
      local off = (i - (#designs + 1) / 2) * 170
      local cx, cy = tm.startX + dx * 260 + px * off, tm.startY + dy * 260 + py * off
      local ty2 = S.byType[ds.type]
      local sq = { team = t, idx = i, type = ds.type, members = {},
        skills = { { key = ty2.skills[1], readyAt = 0, untilT = 0 }, { key = ty2.skills[2], readyAt = 0, untilT = 0 } } }
      local lx, ly = place(world, cx, cy, D.units[ty2.leader].domain == "air" and nil or "land")
      makeLeader(world, sq, t, lx, ly)
      -- the rest of the squad: the same kind of unit, around the leader
      local d = D.units[ty2.unit]
      for n = 1, ty2.size - 1 do
        local a = n * 2.1
        local x, y = place(world, cx + math.cos(a) * (55 + n * 6), cy + math.sin(a) * (55 + n * 6), d.domain == "air" and nil or "land")
        local u = world:spawn(ty2.unit, t, x, y)
        u.homeX, u.homeY = x, y
        prep(u, sq)
        sq.members[#sq.members + 1] = u
      end
      world.squads.list[#world.squads.list + 1] = sq
    end
  end
  setupPoints(world)
  world.parTime = 18 * 60
end

function S.squadsOf(world, team)
  local out = {}
  for _, sq in ipairs(world.squads and world.squads.list or {}) do if sq.team == team then out[#out + 1] = sq end end
  return out
end

-- members still to come: waiting at the HQ, or walking out to the leader
function S.coming(sq)
  local n = #(sq.queue or {})
  for _, u in ipairs(sq.members) do if u.alive and u.rejoining then n = n + 1 end end
  return n
end

function S.held(world, ally)
  local n = 0
  for _, p in ipairs(world.capPoints or {}) do if p.owner == ally then n = n + 1 end end
  return n
end

---------------------------------------------------------------------------
-- Skills

-- can this side see the spot? (any friendly unit/building close enough, or a flare)
function S.sees(world, team, x, y)
  local seen = false
  world:query(x, y, 520, function(f)
    if not seen and f.alive and f.team and world.ally[f.team] == world.ally[team] and f.def.sight
      and U.dist2(f.x, f.y, x, y) <= world:sightOf(f) ^ 2 then seen = true end
  end)
  if seen then return true end
  for _, v in ipairs(world.visionSources or {}) do
    if v.ally == world.ally[team] and world.time < v.untilT and U.dist2(v.x, v.y, x, y) <= v.r * v.r then return true end
  end
  return false
end

local function hurt(world, src, x, y, r, dmg, pred)
  local hits = {}
  world:query(x, y, r + 30, function(o)
    if o.alive and o.team and o.team > 0 and world:hostile(o.team, src.team) and U.dist2(o.x, o.y, x, y) <= (r + o.def.radius) ^ 2
      and (not pred or pred(o)) then hits[#hits + 1] = o end
  end)
  for _, o in ipairs(hits) do world:damage(o, o.def.building and dmg * 0.5 or dmg, src.alive and src or nil) end
end

local function later(world, dt, fn)
  local st = world.squads
  st.pending[#st.pending + 1] = { at = world.time + dt, fn = fn }
end

-- returns true when cast, or false and a reason
function S.cast(world, sq, slot, tx, ty)
  local L = sq.leader
  if not L or not L.alive then return false, "Leader is down" end
  local s = sq.skills[slot]
  if not s then return false, "No skill" end
  local def = S.SKILLS[s.key]
  local t = world.time
  if t < s.readyAt then return false, string.format("%s ready in %ds", def.name, math.ceil(s.readyAt - t)) end
  if def.aim == "point" then
    tx, ty = tx or L.x, ty or L.y
    local d = U.dist(L.x, L.y, tx, ty)
    if d > def.range then
      -- out of reach: as far as it goes, toward the spot
      local nx, ny = U.norm(tx - L.x, ty - L.y)
      tx, ty = L.x + nx * def.range, L.y + ny * def.range
    end
    if def.needSight and not S.sees(world, sq.team, tx, ty) then return false, def.name .. ": you need eyes on that spot" end
  end
  s.readyAt = t + def.cd
  if def.dur then s.untilT = t + def.dur end
  local fx = world.effects
  if s.key == "barrage" then
    for i = 1, 6 do
      later(world, 0.9 + i * 0.45, function()
        local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * 120
        local x, y = tx + math.cos(a) * r, ty + math.sin(a) * r
        hurt(world, L, x, y, 70, 95, function(o) return o.def.domain ~= "air" end)
        fx[#fx + 1] = { kind = "boom", x = x, y = y, t = 0, life = 0.6, size = 60 }
      end)
    end
    fx[#fx + 1] = { kind = "ping", x = tx, y = ty, t = 0, life = 1.6, r = 1, g = 0.5, b = 0.2 }
  elseif s.key == "flare" then
    world.visionSources[#world.visionSources + 1] = { x = tx, y = ty, r = 480, untilT = t + def.dur, ally = world.ally[sq.team], flare = true }
    world.fogDirty = true
    fx[#fx + 1] = { kind = "ping", x = tx, y = ty, t = 0, life = 1.2, r = 1, g = 0.95, b = 0.5 }
  elseif s.key == "flakburst" then
    for i = 1, 4 do
      later(world, 0.3 + i * 0.2, function()
        hurt(world, L, tx, ty, 220, 75, function(o) return o.def.domain == "air" end)
        local a = math.random() * math.pi * 2
        fx[#fx + 1] = { kind = "boom", x = tx + math.cos(a) * 90, y = ty + math.sin(a) * 90, t = 0, life = 0.5, size = 50 }
      end)
    end
  elseif s.key == "strafe" then
    local sx, sy = L.x, L.y
    local nx, ny, len = U.norm(tx - sx, ty - sy)
    len = math.max(len, 200)
    for i = 1, 6 do
      later(world, 0.2 + i * 0.12, function()
        local x, y = sx + nx * len * i / 6, sy + ny * len * i / 6
        hurt(world, L, x, y, 55, 45, function(o) return o.def.domain ~= "air" end)
        fx[#fx + 1] = { kind = "boom", x = x, y = y, t = 0, life = 0.4, size = 34 }
      end)
    end
  end
  if world.onSquadSkill then world.onSquadSkill(sq, slot) end
  return true
end

function S.active(sq, key, t)
  for _, s in ipairs(sq.skills) do if s.key == key and t < s.untilT then return true end end
  return false
end

---------------------------------------------------------------------------
-- Per frame: skills, healing, reinforcements, points, tickets, defeat

function S.update(world, dt)
  local st = world.squads
  if not st then return end
  local t = world.time
  -- delayed skill effects (shells in flight...)
  for i = #st.pending, 1, -1 do
    local p = st.pending[i]
    if t >= p.at then table.remove(st.pending, i); p.fn() end
  end
  for i = #world.visionSources, 1, -1 do
    if t >= world.visionSources[i].untilT then table.remove(world.visionSources, i); world.fogDirty = true end
  end
  for _, sq in ipairs(st.list) do
    local ally = world.ally[sq.team]
    local held = S.held(world, ally)
    -- a fallen leader comes back at the HQ
    if sq.leader and not sq.leader.alive then
      local hq = world.teams[sq.team].hq
      if not sq.respawnAt then
        sq.respawnAt = t + S.LEADER_RESPAWN
        st.tickets[ally] = (st.tickets[ally] or 0) - 6; st.byLoss = (st.byLoss or 0) + 6
        for _, s in ipairs(sq.skills) do s.untilT = 0 end
        if world.onSquadLeaderDown then world.onSquadLeaderDown(sq) end
      elseif t >= sq.respawnAt and hq and hq.alive then
        local air = D.units[S.byType[sq.type].leader].domain == "air"
        local x, y = place(world, hq.x, hq.y + 110, air and nil or "land")
        local old = sq.leader
        local L = makeLeader(world, sq, sq.team, x, y)
        sq.respawnAt = nil
        if world.teams[sq.team].commander == old then world.teams[sq.team].commander = L end
        if world.onSquadLeaderBack then world.onSquadLeaderBack(sq) end
      end
    end
    -- fallen members are replaced at the HQ after a while and rejoin their leader
    sq.queue = sq.queue or {}
    local wait = S.REINFORCE * U.clamp(1.3 - 0.12 * held, 0.6, 1.3)
    for i = #sq.members, 1, -1 do
      local u = sq.members[i]
      if not u.alive and not u.squadLeader then
        table.remove(sq.members, i)
        st.tickets[ally] = (st.tickets[ally] or 0) - 1; st.byLoss = (st.byLoss or 0) + 1
        local w = D.units[u.key].weapon
        local aa = w and w.targets.air and not w.targets.land
        sq.queue[#sq.queue + 1] = { key = u.key, at = t + (aa and wait / 2 or wait) }
      elseif not u.alive and u.squadLeader and u ~= sq.leader then
        table.remove(sq.members, i) -- an old leader's body
      end
    end
    local hq0 = world.teams[sq.team].hq
    for i = #sq.queue, 1, -1 do
      local q = sq.queue[i]
      if t >= q.at and hq0 and hq0.alive then
        table.remove(sq.queue, i)
        local d = D.units[q.key]
        local x, y = place(world, hq0.x + (math.random() - 0.5) * 160, hq0.y + 120, d.domain == "air" and nil or "land")
        local u = world:spawn(q.key, sq.team, x, y)
        u.homeX, u.homeY = x, y
        prep(u, sq)
        u.rejoining = true
        sq.members[#sq.members + 1] = u
        if sq.leader and sq.leader.alive then world:issue(u, { type = "move", x = sq.leader.x, y = sq.leader.y }) end
        if world.onSquadReinforced then world.onSquadReinforced(sq, u) end
      end
    end
    -- replacements walk out to wherever the leader is now, then they're back in the squad
    if sq.leader and sq.leader.alive then
      local L = sq.leader
      for _, u in ipairs(sq.members) do
        if u.alive and u.rejoining then
          if U.dist2(u.x, u.y, L.x, L.y) < 260 * 260 then
            u.rejoining = nil
          elseif #u.orders == 0 or (u.orders[1].type == "move" and U.dist2(u.orders[1].x, u.orders[1].y, L.x, L.y) > 250 * 250) then
            world:issue(u, { type = "move", x = L.x, y = L.y, arrive = 120 })
          end
        end
      end
    end
    -- skill effects on the squad around the leader
    local L = sq.leader
    local alive = L and L.alive
    local hull = alive and S.active(sq, "hulldown", t)
    local smoke = alive and S.active(sq, "smoke", t)
    local spot = alive and S.active(sq, "spotter", t)
    local sprint = alive and S.active(sq, "sprint", t)
    local burn = alive and S.active(sq, "afterburner", t)
    local rep = alive and S.active(sq, "repair", t)
    for _, u in ipairs(sq.members) do
      if u.alive then
        local on = alive and U.dist2(u.x, u.y, L.x, L.y) <= S.RADIUS * S.RADIUS
        u.sqTaken = (on and hull) and 0.65 or nil
        local sp = 1
        if on and hull then sp = sp * 0.5 end
        if on and smoke then sp = sp * 0.85 end
        if on and sprint then sp = sp * 1.5 end
        if on and burn then sp = sp * 1.6 end
        u.sqSpeed = sp ~= 1 and sp or nil
        u.sqSight = (on and spot) and 1.6 or nil
        u.sqRof = (on and burn) and 1.3 or nil
        u.smoked = (on and smoke) or nil
        if on and rep and u.hp < u.maxhp then
          u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.03 * dt); u.healing = 0.3
        end
      end
    end
  end
  -- healing: slow anywhere after a pause, fast beside the HQ
  for _, e in ipairs(world.entities) do
    if e.alive and not e.def.building and e.team and e.team > 0 and e.hp < e.maxhp then
      local hq = world.teams[e.team].hq
      if hq and hq.alive and U.dist2(e.x, e.y, hq.x, hq.y) < S.HQ_RANGE * S.HQ_RANGE then
        e.hp = math.min(e.maxhp, e.hp + e.maxhp * S.HQ_HEAL * dt); e.healing = 0.3
      elseif t - (e.lastHit or -99) > 6 then
        e.hp = math.min(e.maxhp, e.hp + e.maxhp * S.FIELD_HEAL * dt)
      end
    end
  end
  -- capture points: ground units only; an enemy-held point is neutralised first, then taken
  st.capT = (st.capT or 0) - dt
  if st.capT <= 0 then
    local step = 0.25 - st.capT
    st.capT = 0.25
    for _, p in ipairs(world.capPoints or {}) do
      local cnt, who, n = {}, nil, 0
      world:query(p.x, p.y, S.CAP_R + 20, function(o)
        if o.alive and o.team and o.team > 0 and not o.def.building and o.def.domain ~= "air" and not o.neutral
          and U.dist2(o.x, o.y, p.x, p.y) <= S.CAP_R * S.CAP_R then
          local a = world.ally[o.team]
          if not cnt[a] then cnt[a] = 0; n = n + 1 end
          cnt[a] = cnt[a] + 1
          who = a
        end
      end)
      p.contested = n > 1
      if n == 1 and p.owner ~= who then
        if p.capBy ~= who then p.capBy, p.amt = who, 0 end
        p.amt = p.amt + step / S.CAP_TIME * math.min(2, 1 + 0.25 * (cnt[who] - 1))
        if p.amt >= 1 then
          if p.owner then
            p.owner, p.amt = nil, 0 -- neutralised; keep going
            if world.onPointLost then world.onPointLost(p) end
          else
            p.owner, p.amt, p.capBy = who, 0, nil
            if world.onPointTaken then world.onPointTaken(p, who) end
          end
        end
      elseif n == 0 then
        p.amt = math.max(0, p.amt - step * 0.05)
      end
    end
  end
  -- tickets: the side holding more points drains the other (0.4 a second per point of difference)
  st.tickT = (st.tickT or 0) - dt
  if st.tickT <= 0 then
    st.tickT = 1
    local allies = {}
    for a in pairs(st.tickets) do allies[#allies + 1] = a end
    if #allies == 2 then
      local a, b = allies[1], allies[2]
      local d = (S.held(world, a) - S.held(world, b)) * S.DRAIN
      if d > 0 then st.tickets[b] = st.tickets[b] - d elseif d < 0 then st.tickets[a] = st.tickets[a] + d end
      st.byDrain = (st.byDrain or 0) + math.abs(d)
    end
  end
  -- defeat: the HQ is gone, or the tickets ran out
  st.checkT = (st.checkT or 0) - dt
  if st.checkT <= 0 then
    st.checkT = 0.5
    for tt = 1, world.np do
      local tm = world.teams[tt]
      if not tm.dead and (not (tm.hq and tm.hq.alive) or (st.tickets[world.ally[tt]] or 1) <= 0) then
        if os.getenv("PA_SQDBG") then print("SQOUT", tt, math.floor(world.time), st.tickets[world.ally[tt]], "drain", math.floor(st.byDrain or 0), "losses", st.byLoss or 0) end
        world:eliminate(tt)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Drawing: capture points (world) and on the minimap

function S.draw(world, cam)
  local lg = love.graphics
  local cols = (world.mods and world.mods.groovy) and D.groovyColor or D.teamColor
  for _, p in ipairs(world.capPoints or {}) do
    local oc = { 0.85, 0.85, 0.85 }
    if p.owner then
      for t = 1, world.np do if world.ally[t] == p.owner then oc = cols[t]; break end end
    end
    lg.setColor(oc[1], oc[2], oc[3], 0.09)
    lg.circle("fill", p.x, p.y, S.CAP_R)
    lg.setLineWidth(2)
    lg.setColor(oc[1], oc[2], oc[3], p.contested and (0.5 + 0.4 * math.sin(world.time * 8)) or 0.7)
    lg.circle("line", p.x, p.y, S.CAP_R)
    -- progress arc in the capturer's color
    if p.capBy and p.amt > 0 then
      local cc = { 1, 1, 1 }
      for t = 1, world.np do if world.ally[t] == p.capBy then cc = cols[t]; break end end
      lg.setColor(cc[1], cc[2], cc[3], 0.95)
      lg.setLineWidth(5)
      lg.arc("line", "open", p.x, p.y, S.CAP_R - 6, -math.pi / 2, -math.pi / 2 + p.amt * math.pi * 2)
    end
    -- the flag
    lg.setLineWidth(3)
    lg.setColor(0.15, 0.15, 0.17)
    lg.line(p.x, p.y + 22, p.x, p.y - 34)
    lg.setColor(oc[1], oc[2], oc[3])
    lg.polygon("fill", p.x, p.y - 34, p.x + 30, p.y - 26, p.x, p.y - 18)
    local f = require("src.render").font(16)
    lg.setFont(f)
    lg.setColor(0, 0, 0, 0.7)
    lg.print(p.name, p.x - f:getWidth(p.name) / 2 + 1, p.y + 25)
    lg.setColor(1, 1, 1)
    lg.print(p.name, p.x - f:getWidth(p.name) / 2, p.y + 24)
  end
  -- smoke: a drifting grey cloud on every unit inside it
  for _, sq in ipairs(world.squads and world.squads.list or {}) do
    for _, u in ipairs(sq.members) do
      if u.alive and u.smoked and world:isVisible(u) then
        for k = 0, 4 do
          local a = world.time * 0.6 + k * 1.26 + u.id
          local r = 22 + 6 * math.sin(world.time * 1.3 + k)
          lg.setColor(0.72, 0.74, 0.76, 0.22)
          lg.circle("fill", u.x + math.cos(a) * 16, u.y + math.sin(a) * 12, r)
        end
      end
    end
  end
  -- flares
  for _, v in ipairs(world.visionSources or {}) do
    if v.flare and v.ally == world.ally[world.playerTeam] then
      local a = 0.35 + 0.15 * math.sin(world.time * 6)
      lg.setColor(1, 0.95, 0.55, a * 0.25)
      lg.circle("fill", v.x, v.y, 30)
      lg.setColor(1, 0.95, 0.55, a)
      lg.setLineWidth(1)
      lg.circle("line", v.x, v.y, v.r)
    end
  end
end

---------------------------------------------------------------------------
-- The computer's squads: take points, fight what's near, pull back to heal, use skills

local AI = {}
AI.__index = AI

function S.newAI(world, team, level)
  local self = setmetatable({}, AI)
  self.world, self.team = world, team
  self.level = math.max(1, math.min(10, level or 5))
  world:setKiteSkill(team, self.level)
  self.think = math.max(0.4, 1.6 - 0.12 * self.level)
  self.timer = 1
  self.rng = love.math.newRandomGenerator((world.map.seed or 1) + team * 37)
  self.retreatAt = 0.25 + 0.025 * self.level   -- better players pull back earlier
  self.skillUse = 0.25 + 0.075 * self.level     -- and use their skills more often
  -- attention: a person can only look after so many squads at once. Easy bots attend to one
  -- squad per decision, the best to all of them
  self.attend = self.level <= 3 and 1 or (self.level <= 6 and 2 or (self.level <= 8 and 3 or 99))
  self.cursor = 0
  self.profileName = "Heroes"
  return self
end

local function squadHp(sq)
  local hp, max = 0, 0
  for _, u in ipairs(sq.members) do if u.alive then hp, max = hp + u.hp, max + u.maxhp end end
  return max > 0 and hp / max or 0, max
end

-- the point this squad should go for: enemy-held or neutral ones, nearest first, spread out
function AI:pickPoint(sq, taken)
  local w = self.world
  local me = w.ally[self.team]
  local L = sq.leader
  local best, bs
  for i, p in ipairs(w.capPoints or {}) do
    if p.owner ~= me or p.contested or (p.capBy and p.capBy ~= me and p.amt > 0) then
      local s = U.dist(L.x, L.y, p.x, p.y) + (taken[i] and 900 or 0) + (p.owner and p.owner ~= me and 150 or 0)
      if p.contested or (p.capBy and p.capBy ~= me and p.owner == me) then s = s - 600 end -- defend what's slipping
      if not bs or s < bs then best, bs = i, s end
    end
  end
  return best
end

function AI:useSkills(sq, foe, fd, fighting, frac, goal)
  local w = self.world
  local L = sq.leader
  local t = w.time
  if self.rng:random() > self.skillUse then return end
  for slot, s in ipairs(sq.skills) do
    if t >= s.readyAt then
      local k = s.key
      local def = S.SKILLS[k]
      local go, x, y = false, nil, nil
      if k == "hulldown" then go = fighting and frac > 0.3 and fd and fd < 380
      elseif k == "smoke" then go = (sq.healing and foe and fd < 450) or (fighting and frac < 0.55)
      elseif k == "spotter" then go = foe and fd < 1000
      elseif k == "sprint" then go = sq.healing or (goal and not fighting and U.dist(L.x, L.y, goal.x, goal.y) > 700)
      elseif k == "afterburner" then go = fighting
      elseif k == "repair" then go = (not fighting) and frac < 0.8 and not sq.healing
      elseif k == "barrage" then
        if foe and fd < def.range and foe.def.domain ~= "air" and S.sees(w, self.team, foe.x, foe.y) then
          go, x, y = true, foe.x, foe.y
        end
      elseif k == "flare" then
        if goal then go, x, y = U.dist(L.x, L.y, goal.x, goal.y) < def.range, goal.x, goal.y end
      elseif k == "flakburst" then
        local ax, ay
        w:query(L.x, L.y, def.range, function(o)
          if not ax and o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and o.def.domain == "air" then ax, ay = o.x, o.y end
        end)
        if ax then go, x, y = true, ax, ay end
      elseif k == "strafe" then
        if foe and fd < def.range and foe.def.domain ~= "air" then go, x, y = true, foe.x, foe.y end
      end
      if go then S.cast(w, sq, slot, x, y); return end
    end
  end
end

function AI:update(dt)
  local w = self.world
  if w.over or w.teams[self.team].dead then return end
  self.timer = self.timer - dt
  if self.timer > 0 then return end
  self.timer = self.think
  local tm = w.teams[self.team]
  local hq = tm.hq
  local taken = {}
  local mine = S.squadsOf(w, self.team)
  -- which squads get attention this time (round robin); the others carry on with their orders
  local look = {}
  for k = 1, math.min(self.attend, #mine) do
    self.cursor = self.cursor % #mine + 1
    look[mine[self.cursor]] = true
  end
  -- points the others are already heading for stay claimed
  for i, sq in ipairs(mine) do if not look[sq] and sq.goal then taken[sq.goal] = true end end
  for _, sq in ipairs(mine) do
    local L = sq.leader
    if L and L.alive and look[sq] then
      local frac = squadHp(sq)
      -- nearest enemy to the leader (units first, then their HQ)
      local foe, fd
      for _, o in ipairs(w.entities) do
        if o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and (o.def.weapon or o.key == "hq")
          and not (o.smoked and U.dist(L.x, L.y, o.x, o.y) > 90) then
          local d = U.dist(L.x, L.y, o.x, o.y)
          if not o.def.building then d = d * 0.8 end
          if not fd or d < fd then foe, fd = o, d end
        end
      end
      local fighting = foe and fd < 520
      -- pull back to heal, come back when healthy
      if sq.healing then
        if frac > 0.85 then sq.healing = nil end
      elseif frac < self.retreatAt and hq and hq.alive then
        sq.healing = true
        for _, u in ipairs(sq.members) do
          if u.alive then w:issue(u, { type = "retreat", x = hq.x + self.rng:random(-90, 90), y = hq.y + self.rng:random(-90, 90) }) end
        end
      end
      local pi = self:pickPoint(sq, taken)
      local goal = pi and w.capPoints[pi]
      if pi then taken[pi] = true end
      sq.goal = pi
      if not sq.healing then
        -- fight what's close; otherwise go take the point; everyone stays with the leader
        local tx, ty
        if fighting then tx, ty = foe.x, foe.y
        elseif goal then tx, ty = goal.x, goal.y
        elseif foe then tx, ty = foe.x, foe.y end
        if tx then
          for _, u in ipairs(sq.members) do
            if u.alive then
              local o = u.orders[1]
              local far = u ~= L and U.dist(u.x, u.y, L.x, L.y) > 320
              if far then
                if not (o and o.type == "move") then w:issue(u, { type = "move", x = L.x, y = L.y }) end
              elseif not o or (o.type == "amove" and U.dist(o.x, o.y, tx, ty) > 140) or o.type == "move" then
                local jx, jy = 0, 0
                if u ~= L then jx, jy = self.rng:random(-60, 60), self.rng:random(-60, 60) end
                w:issue(u, { type = "amove", x = tx + jx, y = ty + jy })
              end
            end
          end
        end
      end
      self:useSkills(sq, foe, fd, fighting, frac, goal)
    end
  end
end

return S
