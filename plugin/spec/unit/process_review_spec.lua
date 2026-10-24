package.path = "plugin/src/?.lua;src/?.lua;" .. package.path
local spawner = require("crier_obs.proc.spawner")
local resolver = require("crier_obs.proc.resolver")

describe("process review regressions", function()
	it("normalizes Windows environment names and strips credentials regardless of case", function()
		local captured
		local backend = {
			spawn = function(plan)
				captured = plan.env
				return {
					poll = function()
						return { code = 0 }
					end,
					terminate = function() end,
					kill = function() end,
				}
			end,
		}
		local s = spawner.new({
			platform = "Windows",
			backend = backend,
			env = {
				inherited = function()
					return { Path = "old", SystemRoot = "C:\\Windows", crier_token = "bad", ["=C:"] = "C:\\work" }
				end,
				path = function()
					return "new"
				end,
			},
		})
		assert(s.spawn({ executable = "crier.exe", env = { CrIeR_TOKEN = "stored" } }))
		assert.same(
			{ PATH = "new", SYSTEMROOT = "C:\\Windows", CRIER_TOKEN = "stored", ["=C:"] = "C:\\work" },
			captured
		)
		assert(s.spawn({ executable = "crier.exe" }))
		assert.is_nil(captured.CRIER_TOKEN)
	end)

	it("rejects malformed versions instead of presenting them as the pinned release", function()
		for _, version in ipairs({
			"1.1.1junk",
			"01.1.1",
			"1.01.1",
			"1.1.01",
			"1.1.1-",
			"1.1.1+",
			"1.1.1-rc..1",
			"1.1.1-01",
			"1.1.1+bad+build",
			"1.1.1-rc.",
			"1.1.1-.rc",
		}) do
			local cmp, err = resolver.compare(version, "1.1.1")
			assert.is_nil(cmp, version)
			assert.equals("version", err.kind)
		end
		assert.equals(0, resolver.compare("v1.1.1+build.001", "1.1.1"))
		assert.equals(-1, resolver.compare("1.1.1-rc.2", "1.1.1-rc.10"))
	end)
end)
