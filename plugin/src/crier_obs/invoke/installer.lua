local ffi = require("ffi")
local cmdline = require("crier_obs.proc.cmdline_windows")
local M = {}
local function shell(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function ps(s)
	return "'" .. s:gsub("'", "''") .. "'"
end
-- Install crier / Update crier: runs crier's official installer pinned to the registry's crier tag into
-- <state>/bin, removes the macOS quarantine attribute, then waits for the resolver's version check.
-- status() is { state = idle | installing | installed | failed | cancelled, message }.
function M.new(deps)
	local env = deps.env or {}
	local platform = env.os or ffi.os
	local pin = assert(deps.pin, "installer needs the pinned crier version")
	local log = deps.log
	local process, phase, explicit
	local current = { state = "idle", message = "" }
	local self = {}
	local function failed(message, code)
		phase = nil
		current = { state = "failed", message = "Install failed: " .. log.scrub(message), code = code }
		log.error(current.message)
		return current
	end
	local function spawn(plan)
		local p, e = deps.spawner.spawn(plan)
		if not p then
			failed(e.message)
			return nil, e
		end
		process = p
		return p
	end
	-- crier_path is the dialog's explicit crier path: the installer never replaces that binary, so
	-- the version it reports afterwards is that one, not the copy in <state>/bin.
	function self.start(crier_path)
		if process or phase then
			return nil, { kind = "busy", message = "Installation is already running" }
		end
		if not pin:match("^%d+%.%d+%.%d+[%w.%-]*$") then
			return nil, { kind = "version", message = "Invalid installer pin" }
		end
		explicit = crier_path ~= "" and crier_path or nil
		if explicit then
			log.warn(
				"Install crier installs into the crier-obs folder; the crier path set in Advanced still wins: " .. explicit
			)
		end
		local dir = deps.state_dir .. (platform == "Windows" and "\\bin" or "/bin")
		local url = "https://raw.githubusercontent.com/yohimik/crier/v"
			.. pin
			.. "/install."
			.. (platform == "Windows" and "ps1" or "sh")
		local plan = { env = {}, capture_stdout = true, capture_stderr = true, timeout = 300, kind = "installer" }
		if platform == "Windows" then
			plan.executable = cmdline.powershell(env.getenv and env.getenv("SystemRoot"))
			plan.args = {
				"-NoProfile",
				"-NonInteractive",
				"-ExecutionPolicy",
				"Bypass",
				"-Command",
				"& ([scriptblock]::Create((Invoke-RestMethod "
					.. ps(deps.url or url)
					.. "))) -Version "
					.. ps(pin)
					.. " -BinDir "
					.. ps(dir),
			}
		else
			-- curl must succeed before the verified official installer is run; a failed fetch never feeds a partial script to sh.
			local curl = deps.curl_cmd or (platform == "OSX" and "/usr/bin/curl" or "curl")
			plan.executable = "/bin/sh"
			plan.args = {
				"-c",
				"script=$("
					.. shell(curl)
					.. " -fsSL "
					.. shell(deps.url or url)
					.. ") || exit $?; CRIER_VERSION="
					.. shell(pin)
					.. " CRIER_BIN_DIR="
					.. shell(dir)
					.. ' /bin/sh -c "$script"',
			}
		end
		current = { state = "installing", message = "Installing crier " .. pin .. "…" }
		log.info("Installing crier " .. pin .. " into " .. dir)
		phase = "install"
		return spawn(plan)
	end
	local function verify()
		local p, pe = deps.resolver.probe(explicit)
		if not p then
			return failed(pe.message)
		end
		phase = "version"
		current.message = "Checking installed crier…"
		log.info("Checking the installed crier")
		return current
	end
	function self.tick()
		if phase == "version" then
			local status = deps.resolver.status()
			if status.state ~= "checking" then
				phase = nil
				if status.state == "ready" then
					current = { state = "installed", message = status.message }
					log.info("crier installed: " .. status.message)
				else
					failed(status.message)
				end
			end
			return current
		end
		if not process then
			return current
		end
		local r, e = process.poll()
		if e then
			local broken = process
			process = nil
			broken.cancel()
			return failed(e.message or tostring(e)), e
		end
		if not r then
			return current
		end
		process = nil
		if phase == "install" then
			if r.code ~= 0 or r.timed_out then
				return failed(
					r.timed_out and "Installation timed out" or (r.stderr ~= "" and r.stderr or "Installation failed"),
					r.code
				)
			end
			if platform == "OSX" then
				phase = "quarantine"
				log.info("Removing the macOS quarantine attribute from the installed crier")
				process = deps.spawner.spawn({
					executable = "/usr/bin/xattr",
					args = { "-d", "com.apple.quarantine", deps.state_dir .. "/bin/crier" },
					env = {},
					capture_stdout = true,
					capture_stderr = true,
					timeout = 15,
					kind = "installer",
				})
				if process then
					return current
				end
			end
		end
		-- A missing quarantine attribute makes xattr fail; that is the normal case.
		return verify()
	end
	function self.status()
		return current
	end
	function self.detach()
		local interrupted = process or phase
		local record
		if process then
			record = process.cancel()
			process = nil
		end
		phase = nil
		if interrupted then
			current = { state = "cancelled", message = "Installation cancelled because the script unloaded" }
		end
		return record
	end
	return self
end
return M
