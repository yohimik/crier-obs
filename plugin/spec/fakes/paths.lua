-- Absolute paths of the spec fakes, found from this file's own location, so the specs pass whatever
-- the package folder is called and wherever busted runs from. Spawned children get absolute paths,
-- since crier and the installer run in a working directory of their own.
local ffi = require("ffi")
ffi.cdef("char *getcwd(char*,unsigned long);")
local source = debug.getinfo(1, "S").source:sub(2)
local dir = source:match("^(.*)[/\\][^/\\]+$") or "."
if not (dir:match("^[/\\]") or dir:match("^%a:[/\\]")) then
	local cwd = ffi.os == "Windows" and "." or ffi.string(ffi.C.getcwd(ffi.new("char[4096]"), 4096))
	dir = cwd .. "/" .. dir
end
return { dir = dir, crier = dir .. "/crier" }
