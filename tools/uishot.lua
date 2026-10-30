local D = require("src.defs")
local U = require("src.util")
-- Dev tool: start a 2v2 (RTS or Arena), let the AIs play a while, take a screenshot.
-- love . --uishot <rts|arena> [seconds]   (not shipped)
local S = {}
local co, game, startFn, pending
local function frame() coroutine.yield() end
local function script(mode, secs)
  frame()
  if mode == "menu" then
    -- the title screen on a tab (PA_TAB=craft|arena|rts), optionally with a map picked (PA_MAPI)
    local menu = PA_MENU
    menu.mode = os.getenv("PA_TAB") or "craft"
    if os.getenv("PA_SETTINGS") then require("src.settings").open = true end
    if os.getenv("PA_COHGAME") then
      for _, r in ipairs(menu:rects()) do if r.kind == "cohgame" and r.value == os.getenv("PA_COHGAME") then menu:mousepressed(r.x + 4, r.y + 4, 1) end end
    end
    if os.getenv("PA_COHDROP") then
      for _, r in ipairs(menu:rects()) do if r.kind == "sqtype" and r.sqi == 2 then menu:mousepressed(r.x + 4, r.y + 4, 1) end end
    end
    if os.getenv("PA_GAME") then
      for _, r in ipairs(menu:rects()) do if r.gametype == os.getenv("PA_GAME") then menu:mousepressed(r.x + 2, r.y + 2, 1) end end
    end
    if os.getenv("PA_MAPI") then menu.craft.map = tonumber(os.getenv("PA_MAPI")) end
    if os.getenv("PA_LEGACY") then
      for _, r in ipairs(menu:rects()) do if r.action == "legacyai" then menu:mousepressed(r.x + 4, r.y + 4, 1) end end
    end
    for _ = 1, 4 do frame() end
    pending = "uishot_menu.png"
    frame(); frame()
    print("UISHOT menu")
    return
  end
  if os.getenv("PA_BLOCKTEST") then
    -- a unit ordered straight through its own idle Commander (and through a line of tanks)
    game = startFn({ size = 96, water = 0.0, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    local c = w.teams[1].commander
    local results = {}
    for _, kind in ipairs({ "move", "retreat", "amove" }) do
      local x0, y0 = c.x - 160, c.y
      c.orders = {}
      local u = w:spawn("tank", 1, x0, y0)
      u.built = 1
      local wall = {}
      for k = -1, 1 do wall[#wall + 1] = w:spawn("tank", 1, c.x + 60, c.y + k * 26); wall[#wall].built = 1 end
      w:issue(u, { type = kind, x = c.x + 220, y = c.y })
      local t = 0
      while t < 12 and U.dist(u.x, u.y, c.x + 220, c.y) > 20 do w:update(1 / 30); t = t + 1 / 30 end
      results[#results + 1] = string.format("%s: %s in %.1fs (left %d)", kind, U.dist(u.x, u.y, c.x + 220, c.y) <= 20 and "arrived" or "STUCK", t,
        math.floor(U.dist(u.x, u.y, c.x + 220, c.y)))
      w:remove(u)
      for _, o in ipairs(wall) do w:remove(o) end
    end
    print("BLOCKTEST", table.concat(results, "; "))
    return
  end
  if os.getenv("PA_BLOCKTEST2") then
    -- a unit retreating through its own Commander (busy assisting a plant), in the open and with
    -- the Commander up against a building: does it get round?
    game = startFn({ size = 96, water = 0.0, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    local U2 = require("src.util")
    local results = {}
    for case = 1, 3 do
      for _, e in ipairs(w.entities) do if e.alive and not e.def.building and e.key ~= "commander" then w:remove(e) end end
      local c = w.teams[1].commander
      local cx, cy = w.map.w * w.T / 2, w.map.h * w.T / 2
      c.x, c.y, c.orders = cx, cy, {}
      local fac = w:spawn("landfac", 1, cx + (case == 2 and 0 or 300), cy + (case == 2 and -70 or 300))
      fac.built = 1
      w:issue(c, { type = "assist", target = fac })
      local t = w:spawn("tank", 1, cx - 250, cy + (case == 3 and 10 or 0))
      local o = { type = "retreat", x = cx + 400, y = cy + (case == 3 and 10 or 0) }
      w:issue(t, o)
      local passed
      for i = 1, 30 * 20 do
        w:update(1 / 30)
        c.x, c.y = cx, cy -- (pinned: busy, as when building)
        if not passed and t.x > cx + 60 then passed = i / 30 end
      end
      results[#results + 1] = string.format("case %d: %s", case, passed and string.format("got past in %.1fs", passed) or string.format("STUCK at x=%d (cmd at %d)", math.floor(t.x), math.floor(cx)))
      w:remove(fac); w:remove(t)
    end
    for _, r in ipairs(results) do print("BLOCK", r) end
    return
  end
  if os.getenv("PA_BLOCKTEST3") then
    -- the player's Flee with no flag set: four tanks run to the (busy) Commander. Do they settle
    -- around him, or shove at him?
    game = startFn({ size = 96, water = 0.0, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    local c = w.teams[1].commander
    local fac = w:spawn("landfac", 1, c.x + 200, c.y + 200); fac.built = 1
    w:issue(c, { type = "assist", target = fac })
    local tanks = {}
    for k = 1, 4 do tanks[k] = w:spawn("tank", 1, c.x + 500 + k * 30, c.y - 300 + k * 20); tanks[k].built = 1 end
    game:select(tanks)
    game:retreat("flag")
    local t = 0
    local cx, cy = c.x, c.y
    print("BLOCK3 orders", tanks[1].orders[1] and tanks[1].orders[1].type, tanks[1].orders[1] and math.floor(tanks[1].orders[1].x), tanks[1].orders[1] and math.floor(tanks[1].orders[1].y), "tank at", math.floor(tanks[1].x), math.floor(tanks[1].y), "cmd", math.floor(c.x), math.floor(c.y))
    while t < 20 do
      w:update(1 / 30); t = t + 1 / 30
      if math.floor(t * 30) % 90 == 0 then print("BLOCK3 t", math.floor(t), math.floor(tanks[1].x), math.floor(tanks[1].y), tanks[1].orders[1] and tanks[1].orders[1].type) end
      local busy = 0
      for _, u in ipairs(tanks) do if #u.orders > 0 then busy = busy + 1 end end
      if busy == 0 then break end
    end
    local still = 0
    for _, u in ipairs(tanks) do if #u.orders > 0 then still = still + 1 end end
    local md = 1e9
    for _, u in ipairs(tanks) do md = math.min(md, U.dist(u.x, u.y, cx, cy)) end
    print(string.format("BLOCK3 flee to Commander: %s after %.1fs; nearest tank %d from him; Commander moved %d", still == 0 and "all settled" or (still .. " still pushing"), t, math.floor(md), math.floor(U.dist(c.x, c.y, cx, cy))))
    return
  end
  if os.getenv("PA_OVERSHOT") then
    -- the result screen after a win against AI v2 (rating row, opponent line)
    game = startFn({ size = 96, water = 0.3, seed = 7, aiV2 = true, players = { { human = true, ally = 1 }, { ally = 2, level = 5, profile = "Boomer", aiV2 = true } } })
    local w = game.world
    for _ = 1, 30 do game:update(1 / 30) end
    w:eliminate(2)
    for _ = 1, 10 do game:update(1 / 30) end
    game.overTime = love.timer.getTime() - 5
    for _ = 1, 6 do frame() end
    pending = "uishot_over.png"
    frame(); frame()
    print("UISHOT over")
    return
  end
  if os.getenv("PA_AATEST") then
    -- ships vs aircraft: 3 gunships attack a destroyer, then a battleship (and a tank, for scale)
    game = startFn({ size = 96, water = 0.6, seed = 11, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local map = w.map
    for _, ship in ipairs({ "boat", "destroyer", "battleship", "tank", "turret", "battleship+2boats", "battleship+3boats" }) do
      local layer = (ship == "tank" or ship == "turret") and "land" or "sea"
      local tx, ty = map:nearestTile(math.floor(map.w / 2), math.floor(map.h / 2), function(x, y) return map:passable(layer, x, y) end, 40)
      local x, y = map:center(tx, ty)
      local nb = tonumber(ship:match("%+(%d)boats") or "0")
      local target = w:spawn(ship:match("^%a+"), 1, x, y); target.built = 1
      local screen = {}
      for k = 1, nb do
        local bx, by = map:nearestTile(tx + (k == 1 and 2 or (k == 2 and -2 or 0)), ty + (k == 3 and 2 or 1), function(a, b) return map:passable("sea", a, b) end, 8)
        local sx2, sy2 = map:center(bx, by)
        screen[k] = w:spawn("boat", 1, sx2, sy2); screen[k].built = 1
      end
      local gs = {}
      for k = 1, (nb > 0 and 4 or 3) do gs[k] = w:spawn("gunship", 2, x + 400 + k * 20, y + k * 15); gs[k].built = 1; w:issue(gs[k], { type = "attack", target = target }) end
      local t = 0
      while t < 40 and target.alive do
        local any = false
        for _, g in ipairs(gs) do if g.alive then any = true end end
        if not any then break end
        w:update(1 / 30); t = t + 1 / 30
      end
      local left = 0
      for _, g in ipairs(gs) do if g.alive then left = left + 1 end end
      print(string.format("AATEST %-10s %s after %.1fs; gunships left %d", ship, target.alive and string.format("survived (%d%%)", math.floor(target.hp / target.maxhp * 100)) or "sunk", t, left))
      for _, g in ipairs(gs) do if g.alive then w:remove(g) end end
      for _, sb in ipairs(screen) do if sb.alive then w:remove(sb) end end
      if target.alive then w:remove(target) end
    end
    return
  end
  if os.getenv("PA_DDTEST") then
    -- a destroyer in the shallows against land armies of rising size, then gunships
    game = startFn({ size = 96, water = 0.6, seed = 11, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local map = w.map
    -- a sea tile right next to land
    local sx, sy
    for r = 0, 40 do
      for dy = -r, r do for dx = -r, r do
        local x, y = math.floor(map.w / 2) + dx, math.floor(map.h / 2) + dy
        if not sx and map:inBounds(x, y) and map:passable("sea", x, y) and map:inBounds(x + 1, y) and map:passable("land", x + 1, y) then sx, sy = x, y end
      end end
    end
    for _, case in ipairs({ { "tank", 3 }, { "tank", 5 }, { "tank", 7 }, { "artillery", 3 }, { "gunship", 2 }, { "battleship", 1 } }) do
      local key, n = case[1], case[2]
      local x, y = map:center(sx, sy)
      local dd = w:spawn("destroyer", 1, x, y); dd.built = 1
      local foes = {}
      for k = 1, n do
        local fx, fy
        if key == "battleship" then
          local tx, ty = map:nearestTile(sx - 6, sy, function(a, b) return map:passable("sea", a, b) end, 20)
          fx, fy = map:center(tx, ty)
        elseif key == "gunship" then
          fx, fy = x + 420 + k * 26, y + (k % 3) * 30
        else
          -- on the shore, already in their own range of it (a standing fight)
          local rng = key == "artillery" and 380 or 170
          local tx, ty = map:nearestTile(sx + 1 + (k % 3), sy + math.floor(k / 3) - 1, function(a, b)
            local cx2, cy2 = map:center(a, b)
            return map:passable("land", a, b) and U.dist(cx2, cy2, x, y) <= rng and U.dist(cx2, cy2, x, y) > (key == "artillery" and 120 or 0)
          end, 12)
          fx, fy = map:center(tx, ty)
          fx, fy = fx + (k % 2) * 8, fy + (k % 2) * 8
        end
        foes[k] = w:spawn(key, 2, fx, fy); foes[k].built = 1
        w:issue(foes[k], { type = "attack", target = dd })
      end
      local t = 0
      while t < 90 and dd.alive do
        local any = false
        for _, f in ipairs(foes) do if f.alive then any = true end end
        if not any then break end
        w:update(1 / 30); t = t + 1 / 30
      end
      local left, metal = 0, 0
      for _, f in ipairs(foes) do if f.alive then left = left + 1 end; metal = metal + f.def.cost.metal end
      print(string.format("DDTEST destroyer vs %d %-10s (%4d metal): %s after %.1fs; %d of them left", n, key, metal,
        dd.alive and string.format("WON (%d%% hp)", math.floor(dd.hp / dd.maxhp * 100)) or "sunk", t, left))
      for _, f in ipairs(foes) do if f.alive then w:remove(f) end end
      if dd.alive then w:remove(dd) end
    end
    return
  end
  if os.getenv("PA_BBSPOT") then
    -- a battleship far off, an extractor on land, two enemy scouts raiding it: does the
    -- extractor's sight let the battleship shell them?
    game = startFn({ size = os.getenv("PA_BBR") and 128 or 96, water = 0.6, seed = 11, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = false
    local map = w.map
    local sx, sy = map:nearestTile(os.getenv("PA_BBR") and 6 or math.floor(map.w / 2), os.getenv("PA_BBR") and 6 or math.floor(map.h / 2), function(x, y) return map:passable("sea", x, y) end, 40)
    local bx, by = map:center(sx, sy)
    local bb = w:spawn("battleship", 1, bx, by); bb.built = 1
    local lx, ly
    local r0 = tonumber(os.getenv("PA_BBR") or "20")
    for r = r0, r0 + 20 do
      for a = 0, 15 do
        local tx, ty = math.floor(sx + math.cos(a / 16 * 6.28) * r), math.floor(sy + math.sin(a / 16 * 6.28) * r)
        if not lx and map:inBounds(tx, ty) and map:passable("land", tx, ty) then lx, ly = tx, ty end
      end
    end
    local mx, my = map:center(lx, ly)
    local mex = w:spawn("mex", 1, mx, my); mex.built = 1
    local raiders = {}
    for k = 1, 2 do raiders[k] = w:spawn("scout", 2, mx + 120 + k * 15, my + 40); raiders[k].built = 1; w:issue(raiders[k], { type = "attack", target = mex }) end
    local shots, t = 0, 0
    local n0 = #w.projectiles
    while t < 30 and mex.alive do
      w:update(1 / 30); t = t + 1 / 30
      for _, p in ipairs(w.projectiles) do if p.source == bb and not p.counted then p.counted = true; shots = shots + 1 end end
    end
    local left = 0
    for _, r in ipairs(raiders) do if r.alive then left = left + 1 end end
    print(string.format("BBSPOT battleship %d away; shots fired %d; extractor %s after %.0fs; raiders left %d", math.floor(U.dist(bx, by, mx, my)), shots,
      mex.alive and "standing" or "lost", t, left))
    return
  end
  if os.getenv("PA_AUTOSHOT") then
    -- Automation: the panel (main and per-unit views) and each rule doing its job
    local A = require("src.automation")
    game = startFn({ size = 96, water = 0.2, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    A.v.flee, A.v.fleePct, A.v.rejoin, A.v.builders, A.v.builderMin, A.v.repair = true, 30, true, true, 3, true
    A.v.flee_scout = 60
    A.v.expand, A.v.power, A.v.idleOrder = true, true, "repair,expand,power"
    local c = w.teams[1].commander
    local fac = w:spawn("landfac", 1, c.x + 200, c.y + 200); fac.built = 1
    local map = w.map
    local function landNear(x, y)
      local tx, ty = map:tileAt(x, y)
      tx, ty = math.max(1, math.min(map.w - 2, tx)), math.max(1, math.min(map.h - 2, ty))
      local nx, ny = map:nearestTile(tx, ty, function(a, b2) return map:passable("land", a, b2) end, 40)
      return map:center(nx, ny)
    end
    local cx2, cy2 = map.w * w.T / 2, map.h * w.T / 2
    local fx, fy = landNear(c.x + (cx2 - c.x) * 0.6, c.y + (cy2 - c.y) * 0.6)
    local tank = w:spawn("tank", 1, fx, fy); tank.bornFrom, tank.bornX, tank.bornY = fac, fac.x, fac.y + 80
    tank.hp = tank.maxhp * 0.25
    local scout = w:spawn("scout", 1, fx, fy + 60); scout.bornFrom = fac
    scout.hp = scout.maxhp * 0.5
    local scout2 = w:spawn("scout", 1, fx, fy + 120); scout2.bornFrom = fac
    scout2.hp = scout2.maxhp * 0.7
    local b = w:spawn("builder", 1, c.x + 100, c.y)
    local b2 = w:spawn("builder", 1, fx + 300, fy - 300)
    w.teams[1].energy = 100
    local sol = w:spawn("solar", 1, c.x + 160, c.y - 80); sol.built = 1; sol.hp = sol.maxhp * 0.5
    game.opts.autotest = false
    for i = 1, 40 do
      game:update(1 / 30)
      if os.getenv("PA_AUTODBG") and i % 5 == 0 then
        local o = tank.orders[1]
        print("AUTODBG", i, tank.alive, math.floor(tank.hp), o and o.type or "idle", o and math.floor(o.x or 0), o and math.floor(o.y or 0), math.floor(tank.x), math.floor(tank.y), tank.disarmed, require("src.automation").timer)
      end
    end
    game.opts.autotest = true
    local function ord(u) local o = u.orders[1]; return o and o.type or "idle" end
    local nb = 0
    for _, k in ipairs(fac.queue) do if k == "builder" then nb = nb + 1 end end
    local o2 = b2.orders[1]
    print(string.format("AUTOTEST tank(25%%)=%s scout(50%%, own 60%%)=%s scout(70%%)=%s builder=%s plant queue builders=%d builder2=%s %s",
      ord(tank), ord(scout), ord(scout2), ord(b), nb, ord(b2), o2 and o2.key or ""))
    -- power first: with energy at 100 of 3750, an idle constructor should build a solar
    b2.orders = {}
    A.v.idleOrder = "power,expand,repair"
    w.teams[1].energy = 100
    A.timer = 0
    game.opts.autotest = false
    game:update(1 / 30)
    game.opts.autotest = true
    local o3 = b2.orders[1]
    print("AUTOTEST power first: builder2=" .. ord(b2) .. " " .. (o3 and o3.key or ""))
    b2.orders = {}
    A.v.idleOrder = "expand,power,repair"
    A.timer = 0
    game.opts.autotest = false
    game:update(1 / 30)
    game.opts.autotest = true
    local o4 = b2.orders[1]
    print("AUTOTEST expand first: builder2=" .. ord(b2) .. " " .. (o4 and o4.key or "") .. (o4 and o4.tx and string.format(" at %d,%d (it stands at %d,%d)", o4.tx, o4.ty, w.map:tileAt(b2.x, b2.y)) or ""))
    -- drag the third row (Power) onto the first
    A.v.idleOrder = "repair,expand,power"
    do
      local rects = A.rects()
      local hp, h1
      for _, r in ipairs(rects) do
        if r.kind == "handle" and r.idx == 3 then hp = r end
        if r.kind == "handle" and r.idx == 1 then h1 = r end
      end
      A.click(hp.x + 5, hp.y + 5)
      A.release(h1.x + 5, h1.y + 5)
      print("AUTOTEST drag Power to the top: " .. A.v.idleOrder)
      A.v.idleOrder = "repair,expand,power"
    end
    A.v.idleOrder = "repair,expand,power"
    game.autoOpen = true
    for _ = 1, 4 do frame() end
    pending = "uishot_auto.png"
    frame(); frame()
    A.view = "units"
    frame()
    pending = "uishot_auto_units.png"
    frame(); frame()
    print("UISHOT auto")
    return
  end
  if os.getenv("PA_PROF") then
    -- where does the time go in a busy mid-game? two v2 AIs, medium map, some water
    game = startFn({ size = 128, water = 0.3, seed = 1793103957, autotest = true,
      aiV2Teams = { [1] = true, [2] = true }, level = 5, level1 = 5, players = { { ally = 1 }, { ally = 2 } } })
    local w = game.world
    local W = getmetatable(w).__index
    local prof = {}
    local function wrap(obj, name)
      local f = obj[name]
      obj[name] = function(...)
        local t0 = love.timer.getTime()
        local a, b2, c2, d2 = f(...)
        local p = prof[name] or { t = 0, n = 0 }
        prof[name] = p
        p.t, p.n = p.t + love.timer.getTime() - t0, p.n + 1
        return a, b2, c2, d2
      end
    end
    for _, n in ipairs({ "update", "updateWeapon", "updateAA", "findTarget", "spotted", "updateUnit", "separate", "repairZones", "rebuildGrid", "query", "setDest", "updateFactory", "followPath" }) do
      if W[n] then wrap(W, n) end
    end
    local AIm = getmetatable(game.ais[1]).__index
    local aiT = 0
    local total0 = love.timer.getTime()
    local segs = {}
    for sec = 1, 480 do
      local s0 = love.timer.getTime()
      for _ = 1, 30 do
        w:update(1 / 30)
        local a0 = love.timer.getTime()
        for _, ai in ipairs(game.ais) do ai:update(1 / 30) end
        aiT = aiT + love.timer.getTime() - a0
        if w.over then break end
      end
      if sec % 60 == 0 then
        local n = 0
        for _, e in ipairs(w.entities) do if e.alive then n = n + 1 end end
        segs[#segs + 1] = string.format("%d:00 %d entities, %.0f ms per game-second", sec / 60, n, (love.timer.getTime() - s0) * 1000)
      end
      if w.over then break end
    end
    print("PROF total " .. string.format("%.1f s for %.0f s of game, AI %.1f s", love.timer.getTime() - total0, w.time, aiT))
    -- drawing: frames at zoom 1 over the busiest spot, and zoomed out to the whole map
    local R = require("src.render")
    local UI = require("src.ui")
    local busiest, bn
    for _, e in ipairs(w.entities) do
      if e.alive and not e.def.building then
        local n = 0
        w:query(e.x, e.y, 500, function() n = n + 1 end)
        if not bn or n > bn then busiest, bn = e, n end
      end
    end
    local parts = {}
    local function wrapM(mod, name, label)
      local f = mod[name]
      mod[name] = function(...)
        local t0 = love.timer.getTime()
        local r1, r2 = f(...)
        parts[label] = (parts[label] or 0) + love.timer.getTime() - t0
        return r1, r2
      end
    end
    for _, n in ipairs({ "drawWorld", "drawEntity", "drawHealth", "updateFogImage", "drawMinimap" }) do if R[n] then wrapM(R, n, "R." .. n) end end
    for _, n in ipairs({ "draw", "drawMinimap", "drawCommanderCard", "drawSidebar", "drawTop", "drawInfo", "drawCard", "drawOrders" }) do if UI[n] then wrapM(UI, n, "UI." .. n) end end
    for _, z in ipairs({ 1, 0.5, 0.25 }) do
      game.cam.zoom = z
      if busiest then game:centerOn(busiest.x, busiest.y) end
      for _ = 1, 3 do game:draw() end
      local f0 = love.timer.getTime()
      local tw, tu = 0, 0
      for _ = 1, 20 do
        local a0 = love.timer.getTime()
        game:draw()
        love.graphics.present()
        tw = tw + love.timer.getTime() - a0
      end
      print(string.format("PROF draw zoom %.2f: %.1f ms per frame", z, tw / 20 * 1000))
      local pl = {}
      for k, v in pairs(parts) do pl[#pl + 1] = string.format("%s %.1f", k, v / 23 * 1000) end
      table.sort(pl)
      print("PROF   parts (ms/frame): " .. table.concat(pl, ", "))
      parts = {}
    end
    for _, l in ipairs(segs) do print("PROF " .. l) end
    local list = {}
    for k, v in pairs(prof) do list[#list + 1] = { k, v } end
    table.sort(list, function(a, b2) return a[2].t > b2[2].t end)
    for _, it in ipairs(list) do print(string.format("PROF %-14s %7.2f s  %9d calls", it[1], it[2].t, it[2].n)) end
    return
  end
  if os.getenv("PA_FLAGFLEE") then
    -- Auto flee with a flag: to the flag, out of the selection, skipped by select-all; and re-armed
    -- later even with nothing to repair it
    local A = require("src.automation")
    A.v.flee, A.v.fleePct = true, 30
    game = startFn({ size = 96, water = 0.1, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local c = w.teams[1].commander
    local map = w.map
    local function land(x, y)
      local tx, ty = map:tileAt(x, y)
      local nx, ny = map:nearestTile(math.max(1, math.min(map.w - 2, tx)), math.max(1, math.min(map.h - 2, ty)), function(a2, b2) return map:passable("land", a2, b2) end, 40)
      return map:center(nx, ny)
    end
    local cx, cy = map.w * w.T / 2, map.h * w.T / 2
    local fx, fy = land(c.x + (cx - c.x) * 0.3, c.y + (cy - c.y) * 0.3)
    game.flag = { x = fx, y = fy }
    local tx, ty = land(c.x + (cx - c.x) * 0.7, c.y + (cy - c.y) * 0.7)
    local hurt = w:spawn("tank", 1, tx, ty); hurt.hp = hurt.maxhp * 0.2
    local fine = w:spawn("tank", 1, tx + 30, ty)
    game.selected = { [hurt] = true, [fine] = true }
    game.opts.autotest = false
    for _ = 1, 20 do game:update(1 / 30) end
    local o = hurt.orders[1]
    print(string.format("FLAGFLEE order %s to the flag? %s; still selected? %s", o and o.type or "none",
      tostring(o and U.dist(o.x, o.y, fx, fy) < 120), tostring(game.selected[hurt] == true)))
    game:selectAllArmy()
    print("FLAGFLEE Ctrl+A picks the fleeing one? " .. tostring(game.selected[hurt] == true) .. "; the healthy one? " .. tostring(game.selected[fine] == true))
    local t = 0
    while hurt.alive and t < 90 and (hurt.disarmed or hurt.orders[1]) do game:update(1 / 30); t = t + 1 / 30 end
    -- a unit hurt right next to the flag flees too (it used to fight on there)
    local near = w:spawn("tank", 1, fx + 60, fy); near.hp = near.maxhp * 0.2
    for _ = 1, 20 do game:update(1 / 30) end
    print("FLAGFLEE hurt beside the flag flees? " .. tostring(near.autoFled ~= nil) .. "; guns off? " .. tostring(near.disarmed == true))
    game.opts.autotest = true
    print(string.format("FLAGFLEE re-armed after %.0fs at the flag (hp %d%%, nothing to repair it)", t, hurt.hp / hurt.maxhp * 100))
    return
  end
  if os.getenv("PA_LOGCMD") then
    -- the match log's Commander position column, over a few minutes of AI vs AI
    game = startFn({ size = 112, water = 0.3, seed = tonumber(os.getenv("PA_LOGCMD")) or 7, autotest = true,
      level = 5, level1 = 5, profile = "Random", profile1 = "Random", aiV2Teams = { [1] = true, [2] = true } })
    local lg = require("src.matchlog").start(game)
    game.log = lg
    for _ = 1, 30 * 60 * 7 do game:update(1 / 30) end
    lg:flush()
    return
  end
  if os.getenv("PA_SCOUTFLEE") then
    -- per-unit flee: scouts at 60%, everyone else 30%; scouts driven into enemies of each kind
    local A = require("src.automation")
    A.v.flee, A.v.fleePct, A.v.flee_scout = true, 30, 60
    local kinds = { "tank", "artillery", "flak", "turret", "scout", "gunship", "destroyer" }
    for _, foe in ipairs(kinds) do
      game = startFn({ size = 96, water = 0.3, seed = 5, autotest = true })
      game.ais = {}
      local w = game.world
      w.noFog = true
      local map = w.map
      local c = w.teams[1].commander
      local function land(x, y, dom)
        local tx, ty = map:tileAt(x, y)
        local nx, ny = map:nearestTile(math.max(1, math.min(map.w - 2, tx)), math.max(1, math.min(map.h - 2, ty)), function(a2, b2) return map:passable(dom or "land", a2, b2) end, 60)
        return map:center(nx, ny)
      end
      local cx, cy = map.w * w.T / 2, map.h * w.T / 2
      local ex, ey = land(c.x + (cx - c.x) * 0.8, c.y + (cy - c.y) * 0.8, foe == "destroyer" and "sea" or nil)
      for k = 1, (foe == "turret" and 1 or 3) do w:spawn(foe, 2, ex + k * 20, ey) end
      local sx, sy = land(c.x + (cx - c.x) * 0.4, c.y + (cy - c.y) * 0.4)
      local scouts = {}
      for k = 1, 4 do
        local u = w:spawn("scout", 1, sx + k * 18, sy)
        scouts[#scouts + 1] = { u = u }
        w:issue(u, { type = "amove", x = ex, y = ey })
      end
      game.opts.autotest = false
      local t = 0
      while t < 40 do
        game:update(1 / 30); t = t + 1 / 30
        for _, r in ipairs(scouts) do
          local u = r.u
          if u.alive then
            r.minhp = math.min(r.minhp or 1, u.hp / u.maxhp)
            local o = u.orders[1]
            if o and o.type == "retreat" and not r.fled then r.fled = u.hp / u.maxhp end
            r.last = u.hp / u.maxhp
          elseif not r.dead then r.dead = t end
        end
      end
      game.opts.autotest = true
      local out = {}
      for _, r in ipairs(scouts) do
        out[#out + 1] = string.format("%s%s", r.fled and string.format("fled@%d%%", r.fled * 100) or "noflee",
          r.dead and string.format("/died(last seen %d%%)", r.last * 100) or string.format("/alive %d%%", r.u.hp / r.u.maxhp * 100))
      end
      print("SCOUTFLEE vs " .. foe .. ": " .. table.concat(out, "  "))
    end
    return
  end
  if os.getenv("PA_NUKESHOT") then
    -- the Nuke becomes ready: the banner, and the flashing button under the Commander card
    game = startFn({ size = 96, water = 0.2, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    local c = w.teams[1].commander
    for _ = 1, 60 do w:update(1 / 30) end
    c.clevel, c.nukeReady = 5, w.time
    for _ = 1, 4 do frame() end
    pending = "uishot_nuke.png"
    frame(); frame()
    print("UISHOT nuke", tostring(game.nukeBtn ~= nil))
    return
  end
  if os.getenv("PA_COREFOG") then
    -- the Power Core node outlined under the fog, in the view and on the minimap
    game = startFn({ size = 128, water = 0.3, seed = 31, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = false
    for _ = 1, 10 do w:update(1 / 30) end
    w.fogChanged = true
    local cn = w.map.coreNode
    game.cam.zoom = 0.6
    game:centerOn((cn.x + 1) * w.T, (cn.y + 1) * w.T)
    for _ = 1, 5 do frame() end
    pending = "uishot_corefog.png"
    frame(); frame()
    print("UISHOT corefog visible=" .. tostring(w.visible[(cn.y + 1) * w.map.w + cn.x + 1]))
    return
  end
  if os.getenv("PA_BOXTEST") then
    -- a selection box dragged while the view pans: it should cover the whole span on the map
    game = startFn({ size = 128, water = 0.1, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local c = w.teams[1].commander
    local list = {}
    for k = 0, 9 do list[#list + 1] = w:spawn("tank", 1, c.x + k * 300, c.y + 40) end
    game.cam.zoom = 1
    game:centerOn(c.x + 200, c.y)
    local sx, sy = game:worldToScreen(c.x - 40, c.y - 40)
    game:mousepressed(sx, sy, 1)
    -- the view scrolls 2500 to the right while the mouse is held
    game:centerOn(c.x + 2700, c.y)
    local ex, ey = game:worldToScreen(c.x + 2800, c.y + 100)
    game:mousereleased(ex, ey, 1)
    local n = 0
    for _, t in ipairs(list) do if game.selected[t] then n = n + 1 end end
    print("BOXTEST selected " .. n .. " of 10 tanks spread over 2700 (the view panned 2500 during the drag)")
    return
  end
  if os.getenv("PA_PODDEP") then
    -- across many maps: does any drop pod lock up a metal deposit?
    local bad, n = 0, 0
    for seed = 1, 60 do
      local g = startFn({ size = ({ 96, 128, 160 })[seed % 3 + 1], water = ({ 0.15, 0.3, 0.45 })[seed % 3 + 1], seed = seed * 7919, autotest = true,
        players = seed % 2 == 0 and { { ally = 1 }, { ally = 2 }, { ally = 3 }, { ally = 4 } } or nil })
      local w = g.world
      for _, dp in ipairs(w.map.deposits) do
        if not dp.sea then
          n = n + 1
          if not w:canPlace("mex", dp.x, dp.y, 1, "land") and not w:canPlace("mex", dp.x, dp.y, 2, "land") then
            for _, pod in pairs(w.dropPods) do
              local ptx, pty = math.floor(pod.x / w.T), math.floor(pod.y / w.T)
              if math.abs(ptx - dp.x) <= 1 and math.abs(pty - dp.y) <= 1 then bad = bad + 1 end
            end
          end
        end
      end
    end
    print("PODDEP deposits locked by a pod: " .. bad .. " of " .. n .. " land deposits on 60 maps")
    return
  end
  if os.getenv("PA_MECHTEST") then
    -- priority orders, abandoned-build decay, passing through own buildings, the reserved pod
    game = startFn({ size = 96, water = 0.1, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local tm = w.teams[1]
    tm.metal, tm.energy = 5000, 50000
    local c = w.teams[1].commander
    local map = w.map
    local function land(x, y)
      local tx, ty = map:tileAt(x, y)
      local nx, ny = map:nearestTile(tx, ty, function(a, b2) return map:passable("land", a, b2) end, 30)
      return map:center(nx, ny)
    end
    -- 1. priority: a plant halfway through a tank gets a priority constructor
    local fx, fy = land(c.x + 300, c.y + 250)
    local f = w:spawn("landfac", 1, fx, fy); f.built = 1
    f.queue = { "tank", "tank" }; f.repeatMode = true
    for _ = 1, 150 do w:update(1 / 30) end
    local before = f.progress
    game.selected = { [f] = true }
    local m0 = tm.metal
    game:queueUnit("builder", 1, false, true)
    local t = 0
    while f.prio and #f.prio > 0 and t < 30 do w:update(1 / 30); t = t + 1 / 30 end
    print(string.format("MECH priority: tank paused at %d%% (now %d%%), constructor out after %.1fs, queue now %s, metal spent %d (a constructor is %d, +35%% = %d)",
      before * 100, f.progress * 100, t, table.concat(f.queue, ","), m0 - tm.metal, D.units.builder.cost.metal, D.units.builder.cost.metal * 1.35))
    -- 2. decay: a solar left at 99%
    local sx, sy = land(c.x - 250, c.y + 250)
    local sol = w:spawn("solar", 1, sx, sy, 0.99)
    sol.hp = sol.maxhp * 0.99
    local t2 = 0
    while sol.alive and t2 < 40 do w:update(1 / 30); t2 = t2 + 1 / 30 end
    print(string.format("MECH decay: abandoned solar at 99%% %s after %.1fs", sol.alive and "still standing" or "gone", t2))
    -- 3. pass-through: a tank walks straight across a wall of our own solars
    local wx, wy = land(c.x, c.y + 600)
    local wtx, wty = map:tileAt(wx, wy)
    for k = -4, 4 do local s2 = w:spawn("solar", 1, (wtx + 0.5 + 0) * w.T + w.T / 2, (wty + k * 2) * w.T + w.T, 1) end
    local tk = w:spawn("tank", 1, wx - 200, wy); tk.built = 1
    w:issue(tk, { type = "move", x = wx + 200, y = wy })
    local t3 = 0
    print("MECH path", tk.path and #tk.path or "nil", w.passFriendly, map.allyOf and map.allyOf[1])
    while t3 < 15 and U.dist(tk.x, tk.y, wx + 200, wy) > 30 do
      w:update(1 / 30); t3 = t3 + 1 / 30
      if math.floor(t3 * 30) % 60 == 0 then print("MECH tank", math.floor(tk.x - wx), math.floor(tk.y - wy), tk.orders[1] and tk.orders[1].type, tk.path and #tk.path) end
    end
    print(string.format("MECH pass-through: tank crossed our solar wall in %.1fs (straight line would take %.1fs), %s", t3, 400 / tk.def.speed,
      U.dist(tk.x, tk.y, wx + 200, wy) <= 30 and "arrived" or "did not arrive"))
    -- 4. the pod is reserved
    local pod = w.dropPods[1]
    local ptx, pty = map:tileAt(pod.x, pod.y)
    print("MECH pod: solar on the drop pod allowed? " .. tostring(w:canPlace("solar", ptx, pty, 1, "land")))
    return
  end
  if os.getenv("PA_PODSHOT") then
    -- the drop pod: coming down, then the wreck with the Commander hurt and recharging beside it
    game = startFn({ size = 96, water = 0.2, seed = 5, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local c = w.teams[1].commander
    game.cam.zoom = 1.3
    game:centerOn(c.x - 20, c.y - 60)
    for _ = 1, 18 do w:update(1 / 30) end
    for _ = 1, 3 do frame() end
    pending = "uishot_pod1.png"
    frame(); frame()
    for _ = 1, 120 do w:update(1 / 30) end
    c.hp = c.maxhp * 0.5
    for _ = 1, 10 do w:update(1 / 30) end
    for _ = 1, 3 do frame() end
    pending = "uishot_pod2.png"
    frame(); frame()
    print("UISHOT pod", math.floor(c.hp))
    return
  end
  if os.getenv("PA_CORESHOT") then
    -- the Power Core tower built on its node, a Defense Tower beside it, zoomed in
    game = startFn({ size = 112, water = 0.3, seed = 31, autotest = true })
    game.ais = {}
    local w = game.world
    w.noFog = true
    local cn = w.map.coreNode
    local x, y = (cn.x + 1) * w.T, (cn.y + 1) * w.T
    local pc = w:spawn("powercore", 1, x, y); pc.built = 1
    local tw = w:spawn("turret", 1, x + 3 * w.T + w.T / 2, y + w.T / 2); tw.built = 1
    game.cam.zoom = tonumber(os.getenv("PA_ZOOM") or "0.55")
    game:centerOn(x, y)
    for _ = 1, 6 do frame() end
    pending = "uishot_core.png"
    frame(); frame()
    print("UISHOT core")
    return
  end
  if os.getenv("PA_MAPVIEW") then
    -- the whole map from above (fog off), with deposits and starts: PA_MAPSEED, PA_SIZE, PA_WATER
    game = startFn({ size = tonumber(os.getenv("PA_SIZE") or "128"), water = tonumber(os.getenv("PA_WATER") or "0.3"),
      seed = tonumber(os.getenv("PA_MAPSEED")), autotest = true })
    game.world.noFog = true
    game.ais = {}
    local w = game.world
    local W, H = w.map.w * w.T, w.map.h * w.T
    game.cam.zoom = math.min(love.graphics.getWidth() / W, (love.graphics.getHeight() - 240) / H) * 0.98
    game:centerOn(W / 2, H / 2)
    for _ = 1, 4 do frame() end
    pending = "uishot_map.png"
    frame(); frame()
    print("UISHOT map")
    return
  end
  local opts = { size = mode == "arena" and 80 or 112, water = 0.3, seed = 31, autotest = true,
    players = { { ally = 1, level = 5 }, { ally = 2, level = 5 }, { ally = 1, level = 5 }, { ally = 2, level = 5 } } }
  if os.getenv("PA_MODS") then
    opts.mods = {}
    for k in os.getenv("PA_MODS"):gmatch("[^,]+") do opts.mods[k] = true end
    if opts.mods.sandbox then opts.sandbox = { you = { tank = 30, artillery = 10, battleship = 2 }, enemy = { tank = 30, gunship = 8 } } end
  end
  if mode == "arena" then opts.mode = "arena"; opts.players[1].class = os.getenv("PA_CLASS") or "ranger" end
  if mode == "arena" and os.getenv("PA_FIVE") then
    opts.size, opts.template = 112, "battlefield"
    opts.players = {}
    for i = 1, 10 do opts.players[i] = { ally = i % 2 == 1 and 1 or 2, level = 5 } end
    opts.players[1].class = os.getenv("PA_CLASS") or "ranger"
  end
  if mode == "craft" and os.getenv("PA_DECOY") then
    opts = { mode = "craft", size = 88, seed = 31,
      players = { { human = true, ally = 1, race = "vanguard", class = "ranger" }, { ally = 2, level = 1, race = "warband" } } }
    game = startFn(opts)
    local w = game.world
    local A = require("src.arena")
    local h = w.teams[1].commander
    h.skills = { { key = "decoy", readyAt = 0 } }
    local foes = {}
    for i = 1, 4 do foes[i] = w:spawn(i <= 2 and "grunt" or "headhunter", 2, h.x + 200 + i * 20, h.y + 60) end
    for _, f in ipairs(foes) do w:issue(f, { type = "attack", target = h }) end
    for _ = 1, 30 do game:update(1 / 30) end
    print("before", h.hp)
    print("cast", A.useSkill(w, h, 1, h.x - 150, h.y))
    local hp0 = h.hp
    for _ = 1, 90 do game:update(1 / 30) end
    local dec
    for _, e in ipairs(w.entities) do if e.key == "decoy" then dec = e end end
    print("hero lost", hp0 - h.hp, "decoy hp", dec and dec.hp, dec and dec.maxhp)
    for _, f in ipairs(foes) do local o = f.orders[1]; print("foe", f.key, o and o.type, o and o.target and o.target.key, f.chase and f.chase.key) end
    return
  end
  if mode == "craft" and os.getenv("PA_BUILDQ") then
    -- shift-queued builds and group builds, played through the game's own commands
    opts = { mode = "craft", size = 88, seed = 31,
      players = { { human = true, ally = 1, race = "warband" }, { ally = 2, level = 1, race = "vanguard" } } }
    game = startFn(opts)
    local w = game.world
    w.teams[1].gold, w.teams[1].wood = 3000, 1000
    local function step(sec) local tt = w.time + sec; while w.time < tt and not w.over do for _ = 1, 15 do game:update(1 / 30) end; frame() end end
    local function sel(pred) local l = {}; for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and pred(e) then l[#l + 1] = e end end; game:select(l); return l end
    local hall = sel(function(e) return e.def.hall end)[1]
    step(4)
    local ws = sel(function(e) return e.def.worker end)
    local function dump(tag)
      for _, e in ipairs(ws) do
        local t = {}
        for _, o in ipairs(e.orders) do t[#t + 1] = o.type .. (o.key and (":" .. o.key) or "") .. (o.kind and (":" .. o.kind) or "") end
        print(tag, e.id, table.concat(t, ","))
      end
    end
    -- one worker, three shift-queued burrows
    game:select({ ws[1] })
    game.buildKey = "w_burrow"
    print("q1", game:placeBuilding(hall.x + 200, hall.y + 180, true))
    print("q2", game:placeBuilding(hall.x + 280, hall.y + 180, true))
    print("q3", game:placeBuilding(hall.x + 360, hall.y + 180, true))
    dump("AFTERQ")
    -- three workers, one barracks
    game:select({ ws[2], ws[3], ws[4] })
    game.buildKey = "w_barracks"
    local placed
    for _, off in ipairs({ { -250, 250 }, { 0, 300 }, { 250, 320 }, { -300, 0 }, { 300, -60 }, { 0, -300 }, { 200, 450 } }) do
      if not placed and game:placeBuilding(hall.x + off[1], hall.y + off[2], false) then placed = off end
    end
    print("grp", placed and placed[1], placed and placed[2])
    dump("AFTERG")
    step(90)
    dump("LATER")
    local n = {}
    for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and e.def.building then n[e.key] = (n[e.key] or 0) + (e.built >= 1 and 1 or 0) end end
    for k, v in pairs(n) do print("BUILT", k, v) end
    return
  end
  if mode == "craft" and os.getenv("PA_HUMAN") then
    -- play team 1 by hand through the game's own commands
    opts = { mode = "craft", size = 88, seed = 31,
      players = { { human = true, ally = 1, race = os.getenv("PA_RACE") or "vanguard", class = os.getenv("PA_CLASS") }, { ally = 2, level = 5, race = "warband" } } }
    game = startFn(opts)
    local w = game.world
    local function step(sec) local tt = w.time + sec; while w.time < tt and not w.over do for _ = 1, 15 do game:update(1 / 30) end; frame() end end
    local function sel(pred) local l = {}; for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and pred(e) then l[#l + 1] = e end end; game:select(l); return l end
    local hall = sel(function(e) return e.def.hall end)[1]
    game:queueUnit((os.getenv("PA_RACE") == "warband") and "peon" or "peasant", 2)
    step(5)
    local wk = sel(function(e) return e.def.worker end)
    game.buildKey = (os.getenv("PA_RACE") == "warband") and "w_burrow" or "v_farm"
    print("farm placed", game:placeBuilding(hall.x + 150, hall.y + 150))
    step(25)
    for _, e in ipairs(w.entities) do
      if e.team == 1 and (e.def.worker or (e.def.building and e.built < 1)) then
        local o = e.orders and e.orders[1]
        print("W", e.key, math.floor(e.x), math.floor(e.y), e.built, o and o.type, o and (o.key or o.kind), o and o.ent and o.ent.key, e.inMine and "mine" or "", e.dormant and "dorm" or "")
      end
    end
    sel(function(e) return e.def.worker end)
    game.buildKey = (os.getenv("PA_RACE") == "warband") and "w_barracks" or "v_barracks"
    print("barracks placed", game:placeBuilding(hall.x + 60, hall.y + 260))
    -- a worker to the trees
    local one = sel(function(e) return e.def.worker end)[1]
    game:select({ one })
    local tx, ty = require("src.craft").nearestTree(w, w.map:tileAt(one.x, one.y)).x, nil
    local tr = require("src.craft").nearestTree(w, w.map:tileAt(one.x, one.y))
    game:rightClick((tr.x + 0.5) * w.T, (tr.y + 0.5) * w.T)
    step(60)
    sel(function(e) return e.key:match("barracks") and e.built >= 1 end)
    game:queueUnit((os.getenv("PA_RACE") == "warband") and "grunt" or "footman", 3)
    game:queueUnit((os.getenv("PA_RACE") == "warband") and "grunt" or "footman", 1, true)
    local h = w.teams[1].commander
    game:select({ h })
    game:keypressed("q")
    step(40)
    print(string.format("gold %d wood %d food %d/%d", w.teams[1].gold, w.teams[1].wood, w.teams[1].foodUsed, w.teams[1].foodCap))
    for _, e in ipairs(w.entities) do if e.team == 1 and not e.def.worker then io.write(e.key, " ") end end print()
    game:select({ h })
    game.cam.zoom = 0.8
    game:centerOn(hall.x, hall.y + 150)
    for _ = 1, 4 do game:update(1 / 30); frame() end
    pending = "uishot_craft_human.png"
    frame(); frame()
    print("UISHOT human")
    return
  end
  if mode == "craft" then
    opts = { mode = "craft", size = 88, seed = tonumber(os.getenv("PA_SEED") or "31"), autotest = true, template = os.getenv("PA_TEMPLATE"),
      players = { { ally = 1, level = 5, race = os.getenv("PA_RACE") or "vanguard", class = os.getenv("PA_CLASS") }, { ally = 2, level = 5, race = "warband" } } }
    if opts.template == "cross" then
      opts.players[3] = { ally = 1, level = 5, race = opts.players[1].race }
      opts.players[4] = { ally = 2, level = 5, race = "warband" }
    end
  end
  if mode == "coh" then
    -- Commander of Heroes: our squads played through the game's own commands (select, attack-move,
    -- Q / W) against the computer; prints tickets as it goes, then a screenshot
    local SQ = require("src.squads")
    local secs2 = tonumber(os.getenv("PA_SECS") or "180")
    opts = { mode = "rts", coh = true, size = os.getenv("PA_WIHMODE") and 128 or 96, water = 0.15, seed = tonumber(os.getenv("PA_SEED") or "31"), mods = { squads = true },
      squadSetup = SQ.defaults(), enemySquads = os.getenv("PA_MIRROR") and "mirror" or "own",
      cohMode = os.getenv("PA_WIHMODE") and "wih" or "conquest", hillFrac = os.getenv("PA_WIHMODE") and 0.22 or nil, rockFrac = os.getenv("PA_WIHMODE") and 0.06 or nil,
      players = { { human = true, ally = 1 }, { ally = 2, level = tonumber(os.getenv("PA_LEVEL") or "5") } } }
    game = startFn(opts)
    local w = game.world
    for t = 1, 2 do
      local l = {}
      for _, sq in ipairs(SQ.squadsOf(w, t)) do l[#l + 1] = sq.type end
      print("SQUADS", t, table.concat(l, ","))
    end
    local nextOrder, nextLog = 0, 0
    if os.getenv("PA_PLANSHOT") then
      -- War is Hell: how the computer's force moves (fog off, zoomed out, on the red army)
      game.ais[#game.ais + 1] = SQ.newAI(w, 1, 5)
      w.noFog = true
      local secs3 = tonumber(os.getenv("PA_PLANSHOT")) or 40
      local dmg = {}
      local d0 = w.damage
      w.damage = function(self2, o, amount, attacker)
        if attacker and attacker.team and o.alive then
          local k = attacker.team .. " " .. (attacker.key or "?")
          dmg[k] = (dmg[k] or 0) + math.min(amount, o.hp)
        end
        return d0(self2, o, amount, attacker)
      end
      if os.getenv("PA_FULL") then
        for i = 1, 600 * 30 do
          if w.over then break end
          if os.getenv("PA_AIRDBG") and i % 300 == 0 then
            for _, sq in ipairs(SQ.squadsOf(w, 2)) do
              if sq.type == "air" then
                local L = sq.leader
                local o = L and L.alive and L.orders[1]
                print("AIR", math.floor(w.time), L and L.alive, o and o.type, o and o.x and math.floor(o.x), o and o.y and math.floor(o.y), L and math.floor(L.x), L and math.floor(L.y), L and L.target and L.target.key, sq.broken)
              end
            end
          end
          w:update(1 / 30); for _, ai in ipairs(game.ais) do ai:update(1 / 30) end
        end
        local ks = {}
        for k, v in pairs(dmg) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do print("DMG", k, math.floor(dmg[k])) end
        print("OVER", w.over and w.over.winnerAlly, math.floor(w.time))
        return
      end
      for _ = 1, secs3 * 30 do w:update(1 / 30); for _, ai in ipairs(game.ais) do ai:update(1 / 30) end end
      local x, y, n = 0, 0, 0
      for _, e in ipairs(w.entities) do if e.alive and e.team == 2 and e.squad then x, y, n = x + e.x, y + e.y, n + 1 end end
      for _, sq in ipairs(SQ.squadsOf(w, 2)) do
        local L = sq.leader
        if L and L.alive then print("RED", sq.type, math.floor(L.x), math.floor(L.y)) end
      end
      for _, sq in ipairs(SQ.squadsOf(w, 1)) do
        local L = sq.leader
        if L and L.alive then print("BLUE", sq.type, math.floor(L.x), math.floor(L.y)) end
      end
      game.cam.zoom = 0.5
      if n > 0 then game:centerOn(x / n, y / n) end
      game:select({})
      for _ = 1, 4 do frame() end
      pending = "uishot_plan.png"
      frame(); frame()
      print("UISHOT plan")
      return
    end
    if os.getenv("PA_PAD") then
      -- controller hints (and the command wheel held open on an entry)
      for _ = 1, 30 do game:update(1 / 30) end
      local sq = SQ.squadsOf(w, 1)[1]
      game:pickSquad(sq)
      game:centerOn(sq.leader.x, sq.leader.y)
      PAD.fake({ wheel = tonumber(os.getenv("PA_PAD")) ~= 0 and tonumber(os.getenv("PA_PAD")) or nil })
      for _ = 1, 4 do frame() end
      pending = "uishot_pad.png"
      frame(); frame()
      print("UISHOT pad")
      return
    end
    if os.getenv("PA_MERCY") then
      -- War is Hell endgame: some of ours fall, the enemy is cut down to two wounded men who
      -- run off bleeding; they give up, the mercy screen comes up
      for _ = 1, 30 do game:update(1 / 30) end
      local mine = SQ.squadsOf(w, 1)
      for i = 1, 4 do w:kill(mine[i].members[#mine[i].members]) end
      w:kill(mine[2].members[1])
      local foes = {}
      for _, e in ipairs(w.entities) do if e.alive and e.team == 2 and not e.def.building then foes[#foes + 1] = e end end
      for i = (os.getenv("PA_MERCY") == "trail" and 4 or 3), #foes do w:kill(foes[i]) end
      local L = mine[1].leader
      for k = 1, os.getenv("PA_MERCY") == "trail" and 3 or 2 do
        local f = foes[k]
        f.hp = f.maxhp * 0.3
        f.x, f.y = L.x + 260, L.y + (k - 1.5) * 60
        w:issue(f, { type = "move", x = f.x + 500, y = f.y + 300 })
      end
      local surr, broke
      for i = 1, 9000 do
        game:update(1 / 30)
        if not broke and foes[1].broken then
          broke = i
          print("BROKEN at frame", i, "hide at", math.floor(foes[1].hideX or -1), math.floor(foes[1].hideY or -1))
        end
        if broke and i == broke + 240 then
          -- go after them
          local l = {}
          for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and not e.def.building then l[#l + 1] = e end end
          game:select(l)
          game:commandMove(foes[1].hideX, foes[1].hideY, "amove", false)
        end
        if i % 600 == 0 then
          local f = foes[1]
          local nd = 1e9
          for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and not e.def.building then nd = math.min(nd, U.dist(e.x, e.y, f.x, f.y)) end end
          print("T", i, "alive", f.alive, "broken", f.broken, "hide", f.hideX and math.floor(U.dist(f.x, f.y, f.hideX, f.hideY)), "ours", math.floor(nd), "orders", f.orders[1] and f.orders[1].type)
        end
        if game.mercy and not surr then surr = i; print("MERCY at frame", i, "fallen", #game.mercy.fallen, "units", #game.mercy.units); break end
      end
      local found, total = 0, 0
      for _, d in ipairs(w.squads.trail or {}) do total = total + 1; if d.found then found = found + 1 end end
      print("TRAIL drops", total, "found", found)
      game:centerOn(foes[1].x, foes[1].y)
      for _ = 1, 50 do frame() end
      pending = "uishot_mercy.png"
      frame(); frame()
      if os.getenv("PA_MERCY") == "kill" then
        game:decideMercy("kill")
        print("dist to nearest of ours", (function() local b = 1e9; for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and not e.def.building then b = math.min(b, math.sqrt((e.x - foes[1].x) ^ 2 + (e.y - foes[1].y) ^ 2)) end end; return math.floor(b) end)(),
          "range", w:rangeOf(L), "look", w:lookOf(L), "canTarget", w:canTarget(L, foes[1]))
        for _ = 1, 240 do game:update(1 / 30) end
        print("AFTER kill: holdFire", foes[1].holdFire, "flag", foes[1].surrendered, "alive", foes[1].alive)
        game:centerOn(foes[1].x, foes[1].y)
        for _ = 1, 4 do frame() end
        pending = "uishot_mercy2.png"
        frame(); frame()
      else
        game:decideMercy("spare")
        for _ = 1, 60 do game:update(1 / 30) end
        print("AFTER spare: over", w.over and w.over.winnerAlly, "captives", w.captives)
      end
      print("UISHOT mercy")
      return
    end
    if os.getenv("PA_BARRAGE") then
      -- three enemy tanks parked 500 from our Battery's leader, spotted by a scout of ours; barrage them
      game.ais = {}
      for _, e in ipairs(w.entities) do if e.team == 2 and not e.def.building then e.alive = false end end
      local sq = SQ.squadsOf(w, 1)[3]
      local L = sq.leader
      local tx, ty = L.x + 500, L.y
      local foes = {}
      for i = 1, 3 do local f = w:spawn("tank", 2, tx + i * 25, ty + (i - 2) * 30); f.maxhp, f.hp = 5000, 5000; foes[i] = f end
      local eye = w:spawn("scout", 1, tx - 150, ty)
      for _ = 1, 10 do game:update(1 / 30) end
      print("BARRAGE cast", SQ.cast(w, sq, 1, tx + 50, ty))
      for _ = 1, 150 do game:update(1 / 30); for _, f in ipairs(foes) do f.orders = {} end end
      local lost = 0
      for _, f in ipairs(foes) do lost = lost + (5000 - f.hp) end
      print("BARRAGE damage to 3 tanks", math.floor(lost))
      return
    end
    if os.getenv("PA_SMOKE") then
      -- an enemy tank parks 230 away from our Armor squad; does Smoke Screen stop it shooting?
      for _ = 1, 30 do game:update(1 / 30) end
      local sq = SQ.squadsOf(w, 1)[1]
      local L = sq.leader
      for _, u in ipairs(sq.members) do u.orders = {} ; u.x, u.y = L.x + (u.x - L.x) * 0.3, L.y + (u.y - L.y) * 0.3 end
      game.ais = {}
      for _, e in ipairs(w.entities) do if e.team == 2 and not e.def.building then e.alive = false end end
      for _, e in ipairs(w.entities) do if e.team == 2 and e.def.building then e.def = setmetatable({ weapon = false }, { __index = e.def }) end end
      local foe = w:spawn("tank", 2, L.x + 196, L.y)
      foe.holdPos = true; foe.maxhp, foe.hp = 1e6, 1e6
      for _ = 1, 60 do game:update(1 / 30); foe.orders = {} ; foe.homeX, foe.homeY = L.x + 196, L.y end
      local function hp() local h = 0; for _, u in ipairs(sq.members) do if u.alive then h = h + u.hp end end; return h end
      local h0 = hp()
      for _ = 1, 90 do game:update(1 / 30); foe.orders = {}; foe.homeX, foe.homeY = L.x + 196, L.y end
      print("SMOKE no smoke: squad lost", math.floor(h0 - hp()), "in 3s; foe target", foe.autoTarget and foe.autoTarget.key, "built", foe.built, "reload", foe.reload, "dist", math.floor(((foe.x-L.x)^2+(foe.y-L.y)^2)^0.5), "chase", foe.chase and foe.chase.key, "disarmed", foe.disarmed)
      if os.getenv("PA_SMOKE") == "flee" then
        game:select({ L }); game:keypressed("f")
        for _ = 1, 30 do game:update(1 / 30) end
        local hq = w.teams[1].hq
        print("FLEE order", L.orders[1] and L.orders[1].type, "to", L.orders[1] and math.floor(L.orders[1].x), L.orders[1] and math.floor(L.orders[1].y), "hq", math.floor(hq.x), math.floor(hq.y))
      else
        print("cast", SQ.cast(w, sq, 2))
        for _ = 1, 10 do game:update(1 / 30); foe.orders = {}; foe.homeX, foe.homeY = L.x + 196, L.y end
        local h1 = hp()
        for _ = 1, 90 do game:update(1 / 30); foe.orders = {}; foe.homeX, foe.homeY = L.x + 196, L.y end
        print("SMOKE smoked: squad lost", math.floor(h1 - hp()), "in 3s; foe alive", foe.alive, foe.hp, "smoked", L.smoked)
      end
      return
    end
    while w.time < secs2 and not w.over do
      for _ = 1, 15 do game:update(1 / 30) end
      if w.time >= nextOrder then
        nextOrder = w.time + 8
        for i, sq in ipairs(SQ.squadsOf(w, 1)) do
          local L = sq.leader
          if L and L.alive then
            game:select({ L })
            local best, bd
            local targets = w.capPoints or { { x = w.teams[2].startX, y = w.teams[2].startY } }
            for _, p in ipairs(targets) do
              if p.owner ~= w.ally[1] then
                local d = (p.x - L.x) ^ 2 + (p.y - L.y) ^ 2 + i * 1e5 * ((_ + i) % 3)
                if not bd or d < bd then best, bd = p, d end
              end
            end
            if best then game:commandMove(best.x, best.y, "amove", false) end
            local sx, sy = game:worldToScreen(best and best.x or L.x, best and best.y or L.y)
            love.mouse.setPosition(sx, sy)
            game:keypressed("q"); game:keypressed("w")
          end
        end
      end
      if w.time >= nextLog then
        nextLog = w.time + 30
        local parts = {}
        for a, tk in pairs(w.squads.tickets) do parts[#parts + 1] = string.format("ally%d %d tickets %d pts", a, tk, SQ.held(w, a)) end
        table.sort(parts)
        print(string.format("COH %3ds  %s", math.floor(w.time), table.concat(parts, " | ")))
      end
      frame()
    end
    print("COH over", w.over and w.over.winnerAlly, math.floor(w.time))
    local L = SQ.squadsOf(w, 1)[1].leader
    local fx, fy = (L and L.alive) and L.x or w.map.w * w.T / 2, (L and L.alive) and L.y or w.map.h * w.T / 2
    local all = {}
    for _, sq in ipairs(SQ.squadsOf(w, 1)) do for _, u in ipairs(sq.members) do if u.alive then all[#all + 1] = u end end end
    game:select(all)
    game:keypressed("c")
    if os.getenv("PA_HOVER") then
      for _ = 1, 2 do game:update(1 / 30); frame() end
      local b = game.sqInfoBtns and game.sqInfoBtns[3]
      if b then love.mouse.setPosition(b.x + 10, b.y + 10) end
    end
    game.cam.zoom = 0.9
    if os.getenv("PA_BUNKERVIEW") and w.bunkers and w.bunkers[1] then
      w.noFog = true; game.cam.zoom = 0.55; fx, fy = w.bunkers[1].x, w.bunkers[1].y
    end
    game:centerOn(fx, fy)
    for _ = 1, 6 do game:update(1 / 30); frame() end
    pending = "uishot_coh.png"
    frame(); frame()
    print("UISHOT", love.filesystem.getSaveDirectory() .. "/uishot_coh.png")
    return
  end
  local tmpl = mode:match("^arena%-(%a+)")
  if tmpl then
    opts.mode, opts.template, opts.size = "arena", tmpl, 96
    opts.players = { { ally = 1, level = 6, class = "ranger" }, { ally = 2, level = 6 }, { ally = 1, level = 6 },
      { ally = 2, level = 6 }, { ally = 1, level = 6 }, { ally = 2, level = 6 } }
  end
  game = startFn(opts)
  game.opts.autotest = false
  local w = game.world
  local target = w.time + secs
  while w.time < target and not w.over do
    for _ = 1, 30 do w:update(1 / 30); for _, ai in ipairs(game.ais) do ai:update(1 / 30) end end
    frame()
  end
  -- frame the busiest spot near our Commander (or the whole map for overviews)
  local c = w.teams[1].commander
  game.cam.zoom = 1.0
  game:centerOn(c.x, c.y)
  if tmpl then
    w.noFog = true
    local vw, vh = love.graphics.getWidth(), love.graphics.getHeight() - 240
    game.cam.zoom = math.min(vw / (w.map.w * w.T), vh / (w.map.h * w.T))
    game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
  end
  if mode == "craft" then
    local pick = os.getenv("PA_SEL")
    local sel = {}
    for _, e in ipairs(w.entities) do
      if e.alive and e.team == 1 and ((pick == "worker" and e.def.worker) or (pick == "hall" and e.def.hall)
        or (pick == "barracks" and e.key:match("barracks")) or (pick == "army" and not e.def.worker and not e.def.building)) then sel[#sel + 1] = e end
    end
    if #sel > 0 then game:select(sel) end
    if pick == "army" then
      local cg = require("src.craft_game")
      local hs = cg.selectedHeroes(game)
      if hs[1] then game:centerOn(hs[1].x, hs[1].y) end
      cg.cycleHero(game)
    end
    if os.getenv("PA_MOUSE") then
      local mx, my = os.getenv("PA_MOUSE"):match("(%d+),(%d+)")
      love.mouse.setPosition(tonumber(mx), tonumber(my))
    end
    if os.getenv("PA_GMOVE") then
      local units = {}
      for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and not e.def.building and not e.def.worker then units[#units + 1] = e end end
      game:select(units)
      game:commandMove(c.x + 300, c.y, "gmove", false)
      for _, u in ipairs(units) do print("GMOVE", u.key, u.def.speed, w:speedOf(u), u.orders[1] and u.orders[1].type) end
    end
    if os.getenv("PA_INSPECT") then
      w.noFog = true
      local best, bd
      for _, e in ipairs(w.entities) do
        if e.alive and e.team == 0 and e.def.weapon then
          local d = (e.x - c.x) ^ 2 + (e.y - c.y) ^ 2
          if not bd or d < bd then best, bd = e, d end
        end
      end
      game.selected = {}
      game.inspect = best
      game:centerOn(best.x, best.y)
      for _ = 1, 2 do game:update(1 / 30); frame() end
      local hx, hy = best.x + 160, best.y
      for _, e in ipairs(w.entities) do if e.alive and e.team == 2 and not e.def.building then hx, hy = e.x, e.y; game:centerOn(e.x, e.y); break end end
      local sx, sy = game:worldToScreen(hx, hy)
      love.mouse.setPosition(sx, sy)
    end
    if os.getenv("PA_WIDE") then game.cam.zoom = 0.6; game:centerOn(c.x, c.y + 200) end
    if os.getenv("PA_OVERVIEW") then
      w.noFog = true
      local vw, vh = love.graphics.getWidth(), love.graphics.getHeight() - 240
      game.cam.zoom = math.min(vw / (w.map.w * w.T), vh / (w.map.h * w.T))
      game:centerOn(w.map.w * w.T / 2, w.map.h * w.T / 2)
    end
  end
  if os.getenv("PA_PAUSE") then game.menuOpen = true end
  for _ = 1, 6 do game:update(1 / 30); frame() end
  if mode == "arena" then
    local sx, sy = game:worldToScreen(c.x, c.y)
    love.mouse.setPosition(sx, sy)
    -- a skill call-out for the camera
    w.effects[#w.effects + 1] = { kind = "label", text = "Frost Nova", x = c.x + 120, y = c.y - 60, t = 0.3, life = 1.6, color = { 1, 0.5, 0.42 }, size = 13 }
  end
  if tmpl then
    -- also show the jungle panel at a normal zoom
    w.noFog = false
    game.cam.zoom = 1
    game:centerOn(c.x, c.y)
    for _ = 1, 4 do game:update(1 / 30); frame() end
  end
  pending = "uishot_" .. mode .. ".png"
  frame(); frame()
  if os.getenv("PA_OVER") and w.arena then
    require("src.arena").eliminateSide(w, 2)
    for _ = 1, 30 do game:update(1 / 30); frame() end
    pending = "uishot_" .. mode .. "_over.png"
    frame(); frame()
  end
  print("UISHOT", love.filesystem.getSaveDirectory() .. "/" .. "uishot_" .. mode .. ".png")
end
function S.start(fn, mode, secs) startFn = fn; co = coroutine.create(function() script(mode, secs) end) end
function S.update()
  if coroutine.status(co) == "dead" then love.event.quit(); return end
  local ok, err = coroutine.resume(co)
  if not ok then error(err .. "\n" .. debug.traceback(co)) end
end
function S.afterDraw() if pending then love.graphics.captureScreenshot(pending); pending = nil end end
return S
