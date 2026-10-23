local M = {}
function M.new(kind, message, hint)
  return { kind = kind, message = message, hint = hint }
end
local codes = {}
codes[0] = "Posted successfully"
codes[1] = "Invalid configuration"
codes[2] = "Invalid command arguments"
codes[3] = "Rendering failed"
codes[4] = "Some platforms failed"
codes[5] = "Publishing failed"
codes[6] = "Staging failed"
codes[97] = "Run directory is missing"
codes[126] = "crier is not executable"
codes[127] = "crier was not found"
function M.from_exit(code, signal)
  if signal then
    return M.new("signal", "crier stopped by signal " .. signal)
  end
  if code and code >= 0x80000000 then
    return M.new("crashed", "crier crashed (NTSTATUS " .. string.format("0x%08x", code) .. ")")
  end
  return M.new(
    code == 0 and "ok" or "exit",
    codes[code] or ("crier exited with code " .. tostring(code)),
    code == 126 and "On macOS, check the downloaded binary’s quarantine attribute." or nil
  )
end
function M.timeout()
  return M.new("timeout", "crier exceeded the run timeout")
end
M.exit = M.from_exit
return M
