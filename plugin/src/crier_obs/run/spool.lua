local ffi = require('ffi')
local json = require('crier_obs.json')
local M = {}
ffi.cdef([[int kill(int,int); int getpid(void); uint32_t __stdcall GetCurrentProcessId(void);
void * __stdcall OpenProcess(uint32_t,int,uint32_t); uint32_t __stdcall GetLastError(void);
int __stdcall GetExitCodeProcess(void*,uint32_t*); int __stdcall CloseHandle(void*);]])
local secret_keys, secret_flags = {}, {}
for _, descriptor in ipairs(require('crier_obs.registry.keys')) do
  if descriptor.secret then
    secret_keys[descriptor.key] = true
    secret_flags['--' .. descriptor.key:gsub('%.', '-')] = true
  end
end
local function safe_args(arguments)
  if arguments ~= nil and type(arguments) ~= 'table' then return false end
  for _, argument in ipairs(arguments or {}) do
    if type(argument) ~= 'string' then return false end
    if secret_flags[argument] then return false end
    local setting = argument:match('^%-%-set=(.*)$') or argument
    local key, value = setting:match('^([^=]+)=(.*)$')
    if key and (secret_keys[key] or secret_flags[key]) and value ~= '' then return false end
  end
  return true
end
local function safe(entry)
  if type(entry) ~= 'table' or type(entry.run) ~= 'table' or type(entry.plan) ~= 'table' then return false end
  if type(entry.run.dir) ~= 'string' then return false end
  local plan = entry.plan
  if type(plan.executable) ~= 'string' or plan.executable == '' or type(plan.needs_secrets) ~= 'table' then return false end
  for _, key in ipairs(plan.needs_secrets) do
    if type(key) ~= 'string' or not key:match('^[%w_.%-]+$') then return false end
  end
  if (plan.env ~= nil and type(plan.env) ~= 'table') or type(plan.args or {}) ~= 'table'
    or type(plan.files or {}) ~= 'table' then return false end
  if next(plan.env or {}) ~= nil then return false end
  if not safe_args(plan.args) or not safe_args(plan.argv) or not safe_args(plan.base_custom_args) then return false end
  if (plan.stdin_data ~= nil and plan.stdin_data ~= '') or (plan.env_fd_data ~= nil and plan.env_fd_data ~= '') then return false end
  for _, text in pairs(plan.files or {}) do
    if type(text) ~= 'string' then return false end
    local config = json.decode(text)
    if type(config) ~= 'table' then return false end
    for key in pairs(secret_keys) do
      local value = config[key]
      if value == nil then
        value = config
        for part in key:gmatch('[^.]+') do value = type(value) == 'table' and value[part] or nil end
      end
      if value ~= nil and value ~= '' then return false end
    end
  end
  return true
end
local function failure(message) return {kind = 'queue', message = message} end
function M.new(deps)
  local fs, entries, known = deps.fs, {}, {}
  local platform, C = deps.platform or ffi.os, deps.C or ffi.C
  local current_pid = deps.pid or (platform == 'Windows' and tonumber(C.GetCurrentProcessId()) or tonumber(C.getpid()))
  local function alive(pid)
    if deps.owner_alive then return deps.owner_alive(pid) end
    if platform == 'Windows' then
      local h = C.OpenProcess(0x1000, 0, pid)
      if h == nil then
        local code = tonumber(C.GetLastError())
        return code ~= 87 and code ~= 1168
      end
      local code = ffi.new('uint32_t[1]')
      local running = C.GetExitCodeProcess(h, code) ~= 0 and tonumber(code[0]) == 259
      C.CloseHandle(h); return running
    end
    local result = C.kill(pid, 0)
    return result == 0 or ffi.errno() == 1
  end
  local self = {}
  local function ack_path(path)
    local ok = not fs.exists(path) or fs.remove(path)
    if ok then known[path] = nil end
    return ok
  end
  local function restore()
    local found = {}
    for _, dir in ipairs(fs.glob(deps.paths.runs .. '/*')) do
      local path = dir .. '/queued.json'
      if fs.exists(path) then
        local stamp, owner, seq = dir:match('/(%d+)%-(%d+)%-(%d+)$')
        owner = tonumber(owner)
        if owner and (owner == current_pid or not alive(owner)) then
          local journal = fs.read(dir .. '/journal.json')
          local state = journal and json.decode(journal)
          if type(state) == 'table' and state.state ~= 'queued' then ack_path(path)
          else
            found[#found + 1] = {path = path, stamp = tonumber(stamp), owner = owner, sequence = tonumber(seq)}
          end
        end
      end
    end
    table.sort(found, function(a, b)
      if a.stamp ~= b.stamp then return a.stamp < b.stamp end
      if a.owner ~= b.owner then return a.owner < b.owner end
      return a.sequence < b.sequence
    end)
    for _, entry in ipairs(found) do entries[#entries + 1] = entry.path; known[entry.path] = true end
  end
  function self.append(job)
    local entry = job.spill
    if not safe(entry) then return nil, failure('Refusing to persist a queue snapshot containing credentials or invalid data') end
    local path = entry.run.dir .. '/queued.json'
    if known[path] then return true end
    local data, err = json.encode(entry); if not data then return nil, err end
    local ok; ok, err = fs.write_private(path, data); if not ok then return nil, err end
    entries[#entries + 1] = path; known[path] = true
    return true
  end
  function self.take()
    if #entries == 0 then return nil end
    local path = table.remove(entries, 1)
    local text, err = fs.read(path)
    local entry = text and json.decode(text)
    if not safe(entry) or entry.run.dir .. '/queued.json' ~= path then
      local dir = path:match('^(.*)/queued.json$')
      local raw = fs.read(dir .. '/journal.json')
      local journal = raw and json.decode(raw)
      journal = type(journal) == 'table' and journal or {}
      journal.state, journal.error = 'failed', 'Queued post snapshot is missing or invalid'
      fs.write_private(dir .. '/journal.json', json.encode(journal))
      ack_path(path)
      return nil, err or failure('Queued post snapshot is missing or invalid')
    end
    local job; job, err = deps.hydrate(entry, function() return ack_path(path) end)
    if not job then ack_path(path); return nil, err or failure('Queued post could not be restored') end
    job.spill_path = path
    job.spill = entry
    return job
  end
  function self.ack(job) if job.spill_path then return ack_path(job.spill_path) end; return true end
  function self.size() return #entries end
  restore()
  return self
end
return M
