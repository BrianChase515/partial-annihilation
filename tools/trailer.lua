-- Dev tool: record a short captioned feature trailer from real gameplay.
--   love . --trailer rts   --window 1280x720
--   love . --trailer arena --window 1280x720
--   love . --trailer craft --window 1280x720
-- Writes frames trailer_<mode>_#####.png to the save directory; tools/trailer.sh turns them
-- into an MP4 and a GIF. Not shipped.
local U = require("src.util")
local S = {}
local co, game, startFn, mode
local pending
local frameNo = 0
local caption, capT, capY = nil, 0, nil
local cleanNotices = false
local FPS = 15

local function log(...) print("[trailer]", ...); io.stdout:flush() end
local function frame() coroutine.yield() end

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

local function center(x, y)
  local w = game.world
  local vw, vh = love.graphics.getWidth() / game.cam.zoom, (love.graphics.getHeight() - 240) / game.cam.zoom
  local W, H = w.map.w * w.T, w.map.h * w.T
  x = math.max(vw / 2, math.min(W - vw / 2, x))
  y = math.max(vh / 2, math.min(H - vh / 2, y))
  game:centerOn(x, y)
end

-- the soundtrack of a recording: every sound the game makes while frames are being captured,
-- logged with its time, loudness and pan (tools/trailer_audio.py mixes them with the score)
local audio = { ev = {}, int = {}, busyUntil = -1 }
local recording = false
local function tnow() return frameNo / FPS end
local function placed(x, y, view)
  if not view then return 0, 1 end
  local dx, dy = x - view.cx, y - view.cy
  local hw = math.max(200, view.halfW)
  local pan = math.max(-1, math.min(1, dx / hw)) * 0.8
  local d = math.sqrt(dx * dx + dy * dy) / hw
  local fall = d <= 1 and 1 - 0.3 * d or math.max(0, 0.7 - (d - 1) * 0.9)
  return pan, fall
end
local function hookAudio()
  local SFX, CR, VO = require("src.sfx"), require("src.cries"), require("src.voice")
  SFX.recorder = function(name, x, y, view, vol)
    if not recording then return end
    local mix = SFX.MIX[name] or { 0.5, 0.05 }
    local pan, fall = placed(x, y, view)
    local v = (vol or 1) * mix[1] * fall * (SFX.combatVolume or 1)
    if v < 0.02 then return end
    audio.ev[#audio.ev + 1] = string.format("sfx\t%s\t%.3f\t%.3f\t%.2f\t%.2f\t%.3f", name, tnow(), v, pan, SFX.pitchMul or 1, mix[2])
  end
  CR.recorder = function(key, u, view, vol, urgent)
    if not recording then return end
    local t = tnow()
    if t < audio.busyUntil and not (urgent and audio.busyHurt) then return end
    local pan, fall = placed(u.x, u.y, view)
    local v = (vol or 1) * fall
    if v < 0.03 then return end
    audio.ev[#audio.ev + 1] = string.format("voice\t%s\t%.3f\t%.3f\t%.2f\t1\t0", key, t, v, pan)
    audio.busyUntil, audio.busyHurt = t + (key:find("death") and 1.0 or 1.8), key:find("hurt") ~= nil
    return true
  end
  VO.recorder = function(key)
    if not recording or tnow() < audio.busyUntil then return end
    audio.ev[#audio.ev + 1] = string.format("announcer\t%s\t%.3f\t0.9\t0\t1\t0", key, tnow())
    audio.busyUntil, audio.busyHurt = tnow() + 2.4, false
  end
end
local function saveAudio()
  local out = {}
  for _, l in ipairs(audio.ev) do out[#out + 1] = l end
  for i, v in ipairs(audio.int) do out[#out + 1] = string.format("int\t%d\t%.3f", i, v) end
  love.filesystem.write("trailer_" .. mode .. "_audio.txt", table.concat(out, "\n"))
  log("audio events", #audio.ev)
end

-- record `seconds` of play at the trailer frame rate with a caption; `each(i)` can stage things
local function scene(text, seconds, each, opts)
  opts = opts or {}
  caption, capT, capY = text, 0, opts.capY
  local n = math.floor(seconds * FPS)
  recording = true
  for i = 1, n do
    if not opts.still then game:update(1 / FPS * (opts.speed or 1)) end
    -- how heavy the fighting is on screen, for the music mix
    local k = 0
    local cx, cy = game.cam.x, game.cam.y
    for _, p in ipairs(game.world.projectiles) do if (p.x - cx) ^ 2 + (p.y - cy) ^ 2 < 700 * 700 then k = k + 1 end end
    audio.int[frameNo + 1] = math.min(1, k / 10)
    if each then each(i, n) end
    if cleanNotices then game.notices = {} end
    capT = i / n
    frameNo = frameNo + 1
    pending = string.format("trailer_%s_%05d.png", mode, frameNo)
    frame()
  end
  recording = false
  caption = nil
end

local function aiGame(opts)
  opts.autotest = true
  game = startFn(opts)
  game.opts.autotest = false     -- draw notices and the HUD like a real game
  game.cam.zoom = 1.0
  -- nobody loses mid-trailer
  for t = 1, game.world.np do
    local c = game.world.teams[t].commander
    if c then c.invulnUntil = 1e9 end
  end
  return game
end

local function focusFight(minN)
  local w = game.world
  local bn, bx, by = 0
  for _, p in ipairs(w.projectiles) do
    local n = 0
    for _, q in ipairs(w.projectiles) do
      if U.dist2(p.x, p.y, q.x, q.y) < 350 * 350 then n = n + 1 end
    end
    if n > bn then bn, bx, by = n, p.x, p.y end
  end
  if bx and bn >= (minN or 1) then center(bx, by) end
  return bn
end

---------------------------------------------------------------------------
local function rtsScript()
  frame()
  -- 1. a growing base, icons on everything
  aiGame({ size = 112, water = 0.32, seed = 4242, players = {
    { ally = 1, level = 7, profile = "Balanced" }, { ally = 2, level = 7, profile = "Aggressive" } } })
  local w = game.world
  simFast(150)
  local c = w.teams[1].commander
  game.cam.zoom = 1.05
  center(c.x, c.y)
  scene("Build a base: claim metal, raise power, open your factories", 5, function() center(c.x, c.y) end)

  -- 2. roguelike Commander upgrades
  game:select({ c })
  w:commanderXP(c, 600)
  game:select({ c })
  -- (our side's computer player would pick instantly: bench it for this shot)
  local saved = game.ais
  local rest = {}
  for _, ai in ipairs(saved) do if ai.team ~= 1 then rest[#rest + 1] = ai end end
  game.ais = rest
  scene("Your Commander levels up from his own kills - pick 1 of 2 upgrades", 4, function() center(c.x, c.y); game:select({ c }) end, { capY = 250 })
  game.ais = saved
  while #c.offers > 0 do w:chooseUpgrade(c, 1) end

  -- 3. a big 2v2 battle with a General
  aiGame({ size = 128, water = 0.3, seed = 2026, players = {
    { ally = 1, level = 7, profile = "Aggressive" }, { ally = 2, level = 7, profile = "Balanced" },
    { ally = 1, level = 7, profile = "Air" }, { ally = 2, level = 7, profile = "Warlord" } } })
  w = game.world
  game.cam.zoom = 1.1
  for _ = 1, 16 do simFast(40); if focusFight(30) >= 30 then break end end
  -- promote a tank in the thick of it, for the camera
  local best, bd
  local fx, fy = game.cam.x, game.cam.y
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == 1 and e.key == "tank" then
      local d = U.dist(e.x, e.y, fx, fy)
      if not bd or d < bd then best, bd = e, d end
    end
  end
  if best then w:gainXP(best, w:xpForLevel(best, 5) + 1) end
  scene("Armies of land, air and sea - veterans become named Generals", 6, function(i) if i % 20 == 0 then focusFight(10) end end)

  -- 4. navies
  aiGame({ size = 128, water = 0.45, seed = 77, players = {
    { ally = 1, level = 7, profile = "Naval" }, { ally = 2, level = 7, profile = "Naval" } } })
  w = game.world
  simFast(420)
  local e2 = w.teams[2]
  local map = w.map
  local tx, ty = map:tileAt(e2.startX, e2.startY)
  local nx, ny = map:nearestTile(tx, ty, function(x, y) return map:passable("sea", x, y) and (map.shoreDist and (map.shoreDist[y * map.w + x] or 0) >= 3) end, 40)
  local navX, navY = e2.startX, e2.startY
  if nx then
    local sx, sy = map:center(nx, ny)
    for i = 1, 2 do w:spawn("battleship", 1, sx - 260 + i * 60, sy - 120) end
    for i = 1, 4 do w:spawn("destroyer", 1, sx - 200 + i * 50, sy - 40) end
    for i = 1, 3 do w:spawn("destroyer", 2, sx + 140 + i * 40, sy + 60) end
    for i = 1, 3 do w:spawn("sub", 2, sx + 120 + i * 40, sy + 120) end
    game.cam.zoom = 0.95
    center(sx, sy)
    navX, navY = sx, sy
    for _ = 1, 20 do game:update(1 / 15) end
  end
  scene("Navies matter: battleships shell anything near the coast", 5, function() center(navX, navY) end)

  -- 5. the Nuke
  aiGame({ size = 96, water = 0.3, seed = 99, players = {
    { ally = 1, level = 6, profile = "Balanced" }, { ally = 2, level = 6, profile = "Turtle" } } })
  w = game.world
  simFast(300)
  c = w.teams[1].commander
  w:commanderXP(c, 6000)
  while #c.offers > 0 do w:chooseUpgrade(c, 1) end
  e2 = w.teams[2]
  -- aim at the middle of their buildings
  local bx, by, bn = 0, 0, 0
  for _, e in ipairs(w.entities) do
    if e.alive and e.team == 2 and e.def.building then bx, by, bn = bx + e.x, by + e.y, bn + 1 end
  end
  local nx2, ny2 = e2.startX, e2.startY
  if bn > 0 then nx2, ny2 = bx / bn, by / bn end
  w:launchNuke(c, nx2, ny2)
  game.cam.zoom = 0.62
  local nk = w.nukes and w.nukes[#w.nukes]
  -- skip most of the flight, keep the last ~2.5 s of warning
  for _ = 1, 600 do
    if not nk or not nk.x or U.dist(nk.x, nk.y, nx2, ny2) < 2300 then break end
    game:update(1 / 15)
  end
  game.notices = {}
  scene("Reach level 5 and your Commander can call down a Nuke", 7, function() game:centerOn(nx2, ny2) end)

  -- 6. outro: overview of a 4-way game
  aiGame({ size = 128, water = 0.3, seed = 31, players = {
    { ally = 1, level = 6, profile = "Balanced" }, { ally = 2, level = 6, profile = "Raider" },
    { ally = 3, level = 6, profile = "Turtle" }, { ally = 4, level = 6, profile = "Boomer" } } })
  w = game.world
  simFast(360)
  w.noFog = true
  game.cam.zoom = math.min(love.graphics.getWidth() / (w.map.w * w.T), (love.graphics.getHeight() - 240) / (w.map.h * w.T))
  game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
  scene("Partial Annihilation - free on GitHub, play in your browser", 4, function()
    game.notices = {}
    local cc = w.teams[1].commander
    if cc then cc.offers = {} end
  end)
end

---------------------------------------------------------------------------
local function castAll(w)
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
          if c.skills[slot] then c.skills[slot].readyAt = 0 end
          if c.skills[slot] and A.useSkill(w, c, slot, best.x, best.y) then break end
        end
      end
    end
  end
end

local function arenaScript()
  frame()
  local A = require("src.arena")
  -- 1. 3v3 Battlefield overview
  aiGame({ mode = "arena", size = 96, seed = 21, template = "battlefield", players = {
    { ally = 1, level = 7, class = "ranger" }, { ally = 2, level = 7 }, { ally = 1, level = 7 },
    { ally = 2, level = 7 }, { ally = 1, level = 7 }, { ally = 2, level = 7 } } })
  local w = game.world
  simFast(100)
  w.noFog = true
  game.cam.zoom = math.min(love.graphics.getWidth() / (w.map.w * w.T), (love.graphics.getHeight() - 240) / (w.map.h * w.T))
  game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
  scene("Commander Arena: no base, no army - just your Commander, lanes and creep waves", 5)

  -- 2. lane fight with skills and call-outs
  w.noFog = false
  simFast(160)
  local mx, my = w.map.w * w.T / 2, w.map.h * w.T / 2
  local me = w.teams[1].commander
  for t = 1, w.np do
    local cc = w.teams[t].commander
    if cc.alive then
      local side = w.arena.teamSide[t] == 1 and -1 or 1
      cc.x, cc.y = mx + side * 130 + (t % 3) * 30, my + side * 90 - (t % 3) * 40
      cc.orders, cc.path = {}, nil
      cc.invulnUntil = w.time + 40
      w:issue(cc, { type = "amove", x = mx, y = my })
    end
  end
  game.cam.zoom = 1.25
  center(mx, my)
  game:select({ me })
  for _ = 1, 8 do game:update(1 / 15) end
  scene("Seven classes, five skills each and an ultimate - every cast is called out", 7, function(i)
    if i % 14 == 1 then castAll(w) end
  end)

  -- 3. the jungle: shrine + camps
  local j = w.arena.jungle
  if j and #j.shrines > 0 then
    local sh = j.shrines[1]
    me.x, me.y = sh.x - 40, sh.y + 30
    me.orders, me.path = {}, nil
    sh.lockUntil = 0
    game.cam.zoom = 1.1
    center(sh.x, sh.y)
    scene("Capture shrines for speed and damage, farm neutral camps for experience", 6, function() center(sh.x, sh.y) end)
  end

  -- 4. the Colossus
  if j and #j.pits > 0 then
    j.bossAt = w.time
    w:update(0.3)
    local boss = j.boss
    if boss then
      for t = 1, w.np do
        local cc = w.teams[t].commander
        if cc.alive and w.arena.teamSide[t] == 1 then
          cc.x, cc.y = boss.x - 200 + t * 20, boss.y + 120
          cc.orders, cc.path = {}, nil
          A.commanderXP(w, cc, 4000)
          while #cc.offers > 0 do w:chooseUpgrade(cc, 1) end
          w:issue(cc, { type = "attack", target = boss })
        end
      end
      game.cam.zoom = 1.0
      center(boss.x, boss.y)
      scene("At 7:00 the Colossus wakes - slay it for the Crest", 7, function(i)
        center(boss.x, boss.y)
        if i % 20 == 1 then castAll(w) end
      end)
    end
  end

  -- 5. Treeline 3v3 push on the Core
  aiGame({ mode = "arena", size = 96, seed = 33, template = "treeline", players = {
    { ally = 1, level = 7 }, { ally = 2, level = 4 }, { ally = 1, level = 7 },
    { ally = 2, level = 4 }, { ally = 1, level = 7 }, { ally = 2, level = 4 } } })
  w = game.world
  local core
  for _ = 1, 30 do
    simFast(30)
    for _, s in ipairs(w.arena.structures) do
      if s.alive and s.key == "core" and s.side == 2 and not s.protected and s.hp < s.maxhp then core = s end
    end
    if core then break end
  end
  core = core or w.arena.cores[2]
  game.cam.zoom = 1.0
  center(core.x, core.y)
  scene("Break the towers, bring down their Core - 1v1 up to 3v3, or free-for-all", 6, function() if core.alive then center(core.x, core.y) end end)
end

---------------------------------------------------------------------------
local function craftHeroesCast(w)
  local A = require("src.arena")
  local C = require("src.craft")
  for t = 1, w.np do
    for _, c in ipairs(C.heroesOf(w, t, false)) do
      if c.skills then
        local best, bd
        for _, o in ipairs(w.entities) do
          if o.alive and o.team and o.team > 0 and w:hostile(t, o.team) and not o.def.building then
            local d = U.dist(c.x, c.y, o.x, o.y)
            if d < 500 and (not bd or d < bd) then best, bd = o, d end
          end
        end
        if best then
          for slot = 4, 1, -1 do
            if c.skills[slot] then c.skills[slot].readyAt = 0 end
            if c.skills[slot] and A.useSkill(w, c, slot, best.x, best.y) then break end
          end
        end
      end
    end
  end
end

local function overview(w)
  w.noFog = true
  game.cam.zoom = math.min(love.graphics.getWidth() / (w.map.w * w.T), (love.graphics.getHeight() - 240) / (w.map.h * w.T))
  game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
end

local function craftScript()
  frame()
  local C = require("src.craft")
  local function cgame(tmpl, seed)
    aiGame({ mode = "craft", size = 88, seed = seed, template = tmpl, players = {
      { ally = 1, level = 7, race = "vanguard", class = "ranger" }, { ally = 2, level = 7, race = "warband", class = "juggernaut" } } })
    game.world.onCraftRefused = nil -- the computer's "not enough food" would spam the screen
    game.world.noFog = true -- show both sides
    cleanNotices = true
    return game.world
  end
  -- 1. the Horseshoe
  local w = cgame("horseshoe", 515)
  simFast(25)
  overview(w)
  scene("COMMANDER CRAFT  -  a classic fantasy-RTS ruleset, built into Partial Annihilation", 4.5, function() game.notices = {} end)
  -- 2. economy
  local hall
  for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and e.def.hall then hall = e end end
  game.cam.zoom = 1.25
  center(hall.x + 60, hall.y + 40)
  scene("Workers mine gold and chop lumber  -  every tree you fell is gone for good", 5, function() center(hall.x + 60, hall.y + 40) end)
  -- 3. creeping
  local hero, camp
  for _ = 1, 60 do
    simFast(5)
    for t = 1, 2 do
      for _, h in ipairs(C.heroesOf(w, t, false)) do
        for _, cp in ipairs(w.craft.camps) do
          for _, u in ipairs(cp.units) do
            if u.alive and u.lastHit and w.time - u.lastHit < 1 and U.dist(u.x, u.y, h.x, h.y) < 400 then hero, camp = h, cp end
          end
        end
      end
    end
    if hero then break end
  end
  game.cam.zoom = 1.3
  if hero then
    scene("Heroes creep neutral camps for experience  -  and choose a card at every level", 5.5, function() if hero.alive then center(hero.x, hero.y) end end)
  end
  -- 4. armies clash
  game.cam.zoom = 1.15
  for _ = 1, 40 do simFast(15); if w.time > 420 and focusFight(14) >= 14 then break end end
  scene("Two asymmetric races  -  Vanguard and Warband  -  and real melee on the front line", 6, function(i) if i % 15 == 0 then focusFight(4) end end)
  -- 5. heroes and ultimates
  for _ = 1, 30 do simFast(10); if focusFight(10) >= 10 then break end end
  scene("Ten heroes from Commander Arena, split between the races  -  ultimates included", 6, function(i)
    if i % 15 == 0 then focusFight(4) end
    if i % 18 == 1 then craftHeroesCast(w) end
  end)
  -- 6. teching up
  for _ = 1, 40 do if (w.teams[1].tier or 1) >= 3 or w.over then break end simFast(15) end
  local best
  for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and e.def.hall and (not best or e.id < best.id) then best = e end end
  if best then
    game.cam.zoom = 0.9
    w.noFog = true
    center(best.x, best.y + 80)
    scene("Upgrade your hall  -  Keep and Castle, Stronghold and Fortress  -  to unlock new units and research", 5,
      function(i) center(best.x + (i - 30) * 2, best.y + 80) end)
  end
  -- 7. the maps
  local names = { horseshoe = "Horseshoe", temple = "Old Temple", isles = "Shallow Isles", glade = "Serpent Glade" }
  for i, tm in ipairs({ "horseshoe", "temple", "isles", "glade" }) do
    w = cgame(tm, 600 + i)
    simFast(40)
    overview(w)
    scene("Four 1v1 maps  -  " .. names[tm], 2.2, function() game.notices = {} end)
  end
  -- 8. outro
  w = cgame("temple", 77)
  simFast(500)
  game.cam.zoom = 1.1
  focusFight(1)
  scene("Commander Craft  -  free in Partial Annihilation 0.13  -  play it in your browser", 4.5, function(i)
    if i % 15 == 0 then focusFight(1) end
    game.notices = {}
  end)
end


---------------------------------------------------------------------------
-- Annihilation: two big mixed armies attack-move into each other (ranks, march, kiting)
local function battleScript()
  frame()
  aiGame({ size = 112, water = 0.04, seed = 5150, players = {
    { ally = 1, level = 8, profile = "Balanced" }, { ally = 2, level = 8, profile = "Balanced" } } })
  local w = game.world
  game.ais = {}
  w.noFog = true
  w.kiteSkill = nil
  local cx, cy = w.map.w * w.T / 2, w.map.h * w.T / 2
  local function spot(x, y)
    local map = w.map
    local tx, ty = map:tileAt(x, y)
    local nx, ny = map:nearestTile(tx, ty, function(a, b) return map:passable("land", a, b) end, 12)
    if nx then return map:center(nx, ny) end
    return x, y
  end
  -- a jumbled army: spawned in a loose blob, so the attack-move visibly sorts it into ranks
  local function army(team, ox, spec)
    local list, i = {}, 0
    for k, n in spec:gmatch("(%w+):(%d+)") do
      for _ = 1, tonumber(n) do
        i = i + 1
        local a = i * 2.39996
        local r = 28 * math.sqrt(i)
        local x, y = spot(ox + math.cos(a) * r, cy + math.sin(a) * r)
        list[#list + 1] = w:spawn(k, team, x, y)
      end
    end
    return list
  end
  local spec = "tank:18+artillery:10+flak:5+scout:4"
  local A = army(1, cx - 900, spec)
  local B = army(2, cx + 900, spec)
  -- ours: the real attack-move command, exactly as a player issues it
  game:select(A)
  game:commandMove(cx + 700, cy, "amove")
  game:select({})
  -- theirs: the same ranks and march (the command itself only takes our units)
  local slots = game:formation(B, cx - 700, cy, true)
  local slow = 999
  for _, u in ipairs(B) do slow = math.min(slow, w:speedOf(u)) end
  local march = { speed = slow }
  for _, u in ipairs(B) do w:issue(u, { type = "amove", x = slots[u][1], y = slots[u][2], march = march }) end
  local function mid(list)
    local x, y, n = 0, 0, 0
    for _, u in ipairs(list) do if u.alive then x, y, n = x + u.x, y + u.y, n + 1 end end
    if n == 0 then return cx, cy end
    return x / n, y / n
  end
  game.cam.zoom = 0.95
  local function follow(list, lead)
    local x, y = mid(list)
    center(x + (lead or 0), y)
  end
  follow(A)
  scene("Attack-move: the army sorts itself into ranks - tanks in front, artillery behind", 5, function() follow(A, 120) end)
  scene("It marches at the pace of its slowest unit, so nobody runs ahead alone", 4, function() follow(A, 160) end)
  -- skip ahead to just before contact
  for _ = 1, 600 do
    local ax, _ = mid(A)
    local bx, _ = mid(B)
    if bx - ax < 900 then break end
    game:update(1 / 15)
  end
  game.cam.zoom = 0.82
  scene("Contact: the ranks break and everyone fights", 5, function()
    local ax, ay = mid(A); local bx, by = mid(B)
    center((ax + bx) / 2, (ay + by) / 2)
  end)
  game.cam.zoom = 1.15
  scene("Ranged units kite: artillery steps back from tanks and keeps firing", 7, function(i)
    -- watch our artillery line
    local art = {}
    for _, u in ipairs(A) do if u.alive and u.key == "artillery" then art[#art + 1] = u end end
    if #art > 0 then local x, y = mid(art); center(x + 80, y) else local ax, ay = mid(A); center(ax, ay) end
  end)
  game.cam.zoom = 0.82
  scene("Partial Annihilation - free on GitHub, play in your browser", 4, function()
    local ax, ay = mid(A); local bx, by = mid(B)
    center((ax + bx) / 2, (ay + by) / 2)
  end)
end


---------------------------------------------------------------------------
-- Commander of Heroes: squads, points, tickets and skills (both sides played by the computer)
local function cohScript()
  frame()
  local SQ = require("src.squads")
  game = startFn({ mode = "rts", coh = true, size = 96, water = 0.15, seed = 77, mods = { squads = true },
    squadSetup = SQ.defaults(), cohLength = "standard",
    players = { { human = true, ally = 1 }, { ally = 2, level = 8 } } })
  local w = game.world
  w.noFog = true
  game.ais[#game.ais + 1] = SQ.newAI(w, 1, 8)
  local function mine(k) for _, sq in ipairs(SQ.squadsOf(w, 1)) do if sq.type == k then return sq end end end
  local function mid(sq)
    local x, y, n = 0, 0, 0
    for _, u in ipairs(sq.members) do if u.alive then x, y, n = x + u.x, y + u.y, n + 1 end end
    if n == 0 then return w.capPoints[3].x, w.capPoints[3].y end
    return x / n, y / n
  end
  local function pick(sq) local l = {}; for _, u in ipairs(sq.members) do if u.alive then l[#l + 1] = u end end; game:select(l); game.activeSq = sq end
  -- 1. the field
  simFast(8)
  local vw, vh = love.graphics.getWidth(), love.graphics.getHeight() - 240
  game.cam.zoom = math.min(vw / (w.map.w * w.T), vh / (w.map.h * w.T)) * 1.3
  game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
  pick(mine("armor"))
  scene("Commander of Heroes: lead squads, not armies", 4, function() game.notices = {} end)
  -- 2. a squad up close
  game.cam.zoom = 1.0
  local arm = mine("armor")
  scene("Each squad is one kind of unit, led by a veteran - 1-5 grab them anywhere", 4.5, function()
    game.notices = {}; pick(arm); local x, y = mid(arm); center(x, y) end)
  -- 3. a fight over a point
  for _ = 1, 40 do
    simFast(3)
    local hot
    for _, p in ipairs(w.capPoints) do if p.contested then hot = p end end
    if hot then break end
  end
  local hot = w.capPoints[3]
  for _, p in ipairs(w.capPoints) do if p.contested then hot = p end end
  game.cam.zoom = 0.85
  scene("Hold more capture points and the enemy's tickets bleed away", 5, function()
    game.notices = {}; center(hot.x, hot.y) end)
  -- 4. a barrage
  local bat = mine("battery")
  local foe
  for _ = 1, 60 do
    if bat and bat.leader and bat.leader.alive then
      local L = bat.leader
      for _, o in ipairs(w.entities) do
        if o.alive and o.team == 2 and not o.def.building and o.def.domain ~= "air" and U.dist(o.x, o.y, L.x, L.y) < 900 then foe = o; break end
      end
    end
    if foe then break end
    simFast(2)
  end
  if foe and bat then
    bat.skills[1].readyAt = 0
    pick(bat)
    local tx, ty = foe.x, foe.y
    local L = bat.leader
    -- (let the battery see it for the shot)
    w.visionSources[#w.visionSources + 1] = { x = tx, y = ty, r = 200, untilT = w.time + 6, ally = w.ally[1] }
    SQ.cast(w, bat, 1, tx, ty)
    game.cam.zoom = 0.95
    scene("Leader skills on cooldowns: Barrage, Smoke, Flare, Hull Down, Rapid Fire...", 5.5, function()
      game.notices = {}; center((tx + L.x) / 2 * 0.3 + tx * 0.7, (ty + L.y) / 2 * 0.3 + ty * 0.7) end)
  end
  -- 5. outro: the whole battle
  simFast(20)
  game.cam.zoom = math.min(vw / (w.map.w * w.T), vh / (w.map.h * w.T)) * 1.05
  game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
  scene("Partial Annihilation - free on GitHub, play in your browser", 4, function() game.notices = {} end)
end


---------------------------------------------------------------------------
-- War is Hell: deep fog, named crews, bunkers, blood (both sides played by the computer)
local function wihScript()
  frame()
  hookAudio()
  local SQ = require("src.squads")
  game = startFn({ mode = "rts", coh = true, size = 128, water = 0.12, seed = 1944, mods = { squads = true },
    squadSetup = SQ.defaults(), cohMode = "wih", hillFrac = 0.22, rockFrac = 0.06,
    players = { { human = true, ally = 1 }, { ally = 2, level = 8 } } })
  local w = game.world
  SQ.MERCY_AT = 0 -- (the endgame is staged below)
  game.ais[#game.ais + 1] = SQ.newAI(w, 1, 8)
  for _, ai in ipairs(game.ais) do ai.defend = false end -- (the trailer wants them to meet)
  game.edgePan = false
  love.mouse.setPosition(love.graphics.getWidth() / 2, love.graphics.getHeight() - 90) -- (no hover tooltips)
  local mine = SQ.squadsOf(w, 1)
  local function mid(list)
    local x, y, n = 0, 0, 0
    for _, sq in ipairs(list) do for _, u in ipairs(sq.members) do if u.alive then x, y, n = x + u.x, y + u.y, n + 1 end end end
    if n == 0 then return w.map.w * w.T / 2, w.map.h * w.T / 2 end
    return x / n, y / n
  end
  local function pickAll() local l = {}; for _, sq in ipairs(mine) do for _, u in ipairs(sq.members) do if u.alive then l[#l + 1] = u end end end; game:select(l) end
  -- 1. moving out into the fog
  simFast(4)
  game.cam.zoom = 0.75
  pickAll()
  scene("WAR IS HELL", 2, function() game.notices = {}; local x, y = mid(mine); center(x, y) end, { capY = 300 })
  scene("No base. No reinforcements. Every man has a name.", 2.6, function() game.notices = {}; local x, y = mid(mine); center(x, y) end)
  -- 2. contact
  local fx, fy
  for _ = 1, 90 do
    simFast(2)
    local n = focusFight(6)
    if n >= 6 then fx, fy = game.cam.x, game.cam.y; break end
  end
  game.cam.zoom = 0.95
  game:select({})
  scene("Deep fog. Find them before they find you.", 2.4, function(i) game.notices = {}; if i % 8 == 0 then focusFight(3) end end)
  scene("High ground. Bunkers.", 2, function(i) if i % 8 == 0 then focusFight(3) end end)
  scene("When they die, they die.", 2.6, function(i)
    if i % 8 == 0 then focusFight(2) end
    -- (staged: a couple of them fall in shot)
    if i == 6 or i == 22 then
      local best, bd
      for _, o in ipairs(w.entities) do
        if o.alive and o.squad and not o.def.air then
          local d = U.dist(o.x, o.y, game.cam.x, game.cam.y)
          if d < 300 and (not bd or d < bd) then best, bd = o, d end
        end
      end
      if best then w:damage(best, best.hp + 1, nil) end
    end
  end)
  -- a barrage from our battery onto whatever it can reach
  local bat
  for _, sq in ipairs(mine) do if sq.type == "battery" and sq.leader and sq.leader.alive then bat = sq end end
  local foe
  if bat then
    for _ = 1, 30 do
      for _, o in ipairs(w.entities) do
        if o.alive and o.team == 2 and o.squad and U.dist(o.x, o.y, bat.leader.x, bat.leader.y) < 900 then foe = o; break end
      end
      if foe then break end
      simFast(1)
    end
  end
  if foe and bat and bat.leader.alive then
    bat.skills[1].readyAt = 0
    w.visionSources[#w.visionSources + 1] = { x = foe.x, y = foe.y, r = 220, untilT = w.time + 8, ally = w.ally[1] }
    game:select({ bat.leader }); game.activeSq = bat
    SQ.cast(w, bat, 1, foe.x, foe.y)
    local fx2, fy2 = foe.x, foe.y
    game.cam.zoom = 0.9
    scene("Barrage!", 2.6, function() center(fx2, fy2) end)
  end
  -- 3. the hunt: the enemy is bled down to a few men; a wounded one runs, and leaves a trail
  local function theirs()
    local l = {}
    for _, e in ipairs(w.entities) do if e.alive and e.team == 2 and e.squad then l[#l + 1] = e end end
    return l
  end
  local function ours()
    local l = {}
    for _, sq in ipairs(mine) do for _, u in ipairs(sq.members) do if u.alive then l[#l + 1] = u end end end
    return l
  end
  for _ = 1, 60 do
    if #theirs() <= 4 or #ours() < 9 then break end
    simFast(5)
  end
  -- (staged from here: the two nearest are left, wounded; the rest fell out of shot)
  local th = theirs()
  local ox, oy = mid(mine)
  table.sort(th, function(a, b) return U.dist(a.x, a.y, ox, oy) < U.dist(b.x, b.y, ox, oy) end)
  SQ.MERCY_AT = 0
  for i = 3, #th do w:kill(th[i]) end
  th = theirs()
  for _, u in ipairs(ours()) do u.hp = math.max(u.hp, u.maxhp * 0.6) end
  for _, u in ipairs(th) do u.hp = u.maxhp * 0.35 end
  local runner = th[1]
  if runner then
    -- our side stops to regroup (the hunt is ours to run)
    local hold = game.ais
    game.ais = {}
    for _, u in ipairs(ours()) do w:issue(u, { type = "move", x = u.x, y = u.y }) end
    simFast(1)
    SQ.MERCY_AT = 2
    game.notices = {}
    game.cam.zoom = 0.9
    local sx, sy = runner.x, runner.y
    scene("They break and run.", 2.2, function() center(sx, sy) end, { speed = 1.5 })
    simFast(6)
    -- the hunters: recon and armor, along the blood, all the way back to where they came in
    local hunters = {}
    for _, sq in ipairs(mine) do
      if sq.type == "recon" or sq.type == "armor" then for _, u in ipairs(sq.members) do if u.alive then hunters[#hunters + 1] = u end end end
    end
    if #hunters == 0 then hunters = ours() end
    game:select(hunters)
    game.notices = {}
    game:commandMove(runner.hideX or sx, runner.hideY or sy, "amove", false)
    local lead = hunters[1]
    local function follow()
      local l = lead.alive and lead or hunters[#hunters]
      local tx, ty = runner.hideX or runner.x, runner.hideY or runner.y
      center(l.x + (tx - l.x) * 0.25, l.y + (ty - l.y) * 0.25)
    end
    scene("Follow the blood.", 3, follow, { speed = 2 })
    -- (the long walk, off camera)
    for _ = 1, 240 * 30 do
      if game.mercy then break end
      local l = lead.alive and lead or hunters[#hunters]
      if l and runner.hideX and U.dist(l.x, l.y, runner.hideX, runner.hideY) < 900 then break end
      w:update(1 / 30)
    end
    scene("Back to where they came in.", 1.6, follow, { speed = 1.5 })
    -- (still looking: keep after them, off camera, until they're found)
    for _ = 1, 300 * 30 do
      if game.mercy then break end
      if not runner.alive then break end
      local l = lead.alive and lead or hunters[#hunters]
      if l and #l.orders == 0 then for _, u in ipairs(hunters) do if u.alive then w:issue(u, { type = "amove", x = runner.x, y = runner.y }) end end end
      w:update(1 / 30)
    end
    log("mercy", game.mercy and "yes" or "no", "runner alive", runner.alive)
    game.notices = {}
    if game.mercy then
      scene("Found them.", 3.6, function() end, { capY = 60 })
      game:decideMercy("kill")
      game.notices = {}
      local target = runner.alive and runner or nil
      for _, u in ipairs(game.mercy.units) do if not target and u.alive then target = u end end
      if target and target.alive then
        local tx0, ty0 = target.x, target.y
        game.cam.zoom = 1.2
        for _, u in ipairs(hunters) do if u.alive then w:issue(u, { type = "move", x = u.x, y = u.y }) end end
        game:select({})
        local function plead(i)
          center(tx0, ty0)
          if i == 3 or i == 32 then
            for _, u in ipairs(game.mercy.units) do
              if u.alive then u.begLine = SQ.BEGS[love.math.random(#SQ.BEGS)]; u.begShown = w.time; w.onSquadBeg(u); break end
            end
          end
        end
        scene("Have mercy...", 2.6, plead)
        game:select(hunters)
        for k, u in ipairs(hunters) do
          local v = game.mercy.units[(k % #game.mercy.units) + 1]
          if u.alive and v and v.alive then w:issue(u, { type = "attack", target = v }) end
        end
        scene("...or kill 'em all.", 3.5, function(i) if i == 3 then plead(32) else center(tx0, ty0) end end)
      end
    end
    for _, ai in ipairs(hold) do game.ais[#game.ais + 1] = ai end
  end
  game.cam.zoom = 0.85
  pickAll()
  scene("Commander of Heroes: War is Hell - Partial Annihilation", 2.6, function() local a, b = mid(mine); center(a, b) end)
  saveAudio()
end

function S.start(fn, m)
  startFn = fn
  mode = m or "rts"
  co = coroutine.create(function()
    if mode == "arena" then arenaScript() elseif mode == "craft" then craftScript() elseif mode == "battle" then battleScript() elseif mode == "coh" then cohScript() elseif mode == "wih" then wihScript() else rtsScript() end
    log("DONE frames", frameNo)
  end)
end

function S.update()
  if coroutine.status(co) == "dead" then love.event.quit(); return end
  local ok, err = coroutine.resume(co)
  if not ok then error(err .. "\n" .. debug.traceback(co)) end
end

-- the caption: a small lower-third, fading in and out
function S.afterDraw()
  if caption then
    local lg = love.graphics
    local w, h = lg.getDimensions()
    local a = math.min(1, capT * 8, (1 - capT) * 8)
    local f = require("src.render").font(20)
    lg.setFont(f)
    local tw = f:getWidth(caption)
    local x, y = w / 2 - tw / 2, capY or (h - 300)
    lg.setColor(0.03, 0.04, 0.06, 0.62 * a)
    lg.rectangle("fill", x - 18, y - 9, tw + 36, f:getHeight() + 18, 8)
    lg.setColor(1, 0.86, 0.5, 0.9 * a)
    lg.rectangle("fill", x - 18, y - 9, 4, f:getHeight() + 18, 2)
    lg.setColor(1, 1, 1, a)
    lg.print(caption, x, y)
  end
  if pending then
    love.graphics.captureScreenshot(pending)
    pending = nil
  end
end

return S
