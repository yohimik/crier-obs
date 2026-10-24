local M = {}
local function critical(job) return job.event == 'start' or job.event == 'end' or job.event == 'quit' end
function M.new(deps)
  deps = deps or {}
  local pending, active = {}, nil
  local self = {}
  local bound, backlog = deps.bound or 5, deps.backlog
  local function spill(job)
    if not backlog then return false, 'overflow store unavailable' end
    local ok, err = backlog.append(job)
    if not ok then return false, 'cannot preserve queued post: ' .. ((err or {}).message or 'write failed') end
    return true
  end
  function self.push(job)
    if job.event == 'interval' then
      for _, p in ipairs(pending) do if p.event == 'interval' then return false, 'coalesced' end end
    end
    if backlog and backlog.size() > 0 then
      if critical(job) then return spill(job) end
      return false, 'full'
    end
    if #pending >= bound then
      local victim
      for i, p in ipairs(pending) do if p.event == 'interval' then victim = i; break end end
      if victim then
        local dropped = table.remove(pending, victim)
        dropped.cancel()
        if deps.on_drop then deps.on_drop(dropped, 'queue capacity reached') end
      elseif critical(job) then return spill(job)
      else return false, 'full' end
    end
    pending[#pending + 1] = job
    return true
  end
  local function done(job)
    if backlog then backlog.ack(job) end
    if deps.on_done then deps.on_done(job) end
  end
  function self.tick()
    if active then
      active.tick()
      if active.finished() then done(active); active = nil end
    end
    if not active then
      if #pending > 0 then active = table.remove(pending, 1)
      elseif backlog and backlog.size() > 0 then
        local err; active, err = backlog.take()
        if err and deps.on_error then deps.on_error(err) end
      end
      if active then
        active.start()
        if active.finished() then done(active); active = nil end
      end
    end
    return active
  end
  -- Unload: a running post is detached (crier keeps going and the next load adopts it). Posts that
  -- have not started are spilled for the next load of this process, or, when OBS is quitting
  -- (options.skip), cancelled with that reason: a stale "Live now" must never post at the next launch.
  function self.detach(options)
    options = options or {}
    local spilling = backlog and not options.skip
    local records, last_error = {}, nil
    if active then
      if active.finished() then done(active)
      elseif options.skip and active.state ~= 'running' then
        active.cancel(options.skip)
        if backlog then backlog.ack(active) end
      elseif spilling and critical(active) and active.state ~= 'running' then
        local ok, reason = spill(active)
        if not ok then
          active.cancel()
          last_error = {kind = 'queue', message = reason}
        else
          local parked, err = active.park()
          if not parked then last_error = err or {kind = 'queue', message = 'Cannot park queued post safely'} end
        end
      else
        local record, err = active.detach()
        if err then last_error = err end
        if record then records[#records + 1] = record end
        if backlog then backlog.ack(active) end
      end
      active = nil
    end
    for _, job in ipairs(pending) do
      local preserved = false
      if spilling and critical(job) then
        local reason; preserved, reason = spill(job)
        if not preserved then last_error = {kind = 'queue', message = reason} end
      end
      if not preserved then job.cancel(options.skip) end
    end
    pending = {}
    if last_error then return nil, last_error end
    return records
  end
  function self.drop_intervals()
    for i = #pending, 1, -1 do
      if pending[i].event == 'interval' then
        local dropped = table.remove(pending, i)
        dropped.cancel()
        if deps.on_drop then deps.on_drop(dropped, 'stream ended') end
      end
    end
  end
  function self.size() return #pending end
  function self.backlog_size() return backlog and backlog.size() or 0 end
  function self.active() return active end
  function self.items() return pending end
  return self
end
return M
