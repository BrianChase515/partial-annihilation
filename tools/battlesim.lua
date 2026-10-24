-- Dev tool: fight simulator for balance. Real game rules, no economy, no AI planning: just the
-- fight, many times over, with a summary at the end. Not shipped.
--   love . --battlesim camp <class|all> [runs] [small|big] [heroLevel]
--       a lone Commander Craft hero against a creep camp (casts its skills on cooldown)
--   love . --battlesim units footman:6 grunt:5 [runs]
--       two groups of units on open ground (team 1 vs team 2)
--   love . --battlesim duels <level> [runs]                 every hero against every other, equal level
--   love . --battlesim army <class|all> <level> <spec> [runs] hero + army vs the same army without a hero
--   love . --battlesim caught <class|all> <level> <spec> [runs] a lone hero meets an army: survive?
-- Heroes are played by the Arena AI's skill logic (the same brain the computer uses).
local U = require("src.util")
local S = {}
local co, startFn, args

local function log(...) print("[battlesim]", ...); io.stdout:flush() end
local function frame() coroutine.yield() end

local CLASSES = { "warden", "ranger", "elementalist", "ascetic", "infiltrator", "juggernaut", "shifter", "hexer", "spiritcaller", "reclaimer" }
local VANGUARD = { warden = true, ranger = true, elementalist = true, ascetic = true, infiltrator = true }

local function newWorld(seed, class, class2)
  local race = (not class or VANGUARD[class]) and "vanguard" or "warband"
  local race2 = (class2 and VANGUARD[class2]) and "vanguard" or "warband"
  local game = startFn({ mode = "craft", size = 88, seed = seed, autotest = true, template = "horseshoe",
    players = { { ally = 1, level = 5, race = race, class = class }, { ally = 2, level = 5, race = race2, class = class2 } } })
  game.ais = {}
  return game, game.world
end

-- the Arena AI's skill brain, aimed at whatever is in front of it
local spot
local function brainFor(w, team, seed)
  local ArenaAI = require("src.arena_ai")
  local b = setmetatable({ world = w, team = team, level = 7, rng = love.math.newRandomGenerator(seed), skillChance = 0.85 },
    { __index = ArenaAI })
  b.nearestEnemyStructure = function() return nil end
  return b
end

local function think(w, h, brain)
  if not h.alive then return end
  brain:trackEnemies()
  local eh, ed
  local n = 0
  for _, o in ipairs(w.entities) do
    if o.alive and o.team and o.team ~= h.team and o.def.weapon and not o.def.building and U.dist(o.x, o.y, h.x, h.y) < 650 then
      n = n + 1
      if o.key == "commander" then
        local d = U.dist(o.x, o.y, h.x, h.y)
        if not ed or d < ed then eh, ed = o, d end
      end
    end
  end
  if h.offers and #h.offers > 0 then brain:pickOffer(h) end
  brain:useSkills(h, eh, n >= 4 or eh ~= nil)
  -- BS_KITE=1: a hero that outranges the enemy keeps it at the edge of its range, like a player would
  if os.getenv("BS_KITE") and not w:isFleeing(h) and (h.kiteT or 0) <= w.time then
    local myR = w:rangeOf(h)
    local m, md
    for _, o in ipairs(w.entities) do
      if o.alive and o.team and o.team ~= h.team and o.def.weapon and not o.def.building then
        local d = U.dist(o.x, o.y, h.x, h.y)
        if d < myR and (not md or d < md) then m, md = o, d end
      end
    end
    if m and w:rangeOf(m) < myR - 25 and md < myR - 30 then
      local dx, dy = U.norm(h.x - m.x, h.y - m.y)
      local back = math.min(140, myR - 15 - md)
      local x, y = spot(w, h.x + dx * back, h.y + dy * back)
      w:issue(h, { type = "move", x = x, y = y })
      w:issue(h, { type = "attack", target = m }, true)
      h.kiteT = w.time + 0.9
    end
  end
end

local function levelUp(w, h, L, brain)
  local A = require("src.arena")
  if L and L > 0 then
    A.commanderXP(w, h, A.THRESHOLDS[L] - (h.cxp or 0))
    for _ = 1, 20 do if h.offers and #h.offers > 0 then brain:pickOffer(h) else break end end
  end
  -- what-if: scale the hero (BS_HDMG=0.7 BS_HHP=0.8)
  local hd, hh = tonumber(os.getenv("BS_HDMG") or ""), tonumber(os.getenv("BS_HHP") or "")
  if hd then h.mods.dmg = (h.mods.dmg or 1) * hd end
  if hh then h.maxhp = math.floor(h.maxhp * hh) end
  local hs = tonumber(os.getenv("BS_HSKILL") or "")
  if hs then h.mods.skillDmg = (h.mods.skillDmg or 1) * hs end
  h.hp = h.maxhp
end

-- clear the small camp nearest the left base and fight there
local function arena(w)
  for _, cp in ipairs(w.craft.camps) do
    for _, u in ipairs(cp.units) do u.alive = false end
  end
  local camp = w.craft.camps[1]
  return camp.x, camp.y
end

function spot(w, x, y)
  local map = w.map
  local tx, ty = map:tileAt(x, y)
  local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("land", a, b) end, 10)
  if nx then return map:center(nx, ny) end
  return x, y
end

local function placeUnits(w, spec, team, cx, cy, dx)
  local list = {}
  local i = 0
  for k, n in spec:gmatch("(%w+):(%d+)") do
    for _ = 1, tonumber(n) do
      i = i + 1
      local x, y = spot(w, cx + dx + (i % 2) * 36 * (dx > 0 and 1 or -1) + math.random(-12, 12), cy - 100 + math.floor((i - 1) / 2) * 44 + math.random(-8, 8))
      list[#list + 1] = w:spawn(k, team, x, y)
    end
  end
  return list
end

local function hpOf(list)
  local s, m = 0, 0
  for _, u in ipairs(list) do m = m + u.maxhp; if u.alive then s = s + u.hp end end
  return s, m
end

local function putHero(w, h, x, y)
  h.x, h.y = spot(w, x, y)
  h.orders, h.path, h.chase = {}, nil, nil
end

-- run until one side is gone (or the clock runs out); heroes think twice a second
local function fight(w, sides, heroes, limit, each)
  local t0 = w.time
  while w.time - t0 < (limit or 90) do
    for _ = 1, 15 do w:update(1 / 30) end
    for _, hb in ipairs(heroes) do think(w, hb[1], hb[2]) end
    if each and each() then break end
    local alive = 0
    for _, side in ipairs(sides) do if hpOf(side) > 0 then alive = alive + 1 end end
    if alive < 2 then break end
  end
  return w.time - t0
end

local function duel(a, b, L, seed)
  local game, w = newWorld(seed, a, b)
  local cx, cy = arena(w)
  local ha, hb = w.teams[1].commander, w.teams[2].commander
  local ba, bb = brainFor(w, 1, seed), brainFor(w, 2, seed + 1)
  levelUp(w, ha, L, ba); levelUp(w, hb, L, bb)
  putHero(w, ha, cx - 220, cy); putHero(w, hb, cx + 220, cy)
  w:issue(ha, { type = "amove", x = cx + 300, y = cy }); w:issue(hb, { type = "amove", x = cx - 300, y = cy })
  local function sideOf(t)
    local l = {}
    for _, e in ipairs(w.entities) do if e.alive and e.team == t and not e.def.building and not e.def.worker and U.dist(e.x, e.y, cx, cy) < 900 then l[#l + 1] = e end end
    return l
  end
  local t = fight(w, { { ha }, { hb } }, { { ha, ba }, { hb, bb } }, 90, function()
    if os.getenv("BS_DBG") then
      local sk = {}
      for i = 1, 4 do if ha.skills[i] then sk[#sk + 1] = ha.skills[i].key end end
      print(string.format("D %.1f %s %d/%d (%s) dist %d  |  %s %d/%d  o=%s chase=%s", w.time, a, ha.hp, ha.maxhp, table.concat(sk, ","),
        U.dist(ha.x, ha.y, hb.x, hb.y), b, hb.hp, hb.maxhp, ha.orders[1] and ha.orders[1].type or "-", ha.chase and ha.chase.key or "-"))
    end
    if not ha.alive or not hb.alive then return true end
    if ha.orders[1] == nil then w:issue(ha, { type = "amove", x = hb.x, y = hb.y }) end
    if hb.orders[1] == nil then w:issue(hb, { type = "amove", x = ha.x, y = ha.y }) end
  end)
  local res = ha.alive and not hb.alive and 1 or (hb.alive and not ha.alive and 0 or 0.5)
  return res, t
end

local function armyFight(cls, L, spec, seed, withHero)
  local game, w = newWorld(seed, cls)
  local cx, cy = arena(w)
  local h = w.teams[1].commander
  local br = brainFor(w, 1, seed)
  levelUp(w, h, L, br)
  w.teams[2].commander.alive = false
  local A = placeUnits(w, spec, 1, cx, cy, -200)
  local B = placeUnits(w, spec, 2, cx, cy, 200)
  local heroes = {}
  if withHero then
    putHero(w, h, cx - 260, cy)
    A[#A + 1] = h
    heroes[1] = { h, br }
  else
    h.alive = false
  end
  for _, u in ipairs(A) do w:issue(u, { type = "amove", x = cx + 400, y = cy }) end
  for _, u in ipairs(B) do w:issue(u, { type = "amove", x = cx - 400, y = cy }) end
  local t = fight(w, { A, B }, heroes, 90)
  local a, am = hpOf(A)
  local b = hpOf(B)
  return (b <= 0 and a > 0) and 1 or ((a <= 0) and 0 or 0.5), a / am, t
end

local function caught(cls, L, spec, seed)
  local game, w = newWorld(seed, cls)
  local cx, cy = arena(w)
  local h = w.teams[1].commander
  local br = brainFor(w, 1, seed)
  levelUp(w, h, L, br)
  w.teams[2].commander.alive = false
  putHero(w, h, cx - 150, cy)
  local B = placeUnits(w, spec, 2, cx, cy, 150)
  local _, bm = hpOf(B)
  for _, u in ipairs(B) do w:issue(u, { type = "amove", x = h.x, y = h.y }) end
  w:issue(h, { type = "amove", x = cx + 300, y = cy })
  local home = { x = w.teams[1].startX, y = w.teams[1].startY }
  local fled = false
  fight(w, { { h }, B }, { { h, br } }, 30, function()
    if not h.alive then return true end
    -- a sensible player runs for home once it's going badly
    if not fled and not os.getenv("BS_NOFLEE") and h.hp < h.maxhp * 0.4 then
      fled = true
      w:issue(h, { type = "retreat", x = home.x, y = home.y })
    end
  end)
  local b = hpOf(B)
  return h.alive and 1 or 0, 1 - b / bm
end

local function castAllOld(w, h)
  local A = require("src.arena")
  if not h.alive or not h.skills then return end
  local best, bd
  for _, o in ipairs(w.entities) do
    if o.alive and o.team ~= h.team and not o.def.building and o.key ~= "goldmine" and o.def.weapon then
      local d = U.dist(h.x, h.y, o.x, o.y)
      if d < 450 and (not bd or d < bd) then best, bd = o, d end
    end
  end
  if not best then return end
  for slot = 1, 4 do
    if h.skills[slot] then A.useSkill(w, h, slot, best.x, best.y) end
  end
end

local function campFight(class, seed, kind, heroLevel)
  local game, w = newWorld(seed, class)
  local h = w.teams[1].commander
  local br = brainFor(w, 1, seed)
  levelUp(w, h, heroLevel, br)
  -- the camp of the requested kind nearest team 1
  local camp, cd
  for _, cp in ipairs(w.craft.camps) do
    local isBig = #cp.units >= 5
    if (kind == "big") == isBig then
      local d = U.dist(cp.x, cp.y, h.x, h.y)
      if not cd or d < cd then camp, cd = cp, d end
    end
  end
  local ang = math.random() * math.pi * 2
  local map = w.map
  local tx, ty = map:tileAt(camp.x + math.cos(ang) * 300, camp.y + math.sin(ang) * 300)
  local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("land", a, b) end, 10)
  h.x, h.y = map:center(nx, ny)
  h.orders, h.path = {}, nil
  w:issue(h, { type = "amove", x = camp.x, y = camp.y })
  local t0 = w.time
  local creepHp0 = 0
  for _, u in ipairs(camp.units) do creepHp0 = creepHp0 + u.maxhp end
  while w.time - t0 < 120 do
    for _ = 1, 15 do w:update(1 / 30) end
    think(w, h, br)
    if os.getenv("BS_DBG") then
      local t = {}
      for _, u in ipairs(camp.units) do t[#t + 1] = string.format("%s:%d:%s:%d", u.key, u.alive and u.hp or 0, u.chase and u.chase.key or "-", math.floor(U.dist(u.x, u.y, h.x, h.y))) end
      print(string.format("T %.1f hero %d  %s", w.time - t0, h.hp, table.concat(t, " ")))
    end
    local alive = 0
    for _, u in ipairs(camp.units) do if u.alive then alive = alive + 1 end end
    if alive == 0 or not h.alive or (h.respawnAt and not h.alive) then break end
    if h.orders[1] == nil then w:issue(h, { type = "amove", x = camp.x, y = camp.y }) end
  end
  local left = 0
  for _, u in ipairs(camp.units) do if u.alive then left = left + u.hp end end
  if os.getenv("BS_DBG") then
    local tm = w.teams[1]
    print("DBG", class, "campdist", math.floor(U.dist(camp.x, camp.y, tm.startX or 0, tm.startY or 0)), "atBase", tostring(h.atBase), "regen", h.def.regen, "maxhp", h.maxhp, "armor", h.def.armor, h.mods and h.mods.hp)
  end
  return { win = h.alive and left <= 0, hp = h.alive and h.hp / h.maxhp or 0, t = w.time - t0, campLeft = left / creepHp0 }
end

local function unitsFight(specA, specB, seed)
  local game, w = newWorld(seed)
  -- a clear patch of ground: the middle of the bottom strip
  local map = w.map
  local cx, cy
  for _, cp in ipairs(w.craft.camps) do
    for _, u in ipairs(cp.units) do u.alive = false end
  end
  local camp = w.craft.camps[1]
  cx, cy = camp.x, camp.y
  local function place(spec, team, dx)
    local list = {}
    for k, n in spec:gmatch("(%w+):(%d+)") do
      for i = 1, tonumber(n) do
        local x, y = cx + dx + math.random(-30, 30), cy - 120 + i * 34 + math.random(-10, 10)
        local tx, ty = map:tileAt(x, y)
        local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("land", a, b) end, 8)
        if nx then x, y = map:center(nx, ny) end
        local u = w:spawn(k, team, x, y)
        list[#list + 1] = u
      end
    end
    return list
  end
  local A = place(specA, 1, -170)
  local B = place(specB, 2, 170)
  for _, u in ipairs(A) do w:issue(u, { type = "amove", x = cx + 300, y = cy }) end
  for _, u in ipairs(B) do w:issue(u, { type = "amove", x = cx - 300, y = cy }) end
  local t0 = w.time
  local function hp(list) local s, m = 0, 0; for _, u in ipairs(list) do m = m + u.maxhp; if u.alive then s = s + u.hp end end; return s, m end
  while w.time - t0 < 120 do
    for _ = 1, 15 do w:update(1 / 30) end
    local a = hp(A); local b = hp(B)
    if a <= 0 or b <= 0 then break end
  end
  local a, am = hp(A)
  local b, bm = hp(B)
  return { win = b <= 0 and a > 0, loss = a <= 0, hp = a / am, hpB = b / bm, t = w.time - t0 }
end

local function run()
  frame()
  -- what-if: scale the creeps (BS_HP=1.2 BS_DMG=1.5)
  local D = require("src.defs")
  local hm, dm = tonumber(os.getenv("BS_HP") or "1"), tonumber(os.getenv("BS_DMG") or "1")
  for _, k in ipairs({ "gnoll", "gnollarcher", "ogrelord" }) do
    D.units[k].hp = math.floor(D.units[k].hp * hm)
    D.units[k].weapon.damage = D.units[k].weapon.damage * dm
  end
  local what = args[1] or "camp"
  if what == "camp" then
    local cls = args[2] or "all"
    local runs = tonumber(args[3]) or 6
    local kind = args[4] or "small"
    local lvl = tonumber(args[5]) or 0
    local list = cls == "all" and CLASSES or { cls }
    for _, c in ipairs(list) do
      local wins, hp, t, left = 0, 0, 0, 0
      for r = 1, runs do
        math.randomseed(r * 7919)
        local res = campFight(c, 9000 + r, kind, lvl)
        if res.win then wins = wins + 1 end
        hp, t, left = hp + res.hp, t + res.t, left + res.campLeft
        frame()
      end
      print(string.format("CAMP %-13s %s L%d  wins %d/%d  hero hp left %3.0f%%  time %4.1fs  camp hp left %3.0f%%",
        c, kind, lvl, wins, runs, 100 * hp / runs, t / runs, 100 * left / runs))
      io.stdout:flush()
    end
  elseif what == "stats" then
    local L = tonumber(args[2]) or 6
    for _, c in ipairs(CLASSES) do
      local game, w = newWorld(9600, c)
      local h = w.teams[1].commander
      levelUp(w, h, L, brainFor(w, 1, 9600))
      local m = h.mods
      local sk = {}
      for i = 1, 4 do if h.skills[i] then sk[#sk + 1] = h.skills[i].key end end
      local ups = {}
      for _, u in ipairs(h.upgrades or {}) do if not u.skill then ups[#ups + 1] = u.key end end
      local wpn = h.def.weapon
      local dps = wpn.damage * (m.dmg or 1) * (m.rof or 1) / wpn.reload
      print(string.format("STAT %-13s L%d hp %5d  dps %5.1f  range %3d  speed %3d  skillDmg %.2f | %s | %s", c, L, h.maxhp, dps,
        w:rangeOf(h), w:speedOf(h), m.skillDmg or 1, table.concat(sk, ","), table.concat(ups, ",")))
      frame()
    end
  elseif what == "duel" then
    print("RESULT", duel(args[2], args[3], tonumber(args[4]) or 6, 9500))
  elseif what == "duels" then
    local L = tonumber(args[2]) or 3
    local runs = tonumber(args[3]) or 4
    local score, games = {}, {}
    local mat = {}
    for _, c in ipairs(CLASSES) do score[c], games[c], mat[c] = 0, 0, {} end
    for i, a in ipairs(CLASSES) do
      for j = i + 1, #CLASSES do
        local b = CLASSES[j]
        local sa = 0
        for r = 1, runs do
          math.randomseed(r * 31 + i * 7 + j)
          local res = duel(a, b, L, 9200 + r * 13 + i * 3 + j)
          sa = sa + res
          frame()
        end
        score[a], score[b] = score[a] + sa, score[b] + runs - sa
        games[a], games[b] = games[a] + runs, games[b] + runs
        mat[a][b], mat[b][a] = sa / runs, 1 - sa / runs
      end
    end
    local order = { unpack(CLASSES) }
    table.sort(order, function(x, y) return score[x] / games[x] > score[y] / games[y] end)
    for _, c in ipairs(order) do
      local row = {}
      for _, o in ipairs(order) do row[#row + 1] = c == o and "  -" or string.format("%3d", math.floor(100 * mat[c][o] + 0.5)) end
      print(string.format("DUEL L%d %-13s %3.0f%%  | %s", L, c, 100 * score[c] / games[c], table.concat(row, " ")))
    end
    print("DUEL columns: " .. table.concat(order, " "))
  elseif what == "army" or what == "caught" then
    local cls = args[2] or "all"
    local L = tonumber(args[3]) or 3
    local spec = args[4] or "footman:4,rifleman:2"
    local runs = tonumber(args[5]) or 6
    local list = cls == "all" and CLASSES or { cls }
    if what == "army" then
      local base = 0
      for r = 1, runs do math.randomseed(r * 17); base = base + armyFight("warden", 0, spec, 9300 + r, false); frame() end
      print(string.format("ARMY baseline (no hero)        wins %3.0f%%", 100 * base / runs))
    end
    for _, c in ipairs(list) do
      local s1, s2 = 0, 0
      for r = 1, runs do
        math.randomseed(r * 17)
        if what == "army" then
          local res, left = armyFight(c, L, spec, 9300 + r, true)
          s1, s2 = s1 + res, s2 + left
        else
          local alive, dealt = caught(c, L, spec, 9400 + r)
          s1, s2 = s1 + alive, s2 + dealt
        end
        frame()
      end
      if what == "army" then
        print(string.format("ARMY %-13s L%d  wins %3.0f%%  own side hp left %3.0f%%", c, L, 100 * s1 / runs, 100 * s2 / runs))
      else
        print(string.format("CAUGHT %-13s L%d  survives %3.0f%%  enemy army destroyed %3.0f%%", c, L, 100 * s1 / runs, 100 * s2 / runs))
      end
      io.stdout:flush()
    end
  else
    local specA, specB = args[2], args[3]
    local runs = tonumber(args[4]) or 10
    local wins, losses, hp, hpB, t = 0, 0, 0, 0, 0
    for r = 1, runs do
      math.randomseed(r * 104729)
      local res = unitsFight(specA, specB, 9100 + r)
      if res.win then wins = wins + 1 end
      if res.loss then losses = losses + 1 end
      hp, hpB, t = hp + res.hp, hpB + res.hpB, t + res.t
      frame()
    end
    print(string.format("UNITS %s vs %s: A wins %d, B wins %d, draws %d of %d | A hp left %3.0f%%  B hp left %3.0f%%  time %4.1fs",
      specA, specB, wins, losses, runs - wins - losses, runs, 100 * hp / runs, 100 * hpB / runs, t / runs))
  end
  log("DONE")
end

function S.start(fn, a)
  startFn, args = fn, a
  co = coroutine.create(run)
end

function S.update()
  if coroutine.status(co) == "dead" then love.event.quit(); return end
  local ok, err = coroutine.resume(co)
  if not ok then error(err .. "\n" .. debug.traceback(co)) end
end

function S.afterDraw() end

return S
