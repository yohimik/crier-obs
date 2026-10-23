local ffi = require("ffi")
local M = {}
function M.new(deps)
	deps = deps or {}
	local env = deps.env or {}
	local clock = deps.clock or {}
	local windows = (deps.platform or env.os or ffi.os) == "Windows"
	local backend = deps.backend or require(windows and "crier_obs.proc.windows" or "crier_obs.proc.posix").new(deps)
	local function now()
		return clock.now_mono and clock.now_mono() or 0
	end
	local function inherited()
		if env.inherited then
			return env.inherited()
		end
		return require(windows and "crier_obs.proc.windows" or "crier_obs.proc.posix").inherited(deps.C)
	end
  local function debug(message)
    if deps.log and deps.log.debug then deps.log.debug(message) end
  end
	local self = {}
	function self.spawn(plan)
		local copy = {}
		for k, v in pairs(plan) do
			copy[k] = v
		end
		copy.env = {}
		local function name(key)
			return windows and key:upper() or key
		end
		for k, v in pairs(inherited()) do
			k = name(k)
			if not k:match("^CRIER_") then
				copy.env[k] = v
			end
		end
		local path = env.augmented_path or env.path
		if type(path) == "function" then
			copy.env.PATH = path()
		elseif type(path) == "string" then
			copy.env.PATH = path
		end
		-- Callers explicitly provide only credentials needed for this job. Probes never inherit CRIER_*.
		for k, v in pairs(plan.env or {}) do
			copy.env[name(k)] = v
		end
		if env.prepare_host then
			local prepared, host_error = env.prepare_host(copy, deps.fs)
			if not prepared then
				return nil, host_error
			end
			copy = prepared
		end
    debug("spawning "..tostring(plan.kind or "process"))
		local p, e = backend.spawn(copy)
		if not p then
      debug("process spawn failed")
			return nil, e
		end
    debug("process started pid "..tostring(p.pid or "unknown"))
		local poll, terminate, kill = p.poll, p.terminate, p.kill
		local started = now()
		local term_at, result
		function p.poll()
			if result then
				return result
			end
			local r, err = poll()
			if r then
        debug("process finished with code "..tostring(r.code))
				r.timed_out = term_at ~= nil
				result = r
				return r
			end
			if err then
        debug("process poll failed")
				return nil, err
			end
			local t = now()
			if plan.timeout and t - started >= plan.timeout and not term_at then
				term_at = t
        debug("terminating process after timeout")
				terminate()
			elseif term_at and t - term_at >= (plan.kill_grace or 10) then
        debug("killing process after timeout grace")
				kill()
				term_at = t
			end
			return nil
		end
		p.tick = p.poll
		return p
	end
	function self.reap()
		return backend.reap and backend.reap() or {}
	end
	function self.adopt(record)
		if backend.adopt then
			return backend.adopt(record)
		end
		return nil, { kind = "process", message = "This platform cannot adopt an existing process" }
	end
	return self
end
return M
