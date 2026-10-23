-- Commander Arena: no base building. Each side has a Core and two towers per lane;
-- creep waves march down three lanes; Commanders level from creeps, kills and towers,
-- pick class skills, die and respawn. Destroy the enemy Core to win.
local D = require("src.defs")
local U = require("src.util")
local Map = require("src.map")

local A = {}

A.WAVE_FIRST = 12
A.WAVE_EVERY = 30
A.MAX_LEVEL = 10
-- cumulative XP for levels 1..10
A.THRESHOLDS = { 150, 380, 700, 1100, 1600, 2200, 2900, 3700, 4600, 5600 }
A.SKILL_LEVELS = { [2] = 1, [4] = 2, [8] = 3 }   -- level -> skill slot (Q, W, E)
A.ULT_LEVEL = 6
A.FOUNTAIN_R = 400
A.KEYS = { "q", "w", "e", "r" }

---------------------------------------------------------------------------
-- small helpers

local function now(w) return w.time end

function A.buff(e, key, value, dur, w)
  e.buffs = e.buffs or {}
  local cur = e.buffs[key]
  local untilT = w.time + dur
  if cur and cur[2] > w.time and cur[1] ~= value then
    -- stronger of the two wins; refresh duration
    if (key == "armor" and value < cur[1]) or (key ~= "armor" and value > cur[1]) then cur[1] = value end
    cur[2] = math.max(cur[2], untilT)
  else
    e.buffs[key] = { value, untilT }
  end
end

local function fx(w, kind, x, y, size, life, extra)
  local e = { kind = kind, x = x, y = y, t = 0, life = life or 0.5, size = size or 40 }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  w.effects[#w.effects + 1] = e
  return e
end

local function hostiles(w, src, x, y, r, includeBuildings)
  local out = {}
  w:query(x, y, r + 40, function(o)
    if o.alive and not o.dormant and not o.neutral and w:hostile(o.team, src.team)
      and (includeBuildings or not o.def.building) and o.def.domain ~= "air" then
      if U.dist(x, y, o.x, o.y) <= r + o.def.radius * 0.5 then out[#out + 1] = o end
    end
  end)
  return out
end
A.hostiles = hostiles

local function friends(w, src, x, y, r)
  local out = {}
  w:query(x, y, r + 40, function(o)
    if o.alive and not o.def.building and w:allied(o.team, src.team) and U.dist(x, y, o.x, o.y) <= r then out[#out + 1] = o end
  end)
  return out
end

local function skillDmg(c, base) return base * ((c.mods and c.mods.skillDmg) or 1) * (1 + 0.06 * ((c.clevel or 1) - 1)) end

-- damage that respects structure protection; buildings take a fraction
local function hit(w, src, o, dmg, bldMul)
  if o.def.building then dmg = dmg * (bldMul or 0.35) end
  w:damage(o, dmg, src)
end

local function area(w, src, x, y, r, dmg, opts)
  opts = opts or {}
  local list = hostiles(w, src, x, y, r, opts.buildings)
  for _, o in ipairs(list) do
    if o.alive then
      hit(w, src, o, dmg, opts.bldMul)
      if o.alive and not o.def.building then
        if opts.stun then o.stunUntil = math.max(o.stunUntil or 0, w.time + opts.stun) end
        if opts.slow then o.slowUntil = math.max(o.slowUntil or 0, w.time + opts.slow) end
        if opts.amp then o.ampUntil = math.max(o.ampUntil or 0, w.time + opts.amp) end
      end
    end
  end
  return #list
end
A.area = area

local function lineHit(w, src, tx, ty, len, width, dmg, color)
  local dx, dy = U.norm(tx - src.x, ty - src.y)
  local ex, ey = src.x + dx * len, src.y + dy * len
  w:query((src.x + ex) / 2, (src.y + ey) / 2, len / 2 + width + 40, function(o)
    if o.alive and not o.neutral and w:hostile(o.team, src.team) and o.def.domain ~= "air" then
      local vx, vy = o.x - src.x, o.y - src.y
      local t = vx * dx + vy * dy
      if t >= 0 and t <= len then
        local px, py = src.x + dx * t, src.y + dy * t
        if U.dist(px, py, o.x, o.y) <= width + o.def.radius then hit(w, src, o, dmg, 0.3) end
      end
    end
  end)
  fx(w, "beam", src.x, src.y, width, 0.35, { x2 = ex, y2 = ey, color = color })
end

local function dash(w, e, tx, ty, maxD)
  local dx, dy, len = U.norm(tx - e.x, ty - e.y)
  local d = math.min(maxD, len)
  local map = w.map
  local bx, by = e.x, e.y
  local step = 8
  for s = step, d, step do
    local x, y = e.x + dx * s, e.y + dy * s
    local tx2, ty2 = map:tileAt(x, y)
    if map:passable("land", tx2, ty2) then bx, by = x, y else break end
  end
  fx(w, "beam", e.x, e.y, 6, 0.3, { x2 = bx, y2 = by, color = { 0.8, 0.9, 1 } })
  e.x, e.y = bx, by
  e.path, e.destX, e.chase = nil, nil, nil
  if not w:isFleeing(e) then e.orders = {} end
  e.homeX, e.homeY = bx, by
end

local function chain(w, src, x, y, dmg, bounces, jump, color)
  local hitSet = {}
  local cur = nil
  local best, bd
  for _, o in ipairs(hostiles(w, src, x, y, 200)) do
    local d = U.dist(x, y, o.x, o.y)
    if not bd or d < bd then best, bd = o, d end
  end
  cur = best
  local px, py = src.x, src.y
  local n = 0
  while cur and n < bounces do
    n = n + 1
    hitSet[cur] = true
    fx(w, "bolt", px, py, 4, 0.35, { x2 = cur.x, y2 = cur.y, color = color or { 0.7, 0.85, 1 } })
    px, py = cur.x, cur.y
    hit(w, src, cur, dmg, 0.3)
    local nxt, nd
    for _, o in ipairs(hostiles(w, src, px, py, jump)) do
      if not hitSet[o] then
        local d = U.dist(px, py, o.x, o.y)
        if not nd or d < nd then nxt, nd = o, d end
      end
    end
    cur = nxt
  end
  return n
end

local function later(w, delay, fn)
  local st = w.arena
  st.pending[#st.pending + 1] = { at = w.time + delay, fn = fn }
end

-- summon units that follow their owner
local function summon(w, owner, key, n, dur, level, opts)
  opts = opts or {}
  local out = {}
  local map = w.map
  for i = 1, n do
    local a = (i / n) * math.pi * 2 + w.time
    local x, y = (opts.x or owner.x) + math.cos(a) * 40, (opts.y or owner.y) + math.sin(a) * 40
    local tx, ty = map:tileAt(x, y)
    local nx, ny = map:nearestTile(tx, ty, function(xx, yy) return map:passable("land", xx, yy) end, 6)
    if nx then x, y = map:center(nx, ny) end
    local u = w:spawn(key, owner.team, x, y)
    u.owner = owner
    u.follow = not opts.stay
    u.summon = true
    if dur then u.doom = w.time + dur end
    if level and level > 0 then A.setLevel(u, math.min(5, level)) end
    local mm = owner.mods and owner.mods.minionMul
    if mm and (key == "drone" or key == "wolf" or key == "ghoul" or key == "gargantuan") then u.maxhp = math.floor(u.maxhp * mm); u.hp = u.maxhp; u.dmgMul = mm end
    out[#out + 1] = u
  end
  return out
end

local function countOwned(w, owner, key)
  local n = 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.owner == owner and e.key == key then n = n + 1 end
  end
  return n
end

-- sentry turret (a small building) dropped at a point
local function deploy(w, owner, x, y, dur)
  local map = w.map
  local tx, ty = map:tileAt(x, y)
  local nx, ny = map:nearestTile(tx, ty, function(xx, yy) return w:canPlace("sentry", xx, yy, owner.team) end, 5)
  if not nx then return nil end
  local cx, cy = map:center(nx, ny)
  local s = w:spawn("sentry", owner.team, cx, cy)
  s.owner = owner
  s.summon = true
  s.doom = w.time + dur
  fx(w, "levelup", cx, cy, 24, 0.5)
  return s
end

function A.setLevel(u, L)
  u.level = L
  u.maxhp = math.floor(u.def.hp * (1 + 0.10 * L))
  u.hp = u.maxhp
end

---------------------------------------------------------------------------
-- Skills. aim: "point" (at the cursor, within range), "self" (around the Commander).
-- tags tell the computer players when a skill is worth using.

-- damage over time (poison, plague): stacks per source, ticked by A.update
function A.dot(w, src, o, total, dur)
  if not o or not o.alive or o.def.building then return end
  local mul = (src and src.mods and src.mods.dotMul) or 1
  if src and src.owner and src.owner.mods and src.owner.mods.dotMul then mul = src.owner.mods.dotMul end
  o.dots = o.dots or {}
  o.dots[#o.dots + 1] = { dps = total * mul / dur, untilT = w.time + dur, src = src }
end

-- the Spiritcaller's stances: one at a time, each reshapes his basic attack
local STANCES = {
  jaguar    = { mul = { rof = 1.4, speed = 1.15 } },
  gorilla   = { mul = { armor = 0.65 }, regen = 0.01 },
  eagle     = { mul = { range = 1.25, speed = 1.2 }, chill = true },
  centipede = { mul = {}, poison = 70, lifesteal = 0.1 },
}
A.STANCES = STANCES
function A.setStance(w, c, key)
  c.stance = key
  c.stanceMul, c.stanceChill, c.stancePoison, c.stanceLifesteal, c.stanceRegen = {}, nil, nil, nil, nil
  local list = key == "avatar" and { "jaguar", "gorilla", "eagle", "centipede" } or { key }
  for _, k in ipairs(list) do
    local sd = STANCES[k]
    for mk, v in pairs(sd.mul) do c.stanceMul[mk] = (c.stanceMul[mk] or 1) * v end
    if sd.chill then c.stanceChill = true end
    if sd.poison then c.stancePoison = sd.poison * (1 + 0.08 * (c.clevel or 0)) end
    if sd.lifesteal then c.stanceLifesteal = sd.lifesteal end
    if sd.regen then c.stanceRegen = sd.regen end
  end
  local col = ({ jaguar = { 1, 0.75, 0.3 }, gorilla = { 0.7, 0.55, 0.4 }, eagle = { 0.6, 0.85, 1 }, centipede = { 0.5, 1, 0.4 }, avatar = { 1, 0.95, 0.6 } })[key]
  fx(w, "ring", c.x, c.y, 70, 0.6, { color = col })
end

-- Hexer's Sacrifice: enemy creeps fight for you, then burst
local function charm(w, c, o, dur)
  o.charm = { team = o.team, untilT = w.time + dur, src = c }
  o.team = c.team
  o.orders, o.path, o.chase, o.retaliate = {}, nil, nil, nil
  local st = w.arena
  local core = st.cores[st.teamSide[o.charm.team]]
  local tx, ty = o.x, o.y
  if core and core.alive then tx, ty = core.x, core.y end
  w:issue(o, { type = "amove", x = tx, y = ty })
  fx(w, "curse", o.x, o.y, 30, 0.6)
end

local SKILLLOG = os.getenv("PA_SKILLLOG")
A.SKILLS = {
  -- Ranger
  multishot = { name = "Volley", aim = "self", range = 0, cd = 14, tags = { "buff" },
    desc = "For 6 seconds every shot looses 2 extra arrows at other enemies in range (or the same one if it's alone).",
    use = function(w, c) c.volleyUntil = w.time + 6; fx(w, "ring", c.x, c.y, 60, 0.5, { color = { 1, 0.9, 0.5 } }) end },
  lance = { name = "Piercing Lance", aim = "point", range = 560, cd = 10, tags = { "dmg", "line" },
    desc = "Hurls a lance that hits everything in a line.",
    use = function(w, c, tx, ty) lineHit(w, c, tx, ty, 560, 22, skillDmg(c, 230), { 1, 0.9, 0.5 }) end },
  evade = { name = "Evade", aim = "point", range = 260, cd = 11, tags = { "escape", "move" },
    desc = "Dash away and can't be targeted for 1.5 seconds.",
    use = function(w, c, tx, ty) dash(w, c, tx, ty, 260); c.fadeUntil = w.time + 1.5 end },
  decoy = { name = "Decoy", aim = "point", range = 400, cd = 20, tags = { "summon", "defend" },
    desc = "A decoy that enemies prefer to shoot, for 8 seconds.",
    use = function(w, c, tx, ty) summon(w, c, "decoy", 1, 8, 0, { x = tx, y = ty, stay = true }) end },
  frostarrow = { name = "Frost Arrow", aim = "point", range = 560, cd = 8, tags = { "dmg", "aoe", "cc" },
    desc = "An arrow that bursts into frost, slowing everything nearby.",
    use = function(w, c, tx, ty)
      later(w, 0.35, function() area(w, c, tx, ty, 110, skillDmg(c, 130), { slow = 3 }); fx(w, "frost", tx, ty, 110, 0.6) end)
      fx(w, "beam", c.x, c.y, 4, 0.3, { x2 = tx, y2 = ty, color = { 0.6, 0.9, 1 } })
    end },
  chainstorm = { name = "Chain Storm", aim = "point", range = 600, cd = 55, ult = true, tags = { "dmg", "aoe", "ult" },
    desc = "ULTIMATE: lightning that arcs through 9 enemies.",
    use = function(w, c, tx, ty) chain(w, c, tx, ty, skillDmg(c, 260), 9, 260) end },

  -- Elementalist
  teleport = { name = "Teleport", aim = "point", range = 340, cd = 8, tags = { "escape", "move" },
    desc = "Blink to the target spot.",
    use = function(w, c, tx, ty)
      local map = w.map
      local dx, dy, len = U.norm(tx - c.x, ty - c.y)
      local d = math.min(340, len)
      local x, y = c.x + dx * d, c.y + dy * d
      local ttx, tty = map:tileAt(x, y)
      local nx, ny = map:nearestTile(ttx, tty, function(xx, yy) return map:passable("land", xx, yy) end, 4)
      if not nx then return false end
      fx(w, "levelup", c.x, c.y, 30, 0.4)
      c.x, c.y = map:center(nx, ny)
      c.path, c.destX, c.chase = nil, nil, nil
      if not w:isFleeing(c) then c.orders = {} end
      c.homeX, c.homeY = c.x, c.y
      fx(w, "levelup", c.x, c.y, 30, 0.4)
    end },
  frostnova = { name = "Frost Nova", aim = "self", range = 230, cd = 10, tags = { "dmg", "aoe", "cc", "defend" },
    desc = "A ring of frost around you: damage and a 3 second slow.",
    use = function(w, c) area(w, c, c.x, c.y, 230, skillDmg(c, 130), { slow = 3 }); fx(w, "frost", c.x, c.y, 230, 0.7) end },
  fireball = { name = "Fireball", aim = "point", range = 600, cd = 7, tags = { "dmg", "aoe" },
    desc = "A big explosive fireball.",
    use = function(w, c, tx, ty)
      w.projectiles[#w.projectiles + 1] = { x = c.x, y = c.y, sx = c.x, sy = c.y, tx = tx, ty = ty,
        speed = 520, damage = skillDmg(c, 260), splash = 95, team = c.team, weapon = c.def.weapon, source = c, fire = true }
    end },
  chainlightning = { name = "Chain Lightning", aim = "point", range = 520, cd = 9, tags = { "dmg", "aoe" },
    desc = "Lightning that jumps through 5 enemies.",
    use = function(w, c, tx, ty) chain(w, c, tx, ty, skillDmg(c, 150), 5, 220) end },
  energyshield = { name = "Energy Shield", aim = "self", range = 0, cd = 24, tags = { "defend" },
    desc = "Absorbs the next 900 damage (12 seconds).",
    use = function(w, c) c.absorb = 900 + 60 * (c.clevel or 1); c.absorbUntil = w.time + 12 end },
  meteor = { name = "Meteor", aim = "point", range = 900, cd = 65, ult = true, tags = { "dmg", "aoe", "ult", "siege" },
    desc = "ULTIMATE: after a short warning, a meteor flattens a wide area. Hurts buildings too.",
    use = function(w, c, tx, ty)
      fx(w, "warn", tx, ty, 240, 1.4)
      later(w, 1.4, function()
        area(w, c, tx, ty, 240, skillDmg(c, 700), { buildings = true, bldMul = 0.3 })
        fx(w, "nuke", tx, ty, 240, 1.6)
        if w.onDetonate then w.onDetonate({ tx = tx, ty = ty }) end
      end)
    end },

  -- Reclaimer
  raise = { name = "Raise Wrecks", aim = "point", range = 450, cd = 10, tags = { "summon" },
    desc = "Rebuilds up to 3 recent wrecks near the target as your drones (max 5, more with Legion).",
    use = function(w, c, tx, ty)
      local st = w.arena
      local maxN = 5 + ((c.mods and c.mods.extraMinions) or 0)
      local have = countOwned(w, c, "drone")
      local raised = 0
      for i = #st.wrecks, 1, -1 do
        local wr = st.wrecks[i]
        if raised < 3 and have + raised < maxN and U.dist(wr.x, wr.y, tx, ty) < 260 then
          summon(w, c, "drone", 1, nil, math.floor((c.clevel or 1) / 3), { x = wr.x, y = wr.y })
          table.remove(st.wrecks, i)
          raised = raised + 1
        end
      end
      if raised == 0 then return false end
    end },
  amplify = { name = "Amplify Damage", aim = "point", range = 520, cd = 13, tags = { "cc", "aoe" },
    desc = "Curse an area: enemies there take 50% more damage for 8 seconds.",
    use = function(w, c, tx, ty) area(w, c, tx, ty, 200, 1, { amp = 8 }); fx(w, "curse", tx, ty, 200, 0.8) end },
  corpseburst = { name = "Corpse Burst", aim = "point", range = 500, cd = 9, tags = { "dmg", "aoe" },
    desc = "Detonate wrecks near the target. Each one blasts its surroundings.",
    use = function(w, c, tx, ty)
      local st = w.arena
      local n = 0
      for i = #st.wrecks, 1, -1 do
        local wr = st.wrecks[i]
        if n < 5 and U.dist(wr.x, wr.y, tx, ty) < 230 then
          area(w, c, wr.x, wr.y, 110, skillDmg(c, 150))
          fx(w, "boom", wr.x, wr.y, 60, 0.5)
          table.remove(st.wrecks, i)
          n = n + 1
        end
      end
      if n == 0 then return false end
    end },
  bonespear = { name = "Bone Spear", aim = "point", range = 520, cd = 8, tags = { "dmg", "line" },
    desc = "A spear that pierces everything in a line.",
    use = function(w, c, tx, ty) lineHit(w, c, tx, ty, 520, 20, skillDmg(c, 210), { 0.95, 0.95, 0.85 }) end },
  decrepify = { name = "Decrepify", aim = "point", range = 480, cd = 15, tags = { "cc" },
    desc = "Enemies near the target are slowed and take 50% more damage for 5 seconds.",
    use = function(w, c, tx, ty) area(w, c, tx, ty, 140, 1, { slow = 5, amp = 5 }); fx(w, "curse", tx, ty, 140, 0.8) end },
  rise = { name = "Rise", aim = "self", range = 0, cd = 65, ult = true, tags = { "summon", "ult" },
    desc = "ULTIMATE: 5 veteran drones claw out of the ground around you for 22 seconds.",
    use = function(w, c) summon(w, c, "drone", 5, 22, 3) end },

  -- Juggernaut
  leap = { name = "Leap Slam", aim = "point", range = 320, cd = 10, tags = { "dmg", "aoe", "cc", "move" },
    desc = "Leap to the target and slam down, stunning everything nearby.",
    use = function(w, c, tx, ty)
      dash(w, c, tx, ty, 320)
      area(w, c, c.x, c.y, 140, skillDmg(c, 160), { stun = 1.0 })
      fx(w, "splash", c.x, c.y, 140, 0.4)
    end },
  warcry = { name = "War Cry", aim = "self", range = 220, cd = 14, tags = { "cc", "aoe", "defend" },
    desc = "Stuns everything around you for 1.5 seconds.",
    use = function(w, c) area(w, c, c.x, c.y, 220, skillDmg(c, 80), { stun = 1.5 }); fx(w, "ring", c.x, c.y, 220, 0.6) end },
  whirlwind = { name = "Whirlwind", aim = "self", range = 140, cd = 13, tags = { "dmg", "aoe" },
    desc = "Spin for 3 seconds, shredding everything around you, and move faster.",
    use = function(w, c) c.pulse = { untilT = w.time + 3, r = 140, dmg = skillDmg(c, 45), kind = "whirl" }; A.buff(c, "speed", 1.25, 3, w) end },
  battleorders = { name = "Battle Orders", aim = "self", range = 500, cd = 40, tags = { "buff" },
    desc = "You and nearby allies get +30% max health for 30 seconds.",
    use = function(w, c)
      for _, u in ipairs(friends(w, c, c.x, c.y, 500)) do
        if not u.boUntil or u.boUntil < w.time then
          u.boBase = u.maxhp
          u.maxhp = math.floor(u.maxhp * 1.3); u.hp = u.hp + (u.maxhp - u.boBase)
        end
        u.boUntil = w.time + 30
      end
      fx(w, "ring", c.x, c.y, 500, 0.8)
    end },
  shout = { name = "Iron Shout", aim = "self", range = 500, cd = 24, tags = { "buff", "defend" },
    desc = "You and nearby allies take 40% less damage for 8 seconds.",
    use = function(w, c) for _, u in ipairs(friends(w, c, c.x, c.y, 500)) do A.buff(u, "armor", 0.6, 8, w) end; fx(w, "ring", c.x, c.y, 500, 0.6) end },
  berserk = { name = "Berserk", aim = "self", range = 0, cd = 55, ult = true, tags = { "buff", "ult" },
    desc = "ULTIMATE: double damage, faster and quicker to fire for 10 seconds, but you take 25% more damage.",
    use = function(w, c) A.buff(c, "dmg", 2, 10, w); A.buff(c, "speed", 1.35, 10, w); A.buff(c, "rof", 1.3, 10, w); A.buff(c, "armor", 1.25, 10, w); fx(w, "ring", c.x, c.y, 80, 0.6, { color = { 1, 0.3, 0.2 } }) end },

  -- Warden
  charge = { name = "Charge", aim = "point", range = 320, cd = 9, tags = { "dmg", "cc", "move" },
    desc = "Charge forward and smash everything where you land (stun 1s).",
    use = function(w, c, tx, ty)
      dash(w, c, tx, ty, 320)
      area(w, c, c.x, c.y, 110, skillDmg(c, 180), { stun = 0.8 })
      fx(w, "splash", c.x, c.y, 120, 0.3)
    end },
  holyshield = { name = "Holy Shield", aim = "self", range = 0, cd = 15, tags = { "defend" },
    desc = "Take half damage for 10 seconds.",
    use = function(w, c) A.buff(c, "armor", 0.5, 10, w) end },
  hammers = { name = "Spinning Hammers", aim = "self", range = 170, cd = 12, tags = { "dmg", "aoe" },
    desc = "Hammers circle you for 5 seconds, battering everything close.",
    use = function(w, c) c.pulse = { untilT = w.time + 5, r = 175, dmg = skillDmg(c, 36), kind = "hammer" } end },
  smite = { name = "Smite", aim = "point", range = 340, cd = 8, tags = { "dmg", "cc" },
    desc = "Strike the nearest enemy to the target hard and stun it for 1.5 seconds.",
    use = function(w, c, tx, ty)
      local list = hostiles(w, c, tx, ty, 120)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return false end
      hit(w, c, best, skillDmg(c, 270)); best.stunUntil = w.time + 1.2
      fx(w, "bolt", c.x, c.y, 5, 0.3, { x2 = best.x, y2 = best.y, color = { 1, 0.95, 0.6 } })
    end },
  prayer = { name = "Prayer", aim = "self", range = 450, cd = 20, tags = { "heal" },
    desc = "Heal yourself and allies nearby by 30%.",
    use = function(w, c)
      for _, u in ipairs(friends(w, c, c.x, c.y, 450)) do u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.30); u.healing = 1 end
      fx(w, "ring", c.x, c.y, 450, 0.7, { color = { 0.6, 1, 0.6 } })
    end },
  judgment = { name = "Judgment", aim = "point", range = 650, cd = 55, ult = true, tags = { "dmg", "aoe", "ult" },
    desc = "ULTIMATE: a pillar of lightning, then bolts leap to 6 more enemies.",
    use = function(w, c, tx, ty)
      area(w, c, tx, ty, 170, skillDmg(c, 520), { buildings = true, bldMul = 0.25 })
      fx(w, "pillar", tx, ty, 170, 0.8)
      chain(w, c, tx, ty, skillDmg(c, 150), 6, 320, { 1, 0.95, 0.6 })
    end },

  -- Shifter
  wolves = { name = "Summon Wolves", aim = "self", range = 0, cd = 16, tags = { "summon" },
    desc = "Two wolves join you for good (max 2, or 4 with Pack Leader).",
    use = function(w, c)
      local maxN = 2 + ((c.mods and c.mods.extraWolves) or 0)
      local have = countOwned(w, c, "wolf")
      if have >= maxN then return false end
      summon(w, c, "wolf", math.min(2, maxN - have), nil, math.floor((c.clevel or 1) / 3))
    end },
  bear = { name = "Bear Form", aim = "self", range = 0, cd = 30, tags = { "buff" },
    desc = "For 12 seconds: +50% health, +40% damage, shorter range.",
    use = function(w, c)
      if not c.bearUntil or c.bearUntil < w.time then
        c.bearBase = c.maxhp
        c.maxhp = math.floor(c.maxhp * 1.5); c.hp = c.hp + (c.maxhp - c.bearBase)
      end
      c.bearUntil = w.time + 12
      A.buff(c, "dmg", 1.4, 12, w); A.buff(c, "range", 0.6, 12, w)
      fx(w, "ring", c.x, c.y, 70, 0.6, { color = { 0.7, 0.5, 0.3 } })
    end },
  cyclone = { name = "Cyclone", aim = "self", range = 200, cd = 14, tags = { "dmg", "aoe", "cc" },
    desc = "A storm whirls around you for 4 seconds, damaging and slowing enemies.",
    use = function(w, c) c.pulse = { untilT = w.time + 4, r = 200, dmg = skillDmg(c, 34), slow = true, kind = "cyclone" } end },
  firestorm = { name = "Firestorm", aim = "point", range = 460, cd = 8, tags = { "dmg", "line" },
    desc = "A wall of fire rolls toward the target.",
    use = function(w, c, tx, ty) lineHit(w, c, tx, ty, 460, 30, skillDmg(c, 215), { 1, 0.5, 0.2 }) end },
  oaksage = { name = "Spirit of the Oak", aim = "self", range = 500, cd = 30, tags = { "heal", "buff" },
    desc = "You and nearby allies regenerate 3% health per second for 15 seconds.",
    use = function(w, c) for _, u in ipairs(friends(w, c, c.x, c.y, 500)) do u.hot = { untilT = w.time + 15, rate = 0.03 } end; fx(w, "ring", c.x, c.y, 500, 0.7, { color = { 0.5, 1, 0.5 } }) end },
  cataclysm = { name = "Cataclysm", aim = "self", range = 360, cd = 55, ult = true, tags = { "dmg", "aoe", "ult" },
    desc = "ULTIMATE: 10 meteors rain down around you over 4 seconds.",
    use = function(w, c)
      for i = 1, 10 do
        later(w, i * 0.4, function()
          if not c.alive then return end
          local a, r = math.random() * math.pi * 2, 60 + math.random() * 300
          local x, y = c.x + math.cos(a) * r, c.y + math.sin(a) * r
          area(w, c, x, y, 95, skillDmg(c, 230), { buildings = true, bldMul = 0.3 })
          fx(w, "boom", x, y, 95, 0.6)
        end)
      end
    end },

  -- Infiltrator
  sentry = { name = "Lightning Sentry", aim = "point", range = 380, cd = 8, tags = { "summon", "siege" },
    desc = "Deploy a trap turret for 25 seconds (max 3).",
    use = function(w, c, tx, ty)
      if countOwned(w, c, "sentry") >= 3 then return false end
      if not deploy(w, c, tx, ty, 25) then return false end
    end },
  mindblast = { name = "Mind Blast", aim = "point", range = 480, cd = 12, tags = { "cc", "aoe" },
    desc = "Stun everything near the target for 1.8 seconds.",
    use = function(w, c, tx, ty) area(w, c, tx, ty, 170, skillDmg(c, 130), { stun = 1.8 }); fx(w, "ring", tx, ty, 160, 0.5, { color = { 0.9, 0.6, 1 } }) end },
  fade = { name = "Fade", aim = "self", range = 0, cd = 18, tags = { "escape" },
    desc = "Vanish for 4 seconds: nothing can target you, and you move 40% faster.",
    use = function(w, c) c.fadeUntil = w.time + 4; A.buff(c, "speed", 1.4, 4, w) end },
  clone = { name = "Shadow Clone", aim = "self", range = 0, cd = 24, tags = { "summon" },
    desc = "A shadow copy of you fights for 15 seconds.",
    use = function(w, c) summon(w, c, "shadow", 1, 15, math.floor((c.clevel or 1) / 2)) end },
  talon = { name = "Dragon Talon", aim = "point", range = 300, cd = 7, tags = { "dmg", "move" },
    desc = "Lunge at the enemy nearest the target and land three lightning-fast kicks.",
    use = function(w, c, tx, ty)
      local list = hostiles(w, c, tx, ty, 120)
      if #list == 0 then return false end
      local fx0, fy0 = tx, ty
      do local b, bd2; for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd2 or d < bd2 then b, bd2 = o, d end end; fx0, fy0 = b.x, b.y end
      local dx, dy, len = U.norm(fx0 - c.x, fy0 - c.y)
      if len > 60 then dash(w, c, c.x + dx * (len - 45), c.y + dy * (len - 45), 300) end
      list = hostiles(w, c, tx, ty, 160)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return false end
      for i = 0, 2 do later(w, i * 0.15, function() if best.alive then hit(w, c, best, skillDmg(c, 135)); fx(w, "hit", best.x, best.y, 14, 0.2) end end) end
    end },
  swarm = { name = "Sentry Swarm", aim = "point", range = 500, cd = 55, ult = true, tags = { "summon", "ult", "siege" },
    desc = "ULTIMATE: deploy 5 sentries around the target for 20 seconds.",
    use = function(w, c, tx, ty)
      for i = 1, 5 do
        local a = i / 5 * math.pi * 2
        deploy(w, c, tx + math.cos(a) * 90, ty + math.sin(a) * 90, 20)
      end
    end },

  -- Ascetic (a martial monk: fast strikes, mantras, healing)
  flurry = { name = "Flurry of Blows", aim = "point", range = 280, cd = 8, tags = { "dmg", "move" },
    desc = "Dash to the target and strike the nearest enemy four times.",
    use = function(w, c, tx, ty)
      dash(w, c, tx, ty, 280)
      local list = hostiles(w, c, c.x, c.y, 130)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(c.x, c.y, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return end
      for i = 0, 3 do later(w, i * 0.15, function() if best.alive then hit(w, c, best, skillDmg(c, 75)); fx(w, "hit", best.x, best.y, 14, 0.2) end end) end
    end },
  dashstrike = { name = "Dashing Strike", aim = "point", range = 380, cd = 10, tags = { "dmg", "line", "move", "escape" },
    desc = "Streak forward, cutting through everything in the way.",
    use = function(w, c, tx, ty)
      lineHit(w, c, tx, ty, U.dist(c.x, c.y, tx, ty), 26, skillDmg(c, 170), { 0.95, 0.9, 0.6 })
      dash(w, c, tx, ty, 380)
    end },
  mantra = { name = "Mantra of Conviction", aim = "self", range = 450, cd = 22, tags = { "buff" },
    desc = "For 8 seconds you and allies nearby deal +20% damage and move 10% faster.",
    use = function(w, c)
      for _, u in ipairs(friends(w, c, c.x, c.y, 450)) do A.buff(u, "dmg", 1.2, 8, w); A.buff(u, "speed", 1.1, 8, w) end
      fx(w, "ring", c.x, c.y, 450, 0.7, { color = { 1, 0.85, 0.4 } })
    end },
  breath = { name = "Breath of Heaven", aim = "self", range = 400, cd = 18, tags = { "heal" },
    desc = "Heal yourself and allies nearby by 20%, and quicken them for 3 seconds.",
    use = function(w, c)
      for _, u in ipairs(friends(w, c, c.x, c.y, 400)) do u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.2); u.healing = 1; A.buff(u, "speed", 1.25, 3, w) end
      fx(w, "ring", c.x, c.y, 400, 0.7, { color = { 0.7, 1, 0.8 } })
    end },
  pull = { name = "Whirling Pull", aim = "self", range = 260, cd = 14, tags = { "cc", "aoe", "dmg" },
    desc = "Pull every enemy within reach to you, damaging and slowing them.",
    use = function(w, c)
      local list = hostiles(w, c, c.x, c.y, 260)
      if #list == 0 then return false end
      for _, o in ipairs(list) do
        if not o.def.building and o.key ~= "colossus" then
          local dx, dy, len = U.norm(c.x - o.x, c.y - o.y)
          local move = math.max(0, len - 60)
          o.x, o.y = o.x + dx * move, o.y + dy * move
          o.path = nil
        end
      end
      area(w, c, c.x, c.y, 140, skillDmg(c, 120), { slow = 1.5 })
      fx(w, "cyclone", c.x, c.y, 260, 0.5)
    end },
  sanctuary = { name = "Inner Sanctuary", aim = "self", range = 240, cd = 60, ult = true, tags = { "defend", "ult" },
    desc = "ULTIMATE: a holy ground for 7 seconds - allies inside take half damage, enemies inside are slowed.",
    use = function(w, c)
      local st = w.arena
      st.zones = st.zones or {}
      st.zones[#st.zones + 1] = { x = c.x, y = c.y, r = 240, untilT = w.time + 7, team = c.team, kind = "sanctuary" }
      fx(w, "ring", c.x, c.y, 240, 0.8, { color = { 1, 0.95, 0.6 } })
    end },

  -- Hexer (a witch doctor: poison, ghouls, hexes)
  plague = { name = "Plague Dart", aim = "point", range = 560, cd = 7, tags = { "dmg" },
    desc = "Poison the enemy nearest the target: heavy damage over 6 seconds.",
    use = function(w, c, tx, ty)
      local list = hostiles(w, c, tx, ty, 160)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return false end
      A.dot(w, c, best, skillDmg(c, 330), 6)
      fx(w, "beam", c.x, c.y, 3, 0.3, { x2 = best.x, y2 = best.y, color = { 0.55, 1, 0.35 } })
    end },
  ghouls = { name = "Raise Ghouls", aim = "self", range = 0, cd = 18, tags = { "summon" },
    desc = "Three ghouls join you for good (max 3, more with Fetish Army).",
    use = function(w, c)
      local maxN = 3 + ((c.mods and c.mods.extraGhouls) or 0)
      local have = countOwned(w, c, "ghoul")
      if have >= maxN then return false end
      summon(w, c, "ghoul", math.min(3, maxN - have), nil, math.floor((c.clevel or 1) / 3))
    end },
  grasp = { name = "Grasp of the Dead", aim = "point", range = 500, cd = 12, tags = { "cc", "aoe", "dmg" },
    desc = "Hands claw out of the ground: enemies there are slowed and poisoned for 4 seconds.",
    use = function(w, c, tx, ty)
      for _, o in ipairs(hostiles(w, c, tx, ty, 170)) do
        o.slowUntil = math.max(o.slowUntil or 0, w.time + 4)
        A.dot(w, c, o, skillDmg(c, 210), 4)
      end
      fx(w, "curse", tx, ty, 170, 1.0)
    end },
  sacrifice = { name = "Hex: Sacrifice", aim = "point", range = 480, cd = 20, tags = { "summon", "cc" },
    desc = "Up to 4 enemy creeps near the target fight for you for 7 seconds, then burst apart.",
    use = function(w, c, tx, ty)
      local n = 0
      for _, o in ipairs(hostiles(w, c, tx, ty, 170)) do
        if n < 4 and o.creep and not o.charm then charm(w, c, o, 7); n = n + 1 end
      end
      if n == 0 then return false end
    end },
  soulharvest = { name = "Soul Harvest", aim = "self", range = 260, cd = 16, tags = { "buff" },
    desc = "Drain the enemies around you: +7% damage per enemy (up to 5) for 12 seconds, and heal 3% each.",
    use = function(w, c)
      local list = hostiles(w, c, c.x, c.y, 260)
      local n = math.min(5, #list)
      if n == 0 then return false end
      A.buff(c, "dmg", 1 + 0.07 * n, 12, w)
      c.hp = math.min(c.maxhp, c.hp + c.maxhp * 0.03 * n); c.healing = 1
      for i = 1, n do fx(w, "beam", list[i].x, list[i].y, 3, 0.4, { x2 = c.x, y2 = c.y, color = { 0.6, 1, 0.5 } }) end
    end },
  gargantuan = { name = "Gargantuan", aim = "self", range = 0, cd = 60, ult = true, tags = { "summon", "ult", "siege" },
    desc = "ULTIMATE: raise a Gargantuan brute that fights for you for 30 seconds.",
    use = function(w, c) summon(w, c, "gargantuan", 1, 30, math.floor((c.clevel or 1) / 2)) end },

  -- Spiritcaller (spirit stances: one at a time, each reshapes your attack)
  jaguar = { name = "Jaguar Stance", aim = "self", range = 0, cd = 3, tags = { "stance" },
    desc = "Stance: attack 40% faster and move 15% faster.",
    use = function(w, c) if c.stance == "jaguar" then return false end; A.setStance(w, c, "jaguar") end },
  gorilla = { name = "Gorilla Stance", aim = "self", range = 0, cd = 3, tags = { "stance" },
    desc = "Stance: take 35% less damage and regenerate 1% health per second.",
    use = function(w, c) if c.stance == "gorilla" then return false end; A.setStance(w, c, "gorilla") end },
  eaglestance = { name = "Eagle Stance", aim = "self", range = 0, cd = 3, tags = { "stance" },
    desc = "Stance: +25% range, +20% speed, and your shots slow.",
    use = function(w, c) if c.stance == "eagle" then return false end; A.setStance(w, c, "eagle") end },
  centipede = { name = "Centipede Stance", aim = "self", range = 0, cd = 3, tags = { "stance" },
    desc = "Stance: your shots poison, and you heal for 10% of the damage you deal.",
    use = function(w, c) if c.stance == "centipede" then return false end; A.setStance(w, c, "centipede") end },
  rushclaw = { name = "Rushing Claw", aim = "point", range = 340, cd = 9, tags = { "dmg", "move" },
    desc = "Lunge to the target and rake everything around you.",
    use = function(w, c, tx, ty)
      dash(w, c, tx, ty, 340)
      area(w, c, c.x, c.y, 110, skillDmg(c, 210))
      fx(w, "splash", c.x, c.y, 110, 0.35)
    end },
  avatar = { name = "Spirit Avatar", aim = "self", range = 0, cd = 60, ult = true, tags = { "buff", "ult" },
    desc = "ULTIMATE: all four stances at once for 10 seconds.",
    use = function(w, c)
      local prev = c.stance
      A.setStance(w, c, "avatar")
      later(w, 10, function() if c.stance == "avatar" then if prev then A.setStance(w, c, prev) else c.stance, c.stanceMul, c.stanceChill, c.stancePoison, c.stanceLifesteal, c.stanceRegen = nil, nil, nil, nil, nil, nil end end end)
    end },
}
for k, s in pairs(A.SKILLS) do s.key = k end

---------------------------------------------------------------------------
-- Passives: shared ones plus a few per class

local function mulMod(e, k, v) e.mods[k] = (e.mods[k] or 1) * v end
local function hpUp(e, v) local old = e.maxhp; e.maxhp = math.floor(e.maxhp * v); e.hp = e.hp + (e.maxhp - old) end

A.PASSIVES = {
  hull     = { name = "Reinforced Hull", desc = "+25% max health.", apply = function(w, e) hpUp(e, 1.25) end },
  regen    = { name = "Nano Regeneration", desc = "Repair 14 HP per second, even in combat.", apply = function(w, e) e.mods.regen = (e.mods.regen or 0) + 14 end },
  cannon   = { name = "Heavy Cannon", desc = "+20% weapon damage.", apply = function(w, e) mulMod(e, "dmg", 1.2) end },
  loader   = { name = "Rapid Loader", desc = "Fire 20% faster.", apply = function(w, e) mulMod(e, "rof", 1.2) end },
  treads   = { name = "Overdrive Treads", desc = "+15% movement speed.", apply = function(w, e) mulMod(e, "speed", 1.15) end },
  bounty   = { name = "Bounty Hunter", desc = "+30% experience.", apply = function(w, e) mulMod(e, "xpMul", 1.3) end },
  breaker  = { name = "Siege Breaker", desc = "+60% damage to towers and the Core.", apply = function(w, e) mulMod(e, "breaker", 1.6) end },
  lifesteal = { name = "Siphon Rounds", desc = "Heal for 12% of the damage you deal.", apply = function(w, e) e.mods.lifesteal = (e.mods.lifesteal or 0) + 0.12 end },
  secondwind = { name = "Second Wind", desc = "Once per life: survive a killing blow and become invulnerable for 4 seconds.", apply = function(w, e) e.mods.secondWind = true end },
  focus    = { name = "Focus Core", desc = "Skills recharge 20% faster.", apply = function(w, e) mulMod(e, "cdr", 0.8) end },
  power    = { name = "Overcharged Skills", desc = "+25% skill damage.", apply = function(w, e) mulMod(e, "skillDmg", 1.25) end },
  -- class flavor
  crit     = { name = "Critical Strike", desc = "20% chance for double damage shots.", apply = function(w, e) e.mods.crit = (e.mods.crit or 0) + 0.2 end },
  eagle    = { name = "Eagle Eye", desc = "+20% range, +40% sight.", apply = function(w, e) mulMod(e, "range", 1.2); mulMod(e, "sight", 1.4) end },
  dodge    = { name = "Dodge", desc = "20% chance to avoid a hit completely.", apply = function(w, e) e.mods.dodge = (e.mods.dodge or 0) + 0.2 end },
  coldmastery = { name = "Cold Mastery", desc = "Your shots slow enemies for 1 second.", apply = function(w, e) e.mods.chill = true end },
  legion   = { name = "Legion", desc = "+2 drones allowed; drones and wolves +40% health and damage.", apply = function(w, e) e.mods.extraMinions = (e.mods.extraMinions or 0) + 2; mulMod(e, "minionMul", 1.4) end },
  ironskin = { name = "Iron Skin", desc = "Take 15% less damage.", apply = function(w, e) mulMod(e, "armor", 0.85) end },
  might    = { name = "Aura: Might", desc = "Allies within 350 deal +20% damage.", apply = function(w, e) e.mods.auraMight = true end },
  prayeraura = { name = "Aura: Mending", desc = "Allies within 350 regenerate 1.5% health per second.", apply = function(w, e) e.mods.auraMend = true end },
  freezeaura = { name = "Aura: Frostbite", desc = "Enemies within 300 are slowed.", apply = function(w, e) e.mods.auraFreeze = true end },
  pack     = { name = "Pack Leader", desc = "+2 wolves allowed; drones and wolves +40% health and damage.", apply = function(w, e) e.mods.extraWolves = (e.mods.extraWolves or 0) + 2; mulMod(e, "minionMul", 1.4) end },
  lycan    = { name = "Wild Heart", desc = "+20% health and +10% speed.", apply = function(w, e) hpUp(e, 1.2); mulMod(e, "speed", 1.1) end },
  venom    = { name = "Venom", desc = "+25% weapon damage.", apply = function(w, e) mulMod(e, "dmg", 1.25) end },
  shadowstep = { name = "Shadow Step", desc = "+20% movement speed.", apply = function(w, e) mulMod(e, "speed", 1.2) end },
  fleetfoot = { name = "Fleet Foot", desc = "15% chance to avoid a hit, and +10% speed.", apply = function(w, e) e.mods.dodge = (e.mods.dodge or 0) + 0.15; mulMod(e, "speed", 1.1) end },
  harmony  = { name = "Harmony", desc = "Every skill you use heals you 5%.", apply = function(w, e) e.mods.harmony = true end },
  toxin    = { name = "Toxin", desc = "Your poisons deal 35% more damage.", apply = function(w, e) mulMod(e, "dotMul", 1.35) end },
  fetish   = { name = "Fetish Army", desc = "+2 ghouls allowed; ghouls and your Gargantuan +40% health and damage.", apply = function(w, e) e.mods.extraGhouls = (e.mods.extraGhouls or 0) + 2; mulMod(e, "minionMul", 1.4) end },
  primal   = { name = "Primal Spirit", desc = "+15% health and +10% speed.", apply = function(w, e) hpUp(e, 1.15); mulMod(e, "speed", 1.1) end },
  ferocity = { name = "Ferocity", desc = "+15% damage and attack 10% faster.", apply = function(w, e) mulMod(e, "dmg", 1.15); mulMod(e, "rof", 1.1) end },
}
for k, p in pairs(A.PASSIVES) do p.key = k end
A.SHARED = { "hull", "regen", "cannon", "loader", "treads", "bounty", "breaker", "lifesteal", "secondwind", "focus", "power" }

---------------------------------------------------------------------------
-- Classes

A.CLASSES = {
  { key = "ranger", name = "Ranger", tag = "Longest range; volleys and lances.",
    skills = { "multishot", "lance", "evade", "decoy", "frostarrow" }, ult = "chainstorm", passives = { "crit", "eagle", "dodge" },
    base = function(w, e) mulMod(e, "range", 1.22); hpUp(e, 0.84) end },
  { key = "elementalist", name = "Elementalist", tag = "Fragile; fire, frost and lightning.",
    skills = { "teleport", "frostnova", "fireball", "chainlightning", "energyshield" }, ult = "meteor", passives = { "coldmastery", "power", "focus" },
    base = function(w, e) hpUp(e, 0.95); mulMod(e, "skillDmg", 1.2) end },
  { key = "reclaimer", name = "Reclaimer", tag = "Raises wrecked creeps as drones; curses.",
    skills = { "raise", "amplify", "corpseburst", "bonespear", "decrepify" }, ult = "rise", passives = { "legion", "lifesteal" },
    base = function(w, e) end },
  { key = "juggernaut", name = "Juggernaut", tag = "Melee brawler: huge health, leaps and shouts.",
    skills = { "leap", "warcry", "whirlwind", "battleorders", "shout" }, ult = "berserk", passives = { "ironskin", "regen" },
    base = function(w, e) hpUp(e, 1.5); e.mods.melee = true; mulMod(e, "range", 0.45); mulMod(e, "dmg", 1.6); mulMod(e, "armor", 0.85); mulMod(e, "speed", 1.08) end },
  { key = "warden", name = "Warden", tag = "Auras for allies and creeps; charge and smite.",
    skills = { "charge", "holyshield", "hammers", "smite", "prayer" }, ult = "judgment", passives = { "might", "prayeraura", "freezeaura" },
    base = function(w, e) hpUp(e, 1.2); mulMod(e, "armor", 0.92) end },
  { key = "shifter", name = "Shifter", tag = "Wolf pack, bear form and storms.",
    skills = { "wolves", "bear", "cyclone", "firestorm", "oaksage" }, ult = "cataclysm", passives = { "pack", "lycan" },
    base = function(w, e) hpUp(e, 1.2); mulMod(e, "dmg", 1.1) end },
  { key = "infiltrator", name = "Infiltrator", tag = "Trap turrets, stealth and a shadow clone.",
    skills = { "sentry", "mindblast", "fade", "clone", "talon" }, ult = "swarm", passives = { "crit", "venom", "shadowstep" },
    base = function(w, e) mulMod(e, "speed", 1.15); hpUp(e, 1.05); mulMod(e, "dmg", 1.1) end },
  { key = "ascetic", name = "Ascetic", tag = "Melee monk: flurries, dashes, mantras and healing; every blow heals him a little.",
    skills = { "flurry", "dashstrike", "mantra", "breath", "pull" }, ult = "sanctuary", passives = { "fleetfoot", "harmony" },
    base = function(w, e) hpUp(e, 1.3); e.mods.melee = true; e.mods.lifesteal = (e.mods.lifesteal or 0) + 0.05; mulMod(e, "range", 0.42); mulMod(e, "dmg", 1.6); mulMod(e, "speed", 1.15); mulMod(e, "armor", 0.86) end },
  { key = "hexer", name = "Hexer", tag = "Poisons, ghouls and hexes that turn creeps against their own side.",
    skills = { "plague", "ghouls", "grasp", "sacrifice", "soulharvest" }, ult = "gargantuan", passives = { "toxin", "fetish" },
    base = function(w, e) hpUp(e, 0.95); mulMod(e, "skillDmg", 1.1) end },
  { key = "spiritcaller", name = "Spiritcaller", tag = "Switches between four spirit stances that reshape every attack.",
    skills = { "jaguar", "gorilla", "eaglestance", "centipede", "rushclaw" }, ult = "avatar", passives = { "primal", "ferocity" },
    base = function(w, e) hpUp(e, 1.05); mulMod(e, "dmg", 1.05) end },
}
A.byClass = {}
for _, c in ipairs(A.CLASSES) do A.byClass[c.key] = c end

---------------------------------------------------------------------------
-- Setup

function A.setup(w, opts)
  local map = w.map
  local n = map.nSides or 2
  local st = { pending = {}, wrecks = {}, waveAt = A.WAVE_FIRST, wave = 0, kills = {}, deaths = {}, structures = {},
    nSides = n, ffa = n > 2, sideDead = {}, cores = {} }
  w.arena = st
  -- sides by alliance (worked out by the map): side 1 = the human's alliance
  st.teamSide, st.sideTeams, st.sideOwner = {}, {}, {}
  for side = 1, n do st.sideTeams[side] = {}; st.kills[side] = 0 end
  for t = 1, w.np do
    local side = map.teamSide[t]
    st.teamSide[t] = side
    table.insert(st.sideTeams[side], t)
  end
  for side = 1, n do st.sideOwner[side] = st.sideTeams[side][1] end
  for side = 1, n do
    local cpos = map.cores[side]
    local x, y = map:center(cpos.x, cpos.y)
    local core = w:spawn("core", st.sideOwner[side], x, y)
    core.arenaTower = true
    core.side = side
    st.structures[#st.structures + 1] = core
    st["core" .. side] = core
    st.cores[side] = core
  end
  -- three Commanders a side hit much harder: their towers and Core get tougher to match
  local biggest = 1
  for side = 1, n do biggest = math.max(biggest, #st.sideTeams[side]) end
  local hpMul = biggest >= 5 and 1.75 or biggest >= 4 and 1.6 or biggest >= 3 and 1.4 or 1
  if hpMul > 1 then
    for side = 1, n do local core = st.cores[side]; core.maxhp = math.floor(core.maxhp * hpMul); core.hp = core.maxhp end
  end
  for _, t in ipairs(map.towers) do
    local x, y = map:center(t.x, t.y)
    local tw = w:spawn("atower", st.sideOwner[t.side], x, y)
    if hpMul > 1 then tw.maxhp = math.floor(tw.maxhp * hpMul); tw.hp = tw.maxhp end
    tw.arenaTower = true
    tw.side, tw.lane, tw.tier = t.side, t.lane, t.tier
    st.structures[#st.structures + 1] = tw
  end
  A.updateProtection(w)
  -- Commanders: class, level 1 kit
  for t = 1, w.np do
    local c = w.teams[t].commander
    local p = opts.players[t] or {}
    local ck = p.class
    if not ck or not A.byClass[ck] then
      -- random picks don't repeat until every class has been used
      st.classPool = st.classPool or {}
      if #st.classPool == 0 then
        for _, cl in ipairs(A.CLASSES) do
          local used = false
          for t2 = 1, w.np do local o = w.teams[t2].commander; if o and o.class == cl.key then used = true end end
          for _, pl in ipairs(opts.players or {}) do if pl.class == cl.key then used = true end end
          if not used then st.classPool[#st.classPool + 1] = cl.key end
        end
        if #st.classPool == 0 then for _, cl in ipairs(A.CLASSES) do st.classPool[#st.classPool + 1] = cl.key end end
      end
      ck = table.remove(st.classPool, w.rngCmd:random(#st.classPool))
    end
    c.class = ck
    c.skills = {}
    c.mods.dmg = 1.6           -- Commanders hit harder in the Arena
    A.byClass[ck].base(w, c)
    c.respawnX, c.respawnY = c.x, c.y
    st.deaths[t] = 0
    p.class = ck
  end
  if map.jungleT then require("src.jungle").setup(w) end
end

-- inner towers need the outer one down; the Core needs any inner tower down
function A.updateProtection(w)
  local st = w.arena
  local alive = {}
  for _, s in ipairs(st.structures) do
    if s.alive and s.tier then alive[s.side .. s.lane .. s.tier] = true end
  end
  for _, s in ipairs(st.structures) do
    if s.alive then
      if s.tier == "inner" then
        s.protected = (alive[s.side .. s.lane .. "outer"] or alive[s.side .. s.lane .. "middle"]) or nil
      elseif s.tier == "middle" then
        s.protected = alive[s.side .. s.lane .. "outer"] or nil
      elseif s.key == "core" then
        local anyInnerDown = false
        for _, L in ipairs(w.map.lanes) do
          if (L.a == s.side or L.b == s.side) and not alive[s.side .. L.id .. "inner"] then anyInnerDown = true end
        end
        s.protected = (not anyInnerDown) or nil
      else
        s.protected = nil
      end
    end
  end
end

---------------------------------------------------------------------------
-- Levels, offers, XP

function A.offer(w, e, kind)
  local cls = A.byClass[e.class]
  local pool = {}
  if kind == "skill" then
    for _, k in ipairs(cls.skills) do if not e.taken[k] then pool[#pool + 1] = k end end
  else
    for _, k in ipairs(cls.passives) do if not e.taken[k] then pool[#pool + 1] = k end end
    for _, k in ipairs(A.SHARED) do if not e.taken[k] and not U.contains(pool, k) then pool[#pool + 1] = k end end
  end
  local out = {}
  for _ = 1, math.min(2, #pool) do
    local k = table.remove(pool, w.rngCmd:random(#pool))
    if kind == "skill" then
      local s = A.SKILLS[k]
      out[#out + 1] = { key = k, name = "Skill: " .. s.name, desc = s.desc .. string.format(" (%ds cooldown)", s.cd),
        skill = true, apply = function(w2, c) A.learn(w2, c, k) end }
    else
      local p = A.PASSIVES[k]
      out[#out + 1] = { key = k, name = p.name, desc = p.desc, apply = p.apply }
    end
  end
  return out
end

function A.learn(w, c, key)
  local s = A.SKILLS[key]
  local slot = s.ult and 4 or nil
  if not slot then
    for i = 1, 3 do if not c.skills[i] then slot = i; break end end
  end
  if not slot then return end
  c.skills[slot] = { key = key, readyAt = w.time }
  c.taken[key] = true
end

function A.commanderXP(w, e, amount)
  if not e or not e.skills then return end
  -- bigger teams share the map's experience: scale it so max level still arrives late
  local st = w.arena
  local teamMul = 1
  if st and st.teamSide and e.team and st.sideTeams then
    local n = #(st.sideTeams[st.teamSide[e.team]] or {})
    teamMul = n >= 5 and 0.62 or n == 4 and 0.67 or n == 3 and 0.72 or (n == 2 and 0.85 or 1)
  end
  -- catch-up: Commanders below the match's average level learn faster (+15% per level, max +60%)
  local sum, n = 0, 0
  for t = 1, w.np do
    local o = w.teams[t].commander
    if o and o.skills then sum = sum + (o.clevel or 0); n = n + 1 end
  end
  local behind = n > 0 and (sum / n - (e.clevel or 0)) or 0
  local catchUp = behind >= 1 and (1 + math.min(0.6, 0.15 * behind)) or 1
  -- the top difficulties (8-10) also learn faster: +10% experience per level above 7 (said so in the menu)
  local aiBonus = (e.aiLevel and e.aiLevel >= 8) and (1 + 0.1 * (e.aiLevel - 7)) or 1
  e.cxp = (e.cxp or 0) + amount * ((e.mods and e.mods.xpMul) or 1) * teamMul * catchUp * aiBonus
  while (e.clevel or 0) < A.MAX_LEVEL and e.cxp >= A.THRESHOLDS[(e.clevel or 0) + 1] do
    e.clevel = (e.clevel or 0) + 1
    local L = e.clevel
    -- every level: a little tougher and harder hitting
    hpUp(e, 1.06)
    e.hp = math.min(e.maxhp, e.hp + e.maxhp * 0.15)
    mulMod(e, "dmg", 1.05)
    fx(w, "levelup", e.x, e.y, 46, 1.2)
    require("src.mods").onCommanderLevel(w, e)
    if L == A.ULT_LEVEL then
      A.learn(w, e, A.byClass[e.class].ult)
      if w.onCommanderLevel then w.onCommanderLevel(e, nil) end
    else
      local offer = A.offer(w, e, A.SKILL_LEVELS[L] and "skill" or "passive")
      if #offer > 0 then e.offers[#e.offers + 1] = offer end
      if w.onCommanderLevel then w.onCommanderLevel(e, offer) end
    end
  end
end

function A.xpValue(o)
  if o.key == "commander" then return 260 + 90 * (o.clevel or 0) end
  if o.def.xp then return o.def.xp * (1 + 0.15 * (o.level or 0)) end
  if o.def.building then return 0 end
  if o.summon then return 30 end
  return ((o.def.cost and o.def.cost.metal) or 50) * 0.35 * (1 + 0.3 * (o.vet or 0))
end

-- called from World:kill
function A.onKill(w, o, attacker)
  local st = w.arena
  if o.noXP then return end
  local killerC = attacker and (attacker.key == "commander" and attacker or attacker.owner)
  -- wrecks for the Reclaimer
  if not o.def.building and o.key ~= "commander" and not o.summon then
    st.wrecks[#st.wrecks + 1] = { x = o.x, y = o.y, t = w.time }
    if #st.wrecks > 40 then table.remove(st.wrecks, 1) end
  end
  if o.def.building then
    if o.arenaTower then
      -- every Commander on the destroying side shares the reward
      local side = attacker and attacker.team and st.teamSide[attacker.team]
      if side and side ~= o.side then
        for _, t in ipairs(st.sideTeams[side]) do
          local c = w.teams[t].commander
          if c then A.commanderXP(w, c, o.key == "core" and 0 or 260) end
        end
      end
      if w.onTowerDown then w.onTowerDown(o) end
      A.updateProtection(w)
      if o.key == "core" then A.eliminateSide(w, o.side) end
    end
    return
  end
  local value = A.xpValue(o)
  if value <= 0 then return end
  -- jungle neutrals: the killer gets it all, teammates close by get a share
  if o.jungle then
    local ks = attacker and attacker.team and st.teamSide[attacker.team]
    for t = 1, w.np do
      local c = w.teams[t].commander
      if c and c.alive and ks and st.teamSide[t] == ks then
        if c == killerC then A.commanderXP(w, c, value)
        elseif U.dist(c.x, c.y, o.x, o.y) < 700 then A.commanderXP(w, c, value * 0.35) end
      end
    end
    require("src.jungle").onKill(w, o, attacker)
    return
  end
  -- denied: finished off by its own side - nobody gets anything
  if attacker and attacker.team and w.ally[attacker.team] == w.ally[o.team] then
    fx(w, "ring", o.x, o.y, 30, 0.6, { color = { 1, 1, 1 } })
    if w.onDeny then w.onDeny(o, attacker) end
    if os.getenv("PA_DEBUG_AI") then print(string.format("DENY t=%d by team%d %s (vet %d)", w.time, attacker.team, attacker.key, o.vet or 0)) end
    return
  end
  -- the killer's Commander gets it all; other enemy Commanders nearby get a share
  local victimSide = st.teamSide[o.team]
  for t = 1, w.np do
    local c = w.teams[t].commander
    if c and c.alive and st.teamSide[t] ~= victimSide then
      if c == killerC then
        A.commanderXP(w, c, value)
      elseif U.dist(c.x, c.y, o.x, o.y) < 700 then
        A.commanderXP(w, c, value * (killerC and 0.3 or 0.45))
      end
    end
  end
end

function A.commanderDied(w, c, attacker)
  local st = w.arena
  local killer = attacker and attacker.team and st.teamSide[attacker.team]
  if killer and killer ~= st.teamSide[c.team] then st.kills[killer] = st.kills[killer] + 1 end
  st.deaths[c.team] = (st.deaths[c.team] or 0) + 1
  local mins = w.time / 60
  c.respawnAt = w.time + 5 + 2 * (c.clevel or 0) + mins * 0.6
  c.offersDead = true
  fx(w, "boom", c.x, c.y, 120, 1.2)
  if w.onCommanderDown then w.onCommanderDown(c, attacker) end
end

function A.respawn(w, c)
  c.alive = true
  c.hp = c.maxhp
  c.x, c.y = c.respawnX, c.respawnY
  c.homeX, c.homeY = c.x, c.y
  c.orders, c.path, c.chase, c.destX = {}, nil, nil, nil
  c.disarmed, c.retreating, c.stunUntil, c.slowUntil, c.ampUntil = nil, nil, nil, nil, nil
  c.secondWindUsed = nil
  c.respawnAt = nil
  c.pulse = nil
  w.byId[c.id] = c
  w.entities[#w.entities + 1] = c
  fx(w, "levelup", c.x, c.y, 60, 1)
  if w.onRespawn then w.onRespawn(c) end
end

-- a side whose Core falls is out; the last side standing wins
function A.eliminateSide(w, side)
  local st = w.arena
  if st.sideDead[side] then return end
  st.sideDead[side] = true
  for _, t in ipairs(st.sideTeams[side]) do
    local tm = w.teams[t]
    tm.dead = true
    tm.deadTime = w.time
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == t then e.doom = w.time + 0.5 + math.random() * 3 end
    end
    if w.onEliminate then w.onEliminate(t) end
  end
  local alive = {}
  for sd = 1, st.nSides do if not st.sideDead[sd] then alive[#alive + 1] = sd end end
  if #alive <= 1 and not w.over then
    w.over = { winnerAlly = alive[1] and w.ally[st.sideTeams[alive[1]][1]] or -1, time = w.time }
  end
end

---------------------------------------------------------------------------
-- Skills in use

function A.cooldownLeft(w, c, slot)
  local s = c.skills and c.skills[slot]
  if not s then return nil end
  return math.max(0, s.readyAt - w.time)
end

-- returns true, or false plus a reason
function A.useSkill(w, c, slot, tx, ty)
  if not c or not c.alive or not c.skills then return false, "no commander" end
  local s = c.skills[slot]
  if not s then return false, "No skill in that slot yet" end
  if w.time < s.readyAt then return false, string.format("%s recharging (%ds)", A.SKILLS[s.key].name, math.ceil(s.readyAt - w.time)) end
  if c.stunUntil and w.time < c.stunUntil then return false, "Stunned" end
  local def = A.SKILLS[s.key]
  if def.aim == "point" then
    tx, ty = tx or c.x, ty or c.y
    local d = U.dist(c.x, c.y, tx, ty)
    if d > def.range then
      local dx, dy = U.norm(tx - c.x, ty - c.y)
      tx, ty = c.x + dx * def.range, c.y + dy * def.range
    end
  end
  local r = def.use(w, c, tx, ty)
  if r == false then return false, def.name .. ": nothing to use it on" end
  s.readyAt = w.time + def.cd * ((c.mods and c.mods.cdr) or 1)
  c.fadeUntil = (s.key == "fade" or s.key == "evade") and c.fadeUntil or nil -- acting breaks stealth
  if SKILLLOG then print(string.format("SKILL %d %s %s %.0f", c.team, c.class, def.key, w.time)) end
  if c.mods and c.mods.harmony then c.hp = math.min(c.maxhp, c.hp + c.maxhp * 0.05); c.healing = 0.6 end
  if w.onSkill then w.onSkill(c, def) end
  return true
end

---------------------------------------------------------------------------
-- Creep waves

function A.spawnWave(w)
  local st = w.arena
  local map = w.map
  st.wave = st.wave + 1
  local k = st.wave
  local level = math.min(5, math.floor((k - 1) / 4))
  local comp = { "tank", "tank", "tank", "artillery" }
  if k % 3 == 0 then comp[#comp + 1] = "tank" end
  if k >= 8 and k % 2 == 0 then comp[#comp + 1] = "artillery" end
  -- a lane whose enemy towers are both down gets super creeps (like losing barracks in DOTA)
  local towersUp = {}
  for _, sx in ipairs(st.structures) do
    if sx.alive and sx.tier then towersUp[sx.side .. sx.lane] = (towersUp[sx.side .. sx.lane] or 0) + 1 end
  end
  for _, L in ipairs(map.lanes) do
    for _, side in ipairs({ L.a, L.b }) do
      local other = side == L.a and L.b or L.a
      if not st.sideDead[side] and not st.sideDead[other] then
        local team = st.sideOwner[side]
        local route = {}
        if side == L.a then
          for i = 1, #L.pts do route[i] = L.pts[i] end
        else
          for i = #L.pts, 1, -1 do route[#route + 1] = L.pts[i] end
        end
        local superMul = ((towersUp[other .. L.id] or 0) == 0 and not st.sideDead[other]) and 1.6 or 1
        local sx, sy = Map.polyAt(route, 0.07)
        for i, key in ipairs(comp) do
          local x, y = map:center(math.floor(sx + (i % 3) - 1), math.floor(sy + math.floor(i / 3) - 1))
          local u = w:spawn(key, team, x, y)
          u.creep = true
          u.lane = L.id
          if level > 0 then A.setLevel(u, level) end
          -- after 7 minutes the armies keep growing, so games always reach an end
          local m = superMul * (k > 14 and (1 + 0.12 * (k - 14)) or 1) * require("src.jungle").creepMul(w, side)
          if m > 1 then
            u.maxhp = math.floor(u.maxhp * m); u.hp = u.maxhp; u.dmgMul = m
            u.super = superMul > 1
          end
          for j = 2, #route do
            local px, py = map:center(route[j][1], route[j][2])
            w:issue(u, { type = "amove", x = px, y = py, arrive = 60 }, j > 2)
          end
        end
      end
    end
  end
  if w.onWave then w.onWave(k) end
end

---------------------------------------------------------------------------
-- Tick

function A.update(w, dt)
  local st = w.arena
  if w.over then return end
  local t = w.time
  if t >= st.waveAt then
    st.waveAt = st.waveAt + A.WAVE_EVERY
    A.spawnWave(w)
  end
  -- delayed skill effects
  for i = #st.pending, 1, -1 do
    local p = st.pending[i]
    if t >= p.at then table.remove(st.pending, i); p.fn() end
  end
  -- respawns
  for tt = 1, w.np do
    local c = w.teams[tt].commander
    if c and not c.alive and c.respawnAt and t >= c.respawnAt and not st.sideDead[st.teamSide[tt]] then A.respawn(w, c) end
  end
  -- wrecks fade after 40 seconds
  for i = #st.wrecks, 1, -1 do if t - st.wrecks[i].t > 40 then table.remove(st.wrecks, i) end end

  st.slow = (st.slow or 0) - dt
  local tick = st.slow <= 0
  if tick then st.slow = 0.25 end
  for _, e in ipairs(w.entities) do
    if e.alive then
      -- pulse skills (whirlwind, hammers, cyclone)
      if e.pulse then
        if t > e.pulse.untilT then e.pulse = nil
        elseif tick then
          area(w, e, e.x, e.y, e.pulse.r, e.pulse.dmg, { slow = e.pulse.slow and 1 or nil })
          fx(w, e.pulse.kind, e.x, e.y, e.pulse.r, 0.3)
        end
      end
      -- heal over time
      if e.hot then
        if t > e.hot.untilT then e.hot = nil
        else e.hp = math.min(e.maxhp, e.hp + e.maxhp * e.hot.rate * dt); e.healing = 0.3 end
      end
      -- poisons
      if e.dots and tick then
        local total = 0
        for i = #e.dots, 1, -1 do
          local d = e.dots[i]
          if t > d.untilT then table.remove(e.dots, i) else total = total + d.dps * 0.25 end
        end
        if #e.dots == 0 then e.dots = nil end
        if total > 0 then
          local src = e.dots and e.dots[#e.dots].src
          w:damage(e, total, (src and src.alive) and src or nil)
          if e.alive and math.random() < 0.35 then fx(w, "hit", e.x, e.y, 8, 0.25, { color = { 0.5, 1, 0.3 } }) end
        end
      end
      -- gorilla stance regeneration
      if e.stanceRegen and e.alive then e.hp = math.min(e.maxhp, e.hp + e.maxhp * e.stanceRegen * dt) end
      -- Sacrifice: the hexed creep bursts when the hex ends
      if e.charm and t > e.charm.untilT and e.alive then
        local src = e.charm.src
        e.team = e.charm.team
        area(w, src, e.x, e.y, 100, skillDmg(src, 160))
        fx(w, "splash", e.x, e.y, 100, 0.4, { color = { 0.5, 1, 0.3 } })
        e.noXP = true
        e.charm = nil
        w:kill(e, nil)
      end
      if e.alive and e.absorbUntil and t > e.absorbUntil then e.absorb, e.absorbUntil = nil, nil end
      if e.boUntil and t > e.boUntil then e.maxhp = e.boBase or e.maxhp; e.hp = math.min(e.hp, e.maxhp); e.boUntil = nil end
      if e.bearUntil and t > e.bearUntil then e.maxhp = e.bearBase or e.maxhp; e.hp = math.min(e.hp, e.maxhp); e.bearUntil = nil end
    end
  end

  if tick and st.jungle then require("src.jungle").update(w, dt) end
  -- ground zones (Inner Sanctuary)
  if tick and st.zones then
    for i = #st.zones, 1, -1 do
      local z = st.zones[i]
      if t > z.untilT then table.remove(st.zones, i)
      else
        for _, e in ipairs(w.entities) do
          if e.alive and not e.def.building and U.dist(e.x, e.y, z.x, z.y) < z.r then
            if w:hostile(z.team, e.team) then e.slowUntil = math.max(e.slowUntil or 0, t + 0.5)
            else e.sanctuaryUntil = t + 0.4 end
          end
        end
        if math.random() < 0.5 then fx(w, "ring", z.x, z.y, z.r, 0.3, { color = { 1, 0.95, 0.6 } }) end
      end
    end
  end
  if tick then
    -- fountain: heal friendly Commanders at their Core
    for side = 1, st.nSides do
      local core = st.cores[side]
      if core and core.alive then
        for _, tt in ipairs(st.sideTeams[side]) do
          local c = w.teams[tt].commander
          if c and c.alive and U.dist(c.x, c.y, core.x, core.y) < A.FOUNTAIN_R then
            c.hp = math.min(c.maxhp, c.hp + c.maxhp * 0.025)
            c.healing = 0.4
          end
        end
      end
    end
    -- auras (Warden)
    for tt = 1, w.np do
      local c = w.teams[tt].commander
      if c and c.alive and c.mods then
        if c.mods.auraMight or c.mods.auraMend then
          for _, u in ipairs(friends(w, c, c.x, c.y, 350)) do
            if c.mods.auraMight then A.buff(u, "dmg", 1.2, 0.6, w) end
            if c.mods.auraMend then u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.015 * 0.25) end
          end
        end
        if c.mods.auraFreeze then
          for _, o in ipairs(hostiles(w, c, c.x, c.y, 300)) do o.slowUntil = math.max(o.slowUntil or 0, t + 0.6) end
        end
      end
    end
  end

  -- summons follow their owner; owner dead = they hold
  st.followT = (st.followT or 0) - dt
  if st.followT <= 0 then
    st.followT = 0.8
    for _, e in ipairs(w.entities) do
      if e.alive and e.follow and e.owner then
        local o = e.owner
        if not o.alive then
          -- owner died: summons with a timer fade away; the rest stand guard
        elseif U.dist(e.x, e.y, o.x, o.y) > 200 and not (e.chase and e.chase.alive) then
          local a = (e.id % 6) / 6 * math.pi * 2
          w:issue(e, { type = "amove", x = o.x + math.cos(a) * 70, y = o.y + math.sin(a) * 70, arrive = 40 })
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Score par for the Arena: about what a clean, decisive win takes (computer-vs-computer
-- games run ~12 minutes; a player who is winning pushes faster). +2 per extra enemy.

A.TEMPLATE_PAR = { classic = 10, longroad = 12.5, gauntlet = 10, open = 9.5, treeline = 10.5, battlefield = 13 }

function A.par(w)
  local base = A.TEMPLATE_PAR[w.map.template or "classic"] or 10
  local enemies, allies = 0, 0
  for t = 2, w.np do if w:hostile(t, 1) then enemies = enemies + 1 else allies = allies + 1 end end
  return math.floor((base + 2 * (enemies - 1) - 1.5 * allies) * 60)
end

return A
