local spawner = require("crier_obs.proc.spawner")
local logger = require("crier_obs.log")
describe("safe process diagnostics", function()
  it("reports process lifecycle and timeout states without command or environment values", function()
    local now, done = 0, false
    local messages = {}
    local log =
      logger.new({ debug = true, obs = {
        LOG_DEBUG = 1,
        script_log = function(_, message)
          messages[#messages + 1] = message
        end,
      } })
    log.register_secret("SUPER_SECRET")
    local engine = spawner.new({
      log = log,
      clock = {
        now_mono = function()
          return now
        end,
      },
      env = {
        inherited = function()
          return {}
        end,
      },
      backend = {
        spawn = function()
          return {
            pid = 42,
            poll = function()
              if done then
                return { code = 0 }
              end
            end,
            terminate = function() end,
            kill = function() end,
          }
        end,
      },
    })
    local process = assert(
      engine.spawn({ kind = "publish", args = { "SUPER_SECRET" }, env = { CRIER_TOKEN = "SUPER_SECRET" }, timeout = 1, kill_grace = 1 })
    )
    now = 1
    process.poll()
    now = 2
    process.poll()
    done = true
    process.poll()
    process.poll()
    assert.equal(5, #messages)
    assert.matches("spawning publish", messages[1], 1, true)
    assert.matches("pid 42", messages[2], 1, true)
    assert.matches("timeout", messages[3], 1, true)
    assert.matches("timeout grace", messages[4], 1, true)
    assert.matches("code 0", messages[5], 1, true)
    -- Environment names are logged, never their values.
    assert.matches("job environment: CRIER_TOKEN", messages[1], 1, true)
    assert.matches("stdout 0 bytes", messages[5], 1, true)
    for _, message in ipairs(messages) do
      assert.is_nil(message:find("SUPER_SECRET", 1, true))
    end
  end)
end)
