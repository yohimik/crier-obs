-- Win32 contract fake: real FFI buffers, deliberate GC, and strict handle ownership.
local ffi = require("ffi")
local utf16 = require("crier_obs.utf16")
local M = {}

local function wide(ptr)
  local n = 0
  while ptr[n] ~= 0 do
    n = n + 1
  end
  return assert(utf16.decode(ffi.string(ptr, n * 2)))
end

function M.new(options)
  options = options or {}
  local state =
    { live = {}, calls = {}, pipes = {}, processes = {}, next_handle = 100, error = 5, exit_code = options.code or 0 }
  local C = {}
  local function handle(kind)
    state.next_handle = state.next_handle + 1
    local h = ffi.cast("void*", state.next_handle)
    state.live[tostring(h)] = kind
    return h
  end
  local function called(name)
    state.calls[name] = (state.calls[name] or 0) + 1
    if options.fail == name and (not options.fail_at or state.calls[name] == options.fail_at) then
      state.error = 1234
      return false
    end
    return true
  end
  function C.GetLastError()
    return state.error
  end
  function C.CloseHandle(h)
    assert(state.live[tostring(h)], "double-close or unknown handle")
    state.live[tostring(h)] = nil
    state.error = 6 -- cleanup must not overwrite the original error report
    return 1
  end
  function C.CreateFileW(path, _, _, sa)
    assert(sa.bInheritHandle == 1)
    state.last_file = wide(path)
    if not called("CreateFileW") then
      return ffi.cast("void*", -1)
    end
    return handle("file")
  end
  function C.CreatePipe(read, write)
    if not called("CreatePipe") then
      return 0
    end
    read[0], write[0] = handle("pipe-read"), handle("pipe-write")
    local pipe = { data = options.output or "" }
    state.pipes[tostring(read[0])], state.pipes[tostring(write[0])] = pipe, pipe
    return 1
  end
  function C.SetHandleInformation()
    return called("SetHandleInformation") and 1 or 0
  end
  function C.PeekNamedPipe(h, _, _, _, available)
    local pipe = assert(state.pipes[tostring(h)])
    available[0] = #pipe.data
    if state.finished and #pipe.data == 0 then
      state.error = 109
      return 0
    end
    return 1
  end
  function C.ReadFile(h, buffer, size, got)
    local pipe = assert(state.pipes[tostring(h)])
    local data = pipe.data:sub(1, size)
    ffi.copy(buffer, data, #data)
    got[0], pipe.data = #data, pipe.data:sub(#data + 1)
    return 1
  end
  function C.WriteFile(_, data, size, written)
    if not called('WriteFile') then return 0 end
    state.input = (state.input or "") .. ffi.string(data, size)
    written[0] = size
    return 1
  end
  function C.GetCurrentProcess()
    return ffi.cast("void*", -1)
  end
  function C.DuplicateHandle(_, source, _, out, _, inherit, flags)
    assert(inherit == 1 and flags == 2)
    if not called("DuplicateHandle") then
      return 0
    end
    out[0] = handle("duplicate")
    state.pipes[tostring(out[0])] = state.pipes[tostring(source)]
    state.duplicates = state.duplicates or {}; state.duplicates[tostring(out[0])] = source
    return 1
  end
  function C.GetEnvironmentStringsW()
    local bytes = assert(utf16.encode("SystemRoot=C:\\Windows\0CRIER_TOKEN=parent-secret\0\0"))
    state.env_block = ffi.new("uint16_t[?]", #bytes / 2)
    ffi.copy(state.env_block, bytes, #bytes)
    return state.env_block
  end
  function C.FreeEnvironmentStringsW()
    return 1
  end
  function C.InitializeProcThreadAttributeList(ptr, count, flags, size)
    assert(count == 1 and flags == 0)
    size[0] = 64
    if ptr == nil then
      state.error = 122
      return 0
    end
    if not called("InitializeProcThreadAttributeList") then
      return 0
    end
    state.attributes = true
    return 1
  end
  function C.UpdateProcThreadAttribute(_, _, attribute, list, size)
    assert(attribute == 0x20002)
    assert(size == ffi.sizeof("COBS_HANDLE") * 3)
    state.handle_list = list
    return called("UpdateProcThreadAttribute") and 1 or 0
  end
  function C.DeleteProcThreadAttributeList()
    assert(state.attributes, "attribute list deleted twice")
    state.attributes = false
    state.error = 6
  end
  function C.CreateProcessW(app, line, _, _, inherit, flags, env, cwd, si, pi)
    collectgarbage()
    collectgarbage()
    local junk = {}
    for i = 1, 3000 do
      junk[i] = string.rep(tostring(i), 50)
    end
    assert(#junk == 3000)
    assert(inherit == 1)
    assert(si.StartupInfo.cb == ffi.sizeof("COBS_STARTUPINFOEXW"))
    assert(flags == 0x08000000 + 0x400 + 4 + 0x80000)
    assert(state.handle_list[0] == si.StartupInfo.hStdInput)
    assert(state.handle_list[1] == si.StartupInfo.hStdOutput)
    assert(state.handle_list[2] == si.StartupInfo.hStdError)
    state.application, state.command, state.cwd = wide(app), wide(line), wide(cwd)
    local p = ffi.cast("uint16_t*", env)
    local n = 0
    while not (p[n] == 0 and p[n + 1] == 0) do
      n = n + 1
    end
    state.environment = assert(utf16.decode(ffi.string(p, (n + 2) * 2)))
    state.environment_buffer = env
    state.environment_size = (n + 2) * 2
    state.processes[#state.processes + 1] =
      { application = state.application, command = state.command, environment = state.environment,
        stdin = si.StartupInfo.hStdInput,
        inherited = {state.handle_list[0], state.handle_list[1], state.handle_list[2]} }
    if not called("CreateProcessW") then
      return 0
    end
    pi.hProcess, pi.hThread = handle("process"), handle("thread")
    pi.dwProcessId = 4321
    return 1
  end
  function C.CreateJobObjectW(_, name)
    state.job_name = wide(name)
    if not called("CreateJobObjectW") then
      return ffi.NULL
    end
    return handle("job")
  end
  function C.AssignProcessToJobObject()
    return called("AssignProcessToJobObject") and 1 or 0
  end
  function C.ResumeThread()
    return called("ResumeThread") and 1 or 0xffffffff
  end
  function C.WaitForSingleObject(_, timeout)
    assert(timeout == 0)
    if not called("WaitForSingleObject") then
      return 0xffffffff
    end
    if not options.running then
      state.finished = true
    end
    return options.running and 258 or 0
  end
  function C.GetExitCodeProcess(_, out)
    if not called("GetExitCodeProcess") then
      return 0
    end
    out[0] = state.exit_code
    return 1
  end
  function C.TerminateProcess()
    called("TerminateProcess")
    state.error = 6
    return 1
  end
  function C.TerminateJobObject()
    called("TerminateJobObject")
    return 1
  end
  function C.OpenProcess()
    if not called('OpenProcess') then return ffi.NULL end
    return handle("process")
  end
  function C.OpenJobObjectW()
    return handle("job")
  end
  function state.assert_closed()
    assert(next(state.live) == nil, "unclosed Win32 handles")
    assert(not state.attributes, "unreleased attribute list")
  end
  return C, state
end

return M
