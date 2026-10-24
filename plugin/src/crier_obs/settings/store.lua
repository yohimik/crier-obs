local M = {}
function M.new(deps)
	local obs = assert(deps.obs)
	local self = {}
	function self.has(data, key)
		return obs.obs_data_has_user_value(data, key)
	end
	function self.unset(data, key)
		obs.obs_data_unset_user_value(data, key)
	end
	local function kind(d)
		return type(d) == "table" and d.kind or d
	end
	function self.get(data, key, d)
		local t = kind(d)
		if t == "list" then
			local array = obs.obs_data_get_array(data, key)
			local out = {}
			if array then
				for i = 0, obs.obs_data_array_count(array) - 1 do
					local item = obs.obs_data_array_item(array, i)
					out[#out + 1] = obs.obs_data_get_string(item, "value")
					obs.obs_data_release(item)
				end
				obs.obs_data_array_release(array)
			end
			return out
		end
		local suffix = t == "bool" and "bool" or t == "int" and "int" or t == "float" and "double" or "string"
		return obs["obs_data_get_" .. suffix](data, key)
	end
	local function put(data, key, d, value, default)
		local t = kind(d)
		local prefix = default and "obs_data_set_default_" or "obs_data_set_"
		if t == "list" then
			local array = obs.obs_data_array_create()
			for _, v in ipairs(value or {}) do
				local item = obs.obs_data_create()
				obs.obs_data_set_string(item, "value", v)
				obs.obs_data_array_push_back(array, item)
				obs.obs_data_release(item)
			end
			obs[prefix .. "array"](data, key, array)
			obs.obs_data_array_release(array)
		else
			local suffix = t == "bool" and "bool" or t == "int" and "int" or t == "float" and "double" or "string"
			obs[prefix .. suffix](data, key, value)
		end
	end
	function self.set(data, key, d, value)
		put(data, key, d, value, false)
	end
	function self.default(data, key, d, value)
		put(data, key, d, value, true)
	end
	return self
end
return M
