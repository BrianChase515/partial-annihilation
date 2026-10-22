-- Grid A* with 8-way movement, partial paths and line-of-sight smoothing.
local U = require("src.util")

local P = {}

local SQ2 = 1.41421356
local DIRS = {
  { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
  { 1, 1, SQ2 }, { 1, -1, SQ2 }, { -1, 1, SQ2 }, { -1, -1, SQ2 },
}

local function octile(ax, ay, bx, by)
  local dx, dy = math.abs(ax - bx), math.abs(ay - by)
  if dx > dy then return dx + (SQ2 - 1) * dy end
  return dy + (SQ2 - 1) * dx
end

-- Straight-line walkability between tile centers (supercover-ish sampling)
function P.lineClear(map, layer, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local n = math.ceil(math.max(math.abs(dx), math.abs(dy)) * 3)
  if n == 0 then return true end
  for i = 1, n do
    local t = i / n
    local x, y = ax + dx * t, ay + dy * t
    -- check a small cross around the sample to keep away from corners
    for _, o in ipairs({ { 0, 0 }, { 0.3, 0 }, { -0.3, 0 }, { 0, 0.3 }, { 0, -0.3 } }) do
      if not map:passable(layer, math.floor(x + 0.5 + o[1]), math.floor(y + 0.5 + o[2])) then
        return false
      end
    end
  end
  return true
end

-- Find a path from world (sx,sy) to world (gx,gy). Returns list of {x,y} world points.
function P.find(map, layer, sx, sy, gx, gy, budget)
  budget = budget or 9000
  local T = map.T
  local w = map.w
  local stx, sty = math.floor(sx / T), math.floor(sy / T)
  local gtx, gty = math.floor(gx / T), math.floor(gy / T)
  gtx, gty = U.clamp(gtx, 0, map.w - 1), U.clamp(gty, 0, map.h - 1)

  -- If the unit stands on a blocked tile (e.g. just spawned), start from nearest free tile
  if not map:passable(layer, stx, sty) then
    local nx, ny = map:nearestTile(stx, sty, function(x, y) return map:passable(layer, x, y) end, 4)
    if not nx then return nil end
    stx, sty = nx, ny
  end
  -- If goal is impassable, aim for the nearest passable tile instead
  local replaced = false
  if not map:passable(layer, gtx, gty) then
    local nx, ny = map:nearestTile(gtx, gty, function(x, y) return map:passable(layer, x, y) end, 12)
    if nx then gtx, gty = nx, ny; replaced = true end
  end

  local start = sty * w + stx
  local goal = gty * w + gtx
  local open = U.newHeap()
  local g = { [start] = 0 }
  local came = {}
  local closed = {}
  open:push(start, octile(stx, sty, gtx, gty))
  local best, bestH = start, octile(stx, sty, gtx, gty)
  local expanded = 0
  local found = false

  while open.n > 0 do
    local cur = open:pop()
    if not closed[cur] then
      closed[cur] = true
      if cur == goal then found = true; break end
      expanded = expanded + 1
      if expanded > budget then break end
      local cx, cy = cur % w, math.floor(cur / w)
      local cg = g[cur]
      for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        if map:passable(layer, nx, ny) then
          -- no corner cutting
          local okDiag = true
          if d[3] ~= 1 then
            okDiag = map:passable(layer, cx + d[1], cy) and map:passable(layer, cx, cy + d[2])
          end
          if okDiag then
            local ni = ny * w + nx
            if not closed[ni] then
              local ng = cg + d[3]
              if not g[ni] or ng < g[ni] then
                g[ni] = ng
                came[ni] = cur
                local hh = octile(nx, ny, gtx, gty)
                open:push(ni, ng + hh * 1.05)
                if hh < bestH then best, bestH = ni, hh end
              end
            end
          end
        end
      end
    end
  end

  local endNode = found and goal or best
  local tiles = {}
  local n = endNode
  while n do
    tiles[#tiles + 1] = n
    n = came[n]
  end
  -- reverse into tile coords
  local pts = {}
  for i = #tiles, 1, -1 do
    local t = tiles[i]
    pts[#pts + 1] = { t % w, math.floor(t / w) }
  end
  -- smooth: greedy farthest visible
  local out = {}
  local i = 1
  while i < #pts do
    local j = #pts
    while j > i + 1 and not P.lineClear(map, layer, pts[i][1], pts[i][2], pts[j][1], pts[j][2]) do
      j = j - 1
    end
    out[#out + 1] = pts[j]
    i = j
  end
  local path = {}
  for k, p in ipairs(out) do
    path[k] = { x = (p[1] + 0.5) * T, y = (p[2] + 0.5) * T }
  end
  -- final point: exact goal if reachable tile is the goal tile
  if found and not replaced then
    if #path > 0 then path[#path] = { x = gx, y = gy } else path[1] = { x = gx, y = gy } end
  end
  return path, found
end

return P
