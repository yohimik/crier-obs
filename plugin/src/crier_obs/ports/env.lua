local ffi = require("ffi")
local M = {}
ffi.cdef([[int access(const char*,int); int sysctlbyname(const char*,void*,size_t*,void*,size_t);
int open(const char*, int, ...); long read(int,void*,unsigned long); int close(int);]])
function M.new(deps)
	deps = deps or {}
	local get = deps.getenv or os.getenv
	local platform = deps.platform or ffi.os
	local C = deps.C or ffi.C
	local self = { os = platform, arch = ffi.arch, getenv = get }
	function self.flatpak()
		if get("FLATPAK_ID") ~= nil then
			return true
		end
		if deps.fs then
			return deps.fs.exists("/.flatpak-info")
		end
		return platform == "Linux" and C.access("/.flatpak-info", 0) == 0 or false
	end
	function self.snap()
		return get("SNAP") ~= nil or get("SNAP_NAME") ~= nil
	end
	function self.path(extra)
		local sep = platform == "Windows" and ";" or ":"
		local home = get(platform == "Windows" and "USERPROFILE" or "HOME") or ""
		local paths = {}
		if extra and extra ~= "" then
			paths[#paths + 1] = extra
		end
		local inherited_path = get("PATH")
		if inherited_path and inherited_path ~= "" then
			paths[#paths + 1] = inherited_path
		end
		if home ~= "" then
			paths[#paths + 1] = home .. "/.local/bin"
			paths[#paths + 1] = home .. "/bin"
		end
		if platform == "Windows" then
			paths[#paths + 1] = (get("LOCALAPPDATA") or "") .. "\\Microsoft\\WinGet\\Links"
		else
			paths[#paths + 1] = "/opt/homebrew/bin"
			paths[#paths + 1] = "/usr/local/bin"
			paths[#paths + 1] = "/usr/bin"
			paths[#paths + 1] = "/bin"
		end
		return table.concat(paths, sep)
	end
	self.augmented_path = self.path
	function self.inherited()
		local values = {}
		if platform == "Windows" then
			ffi.cdef(
				"uint16_t* __stdcall GetEnvironmentStringsW(void); int __stdcall FreeEnvironmentStringsW(uint16_t*);"
			)
			local utf16 = require("crier_obs.utf16")
			local block = C.GetEnvironmentStringsW()
			if block == nil then
				return values
			end
			local offset = 0
			while block[offset] ~= 0 do
				local finish = offset
				while block[finish] ~= 0 do
					finish = finish + 1
				end
				local text = utf16.decode(ffi.string(block + offset, (finish - offset) * 2))
				if text then
					local name, value = text:match("^(=?[^=]+)=(.*)$")
					if name then
						values[name] = value
					end
				end
				offset = finish + 1
			end
			C.FreeEnvironmentStringsW(block)
		else
			local entries
			if platform == "OSX" then
				ffi.cdef("char ***_NSGetEnviron(void);")
				entries = C._NSGetEnviron()[0]
			else
				ffi.cdef("extern char **environ;")
				entries = C.environ
			end
			local i = 0
			while entries[i] ~= nil do
				local name, value = ffi.string(entries[i]):match("^([^=]+)=(.*)$")
				if name then
					values[name] = value
				end
				i = i + 1
			end
		end
		return values
	end
	function self.crier_names()
		local names = {}
		for name in pairs(self.inherited()) do
			if name:match("^CRIER_") then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		return names
	end
	-- Identifies the current boot, so a journal written before a reboot is never mistaken for a live
	-- process whose pid was reused. nil where the platform offers no cheap identifier.
	function self.boot_id()
		if platform == "OSX" then
			local timeval, size = ffi.new("int64_t[2]"), ffi.new("size_t[1]", 16)
			if C.sysctlbyname("kern.boottime", timeval, size, nil, 0) == 0 then
				return "darwin-" .. tostring(timeval[0]):gsub("LL$", "")
			end
		elseif platform == "Linux" then
			local fd = C.open("/proc/sys/kernel/random/boot_id", 0)
			if fd >= 0 then
				local buffer = ffi.new("char[64]")
				local count = tonumber(C.read(fd, buffer, 64))
				C.close(fd)
				local id = count > 0 and ffi.string(buffer, count):match("^[%x%-]+")
				if id and id ~= "" then
					return "linux-" .. id
				end
			end
		end
		return nil
	end
	function self.sandbox_status(fs)
		if not self.flatpak() then
			if self.snap() then
				return {
					kind = "snap",
					ok = false,
					message = "Snap may isolate host tools and credential services; use a native OBS package",
				}
			end
			return { kind = "native", ok = true }
		end
		fs = fs or deps.fs
		local helper
		if fs then
			for directory in self.path():gmatch("[^:]+") do
				if fs.exists(directory .. "/flatpak-spawn") then
					helper = directory .. "/flatpak-spawn"
					break
				end
			end
		end
		if not helper then
			return {
				kind = "flatpak",
				ok = false,
				message = "Flatpak host access is unavailable: flatpak-spawn is missing; use a native OBS package",
			}
		end
		return {
			kind = "flatpak",
			helper = helper,
			warning = true,
			message = "Flatpak host bridge requires flatpak-spawn --env-fd support and shared home paths; Check setup verifies the host command",
		}
	end
	return self
end
return M
