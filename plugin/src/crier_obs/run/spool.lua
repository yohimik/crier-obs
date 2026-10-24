local json = require('crier_obs.json')
local M = {}
-- A snapshot is spilled while one OBS process switches scene collections and is restored by the next
-- load of that same process seconds later. Anything older, or left by an OBS that has since exited,
-- describes a stream that is over: it is journaled as skipped and never published.
M.RESTORE_WINDOW = 600
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
  local current_pid, alive, clock = assert(deps.pid), assert(deps.alive), assert(deps.clock)
  local log = deps.log
  local self = {skipped = 0}
  local function ack_path(path)
    local ok = not fs.exists(path) or fs.remove(path)
    if ok then known[path] = nil end
    return ok
  end
  local function skip(dir, path, reason)
    local raw = fs.read(dir .. '/journal.json')
    local journal = raw and json.decode(raw)
    journal = type(journal) == 'table' and journal or {}
    journal.state, journal.error = 'failed', reason
    fs.write_private(dir .. '/journal.json', json.encode(journal))
    ack_path(path)
    self.skipped = self.skipped + 1
  end
  local function fresh(path)
    local text = fs.read(path)
    local entry = text and json.decode(text)
    local stamp = type(entry) == 'table' and tonumber(entry.spilled_at)
    return stamp ~= nil and clock.now_wall() - stamp <= M.RESTORE_WINDOW
  end
  local function restore()
    local found = {}
    for _, dir in ipairs(fs.glob(deps.paths.runs .. '/*')) do
      local path = dir .. '/queued.json'
      local stamp, owner, seq = dir:match('/(%d+)%-(%d+)%-(%d+)$')
      owner = tonumber(owner)
      if owner and fs.exists(path) then
        local journal = fs.read(dir .. '/journal.json')
        local state = journal and json.decode(journal)
        if type(state) == 'table' and state.state ~= 'queued' then ack_path(path)
        elseif owner ~= current_pid then
          if not alive(owner) then skip(dir, path, 'Queued post skipped: the OBS session that queued it has ended') end
        elseif not fresh(path) then
          skip(dir, path, 'Queued post skipped: it waited longer than a scene collection switch takes')
        else
          found[#found + 1] = {path = path, stamp = tonumber(stamp), owner = owner, sequence = tonumber(seq)}
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
    entry.spilled_at = clock.now_wall()
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
  if self.skipped > 0 and log then
    log.info('Skipped ' .. self.skipped .. ' queued post' .. (self.skipped == 1 and '' or 's') .. ' from an earlier OBS session')
  end
  return self
end
return M
