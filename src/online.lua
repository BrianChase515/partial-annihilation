-- Talking to GitHub without any libraries: `curl` (built into macOS, Windows 10+ and most
-- Linux) runs in a background thread so the game never stalls.
--   * update check: compares VERSION on GitHub with ours, and can download the newest
--     PartialAnnihilation.love over the one we're running from
--   * online leaderboard: reads leaderboard/v<version>.json; scores are submitted by opening a
--     pre-filled GitHub issue that a GitHub Action checks and adds to the board
local D = require("src.defs")
local O = { state = "idle" }

O.REPO = "BrianChase515/partial-annihilation"
O.RAW = "https://raw.githubusercontent.com/" .. O.REPO .. "/main/"
O.LOVE_URL = O.RAW .. "dist/PartialAnnihilation.love"

local THREAD = [[
local cmd, id = ...
local f = io.popen(cmd)
local out = f and f:read("*a") or ""
if f then f:close() end
love.thread.getChannel("pa_online"):push({ id = id, out = out })
]]

local pending = {}

local function lovePath()
  local src = love.filesystem.getSource()
  if src and src:match("%.love$") then return src end
end

local function shellQuote(s)
  if love.system.getOS() == "Windows" then return '"' .. s .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function O.enabled()
  if love.system.getOS() == "Web" then return false end
  return io and io.popen ~= nil and love.thread ~= nil
end

-- 32-bit XOR without the LuaJIT bit library (the browser build runs plain Lua)
local function bxor(a, b)
  if bit then return bit.bxor(a, b) end
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = (a - x) / 2, (b - y) / 2, p * 2
  end
  return r
end

local function run(id, cmd)
  if not O.enabled() then return end
  pending[id] = true
  love.thread.newThread(THREAD):start(cmd, id)
end

function O.vnum(v)
  local n = 0
  for part in tostring(v):gmatch("%d+") do n = n * 1000 + tonumber(part) end
  local parts = select(2, tostring(v):gsub("%d+", ""))
  for _ = parts + 1, 3 do n = n * 1000 end
  return n
end

-- kick off the update check + leaderboard fetch (call once on the title screen)
function O.check()
  if not O.enabled() then return end
  -- once per launch, and again whenever you come back to the title screen a while later
  local now = love.timer.getTime()
  if O.checkedAt and now - O.checkedAt < 120 then return end
  if pending.version or O.state == "downloading" or O.state == "updated" then return end
  O.checkedAt = now
  O.checked = true
  run("version", "curl -fsSL --max-time 8 " .. O.RAW .. "VERSION")
  run("board", "curl -fsSL --max-time 8 " .. O.RAW .. "leaderboard/v" .. D.SEASON .. ".json")
  run("arenaboard", "curl -fsSL --max-time 8 " .. O.RAW .. "leaderboard/arena-v" .. D.SEASON .. ".json")
end

-- replace the .love we were launched from with the newest build
O.DOWNLOAD_PAGE = "https://github.com/" .. O.REPO .. "#download"

function O.update()
  local dst = lovePath()
  if not dst then
    -- standalone builds (Windows .exe, Linux AppImage) can't replace themselves while
    -- running: send the player to the download page instead
    love.system.openURL(O.DOWNLOAD_PAGE)
    O.state = "noupdate"
    O.msg = "Opened the download page in your browser - grab the new build there."
    return
  end
  O.state = "downloading"
  O.tmp = dst .. ".download"
  run("download", "curl -fsSL --max-time 120 -o " .. shellQuote(O.tmp) .. " " .. O.LOVE_URL .. " && echo OK")
end

local function finishDownload(out)
  local dst = lovePath()
  local f = io.open(O.tmp, "rb")
  local head = f and f:read(2)
  local size = f and f:seek("end") or 0
  if f then f:close() end
  if out:match("OK") and head == "PK" and size > 100000 then
    os.remove(dst .. ".old")
    os.rename(dst, dst .. ".old")
    if os.rename(O.tmp, dst) then
      os.remove(dst .. ".old")
      O.state = "updated"
      O.msg = "Updated to v" .. (O.latest or "?") .. ". Restart to play it."
      return
    end
    os.rename(dst .. ".old", dst)
  end
  os.remove(O.tmp)
  O.state = "failed"
  O.msg = "Update failed (no connection?). You can also download it from github.com/" .. O.REPO
end

local function parseBoard(s)
  -- tiny reader for [{"name":..,"score":..,"result":..,"time":..}, ...]
  local list = {}
  for obj in s:gmatch("{(.-)}") do
    local e = {}
    for k, v in obj:gmatch('"(%w+)"%s*:%s*"?([^",]*)"?') do e[k] = tonumber(v) or v end
    if e.score then list[#list + 1] = e end
  end
  table.sort(list, function(a, b) return a.score > b.score end)
  return list
end

function O.poll()
  if not O.enabled() then return end
  local ch = love.thread.getChannel("pa_online")
  local msg = ch:pop()
  while msg do
    pending[msg.id] = nil
    local out = msg.out or ""
    if msg.id == "version" then
      local v = out:match("([%d%.]+)")
      if v then
        O.latest = v
        if O.vnum(v) > O.vnum(D.VERSION) then O.state = "available" end
      end
    elseif msg.id == "board" then
      O.board = parseBoard(out)
    elseif msg.id == "arenaboard" then
      O.arenaBoard = parseBoard(out)
    elseif msg.id == "download" then
      finishDownload(out)
    end
    msg = ch:pop()
  end
end

-- a light checksum so the Action can spot hand-edited submissions (not real security:
-- the game is open source)
function O.check32(s)
  local h = 2166136261
  for i = 1, #s do
    h = bxor(h, s:byte(i)) % 4294967296
    -- h * 16777619 mod 2^32 without overflowing a double (16777619 = 2^24 + 403)
    h = (h * 403 + (h % 256) * 16777216) % 4294967296
  end
  return string.format("%08x", h)
end

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- open a pre-filled GitHub issue; the leaderboard Action does the rest
function O.submit(info)
  local fields = {
    "version: " .. D.VERSION,
    "mode: " .. (info.mode or "rts"),
    "score: " .. info.score,
    "result: " .. info.result,
    "time: " .. info.time,
    "players: " .. info.players,
    "map: " .. info.map,
    "lineup: " .. info.lineup,
    "breakdown: " .. info.breakdown,
  }
  local key = table.concat({ D.VERSION, info.score, info.result, info.time, info.map }, "|")
  fields[#fields + 1] = "check: " .. O.check32(key .. "|partial")
  local body = "Submitted from Partial Annihilation. Just press **Submit new issue** - the bot adds it to the "
    .. "[leaderboard](https://github.com/" .. O.REPO .. "/blob/main/LEADERBOARD.md) and closes this.\n\n```pa-score\n"
    .. table.concat(fields, "\n") .. "\n```\n"
  local title = string.format("[score] %s%s - %s %s", info.mode == "arena" and "Arena " or "", info.score, info.result, info.time)
  local url = "https://github.com/" .. O.REPO .. "/issues/new?title=" .. urlencode(title) .. "&body=" .. urlencode(body)
  return love.system.openURL(url)
end

return O
