local M = {}
local guidance = "Instagram needs a public URL. ngrok: install it, sign up, run ngrok config add-authtoken <token>, "
guidance = guidance .. "then select ngrok. The free tier interstitial breaks Meta fetching; use a paid plan or zrok. "
guidance = guidance .. "zrok: install it, run zrok invite and zrok enable <token>, then select zrok. "
guidance = guidance .. "S3 is an alternative without a tunnel."

M.strings = {
  ["en-US"] = {
    status = "Status",
    posting = "Posting",
    section = "Section",
    platforms = "Platforms",
    custom = "Custom platforms",
    render = "Render",
    video = "Video",
    staging = "Staging",
    advanced = "Advanced",
    install = "Install crier",
    update = "Update crier",
    refresh = "Refresh results",
    check = "Check setup",
    dry_run = "Send a test post (dry run)",
    post = "Post now",
    save = "Save credentials",
    forget = "Forget credentials",
    not_stored = "not stored",
    stored = "stored ✓",
    platform = "Platform to configure",
    custom_platform = "Custom platform to configure",
    guide = "How to get these values",
    custom_names = "Custom platform names",
    tunnel_guidance = guidance,
  },
}
function M.new(locale)
  local strings = M.strings[locale] or M.strings["en-US"]
  return function(key, ...)
    local s = strings[key] or M.strings["en-US"][key] or key
    if select("#", ...) > 0 then
      return string.format(s, ...)
    end
    return s
  end
end
M.t = M.new("en-US")
return M
