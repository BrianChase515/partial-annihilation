-- Squad Tactics (an Annihilation game type): no economy, no Commander. Each side has a Field HQ
-- and two or three squads designed before the match. Every squad follows a Squad Leader with a
-- toggle ability (V). Units slowly heal anywhere and quickly beside their HQ, so pulling back
-- (Flee) and coming back is the rhythm of the game. A fallen leader returns at the HQ after 45 s
-- (his squad fights on without the ability meanwhile). Destroy the enemy HQ to win.
local U = require("src.util")
local D = require("src.defs")

local S = {}

-- what a squad can hold: points per unit, from a budget per squad
S.BUDGET = 12
S.COST = { scout = 1, tank = 2, flak = 2, artillery = 3, fighter = 2, gunship = 3, bomber = 4 }
S.UNITS = { "scout", "tank", "artillery", "flak", "fighter", "gunship", "bomber" }

S.ABILITIES = {
  { key = "entrench", name = "Entrench", desc = "The squad digs in: it takes 35% less damage but moves at half speed." },
  { key = "spotter", name = "Spotter Drone", desc = "The squad sees 60% further - artillery can fire at everything it sees." },
  { key = "smoke", name = "Smoke", desc = "Smoke hides the squad from anything further than point-blank. Slightly slower." },
  { key = "overdrive", name = "Overdrive", desc = "The squad moves and fires 30% faster, while the leader burns 1.5% of his health a second." },
  { key = "repair", name = "Field Repair", desc = "While the leader stands still (and holds fire), nearby squad members repair 2.5% a second." },
}
S.byAbility = {}
for _, a in ipairs(S.ABILITIES) do S.byAbility[a.key] = a end

S.RADIUS = 260         -- an ability reaches squad members this close to their leader
S.HQ_HEAL = 0.05       -- per second, near your HQ
S.HQ_RANGE = 320
S.FIELD_HEAL = 0.006   -- per second anywhere, after 6 s without being hit
S.LEADER_RESPAWN = 45
S.REINFORCE = 30       -- a fallen squad member is replaced at the HQ this long after

function S.cost(units)
  local p = 0
  for k, n in pairs(units or {}) do p = p + (S.COST[k] or 0) * n end
  return p
end

-- a random squad within the budget (for the computer's side)
function S.randomSquad(rng, idx)
  local units = {}
  local left = S.BUDGET
  -- a backbone of tanks, then a little of everything
  units.tank = 2; left = left - 4
  local pool = { "scout", "artillery", "flak", "tank", "gunship", "fighter", "bomber" }
  for _ = 1, 20 do
    local k = pool[rng:random(#pool)]
    if S.COST[k] <= left then units[k] = (units[k] or 0) + 1; left = left - S.COST[k] end
    if left <= 0 then break end
  end
  return { leader = S.ABILITIES[rng:random(#S.ABILITIES)].key, units = units }
end

S.DEFAULT = {
  { on = true, leader = "entrench", units = { tank = 3, artillery = 1, flak = 1, scout = 1 } },
  { on = true, leader = "spotter", units = { scout = 2, artillery = 2, tank = 2 } },
  { on = false, leader = "overdrive", units = { tank = 2, gunship = 2, scout = 2 } },
}

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

function S.setup(world, opts)
  local map = world.map
  world.squads = { list = {} }
  local rng = love.math.newRandomGenerator((map.seed or 1) + 911)
  for t = 1, world.np do
    local tm = world.teams[t]
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
    tm.hq = hq
    if os.getenv("PA_SQDBG") then print("SQHQ", t, hq and "ok" or "NONE", math.floor(tm.startX), math.floor(tm.startY)) end
    -- squads: the human's own designs, the computer's at random
    local designs = {}
    local human = opts.players and opts.players[t] and opts.players[t].human
    if human and opts.squadSetup then
      for _, sq in ipairs(opts.squadSetup) do if sq.on then designs[#designs + 1] = sq end end
    else
      local n = (opts.squadSetup and #(function() local l = {}; for _, s in ipairs(opts.squadSetup) do if s.on then l[#l + 1] = s end end; return l end)()) or 2
      for i = 1, math.max(2, n) do designs[i] = S.randomSquad(rng, i) end
    end
    -- toward the middle of the map: that's where the squads stand ready
    local mx, my = map.w * world.T / 2, map.h * world.T / 2
    local dx, dy = U.norm(mx - tm.startX, my - tm.startY)
    local px, py = -dy, dx
    for i, ds in ipairs(designs) do
      local off = (i - (#designs + 1) / 2) * 190
      local cx, cy = tm.startX + dx * 260 + px * off, tm.startY + dy * 260 + py * off
      local sq = { team = t, idx = i, ability = ds.leader, on = false, members = {} }
      local lx, ly = place(world, cx, cy, "land")
      local leader = world:spawn("leader", t, lx, ly)
      leader.homeX, leader.homeY = lx, ly
      leader.squad, leader.squadLeader = sq, true
      sq.leader = leader
      sq.members[#sq.members + 1] = leader
      local n = 0
      for _, k in ipairs(S.UNITS) do
        for _ = 1, (ds.units and ds.units[k] or 0) do
          n = n + 1
          local a = n * 1.9
          local d = D.units[k]
          local x, y = place(world, cx + math.cos(a) * (50 + n * 6), cy + math.sin(a) * (50 + n * 6), d.domain == "air" and nil or "land")
          local u = world:spawn(k, t, x, y)
          u.homeX, u.homeY = x, y
          u.squad = sq
          sq.members[#sq.members + 1] = u
        end
      end
      world.squads.list[#world.squads.list + 1] = sq
    end
  end
end

function S.squadsOf(world, team)
  local out = {}
  for _, sq in ipairs(world.squads and world.squads.list or {}) do if sq.team == team then out[#out + 1] = sq end end
  return out
end

---------------------------------------------------------------------------
-- Per frame: abilities, healing, defeat

function S.toggle(world, sq, on)
  if not sq or not sq.leader or not sq.leader.alive then return false end
  if on == nil then on = not sq.on end
  sq.on = on
  if world.onSquadAbility then world.onSquadAbility(sq) end
  return true
end

function S.update(world, dt)
  local st = world.squads
  if not st then return end
  local t = world.time
  -- everyone's squad effects are rebuilt each frame
  for _, sq in ipairs(st.list) do
    -- a fallen leader comes back at the HQ
    if sq.leader and not sq.leader.alive then
      local hq = world.teams[sq.team].hq
      if not sq.respawnAt then
        sq.respawnAt = t + S.LEADER_RESPAWN
        sq.on = false
        if world.onSquadLeaderDown then world.onSquadLeaderDown(sq) end
      elseif t >= sq.respawnAt and hq and hq.alive then
        local x, y = place(world, hq.x, hq.y + 110, "land")
        local old = sq.leader
        local L = world:spawn("leader", sq.team, x, y)
        L.homeX, L.homeY = x, y
        L.squad, L.squadLeader = sq, true
        L.mods, L.taken, L.upgrades, L.offers, L.cxp, L.clevel = {}, {}, {}, {}, 0, 0
        sq.leader, sq.respawnAt = L, nil
        sq.members[#sq.members + 1] = L
        if world.teams[sq.team].commander == old then world.teams[sq.team].commander = L end
        if world.onSquadLeaderBack then world.onSquadLeaderBack(sq) end
      end
    end
    -- fallen members are replaced at the HQ after a while and rejoin their leader
    sq.queue = sq.queue or {}
    for i = #sq.members, 1, -1 do
      local u = sq.members[i]
      if not u.alive and not u.squadLeader then
        table.remove(sq.members, i)
        sq.queue[#sq.queue + 1] = { key = u.key, at = t + (D.units[u.key].weapon and D.units[u.key].weapon.targets.air and not D.units[u.key].weapon.targets.land and S.REINFORCE / 2 or S.REINFORCE) }
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
        u.squad = sq
        sq.members[#sq.members + 1] = u
        if sq.leader and sq.leader.alive then world:issue(u, { type = "move", x = sq.leader.x, y = sq.leader.y }) end
      end
    end
    local L = sq.leader
    local alive = L and L.alive
    if alive and sq.ability == "overdrive" and sq.on then
      L.hp = L.hp - L.maxhp * 0.015 * dt
      if L.hp <= 1 then L.hp = 1; sq.on = false end
    end
    local moving = alive and L.orders[1] and (L.orders[1].type == "move" or L.orders[1].type == "amove" or L.orders[1].type == "retreat")
    if alive then L.holdFire = (sq.ability == "repair" and sq.on) or nil end
    for _, u in ipairs(sq.members) do
      if u.alive then
        local near = alive and U.dist2(u.x, u.y, L.x, L.y) <= S.RADIUS * S.RADIUS
        local on = near and sq.on
        local ab = sq.ability
        u.sqTaken = (on and ab == "entrench") and 0.65 or nil
        u.sqSpeed = on and ((ab == "entrench" and 0.5) or (ab == "overdrive" and 1.3) or (ab == "smoke" and 0.85)) or nil
        u.sqSight = (on and ab == "spotter") and 1.6 or nil
        u.sqRof = (on and ab == "overdrive") and 1.3 or nil
        u.smoked = (on and ab == "smoke") or nil
        if on and ab == "repair" and not moving and u ~= L and u.hp < u.maxhp then
          u.hp = math.min(u.maxhp, u.hp + u.maxhp * 0.025 * dt); u.healing = 0.3
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
  -- defeat: the HQ is gone
  st.checkT = (st.checkT or 0) - dt
  if st.checkT <= 0 then
    st.checkT = 0.5
    for tt = 1, world.np do
      local tm = world.teams[tt]
      if not tm.dead and not (tm.hq and tm.hq.alive) then
        if os.getenv("PA_SQDBG") then print("SQOUT", tt, math.floor(world.time)) end
        world:eliminate(tt)
      end
    end
  end
end

---------------------------------------------------------------------------
-- The computer's squads

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
  self.useAbility = 0.3 + 0.07 * self.level
  self.profileName = "Squads"
  return self
end

local function squadHp(sq)
  local hp, max = 0, 0
  for _, u in ipairs(sq.members) do if u.alive then hp, max = hp + u.hp, max + u.maxhp end end
  return max > 0 and hp / max or 0, max
end

function AI:update(dt)
  local w = self.world
  if w.over or w.teams[self.team].dead then return end
  self.timer = self.timer - dt
  if self.timer > 0 then return end
  self.timer = self.think
  local tm = w.teams[self.team]
  local hq = tm.hq
  for _, sq in ipairs(S.squadsOf(w, self.team)) do
    local L = sq.leader
    if L and L.alive then
      local frac = squadHp(sq)
      -- nearest enemy to the leader (units first, then their HQ)
      local foe, fd
      for _, o in ipairs(w.entities) do
        if o.alive and o.team and o.team > 0 and w:hostile(o.team, self.team) and (o.def.weapon or o.key == "hq") then
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
      if not sq.healing and foe then
        -- move as one: everyone attack-moves to where the leader is heading
        local tx, ty = foe.x, foe.y
        for _, u in ipairs(sq.members) do
          if u.alive then
            local o = u.orders[1]
            local far = U.dist(u.x, u.y, L.x, L.y) > 320 and u ~= L
            if far then
              if not (o and o.type == "move") then w:issue(u, { type = "move", x = L.x, y = L.y }) end
            elseif not o or (o.type == "amove" and U.dist(o.x, o.y, tx, ty) > 200) or (o.type == "move" and not far) then
              w:issue(u, { type = "amove", x = tx, y = ty })
            end
          end
        end
      end
      -- abilities
      if self.rng:random() < self.useAbility then
        local ab = sq.ability
        local want
        if ab == "entrench" then want = fighting and frac > 0.3
        elseif ab == "spotter" then want = foe and fd < 900
        elseif ab == "smoke" then want = sq.healing or (fighting and frac < 0.6)
        elseif ab == "overdrive" then want = fighting and L.hp > L.maxhp * 0.5
        elseif ab == "repair" then want = (not fighting) and frac < 0.9 and not sq.healing end
        if want ~= nil and (want and true or false) ~= sq.on then S.toggle(w, sq, want and true or false) end
      end
    end
  end
end

return S
