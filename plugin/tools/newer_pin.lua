package.path = "plugin/src/?.lua;" .. package.path
local compare = require("crier_obs.proc.resolver").compare
local old, new = arg[1], arg[2]
if not old or not new or not new:match("^%d+%.%d+%.%d+$") then
  io.stderr:write("Expected a stable crier release\n")
  os.exit(2)
end
local order, err = compare(new, old)
if not order then
  io.stderr:write((err and err.message or "Invalid semantic version") .. "\n")
  os.exit(2)
end
if order <= 0 then
  os.exit(3)
end
