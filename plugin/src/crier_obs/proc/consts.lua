-- Native constants that differ between operating systems and CPU architectures, taken from the
-- system headers: Darwin <fcntl.h>, <errno.h>, <signal.h> and <spawn.h>; Linux asm-generic with the
-- overrides in arch/{arm,arm64,powerpc,mips}/include/uapi/asm. Callers never spell these as literals.
local ffi = require("ffi")
local M = {}
local shared = {
	O_RDONLY = 0,
	O_WRONLY = 1,
	O_RDWR = 2,
	F_GETFD = 1,
	F_SETFD = 2,
	F_GETFL = 3,
	F_SETFL = 4,
	FD_CLOEXEC = 1,
	WNOHANG = 1,
	LOCK_EX = 2,
	LOCK_NB = 4,
	LOCK_UN = 8,
	EPERM = 1,
	ESRCH = 3,
	EINTR = 4,
	EBADF = 9,
	ECHILD = 10,
	EEXIST = 17,
	EINVAL = 22,
	EPIPE = 32,
	SIGKILL = 9,
	SIGPIPE = 13,
	SIGTERM = 15,
	POSIX_SPAWN_SETPGROUP = 2,
	S_IRWXU = 448, -- 0700
	S_IRUSR_IWUSR = 384, -- 0600
}
local darwin = {
	O_NONBLOCK = 0x4,
	O_NOFOLLOW = 0x100,
	O_CREAT = 0x200,
	O_EXCL = 0x800,
	O_DIRECTORY = 0x100000,
	EAGAIN = 35,
	ENOTSUP = 45,
	SIG_BLOCK = 1,
	SIG_SETMASK = 3,
	POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000,
}
local linux = {
	O_CREAT = 0x40,
	O_EXCL = 0x80,
	O_NONBLOCK = 0x800,
	O_DIRECTORY = 0x10000,
	O_NOFOLLOW = 0x20000,
	EAGAIN = 11,
	ENOTSUP = 95,
	SIG_BLOCK = 0,
	SIG_SETMASK = 2,
}
-- arm, arm64 and powerpc move O_DIRECTORY and O_NOFOLLOW (0x10000 is O_DIRECT there); mips moves the
-- creation flags and the signal mask operations instead.
local linux_arch = {
	arm = { O_DIRECTORY = 0x4000, O_NOFOLLOW = 0x8000 },
	ppc = { O_DIRECTORY = 0x4000, O_NOFOLLOW = 0x8000 },
	mips = { O_CREAT = 0x100, O_EXCL = 0x400, O_NONBLOCK = 0x80, SIG_BLOCK = 1, SIG_SETMASK = 3 },
}
local function family(arch)
	if arch:match("^arm") then
		return "arm"
	elseif arch:match("^ppc") then
		return "ppc"
	elseif arch:match("^mips") then
		return "mips"
	end
	return "generic"
end
local cache = {}
function M.of(platform, arch)
	platform, arch = platform or ffi.os, arch or ffi.arch
	local id = platform .. "/" .. arch
	if cache[id] then
		return cache[id]
	end
	local out = {}
	for k, v in pairs(shared) do
		out[k] = v
	end
	local layers = platform == "OSX" and { darwin } or { linux, linux_arch[family(arch)] or {} }
	for _, layer in ipairs(layers) do
		for k, v in pairs(layer) do
			out[k] = v
		end
	end
	cache[id] = out
	return out
end
return M
