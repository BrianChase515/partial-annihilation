-- World rendering: terrain, deposits, entities, projectiles, effects, fog.
local D = require("src.defs")
local U = require("src.util")

local R = {}

local fonts = {}
local function font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end
R.font = font

function R.init(world)
  R.world = world
  local map = world.map
  map:buildImages()
  R.fogData = love.image.newImageData(map.w, map.h)
  R.fogImage = love.graphics.newImage(R.fogData)
  R.fogImage:setFilter("linear", "linear")
  R.updateFogImage()
end

function R.updateFogImage()
  local world = R.world
  local map = world.map
  local w = map.w
  local fd = R.fogData
  for ty = 0, map.h - 1 do
    for tx = 0, w - 1 do
      local i = ty * w + tx
      local a
      if world.noFog or world.visible[i] == 1 then a = 0
      elseif world.explored[i] then a = 0.5
      else a = 0.86 end
      fd:setPixel(tx, ty, 0.02, 0.03, 0.06, a)
    end
  end
  R.fogImage:replacePixels(fd)
  world.fogChanged = false
end

local function teamColor(team, k)
  local c = D.teamColor[team]
  k = k or 1
  return c[1] * k, c[2] * k, c[3] * k
end
R.teamColor = teamColor

local function drawLabel(text, x, y, size, zoom)
  if zoom < 0.45 then return end
  local f = font(size)
  love.graphics.setFont(f)
  local tw = f:getWidth(text)
  love.graphics.print(text, x - tw / 2, y - f:getHeight() / 2)
end

-- shape helpers
local function rrect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x - w / 2, y - h / 2, w, h, r, r)
end

function R.drawEntity(e, cam, selected)
  local d = e.def
  local zoom = cam.zoom
  local cr, cg, cb = teamColor(e.team)
  local frame = e.built < 1
  local lg = love.graphics
  if d.building then
    local w, h = d.w * D.TILE, d.h * D.TILE
    local x, y = e.x, e.y
    if frame then
      lg.setColor(cr, cg, cb, 0.18)
      rrect("fill", x, y, w - 4, h - 4, 4)
      -- fill from the bottom by progress
      lg.setColor(cr, cg, cb, 0.55)
      local fh = (h - 4) * e.built
      lg.rectangle("fill", x - w / 2 + 2, y + h / 2 - 2 - fh, w - 4, fh)
      lg.setColor(cr, cg, cb, 0.9)
      lg.setLineWidth(1.5)
      rrect("line", x, y, w - 4, h - 4, 4)
    else
      lg.setColor(0, 0, 0, 0.35)
      rrect("fill", x + 3, y + 4, w - 4, h - 4, 5)
      lg.setColor(cr * 0.55, cg * 0.55, cb * 0.55)
      rrect("fill", x, y, w - 4, h - 4, 5)
      lg.setColor(cr * 0.85, cg * 0.85, cb * 0.85)
      rrect("fill", x, y, w - 12, h - 12, 3)
      lg.setColor(0.05, 0.05, 0.08)
      lg.setLineWidth(2)
      rrect("line", x, y, w - 4, h - 4, 5)
      if d.factory then
        -- door stripe on the exit side
        lg.setColor(0.1, 0.1, 0.12)
        lg.rectangle("fill", x - w / 6, y + h / 2 - 9, w / 3, 6)
        if e.queue and #e.queue > 0 then
          lg.setColor(1, 1, 1, 0.8)
          lg.rectangle("fill", x - w / 2 + 6, y - h / 2 + 5, (w - 12) * e.progress, 4)
        end
      end
      if d.weapon then
        local a = e.angle or 0
        lg.setColor(0.08, 0.08, 0.1)
        lg.setLineWidth(4)
        lg.line(x, y, x + math.cos(a) * 16, y + math.sin(a) * 16)
        lg.setColor(cr, cg, cb)
        lg.circle("fill", x, y, 7)
      end
      if e.key == "mex" then
        lg.setColor(0.95, 0.85, 0.3)
        lg.circle("line", x, y, 9)
      elseif e.key == "solar" then
        lg.setColor(0.95, 0.95, 0.6, 0.8)
        lg.setLineWidth(1)
        for i = -1, 1 do lg.line(x - 20, y + i * 9, x + 20, y + i * 9) end
      end
      lg.setColor(1, 1, 1, 0.95)
      drawLabel(d.short, x, y + (d.weapon and 0 or 0), d.w >= 3 and 18 or 12, zoom)
    end
  else
    local r = d.radius
    local x, y = e.x, e.y
    local dom = d.domain
    if dom == "air" then
      -- shadow
      lg.setColor(0, 0, 0, 0.3)
      local a = e.angle
      local function tri(cx, cy, s)
        lg.polygon("fill",
          cx + math.cos(a) * s * 1.3, cy + math.sin(a) * s * 1.3,
          cx + math.cos(a + 2.5) * s, cy + math.sin(a + 2.5) * s,
          cx + math.cos(a - 2.5) * s, cy + math.sin(a - 2.5) * s)
      end
      tri(x + 8, y + 14, r)
      lg.setColor(cr, cg, cb)
      tri(x, y, r)
      lg.setColor(0.04, 0.04, 0.06)
      lg.setLineWidth(1.5)
      lg.polygon("line",
        x + math.cos(a) * r * 1.3, y + math.sin(a) * r * 1.3,
        x + math.cos(a + 2.5) * r, y + math.sin(a + 2.5) * r,
        x + math.cos(a - 2.5) * r, y + math.sin(a - 2.5) * r)
      lg.setColor(0, 0, 0, 0.9)
      drawLabel(d.short, x, y, 10, zoom)
    elseif dom == "sea" or dom == "sub" then
      local alpha = dom == "sub" and 0.55 or 1
      lg.setColor(1, 1, 1, 0.12 * alpha)
      lg.circle("fill", x, y, r + 4)
      lg.setColor(cr, cg, cb, alpha)
      lg.circle("fill", x, y, r)
      lg.setColor(0.04, 0.04, 0.06, alpha)
      lg.setLineWidth(1.5)
      lg.circle("line", x, y, r)
      if dom == "sub" then
        lg.setColor(1, 1, 1, 0.5)
        lg.circle("line", x, y, r - 4)
      end
      -- bow direction tick
      local a = e.angle
      lg.setColor(1, 1, 1, 0.7 * alpha)
      lg.line(x + math.cos(a) * (r - 3), y + math.sin(a) * (r - 3), x + math.cos(a) * (r + 5), y + math.sin(a) * (r + 5))
      lg.setColor(0, 0, 0, 0.9)
      drawLabel(d.short, x, y, r >= 14 and 13 or 11, zoom)
    else
      -- land: rounded squares, commander bigger with double outline
      lg.setColor(0, 0, 0, 0.3)
      rrect("fill", x + 3, y + 4, r * 2, r * 2, 4)
      lg.setColor(cr, cg, cb)
      lg.push()
      lg.translate(x, y)
      lg.rotate(e.angle + math.pi / 2)
      rrect("fill", 0, 0, r * 2, r * 2, 4)
      lg.setColor(0.04, 0.04, 0.06)
      lg.setLineWidth(1.5)
      rrect("line", 0, 0, r * 2, r * 2, 4)
      lg.setColor(1, 1, 1, 0.55)
      lg.polygon("fill", 0, -r - 1, -4, -r + 5, 4, -r + 5)
      lg.pop()
      if d.weapon and e.turret then
        lg.setColor(0.06, 0.06, 0.08)
        lg.setLineWidth(3)
        lg.line(x, y, x + math.cos(e.turret) * (r + 6), y + math.sin(e.turret) * (r + 6))
      end
      if e.key == "commander" then
        lg.setColor(1, 0.9, 0.3)
        lg.setLineWidth(2)
        rrect("line", x, y, r * 2 + 8, r * 2 + 8, 6)
      end
      lg.setColor(0, 0, 0, 0.92)
      drawLabel(d.short, x, y, e.key == "commander" and 11 or (r >= 12 and 13 or 11), zoom)
    end
    if e.flash and e.flash > 0 and e.turret then
      lg.setColor(1, 0.95, 0.6, 0.9)
      lg.circle("fill", x + math.cos(e.turret) * (r + 8), y + math.sin(e.turret) * (r + 8), 3)
    end
  end
  -- disarmed (retreated, not yet fully repaired): grey slash over the unit
  if e.disarmed and zoom > 0.3 then
    local r = d.radius
    lg.setColor(0.1, 0.1, 0.1, 0.7)
    lg.setLineWidth(3)
    lg.line(e.x - r, e.y + r, e.x + r, e.y - r)
    lg.setColor(0.85, 0.85, 0.85, 0.9)
    lg.setLineWidth(1.5)
    lg.line(e.x - r, e.y + r, e.x + r, e.y - r)
  end
  -- repairing indicator
  if e.healing and zoom > 0.35 then
    local r = d.radius
    lg.setColor(0.3, 1, 0.45, 0.85)
    lg.setLineWidth(2)
    lg.line(e.x - r - 6, e.y - r, e.x - r, e.y - r)
    lg.line(e.x - r - 3, e.y - r - 3, e.x - r - 3, e.y - r + 3)
  end
  -- veterancy chevrons
  local L = e.level or 0
  if L > 0 and zoom > 0.35 then
    local r = d.building and d.w * D.TILE / 2 or d.radius
    local bx, by = e.x + r + 3, e.y - r - 2
    for i = 0, L - 1 do
      local yy = by + i * 4.5
      lg.setColor(0, 0, 0, 0.8)
      lg.setLineWidth(3)
      lg.line(bx - 4, yy + 3, bx, yy, bx + 4, yy + 3)
      lg.setColor(1, 0.82, 0.25)
      lg.setLineWidth(1.6)
      lg.line(bx - 4, yy + 3, bx, yy, bx + 4, yy + 3)
    end
  end
  if e.hitTimer then
    lg.setColor(1, 1, 1, 0.35)
    if d.building then rrect("fill", e.x, e.y, d.w * D.TILE - 4, d.h * D.TILE - 4, 4)
    else lg.circle("fill", e.x, e.y, d.radius) end
  end
end

function R.drawHealth(e, show)
  local d = e.def
  local frac = e.hp / e.maxhp
  if not show and frac > 0.995 then return end
  local w = d.building and d.w * D.TILE * 0.8 or math.max(22, d.radius * 2.4)
  local y = e.y - (d.building and d.h * D.TILE / 2 + 7 or d.radius + 9)
  local lg = love.graphics
  lg.setColor(0, 0, 0, 0.7)
  lg.rectangle("fill", e.x - w / 2 - 1, y - 1, w + 2, 5)
  local r, g = 1 - frac, frac
  lg.setColor(0.2 + r * 0.8, 0.3 + g * 0.6, 0.15)
  lg.rectangle("fill", e.x - w / 2, y, w * frac, 3)
end

function R.drawWorld(cam, game)
  local world = R.world
  local map = world.map
  local lg = love.graphics
  local T = D.TILE

  -- terrain
  lg.setColor(1, 1, 1)
  local s = T / map.imagePx
  lg.draw(map.image, 0, 0, 0, s, s)

  -- visible bounds in world coords
  local x0, y0, x1, y1 = cam.wx0, cam.wy0, cam.wx1, cam.wy1

  -- grid lines when zoomed in
  if cam.zoom > 0.9 then
    lg.setColor(0, 0, 0, 0.06)
    lg.setLineWidth(1)
    local tx0, tx1 = math.max(0, math.floor(x0 / T)), math.min(map.w, math.ceil(x1 / T))
    local ty0, ty1 = math.max(0, math.floor(y0 / T)), math.min(map.h, math.ceil(y1 / T))
    for tx = tx0, tx1 do lg.line(tx * T, ty0 * T, tx * T, ty1 * T) end
    for ty = ty0, ty1 do lg.line(tx0 * T, ty * T, tx1 * T, ty * T) end
  end

  -- metal deposits
  for _, dpos in ipairs(map.deposits) do
    local cx, cy = (dpos.x + 0.5) * T, (dpos.y + 0.5) * T
    if cx > x0 - T and cx < x1 + T and cy > y0 - T and cy < y1 + T then
      lg.setColor(0.12, 0.12, 0.12, 0.85)
      lg.circle("fill", cx, cy, 11)
      lg.setColor(0.85, 0.75, 0.35, 0.9)
      lg.circle("fill", cx - 3, cy - 2, 3)
      lg.circle("fill", cx + 3, cy + 3, 2.5)
      lg.circle("fill", cx + 4, cy - 4, 2)
    end
  end

  local sel = game.selected
  local margin = 80

  -- buildings first, then sea, land, air
  local order = { building = 1, sub = 2, sea = 3, land = 4, air = 5 }
  local list = {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.x > x0 - margin and e.x < x1 + margin and e.y > y0 - margin and e.y < y1 + margin then
      local show = world:isVisible(e) or (e.def.building and e.seen[world.playerTeam])
      if e.def.domain == "sub" and world:hostile(e.team, world.playerTeam) and not world.noFog then
        -- enemy subs are only revealed near your ships
        show = show and game:subRevealed(e)
      end
      if show then list[#list + 1] = e end
    end
  end
  table.sort(list, function(a, b)
    local oa, ob = order[a.def.domain], order[b.def.domain]
    if oa ~= ob then return oa < ob end
    return a.id < b.id
  end)

  -- selection circles under units
  for _, e in ipairs(list) do
    if sel[e] then
      lg.setColor(0.3, 1, 0.4, 0.9)
      lg.setLineWidth(2)
      if e.def.building then
        rrect("line", e.x, e.y, e.def.w * T + 2, e.def.h * T + 2, 6)
      else
        lg.circle("line", e.x, e.y, e.def.radius + 5)
      end
    end
  end

  for _, e in ipairs(list) do R.drawEntity(e, cam, sel[e]) end

  -- nano build beams
  for _, e in ipairs(list) do
    if e.nanoTarget and e.nanoTarget.alive then
      local t = e.nanoTarget
      local cr, cg, cb = teamColor(e.team)
      lg.setColor(cr, cg + 0.2, cb, 0.55)
      lg.setLineWidth(2)
      local wob = math.sin(world.time * 20 + e.id) * 6
      if e ~= t then lg.line(e.x, e.y, t.x + wob, t.y - wob) end
    end
  end

  for _, e in ipairs(list) do
    R.drawHealth(e, sel[e] or e.built < 1)
  end

  -- projectiles
  for _, p in ipairs(world.projectiles) do
    if p.x > x0 - 20 and p.x < x1 + 20 and p.y > y0 - 20 and p.y < y1 + 20 then
      if p.weapon.ballistic then
        local total = U.dist(p.sx, p.sy, p.tx, p.ty)
        local left = U.dist(p.x, p.y, p.tx, p.ty)
        local arc = math.sin((1 - left / math.max(total, 1)) * math.pi) * math.min(60, total * 0.2)
        if p.weapon.bomb then arc = 0 end
        lg.setColor(0, 0, 0, 0.3)
        lg.circle("fill", p.x, p.y, 3)
        lg.setColor(1, 0.8, 0.4)
        lg.circle("fill", p.x, p.y - arc, p.weapon.bomb and 4 or 3.5)
      elseif p.weapon.torpedo then
        lg.setColor(0.8, 0.95, 1, 0.8)
        lg.circle("fill", p.x, p.y, 2.5)
      else
        local nx, ny = U.norm(p.tx - p.x, p.ty - p.y)
        local cr, cg, cb = teamColor(p.team)
        lg.setColor(math.min(1, cr + 0.5), math.min(1, cg + 0.5), math.min(1, cb + 0.4))
        lg.setLineWidth(2)
        lg.line(p.x, p.y, p.x - nx * 8, p.y - ny * 8)
      end
    end
  end

  -- effects
  for _, fx in ipairs(world.effects) do
    local k = fx.t / fx.life
    if fx.kind == "boom" then
      lg.setColor(1, 0.75 - k * 0.5, 0.2, 1 - k)
      lg.circle("fill", fx.x, fx.y, fx.size * (0.4 + k * 0.6))
      lg.setColor(1, 1, 0.8, (1 - k) * 0.8)
      lg.circle("fill", fx.x, fx.y, fx.size * 0.3 * (1 - k))
    elseif fx.kind == "splash" then
      lg.setColor(1, 0.6, 0.2, 0.7 * (1 - k))
      lg.circle("line", fx.x, fx.y, fx.size * (0.3 + k * 0.7))
      lg.setColor(1, 0.8, 0.4, 0.4 * (1 - k))
      lg.circle("fill", fx.x, fx.y, fx.size * 0.5 * (1 - k))
    elseif fx.kind == "hit" then
      lg.setColor(1, 1, 0.7, 1 - k)
      lg.circle("fill", fx.x, fx.y, fx.size)
    elseif fx.kind == "levelup" then
      lg.setColor(1, 0.85, 0.3, 1 - k)
      lg.setLineWidth(2.5)
      lg.circle("line", fx.x, fx.y, fx.size * (0.8 + k * 0.8))
    elseif fx.kind == "ping" then
      lg.setColor(fx.r or 0.3, fx.g or 1, fx.b or 0.4, 1 - k)
      lg.setLineWidth(2)
      lg.circle("line", fx.x, fx.y, 6 + k * 18)
    end
  end

  -- fog overlay
  if not world.noFog then
    if world.fogChanged then R.updateFogImage() end
    lg.setColor(1, 1, 1)
    lg.draw(R.fogImage, 0, 0, 0, T, T)
  end
end

return R
