-- Commander Craft: a Warcraft-style mode. Workers mine gold and chop wood, a supply cap
-- (food) limits the army and upkeep taxes big armies, halls upgrade through three tiers,
-- each production building researches upgrades for its own units, and your Arena hero
-- (plus up to two more from the altar) levels up with cards. Destroy every enemy building.
local D = require("src.defs")
local U = require("src.util")
local ARENA = require("src.arena")

local C = {}
local CR = D.CRAFT
local XPDBG = os.getenv("PA_XPDBG")

C.XP_MUL = 1.9            -- hero experience per kill (scaled from the Arena's numbers)
C.HERO_XP_RANGE = 1000
C.MINE_TIME = 1.0         -- seconds a worker spends inside a gold mine
C.CHOP_TIME = 5.5         -- seconds to chop a load of wood
C.GOLD_LOAD, C.WOOD_LOAD = 10, 10
C.UPKEEP = { { 40, 1.0, "No upkeep" }, { 60, 0.7, "Low upkeep (-30% gold)" }, { 999, 0.4, "High upkeep (-60% gold)" } }

local function fx(w, kind, x, y, size, life, extra)
  local e = { kind = kind, x = x, y = y, t = 0, life = life or 0.5, size = size or 40 }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  w.effects[#w.effects + 1] = e
end

local function raceOf(w, team) return CR.byKey[w.teams[team].race] end
C.raceOf = raceOf

---------------------------------------------------------------------------
-- Setup

function C.setup(w, opts)
  local map = w.map
  local st = { pending = {}, wrecks = {}, zones = {}, mines = {}, camps = {}, heroes = {}, kills = {}, lost = {} }
  w.craft = st
  w.hs = st
  w.teams[0] = w.teams[0] or { neutral = true, metal = 0, energy = 0, mStore = 0, eStore = 0, mIncome = 0, eIncome = 0,
    mSpend = 0, eSpend = 0, incomeMul = 1, lastAttacked = -99, gold = 0, wood = 0 }
  local players = opts.players or {}
  local races = CR.races
  for t = 1, w.np do
    local tm = w.teams[t]
    local p = players[t] or {}
    local rk = p.race
    if not rk or not CR.byKey[rk] then rk = races[w.rngCmd:random(#races)].key end
    p.race = rk
    tm.race = rk
    tm.gold, tm.wood = CR.START_GOLD, CR.START_WOOD
    tm.tier = 1
    tm.research, tm.flags, tm.weap, tm.armor = {}, {}, 0, 0
    tm.metal, tm.energy = 0, 0
    st.kills[t], st.lost[t] = 0, 0
  end
  -- gold mines
  for _, m in ipairs(map.mines) do
    local x, y = (m.x + 1.5) * w.T, (m.y + 1.5) * w.T
    local e = w:spawn("goldmine", 0, x, y)
    e.neutral = true
    e.gold, e.goldMax = m.gold, m.gold
    e.center = m.center
    e.busyUntil = 0
    st.mines[#st.mines + 1] = e
  end
  -- each player: a hall, five workers, the starting hero
  for t = 1, w.np do
    local r = raceOf(w, t)
    local side = map.starts[t].side or t
    local hl = map.halls[side]
    local hx, hy = (hl.x + 2) * w.T, (hl.y + 2) * w.T
    local hall = w:spawn(r.hall, t, hx, hy)
    hall.rally = nil
    local mine = C.nearestMine(w, hx, hy)
    for i = 1, 5 do
      -- in a row just above the hall, toward the mine
      local px, py = hx - 80 + i * 32, hy - hall.def.h * w.T * 0.5 - 26
      local ptx, pty = map:tileAt(px, py)
      local nx, ny = map:nearestTile(ptx, pty, function(x, y) return map:passable("land", x, y) end, 6)
      if nx then px, py = map:center(nx, ny) end
      local u = w:spawn(r.worker, t, px, py)
      if mine then w:issue(u, { type = "harvest", kind = "gold", target = mine }) end
    end
    local c = w.teams[t].commander
    C.makeHero(w, c, (players[t] or {}).class)
    do
      -- just outside the hall, on its side toward the middle of the map
      local mx, my = map.w * w.T / 2, map.h * w.T / 2
      local dx, dy = U.norm(mx - hx, my - hy)
      local tx, ty = map:tileAt(hx + dx * 120, hy + dy * 120)
      local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("land", a, b) end, 8)
      c.x, c.y = nx and (nx + 0.5) * w.T or hx, ny and (ny + 0.5) * w.T or hy + 120
    end
    c.homeX, c.homeY = c.x, c.y
    w.teams[t].startX, w.teams[t].startY = hx, hy
  end
  -- neutral creep camps (hero experience, and the middle mine's guards)
  for _, cp in ipairs(map.camps or {}) do
    local x, y = (cp.x + 0.5) * w.T, (cp.y + 0.5) * w.T
    local comp = cp.kind == "big" and { "ogrelord", "gnoll", "gnoll", "gnollarcher", "gnollarcher" } or { "gnoll", "gnoll", "gnollarcher" }
    local camp = { x = x, y = y, units = {} }
    for i, key in ipairs(comp) do
      local a = i / #comp * math.pi * 2
      local u = w:spawn(key, 0, x + math.cos(a) * 46, y + math.sin(a) * 46)
      u.creepCamp = camp
      u.homeX, u.homeY = u.x, u.y
      camp.units[#camp.units + 1] = u
    end
    st.camps[#st.camps + 1] = camp
  end
  w.onCampAlert = function(camp, foe)
    if not foe.alive or foe.key == "goldmine" then return end
    for _, u in ipairs(camp.units) do
      if u.alive and #u.orders == 0 and not (u.retaliate and u.retaliate.alive) then u.retaliate = foe end
    end
  end
  C.recount(w)
end

-- the Arena class kit on a Craft hero: tougher and harder hitting than any unit, but
-- nowhere near an Arena Commander (that was built to fight a whole army alone)
function C.makeHero(w, c, cls)
  local team = c.team
  local r = raceOf(w, team)
  if not cls or not ARENA.byClass[cls] or not U.contains(r.heroes, cls) then
    local pool = {}
    for _, k in ipairs(r.heroes) do
      local taken = false
      for _, h in ipairs(C.heroesOf(w, team, true)) do if h.class == k then taken = true end end
      if not taken then pool[#pool + 1] = k end
    end
    if #pool == 0 then pool = r.heroes end
    cls = pool[w.rngCmd:random(#pool)]
  end
  c.class = cls
  c.hero = true
  c.skills = {}
  c.mods, c.taken, c.upgrades, c.offers = c.mods or {}, c.taken or {}, c.upgrades or {}, c.offers or {}
  c.cxp, c.clevel = c.cxp or 0, c.clevel or 0
  c.maxhp, c.hp = 1150, 1150
  c.mods.dmg = 0.62
  ARENA.byClass[cls].base(w, c)
  -- Craft heroes fight next to armies, not instead of them: Arena skills and attacks are tuned to
  -- take on whole lanes, so here they're scaled down (set with tools/battlesim.lua: a lone level-3
  -- hero should survive a 6-unit army only about half the time if it stands and fights)
  c.mods.dmg = (c.mods.dmg or 1) * 0.75
  c.mods.skillDmg = (c.mods.skillDmg or 1) * 0.6
  c.maxhp = math.floor(c.maxhp * 0.9); c.hp = c.maxhp
  -- and each hero leans into its role
  local role = C.ROLE_TUNING[cls]
  if role then role(c) end
  c.respawnX, c.respawnY = c.x, c.y
  -- a hero starts with one skill from his class
  local off = ARENA.offer(w, c, "skill")
  if off[1] then ARENA.learn(w, c, off[1].key) end
  return c
end

-- per-class Craft adjustments (Arena keeps its own numbers)
C.ROLE_TUNING = {
  -- the tank: holds the line, doesn't win fights alone
  juggernaut = function(c) c.mods.dmg = c.mods.dmg * 0.72; c.mods.skillDmg = (c.mods.skillDmg or 1) * 0.8 end,
  -- the support: less personal punch, but his army hits harder from the start (Aura: Might)
  warden = function(c) c.mods.dmg = c.mods.dmg * 0.75; c.mods.auraMight = true; c.taken.might = true end,
  -- the ranged carry: weak early, grows more per level than anyone
  -- the ranged carry: fragile and weak in a brawl, but quicker on his feet than anyone (keep them at
  -- the edge of his long range) and growing more per level
  ranger = function(c)
    c.mods.dmg = c.mods.dmg * 1.3; c.mods.levelDmg = 1.05
    c.maxhp = math.floor(c.maxhp * 1.15); c.hp = c.maxhp
    c.mods.speed = (c.mods.speed or 1) * 1.1
  end,
}

function C.heroesOf(w, team, includeDead)
  local out = {}
  for _, h in ipairs(w.craft and w.craft.heroes or {}) do
    if h.team == team and (includeDead or h.alive) then out[#out + 1] = h end
  end
  local c = w.teams[team] and w.teams[team].commander
  if c and (includeDead or c.alive) then
    local dup = false
    for _, h in ipairs(out) do if h == c then dup = true end end
    if not dup then table.insert(out, 1, c) end
  end
  return out
end

function C.spawnHero(w, team, cls, x, y)
  local c = w:spawn("commander", team, x, y)
  c.mods, c.taken, c.upgrades, c.offers = {}, {}, {}, {}
  c.cxp, c.clevel = 0, 0
  C.makeHero(w, c, cls)
  w.craft.heroes[#w.craft.heroes + 1] = c
  -- a later hero starts a little ahead, like an Arena catch-up
  local best = 0
  for _, h in ipairs(C.heroesOf(w, team, true)) do best = math.max(best, h.clevel or 0) end
  if best >= 3 then ARENA.commanderXP(w, c, ARENA.THRESHOLDS[math.max(1, best - 2)]) end
  if w.onHeroJoined then w.onHeroJoined(c) end
  return c
end

---------------------------------------------------------------------------
-- Economy: food, upkeep, prices

function C.recount(w)
  for t = 1, w.np do
    local tm = w.teams[t]
    tm.foodCap, tm.foodUsed = 0, 0
  end
  for _, e in ipairs(w.entities) do
    if e.alive and e.team and e.team > 0 then
      local tm = w.teams[e.team]
      if e.def.building then
        if e.built >= 1 and e.def.food then tm.foodCap = tm.foodCap + e.def.food end
        if e.queue then
          for _, k in ipairs(e.queue) do
            local d = D.units[k]
            tm.foodUsed = tm.foodUsed + (d.cost and d.cost.food or 0)
          end
        end
      elseif e.key == "commander" then
        tm.foodUsed = tm.foodUsed + CR.HERO_FOOD
      elseif e.def.cost and e.def.cost.food and not e.summon then
        tm.foodUsed = tm.foodUsed + e.def.cost.food
      end
    end
  end
  -- a dead hero waiting to rise still counts
  for _, h in ipairs(w.craft.heroes) do
    if not h.alive and h.respawnAt then w.teams[h.team].foodUsed = w.teams[h.team].foodUsed + CR.HERO_FOOD end
  end
  for t = 1, w.np do
    local tm = w.teams[t]
    local c = tm.commander
    if c and not c.alive and c.respawnAt then tm.foodUsed = tm.foodUsed + CR.HERO_FOOD end
    tm.foodCap = math.min(CR.FOOD_CAP, tm.foodCap)
  end
end

function C.upkeep(tm)
  local used = tm.foodUsed or 0
  for i, u in ipairs(C.UPKEEP) do
    if used <= u[1] then return u[2], u[3], i end
  end
  return 0.4, C.UPKEEP[3][3], 3
end

local function heroCount(w, team)
  local n = #C.heroesOf(w, team, true)
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team and e.queue then
      for _, k in ipairs(e.queue) do if D.units[k].heroRecruit then n = n + 1 end end
    end
  end
  return n
end

-- the real price of something right now (heroes get dearer)
function C.price(w, team, key)
  local d = D.units[key]
  if d.heroRecruit then
    local n = heroCount(w, team)
    local hc = CR.HERO_COST[math.min(#CR.HERO_COST, n + 1)]
    return hc.gold, hc.wood, CR.HERO_FOOD
  end
  return d.cost.gold or 0, d.cost.wood or 0, d.cost.food or 0
end

local function queuedAnywhere(w, team, key)
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team and e.queue then
      for _, k in ipairs(e.queue) do if k == key then return true end end
    end
  end
  return false
end

-- can this team order `key` right now? returns ok, reason
function C.canOrder(w, team, key)
  local tm = w.teams[team]
  local d = D.units[key]
  if not d then return false, "?" end
  local r = raceOf(w, team)
  if d.building and not U.contains(D.units[r.worker].builds, key) then return false, "Not a " .. r.name .. " building" end
  if d.tier and (tm.tier or 1) < d.tier then
    return false, "Needs " .. r.tierNames[d.tier] .. " (upgrade your " .. r.tierNames[1] .. ")"
  end
  if d.research then
    if tm.research[key] then return false, "Already researched" end
    if queuedAnywhere(w, team, key) then return false, "Already being researched" end
    if d.after and not tm.research[d.after] then return false, "Needs " .. D.units[d.after].name .. " first" end
  end
  if d.heroRecruit then
    local n = heroCount(w, team)
    if n >= CR.MAX_HEROES then return false, "You already have three heroes" end
    if n >= 1 and (tm.tier or 1) < n + 1 then return false, "Hero #" .. (n + 1) .. " needs " .. r.tierNames[n + 1] end
    for _, h in ipairs(C.heroesOf(w, team, true)) do
      if h.class == d.heroRecruit then return false, "That hero is already yours" end
    end
    if queuedAnywhere(w, team, key) then return false, "Already summoning that hero" end
  end
  local g, wd, food = C.price(w, team, key)
  if tm.gold < g then return false, string.format("Not enough gold (%d)", g) end
  if tm.wood < wd then return false, string.format("Not enough wood (%d)", wd) end
  if food > 0 and (tm.foodUsed or 0) + food > (tm.foodCap or 0) then
    if (tm.foodCap or 0) >= CR.FOOD_CAP then return false, "Food cap reached (" .. CR.FOOD_CAP .. ")" end
    return false, "Not enough food: build more " .. D.units[r.farm].name .. "s"
  end
  return true
end

function C.payFor(w, team, key, who)
  local ok, why = C.canOrder(w, team, key)
  if not ok then
    if w.onCraftRefused and team == w.playerTeam then w.onCraftRefused(why, who) end
    return false, why
  end
  local tm = w.teams[team]
  local g, wd, food = C.price(w, team, key)
  tm.gold, tm.wood = tm.gold - g, tm.wood - wd
  tm.foodUsed = (tm.foodUsed or 0) + food
  return true
end

-- queue a unit / research / hero at a building, paying up front
function C.enqueue(w, f, key)
  if not f.alive or f.built < 1 then return false end
  if #f.queue >= 5 then return false, "Queue full" end
  local ok, why = C.payFor(w, f.team, key, f)
  if not ok then return false, why end
  local g, wd = C.price(w, f.team, key)
  f.queue[#f.queue + 1] = key
  f.paid = f.paid or {}
  f.paid[#f.queue] = { g, wd }
  return true
end

function C.dequeue(w, f, i)
  local key = f.queue[i]
  if not key then return end
  table.remove(f.queue, i)
  local paid = f.paid and table.remove(f.paid, i)
  local tm = w.teams[f.team]
  if paid then tm.gold, tm.wood = tm.gold + paid[1], tm.wood + paid[2] end
  if i == 1 then f.progress = 0 end
  C.recount(w)
end

-- a factory finished something: research and heroes don't walk out of the door
function C.produce(w, f, key)
  local d = D.units[key]
  if f.paid then table.remove(f.paid, 1) end
  local tm = w.teams[f.team]
  if d.heroRecruit then
    local x, y = f.x, f.y + f.def.h * w.T * 0.5 + 30
    local c = C.spawnHero(w, f.team, d.heroRecruit, x, y)
    if f.rally and f.rally.x then w:issue(c, { type = "move", x = f.rally.x, y = f.rally.y }) end
    return true
  end
  if not d.research then return false end
  tm.research[key] = true
  if d.tierUp then
    tm.tier = math.max(tm.tier, d.tierUp)
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == f.team and e.def.hall then e.maxhp = e.maxhp + 1000; e.hp = e.hp + 1000 end
    end
  end
  if d.stat == "weap" then tm.weap = math.max(tm.weap, d.level) end
  if d.stat == "armor" then tm.armor = math.max(tm.armor, d.level) end
  if d.flag then tm.flags[d.flag] = true end
  if d.unitMods then
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == f.team and d.unitMods[e.key] then C.applyMods(w, e, d.unitMods[e.key]) end
    end
  end
  if w.onResearch then w.onResearch(f.team, d) end
  return true
end

function C.applyMods(w, e, m)
  e.mods = e.mods or {}
  if m.hp then local old = e.maxhp; e.maxhp = math.floor(e.maxhp * m.hp); e.hp = e.hp + (e.maxhp - old) end
  if m.range then e.mods.range = (e.mods.range or 1) * m.range end
  if m.regen then e.mods.regen = (e.mods.regen or 0) + m.regen end
  if m.dmg then e.mods.craftDmg = (e.mods.craftDmg or 1) * m.dmg end
  if m.splash then
    local base = e.def.weapon and e.def.weapon.splash or 0
    e.mods.splash = base > 0 and base * m.splash or m.splash
  end
  if m.poison then e.stancePoison = m.poison end
  if m.ensnare then e.stanceChill = true end
  if m.rangedArmor then e.mods.rangedArmor = m.rangedArmor end
end

-- every new unit gets its side's finished research
function C.onSpawn(w, u)
  local tm = w.teams[u.team]
  if not tm or not tm.research then return end
  for k in pairs(tm.research) do
    local d = D.units[k]
    if d.unitMods and d.unitMods[u.key] then C.applyMods(w, u, d.unitMods[u.key]) end
  end
end

---------------------------------------------------------------------------
-- Combat modifiers

local function isMelee(e) return e.def.melee or (e.mods and e.mods.melee) end

function C.damageMul(w, e, o)
  local m = 1
  local tm = w.teams[e.team]
  if e.key ~= "commander" and not e.def.building and tm and tm.weap then m = m * (1 + 0.12 * tm.weap) end
  if e.mods and e.mods.craftDmg then m = m * e.mods.craftDmg end
  if o and o.def.building then
    local wpn = e.def.weapon
    if e.key == "commander" then m = m * 0.5
    elseif wpn and wpn.bldMul then m = m * wpn.bldMul
    elseif e.def.building then m = m * 0.6
    else m = m * 0.75 end
  end
  return m
end

function C.armorMul(w, o, attacker)
  local m = o.def.armor or 1
  local tm = w.teams[o.team]
  if tm and tm.armor and not o.def.building and o.key ~= "commander" and o.team > 0 then m = m * (1 - 0.09 * tm.armor) end
  if o.mods and o.mods.rangedArmor and attacker and not isMelee(attacker) then m = m * o.mods.rangedArmor end
  if o.def.building and tm and tm.flags then
    if tm.flags.masonry then m = m * 0.8 end
    -- Spiked Barricades: melee attackers get hurt back
    if tm.flags.spikes and attacker and attacker.alive and isMelee(attacker) and attacker.key ~= "commander" then
      attacker.spikeAcc = (attacker.spikeAcc or 0) + 1
    end
  end
  -- Pillage: melee hits on enemy buildings steal gold
  if o.def.building and attacker and attacker.team and attacker.team > 0 and isMelee(attacker) then
    local atm = w.teams[attacker.team]
    if atm.flags and atm.flags.pillage and w:hostile(attacker.team, o.team) and o.team > 0 then
      atm.gold = atm.gold + 4
      if math.random() < 0.15 then fx(w, "label", o.x, o.y - 30, 11, 0.8, { text = "+gold", color = { 1, 0.85, 0.3 } }) end
    end
  end
  return m
end

---------------------------------------------------------------------------
-- Harvesting

function C.nearestMine(w, x, y)
  local best, bd
  for _, m in ipairs(w.craft.mines) do
    if m.alive and m.gold > 0 then
      local d = U.dist(x, y, m.x, m.y)
      if not bd or d < bd then best, bd = m, d end
    end
  end
  return best, bd
end

function C.nearestDropoff(w, team, x, y, kind)
  local best, bd
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team and e.built >= 1 and e.def.dropoff and e.def.dropoff[kind] then
      local d = U.dist(x, y, e.x, e.y)
      if not bd or d < bd then best, bd = e, d end
    end
  end
  return best, bd
end

-- nearest standing tree to a point (tile coords), searching outward
function C.nearestTree(w, tx, ty, maxR, bad)
  local map = w.map
  for r = 0, maxR or 14 do
    local best, bd
    for dy = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then
          local x, y = tx + dx, ty + dy
          if map:inBounds(x, y) and map.terrain[y * map.w + x] == 4 and not (bad and bad[y * map.w + x]) then
            -- must have an open neighbour to stand on
            local open = false
            for _, n in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
              if map:passable("land", x + n[1], y + n[2]) then open = true end
            end
            if open then
              local d = dx * dx + dy * dy
              if not bd or d < bd then best, bd = { x = x, y = y }, d end
            end
          end
        end
      end
    end
    if best then return best end
  end
end

local function standSpot(w, e, tree)
  local map = w.map
  local best, bd
  for _, n in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
    local x, y = tree.x + n[1], tree.y + n[2]
    if map:passable("land", x, y) then
      local cx, cy = map:center(x, y)
      local d = U.dist(e.x, e.y, cx, cy)
      if not bd or d < bd then best, bd = { cx, cy }, d end
    end
  end
  return best
end

-- the spot just outside a building, on the walker's side
local function edgeOf(w, e, b, gap)
  local dx, dy = U.norm(e.x - b.x, e.y - b.y)
  if dx == 0 and dy == 0 then dx, dy = 0, 1 end
  local half = b.def.w * w.T * 0.5
  -- square footprint: scale the direction to reach the square's edge
  local k = half / math.max(math.abs(dx), math.abs(dy), 0.01)
  return b.x + dx * (k + (gap or 12)), b.y + dy * (k + (gap or 12))
end

local function walkTo(w, e, x, y, dt, arrive)
  if not e.path or e.destX ~= x or e.destY ~= y then w:setDest(e, x, y) end
  return w:followPath(e, dt, arrive or 10)
end

function C.updateHarvest(w, e, o, dt)
  local tm = w.teams[e.team]
  local carry = e.carry
  local full = carry and carry.amount >= (carry.kind == "gold" and C.GOLD_LOAD or C.woodLoad(tm))
  -- 1. bring a load home
  if full or (carry and o.returning) then
    local drop = C.nearestDropoff(w, e.team, e.x, e.y, carry.kind)
    if not drop then w:popOrder(e); return end
    local reach = drop.def.w * w.T * 0.72 + e.def.radius + 14
    if U.dist(e.x, e.y, drop.x, drop.y) > reach then
      if not o.edge or o.edgeFor ~= drop then o.edge = { edgeOf(w, e, drop) }; o.edgeFor = drop end
      if walkTo(w, e, o.edge[1], o.edge[2], dt, 8) then o.edge = nil end
      return
    end
    o.edge = nil
    e.path = nil
    if carry.kind == "gold" then
      local mul = C.upkeep(tm) * (tm.goldMul or 1)
      tm.gold = tm.gold + carry.amount * mul
      tm.goldIn = (tm.goldIn or 0) + carry.amount * mul
    else
      tm.wood = tm.wood + carry.amount
      tm.woodIn = (tm.woodIn or 0) + carry.amount
    end
    e.carry = nil
    o.returning = nil
    if o.kind ~= carry.kind then o.kind = carry.kind end
    return
  end
  -- 2. gold: walk to the mine, wait your turn, go inside
  if o.kind == "gold" then
    local m = o.target
    if not m or not m.alive or m.gold <= 0 then
      local nm = C.nearestMine(w, e.x, e.y)
      if nm and U.dist(e.x, e.y, nm.x, nm.y) < 1400 then o.target = nm; m = nm
      else w:popOrder(e); return end
    end
    local reach = m.def.w * w.T * 0.72 + e.def.radius + 12
    if U.dist(e.x, e.y, m.x, m.y) > reach then
      if not o.edge or o.edgeFor ~= m then o.edge = { edgeOf(w, e, m) }; o.edgeFor = m end
      if walkTo(w, e, o.edge[1], o.edge[2], dt, 8) then o.edge = nil end
      return
    end
    o.edge = nil
    e.path = nil
    if w.time >= (m.busyUntil or 0) then
      m.busyUntil = w.time + C.MINE_TIME
      e.inMine = m
      e.inMineUntil = w.time + C.MINE_TIME
      e.dormant = true
    end
    return
  end
  -- 3. wood: walk to a tree, chop, carry it home
  local tr = o.tree
  if not tr or w.map.terrain[tr.y * w.map.w + tr.x] ~= 4 then
    local tx, ty = w.map:tileAt(e.x, e.y)
    if tr then tx, ty = tr.x, tr.y end
    tr = C.nearestTree(w, tx, ty, 16, o.bad)
    -- this grove is used up (or out of reach): look further afield before giving up
    if not tr then tr = C.nearestTree(w, tx, ty, 40, o.bad) end
    if not tr then w:popOrder(e); return end
    o.tree = tr
    o.spot = nil
  end
  o.spot = o.spot or standSpot(w, e, tr)
  local function giveUpOn(t)
    -- a tree nobody can get next to (walled in by buildings or other trees): skip it from now on
    o.bad = o.bad or {}
    o.bad[t.y * w.map.w + t.x] = true
    o.tree, o.spot = nil, nil
    e.path = nil
  end
  if not o.spot then giveUpOn(tr); return end
  if U.dist(e.x, e.y, o.spot[1], o.spot[2]) > 18 then
    if walkTo(w, e, o.spot[1], o.spot[2], dt, 8) and U.dist(e.x, e.y, o.spot[1], o.spot[2]) > 30 then
      -- the path ended short of the tree: it can't be reached
      giveUpOn(tr)
    end
    return
  end
  e.path = nil
  e.angle = math.atan2((tr.y + 0.5) * w.T - e.y, (tr.x + 0.5) * w.T - e.x)
  e.chopT = (e.chopT or 0) + dt
  e.chopping = true
  if e.chopT >= C.CHOP_TIME then
    e.chopT = 0
    local i = tr.y * w.map.w + tr.x
    local load = C.woodLoad(tm)
    local left = (w.map.wood[i] or 0)
    local got = math.min(load, left)
    w.map.wood[i] = left - got
    if w.map.wood[i] <= 0 then w.map:fellTree(tr.x, tr.y); o.tree = nil end
    e.carry = { kind = "wood", amount = got }
    e.chopping = nil
  end
end

-- a fresh worker gets to work: gold until the mine has five, then wood. A hall's rally
-- point on a mine or a tree sends them straight there; on open ground they just go there.
function C.autoGather(w, u, rally)
  if rally and rally.x then
    local rm, rd = C.nearestMine(w, rally.x, rally.y)
    if rm and rd < 110 then w:issue(u, { type = "harvest", kind = "gold", target = rm }); return end
    local tx, ty = w.map:tileAt(rally.x, rally.y)
    if w.map:inBounds(tx, ty) and w.map.terrain[ty * w.map.w + tx] == 4 then
      w:issue(u, { type = "harvest", kind = "wood", tree = { x = tx, y = ty } }); return
    end
    return
  end
  local m = C.nearestMine(w, u.x, u.y)
  local onGold = 0
  if m then
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == u.team and e.orders and e.orders[1] and e.orders[1].type == "harvest" and e.orders[1].target == m then onGold = onGold + 1 end
    end
  end
  if m and U.dist(u.x, u.y, m.x, m.y) < 900 and onGold < 5 then
    w:issue(u, { type = "harvest", kind = "gold", target = m })
  else
    local tx, ty = w.map:tileAt(u.x, u.y)
    local tr = C.nearestTree(w, tx, ty, 18)
    if tr then w:issue(u, { type = "harvest", kind = "wood", tree = tr }) end
  end
end

function C.woodLoad(tm) return (tm.flags and tm.flags.lumber) and 15 or C.WOOD_LOAD end

---------------------------------------------------------------------------
-- Per-frame

local function hostileFighterNear(w, e, r)
  local best, bd
  w:query(e.x, e.y, r + 30, function(o)
    if o.alive and not o.dormant and not o.neutral and w:hostile(o.team, e.team) and not o.def.building then
      local d = U.dist(e.x, e.y, o.x, o.y)
      if d <= r and (not bd or d < bd) then best, bd = o, d end
    end
  end)
  return best
end

function C.update(w, dt)
  local st = w.craft
  if w.over then return end
  local t = w.time
  -- workers inside a mine come out with gold
  for _, e in ipairs(w.entities) do
    if e.alive and e.inMineUntil and t >= e.inMineUntil then
      local m = e.inMine
      e.dormant, e.inMine, e.inMineUntil = nil, nil, nil
      local got = 0
      if m and m.alive then
        got = math.min(C.GOLD_LOAD, m.gold)
        m.gold = m.gold - got
        if m.gold <= 0 then
          if w.onMineEmpty then w.onMineEmpty(m) end
          w:kill(m)
        end
        -- pop out on the hall side of the mine
        local drop = C.nearestDropoff(w, e.team, m.x, m.y, "gold")
        if drop then
          local dx, dy = U.norm(drop.x - m.x, drop.y - m.y)
          e.x, e.y = m.x + dx * (m.def.w * w.T * 0.5 + 14), m.y + dy * (m.def.w * w.T * 0.5 + 14)
        end
      end
      if got > 0 then e.carry = { kind = "gold", amount = got } end
    end
  end
  local tick = ARENA.tickHeroes(w, dt, st)
  if tick then
    C.recount(w)
    -- casters: Clerics heal, Magi slow, Shamans bloodlust, Mystics' healing wards
    for _, e in ipairs(w.entities) do
      if e.alive and e.team and e.team > 0 and not e.dormant then
        local d = e.def
        local tm = w.teams[e.team]
        if d.healer then
          e.castT = (e.castT or 0) - 0.25
          if e.castT <= 0 then
            local adept = tm.flags.clericAdept
            local best, bf
            w:query(e.x, e.y, d.healer.range + 30, function(u)
              if u.alive and u.team == e.team and not u.def.building and u.hp < u.maxhp - 20 and U.dist(e.x, e.y, u.x, u.y) <= d.healer.range then
                local f = u.hp / u.maxhp
                if not bf or f < bf then best, bf = u, f end
              end
            end)
            if best then
              best.hp = math.min(best.maxhp, best.hp + d.healer.amount * (adept and 1.6 or 1))
              best.healing = 0.6
              fx(w, "beam", e.x, e.y, 3, 0.35, { x2 = best.x, y2 = best.y, color = { 1, 1, 0.6 } })
              e.castT = d.healer.every * (adept and 0.8 or 1)
            end
          end
        end
        if d.slower then
          e.castT = (e.castT or 0) - 0.25
          if e.castT <= 0 then
            local adept = tm.flags.magusAdept
            local n = 0
            for _ = 1, adept and 2 or 1 do
              local o = hostileFighterNear(w, e, d.slower.range)
              if o and not (o.slowUntil and o.slowUntil > t + 1) then
                o.slowUntil = t + d.slower.dur * (adept and 1.5 or 1)
                fx(w, "beam", e.x, e.y, 3, 0.35, { x2 = o.x, y2 = o.y, color = { 0.6, 0.6, 1 } })
                n = n + 1
              end
            end
            if n > 0 then e.castT = d.slower.every end
          end
        end
        if d.lust then
          e.castT = (e.castT or 0) - 0.25
          if e.castT <= 0 then
            local adept = tm.flags.shamanAdept
            local best
            w:query(e.x, e.y, d.lust.range + 30, function(u)
              if not best and u.alive and u.team == e.team and not u.def.building and u.def.weapon and isMelee(u)
                and u.chase and u.chase.alive and not (u.buffs and u.buffs.rof and u.buffs.rof[2] > t + 2) then best = u end
            end)
            if not best then
              w:query(e.x, e.y, d.lust.range + 30, function(u)
                if not best and u.alive and u.team == e.team and not u.def.building and u.def.weapon and u ~= e
                  and (u.chase or (u.orders[1] and u.orders[1].type == "attack")) and not (u.buffs and u.buffs.rof and u.buffs.rof[2] > t + 2) then best = u end
              end)
            end
            if best then
              local dur = d.lust.dur * (adept and 1.5 or 1)
              ARENA.buff(best, "rof", d.lust.rof, dur, w)
              ARENA.buff(best, "speed", d.lust.speed, dur, w)
              fx(w, "ring", best.x, best.y, 26, 0.5, { color = { 1, 0.3, 0.2 } })
              e.castT = d.lust.every * (adept and 0.7 or 1)
            end
          end
        end
        if d.ward then
          e.castT = (e.castT or 0) - 0.25
          if e.castT <= 0 then
            e.castT = d.ward.every
            local amt = d.ward.amount * (tm.flags.mysticAdept and 1.6 or 1)
            local any = false
            w:query(e.x, e.y, d.ward.range + 30, function(u)
              if u.alive and u.team == e.team and not u.def.building and u.hp < u.maxhp and U.dist(e.x, e.y, u.x, u.y) <= d.ward.range then
                u.hp = math.min(u.maxhp, u.hp + amt); u.healing = 0.5; any = true
              end
            end)
            if any then fx(w, "ring", e.x, e.y, d.ward.range, 0.5, { color = { 0.4, 1, 0.5 } }) end
          end
        end
        -- Spiked Barricades: pay back what was stored up this tick
        if e.spikeAcc then
          local n = e.spikeAcc
          e.spikeAcc = nil
          w:damage(e, n * (d.weapon and d.weapon.damage or 10) * 0.2, nil)
        end
      end
    end
    -- heroes standing by one of their halls recover quickly (2% a second)
    for _, h in ipairs(w.entities) do
      if h.alive and h.key == "commander" and h.hp < h.maxhp and h.team and h.team > 0 then
        local near = false
        w:query(h.x, h.y, 420, function(b) if b.alive and b.team == h.team and b.def.hall and b.built >= 1 and U.dist(b.x, b.y, h.x, h.y) < 400 then near = true end end)
        if near then h.hp = math.min(h.maxhp, h.hp + h.maxhp * 0.005); h.healing = 0.4 end
      end
    end
    -- fallen heroes rise at an altar (or the hall)
    for tt = 1, w.np do
      for _, h in ipairs(C.heroesOf(w, tt, true)) do
        if not h.alive and h.respawnAt and t >= h.respawnAt and not w.teams[tt].dead then
          local spot = C.reviveSpot(w, tt)
          local cost = C.reviveCost(h)
          if spot and w.teams[tt].gold >= cost then
            w.teams[tt].gold = w.teams[tt].gold - cost
            h.respawnX, h.respawnY = spot.x, spot.y + spot.def.h * w.T * 0.5 + 30
            ARENA.respawn(w, h)
          end
        end
      end
    end
  end
  -- income statistics (per minute) for the HUD
  st.rateT = (st.rateT or 0) + dt
  if st.rateT >= 10 then
    for tt = 1, w.np do
      local tm = w.teams[tt]
      tm.goldRate = (tm.goldIn or 0) / st.rateT * 60
      tm.woodRate = (tm.woodIn or 0) / st.rateT * 60
      tm.goldIn, tm.woodIn = 0, 0
    end
    st.rateT = 0
  end
  -- elimination: a side with no buildings left is out
  st.elimT = (st.elimT or 0) - dt
  if st.elimT <= 0 then
    st.elimT = 1
    local blds, halls = {}, {}
    for _, e in ipairs(w.entities) do
      if e.alive and e.def.building and e.team and e.team > 0 then
        blds[e.team] = (blds[e.team] or 0) + 1
        if e.def.hall then halls[e.team] = true end
      end
    end
    for tt = 1, w.np do
      local tm = w.teams[tt]
      if not tm.dead then
        if not blds[tt] then w:eliminate(tt)
        elseif not halls[tt] and not tm.revealed then
          tm.revealed = true
          if w.onRevealed then w.onRevealed(tt) end
        elseif halls[tt] then tm.revealed = nil end
        if tm.revealed then
          -- no hall: every enemy can see your buildings
          for _, e in ipairs(w.entities) do
            if e.alive and e.team == tt and e.def.building then
              for t2 = 1, w.np do if w:hostile(t2, tt) then e.seen[t2] = true end end
            end
          end
        end
      end
    end
  end
end

-- bringing a hero back costs gold (more for a higher level); no gold, no hero
function C.reviveCost(h) return 80 + 30 * (h.clevel or 0) end

function C.reviveSpot(w, team)
  local altar, hall
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == team and e.built >= 1 then
      if e.def.altar then altar = altar or e end
      if e.def.hall then hall = hall or e end
    end
  end
  return altar or hall
end

---------------------------------------------------------------------------
-- Kills: hero experience, bounties, revives

function C.xpValue(o)
  if o.key == "commander" then return 110 + 60 * (o.clevel or 0) end
  if o.def.building then return 0 end
  if o.summon then return 20 end
  return o.def.xp or 20
end

function C.onKill(w, o, attacker)
  local st = w.craft
  if o.key == "goldmine" then return end
  if o.team and o.team > 0 then st.lost[o.team] = (st.lost[o.team] or 0) + 1 end
  if attacker and attacker.team and attacker.team > 0 and o.team ~= attacker.team then
    st.kills[attacker.team] = (st.kills[attacker.team] or 0) + 1
  end
  -- wrecks for the Reclaimer
  if not o.def.building and o.key ~= "commander" and not o.summon then
    st.wrecks[#st.wrecks + 1] = { x = o.x, y = o.y, t = w.time }
    if #st.wrecks > 40 then table.remove(st.wrecks, 1) end
  end
  -- bounty for neutral creeps
  if o.team == 0 and o.def.bounty and attacker and attacker.team and attacker.team > 0 then
    w.teams[attacker.team].gold = w.teams[attacker.team].gold + o.def.bounty
    fx(w, "label", o.x, o.y - 20, 12, 1.2, { text = "+" .. o.def.bounty .. " gold", color = { 1, 0.85, 0.3 } })
  end
  if o.key == "commander" then C.heroDied(w, o, attacker) end
  if o.noXP then return end
  local value = C.xpValue(o) * C.XP_MUL
  if value <= 0 then return end
  -- every hostile hero close by shares it evenly (Warcraft style)
  local takers = {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.key == "commander" and e.skills and (o.team == 0 or w:hostile(e.team, o.team))
      and U.dist(e.x, e.y, o.x, o.y) < C.HERO_XP_RANGE then
      if not attacker or attacker.team == nil or attacker.team == 0 or w:allied(e.team, attacker.team) or o.team == 0 then
        takers[#takers + 1] = e
      end
    end
  end
  for _, h in ipairs(takers) do ARENA.commanderXP(w, h, value / #takers) end
  if XPDBG then print(string.format("XP t=%d victim=%s(team %s) value=%d takers=%d killer=%s", w.time, o.key, tostring(o.team), value, #takers, attacker and attacker.key or "?")) end
end

function C.heroDied(w, c, attacker)
  c.respawnAt = w.time + 12 + 3 * (c.clevel or 0)
  c.pulse, c.dots = nil, nil
  if w.onCommanderDown then w.onCommanderDown(c, attacker) end
end

---------------------------------------------------------------------------
-- Score par: a clean 1v1 win takes about this long

function C.par(w) return 16 * 60 end

---------------------------------------------------------------------------
-- Drawing helpers (trees and mines)

function C.drawGround(w, x0, y0, x1, y1)
  local lg = love.graphics
  local map = w.map
  local T = w.T
  local tx0, tx1 = math.max(0, math.floor(x0 / T) - 1), math.min(map.w - 1, math.ceil(x1 / T) + 1)
  local ty0, ty1 = math.max(0, math.floor(y0 / T) - 1), math.min(map.h - 1, math.ceil(y1 / T) + 1)
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local i = ty * map.w + tx
      if map.terrain[i] == 4 then
        local cx, cy = (tx + 0.5) * T, (ty + 0.5) * T
        local h = (i * 7919) % 97 / 97
        local r = T * (0.55 + h * 0.2)
        local ox, oy = (h - 0.5) * 6, ((i * 31) % 13 / 13 - 0.5) * 6
        lg.setColor(0.05, 0.12, 0.05, 0.55)
        lg.circle("fill", cx + ox + 3, cy + oy + 4, r)
        lg.setColor(0.13 + h * 0.05, 0.32 + h * 0.08, 0.13, 1)
        lg.circle("fill", cx + ox, cy + oy, r)
        lg.setColor(0.2 + h * 0.06, 0.44 + h * 0.08, 0.18, 1)
        lg.circle("fill", cx + ox - r * 0.25, cy + oy - r * 0.25, r * 0.55)
        local wd = map.wood[i] or 100
        if wd < 100 then
          lg.setColor(0.55, 0.38, 0.2, 0.9)
          lg.circle("fill", cx + ox, cy + oy + r * 0.4, 3)
        end
      end
    end
  end
end

return C
