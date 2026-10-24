local ffi = require("ffi")
local bit = require("bit")
ffi.cdef([[
int pipe(int[2]); int fcntl(int,int,...); long read(int,void*,unsigned long);
long write(int,const void*,unsigned long); int close(int); int sigemptyset(void*);
int sigaddset(void*,int); int sigismember(const void*,int); int sigpending(void*);
int pthread_sigmask(int,const void*,void*); int sigwait(const void*,int*);
]])
local consts = require("crier_obs.proc.consts")
local M = {}
local READ_CHUNK = 8192
function M.new(deps)
	deps = deps or {}
	local C = deps.C or ffi.C
	local K = consts.of(deps.platform, deps.arch)
	local self = {}
	-- One set of signal masks per pool: writes happen on one thread at a time (the heartbeat or a callback).
	local mask, old, pending, signal = ffi.new("uint64_t[16]"), ffi.new("uint64_t[16]"), ffi.new("uint64_t[16]"), ffi.new("int[1]")
	local function safe_write(fd, data, size)
		-- SIGPIPE is thread-local blocked during write, so a closed keyring pipe cannot kill OBS.
		C.sigemptyset(mask)
		C.sigaddset(mask, K.SIGPIPE)
		C.sigpending(pending)
		local was_pending = C.sigismember(pending, K.SIGPIPE) == 1
		if C.pthread_sigmask(K.SIG_BLOCK, mask, old) ~= 0 then
			return -1, K.EINVAL
		end
		local n = tonumber(C.write(fd, data, size))
		local e = n < 0 and ffi.errno() or 0
		if e == K.EPIPE and not was_pending then
			C.sigpending(pending)
			if C.sigismember(pending, K.SIGPIPE) == 1 then
				C.sigwait(mask, signal)
			end
		end
		C.pthread_sigmask(K.SIG_SETMASK, old, nil)
		return n, e
	end
	function self.open()
		local fds = ffi.new("int[2]")
		if C.pipe(fds) ~= 0 then
			return nil, { kind = "pipe", message = "Cannot create pipe", errno = ffi.errno() }
		end
		local p = { read_fd = tonumber(fds[0]), write_fd = tonumber(fds[1]), chunks = {}, pending = "", closed = false }
		for _, fd in ipairs({ p.read_fd, p.write_fd }) do
			local flags = C.fcntl(fd, K.F_GETFL)
			if flags < 0 or C.fcntl(fd, K.F_SETFL, ffi.new("int", bit.bor(flags, K.O_NONBLOCK))) < 0 then
				C.close(p.read_fd)
				C.close(p.write_fd)
				return nil, { kind = "pipe", message = "Cannot configure pipe", errno = ffi.errno() }
			end
			C.fcntl(fd, K.F_SETFD, ffi.new("int", K.FD_CLOEXEC))
		end
		local buffer
		function p.close_read()
			if p.read_fd then
				C.close(p.read_fd)
				p.read_fd = nil
			end
		end
		function p.close_write()
			if p.write_fd then
				C.close(p.write_fd)
				p.write_fd = nil
			end
		end
		function p.read(limit)
			if not p.read_fd then
				return ""
			end
			local out, total = {}, 0
			limit = limit or 65536
			buffer = buffer or ffi.new("char[?]", READ_CHUNK)
			while total < limit do
				local size = math.min(READ_CHUNK, limit - total)
				local n = tonumber(C.read(p.read_fd, buffer, size))
				if n > 0 then
					out[#out + 1] = ffi.string(buffer, n)
					total = total + n
				elseif n == 0 then
					p.eof = true
					p.close_read()
					break
				else
					local e = ffi.errno()
					if e ~= K.EINTR and e ~= K.EAGAIN then
						p.close_read()
						return nil, { kind = "pipe", message = "Cannot read pipe", errno = e }
					end
					if e ~= K.EINTR then
						break
					end
				end
			end
			return table.concat(out)
		end
		function p.feed(data)
			p.pending = p.pending .. (data or "")
			return p.flush()
		end
		function p.flush()
			if not p.write_fd then
				return #p.pending == 0
			end
			local budget = 65536
			while #p.pending > 0 and budget > 0 do
				local n, e = safe_write(p.write_fd, p.pending, math.min(#p.pending, budget))
				if n > 0 then
					p.pending = p.pending:sub(n + 1)
					budget = budget - n
				else
					if e == K.EAGAIN then
						return false
					elseif e ~= K.EINTR then
						p.close_write()
						return nil, { kind = "pipe", message = "Cannot write pipe", errno = e }
					end
				end
			end
			return #p.pending == 0
		end
		function p.close()
			p.close_read()
			p.close_write()
			p.pending = ""
		end
		return p
	end
	return self
end
return M
