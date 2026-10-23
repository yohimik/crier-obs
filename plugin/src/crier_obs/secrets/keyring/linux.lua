local cli = require('crier_obs.secrets.keyring.cli')
local M = {}
function M.new(deps)
  local commands = cli.new(deps)
  local self = {name = 'linux', tick = commands.tick, close = commands.close}
  local function run(args, input, callback)
    local executable = deps.secret_tool_bin or 'secret-tool'
    commands.run(executable, args, input, callback)
  end
  function self.store(account, value, callback)
    run({'store', '--label=crier-obs', 'service', 'crier-obs', 'account', account}, value, function(result, err)
      local failure = cli.failure(result, err); callback(not failure, failure)
    end)
  end
  function self.lookup(account, callback)
    run({'lookup', 'service', 'crier-obs', 'account', account}, nil, function(result, err)
      local failure = cli.failure(result, err, 1)
      if failure then callback(nil, failure); return end
      local value = (result.stdout or ''):gsub('\r?\n$', '')
      if value == '' then callback(nil, {kind = 'missing', message = 'Credential not stored'}); return end
      callback(value)
    end)
  end
  function self.forget(account, callback)
    run({'clear', 'service', 'crier-obs', 'account', account}, nil, function(result, err)
      local failure = cli.failure(result, err, 1)
      if failure and failure.kind == 'missing' then failure = nil end
      callback(not failure, failure)
    end)
  end
  return self
end
return M
