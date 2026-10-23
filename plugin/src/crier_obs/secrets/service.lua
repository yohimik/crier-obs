local json = require('crier_obs.json')
local ffi = require('ffi')
local M = {}
local function failure(kind, message) return {kind = kind, message = message} end
local function account_for(set, key)
  set = set or 'default'
  if type(set) ~= 'string' or set == '' or set:find('[/%c]') or type(key) ~= 'string' or key == '' or key:find('%c') then
    return nil, failure('credential', 'Invalid credential set or key')
  end
  return set .. '/' .. key
end
function M.new(deps)
  local fs, log = assert(deps.fs), deps.log or {}
  local dir = assert(deps.state_dir) .. '/secrets'
  local backends = deps.backends or {}
  local platform = deps.platform or (deps.env or {}).os or ffi.os
  local primary = platform == 'OSX' and 'macos' or platform == 'Windows' and 'windows' or 'linux'
  if deps.backend then backends[deps.backend.name] = deps.backend; primary = deps.backend.name end
  if not backends[primary] then backends[primary] = require('crier_obs.secrets.keyring.' .. primary).new(deps) end
  if not backends.file then backends.file = require('crier_obs.secrets.keyring.file').new(deps) end
  local index, index_error = {}, nil
  if fs.exists(dir .. '/index.json') then
    local data, err = fs.read(dir .. '/index.json')
    local decoded = data and json.decode(data)
    if type(decoded) == 'table' then index = decoded else index_error = err or failure('credential', 'Credential index is corrupted') end
  end
  local pending, cache, statuses, slots = {}, {}, {}, {}
  local self = {cache = cache, backends = backends}
  local closed = false
  local locked = deps.lock or require('crier_obs.secrets.lock').new(deps)
  local ready = primary ~= 'linux' or deps.skip_probe == true
  local probing, linux_available = false, true
  local function register(value) if log.register_secret then log.register_secret(value) end end
  local function persist(account, backend)
    if index_error then return nil, index_error end
    local ok, err = fs.mkdir_private(dir); if not ok then return nil, err end
    return locked(function()
    local merged = {}
    if fs.exists(dir .. '/index.json') then
      local data; data, err = fs.read(dir .. '/index.json')
      local decoded = data and json.decode(data)
      if type(decoded) ~= 'table' then return nil, err or failure('credential', 'Credential index is corrupted') end
      merged = decoded
    end
    merged[account] = backend
    ok, err = fs.write_private(dir .. '/index.json', json.encode(merged))
    if ok then index = merged end
    return ok, err
    end)
  end
  local function finish(job, value, err, backend)
    if closed then return end
    job.state, job.value, job.error = err and 'failed' or 'done', value, err
    if err then
      statuses[job.account] = {state = err.kind == 'unavailable' and 'unavailable' or 'not stored',
         backend = backend,
         message = err.message}
    elseif job.operation == 'forget' then statuses[job.account] = {state = 'not stored'}
    elseif value then statuses[job.account] = {state = 'stored', backend = backend}
    else statuses[job.account] = {state = 'not stored', backend = backend} end
    for _, callback in ipairs(job.callbacks) do callback(value, err) end
    local slot = slots[job.account]
    if slot and slot.active == job then slot.active = nil end
  end
  local function enqueue(set, key, operation, value, callback)
    if closed then
      local err = failure('cancelled', 'Credential service is closed')
      if callback then callback(nil, err) end
      return {state = 'failed', error = err}
    end
    local account, err = account_for(set, key)
    local job = {state = 'queued', operation = operation, value = value, account = account, key = key, callbacks = {}}
    if callback then job.callbacks[1] = callback end
    if not account then job.state, job.error = 'failed', err; if callback then callback(nil, err) end; return job end
    local slot = slots[account] or {}; slots[account] = slot
    if operation == 'commit' and slot.waiting and slot.waiting.operation == 'commit' then
      slot.waiting.value = value
      if callback then slot.waiting.callbacks[#slot.waiting.callbacks + 1] = callback end
      return slot.waiting
    end
    slot.queue = slot.queue or {}
    slot.queue[#slot.queue + 1] = job
    slot.waiting = job
    return job
  end
  function self.commit(set, key, value, callback)
    local account, err = account_for(set, key)
    if value == nil and account then value = pending[account] end
    if type(value) == 'string' then value = value:match('^%s*(.-)%s*$') end
    if not account or type(value) ~= 'string' or value == '' then
      local job = {state = 'failed', error = err or failure('missing', 'Enter a credential before saving')}
      if callback then callback(nil, job.error) end
      return job
    end
    register(value); pending[account] = value
    statuses[account] = {state = 'saving', backend = index[account] or primary}
    return enqueue(set, key, 'commit', value, callback)
  end
  function self.forget(set, key, callback)
    local account = account_for(set, key)
    if account then pending[account], cache[account] = nil, nil; statuses[account] = {state = 'forgetting'} end
    return enqueue(set, key, 'forget', nil, callback)
  end
  function self.resolve(set, keys, callback)
    local group = {state = 'queued', values = {}, remaining = #keys}
    if #keys == 0 then group.state = 'done'; if callback then callback(group.values) end; return group end
    for _, key in ipairs(keys) do
      local account = account_for(set, key)
      local function resolved(value, err)
        if value then group.values[key] = value end
        group.error = group.error or err; group.remaining = group.remaining - 1
        if group.remaining == 0 then
          group.state = group.error and 'failed' or 'done'
          if callback then
            if group.error then callback(nil, group.error) else callback(group.values) end
          end
        end
      end
      if account and cache[account] then resolved(cache[account]) else enqueue(set, key, 'lookup', nil, resolved) end
    end
    return group
  end
  function self.backend_status()
    local state = closed and 'unavailable' or ready and 'ready' or 'checking'
    local message = primary == 'file' and 'Secret Service unavailable; using encrypted credential files' or nil
    return {name = primary, state = state, message = message}
  end
  function self.status(set, key)
    local account, err = account_for(set, key)
    if not account then return {state = 'unavailable', message = err.message} end
    if not statuses[account] then statuses[account] = {state = 'checking'}; enqueue(set, key, 'lookup') end
    return statuses[account]
  end
  function self.pending(set, key) local account = account_for(set, key); return account and pending[account] end
  function self.cached(set, keys)
    local values = {}; set = set or 'default'
    if keys then for _, key in ipairs(keys) do values[key] = cache[set .. '/' .. key] end
    else for account, value in pairs(cache) do local prefix = set .. '/';
       if account:sub(1, #prefix) == prefix then values[account:sub(#prefix + 1)] = value end end end
    return values
  end
  function self.clear_cache() for key in pairs(cache) do cache[key] = nil end end
  function self.scrub(settings, keys, set)
    local store = assert(deps.store, 'settings store required to scrub credentials')
    if not keys then
      keys = {};
         for _,
            descriptor in ipairs(require('crier_obs.registry.keys')) do if descriptor.secret then keys[#keys + 1] = descriptor.key end end
    end
    for _, key in ipairs(keys) do
      if store.has(settings, key) then
        local value = store.get(settings, key, 'string')
        local account = account_for(set, key)
        if account and type(value) == 'string' and value ~= '' then pending[account] = value; register(value) end
        store.unset(settings, key)
      end
    end
  end
  local function unavailable(name)
    return not backends[name] or (name == 'linux' and not linux_available)
  end
  local function lookup(job)
    local bound = index[job.account]
    local choices = bound and {bound} or {primary, 'file'}
    local at = 0
    local function next_backend()
      at = at + 1; local name = choices[at]
      if not name then finish(job, nil); return end
      if unavailable(name) then
        if bound then finish(job, nil, failure('unavailable', 'Stored credential backend is unavailable; unlock or restore it'), name)
        else next_backend() end
        return
      end
      backends[name].lookup(job.account, function(value, err)
        if closed then return end
        if value and value ~= '' then register(value); cache[job.account] = value; finish(job, value, nil, name)
        elseif err and err.kind ~= 'missing' then finish(job, nil, err, name)
        elseif bound then finish(job, nil, failure('missing', 'Stored credential is missing; re-enter it'), name)
        else next_backend() end
      end)
    end
    next_backend()
  end
  local function start(job)
    job.state = 'running'
    if index_error then finish(job, nil, index_error); return end
    if job.operation == 'lookup' then lookup(job); return end
    if job.operation == 'commit' then
      local name = index[job.account] or primary
      if unavailable(name) then finish(job,
         nil,
         failure('unavailable',
         'Stored credential backend is unavailable; restore it before saving'),
         name);
         return end
      local backend = backends[name]
      backend.store(job.account, job.value, function(ok, err)
        if closed then return end
        if not ok then finish(job, nil, err or failure('credential', 'Credential could not be saved'), name); return end
        backend.lookup(job.account, function(value, lookup_err)
          if closed then return end
          if value ~= job.value then finish(job,
             nil,
             lookup_err or failure('credential',
             'Credential verification failed; it was not saved'),
             name);
             return end
          local saved, save_err = persist(job.account, name)
          if not saved then finish(job, nil, save_err, name); return end
          register(value); cache[job.account] = value
          if pending[job.account] == job.value then pending[job.account] = nil end
          finish(job, true, nil, name)
        end)
      end)
      return
    end
    local names, seen, first_error = {index[job.account] or primary, 'file'}, {}, nil
    local at = 0
    local function next_backend()
      at = at + 1; local name = names[at]
      if not name then
        if first_error then finish(job, nil, first_error); return end
        local ok, err = persist(job.account, nil)
        if ok then cache[job.account], pending[job.account] = nil, nil end
        finish(job, ok, err); return
      end
      if seen[name] then next_backend(); return end; seen[name] = true
      if not backends[name] then first_error = first_error or failure('unavailable', 'Stored credential backend is unavailable');
         next_backend();
         return end
      backends[name].forget(job.account, function(ok, err)
        if closed then return end
        if not ok then first_error = first_error or err end; next_backend()
      end)
    end
    next_backend()
  end
  local function probe()
    probing = true
    local bytes, err = fs.random_bytes(12)
    if not bytes then primary, linux_available, ready = 'file', false, true; if log.warn then log.warn(err.message) end; return end
    local canary = bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end)
    local account = '__probe__/' .. canary
    register(canary)
    local function selected(ok)
      if closed then return end
      backends.linux.forget(account, function()
        if closed then return end
        linux_available, ready = ok, true
        if not ok then primary = 'file';
           if log.warn then log.warn('Secret Service unavailable; credentials use the encrypted file store') end end
      end)
    end
    backends.linux.store(account, canary, function(ok)
      if closed then return end
      if not ok then selected(false); return end
      backends.linux.lookup(account, function(value) selected(value == canary) end)
    end)
  end
  function self.tick()
    if closed then return end
    for _, backend in pairs(backends) do if backend.tick then backend.tick() end end
    if not ready then if not probing then probe() end; return end
    local active, candidates = 0, {}
    for _, slot in pairs(slots) do
      if slot.active then active = active + 1
      elseif slot.queue and #slot.queue > 0 then candidates[#candidates + 1] = slot end
    end
    table.sort(candidates, function(a, b)
      local first, second = a.queue[1], b.queue[1]
      local priority_a, priority_b = first.operation == 'lookup' and 1 or 0, second.operation == 'lookup' and 1 or 0
      return priority_a == priority_b and first.account < second.account or priority_a < priority_b
    end)
    for _, slot in ipairs(candidates) do
      if active >= (deps.concurrency or 2) then break end
      local job = table.remove(slot.queue, 1); slot.active = job
      if slot.waiting == job then slot.waiting = nil end
      start(job)
      if slot.active then active = active + 1 end
    end
  end
  function self.forget_all(set, callback)
    local keys, prefix = {}, (set or 'default') .. '/'
    local seen = {}; for account in pairs(index) do seen[account] = true end; for account in pairs(pending) do seen[account] = true end
    for account in pairs(seen) do if account:sub(1, #prefix) == prefix then keys[#keys + 1] = account:sub(#prefix + 1) end end
    local group = {state = 'queued', remaining = #keys}
    if #keys == 0 then group.state = 'done'; if callback then callback(true) end; return group end
    for _, key in ipairs(keys) do self.forget(set, key, function(_, err)
      group.error = group.error or err; group.remaining = group.remaining - 1
      if group.remaining == 0 then group.state = group.error and 'failed' or 'done';
         if callback then callback(not group.error, group.error) end end
    end) end
    return group
  end
  function self.close()
    closed = true
    for _, slot in pairs(slots) do
      if slot.active then slot.active.state = 'cancelled'; slot.active.callbacks = {} end
      for _, job in ipairs(slot.queue or {}) do job.state = 'cancelled'; job.callbacks = {} end
    end
    for _, backend in pairs(backends) do if backend.close then backend.close() end end
    local unsaved = next(pending) ~= nil
    if unsaved and log.warn then log.warn('Credentials typed but not saved') end
    self.clear_cache(); for account in pairs(pending) do pending[account] = nil end
    return not unsaved
  end
  return self
end
return M
