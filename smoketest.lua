local U_dist = require("src.util").dist
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
  -- Delete key: self-destruct, with the Commander guard
  game = startFn({ size = 96, water = 0.30, seed = 11 })
  w = game.world
  local cm = w.teams[1].commander
  local s1 = w:spawn("tank", 1, cm.x + 60, cm.y)
  local s2 = w:spawn("solar", 1, cm.x - 80, cm.y + 40); s2.built = 0.5
  local m0 = w.teams[1].metal
  game:select({ s1, s2, cm })
  key("delete")
  log("delete: tank alive", s1.alive, "half-built solar alive", s2.alive, "commander alive", cm.alive,
    "refund", math.floor(w.teams[1].metal - m0))
  game:select({ cm }); key("backspace")
  log("one press on commander alone -> alive", cm.alive)
  key("backspace")
  log("second press -> alive", cm.alive, "over", w.over ~= nil)
  -- orders bar: select some tanks, hover Flee, click Attack then a spot
  game = startFn({ size = 128, water = 0.45, seed = 21 })
  w = game.world
  local cm2 = w.teams[1].commander
  local ts = {}
  for i = 1, 4 do ts[i] = w:spawn("tank", 1, cm2.x + 40 * i, cm2.y - 40) end
  game:select(ts)
  frame()
  local fb
  for _, b in ipairs(game.orderBtns or {}) do if b.action == "flee" then fb = b end end
  log("orders bar buttons:", #(game.orderBtns or {}), "flee enabled", fb and fb.on)
  love.mouse.setPosition(fb.x + 10, fb.y + 10)
  frame(); shot("orders.png")
  local ab
  for _, b in ipairs(game.orderBtns) do if b.action == "amove" then ab = b end end
  game:mousepressed(ab.x + 5, ab.y + 5, 1); game:mousereleased(ab.x + 5, ab.y + 5, 1)
  log("mode after Attack button:", game.mode)
  game:mousepressed(500, 300, 1); game:mousereleased(500, 300, 1)
  log("tank order:", ts[1].orders[1] and ts[1].orders[1].type)
  log("check32", require("src.online").check32("abc|partial"))
  -- force a win to see the score screen
  local e2b = w.teams[2].commander
  w:commanderXP(cm2, 600)
  w:kill(e2b, cm2)
  local t1 = love.timer.getTime()
  while love.timer.getTime() - t1 < 1.7 do game:update(1 / 60); frame() end
  shot("score.png")
  -- v0.6 sea: battleship, sea constructor, tidal, offshore extractor
  game = startFn({ size = 128, water = 0.45, seed = 5 })
  w = game.world
  local map = w.map
  local sea
  for _, dp in ipairs(map.deposits) do
    if dp.sea and (not sea or U_dist(dp.x, dp.y, map.starts[1].x, map.starts[1].y) < U_dist(sea.x, sea.y, map.starts[1].x, map.starts[1].y)) then sea = dp end
  end
  local nsea = 0
  for _, dp in ipairs(map.deposits) do if dp.sea then nsea = nsea + 1 end end
  log("sea deposits:", nsea, "nearest at", sea and sea.x, sea and sea.y, "shore", sea and sea.shore)
  local sx, sy = map:center(sea.x, sea.y)
  local m = w:spawn("mex", 1, sx, sy, 1)
  w.economyDirty = true
  local bb = w:spawn("battleship", 1, sx + 60, sy + 60)
  local sb = w:spawn("seabuilder", 1, sx - 50, sy + 40)
  log("can place tidal near:", w:canPlace("tidal", sea.x + 3, sea.y + 2, 1))
  local enemyTank = w:spawn("tank", 2, sx + 500, sy - 300)
  local tgt = w:findTarget(bb, w:rangeOf(bb))
  log("battleship range", w:rangeOf(bb), "auto-target", tgt and tgt.key)
  for _ = 1, 240 do w:update(1 / 30) end
  log("enemy tank hp after 2s near battleship:", math.floor(enemyTank.hp), "/", enemyTank.maxhp, "bb target", bb.target and bb.target.key)
  log("offshore mex income mods", m.mods and m.mods.income.metal, "team income", w.teams[1].mIncome)
  game:centerOn(sx, sy); game.cam.zoom = 0.8; game:centerOn(sx, sy)
  game:select({ bb })
  frame(); shot("sea.png")
  -- Repair zone: P + drag with a constructor; a damaged building inside gets fixed
  do
    local c1 = w.teams[1].commander
    local zx, zy = c1.x + 120, c1.y
    local bld = w:spawn("builder", 1, zx - 60, zy + 40)
    local tw = w:spawn("solar", 1, zx + 80, zy - 40, 1)
    tw.hp = tw.maxhp * 0.3
    game:centerOn(zx, zy); game.cam.zoom = 1
    frame()
    game:select({ bld })
    key("p")
    local sx1, sy1 = game:worldToScreen(zx, zy)
    love.mouse.setPosition(sx1, sy1)
    game:mousepressed(sx1, sy1, 1)
    local sx2, sy2 = game:worldToScreen(zx + 260, zy)
    love.mouse.setPosition(sx2, sy2)
    frame(); shot("repairzone_drag.png")
    game:mousereleased(sx2, sy2, 1)
    local o = bld.orders[1]
    log("repair zone order", o and o.type, o and math.floor(o.r))
    for _ = 1, 30 * 20 do w:update(1 / 30) end
    log("damaged building hp after 20s in zone:", math.floor(tw.hp / tw.maxhp * 100) .. "%", "builder still on duty", bld.orders[1] and bld.orders[1].type)
    game:select({ bld }); frame(); shot("repairzone.png")
  end
  -- Commander Arena
  game = startFn({ mode = "arena", size = 80, seed = 3, players = {
    { human = true, ally = 1, class = "elementalist" }, { ally = 2, level = 5, class = "juggernaut" } } })
  w = game.world
  local ac = w.teams[1].commander
  log("arena: class", ac.class, "structures", #w.arena.structures, "lanes", w.map.lanes.top and "ok")
  game:select({ ac })
  for _ = 1, 30 * 20 do game:update(1 / 30) end
  log("arena wave", w.arena.wave, "entities", #w.entities)
  frame(); shot("arena_start.png")
  w:commanderXP(ac, 2300)
  log("arena level", ac.clevel, "offers", #ac.offers, "skills", ac.skills[4] and ac.skills[4].key)
  frame(); shot("arena_offer.png")
  for _ = 1, 6 do key("z") end
  local sk = {}
  for i = 1, 4 do sk[#sk + 1] = ac.skills[i] and ac.skills[i].key or "-" end
  log("arena skills", table.concat(sk, ","), "upgrades", #ac.upgrades)
  -- walk to mid and fight for a while
  local mx, my = w.map:center(40, 40)
  w:issue(ac, { type = "amove", x = mx, y = my })
  for _ = 1, 30 * 50 do game:update(1 / 30) end
  game:centerOn(ac.x, ac.y)
  for slot = 1, 4 do
    local ok, why = require("src.arena").useSkill(w, ac, slot, ac.x + 150, ac.y - 100)
    log("skill", slot, ok, why)
  end
  for _ = 1, 30 do game:update(1 / 30) end
  frame(); shot("arena_fight.png")
  -- hold fire and denial
  game:select({ ac })
  game.holdToggle = true
  game:update(1 / 30)
  log("hold fire flag on commander:", ac.holdFire)
  game.holdToggle = false
  game:update(1 / 30)
  log("hold fire released:", ac.holdFire)
  local mine
  for _, e in ipairs(w.entities) do if e.alive and e.creep and e.team == 1 then mine = e; break end end
  if mine then
    mine.hp = mine.maxhp * 0.2
    log("can deny own low creep:", w:canDeny(ac, mine), "can deny healthy:", (function() local hp = mine.hp; mine.hp = mine.maxhp; local r = w:canDeny(ac, mine); mine.hp = hp; return r end)())
    local xp0 = ac.cxp
    mine.x, mine.y = ac.x + 60, ac.y
    w:issue(ac, { type = "attack", target = mine })
    for _ = 1, 30 * 4 do w:update(1 / 30) end
    log("denied creep alive:", mine.alive, "commander xp change:", math.floor(ac.cxp - xp0))
  end
  -- end it
  local core2 = w.arena.core2
  core2.protected = nil
  w:kill(core2, ac)
  local t2 = love.timer.getTime()
  while love.timer.getTime() - t2 < 1.7 do game:update(1 / 60); frame() end
  log("arena over", w.over and w.over.winnerAlly)
  shot("arena_over.png")
  local MUSIC = require("src.music")
  log("music heat", MUSIC.heat, "intensity", math.floor(MUSIC.intensity * 100) / 100)
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
