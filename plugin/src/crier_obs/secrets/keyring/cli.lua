local M = {}
function M.new(deps)
  local active, self, closed = {}, {}, false
  function self.run(executable, args, input, callback)
    if closed then callback(nil, {kind = 'cancelled', message = 'Credential store is closed'}); return end
    local process, err = deps.spawner.spawn{
      executable = executable, args = args, stdin_data = input, env = deps.command_env or {},
      capture_stdout = true, capture_stderr = true, timeout = deps.keyring_timeout or 60, kind = 'keyring',
    }
    if not process then callback(nil, err); return end
    active[#active + 1] = {process = process, callback = callback}
  end
  local function cancel(process)
    if process.cancel then process.cancel()
    else
      if process.kill then process.kill() end
      process.poll()
      if process.detach then process.detach() end
    end
  end
  function self.tick()
    if closed then return end
    local previous = active; active = {}
    for _, job in ipairs(previous) do
      local result, err = job.process.poll()
      if result or err then
        if err then cancel(job.process) end
        if result and result.timed_out then err = {kind = 'unavailable', message = 'Credential store timed out'} end
        job.callback(result, err)
      else active[#active + 1] = job end
    end
  end
  function self.close()
    closed = true
    for _, job in ipairs(active) do cancel(job.process) end
    active = {}
  end
  return self
end
function M.failure(result, err, missing_code)
  if err then return err end
  if result and result.code == 0 then return nil end
  if result and result.code == missing_code then return {kind = 'missing', message = 'Credential not stored'} end
  local detail = result and result.stderr or ''
  if detail:lower():find('interaction') or detail:lower():find('locked') then
    return {kind = 'unavailable', message = 'Credential store is locked; unlock it and try again'}
  end
  return {kind = 'unavailable', message = 'Credential store is unavailable or refused access'}
end
return M
