local json = require("crier_obs.json")
local plans = require("crier_obs.invoke.plan")
local base = require("crier_obs.invoke.base")
local M = {}
-- Check setup: the crier binary, the credential store, staging, optional tools, then `crier platforms
-- --json` (plain environment: what each ticked platform is missing besides its credentials) and
-- `crier ping --json` (credentials in the environment). rows() is what the dialog shows.
function M.new(deps)
	local self = {}
	local log = deps.log
	local jobs = {}
	local rows = {}
	local pending = false
	local generation = 0
	local check_run
	local complete = false
	local cleanup_records = {}
	local secret_keys = {}
	for _, d in ipairs(require("crier_obs.registry.keys")) do
		if d.secret then
			secret_keys[#secret_keys + 1] = d.key
		end
	end
	local function scrub(s)
		return log.scrub(s or "")
	end
	-- platforms runs without credentials, so a problem naming a credential key is expected there;
	-- ping reports on the credentials themselves.
	local function about_credentials(problem)
		for _, key in ipairs(secret_keys) do
			if problem:find(key, 1, true) then
				return true
			end
		end
		return false
	end
	local function add(executable, args, values, kind)
		local p, e = deps.spawner.spawn(plans.with_secrets({
			executable = executable,
			args = args,
			env = {},
			capture_stdout = true,
			capture_stderr = true,
			timeout = 60,
			kind = kind,
		}, values, log))
		if p then
			jobs[#jobs + 1] = { process = p, kind = kind }
		else
			rows[#rows + 1] = { target = kind, ok = false, error = scrub(e.message) }
		end
	end
	function self.start(model, executable, plan)
		if pending or #jobs > 0 then
			return false
		end
		generation = generation + 1
		local request = generation
		pending = true
		complete = false
		cleanup_records = {}
		check_run = plan.run
		rows = {
			{ target = "crier", ok = true, message = executable },
			{ target = "keyring", warning = true, message = "checking…" },
			{
				target = "stage",
				ok = model.values["stage.mode"] == "none",
				warning = model.values["stage.mode"] ~= "none",
				message = model.values["stage.mode"] == "none" and "Staging is not enabled" or "checking…",
			},
		}
		jobs = {}
		local sandbox = deps.env.sandbox_status(deps.fs)
		if sandbox.kind ~= "native" then
			rows[#rows + 1] =
				{ target = sandbox.kind, ok = sandbox.ok, warning = sandbox.ok, message = scrub(sandbox.message) }
		end
		for _, item in ipairs({
			{
				enabled = model.values["render.video.enabled"],
				key = "render.video.ffmpeg-bin",
				target = "ffmpeg",
				default = "ffmpeg",
			},
			{
				enabled = model.values["stage.server.tunnel.mode"] ~= "none",
				key = "stage.server.tunnel.bin",
				target = "tunnel",
				default = model.values["stage.server.tunnel.mode"],
			},
		}) do
			if item.enabled then
				local binary = model.values[item.key]
				if not binary or binary == "" then
					binary = item.default
				end
				local found = deps.find_binary(binary)
				rows[#rows + 1] =
					{ target = item.target, ok = found ~= nil, message = found or ("Cannot find " .. tostring(binary)) }
			end
		end
		-- Config and explicit enables match the snapshot checked by this request.
		for path, data in pairs(plan.files or {}) do
			local ok, e = deps.fs.write(path, data)
			if not ok then
				rows[#rows + 1] = { target = "config", ok = false, error = scrub(e.message) }
				pending = false
				return nil, e
			end
		end
		local verified_base
		local function probe_credentials()
			local function with(command)
				local out = { command, "--json" }
				for _, arg in ipairs(plan.args) do
					out[#out + 1] = arg
				end
				return out
			end
			add(executable, with("platforms"), {}, "platforms")
			deps.secrets.resolve(model.credential_set, plan.needs_secrets, function(values, e)
				if request ~= generation then
					return
				end
				local backend = deps.secrets.backend_status()
				rows[2] = {
					target = "keyring",
					ok = not e and backend.state == "ready",
					warning = backend.state == "checking",
					message = backend.label,
					error = e and scrub(e.message),
				}
				if e then
					rows[#rows + 1] = { target = "keyring", ok = false, error = scrub(e.message) }
				else
					if verified_base then
						local current, read_error = base.fingerprint(deps.fs, plan.base_config)
						if current ~= verified_base then
							rows[#rows + 1] = {
								target = "config",
								ok = false,
								error = scrub(
									read_error and read_error.message
										or "Base configuration changed while it was being checked"
								),
							}
							pending = false
							return
						end
					end
					add(executable, with("ping"), values or {}, "ping")
				end
				pending = false
			end)
		end
		if plan.base_config then
			local inspection, e = base.inspect(deps.spawner, deps.fs, plan)
			if not inspection then
				rows[#rows + 1] = { target = "config", ok = false, error = scrub(e.message) }
				pending = false
				return true
			end
			verified_base = inspection.fingerprint
			jobs[#jobs + 1] = {
				inspection = inspection,
				process = inspection.process,
				kind = "base_config",
				plan = plan,
				after = probe_credentials,
			}
		else
			probe_credentials()
		end
		return true
	end
	local function cancel(process)
		local record = process.cancel()
		if type(record) == "table" and record.pid and record.code == nil and check_run then
			cleanup_records[#cleanup_records + 1] = record
			local ok, e = deps.runs.journal(check_run, { state = "failed", drainers = cleanup_records })
			if not ok and e then
				log.warn("Cannot save setup cleanup: " .. scrub(e.message))
			end
		end
	end
	local function platform_rows(data)
		for _, row in ipairs(type(data) == "table" and data or {}) do
			local problem = type(row) == "table" and type(row.problem) == "string" and row.problem or ""
			if row.enabled == true and problem ~= "" and not about_credentials(problem) then
				rows[#rows + 1] = { target = scrub(row.name), warning = true, message = scrub(problem) }
			end
		end
	end
	local function ping_rows(data, r)
		local results = type(data) == "table" and type(data.results) == "table" and data.results or {}
		for _, row in ipairs(results) do
			local rendered = {
				target = scrub(row.target),
				ok = row.ok,
				account = scrub(row.account),
				message = scrub(row.note),
				error = scrub(row.error),
				ms = row.ms,
			}
			if row.target == "stage" or (type(row.target) == "string" and row.target:match("^stage:")) then
				rows[3] = rendered
			else
				rows[#rows + 1] = rendered
			end
		end
		if r.code ~= 0 and #results == 0 then
			rows[#rows + 1] =
				{ target = "ping", ok = false, error = scrub(r.stderr), message = "Check failed with code " .. r.code }
		end
	end
	local function base_done(job)
		local stdout, e = job.inspection.poll()
		if stdout == nil then
			return false
		end
		if stdout == false then
			cancel(job.process)
			rows[#rows + 1] = { target = "config", ok = false, error = scrub(e.message) }
			pending = false
			return true
		end
		local names, parse_error = plans.disable_base_custom(job.plan, stdout)
		if not names then
			rows[#rows + 1] = { target = "config", ok = false, error = scrub(parse_error.message) }
			pending = false
		else
			job.after()
		end
		return true
	end
	local function summarise()
		local ok, failed, warnings = 0, 0, 0
		for _, row in ipairs(rows) do
			if row.ok == false then
				failed = failed + 1
			elseif row.warning then
				warnings = warnings + 1
			elseif row.ok then
				ok = ok + 1
			end
		end
		log.info("Check setup finished: " .. ok .. " ok, " .. warnings .. " warnings, " .. failed .. " failed")
		return failed
	end
	function self.tick()
		for i = #jobs, 1, -1 do
			local job = jobs[i]
			if job.kind == "base_config" then
				if base_done(job) then
					table.remove(jobs, i)
				end
			else
				local r, e = job.process.poll()
				if r or e then
					table.remove(jobs, i)
					if e then
						cancel(job.process)
						rows[#rows + 1] = { target = job.kind, ok = false, error = scrub(e.message) }
					elseif job.kind == "platforms" then
						platform_rows(json.decode(r.stdout or ""))
					else
						ping_rows(json.decode(r.stdout or ""), r)
					end
				end
			end
		end
		if not pending and #jobs == 0 and check_run and not complete then
			if rows[3].message == "checking…" then
				rows[3] = { target = "stage", ok = true, message = "This staging mode has no credentials to check" }
			end
			complete = true
			local failed = summarise()
			local ok, e = deps.runs.finish(
				check_run,
				{ code = failed > 0 and 1 or 0, stdout = "", stderr = "", drainers = cleanup_records }
			)
			if not ok and e then
				log.warn("Cannot save setup report: " .. scrub(e.message))
			end
		end
		return rows
	end
	function self.busy()
		return pending or #jobs > 0
	end
	function self.rows()
		if pending or #jobs > 0 then
			local out = {}
			for _, r in ipairs(rows) do
				out[#out + 1] = r
			end
			out[#out + 1] = { target = "setup", message = "checking…", warning = true }
			return out
		end
		return rows
	end
	function self.detach()
		generation = generation + 1
		for _, job in ipairs(jobs) do
			cancel(job.process)
		end
		jobs = {}
		pending = false
	end
	return self
end
return M
