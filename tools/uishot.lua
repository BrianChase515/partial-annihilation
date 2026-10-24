-- Dev tool: start a 2v2 (RTS or Arena), let the AIs play a while, take a screenshot.
-- love . --uishot <rts|arena> [seconds]   (not shipped)
local S = {}
local co, game, startFn, pending
local function frame() coroutine.yield() end
local function script(mode, secs)
  frame()
  local opts = { size = mode == "arena" and 80 or 112, water = 0.3, seed = 31, autotest = true,
    players = { { ally = 1, level = 5 }, { ally = 2, level = 5 }, { ally = 1, level = 5 }, { ally = 2, level = 5 } } }
  if mode == "arena" then opts.mode = "arena"; opts.players[1].class = os.getenv("PA_CLASS") or "ranger" end
  if mode == "arena" and os.getenv("PA_FIVE") then
    opts.size, opts.template = 112, "battlefield"
    opts.players = {}
    for i = 1, 10 do opts.players[i] = { ally = i % 2 == 1 and 1 or 2, level = 5 } end
    opts.players[1].class = os.getenv("PA_CLASS") or "ranger"
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
    opts = { mode = "craft", size = 88, seed = 31, autotest = true,
      players = { { ally = 1, level = 5, race = os.getenv("PA_RACE") or "vanguard", class = os.getenv("PA_CLASS") }, { ally = 2, level = 5, race = "warband" } } }
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
        or (pick == "barracks" and e.key:match("barracks"))) then sel[#sel + 1] = e end
    end
    if #sel > 0 then game:select(sel) end
    if os.getenv("PA_WIDE") then game.cam.zoom = 0.6; game:centerOn(c.x, c.y + 200) end
  end
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
