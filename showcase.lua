-- Showcase: plays computer-vs-computer matches and captures marketing screenshots and
-- short frame sequences (turned into GIF/MP4 by tools/showcase.sh). Not shipped.
-- Run: love . --showcase --window 1920x1080
local U = require("src.util")
local S = {}
local co, game, startFn
local pendingShot
local frameNo = 0

local function log(...) print("[showcase]", ...); io.stdout:flush() end
local function frame() coroutine.yield() end

-- fast-forward without drawing
local function simFast(seconds)
  local w = game.world
  local target = w.time + seconds
  local n = 0
  while w.time < target and not w.over do
    w:update(1 / 30)
    for _, ai in ipairs(game.ais) do ai:update(1 / 30) end
    n = n + 1
    if n % 600 == 0 then frame() end
  end
end

local function still(name)
  frame()
  pendingShot = name .. ".png"
  frame(); frame()
end

-- record real-time-ish frames
local function clip(name, seconds, fps, each)
  fps = fps or 15
  local n = math.floor(seconds * fps)
  for i = 1, n do
    game:update(1 / fps)
    if each then each(i) end
    pendingShot = string.format("clip_%s_%03d.png", name, i)
    frame()
  end
  frame()
end

-- center the camera but keep the view inside the map
local function center(x, y)
  local w = game.world
  local vw, vh = love.graphics.getWidth() / game.cam.zoom, (love.graphics.getHeight() - 240) / game.cam.zoom
  local W, H = w.map.w * w.T, w.map.h * w.T
  x = math.max(vw / 2, math.min(W - vw / 2, x))
  y = math.max(vh / 2, math.min(H - vh / 2, y))
  game:centerOn(x, y)
end

-- Arena: every Commander throws whatever skill is ready at the nearest enemy
local function castAll()
  local w = game.world
  local A = require("src.arena")
  for t = 1, w.np do
    local c = w.teams[t].commander
    if c and c.alive and c.skills then
      local best, bd
      for t2 = 1, w.np do
        local o = w.teams[t2].commander
        if o and o.alive and w:hostile(t, t2) then
          local d = U.dist(c.x, c.y, o.x, o.y)
          if not bd or d < bd then best, bd = o, d end
        end
      end
      if best then
        for slot = 1, 4 do
          if c.skills[slot] and w.time >= c.skills[slot].readyAt then
            if A.useSkill(w, c, slot, best.x, best.y) then break end
          end
        end
      end
    end
  end
end

-- point the camera at the busiest fight
local function focusFight(filter)
  local w = game.world
  local best, bn, bx, by = nil, 0
  for _, p in ipairs(w.projectiles) do
    local n = 0
    for _, q in ipairs(w.projectiles) do
      if U.dist2(p.x, p.y, q.x, q.y) < 350 * 350 then n = n + 1 end
    end
    if (not filter or filter(p)) and n > bn then bn, bx, by = n, p.x, p.y end
  end
  if bx then center(bx, by) end
  return bn
end

local function aiGame(opts)
  opts.autotest = true
  game = startFn(opts)
  game.cam.zoom = 1.0
  return game
end

local function script()
  frame()
  -- 1. RTS 2v2 battle
  aiGame({ size = 128, water = 0.3, seed = 2026, players = {
    { ally = 1, level = 7, profile = "Aggressive" }, { ally = 2, level = 7, profile = "Balanced" },
    { ally = 1, level = 7, profile = "Air" }, { ally = 2, level = 7, profile = "Warlord" } } })
  game.cam.zoom = 1.15
  for _ = 1, 16 do
    simFast(40)
    if focusFight() >= 30 then break end
  end
  focusFight()
  still("rts-battle")
  clip("rts-battle", 8, 15)
  still("rts-battle-2")

  -- 2. Naval: battleships on a wet map
  aiGame({ size = 128, water = 0.45, seed = 77, players = {
    { ally = 1, level = 7, profile = "Naval" }, { ally = 2, level = 7, profile = "Naval" } } })
  simFast(600)
  local w = game.world
  game.cam.zoom = 0.95
  for _ = 1, 12 do
    local bb
    for _, e in ipairs(w.entities) do if e.alive and e.key == "battleship" then bb = e end end
    if bb then
      -- frame the battleship with the fleet around it
      local sx, sy, n = 0, 0, 0
      for _, e in ipairs(w.entities) do
        if e.alive and (e.def.domain == "sea" or e.def.domain == "sub") and U.dist(e.x, e.y, bb.x, bb.y) < 700 then sx, sy, n = sx + e.x, sy + e.y, n + 1 end
      end
      if n >= 4 then center(sx / n, sy / n); break end
    end
    simFast(60)
  end
  -- stage a fleet action: our battleships and escorts against their navy near their coast
  local e2 = w.teams[2]
  local A2 = require("src.ai")
  local map = w.map
  local tx, ty = map:tileAt(e2.startX, e2.startY)
  local nx, ny = map:nearestTile(tx, ty, function(x, y) return map:passable("sea", x, y) and (map.shoreDist and (map.shoreDist[y * map.w + x] or 0) >= 3) end, 40)
  if nx then
    local sx, sy = map:center(nx, ny)
    for i = 1, 2 do w:spawn("battleship", 1, sx - 260 + i * 60, sy - 120) end
    for i = 1, 4 do w:spawn("destroyer", 1, sx - 200 + i * 50, sy - 40) end
    for i = 1, 3 do w:spawn("destroyer", 2, sx + 140 + i * 40, sy + 60) end
    for i = 1, 3 do w:spawn("sub", 2, sx + 120 + i * 40, sy + 120) end
    game.cam.zoom = 1.0
    center(sx, sy)
    for _ = 1, 45 do game:update(1 / 15) end
  end
  still("naval")

  -- 3. Groovy modifier
  aiGame({ size = 128, water = 0.3, seed = 2026, mods = { groovy = true }, players = {
    { ally = 1, level = 7, profile = "Aggressive" }, { ally = 2, level = 7, profile = "Balanced" },
    { ally = 1, level = 7, profile = "Air" }, { ally = 2, level = 7, profile = "Warlord" } } })
  game.cam.zoom = 1.1
  for _ = 1, 16 do simFast(40); if focusFight() >= 30 then break end end
  focusFight()
  for _ = 1, 12 do game:update(1 / 15) end
  still("groovy")

  -- 4. Commander upgrade choice + Nuke
  aiGame({ size = 96, water = 0.3, seed = 99, players = {
    { ally = 1, level = 6, profile = "Balanced" }, { ally = 2, level = 6, profile = "Turtle" } } })
  simFast(240)
  w = game.world
  local c = w.teams[1].commander
  game.cam.zoom = 1.0
  center(c.x, c.y)
  game:select({ c })
  w:commanderXP(c, 600)
  still("commander-upgrade")
  while #c.offers > 0 do w:chooseUpgrade(c, 1) end
  w:commanderXP(c, 5000)
  while #c.offers > 0 do w:chooseUpgrade(c, 1) end
  local e2 = w.teams[2]
  w:launchNuke(c, e2.startX, e2.startY)
  game.cam.zoom = 0.85
  center(e2.startX, e2.startY)
  for _ = 1, 40 do game:update(1 / 15) end
  still("nuke-incoming")
  clip("nuke", 5, 15)

  -- 5. Commander Arena: 2v2, fights with skills
  aiGame({ mode = "arena", size = 80, seed = 12, players = {
    { ally = 1, level = 7, class = "elementalist" }, { ally = 1, level = 7, class = "warden" },
    { ally = 2, level = 7, class = "juggernaut" }, { ally = 2, level = 7, class = "reclaimer" } } })
  simFast(330)
  w = game.world
  local A = require("src.arena")
  -- find two enemy Commanders close together
  local cx, cy
  for _ = 1, 30 do
    local best
    for t = 1, 2 do
      local a = w.teams[t].commander
      for t2 = 3, 4 do
        local b = w.teams[t2].commander
        if a.alive and b.alive then
          local d = U.dist(a.x, a.y, b.x, b.y)
          if d < 700 and (not best or d < best) then best, cx, cy = d, (a.x + b.x) / 2, (a.y + b.y) / 2 end
        end
      end
    end
    if best then break end
    simFast(10)
  end
  local me = w.teams[1].commander
  -- stage a brawl in the middle of the map
  local mx, my = w.map.w * 16, w.map.h * 16
  for t = 1, 4 do
    local cc = w.teams[t].commander
    if cc.alive then
      local side = t <= 2 and -1 or 1
      cc.x, cc.y = mx + side * 120 + (t % 2) * 40, my + side * 90 - (t % 2) * 60
      cc.orders, cc.path = {}, nil
      cc.invulnUntil = w.time + 60   -- camera stars: keep them alive for the recording
      w:issue(cc, { type = "amove", x = mx, y = my })
    end
  end
  cx, cy = mx, my
  game.cam.zoom = 1.25
  center(cx, cy)
  game:select({ me })
  -- make sure skills are flying for the camera
  for t = 1, 4 do
    local cc = w.teams[t].commander
    if cc.alive then
      for slot = 1, 4 do
        local sk = cc.skills[slot]
        if sk then sk.readyAt = 0 end
      end
    end
  end
  for _ = 1, 10 do game:update(1 / 15) end
  castAll()
  for _ = 1, 6 do game:update(1 / 15) end
  still("arena-fight")
  clip("arena", 8, 15, function(i)
    if i % 12 == 0 then
      for t = 1, 4 do local cc = w.teams[t].commander; for sl = 1, 4 do if cc.skills[sl] then cc.skills[sl].readyAt = 0 end end end
      castAll()
    end
  end)
  still("arena-fight-2")

  -- 6. Arena free-for-all overview
  aiGame({ mode = "arena", size = 80, seed = 4, template = "classic", players = {
    { ally = 1, level = 6 }, { ally = 2, level = 6 }, { ally = 3, level = 6 }, { ally = 4, level = 6 } } })
  simFast(240)
  w = game.world
  game.cam.zoom = 0.45
  game:centerOn(w.map.w * 16, w.map.h * 16)
  still("arena-ffa")

  -- title screens
  game = nil
  log("DONE")
end

function S.start(fn)
  startFn = fn
  co = coroutine.create(script)
end

function S.update(dt)
  if coroutine.status(co) == "dead" then
    love.event.quit()
    return
  end
  local ok, err = coroutine.resume(co)
  if not ok then error(err .. "\n" .. debug.traceback(co)) end
end

function S.afterDraw()
  if pendingShot then
    love.graphics.captureScreenshot(pendingShot)
    pendingShot = nil
  end
end

return S
