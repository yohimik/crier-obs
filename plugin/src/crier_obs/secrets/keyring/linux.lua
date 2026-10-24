local cli = require("crier_obs.secrets.keyring.cli")
local i18n = require("crier_obs.i18n")
local M = {}
-- posix_spawnp would look a bare secret-tool up on OBS's own PATH, which lacks the shell-profile and
-- Homebrew directories when OBS starts from a desktop launcher. The resolver's find_binary searches
-- the augmented PATH that crier and ffmpeg discovery use, and the spawn gets the absolute path it
-- returns. In Flatpak the host runs the command, so the name stays bare and the host resolves it;
-- the sandbox's own files say nothing about what the host has installed.
local function locate(deps)
	if deps.secret_tool_bin then
		return deps.secret_tool_bin
	end
	local env = deps.env or {}
	if env.flatpak and env.flatpak() then
		return "secret-tool"
	end
	return deps.find_binary and deps.find_binary("secret-tool") or nil
end
function M.new(deps)
	local commands = cli.new(deps)
	local executable = locate(deps)
	local self = { name = "linux", tick = commands.tick, close = commands.close, executable = executable }
	if not executable then
		-- The credential service checks this before its Secret Service probe and uses the file store.
		self.missing = i18n.with({ kind = "unavailable" }, "keyring_secret_tool_missing")
	end
	local function run(args, input, callback)
		if not executable then
			callback(nil, self.missing)
			return
		end
		commands.run(executable, args, input, callback)
	end
	function self.store(account, value, callback)
		run({ "store", "--label=crier-obs", "service", "crier-obs", "account", account }, value, function(result, err)
			local failure = cli.failure(result, err)
			callback(not failure, failure)
		end)
	end
	function self.lookup(account, callback)
		run({ "lookup", "service", "crier-obs", "account", account }, nil, function(result, err)
			local failure = cli.failure(result, err, 1)
			if failure then
				callback(nil, failure)
				return
			end
			local value = (result.stdout or ""):gsub("\r?\n$", "")
			if value == "" then
				callback(nil, { kind = "missing", message = "Credential not stored" })
				return
			end
			callback(value)
		end)
	end
	-- secret-tool has no presence query that withholds the secret, so the value is read and dropped.
	function self.exists(account, callback)
		self.lookup(account, function(value, err)
			callback(value and true or nil, err)
		end)
	end
	function self.forget(account, callback)
		run({ "clear", "service", "crier-obs", "account", account }, nil, function(result, err)
			local failure = cli.failure(result, err, 1)
			if failure and failure.kind == "missing" then
				failure = nil
			end
			callback(not failure, failure)
		end)
	end
	return self
end
return M
