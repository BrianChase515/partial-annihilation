-- World rendering: terrain, deposits, entities, projectiles, effects, fog.
local D = require("src.defs")
local U = require("src.util")

local R = {}
local ICONS = require("src.icons")

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

local function groovy() return R.world and R.world.mods and R.world.mods.groovy end
R.groovy = groovy

-- hue 0..1 -> bright rgb
local function hsv(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
end
R.hsv = hsv

-- a flower: petals around a center, used instead of explosions in Groovy mode
local function flower(x, y, r, petals, hue, alpha, spin)
  local lg = love.graphics
  for i = 0, petals - 1 do
    local a = spin + i * math.pi * 2 / petals
    local pr, pg, pb = hsv(hue + i * 0.07, 0.85, 1)
    lg.setColor(pr, pg, pb, alpha)
    lg.circle("fill", x + math.cos(a) * r * 0.55, y + math.sin(a) * r * 0.55, r * 0.42)
  end
  lg.setColor(1, 0.92, 0.2, alpha)
  lg.circle("fill", x, y, r * 0.35)
  lg.setColor(1, 0.55, 0.1, alpha)
  lg.circle("fill", x, y, r * 0.18)
end
R.flower = flower

local function teamColor(team, k)
  local c = (groovy() and D.groovyColor[team]) or D.teamColor[team] or D.teamColor[0]
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

-- a unit's mark: its picture when it's big enough on screen, otherwise the short label
local function unitMark(e, x, y, r, labelSize, zoom, scale)
  -- Arena Commanders show their class (a bow for the Ranger, axes for the Juggernaut...)
  local key = e.key
  if key == "commander" and e.class and ICONS.has("cls_" .. e.class) then key = "cls_" .. e.class end
  if zoom * r >= 7 and ICONS.has(key) then
    ICONS.draw(key, x, y, r * (scale or 1.55))
  else
    drawLabel(e.def.short, x, y, labelSize, zoom)
  end
end

-- shape helpers
local function rrect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x - w / 2, y - h / 2, w, h, r, r)
end

function R.drawEntity(e, cam, selected)
  local d = e.def
  local zoom = cam.zoom
  local cr, cg, cb = teamColor(e.team)
  if e.key == "goldmine" then cr, cg, cb = 0.85, 0.66, 0.22 end
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
      -- the picture first, so a turret's barrel draws on top of it
      local drewIcon = zoom >= 0.3 and ICONS.has(e.key) and e.key ~= "powercore"
      if drewIcon then
        lg.setColor(1, 1, 1, 0.9)
        ICONS.draw(e.key, x, y, math.min(d.w, d.h) * D.TILE * (d.weapon and 0.6 or 0.7))
      end
      if d.weapon then
        local a = e.angle or 0
        lg.setColor(0.08, 0.08, 0.1)
        lg.setLineWidth(4)
        lg.line(x, y, x + math.cos(a) * 16, y + math.sin(a) * 16)
        lg.setColor(cr, cg, cb)
        lg.circle("fill", x, y, 7)
      end
      if e.key == "powercore" and (e.built or 1) >= 1 then
        -- a tall sensor tower: it casts a long shadow, a mast rises from the pad, and the beacon
        -- on top sweeps the middle of the map
        local tt = love.timer.getTime()
        local pulse = 0.5 + 0.5 * math.sin(tt * 3)
        local topX, topY = x - 10, y - 40
        lg.setColor(0, 0, 0, 0.3)
        lg.polygon("fill", x - 7, y + 4, x + 7, y - 4, x + 40, y + 42, x + 30, y + 50)
        -- pad rings
        lg.setColor(0.4, 0.85, 1, 0.9)
        lg.setLineWidth(2)
        lg.circle("line", x, y, 22)
        -- the mast: a tapered column from the pad up to the beacon
        lg.setColor(cr * 0.45, cg * 0.45, cb * 0.45)
        lg.polygon("fill", x - 9, y + 2, x + 9, y + 2, topX + 5, topY, topX - 5, topY)
        lg.setColor(cr, cg, cb)
        lg.polygon("fill", x - 4, y + 2, x + 4, y + 2, topX + 2, topY, topX - 2, topY)
        lg.setColor(0.05, 0.05, 0.08)
        lg.setLineWidth(1.5)
        lg.polygon("line", x - 9, y + 2, x + 9, y + 2, topX + 5, topY, topX - 5, topY)
        -- beacon
        lg.setColor(0.4, 0.85, 1, 0.25 + 0.2 * pulse)
        lg.circle("fill", topX, topY, 12 + 4 * pulse)
        lg.setColor(0.7, 0.97, 1)
        lg.circle("fill", topX, topY, 5 + pulse)
        local a = tt * 1.4
        lg.setColor(0.5, 0.9, 1, 0.4)
        lg.setLineWidth(3)
        lg.line(topX, topY, topX + math.cos(a) * 60, topY + math.sin(a) * 60)
        -- how far it sees (faint, so the middle reads as watched)
        lg.setColor(0.4, 0.85, 1, 0.1 + 0.05 * pulse)
        lg.setLineWidth(2)
        lg.circle("line", x, y, d.sight)
        drewIcon = true
      end
      if drewIcon then
        -- (the picture says what it is)
      elseif e.key == "mex" then
        lg.setColor(0.95, 0.85, 0.3)
        lg.circle("line", x, y, 9)
      elseif e.key == "solar" then
        lg.setColor(0.95, 0.95, 0.6, 0.8)
        lg.setLineWidth(1)
        for i = -1, 1 do lg.line(x - 20, y + i * 9, x + 20, y + i * 9) end
      end
      if not drewIcon then
        lg.setColor(1, 1, 1, 0.95)
        drawLabel(d.short, x, y + (d.weapon and 0 or 0), d.w >= 3 and 18 or 12, zoom)
      end
    end
  elseif d.shape == "walker" then
    local r = d.radius
    local x, y = e.x, e.y
    local t = (R.world and R.world.time or 0)
    -- legs
    lg.setColor(0.1, 0.08, 0.14)
    lg.setLineWidth(4)
    for i = 0, 3 do
      local a = e.angle + math.pi / 4 + i * math.pi / 2
      local step = math.sin(t * 4 + i * 1.6) * (e.dormant and 0 or 5)
      lg.line(x, y, x + math.cos(a) * (r + 12 + step), y + math.sin(a) * (r + 12 + step))
    end
    -- hexagonal body
    local pts = {}
    for i = 0, 5 do
      local a = e.angle + i * math.pi / 3
      pts[#pts + 1] = x + math.cos(a) * r
      pts[#pts + 1] = y + math.sin(a) * r
    end
    lg.setColor(cr * 0.6, cg * 0.6, cb * 0.6)
    lg.polygon("fill", pts)
    lg.setColor(cr, cg, cb)
    lg.circle("fill", x, y, r * 0.55)
    lg.setColor(0.05, 0.03, 0.08)
    lg.setLineWidth(2)
    lg.polygon("line", pts)
    -- glowing eye
    local glow = 0.6 + 0.4 * math.sin(t * 3)
    lg.setColor(0.9, 1, 0.6, e.dormant and glow * 0.6 or glow)
    lg.circle("fill", x, y, r * 0.22)
    if e.turret then
      lg.setColor(0.06, 0.06, 0.08)
      lg.setLineWidth(5)
      lg.line(x, y, x + math.cos(e.turret) * (r + 14), y + math.sin(e.turret) * (r + 14))
    end
    lg.setColor(1, 1, 1, 0.9)
    drawLabel(e.dormant and "?" or "W", x, y + r * 0.62, 12, zoom)
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
      unitMark(e, x, y, d.radius, 10, zoom, 1.25)
    elseif e.key == "battleship" then
      -- a long rounded hull with two gun turrets: easy to spot, as it should be
      local a = e.angle
      lg.push()
      lg.translate(x, y)
      lg.rotate(a)
      lg.setColor(1, 1, 1, 0.12)
      lg.ellipse("fill", 0, 0, r * 1.5 + 4, r * 0.8 + 4)
      lg.setColor(cr, cg, cb)
      lg.ellipse("fill", 0, 0, r * 1.5, r * 0.8)
      lg.setColor(0.04, 0.04, 0.06)
      lg.setLineWidth(2)
      lg.ellipse("line", 0, 0, r * 1.5, r * 0.8)
      lg.setColor(1, 1, 1, 0.7)
      lg.line(r * 1.2, 0, r * 1.7, 0)
      lg.pop()
      local ta = e.turret or a
      for _, off in ipairs({ -0.75, 0.75 }) do
        local gx, gy = x + math.cos(a) * r * off, y + math.sin(a) * r * off
        lg.setColor(0.06, 0.06, 0.08)
        lg.setLineWidth(3)
        lg.line(gx, gy, gx + math.cos(ta) * 15, gy + math.sin(ta) * 15)
        lg.setColor(cr * 0.7, cg * 0.7, cb * 0.7)
        lg.circle("fill", gx, gy, 6)
      end
      lg.setColor(0, 0, 0, 0.9)
      unitMark(e, x, y, d.radius, 13, zoom, 1.45)
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
      unitMark(e, x, y, r, r >= 14 and 13 or 11, zoom, 1.45)
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
      unitMark(e, x, y, r, e.key == "commander" and 11 or (r >= 12 and 13 or 11), zoom, e.key == "commander" and 1.5 or 1.55)
    end
    if e.flash and e.flash > 0 and e.turret then
      lg.setColor(1, 0.95, 0.6, 0.9)
      lg.circle("fill", x + math.cos(e.turret) * (r + 8), y + math.sin(e.turret) * (r + 8), 3)
    end
  end
  -- Arena: shielded structures, stunned units, faded Commanders, energy shields
  do
  local x, y, r = e.x, e.y, d.radius
  if e.protected then
    lg.setColor(0.6, 0.8, 1, 0.35 + 0.15 * math.sin(R.world.time * 3))
    lg.setLineWidth(2)
    lg.circle("line", x, y, r + 10)
  end
  if e.stunUntil and R.world.time < e.stunUntil then
    lg.setColor(1, 1, 0.4, 0.9)
    for i = 0, 2 do
      local a = R.world.time * 6 + i * 2.09
      lg.circle("fill", x + math.cos(a) * (r + 4), y - r - 6 + math.sin(a) * 4, 2.5)
    end
  end
  if e.absorb then
    lg.setColor(0.5, 0.7, 1, 0.5)
    lg.setLineWidth(3)
    lg.circle("line", x, y, r + 7)
  end
  if e.summon and e.doom then
    lg.setColor(1, 1, 1, 0.5)
    lg.setLineWidth(1)
    lg.circle("line", x, y, r + 3)
  end
  if e.fadeUntil and R.world.time < e.fadeUntil then
    lg.setColor(0.6, 0.5, 1, 0.6)
    lg.setLineWidth(2)
    lg.circle("line", x, y, r + 12)
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
  if e.invulnUntil and R.world and R.world.time < e.invulnUntil then
    lg.setColor(1, 1, 0.6, 0.35 + 0.25 * math.sin(R.world.time * 12))
    lg.setLineWidth(3)
    lg.circle("line", e.x, e.y, d.radius + 10)
  end
  -- repairing indicator
  if e.healing and zoom > 0.35 then
    local r = d.radius
    lg.setColor(0.3, 1, 0.45, 0.85)
    lg.setLineWidth(2)
    lg.line(e.x - r - 6, e.y - r, e.x - r, e.y - r)
    lg.line(e.x - r - 3, e.y - r - 3, e.x - r - 3, e.y - r + 3)
  end
  -- Arena creep veterancy: gold pips above the creep
  if e.vet and e.vet > 0 and zoom > 0.35 then
    local r = d.radius
    for i = 1, e.vet do
      local px = e.x - (e.vet - 1) * 4 + (i - 1) * 8
      lg.setColor(0, 0, 0, 0.8)
      lg.circle("fill", px, e.y - r - 6, 3.4)
      lg.setColor(1, 0.82, 0.25)
      lg.circle("fill", px, e.y - r - 6, 2.4)
    end
  end
  -- veterancy chevrons (the Commander shows his own level)
  local L = e.key == "commander" and (e.clevel or 0) or (e.level or 0)
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

-- "me", "ally", "enemy" or "neutral", seen from the human player (team 1)
function R.relation(team)
  if team == 1 then return "me" end
  local w = R.world
  if not w or not w.ally or not w.ally[team] then return "neutral" end
  if w.ally[team] == w.ally[1] then return "ally" end
  return w:hostile(team, 1) and "enemy" or "neutral"
end
R.REL_COLOR = { me = { 1, 1, 1 }, ally = { 0.35, 1, 0.45 }, enemy = { 1, 0.35, 0.3 }, neutral = { 0.8, 0.8, 0.8 } }

-- progress to the next Commander level: frac (0..1), level, isMax
function R.cmdXP(e)
  local T = R.world and R.world.heroes and require("src.arena").THRESHOLDS or require("src.commander").THRESHOLDS
  local L = e.clevel or 0
  local lo = L > 0 and T[L] or 0
  local hi = T[L + 1]
  if not hi then return 1, L, true end
  return math.max(0, math.min(1, ((e.cxp or 0) - lo) / (hi - lo))), L, false
end

-- a name tag over every Commander: YOU / ALLY / ENEMY, plus the class in the Arena
function R.drawNameplate(e, zoom)
  if e.key ~= "commander" or not e.alive or zoom < 0.3 then return end
  local rel = R.relation(e.team)
  local A = R.world.heroes and require("src.arena")
  local cls = A and e.class and A.byClass[e.class]
  local tag = rel == "me" and "YOU" or (rel == "ally" and "ALLY" or (rel == "enemy" and "ENEMY" or ""))
  local who = cls and cls.name or D.teamName[e.team]
  local text = rel == "me" and ((cls and ("YOU - " .. cls.name) or "YOU") .. "  Lv " .. (e.clevel or 0)) or (tag .. " - " .. (who or "?"))
  local f = font(11)
  local s = 1 / math.max(zoom, 0.6)
  local tw = f:getWidth(text) * s
  local y = e.y - e.def.radius - 28 * s
  local c = R.REL_COLOR[rel]
  local tr, tg, tb = R.teamColor(e.team)
  local lg = love.graphics
  lg.setColor(0, 0, 0, 0.65)
  lg.rectangle("fill", e.x - tw / 2 - 5 * s, y - 1 * s, tw + 10 * s, 14 * s, 3 * s)
  lg.setColor(tr, tg, tb, 0.95)
  lg.rectangle("fill", e.x - tw / 2 - 5 * s, y - 1 * s, 3 * s, 14 * s)
  lg.setColor(c[1], c[2], c[3])
  lg.setFont(f)
  lg.print(text, e.x - tw / 2, y, 0, s, s)
end

-- a General's name tag: a gold star, his name, colored by side
function R.drawGeneralTag(e, zoom)
  if zoom < 0.3 then return end
  local lg = love.graphics
  local rel = R.relation(e.team)
  local f = font(10)
  local sc = 1 / math.max(zoom, 0.6)
  local text = "* " .. (e.genName or "General")
  local tw = f:getWidth(text) * sc
  local y = e.y - e.def.radius - 24 * sc
  local c = R.REL_COLOR[rel]
  lg.setColor(0, 0, 0, 0.6)
  lg.rectangle("fill", e.x - tw / 2 - 4 * sc, y - 1 * sc, tw + 8 * sc, 13 * sc, 3 * sc)
  lg.setColor(1, 0.82, 0.25)
  lg.setFont(f)
  lg.print("*", e.x - tw / 2, y, 0, sc, sc)
  lg.setColor(c[1], c[2], c[3])
  lg.print(text:sub(2), e.x - tw / 2 + f:getWidth("*") * sc, y, 0, sc, sc)
  -- aura ring when zoomed in
  if zoom > 0.7 then
    lg.setColor(1, 0.82, 0.25, 0.12)
    lg.setLineWidth(1)
    lg.circle("line", e.x, e.y, e.squadLeader and require("src.squads").RADIUS or 320)
  end
end

function R.drawHealth(e, show)
  local d = e.def
  local frac = e.hp / e.maxhp
  if not show and frac > 0.995 then return end
  local w = d.building and d.w * D.TILE * 0.8 or math.max(22, d.radius * 2.4)
  local y = e.y - (d.building and d.h * D.TILE / 2 + 7 or d.radius + 9)
  local lg = love.graphics
  -- the frame tells friend from foe: dark for yours, green for allies, red for enemies
  local rel = R.relation(e.team)
  if rel == "ally" then lg.setColor(0.25, 0.95, 0.4, 0.9)
  elseif rel == "enemy" then lg.setColor(1, 0.25, 0.2, 0.85)
  else lg.setColor(0, 0, 0, 0.7) end
  lg.rectangle("fill", e.x - w / 2 - 1, y - 1, w + 2, 5)
  if rel ~= "me" then
    lg.setColor(0, 0, 0, 0.7)
    lg.rectangle("fill", e.x - w / 2, y, w, 3)
  end
  local r, g = 1 - frac, frac
  lg.setColor(0.2 + r * 0.8, 0.3 + g * 0.6, 0.15)
  lg.rectangle("fill", e.x - w / 2, y, w * frac, 3)
  if e.key == "commander" then
    -- experience toward the next level, 0-100%
    local xf, _, max = R.cmdXP(e)
    lg.setColor(0, 0, 0, 0.75)
    lg.rectangle("fill", e.x - w / 2 - 1, y + 4, w + 2, 4)
    if max then lg.setColor(1, 0.85, 0.3) else lg.setColor(0.68, 0.55, 1) end
    lg.rectangle("fill", e.x - w / 2, y + 5, w * xf, 2)
  end
end

function R.drawWorld(cam, game)
  local world = R.world
  local map = world.map
  local lg = love.graphics
  local T = D.TILE

  -- terrain
  lg.setColor(1, 1, 1)
  if groovy() then
    -- slowly cycling psychedelic tint
    local r1, g1, b1 = hsv(world.time * 0.03, 0.45, 1)
    lg.setColor(0.55 + r1 * 0.6, 0.55 + g1 * 0.6, 0.55 + b1 * 0.6)
  end
  local s = T / map.imagePx
  lg.draw(map.image, 0, 0, 0, s, s)
  -- visible bounds in world coords
  local x0, y0, x1, y1 = cam.wx0, cam.wy0, cam.wx1, cam.wy1
  if groovy() then
    -- drifting blobs of color
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    local span = math.min(x1 - x0, 6000)
    for i = 1, 5 do
      local a = world.time * 0.15 + i * 1.3
      local rr, gg, bb = hsv(world.time * 0.04 + i * 0.2, 0.9, 1)
      lg.setColor(rr, gg, bb, 0.07)
      lg.circle("fill", cx + math.cos(a) * span * 0.35, cy + math.sin(a * 1.3) * span * 0.35, span * 0.3, 48)
    end
  end

  -- grid lines when zoomed in
  if cam.zoom > 0.9 then
    lg.setColor(0, 0, 0, 0.06)
    lg.setLineWidth(1)
    local tx0, tx1 = math.max(0, math.floor(x0 / T)), math.min(map.w, math.ceil(x1 / T))
    local ty0, ty1 = math.max(0, math.floor(y0 / T)), math.min(map.h, math.ceil(y1 / T))
    for tx = tx0, tx1 do lg.line(tx * T, ty0 * T, tx * T, ty1 * T) end
    for ty = ty0, ty1 do lg.line(tx0 * T, ty * T, tx1 * T, ty * T) end
  end

  -- Commander of Heroes: bunkers, and War is Hell's blood on the ground (under the units)
  if world.squads then require("src.squads").drawGround(world) end
  -- the Power Core node (a pad in the middle of the map, until someone builds on it)
  local cn = map.coreNode
  if cn and not map.blocked[cn.y * map.w + cn.x] then
    local px, py = (cn.x + 1) * T, (cn.y + 1) * T
    local pulse = 0.6 + 0.4 * math.sin(love.timer.getTime() * 2)
    lg.setColor(0.1, 0.12, 0.16, 0.85)
    lg.rectangle("fill", cn.x * T + 2, cn.y * T + 2, 2 * T - 4, 2 * T - 4, 6)
    lg.setColor(0.4, 0.85, 1, 0.5 + 0.4 * pulse)
    lg.setLineWidth(3)
    lg.rectangle("line", cn.x * T + 2, cn.y * T + 2, 2 * T - 4, 2 * T - 4, 6)
    lg.circle("fill", px, py, 6 + 3 * pulse)
  end
  -- metal deposits
  for _, dpos in ipairs(map.deposits) do
    local cx, cy = (dpos.x + 0.5) * T, (dpos.y + 0.5) * T
    if cx > x0 - T and cx < x1 + T and cy > y0 - T and cy < y1 + T then
      if dpos.sea or dpos.rich then
        -- rich deposit: teal ring offshore, gold ring on land
        if dpos.sea then lg.setColor(0.35, 0.95, 0.9, 0.7) else lg.setColor(1, 0.8, 0.25, 0.85) end
        lg.setLineWidth(2)
        lg.circle("line", cx, cy, 14)
      end
      lg.setColor(0.12, 0.12, 0.12, 0.85)
      lg.circle("fill", cx, cy, 11)
      lg.setColor(0.85, 0.75, 0.35, 0.9)
      lg.circle("fill", cx - 3, cy - 2, 3)
      lg.circle("fill", cx + 3, cy + 3, 2.5)
      lg.circle("fill", cx + 4, cy - 4, 2)
    end
  end

  -- drop pods: the wreck where each Commander landed (his home, where he recharges)
  if world.dropPods then
    local now = world.time
    for t, p in pairs(world.dropPods) do
      local own = t == world.playerTeam or not world:hostile(t, world.playerTeam)
      local tx, ty = math.floor(p.x / T), math.floor(p.y / T)
      local vis = world.noFog or own or (world.visible[ty * map.w + tx] == 1) or p.seen
      if vis then p.seen = true end
      if vis and p.x > x0 - 120 and p.x < x1 + 120 and p.y > y0 - 900 and p.y < y1 + 120 then
        local tc = D.teamColor[t]
        local cr, cg, cb = tc[1], tc[2], tc[3]
        if now < p.landAt then
          -- falling: shadow growing on the ground, the pod and its flame trail coming down
          local k = math.max(0, (p.landAt - now) / p.landAt)
          local hgt = 700 * k * k
          lg.setColor(0, 0, 0, 0.45 * (1 - k))
          lg.ellipse("fill", p.x, p.y, 20 * (1 - k * 0.6), 9 * (1 - k * 0.6))
          local py = p.y - hgt
          for i = 1, 6 do
            lg.setColor(1, 0.55 + i * 0.05, 0.2, 0.5 - i * 0.07)
            lg.circle("fill", p.x + math.sin(now * 40 + i) * 2, py - 14 - i * 12, 9 - i)
          end
          lg.setColor(0.32, 0.34, 0.38)
          lg.ellipse("fill", p.x, py, 12, 18)
          lg.setColor(cr, cg, cb)
          lg.rectangle("fill", p.x - 11, py - 3, 22, 6)
        else
          -- the wreck: a scorched crater and the opened pod, glowing while he recharges
          lg.setColor(0.08, 0.07, 0.06, 0.55)
          lg.circle("fill", p.x, p.y, 40)
          lg.setColor(0.12, 0.1, 0.08, 0.5)
          lg.circle("fill", p.x, p.y, 26)
          local c = world.teams[t] and world.teams[t].commander
          local healing = c and c.alive and c.key == "commander" and c.atBase and c.hp < c.maxhp - 0.5
          if healing then
            local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 4)
            lg.setColor(0.4, 1, 0.6, 0.25 + 0.3 * pulse)
            lg.setLineWidth(3)
            lg.circle("line", p.x, p.y, 30 + 6 * pulse)
          end
          lg.setColor(0.22, 0.24, 0.27)
          lg.ellipse("fill", p.x, p.y, 13, 19)
          lg.setColor(0.36, 0.38, 0.42)
          lg.ellipse("fill", p.x - 2, p.y - 3, 9, 13)
          lg.setColor(0.05, 0.05, 0.06)
          lg.ellipse("fill", p.x + 3, p.y - 4, 5, 8) -- the open hatch
          lg.setColor(cr, cg, cb, 0.9)
          lg.rectangle("fill", p.x - 12, p.y + 4, 24, 4)
          -- three fins
          lg.setColor(0.18, 0.19, 0.22)
          lg.polygon("fill", p.x - 13, p.y + 10, p.x - 22, p.y + 22, p.x - 8, p.y + 16)
          lg.polygon("fill", p.x + 13, p.y + 10, p.x + 22, p.y + 22, p.x + 8, p.y + 16)
          lg.polygon("fill", p.x - 3, p.y + 18, p.x, p.y + 28, p.x + 3, p.y + 18)
        end
      end
    end
  end

  local sel = game.selected
  local margin = 80

  -- buildings first, then sea, land, air
  local order = { building = 1, sub = 2, sea = 3, land = 4, air = 5 }
  local list = {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.x > x0 - margin and e.x < x1 + margin and e.y > y0 - margin and e.y < y1 + margin then
      local show = e.dormant or world:isVisible(e) or (e.def.building and e.seen[world.playerTeam])
      if e.inMine then show = false end
      -- the Commander is still in his pod
      if e.key == "commander" and world.dropPods and world.time < (require("src.world").POD_LAND or 0) then show = false end
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

  if world.arena and world.arena.jungle then require("src.jungle").draw(world) end
  if world.craft then require("src.craft_ui").drawWorld(world, x0, y0, x1, y1, list) end
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
    R.drawHealth(e, sel[e] or e.built < 1 or (e.key == "commander") or e.general or e.squadLeader)
  end
  if world.craft then require("src.craft_ui").drawOver(world, cam, list) end
  for _, e in ipairs(list) do
    if e.key == "commander" then R.drawNameplate(e, cam.zoom)
    elseif e.general or e.squadLeader then R.drawGeneralTag(e, cam.zoom) end
  end

  -- repair zones: the one being dragged, and those of selected constructors
  if game then
    local cx, cy, r = game:zoneDraft()
    if cx and r >= 40 then
      r = math.max(140, math.min(900, r))
      lg.setColor(0.3, 1, 0.6, 0.12); lg.circle("fill", cx, cy, r)
      lg.setColor(0.3, 1, 0.6, 0.8); lg.setLineWidth(2); lg.circle("line", cx, cy, r)
    end
    local shown = {}
    for e in pairs(game.selected) do
      local o = e.alive and e.orders and e.orders[1]
      if o and o.type == "repairzone" then
        local k = math.floor(o.x) .. ":" .. math.floor(o.y)
        if not shown[k] then
          shown[k] = true
          lg.setColor(0.3, 1, 0.6, 0.06); lg.circle("fill", o.x, o.y, o.r)
          lg.setColor(0.3, 1, 0.6, 0.45); lg.setLineWidth(1.5); lg.circle("line", o.x, o.y, o.r)
        end
      end
    end
  end

  -- projectiles
  for _, p in ipairs(world.projectiles) do
    if not p.melee and p.x > x0 - 20 and p.x < x1 + 20 and p.y > y0 - 20 and p.y < y1 + 20 then
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
        if groovy() then
          local rr, gg, bb = hsv(world.time * 2 + p.sx * 0.01, 0.9, 1)
          lg.setColor(rr, gg, bb)
          lg.circle("fill", p.x, p.y, 3)
        else
          local cr, cg, cb = teamColor(p.team)
          lg.setColor(math.min(1, cr + 0.5), math.min(1, cg + 0.5), math.min(1, cb + 0.4))
          lg.setLineWidth(2)
          lg.line(p.x, p.y, p.x - nx * 8, p.y - ny * 8)
        end
      end
    end
  end

  -- effects
  for _, fx in ipairs(world.effects) do
    local k = fx.t / fx.life
    if fx.kind == "label" then
      -- floating text (skill call-outs): rises and fades, constant size on screen
      local zs = 1 / math.max(0.5, cam.zoom)
      local f = font(fx.size or 14)
      local tw = f:getWidth(fx.text) * zs
      local yy = fx.y - k * 30
      local a = 1 - k * k
      lg.setFont(f)
      lg.setColor(0, 0, 0, 0.6 * a)
      lg.rectangle("fill", fx.x - tw / 2 - 4 * zs, yy - 2 * zs, tw + 8 * zs, (f:getHeight() + 4) * zs, 3 * zs)
      lg.setColor(fx.color[1], fx.color[2], fx.color[3], a)
      lg.print(fx.text, fx.x - tw / 2, yy, 0, zs, zs)
    elseif groovy() and (fx.kind == "boom" or fx.kind == "splash" or fx.kind == "hit" or fx.kind == "nuke") then
      -- flower power
      local size = fx.kind == "hit" and 7 or fx.size
      local grow = fx.kind == "nuke" and (0.3 + k * 1.3) or (0.4 + k * 0.8)
      local hue = (fx.x * 0.003 + fx.y * 0.002) % 1
      flower(fx.x, fx.y, size * grow, fx.kind == "nuke" and 12 or 6, hue, 1 - k * k, k * 2)
      if fx.kind == "nuke" then
        for ring = 1, 6 do
          local rr, gg, bb = hsv(ring / 6 + world.time * 0.2, 0.9, 1)
          lg.setColor(rr, gg, bb, (1 - k) * 0.7)
          lg.setLineWidth(8)
          lg.circle("line", fx.x, fx.y, fx.size * (0.2 + k * 1.4) + ring * 10)
        end
      end
    elseif fx.kind == "boom" then
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
    elseif fx.kind == "nuke" then
      local R0 = fx.size
      local flash = math.max(0, 1 - k * 3)
      lg.setColor(1, 1, 0.9, flash * 0.9)
      lg.circle("fill", fx.x, fx.y, R0 * (0.3 + k * 1.2))
      lg.setColor(1, 0.55, 0.15, (1 - k) * 0.6)
      lg.circle("fill", fx.x, fx.y, R0 * (0.5 + k * 0.6))
      lg.setColor(1, 0.85, 0.5, 1 - k)
      lg.setLineWidth(6)
      lg.circle("line", fx.x, fx.y, R0 * (0.2 + k * 1.4))
      lg.setColor(0.3, 0.25, 0.2, (1 - k) * 0.5)
      lg.circle("fill", fx.x, fx.y - k * 60, R0 * 0.35 * (0.5 + k))
    elseif fx.kind == "dropship" then
      -- the dropship descends, hovers, then lifts off
      local alt = (k < 0.4) and (1 - k / 0.4) * 300 or ((k > 0.75) and (k - 0.75) / 0.25 * 300 or 0)
      lg.setColor(0, 0, 0, 0.35)
      lg.ellipse("fill", fx.x, fx.y, 70, 30)
      local px, py = fx.x, fx.y - 40 - alt
      local cr, cg, cb = teamColor(0)
      lg.setColor(cr * 0.6, cg * 0.6, cb * 0.6)
      lg.ellipse("fill", px, py, 70, 26)
      lg.setColor(cr, cg, cb)
      lg.ellipse("fill", px, py - 8, 40, 16)
      lg.setColor(0.9, 1, 0.6, 0.8)
      for i = -2, 2 do lg.circle("fill", px + i * 22, py + 10, 4) end
      if alt < 50 then
        lg.setColor(0.8, 1, 0.6, 0.25)
        lg.polygon("fill", px - 30, py + 12, px + 30, py + 12, fx.x + 50, fx.y, fx.x - 50, fx.y)
      end
    elseif fx.kind == "levelup" then
      lg.setColor(1, 0.85, 0.3, 1 - k)
      lg.setLineWidth(2.5)
      lg.circle("line", fx.x, fx.y, fx.size * (0.8 + k * 0.8))
    elseif fx.kind == "blood" then
      require("src.cries").drawSpray(fx, k)
    elseif fx.kind == "reticle" then
      -- a barrage on its way: a red target zone that tightens until the shells land
      local a = math.min(1, k * 6) * (1 - k * k)
      lg.setColor(1, 0.3, 0.15, 0.10 * a)
      lg.circle("fill", fx.x, fx.y, fx.size)
      lg.setColor(1, 0.35, 0.2, 0.85 * a)
      lg.setLineWidth(3)
      local r = fx.size * (1.15 - 0.15 * math.min(1, k * 3))
      for i = 0, 11 do
        local a1 = i * math.pi / 6 + k * 2
        lg.arc("line", "open", fx.x, fx.y, r, a1, a1 + math.pi / 12)
      end
      lg.line(fx.x - 14, fx.y, fx.x + 14, fx.y)
      lg.line(fx.x, fx.y - 14, fx.x, fx.y + 14)
    elseif fx.kind == "shell" then
      -- a shell dropping out of the sky onto its spot
      local h = 260 * (1 - k)
      lg.setColor(1, 0.85, 0.5, 0.25 + 0.6 * k)
      lg.setLineWidth(3)
      lg.line(fx.x + h * 0.35, fx.y - h, fx.x + h * 0.35 + 10, fx.y - h - 40)
      lg.setColor(1, 0.95, 0.75, 0.9)
      lg.circle("fill", fx.x + h * 0.35, fx.y - h, 4)
      lg.setColor(0, 0, 0, 0.25 * k)
      lg.circle("fill", fx.x, fx.y, 6 + 10 * k)
    elseif fx.kind == "ping" then
      lg.setColor(fx.r or 0.3, fx.g or 1, fx.b or 0.4, 1 - k)
      lg.setLineWidth(2)
      lg.circle("line", fx.x, fx.y, 6 + k * 18)
    -- Arena skill effects
    elseif fx.kind == "beam" then
      local c = fx.color or { 1, 0.9, 0.6 }
      lg.setColor(c[1], c[2], c[3], 0.85 * (1 - k))
      lg.setLineWidth(fx.size * (1 - k * 0.5))
      lg.line(fx.x, fx.y, fx.x2, fx.y2)
      lg.setColor(1, 1, 1, 0.6 * (1 - k))
      lg.setLineWidth(math.max(1, fx.size * 0.3))
      lg.line(fx.x, fx.y, fx.x2, fx.y2)
    elseif fx.kind == "bolt" then
      local c = fx.color or { 0.7, 0.85, 1 }
      lg.setColor(c[1], c[2], c[3], 1 - k)
      lg.setLineWidth(3)
      local pts = { fx.x, fx.y }
      local segs = 6
      for i = 1, segs - 1 do
        local t = i / segs
        pts[#pts + 1] = fx.x + (fx.x2 - fx.x) * t + (math.random() - 0.5) * 18
        pts[#pts + 1] = fx.y + (fx.y2 - fx.y) * t + (math.random() - 0.5) * 18
      end
      pts[#pts + 1] = fx.x2; pts[#pts + 1] = fx.y2
      lg.line(pts)
    elseif fx.kind == "frost" then
      lg.setColor(0.6, 0.9, 1, 0.35 * (1 - k))
      lg.circle("fill", fx.x, fx.y, fx.size * (0.6 + 0.4 * k))
      lg.setColor(0.85, 0.97, 1, 0.9 * (1 - k))
      lg.setLineWidth(3)
      lg.circle("line", fx.x, fx.y, fx.size * (0.6 + 0.4 * k))
    elseif fx.kind == "curse" then
      lg.setColor(0.7, 0.2, 0.9, 0.35 * (1 - k))
      lg.circle("fill", fx.x, fx.y, fx.size)
      lg.setColor(0.85, 0.4, 1, 0.9 * (1 - k))
      lg.setLineWidth(2)
      lg.circle("line", fx.x, fx.y, fx.size * (1 - 0.3 * k))
    elseif fx.kind == "ring" then
      local c = fx.color or { 1, 0.85, 0.4 }
      lg.setColor(c[1], c[2], c[3], 0.8 * (1 - k))
      lg.setLineWidth(4)
      lg.circle("line", fx.x, fx.y, fx.size * (0.2 + 0.8 * k))
    elseif fx.kind == "warn" then
      local pulse = 0.5 + 0.5 * math.sin(world.time * 14)
      lg.setColor(1, 0.3, 0.2, 0.25 + 0.25 * pulse)
      lg.circle("fill", fx.x, fx.y, fx.size)
      lg.setColor(1, 0.4, 0.3, 0.9)
      lg.setLineWidth(2)
      lg.circle("line", fx.x, fx.y, fx.size)
      lg.circle("line", fx.x, fx.y, fx.size * (1 - k))
    elseif fx.kind == "pillar" then
      lg.setColor(1, 0.95, 0.6, 0.8 * (1 - k))
      lg.rectangle("fill", fx.x - 16 * (1 - k), fx.y - 400, 32 * (1 - k), 400)
      lg.setColor(1, 0.9, 0.5, 0.5 * (1 - k))
      lg.circle("fill", fx.x, fx.y, fx.size * (0.5 + 0.5 * k))
    elseif fx.kind == "whirl" or fx.kind == "hammer" or fx.kind == "cyclone" then
      local col = fx.kind == "whirl" and { 1, 0.5, 0.3 } or (fx.kind == "hammer" and { 1, 0.9, 0.5 } or { 0.6, 0.9, 1 })
      lg.setColor(col[1], col[2], col[3], 0.6 * (1 - k))
      lg.setLineWidth(3)
      local a0 = world.time * 9
      for i = 0, 2 do
        local a = a0 + i * 2.09
        lg.arc("line", "open", fx.x, fx.y, fx.size * 0.8, a, a + 1.1)
      end
    end
  end

  -- fog overlay
  if not world.noFog then
    if world.fogChanged then R.updateFogImage() end
    lg.setColor(1, 1, 1)
    lg.draw(R.fogImage, 0, 0, 0, T, T)
    -- metal deposits stay marked under the fog, so you can plan where to expand
    -- (and guess where the enemy will)
    for _, dpos in ipairs(map.deposits) do
      local i = dpos.y * map.w + dpos.x
      if world.visible[i] ~= 1 then
        local cx, cy = (dpos.x + 0.5) * T, (dpos.y + 0.5) * T
        if cx > x0 - T and cx < x1 + T and cy > y0 - T and cy < y1 + T then
          if dpos.sea then lg.setColor(0.35, 0.95, 0.9, 0.45)
          elseif dpos.rich then lg.setColor(1, 0.8, 0.25, 0.55)
          else lg.setColor(0.85, 0.75, 0.35, 0.45) end
          lg.setLineWidth(1.5)
          lg.circle("line", cx, cy, 8)
          lg.circle("fill", cx, cy, 3)
        end
      end
    end
  end

  -- Commander of Heroes: capture points and flares
  if world.squads then require("src.squads").draw(world, cam, game) end

  -- Alien Tech landing zone (everyone sees it)
  local a = world.alien
  if a and (a.state == "announced" or a.state == "dormant") then
    local MOD = require("src.mods")
    local Rz = MOD.ALIEN_RADIUS
    local pulse = 0.5 + 0.5 * math.sin(world.time * 3)
    if a.state == "announced" then
      lg.setColor(0.75, 0.4, 1, 0.5 + 0.3 * pulse)
      lg.setLineWidth(3)
      for i = 0, 23 do
        local a1 = i * math.pi / 12 + world.time * 0.3
        lg.arc("line", "open", a.x, a.y, Rz, a1, a1 + math.pi / 24)
      end
      local secs = math.max(0, math.ceil(a.arriveAt - world.time))
      local f = R.font(18)
      lg.setFont(f)
      local txt = "ALIEN TECH lands in " .. secs .. "s"
      lg.setColor(0, 0, 0, 0.6)
      lg.print(txt, a.x - f:getWidth(txt) / 2 + 2, a.y - 10 + 2)
      lg.setColor(0.85, 0.6, 1)
      lg.print(txt, a.x - f:getWidth(txt) / 2, a.y - 10)
    else
      local hc = a.holder and ((groovy() and D.groovyColor or D.teamColor)[a.holder] or D.teamColor[0]) or { 0.85, 0.85, 0.85 }
      lg.setColor(0.75, 0.4, 1, 0.08)
      lg.circle("fill", a.x, a.y, Rz)
      lg.setColor(0.75, 0.4, 1, 0.6)
      lg.setLineWidth(2)
      lg.circle("line", a.x, a.y, Rz)
      if a.progress and a.progress > 0 then
        lg.setColor(hc[1], hc[2], hc[3], 0.95)
        lg.setLineWidth(8)
        lg.arc("line", "open", a.x, a.y, Rz + 8, -math.pi / 2, -math.pi / 2 + math.pi * 2 * (a.progress / MOD.ALIEN_HOLD))
      end
      local f = R.font(15)
      lg.setFont(f)
      local txt = a.contested and "CONTESTED" or (a.holder and string.format("Capturing %d%%", a.progress / MOD.ALIEN_HOLD * 100) or "Hold the zone 15s to claim")
      lg.setColor(0, 0, 0, 0.6)
      lg.print(txt, a.x - f:getWidth(txt) / 2 + 2, a.y + Rz + 14)
      lg.setColor(a.contested and 1 or 0.9, a.contested and 0.4 or 0.8, a.contested and 0.3 or 1)
      lg.print(txt, a.x - f:getWidth(txt) / 2, a.y + Rz + 12)
    end
  end

  -- nukes: everyone sees the launch, the missile and where it will land
  local CMD = require("src.commander")
  for _, n in ipairs(world.nukes or {}) do
    local blink = 0.5 + 0.5 * math.sin(world.time * 10)
    lg.setColor(1, 0.15, 0.1, 0.10 + 0.08 * blink)
    lg.circle("fill", n.tx, n.ty, CMD.NUKE_RADIUS)
    lg.setColor(1, 0.2, 0.1, 0.6 + 0.4 * blink)
    lg.setLineWidth(3)
    lg.circle("line", n.tx, n.ty, CMD.NUKE_RADIUS)
    lg.line(n.tx - 24, n.ty, n.tx + 24, n.ty); lg.line(n.tx, n.ty - 24, n.tx, n.ty + 24)
    -- trail and missile
    local dx, dy = U.norm(n.tx - n.x, n.ty - n.y)
    lg.setColor(1, 0.8, 0.5, 0.35)
    lg.setLineWidth(6)
    lg.line(n.x - dx * 90, n.y - dy * 90, n.x, n.y)
    lg.setColor(0.95, 0.95, 0.95)
    lg.setLineWidth(1)
    lg.polygon("fill", n.x + dx * 16, n.y + dy * 16, n.x - dx * 10 - dy * 6, n.y - dy * 10 + dx * 6, n.x - dx * 10 + dy * 6, n.y - dy * 10 - dx * 6)
    lg.setColor(1, 0.6, 0.2, blink)
    lg.circle("fill", n.x - dx * 12, n.y - dy * 12, 5)
  end
end

return R
