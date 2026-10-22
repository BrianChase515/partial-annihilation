-- Local high-score table (official games only). A new game version starts a fresh table.
local S = {}
local FILE = "high_scores_v" .. require("src.defs").VERSION .. ".txt"

function S.load()
  local list = {}
  if not love.filesystem.getInfo(FILE) then return list end
  for line in love.filesystem.lines(FILE) do
    local pts, result, date, desc = line:match("^(%d+)\t(.-)\t(.-)\t(.*)$")
    if pts then list[#list + 1] = { pts = tonumber(pts), result = result, date = date, desc = desc } end
  end
  table.sort(list, function(a, b) return a.pts > b.pts end)
  return list
end

function S.add(entry)
  local list = S.load()
  list[#list + 1] = entry
  table.sort(list, function(a, b) return a.pts > b.pts end)
  local out = {}
  for i = 1, math.min(20, #list) do
    local e = list[i]
    out[#out + 1] = string.format("%d\t%s\t%s\t%s", e.pts, e.result, e.date, (e.desc or ""):gsub("[\t\n]", " "))
  end
  love.filesystem.write(FILE, table.concat(out, "\n") .. "\n")
  for i, e in ipairs(list) do if e == entry then return i end end
end

return S
