-- Report untested files as misses. These thresholds are release gates, not targets to round up.
local reporter = require("luacov.reporter")
local configuration = require("luacov").load_config()
configuration.includeuntestedfiles = { "src/crier_obs" }
local report, err = reporter.DefaultReporter:new(configuration)
assert(report, err)
report:run()
report:close()
local pure = {
	json = true,
	utf16 = true,
	errors = true,
	i18n = true,
	["proc/cmdline_windows"] = true,
	["schema/descriptor"] = true,
	["schema/layout"] = true,
	["invoke/datadoc"] = true,
	["invoke/plan"] = true,
	["invoke/builder"] = true,
	["invoke/report"] = true,
	["proc/resolver"] = true,
	["state/paths"] = true,
	["secrets/chacha20poly1305"] = true,
	["secrets/base64"] = true,
	["run/scheduler"] = true,
	["run/queue"] = true,
	["run/session"] = true,
	["run/job"] = true,
}
local hits, total, failed = 0, 0, false
for path, counts in pairs(report._summary) do
	local lines = counts.hits + counts.miss
	if lines > 0 then
		local percentage = counts.hits / lines * 100
		local name = path:match("src/crier_obs/(.-)%.lua$")
		local minimum = pure[name] and 100 or 90
		if percentage + 1e-9 < minimum then
			io.stderr:write(string.format("%s: %.2f%% < %d%%\n", path, percentage, minimum))
			failed = true
		end
		hits = hits + counts.hits
		total = total + lines
	end
end
local percent = total > 0 and hits / total * 100 or 0
print(string.format("Coverage: %d/%d lines (%.2f%%)", hits, total, percent))
if percent < 95 then
	io.stderr:write("Overall coverage is below 95%\n")
	failed = true
end
if failed then
	os.exit(1)
end
