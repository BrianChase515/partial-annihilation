-- Dev tool: fight simulator for balance. Real game rules, no economy, no AI planning: just the
-- fight, many times over, with a summary at the end. Not shipped.
--   love . --battlesim camp <class|all> [runs] [small|big] [heroLevel]
--       a lone Commander Craft hero against a creep camp (casts its skills on cooldown)
--   love . --battlesim units footman:6 grunt:5 [runs]
--       two groups of units on open ground (team 1 vs team 2)
local U = require("src.util")
local S = {}
local co, startFn, args

local function log(...) print("[battlesim]", ...); io.stdout:flush() end
local function frame() coroutine.yield() end

local CLASSES = { "warden", "ranger", "elementalist", "ascetic", "infiltrator", "juggernaut", "shifter", "hexer", "spiritcaller", "reclaimer" }
local VANGUARD = { warden = true, ranger = true, elementalist = true, ascetic = true, infiltrator = true }

local function newWorld(seed, class)
  local race = (not class or VANGUARD[class]) and "vanguard" or "warband"
  local game = startFn({ mode = "craft", size = 88, seed = seed, autotest = true, template = "horseshoe",
    players = { { ally = 1, level = 5, race = race, class = class }, { ally = 2, level = 5, race = "warband" } } })
  game.ais = {}
  return game, game.world
end

local function castAll(w, h)
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
  local A = require("src.arena")
  local h = w.teams[1].commander
  if heroLevel and heroLevel > 0 then
    A.commanderXP(w, h, A.THRESHOLDS[heroLevel])
    while h.offers and #h.offers > 0 do w:chooseUpgrade(h, 1) end
  end
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
    castAll(w, h)
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
