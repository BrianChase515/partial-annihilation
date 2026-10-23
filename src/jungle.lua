-- Commander Arena jungle (Treeline and Battlefield maps): neutral camps that only fight
-- back, two capture shrines, the Colossus boss and healing relics.
local U = require("src.util")

local J = {}

J.CAMP_FIRST = 40          -- camps appear at 0:40
J.CAMP_RESPAWN = 70        -- and come back 70 s after they're cleared
J.LEASH = 330              -- neutrals chase this far from home, then walk back and heal
J.SHRINE_R = 150
J.SHRINE_TIME = 8          -- seconds for one Commander to capture (two take half as long)
J.SHRINE_LOCK = 40
J.SHRINE_FIRST = 90        -- shrines wake at 1:30         -- a fresh capture can't be taken back for this long
J.SHRINE_BONUS = 0.08      -- +8% speed and damage per shrine held
J.BOSS_FIRST = 420         -- the Colossus wakes at 7:00
J.BOSS_RESPAWN = 300
J.CREST_TIME = 120         -- the Colossus Crest lasts 2:00
J.RELIC_FIRST = 90
J.RELIC_RESPAWN = 70
J.RELIC_R = 50

local function event(w, text, side, kind)
  if os.getenv("PA_DEBUG_AI") then print(string.format("JUNGLE t=%d %s", w.time, string.format(text, side and ("side " .. side) or ""))) end
  if w.onJungle then w.onJungle(text, side, kind) end
end

function J.setup(w)
  local map = w.map
  local st = w.arena
  -- neutrals live on team 0: give it a stub team record so the world can track them
  w.teams[0] = w.teams[0] or { neutral = true, metal = 0, energy = 0, mStore = 0, eStore = 0, mIncome = 0, eIncome = 0,
    mSpend = 0, eSpend = 0, incomeMul = 1, lastAttacked = -99 }
  local j = { camps = {}, shrines = {}, pits = {}, relics = {}, crest = {}, bossAt = J.BOSS_FIRST, pitIndex = 1 }
  st.jungle = j
  w.onProvoke = function(o, attacker) J.onProvoke(w, o, attacker) end
  for _, c in ipairs(map.camps or {}) do
    local x, y = map:center(c.x, c.y)
    j.camps[#j.camps + 1] = { x = x, y = y, kind = c.kind, units = {}, readyAt = J.CAMP_FIRST, half = c.half }
  end
  for _, s in ipairs(map.shrines or {}) do
    local x, y = map:center(s.x, s.y)
    j.shrines[#j.shrines + 1] = { x = x, y = y, owner = nil, prog = 0, progSide = nil, lockUntil = J.SHRINE_FIRST }
  end
  for _, p in ipairs(map.pits or {}) do
    local x, y = map:center(p.x, p.y)
    j.pits[#j.pits + 1] = { x = x, y = y }
  end
  for _, r in ipairs(map.relics or {}) do
    local x, y = map:center(r.x, r.y)
    j.relics[#j.relics + 1] = { x = x, y = y, readyAt = J.RELIC_FIRST }
  end
end

local function spawnNeutral(w, key, x, y, home, level)
  local u = w:spawn(key, 0, x, y)
  u.passive = true
  u.jungle = true
  u.homeX, u.homeY = home.x, home.y
  u.campRef = home
  if level and level > 0 then
    u.level = level
    u.maxhp = math.floor(u.def.hp * (1 + 0.15 * level))
    u.hp = u.maxhp
  end
  return u
end

local function spawnCamp(w, c)
  local level = math.min(4, math.floor(w.time / 240))
  local comp = c.kind == "big" and { "ravager", "scavenger", "scavenger" } or { "scavenger", "scavenger", "scavenger" }
  c.units = {}
  for i, key in ipairs(comp) do
    local a = i / #comp * math.pi * 2
    c.units[#c.units + 1] = spawnNeutral(w, key, c.x + math.cos(a) * 34, c.y + math.sin(a) * 34, c, level)
  end
end

-- everyone in a camp turns on whoever hit one of them
function J.onProvoke(w, o, attacker)
  local c = o.campRef
  if not c or not c.units then return end
  for _, u in ipairs(c.units) do
    if u.alive and u ~= o then
      u.aggro = u.aggro or {}
      u.aggro[attacker] = w.time + 8
      if #u.orders == 0 and not u.retaliate then u.retaliate = attacker end
    end
  end
end

-- a commander-side reward: XP for neutral kills is handled in the Arena's onKill; the boss
-- also hands out the Crest
function J.onKill(w, o, attacker)
  local st = w.arena
  local j = st.jungle
  if not j or not o.jungle then return end
  if o.def.boss then
    local side = attacker and attacker.team and st.teamSide[attacker.team]
    j.boss = nil
    j.bossAt = w.time + J.BOSS_RESPAWN
    j.pitIndex = (j.pitIndex % math.max(1, #j.pits)) + 1
    if side then
      j.crest[side] = w.time + J.CREST_TIME
      event(w, "%s slew the Colossus! Colossus Crest for 2:00", side, "crest")
    end
  end
end

-- per-tick (every 0.25 s) jungle update
function J.update(w, dt)
  local st = w.arena
  local j = st.jungle
  if not j then return end
  local t = w.time
  -- camps: spawn / respawn, and leash
  for _, c in ipairs(j.camps) do
    local alive = 0
    for _, u in ipairs(c.units) do if u.alive then alive = alive + 1 end end
    if alive == 0 then
      if #c.units > 0 and not c.cleared then c.cleared = true; c.readyAt = t + J.CAMP_RESPAWN end
      if t >= c.readyAt then c.cleared = false; spawnCamp(w, c) end
    end
  end
  -- leash: neutrals that wander too far walk home, forget their attackers and heal up
  for _, e in ipairs(w.entities) do
    if e.alive and e.jungle then
      local leash = e.def.boss and J.LEASH + 60 or J.LEASH
      local d = U.dist(e.x, e.y, e.homeX, e.homeY)
      if d > leash and not e.leashing then
        e.leashing = true
        e.aggro, e.retaliate, e.chase = {}, nil, nil
        w:issue(e, { type = "move", x = e.homeX, y = e.homeY })
      elseif e.leashing then
        if d < 50 then
          e.leashing = nil
          e.hp = e.maxhp
          e.orders = {}
        end
      elseif not e.aggro or not next(e.aggro) then
        -- idle and nobody fighting it: slow regeneration back to full
        if t - (e.lastHit or -99) > 5 then e.hp = math.min(e.maxhp, e.hp + e.maxhp * 0.02) end
      end
      if e.aggro then for k, untilT in pairs(e.aggro) do if not k.alive or untilT < t then e.aggro[k] = nil end end end
    end
  end
  -- the Colossus
  if not j.boss and #j.pits > 0 and t >= j.bossAt then
    local p = j.pits[j.pitIndex]
    j.boss = spawnNeutral(w, "colossus", p.x, p.y, p, math.min(4, math.floor(t / 300)))
    event(w, "The Colossus has awoken in the pit", nil, "boss")
  end
  -- shrines
  for _, s in ipairs(j.shrines) do
    local count = {}
    local sides = 0
    for tt = 1, w.np do
      local c = w.teams[tt].commander
      if c and c.alive and U.dist2(c.x, c.y, s.x, s.y) < J.SHRINE_R * J.SHRINE_R then
        local sd = st.teamSide[tt]
        if not count[sd] then sides = sides + 1 end
        count[sd] = (count[sd] or 0) + 1
      end
    end
    if sides == 1 and t >= s.lockUntil then
      local sd = next(count)
      if sd ~= s.owner then
        if s.progSide ~= sd then s.progSide, s.prog = sd, 0 end
        s.prog = s.prog + 0.25 * count[sd] / J.SHRINE_TIME
        if s.prog >= 1 then
          s.owner, s.prog, s.progSide = sd, 0, nil
          s.lockUntil = t + J.SHRINE_LOCK
          event(w, "%s captured a shrine", sd, "shrine")
        end
      end
    elseif sides == 0 then
      s.prog = math.max(0, s.prog - 0.25 / J.SHRINE_TIME)
    end
  end
  -- relics
  for _, r in ipairs(j.relics) do
    if t >= r.readyAt then
      for tt = 1, w.np do
        local c = w.teams[tt].commander
        if c and c.alive and U.dist2(c.x, c.y, r.x, r.y) < J.RELIC_R * J.RELIC_R then
          c.hp = math.min(c.maxhp, c.hp + c.maxhp * 0.35)
          c.healing = 0.8
          require("src.arena").buff(c, "speed", 1.3, 4, w)
          r.readyAt = t + J.RELIC_RESPAWN
          w.effects[#w.effects + 1] = { kind = "levelup", x = r.x, y = r.y, t = 0, life = 0.8, size = 40 }
          break
        end
      end
    end
  end
  -- standing bonuses: shrines held and the Crest
  local held = {}
  for _, s in ipairs(j.shrines) do if s.owner then held[s.owner] = (held[s.owner] or 0) + 1 end end
  for tt = 1, w.np do
    local c = w.teams[tt].commander
    if c then
      local sd = st.teamSide[tt]
      local m = 1 + J.SHRINE_BONUS * (held[sd] or 0)
      local crest = j.crest[sd] and t < j.crest[sd]
      c.zoneMul = c.zoneMul or {}
      c.zoneMul.speed = m
      c.zoneMul.dmg = m * (crest and 1.2 or 1)
      c.zoneMul.armor = crest and 0.85 or nil
      if crest and c.alive then c.hp = math.min(c.maxhp, c.hp + c.maxhp * 0.004) end
    end
  end
end

-- lane creeps of a side with the Crest come out stronger
function J.creepMul(w, side)
  local j = w.arena and w.arena.jungle
  if j and j.crest[side] and w.time < j.crest[side] then return 1.2 end
  return 1
end

-------------------------------------------------------------------------------
-- drawing (world space): pits, shrines with capture rings, relics, camp markers

function J.draw(w)
  local st = w.arena
  local j = st and st.jungle
  if not j then return end
  local lg = love.graphics
  local R = require("src.render")
  local t = w.time
  for _, p in ipairs(j.pits) do
    lg.setColor(0.08, 0.06, 0.06, 0.55)
    lg.circle("fill", p.x, p.y, 110)
    lg.setColor(0.75, 0.35, 0.25, 0.6)
    lg.setLineWidth(3)
    lg.circle("line", p.x, p.y, 110)
    if not j.boss and t < j.bossAt and j.pits[j.pitIndex] == p then
      local left = math.ceil(j.bossAt - t)
      lg.setFont(R.font(13))
      local s = string.format("Colossus %d:%02d", math.floor(left / 60), left % 60)
      lg.setColor(1, 0.75, 0.6, 0.85)
      lg.print(s, p.x - R.font(13):getWidth(s) / 2, p.y - 8)
    end
  end
  for _, c in ipairs(j.camps) do
    lg.setColor(0.72, 0.42, 1, 0.18)
    lg.setLineWidth(2)
    lg.circle("line", c.x, c.y, c.kind == "big" and 70 or 58)
  end
  for _, s in ipairs(j.shrines) do
    local r = 34
    local cr, cg, cb = 0.75, 0.75, 0.8
    if s.owner then cr, cg, cb = R.teamColor(st.sideOwner[s.owner]) end
    lg.setColor(0, 0, 0, 0.35)
    lg.circle("fill", s.x, s.y, J.SHRINE_R)
    lg.setColor(cr, cg, cb, 0.35)
    lg.setLineWidth(2)
    lg.circle("line", s.x, s.y, J.SHRINE_R)
    lg.setColor(cr, cg, cb, 0.95)
    lg.polygon("fill", s.x, s.y - r, s.x + r * 0.7, s.y, s.x, s.y + r, s.x - r * 0.7, s.y)
    lg.setColor(0, 0, 0, 0.8)
    lg.polygon("line", s.x, s.y - r, s.x + r * 0.7, s.y, s.x, s.y + r, s.x - r * 0.7, s.y)
    if s.prog > 0 and s.progSide then
      local pr, pg, pb = R.teamColor(st.sideOwner[s.progSide])
      lg.setColor(pr, pg, pb, 0.95)
      lg.setLineWidth(5)
      lg.arc("line", "open", s.x, s.y, r + 14, -math.pi / 2, -math.pi / 2 + math.pi * 2 * s.prog)
    end
    if t < s.lockUntil then
      lg.setColor(1, 1, 1, 0.5)
      lg.setLineWidth(1.5)
      lg.circle("line", s.x, s.y, r + 22)
    end
  end
  for _, r in ipairs(j.relics) do
    if t >= r.readyAt then
      local pulse = 0.75 + 0.25 * math.sin(love.timer.getTime() * 4)
      lg.setColor(0.3, 1, 0.45, 0.25 * pulse)
      lg.circle("fill", r.x, r.y, 26)
      lg.setColor(0.4, 1, 0.5, pulse)
      lg.rectangle("fill", r.x - 4, r.y - 14, 8, 28, 2)
      lg.rectangle("fill", r.x - 14, r.y - 4, 28, 8, 2)
    else
      lg.setColor(0.4, 1, 0.5, 0.2)
      lg.setLineWidth(1.5)
      lg.circle("line", r.x, r.y, 18)
    end
  end
end

-- minimap markers
function J.drawMinimap(w, mm, s)
  local j = w.arena and w.arena.jungle
  if not j then return end
  local lg = love.graphics
  local R = require("src.render")
  local T = w.T
  for _, sh in ipairs(j.shrines) do
    local cr, cg, cb = 0.85, 0.85, 0.9
    if sh.owner then cr, cg, cb = R.teamColor(w.arena.sideOwner[sh.owner]) end
    lg.setColor(cr, cg, cb)
    local px, py = mm.x + sh.x / T * s, mm.y + sh.y / T * s
    lg.polygon("fill", px, py - 4, px + 3, py, px, py + 4, px - 3, py)
  end
  for _, p in ipairs(j.pits) do
    lg.setColor(0.85, 0.4, 0.3, j.boss and 1 or 0.5)
    lg.circle(j.boss and "fill" or "line", mm.x + p.x / T * s, mm.y + p.y / T * s, 3.5)
  end
end

return J
