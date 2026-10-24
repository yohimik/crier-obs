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
  -- Polls in place; the list is only rebuilt when a job finishes, so an idle heartbeat allocates nothing.
  function self.tick()
    if closed or #active == 0 then return end
    local i = 1
    while i <= #active do
      local job = active[i]
      local result, err = job.process.poll()
      if result or err then
        table.remove(active, i)
        if err then job.process.cancel() end
        if result and result.timed_out then err = {kind = 'unavailable', message = 'Credential store timed out'} end
        job.callback(result, err)
      else i = i + 1 end
    end
  end
  function self.close()
    closed = true
    for _, job in ipairs(active) do job.process.cancel() end
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
