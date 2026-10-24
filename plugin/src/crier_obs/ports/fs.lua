local ffi = require("ffi")
local bit = require("bit")
local consts = require("crier_obs.proc.consts")
local M = {}
ffi.cdef(
  [[int open(const char*, int, ...); long write(int,const void*,unsigned long); long read(int,void*,unsigned long);
 int close(int); int mkdir(const char*, unsigned int); int chmod(const char*, unsigned int); int unlink(const char*);
 int fchmod(int,unsigned int); int getpid(void); int rename(const char*,const char*);
 void *opendir(const char*); void *readdir(void*); int closedir(void*);
 void *cobs_opendir_inode64(const char*) __asm__("opendir$INODE64");
 void *cobs_readdir_inode64(void*) __asm__("readdir$INODE64");
 typedef struct { uint64_t ino; uint64_t seek; uint16_t reclen; uint16_t namlen; uint8_t type; char name[1024]; }
   cobs_dirent_darwin;
 typedef struct { unsigned long ino; long off; unsigned short reclen; unsigned char type; char name[256]; }
   cobs_dirent_linux;]]
)
function M.new(deps)
  local obs = assert(deps.obs)
  local platform = deps.platform or ffi.os
  local arch = deps.arch or ffi.arch
  local C = deps.C or ffi.C
  local K = consts.of(platform, arch)
  local private_create = bit.bor(K.O_WRONLY, K.O_CREAT, K.O_EXCL)
  local self = {}
  local counter = 0
  function self.exists(path)
    return obs.os_file_exists(path)
  end
  function self.read(path)
    local s = obs.os_quick_read_utf8_file(path)
    if s == nil then
      return nil, { kind = "filesystem", message = "Cannot read " .. path }
    end
    return s
  end
  function self.mkdir(path)
    local rc = obs.os_mkdirs(path)
    if rc == false or (type(rc) == "number" and rc < 0) then
      return nil, { kind = "filesystem", message = "Cannot create " .. path }
    end
    return true
  end
  function self.mkdir_private(path)
    local ok, err = self.mkdir(path)
    if not ok then
      return nil, err
    end
    if platform ~= "Windows" then
      local fd = C.open(path, bit.bor(K.O_RDONLY, K.O_DIRECTORY, K.O_NOFOLLOW))
      if fd < 0 then
        return nil, { kind = "filesystem", message = "Private directory is inaccessible or a symlink: " .. path }
      end
      local secured = C.fchmod(fd, K.S_IRWXU) == 0
      C.close(fd)
      if not secured then
        return nil, { kind = "filesystem", message = "Cannot secure " .. path }
      end
    end
    return true
  end
  function self.write(path, data)
    local ok = obs.os_quick_write_utf8_file_safe(path, data, #data, false, "tmp", "bak")
    if not ok then
      return nil, { kind = "filesystem", message = "Cannot write " .. path }
    end
    return true
  end
  function self.write_private(path, data)
    if platform == "Windows" then
      -- No backup extension: os_safe_replace would otherwise keep the previous record as <path>.bak,
      -- and a re-saved or forgotten credential must not survive in a backup file.
      if not obs.os_quick_write_utf8_file_safe(path, data, #data, false, "tmp", nil) then
        return nil, { kind = "filesystem", message = "Cannot write private file " .. path }
      end
      return true
    end
    counter = counter + 1
    local tmp = path .. "." .. tonumber(C.getpid()) .. "." .. counter .. ".tmp"
    local fd = C.open(tmp, private_create, ffi.cast("unsigned int", K.S_IRUSR_IWUSR))
    if fd < 0 then
      return nil, { kind = "filesystem", message = "Cannot create private file " .. path }
    end
    local buf = ffi.new("uint8_t[?]", #data)
    ffi.copy(buf, data, #data)
    local offset = 0
    local ok = true
    while offset < #data do
      local n = tonumber(C.write(fd, buf + offset, #data - offset))
      if n <= 0 then
        if n ~= -1 or ffi.errno() ~= K.EINTR then
          ok = false
          break
        end
      else
        offset = offset + n
      end
    end
    ffi.fill(buf, #data)
    if C.close(fd) ~= 0 then
      ok = false
    end
    if ok and C.rename(tmp, path) == 0 then
      return true
    end
    C.unlink(tmp)
    return nil, { kind = "filesystem", message = "Cannot write private file " .. path }
  end
  -- Removes a private record together with the side files a safe write can leave behind.
  function self.remove_private(path)
    local ok = not self.exists(path) or self.remove(path)
    for _, suffix in ipairs({ ".bak", ".tmp" }) do
      if self.exists(path .. suffix) and not self.remove(path .. suffix) then
        ok = false
      end
    end
    return ok
  end
  function self.create_private(path, data)
    if platform == "Windows" then
      local utf16 = require("crier_obs.utf16")
      ffi.cdef([[void* __stdcall CreateFileW(const uint16_t*,uint32_t,uint32_t,void*,uint32_t,uint32_t,void*);
        int __stdcall WriteFile(void*,const void*,uint32_t,uint32_t*,void*);
        int __stdcall CloseHandle(void*); uint32_t __stdcall GetLastError(void);]])
      local encoded = utf16.encode(path)
      if not encoded then
        return nil, { kind = "filesystem", message = "Invalid private path" }
      end
      local wide = ffi.new("uint16_t[?]", #encoded / 2 + 1)
      ffi.copy(wide, encoded, #encoded)
      local handle = C.CreateFileW(wide, 0x40000000, 0, nil, 1, 0x80, nil)
      if handle == ffi.cast("void*", -1) then
        local code = tonumber(C.GetLastError())
        return nil,
          { kind = (code == 80 or code == 183) and "exists" or "filesystem", message = "Cannot create private file" }
      end
      local written = ffi.new("uint32_t[1]")
      local ok = C.WriteFile(handle, data, #data, written, nil) ~= 0 and tonumber(written[0]) == #data
      C.CloseHandle(handle)
      if not ok then
        self.remove(path)
        return nil, { kind = "filesystem", message = "Cannot write private file" }
      end
      return true
    end
    local fd = C.open(path, private_create, ffi.cast("unsigned int", K.S_IRUSR_IWUSR))
    if fd < 0 then
      return nil, { kind = ffi.errno() == K.EEXIST and "exists" or "filesystem", message = "Cannot create private file" }
    end
    local buffer = ffi.new("uint8_t[?]", #data)
    ffi.copy(buffer, data, #data)
    local offset = 0
    while offset < #data do
      local count = tonumber(C.write(fd, buffer + offset, #data - offset))
      if count <= 0 then
        if count ~= -1 or ffi.errno() ~= K.EINTR then
          ffi.fill(buffer, #data)
          C.close(fd)
          C.unlink(path)
          return nil, { kind = "filesystem", message = "Cannot write private file" }
        end
      else
        offset = offset + count
      end
    end
    ffi.fill(buffer, #data)
    local ok = C.close(fd) == 0
    if not ok then
      return nil, { kind = "filesystem", message = "Cannot close private file" }
    end
    return true
  end
  function self.remove(path)
    return obs.os_unlink(path) == 0
  end
  self.unlink = self.remove
  function self.rmdir(path)
    return obs.os_rmdir(path) == 0
  end
  function self.rename(from, to)
    return obs.os_rename(from, to) == 0
  end
  function self.glob(pattern)
    local directory, mask = pattern:match("^(.*)[/\\]([^/\\]*)$")
    directory = directory or "."
    mask = mask or pattern
    local names = {}
    if platform == "Windows" then
      local utf16 = require("crier_obs.utf16")
      ffi.cdef([[typedef struct { uint32_t attrs; uint32_t times[6]; uint32_t sizehi;
        uint32_t sizelo; uint32_t reserved[2]; uint16_t name[260]; uint16_t alt[14]; } cobs_find_data;
        void* __stdcall FindFirstFileW(const uint16_t*,cobs_find_data*);
        int __stdcall FindNextFileW(void*,cobs_find_data*); int __stdcall FindClose(void*);]])
      local encoded = utf16.encode(pattern)
      if not encoded then
        return names
      end
      local wide = ffi.new("uint16_t[?]", #encoded / 2 + 1)
      ffi.copy(wide, encoded, #encoded)
      local data = ffi.new("cobs_find_data[1]")
      local handle = C.FindFirstFileW(wide, data)
      if handle == ffi.cast("void*", -1) then
        return names
      end
      repeat
        local i = 0
        while data[0].name[i] ~= 0 do
          i = i + 1
        end
        local name = utf16.decode(ffi.string(data[0].name, i * 2))
        if name and name ~= "." and name ~= ".." then
          names[#names + 1] = directory .. "/" .. name
        end
      until C.FindNextFileW(handle, data) == 0
      C.FindClose(handle)
    else
      -- Darwin's plain opendir/readdir are the legacy 32-bit-inode ABI on x86_64; the $INODE64 symbols
      -- return the layout below there, and arm64 has only that layout under the plain names.
      local legacy = platform == "OSX" and arch == "x64"
      local opendir = legacy and C.cobs_opendir_inode64 or C.opendir
      local readdir = legacy and C.cobs_readdir_inode64 or C.readdir
      local layout = platform == "OSX" and "cobs_dirent_darwin*" or "cobs_dirent_linux*"
      local dir = opendir(directory)
      if dir == nil then
        return names
      end
      local match = "^" .. mask:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
      while true do
        local entry = readdir(dir)
        if entry == nil then
          break
        end
        local name = ffi.string(ffi.cast(layout, entry).name)
        if name ~= "." and name ~= ".." and name:match(match) then
          names[#names + 1] = directory .. "/" .. name
        end
      end
      C.closedir(dir)
    end
    table.sort(names)
    return names
  end
  self.list = function(path)
    return self.glob(path .. "/*")
  end
  function self.random_bytes(n)
    if platform == "Windows" then
      ffi.cdef("long __stdcall BCryptGenRandom(void*, unsigned char*, unsigned long, unsigned long);")
      local buf = ffi.new("uint8_t[?]", n)
      local bcrypt = deps.bcrypt or ffi.load("bcrypt")
      if bcrypt.BCryptGenRandom(nil, buf, n, 2) ~= 0 then
        return nil, { kind = "random", message = "System random source unavailable" }
      end
      return ffi.string(buf, n)
    end
    local fd = C.open("/dev/urandom", 0)
    if fd < 0 then
      return nil, { kind = "random", message = "System random source unavailable" }
    end
    local b = ffi.new("uint8_t[?]", n)
    local at = 0
    while at < n do
      local count = tonumber(C.read(fd, b + at, n - at))
      if count <= 0 then
        C.close(fd)
        return nil, { kind = "random", message = "Random read failed" }
      end
      at = at + count
    end
    C.close(fd)
    return ffi.string(b, n)
  end
  return self
end
return M
