local json = require("crier_obs.json")
local plans = require("crier_obs.invoke.plan")
local M = {}
local base = require("crier_obs.invoke.base")
function M.new(deps)
	local self = {}
	local jobs = {}
	local rows = {}
	local pending = false
	local generation = 0
	local check_run
	local complete = false
	local cleanup_records = {}
	local function scrub(s)
		return deps.log.scrub(s or "")
	end
	function self.start(model, executable, plan)
		if pending or #jobs > 0 then
			return false
		end
		generation = generation + 1
		local request = generation
		local verified_base
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
		if deps.env.sandbox_status then
			local sandbox = deps.env.sandbox_status(deps.fs)
			if sandbox.kind ~= "native" then
				rows[#rows + 1] =
					{ target = sandbox.kind, ok = sandbox.ok, warning = sandbox.ok, message = scrub(sandbox.message) }
			end
		elseif deps.env.flatpak and deps.env.flatpak() then
			rows[#rows + 1] = {
				target = "Flatpak",
				warning = true,
				message = "Check host access to crier, secret-tool and rendering tools",
			}
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
				local found = deps.find_binary and deps.find_binary(binary)
				rows[#rows + 1] =
					{ target = item.target, ok = found ~= nil, message = found or ("Cannot find " .. tostring(binary)) }
			end
		end
		local function add(args, values, kind)
			local p, e = deps.spawner.spawn(plans.with_secrets({
				executable = executable,
				args = args,
				env = {},
				capture_stdout = true,
				capture_stderr = true,
				timeout = 60,
				kind = kind,
			}, values, deps.log))
			if p then
				jobs[#jobs + 1] = { process = p, kind = kind }
			else
				rows[#rows + 1] = { target = kind, ok = false, error = scrub(e.message) }
			end
		end
		add({ "platforms", "--json" }, {}, "platforms")
		-- Config and explicit enables match the snapshot checked by this request.
		for path, data in pairs(plan.files or {}) do
			local ok, e = deps.fs.write(path, data)
			if not ok then
				rows[#rows + 1] = { target = "config", ok = false, error = scrub(e.message) }
				pending = false
				return nil, e
			end
		end
		local function probe_credentials()
			local pingargs = { "ping", "--json" }
			for _, arg in ipairs(plan.args) do
				pingargs[#pingargs + 1] = arg
			end
			deps.secrets.resolve(model.credential_set, plan.needs_secrets, function(values, e)
				if request ~= generation then
					return
				end
				local backend = deps.secrets.backend_status and deps.secrets.backend_status()
					or { state = "ready", message = deps.backend_name or "OS credential store" }
				rows[2] = {
					target = "keyring",
					ok = not e and backend.state == "ready",
					warning = backend.state == "checking",
					message = backend.message or backend.name,
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
										or "Base configuration changed during setup checks"
								),
							}
							pending = false
							return
						end
					end
					add(pingargs, values or {}, "ping")
				end
				pending = false
			end)
		end
		if plan.base_config then
			local fingerprint, e = base.fingerprint(deps.fs, plan.base_config)
			if not fingerprint then
				rows[#rows + 1] = { target = "config", ok = false, error = scrub(e.message) }
				pending = false
				return nil, e
			end
			verified_base = fingerprint
			local process, spawn_error = deps.spawner.spawn(plans.base_probe(plan))
			if not process then
				rows[#rows + 1] = { target = "config", ok = false, error = scrub(spawn_error.message) }
				pending = false
			else
				jobs[#jobs + 1] = {
					process = process,
					kind = "base_config",
					plan = plan,
					after = probe_credentials,
					fingerprint = verified_base,
				}
			end
		else
			probe_credentials()
		end
		return true
	end
	local function cancel(process)
		local record
		if process.cancel then
			record = process.cancel()
		else
			process.terminate()
			record = process.detach()
		end
		if type(record) == "table" and record.pid and record.code == nil and check_run and deps.runs then
			cleanup_records[#cleanup_records + 1] = record
			local ok, e = deps.runs.journal(check_run, { state = "failed", drainers = cleanup_records })
			if not ok and e then
				deps.log.warn("Cannot save setup cleanup: " .. scrub(e.message))
			end
		end
	end
	function self.tick()
		for i = #jobs, 1, -1 do
			local job = jobs[i]
			local r, e = job.process.poll()
			if r or e then
				table.remove(jobs, i)
				if e then
					cancel(job.process)
					if job.kind == "base_config" then
						pending = false
					end
					rows[#rows + 1] = {
						target = job.kind == "base_config" and "config" or job.kind,
						ok = false,
						error = scrub(e.message),
					}
				elseif job.kind == "base_config" then
					if r.code ~= 0 or r.timed_out then
						rows[#rows + 1] =
							{ target = "config", ok = false, error = "Cannot inspect the base configuration" }
						pending = false
					else
						local current, read_error = base.fingerprint(deps.fs, job.plan.base_config)
						local names, parse_error
						if current ~= job.fingerprint then
							parse_error = read_error
								or { kind = "configuration", message = "Base configuration changed during setup checks" }
						else
							names, parse_error = plans.disable_base_custom(job.plan, r.stdout)
						end
						if not names then
							rows[#rows + 1] = { target = "config", ok = false, error = scrub(parse_error.message) }
							pending = false
						else
							job.after()
						end
					end
				else
					local data = json.decode(r.stdout or "")
					local results = job.kind == "ping" and type(data) == "table" and (data.results or data) or {}
					local count = 0
					for _, row in ipairs(results) do
						count = count + 1
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
					if r.code ~= 0 and count == 0 then
						rows[#rows + 1] = {
							target = job.kind,
							ok = false,
							error = scrub(r.stderr),
							message = "Check failed with code " .. r.code,
						}
					end
				end
			end
		end
		if not pending and #jobs == 0 and check_run and not complete then
			if rows[3].message == "checking…" then
				rows[3] = { target = "stage", ok = true, message = "This staging mode has no credentials to check" }
			end
			complete = true
			if deps.runs then
				local failed = false
				for _, row in ipairs(rows) do
					if row.ok == false then
						failed = true
					end
				end
				local ok, e = deps.runs.finish(
					check_run,
					{ code = failed and 1 or 0, stdout = "", stderr = "", drainers = cleanup_records }
				)
				if not ok and e then
					deps.log.warn("Cannot save setup report: " .. scrub(e.message))
				end
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
