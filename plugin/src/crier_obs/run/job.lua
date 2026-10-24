local plans = require("crier_obs.invoke.plan")
local report = require("crier_obs.invoke.report")
local base = require("crier_obs.invoke.base")
local M = {}
-- What a finished run keeps on disk and in memory. crier's --json report is small; its stderr can be
-- megabytes at log level debug, and only its tail is ever shown, so only the tail is scrubbed.
M.STDOUT_LIMIT = 1048576
M.STDERR_LIMIT = 65536
local function tail(text, limit)
	text = text or ""
	if #text <= limit then
		return text
	end
	-- Cut at a line start so a partial secret at the boundary cannot survive the exact-value scrub.
	local cut = text:find("\n", #text - limit + 1, true)
	return cut and text:sub(cut + 1) or text:sub(-limit)
end
M.tail = tail
function M.new(deps)
	local self = { event = deps.event, state = "queued", plan = deps.plan, run = deps.run }
	local process, inspection
	local cancelled = false
	local log = deps.log
	local function enter(state)
		if self.state ~= state then
			log.debug(tostring(self.event) .. " post: " .. self.state .. " -> " .. state)
			self.state = state
		end
	end
	local function persist(result)
		local ok, e = deps.runs.finish(self.run, result)
		if not ok and e then
			log.warn("Cannot save run report: " .. log.scrub(e.message))
		end
		return ok, e
	end
	local function fail(e)
		enter("failed")
		self.result =
			{ ok = false, code = 1, level = "error", message = log.scrub(e.message or tostring(e)), stderr = "" }
		log.error(self.result.message)
		persist({ code = 1, stdout = "", stderr = self.result.message })
	end
	local function stop_process()
		local current = process or (inspection and inspection.process)
		if not current then
			return nil
		end
		return current.cancel()
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
		enter("spawning")
		local plan = plans.with_secrets(self.plan, values, log)
		if deps.on_secrets then
			deps.on_secrets(values or {})
		end
		for _, warning in ipairs(plan.warnings or {}) do
			log.warn(warning)
		end
		local p, e = deps.spawner.spawn(plan)
		if not p then
			fail(e)
			return
		end
		process = p
		enter("running")
		self.spawned = true
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
		elseif #self.plan.needs_secrets > 0 then
			enter("resolving_secrets")
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
			local e
			inspection, e = base.inspect(deps.spawner, deps.fs, self.plan)
			if not inspection then
				fail(e)
				return
			end
			self.plan.base_fingerprint = inspection.fingerprint
			self.plan.base_path = self.plan.base_config
			enter("inspecting_base")
		else
			resolve_secrets()
		end
	end
	local function finish_run(r)
		local stdout = log.scrub(tail(r.stdout, M.STDOUT_LIMIT))
		local stderr = log.scrub(tail(r.stderr, M.STDERR_LIMIT))
		r.stdout, r.stderr = stdout, stderr
		self.result = report.parse(r, log)
		enter(r.timed_out and "timed_out" or r.code == 0 and "done" or "failed")
		persist(r)
		log[self.result.level](
			self.result.message
				.. (self.result.hint and (". " .. self.result.hint) or "")
				.. (self.result.stderr ~= "" and ": " .. self.result.stderr or "")
		)
		-- One line per platform that did not take the post, so a partial publish names who failed.
		for _, outcome in ipairs(self.result.failed or {}) do
			log.warn(
				outcome.platform .. " did not take the post" .. (outcome.error ~= "" and ": " .. outcome.error or "")
			)
		end
		if self.event == "test" and r.code == 0 then
			log.info(self.result.summary)
		end
	end
	function self.tick()
		if self.state == "inspecting_base" then
			local stdout, e = inspection.poll()
			if stdout == false then
				local record = stop_process()
				inspection = nil
				fail(e)
				journal_cleanup(record)
				return
			end
			if not stdout then
				return
			end
			inspection = nil
			local names, parse_error = plans.disable_base_custom(self.plan, stdout)
			if not names then
				fail(parse_error)
				return
			end
			if deps.on_base_custom then
				deps.on_base_custom(names, self.plan.base_fingerprint)
			end
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
		if r then
			finish_run(r)
		end
	end
	function self.finished()
		return self.state == "done"
			or self.state == "failed"
			or self.state == "timed_out"
			or self.state == "detached"
			or self.state == "cancelled"
			or self.state == "skipped"
	end
	function self.cancel(reason)
		cancelled = true
		local record = stop_process()
		enter(reason and "skipped" or "cancelled")
		if reason then
			log.warn(reason .. " (" .. tostring(self.event) .. " post)")
		end
		persist({ code = 1, stdout = "", stderr = reason or "Post cancelled before completion" })
		journal_cleanup(record)
	end
	function self.park()
		cancelled = true
		local record = stop_process()
		enter("parked")
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
				enter("failed")
				persist({ code = 1, stderr = log.scrub(e.message) })
				journal_cleanup(pending)
				return nil, e
			end
			record.state = "detached"
			enter("detached")
			local ok, journal_error = deps.runs.journal(self.run, record)
			if not ok then
				local adopted = deps.spawner.adopt(record)
				local pending = adopted and adopted.cancel() or process.kill()
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
