-- An owned-reference OBS model. Borrowed callbacks do not change refcounts.
local json = require("crier_obs.json")
local ffi = require("ffi")
ffi.cdef(
  "int mkdir(const char*, unsigned int); int unlink(const char*); int rmdir(const char*); int rename(const char*,const char*);"
)
local M = {}
local refs = {}
local timers, pending, events = {}, {}, {}
local mono = 0
M.logs = {}
M.streaming = false
M.recording = false
M.replay_active = false
M.last_replay = ""
M.last_recording = ""
M.locale = "en-US"
M.scene_name = "Scene"
M.profile_name = "Profile"
M.collection_name = "Collection"
M.active_fps = 60
M.stream_frames = 0
M.tmp_root = "/tmp/crier-obs-stub/"
-- Timers run on OBS's graphics thread; the frontend getters below read Qt UI state and may only be
-- called from the UI thread (frontend events, script_update, buttons).
M.graphics_thread = false
local function ui_thread(name)
  assert(not M.graphics_thread, name .. " called from the graphics thread")
end
local constants = {
  "OBS_TEXT_DEFAULT",
  "OBS_TEXT_MULTILINE",
  "OBS_TEXT_PASSWORD",
  "OBS_TEXT_INFO",
  "OBS_TEXT_INFO_NORMAL",
  "OBS_TEXT_INFO_WARNING",
  "OBS_TEXT_INFO_ERROR",
  "OBS_PATH_FILE",
  "OBS_PATH_DIRECTORY",
  "OBS_COMBO_TYPE_LIST",
  "OBS_COMBO_FORMAT_STRING",
  "OBS_EDITABLE_LIST_TYPE_STRINGS",
  "OBS_GROUP_NORMAL",
  "OBS_BUTTON_DEFAULT",
  "OBS_BUTTON_URL",
  "OBS_GROUP_CHECKABLE",
  "OBS_FRONTEND_EVENT_STREAMING_STARTING",
  "OBS_FRONTEND_EVENT_STREAMING_STARTED",
  "OBS_FRONTEND_EVENT_STREAMING_STOPPING",
  "OBS_FRONTEND_EVENT_STREAMING_STOPPED",
  "OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN",
  "OBS_FRONTEND_EVENT_EXIT",
  "OBS_FRONTEND_EVENT_RECORDING_STARTED",
  "OBS_FRONTEND_EVENT_RECORDING_STOPPED",
  "OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED",
  "OBS_FRONTEND_EVENT_FINISHED_LOADING",
  "OBS_FRONTEND_EVENT_SCENE_CHANGED",
  "OBS_FRONTEND_EVENT_PROFILE_CHANGED",
  "OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING",
  "OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED",
  "OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP",
  "LOG_DEBUG",
  "LOG_INFO",
  "LOG_WARNING",
  "LOG_ERROR",
}
for i, name in ipairs(constants) do
  M[name] = i
end
local function object(kind, values)
  local o = { kind = kind, values = values or {}, defaults = {}, refs = 1 }
  refs[o] = true
  return o
end
local function addref(o)
  assert(o and o.refs > 0, "addref on released object")
  o.refs = o.refs + 1
end
local function release(o)
  assert(o and o.refs > 0, "double release")
  o.refs = o.refs - 1
  if o.refs == 0 then
    refs[o] = nil
  end
end
local function clone(v)
  if type(v) ~= "table" or v == json.null then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = clone(x)
  end
  if getmetatable(v) then
    setmetatable(out, getmetatable(v))
  end
  return out
end
function M.obs_data_create()
  return object("data")
end
function M.obs_data_create_from_json(s)
  local v = assert(json.decode(s))
  return object("data", v)
end
M.obs_data_addref = addref
M.obs_data_release = release
function M.obs_data_has_user_value(o, k)
  return o.values[k] ~= nil
end
function M.obs_data_unset_user_value(o, k)
  o.values[k] = nil
end
local function get(o, k, zero)
  local v = o.values[k]
  if v == nil then
    v = o.defaults[k]
  end
  if v == nil then
    return zero
  end
  return v
end
for _, kind in ipairs({ "string", "bool", "int", "double" }) do
  local zero = kind == "string" and "" or (kind == "bool" and false or 0)
  M["obs_data_get_" .. kind] = function(o, k)
    return get(o, k, zero)
  end
  M["obs_data_set_" .. kind] = function(o, k, v)
    o.values[k] = v
  end
  M["obs_data_set_default_" .. kind] = function(o, k, v)
    o.defaults[k] = v
  end
end
function M.obs_data_get_json(o)
  return assert(json.encode(o.values))
end
function M.obs_data_get_defaults(o)
  return object("data", clone(o.defaults))
end
function M.obs_data_set_obj(o, k, v)
  o.values[k] = clone(v.values)
end
function M.obs_data_get_obj(o, k)
  local v = get(o, k, nil)
  if not v then
    return nil
  end
  return object("data", clone(v))
end
function M.obs_data_array_create()
  return object("array", json.array())
end
M.obs_data_array_release = release
M.obs_data_array_addref = addref
function M.obs_data_array_count(a)
  return #a.values
end
function M.obs_data_array_item(a, i)
  return object("data", clone(a.values[i + 1]))
end
function M.obs_data_array_push_back(a, o)
  a.values[#a.values + 1] = clone(o.values)
end
function M.obs_data_set_array(o, k, a)
  o.values[k] = clone(a.values)
end
function M.obs_data_set_default_array(o, k, a)
  o.defaults[k] = clone(a.values)
end
function M.obs_data_get_array(o, k)
  return object("array", clone(get(o, k, {})))
end
function M.obs_properties_create()
  return { ordered = {}, by_name = {} }
end
function M.obs_properties_destroy() end
-- libobs looks names up through nested groups, and a name is unique across the whole tree.
local function root_of(ps)
  while ps.parent do
    ps = ps.parent
  end
  return ps
end
local function lookup(ps, name)
  if ps.by_name[name] then
    return ps.by_name[name], ps
  end
  for _, p in ipairs(ps.ordered) do
    if p.content then
      local found, owner = lookup(p.content, name)
      if found then
        return found, owner
      end
    end
  end
end
local function prop(ps, kind, name, label, ...)
  assert(not lookup(root_of(ps), name), "duplicate property " .. name)
  local p = { kind = kind, name = name, label = label, visible = true, args = { ... } }
  ps.by_name[name] = p
  ps.ordered[#ps.ordered + 1] = p
  -- The lookup table lists every property, nested ones too, for specs that address them by name.
  local root = root_of(ps)
  if root ~= ps then
    root.by_name[name] = p
  end
  return p
end
for _, kind in ipairs({ "bool", "int", "float", "text", "path", "list", "editable_list" }) do
  M["obs_properties_add_" .. kind] = function(ps, name, label, ...)
    return prop(ps, kind, name, label, ...)
  end
end
function M.obs_properties_add_group(ps, name, label, group_type, content)
  assert(content and content.ordered and not content.parent, "group content must be a fresh properties object")
  local p = prop(ps, "group", name, label, group_type)
  p.content = content
  content.parent = ps
  for child_name, child in pairs(content.by_name) do
    assert(not root_of(ps).by_name[child_name] or root_of(ps).by_name[child_name] == child, "duplicate property " .. child_name)
    root_of(ps).by_name[child_name] = child
  end
  return p
end
function M.obs_property_group_content(p)
  return p.content
end
function M.obs_properties_add_button(ps, name, label, callback)
  if type(callback) ~= "function" then
    return nil
  end
  local p = prop(ps, "button", name, label)
  p.callback = callback
  return p
end
function M.obs_properties_add_button2(ps, name, label, callback, private)
  local p = M.obs_properties_add_button(ps, name, label, callback)
  p.private = private
  return p
end
function M.obs_properties_remove_by_name(ps, name)
  local p, owner = lookup(ps, name)
  if not p then
    return
  end
  owner.by_name[name] = nil
  root_of(ps).by_name[name] = nil
  for i = #owner.ordered, 1, -1 do
    if owner.ordered[i] == p then
      table.remove(owner.ordered, i)
    end
  end
end
function M.obs_properties_get(ps, name)
  return (lookup(ps, name))
end
-- Mirrors OBSPropertiesView::AddText for OBS_TEXT_INFO: the right-hand text is the settings value,
-- or the long description when there is no value; with neither, the description spans the row.
function M.render_info(p, settings)
  assert(p.kind == "text" and p.args[1] == M.OBS_TEXT_INFO, "not an info row: " .. tostring(p.name))
  local value = settings and M.obs_data_get_string(settings, p.name) or ""
  if value == "" and p.description == nil then
    return nil, p.label
  end
  return p.label, value ~= "" and value or p.description
end
function M.obs_properties_first(ps)
  return ps.ordered[1]
end
function M.obs_property_set_visible(p, v)
  p.visible = v
end
function M.obs_property_set_enabled(p, v)
  p.enabled = v
end
function M.obs_property_set_long_description(p, s)
  p.description = s
end
function M.obs_property_set_description(p, s)
  p.label = s
end
function M.obs_property_set_modified_callback(p, f)
  p.modified = f
end
function M.obs_property_set_modified_callback2(p, f, private)
  p.modified = f
  p.private = private
end
function M.obs_property_list_add_string(p, label, value)
  p.items = p.items or {}
  p.items[#p.items + 1] = { label = label, value = value }
  return #p.items - 1
end
function M.obs_property_list_clear(p)
  p.items = {}
end
function M.obs_property_text_set_info_type(p, t)
  p.info_type = t
end
function M.obs_property_text_set_info_word_wrap(p, v)
  p.word_wrap = v
end
function M.obs_property_button_set_type(p, t)
  p.button_type = t
end
function M.obs_property_button_set_url(p, u)
  p.url = u
end
function M.timer_add(fn, ms)
  if ms > 0 then
    pending[#pending + 1] = { fn = fn, ms = ms, next = mono + ms / 1000 }
  end
end
function M.timer_remove(fn)
  timers[fn] = nil
  for i = #pending, 1, -1 do
    if pending[i].fn == fn then
      table.remove(pending, i)
    end
  end
end
function M.remove_current_callback()
  if M.current_timer then
    M.timer_remove(M.current_timer)
  end
end
function M.advance(seconds)
  mono = mono + seconds
  for _, t in ipairs(pending) do
    timers[t.fn] = t
  end
  pending = {}
  local due = {}
  for _, t in pairs(timers) do
    due[#due + 1] = t
  end
  for _, t in ipairs(due) do
    local count = 0
    while timers[t.fn] and t.next <= mono and count < 10000 do
      t.next = t.next + t.ms / 1000
      count = count + 1
      M.current_timer = t.fn
      M.graphics_thread = true
      local ok, err = pcall(t.fn)
      M.graphics_thread = false
      M.current_timer = nil
      assert(ok, err)
    end
  end
end
function M.timer_count()
  local n = #pending
  for _ in pairs(timers) do
    n = n + 1
  end
  return n
end
function M.os_gettime_ns()
  return mono * 1e9
end
function M.obs_frontend_add_event_callback(fn)
  events[fn] = true
end
function M.obs_frontend_remove_event_callback(fn)
  events[fn] = nil
end
function M.emit(e)
  if e == M.OBS_FRONTEND_EVENT_STREAMING_STARTED then
    M.streaming = true
  end
  if e == M.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
    M.streaming = false
  end
  if e == M.OBS_FRONTEND_EVENT_RECORDING_STARTED then
    M.recording = true
  end
  if e == M.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
    M.recording = false
  end
  local list = {}
  for fn in pairs(events) do
    list[#list + 1] = fn
  end
  for _, fn in ipairs(list) do
    fn(e)
  end
end
function M.obs_frontend_streaming_active()
  return M.streaming
end
function M.obs_frontend_recording_active()
  return M.recording
end
function M.obs_frontend_replay_buffer_active()
  return M.replay_active
end
function M.obs_frontend_get_last_replay()
  ui_thread("obs_frontend_get_last_replay")
  return M.last_replay
end
function M.obs_frontend_get_last_recording()
  ui_thread("obs_frontend_get_last_recording")
  return M.last_recording
end
function M.obs_frontend_get_current_profile()
  ui_thread("obs_frontend_get_current_profile")
  return M.profile_name
end
function M.obs_frontend_get_current_scene_collection()
  ui_thread("obs_frontend_get_current_scene_collection")
  return M.collection_name
end
function M.obs_frontend_get_current_scene()
  ui_thread("obs_frontend_get_current_scene")
  return object("source", { name = M.scene_name })
end
function M.obs_source_get_name(o)
  return o.values.name
end
M.obs_source_release = release
function M.obs_frontend_get_streaming_output()
  return object("output", { frames = M.stream_frames })
end
function M.obs_get_active_fps()
  return M.active_fps
end
M.obs_output_release = release
function M.obs_output_get_total_frames(o)
  return o.values.frames
end
function M.obs_frontend_get_streaming_service()
  ui_thread("obs_frontend_get_streaming_service")
  M.service = M.service or { values = { server = "rtmp://example.test", key = "NEVER INCLUDE STREAM KEY" } }
  return M.service
end
function M.obs_service_get_settings(o)
  return object("data", clone(o.values))
end
function M.obs_get_version_string()
  return "32.2.2"
end
function M.obs_get_locale()
  return M.locale
end
function M.script_log(level, text)
  M.logs[#M.logs + 1] = { level = level, text = text }
end
local function wide(text)
  local encoded = assert(require("crier_obs.utf16").encode(text))
  local buffer = ffi.new("uint16_t[?]", #encoded / 2 + 1)
  ffi.copy(buffer, encoded, #encoded)
  return buffer
end
if ffi.os == "Windows" then
  ffi.cdef([[uint32_t __stdcall GetFileAttributesW(const uint16_t*);
    int __stdcall CreateDirectoryW(const uint16_t*,void*);
    int __stdcall DeleteFileW(const uint16_t*); int __stdcall RemoveDirectoryW(const uint16_t*);
    int __stdcall MoveFileExW(const uint16_t*,const uint16_t*,uint32_t);
    uint32_t __stdcall GetLastError(void);
    void* __stdcall CreateFileW(const uint16_t*,uint32_t,uint32_t,void*,uint32_t,uint32_t,void*);
    int __stdcall CloseHandle(void*);
    int __stdcall ReadFile(void*,void*,uint32_t,uint32_t*,void*);
    int __stdcall WriteFile(void*,const void*,uint32_t,uint32_t*,void*);]])
end
function M.os_file_exists(path)
  if ffi.os == "Windows" then
    return ffi.C.GetFileAttributesW(wide(path)) ~= 0xFFFFFFFF
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end
function M.os_quick_read_utf8_file(path)
  if ffi.os == "Windows" then
    local file = ffi.C.CreateFileW(wide(path), 0x80000000, 7, nil, 3, 0x80, nil)
    if file == ffi.cast("void*", -1) then
      return nil
    end
    local buffer, count = ffi.new("uint8_t[65536]"), ffi.new("uint32_t[1]")
    local chunks = {}
    while true do
      if ffi.C.ReadFile(file, buffer, 65536, count, nil) == 0 then
        ffi.C.CloseHandle(file)
        return nil
      end
      if count[0] == 0 then
        break
      end
      chunks[#chunks + 1] = ffi.string(buffer, count[0])
    end
    ffi.C.CloseHandle(file)
    return table.concat(chunks)
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end
function M.os_quick_write_utf8_file(path, data, len)
  if ffi.os == "Windows" then
    local file = ffi.C.CreateFileW(wide(path), 0x40000000, 7, nil, 2, 0x80, nil)
    if file == ffi.cast("void*", -1) then
      return false
    end
    local written = ffi.new("uint32_t[1]")
    local ok = ffi.C.WriteFile(file, data, len, written, nil) ~= 0 and tonumber(written[0]) == len
    ffi.C.CloseHandle(file)
    return ok
  end
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  local ok = f:write(data:sub(1, len))
  f:close()
  return ok ~= nil
end
-- libobs writes <path>.<temp_ext>, then os_safe_replace keeps the previous file as <path>.<backup_ext>
-- when a backup extension is given.
function M.os_quick_write_utf8_file_safe(path, data, len, _, temp_ext, backup_ext)
  assert(temp_ext and temp_ext ~= "", "os_quick_write_utf8_file_safe needs a temporary extension")
  local tmp = path .. "." .. temp_ext
  if not M.os_quick_write_utf8_file(tmp, data, len) then
    return false
  end
  if backup_ext and backup_ext ~= "" and M.os_file_exists(path) then
    local backup = path .. "." .. backup_ext
    if M.os_file_exists(backup) then
      M.os_unlink(backup)
    end
    if M.os_rename(path, backup) ~= 0 then
      return false
    end
  end
  return M.os_rename(tmp, path) == 0
end
function M.os_mkdirs(path)
  if ffi.os == "Windows" then
    local normalized = path:gsub("\\", "/")
    local drive = normalized:match("^%a:/")
    local current = drive or ""
    if drive then
      normalized = normalized:sub(4)
    end
    for part in normalized:gmatch("[^/]+") do
      current = current .. part .. "/"
      if ffi.C.CreateDirectoryW(wide(current), nil) == 0 and ffi.C.GetLastError() ~= 183 then
        return -1
      end
    end
    return 0
  end
  local current = path:sub(1, 1) == "/" and "/" or ""
  for part in path:gmatch("[^/]+") do
    current = current .. part .. "/"
    local rc = ffi.C.mkdir(current, 448)
    if rc ~= 0 and ffi.errno() ~= 17 then
      return -1
    end
  end
  return 0
end
function M.os_unlink(path)
  if ffi.os == "Windows" then
    return ffi.C.DeleteFileW(wide(path)) ~= 0 and 0 or -1
  end
  return ffi.C.unlink(path)
end
function M.os_rmdir(path)
  if ffi.os == "Windows" then
    return ffi.C.RemoveDirectoryW(wide(path)) ~= 0 and 0 or -1
  end
  return ffi.C.rmdir(path)
end
function M.os_rename(a, b)
  if ffi.os == "Windows" then
    return ffi.C.MoveFileExW(wide(a), wide(b), 1) ~= 0 and 0 or -1
  end
  return ffi.C.rename(a, b)
end
function M.os_get_config_path_ptr(s)
  return M.tmp_root .. (s or "")
end
function M.os_get_abs_path_ptr(s)
  if s:sub(1, 1) == "/" then
    return s
  end
  return (os.getenv("PWD") or ".") .. "/" .. s
end
function M.assert_no_leaks()
  local kinds = {}
  for o in pairs(refs) do
    kinds[#kinds + 1] = o.kind .. ":" .. o.refs
  end
  assert(#kinds == 0, "OBS reference leaks: " .. table.concat(kinds, ","))
end
-- Drops the reference table after a leak has been reported, so one failing spec does not fail the rest.
function M.forget_references()
  refs = {}
end
function M.reset()
  M.assert_no_leaks()
  timers = {}
  pending = {}
  events = {}
  mono = 0
  M.logs = {}
  M.streaming = false
  M.recording = false
  M.replay_active = false
  M.graphics_thread = false
  M.stream_frames = 0
end
function M.lifecycle(script, settings)
  script.script_defaults(settings)
  script.script_load(settings)
  script.script_update(settings)
end
-- The real module has no field for a name it does not export. Reading an OBS-shaped name that obslua
-- lacks fails here, so a misspelt API call cannot pass under the stub while it is nil inside OBS.
local exports = require("stub.obslua_exports")
local api = { "^obs_", "^os_", "^OBS_", "^LOG_", "^timer_", "^script_log$", "^remove_current_callback$", "^gs_" }
setmetatable(M, {
  __index = function(_, name)
    if type(name) == "string" and not exports[name] then
      for _, pattern in ipairs(api) do
        if name:match(pattern) then
          assert(false, "obslua does not export " .. name)
        end
      end
    end
    return nil
  end,
})
return M
