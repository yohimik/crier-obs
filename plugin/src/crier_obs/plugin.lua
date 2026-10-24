local datadoc = require("crier_obs.invoke.datadoc")
local builder = require("crier_obs.invoke.builder")
local plans = require("crier_obs.invoke.plan")
local base = require("crier_obs.invoke.base")
local job_module = require("crier_obs.run.job")
local descriptor = require("crier_obs.schema.descriptor")
local models = require("crier_obs.settings.model")
local i18n = require("crier_obs.i18n")
local json = require("crier_obs.json")
local version = require("crier_obs.version")
local M = {}
-- An adopted run that still reports "running" this long after its run timeout is treated as lost
-- (its pid may name another process by now) and stops being polled.
M.ADOPTION_GRACE = 3600
local QUIT_SKIP = "Post skipped: OBS quit before it started"
function M.new(deps)
	deps = deps or {}
	local obs = deps.obs or require("crier_obs.ports.obs")
	local t = i18n.new(obs.obs_get_locale())
	local env = deps.env or require("crier_obs.ports.env").new({})
	local fs = deps.fs or require("crier_obs.ports.fs").new({ obs = obs, env = env })
	local clock = deps.clock or require("crier_obs.ports.clock").new({ obs = obs })
	local log = deps.log or require("crier_obs.log").new({ obs = obs, clock = clock })
	local store = deps.store or require("crier_obs.settings.store").new({ obs = obs })
	local model_port = deps.model or models.new({ obs = obs, store = store })
	local paths = deps.paths
		or require("crier_obs.state.paths").new({
			env = env,
			state_dir = deps.state_dir or env.getenv("CRIER_OBS_STATE_DIR"),
		})
	local spawner = deps.spawner
		or require("crier_obs.proc.spawner").new({ env = env, fs = fs, clock = clock, log = log })
	local resolver = deps.resolver
		or require("crier_obs.proc.resolver").new({
			env = env,
			fs = fs,
			spawner = spawner,
			pin = version.CRIER_VERSION,
			state_dir = paths.root,
			json = json,
		})
	local runs = deps.runs
		or require("crier_obs.state.runs").new({
			fs = fs,
			clock = clock,
			paths = paths,
			pid = spawner.current_pid(),
			boot_id = env.boot_id(),
		})
	local secrets = deps.secrets
		or require("crier_obs.secrets.service").new({
			obs = obs,
			fs = fs,
			env = env,
			clock = clock,
			log = log,
			spawner = spawner,
			state_dir = paths.root,
			store = store,
		})
	local installer = deps.installer
		or require("crier_obs.invoke.installer").new({
			fs = fs,
			env = env,
			log = log,
			spawner = spawner,
			resolver = resolver,
			state_dir = paths.root,
			pin = version.CRIER_VERSION,
		})
	local ping = deps.ping
		or require("crier_obs.run.ping").new({
			fs = fs,
			spawner = spawner,
			secrets = secrets,
			log = log,
			env = env,
			find_binary = resolver.find_binary,
			runs = runs,
		})
	local settings, model, scheduler, queue
	local loaded = false
	local initialized, state_error = false, nil
	local live_recheck = false
	local credential_revision = 0
	local adopted = {}
	local last_run = t("no_posts")
	local recheck = false
	local logged_resolver
	-- Frontend context read on the UI thread (events, script_update, buttons); posts the heartbeat
	-- builds on the graphics thread use this copy instead of calling the frontend getters there.
	local frontend = {}
	local preflight
	local self = { paths = paths, spawner = spawner, secrets = secrets, resolver = resolver, runs = runs }
	local function refresh_frontend()
		frontend = datadoc.frontend(obs)
		return frontend
	end
	local function drop_live_cache(session)
		if session then
			session.cache = {}
			session.cache_ready = false
		end
		secrets.clear_cache()
	end
	-- Advanced mode: the quit post cannot wait for a base-file probe at shutdown, so the live session
	-- inspects the base file as soon as it starts and keeps the custom destinations it defines.
	local function inspect_base(session)
		if preflight then
			preflight.inspection.cancel()
			preflight = nil
		end
		if model.mode ~= "advanced" then
			return
		end
		local executable = resolver.find(model.crier_path)
		if not executable then
			return
		end
		local inspection, e = base.inspect(spawner, fs, {
			executable = executable,
			base_config = model.base_config,
			cwd = model.base_config:match("^(.*)[/\\]") or ".",
		})
		if not inspection then
			log.warn("Cannot inspect the base configuration: " .. e.message)
			return
		end
		preflight = {
			inspection = inspection,
			session = session,
			generation = session.generation,
			revision = credential_revision,
			path = model.base_config,
		}
	end
	local function tick_preflight()
		if not preflight then
			return
		end
		local stdout, e = preflight.inspection.poll()
		if stdout == nil then
			return
		end
		local current = preflight
		preflight = nil
		local names, parse_error
		if stdout == false then
			current.inspection.cancel()
			parse_error = e
		else
			names, parse_error = plans.base_custom_names(stdout)
		end
		local session = current.session
		if session.generation ~= current.generation or credential_revision ~= current.revision then
			return
		end
		if not names then
			log.warn("Cannot inspect the base configuration: " .. parse_error.message)
			return
		end
		session.base_custom_names = names
		session.base_fingerprint = current.inspection.fingerprint
		session.base_config_ready = true
		session.base_config_path = current.path
		log.debug("base configuration inspected for the live session: " .. #names .. " custom destinations")
	end
	local function resolve_live(session)
		local target = session
		local generation = session.generation
		local revision = credential_revision
		secrets.resolve(model.credential_set, builder.needs_secrets(model), function(values, e)
			if not loaded or target.generation ~= generation or credential_revision ~= revision then
				return
			end
			if e then
				target.cache_ready = false
				target.cache_error = e
				log.warn(e.message)
			else
				target.cache_ready = true
				target.cache_error = nil
				target.cache = values or {}
				for _, value in pairs(target.cache) do
					log.register_secret(value)
				end
			end
		end, { remember = true })
		inspect_base(session)
	end
	-- Mid-stream load: OBS's frame counter is the best estimate of how long the stream has run.
	local function stream_uptime()
		local output = obs.obs_frontend_get_streaming_output()
		if not output then
			return 0
		end
		local frames = obs.obs_output_get_total_frames(output)
		obs.obs_output_release(output)
		local fps = obs.obs_get_active_fps()
		return fps and fps > 0 and frames / fps or 0
	end
	local function write_data(run, m, context)
		local source = m.values["render.data"]
		local data_path = run.data
		if source and source ~= "" then
			local full = builder.absolute(
				source,
				m.mode == "advanced" and (m.base_config:match("^(.*)[/\\]") or ".") or paths.root
			)
			if source:lower():match("%.ya?ml$") then
				log.info("YAML render.data is passed through; stream context is skipped")
				return full
			end
			if source:lower():match("%.json$") then
				local text, e = fs.read(full)
				local user, je
				if text then
					user, je = json.decode(text)
				end
				if type(user) == "table" and not getmetatable(user) then
					context = datadoc.merge(user, context)
				else
					log.warn(
						"Cannot merge render.data; using stream context: "
							.. ((e or je or {}).message or "expected a JSON object")
					)
				end
			else
				return full
			end
		end
		local text, e = json.encode(context)
		if not text then
			return nil, e
		end
		local ok, we = fs.write(data_path, text)
		if not ok then
			return nil, we
		end
		return data_path
	end
	local function save_result(run, result)
		local ok, e = runs.finish(run, result)
		if not ok and e then
			log.warn("Cannot save run report: " .. log.scrub(e.message))
		end
		return ok, e
	end
	-- Returns the job when the post was queued (or spawned, for the quit post), nil when it was refused.
	local function enqueue(event, session, extra)
		if not initialized then
			log.error("State directory is unavailable", "state-dir")
			return nil
		end
		extra = extra or {}
		local session_generation = session and session.generation
		local snapshot_revision = credential_revision
		local snapshot = datadoc.copy(model)
		local front = datadoc.copy(extra.cached_frontend and frontend or refresh_frontend())
		-- Each event carries only its own file: the saved recording on recording_end, the clip on replay.
		if event ~= "rec_end" then
			front.recording_path = nil
		end
		if event ~= "replay" then
			front.replay_path = nil
		end
		local ss = session and session.snapshot() or {}
		if event == "replay" and (not front.replay_path or front.replay_path == "") then
			log.warn("Replay post skipped: no saved clip path is available")
			return nil
		end
		local count = 0
		for _, enabled in pairs(snapshot.platforms) do
			if enabled then
				count = count + 1
			end
		end
		if count == 0 then
			log.warn("No platform is selected; post skipped", "no-platforms")
			return nil
		end
		if
			extra.immediate
			and session
			and snapshot.mode == "advanced"
			and (
				not session.base_config_ready
				or not session.base_fingerprint
				or session.base_config_path ~= snapshot.base_config
			)
		then
			log.warn("quit post skipped: base configuration is not ready")
			return nil
		end
		if extra.immediate and session and not session.cache_ready and #builder.needs_secrets(snapshot) > 0 then
			log.warn("quit post skipped: credentials are not ready")
			return nil
		end
		local path, e = resolver.find(snapshot.crier_path)
		if not path then
			log.error(e.message, "missing-crier")
			return nil
		end
		local run, re = runs.create(event)
		if not run then
			log.error(re.message)
			return nil
		end
		local event_names = { rec_start = "recording_start", rec_end = "recording_end" }
		local context = datadoc.build({
			event = event_names[event] or event,
			model = snapshot,
			frontend = front,
			session = ss,
			uptime = ss.uptime,
			now = clock.now_wall(),
			plugin_version = version.VERSION,
		})
		local data_path, de = write_data(run, snapshot, context)
		if not data_path then
			log.error(de.message)
			save_result(run, { code = 1, stderr = log.scrub(de.message) })
			return nil
		end
		local caption = (snapshot.triggers[event] or {}).caption or snapshot.manual_caption
		local plan, pe = builder.build({
			model = snapshot,
			run = run,
			executable = path,
			caption = caption,
			data_path = data_path,
			clip = event == "replay" and front.replay_path or nil,
			dry_run = event == "test",
			discard_output = extra.discard_output,
			source_dir = paths.root,
			base_custom_names = extra.immediate and session and session.base_custom_names or nil,
			base_fingerprint = extra.immediate and session and session.base_fingerprint or nil,
			skip_base_probe = extra.immediate == true,
		})
		if not plan then
			log[pe.kind == "skipped" and "warn" or "error"](pe.message)
			save_result(run, { code = 1, stderr = log.scrub(pe.message) })
			return nil
		end
		local job = job_module.new({
			event = event,
			plan = plan,
			run = run,
			fs = fs,
			runs = runs,
			spawner = spawner,
			secrets = secrets,
			credential_set = snapshot.credential_set,
			log = log,
			cached_secrets = extra.cached_secrets,
			on_base_custom = function(names, fingerprint)
				if
					session
					and session.generation == session_generation
					and credential_revision == snapshot_revision
				then
					session.base_custom_names = names
					session.base_fingerprint = fingerprint
					session.base_config_ready = true
					session.base_config_path = snapshot.base_config
				end
			end,
			on_secrets = function(values)
				if
					session
					and session.live
					and session.generation == session_generation
					and credential_revision == snapshot_revision
				then
					session.cache_ready = true
					session.cache_error = nil
					for k, v in pairs(values) do
						session.cache[k] = v
					end
				end
			end,
			on_spawn = function()
				-- The live session's credentials go once the end post has them.
				if event == "end" then
					drop_live_cache(nil)
				end
			end,
		})
		job.spill = { event = event, plan = plan, run = run, credential_set = snapshot.credential_set }
		if extra.immediate then
			job.start()
			if job.state ~= "running" then
				log.warn("quit post skipped: " .. ((job.result or {}).message or "post is not ready"))
				return job
			end
			local record, derr = job.detach()
			if not record then
				log.error(derr.message)
				return job
			end
			log.info("quit post spawned")
			return job
		end
		local accepted, reason = queue.push(job)
		if not accepted then
			job.cancel()
			log.warn("Post " .. event .. " " .. reason)
			return nil
		end
		return job
	end
	local function status()
		local r = resolver.status()
		local install = installer.status()
		local secret_status = {}
		if model then
			for _, d in ipairs(descriptor.build(model.custom_names)) do
				if d.secret then
					secret_status[d.key] = secrets.status(model.credential_set, d.key)
				end
			end
		end
		local backend = secrets.backend_status()
		local installing = install.state == "installing" or install.state == "failed" or install.state == "cancelled"
		local crier = i18n.shown(t, installing and install or r)
		local keyring = i18n.shown(t, backend, "label")
		local level = install.state == "failed" and "error"
			or (not installing and (r.state == "missing" or r.state == "failed")) and "error"
			or (not installing and r.state == "outdated") and "warning"
			or "normal"
		return {
			crier = crier,
			crier_level = level,
			keyring = backend.state == "checking" and t("keyring_state", keyring, t("checking")) or keyring,
			last_run = last_run,
			logs = initialized and paths.runs or t("state_unavailable", state_error or "?"),
			update_available = r.state == "outdated",
			secrets = secret_status,
			results = ping.rows(),
		}
	end
	local callbacks = {}
	callbacks.install = function()
		local _, e = installer.start(model and model.crier_path or "")
		if e then
			log.error(e.message)
		end
		return true
	end
	callbacks.refresh = function()
		return true
	end
	callbacks.post = function()
		enqueue("manual", scheduler and scheduler.stream)
		return true
	end
	callbacks.dry_run = function()
		enqueue("test", scheduler and scheduler.stream)
		return true
	end
	callbacks.check = function()
		if ping.busy() then
			return true
		end
		if not initialized then
			log.error("State directory is unavailable", "state-dir")
			return true
		end
		local executable, e = resolver.find(model.crier_path)
		if not executable then
			log.error(e.message)
			return true
		end
		if resolver.status().state ~= "checking" then
			resolver.probe(model.crier_path)
		end
		local run, re = runs.create("check")
		if not run then
			log.error(re.message)
			return true
		end
		local plan, pe = builder.build({
			model = datadoc.copy(model),
			run = run,
			executable = executable,
			caption = "",
			data_path = run.data,
			source_dir = paths.root,
		})
		if not plan then
			log.error(pe.message)
			save_result(run, { code = 1, stderr = log.scrub(pe.message) })
			return true
		end
		local data_ok, data_error = fs.write(run.data, "{}")
		if not data_ok then
			log.error(data_error.message)
			save_result(run, { code = 1, stderr = log.scrub(data_error.message) })
			return true
		end
		ping.start(datadoc.copy(model), executable, plan)
		return true
	end
	local function invalidate(key)
		credential_revision = credential_revision + 1
		if scheduler then
			scheduler.stream.cache[key] = nil
			scheduler.stream.cache_ready = false
		end
	end
	-- Only a commit that is really queued touches the live session; a failed one re-resolves the stored
	-- value, so a misclick on Save never leaves the quit post without credentials.
	callbacks.save_secret = function(key)
		if settings then
			secrets.scrub(settings, nil, model.credential_set)
		end
		local value = secrets.pending(model.credential_set, key)
		if not value or value:match("^%s*$") then
			log.warn("Enter a credential before saving " .. key)
			return true
		end
		invalidate(key)
		secrets.commit(model.credential_set, key, value, function(ok, e)
			if not ok then
				log.error(e.message)
			end
			live_recheck = true
		end)
		return true
	end
	callbacks.forget_secret = function(key)
		invalidate(key)
		secrets.forget(model.credential_set, key, function(ok, e)
			if not ok then
				log.error(e.message)
			end
			live_recheck = true
		end)
		return true
	end
	callbacks.forget_all = function()
		credential_revision = credential_revision + 1
		if scheduler then
			scheduler.stream.cache = {}
			scheduler.stream.cache_ready = false
		end
		secrets.forget_all(model.credential_set, function(ok, e)
			if not ok then
				log.error(e.message)
			end
			live_recheck = true
		end)
		return true
	end
	local properties = deps.properties
		or require("crier_obs.schema.properties").new({
			obs = obs,
			store = store,
			model = model_port,
			callbacks = callbacks,
			status = status,
		})
	local function log_resolver(r)
		local id = r.state .. "\0" .. tostring(r.path) .. "\0" .. tostring(r.version)
		if id == logged_resolver or r.state == "checking" then
			return
		end
		logged_resolver = id
		if r.state == "ready" then
			log.info(r.message)
		elseif r.state == "outdated" then
			log.warn(
				"crier "
					.. r.version
					.. " at "
					.. r.path
					.. " is older than "
					.. version.CRIER_VERSION
					.. "; click Update crier",
				"outdated:" .. r.path .. ":" .. r.version,
				math.huge
			)
		elseif r.state == "missing" then
			log.warn(r.message .. "; click Install crier", "crier-status")
		elseif r.state == "failed" then
			log.warn(r.message)
		end
	end
	local function poll_adopted()
		for i = #adopted, 1, -1 do
			local item = adopted[i]
			local result, err = item.process.poll()
			local record = item.record
			local lost = not result
				and not err
				and record.event ~= "drainer"
				and record.created_at
				and clock.now_wall() - record.created_at > (model.timeout + M.ADOPTION_GRACE)
			if result or err or lost then
				local journal = record.journal
					and {
						event = record.event,
						created_at = record.created_at,
						journal = record.journal,
						status = record.status_path,
						pid = record.pid_path,
					}
				if result and record.event ~= "drainer" then
					last_run = t("last_run_code", result.code)
					log.info("Adopted " .. tostring(record.event) .. " post finished with code " .. result.code)
					if journal then
						runs.journal(journal, { state = result.code == 0 and "done" or "failed", pid = record.pid })
					end
				elseif err then
					item.process.cancel()
					log.warn(err.message)
				elseif lost then
					log.warn("Adopted " .. tostring(record.event) .. " post stopped reporting; its result is unknown")
					if journal then
						runs.journal(journal, { state = "failed", pid = record.pid, error = "Run stopped reporting" })
					end
				end
				table.remove(adopted, i)
			end
		end
	end
	local function heartbeat()
		secrets.tick()
		for _, record in ipairs(spawner.reap()) do
			if record.run then
				runs.journal(record.run, { state = "failed", pid = record.pid })
			end
		end
		log_resolver(resolver.tick())
		installer.tick()
		ping.tick()
		if recheck then
			recheck = false
			if resolver.status().state ~= "checking" then
				resolver.probe(model.crier_path)
			end
		end
		if live_recheck then
			live_recheck = false
			if scheduler.stream.live then
				resolve_live(scheduler.stream)
			end
		end
		tick_preflight()
		scheduler.tick()
		queue.tick()
		poll_adopted()
	end
	local function tick()
		if not loaded then
			return
		end
		local ok, e = pcall(heartbeat)
		if not ok then
			log.error(tostring(e), "heartbeat-error")
		end
	end
	local function frontend_event(event)
		local ok, e = pcall(function()
			refresh_frontend()
			scheduler.event(event)
		end)
		if not ok then
			log.error(tostring(e), "frontend-error")
		end
	end
	local function log_inherited()
		local names = env.crier_names()
		if #names > 0 then
			log.debug(
				"inherited CRIER_* variables are removed before crier runs (the dialog and the credential store win): "
					.. table.concat(names, ", ")
			)
		end
	end
	function self.defaults(data)
		model_port.defaults(data, paths.template)
	end
	function self.load(data)
		if loaded then
			self.unload()
		end
		settings = data
		obs.obs_data_addref(settings)
		model = model_port.snapshot(data)
		log.set_debug(model.debug)
		loaded = true
		log.info(
			"crier-obs " .. version.VERSION .. " for crier " .. version.CRIER_VERSION .. "; state in " .. paths.root
		)
		log_inherited()
		local sandbox = env.sandbox_status(fs)
		if sandbox.kind ~= "native" then
			log.warn(sandbox.message, "sandbox", math.huge)
		end
		local ok, e = runs.init()
		initialized = ok == true
		state_error = e and e.message
		if not ok then
			log.error(e.message)
		end
		refresh_frontend()
		local spool = require("crier_obs.run.spool").new({
			fs = fs,
			paths = paths,
			clock = clock,
			log = log,
			pid = spawner.current_pid(),
			alive = spawner.alive,
			hydrate = function(entry, ack)
				return job_module.new({
					event = entry.event,
					plan = entry.plan,
					run = entry.run,
					credential_set = entry.credential_set,
					fs = fs,
					runs = runs,
					spawner = spawner,
					secrets = secrets,
					log = log,
					on_spawn = ack,
				})
			end,
		})
		queue = require("crier_obs.run.queue").new({
			bound = 5,
			backlog = spool,
			on_drop = function(job, reason)
				log.warn("Dropped " .. job.event .. " post: " .. reason)
			end,
			on_error = function(err)
				log.error(err.message)
			end,
			on_done = function(job)
				if job.result then
					last_run = log.scrub(i18n.shown(t, job.result) or "")
				end
				-- An end post that never reached crier still ends the live session's credentials.
				if job.event == "end" and not job.spawned then
					drop_live_cache(nil)
				end
				runs.sweep(model.retention_days, model.retention_count)
			end,
		})
		scheduler = require("crier_obs.run.scheduler").new({
			obs = obs,
			clock = clock,
			model = model,
			enqueue = enqueue,
			log = log,
			drop_intervals = queue.drop_intervals,
			resolve_live = resolve_live,
			stream_uptime = stream_uptime,
			on_stream_end = function()
				drop_live_cache(nil)
			end,
		})
		if initialized then
			local found = 0
			for _, record in ipairs(runs.adopt()) do
				local p, ae = spawner.adopt(record)
				if p then
					adopted[#adopted + 1] = { process = p, record = record }
					found = found + (record.event == "drainer" and 0 or 1)
				else
					log.warn(ae.message)
				end
				for _, drainer in ipairs(record.drainers or {}) do
					local dp = spawner.adopt(drainer)
					if dp then
						adopted[#adopted + 1] = { process = dp, record = { event = "drainer", pid = drainer.pid } }
					end
				end
			end
			if found > 0 then
				log.info(
					"Adopted " .. found .. " detached post" .. (found == 1 and "" or "s") .. " from an earlier load"
				)
			end
			runs.sweep(model.retention_days, model.retention_count)
		end
		resolver.probe(model.crier_path)
		scheduler.load()
		obs.obs_frontend_add_event_callback(frontend_event)
		obs.timer_add(tick, 500)
		self.scheduler = scheduler
		self.queue = queue
	end
	function self.update(data)
		local next_model = model_port.snapshot(data)
		local changes = models.diff(model, next_model)
		log.set_debug(next_model.debug)
		if model and changes.debug and next_model.debug then
			log_inherited()
		end
		if model and changes.crier_path ~= nil then
			recheck = true
		end
		if
			model
			and (
				changes.platforms ~= nil
				or changes.credential_set ~= nil
				or changes.base_config ~= nil
				or changes.mode ~= nil
			)
		then
			live_recheck = true
			credential_revision = credential_revision + 1
			if scheduler then
				scheduler.stream.cache = {}
				scheduler.stream.cache_ready = false
			end
		end
		model = next_model
		refresh_frontend()
		if scheduler then
			scheduler.update(model)
		end
	end
	function self.save(data)
		secrets.scrub(data, nil, model and model.credential_set or "default")
	end
	function self.properties()
		return properties.build(settings)
	end
	function self.unload()
		if not loaded then
			return
		end
		-- An unload with no SCRIPTING_SHUTDOWN and no scene-collection switch before it is OBS ending.
		scheduler.unload()
		loaded = false
		obs.timer_remove(tick)
		obs.obs_frontend_remove_event_callback(frontend_event)
		local records, e = queue.detach({ skip = scheduler.closing() and QUIT_SKIP or nil })
		if e then
			log.error(e.message)
		end
		if records and #records > 0 then
			log.info(
				"Detached "
					.. #records
					.. " running post"
					.. (#records == 1 and "" or "s")
					.. "; the next load adopts them"
			)
		end
		for _, item in ipairs(adopted) do
			item.process.detach()
		end
		adopted = {}
		if preflight then
			preflight.inspection.cancel()
			preflight = nil
		end
		ping.detach()
		installer.detach()
		resolver.detach()
		if settings then
			secrets.scrub(settings, nil, model.credential_set)
		end
		secrets.close()
		log.clear_secrets()
		if settings then
			obs.obs_data_release(settings)
		end
		settings = nil
	end
	self.tick = tick
	self.event = frontend_event
	self.status = status
	self.callbacks = callbacks
	self.enqueue = enqueue
	return self
end
return M
