local ffi = require("ffi")
local cmdline = require("crier_obs.proc.cmdline_windows")
local M = {}
local function shell(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function ps(s)
  return "'" .. s:gsub("'", "''") .. "'"
end
function M.new(deps)
  local env = deps.env or {}
  local platform = env.os or ffi.os
  local pin = deps.pin or "1.1.1"
  local process, phase
  local current = { state = "idle", message = "" }
  local self = {}
  local function cancel_process(p)
    if p.cancel then
      return p.cancel()
    end
    if p.close then
      return p.close()
    end
    if p.kill then
      p.kill()
    elseif p.terminate then
      p.terminate()
    end
    if p.detach then
      return p.detach()
    end
  end
  local function spawn(plan)
    local p, e = deps.spawner.spawn(plan)
    if not p then
      phase = nil
      current = { state = "failed", message = e.message }
      return nil, e
    end
    process = p
    return p
  end
  function self.start()
    if process or phase then
      return nil, { kind = "busy", message = "Installation is already running" }
    end
    if not pin:match("^%d+%.%d+%.%d+[%w.%-]*$") then
      return nil, { kind = "version", message = "Invalid installer pin" }
    end
    local dir = deps.state_dir .. (platform == "Windows" and "\\bin" or "/bin")
    local url = "https://raw.githubusercontent.com/yohimik/crier/v"
      .. pin
      .. "/install."
      .. (platform == "Windows" and "ps1" or "sh")
    local plan = { env = {}, capture_stdout = true, capture_stderr = true, timeout = 300, kind = "installer" }
    if platform == "Windows" then
      plan.executable = cmdline.powershell(env.getenv and env.getenv("SystemRoot"))
      plan.args = {
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        "& ([scriptblock]::Create((Invoke-RestMethod "
          .. ps(deps.url or url)
          .. "))) -Version "
          .. ps(pin)
          .. " -BinDir "
          .. ps(dir),
      }
    else
      -- curl must succeed before the verified official installer is run; a failed fetch never feeds a partial script to sh.
      local curl = deps.curl_cmd or (platform == "OSX" and "/usr/bin/curl" or "curl")
      plan.executable = "/bin/sh"
      plan.args = {
        "-c",
        "script=$(" .. shell(curl) .. " -fsSL " .. shell(deps.url or url) .. ") || exit $?; CRIER_VERSION=" .. shell(
          pin
        ) .. " CRIER_BIN_DIR=" .. shell(dir) .. ' /bin/sh -c "$script"',
      }
    end
    current = { state = "installing", message = "Installing crier " .. pin .. "…" }
    phase = "install"
    return spawn(plan)
  end
  function self.tick()
    if not process then
      return current
    end
    local r, e = process.poll()
    if e then
      local failed = process
      process = nil
      phase = nil
      cancel_process(failed)
      current = { state = "failed", message = e.message or tostring(e) }
      return current, e
    end
    if not r then
      return current, e
    end
    process = nil
    if phase == "install" then
      if r.code ~= 0 or r.timed_out then
        phase = nil
        current = {
          state = "failed",
          message = r.timed_out and "Installation timed out" or (r.stderr ~= "" and r.stderr or "Installation failed"),
          code = r.code,
        }
        return current
      end
      if platform == "OSX" then
        phase = "quarantine"
        spawn({
          executable = "/usr/bin/xattr",
          args = { "-d", "com.apple.quarantine", deps.state_dir .. "/bin/crier" },
          env = {},
          capture_stdout = true,
          capture_stderr = true,
          timeout = 15,
          kind = "installer",
        })
        if process then
          return current
        end
      end
      phase = "probe"
    elseif phase == "quarantine" then
      phase = "probe"
    end
    if phase == "probe" then
      local p, pe = deps.resolver.probe()
      if not p then
        phase = nil
        current = { state = "failed", message = pe.message }
        return current
      end
      phase = "version"
      current.message = "Checking installed crier…"
      return current
    end
    return current
  end
  local tick = self.tick
  function self.tick()
    if phase == "version" then
      local status = deps.resolver.tick()
      if status.state ~= "checking" then
        current = { state = status.state == "ready" and "installed" or "failed", message = status.message }
        phase = nil
      end
      return current
    end
    return tick()
  end
  function self.status()
    return current
  end
  function self.detach()
    local interrupted = process or phase
    local record
    if process then
      record = cancel_process(process)
      process = nil
    end
    phase = nil
    if interrupted then
      current = { state = "cancelled", message = "Installation cancelled because the script unloaded" }
    end
    return record
  end
  return self
end
return M
