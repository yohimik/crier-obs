local ffi = require("ffi")
local bit = require("bit")
local pipes = require("crier_obs.proc.pipes")
ffi.cdef([[
int posix_spawnp(int*,const char*,const void*,const void*,char*const[],char*const[]);
int posix_spawn_file_actions_init(void*); int posix_spawn_file_actions_destroy(void*);
int posix_spawnattr_init(void*); int posix_spawnattr_destroy(void*);
int posix_spawnattr_setflags(void*,short); int posix_spawnattr_setpgroup(void*,int);
int posix_spawn_file_actions_addclosefrom_np(void*,int); int posix_spawn_file_actions_addinherit_np(void*,int);
int posix_spawn_file_actions_adddup2(void*,int,int); int posix_spawn_file_actions_addclose(void*,int);
int waitpid(int,int*,int); int kill(int,int); extern char **environ; char ***_NSGetEnviron(void);
void *opendir(const char*); void *readdir(void*); int closedir(void*); int dirfd(void*);
]])
local M = {}
local SCRIPT = [=[umask 077
in=$COBS_IN out=$COBS_OUT err=$COBS_ERR d=$COBS_CWD st=$COBS_STATUS pf=$COBS_PIDFILE
unset COBS_IN COBS_OUT COBS_ERR COBS_CWD COBS_STATUS COBS_PIDFILE
if [ -n "$d" ]; then cd "$d" || { [ -z "$st" ] || echo 97 >"$st"; exit 97; }; fi
[ -z "$in" ] || exec <"$in"
[ -z "$out" ] || exec >"$out"
[ -z "$err" ] || exec 2>"$err"
"$0" "$@" <&0 & c=$!
[ -z "$pf" ] || echo "$c" >"$pf"
term=0; trap 'term=1; kill -TERM "$c" 2>/dev/null' TERM
wait "$c"; rc=$?
if [ "$term" = 1 ]; then wait "$c"; rc=$?; fi
[ -z "$st" ] || echo "$rc" >"$st"
exit "$rc"
]=]
local function failure(message, code)
	return nil, { kind = "spawn", message = message .. (code and (" (errno " .. code .. ")") or ""), errno = code }
end
function M.inherited(C)
	C = C or ffi.C
	local env = {}
	local ptr = ffi.os == "OSX" and C._NSGetEnviron()[0] or C.environ
	local i = 0
	while ptr[i] ~= nil do
		local s = ffi.string(ptr[i])
		local k, v = s:match("^([^=]+)=(.*)$")
		if k then
			env[k] = v
		end
		i = i + 1
	end
	return env
end

function M.new(deps)
	deps = deps or {}
	local C = deps.C or ffi.C
	local platform = deps.platform or ffi.os
	local pool = pipes.new({ C = C })
	local fs = deps.fs or {}
	local self = {}
	local reapers = {}
	function self.reap()
		local completed = {}
		for i = #reapers, 1, -1 do
			local record = reapers[i]
			local status = ffi.new("int[1]")
			local waited = C.waitpid(record.pid, status, 1)
			if waited > 0 or (waited < 0 and ffi.errno() == 10) then
				local previous = record.status_path and fs.read and fs.read(record.status_path)
				record.code = waited > 0
						and (bit.band(status[0], 127) == 0 and bit.rshift(status[0], 8) or 128 + bit.band(
							status[0],
							127
						))
					or tonumber(previous)
					or 1
				if fs.write and record.status_path then
					fs.write(record.status_path, tostring(record.code))
				end
				completed[#completed + 1] = record
				table.remove(reapers, i)
			end
		end
		return completed
	end
	local function readfile(path)
		if path and fs.read then
			return fs.read(path)
		end
		return nil
	end
	function self.spawn(plan)
		local executable = plan.executable or plan.command
		if type(executable) ~= "string" or executable == "" or executable:find("\0", 1, true) then
			return failure("Invalid executable")
		end
		local env = {}
		for k, v in pairs(plan.env or {}) do
			env[k] = tostring(v)
		end
		env.COBS_IN = plan.stdin or "/dev/null"
		env.COBS_OUT = plan.stdout or "/dev/null"
		env.COBS_ERR = plan.stderr or "/dev/null"
		env.COBS_CWD = plan.cwd or ""
		env.COBS_STATUS = plan.status_path or ""
		env.COBS_PIDFILE = plan.pid_path or ""
		local pin, pout, perr, pextra
		local function cleanup()
			for _, p in ipairs({ pin or false, pout or false, perr or false, pextra or false }) do
				if p then
					p.close()
				end
			end
		end
		local function openpipe()
			local p, e = pool.open()
			if not p then
				cleanup()
				return nil, e
			end
			return p
		end
		local err
		if plan.env_fd_data ~= nil then
			pextra, err = openpipe()
			if not pextra then
				return nil, err
			end
		end
		if plan.stdout_fd then
			env.COBS_OUT = ""
		end
		if plan.stdin_fd then
			env.COBS_IN = ""
		end
		if plan.stdin_data ~= nil then
			pin, err = openpipe()
			if not pin then
				return nil, err
			end
			env.COBS_IN = ""
		end
		if plan.capture_stdout then
			pout, err = openpipe()
			if not pout then
				return nil, err
			end
			env.COBS_OUT = ""
		end
		if plan.capture_stderr then
			perr, err = openpipe()
			if not perr then
				return nil, err
			end
			env.COBS_ERR = ""
		end
		local direct = (plan.kind == "keyring" or plan.kind == "env_writer") and not plan.cwd
		if direct then
			for name in pairs(env) do
				if name:match("^COBS_") then
					env[name] = nil
				end
			end
		end
		local args = direct and { executable } or { "/bin/sh", "-c", SCRIPT, executable }
		for _, a in ipairs(plan.args or plan.argv or {}) do
			args[#args + 1] = tostring(a)
		end
		local keep, buffers = {}, {}
		local function array(values)
			local a = ffi.new("char *[?]", #values + 1)
			keep[#keep + 1] = a
			for i, s in ipairs(values) do
				if s:find("\0", 1, true) then
					return nil
				end
				local b = ffi.new("char[?]", #s + 1, s)
				keep[#keep + 1] = b
				buffers[#buffers + 1] = b
				a[i - 1] = b
			end
			return a
		end
		local argv = array(args)
		local entries = {}
		for k, v in pairs(env) do
			if k:find("=", 1, true) or k:find("\0", 1, true) then
				cleanup()
				return failure("Invalid environment name")
			end
			entries[#entries + 1] = k .. "=" .. v
		end
		table.sort(entries)
		local envp = array(entries)
		if not argv or not envp then
			cleanup()
			return failure("NUL in process arguments or environment")
		end
		local actions = ffi.new("uint64_t[32]")
		local rc = C.posix_spawn_file_actions_init(actions)
		if rc ~= 0 then
			cleanup()
			return failure("Cannot initialize spawn actions", rc)
		end
		local function action(result)
			if result ~= 0 then
				err = result
			end
		end
		if platform == "OSX" then
			for fd = 0, 2 do
				if C.fcntl(fd, 1) >= 0 then
					action(C.posix_spawn_file_actions_addinherit_np(actions, fd))
				end
			end
		end
		local nonblock = ffi.os == "OSX" and 4 or 2048
		for _, entry in ipairs({
			pin and { pin.read_fd, 0 } or (plan.stdin_fd and { plan.stdin_fd, 0 } or false),
			pout and { pout.write_fd, 1 } or (plan.stdout_fd and { plan.stdout_fd, 1 } or false),
			perr and { perr.write_fd, 2 } or false,
			pextra and { pextra.read_fd, 3 } or false,
		}) do
			if entry then
				local flags = C.fcntl(entry[1], 3)
				C.fcntl(entry[1], 4, ffi.new("int", bit.band(flags, bit.bnot(nonblock))))
				action(C.posix_spawn_file_actions_adddup2(actions, entry[1], entry[2]))
			end
		end
		if pextra and platform == "OSX" then
			action(C.posix_spawn_file_actions_addinherit_np(actions, 3))
		end
		local attributes = ffi.new("uint64_t[128]")
		local attr_rc = C.posix_spawnattr_init(attributes)
		if attr_rc ~= 0 then
			err = attr_rc
			attributes = nil
		else
			action(C.posix_spawnattr_setpgroup(attributes, 0))
			action(C.posix_spawnattr_setflags(attributes, platform == "OSX" and 0x4002 or 2))
		end
		if platform ~= "OSX" then
			local available, closefrom = pcall(function()
				return C.posix_spawn_file_actions_addclosefrom_np
			end)
			if available and closefrom then
				action(closefrom(actions, pextra and 4 or 3))
			else
				err = 95
			end
		end

		if err then
			C.posix_spawn_file_actions_destroy(actions)
			if attributes then
				C.posix_spawnattr_destroy(attributes)
			end
			cleanup()
			return failure("Cannot configure descriptor hygiene", err)
		end
		if deps.before_spawn then
			deps.before_spawn(plan, keep)
		end
		local pid = ffi.new("int[1]")
		rc = C.posix_spawnp(pid, direct and executable or "/bin/sh", actions, attributes, argv, envp)
		for _, b in ipairs(buffers) do
			ffi.fill(b, ffi.sizeof(b), 0)
		end
		C.posix_spawn_file_actions_destroy(actions)
		if attributes then
			C.posix_spawnattr_destroy(attributes)
		end
		if rc ~= 0 then
			cleanup()
			return failure("Cannot spawn process", rc)
		end
		if pin then
			pin.close_read()
			pin.pending = plan.stdin_data
		end
		if pout then
			pout.close_write()
		end
		if perr then
			perr.close_write()
		end
		local auxiliary = {}
		if pextra then
			pextra.close_read()
			local forwarded = {}
			for entry in plan.env_fd_data:gmatch("[^%z]+") do
				local key, value = entry:match("^(=?[^=]+)=(.*)$")
				if key then
					forwarded[key] = value
				end
			end
			local writer, we = self.spawn({
				executable = "/usr/bin/env",
				args = { "-0" },
				env = forwarded,
				stdout_fd = pextra.write_fd,
				kind = "env_writer",
			})
			pextra.close_write()
			if not writer then
				C.kill(-pid[0], 9)
				reapers[#reapers + 1] = { pid = tonumber(pid[0]), status_path = plan.status_path, run = plan.run }
				cleanup()
				return nil, { kind = "spawn", message = "Cannot deliver host environment: " .. we.message }
			end
			local record = writer.detach()
			auxiliary[#auxiliary + 1] = record
			reapers[#reapers + 1] = record
		end
		local cleanup_helpers = auxiliary
		local process =
			{ pid = tonumber(pid[0]), child_pid = direct and tonumber(pid[0]) or nil, stdout = "", stderr = "" }
		local result, exited, pipe_error
		local function pump()
			if pin and pin.write_fd then
				local done = pin.flush()
				if done then
					pin.close_write()
				end
			end
			for _, entry in ipairs({ pout and { pout, "stdout" } or false, perr and { perr, "stderr" } or false }) do
				if entry then
					local data, e = entry[1].read()
					if e then
						pipe_error = e
						entry[1].eof = true
					end
					if data then
						process[entry[2]] = (process[entry[2]] .. data):sub(-(plan.capture_limit or 8388608))
					end
				end
			end
			process.child_pid = tonumber((readfile(plan.pid_path))) or process.child_pid
		end
		function process.poll()
			if result then
				return result
			end
			pump()
			if pipe_error then
				return nil, pipe_error
			end
			local status = ffi.new("int[1]")
			local waited = exited and 0 or C.waitpid(process.pid, status, 1)
			if exited then
				if (not pout or pout.eof) and (not perr or perr.eof) then
					cleanup()
					result = exited
					result.stdout = process.stdout
					result.stderr = process.stderr
					return result
				end
				return nil
			end
			if waited == 0 then
				return nil
			end
			local code, signal
			if waited < 0 then
				local e = ffi.errno()
				if e == 4 then
					return nil
				end
				if e ~= 10 then
					return failure("Cannot poll process", e)
				end
				code = tonumber((readfile(plan.status_path)))
				if not code then
					if C.kill(process.pid, 0) ~= 0 and ffi.errno() == 3 then
						code = 1
					else
						return nil
					end
				end
			else
				local s = tonumber(status[0])
				if bit.band(s, 127) == 0 then
					code = bit.rshift(s, 8)
				else
					signal = bit.band(s, 127)
					code = 128 + signal
				end
				code = tonumber((readfile(plan.status_path))) or code
			end
			exited = { code = code, signal = signal, pid = process.pid }
			if pin then
				pin.close()
			end
			if (not pout or pout.eof) and (not perr or perr.eof) then
				cleanup()
				result = exited
				result.stdout = process.stdout
				result.stderr = process.stderr
				return result
			end
			return nil
		end
		function process.cancel()
			if result then
				cleanup()
				return true
			end
			process.kill()
			cleanup()
			local status = ffi.new("int[1]")
			local waited = C.waitpid(process.pid, status, 1)
			if waited == 0 or (waited < 0 and ffi.errno() == 4) then
				local record = {
					pid = process.pid,
					child_pid = process.child_pid,
					status_path = plan.status_path,
					pid_path = plan.pid_path,
					run = plan.run,
					state = "detached",
					drainers = cleanup_helpers,
				}
				reapers[#reapers + 1] = record
				return record
			end
			if #cleanup_helpers > 0 then
				return {
					pid = process.pid,
					child_pid = process.child_pid,
					status_path = plan.status_path,
					pid_path = plan.pid_path,
					drainers = cleanup_helpers,
				}
			end
			return true
		end
		process.close = process.cancel
		function process.terminate()
			if exited or result then
				return false
			end
			return C.kill(process.pid, 15) == 0
		end
		function process.kill()
			if result then
				return true
			end
			if not exited then
				pump()
			end
			-- Every spawned wrapper has its own process group. Escalation and cancellation
			-- reach children even before the wrapper has written its child pid file.
			return C.kill(-process.pid, 9) == 0
		end

		function process.detach()
			if pin and pin.write_fd then
				return nil, { kind = "detach", message = "Cannot detach a process with pending stdin" }
			end
			local drainers = {}
			for _, record in ipairs(auxiliary) do
				drainers[#drainers + 1] = record
			end
			for _, pipe_ in ipairs({ pout or false, perr or false }) do
				if pipe_ and pipe_.read_fd then
					local drainer, e =
						self.spawn({ executable = "/bin/cat", args = {}, env = {}, stdin_fd = pipe_.read_fd })
					if not drainer then
						return nil, { kind = "detach", message = "Cannot hand off output pipe: " .. e.message }
					end
					local record = drainer.detach()
					drainers[#drainers + 1] = record
					cleanup_helpers[#cleanup_helpers + 1] = record
					reapers[#reapers + 1] = record
				end
			end
			cleanup()
			return {
				pid = process.pid,
				child_pid = process.child_pid,
				status_path = plan.status_path,
				pid_path = plan.pid_path,
				drainers = drainers,
			}
		end
		process.tick = process.poll
		return process
	end
	function self.adopt(record)
		if type(record.pid) ~= "number" or record.pid < 2 or record.pid % 1 ~= 0 then
			return failure("Invalid adopted process PID")
		end
		local result
		local p = { pid = record.pid, child_pid = record.child_pid }
		function p.poll()
			if result then
				return result
			end
			local s = ffi.new("int[1]")
			local n = C.waitpid(p.pid, s, 1)
			local wait_error = n < 0 and ffi.errno() or nil
			if wait_error and wait_error ~= 4 and wait_error ~= 10 then
				return failure("Cannot poll adopted process", wait_error)
			end
			if n == 0 or wait_error == 4 then
				return nil
			end
			local code = tonumber((readfile(record.status_path)))
			if not code and n > 0 then
				code = bit.band(s[0], 127) == 0 and bit.rshift(s[0], 8) or 128 + bit.band(s[0], 127)
			end
			if not code and wait_error == 10 and C.kill(p.pid, 0) ~= 0 and ffi.errno() == 3 then
				code = 1
			end
			if code then
				result = { code = code, pid = p.pid }
				return result
			end
		end
		function p.terminate()
			if result then
				return false
			end
			return C.kill(p.pid, 15) == 0
		end
		function p.kill()
			if result then
				return true
			end
			return C.kill(-p.pid, 9) == 0
		end
		function p.cancel()
			if result then
				return true
			end
			p.kill()
			local status = ffi.new("int[1]")
			local waited = C.waitpid(p.pid, status, 1)
			if waited == 0 or (waited < 0 and ffi.errno() == 4) then
				local pending = {
					pid = p.pid,
					child_pid = p.child_pid,
					status_path = record.status_path,
					state = "detached",
					drainers = record.drainers,
				}
				if record.journal and record.event ~= "drainer" then
					pending.run = {
						event = record.event,
						created_at = record.created_at,
						journal = record.journal,
						status = record.status_path,
						pid = record.pid_path,
					}
				end
				reapers[#reapers + 1] = pending
				return pending
			end
			result = { pid = p.pid, code = 1, cancelled = true }
			return true
		end
		p.close = p.cancel

		function p.detach()
			return record
		end
		return p
	end
	return self
end
M.wrapper = SCRIPT
return M
