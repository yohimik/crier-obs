local json = require('crier_obs.json')
local b64 = require('crier_obs.secrets.base64')
local crypto = require('crier_obs.secrets.chacha20poly1305')
local M = {}
function M.record_path(dir, account)
  return dir .. '/' .. account:gsub('.', function(c) return string.format('%02x', c:byte()) end) .. '.json'
end
function M.new(deps)
  local fs, dir = assert(deps.fs), assert(deps.state_dir) .. '/secrets'
  local key, self = nil, {name = 'file'}
  local function master(create)
    if key then return key end
    local ok, err = fs.mkdir_private(dir); if not ok then return nil, err end
    local path = dir .. '/key'
    if fs.exists(path) then
      local encoded; encoded, err = fs.read(path)
      if not encoded then return nil, err end
      key = b64.decode(encoded)
      if not key or #key ~= 32 then key = nil; return nil, {kind = 'credential', message = 'Credential key is missing or corrupted'} end
      return key
    end
    if not create then return nil, {kind = 'missing', message = 'Credential not stored'} end
    local fresh; fresh, err = fs.random_bytes(32); if not fresh then return nil, err end
    if not fs.create_private then return nil, {kind = 'filesystem', message = 'Exclusive private key creation is unavailable'} end
    ok, err = fs.create_private(path, b64.encode(fresh))
    if not ok then
      if fs.exists(path) then return master(false) end
      return nil, err
    end
    key = fresh
    return key
  end
  function self.store(account, value, callback)
    local k, err = master(true); if not k then callback(nil, err); return end
    local nonce; nonce, err = fs.random_bytes(12); if not nonce then callback(nil, err); return end
    local ct, tag = crypto.encrypt(k, nonce, value, account)
    local record = json.encode{nonce = b64.encode(nonce), ct = b64.encode(ct), tag = b64.encode(tag)}
    local ok; ok, err = fs.write_private(M.record_path(dir, account), record)
    callback(ok, err)
  end
  function self.lookup(account, callback)
    local path = M.record_path(dir, account)
    if not fs.exists(path) then callback(nil, {kind = 'missing', message = 'Credential not stored'}); return end
    local k, err = master(false); if not k then callback(nil, err); return end
    local data; data, err = fs.read(path); if not data then callback(nil, err); return end
    local record = json.decode(data)
    if type(record) ~= 'table' then callback(nil, {kind = 'credential', message = 'Credential missing or corrupted'}); return end
    local nonce, ct, tag = b64.decode(record.nonce), b64.decode(record.ct), b64.decode(record.tag)
    if not nonce or not ct or not tag then callback(nil, {kind = 'credential', message = 'Credential missing or corrupted'}); return end
    local value; value, err = crypto.decrypt(k, nonce, ct, tag, account)
    if value == '' then value, err = nil, {kind = 'missing', message = 'Credential not stored'} end
    callback(value, err)
  end
  function self.forget(account, callback)
    local path = M.record_path(dir, account)
    if not fs.exists(path) then callback(true); return end
    local ok, err = fs.remove(path); callback(ok, err or (not ok and {kind = 'filesystem', message = 'Cannot forget credential'} or nil))
  end
  function self.tick() end
  return self
end
return M
