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
    if mm and (key == "drone" or key == "wolf") then u.maxhp = math.floor(u.maxhp * mm); u.hp = u.maxhp; u.dmgMul = mm end
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

A.SKILLS = {
  -- Ranger
  multishot = { name = "Multishot", aim = "point", range = 520, cd = 7, tags = { "dmg", "aoe" },
    desc = "A fan of 5 shots toward the target.",
    use = function(w, c, tx, ty)
      local base = math.atan2(ty - c.y, tx - c.x)
      for i = -2, 2 do
        local a = base + i * 0.16
        local d = 480
        w.projectiles[#w.projectiles + 1] = { x = c.x, y = c.y, sx = c.x, sy = c.y, tx = c.x + math.cos(a) * d, ty = c.y + math.sin(a) * d,
          speed = 700, damage = skillDmg(c, 80), splash = 34, team = c.team, weapon = c.def.weapon, source = c }
      end
    end },
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
    desc = "Rebuilds up to 3 recent wrecks near the target as your drones (max 6, more with Legion).",
    use = function(w, c, tx, ty)
      local st = w.arena
      local maxN = 6 + ((c.mods and c.mods.extraMinions) or 0)
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
          area(w, c, wr.x, wr.y, 110, skillDmg(c, 170))
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
    desc = "ULTIMATE: 6 veteran drones claw out of the ground around you for 25 seconds.",
    use = function(w, c) summon(w, c, "drone", 6, 25, 3) end },

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
    desc = "Charge forward and smash the first enemy you reach (stun 1s).",
    use = function(w, c, tx, ty)
      dash(w, c, tx, ty, 320)
      local list = hostiles(w, c, c.x, c.y, 90)
      if list[1] then hit(w, c, list[1], skillDmg(c, 220)); list[1].stunUntil = w.time + 1 end
      fx(w, "splash", c.x, c.y, 70, 0.3)
    end },
  holyshield = { name = "Holy Shield", aim = "self", range = 0, cd = 18, tags = { "defend" },
    desc = "Take half damage for 10 seconds.",
    use = function(w, c) A.buff(c, "armor", 0.5, 10, w) end },
  hammers = { name = "Spinning Hammers", aim = "self", range = 170, cd = 12, tags = { "dmg", "aoe" },
    desc = "Hammers circle you for 5 seconds, battering everything close.",
    use = function(w, c) c.pulse = { untilT = w.time + 5, r = 170, dmg = skillDmg(c, 30), kind = "hammer" } end },
  smite = { name = "Smite", aim = "point", range = 260, cd = 8, tags = { "dmg", "cc" },
    desc = "Strike the nearest enemy to the target hard and stun it for 1.5 seconds.",
    use = function(w, c, tx, ty)
      local list = hostiles(w, c, tx, ty, 120)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return false end
      hit(w, c, best, skillDmg(c, 260)); best.stunUntil = w.time + 1.5
      fx(w, "bolt", c.x, c.y, 5, 0.3, { x2 = best.x, y2 = best.y, color = { 1, 0.95, 0.6 } })
    end },
  prayer = { name = "Prayer", aim = "self", range = 450, cd = 20, tags = { "heal" },
    desc = "Heal yourself and allies nearby by 25%.",
    use = function(w, c)
      for _, u in ipairs(friends(w, c, c.x, c.y, 450)) do u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.25); u.healing = 1 end
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
    use = function(w, c) c.pulse = { untilT = w.time + 4, r = 200, dmg = skillDmg(c, 26), slow = true, kind = "cyclone" } end },
  firestorm = { name = "Firestorm", aim = "point", range = 460, cd = 8, tags = { "dmg", "line" },
    desc = "A wall of fire rolls toward the target.",
    use = function(w, c, tx, ty) lineHit(w, c, tx, ty, 460, 30, skillDmg(c, 190), { 1, 0.5, 0.2 }) end },
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
    use = function(w, c, tx, ty) area(w, c, tx, ty, 160, skillDmg(c, 90), { stun = 1.8 }); fx(w, "ring", tx, ty, 160, 0.5, { color = { 0.9, 0.6, 1 } }) end },
  fade = { name = "Fade", aim = "self", range = 0, cd = 18, tags = { "escape" },
    desc = "Vanish for 4 seconds: nothing can target you, and you move 40% faster.",
    use = function(w, c) c.fadeUntil = w.time + 4; A.buff(c, "speed", 1.4, 4, w) end },
  clone = { name = "Shadow Clone", aim = "self", range = 0, cd = 24, tags = { "summon" },
    desc = "A shadow copy of you fights for 15 seconds.",
    use = function(w, c) summon(w, c, "shadow", 1, 15, math.floor((c.clevel or 1) / 2)) end },
  talon = { name = "Dragon Talon", aim = "point", range = 220, cd = 7, tags = { "dmg" },
    desc = "Three lightning-fast kicks on the nearest enemy to the target.",
    use = function(w, c, tx, ty)
      local list = hostiles(w, c, tx, ty, 120)
      local best, bd
      for _, o in ipairs(list) do local d = U.dist(tx, ty, o.x, o.y); if not bd or d < bd then best, bd = o, d end end
      if not best then return false end
      for i = 0, 2 do later(w, i * 0.15, function() if best.alive then hit(w, c, best, skillDmg(c, 110)); fx(w, "hit", best.x, best.y, 14, 0.2) end end) end
    end },
  swarm = { name = "Sentry Swarm", aim = "point", range = 500, cd = 55, ult = true, tags = { "summon", "ult", "siege" },
    desc = "ULTIMATE: deploy 5 sentries around the target for 20 seconds.",
    use = function(w, c, tx, ty)
      for i = 1, 5 do
        local a = i / 5 * math.pi * 2
        deploy(w, c, tx + math.cos(a) * 90, ty + math.sin(a) * 90, 20)
      end
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
}
for k, p in pairs(A.PASSIVES) do p.key = k end
A.SHARED = { "hull", "regen", "cannon", "loader", "treads", "bounty", "breaker", "lifesteal", "secondwind", "focus", "power" }

---------------------------------------------------------------------------
-- Classes

A.CLASSES = {
  { key = "ranger", name = "Ranger", tag = "Longest range; volleys and lances.",
    skills = { "multishot", "lance", "evade", "decoy", "frostarrow" }, ult = "chainstorm", passives = { "crit", "eagle", "dodge" },
    base = function(w, e) mulMod(e, "range", 1.35); hpUp(e, 0.9) end },
  { key = "elementalist", name = "Elementalist", tag = "Fragile; fire, frost and lightning.",
    skills = { "teleport", "frostnova", "fireball", "chainlightning", "energyshield" }, ult = "meteor", passives = { "coldmastery", "power", "focus" },
    base = function(w, e) hpUp(e, 0.85); mulMod(e, "skillDmg", 1.1) end },
  { key = "reclaimer", name = "Reclaimer", tag = "Raises wrecked creeps as drones; curses.",
    skills = { "raise", "amplify", "corpseburst", "bonespear", "decrepify" }, ult = "rise", passives = { "legion", "lifesteal" },
    base = function(w, e) end },
  { key = "juggernaut", name = "Juggernaut", tag = "Huge health, short range; leaps and shouts.",
    skills = { "leap", "warcry", "whirlwind", "battleorders", "shout" }, ult = "berserk", passives = { "ironskin", "regen" },
    base = function(w, e) hpUp(e, 1.5); mulMod(e, "range", 0.8); mulMod(e, "dmg", 1.25); mulMod(e, "armor", 0.9) end },
  { key = "warden", name = "Warden", tag = "Auras for allies and creeps; charge and smite.",
    skills = { "charge", "holyshield", "hammers", "smite", "prayer" }, ult = "judgment", passives = { "might", "prayeraura", "freezeaura" },
    base = function(w, e) hpUp(e, 1.15) end },
  { key = "shifter", name = "Shifter", tag = "Wolf pack, bear form and storms.",
    skills = { "wolves", "bear", "cyclone", "firestorm", "oaksage" }, ult = "cataclysm", passives = { "pack", "lycan" },
    base = function(w, e) end },
  { key = "infiltrator", name = "Infiltrator", tag = "Trap turrets, stealth and a shadow clone.",
    skills = { "sentry", "mindblast", "fade", "clone", "talon" }, ult = "swarm", passives = { "crit", "venom", "shadowstep" },
    base = function(w, e) mulMod(e, "speed", 1.15); hpUp(e, 0.95) end },
}
A.byClass = {}
for _, c in ipairs(A.CLASSES) do A.byClass[c.key] = c end

---------------------------------------------------------------------------
-- Setup

function A.setup(w, opts)
  local map = w.map
  local st = { pending = {}, wrecks = {}, waveAt = A.WAVE_FIRST, wave = 0, kills = { 0, 0 }, deaths = {}, structures = {} }
  w.arena = st
  -- sides by alliance: side 1 = the human's alliance
  st.teamSide, st.sideTeams = {}, { {}, {} }
  for t = 1, w.np do
    local side = w.ally[t] == w.ally[1] and 1 or 2
    st.teamSide[t] = side
    table.insert(st.sideTeams[side], t)
  end
  st.sideOwner = { st.sideTeams[1][1], st.sideTeams[2][1] }
  for side = 1, 2 do
    local cpos = map.cores[side]
    local x, y = map:center(cpos.x, cpos.y)
    local core = w:spawn("core", st.sideOwner[side], x, y)
    core.arenaTower = true
    core.side = side
    st.structures[#st.structures + 1] = core
    st["core" .. side] = core
  end
  for _, t in ipairs(map.towers) do
    local x, y = map:center(t.x, t.y)
    local tw = w:spawn("atower", st.sideOwner[t.side], x, y)
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
    if not ck or not A.byClass[ck] then ck = A.CLASSES[w.rngCmd:random(#A.CLASSES)].key end
    c.class = ck
    c.skills = {}
    c.mods.dmg = 1.6           -- Commanders hit harder in the Arena
    A.byClass[ck].base(w, c)
    c.respawnX, c.respawnY = c.x, c.y
    st.deaths[t] = 0
    p.class = ck
  end
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
        s.protected = alive[s.side .. s.lane .. "outer"] or nil
      elseif s.key == "core" then
        local anyInnerDown = false
        for _, lane in ipairs({ "top", "mid", "bot" }) do
          if not alive[s.side .. lane .. "inner"] then anyInnerDown = true end
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
  e.cxp = (e.cxp or 0) + amount * ((e.mods and e.mods.xpMul) or 1)
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
  if o.def.building then return 0 end
  if o.summon then return 30 end
  return ((o.def.cost and o.def.cost.metal) or 50) * 0.35
end

-- called from World:kill
function A.onKill(w, o, attacker)
  local st = w.arena
  local killerC = attacker and (attacker.key == "commander" and attacker or attacker.owner)
  -- wrecks for the Reclaimer
  if not o.def.building and o.key ~= "commander" and not o.summon then
    st.wrecks[#st.wrecks + 1] = { x = o.x, y = o.y, t = w.time }
    if #st.wrecks > 40 then table.remove(st.wrecks, 1) end
  end
  if o.def.building then
    if o.arenaTower then
      -- every Commander on the destroying side shares the reward
      local side = 3 - o.side
      for _, t in ipairs(st.sideTeams[side]) do
        local c = w.teams[t].commander
        if c then A.commanderXP(w, c, o.key == "core" and 0 or 260) end
      end
      if w.onTowerDown then w.onTowerDown(o) end
      A.updateProtection(w)
      if o.key == "core" then A.finish(w, side) end
    end
    return
  end
  local value = A.xpValue(o)
  if value <= 0 then return end
  -- denied: finished off by its own side - nobody gets anything
  if attacker and attacker.team and w.ally[attacker.team] == w.ally[o.team] then
    fx(w, "ring", o.x, o.y, 30, 0.6, { color = { 1, 1, 1 } })
    if w.onDeny then w.onDeny(o, attacker) end
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
  local side = st.teamSide[c.team]
  st.kills[3 - side] = st.kills[3 - side] + 1
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

function A.finish(w, winnerSide)
  local st = w.arena
  if w.over then return end
  local loser = 3 - winnerSide
  for _, t in ipairs(st.sideTeams[loser]) do
    local tm = w.teams[t]
    tm.dead = true
    tm.deadTime = w.time
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == t then e.doom = w.time + 0.5 + math.random() * 3 end
    end
  end
  w.over = { winnerAlly = w.ally[st.sideTeams[winnerSide][1]], time = w.time }
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
  for side = 1, 2 do
    local team = st.sideOwner[side]
    for lane, pts in pairs(map.lanes) do
      local superMul = (towersUp[(3 - side) .. lane] or 0) == 0 and 1.6 or 1
      local route = {}
      if side == 1 then
        for i = 1, #pts do route[i] = pts[i] end
      else
        for i = #pts, 1, -1 do route[#route + 1] = pts[i] end
      end
      local sx, sy = Map.polyAt(route, 0.07)
      for i, key in ipairs(comp) do
        local x, y = map:center(math.floor(sx + (i % 3) - 1), math.floor(sy + math.floor(i / 3) - 1))
        local u = w:spawn(key, team, x, y)
        u.creep = true
        u.lane = lane
        if level > 0 then A.setLevel(u, level) end
        -- after 8 minutes the armies keep growing, so games always reach an end
        local m = superMul * (k > 14 and (1 + 0.12 * (k - 14)) or 1)
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
    if c and not c.alive and c.respawnAt and t >= c.respawnAt then A.respawn(w, c) end
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
      if e.absorbUntil and t > e.absorbUntil then e.absorb, e.absorbUntil = nil, nil end
      if e.boUntil and t > e.boUntil then e.maxhp = e.boBase or e.maxhp; e.hp = math.min(e.hp, e.maxhp); e.boUntil = nil end
      if e.bearUntil and t > e.bearUntil then e.maxhp = e.bearBase or e.maxhp; e.hp = math.min(e.hp, e.maxhp); e.bearUntil = nil end
    end
  end

  if tick then
    -- fountain: heal friendly Commanders at their Core
    for side = 1, 2 do
      local core = st["core" .. side]
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
-- Score par for the Arena: 14 minutes, +3 per extra enemy

function A.par(w)
  local enemies = #w.arena.sideTeams[2]
  local allies = #w.arena.sideTeams[1] - 1
  return (14 + 3 * (enemies - 1) - 2 * allies) * 60
end

return A
