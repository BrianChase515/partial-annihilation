-- Dev tool: the AI tournament. Plays many computer-vs-computer games at full speed, turns each
-- side of each game into a behaviour fingerprint (src/telemetry.lua) and reports:
--   * results: who wins, how long games last, how many stall
--   * variety: how different the games are from each other (and how many are near-repeats)
--   * balance: win rates by difficulty / profile / army make-up
--   love . --tourney <coh|wih|rts> [games] [level2|mix] [level1|mix] [fixed]
-- "fixed" replays the same map, armies and levels every game, so any difference between games
-- comes from the AI alone (the honest variety number); otherwise maps, armies and levels vary.
-- Writes tourney_<mode>.csv (one row per side per game) to the save folder. Not shipped.
local Tel = require("src.telemetry")
local U = require("src.util")
local S = {}
local co, startFn, args

local function log(...) print("[tourney]", ...); io.stdout:flush() end
local function frame() coroutine.yield() end

local CAP = { coh = 900, wih = 600, rts = 1500 }

local function levelFor(spec, rng)
  if spec == "mix" or not spec then return rng:random(3, 9) end
  return tonumber(spec) or 5
end

local function newGame(mode, seed, l1, l2, rng)
  if mode == "rts" then
    return startFn({ size = tonumber(os.getenv("PA_SIZE") or "112"), water = tonumber(os.getenv("PA_WATER") or "0.3"),
      seed = tonumber(os.getenv("PA_MAPSEED") or "") or seed, autotest = true, level = l2, level1 = l1,
      profile = "Random", profile1 = "Random", aiV2Teams = { [1] = S.v2both, [2] = S.v2 or S.v2both } })
  end
  local SQ = require("src.squads")
  local nSq = rng:random(3, 5)
  local game = startFn({ mode = "rts", coh = true, size = mode == "wih" and 128 or 96, water = 0.15, seed = seed,
    mods = { squads = true }, autotest = true, cohMode = mode == "wih" and "wih" or "conquest",
    hillFrac = mode == "wih" and 0.22 or nil, rockFrac = mode == "wih" and 0.06 or nil,
    squadSetup = SQ.randomSquads(rng, nSq), enemySquads = "own",
    players = { { ally = 1, level = l1, aiV2 = S.v2both }, { ally = 2, level = l2, aiV2 = S.v2 or S.v2both } } })
  return game
end

-- the scalar features we compare games on (per side)
local BASE = { "firstContact", "length", "groups", "groupsVar", "coverage", "spread", "fromHome", "killRange",
  "earlyFwd", "earlySide", "midFwd", "midSide", "decisionRate" }

local function features(w, t)
  local f = Tel.fingerprint(w, t)
  local tm = w.teams[t]
  local W, H = w.map.w * w.T, w.map.h * w.T
  f.fromHome = U.dist(f.cx * W, f.cy * H, tm.startX or 0, tm.startY or 0) / math.sqrt(W * W + H * H)
  return f
end

local function run()
  frame()
  local mode = args[1] or "coh"
  -- experiments (never shipped by themselves):
  --   PA_RULES=towers,structguns,cmdhp   towers x2.5 vs Commanders; every structure a small gun;
  --                                      Commander 15% less health
  local rules = os.getenv("PA_RULES") or ""
  do
    local D = require("src.defs")
    if rules:find("towers") then D.towerVsCmd = 2.5 end
    if rules:find("unarmed") then
      -- (back to the old rules: structures without guns, towers normal against Commanders)
      for _, k in ipairs({ "mex", "solar", "storage", "landfac", "airfac", "shipyard" }) do D.units[k].weapon = nil end
      D.TOWER_VS_COMMANDER = nil
    end
    if rules:find("structguns") then
      local light = { damage = 7, range = 170, reload = 0.7, speed = 600, minRange = 0, splash = 0, targets = { land = true, sea = true } }
      local plant = { damage = 16, range = 230, reload = 0.6, speed = 600, minRange = 0, splash = 0, targets = { land = true, sea = true } }
      for _, k in ipairs({ "mex", "solar", "storage" }) do D.units[k].weapon = light end
      for _, k in ipairs({ "landfac", "airfac" }) do D.units[k].weapon = plant end
    end
    if rules:find("cmdhp") then D.units.commander.hp = math.floor(D.units.commander.hp * 0.85) end
    if rules ~= "" then log("rules:", rules) end
  end
  -- (experiment: PA_CMDHP=1.5 scales the Annihilation Commander's health)
  if os.getenv("PA_CMDHP") then
    local D = require("src.defs")
    D.units.commander.hp = math.floor(D.units.commander.hp * tonumber(os.getenv("PA_CMDHP")))
  end
  local n = tonumber(args[2]) or 20
  local rng = love.math.newRandomGenerator(os.time())
  -- "v2": side 2 plays AI v2 against v1 on side 1; "v2both": both sides v2
  local v2, v2both = false, false
  for k = #args, 1, -1 do
    if args[k] == "v2" then v2 = true; table.remove(args, k) elseif args[k] == "v2both" then v2both = true; table.remove(args, k) end
  end
  S.v2, S.v2both = v2, v2both
  local fixed = args[5] == "fixed" or args[3] == "fixed"
  if args[3] == "fixed" then args[3] = nil end
  local rows = {}
  local t0 = love.timer.getTime()
  for g = 1, n do
    local seed = fixed and 7037 or (7000 + g * 37)
    local grng = fixed and love.math.newRandomGenerator(99) or rng
    local l1, l2 = levelFor(args[4], grng), levelFor(args[3], grng)
    -- (the AI's own dice still differ from game to game)
    love.math.setRandomSeed(os.time() + g * 7919)
    math.randomseed(os.time() + g * 104729)
    local game = newGame(mode, seed, l1, l2, grng)
    local w = game.world
    local steps = 0
    while not w.over and w.time < CAP[mode] do
      w:update(1 / 30)
      for _, ai in ipairs(game.ais) do ai:update(1 / 30) end
      steps = steps + 1
      if os.getenv("PA_CMDDBG") and steps % 90 == 0 then
        local parts = {}
        for i, ai in ipairs(game.ais) do
          local c = w.teams[ai.team].commander
          local tm = w.teams[ai.team]
          parts[#parts + 1] = string.format("T%d %s L%d hp%d%% home%d dng%d sup%d", ai.team, tostring(ai.cmdMode), c and c.clevel or -1,
            c and math.floor(c.hp / c.maxhp * 100) or 0, c and math.floor(U.dist(c.x, c.y, tm.startX, tm.startY)) or 0,
            c and math.floor(ai:strengthNear(c.x, c.y, 450, true)) or 0, c and math.floor(ai:strengthNear(c.x, c.y, 450, false)) or 0)
        end
        print(string.format("CMD %4ds  %s", math.floor(w.time), table.concat(parts, " | ")))
      end
      if steps % 1500 == 0 then frame() end
    end
    local winner = w.over and w.over.winnerAlly or 0
    if os.getenv("PA_CORELOG") then
      local who = "nobody"
      for _, e in ipairs(w.entities) do if e.alive and e.key == "powercore" then who = "team " .. e.team .. (e.built >= 1 and "" or " (unfinished)") end end
      local ships = 0
      for _, e in ipairs(w.entities) do if e.alive and (e.def.domain == "sea" or e.def.domain == "sub") then ships = ships + 1 end end
      log(string.format("   power core: %s; ships afloat at the end: %d", who, ships))
    end
    -- how it ended: who killed each Commander, and what the dead one was doing
    local ends = {}
    for _, r in ipairs(w.tel.kills) do
      if r.vk == "commander" then
        local ai
        for _, a in ipairs(game.ais) do if a.team == r.vt then ai = a end end
        ends[#ends + 1] = string.format("T%d cmd killed by %s at %ds (mode %s)", r.vt, tostring(r.ak), math.floor(r.t), ai and tostring(ai.cmdMode) or "?")
      end
    end
    if os.getenv("PA_NOTES") then
      for _, nt in ipairs(w.tel.notes) do print(string.format("  [%4ds] T%s %-11s %s", math.floor(nt.t), tostring(nt.team), nt.kind, nt.text or "")) end
    end
    for t = 1, math.min(2, w.np) do
      local f = features(w, t)
      local who = game.players[t] and (game.players[t].profileName or "?") or "?"
      local comp = {}
      if w.squads then
        for _, sq in ipairs(require("src.squads").squadsOf(w, t)) do comp[#comp + 1] = sq.type end
        table.sort(comp)
      end
      rows[#rows + 1] = { game = g, team = t, level = t == 1 and l1 or l2, profile = who, comp = table.concat(comp, "+"),
        won = (winner == w.ally[t]) and 1 or 0, over = w.over and 1 or 0, f = f }
    end
    if #ends > 0 then log("   " .. table.concat(ends, "; ")) end
    log(string.format("game %d/%d  L%d vs L%d  [%s | %s]  %s  %ds  (%.0fs real)", g, n, l1, l2,
      game.players[1].profileName or "?", game.players[2] and game.players[2].profileName or "?",
      w.over and ("winner side " .. winner) or "no winner", math.floor(w.time), love.timer.getTime() - t0))
  end
  -- every damage type that turned up becomes a feature too (its share of the side's damage)
  local keys = {}
  for _, r in ipairs(rows) do for k in pairs(r.f.dmgShare or {}) do keys[k] = true end end
  local dmgKeys = {}
  for k in pairs(keys) do dmgKeys[#dmgKeys + 1] = k end
  table.sort(dmgKeys)
  local names = {}
  for _, k in ipairs(BASE) do names[#names + 1] = k end
  for _, k in ipairs(dmgKeys) do names[#names + 1] = "dmg_" .. k end
  local function vec(r)
    local v = {}
    for _, k in ipairs(BASE) do v[#v + 1] = r.f[k] or 0 end
    for _, k in ipairs(dmgKeys) do v[#v + 1] = (r.f.dmgShare or {})[k] or 0 end
    return v
  end
  -- CSV
  local out = { "game,team,level,profile,comp,won,over," .. table.concat(names, ",") }
  for _, r in ipairs(rows) do
    local v = vec(r)
    local cells = {}
    for i, x in ipairs(v) do cells[i] = string.format("%.3f", x) end
    out[#out + 1] = string.format("%d,%d,%d,%s,%s,%d,%d,%s", r.game, r.team, r.level, r.profile, r.comp, r.won, r.over, table.concat(cells, ","))
  end
  love.filesystem.write("tourney_" .. mode .. ".csv", table.concat(out, "\n"))
  -- variety: every feature divided by a fixed "meaningful difference" (so runs can be compared
  -- with each other: 1.0 = typically one meaningful step apart on each feature)
  local SCALE = { firstContact = 60, length = 300, groups = 1, groupsVar = 0.5, coverage = 0.25, spread = 0.2,
    fromHome = 0.15, killRange = 100, earlyFwd = 0.06, earlySide = 0.06, midFwd = 0.06, midSide = 0.06, decisionRate = 2 }
  local V = {}
  for i, r in ipairs(rows) do V[i] = vec(r) end
  local dims = #names
  local mean, sd = {}, {}
  for d = 1, dims do
    local s2 = 0
    for i = 1, #V do s2 = s2 + V[i][d] end
    mean[d] = s2 / math.max(1, #V)
    local q = 0
    for i = 1, #V do q = q + (V[i][d] - mean[d]) ^ 2 end
    sd[d] = math.sqrt(q / math.max(1, #V - 1))
  end
  local Z = {}
  for i = 1, #V do
    Z[i] = {}
    for d = 1, dims do Z[i][d] = V[i][d] / (SCALE[names[d]] or 0.25) end
  end
  local function dist(a, b)
    local s = 0
    for d = 1, dims do s = s + (a[d] - b[d]) ^ 2 end
    return math.sqrt(s / dims)
  end
  local sum, cnt, nn, close = 0, 0, {}, 0
  for i = 1, #Z do
    local best = math.huge
    for j = 1, #Z do
      if i ~= j then
        local d = dist(Z[i], Z[j])
        if j > i then sum, cnt = sum + d, cnt + 1 end
        if d < best then best = d end
      end
    end
    nn[i] = best
    if best < 0.4 then close = close + 1 end
  end
  table.sort(nn)
  print("")
  print(string.format("TOURNEY %s: %d games, %d sides%s", mode, n, #rows, fixed and " (same map, armies and levels every game)" or ""))
  local overN, len = 0, 0
  for _, r in ipairs(rows) do if r.team == 1 then overN = overN + r.over; len = len + r.f.length end end
  print(string.format("  finished %d/%d, average length %d:%02d", overN, n, math.floor(len / n / 60), math.floor(len / n % 60)))
  print(string.format("  VARIETY: mean distance between sides %.2f, median nearest-neighbour %.2f, near-repeats %d/%d (%.0f%%)",
    cnt > 0 and sum / cnt or 0, nn[math.ceil(#nn / 2)] or 0, close, #rows, 100 * close / math.max(1, #rows)))
  print("  (distance: 1.0 = about one meaningful step apart on every feature; under 0.4 = a near-repeat of another game)")
  print("  feature spread (mean +/- sd):")
  for d = 1, dims do print(string.format("    %-16s %8.2f +/- %.2f", names[d], mean[d], sd[d])) end
  -- balance: win rate by level, profile and make-up
  local function table_by(key)
    local agg = {}
    for _, r in ipairs(rows) do
      if r.over == 1 then
        local k = tostring(r[key])
        agg[k] = agg[k] or { w = 0, n = 0 }
        agg[k].w, agg[k].n = agg[k].w + r.won, agg[k].n + 1
      end
    end
    local ks = {}
    for k in pairs(agg) do ks[#ks + 1] = k end
    table.sort(ks)
    print("  win rate by " .. key .. ":")
    for _, k in ipairs(ks) do print(string.format("    %-28s %3d%%  (%d)", k, math.floor(100 * agg[k].w / agg[k].n + 0.5), agg[k].n)) end
  end
  table_by("level")
  if mode == "rts" or S.v2 then table_by("profile") end
  -- how fast each kind of AI gets an army out
  do
    local agg = {}
    for _, r in ipairs(rows) do
      local k = (r.profile or "?"):find("Rush") and "Rush" or ((r.profile or "?"):find("v2") and "v2" or "classic")
      agg[k] = agg[k] or { a3 = 0, a6 = 0, n = 0, w = 0, d = 0 }
      local a = agg[k]
      a.a3, a.a6, a.n = a.a3 + (r.f.army3 or 0), a.a6 + (r.f.army6 or 0), a.n + 1
      a.c = (a.c or 0) + (r.f.centre or 0); a.cl = (a.cl or 0) + (r.f.cmdLevel or 0)
      local navy = 0
      for k2, v in pairs(r.f.dmgShare or {}) do if k2 == "boat" or k2 == "destroyer" or k2 == "sub" or k2 == "battleship" then navy = navy + v end end
      a.nv = (a.nv or 0) + navy
      local air = 0
      for k2, v in pairs(r.f.dmgShare or {}) do if k2 == "gunship" or k2 == "bomber" or k2 == "fighter" then air = air + v end end
      a.air = (a.air or 0) + air
      a.rd = (a.rd or 0) + ((r.f.decisions or {}).raid or 0)
      a.n6 = (a.n6 or 0) + (r.f.navy6 or 0)
      a.fc = (a.fc or 0) + (r.f.firstContact or 0)
      a.f3, a.f6, a.b3, a.i3, a.i6 = (a.f3 or 0) + (r.f.fac3 or 0), (a.f6 or 0) + (r.f.fac6 or 0), (a.b3 or 0) + (r.f.bank3 or 0),
        (a.i3 or 0) + (r.f.inc3 or 0), (a.i6 or 0) + (r.f.inc6 or 0)
      a.len = (a.len or 0) + (r.f.length or 0)
      a.nm = (a.nm or 0) + (r.f.navyMax or 0)
      if r.f.yardAt then a.ny, a.yt = (a.ny or 0) + 1, (a.yt or 0) + r.f.yardAt end
      if r.over == 1 then a.d, a.w = a.d + 1, a.w + r.won end
    end
    print("  army at 3:00 / 6:00, time in the centre, air and navy share of damage, raids, Commander level, wins:")
    for k, a in pairs(agg) do
      print(string.format("    %-8s %5d / %5d   centre %2d%%  air %2d%%  navy %2d%%  raids %.1f  cmd L%.1f   won %d of %d", k, math.floor(a.a3 / a.n), math.floor(a.a6 / a.n),
        math.floor(100 * a.c / a.n), math.floor(100 * (a.air or 0) / a.n), math.floor(100 * a.nv / a.n), a.rd / a.n, a.cl / a.n, a.w, a.d))
      print(string.format("             income %.0f / %.0f metal/s at 3:00 / 6:00, factories %.1f / %.1f, metal banked at 3:00 %d",
        a.i3 / a.n, a.i6 / a.n, a.f3 / a.n, a.f6 / a.n, math.floor(a.b3 / a.n)))
      print(string.format("             first contact %d:%02d, game length %d:%02d", math.floor(a.fc / a.n / 60), math.floor(a.fc / a.n % 60),
        math.floor(a.len / a.n / 60), math.floor(a.len / a.n % 60)))
      print(string.format("             shipyard in %d of %d sides (avg at %ds), fleet value at 6:00 %d, biggest fleet %d", a.ny or 0, a.n,
        math.floor((a.yt or 0) / math.max(1, a.ny or 0)), math.floor((a.n6 or 0) / a.n), math.floor((a.nm or 0) / a.n)))
    end
  end
  if mode == "rts" then
    -- progression: Commanders reaching level 5 (the nuke) and units promoted to General, per game
    local games, c5, gen, lv, c5t, c5n = {}, 0, 0, 0, 0, 0
    for _, r in ipairs(rows) do
      local g = games[r.game] or { c5 = false, gen = false }
      games[r.game] = g
      if (r.f.cmdLevel or 0) >= 5 then g.c5 = true end
      g.top = math.max(g.top or 0, r.f.cmdLevel or 0)
      if (r.f.generals or 0) > 0 then g.gen = true end
      lv = lv + (r.f.maxUnitLevel or 0)
      if r.f.cmd5At then c5t, c5n = c5t + r.f.cmd5At, c5n + 1 end
    end
    local ng = 0
    local c6, topL = 0, 0
    for _, g in pairs(games) do ng = ng + 1; if g.c5 then c5 = c5 + 1 end; if g.gen then gen = gen + 1 end
      if (g.top or 0) >= 6 then c6 = c6 + 1 end; topL = math.max(topL, g.top or 0) end
    print(string.format("  past level 5 (an extra nuke each): in %d of %d games, highest level %d", c6, ng, topL))
    print(string.format("  progression: a level-5 Commander (nuke) in %d of %d games%s; a General in %d of %d; best unit level %.1f on average",
      c5, ng, c5n > 0 and string.format(" (at %d:%02d)", math.floor(c5t / c5n / 60), math.floor(c5t / c5n % 60)) or "", gen, ng, lv / math.max(1, #rows)))
  end
  if mode == "rts" then
    local agg = {}
    for _, r in ipairs(rows) do
      for dom, L in pairs(r.f.lvl or {}) do
        local a = agg[dom] or { n = 0, s = 0, max = 0, sides = 0 }
        agg[dom] = a
        a.n, a.s, a.max, a.sides = a.n + L.n, a.s + L.s, a.max + L.max, a.sides + 1
      end
    end
    local parts = {}
    for _, dom in ipairs({ "land", "air", "sea" }) do
      local a = agg[dom]
      if a and a.n > 0 then parts[#parts + 1] = string.format("%s avg L%.1f (best L%.1f, %d units)", dom, a.s / a.n, a.max / a.sides, a.n) end
    end
    print("  veterancy at the end: " .. table.concat(parts, ";  "))
  end
  if mode ~= "rts" then table_by("comp") end
  print("CSV", love.filesystem.getSaveDirectory() .. "/tourney_" .. mode .. ".csv")
end

function S.start(fn, a)
  startFn, args = fn, a
  co = coroutine.create(run)
end

function S.update()
  if coroutine.status(co) == "dead" then love.event.quit(); return end
  local ok, err = coroutine.resume(co)
  if not ok then print("ERROR", err, debug.traceback(co)); love.event.quit() end
end

function S.afterDraw() end

return S
