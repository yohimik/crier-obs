local json = require("crier_obs.json")
local errors = require("crier_obs.errors")
local logger = require("crier_obs.log")
local i18n = require("crier_obs.i18n")
local descriptors = require("crier_obs.schema.descriptor")
local layout = require("crier_obs.schema.layout")
local models = require("crier_obs.settings.model")
local obs = require("stub.obslua")
local fs_module = require("crier_obs.ports.fs")
local env_module = require("crier_obs.ports.env")
local host = require("crier_obs.proc.host")
local builder = require("crier_obs.invoke.builder")
local ffi = require("ffi")

describe("strict JSON", function()
	it("round-trips objects, arrays, escapes, Unicode and null", function()
		local value = {
			bool = false,
			num = -12.25,
			utf8 = "🔴 日本語",
			empty = json.array(),
			null = json.null,
			escaped = '"\\\n\r\t\b\f\0',
			list = json.array({ 1, true, "x" }),
		}
		local encoded = assert(json.encode(value))
		local decoded = assert(json.decode(encoded))
		assert.equal(value.utf8, decoded.utf8)
		assert.equal(value.escaped, decoded.escaped)
		assert.equal("[]", json.encode(decoded.empty))
		assert.equal(json.null, decoded.null)
		assert.equal("🔴", json.decode('"\\uD83D\\uDD34"'))
		assert.equal(100, json.decode("1e2"))
		assert.equal(-0.125, json.decode("-1.25e-1"))
		assert.equal("a/b", json.decode('"a\\/b"'))
	end)
	it("rejects malformed input and invalid encodable values", function()
		for _, text in ipairs({
			"01e2",
			"1.e2",
			"00e0",
			"-01e1",
			"01",
			"-",
			"1e",
			"1e+",
			"[1,]",
			'{"a":1,}',
			'{"a":1,"a":2}',
			'"\\uD800"',
			'"\\uDC00"',
			'"\\uD800\\u0000"',
			'"\\uZZZZ"',
			'"\\x"',
			'"\n"',
			'"unterminated',
			"[",
			"{a:1}",
			'{"a" 1}',
			"true false",
			"NaN",
			"1e999",
			"[1 2]",
		}) do
			local value, err = json.decode(text)
			assert.is_nil(value, text)
			assert.equal("json", err.kind, text)
		end
		assert.is_nil(json.decode(5))
		assert.is_nil(json.decode(string.rep("[", 130)))
		local cyclic = {}
		cyclic.self = cyclic
		for _, v in ipairs({ cyclic, { [2] = "sparse" }, { [1] = "x", foo = "y" }, math.huge, 0 / 0, function() end }) do
			assert.is_nil(json.encode(v))
		end
		assert.equal("false", json.encode(false))
		assert.equal("null", json.encode(json.null))
		assert.equal("null", tostring(json.null))
		assert.equal("é", json.decode('"\\u00e9"'))
		assert.equal("日", json.decode('"\\u65e5"'))
	end)
end)

describe("errors and translated messages", function()
	it("maps every exit and signal and falls back to English", function()
		for _, code in ipairs({ 0, 1, 2, 3, 4, 5, 6, 97, 126, 127, 99 }) do
			assert.is_string(errors.from_exit(code).message)
		end
		assert.equal("signal", errors.from_exit(nil, 9).kind)
		assert.equal("crashed", errors.from_exit(0xC0000005).kind)
		assert.equal("timeout", errors.timeout().kind)
		assert.equal("Status", i18n.new("xx-XX")("status"))
		assert.equal("unknown", i18n.new("xx-XX")("unknown"))
		i18n.strings.test = { hello = "Hello %s" }
		assert.equal("Hello world", i18n.new("test")("hello", "world"))
	end)
end)

describe("secret scrubbing and rate limiting", function()
	it("drops a debug line before scrubbing it while Debug logging is off", function()
		local lines = {}
		local log = logger.new({
			obs = {
				LOG_DEBUG = 400,
				LOG_INFO = 300,
				script_log = function(level, text)
					lines[#lines + 1] = { level, text }
				end,
			},
		})
		local scrubbed, scrub = 0, log.scrub
		log.scrub = function(v)
			scrubbed = scrubbed + 1
			return scrub(v)
		end
		log.register_secret("HEARTBEAT_SECRET")
		local emitted = log.debug("spawning keyring: HEARTBEAT_SECRET")
		assert.equal(0, scrubbed)
		assert.same({}, lines)
		assert.is_false(emitted)
		log.set_debug(true)
		assert.is_true(log.debug("spawning keyring: HEARTBEAT_SECRET"))
		assert.equal(1, scrubbed)
		assert.same({ { 300, "crier-obs: [debug] spawning keyring: ***" } }, lines)
		log.set_debug(false)
		assert.is_true(log.info("plain HEARTBEAT_SECRET"))
		assert.equal(2, scrubbed)
		assert.same({ 300, "crier-obs: plain ***" }, lines[2])
	end)
	it("scrubs literal secrets and credential-shaped URLs on all levels", function()
		local now = 0
		local log = logger.new({
			obs = obs,
			clock = {
				now_mono = function()
					return now
				end,
			},
			debug = true,
		})
		log.register_secret("a.[secret]%")
		log.register_secret("secret")
		log.register_secret("")
		local text = log.scrub("a.[secret]% /api/webhooks/123/abc bot123:abc ?token=abc&x=y password=abc")
		assert.is_nil(text:find("secret", 1, true))
		assert.is_nil(text:find("abc", 1, true))
		for _, level in ipairs({ "debug", "info", "warn", "error" }) do
			assert.is_true(log[level]("secret"))
		end
		assert.equal(obs.LOG_WARNING, obs.logs[#obs.logs - 1].level)
		assert.is_true(log.warn("first", "key", 10))
		assert.is_false(log.warn("second", "key", 10))
		now = 10
		assert.is_true(log.warn("third", "key", 10))
		assert.equal("token=*** ordinary=value", log.scrub("token=unknown ordinary=value"))
		assert.equal('{"client-***":"***","title":"safe"}', log.scrub('{"client-secret":"unknown","title":"safe"}'))
		log.register_secret('line\nquote"')
		assert.equal("***", log.scrub('line\\nquote\\"'))
		for _, token in ipairs({ 'a"TAILSECRET', "back\\slash\nTAILSECRET", "end\\" }) do
			log.register_secret(token)
			local clean = log.scrub(assert(json.encode({ token = token })))
			assert.is_nil(clean:find("TAILSECRET", 1, true))
			assert.equal("***", assert(json.decode(clean)).token)
			assert.equal("***", log.scrub(token))
		end
		local unknown = log.scrub('{"token":"a\\"UNKNOWN_SUFFIX"}')
		assert.equal("***", assert(json.decode(unknown)).token)
		assert.equal('{"token":"***"', log.scrub('{"token":"unterminated'))
		-- OBS shows LOG_DEBUG only with --verbose: the Debug logging setting lifts debug lines to
		-- LOG_INFO with a [debug] marker; without it they are dropped.
		local debug_log = logger.new({ obs = obs })
		local before = #obs.logs
		assert.is_false(debug_log.debug("quiet line"))
		assert.equal(before, #obs.logs)
		debug_log.set_debug(true)
		assert.is_true(debug_log.debug_enabled())
		assert.is_true(debug_log.debug("visible line"))
		assert.same({ level = obs.LOG_INFO, text = "crier-obs: [debug] visible line" }, obs.logs[#obs.logs])
		debug_log.info("plain info")
		assert.same({ level = obs.LOG_INFO, text = "crier-obs: plain info" }, obs.logs[#obs.logs])
		debug_log.set_debug(false)
		assert.is_false(debug_log.debug("quiet again"))
		assert.same({ level = obs.LOG_INFO, text = "crier-obs: plain info" }, obs.logs[#obs.logs])
		log.register_secret("a/b?c d")
		assert.equal(
			"https://example.test/***?other=***",
			log.scrub("https://example.test/a%2Fb%3Fc+d?other=a%2fb%3fc%20d")
		)
		log.register_secret("a+b&c:d e")
		assert.equal("https://example.test/***", log.scrub("https://example.test/a+b&c:d%20e"))
		assert.equal("other=***", log.scrub("other=a%2Bb%26c%3Ad+e"))
		log.register_secret("<&>\226\128\168\226\128\169")
		assert.equal('{"error":"***"}', log.scrub('{"error":"\\u003c\\u0026\\u003e\\u2028\\u2029"}'))
		log.clear_secrets()
		assert.equal("secret", log.scrub("secret"))
		assert.is_true(logger.new({}).info("x"))
		assert.is_true(logger.new({ debug = true }).debug("x"))
	end)
end)

describe("registry, model and OBS properties", function()
	local data, model
	before_each(function()
		obs.reset()
		data = obs.obs_data_create()
		model = models.new({ obs = obs })
		model.defaults(data, "/template.html")
	end)
	after_each(function()
		obs.obs_data_release(data)
		obs.assert_no_leaks()
	end)
	it("has the complete pin and safe numeric descriptors and custom expansions", function()
		local meta = require("crier_obs.registry.meta")
		assert.equal(#require("crier_obs.registry.keys"), meta.count)
		assert.equal(#require("crier_obs.registry.custom"), meta.custom_count)
		local all = descriptors.build({ "mine", "mine", "telegram", "BAD" })
		assert.equal(meta.count + meta.custom_count, #all)
		local seen = {}
		for _, d in ipairs(all) do
			assert.is_nil(seen[d.key])
			seen[d.key] = true
			if d.kind == "int" or d.kind == "float" then
				assert.is_number(d.min)
				assert.is_number(d.max)
				assert.is_number(d.step)
			end
			if not d.custom and not d.secret then
				assert.is_not_nil(data.defaults[d.key])
			end
		end
		assert.is_false(descriptors.valid_custom("telegram"))
		assert.is_false(descriptors.valid_custom("-bad"))
		assert.is_true(descriptors.valid_custom("my-tool1"))
		assert.is_true(layout.visible({ section = "render" }, { section = "render" }))
		assert.is_false(layout.visible({ section = "render" }, { section = "video" }))
		assert.is_true(
			layout.visible(
				{ section = "platforms", platform = "telegram" },
				{ section = "platforms", platform = "telegram" }
			)
		)
		assert.is_false(
			layout.visible({ section = "custom", platform = "one" }, { section = "custom", custom_platform = "two" })
		)
	end)
	it("reads editable lists with balanced references and compares effective values", function()
		local store = require("crier_obs.settings.store").new({ obs = obs })
		store.set(data, "cobs.custom_names", "list", { "mine" })
		store.set(data, "cobs.custom_fields", "list", { "hello=world", "with=equals=sign" })
		store.set(data, "render.width", "int", 900)
		store.set(data, "render.video.crf", "float", 23.5)
		local snapshot = model.snapshot(data)
		assert.same({ "mine" }, snapshot.custom_names)
		assert.equal(900, snapshot.values["render.width"])
		assert.is_true(snapshot.touched["render.width"])
		assert.equal(1080, snapshot.values["render.height"])
		assert.is_false(snapshot.touched["render.height"])
		assert.same({}, model.diff(snapshot, snapshot))
		assert.is_false(models.equal({ a = 1 }, { a = 1, b = 2 }))
		assert.is_false(models.equal(1, "1"))
		assert.is_false(models.equal({ a = 1 }, { a = 2 }))
		assert.is_not_nil(model.diff(nil, snapshot).values)
		store.unset(data, "render.width")
		assert.is_false(store.has(data, "render.width"))
		store.set(data, "cobs.base_config", "string", "/base.json")
		assert.equal("advanced", model.snapshot(data).mode)
	end)
end)

describe("native filesystem and environment ports #posix", function()
	it("creates private files without replacement and writes atomically", function()
		local fs = fs_module.new({ obs = obs })
		local dir = "/tmp/crier-obs-foundation-" .. tonumber(ffi.C.getpid())
		assert(fs.mkdir_private(dir))
		local path = dir .. "/secret"
		fs.remove(path)
		assert(fs.create_private(path, "abc"))
		local ok, err = fs.create_private(path, "wrong")
		assert.is_nil(ok)
		assert.equal("exists", err.kind)
		assert.equal("abc", fs.read(path))
		assert(fs.write_private(path, "new"))
		assert.equal("new", fs.read(path))
		assert(fs.write(dir .. "/ordinary", "hello"))
		assert.is_true(fs.exists(path))
		assert.equal(2, #fs.glob(dir .. "/*"))
		assert.equal(2, #fs.list(dir))
		assert.equal(32, #assert(fs.random_bytes(32)))
		assert(fs.rename(dir .. "/ordinary", dir .. "/renamed"))
		fs.remove(dir .. "/renamed")
		fs.remove(path)
		assert(fs.rmdir(dir))
		assert.is_nil(fs.read(dir .. "/missing"))
		assert.is_nil(fs.write_private(dir .. "/missing", "x"))
		assert.is_nil(fs.create_private(dir .. "/missing", "x"))
		assert.is_nil(fs.write(dir .. "/missing", "x"))
		assert.same({}, fs.glob(dir .. "/*"))
		local env = env_module.new({
			getenv = function(k)
				if k == "HOME" then
					return "/home/u"
				end
				if k == "PATH" then
					return "/usr/bin"
				end
			end,
		})
		assert.is_string(env.path("/extra"))
		assert.is_table(env.inherited())
		assert.is_table(env.crier_names())
		assert.is_false(env.flatpak())
		assert.is_true(env_module
			.new({
				getenv = function()
					return "sandbox"
				end,
			})
			.flatpak())
	end)
end)

describe("OBS stub timer identity", function()
	it("defers registration and keeps different closures distinct", function()
		local count = 0
		local function tick()
			count = count + 1
		end
		obs.timer_add(tick, 500)
		obs.timer_remove(function() end)
		obs.advance(2)
		assert.equal(4, count)
		obs.timer_remove(tick)
		obs.advance(2)
		assert.equal(4, count)
	end)
end)

describe("portable filesystem and environment glue", function()
	it("uses UTF-16 Windows APIs and preserves inherited drive variables", function()
		local utf16 = require("crier_obs.utf16")
		local function wide(text)
			local encoded = assert(utf16.encode(text))
			local data = ffi.new("uint16_t[?]", #encoded / 2 + 1)
			ffi.copy(data, encoded, #encoded)
			return data
		end
		local block = wide("=C:=C:\\\0SystemRoot=C:\\Windows\0CRIER_TOKEN=secret\0\0")
		local closed = 0
		local env = env_module.new({
			platform = "Windows",
			C = {
				GetEnvironmentStringsW = function()
					return block
				end,
				FreeEnvironmentStringsW = function(value)
					assert.equal(block, value)
					return 1
				end,
			},
			getenv = function(key)
				return ({ USERPROFILE = "C:/User", LOCALAPPDATA = "C:/Local", PATH = "C:/Windows" })[key]
			end,
		})
		assert.equal("C:\\", env.inherited()["=C:"])
		assert.equal("C:\\Windows", env.inherited().SystemRoot)
		assert.same({ "CRIER_TOKEN" }, env.crier_names())
		assert.matches("WinGet", env.augmented_path(), 1, true)
		local no_env = env_module.new({
			platform = "Windows",
			C = {
				GetEnvironmentStringsW = function()
					return nil
				end,
			},
		})
		assert.same({}, no_env.inherited())
		local C = {
			CreateFileW = function(path)
				assert.matches("secret", assert(utf16.decode(ffi.string(path, 12))), 1, true)
				return ffi.cast("void*", 1)
			end,
			WriteFile = function(_, data, count, written)
				assert.equal("abc", data)
				written[0] = count
				return 1
			end,
			CloseHandle = function()
				closed = closed + 1
				return 1
			end,
			GetLastError = function()
				return 80
			end,
			FindFirstFileW = function(_, data)
				ffi.copy(data[0].name, (assert(utf16.encode("file 🔴.txt"))))
				return ffi.cast("void*", 1)
			end,
			FindNextFileW = function()
				return 0
			end,
			FindClose = function()
				closed = closed + 1
				return 1
			end,
		}
		local bcrypt = {
			BCryptGenRandom = function(_, buffer, count)
				ffi.fill(buffer, count, 7)
				return 0
			end,
		}
		local fs = fs_module.new({ obs = obs, platform = "Windows", C = C, bcrypt = bcrypt })
		assert(fs.create_private("secret", "abc"))
		assert.equal(1, closed)
		assert.same({ "folder/file 🔴.txt" }, fs.glob("folder/*"))
		assert.equal(string.rep("\7", 8), fs.random_bytes(8))
		local temp = os.tmpname()
		os.remove(temp)
		assert(fs.mkdir_private(temp))
		assert(fs.write_private(temp .. "/data", "abc"))
		fs.remove(temp .. "/data")
		fs.rmdir(temp)
		C.CreateFileW = function()
			return ffi.cast("void*", -1)
		end
		local ok, e = fs.create_private("secret", "abc")
		assert.is_nil(ok)
		assert.equal("exists", e.kind)
		C.GetLastError = function()
			return 5
		end
		assert.equal("filesystem", select(2, fs.create_private("secret", "abc")).kind)
		C.CreateFileW = function()
			return ffi.cast("void*", 1)
		end
		C.WriteFile = function()
			return 0
		end
		assert.is_nil(fs.create_private("secret", "abc"))
		C.FindFirstFileW = function()
			return ffi.cast("void*", -1)
		end
		assert.same({}, fs.glob("folder/*"))
		bcrypt.BCryptGenRandom = function()
			return -1
		end
		assert.is_nil(fs.random_bytes(8))
	end)
	it("returns filesystem errors, retries interrupted writes and closes failed reads", function()
		local calls = 0
		local C = {
			open = function()
				return 4
			end,
			close = function()
				return 0
			end,
			unlink = function()
				return 0
			end,
			rename = function()
				return 0
			end,
			fchmod = function()
				return 0
			end,
			getpid = function()
				return 123
			end,
			write = function(_, _, n)
				calls = calls + 1
				if calls == 1 then
					ffi.errno(4)
					return -1
				end
				return n
			end,
			read = function(_, buffer, n)
				ffi.fill(buffer, n, 65)
				return n
			end,
		}
		local fake_obs = {
			os_mkdirs = function()
				return 0
			end,
			os_file_exists = function()
				return true
			end,
		}
		local fs = fs_module.new({ obs = fake_obs, C = C, platform = "OSX" })
		assert(fs.write_private("file", "abcdef"))
		calls = 0
		assert(fs.create_private("file", "abc"))
		assert.equal("AAA", fs.random_bytes(3))
		C.write = function()
			return 0
		end
		assert.is_nil(fs.write_private("file", "abc"))
		assert.is_nil(fs.create_private("file", "abc"))
		C.read = function()
			return 0
		end
		assert.is_nil(fs.random_bytes(3))
		C.open = function()
			ffi.errno(13)
			return -1
		end
		assert.is_nil(fs.random_bytes(3))
		assert.is_nil(fs.mkdir_private("dir"))
		C.open = function()
			return 4
		end
		C.fchmod = function()
			return -1
		end
		assert.is_nil(fs.mkdir_private("dir"))
		fake_obs.os_mkdirs = function()
			return -1
		end
		assert.is_nil(fs.mkdir_private("dir"))
		C.close = function()
			return -1
		end
		C.write = function(_, _, n)
			return n
		end
		assert.is_nil(fs.write_private("file", "abc"))
		assert.is_nil(fs.create_private("file", "abc"))
		local linuxenv = env_module.new({
			platform = "Linux",
			C = { environ = ffi.new("char*[1]") },
			getenv = function()
				return nil
			end,
		})
		assert.same({}, linuxenv.inherited())
	end)
	it("provides a monotonic clock and direct OBS port", function()
		package.preload.obslua = function()
			return obs
		end
		assert.equal(obs, require("crier_obs.ports.obs"))
		local clock = require("crier_obs.ports.clock").new({
			obs = {
				os_gettime_ns = function()
					return 12500000000
				end,
			},
		})
		assert.equal(12.5, clock.now_mono())
		assert.is_number(clock.now_wall())
		assert.is_string(require("crier_obs.templates").live)
		assert.is_string(require("crier_obs.version").VERSION)
	end)
end)

describe("Flatpak host policy", function()
	local function environment(extra)
		local vars = { HOME = "/home/u", PATH = "/usr/bin:/bin" }
		for k, v in pairs(extra or {}) do
			vars[k] = v
		end
		return env_module.new({
			platform = "Linux",
			getenv = function(k)
				return vars[k]
			end,
			C = {
				access = function()
					return -1
				end,
			},
		})
	end
	local fs = {
		exists = function(path)
			return path == "/usr/bin/flatpak-spawn"
		end,
	}
	it("detects both markers and reports absent or sandboxed host access honestly", function()
		local native = environment()
		assert.is_false(native.flatpak())
		assert.is_false(native.snap())
		assert.equal("native", native.sandbox_status(fs).kind)
		assert.is_nil(native.path():match("^:"))
		local no_home = env_module.new({
			platform = "Linux",
			getenv = function(k)
				if k == "FLATPAK_ID" then
					return "obs"
				end
			end,
			C = {
				access = function()
					return -1
				end,
			},
		})
		assert.is_nil(host.prepare({ executable = "crier", env = {} }, no_home, fs))
		assert.is_nil(no_home.path():match("^:"))
		local plan = { executable = "/bin/true" }
		assert.equal(plan, host.prepare(plan, native, fs))
		local marker = env_module.new({
			platform = "Linux",
			C = {
				access = function()
					return 0
				end,
			},
			getenv = function()
				return nil
			end,
		})
		assert.is_true(marker.flatpak())
		local disk = env_module.new({
			platform = "Linux",
			fs = {
				exists = function()
					return true
				end,
			},
			getenv = function()
				return nil
			end,
		})
		assert.is_true(disk.flatpak())
		local flatpak = environment({ FLATPAK_ID = "com.obsproject.Studio" })
		local missing = {
			exists = function()
				return false
			end,
		}
		assert.is_false(flatpak.sandbox_status(missing).ok)
		assert.equal("sandbox", select(2, host.prepare(plan, flatpak, missing)).kind)
		assert.equal("snap", environment({ SNAP = "/snap/obs" }).sandbox_status(fs).kind)
		assert.is_true(environment({ SNAP_NAME = "obs" }).snap())
	end)
	it("forwards secrets only through an independent env fd and validates shared paths", function()
		local flatpak = environment({ FLATPAK_ID = "com.obsproject.Studio" })
		local plan = {
			executable = "/home/u/.local/bin/crier",
			args = {
				"--config",
				"/home/u/run/config.json",
				"--publish-input",
				"/home/u/clip.mp4",
				"--render-output",
				"/home/u/run/preview.png",
				"--set",
				"render.data=/home/u/data.json",
			},
			cwd = "/home/u/run",
			stdin = "/home/u/input",
			stdout = "/home/u/output",
			stderr = "/home/u/error",
			status_path = "/home/u/status",
			pid_path = "/home/u/pid",
			env = {
				PATH = "/usr/bin",
				CRIER_TOKEN = "secret 🔴",
				LD_LIBRARY_PATH = "/app/lib",
				FLATPAK_ID = "sandbox",
			},
			files = {
				["/home/u/run/config.json"] = assert(json.encode({
					render = {
						template = "/home/u/live.html",
						overlays = json.array({ "/home/u/overlay.html" }),
						data = "/home/u/data.json",
					},
					publish = { telegram = { overlay = json.array({ "/home/u/p.html" }) } },
				})),
			},
		}
		plan.path_keys = builder.path_keys({})
		local prepared = assert(host.prepare(plan, flatpak, fs))
		assert.equal("/usr/bin/flatpak-spawn", prepared.executable)
		assert.equal("--env-fd=3", prepared.args[2])
		assert.equal("--clear-env", prepared.args[3])
		assert.equal("--watch-bus", prepared.args[4])
		assert.is_nil(prepared.cwd)
		assert.matches("CRIER_TOKEN=secret 🔴", prepared.env_fd_data, 1, true)
		assert.is_nil(prepared.env_fd_data:find("LD_LIBRARY_PATH", 1, true))
		for _, arg in ipairs(prepared.args) do
			assert.is_nil(arg:find("secret 🔴", 1, true))
		end
		assert.equal("/home/u/run", plan.cwd)
		local no_cwd = { executable = "/usr/bin/crier", args = { "--version" }, env = {} }
		assert(host.prepare(no_cwd, flatpak, fs))
		local cases = {
			{ cwd = "/tmp" },
			{ executable = "/app/bin/crier" },
			{ executable = "/tmp/crier" },
			{ executable = "/run/crier" },
			{ executable = "/home/u/a/../crier" },
			{ stdin = "/tmp/input" },
			{ files = { ["/tmp/config.json"] = "{}" } },
			{ files = { ["/home/u/config.json"] = "invalid" } },
			{ files = { ["/home/u/config.json"] = '{"render":{"template":"/tmp/t.html"}}' } },
			{ files = { ["/home/u/config.json"] = '{"render":{"overlays":["/tmp/t.html"]}}' } },
			{ args = { "--config", "/tmp/cfg" } },
			{ args = { "--set", "render.data=/tmp/data.json" } },
			{ args = { "--set", "render.template=relative.html" } },
			{ env = { ["BAD=NAME"] = "value" } },
			{ env = { VALUE = "bad\0value" } },
			{ args = { "--set", "publish.custom.mine.overlay=/home/u/ok.html,/tmp/t.html" } },
		}
		for _, override in ipairs(cases) do
			local current =
				{ executable = "/usr/bin/crier", env = {}, cwd = "/home/u", path_keys = builder.path_keys({ "mine" }) }
			for k, v in pairs(override) do
				current[k] = v
			end
			assert.is_nil(host.prepare(current, flatpak, fs))
		end
		assert(host.prepare({
			executable = "/usr/bin/crier",
			env = {},
			files = { ["/home/u/config.json"] = '{"render":{"data":"env:MY","base-url":"https://example.com"}}' },
		}, flatpak, fs))
	end)
end)
