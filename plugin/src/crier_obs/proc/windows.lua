local ffi = require("ffi")
local bit = require("bit")
local utf16 = require("crier_obs.utf16")
local cmdline = require("crier_obs.proc.cmdline_windows")
ffi.cdef([[
typedef void *COBS_HANDLE;
typedef struct { uint32_t nLength; void *lpSecurityDescriptor; int bInheritHandle; } COBS_SECURITY_ATTRIBUTES;
typedef struct { uint32_t cb; uint16_t *lpReserved; uint16_t *lpDesktop; uint16_t *lpTitle;
uint32_t dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
 uint16_t wShowWindow,cbReserved2; unsigned char *lpReserved2; COBS_HANDLE hStdInput,hStdOutput,hStdError; } COBS_STARTUPINFOW;
typedef struct { COBS_STARTUPINFOW StartupInfo; void *lpAttributeList; } COBS_STARTUPINFOEXW;
typedef struct { COBS_HANDLE hProcess,hThread; uint32_t dwProcessId,dwThreadId; } COBS_PROCESS_INFORMATION;
uint16_t *__stdcall GetEnvironmentStringsW(void); int __stdcall FreeEnvironmentStringsW(uint16_t*);
COBS_HANDLE __stdcall OpenProcess(uint32_t,int,uint32_t); COBS_HANDLE __stdcall OpenJobObjectW(uint32_t,int,const uint16_t*);
uint32_t __stdcall GetLastError(void); int __stdcall CloseHandle(COBS_HANDLE);
COBS_HANDLE __stdcall GetCurrentProcess(void); uint32_t __stdcall GetCurrentProcessId(void);
int __stdcall DuplicateHandle(COBS_HANDLE,COBS_HANDLE,COBS_HANDLE,COBS_HANDLE*,uint32_t,int,uint32_t);
COBS_HANDLE __stdcall CreateFileW(const uint16_t*,uint32_t,uint32_t,COBS_SECURITY_ATTRIBUTES*,uint32_t,uint32_t,COBS_HANDLE);
int __stdcall CreatePipe(COBS_HANDLE*,COBS_HANDLE*,COBS_SECURITY_ATTRIBUTES*,uint32_t);
int __stdcall SetHandleInformation(COBS_HANDLE,uint32_t,uint32_t);
int __stdcall PeekNamedPipe(COBS_HANDLE,void*,uint32_t,uint32_t*,uint32_t*,uint32_t*);
int __stdcall ReadFile(COBS_HANDLE,void*,uint32_t,uint32_t*,void*);
int __stdcall WriteFile(COBS_HANDLE,const void*,uint32_t,uint32_t*,void*);
int __stdcall InitializeProcThreadAttributeList(void*,uint32_t,uint32_t,size_t*);
int __stdcall UpdateProcThreadAttribute(void*,uint32_t,uintptr_t,void*,size_t,void*,size_t*);
void __stdcall DeleteProcThreadAttributeList(void*);
int __stdcall CreateProcessW(const uint16_t*,uint16_t*,void*,void*,int,uint32_t,void*,const uint16_t*,
COBS_STARTUPINFOEXW*,COBS_PROCESS_INFORMATION*);
COBS_HANDLE __stdcall CreateJobObjectW(void*,const uint16_t*);
int __stdcall AssignProcessToJobObject(COBS_HANDLE,COBS_HANDLE);
uint32_t __stdcall ResumeThread(COBS_HANDLE);
uint32_t __stdcall WaitForSingleObject(COBS_HANDLE,uint32_t);
int __stdcall GetExitCodeProcess(COBS_HANDLE,uint32_t*);
int __stdcall TerminateJobObject(COBS_HANDLE,uint32_t);
int __stdcall TerminateProcess(COBS_HANDLE,uint32_t);
]])
local M = {}
-- The observer inherits a duplicate of the actual process handle as stdin.
-- It cannot race PID reuse or lose the exit code when OBS unloads first.
local OBSERVE = [=[
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CrierProcessWatch {
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
 [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
$h = [CrierProcessWatch]::GetStdHandle(-10)
try {
 if ([CrierProcessWatch]::WaitForSingleObject($h, [uint32]::MaxValue) -ne 0) { exit 1 }
 [uint32]$code = 0
 if (-not [CrierProcessWatch]::GetExitCodeProcess($h, [ref]$code)) { exit 1 }
 $target = $env:COBS_STATUS
 $tmp = $target + '.observer-' + $PID
 $encoding = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllText($tmp, [string]$code, $encoding)
 try { [System.IO.File]::Move($tmp, $target) }
 catch [System.IO.IOException] {
  if (-not [System.IO.File]::Exists($target)) { throw }
  [System.IO.File]::Replace($tmp, $target, $null)
 }
} finally { [void][CrierProcessWatch]::CloseHandle($h) }
]=]
M.observer_script = OBSERVE
function M.new(deps)
  deps = deps or {}
  local C = deps.C or ffi.C
  local env = deps.env or require("crier_obs.ports.env").new({ platform = "Windows", C = C })
  local self = {}
  local fs = deps.fs or {}
  function self.current_pid()
    return tonumber(C.GetCurrentProcessId())
  end
  -- ERROR_INVALID_PARAMETER and ERROR_NOT_FOUND mean no such process; any other failure (access
  -- denied) means it exists.
  function self.alive(pid)
    local h = C.OpenProcess(0x1000, 0, pid)
    if h == nil then
      local code = tonumber(C.GetLastError())
      return code ~= 87 and code ~= 1168
    end
    local code = ffi.new("uint32_t[1]")
    local running = C.GetExitCodeProcess(h, code) ~= 0 and tonumber(code[0]) == 259
    C.CloseHandle(h)
    return running
  end
  function self.spawn(plan)
    local keep, handles = {}, {}
    local attrs
    local process, job, thread, job_name
    local function wide(text)
      local bytes, err = utf16.encode(text)
      if not bytes then
        return nil, err
      end
      if text:find("\0", 1, true) then
        return nil, { kind = "spawn", message = "NUL in process text" }
      end
      local b = ffi.new("uint16_t[?]", #bytes / 2 + 1)
      ffi.copy(b, bytes, #bytes)
      keep[#keep + 1] = b
      return b
    end
    local function remember(h)
      if h ~= nil and h ~= ffi.cast("void*", -1) then
        handles[#handles + 1] = h
      end
      return h
    end
    local function close(h)
      if h and h ~= nil then
        for i, v in ipairs(handles) do
          if v == h then
            C.CloseHandle(h)
            handles[i] = false
            break
          end
        end
      end
    end
    local function cleanup()
      if attrs then
        C.DeleteProcThreadAttributeList(attrs)
        attrs = nil
      end
      for _, h in ipairs(handles) do
        if h then
          C.CloseHandle(h)
        end
      end
      handles = {}
    end
    local function fail(message, code)
      code = code or tonumber(C.GetLastError())
      if process then
        C.TerminateProcess(process, 1)
      end
      cleanup()
      return nil, { kind = "spawn", message = message, win32 = code }
    end
    local sa = ffi.new("COBS_SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof(sa)
    sa.bInheritHandle = 1
    local function file(path, input)
      local name, e = wide(path or "NUL")
      if not name then
        return nil, e
      end
      local h = C.CreateFileW(name, input and 0x80000000 or 0x40000000, 7, sa, input and 3 or 2, 0x80, nil)
      if h == nil or h == ffi.cast("void*", -1) then
        return nil, tonumber(C.GetLastError())
      end
      return remember(h)
    end
    local function pipe(input)
      local r, w = ffi.new("COBS_HANDLE[1]"), ffi.new("COBS_HANDLE[1]")
      if C.CreatePipe(r, w, sa, 4096) == 0 then
        return nil, tonumber(C.GetLastError())
      end
      remember(r[0])
      remember(w[0])
      local parent = input and w[0] or r[0]
      if C.SetHandleInformation(parent, 1, 0) == 0 then
        return nil, tonumber(C.GetLastError())
      end
      return { read = r[0], write = w[0], parent = parent, child = input and r[0] or w[0], input = input }
    end
    local pin, pout, perr
    local hin, hout, herr, e
    if plan.stdin_handle then
      local duplicate = ffi.new("COBS_HANDLE[1]")
      local owner = C.GetCurrentProcess()
      if C.DuplicateHandle(owner, plan.stdin_handle, owner, duplicate, 0, 1, 2) == 0 then
        return fail("Cannot transfer input handle", tonumber(C.GetLastError()))
      end
      hin = remember(duplicate[0])
    elseif plan.stdin_data ~= nil then
      pin, e = pipe(true)
      if pin then
        hin = pin.child
      end
    else
      hin, e = file(plan.stdin, true)
    end
    if not hin then
      return fail("Cannot open stdin", e)
    end
    if plan.capture_stdout then
      pout, e = pipe(false)
      if pout then
        hout = pout.child
      end
    else
      hout, e = file(plan.stdout, false)
    end
    if not hout then
      return fail("Cannot open stdout", e)
    end
    if plan.capture_stderr then
      perr, e = pipe(false)
      if perr then
        herr = perr.child
      end
    else
      herr, e = file(plan.stderr, false)
    end
    if not herr then
      return fail("Cannot open stderr", e)
    end
    local size = ffi.new("size_t[1]")
    C.InitializeProcThreadAttributeList(nil, 1, 0, size)
    if tonumber(size[0]) == 0 then
      return fail("Cannot size handle list")
    end
    local memory = ffi.new("uint8_t[?]", tonumber(size[0]))
    keep[#keep + 1] = memory
    if C.InitializeProcThreadAttributeList(memory, 1, 0, size) == 0 then
      return fail("Cannot initialize handle list")
    end
    attrs = memory
    local list = ffi.new("COBS_HANDLE[3]", { hin, hout, herr })
    keep[#keep + 1] = list
    if C.UpdateProcThreadAttribute(attrs, 0, 0x20002, list, ffi.sizeof(list), nil, nil) == 0 then
      return fail("Cannot restrict inherited handles")
    end
    local si = ffi.new("COBS_STARTUPINFOEXW")
    si.StartupInfo.cb = ffi.sizeof(si)
    si.StartupInfo.dwFlags = 0x100
    si.StartupInfo.hStdInput = hin
    si.StartupInfo.hStdOutput = hout
    si.StartupInfo.hStdError = herr
    si.lpAttributeList = attrs
    local pi = ffi.new("COBS_PROCESS_INFORMATION")
    local exe = plan.executable or plan.command
    if type(exe) ~= "string" or exe == "" then
      return fail("Invalid executable", 87)
    end
    local app, ae = wide(exe)
    local line, le = wide(cmdline.command(exe, plan.args or plan.argv))
    local cwd, ce = wide(plan.cwd or ".")
    if not app or not line or not cwd then
      cleanup()
      return nil, ae or le or ce
    end
    local bytes, be = cmdline.environment(plan.env or {})
    if not bytes then
      cleanup()
      return nil, be
    end
    local block = ffi.new("uint16_t[?]", #bytes / 2)
    ffi.copy(block, bytes, #bytes)
    keep[#keep + 1] = block
    if deps.before_spawn then
      deps.before_spawn(plan, keep)
    end
    local ok = C.CreateProcessW(app, line, nil, nil, 1, bit.bor(0x08000000, 0x400, 4, 0x80000), block, cwd, si, pi)
    local spawn_error = ok == 0 and tonumber(C.GetLastError()) or nil
    ffi.fill(block, ffi.sizeof(block), 0)
    if ok == 0 then
      return fail("Cannot create process", spawn_error)
    end
    process = remember(pi.hProcess)
    thread = remember(pi.hThread)
    job_name = "Local\\crier-obs-" .. tonumber(pi.dwProcessId)
    job = remember(C.CreateJobObjectW(nil, wide(job_name)))
    if job == nil then
      return fail("Cannot create job")
    end
    if C.AssignProcessToJobObject(job, process) == 0 then
      return fail("Cannot assign process to job")
    end
    -- A named job object loses its name when its last handle closes. The observer of a detached
    -- run receives a duplicate of that run's job handle, so the next load can still reopen the job
    -- by name and stop the whole tree. Without it, adoption falls back to the process handle.
    local kept = false
    if plan.keep_alive then
      local copy = ffi.new("COBS_HANDLE[1]")
      kept = C.DuplicateHandle(C.GetCurrentProcess(), plan.keep_alive, process, copy, 0, 0, 2) ~= 0
    end
    if C.ResumeThread(thread) == 0xffffffff then
      return fail("Cannot resume process")
    end
    close(thread)
    if not pin then
      close(hin)
    end
    close(hout)
    close(herr)
    if attrs then
      C.DeleteProcThreadAttributeList(attrs)
      attrs = nil
    end
    local p = { pid = tonumber(pi.dwProcessId), child_pid = tonumber(pi.dwProcessId), stdout = "", stderr = "", kept = kept }
    local result, exited
    local pending = plan.stdin_data or ""
    if fs.write and plan.pid_path then
      fs.write(plan.pid_path, tostring(p.pid))
    end
    local function pump()
      if pin and pin.write and #pending > 0 then
        local available = ffi.new("uint32_t[1]")
        if C.PeekNamedPipe(pin.read, nil, 0, nil, available, nil) ~= 0 then
          local n = math.min(#pending, math.max(0, 4096 - tonumber(available[0])), 1024)
          if n > 0 then
            local written = ffi.new("uint32_t[1]")
            if C.WriteFile(pin.write, pending, n, written, nil) ~= 0 then
              pending = pending:sub(tonumber(written[0]) + 1)
            else
              close(pin.write)
              pin.write = nil
            end
          end
        end
      end
      if pin and #pending == 0 then
        close(pin.write)
        close(pin.read)
        pin = nil
      end
      for _, entry in ipairs({ pout and { pout, "stdout" } or false, perr and { perr, "stderr" } or false }) do
        if entry then
          local pipe_ = entry[1]
          local available = ffi.new("uint32_t[1]")
          local peek = C.PeekNamedPipe(pipe_.read, nil, 0, nil, available, nil)
          if peek == 0 then
            pipe_.eof = true
          elseif available[0] > 0 then
            local n = math.min(65536, tonumber(available[0]))
            local buf = ffi.new("char[?]", n)
            local got = ffi.new("uint32_t[1]")
            if C.ReadFile(pipe_.read, buf, n, got, nil) ~= 0 then
              p[entry[2]] = (p[entry[2]] .. ffi.string(buf, got[0])):sub(-(plan.capture_limit or 8388608))
            end
          end
        end
      end
    end
    function p.poll()
      if result then
        return result
      end
      pump()
      if exited then
        if (not pout or pout.eof) and (not perr or perr.eof) then
          result = exited
          result.stdout = p.stdout
          result.stderr = p.stderr
          cleanup()
          return result
        end
        return nil
      end
      local wait = C.WaitForSingleObject(process, 0)
      if wait == 258 then
        return nil
      elseif wait ~= 0 then
        return nil, { kind = "process", message = "Cannot poll process", win32 = tonumber(C.GetLastError()) }
      end
      local code = ffi.new("uint32_t[1]")
      if C.GetExitCodeProcess(process, code) == 0 then
        return nil, { kind = "process", message = "Cannot read exit code", win32 = tonumber(C.GetLastError()) }
      end
      exited = { code = tonumber(code[0]), crashed = code[0] >= 0x80000000, pid = p.pid }
      if fs.write and plan.status_path then
        fs.write(plan.status_path, tostring(exited.code))
      end
      if (not pout or pout.eof) and (not perr or perr.eof) then
        result = exited
        result.stdout = p.stdout
        result.stderr = p.stderr
        cleanup()
        return result
      end
      return nil
    end
    function p.terminate()
      return C.TerminateJobObject(job, 1) ~= 0
    end
    p.kill = p.terminate
    function p.cancel()
      if result then return true end
      local stopped = C.TerminateJobObject(job, 1)
      local code = stopped == 0 and tonumber(C.GetLastError()) or nil
      pending = ""
      if pout then pout.eof = true end
      if perr then perr.eof = true end
      cleanup()
      result = {code = 1, cancelled = true, stdout = "", stderr = "", pid = p.pid}
      p.cancelled = true
      if fs.write and plan.status_path then fs.write(plan.status_path, "1") end
      if stopped == 0 then return nil, {kind = "process", message = "Cannot cancel process job", win32 = code} end
      return true
    end
    p.close = p.cancel
    local detached
    function p.detach()
      if detached then return detached end
      local helpers = {}
      local plain = {}
      for key, value in pairs(env.inherited()) do
        if not key:upper():match("^CRIER_") then plain[key:upper()] = value end
      end
      local executable = cmdline.powershell(plain.SYSTEMROOT)
      local function helper(script, input, status, keep_alive)
        local environment = {}
        for key, value in pairs(plain) do environment[key] = value end
        environment.COBS_STATUS = status
        local child, err = self.spawn({
          executable = executable,
          args = {"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script},
          env = environment, stdin_handle = input, kind = status and "observer" or "drainer", keep_alive = keep_alive,
        })
        if child then helpers[#helpers + 1] = child; return child end
        for _, started in ipairs(helpers) do started.kill(); started.detach() end
        return nil, err
      end
      -- Transfer the process handle before closing ours, even if it has already exited.
      local named
      if plan.status_path and not result then
        local observer, err = helper(OBSERVE, process, plan.status_path, job)
        if not observer then return nil, err end
        named = observer.kept and job_name or nil
      end
      for _, source in ipairs({pout or false, perr or false}) do
        if source and not source.eof then
          local drainer, err = helper("[Console]::OpenStandardInput().CopyTo([System.IO.Stream]::Null)", source.read)
          if not drainer then return nil, err end
        end
      end
      local records = {}
      for _, helper_process in ipairs(helpers) do records[#records + 1] = helper_process.detach() end
      cleanup()
      detached = {pid = p.pid, child_pid = p.pid, status_path = plan.status_path,
        job_name = named, drainers = records, kind = plan.kind}
      return detached
    end
    p.tick = p.poll
    return p
  end
  function self.adopt(record)
    local function persisted()
      if not record.status_path or not fs.read then return nil end
      local text = fs.read(record.status_path)
      local code = tonumber(text)
      if not code or code < 0 or code > 4294967295 or code % 1 ~= 0 then return nil end
      return {code = code, crashed = code >= 0x80000000, pid = record.pid}
    end
    local saved = persisted()
    if saved then
      return {pid = record.pid, child_pid = record.pid,
        poll = function() return saved end, terminate = function() return false end, kill = function() return false end,
        cancel = function() return true end, close = function() return true end,
        detach = function() return record end}
    end
    local h = C.OpenProcess(0x00100000 + 0x1000 + 1, 0, record.pid)
    if h == nil then
      local native_error = tonumber(C.GetLastError())
      local observed = false
      for _, helper in ipairs(record.drainers or {}) do if helper.kind == "observer" then observed = true end end
      if observed and record.status_path then
        local clock = (deps.clock or {}).now_mono or os.time
        local started, completed = clock(), nil
        local waiting = {pid = record.pid, child_pid = record.pid}
        function waiting.poll()
          if completed then return completed end
          completed = persisted()
          if completed then return completed end
          if clock() - started >= (deps.observer_timeout or 60) then
            return nil, {kind = "process", message = "Detached process observer did not produce an exit status", win32 = native_error}
          end
          return nil
        end
        function waiting.terminate() return false end
        waiting.kill = waiting.terminate
        function waiting.cancel() completed = {pid = record.pid, code = 1, cancelled = true}; return true end
        waiting.close = waiting.cancel
        function waiting.detach() return record end
        return waiting
      end
      return nil, {kind = "process", message = "Cannot reopen detached process", win32 = native_error}
    end
    local job
    if record.job_name then
      local bytes = utf16.encode(record.job_name)
      local name = ffi.new("uint16_t[?]", #bytes / 2 + 1)
      ffi.copy(name, bytes, #bytes)
      job = C.OpenJobObjectW(8, 0, name)
      -- A NULL cdata is truthy in LuaJIT; without the job, the process handle is what remains.
      if job == nil then
        job = nil
      end
    end
    local p = { pid = record.pid, child_pid = record.pid }
    local result
    local function close()
      if h then
        C.CloseHandle(h)
        h = nil
      end
      if job then
        C.CloseHandle(job)
        job = nil
      end
    end
    function p.poll()
      if result then
        return result
      end
      local wait = C.WaitForSingleObject(h, 0)
      if wait == 258 then
        return nil
      end
      if wait ~= 0 then
        return nil, { kind = "process", message = "Cannot poll detached process", win32 = tonumber(C.GetLastError()) }
      end
      local code = ffi.new("uint32_t[1]")
      if C.GetExitCodeProcess(h, code) == 0 then
        return nil,
          { kind = "process", message = "Cannot read detached process exit code", win32 = tonumber(C.GetLastError()) }
      end
      result = { code = tonumber(code[0]), crashed = code[0] >= 0x80000000, pid = p.pid }
      if fs.write and record.status_path then
        fs.write(record.status_path, tostring(result.code))
      end
      close()
      return result
    end
    function p.terminate()
      if job then
        return C.TerminateJobObject(job, 1) ~= 0
      end
      return C.TerminateProcess(h, 1) ~= 0
    end
    p.kill = p.terminate
    function p.cancel()
      if result then return true end
      local ok
      if job then ok = C.TerminateJobObject(job, 1) else ok = C.TerminateProcess(h, 1) end
      local code = ok == 0 and tonumber(C.GetLastError()) or nil
      close()
      result = {code = 1, cancelled = true, stdout = "", stderr = "", pid = p.pid}
      p.cancelled = true
      if fs.write and record.status_path then fs.write(record.status_path, "1") end
      if ok == 0 then return nil, {kind = "process", message = "Cannot cancel detached process", win32 = code} end
      return true
    end
    p.close = p.cancel
    function p.detach()
      close()
      return record
    end
    return p
  end
  return self
end
return M
