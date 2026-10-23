#!/usr/bin/env luajit
-- A process fixture: fake backing records live outside the plugin state tree.
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function unhex(s) return (s:gsub('..', function(c) return string.char(tonumber(c, 16)) end)) end
if os.getenv('FAKE_KEYRING_SLEEP') then
  local ffi = require('ffi'); ffi.cdef('int usleep(unsigned int);'); ffi.C.usleep(2000000)
end
local command, account, value = arg[1]
if command == '-i' then
  local input = io.read('*a')
  account = input:match('%-a "([^"]+)"')
  value = unhex(input:match('%-X ([%x]+)') or '')
  command = 'store'
elseif command == 'find-generic-password' or command == 'delete-generic-password' then
  for i = 2, #arg do if arg[i] == '-a' then account = arg[i + 1] end end
  command = command == 'find-generic-password' and 'lookup' or 'clear'
else
  for i = 2, #arg do if arg[i] == 'account' then account = arg[i + 1] end end
  if command == 'store' then value = io.read('*a') end
end
if os.getenv('FAKE_KEYRING_LOCKED') then io.stderr:write('Keychain locked\n'); os.exit(36) end
local path = os.getenv('FAKE_KEYRING_DIR') .. '/' .. hex(account or '')
if command == 'store' then
  local f = assert(io.open(path, 'wb')); f:write(value); f:close()
elseif command == 'lookup' then
  local f = io.open(path, 'rb'); if not f then os.exit(44) end
  local data = f:read('*a'); f:close()
  if not os.getenv('FAKE_KEYRING_EMPTY') then io.write(data, '\n') end
elseif command == 'clear' then os.remove(path)
else os.exit(1) end
