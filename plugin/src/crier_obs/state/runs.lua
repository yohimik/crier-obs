local json = require("crier_obs.json")
local M = {}
function M.new(deps)
	local fs, clock, paths = deps.fs, deps.clock, deps.paths
	local seq = 0
	local owner = assert(deps.pid, "runs need the OBS process id")
	-- Journals carry the boot they were written in; a pid from another boot names some other process.
	local boot = deps.boot_id
	local self = {}
	local function write_json(path, value)
		local text, e = json.encode(value)
		if not text then
			return nil, e
		end
		return fs.write(path, text)
	end
	function self.init()
		for _, path in ipairs({ paths.root, paths.runs, paths.bin, paths.templates }) do
			local ok, e = fs.mkdir(path)
			if not ok then
				return nil, e
			end
		end
		local ok, e = fs.mkdir_private(paths.secrets)
		if not ok then
			return nil, e
		end
		if not fs.exists(paths.template) then
			return fs.write(paths.template, require("crier_obs.templates").live)
		end
		return true
	end
	function self.create(event)
		seq = seq + 1
		local timestamp = math.floor(clock.now_wall())
		local dir = paths.runs .. "/" .. timestamp .. "-" .. owner .. "-" .. seq
		while fs.exists(dir) do
			seq = seq + 1
			dir = paths.runs .. "/" .. timestamp .. "-" .. owner .. "-" .. seq
		end
		local ok, e = fs.mkdir(dir)
		if not ok then
			return nil, e
		end
		local run = {
			dir = dir,
			event = event,
			created_at = timestamp,
			config = dir .. "/config.json",
			data = dir .. "/data.json",
			stdout = dir .. "/stdout",
			stderr = dir .. "/stderr",
			status = dir .. "/status",
			pid = dir .. "/pid",
			journal = dir .. "/journal.json",
			preview = dir .. "/preview.png",
		}
		local saved, se = write_json(run.journal, { event = event, created_at = timestamp, state = "queued" })
		if not saved then
			return nil, se
		end
		return run
	end
	function self.journal(run, record)
		local value = {
			event = run.event,
			created_at = run.created_at,
			state = record.state or "running",
			pid = record.pid,
			child_pid = record.child_pid,
			status_path = run.status,
			pid_path = run.pid,
			drainers = record.drainers,
			job_name = record.job_name,
			boot_id = boot,
			error = record.error,
		}
		return write_json(run.journal, value)
	end
	function self.finish(run, result)
		local ok, e = fs.write(run.stdout, result.stdout or "")
		if not ok then
			return nil, e
		end
		ok, e = fs.write(run.stderr, result.stderr or "")
		if not ok then
			return nil, e
		end
		ok, e = fs.write(run.status, tostring(result.code or 1))
		if not ok then
			return nil, e
		end
		return self.journal(
			run,
			{
				state = result.timed_out and "timed_out" or result.code == 0 and "done" or "failed",
				pid = result.pid,
				drainers = result.drainers,
			}
		)
	end
	function self.adopt()
		local out = {}
		for _, dir in ipairs(fs.glob(paths.runs .. "/*")) do
			local text = fs.read(dir .. "/journal.json")
			local rec = text and json.decode(text)
			if
				type(rec) == "table"
				and rec.state ~= "running"
				and rec.state ~= "detached"
				and rec.state ~= "adopted"
			then
				for _, helper in ipairs(rec.drainers or {}) do
					helper.event = "drainer"
					out[#out + 1] = helper
				end
			end
			if
				type(rec) == "table"
				and (rec.state == "running" or rec.state == "detached" or rec.state == "adopted")
				and rec.pid
			then
				if rec.boot_id and boot and rec.boot_id ~= boot then
					-- Written before a reboot: the process is gone and its exit code with it.
					rec.state, rec.error = "failed", "OBS or the computer restarted while this run was detached; its result is unknown"
					rec.drainers = nil
					write_json(dir .. "/journal.json", rec)
				else
					rec.status_path = dir .. "/status"
					rec.pid_path = dir .. "/pid"
					rec.dir = dir
					rec.journal = dir .. "/journal.json"
					out[#out + 1] = rec
				end
			end
		end
		return out
	end
	local function remove_tree(path)
		for _, file in ipairs(fs.glob(path .. "/*")) do
			if fs.exists(file .. "/journal.json") then
				remove_tree(file)
			else
				fs.remove(file)
			end
		end
		fs.rmdir(path)
	end
	function self.sweep(days, count)
		local completed = {}
		local now = clock.now_wall()
		for _, dir in ipairs(fs.glob(paths.runs .. "/*")) do
			local text = fs.read(dir .. "/journal.json")
			local rec = text and json.decode(text)
			if type(rec) == "table" and (rec.state == "done" or rec.state == "failed" or rec.state == "timed_out") then
				completed[#completed + 1] = { dir = dir, time = rec.created_at or 0 }
			end
		end
		table.sort(completed, function(a, b)
			return a.time > b.time
		end)
		for i, run in ipairs(completed) do
			if i > (count or 50) or now - run.time > (days or 7) * 86400 then
				remove_tree(run.dir)
			end
		end
	end
	return self
end
return M
