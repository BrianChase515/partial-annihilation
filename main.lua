-- Partial Annihilation: a small land/sea/air RTS.
local Menu = require("src.menu")
local Game = require("src.game")

local state, menu, game
local lastOpts
local autotest = nil
smoke = nil

local function startGame(opts)
  lastOpts = opts
  opts.seed = opts.seed or os.time()
  game = Game.new(opts)
  state = "game"
end

local function parseMods(args)
  for i, a in ipairs(args or {}) do
    if a == "--mods" and args[i + 1] then
      local m = {}
      for k in args[i + 1]:gmatch("[^,]+") do m[k] = true end
      return m
    end
  end
end

-- Fit the window to the display: small screens (Steam Deck 1280x800, laptops) go
-- borderless fullscreen; --window WxH forces a windowed size (for testing).
local function fitWindow(args)
  local forced
  for i, a in ipairs(args or {}) do
    if a == "--window" and args[i + 1] then
      local w, h = args[i + 1]:match("(%d+)x(%d+)")
      forced = { tonumber(w), tonumber(h) }
    end
  end
  local flags = { resizable = true, minwidth = 960, minheight = 600, vsync = 1, msaa = 4, highdpi = true }
  if forced then
    love.window.setMode(forced[1], forced[2], flags)
    return
  end
  local dw, dh = love.window.getDesktopDimensions()
  if dw and (dw < 1650 or dh < 1010) then
    flags.fullscreen, flags.fullscreentype = true, "desktop"
    love.window.setMode(dw, dh, flags)
  end
end

function love.load(args)
  fitWindow(args)
  love.graphics.setDefaultFilter("linear", "linear")
  love.keyboard.setKeyRepeat(false)
  require("src.sfx").init()
  for i, a in ipairs(args or {}) do
    if a == "--autotest" then
      autotest = { minutes = tonumber(args[i + 1]) or 15, seed = tonumber(args[i + 2]) or 12345, size = tonumber(args[i + 3]) or 96,
        level1 = tonumber(args[i + 4]) or 5, profile1 = args[i + 5] or "Balanced",
        level2 = tonumber(args[i + 6]) or 5, profile2 = args[i + 7] or "Balanced" }
    end
  end
  for i, a in ipairs(args or {}) do
    if a == "--autotest4" then
      autotest = { minutes = tonumber(args[i + 1]) or 20, seed = tonumber(args[i + 2]) or 5, size = tonumber(args[i + 3]) or 128 }
      local mode = args[i + 4] or "ffa"
      local profs = { "Balanced", "Aggressive", "Turtle", "Raider" }
      local players = {}
      for p = 1, 4 do
        players[p] = { ally = mode == "2v2" and ((p == 1 or p == 3) and 1 or 2) or p, level = 5, profile = profs[p] }
      end
      if mode == "3" then players[4] = nil end
      startGame({ size = autotest.size, water = 0.30, seed = autotest.seed, autotest = true, players = players,
        level1 = 5, profile1 = profs[1], mods = parseMods(args) })
      return
    end
  end
  for i, a in ipairs(args or {}) do
    -- love . --arenatest <minutes> <seed> <size> <1v1|2v2|1v2> <level> [class1,class2,...]
    if a == "--arenatest" then
      autotest = { minutes = tonumber(args[i + 1]) or 20, seed = tonumber(args[i + 2]) or 5, size = tonumber(args[i + 3]) or 80, arena = true }
      local fmt = args[i + 4] or "1v1"
      local lvl = tonumber(args[i + 5]) or 5
      local classes = {}
      for k in (args[i + 6] or ""):gmatch("[^,]+") do classes[#classes + 1] = k end
      local players = {}
      local nffa = tonumber(fmt:match("^ffa(%d)"))
      if nffa then
        for p = 1, nffa do players[#players + 1] = { ally = p, level = lvl } end
      else
        local a1, a2 = fmt:match("(%d)v(%d)")
        a1, a2 = tonumber(a1) or 1, tonumber(a2) or 1
        for p = 1, a1 do players[#players + 1] = { ally = 1, level = lvl } end
        for p = 1, a2 do players[#players + 1] = { ally = 2, level = lvl } end
      end
      for p, pl in ipairs(players) do pl.class = classes[p] end
      local tmpl
      for k, x in ipairs(args) do if x == "--template" then tmpl = args[k + 1] end end
      startGame({ size = autotest.size, seed = autotest.seed, autotest = true, players = players, mode = "arena", template = tmpl })
      return
    end
  end
  if autotest then
    startGame({ size = autotest.size, water = 0.30, seed = autotest.seed, autotest = true, mods = parseMods(args),
      level = autotest.level2, profile = autotest.profile2, level1 = autotest.level1, profile1 = autotest.profile1 })
    return
  end
  for _, a in ipairs(args or {}) do
    if a == "--showcase" then
      smoke = require("showcase")
      menu = Menu.new()
      state = "menu"
      smoke.start(function(opts) startGame(opts) return game end)
      return
    end
    if a == "--smoketest" then
      smoke = require("smoketest")
      menu = Menu.new()
      state = "menu"
      smoke.start(function(opts) startGame(opts) return game end)
      return
    end
  end
  menu = Menu.new()
  state = "menu"
  for i, a in ipairs(args or {}) do
    if a == "--menushot" then
      menu.mode = args[i + 1] or "rts"
      menu.noOnline = true
      menuShot = 0
    end
  end
end

-- Headless-ish accelerated simulation for testing: AI vs AI
local function runAutotest()
  local world = game.world
  local dt = 1 / 30
  world.debugDeaths = true
  local t0 = love.timer.getTime()
  local nextReport = 60
  local maxSec = autotest.minutes * 60
  for i, a in ipairs(arg or {}) do if a == "--shotat" then maxSec = tonumber(arg[i + 1]) end end
  while world.time < maxSec and not world.over do
    world:update(dt)
    for _, ai in ipairs(game.ais) do ai:update(dt) end
    if world.arena and world.time >= nextReport then
      nextReport = nextReport + 60
      local st = world.arena
      local alive = {}
      for sd = 1, st.nSides do alive[sd] = 0 end
      for _, s in ipairs(st.structures) do if s.alive then alive[s.side] = alive[s.side] + 1 end end
      local kl = {}
      for sd = 1, st.nSides do kl[sd] = st.kills[sd] end
      local parts = {}
      for t = 1, world.np do
        local c = world.teams[t].commander
        parts[#parts + 1] = string.format("T%d %s L%d %s deaths %d", t, c.class, c.clevel or 0, c.alive and ("hp" .. math.floor(c.hp)) or "DEAD", st.deaths[t] or 0)
      end
      print(string.format("[%4ds] wave %d kills %s towers %s units %d | %s", world.time, st.wave, table.concat(kl, "-"),
        table.concat(alive, "/"), #world.entities, table.concat(parts, " | ")))
      io.stdout:flush()
    elseif world.time >= nextReport then
      nextReport = nextReport + 60
      print(string.format("MEM lua %.1f MB  texture %.1f MB", collectgarbage("count") / 1024, love.graphics.getStats().texturememory / 1048576))
      local s = {}
      for t = 1, world.np do
        local tm = world.teams[t]
        local units, blds = 0, 0
        local kinds = {}
        for _, e in ipairs(world.entities) do
          if e.team == t then
            if e.def.building then blds = blds + 1 else units = units + 1 end
            kinds[e.key] = (kinds[e.key] or 0) + 1
          end
        end
        local ks = {}
        local lv = { 0, 0, 0, 0, 0, 0 }
        for _, e in ipairs(world.entities) do
          if e.team == t and e.def.weapon then lv[(e.level or 0) + 1] = lv[(e.level or 0) + 1] + 1 end
        end
        ks[#ks + 1] = "LV:" .. table.concat(lv, "/")
        local c = tm.commander
        local ups = {}
        for _, u in ipairs(c.upgrades or {}) do ups[#ups + 1] = u.key end
        ks[#ks + 1] = string.format("CMD:L%d xp%d {%s}", c.clevel or 0, c.cxp or 0, table.concat(ups, ","))
        for k, n in pairs(kinds) do ks[#ks + 1] = k .. "=" .. n end
        table.sort(ks)
        s[#s + 1] = string.format("T%d m=%d(+%.1f) e=%d(+%.0f) units=%d blds=%d cmdHP=%d [%s]", t, tm.metal, tm.mIncome, tm.energy, tm.eIncome,
          units, blds, tm.commander.alive and tm.commander.hp or 0, table.concat(ks, " "))
      end
      print(string.format("[%5.0fs game, %.1fs real] %s", world.time, love.timer.getTime() - t0, s[1]))
      for k = 2, #s do print(string.rep(" ", 28) .. s[k]) end
      io.stdout:flush()
    end
  end
  local dead = {}
  for t = 1, world.np do if world.teams[t].dead then dead[#dead + 1] = t .. "@" .. math.floor(world.teams[t].deadTime) end end
  print("NUKES", world.nukeCount or 0)
  if world.alien then print("ALIEN captures", world.alien.captures, "state", world.alien.state, "lastOwner", world.alien.lastOwner) end
  if world.score then
    local t = {}
    for p = 1, world.np do t[#t + 1] = p .. "=" .. math.floor(world.score[p].pts) end
    print("SCORES", table.concat(t, " "))
  end
  print("RESULT", world.over and ("winner alliance " .. world.over.winnerAlly .. " at " .. math.floor(world.over.time) .. "s") or "no winner",
    "eliminated:", table.concat(dead, ","), "entities", #world.entities)
  -- point the camera at the action for the screenshot
  local p = world.projectiles[#world.projectiles]
  if p then game:centerOn(p.x, p.y) end
  game.cam.zoom = 1.0
  if p then game:centerOn(p.x, p.y) end
  io.stdout:flush()
end

function love.update(dt)
  dt = math.min(dt, 0.1)
  if autotest then
    if not autotest.done then
      autotest.done = true
      local ok, err = xpcall(runAutotest, debug.traceback)
      if not ok then print("ERROR", err) end
      autotest.shot = 0
    end
    return
  end
  if smoke then
    local ok, err = xpcall(function() smoke.update(dt) end, debug.traceback)
    if not ok then print("ERROR", err); love.event.quit() end
    return
  end
  local MUSIC = require("src.music")
  MUSIC.update(dt, state == "menu" and "menu" or nil)
  if state == "menu" then
    love.mouse.setGrabbed(false)
    MUSIC.menu()
    menu:update(dt)
  else
    game:update(dt)
    if (game.quitToTitle or game.playAgain) and game.log then game.log:finish() end
    if game.quitToTitle then
      menu = Menu.new(lastOpts)
      state = "menu"
    elseif game.playAgain then
      local o = {}
      for k, v in pairs(lastOpts) do o[k] = v end
      if not o.savedMap then o.seed = nil end
      startGame(o)
    end
  end
end

function love.draw()
  if autotest then
    game:draw()
    autotest.shot = (autotest.shot or 0) + 1
    if autotest.shot == 3 then
      love.graphics.captureScreenshot("autotest.png")
    elseif autotest.shot == 6 then
      print("SCREENSHOT", love.filesystem.getSaveDirectory() .. "/autotest.png")
      love.event.quit()
    end
    return
  end
  if state == "menu" then menu:draw() else game:draw() end
  if smoke then smoke.afterDraw() end
  if menuShot then
    menuShot = menuShot + 1
    if menuShot == 20 then love.graphics.captureScreenshot("menu_" .. menu.mode .. ".png") end
    if menuShot == 24 then love.event.quit() end
  end
end

function love.mousepressed(x, y, b)
  if autotest then return end
  if state == "menu" then
    if menu:mousepressed(x, y, b) == "start" then startGame(menu:options()) end
  else
    game:mousepressed(x, y, b)
  end
end

function love.mousereleased(x, y, b)
  if state == "game" and not autotest then game:mousereleased(x, y, b) end
end

function love.mousemoved(x, y, dx, dy)
  if state == "game" and not autotest then game:mousemoved(x, y, dx, dy) end
end

function love.wheelmoved(dx, dy)
  if state == "game" and not autotest then game:wheelmoved(dx, dy) end
end

function love.keypressed(k)
  if autotest then return end
  if k == "f11" or (k == "f" and love.keyboard.isDown("lgui", "rgui") and love.keyboard.isDown("lctrl", "rctrl")) then
    love.window.setFullscreen(not love.window.getFullscreen(), "desktop")
    if game then game:clampCam() end
    return
  end
  if state == "menu" then
    if menu:keypressed(k) == "start" then startGame(menu:options()) end
  else
    game:keypressed(k)
  end
end

function love.textinput(t)
  if state == "game" and game and not autotest then game:textinput(t) end
end

function love.resize()
  if state == "game" and game then
    -- early in a match (e.g. the browser sizing its canvas), keep the Commander in view
    local c = game.world.teams[1].commander
    if game.world.time < 5 and c and c.alive and not game.opts.autotest then game:centerOn(c.x, c.y) end
    game:clampCam()
  end
end

function love.quit()
  if game and game.log then pcall(function() game.log:finish() end) end
  return false
end
