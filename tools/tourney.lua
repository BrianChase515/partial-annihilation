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
    return startFn({ size = 112, water = 0.3, seed = seed, autotest = true, level = l2, level1 = l1,
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
      if steps % 1500 == 0 then frame() end
    end
    local winner = w.over and w.over.winnerAlly or 0
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
      local k = (r.profile or "?"):find("v2") and "v2" or "classic"
      agg[k] = agg[k] or { a3 = 0, a6 = 0, n = 0, w = 0, d = 0 }
      local a = agg[k]
      a.a3, a.a6, a.n = a.a3 + (r.f.army3 or 0), a.a6 + (r.f.army6 or 0), a.n + 1
      if r.over == 1 then a.d, a.w = a.d + 1, a.w + r.won end
    end
    print("  army value at 3:00 / 6:00, and wins:")
    for k, a in pairs(agg) do print(string.format("    %-8s %5d / %5d   won %d of %d", k, math.floor(a.a3 / a.n), math.floor(a.a6 / a.n), a.w, a.d)) end
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
