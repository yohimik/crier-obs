local plans = require("crier_obs.invoke.plan")
local report = require("crier_obs.invoke.report")
local M = {}
local base = require("crier_obs.invoke.base")
function M.new(deps)
	local self = { event = deps.event, state = "queued", plan = deps.plan, run = deps.run }
	local process
	local cancelled = false
	local function persist(result)
		local ok, e = deps.runs.finish(self.run, result)
		if not ok and e then
			deps.log.warn("Cannot save run report: " .. deps.log.scrub(e.message))
		end
		return ok, e
	end
	local function fail(e)
		self.state = "failed"
		self.result =
			{ ok = false, code = 1, level = "error", message = deps.log.scrub(e.message or tostring(e)), stderr = "" }
		deps.log.error(self.result.message)
		if deps.runs then
			persist({ code = 1, stdout = "", stderr = self.result.message })
		end
	end
	local function stop_process()
		if not process then
			return
		end
		if process.cancel then
			return process.cancel()
		end
		process.kill()
		if process.detach then
			return process.detach()
		end
	end
	local function journal_cleanup(record)
		if type(record) == "table" and record.pid and record.code == nil then
			record.state = "detached"
			deps.runs.journal(self.run, record)
		end
	end
	local function spawn(values)
		if self.plan.base_fingerprint then
			local current, e = base.fingerprint(deps.fs, self.plan.base_path)
			if not current or current ~= self.plan.base_fingerprint then
				fail(e or {
					kind = "configuration",
					message = "Base configuration changed after destination checks; post skipped",
				})
				return
			end
		end
		self.state = "spawning"
		local plan = plans.with_secrets(self.plan, values, deps.log)
		if deps.on_secrets then
			deps.on_secrets(values or {})
		end
		for _, warning in ipairs(plan.warnings or {}) do
			deps.log.warn(warning)
		end
		local p, e = deps.spawner.spawn(plan)
		if not p then
			fail(e)
			return
		end
		process = p
		self.state = "running"
		local journal_ok, journal_error =
			deps.runs.journal(self.run, { state = "running", pid = p.pid, child_pid = p.child_pid })
		if not journal_ok then
			local pending = stop_process()
			fail(journal_error or { kind = "filesystem", message = "Cannot journal the running post" })
			journal_cleanup(pending)
			return
		end
		-- Credentials stay only in the live-session cache and the child's environment.
		plan.env = {}
		if deps.on_spawn then
			deps.on_spawn(self)
		end
	end
	local function resolve_secrets()
		if deps.cached_secrets then
			spawn(deps.cached_secrets)
		elseif #self.plan.needs_secrets > 0 and deps.secrets then
			self.state = "resolving_secrets"
			deps.secrets.resolve(deps.credential_set, self.plan.needs_secrets, function(values, e)
				if cancelled then
					return
				end
				if e then
					fail(e)
				else
					spawn(values or {})
				end
			end)
		else
			spawn({})
		end
	end
	function self.start()
		if self.state ~= "queued" then
			return
		end
		for path, data in pairs(self.plan.files or {}) do
			local ok, e = deps.fs.write(path, data)
			if not ok then
				fail(e)
				return
			end
		end
		if self.plan.base_config then
			local fingerprint, e = base.fingerprint(deps.fs, self.plan.base_config)
			if not fingerprint then
				fail(e)
				return
			end
			self.plan.base_fingerprint = fingerprint
			self.plan.base_path = self.plan.base_config
			local p, spawn_error = deps.spawner.spawn(plans.base_probe(self.plan))
			if not p then
				fail(spawn_error)
				return
			end
			process = p
			self.state = "inspecting_base"
		else
			resolve_secrets()
		end
	end

	function self.tick()
		if self.state == "inspecting_base" then
			local r, e = process.poll()
			if e then
				local record = stop_process()
				fail(e)
				journal_cleanup(record)
				return
			end
			if not r then
				return
			end
			if r.code ~= 0 or r.timed_out then
				fail({
					kind = "configuration",
					message = "Cannot inspect the base configuration (exit " .. tostring(r.code) .. ")",
				})
				return
			end
			local fingerprint, read_error = base.fingerprint(deps.fs, self.plan.base_path)
			if fingerprint ~= self.plan.base_fingerprint then
				fail(read_error or {
					kind = "configuration",
					message = "Base configuration changed during destination checks; post skipped",
				})
				return
			end
			local names, parse_error = plans.disable_base_custom(self.plan, r.stdout)
			if not names then
				fail(parse_error)
				return
			end
			if deps.on_base_custom then
				deps.on_base_custom(names, self.plan.base_fingerprint)
			end
			process = nil
			resolve_secrets()
			return
		end
		if self.state ~= "running" then
			return
		end
		local r, e = process.poll()
		if e then
			local record = stop_process()
			fail(e)
			journal_cleanup(record)
			return
		end
		if not r then
			return
		end
		r.stdout = deps.log.scrub(r.stdout or "")
		r.stderr = deps.log.scrub(r.stderr or "")
		self.result = report.parse(r, deps.log)
		self.state = r.timed_out and "timed_out" or r.code == 0 and "done" or "failed"
		persist(r)
		deps.log[self.result.level](
			self.result.message .. (self.result.stderr ~= "" and ": " .. self.result.stderr or "")
		)
	end
	function self.finished()
		return self.state == "done"
			or self.state == "failed"
			or self.state == "timed_out"
			or self.state == "detached"
			or self.state == "cancelled"
	end
	function self.cancel()
		cancelled = true
		local record = stop_process()
		self.state = "cancelled"
		persist({ code = 1, stdout = "", stderr = "Post cancelled before completion" })
		journal_cleanup(record)
	end
	function self.park()
		cancelled = true
		local record = stop_process()
		self.state = "parked"
		local ok, e = deps.runs.journal(self.run, {
			state = "queued",
			drainers = type(record) == "table" and record.pid and record.code == nil and { record } or nil,
		})
		if not ok then
			return nil, e or { kind = "filesystem", message = "Cannot journal parked post" }
		end
		return true
	end
	function self.detach()
		cancelled = true
		if process and self.state == "running" then
			local record, e = process.detach()
			if not record then
				local pending = stop_process()
				self.state = "failed"
				persist({ code = 1, stderr = deps.log.scrub(e.message) })
				journal_cleanup(pending)
				return nil, e
			end
			record.state = "detached"
			self.state = "detached"
			local ok, journal_error = deps.runs.journal(self.run, record)
			if not ok then
				local adopted = deps.spawner.adopt and deps.spawner.adopt(record)
				local pending
				if adopted and adopted.cancel then
					pending = adopted.cancel()
				elseif process.kill then
					process.kill()
				end
				local problem = journal_error or { kind = "filesystem", message = "Cannot journal detached post" }
				fail(problem)
				journal_cleanup(pending)
				return nil, problem
			end
			return record
		end
		self.cancel()
		return { state = "cancelled" }
	end
	return self
end
return M
