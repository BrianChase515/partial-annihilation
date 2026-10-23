-- Game modifiers (toggled on the title screen, can run together):
--   Alien Tech: a dormant alien walker lands near the middle of the map; hold its zone
--               for 15 seconds with no enemies inside to claim it. Repeats after a capture.
--   Score mode: points for kills/building/progress, kill-streak multipliers, a live
--               leaderboard and a 25-minute clock (highest score wins).
local U = require("src.util")
local D = require("src.defs")

local M = {}

M.ALIEN_RADIUS = 260
M.ALIEN_HOLD = 15
M.ALIEN_FIRST = 300      -- first landing (seconds)
M.ALIEN_WARN = 60        -- announced this long before landing
M.ALIEN_REPEAT = 300     -- next landing this long after a capture
M.STREAK_WINDOW = 10     -- multiplier holds until 10s pass with no enemy deaths...
M.STREAK_WINDOW_MIN = 5  -- ...and the window shrinks as the streak grows (1s per 10 kills, down to 5s)
M.STREAK_STEP = 0.1
M.STREAK_MAX = 3

function M.streakWindow(sc)
  return math.max(M.STREAK_WINDOW_MIN, M.STREAK_WINDOW - (sc.streak or 0) * 0.1)
end

M.DROP_FIRST = 180
M.DROP_EVERY = 150
M.DROP_SIGHT = 380
M.FLIP_TIME = 2.6           -- suspense pause (real seconds) when YOU meet a drop crew

function M.init(world, mods)
  world.mods = mods or {}
  world.ally[0] = 0    -- neutral: dormant walker, undecided drop crews
  world.ally[-1] = -1  -- marauders: drop crews that chose violence (hostile to everyone)
  for _, t in ipairs({ 0, -1 }) do
    world.teams[t] = { id = t, lastAttacked = -100, metal = 0, energy = 0, mStore = 1, eStore = 1, dead = false,
      startX = world.map.w * world.map.T / 2, startY = world.map.h * world.map.T / 2 }
  end
  if world.mods.drops then
    world.drops = { nextAt = M.DROP_FIRST, squads = {}, count = 0 }
  end
  if world.mods.alien then
    world.alien = { state = "waiting", arriveAt = M.ALIEN_FIRST, captures = 0 }
  end
  -- Score runs in every game. It is "official" (high-score table, online board) only when
  -- no gameplay modifiers are on; Groovy is cosmetic so it doesn't count.
  world.official = not (world.mods.alien or world.mods.drops)
  do
    world.score = {}
    for t = 1, world.np do
      world.score[t] = { pts = 0, streak = 0, mult = 1, last = -99,
        killPts = 0, streakPts = 0, buildPts = 0, cmdPts = 0,
        kills = 0, bldKills = 0, cmdKills = 0, bestStreak = 0, bestMult = 1, built = 0, lost = 0 }
    end
    -- par time (from the human's side): bigger maps take longer, and so do more enemies -
    -- +4 min for each extra enemy teamed up with another, +3 min for each extra free-for-all
    -- side (they thin each other out), -2 min for each computer ally
    local size = world.map.w
    local par = (size <= 96 and 10) or (size <= 128 and 13) or 17
    local groups, allies = {}, 0
    for t = 2, world.np do
      if world:hostile(t, 1) then
        local a = world.ally[t]
        groups[a] = (groups[a] or 0) + 1
      else allies = allies + 1 end
    end
    local sides = 0
    for _, n in pairs(groups) do
      sides = sides + 1
      par = par + 4 * (n - 1)
    end
    par = par + 3 * math.max(0, sides - 1) - 2 * allies
    world.parTime = math.max(6, par) * 60
  end
end

---------------------------------------------------------------------------
-- Alien Tech

-- Somewhere near the middle, nudged at most 15% of the way toward a random base
function M.pickAlienSpot(world)
  local map = world.map
  local T = map.T
  local cx, cy = map.w * T / 2, map.h * T / 2
  local rng = world.rngCmd
  local t = rng:random(1, world.np)
  local s = world.teams[t]
  local f = rng:random() * 0.15
  local x = cx + (s.startX - cx) * f + (rng:random() - 0.5) * 3 * T
  local y = cy + (s.startY - cy) * f + (rng:random() - 0.5) * 3 * T
  -- land tile that player 1's start can walk to (every base can on these maps)
  local c1 = world.teams[1]
  local tx, ty = map:tileAt(x, y)
  local nx, ny = map:nearestTile(tx, ty, function(xx, yy)
    return map:passable("land", xx, yy) and map:canReach("land", c1.startX, c1.startY, (xx + 0.5) * T, (yy + 0.5) * T, 0)
  end, 30)
  if not nx then nx, ny = tx, ty end
  return map:center(nx, ny)
end

function M.updateAlien(world, dt)
  local a = world.alien
  if not a then return end
  local t = world.time
  if a.state == "waiting" and t >= a.arriveAt - M.ALIEN_WARN then
    a.x, a.y = M.pickAlienSpot(world)
    a.state = "announced"
    if world.onAlien then world.onAlien("announce", a) end
  elseif a.state == "announced" and t >= a.arriveAt then
    local e = world:spawn("walker", 0, a.x, a.y)
    e.dormant = true
    e.angle = math.pi / 2
    a.entity = e
    a.state = "dormant"
    a.holder, a.progress = nil, 0
    world.effects[#world.effects + 1] = { kind = "nuke", x = a.x, y = a.y, t = 0, life = 1.0, size = 90 }
    if world.onAlien then world.onAlien("land", a) end
  elseif a.state == "dormant" then
    a.tick = (a.tick or 0) + dt
    if a.tick < 0.25 then return end
    local step = a.tick
    a.tick = 0
    -- who has armed units in the zone?
    local count, byTeam = {}, {}
    local allies = 0
    world:query(a.x, a.y, M.ALIEN_RADIUS + 30, function(u)
      if u.alive and u.team > 0 and not u.def.building and u.def.weapon and u.built >= 1 and not u.disarmed
        and not world.teams[u.team].dead and U.dist2(u.x, u.y, a.x, a.y) <= M.ALIEN_RADIUS * M.ALIEN_RADIUS then
        local al = world.ally[u.team]
        if not count[al] then count[al] = 0; allies = allies + 1 end
        count[al] = count[al] + 1
        byTeam[u.team] = (byTeam[u.team] or 0) + 1
      end
    end)
    a.contested = allies > 1
    if allies == 1 then
      local al = next(count)
      if a.holder ~= al then a.holder, a.progress = al, 0 end
      a.progress = a.progress + step
      if a.progress >= M.ALIEN_HOLD then
        -- the player in that alliance with the most units in the zone gets it
        local best, bn
        for team, n in pairs(byTeam) do
          if world.ally[team] == al and (not bn or n > bn) then best, bn = team, n end
        end
        local e = a.entity
        e.team = best
        e.dormant = nil
        e.homeX, e.homeY = e.x, e.y
        e.seen = {}
        a.state = "waiting"
        a.captures = a.captures + 1
        a.arriveAt = t + M.ALIEN_REPEAT
        a.entity = nil
        a.lastOwner = best
        world.effects[#world.effects + 1] = { kind = "levelup", x = e.x, y = e.y, t = 0, life = 1.5, size = 80 }
        M.addPoints(world, best, 1500, false)
        if world.onAlien then world.onAlien("claim", a, best) end
      end
    end
    if a.entity and not a.entity.alive then
      -- shouldn't happen (dormant is untargetable), but don't get stuck
      a.state, a.arriveAt = "waiting", t + M.ALIEN_REPEAT
    end
  end
end

---------------------------------------------------------------------------
-- Alien Dropships: neutral crews that wander until they meet someone,
-- then flip a coin: join that player, or attack.

local CREW = { "scout", "tank", "tank", "artillery", "flak", "tank" }

function M.updateDrops(world, dt)
  local d = world.drops
  if not d then return end
  local t = world.time
  local rng = world.rngCmd
  if t >= d.nextAt then
    d.nextAt = t + M.DROP_EVERY
    local x, y = M.pickAlienSpot(world)
    local sq = { units = {}, state = "wander", x = x, y = y, id = d.count + 1 }
    d.count = d.count + 1
    local n = rng:random(3, 5)
    for i = 1, n do
      local key = CREW[rng:random(#CREW)]
      local u = world:spawn(key, 0, x + math.cos(i * 1.7) * 40, y + math.sin(i * 1.7) * 40)
      u.neutral = true
      u.homeX, u.homeY = u.x, u.y
      sq.units[#sq.units + 1] = u
    end
    d.squads[#d.squads + 1] = sq
    world.effects[#world.effects + 1] = { kind = "dropship", x = x, y = y, t = 0, life = 2.5, size = 60 }
    if world.onDrop then world.onDrop(sq) end
  end
  d.tick = (d.tick or 0) + dt
  if d.tick < 0.5 then return end
  d.tick = 0
  local keep = {}
  for _, sq in ipairs(d.squads) do
    local alive = {}
    for _, u in ipairs(sq.units) do if u.alive then alive[#alive + 1] = u end end
    sq.units = alive
    if #alive > 0 then
      keep[#keep + 1] = sq
      if sq.state == "wander" then M.wanderOrEncounter(world, sq)
      elseif sq.state == "hostile" then M.maraud(world, sq) end
    end
  end
  d.squads = keep
end

function M.wanderOrEncounter(world, sq)
  local rng = world.rngCmd
  -- anyone (a real player) in sight?
  local met
  for _, u in ipairs(sq.units) do
    world:query(u.x, u.y, M.DROP_SIGHT, function(o)
      if not met and o.alive and o.team > 0 and not world.teams[o.team].dead and U.dist2(u.x, u.y, o.x, o.y) < M.DROP_SIGHT ^ 2 then
        met = o.team
      end
    end)
    if met then break end
  end
  if met then
    sq.team = met
    sq.result = rng:random() < 0.5 and "join" or "attack"
    sq.state = "pending"
    for _, u in ipairs(sq.units) do u.orders, u.path = {}, nil end
    -- the human player gets a suspenseful coin flip; computers decide instantly
    local waitForUI = world.onDropEncounter and world.onDropEncounter(sq)
    if not waitForUI then M.applyDrop(world, sq) end
    return
  end
  -- keep wandering around the middle of the map
  local lead = sq.units[1]
  if #lead.orders == 0 then
    local map = world.map
    local T = map.T
    local cx, cy = map.w * T / 2, map.h * T / 2
    local r = map.w * T * 0.3
    for _ = 1, 10 do
      local x, y = cx + (rng:random() - 0.5) * 2 * r, cy + (rng:random() - 0.5) * 2 * r
      local tx, ty = map:tileAt(x, y)
      if map:passable("land", tx, ty) and map:canReach("land", lead.x, lead.y, x, y, 0) then
        for i, u in ipairs(sq.units) do
          world:issue(u, { type = "move", x = x + math.cos(i * 2.1) * 36, y = y + math.sin(i * 2.1) * 36 })
        end
        break
      end
    end
  end
end

-- Resolve an encounter: they join the player they met, or turn hostile and attack
function M.applyDrop(world, sq)
  for _, u in ipairs(sq.units) do
    if u.alive then
      u.neutral = nil
      u.orders, u.path, u.chase = {}, nil, nil
      u.homeX, u.homeY = u.x, u.y
      u.seen = {}
      if sq.result == "join" then u.team = sq.team else u.team = -1 end
    end
  end
  if sq.result == "join" then
    sq.state = "joined"
  else
    sq.state = "hostile"
    sq.target = sq.team
    M.maraud(world, sq)
  end
  if world.onDropResolved then world.onDropResolved(sq) end
end

-- Hostile crews hunt the player they met first, then anyone
function M.maraud(world, sq)
  for _, u in ipairs(sq.units) do
    if u.alive and #u.orders == 0 then
      local best, bd
      for _, e in ipairs(world.entities) do
        if e.alive and e.team > 0 and not world.teams[e.team].dead and (e.team == sq.target or not best) then
          local dd = U.dist2(u.x, u.y, e.x, e.y) * (e.team == sq.target and 1 or 4)
          if not bd or dd < bd then best, bd = e, dd end
        end
      end
      if best then world:issue(u, { type = "amove", x = best.x, y = best.y }) end
    end
  end
end

---------------------------------------------------------------------------
-- Score

function M.addPoints(world, team, pts, streaky, kind)
  local sc = world.score and world.score[team]
  if not sc or not team or team < 1 then return end
  if streaky then
    if world.time - sc.last > M.streakWindow(sc) then sc.streak = 0 end
    sc.streak = sc.streak + 1
    sc.mult = math.min(M.STREAK_MAX, 1 + M.STREAK_STEP * (sc.streak - 1))
    sc.last = world.time
    sc.bestStreak = math.max(sc.bestStreak, sc.streak)
    sc.bestMult = math.max(sc.bestMult, sc.mult)
    sc.killPts = sc.killPts + pts
    sc.streakPts = sc.streakPts + pts * (sc.mult - 1)
    pts = pts * sc.mult
  elseif kind == "build" then sc.buildPts = sc.buildPts + pts
  elseif kind == "cmd" then sc.cmdPts = sc.cmdPts + pts end
  sc.pts = sc.pts + pts
end

function M.onKill(world, o, attacker)
  if not world.score or not attacker or not attacker.team or attacker.team < 1 then return end
  if o.team == 0 or not world:hostile(attacker.team, o.team) then return end
  if world.arena and not (attacker.key == "commander" or attacker.owner or o.arenaTower) then return end -- creeps' own fights don't score
  -- worth = metal + a tenth of the energy (towers and plants are mostly energy)
  local c = o.def.cost
  local v = c and ((c.metal or 0) + (c.energy or 0) / 10) or 50
  if o.key == "commander" then v = world.arena and 800 or 3000 end
  v = v * (1 + 0.1 * ((o.key == "commander" and o.clevel) or o.level or 0))
  if o.general then v = v * 3 end
  if o.def.building then
    -- siege bonus: cracking towers, AA and sea batteries is real work
    if o.def.weapon and not world.arena then v = v * 1.5 else v = v * 0.75 end
  end
  local sc = world.score[attacker.team]
  if o.key == "commander" then sc.cmdKills = sc.cmdKills + 1
  elseif o.def.building then sc.bldKills = sc.bldKills + 1
  else sc.kills = sc.kills + 1 end
  M.addPoints(world, attacker.team, v, true)
end

function M.onBuilt(world, b)
  if b.def.cost and world.score and world.score[b.team] then
    world.score[b.team].built = world.score[b.team].built + 1
    M.addPoints(world, b.team, b.def.cost.metal * 0.1, false, "build")
  end
end

function M.onCommanderLevel(world, e)
  M.addPoints(world, e.team, 150 * (e.clevel or 1), false, "cmd")
end

function M.updateScore(world, dt)
  if not world.score then return end
  for t = 1, world.np do
    local sc = world.score[t]
      if world.time - sc.last > M.streakWindow(sc) then sc.streak, sc.mult = 0, 1 end
  end
end

-- End-of-game score:
--   points x difficulty x opposition x time-vs-par
-- difficulty: average enemy level (5 = x1.25, 10 = x2.0)
-- opposition: how many enemies, whether they are teamed up (a 1v2 is much harder than a
--   3-way free-for-all where the two computers also fight each other), and how much help
--   you had from computer allies
-- time: par / your time (half par = x2, up to x3); slower = down to x0.5; a loss is a flat x0.75
-- levels[t] = AI level of team t
function M.finalScore(world, team, levels)
  local sc = world.score[team]
  local enemies, allies, groups = 0, 0, {}
  local sum = 0
  for t = 1, world.np do
    if t ~= team then
      if world:hostile(t, team) then
        enemies = enemies + 1
        sum = sum + (levels[t] or 5)
        local a = world.ally[t]
        groups[a] = (groups[a] or 0) + 1
      else
        allies = allies + 1
      end
    end
  end
  local avg = enemies > 0 and sum / enemies or 5
  local diffMul = 0.5 + 0.15 * avg
  local strengths = {}
  for _, n in pairs(groups) do strengths[#strengths + 1] = 1 + 0.6 * (n - 1) end
  table.sort(strengths, function(a, b) return a > b end)
  local opp = strengths[1] or 1
  for i = 2, #strengths do opp = opp + 0.35 * strengths[i] end
  opp = opp / (1 + 0.5 * allies)
  local won = world.over and world.over.winnerAlly == world.ally[team]
  local dev = (world.parTime - world.time) / world.parTime  -- +0.5 = finished in half the par time
  -- winning in half the par time doubles your score, a third triples it (the cap); slow wins fade to x0.5
  local timeMul = won and math.max(0.5, math.min(3.0, world.parTime / math.max(1, world.time))) or 0.75
  local total = math.floor(sc.pts * diffMul * opp * timeMul)
  return total, {
    pts = sc.pts, diffMul = diffMul, avgLevel = avg, oppMul = opp, timeMul = timeMul, won = won,
    enemies = enemies, allies = allies, enemyTeams = #strengths, dev = dev, total = total,
  }
end

-- ranking rows for the leaderboard
function M.ranking(world)
  local rows = {}
  for t = 1, world.np do
    local sc = world.score[t]
    rows[#rows + 1] = { team = t, pts = sc.pts, mult = sc.mult, ally = world.ally[t], dead = world.teams[t].dead }
  end
  table.sort(rows, function(a, b) return a.pts > b.pts end)
  return rows
end

return M
