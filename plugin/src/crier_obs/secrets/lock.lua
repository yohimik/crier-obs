local ffi = require('ffi')
local bit = require('bit')
local utf16 = require('crier_obs.utf16')
ffi.cdef[[int open(const char*,int,...); int close(int); int flock(int,int);
void * __stdcall CreateMutexW(void*,int,const uint16_t*);
uint32_t __stdcall WaitForSingleObject(void*,uint32_t);
int __stdcall ReleaseMutex(void*); int __stdcall CloseHandle(void*);]]
local M = {}
function M.new(deps)
  local platform = deps.platform or (deps.env or {}).os or ffi.os
  local C = deps.lock_C or (platform == 'Windows' and ffi.load('kernel32') or ffi.C)
  local path = deps.state_dir .. '/secrets/index.lock'
  local function busy() return nil, {kind = 'busy', message = 'Another OBS instance is saving credentials; try again'} end
  return function(callback)
    local handle, fd
    if platform == 'Windows' then
      local a, b = 5381, 52711
      for i = 1, #path do a = (a * 33 + path:byte(i)) % 4294967296; b = (b * 65599 + path:byte(i)) % 4294967296 end
      local name = utf16.encode(string.format('Local\\crier-obs-%08x%08x', a, b))
      local wide = ffi.new('uint16_t[?]', #name / 2 + 1); ffi.copy(wide, name, #name)
      handle = C.CreateMutexW(nil, 0, wide)
      if handle == nil then return busy() end
      local acquired = tonumber(C.WaitForSingleObject(handle, 0))
      if acquired ~= 0 and acquired ~= 128 then C.CloseHandle(handle); return busy() end
    else
      local flags = bit.bor(2, platform == 'OSX' and 512 or 64, platform == 'OSX' and 256 or 131072)
      fd = C.open(path, flags, ffi.cast('unsigned int', 384))
      if fd < 0 then return nil, {kind = 'filesystem', message = 'Cannot open credential index lock'} end
      if C.flock(fd, 6) ~= 0 then C.close(fd); return busy() end
    end
    local ran, ok, err = pcall(callback)
    if handle then C.ReleaseMutex(handle); C.CloseHandle(handle) else C.flock(fd, 8); C.close(fd) end
    if not ran then return nil, {kind = 'filesystem', message = 'Credential index update failed'} end
    return ok, err
  end
end
return M
