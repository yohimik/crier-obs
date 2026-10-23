local queue_module = require('crier_obs.run.queue')
local spool_module = require('crier_obs.run.spool')
local json = require('crier_obs.json')
local function job(event, id, starts)
  local self = {event = event, state = 'queued', id = id}
  function self.start() self.state = 'running'; starts[#starts + 1] = id end
  function self.tick() self.state = 'done' end
  function self.finished() return self.state == 'done' end
  function self.cancel() self.state = 'cancelled' end
  function self.detach() return {pid = id} end
  return self
end
describe('bounded queue with durable overflow', function()
  it('reports each cancelled pending interval with the reason it was dropped', function()
    local starts, dropped = {}, {}
    local q = queue_module.new{bound = 1, on_drop = function(item, reason)
      assert.equal('cancelled', item.state)
      dropped[#dropped + 1] = {item.id, item.event, reason}
    end}
    q.push(job('interval', 1, starts)); q.push(job('end', 2, starts))
    assert.same({{1, 'interval', 'queue capacity reached'}}, dropped)
    q.tick(); q.push(job('interval', 3, starts)); q.drop_intervals()
    assert.same({{1, 'interval', 'queue capacity reached'}, {3, 'interval', 'stream ended'}}, dropped)
    assert.equal('end', q.active().event); assert.equal(0, q.size())
  end)
  it('spills critical overflow, preserves FIFO, rejects later noncritical bypass and never holds more than the bound', function()
    local starts, disk = {}, {}
    local backlog = {append = function(j) disk[#disk + 1] = j.id; return true end,
      size = function() return #disk end, ack = function() end,
      take = function() return job('start', table.remove(disk, 1), starts) end}
    local q = queue_module.new{bound = 5, backlog = backlog}
    for i = 1, 30 do assert(q.push(job(i % 2 == 0 and 'end' or 'start', i, starts))); assert.is_true(q.size() <= 5) end
    assert.equal(25, q.backlog_size()); assert.is_false(q.push(job('manual', 31, starts)))
    for _ = 1, 35 do q.tick(); assert.is_true(q.size() <= 5) end
    local expected = {}; for i = 1, 30 do expected[i] = i end
    assert.same(expected, starts); assert.equal(0, q.backlog_size())
  end)
  it('does not resurrect a terminal critical post while unloading', function()
    local starts, writes = {}, 0
    local j = job('start', 1, starts)
    local q = queue_module.new{backlog = {size = function() return 0 end,
      append = function() writes = writes + 1; return true end, ack = function() end}}
    q.push(j); q.tick(); j.state = 'done'; q.detach()
    assert.equal(0, writes)
  end)
  it('reports spill errors and preserves pending critical work during unload', function()
    local starts, disk, count = {}, {}, 0
    local backlog = {append = function(j) count = count + 1; disk[#disk + 1] = j; return true end,
      size = function() return #disk end, ack = function() end}
    local q = queue_module.new{bound = 1, backlog = backlog}
    local first, second = job('start', 1, starts), job('end', 2, starts)
    q.push(first); q.push(second); assert.equal(1, count)
    q.detach(); assert.equal(2, count); assert.equal('queued', first.state)
    backlog.append = function() return nil, {message = 'disk full'} end
    q = queue_module.new{bound = 1, backlog = backlog}
    local ok, reason = q.push(first); assert.is_false(ok); assert.is_truthy(reason:find('disk full'))
    q = queue_module.new{bound = 0}
    ok, reason = q.push(first); assert.is_false(ok); assert.equal('overflow store unavailable', reason)
    local errors = {}
    q = queue_module.new{backlog = {size = function() return 1 end, take = function() return nil, {message = 'corrupted'} end},
      on_error = function(e) errors[#errors + 1] = e.message end}
    q.tick(); assert.same({'corrupted'}, errors)
  end)
  it('preserves every pending critical snapshot even when active process detach fails', function()
    local starts, preserved = {}, {}
    local active = job('manual', 1, starts)
    active.detach = function() return nil, {kind = 'detach', message = 'cannot detach'} end
    local q = queue_module.new{backlog = {size = function() return 0 end,
      append = function(j) preserved[#preserved + 1] = j.id; return true end, ack = function() end}}
    q.push(active); q.tick(); q.push(job('start', 2, starts)); q.push(job('end', 3, starts))
    local result, err = q.detach()
    assert.is_nil(result); assert.equal('detach', err.kind); assert.same({2, 3}, preserved); assert.equal(0, q.size())
  end)
  it('preserves an active unresolved critical post and reports unload persistence errors', function()
    local starts = {}; local active = job('start', 1, starts)
    active.start = function() active.state = 'resolving_secrets' end
    local parked = false; active.park = function() parked = true; return true end
    local records = {}
    local backlog = {size = function() return 0 end, append = function(j) records[#records + 1] = j.id; return true end}
    local q = queue_module.new{backlog = backlog}; q.push(active); q.tick(); q.detach()
    assert.same({1}, records); assert.equal('resolving_secrets', active.state); assert.is_true(parked)
    active = job('start', 2, starts); active.start = function() active.state = 'resolving_secrets' end
    backlog.append = function() return nil, {message = 'read only'} end
    q = queue_module.new{backlog = backlog}; q.push(active); q.tick()
    local _, err = q.detach(); assert.equal('queue', err.kind); assert.equal('cancelled', active.state)
  end)
end)
local function memory_fs()
  local files, dirs = {}, {}
  return {files = files, dirs = dirs, exists = function(path) return files[path] ~= nil end,
    read = function(path) return files[path] end,
    write_private = function(path, data) files[path] = data; return true end,
    remove = function(path) files[path] = nil; return true end,
    glob = function() return dirs end}
end
local function snapshot(dir, event)
  return {event = event or 'start', credential_set = 'original', run = {dir = dir},
    plan = {executable = '/crier', needs_secrets = {}, args = {'--config', dir .. '/config.json'}, env = {},
      files = {[dir .. '/config.json'] = '{"publish":{"caption":"original"}}'}}}
end
describe('durable queue snapshots', function()
  it('restores snapshots without mutable settings, rejects credentials, and cleans terminal records', function()
    local fs = memory_fs(); fs.dirs[1], fs.dirs[2], fs.dirs[3] = '/runs/10-1-1', '/runs/10-1-2', '/runs/10-99-1'
    local function hydrate(entry, ack) return {event = entry.event, restored = entry, start = ack} end
    local deps = {fs = fs, paths = {runs = '/runs'}, pid = 1, hydrate = hydrate, owner_alive = function(pid) return pid == 99 end}
    local spool = spool_module.new(deps)
    for i = 1, 3 do assert(spool.append{spill = snapshot(fs.dirs[i])}) end
    assert.equal(3, spool.size())
    local original = snapshot('/runs/10-1-1'); original.plan.env.CRIER_TOKEN = 'secret'
    assert.is_nil(spool.append{spill = original})
    original.plan.env = {}; original.plan.files = {x = '{"publish":{"telegram":{"token":"secret"}}}'}
    assert.is_nil(spool.append{spill = original})
    original.plan.files = {x = '{"publish.telegram.token":"secret"}'}
    assert.is_nil(spool.append{spill = original})
    original.plan.files = {}
    for _, args in ipairs({{'--set', 'publish.telegram.token=secret'}, {'--set=publish.telegram.token=secret'},
      {'--publish-telegram-token', 'secret'}, {'--publish-telegram-token=secret'}}) do
      original.plan.args = args; assert.is_nil(spool.append{spill = original})
    end
    spool = spool_module.new(deps); assert.equal(2, spool.size())
    local restored = assert(spool.take()); assert.equal('original', restored.restored.credential_set)
    assert.equal('/runs/10-1-1', restored.restored.run.dir); restored.start(); spool.ack(restored)
    assert.is_nil(fs.files['/runs/10-1-1/queued.json'])
    fs.files['/runs/10-1-2/journal.json'] = '{"state":"done"}'
    spool = spool_module.new(deps); assert.equal(0, spool.size()); assert.is_nil(fs.files['/runs/10-1-2/queued.json'])
    assert.is_not_nil(fs.files['/runs/10-99-1/queued.json'])
  end)
  it('does not steal a live owner and recovers dead owners on POSIX and Windows', function()
    for _, platform in ipairs({'OSX', 'Windows'}) do
      local fs = memory_fs(); fs.dirs[1] = '/runs/10-99-1'
      local path = fs.dirs[1] .. '/queued.json'; fs.files[path] = json.encode(snapshot(fs.dirs[1]))
      local running, closed = true, 0
      local C = {kill = function() return running and 0 or -1 end,
        OpenProcess = function() return require('ffi').cast('void*', 123) end,
        GetExitCodeProcess = function(_, out) out[0] = running and 259 or 0; return 1 end,
        CloseHandle = function() closed = closed + 1 end}
      local deps = {fs = fs, paths = {runs = '/runs'}, pid = 1, C = C, platform = platform,
        hydrate = function(entry) return {event = entry.event} end}
      assert.equal(0, spool_module.new(deps).size()); running = false
      assert.equal(1, spool_module.new(deps).size())
      if platform == 'Windows' then
        assert.equal(2, closed)
        C.OpenProcess = function() return require('ffi').NULL end
        C.GetLastError = function() return 5 end
        assert.equal(0, spool_module.new(deps).size())
        C.GetLastError = function() return 87 end
        assert.equal(1, spool_module.new(deps).size())
      end
    end
  end)
  it('rejects malformed durable data and reports serialization/read failures', function()
    local fs = memory_fs()
    local spool = spool_module.new{fs = fs, paths = {runs = '/runs'}, pid = 1, hydrate = function() end}
    local mutations = {
      function(e) e.run.dir = nil end,
      function(e) e.plan.executable = '' end,
      function(e) e.plan.needs_secrets = false end,
      function(e) e.plan.needs_secrets = {7} end,
      function(e) e.plan.env = 'invalid' end,
      function(e) e.plan.args = 'invalid' end,
      function(e) e.plan.args = {7} end,
      function(e) e.plan.argv = {'--set', 'publish.telegram.token=secret'} end,
      function(e) e.plan.base_custom_args = {'--set', 'publish.telegram.token=secret'} end,
      function(e) e.plan.base_custom_args = 'invalid' end,
      function(e) e.plan.stdin_data = 'secret' end,
      function(e) e.plan.env_fd_data = 'CRIER_TOKEN=secret' end,
      function(e) e.plan.files = 'invalid' end,
      function(e) e.plan.files = {x = 7} end,
      function(e) e.plan.files = {x = 'invalid JSON'} end,
    }
    for _, mutate in ipairs(mutations) do
      local entry = snapshot('/runs/10-1-1'); mutate(entry)
      local ok, err = spool.append{spill = entry}; assert.is_nil(ok); assert.equal('queue', err.kind)
    end
    assert.is_nil(spool.append{spill = false})
    local cyclic = snapshot('/runs/10-1-1'); cyclic.extra = cyclic
    local ok, err = spool.append{spill = cyclic}; assert.is_nil(ok); assert.is_not_nil(err)
    local entry = snapshot('/runs/10-1-1'); assert(spool.append{spill = entry}); assert(spool.append{spill = entry})
    assert.equal(1, spool.size())
    local old_read = fs.read
    fs.read = function(path)
      if path:match('queued.json$') then return nil, {kind = 'filesystem', message = 'cannot read queued snapshot'} end
      return old_read(path)
    end
    local value; value, err = spool.take(); assert.is_nil(value); assert.equal('filesystem', err.kind)
    local win = spool_module.new{fs = memory_fs(), paths = {runs = '/runs'}, platform = 'Windows',
      C = {GetCurrentProcessId = function() return 7 end}, hydrate = function() end}
    assert.equal(0, win.size())
  end)
  it('fails missing/corrupt snapshots explicitly and refuses failed hydration', function()
    local fs = memory_fs(); local deps = {fs = fs, paths = {runs = '/runs'}, pid = 1,
      hydrate = function() return nil, {message = 'hydrate failed'} end}
    local spool = spool_module.new(deps); assert(spool.append{spill = snapshot('/runs/10-1-1')})
    fs.files['/runs/10-1-1/queued.json'] = 'invalid'
    local value, err = spool.take(); assert.is_nil(value); assert.equal('queue', err.kind)
    assert.equal('failed', json.decode(fs.files['/runs/10-1-1/journal.json']).state)
    assert(spool.append{spill = snapshot('/runs/10-1-2')})
    value, err = spool.take(); assert.is_nil(value); assert.equal('hydrate failed', err.message)
    assert.is_nil(spool.take()); assert.is_true(spool.ack({}))
    fs.write_private = function() return nil, {message = 'disk full'} end
    assert.is_nil(spool.append{spill = snapshot('/runs/10-1-3')})
  end)
end)

local job_module = require('crier_obs.run.job')
describe('parking queued preflight and credential operations', function()
  it('cancels native preflight and prevents a late credential callback from publishing', function()
    for _, preflight in ipairs({true, false}) do
      local cancelled, spawned, finished, journal, callback = 0, 0, 0, nil, nil
      local plan = {executable = '/crier', args = {}, env = {}, files = {}, needs_secrets = {'publish.telegram.token'},
        base_config = preflight and '/base' or nil}
      local j = job_module.new{event = 'start', plan = plan, run = {}, credential_set = 'default',
        fs = {read = function() return '{}' end, write = function() return true end},
        runs = {journal = function(_, value) journal = value; return true end, finish = function() finished = finished + 1 end},
        log = {scrub = function(v) return v end, error = function() end},
        secrets = {resolve = function(_, _, cb) callback = cb end},
        spawner = {spawn = function()
          spawned = spawned + 1
          return {pid = 21, poll = function() return nil end, cancel = function() cancelled = cancelled + 1; return {pid = 21} end}
        end}}
      local q = queue_module.new{backlog = {size = function() return 0 end, append = function() return true end}}
      q.push(j); q.tick(); assert.equal(preflight and 'inspecting_base' or 'resolving_secrets', j.state)
      assert(q.detach()); assert.equal('parked', j.state); assert.equal('queued', journal.state)
      assert.equal(0, finished)
      if preflight then assert.equal(1, cancelled); assert.equal(21, journal.drainers[1].pid)
      else callback({['publish.telegram.token'] = 'late-secret'}); assert.equal(0, spawned) end
    end
  end)
end)
