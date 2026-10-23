local obs = require('obslua')
local json = require('crier_obs.json')
local fs_module = require('crier_obs.ports.fs')
local plugin_module = require('crier_obs.plugin')
describe('durable critical posts through plugin reload', function()
  it('keeps five waiting snapshots resident and restores original FIFO captions/data after unload', function()
    obs.reset()
    local root = os.tmpname(); os.remove(root)
    local fs = fs_module.new{obs = obs}
    local started, ready, pid = {}, false, 800
    local spawner = {}
    function spawner.spawn(plan)
      pid = pid + 1
      local raw = fs.read(plan.run.data)
      local doc = assert(json.decode(raw)); started[#started + 1] = doc.title
      local p = {pid = pid, child_pid = pid}
      function p.poll() if ready then return {code = 0, stdout = '{"results":[]}', stderr = ''} end end
      function p.detach() return {pid = pid, child_pid = pid} end
      function p.kill() end
      return p
    end
    function spawner.adopt(record)
      return {pid = record.pid, poll = function() return {code = 0} end, detach = function() return record end}
    end
    local resolver = {find = function() return '/crier' end, status = function() return {state = 'ready'} end,
      probe = function() end, tick = function() end, detach = function() end}
    local function secrets()
      return {resolve = function(_, _, cb) cb({}) end, status = function() return {state = 'not stored'} end,
        tick = function() end, scrub = function() end, close = function() end}
    end
    local settings = obs.obs_data_create()
    local function create()
      return plugin_module.new{obs = obs, fs = fs, state_dir = root, resolver = resolver, spawner = spawner, secrets = secrets()}
    end
    local p = create(); p.defaults(settings); obs.obs_data_set_bool(settings, 'publish.telegram.enabled', true)
    p.load(settings); p.update(settings)
    for i = 1, 15 do
      obs.obs_data_set_string(settings, 'cobs.title', 'snapshot-' .. i); p.update(settings)
      p.enqueue(i % 2 == 0 and 'end' or 'start')
      assert.is_true(p.queue.size() <= 5)
    end
    assert.equal(10, p.queue.backlog_size())
    p.tick(); assert.equal('snapshot-1', started[1]); p.unload()
    obs.obs_data_set_string(settings, 'cobs.title', 'changed-after-enqueue')
    p = create(); p.load(settings); p.update(settings); ready = true
    for _ = 1, 40 do p.tick(); assert.is_true(p.queue.size() <= 5) end
    local expected = {}; for i = 1, 15 do expected[i] = 'snapshot-' .. i end
    assert.same(expected, started)
    for _, dir in ipairs(fs.glob(root .. '/runs/*')) do assert.is_false(fs.exists(dir .. '/queued.json')) end
    p.unload(); obs.obs_data_release(settings); obs.assert_no_leaks(); assert.equal(0, obs.timer_count())
  end)
end)
