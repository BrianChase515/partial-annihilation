-- Scripted "fake player" that drives the real input handlers. Not shipped.
local D = require("src.defs")
local S = {}
local co, game, startFn
local shots = {}
local pendingShot

local function log(...) print("[smoke]", ...); io.stdout:flush() end

local function sim(seconds)
  -- advance game time quickly while still drawing occasionally
  local target = game.world.time + seconds
  while game.world.time < target and not game.world.over do
    for _ = 1, 20 do game:update(1 / 30) end
    coroutine.yield()
  end
end

local function frame() coroutine.yield() end

local function click(wx, wy, button)
  game:centerOn(wx, wy)
  local sx, sy = game:worldToScreen(wx, wy)
  game:mousepressed(sx, sy, button or 1)
  game:mousereleased(sx, sy, button or 1)
end

local function key(k) game:keypressed(k) end

local function shot(name)
  pendingShot = name
  frame(); frame()
end

local function script()
  -- menu -> start
  frame()
  -- lobby: turn on two more CPUs and make a 2v2, check the options produced
  local Menu = require("src.menu")
  local m = Menu.new()
  local function clickRect(pred, b)
    for _, r in ipairs(m:rects()) do if pred(r) then m:mousepressed(r.x + 3, r.y + 3, b or 1); return true end end
  end
  clickRect(function(r) return r.kind == "toggle" and r.slot == 4 end) -- turns on 3 and 4
  clickRect(function(r) return r.kind == "team" and r.slot == 3 end)    -- slot 3: team 3 -> 4
  clickRect(function(r) return r.kind == "team" and r.slot == 3 end)    -- 4 -> 1
  clickRect(function(r) return r.kind == "team" and r.slot == 4 end)    -- slot 4: team 4 -> 1
  clickRect(function(r) return r.kind == "team" and r.slot == 4 end)    -- 1 -> 2
  clickRect(function(r) return r.kind == "lvup" and r.slot == 2 end)
  clickRect(function(r) return r.kind == "prof" and r.slot == 2 end)
  local o = m:options()
  local desc = {}
  for i, p in ipairs(o.players) do desc[#desc + 1] = string.format("P%d ally%d %s %s", i, p.ally, p.human and "human" or ("lvl" .. p.level), p.profile or "") end
  log("lobby players:", table.concat(desc, " | "), "valid:", m:validTeams())
  shot("title.png")
  game = startFn({ size = 96, water = 0.30, seed = 4242, players = o.players })
  log("players in world:", game.world.np, "allies:", game.world.ally[1], game.world.ally[2], game.world.ally[3], game.world.ally[4])
  -- save-map flow
  game:startNaming()
  for _, ch in ipairs({ "T", "e", "s", "t" }) do game:textinput(ch) end
  game:keypressed("return")
  local saved = require("src.maps").load()
  log("saved maps:", #saved, saved[1] and saved[1].name, saved[1] and saved[1].np)
  frame()
  local w = game.world
  local cmd = w.teams[1].commander
  log("commander at", math.floor(cmd.x), math.floor(cmd.y), "selected", game.selected[cmd])

  -- drag-build extractors over the area around the commander
  local function drag(ax, ay, bx, by)
    game:centerOn((ax + bx) / 2, (ay + by) / 2)
    local sx, sy = game:worldToScreen(ax, ay)
    local ex, ey = game:worldToScreen(bx, by)
    game:mousepressed(sx, sy, 1)
    game:mousereleased(ex, ey, 1)
  end
  game:select({ cmd })
  key("q")
  drag(cmd.x - 260, cmd.y - 260, cmd.x + 260, cmd.y + 260)
  log("drag mex -> commander orders:", #cmd.orders, "mode:", game.mode)
  local function placeNear(k, ox, oy)
    for r = 2, 12 do
      for a = 0, 7 do
        local x = cmd.x + math.cos(a * math.pi / 4) * r * 32 + ox
        local y = cmd.y + math.sin(a * math.pi / 4) * r * 32 + oy
        local tx, ty = w:footprintAt(k, x, y)
        if w:canPlace(k, tx, ty, 1) then
          game:select({ cmd })
          key(({ solar = "w", landfac = "e", turret = "y" })[k])
          click(x, y)
          return true
        end
      end
    end
  end
  sim(30)
  log("mex built:", w:count(1, "mex"))
  -- drag a line of solars
  game:select({ cmd })
  key("w")
  drag(cmd.x - 220, cmd.y + 130, cmd.x + 220, cmd.y + 160)
  log("drag solar line -> orders:", #cmd.orders)
  sim(35)
  placeNear("landfac", 120, -100)
  sim(20)
  shot("early.png")
  sim(50)
  log("time", math.floor(w.time), "mex", w:count(1, "mex"), "solar", w:count(1, "solar"), "landfac", w:count(1, "landfac"))
  local fac
  for _, e in ipairs(w.entities) do if e.team == 1 and e.key == "landfac" then fac = e end end
  if fac and fac.built >= 1 then
    click(fac.x, fac.y)
    log("factory selected:", game.selected[fac])
    key("q")
    for _ = 1, 4 do key("e") end
    fac.assignGroup = 3
    log("queue length", #fac.queue)
    click(fac.x + 200, fac.y - 200, 2)
    log("rally", fac.rally and math.floor(fac.rally.x))
    frame(); shot("factory.png")
  else
    log("factory not finished", fac and fac.built)
  end
  -- control group test
  game:select({ cmd })
  local ctrlDown = love.keyboard.isDown
  sim(80)
  -- box-select army
  local army = w:teamEntities(1, function(e) return e.key == "tank" end)
  log("tanks:", #army)
  if #army > 0 then
    local sx, sy = game:worldToScreen(army[1].x, army[1].y)
    game:centerOn(army[1].x, army[1].y)
    sx, sy = game:worldToScreen(army[1].x, army[1].y)
    game:mousepressed(sx - 150, sy - 150, 1)
    game:mousereleased(sx + 150, sy + 150, 1)
    log("box selected:", #game:selectedList())
    key("h"); log("after half:", #game:selectedList(), "other:", #game.otherHalf)
    game:selectOtherHalf(); log("other half:", #game:selectedList())
    game:selectAllArmy(); log("all army:", #game:selectedList())
    game.groups[1] = game:selectedList()
    key("1"); key("1")
    -- attack-move toward the middle
    key("a")
    log("mode:", game.mode)
    click(w.map.w * 16, w.map.h * 16)
    log("first tank order:", army[1].orders[1] and army[1].orders[1].type)
  end
  sim(40)
  log("group 3 (factory output):", game.groups[3] and #game.groups[3])
  -- retreat test
  local tanks = w:teamEntities(1, function(e) return e.key == "tank" end)
  if #tanks > 0 then
    game:select(tanks)
    key("f")
    log("retreat order:", tanks[1].orders[1] and tanks[1].orders[1].type)
    sim(1)
    log("disarmed:", tanks[1].disarmed, "hp", math.floor(tanks[1].hp), "/", tanks[1].maxhp)
    key("l"); log("follow:", game.follow and #game.follow.units)
    for _ = 1, 30 do game:update(1 / 30) end
    key("l"); log("follow after second L:", game.follow)
  end
  -- sidebar click
  local UI = require("src.ui")
  local items = UI.sidebarItems(game)
  if items[1] and items[1].e then
    game:mousepressed(items[1].x + 10, items[1].y + 10, 1)
    game:mousereleased(items[1].x + 10, items[1].y + 10, 1)
    log("sidebar click selected:", items[1].e.key, game.selected[items[1].e])
  end
  -- top bar speed button
  frame()
  for _, tb in ipairs(game.topBtns or {}) do
    if tb.action == "faster" then game:mousepressed(tb.x + 5, tb.y + 5, 1) end
  end
  log("speed after + click:", game.speed)
  game:setSpeed(1)
  sim(40)
  shot("mid.png")
  key("f1"); frame(); shot("help.png"); key("f1")
  key("escape"); frame(); shot("menu.png"); key("escape")
  -- select factory and screenshot the queue panel
  if fac and fac.alive then click(fac.x, fac.y); frame(); shot("factory.png") end
  sim(200)
  log("t", math.floor(w.time), "over", w.over and w.over.winner)
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 2 do game:update(1 / 60); frame() end
  shot("over.png")
  -- Commander progression + nuke on a fresh game
  game = startFn({ size = 96, water = 0.30, seed = 99 })
  w = game.world
  local c = w.teams[1].commander
  local CMD = require("src.commander")
  w:commanderXP(c, 250)
  log("cmd level", c.clevel, "offers", #c.offers, c.offers[1] and (c.offers[1][1].name .. " / " .. c.offers[1][2].name))
  frame(); shot("offer.png")
  key("z")
  log("after Z: upgrades", #c.upgrades, c.upgrades[1] and c.upgrades[1].name, "offers left", #c.offers)
  w:commanderXP(c, 5000)
  log("cmd level", c.clevel, "pending offers", #c.offers, "nuke unlocked", c.nukeReady ~= nil)
  for _ = 1, 3 do key("x") end
  log("upgrades now", #c.upgrades)
  -- nuke the enemy start
  local e2 = w.teams[2]
  game:select({ c })
  key("n")
  log("mode after N:", game.mode)
  local before = #w:teamEntities(2, function(e) return e.def.building end)
  -- give the enemy something to lose
  for i = 1, 3 do w:spawn("solar", 2, e2.startX + 80 * i, e2.startY + 60) end
  game:centerOn(e2.startX, e2.startY)
  local sx, sy = game:worldToScreen(e2.startX, e2.startY)
  game:mousepressed(sx, sy, 1)
  log("nukes in flight:", #w.nukes, "cooldown set:", c.nukeReady > w.time)
  frame(); shot("nuke_flight.png")
  for _ = 1, 30 * 12 do w:update(1 / 30) end
  local after = #w:teamEntities(2, function(e) return e.def.building end)
  log("enemy buildings before/after nuke:", before + 3, after, "enemy commander alive:", e2.commander.alive, "hp", math.floor(e2.commander.hp))
  -- Dropship encounter with the human player (coin flip pause)
  game = startFn({ size = 96, water = 0.30, seed = 7, mods = { drops = true, score = true, alien = true } })
  w = game.world
  local MOD = require("src.mods")
  local cmdr = w.teams[1].commander
  w.drops.nextAt = 0
  for _ = 1, 3 do w:update(1 / 30) end
  local sq = w.drops.squads[1]
  log("drop squad:", sq and #sq.units, sq and sq.state)
  for _, u in ipairs(sq.units) do u.x, u.y = cmdr.x + 150, cmdr.y + 30 end
  for _ = 1, 30 do game:update(1 / 30) end
  log("flip pending:", #game.flips, "squad state:", sq.state, "world time", math.floor(w.time * 10) / 10)
  frame(); shot("coinflip.png")
  local t0 = w.time
  for _ = 1, 30 * 3 do game:update(1 / 30) end
  log("after flip: state", sq.state, "result", sq.result, "unit team", sq.units[1] and sq.units[1].team, "world advanced", math.floor((w.time - t0) * 10) / 10)
  frame(); shot("after_flip.png")
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
    log("shot", pendingShot)
    pendingShot = nil
  end
end

return S
