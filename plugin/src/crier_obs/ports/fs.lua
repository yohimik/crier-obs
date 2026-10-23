local ffi = require("ffi")
local M = {}
ffi.cdef(
  [[int open(const char*, int, ...); long write(int,const void*,unsigned long); long read(int,void*,unsigned long);
 int close(int); int mkdir(const char*, unsigned int); int chmod(const char*, unsigned int); int unlink(const char*);
 int fchmod(int,unsigned int); int getpid(void); int rename(const char*,const char*);]]
)
function M.new(deps)
  local obs = assert(deps.obs)
  local platform = deps.platform or ffi.os
  local C = deps.C or ffi.C
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
      local flags = platform == "OSX" and (0x100000 + 0x100) or (0x10000 + 0x20000)
      local fd = C.open(path, flags)
      if fd < 0 then
        return nil, { kind = "filesystem", message = "Private directory is inaccessible or a symlink: " .. path }
      end
      local secured = C.fchmod(fd, 448) == 0
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
      return self.write(path, data)
    end
    counter = counter + 1
    local tmp = path .. "." .. tonumber(C.getpid()) .. "." .. counter .. ".tmp"
    local flags = platform == "OSX" and (1 + 512 + 2048) or (1 + 64 + 128)
    local fd = C.open(tmp, flags, ffi.cast("unsigned int", 384))
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
        if n ~= -1 or ffi.errno() ~= 4 then
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
    local flags = platform == "OSX" and (1 + 512 + 2048) or (1 + 64 + 128)
    local fd = C.open(path, flags, ffi.cast("unsigned int", 384))
    if fd < 0 then
      return nil, { kind = ffi.errno() == 17 and "exists" or "filesystem", message = "Cannot create private file" }
    end
    local buffer = ffi.new("uint8_t[?]", #data)
    ffi.copy(buffer, data, #data)
    local offset = 0
    while offset < #data do
      local count = tonumber(C.write(fd, buffer + offset, #data - offset))
      if count <= 0 then
        if count ~= -1 or ffi.errno() ~= 4 then
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
      ffi.cdef("void* opendir(const char*); void* readdir(void*); int closedir(void*);")
      if platform == "OSX" then
        ffi.cdef(
          "typedef struct { uint64_t ino; uint64_t seek; uint16_t reclen; uint16_t namlen; uint8_t type; char name[1024]; } cobs_dirent;"
        )
      else
        ffi.cdef(
          "typedef struct { unsigned long ino; long off; unsigned short reclen; unsigned char type; char name[256]; } cobs_dirent;"
        )
      end
      local dir = C.opendir(directory)
      if dir == nil then
        return names
      end
      local match = "^" .. mask:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
      while true do
        local entry = C.readdir(dir)
        if entry == nil then
          break
        end
        local name = ffi.string(ffi.cast("cobs_dirent*", entry).name)
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
