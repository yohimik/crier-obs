local datadoc = require("crier_obs.invoke.datadoc")
local builder = require("crier_obs.invoke.builder")
local job_module = require("crier_obs.run.job")
local descriptor = require("crier_obs.schema.descriptor")
local version = require("crier_obs.version")
local M = {}
function M.new(deps)
	deps = deps or {}
	local obs = deps.obs or require("crier_obs.ports.obs")
	local env = deps.env or require("crier_obs.ports.env").new({})
	local fs = deps.fs or require("crier_obs.ports.fs").new({ obs = obs, env = env })
	local clock = deps.clock or require("crier_obs.ports.clock").new({ obs = obs })
	local log = deps.log or require("crier_obs.log").new({ obs = obs, clock = clock })
	local store = deps.store or require("crier_obs.settings.store").new({ obs = obs })
	local model_port = deps.model or require("crier_obs.settings.model").new({ obs = obs, store = store })
	local paths = deps.paths
		or require("crier_obs.state.paths").new({
			env = env,
			state_dir = deps.state_dir or (env.getenv and env.getenv("CRIER_OBS_STATE_DIR")),
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
			json = require("crier_obs.json"),
		})
	local runs = deps.runs or require("crier_obs.state.runs").new({ fs = fs, clock = clock, paths = paths })
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
			spawner = spawner,
			resolver = resolver,
			state_dir = paths.root,
			pin = version.CRIER_VERSION,
		})
	local settings, model, scheduler, queue, spool
	local loaded = false
	local initialized = false
	local live_recheck = false
	local credential_revision = 0
	local adopted = {}
	local last_run = "No posts yet"
	local recheck = false
	local self = { paths = paths, spawner = spawner, secrets = secrets, resolver = resolver, runs = runs }
	local json = require("crier_obs.json")
	local function secret_keys(m)
		local keys = {}
		for _, d in ipairs(descriptor.build(m.custom_names)) do
			if
				d.secret
				and (
					(d.platform and m.platforms[d.platform])
					or (
						not d.platform
						and (
							not d.key:match("^stage%.s3%.")
							or m.values["stage.mode"] == "s3"
							or (m.mode == "advanced" and not m.touched["stage.mode"])
						)
					)
				)
			then
				keys[#keys + 1] = d.key
			end
		end
		return keys
	end
	local function resolve_live(session)
		local target = session
		local generation = session.generation
		local revision = credential_revision
		secrets.resolve(model.credential_set, secret_keys(model), function(values, e)
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
		end)
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
	local function enqueue(event, session, extra)
		if not initialized then
			log.error("State directory is unavailable", "state-dir")
			return
		end
		extra = extra or {}
		local session_generation = session and session.generation
		local snapshot_revision = credential_revision
		local snapshot = datadoc.copy(model)
		local front = datadoc.frontend(obs)
		local ss = session and session.snapshot() or {}
		if event == "replay" and (not front.replay_path or front.replay_path == "") then
			log.warn("Replay post skipped: no saved clip path is available")
			return
		end
		local count = 0
		for _, enabled in pairs(snapshot.platforms) do
			if enabled then
				count = count + 1
			end
		end
		if count == 0 then
			log.warn("No platform is selected; post skipped", "no-platforms")
			return
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
			return
		end
		if extra.immediate and session and not session.cache_ready and #secret_keys(snapshot) > 0 then
			log.warn("quit post skipped: credentials are not ready")
			return
		end
		local path, e = resolver.find(snapshot.crier_path)
		if not path then
			log.error(e.message, "missing-crier")
			return
		end
		local run, re = runs.create(event)
		if not run then
			log.error(re.message)
			return
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
			return
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
			log.error(pe.message)
			save_result(run, { code = 1, stderr = log.scrub(pe.message) })
			return
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
				if
					event == "end"
					and session
					and session.generation == session_generation
					and credential_revision == snapshot_revision
				then
					session.cache = {}
					if secrets.clear_cache then
						secrets.clear_cache()
					end
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
		end
		return job
	end
	local function find_binary(binary)
		if not binary or binary == "" then
			return nil
		end
		if binary:find("[/\\]") then
			return fs.exists(binary) and binary or nil
		end
		local augment = env.augmented_path or env.path
		local path = type(augment) == "function" and augment() or augment or ""
		for dir in path:gmatch(env.os == "Windows" and "[^;]+" or "[^:]+") do
			local full = dir .. "/" .. binary
			if fs.exists(full) then
				return full
			end
			if env.os == "Windows" and fs.exists(full .. ".exe") then
				return full .. ".exe"
			end
		end
	end
	local ping = deps.ping
		or require("crier_obs.run.ping").new({
			fs = fs,
			spawner = spawner,
			secrets = secrets,
			log = log,
			env = env,
			find_binary = find_binary,
			runs = runs,
		})
	local function status()
		local r = resolver.status()
		local install = installer.status()
		local secret_status = {}
		if model then
			for _, d in ipairs(descriptor.build(model.custom_names)) do
				if d.secret then
					local s = secrets.status(model.credential_set, d.key)
					secret_status[d.key] = s.message or s.state or "not stored"
				end
			end
		end
		local backend = secrets.backend_status and secrets.backend_status()
		return {
			crier = install.state == "installing" and install.message or r.message,
			keyring = backend and backend.message or secrets.backend_name or "OS credential store",
			last_run = last_run,
			logs = paths.runs,
			update_available = r.state == "outdated",
			secrets = secret_status,
			results = ping.rows(),
		}
	end
	local callbacks = {}
	callbacks.install = function()
		local _, e = installer.start()
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
		if ping.busy and ping.busy() then
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
	callbacks.save_secret = function(key)
		if settings then
			secrets.scrub(settings, nil, model.credential_set)
		end
		credential_revision = credential_revision + 1
		if scheduler then
			scheduler.stream.cache[key] = nil
			scheduler.stream.cache_ready = false
		end
		local value = secrets.pending(model.credential_set, key)
		if value and value ~= "" then
			secrets.commit(model.credential_set, key, value, function(ok, e)
				if not ok then
					log.error(e.message)
				else
					live_recheck = true
				end
			end)
		end
		return true
	end
	callbacks.forget_secret = function(key)
		credential_revision = credential_revision + 1
		if scheduler then
			scheduler.stream.cache[key] = nil
			scheduler.stream.cache_ready = false
		end
		secrets.forget(model.credential_set, key, function(ok, e)
			if not ok then
				log.error(e.message)
			else
				live_recheck = true
			end
		end)
		return true
	end
	callbacks.forget_all = function()
		for _, d in ipairs(descriptor.build(model.custom_names)) do
			if d.secret then
				callbacks.forget_secret(d.key)
			end
		end
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
	local function tick()
		if not loaded then
			return
		end
		local ok, e = pcall(function()
			secrets.tick()
			if spawner.reap then
				for _, record in ipairs(spawner.reap()) do
					if record.run then
						runs.journal(record.run, { state = "failed", pid = record.pid })
					end
				end
			end
			resolver.tick()
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
			scheduler.tick()
			queue.tick()
			for i = #adopted, 1, -1 do
				local item = adopted[i]
				local result, err = item.process.poll()
				if result or err then
					if result and item.record.event ~= "drainer" then
						last_run = "Last run finished with code " .. result.code
						log.info(last_run)
						if item.record.journal then
							runs.journal({
								event = item.record.event,
								created_at = item.record.created_at,
								journal = item.record.journal,
								status = item.record.status_path,
								pid = item.record.pid_path,
							}, { state = result.code == 0 and "done" or "failed", pid = item.record.pid })
						end
					elseif err then
						if item.process.cancel then
							item.process.cancel()
						else
							item.process.terminate()
							item.process.detach()
						end
						log.warn(err.message)
					end
					table.remove(adopted, i)
				end
			end
		end)
		if not ok then
			log.error(tostring(e), "heartbeat-error")
		end
	end
	local function frontend_event(event)
		local ok, e = pcall(function()
			scheduler.event(event)
		end)
		if not ok then
			log.error(tostring(e), "frontend-error")
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
		if obs.obs_data_addref then
			obs.obs_data_addref(settings)
		end
		model = model_port.snapshot(data)
		if log.set_debug then
			log.set_debug(model.debug)
		end
		loaded = true
		local ok, e = runs.init()
		initialized = ok == true
		if not ok then
			log.error(e.message)
		end
		spool = require("crier_obs.run.spool").new({
			fs = fs,
			paths = paths,
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
					last_run = job.result.message
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
		})
		if initialized then
			for _, record in ipairs(runs.adopt()) do
				local p, ae = spawner.adopt(record)
				if p then
					adopted[#adopted + 1] = { process = p, record = record }
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
		if log.set_debug then
			log.set_debug(next_model.debug)
		end
		if model and next_model.crier_path ~= model.crier_path then
			recheck = true
		end
		if
			model
			and (
				not require("crier_obs.settings.model").equal(model.platforms, next_model.platforms)
				or model.credential_set ~= next_model.credential_set
				or model.base_config ~= next_model.base_config
				or model.mode ~= next_model.mode
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
		loaded = false
		obs.timer_remove(tick)
		obs.obs_frontend_remove_event_callback(frontend_event)
		local _, e = queue.detach()
		if e then
			log.error(e.message)
		end
		for _, item in ipairs(adopted) do
			item.process.detach()
		end
		adopted = {}
		ping.detach()
		installer.detach()
		resolver.detach()
		if settings then
			secrets.scrub(settings, nil, model.credential_set)
		end
		if secrets.close then
			secrets.close()
		elseif secrets.unload then
			secrets.unload()
		elseif secrets.detach then
			secrets.detach()
		end
		if settings and obs.obs_data_release then
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
