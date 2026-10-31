-- Map thumbnails for the title screen: Commander Craft and Arena maps are built from fixed
-- templates, so a small picture says more than a paragraph. Terrain is drawn one pixel per
-- tile into a cached image; gold mines, bases, creep camps and shrines are marked on top.
local M = require("src.map")

local MT = {}
local cache = {}

local function terrainImage(map)
  local w, h = map.w, map.h
  local id = love.image.newImageData(w, h)
  for ty = 0, h - 1 do
    for tx = 0, w - 1 do
      local i = ty * w + tx
      local t = map.terrain[i]
      local r, g, b = 0.30, 0.45, 0.25
      if t == M.WATER then r, g, b = 0.12, 0.30, 0.50
      elseif map.river and map.river[i] then r, g, b = 0.22, 0.42, 0.50
      elseif t == M.HILL then r, g, b = 0.42, 0.50, 0.30
      elseif t == M.ROCK then r, g, b = 0.34, 0.32, 0.30
      elseif t == 4 then r, g, b = 0.12, 0.26, 0.12 end
      id:setPixel(tx, ty, r, g, b, 1)
    end
  end
  local img = love.graphics.newImage(id)
  img:setFilter("linear", "nearest")
  return img
end

-- a Craft map: its template (and camp setting: "random" camps show this one seed's spots)
function MT.craft(template, camps)
  local key = "craft:" .. template .. ":" .. (camps or "plenty")
  if cache[key] then return cache[key] end
  local CM = require("src.craft_map")
  local players = nil
  for _, t in ipairs(CM.TEMPLATES) do if t[1] == template and t.players == 4 then players = { {}, {}, {}, {} } end end
  local map = CM.generate({ template = template, seed = 1, camps = camps, players = players })
  local marks = {}
  for _, m in ipairs(map.mines or {}) do marks[#marks + 1] = { x = m.x + 1, y = m.y + 1, kind = (m.gold or 0) > 9000 and "richmine" or "mine" } end
  for i, hl in ipairs(map.halls or {}) do marks[#marks + 1] = { x = hl.x + 2, y = hl.y + 2, kind = "base", side = ((i - 1) % 2) + 1 } end
  for _, cp in ipairs(map.camps or {}) do marks[#marks + 1] = { x = cp.x, y = cp.y, kind = "camp" .. (cp.kind or "small") } end
  local t = { img = terrainImage(map), w = map.w, h = map.h, marks = marks,
    note = camps == "random" and "extra camps move every game" or nil }
  cache[key] = t
  return t
end

-- an Arena map, built with the options the menu would start it with
function MT.arena(opts, key)
  key = "arena:" .. key
  if cache[key] then return cache[key] end
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.seed = 1
  local ok, map = pcall(M.generateArena, o)
  if not ok or not map then return nil end
  local marks = {}
  for sd, c in ipairs(map.cores or {}) do marks[#marks + 1] = { x = c.x, y = c.y, kind = "base", side = sd } end
  for _, cp in ipairs(map.camps or {}) do marks[#marks + 1] = { x = cp.x, y = cp.y, kind = "camp" .. (cp.kind or "small") } end
  for _, s in ipairs(map.shrines or {}) do marks[#marks + 1] = { x = s.x, y = s.y, kind = "shrine" } end
  for _, p in ipairs(map.pits or {}) do marks[#marks + 1] = { x = p.x, y = p.y, kind = "boss" } end
  for _, tw in ipairs(map.towers or {}) do marks[#marks + 1] = { x = tw.x, y = tw.y, kind = "tower", side = tw.side } end
  -- the lanes, as lines (points are in tiles)
  local lanes = {}
  for _, L in ipairs(map.lanes or {}) do
    local pts = {}
    for _, p in ipairs(L.pts or {}) do pts[#pts + 1] = { p[1] or p.x, p[2] or p.y } end
    lanes[#lanes + 1] = pts
  end
  local t = { img = terrainImage(map), w = map.w, h = map.h, marks = marks, lanes = lanes,
    note = (o.template == "treeline" or o.template == "battlefield") and "randomized every match" or nil }
  cache[key] = t
  return t
end

local SIDE = { { 0.35, 0.6, 1 }, { 1, 0.35, 0.3 }, { 0.4, 1, 0.5 }, { 1, 0.85, 0.3 } }

-- draw it in a framed square at (x, y), size px, with a title and a small key
function MT.draw(t, x, y, size, title)
  if not t then return end
  local lg = love.graphics
  local R = require("src.render")
  lg.setColor(0.05, 0.06, 0.07, 0.85)
  lg.rectangle("fill", x - 6, y - 6, size + 12, size + 40, 6)
  lg.setColor(1, 1, 1)
  local s = size / math.max(t.w, t.h)
  lg.draw(t.img, x, y, 0, s, s)
  if t.lanes then
    lg.setColor(0.85, 0.78, 0.55, 0.85)
    lg.setLineWidth(2.5)
    for _, pts in ipairs(t.lanes) do
      local flat = {}
      for _, p in ipairs(pts) do flat[#flat + 1] = x + (p[1] + 0.5) * s; flat[#flat + 1] = y + (p[2] + 0.5) * s end
      if #flat >= 4 then lg.line(flat) end
    end
    lg.setLineWidth(1)
  end
  for _, m in ipairs(t.marks) do
    local px, py = x + (m.x + 0.5) * s, y + (m.y + 0.5) * s
    if m.kind == "mine" or m.kind == "richmine" then
      lg.setColor(1, 0.85, 0.25)
      lg.rectangle("fill", px - 3, py - 3, 6, 6)
      if m.kind == "richmine" then lg.setColor(1, 1, 0.7); lg.rectangle("line", px - 4.5, py - 4.5, 9, 9) end
    elseif m.kind == "base" then
      local c = SIDE[m.side or 1] or SIDE[1]
      lg.setColor(c[1], c[2], c[3])
      lg.rectangle("fill", px - 5, py - 5, 10, 10, 2)
      lg.setColor(0, 0, 0, 0.8)
      lg.rectangle("line", px - 5, py - 5, 10, 10, 2)
    elseif m.kind:match("^camp") then
      local r = m.kind == "campbig" and 4.5 or (m.kind == "campmedium" and 3.5 or 2.6)
      lg.setColor(0.95, 0.3, 0.25)
      lg.circle("fill", px, py, r)
    elseif m.kind == "shrine" then
      lg.setColor(0.6, 0.9, 1)
      lg.circle("line", px, py, 3.5)
    elseif m.kind == "boss" then
      lg.setColor(0.85, 0.4, 1)
      lg.circle("fill", px, py, 4.5)
    elseif m.kind == "tower" then
      local c = SIDE[m.side or 1] or SIDE[1]
      lg.setColor(c[1], c[2], c[3], 0.9)
      lg.rectangle("fill", px - 2, py - 2, 4, 4)
    end
  end
  lg.setColor(0.45, 0.5, 0.55)
  lg.rectangle("line", x - 0.5, y - 0.5, size + 1, size + 1)
  lg.setFont(R.font(12))
  lg.setColor(0.9, 0.92, 0.85)
  lg.print(title or "", x, y + size + 6)
  lg.setFont(R.font(10))
  lg.setColor(0.65, 0.68, 0.62)
  local key = t.lanes and "lanes, towers, red = camps" or "gold = mine   red = creeps"
  lg.print(t.note and (t.note) or key, x, y + size + 21)
end

return MT
