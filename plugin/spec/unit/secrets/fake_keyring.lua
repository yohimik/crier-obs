#!/usr/bin/env luajit
-- A process fixture: fake backing records live outside the plugin state tree.
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function unhex(s) return (s:gsub('..', function(c) return string.char(tonumber(c, 16)) end)) end
if os.getenv('FAKE_KEYRING_SLEEP') then
  local ffi = require('ffi'); ffi.cdef('int usleep(unsigned int);'); ffi.C.usleep(2000000)
end
local command, account, value = arg[1]
-- The two CLIs report a missing item differently: security exits 44, secret-tool exits 1.
local tool = (os.getenv('FAKE_KEYRING_TOOL') or arg[0]):match('secret%-tool') and 'secret-tool' or 'security'
local missing = tool == 'security' and 44 or 1
local show_password = tool == 'secret-tool'
if command == '-i' then
  local input = io.read('*a')
  account = input:match('%-a "([^"]+)"')
  value = unhex(input:match('%-X ([%x]+)') or '')
  command = 'store'
elseif command == 'find-generic-password' or command == 'delete-generic-password' then
  for i = 2, #arg do
    if arg[i] == '-a' then account = arg[i + 1] end
    if arg[i] == '-w' then show_password = true end
  end
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
  local f = io.open(path, 'rb'); if not f then os.exit(missing) end
  local data = f:read('*a'); f:close()
  -- Without -w, security prints the item's attributes, never the password.
  if not show_password then io.write('keychain: "fake"\nattributes:\n    "acct"<blob>="', account, '"\n')
  elseif not os.getenv('FAKE_KEYRING_EMPTY') then io.write(data, '\n') end
elseif command == 'clear' then
  if not os.remove(path) then os.exit(missing) end
else os.exit(1) end
