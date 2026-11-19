-- The service version this plugin was written against.
--
-- The Rust service lives in `service/` and has its own version. The plugin
-- requests exactly this release: `service.install` downloads
-- `nvim_ade_server-v<VERSION>`, and `tests/spec_service.lua` fails when
-- `service/Cargo.toml` disagrees.
--
-- `api_version` is the integer front-end protocol version from
-- `service/PROTOCOL.md`. It changes only when the JSON-RPC surface breaks.
--
-- Everything in the plugin and its tests reads these two constants; no test may
-- hardcode a version or an API version, so bumping this file is the only edit
-- a version change needs.
local M = {}

M.VERSION = "0.7.1"
M.API_VERSION = 6

---Release tag the prebuilt archives are published under.
---@return string
function M.release_tag()
  return "nvim_ade_server-v" .. M.VERSION
end

---Name of the archive for one release target.
---@param version string
---@param target string
---@param extension string "tar.gz" or "zip"
---@return string
function M.archive_name(version, target, extension)
  return string.format("nvim_ade_server-%s-%s.%s", version, target, extension)
end

return M
