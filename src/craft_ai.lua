-- Commander Craft computer player (filled in below)
local AI = {}
AI.__index = AI
function AI.new(world, team, level)
  local self = setmetatable({}, AI)
  self.world, self.team, self.level = world, team, level or 5
  self.profileName = "Craft"
  return self
end
function AI:update(dt) end
return AI
