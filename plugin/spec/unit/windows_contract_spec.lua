package.path = "plugin/src/?.lua;plugin/spec/?.lua;src/?.lua;spec/?.lua;" .. package.path
local ffi = require("ffi")
local windows = require("crier_obs.proc.windows")
local fake = require("fakes.win32")

local function plan()
  return {
    executable = "C:\\Program Files\\crier.exe",
    args = { "--set", 'publish.caption=Live 🔴 "hello"' },
    cwd = "C:\\Users\\名字",
    env = { SystemRoot = "C:\\Windows", CRIER_TOKEN = "secret 🔴" },
  }
end

describe("Windows process contracts through real FFI buffers", function()
  it("anchors UTF16 command/environment memory and closes every successful handle", function()
    local C, state = fake.new()
    local p = assert(windows.new({ C = C }).spawn(plan()))
    assert.equals("C:\\Program Files\\crier.exe", state.application)
    assert.matches("Live 🔴", state.command, 1, true)
    assert.equals("CRIER_TOKEN=secret 🔴\0SystemRoot=C:\\Windows\0\0", state.environment)
    assert.equals(
      string.rep("\0", state.environment_size),
      ffi.string(state.environment_buffer, state.environment_size)
    )
    assert.equals(0, p.poll().code)
    state.assert_closed()
  end)

  for _, name in ipairs({
    "CreateFileW",
    "InitializeProcThreadAttributeList",
    "UpdateProcThreadAttribute",
    "CreateProcessW",
    "CreateJobObjectW",
    "AssignProcessToJobObject",
    "ResumeThread",
  }) do
    it("closes resources and preserves GetLastError after " .. name .. " fails", function()
      local C, state = fake.new({ fail = name })
      local p, err = windows.new({ C = C }).spawn(plan())
      assert.is_nil(p)
      assert.equals(1234, err.win32)
      state.assert_closed()
    end)
  end

  it("detaches without terminating a running job, then adopts and reports it", function()
    local C, state = fake.new({ running = true })
    local backend = windows.new({ C = C })
    local p = assert(backend.spawn(plan()))
    assert.is_nil(p.poll())
    local record = p.detach()
    state.assert_closed()
    assert.is_nil(state.calls.TerminateProcess)
    local adopted = assert(backend.adopt(record))
    assert.is_true(adopted.terminate())
    assert.equals(1, state.calls.TerminateJobObject)
    adopted.detach()
    state.assert_closed()
  end)

  it("maps native crash status separately from normal exit codes", function()
    local C, state = fake.new({ code = 0xc0000005 })
    local p = assert(windows.new({ C = C }).spawn(plan()))
    assert.is_true(p.poll().crashed)
    state.assert_closed()
  end)

  it("drains captured output incrementally and closes pipe handles", function()
    local text = string.rep("output 🔴", 20000)
    local C, state = fake.new({ output = text })
    local request = plan()
    request.capture_stdout, request.capture_stderr = true, true
    local p = assert(windows.new({ C = C }).spawn(request))
    local result
    for _ = 1, 20 do
      result = p.poll()
      if result then
        break
      end
    end
    assert.equals(text, result.stdout)
    assert.equals(text, result.stderr)
    state.assert_closed()
  end)

  it("hands detached capture streams to isolated discard drainers", function()
    local C, state = fake.new({ running = true })
    local request = plan()
    request.capture_stdout, request.capture_stderr = true, true
    local p = assert(windows.new({ C = C }).spawn(request))
    local record = assert(p.detach())
    assert.equals(2, #record.drainers)
    assert.equals(3, #state.processes)
    for i = 2, 3 do
      assert.matches("OpenStandardInput().CopyTo", state.processes[i].command, 1, true)
      assert.is_nil(state.processes[i].environment:find("CRIER_", 1, true))
      assert.is_nil(state.processes[i].environment:find("parent-secret", 1, true))
    end
    state.assert_closed()
  end)

  it('feeds credentials only through memory pipes and records status paths', function()
    local C, state
    local files = {}
    local request = plan()
    request.stdin_data = string.rep('secret 🔴', 800)
    request.pid_path, request.status_path = 'pid', 'status'
    local options = {running = true}
    C, state = fake.new(options)
    local p = assert(windows.new{C = C, fs = {write = function(path, value) files[path] = value; return true end},
      before_spawn = function() collectgarbage() end}.spawn(request))
    for _ = 1, 30 do assert.is_nil(p.poll()) end
    assert.equals(request.stdin_data, state.input)
    options.running = false
    local result = p.poll()
    assert.equals(result, p.poll())
    assert.equals('4321', files.pid)
    assert.equals('0', files.status)
    state.assert_closed()
  end)

  for _, case in ipairs({{'CreateFileW', 2}, {'CreateFileW', 3}, {'CreatePipe', 1}, {'SetHandleInformation', 1}}) do
    it('cleans up partial stream setup after '..case[1]..' failure '..case[2], function()
      local C, state = fake.new{fail = case[1], fail_at = case[2]}
      local request = plan()
      if case[1] ~= 'CreateFileW' then request.capture_stdout = true end
      local p, err = windows.new{C = C}.spawn(request)
      assert.is_nil(p)
      assert.equals(1234, err.win32)
      state.assert_closed()
    end)
  end

  it('rejects invalid process text and environment without leaking prepared handles', function()
    for _, mutate in ipairs({
      function(p) p.executable = '' end,
      function(p) p.executable = '\255' end,
      function(p) p.executable = 'a\0b' end,
      function(p) p.stdin = '\255' end,
      function(p) p.env.VALUE = 'a\0b' end,
    }) do
      local C, state = fake.new()
      local request = plan(); mutate(request)
      local p, err = windows.new{C = C}.spawn(request)
      assert.is_nil(p); assert.is_table(err)
      state.assert_closed()
    end
  end)

  it('reports a failed attribute sizing call and releases open files', function()
    local C, state = fake.new()
    C.InitializeProcThreadAttributeList = function() return 0 end
    local p, err = windows.new{C = C}.spawn(plan())
    assert.is_nil(p); assert.matches('size handle list', err.message, 1, true)
    state.assert_closed()
  end)

  it('returns poll errors for caller cleanup and tolerates an exited stdin reader', function()
    for _, failure in ipairs({'WaitForSingleObject', 'GetExitCodeProcess', 'WriteFile'}) do
      local C, state = fake.new{fail = failure}
      local request = plan()
      if failure == 'WriteFile' then request.stdin_data = 'secret' end
      local p = assert(windows.new{C = C}.spawn(request))
      local result, err = p.poll()
      if failure == 'WriteFile' then assert.equals(0, result.code)
      else assert.is_nil(result); assert.equals(1234, err.win32); p.kill(); p.detach() end
      state.assert_closed()
    end
  end)

  it('retains capture ownership if drainer setup fails and allows cleanup retry', function()
    for _, failure in ipairs({'DuplicateHandle', 'CreateProcessW'}) do
      local options = {running = true, fail = failure, fail_at = failure == 'CreateProcessW' and 3 or 2}
      local C, state = fake.new(options)
      local request = plan(); request.capture_stdout, request.capture_stderr = true, true
      local p = assert(windows.new{C = C}.spawn(request))
      local record, err = p.detach()
      assert.is_nil(record); assert.equals(1234, err.win32)
      assert.is_not_nil(next(state.live))
      options.fail = nil
      assert(p.detach())
      state.assert_closed()
    end
  end)

  it('polls an adopted process to completion and persists the exit code once', function()
    local options = {running = true, code = 4}
    local C, state = fake.new(options)
    local files = {}
    local backend = windows.new{C = C, fs = {write = function(path, value) files[path] = value; return true end}}
    local p = assert(backend.adopt{pid = 42, status_path = 'result'})
    assert.is_nil(p.poll())
    assert.is_true(p.terminate())
    assert.equals(1, state.calls.TerminateProcess)
    options.running = false
    assert.equals(4, p.poll().code)
    assert.equals(4, p.poll().code)
    assert.equals('4', files.result)
    state.assert_closed()
  end)

  it('reports adoption and adopted-poll failures without leaking handles', function()
    for _, failure in ipairs({'OpenProcess', 'WaitForSingleObject', 'GetExitCodeProcess'}) do
      local C, state = fake.new{fail = failure}
      local p, err = windows.new{C = C}.adopt{pid = 42}
      if p then
        local result; result, err = p.poll(); assert.is_nil(result)
        p.detach()
      end
      assert.equals(1234, err.win32)
      state.assert_closed()
    end
    local C = {GetEnvironmentStringsW = function() return ffi.NULL end}
    assert.same({}, windows.inherited(C))
  end)
  it('hands detached completion to an isolated observer holding the actual process handle', function()
    local C, state = fake.new{running = true}
    local request = plan(); request.status_path = 'C:\\state\\exit status'; request.capture_stdout = true
    local backend = windows.new{C = C}
    local process = assert(backend.spawn(request))
    local record = assert(process.detach())
    assert.equal(2, #record.drainers); assert.equal(3, #state.processes)
    local observer = state.processes[2]
    assert.is_truthy(observer.command:find('CrierProcessWatch', 1, true))
    assert.is_truthy(observer.command:find('GetStdHandle(-10)', 1, true))
    assert.is_truthy(observer.command:find('GetExitCodeProcess', 1, true))
    assert.is_truthy(observer.command:find('File]::Move', 1, true))
    assert.is_truthy(observer.environment:find('COBS_STATUS=' .. request.status_path, 1, true))
    assert.is_nil(observer.environment:find('CRIER_', 1, true)); assert.is_nil(observer.environment:find('secret', 1, true))
    assert.equal(3, #observer.inherited)
    assert.is_not_nil(state.duplicates[tostring(observer.stdin)])
    assert.equal(record, process.detach()); assert.equal(3, #state.processes)
    state.assert_closed()
  end)

  it('recovers persisted detached results after the original PID is gone without reopening another process', function()
    for _, code in ipairs({0, 5, 0xc0000005}) do
      local C, state = fake.new{fail = 'OpenProcess'}
      local record = {pid = 42, status_path = 'result'}
      local backend = windows.new{C = C, fs = {read = function() return tostring(code) end}}
      local adopted = assert(backend.adopt(record))
      assert.equal(code, adopted.poll().code); assert.equal(code >= 0x80000000, adopted.poll().crashed)
      assert.is_false(adopted.terminate()); assert.is_false(adopted.kill()); assert.equal(record, adopted.detach())
      assert.is_true(adopted.cancel()); assert.is_true(adopted.close())
      assert.is_nil(state.calls.OpenProcess); state.assert_closed()
    end
  end)

  it('keeps original capture and process ownership when observer launch fails, then retries safely', function()
    local options = {running = true, fail = 'CreateProcessW', fail_at = 2}
    local C, state = fake.new(options)
    local request = plan(); request.status_path = 'status'
    local process = assert(windows.new{C = C}.spawn(request))
    local record, err = process.detach(); assert.is_nil(record); assert.equal(1234, err.win32)
    assert.is_not_nil(next(state.live)); options.fail = nil
    assert(process.detach()); state.assert_closed()
  end)

  it('falls back to live adoption when persisted status is malformed', function()
    for _, value in ipairs({'', 'partial', '-1', '1.5', '4294967296'}) do
      local C, state = fake.new()
      local backend = windows.new{C = C, fs = {read = function() return value end}}
      local adopted = assert(backend.adopt{pid = 42, status_path = 'result'})
      assert.equal(0, adopted.poll().code); state.assert_closed()
    end
  end)

  it('cancels live captured jobs without launching helpers and keeps cancellation idempotent', function()
    local C, state = fake.new{running = true}
    local request = plan(); request.capture_stdout, request.capture_stderr = true, true
    request.stdin_data, request.status_path = 'secret', 'result'
    local files = {}
    local p = assert(windows.new{C = C, fs = {write = function(path, data) files[path] = data end}}.spawn(request))
    assert.is_true(p.cancel()); assert.is_true(p.cancel()); assert.is_true(p.close()); assert.is_true(p.cancelled)
    assert.is_true(p.poll().cancelled); assert.equal('1', files.result)
    assert.equal(1, state.calls.TerminateJobObject); assert.equal(1, #state.processes)
    assert(p.detach()); assert.equal(1, #state.processes); state.assert_closed()
    C, state = fake.new()
    p = assert(windows.new{C = C}.spawn(plan())); assert.equal(0, p.poll().code)
    assert.is_true(p.cancel()); assert.is_nil(state.calls.TerminateJobObject); state.assert_closed()
  end)

  it('preserves native cancellation errors while releasing every handle', function()
    local C, state = fake.new{running = true}
    C.TerminateJobObject = function() state.error = 1234; return 0 end
    local p = assert(windows.new{C = C}.spawn(plan()))
    local ok, err = p.cancel(); assert.is_nil(ok); assert.equal(1234, err.win32); state.assert_closed()
  end)

  it('cancels adopted processes through the job or process handle and never double-closes completion', function()
    for _, named in ipairs({false, true}) do
      local C, state = fake.new{running = true}
      local files = {}
      local p = assert(windows.new{C = C, fs = {read = function() return nil, {kind = 'missing'} end,
        write = function(path, data) files[path] = data end}}.adopt{
        pid = 42, status_path = 'result', job_name = named and 'job' or nil})
      assert.is_true(p.cancel()); assert.is_true(p.cancel()); assert.is_true(p.close())
      assert.is_true(p.poll().cancelled); assert.equal('1', files.result)
      assert.is_true(p.cancelled); p.detach(); state.assert_closed()
      assert.equal(1, state.calls[named and 'TerminateJobObject' or 'TerminateProcess'])
    end
    local C, state = fake.new()
    local p = assert(windows.new{C = C}.adopt{pid = 42})
    assert.equal(0, p.poll().code); assert.is_true(p.cancel()); state.assert_closed()
    C, state = fake.new{running = true}; C.TerminateProcess = function() state.error = 1234; return 0 end
    p = assert(windows.new{C = C}.adopt{pid = 42})
    local ok, err = p.cancel(); assert.is_nil(ok); assert.equal(1234, err.win32); state.assert_closed()
  end)

  it('waits for an inherited-handle observer when the PID disappears before its atomic status write', function()
    local C, state = fake.new{fail = 'OpenProcess'}
    local files, now = {}, 0
    local backend = windows.new{C = C, fs = {read = function(path) return files[path], {kind = 'missing'} end},
      clock = {now_mono = function() return now end}}
    local record = {pid = 42, status_path = 'result', drainers = {{pid = 43, kind = 'observer'}}}
    local p = assert(backend.adopt(record)); assert.is_nil(p.poll()); assert.is_false(p.terminate()); assert.is_false(p.kill())
    files.result = '5'; assert.equal(5, p.poll().code); assert.equal(5, p.poll().code); assert.equal(record, p.detach())
    state.assert_closed()
    files.result = nil; p = assert(backend.adopt(record)); now = 61
    local result, err = p.poll(); assert.is_nil(result); assert.is_truthy(err.message:find('observer', 1, true))
    assert.is_true(p.cancel()); assert.is_true(p.poll().cancelled); assert.is_true(p.close()); state.assert_closed()
  end)

end)
