std = "luajit"
not_globals = {"error"}
max_line_length = 140
globals = {"script_defaults", "script_description", "script_load", "script_update", "script_properties", "script_save", "script_unload"}
exclude_files = {"dist/**", ".cache/**"}

files["src/crier_obs/registry/*.lua"] = {max_line_length = false}
files["src/crier_obs/templates.lua"] = {max_line_length = false}
files["tools/smoke.lua"] = {globals = {"error", "print"}, not_globals = {}}
