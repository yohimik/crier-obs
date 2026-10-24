local utf16 = require('crier_obs.utf16')
local command = require('crier_obs.proc.cmdline_windows')
local resolver = require('crier_obs.proc.resolver')
local json = require('crier_obs.json')
describe('UTF-16 strict boundary handling', function()
  it('covers the Unicode scalar ranges and refuses truncated/overlong encodings', function()
    for _, text in ipairs({'', '\0ASCII', '\194\128', '\223\191', '\224\160\128', '\239\191\191',
      '\240\144\128\128', '\244\143\191\191'}) do
      assert.equal(text, utf16.decode(assert(utf16.encode(text))))
    end
    for _, text in ipairs({'\128', '\255', '\194', '\194A', '\194\255', '\224\128\128',
      '\240\128\128\128', '\244\144\128\128', '\237\160\128'}) do
      local encoded, err = utf16.encode(text)
      assert.is_nil(encoded); assert.equal('encoding', err.kind)
    end
    for _, bytes in ipairs({'x', '\0\216', '\0\216A\0', '\0\216\255\223', '\0\220'}) do
      local decoded, err = utf16.decode(bytes)
      if bytes == '\0\216\255\223' then assert.is_string(decoded)
      else assert.is_nil(decoded); assert.equal('encoding', err.kind) end
    end
  end)
end)
describe('Windows environment block boundaries', function()
  it('rejects NUL names and values and preserves empty blocks/drive pseudo-variables', function()
    for _, env in ipairs({{['BAD\0KEY'] = 'value'}, {KEY = 'bad\0value'}}) do
      local block, err = command.environment(env); assert.is_nil(block); assert.equal('environment', err.kind)
    end
    assert.equal('\0\0', utf16.decode(assert(command.environment({}))))
    local block = command.environment({['=C:'] = 'C:\\work', Path = 'first', SYSTEMROOT = 'C:\\Windows'})
    assert.equal('=C:=C:\\work\0Path=first\0SYSTEMROOT=C:\\Windows\0\0', utf16.decode(block))
    assert.equal('tool.exe', command.command('tool.exe'))
    assert.equal('"C:\\Program Files\\tool.exe" "" "a\\\\\\"b"', command.command('C:\\Program Files\\tool.exe', {'', 'a\\"b'}))
  end)
end)
local function instance(options)
  options = options or {}
  local result = options.result or {code = 0, stdout = '{"version":"1.1.1"}'}
  local process = options.process or {poll = function() return result end, cancel = function() return true end}
  return resolver.new{fs = options.fs or {exists = function(path) return path == '/crier' end},
    env = options.env or {os = 'Linux'}, state_dir = options.state_dir, pin = '1.1.1', json = json,
    spawner = options.spawner or {spawn = function(plan)
      assert.same({}, plan.env); assert.equal('probe', plan.kind); return process
    end}}, process
end
describe('semantic version comparison without numeric precision loss', function()
  it('implements the SemVer precedence chain and treats numeric identifiers as digit strings', function()
    local chain = {'1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2',
      '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0'}
    for i = 1, #chain - 1 do
      assert.equal(-1, resolver.compare(chain[i], chain[i + 1])); assert.equal(1, resolver.compare(chain[i + 1], chain[i]))
    end
    for _, pair in ipairs({{'1.0.0', '2.0.0'}, {'1.0.0', '1.1.0'}, {'1.0.0', '1.0.1'},
      {'9007199254740992.0.0', '9007199254740993.0.0'},
      {'1.0.0-9007199254740992', '1.0.0-9007199254740993'}, {'1.0.0-2', '1.0.0-1e0'},
      {'1.0.0-17', '1.0.0-0x10'}, {'1.0.0-a', '1.0.0-z'}}) do
      assert.equal(-1, resolver.compare(pair[1], pair[2])); assert.equal(1, resolver.compare(pair[2], pair[1]))
    end
    assert.equal(0, resolver.compare('1.0.0+build.1', 'v1.0.0+build.2'))
    assert.equal(0, resolver.compare('1.0.0-rc.1+build.1', '1.0.0-rc.1+build.2'))
    for _, invalid in ipairs({'nonsense', '1.0', '1.0.0.1', '01.0.0', '1.0.0-', '1.0.0-01',
      '1.0.0+bad+meta', '1.0.0+bad.', '1.0.0-.rc', '1.0.0-rc..1', '1.0.0-rc_'}) do
      local cmp, err = resolver.compare(invalid, '1.0.0'); assert.is_nil(cmp); assert.equal('version', err.kind)
    end
  end)
end)
describe('resolver discovery and failure cleanup', function()
  it('checks configured, managed and augmented PATH directories in order on both OS families', function()
    local available = {['/managed/bin/crier'] = true, ['/path/crier'] = true, ['/usr/local/bin/crier'] = true}
    -- The env port's augmented PATH carries the Homebrew, /usr/local and ~/.local directories.
    local env = require('crier_obs.ports.env').new{platform = 'Linux', getenv = function(name)
      return ({PATH = '/path', HOME = '/home/user'})[name]
    end}
    local r = instance{state_dir = '/managed', fs = {exists = function(path) return available[path] end}, env = env}
    assert.equal('/managed/bin/crier', r.find()); available['/managed/bin/crier'] = nil
    assert.equal('/path/crier', r.find()); available['/path/crier'] = nil
    assert.equal('/usr/local/bin/crier', r.find()); assert.is_nil(r.find('/nonexistent'))
    available['/home/user/.local/bin/ffmpeg'] = true
    assert.equal('/home/user/.local/bin/ffmpeg', r.find_binary('ffmpeg'))
    assert.is_nil(r.find_binary('')); assert.is_nil(r.find_binary('/missing/zrok'))
    assert.equal('/usr/local/bin/crier', r.find_binary('/usr/local/bin/crier'))
    r = instance{fs = {exists = function(path) return path == 'D:\\tools\\crier.exe' or path == 'D:\\tools\\zrok.exe' end},
      env = {os = 'Windows', getenv = function() return 'C:\\other;D:\\tools' end}}
    assert.equal('D:\\tools\\crier.exe', r.find())
    assert.equal('D:\\tools\\zrok.exe', r.find_binary('zrok'))
    r = instance{fs = {exists = function() return false end}}
    assert.is_nil(r.probe()); assert.equal('missing', r.tick().state)
  end)
  it('reports spawn, empty/invalid version, timeout, and nonzero command failures', function()
    local r = instance{spawner = {spawn = function() return nil, {message = 'not executable'} end}}
    assert.is_nil(r.probe('/crier')); assert.equal('failed', r.status().state)
    for _, result in ipairs({{code = 1, stderr = 'refused'}, {code = 0, timed_out = true},
      {code = 0, stdout = 'unknown'}, {code = 0, stdout = '{"version":"invalid"}'},
      {code = 0, stdout = '{"version":"1.1.1junk"}'}}) do
      r = instance{result = result}; assert(r.probe('/crier')); assert.equal('failed', r.tick().state)
    end
    r = instance{result = {code = 0, stdout = '{"Version":"1.2.0"}'}}
    assert(r.probe('/crier')); assert.equal('ready', r.tick().state); assert.equal('1.2.0', r.status().version)
    r = instance{result = {code = 0, stdout = 'crier 1.0.0'}}
    assert(r.probe('/crier')); assert.equal('outdated', r.tick().state)
    r = resolver.new{fs = {exists = function() return true end}, pin = '1.1.1',
      spawner = {spawn = function() return {poll = function() return {code = 0, stdout = 'crier 1.0.0'} end} end}}
    assert(r.probe('/crier')); assert.is_truthy(r.tick().message:find('older than 1.1.1', 1, true))
    assert.has_error(function() resolver.new{fs = {}} end)
  end)
  it('cancels an outstanding utility version probe during unload', function()
    local stopped = 0
    local process = {poll = function() return nil end, cancel = function() stopped = stopped + 1; return true end}
    local r = instance{process = process}; assert(r.probe('/crier')); r.detach()
    assert.equal(1, stopped); assert.equal('cancelled', r.status().state)
    r.detach(); assert.equal(1, stopped); assert(r.probe('/crier')); r.detach(); assert.equal(2, stopped)
  end)
  it('cleans poll errors and allows a subsequent probe instead of staying busy', function()
    local cleaned = 0
    local process = {poll = function() return nil, {kind = 'process', message = 'poll failed'} end,
      cancel = function() cleaned = cleaned + 1; return true end}
    local r = instance{process = process}
    assert(r.probe('/crier')); assert.is_nil(r.probe('/crier'))
    local status, err = r.tick(); assert.equal('failed', status.state); assert.equal('poll failed', err.message)
    assert.equal(1, cleaned)
    assert(r.probe('/crier')); r.detach(); assert.equal(2, cleaned)
    r.detach(); assert.equal('cancelled', r.tick().state)
    local pending = {poll = function() return nil end, cancel = function() return true end}
    r = instance{process = pending}; assert(r.probe('/crier')); assert.equal('checking', r.tick().state); r.detach()
  end)
end)
