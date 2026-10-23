local cli = require('crier_obs.secrets.keyring.cli')
local M = {}
local function quote(value) return '"' .. value:gsub('([\\"])', '\\%1') .. '"' end
function M.new(deps)
  local commands = cli.new(deps)
  local self = {name = 'macos', tick = commands.tick, close = commands.close}
  local executable = deps.security_bin or '/usr/bin/security'
  function self.store(account, value, callback)
    local hex = value:gsub('.', function(c) return string.format('%02x', c:byte()) end)
    commands.run(executable,
       {'-i'},
       'add-generic-password -U -a ' .. quote(account) .. ' -s crier-obs -X ' .. hex .. '\n',
       function(result,
       err)
      local failure = cli.failure(result, err)
      callback(not failure, failure)
    end)
  end
  function self.lookup(account, callback)
    commands.run(executable, {'find-generic-password', '-s', 'crier-obs', '-a', account, '-w'}, nil, function(result, err)
      local failure = cli.failure(result, err, 44)
      if failure then callback(nil, failure); return end
      local value = (result.stdout or ''):gsub('\r?\n$', '')
      if value == '' then callback(nil, {kind = 'missing', message = 'Credential not stored'}); return end
      callback(value)
    end)
  end
  function self.forget(account, callback)
    commands.run(executable, {'delete-generic-password', '-s', 'crier-obs', '-a', account}, nil, function(result, err)
      local failure = cli.failure(result, err, 44)
      if failure and failure.kind == 'missing' then failure = nil end
      callback(not failure, failure)
    end)
  end
  return self
end
return M
