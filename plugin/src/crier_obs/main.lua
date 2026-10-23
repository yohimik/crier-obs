local version = require("crier_obs.version")
local plugin = require("crier_obs.plugin").new({})
function script_description()
	return "crier-obs "
		.. version.VERSION
		.. " — publish stream announcements with crier "
		.. version.CRIER_VERSION
		.. ". Configure platforms, save credentials, then enable your triggers."
end
function script_defaults(settings)
	plugin.defaults(settings)
end
function script_load(settings)
	plugin.load(settings)
end
function script_update(settings)
	plugin.update(settings)
end
function script_save(settings)
	plugin.save(settings)
end
function script_properties()
	return plugin.properties()
end
function script_unload()
	plugin.unload()
end
return {
	plugin = plugin,
	VERSION = version.VERSION,
	CRIER_VERSION = version.CRIER_VERSION,
	script_description = script_description,
	script_defaults = script_defaults,
	script_load = script_load,
	script_update = script_update,
	script_save = script_save,
	script_properties = script_properties,
	script_unload = script_unload,
}
