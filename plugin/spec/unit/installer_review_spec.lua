local installer = require("crier_obs.invoke.installer")
local function fixture(process, resolve)
  return installer.new({
    state_dir = "/state",
    env = { os = "Linux" },
    spawner = {
      spawn = function()
        return process
      end,
    },
    resolver = resolve or {
      probe = function()
        return {}
      end,
      tick = function()
        return { state = "ready", message = "installed" }
      end,
    },
  })
end
describe("installer completion and error cleanup", function()
  it("serializes installation through the asynchronous version check", function()
    local checking = true
    local instance = fixture({
      poll = function()
        return { code = 0 }
      end,
    }, {
      probe = function()
        return {}
      end,
      tick = function()
        return { state = checking and "checking" or "ready", message = "crier 1.1.1" }
      end,
    })
    assert(instance.start())
    instance.tick()
    local value, err = instance.start()
    assert.is_nil(value)
    assert.equal("busy", err.kind)
    assert.equal("installing", instance.tick().state)
    checking = false
    assert.equal("installed", instance.tick().state)
    assert(instance.start())
  end)
  it("closes failed polls and permits an explicit retry", function()
    for _, method in ipairs({ "cancel", "close", "kill", "terminate" }) do
      local cleaned, detached = 0, 0
      local process = {
        poll = function()
          return nil, { kind = "process", message = "poll failed" }
        end,
        detach = function()
          detached = detached + 1
        end,
      }
      process[method] = function()
        cleaned = cleaned + 1
      end
      local instance = fixture(process)
      assert(instance.start())
      local status, err = instance.tick()
      assert.equal("failed", status.state)
      assert.equal("poll failed", status.message)
      assert.equal("process", err.kind)
      assert.equal(1, cleaned)
      assert.equal((method == "kill" or method == "terminate") and 1 or 0, detached)
      assert(instance.start())
    end
  end)
  it("permits retry after spawn, install or verification failure", function()
    local attempts = 0
    local instance = installer.new({
      state_dir = "/state",
      env = { os = "Linux" },
      spawner = {
        spawn = function()
          attempts = attempts + 1
          if attempts == 1 then
            return nil, { kind = "spawn", message = "spawn failed" }
          end
          return {
            poll = function()
              return { code = 1, stderr = "digest mismatch" }
            end,
          }
        end,
      },
    })
    assert.is_nil(instance.start())
    assert(instance.start())
    assert.equal("failed", instance.tick().state)
    assert(instance.start())
    local probe_failure = fixture({
      poll = function()
        return { code = 0 }
      end,
    }, {
      probe = function()
        return nil, { message = "probe failed" }
      end,
    })
    assert(probe_failure.start())
    assert.equal("failed", probe_failure.tick().state)
    assert(probe_failure.start())
  end)
  it("cancels installer work on unload and leaves verification cleanup to the resolver owner", function()
    local cancelled, detached = 0, 0
    local process = {
      poll = function()
        return nil
      end,
      cancel = function()
        cancelled = cancelled + 1
        return { pid = 42 }
      end,
      detach = function()
        detached = detached + 1
      end,
    }
    local instance = fixture(process)
    assert(instance.start())
    assert.equal(42, instance.detach().pid)
    assert.equal(1, cancelled)
    assert.equal(0, detached)
    assert.equal("cancelled", instance.status().state)
    assert(instance.start())
    local version_polls, version_closes = 0, 0
    local resolver = {
      probe = function()
        return {}
      end,
      tick = function()
        version_polls = version_polls + 1
        return { state = "checking" }
      end,
      detach = function()
        version_closes = version_closes + 1
      end,
    }
    local verifying = fixture({
      poll = function()
        return { code = 0 }
      end,
    }, resolver)
    assert(verifying.start())
    verifying.tick()
    verifying.detach()
    assert.equal("cancelled", verifying.tick().state)
    assert.equal(0, version_polls)
    assert.equal(0, version_closes)
    resolver.detach()
    assert.equal(1, version_closes)
    assert(verifying.start())
  end)
end)
