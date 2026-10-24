local ffi = require('ffi')
local fs_module = require('crier_obs.ports.fs')
local spawner_module = require('crier_obs.proc.spawner')
local service_module = require('crier_obs.secrets.service')
local macos = require('crier_obs.secrets.keyring.macos')
local linux = require('crier_obs.secrets.keyring.linux')
local file = require('crier_obs.secrets.keyring.file')
local lock_module = require('crier_obs.secrets.lock')
local obs = require('stub.obslua')
local log_module = require('crier_obs.log')
ffi.cdef('int usleep(unsigned int);')
local fs = fs_module.new{obs = obs}
local source = debug.getinfo(1, 'S').source:sub(2)
local fake_dir = source:gsub('unit/secrets/native_spec.lua$', 'fakes/')
local fixture = fake_dir .. 'security'
local function temporary()
  local path = os.tmpname(); os.remove(path); assert(fs.mkdir_private(path)); return path
end
local function drain(s, job)
  for _ = 1, 5000 do
    s.tick()
    if job and (job.state == 'done' or job.state == 'failed') then return end
    ffi.C.usleep(1000)
  end
  assert.is_true(false, 'keyring operation did not complete')
end
describe('native credential pipes #posix', function()
  it('stores and verifies quoted, non-ASCII bytes using the real POSIX spawner', function()
    for _, factory in ipairs({macos, linux}) do
      local state, fake = temporary(), temporary()
      local deps = {fs = fs, state_dir = state, security_bin = fixture, secret_tool_bin = fake_dir .. 'secret-tool',
        spawner = spawner_module.new{}, command_env = {FAKE_KEYRING_DIR = fake}, platform = 'OSX', log = log_module.new{}}
      deps.backend = factory.new(deps)
      local service = service_module.new(deps)
      local token = 'spaces "quotes" \\ emoji 😀'
      local job = service.commit('default', 'publish.telegram.token', token); drain(service, job)
      assert.equal('done', job.state, job.error and job.error.message)
      local found = service.resolve('default', {'publish.telegram.token'}); drain(service, found)
      assert.equal(token, found.values['publish.telegram.token'])
      local checked = service.status('default', 'publish.other.token')
      for _ = 1, 3000 do service.tick(); if checked.state ~= 'checking' then break end; ffi.C.usleep(1000) end
      assert.equal('not stored', service.status('default', 'publish.other.token').state)
      assert.is_nil(fs.read(state .. '/secrets/index.json'):find(token, 1, true))
      assert.is_false(fs.exists(state .. '/secrets/key'))
      local forgotten = service.forget('default', 'publish.telegram.token'); drain(service, forgotten)
      assert.equal('done', forgotten.state)
      service.close()
    end
  end)
  it('does not report an empty security lookup as a successful save', function()
    local state, fake = temporary(), temporary()
    local deps = {fs = fs, state_dir = state, security_bin = fixture, spawner = spawner_module.new{},
      command_env = {FAKE_KEYRING_DIR = fake, FAKE_KEYRING_EMPTY = '1'}, platform = 'OSX', log = log_module.new{}}
    deps.backend = macos.new(deps)
    local service = service_module.new(deps)
    local job = service.commit('default', 'token', 'secret'); drain(service, job)
    assert.equal('failed', job.state); assert.equal('not stored', service.status('default', 'token').state)
    assert.is_false(fs.exists(state .. '/secrets/index.json')); service.close()
  end)
  it('maps locked native keychain failures and reaps a timed out native keyring child', function()
    local state, fake, now = temporary(), temporary(), 0
    local spawner = spawner_module.new{clock = {now_mono = function() return now end}}
    local deps = {fs = fs, state_dir = state, security_bin = fixture, spawner = spawner,
      command_env = {FAKE_KEYRING_DIR = fake, FAKE_KEYRING_LOCKED = '1'}, platform = 'OSX', log = log_module.new{}}
    deps.backend = macos.new(deps)
    local service = service_module.new(deps)
    local job = service.commit('default', 'token', 'secret'); drain(service, job)
    assert.equal('failed', job.state); assert.equal('unavailable', job.error.kind); service.close()
    deps.command_env = {FAKE_KEYRING_DIR = fake, FAKE_KEYRING_SLEEP = '1'}; deps.keyring_timeout = 1
    local spawned, original_spawn = nil, spawner.spawn
    spawner.spawn = function(plan) local p, e = original_spawn(plan); spawned = p; return p, e end
    deps.backend = macos.new(deps); service = service_module.new(deps)
    job = service.commit('default', 'token', 'secret'); service.tick(); ffi.C.usleep(10000); now = 2
    drain(service, job)
    assert.equal('failed', job.state); assert.equal('unavailable', job.error.kind)
    assert.is_truthy(job.error.message:find('timed out', 1, true))
    assert.equal(-1, ffi.C.kill(spawned.pid, 0)); service.close()
  end)
  it('falls through a Secret Service miss to the encrypted file store and reports not stored', function()
    local state, fake = temporary(), temporary()
    local deps = {fs = fs, state_dir = state, secret_tool_bin = fake_dir .. 'secret-tool', spawner = spawner_module.new{},
      command_env = {FAKE_KEYRING_DIR = fake}, platform = 'Linux', skip_probe = true, log = log_module.new{}}
    local service = service_module.new(deps)
    local lookup = service.resolve('default', {'publish.telegram.token'}); drain(service, lookup)
    assert.equal('done', lookup.state, lookup.error and lookup.error.message)
    assert.is_nil(lookup.values['publish.telegram.token'])
    local status = service.status('default', 'publish.telegram.token')
    for _ = 1, 3000 do service.tick(); if status.state ~= 'checking' then break end; ffi.C.usleep(1000) end
    assert.equal('not stored', service.status('default', 'publish.telegram.token').state)
    service.close()
  end)
  it('checks macOS presence without asking security for the password', function()
    local state, fake = temporary(), temporary()
    local deps = {fs = fs, state_dir = state, security_bin = fixture, spawner = spawner_module.new{},
      command_env = {FAKE_KEYRING_DIR = fake}, platform = 'OSX', log = log_module.new{}}
    local backend = macos.new(deps)
    local stored = false
    backend.store('default/token', 'PRESENT_SECRET', function(ok) stored = ok end)
    for _ = 1, 3000 do backend.tick(); if stored then break end; ffi.C.usleep(1000) end
    assert.is_true(stored)
    local answer, plans = nil, {}
    local spawn = deps.spawner.spawn
    deps.spawner.spawn = function(plan) plans[#plans + 1] = plan; return spawn(plan) end
    backend.exists('default/token', function(value, err) answer = {value, err} end)
    for _ = 1, 3000 do backend.tick(); if answer then break end; ffi.C.usleep(1000) end
    assert.is_true(answer[1])
    for _, arg in ipairs(plans[1].args) do assert.is_not.equal('-w', arg) end
    answer = nil
    backend.exists('default/other', function(value, err) answer = {value, err} end)
    for _ = 1, 3000 do backend.tick(); if answer then break end; ffi.C.usleep(1000) end
    assert.is_nil(answer[1]); assert.equal('missing', answer[2].kind)
  end)
  it('writes only private authenticated ciphertext and a private key on disk', function()
    local state = temporary(); local b = file.new{fs = fs, state_dir = state}
    b.store('default/token', 'secret😀', function(ok) assert.is_true(ok) end)
    local record = file.record_path(state .. '/secrets', 'default/token')
    for _, path in ipairs({state .. '/secrets/key', record}) do
      assert.is_nil(fs.read(path):find('secret😀', 1, true))
      local p = assert(io.popen((ffi.os == 'OSX' and 'stat -f %Lp ' or 'stat -c %a ') .. path))
      assert.equal('600', p:read('*l')); p:close()
    end
    local p = assert(io.popen((ffi.os == 'OSX' and 'stat -f %Lp ' or 'stat -c %a ') .. state .. '/secrets'))
    assert.equal('700', p:read('*l')); p:close()
    b.lookup('default/token', function(value) assert.equal('secret😀', value) end)
  end)
  it('releases advisory locks after success, contention and a failed callback', function()
    local state = temporary(); assert(fs.mkdir_private(state .. '/secrets'))
    local lock = lock_module.new{state_dir = state}
    local outer = lock(function()
      local nested, err = lock(function() return true end)
      assert.is_nil(nested); assert.equal('busy', err.kind)
      return true
    end)
    assert.is_true(outer)
    assert.is_nil(lock(function() assert(false) end))
    assert.is_true(lock(function() return true end))
  end)
end)
