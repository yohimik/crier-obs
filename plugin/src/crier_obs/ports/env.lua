local ffi = require("ffi")
local M = {}
ffi.cdef("int access(const char*,int);")
function M.new(deps)
  deps = deps or {}
  local get = deps.getenv or os.getenv
  local platform = deps.platform or ffi.os
  local C = deps.C or ffi.C
  local self = { os = platform, arch = ffi.arch, getenv = get }
  function self.flatpak()
    if get("FLATPAK_ID") ~= nil then
      return true
    end
    if deps.fs then
      return deps.fs.exists("/.flatpak-info")
    end
    return platform == "Linux" and C.access("/.flatpak-info", 0) == 0 or false
  end
  function self.snap()
    return get("SNAP") ~= nil or get("SNAP_NAME") ~= nil
  end
  function self.path(extra)
    local sep = platform == "Windows" and ";" or ":"
    local home = get(platform == "Windows" and "USERPROFILE" or "HOME") or ""
    local paths = {}
    if extra and extra ~= "" then
      paths[#paths + 1] = extra
    end
    local inherited_path = get("PATH")
    if inherited_path and inherited_path ~= "" then
      paths[#paths + 1] = inherited_path
    end
    if home ~= "" then
      paths[#paths + 1] = home .. "/.local/bin"
      paths[#paths + 1] = home .. "/bin"
    end
    if platform == "Windows" then
      paths[#paths + 1] = (get("LOCALAPPDATA") or "") .. "\\Microsoft\\WinGet\\Links"
    else
      paths[#paths + 1] = "/opt/homebrew/bin"
      paths[#paths + 1] = "/usr/local/bin"
      paths[#paths + 1] = "/usr/bin"
      paths[#paths + 1] = "/bin"
    end
    return table.concat(paths, sep)
  end
  self.augmented_path = self.path
  function self.inherited()
    local values = {}
    if platform == "Windows" then
      ffi.cdef("uint16_t* __stdcall GetEnvironmentStringsW(void); int __stdcall FreeEnvironmentStringsW(uint16_t*);")
      local utf16 = require("crier_obs.utf16")
      local block = C.GetEnvironmentStringsW()
      if block == nil then
        return values
      end
      local offset = 0
      while block[offset] ~= 0 do
        local finish = offset
        while block[finish] ~= 0 do
          finish = finish + 1
        end
        local text = utf16.decode(ffi.string(block + offset, (finish - offset) * 2))
        if text then
          local name, value = text:match("^(=?[^=]+)=(.*)$")
          if name then
            values[name] = value
          end
        end
        offset = finish + 1
      end
      C.FreeEnvironmentStringsW(block)
    else
      local entries
      if platform == "OSX" then
        ffi.cdef("char ***_NSGetEnviron(void);")
        entries = C._NSGetEnviron()[0]
      else
        ffi.cdef("extern char **environ;")
        entries = C.environ
      end
      local i = 0
      while entries[i] ~= nil do
        local name, value = ffi.string(entries[i]):match("^([^=]+)=(.*)$")
        if name then
          values[name] = value
        end
        i = i + 1
      end
    end
    return values
  end
  function self.crier_names()
    local names = {}
    for name in pairs(self.inherited()) do
      if name:match("^CRIER_") then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end
  function self.sandbox_status(fs)
    if not self.flatpak() then
      if self.snap() then
        return {
          kind = "snap",
          ok = false,
          message = "Snap may isolate host tools and credential services; use a native OBS package",
        }
      end
      return { kind = "native", ok = true }
    end
    fs = fs or deps.fs
    local helper
    if fs then
      for directory in self.path():gmatch("[^:]+") do
        if fs.exists(directory .. "/flatpak-spawn") then
          helper = directory .. "/flatpak-spawn"
          break
        end
      end
    end
    if not helper then
      return {
        kind = "flatpak",
        ok = false,
        message = "Flatpak host access is unavailable: flatpak-spawn is missing; use a native OBS package",
      }
    end
    return {
      kind = "flatpak",
      helper = helper,
      warning = true,
      message = "Flatpak host bridge requires flatpak-spawn --env-fd support and shared home paths; Check setup verifies the host command",
    }
  end
  local function shared_path(path)
    if type(path) ~= "string" or path == "" then
      return true
    end
    if path == "-" or path:match("^env:") or path:match("^%a[%w+.-]*://") then
      return true
    end
    local home = get("HOME")
    if not home or home == "" or path:find("/../", 1, true) or path:match("/%.%.$") then
      return false
    end
    if path:sub(1, 1) ~= "/" then
      return false
    end
    return path == home or path:sub(1, #home + 1) == home .. "/"
  end
  function self.prepare_host(plan, fs)
    if not self.flatpak() then
      return plan
    end
    local status = self.sandbox_status(fs)
    if not status.helper then
      return nil, { kind = "sandbox", message = status.message }
    end
    local function unavailable()
      return nil,
        {
          kind = "sandbox",
          message = "Flatpak host paths cannot be mapped safely. Keep the state folder, configuration, "
            .. "templates and media under the shared home directory, or use a native OBS package",
        }
    end
    local cwd = plan.cwd or get("HOME")
    if type(cwd) ~= "string" or cwd == "" or not shared_path(cwd) then
      return unavailable()
    end
    local executable = plan.executable or (plan.argv and plan.argv[1])
    if
      type(executable) ~= "string"
      or executable == ""
      or executable:match("^/app/")
      or executable:match("^/tmp/")
      or executable:match("^/run/")
      or executable:find("/../", 1, true)
    then
      return unavailable()
    end
    for _, name in ipairs({ "stdin", "stdout", "stderr", "status_path", "pid_path" }) do
      if plan[name] and not shared_path(plan[name]) then
        return unavailable()
      end
    end
    local path_keys = {}
    for _, d in ipairs(require("crier_obs.registry.keys")) do
      if d.path then
        path_keys[d.key] = d.kind
      end
    end
    local json = require("crier_obs.json")
    for file, body in pairs(plan.files or {}) do
      if not shared_path(file) then
        return unavailable()
      end
      if file:match("config%.json$") then
        local config = json.decode(body)
        if type(config) ~= "table" then
          return unavailable()
        end
        local names = {}
        for name in pairs(((config.publish or {}).custom or {})) do
          names[#names + 1] = name
        end
        for _, d in ipairs(require("crier_obs.schema.descriptor").build(names)) do
          if d.path then
            path_keys[d.key] = d.kind
          end
        end
        for key in pairs(path_keys) do
          local value = config
          for part in key:gmatch("[^.]+") do
            if type(value) == "table" then
              value = value[part]
            else
              value = nil
            end
          end
          if type(value) == "table" then
            for _, item in ipairs(value) do
              if not shared_path(item) then
                return unavailable()
              end
            end
          elseif value and not shared_path(value) then
            return unavailable()
          end
        end
      end
    end
    local args = plan.args or {}
    for i, arg in ipairs(args) do
      if arg == "--config" or arg == "--publish-input" or arg == "--render-output" then
        if not shared_path(args[i + 1]) then
          return unavailable()
        end
      elseif arg == "--set" then
        local key, value = (args[i + 1] or ""):match("^([^=]+)=(.*)$")
        local kind = path_keys[key] or (key and key:match("^publish%.custom%.[^.]+%.overlay$") and "list")
        if kind == "list" then
          for item in value:gmatch("[^,]+") do
            if not shared_path(item) then
              return unavailable()
            end
          end
        elseif kind and not shared_path(value) then
          return unavailable()
        end
      end
    end
    local names = {}
    for name, value in pairs(plan.env or {}) do
      if name:find("%z") or name:find("=", 1, true) or tostring(value):find("%z") then
        return nil, { kind = "environment", message = "Invalid host environment entry" }
      end
      if not name:match("^LD_") and not name:match("^FLATPAK_") then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    local block = {}
    for _, name in ipairs(names) do
      block[#block + 1] = name .. "=" .. tostring(plan.env[name]) .. "\0"
    end
    local host_args = { "--host", "--env-fd=3", "--clear-env", "--watch-bus", "--directory=" .. cwd, "--", executable }
    for _, value in ipairs(args) do
      host_args[#host_args + 1] = value
    end
    local prepared = {}
    for key, value in pairs(plan) do
      prepared[key] = value
    end
    prepared.executable = status.helper
    prepared.args = host_args
    prepared.cwd = nil
    prepared.env_fd_data = table.concat(block)
    return prepared
  end
  return self
end
return M
