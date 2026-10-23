-- Dev tool: start a 2v2 (RTS or Arena), let the AIs play a while, take a screenshot.
-- love . --uishot <rts|arena> [seconds]   (not shipped)
local S = {}
local co, game, startFn, pending
local function frame() coroutine.yield() end
local function script(mode, secs)
  frame()
  local opts = { size = mode == "arena" and 80 or 112, water = 0.3, seed = 31, autotest = true,
    players = { { ally = 1, level = 5 }, { ally = 2, level = 5 }, { ally = 1, level = 5 }, { ally = 2, level = 5 } } }
  if mode == "arena" then opts.mode = "arena"; opts.players[1].class = "ranger" end
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
  for _ = 1, 6 do game:update(1 / 30); frame() end
  if mode == "arena" then
    local sx, sy = game:worldToScreen(c.x, c.y)
    love.mouse.setPosition(sx, sy)
    -- a skill call-out for the camera
    w.effects[#w.effects + 1] = { kind = "label", text = "Frost Nova", x = c.x + 120, y = c.y - 60, t = 0.3, life = 1.6, color = { 1, 0.5, 0.42 }, size = 13 }
  end
  pending = "uishot_" .. mode .. ".png"
  frame(); frame()
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
