local service = require('crier_obs.secrets.service')
local function new(deps) deps.lock = function(cb) return cb() end; return service.new(deps) end
local json = require('crier_obs.json')
local cipherfile = require('crier_obs.secrets.keyring.file')
local function memory_fs()
  local files, writes, random = {}, {}, 0
  local fs = {files = files, writes = writes}
  function fs.exists(path) return files[path] ~= nil end
  function fs.read(path) return files[path] end
  function fs.mkdir_private() return true end
  function fs.write_private(path, value) files[path] = value; writes[#writes + 1] = {path, value}; return true end
  function fs.create_private(path, value)
    if files[path] then return nil, {kind = 'exists'} end
    return fs.write_private(path, value)
  end
  function fs.remove(path) files[path] = nil; return true end
  function fs.random_bytes(n)
    random = random + 1; local bytes = {}
    for i = 1, n do bytes[i] = string.char(math.floor(random / 256 ^ ((i - 1) % 4)) % 256) end
    return table.concat(bytes)
  end
  return fs
end
local function backend(name)
  local values, operations, callbacks = {}, {}, {}
  local b = {name = name or 'test', values = values, operations = operations}
  function b.store(account, value, cb)
    operations[#operations + 1] = {'store', account, value}
    callbacks[#callbacks + 1] = function() values[account] = value; cb(true) end
  end
  function b.lookup(account, cb)
    operations[#operations + 1] = {'lookup', account}
    callbacks[#callbacks + 1] = function() cb(values[account], not values[account] and {kind = 'missing'} or nil) end
  end
  function b.forget(account, cb)
    operations[#operations + 1] = {'forget', account}
    callbacks[#callbacks + 1] = function() values[account] = nil; cb(true) end
  end
  function b.tick() local tasks = callbacks; callbacks = {}; for _, cb in ipairs(tasks) do cb() end end
  return b
end
local function drain(s) for _ = 1, 30 do s.tick() end end
describe('credential service', function()
  it('coalesces rapid saves, verifies bytes, binds index, caches and forgets', function()
    local fs, b = memory_fs(), backend()
    local s = new{fs = fs, state_dir = '/state', backend = b}
    local first = s.commit('default', 'publish.telegram.token', 'first')
    local last = s.commit('default', 'publish.telegram.token', '  final😀  ')
    assert.equal(first, last); assert.equal('queued', first.state); assert.equal(0, #b.operations)
    drain(s)
    assert.equal('done', first.state); assert.equal('final😀', b.values['default/publish.telegram.token'])
    assert.equal('store', b.operations[1][1]); assert.equal('lookup', b.operations[2][1]); assert.equal(2, #b.operations)
    assert.equal('stored', s.status('default', 'publish.telegram.token').state)
    assert.equal('test', json.decode(fs.files['/state/secrets/index.json'])['default/publish.telegram.token'])
    local resolved
    s.resolve('default', {'publish.telegram.token'}, function(values) resolved = values end)
    assert.equal('final😀', resolved['publish.telegram.token']); assert.equal(2, #b.operations)
    local forgotten = s.forget('default', 'publish.telegram.token'); drain(s)
    assert.equal('done', forgotten.state); assert.is_true(forgotten.value)
    assert.equal('not stored', s.status('default', 'publish.telegram.token').state)
    assert.is_nil(s.cached('default')['publish.telegram.token']); assert.is_nil(s.pending('default', 'publish.telegram.token'))
  end)
  it('scrubs scene values into pending without an implicit save, and preserves failure values', function()
    local fs, b = memory_fs(), backend()
    local settings = {['publish.telegram.token'] = 'typed-secret', ['publish.caption'] = 'hello'}
    local store = {has = function(v, k) return v[k] ~= nil end, get = function(v, k) return v[k] end,
      unset = function(v, k) v[k] = nil end}
    local s = new{fs = fs, state_dir = '/state', backend = b, store = store}
    s.scrub(settings)
    assert.is_nil(settings['publish.telegram.token']); assert.equal('hello', settings['publish.caption'])
    assert.equal('typed-secret', s.pending('default', 'publish.telegram.token')); drain(s); assert.equal(0, #b.operations)
    b.store = function(_, _, callback) callback(nil, {kind = 'unavailable', message = 'locked'}) end
    local job = s.commit('default', 'publish.telegram.token'); drain(s)
    assert.equal('failed', job.state); assert.equal('typed-secret', s.pending('default', 'publish.telegram.token'))
    assert.equal('unavailable', s.status('default', 'publish.telegram.token').state)
    assert.is_nil(fs.files['/state/secrets/index.json'])
  end)
  it('refuses unavailable indexed backends without silently writing fallback files', function()
    local fs = memory_fs()
    fs.files['/state/secrets/index.json'] = json.encode{['default/publish.telegram.token'] = 'macos'}
    local s = new{fs = fs, state_dir = '/state', backend = backend('file')}
    local returned = true
    local result = s.resolve('default', {'publish.telegram.token'}, function(values, err)
      returned = values; assert.equal('unavailable', err.kind)
    end); drain(s)
    assert.is_nil(returned)
    assert.equal('failed', result.state); assert.equal('unavailable', result.error.kind)
    local saved = s.commit('default', 'publish.telegram.token', 'new-value'); drain(s)
    assert.equal('failed', saved.state); assert.equal(0, #fs.writes)
  end)
  it('requires verifying lookup to match before reporting stored', function()
    local b = backend(); b.lookup = function(_, cb) cb('different') end
    local s = new{fs = memory_fs(), state_dir = '/state', backend = b}
    local job = s.commit('default', 'token', 'secret'); drain(s)
    assert.equal('failed', job.state); assert.equal('not stored', s.status('default', 'token').state)
  end)
  it('canary-selects encrypted files when Secret Service is absent without migrating indexed tokens', function()
    local fs, b = memory_fs(), backend('linux')
    b.store = function(_, _, cb) cb(nil, {kind = 'unavailable'}) end
    local s = new{fs = fs, state_dir = '/state', platform = 'Linux', backends = {linux = b}}
    local job = s.commit('default', 'token', 'secret'); drain(s)
    assert.equal('done', job.state); assert.equal('file', s.status('default', 'token').backend)
  end)
  it('does not resurrect a cache entry when forgetting an in-flight save', function()
    local s = new{fs = memory_fs(), state_dir = '/state', backend = backend()}
    s.commit('default', 'token', 'secret'); s.tick(); s.forget('default', 'token'); drain(s)
    assert.is_nil(s.cached('default').token)
  end)
  it('clears stale queued lookups after forget and cancels all callbacks on close', function()
    local b = backend(); local closed = false
    b.close = function() closed = true end
    local s = new{fs = memory_fs(), state_dir = '/state', backend = b}
    s.commit('default', 'token', 'secret'); drain(s); s.clear_cache()
    local lookup = s.resolve('default', {'token'}); s.tick()
    local forgotten = s.forget('default', 'token')
    local queued = s.resolve('default', {'token'}); drain(s)
    assert.equal('done', forgotten.state); assert.equal('done', lookup.state); assert.equal('done', queued.state)
    assert.is_nil(queued.values.token); assert.is_nil(s.cached('default').token)
    local called = false
    s.resolve('default', {'token'}, function() called = true end); s.tick(); s.close(); b.tick(); s.tick()
    assert.is_true(closed); assert.is_false(called); assert.equal('unavailable', s.backend_status().state)
    assert.equal('failed', s.forget('default', 'token').state)
  end)
  it('merges index bindings from separate OBS instances under the persisted mutex', function()
    local fs = memory_fs()
    local a = new{fs = fs, state_dir = '/state', backend = backend('one')}
    local b = new{fs = fs, state_dir = '/state', backend = backend('two')}
    a.commit('default', 'a', 'alpha'); drain(a)
    b.commit('default', 'b', 'beta'); drain(b)
    assert.same({['default/a'] = 'one', ['default/b'] = 'two'}, json.decode(fs.files['/state/secrets/index.json']))
  end)
  it('limits dialog status lookups to two active credential jobs', function()
    local b = backend(); local s = new{fs = memory_fs(), state_dir = '/state', backend = b}
    for i = 1, 40 do s.status('default', 'token' .. i) end
    s.tick(); assert.equal(2, #b.operations)
    drain(s)
    assert.equal('not stored', s.status('default', 'token1').state)
  end)
  it('rejects malformed credential account names and forgets a complete set', function()
    local s = new{fs = memory_fs(), state_dir = '/state', backend = backend()}
    assert.equal('failed', s.commit('bad\nset', 'token', 'secret').state)
    s.commit('one', 'a', 'alpha'); s.commit('one', 'b', 'beta'); s.commit('two', 'a', 'gamma'); drain(s)
    local job = s.forget_all('one'); drain(s)
    assert.equal('done', job.state); assert.same({}, s.cached('one')); assert.equal('gamma', s.cached('two').a)
  end)
end)
describe('encrypted credential files', function()
  it('round trips authenticated records, uses unique nonces, and never writes plaintext', function()
    local fs = memory_fs(); local b = cipherfile.new{fs = fs, state_dir = '/state'}
    local nonces = {}
    for _ = 1, 1000 do
      local saved; b.store('default/token', 'secret😀', function(ok) saved = ok end); assert.is_true(saved)
      local record = json.decode(fs.files[cipherfile.record_path('/state/secrets', 'default/token')])
      assert.is_nil(nonces[record.nonce]); nonces[record.nonce] = true
    end
    local value; b.lookup('default/token', function(v) value = v end); assert.equal('secret😀', value)
    for _, write in ipairs(fs.writes) do assert.is_nil(write[2]:find('secret😀', 1, true)) end
    local path = cipherfile.record_path('/state/secrets', 'default/token')
    local record = json.decode(fs.files[path]); record.tag = 'AAAAAAAAAAAAAAAAAAAAAA=='
    fs.files[path] = json.encode(record)
    local err; b.lookup('default/token', function(v, e) value, err = v, e end)
    assert.is_nil(value); assert.equal('credential', err.kind)
    b.forget('default/token', function(ok) assert.is_true(ok) end)
    assert.is_nil(fs.files[path])
  end)
  it('rereads a competing process key after exclusive creation loses the race', function()
    local fs = memory_fs(); local create = fs.create_private
    fs.create_private = function(path, value) create(path, value); return nil, {kind = 'exists'} end
    local b = cipherfile.new{fs = fs, state_dir = '/state'}
    b.store('default/token', 'secret', function(ok) assert.is_true(ok) end)
    b.lookup('default/token', function(v) assert.equal('secret', v) end)
  end)
end)
