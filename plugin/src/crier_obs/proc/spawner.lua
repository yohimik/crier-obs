local ffi = require("ffi")
local host = require("crier_obs.proc.host")
local M = {}
local function sorted_names(t)
	local names = {}
	for name in pairs(t or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end
function M.new(deps)
	deps = deps or {}
	local platform = deps.platform or (deps.env or {}).os or ffi.os
	local env = deps.env or require("crier_obs.ports.env").new({ platform = platform, C = deps.C })
	local clock = deps.clock or {}
	local windows = platform == "Windows"
	local backend = deps.backend
		or require(windows and "crier_obs.proc.windows" or "crier_obs.proc.posix").new({
			C = deps.C,
			platform = platform,
			arch = deps.arch,
			env = env,
			fs = deps.fs,
			clock = deps.clock,
			before_spawn = deps.before_spawn,
			observer_timeout = deps.observer_timeout,
		})
	local function now()
		return clock.now_mono and clock.now_mono() or 0
	end
	local function debug(message)
		if deps.log then
			deps.log.debug(message)
		end
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
		for k, v in pairs(env.inherited()) do
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
		local prepared, host_error = host.prepare(copy, env, deps.fs)
		if not prepared then
			return nil, host_error
		end
		copy = prepared
		local kind = tostring(plan.kind or "process")
		-- Credentials travel only in the environment, so it is logged by name; every line is scrubbed.
		local names = table.concat(sorted_names(plan.env), ", ")
		debug(
			"spawning "
				.. kind
				.. ": "
				.. table.concat({ tostring(plan.executable or plan.command), unpack(plan.args or {}) }, " ")
				.. "; job environment: "
				.. (names ~= "" and names or "none")
		)
		local p, e = backend.spawn(copy)
		if not p then
			debug(kind .. " spawn failed")
			return nil, e
		end
		debug(kind .. " started pid " .. tostring(p.pid or "unknown"))
		local poll, terminate, kill = p.poll, p.terminate, p.kill
		local started = now()
		local term_at, result
		function p.poll()
			if result then
				return result
			end
			local r, err = poll()
			if r then
				debug(
					kind
						.. " finished with code "
						.. tostring(r.code)
						.. " (stdout "
						.. #(r.stdout or "")
						.. " bytes, stderr "
						.. #(r.stderr or "")
						.. " bytes)"
				)
				r.timed_out = term_at ~= nil
				result = r
				return r
			end
			if err then
				debug(kind .. " poll failed")
				return nil, err
			end
			local t = now()
			if plan.timeout and t - started >= plan.timeout and not term_at then
				term_at = t
				debug("terminating " .. kind .. " after timeout")
				terminate()
			elseif term_at and t - term_at >= (plan.kill_grace or 10) then
				debug("killing " .. kind .. " after timeout grace")
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
	-- Every process this spawner hands out supports cancel(): it stops the process and returns true,
	-- or a pending record whose wrapper is still being reaped.
	function self.stop(process)
		return process.cancel()
	end
	function self.current_pid()
		return backend.current_pid()
	end
	function self.alive(pid)
		return backend.alive(pid)
	end
	return self
end
return M
