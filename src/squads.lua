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
  { key = "battery", name = "Battery", unit = "artillery", size = 3, skills = { "barrage", "rapidfire" },
    desc = "Three Artillery pieces. Breaks up anything your side can see - pair them with Recon (Flare) and keep them behind the tanks." },
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
    desc = "Six heavy shells (150 damage each, splash) on a spot your side can see, within 950 of the leader. A red marker shows where they'll land." },
  spotter = { name = "Spotter Drone", aim = "self", dur = 15, cd = 35,
    desc = "15 s: the squad sees 60% further - artillery reaches everything it sees." },
  rapidfire = { name = "Rapid Fire", aim = "self", dur = 8, cd = 40,
    desc = "8 s: the battery's guns reload 80% faster. Best when Recon has lit up a target." },
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
-- match lengths: tickets per side (and par) for a quick, standard or long game
S.LENGTHS = {
  quick = { tickets = 280, par = 6, name = "Quick" },
  standard = { tickets = 620, par = 11, name = "Standard" },
  long = { tickets = 1000, par = 18, name = "Long" },
}
S.DRAIN = 0.4         -- tickets a second per point of difference
S.CAP_R = 160           -- capture radius
S.CAP_TIME = 14         -- seconds for one unit to take a neutral point
S.HQ_HP = 16000
S.HP_MUL = 1.6          -- squad units are this much tougher than in Annihilation

-- terrain: high ground sees further but is exposed; a bunker hides you and soaks hits
S.HILL_SIGHT, S.HILL_TAKEN = 1.3, 1.15
S.BUNKER_SIGHT, S.BUNKER_TAKEN, S.BUNKER_R = 0.7, 0.6, 95
S.WIH_SIGHT = 0.8       -- War is Hell: deep fog - everyone sees less

-- every crewman has a name (War is Hell makes you care)
S.SURNAMES = { "Price", "Kowalski", "Okafor", "Reyes", "Lindqvist", "Brennan", "Haddad", "Nakamura", "Duarte", "Fischer",
  "Mbeki", "Sullivan", "Ivanova", "Castillo", "Abara", "Moreau", "Tanaka", "Byrne", "Novak", "Hargrove", "Quinn",
  "Delgado", "Varga", "Osei", "Holt", "Petrov", "Calloway", "Sorensen", "Adeyemi", "Marsh", "Kaur", "Lindgren",
  "Booker", "Rinaldi", "Okoro", "Dubois", "Whitlock", "Kim", "Farouk", "Mendez", "Strand", "Ruiz", "Hale", "Bianchi",
  "Achebe", "Lowe", "Sato", "Grady", "Moss", "Varela", "Thorne", "Pike", "Kovac", "Dunn", "Ash", "Vance", "Ortiz", "Royce" }
S.RANKS = { "Pvt.", "Pvt.", "Pfc.", "Cpl.", "Spc." }

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
local nameRng = love.math.newRandomGenerator(os.time())
local function newName(world, leader)
  world.usedNames = world.usedNames or {}
  local nm
  for _ = 1, 20 do
    nm = S.SURNAMES[nameRng:random(#S.SURNAMES)]
    if not world.usedNames[nm] then break end
  end
  world.usedNames[nm] = true
  return (leader and "Sgt." or S.RANKS[nameRng:random(#S.RANKS)]) .. " " .. nm
end

local function prep(u, sq, leader)
  u.squad = sq
  u.hpMul = S.HP_MUL * (leader and 1.75 or 1)
  u.maxhp = math.floor(u.def.hp * (1 + 0.10 * (u.level or 0)) * u.hpMul); u.hp = u.maxhp
  u.mods = u.mods or {}
  if leader then u.mods.dmg = 1.25 end
  -- light anti-air: Recon's guns hit aircraft hard for their size, a tank's machine gun a little
  if sq.type == "recon" then u.mods.hitsAir, u.mods.airDmg = true, 2.0 end
  if sq.type == "armor" then u.mods.hitsAir, u.mods.airDmg = true, 0.35 end
  u.callsign = u.callsign or newName(sq.world, leader)
end

local function makeLeader(world, sq, t, x, y)
  local ty = S.byType[sq.type]
  local L = world:spawn(ty.leader, t, x, y)
  L.homeX, L.homeY = x, y
  L.squad, L.squadLeader = sq, true
  prep(L, sq, true)
  L.genName = L.callsign
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

-- bunkers: dug-in positions scattered (mirrored, so it's fair) across the map
local function setupBunkers(world, n)
  local map = world.map
  local rng = love.math.newRandomGenerator((map.seed or 1) + 4242)
  local W, H = map.w * world.T, map.h * world.T
  world.bunkers = {}
  local tries = 0
  while #world.bunkers < n * 2 and tries < 400 do
    tries = tries + 1
    local x, y = rng:random(250, W - 250), rng:random(250, H / 2)
    local tx, ty = map:tileAt(x, y)
    local tx2, ty2 = map:tileAt(W - x, H - y)
    local ok = map:passable("land", tx, ty) and map:passable("land", tx2, ty2)
    for t = 1, world.np do
      local tm = world.teams[t]
      if U.dist(x, y, tm.startX, tm.startY) < 500 or U.dist(W - x, H - y, tm.startX, tm.startY) < 500 then ok = false end
    end
    for _, b in ipairs(world.bunkers) do if U.dist(x, y, b.x, b.y) < 380 then ok = false end end
    if ok then
      world.bunkers[#world.bunkers + 1] = { x = x, y = y, r = S.BUNKER_R }
      world.bunkers[#world.bunkers + 1] = { x = W - x, y = H - y, r = S.BUNKER_R }
    end
  end
end

function S.inBunker(world, x, y)
  for _, b in ipairs(world.bunkers or {}) do if U.dist2(x, y, b.x, b.y) <= b.r * b.r then return b end end
end

function S.setup(world, opts)
  local map = world.map
  world.squads = { list = {}, tickets = {}, pending = {} }
  world.visionSources = world.visionSources or {}
  world.wih = opts.cohMode == "wih" or os.getenv("PA_WIH") ~= nil
  if world.wih then world.sightMul = S.WIH_SIGHT end
  local rng = love.math.newRandomGenerator((map.seed or 1) + 911)
  for t = 1, world.np do
    local tm = world.teams[t]
    -- each side's pool grows with its size (2v2: twice the squads, half again the tickets)
    local size = 0
    for t2 = 1, world.np do if world.ally[t2] == world.ally[t] then size = size + 1 end end
    local len = S.LENGTHS[opts.cohLength or (os.getenv("PA_COHLEN") or "standard")] or S.LENGTHS.standard
    if not world.wih then world.squads.tickets[world.ally[t]] = len.tickets * (1 + 0.5 * (size - 1)) end
    world.parTime = world.wih and 15 * 60 or len.par * 60
    -- the HQ where the Commander would stand
    local tx, ty = map:tileAt(tm.startX, tm.startY)
    local hq
    for r = 0, world.wih and -1 or 8 do
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
      if opts.enemySquads == "mirror" and opts.squadSetup and nOn >= 2 then
        -- mirror: the same squads as the human, so every matchup has an answer
        for _, ds in ipairs(opts.squadSetup) do if ds.on then designs[#designs + 1] = { type = ds.type } end end
      else
        designs = S.randomSquads(rng, math.max(2, nOn > 0 and nOn or 4))
      end
      -- facing air (the human's setup is known): make sure something here shoots it down
      local enemyAir = false
      for _, ds in ipairs(opts.squadSetup or {}) do if ds.on and ds.type == "air" then enemyAir = true end end
      if enemyAir and not S.hasAntiAir(designs) and opts.enemySquads ~= "mirror" then designs[#designs].type = "aa" end
    end
    -- toward the middle of the map: that's where the squads stand ready
    local mx, my = map.w * world.T / 2, map.h * world.T / 2
    local dx, dy = U.norm(mx - tm.startX, my - tm.startY)
    local px, py = -dy, dx
    for i, ds in ipairs(designs) do
      local off = (i - (#designs + 1) / 2) * 170
      local cx, cy = tm.startX + dx * 260 + px * off, tm.startY + dy * 260 + py * off
      local ty2 = S.byType[ds.type]
      local sq = { team = t, idx = i, type = ds.type, members = {}, world = world, roster = {},
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
  if world.wih then world.capPoints = nil else setupPoints(world) end
  setupBunkers(world, world.wih and 6 or 3)
  -- the roster (names, alive or fallen) for the squad cards
  for _, sq in ipairs(world.squads.list) do
    for _, u in ipairs(sq.members) do sq.roster[#sq.roster + 1] = u end
  end
  -- no economy here: no metal deposits on the map or the minimap
  map.deposits = {}
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
  dmg = dmg * S.HP_MUL -- squad units are tougher here, so skills hit as hard as they were meant to
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
    fx[#fx + 1] = { kind = "reticle", x = tx, y = ty, t = 0, life = 4.0, size = 130 }
    if world.onSquadSound then world.onSquadSound("artillery", L.x, L.y, 1) end
    for i = 1, 6 do
      local land = 0.9 + i * 0.45
      local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * 120
      local x, y = tx + math.cos(a) * r, ty + math.sin(a) * r
      later(world, land - 0.45, function()
        fx[#fx + 1] = { kind = "shell", x = x, y = y, t = 0, life = 0.45 }
      end)
      later(world, land, function()
        hurt(world, L, x, y, 70, 95, function(o) return o.def.domain ~= "air" end)
        fx[#fx + 1] = { kind = "boom", x = x, y = y, t = 0, life = 0.8, size = 85 }
        fx[#fx + 1] = { kind = "boom", x = x + math.random(-20, 20), y = y + math.random(-20, 20), t = 0, life = 0.5, size = 45 }
        if world.onSquadSound then world.onSquadSound(i % 2 == 0 and "bigboom" or "boom", x, y, 1) end
      end)
    end
  elseif s.key == "flare" then
    if world.onSquadSound then world.onSquadSound("skill", L.x, L.y, 0.8) end
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
    -- War is Hell: no HQ, no reinforcements. A fallen leader's best survivor takes command
    if world.wih and sq.leader and not sq.leader.alive then
      local old = sq.leader
      local best
      for _, u in ipairs(sq.members) do if u.alive and u ~= old and (not best or u.hp > best.hp) then best = u end end
      if best then
        best.squadLeader, best.genName = true, best.callsign
        best.mods = best.mods or {}; best.mods.dmg = 1.25
        sq.leader = best
        if world.teams[sq.team].commander == old then world.teams[sq.team].commander = best end
        if world.onSquadPromoted then world.onSquadPromoted(sq, best, old) end
      else
        sq.dead = true
      end
    end
    -- a fallen leader comes back at the HQ
    if not world.wih and sq.leader and not sq.leader.alive then
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
      if not u.alive and not u.fallenNoted then
        u.fallenNoted = true
        if world.onSquadDeath then world.onSquadDeath(sq, u) end
      end
      if not u.alive and not u.squadLeader then
        table.remove(sq.members, i)
        if not world.wih then
          st.tickets[ally] = (st.tickets[ally] or 0) - 1; st.byLoss = (st.byLoss or 0) + 1
          local w = D.units[u.key].weapon
          local aa = w and w.targets.air and not w.targets.land
          sq.queue[#sq.queue + 1] = { key = u.key, at = t + (aa and wait / 2 or wait) }
        end
      elseif not u.alive and u.squadLeader and u ~= sq.leader then
        table.remove(sq.members, i) -- an old leader's body
      end
    end
    local hq0 = world.teams[sq.team].hq
    for i = #sq.queue, 1, -1 do
      local q = sq.queue[i]
      -- the leader comes back first: replacements wait at the HQ until he's there to lead them
      if t >= q.at and hq0 and hq0.alive and sq.leader and sq.leader.alive then
        table.remove(sq.queue, i)
        local d = D.units[q.key]
        local x, y = place(world, hq0.x + (math.random() - 0.5) * 160, hq0.y + 120, d.domain == "air" and nil or "land")
        local u = world:spawn(q.key, sq.team, x, y)
        u.homeX, u.homeY = x, y
        prep(u, sq)
        u.rejoining = true
        sq.members[#sq.members + 1] = u
        sq.roster[#sq.roster + 1] = u
        if sq.leader and sq.leader.alive then world:issue(u, { type = "move", x = sq.leader.x, y = sq.leader.y, rejoin = true }) end
        if world.onSquadReinforced then world.onSquadReinforced(sq, u) end
      end
    end
    -- replacements head for the leader - or, if he's fleeing, straight to where he's fleeing to
    -- and wait for him there. Once with him they take up his current order and go on together
    if sq.leader and sq.leader.alive then
      local L = sq.leader
      local lo = L.orders[1]
      local fleeing = lo and lo.type == "retreat"
      local gx, gy = L.x, L.y
      if fleeing then gx, gy = lo.x, lo.y end
      -- a squad that pulls back stops digging in (Hull Down would halve its speed)
      if fleeing then for _, sk in ipairs(sq.skills) do if sk.key == "hulldown" and t < sk.untilT then sk.untilT = t end end end
      for _, u in ipairs(sq.members) do
        -- given an order of their own (by you or the computer)? then they're back in the squad already
        if u.alive and u.rejoining and u.orders[1] and not u.orders[1].rejoin then u.rejoining = nil end
        if u.alive and u.rejoining then
          if U.dist2(u.x, u.y, L.x, L.y) < 260 * 260 then
            u.rejoining = nil
            if lo and (lo.type == "move" or lo.type == "amove") then
              world:issue(u, { type = lo.type, x = lo.x + (u.x - L.x) * 0.5, y = lo.y + (u.y - L.y) * 0.5, march = lo.march })
            end
          elseif fleeing and U.dist2(u.x, u.y, gx, gy) < 150 * 150 then
            if #u.orders > 0 then u.orders = {}; u.path = nil end -- at the rally point: wait for him
          elseif #u.orders == 0 or (u.orders[1].type == "move" and U.dist2(u.orders[1].x, u.orders[1].y, gx, gy) > 120 * 120) then
            world:issue(u, { type = "move", x = gx, y = gy, arrive = 100, rejoin = true })
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
    local rapid = alive and S.active(sq, "rapidfire", t)
    local rep = alive and S.active(sq, "repair", t)
    for _, u in ipairs(sq.members) do
      if u.alive then
        local on = alive and U.dist2(u.x, u.y, L.x, L.y) <= S.RADIUS * S.RADIUS
        -- the ground under it: hills see further but are exposed; bunkers hide and protect
        local tsight, ttaken = 1, 1
        u.onHill, u.inBunker = nil, nil
        if u.def.domain == "land" then
          local tx, ty = world.map:tileAt(u.x, u.y)
          if world.map:terrainAt(tx, ty) == 2 then tsight, ttaken, u.onHill = S.HILL_SIGHT, S.HILL_TAKEN, true
          elseif S.inBunker(world, u.x, u.y) then tsight, ttaken, u.inBunker = S.BUNKER_SIGHT, S.BUNKER_TAKEN, true end
        end
        local taken = ttaken * ((on and hull) and 0.65 or 1)
        u.sqTaken = taken ~= 1 and taken or nil
        local sp = 1
        if on and hull then sp = sp * 0.5 end
        if on and smoke then sp = sp * 0.85 end
        if on and sprint then sp = sp * 1.5 end
        if on and burn then sp = sp * 1.6 end
        u.sqSpeed = sp ~= 1 and sp or nil
        local sight = tsight * ((on and spot) and 1.6 or 1)
        u.sqSight = sight ~= 1 and sight or nil
        u.sqRof = (on and rapid) and 1.8 or ((on and burn) and 1.3 or nil)
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
  if world.wih then S.updateWih(world, dt) end
  -- defeat: the HQ is gone, or the tickets ran out
  st.checkT = (st.checkT or 0) - dt
  if st.checkT <= 0 then
    st.checkT = 0.5
    for tt = 1, world.np do
      local tm = world.teams[tt]
      local out
      if world.wih then
        out = true
        for _, sq in ipairs(st.list) do
          if sq.team == tt then for _, u in ipairs(sq.members) do if u.alive then out = false end end end
        end
      else
        out = not (tm.hq and tm.hq.alive) or (st.tickets[world.ally[tt]] or 1) <= 0
      end
      if not tm.dead and out then
        if os.getenv("PA_SQDBG") then print("SQOUT", tt, math.floor(world.time), st.tickets[world.ally[tt]], "drain", math.floor(st.byDrain or 0), "losses", st.byLoss or 0) end
        world:eliminate(tt)
      end
    end
  end
end


---------------------------------------------------------------------------
-- War is Hell endgame: blood trails to hunt by, and a beaten enemy that begs for mercy

S.TRAIL_HP = 0.75      -- below this much health a man leaves a trail of blood
S.TRAIL_STEP = 28      -- a drop every this many pixels walked (and now and then standing still)
S.TRAIL_LIFE = 180     -- drops dry up after this many seconds
S.MERCY_AT = 2         -- an enemy side down to this many men (and outnumbered) gives up
S.BEGS = { "Please! Don't shoot!", "I surrender!", "Mercy! Mercy!", "I have a family...", "We give up!",
  "Don't... please...", "Hold your fire! I'm done!", "I just want to go home" }

local function living(world, ally)
  local out = {}
  for _, sq in ipairs(world.squads.list) do
    if world.ally[sq.team] == ally then
      for _, u in ipairs(sq.members) do if u.alive then out[#out + 1] = u end end
    end
  end
  return out
end

-- for the memorial: who a fallen man leaves behind
local WIVES = { "Anna", "Maria", "Claire", "Rosa", "Helen", "Grace", "Elena", "Margaret", "Lucy", "Ruth", "Sofia", "Joan", "Irene", "Alice", "Nadia", "Mei" }
local KIDS_B = { "Tommy", "Sam", "Danny", "Leo", "Joseph", "Eli", "Michael", "Luis", "Peter", "Jack" }
local KIDS_G = { "Emma", "Lily", "Rose", "Sarah", "Ava", "Clara", "Hannah", "Mia", "Nora", "Ellie" }
local function kid()
  if love.math.random() < 0.5 then return KIDS_B[love.math.random(#KIDS_B)], love.math.random(1, 12), "son" end
  return KIDS_G[love.math.random(#KIDS_G)], love.math.random(1, 12), "daughter"
end
function S.survivedBy()
  local r = love.math.random
  local age = r(18, 41)
  local wife = WIVES[r(#WIVES)]
  local line
  if age < 22 then
    local opts = {
      "survived by his mother, " .. wife,
      "survived by his parents and a little sister, " .. r(6, 15),
      "survived by his parents and two brothers",
      "survived by his fiancée, " .. wife .. ". They were to marry in the spring",
      "survived by his grandmother, who raised him",
      "survived by his mother and a dog called Buster",
    }
    line = opts[r(#opts)]
  else
    local n = age < 27 and r(0, 1) or r(0, 3)
    if n == 0 then
      line = r() < 0.7 and ("survived by his wife, " .. wife) or ("survived by his wife, " .. wife .. ", expecting their first child")
    elseif n == 1 then
      local nm, a, rel = kid()
      line = string.format("survived by his wife, %s, and a %s, %s, %d", wife, rel, nm, a)
    else
      local ages = {}
      for k = 1, n do ages[k] = r(1, 14) end
      table.sort(ages, function(x, y) return x > y end)
      local list = table.concat(ages, ", ", 1, n - 1) .. " and " .. ages[n]
      line = string.format("survived by his wife, %s, and %s children, %s", wife, ({ "", "two", "three" })[n], list)
    end
  end
  return age, line
end

function S.updateWih(world, dt)
  local st = world.squads
  local t = world.time
  st.trail = st.trail or {}
  local trail = st.trail
  -- the wounded bleed as they go
  for _, sq in ipairs(st.list) do
    for _, u in ipairs(sq.members) do
      if u.alive and not u.def.air and (u.hp < u.maxhp * S.TRAIL_HP or u.broken) then
        local moved = u.trailX and U.dist(u.x, u.y, u.trailX, u.trailY) or 999
        local still = t - (u.trailT or -99) > 5 and moved < 4
        if moved >= S.TRAIL_STEP or still then
          local hurt = math.max(0.4, 1 - u.hp / u.maxhp)
          local a = love.math.random() * math.pi * 2
          trail[#trail + 1] = { x = u.x + math.cos(a) * 5, y = u.y + math.sin(a) * 5, t = t,
            r = 2 + hurt * 3 + love.math.random() * 1.5, ally = world.ally[sq.team], pool = still }
          u.trailX, u.trailY, u.trailT = u.x, u.y, t
        end
      end
    end
  end
  -- drops dry up; the player finds a drop once his men have had eyes on it
  st.trailT = (st.trailT or 0) - dt
  if st.trailT <= 0 then
    st.trailT = 0.4
    local keep = {}
    for _, d in ipairs(trail) do
      if t - d.t < S.TRAIL_LIFE then
        if not d.found then
          local tx, ty = math.floor(d.x / world.T), math.floor(d.y / world.T)
          d.found = world:tileVisible(tx, ty)
        end
        keep[#keep + 1] = d
      end
    end
    while #keep > 1500 do table.remove(keep, 1) end
    st.trail = keep
    trail = keep
  end
  -- the break. Men who have run from the fight have, for all purposes, laid down their arms: a
  -- squad of the computer's that pulls back, or a side down to its last men and outnumbered.
  -- They stop shooting and make for cover (bleeding as they go); nothing chases them down by
  -- itself. When the player's men find a group of them, that group begs for mercy
  local mine = world.ally[world.playerTeam]
  local us = living(world, mine)
  for tt = 1, world.np do
    local ally = world.ally[tt]
    if ally ~= mine then
      local them = living(world, ally)
      local fighting = 0
      for _, u in ipairs(them) do if not u.broken then fighting = fighting + 1 end end
      if fighting > 0 and #them <= S.MERCY_AT and #us >= #them + 2 then
        local cx, cy = 0, 0
        for _, f in ipairs(us) do cx, cy = cx + f.x, cy + f.y end
        S.breakUnits(world, them, cx / #us, cy / #us)
        if world.onSquadBroken then world.onSquadBroken(ally, them, true) end
      end
    end
  end
  -- found? any broken man one of ours can see (after a few seconds' head start) gives up, and
  -- so does everyone broken who's with him
  local found
  for _, sq in ipairs(st.list) do
    for _, u in ipairs(sq.members) do
      -- (only once they've made it back to where they gather - not while they're running)
      if u.alive and u.broken and not u.surrendered and u.hideX and U.dist(u.x, u.y, u.hideX, u.hideY) < 180 then
        for _, f in ipairs(us) do
          if U.dist2(f.x, f.y, u.x, u.y) <= world:sightOf(f) ^ 2 then found = u; break end
        end
      end
      if found then break end
    end
    if found then break end
  end
  if found then
    local group = {}
    local ally = world.ally[found.team]
    for _, sq in ipairs(st.list) do
      if world.ally[sq.team] == ally then
        for _, u in ipairs(sq.members) do
          if u.alive and u.broken and not u.surrendered and U.dist(u.x, u.y, found.x, found.y) < 450 then
            u.surrendered = true
            u.begT = t + love.math.random() * 1.5
            world:issue(u, { type = "move", x = u.x, y = u.y })
            group[#group + 1] = u
          end
        end
      end
    end
    if world.onSquadSurrender then world.onSquadSurrender(ally, group) end
  end
  for _, sq in ipairs(st.list) do
    for _, u in ipairs(sq.members) do
      if u.alive and u.broken then
        u.holdFire = true
        if u.surrendered then
          -- found: hands up, in plain sight, pleading
          local o = u.orders[1]
          if o and not (o.type == "move" and U.dist(o.x, o.y, u.x, u.y) < 10) then world:issue(u, { type = "move", x = u.x, y = u.y }) end
          world.visionSources[#world.visionSources + 1] = { x = u.x, y = u.y, r = 110, untilT = t + 0.3, ally = mine }
          world.fogDirty = true
          if t >= (u.begT or 0) then
            u.begT = t + 3.5 + love.math.random() * 2.5
            u.begLine = S.BEGS[love.math.random(#S.BEGS)]
            u.begShown = t
            if world.onSquadBeg then world.onSquadBeg(u) end
          end
        elseif #u.orders == 0 and u.hideX and U.dist(u.x, u.y, u.hideX, u.hideY) > 60 then
          world:issue(u, { type = "retreat", x = u.hideX, y = u.hideY })
        end
      end
    end
  end
end

-- these men are done fighting: they run off into the fog, away from (fx, fy)
function S.breakUnits(world, units, fx, fy)
  local W, H = world.map.w * world.T, world.map.h * world.T
  local t = world.time
  for _, u in ipairs(units) do
    if u.alive and not u.broken then
      u.broken, u.brokenT, u.holdFire, u.flagSeed = true, t, true, love.math.random() * 6
      -- back to where they came in, where the broken gather
      local tm = world.teams[u.team]
      local sx, sy = tm.startX or u.x, tm.startY or u.y
      local a, r = love.math.random() * math.pi * 2, 40 + love.math.random() * 110
      u.hideX = math.max(150, math.min(W - 150, sx + math.cos(a) * r))
      u.hideY = math.max(150, math.min(H - 150, sy + math.sin(a) * r))
      world:issue(u, { type = "retreat", x = u.hideX, y = u.hideY })
      if u.squad then
        local all = true
        for _, m in ipairs(u.squad.members) do if m.alive and not m.broken then all = false end end
        if all then u.squad.broken = true end
      end
    end
  end
end

-- blood the player has found, then the white flags and the pleading (drawn over the fog)
function S.drawWih(world, cam)
  local lg = love.graphics
  local st = world.squads
  local t = world.time
  for _, d in ipairs(st.trail or {}) do
    if d.found then
      local age = (t - d.t) / S.TRAIL_LIFE
      local a = (1 - age) * 0.85
      lg.setColor(0.55 - 0.25 * age, 0.03, 0.03, a)
      lg.circle("fill", d.x, d.y, d.r * (d.pool and 1.6 or 1))
    end
  end
  local R = require("src.render")
  for _, sq in ipairs(st.list) do
    do
      for _, u in ipairs(sq.members) do
        if u.alive and u.surrendered then
          local top = u.y - u.def.radius - 6
          -- a white flag
          lg.setColor(0.35, 0.28, 0.2)
          lg.setLineWidth(2)
          lg.line(u.x + u.def.radius, top + 6, u.x + u.def.radius, top - 22)
          local wave = math.sin(t * 6 + (u.flagSeed or 0)) * 2
          lg.setColor(0.96, 0.96, 0.92)
          lg.polygon("fill", u.x + u.def.radius, top - 22, u.x + u.def.radius + 16, top - 18 + wave, u.x + u.def.radius, top - 12)
          -- what he's saying
          if u.begLine and t - (u.begShown or -99) < 3 then
            local f = R.font(13)
            lg.setFont(f)
            local tw = f:getWidth(u.begLine) + 14
            local bx, by = u.x - tw / 2, top - 52
            lg.setColor(0.97, 0.95, 0.9, 0.95)
            lg.rectangle("fill", bx, by, tw, 22, 6)
            lg.polygon("fill", u.x - 5, by + 22, u.x + 5, by + 22, u.x, by + 29)
            lg.setColor(0.15, 0.08, 0.06)
            lg.print(u.begLine, bx + 7, by + 3)
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Drawing: capture points (world) and on the minimap

-- on the ground, under everything: bunkers (sandbag rings), and blood
function S.drawGround(world)
  local lg = love.graphics
  for _, b in ipairs(world.bunkers or {}) do
    lg.setColor(0.22, 0.18, 0.12, 0.55)
    lg.circle("fill", b.x, b.y, b.r)
    lg.setColor(0.62, 0.55, 0.38, 0.95)
    for i = 0, 15 do
      local a = i * math.pi / 8
      lg.circle("fill", b.x + math.cos(a) * b.r, b.y + math.sin(a) * b.r, 9)
    end
    lg.setColor(0.4, 0.34, 0.22, 0.9)
    for i = 0, 15 do
      local a = i * math.pi / 8 + math.pi / 16
      lg.circle("fill", b.x + math.cos(a) * (b.r - 8), b.y + math.sin(a) * (b.r - 8), 6)
    end
  end
  if world.wih then require("src.cries").drawDecals(world) end
end

function S.draw(world, cam, game)
  local lg = love.graphics
  if world.wih then S.drawWih(world, cam) end
  -- the ACTIVE squad (whose skills Q / W fire): a gold beacon on its leader, the reach of his
  -- skills, and a gold ring under every member
  local act = game and game.activeSquad and game:activeSquad()
  if act and act.team == world.playerTeam then
    local L = act.leader
    local pulse = 0.5 + 0.5 * math.sin(world.time * 5)
    for _, u in ipairs(act.members) do
      if u.alive then
        lg.setColor(1, 0.8, 0.25, 0.55)
        lg.setLineWidth(2)
        lg.circle("line", u.x, u.y, u.def.radius + 7)
      end
    end
    if L and L.alive then
      lg.setColor(1, 0.8, 0.25, 0.08)
      lg.circle("fill", L.x, L.y, S.RADIUS)
      lg.setColor(1, 0.8, 0.25, 0.5)
      lg.setLineWidth(2)
      for i = 0, 35 do
        local a = i * math.pi / 18 + world.time * 0.2
        lg.arc("line", "open", L.x, L.y, S.RADIUS, a, a + math.pi / 36)
      end
      lg.setColor(1, 0.82, 0.25, 0.6 + 0.4 * pulse)
      lg.setLineWidth(3)
      lg.circle("line", L.x, L.y, L.def.radius + 12 + pulse * 4)
      -- a chevron above him, scaled to stay readable when zoomed out
      local sc = 1 / math.max(cam.zoom or 1, 0.45)
      local y = L.y - L.def.radius - 40 * sc - pulse * 4 * sc
      lg.setColor(1, 0.82, 0.25, 0.95)
      lg.polygon("fill", L.x - 11 * sc, y, L.x + 11 * sc, y, L.x, y + 13 * sc)
    end
    lg.setLineWidth(1)
  end
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
  -- an HQ is shielded while its side holds a point: a blue dome says so
  for t = 1, world.np do
    local hq = world.teams[t].hq
    if hq and hq.alive and world:isVisible(hq) then
      local held = S.held(world, world.ally[t]) > 0
      local r = (hq.def.radius or 40) * 2.1 + 10
      if held then
        lg.setColor(0.45, 0.75, 1, 0.10 + 0.04 * math.sin(world.time * 2))
        lg.circle("fill", hq.x, hq.y, r)
        lg.setColor(0.55, 0.85, 1, 0.55)
        lg.setLineWidth(2)
        lg.circle("line", hq.x, hq.y, r)
      else
        lg.setColor(1, 0.35, 0.25, 0.5 + 0.4 * math.sin(world.time * 6))
        lg.setLineWidth(2)
        for i = 0, 11 do
          local a = i * math.pi / 6 + world.time
          lg.arc("line", "open", hq.x, hq.y, r, a, a + math.pi / 12)
        end
      end
      lg.setLineWidth(1)
    end
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
  if world.wih then
    -- War is Hell: one army, closely watched, that fights it out
    self.attend = self.attend + 1
    self.retreatAt = 0.12 + 0.012 * self.level
    -- some games the computer holds its ground and lets you come (always as one combined force)
    self.defend = self.level >= 4 and self.rng:random() < 0.35
  end
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
      elseif k == "rapidfire" then go = foe and fd < 900 and S.sees(w, self.team, foe.x, foe.y)
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

-- War is Hell: where to go. In a fight, take the nearest bunker or high ground if it's close;
-- otherwise head for where the enemy was last seen, or sweep the map toward their side
function AI:huntGoal(sq, foe, fighting)
  local w = self.world
  local L = sq.leader
  if fighting and self.level >= 4 then
    local best, bd
    for _, b in ipairs(w.bunkers or {}) do
      local d = U.dist(L.x, L.y, b.x, b.y)
      if d < 360 and (not bd or d < bd) and U.dist(foe.x, foe.y, b.x, b.y) > 120 then best, bd = b, d end
    end
    if best then return { x = best.x, y = best.y, hold = true } end
  end
  if self.lastSeen and w.time - self.lastSeen.t < 40 then return { x = self.lastSeen.x, y = self.lastSeen.y } end
  -- sweep: waypoints spread over the enemy half, a new one when we get there
  if not self.sweep or U.dist(L.x, L.y, self.sweep.x, self.sweep.y) < 250 or w.time > self.sweep.untilT then
    local ex, ey
    for t = 1, w.np do if w:hostile(t, self.team) then ex, ey = w.teams[t].startX, w.teams[t].startY end end
    local W, H = w.map.w * w.T, w.map.h * w.T
    local x = U.clamp((ex or W / 2) + self.rng:random(-W * 0.35, W * 0.35), 200, W - 200)
    local y = U.clamp((ey or H / 2) + self.rng:random(-H * 0.35, H * 0.35), 200, H - 200)
    self.sweep = { x = x, y = y, untilT = w.time + 60 }
  end
  return self.sweep
end


---------------------------------------------------------------------------
-- War is Hell: combined arms. One plan for the whole force, then each squad plays its part:
-- recon screens ahead and spots, armor leads and takes the fight, the battery stays back at
-- the edge of its reach and shells what the others can see, AA rides with the guns, air
-- strikes what's been found (their guns first)


function AI:armyPlan(mine)
  local w = self.world
  local tm = w.teams[self.team]
  local by = {}
  local cx, cy, n = 0, 0, 0
  for _, sq in ipairs(mine) do
    local L = sq.leader
    if L and L.alive and not sq.broken then
      by[sq.type] = by[sq.type] or sq
      cx, cy, n = cx + L.x, cy + L.y, n + 1
    end
  end
  if n == 0 then return nil end
  cx, cy = cx / n, cy / n
  -- the anchor: the armor if there is any (it leads), else the middle of the force
  local A = by.armor and by.armor.leader or nil
  local ax, ay = A and A.x or cx, A and A.y or cy
  -- where we're going: the last place we saw them, or (defending) our ground, or a sweep
  local obj
  local seen = self.lastSeen and w.time - self.lastSeen.t < 45 and self.lastSeen
  if seen then obj = { x = seen.x, y = seen.y }
  elseif self.defend and w.time < (self.defendUntil or 170) then
    if not self.holdAt then
      -- the bunker (else just a spot) a third of the way from our start to the middle
      local W, H = w.map.w * w.T, w.map.h * w.T
      local px, py = tm.startX + (W / 2 - tm.startX) * 0.33, tm.startY + (H / 2 - tm.startY) * 0.33
      local best, bd
      for _, b in ipairs(w.bunkers or {}) do
        local d = U.dist(px, py, b.x, b.y)
        if d < 900 and (not bd or d < bd) then best, bd = b, d end
      end
      self.holdAt = best and { x = best.x, y = best.y, bunker = true } or { x = px, y = py }
    end
    obj = { x = self.holdAt.x, y = self.holdAt.y, hold = true }
  else
    if not self.sweep or U.dist(ax, ay, self.sweep.x, self.sweep.y) < 300 or w.time > self.sweep.untilT then
      local ex, ey
      for t = 1, w.np do if w:hostile(t, self.team) then ex, ey = w.teams[t].startX, w.teams[t].startY end end
      local W, H = w.map.w * w.T, w.map.h * w.T
      self.sweep = { x = U.clamp((ex or W / 2) + self.rng:random(-W * 0.3, W * 0.3), 200, W - 200),
        y = U.clamp((ey or H / 2) + self.rng:random(-H * 0.3, H * 0.3), 200, H - 200), untilT = w.time + 70 }
    end
    obj = { x = self.sweep.x, y = self.sweep.y }
  end
  local dx, dy = U.norm(obj.x - ax, obj.y - ay)
  if dx == 0 and dy == 0 then dx = 1 end
  return { by = by, ax = ax, ay = ay, obj = obj, dx = dx, dy = dy, contact = seen and U.dist(ax, ay, seen.x, seen.y) < 900 }
end


-- Conquest: points want different things than a hunt. The scouts run off and take what they
-- can on their own; the rest march in order as one force - or, with four or more squads, as two
-- (the guns with the main body on one point, the rest on another)
local function pointDone(w, p, me)
  return p.owner == me and not p.contested and not (p.capBy and p.capBy ~= me and p.amt > 0)
end

function AI:groupPlan(list, keyName, taken)
  local w = self.world
  local me = w.ally[self.team]
  local by, cx, cy, n = {}, 0, 0, 0
  for _, sq in ipairs(list) do
    by[sq.type] = by[sq.type] or sq
    cx, cy, n = cx + sq.leader.x, cy + sq.leader.y, n + 1
  end
  if n == 0 then return nil end
  local A = by.armor and by.armor.leader
  local ax, ay = A and A.x or cx / n, A and A.y or cy / n
  self.gobj = self.gobj or {}
  local pi = self.gobj[keyName]
  if not pi or not w.capPoints[pi] or pointDone(w, w.capPoints[pi], me) or (taken[pi] and taken[pi] ~= keyName) then
    local lead = by.armor or by.battery or by.aa or by.air or list[1]
    local blocked = {}
    for k, v in pairs(taken) do if v ~= keyName then blocked[k] = true end end
    pi = self:pickPoint(lead, blocked)
    self.gobj[keyName] = pi
  end
  local obj
  if pi then
    taken[pi] = keyName
    obj = { x = w.capPoints[pi].x, y = w.capPoints[pi].y, point = true }
  else
    local p = w.capPoints[math.ceil(#w.capPoints / 2)]
    obj = { x = p.x, y = p.y, hold = true }
  end
  local dx, dy = U.norm(obj.x - ax, obj.y - ay)
  if dx == 0 and dy == 0 then dx = 1 end
  return { by = by, ax = ax, ay = ay, obj = obj, dx = dx, dy = dy }
end

function AI:conquestPlan(mine)
  local w = self.world
  local recon, rest = {}, {}
  for _, sq in ipairs(mine) do
    local L = sq.leader
    if L and L.alive and not sq.healing then
      if sq.type == "recon" then recon[#recon + 1] = sq else rest[#rest + 1] = sq end
    end
  end
  local plan = { of = {} }
  local taken = {}
  -- the main body (and, with 4+ squads, a second group), then the scouts on whatever's left
  local main, flank = rest, nil
  if #rest >= 4 then
    main, flank = {}, {}
    local armorSeen = false
    for _, sq in ipairs(rest) do
      local t = sq.type
      if t == "battery" or t == "aa" or (t == "armor" and not armorSeen) then
        main[#main + 1] = sq
        if t == "armor" then armorSeen = true end
      else
        flank[#flank + 1] = sq
      end
    end
    if #flank == 0 then flank = nil end
  end
  local gm = self:groupPlan(main, "main", taken)
  for _, sq in ipairs(main) do plan.of[sq] = gm end
  if flank then
    local gf = self:groupPlan(flank, "flank", taken)
    for _, sq in ipairs(flank) do plan.of[sq] = gf end
  end
  local me = w.ally[self.team]
  for _, sq in ipairs(recon) do
    local pi = sq.raidPoint
    if not pi or not w.capPoints[pi] or pointDone(w, w.capPoints[pi], me) then
      local blocked = {}
      for k in pairs(taken) do blocked[k] = true end
      pi = self:pickPoint(sq, blocked) or self:pickPoint(sq, {})
      sq.raidPoint = pi
    end
    if pi then taken[pi] = "raid" end
    local p = pi and w.capPoints[pi]
    plan.of[sq] = { raid = true, obj = p and { x = p.x, y = p.y } or { x = sq.leader.x, y = sq.leader.y } }
  end
  plan.main = gm
  return plan
end

-- where this squad should be, given the plan; { x, y, move = true } means just get there
function AI:roleGoal(sq, plan, foe, fd, fighting)
  local w = self.world
  local L = sq.leader
  local t = sq.type
  local W, H = w.map.w * w.T, w.map.h * w.T
  local function at(x, y, move) return { role = true, x = U.clamp(x, 120, W - 120), y = U.clamp(y, 120, H - 120), move = move } end
  if plan.of then plan = plan.of[sq] end
  if not plan then return nil end
  if plan.raid then
    -- a scout raid: straight for the point; give way to anything heavier than scouts
    if foe and fd < 240 and foe.key ~= "scout" and foe.def and foe.def.weapon then
      local bx, by2 = U.norm(L.x - foe.x, L.y - foe.y)
      return { role = true, x = U.clamp(L.x + bx * 260, 120, W - 120), y = U.clamp(L.y + by2 * 260, 120, H - 120), move = true }
    end
    return { role = true, x = plan.obj.x, y = plan.obj.y }
  end
  local ax, ay, dx, dy, obj = plan.ax, plan.ay, plan.dx, plan.dy, plan.obj
  local px, py = -dy, dx -- sideways
  local side = (sq.idx % 2 == 0) and 1 or -1
  local range = w:rangeOf(L)
  if t == "armor" then
    if fighting and foe then return at(foe.x, foe.y) end
    -- lead, but never so far out that the guns can't cover us
    local bat = plan.by.battery and plan.by.battery.leader
    if bat and U.dist(L.x, L.y, bat.x, bat.y) > 520 then return at(L.x, L.y) end
    if obj.hold then return at(obj.x, obj.y) end
    return at(obj.x, obj.y)
  elseif t == "recon" then
    -- too close to the fight: fall back behind the tanks and keep spotting from the edge of sight
    if foe and fd < 260 then
      local bx, by2 = U.norm(L.x - foe.x, L.y - foe.y)
      return at(L.x + bx * 220, L.y + by2 * 220, true)
    end
    -- screen out ahead and to one side of the force
    local ahead = obj.hold and 420 or 380
    return at(ax + dx * ahead + px * side * 160, ay + dy * ahead + py * side * 160)
  elseif t == "battery" then
    if foe and fd < 230 then
      -- something's on the guns: back off toward the armor
      local bx, by2 = U.norm(L.x - foe.x, L.y - foe.y)
      return at(L.x + bx * 200, L.y + by2 * 200, true)
    end
    if foe and fd < range * 0.95 then return at(L.x, L.y) end -- in reach: stay and shoot
    if foe and fd < range + 260 and S.sees(w, self.team, foe.x, foe.y) then
      -- creep up just until it's in reach
      local bx, by2 = U.norm(foe.x - L.x, foe.y - L.y)
      return at(foe.x - bx * range * 0.9, foe.y - by2 * range * 0.9)
    end
    return at(ax - dx * 240 + px * side * 60, ay - dy * 240 + py * side * 60, true)
  elseif t == "aa" then
    -- ride with the guns (or the tanks), between them and the enemy
    local g = plan.by.battery and plan.by.battery.leader or plan.by.armor and plan.by.armor.leader
    local gx, gy = g and g.x or ax, g and g.y or ay
    return at(gx + dx * 90, gy + dy * 90)
  elseif t == "air" then
    -- strike: their guns if we can see them, else whatever we're fighting; else circle the force
    local best, bd
    for _, o in ipairs(w.entities) do
      if o.alive and o.squad and w:hostile(o.team, self.team) and not o.broken and S.sees(w, self.team, o.x, o.y) then
        local d = U.dist(L.x, L.y, o.x, o.y) - (o.key == "artillery" and 500 or 0) - (o.key == "flak" and -400 or 0)
        if not bd or d < bd then best, bd = o, d end
      end
    end
    if best then return at(best.x, best.y) end
    return at(ax + dx * 120, ay + dy * 120)
  end
  if fighting and foe then return at(foe.x, foe.y) end
  return at(obj.x, obj.y)
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
  local plan = w.wih and self:armyPlan(mine) or (w.capPoints and self:conquestPlan(mine))
  for _, sq in ipairs(mine) do
    local L = sq.leader
    if L and L.alive and look[sq] and not sq.broken then
      local frac = squadHp(sq)
      -- nearest enemy to the leader (units first, then their HQ)
      local foe, fd
      for _, o in ipairs(w.entities) do
        if o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and (o.def.weapon or o.key == "hq")
          and not (o.smoked and U.dist(L.x, L.y, o.x, o.y) > 90) then
          local d = U.dist(L.x, L.y, o.x, o.y)
          -- War is Hell: the computer only knows what its side can see
          if w.wih and d > 400 and not S.sees(w, self.team, o.x, o.y) then d = nil end
          if d then
            if not o.def.building then d = d * 0.8 end
            if not fd or d < fd then foe, fd = o, d end
          end
        end
      end
      if w.wih and foe then self.lastSeen = { x = foe.x, y = foe.y, t = w.time } end
      -- War is Hell: shot at by something it can't see (artillery in the fog)? It knows roughly
      -- where from, and goes for it
      if w.wih and not foe then
        for _, u in ipairs(sq.members) do
          local hf = u.alive and u.hitFrom
          if hf and w.time - hf.t < 6 then
            foe, fd = { x = hf.x + self.rng:random(-80, 80), y = hf.y + self.rng:random(-80, 80), def = {} }, U.dist(L.x, L.y, hf.x, hf.y)
            self.lastSeen = { x = foe.x, y = foe.y, t = w.time }
            break
          end
        end
      end
      local fighting = foe and fd < 520
      -- pull back to heal, come back when healthy
      if sq.healing then
        if frac > 0.85 then sq.healing = nil end
      elseif w.wih and frac < self.retreatAt then
        -- War is Hell: there's nowhere to heal. A squad that pulls back is done fighting
        if self.team ~= w.playerTeam and w.ally[self.team] ~= w.ally[w.playerTeam] then
          S.breakUnits(w, sq.members, foe and foe.x or L.x, foe and foe.y or L.y)
          if w.onSquadBroken then w.onSquadBroken(w.ally[self.team], sq.members, false) end
          goto nextsq
        end
      elseif frac < self.retreatAt and (hq and hq.alive) then
        sq.healing = true
        -- (War is Hell: no HQ - fall back toward where we came in, out of the fight)
        local rx, ry = hq and hq.x or tm.startX, hq and hq.y or tm.startY
        for _, u in ipairs(sq.members) do
          if u.alive then w:issue(u, { type = "retreat", x = rx + self.rng:random(-90, 90), y = ry + self.rng:random(-90, 90) }) end
        end
      end
      local goal
      if plan then
        goal = self:roleGoal(sq, plan, foe, fd, fighting)
      elseif w.wih then
        goal = self:huntGoal(sq, foe, fighting)
      else
        local pi = self:pickPoint(sq, taken)
        goal = pi and w.capPoints[pi]
        if pi then taken[pi] = true end
        sq.goal = pi
      end
      if not sq.healing then
        -- fight what's close; otherwise go take the point; everyone stays with the leader
        local tx, ty
        if goal and (goal.hold or goal.role) then tx, ty = goal.x, goal.y -- (War is Hell: its part in the plan)
        elseif fighting then tx, ty = foe.x, foe.y
        elseif goal then tx, ty = goal.x, goal.y
        elseif foe then tx, ty = foe.x, foe.y end
        if tx then
          for _, u in ipairs(sq.members) do
            if u.alive then
              local o = u.orders[1]
              local far = u ~= L and U.dist(u.x, u.y, L.x, L.y) > 320
              if far then
                if not (o and o.type == "move") then w:issue(u, { type = "move", x = L.x, y = L.y }) end
              elseif goal and goal.role then
                -- spread out around the spot rather than piling onto it
                local kind = goal.move and "move" or "amove"
                if not o or o.type == "attack" and kind == "move" or ((o.type == "amove" or o.type == "move") and (o.type ~= kind or U.dist(o.x, o.y, tx, ty) > 110)) then
                  local jx, jy = 0, 0
                  if u ~= L then
                    local k = u.slotK or self.rng:random(1, 8); u.slotK = k
                    local a = k / 8 * math.pi * 2
                    jx, jy = math.cos(a) * 55, math.sin(a) * 55
                  end
                  w:issue(u, { type = kind, x = tx + jx, y = ty + jy })
                end
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
    ::nextsq::
  end
end

return S
