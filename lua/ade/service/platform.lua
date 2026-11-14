-- Mapping from the running machine to a prebuilt release target.
--
-- The release matrix lives in `.acp-work/design.md` §6.3. A platform that is
-- not listed here has no prebuilt archive, and the installer falls back to
-- compiling from `service/`.
local M = {}

M.TARGETS = {
  linux = {
    x86_64 = "x86_64-unknown-linux-musl",
    aarch64 = "aarch64-unknown-linux-musl",
  },
  darwin = {
    x86_64 = "x86_64-apple-darwin",
    arm64 = "aarch64-apple-darwin",
  },
  windows = {
    x86_64 = "x86_64-pc-windows-msvc",
  },
}

---The archive extension for one target.
---@param target string
---@return string
function M.extension(target)
  return target:find("windows", 1, true) and "zip" or "tar.gz"
end

---The executable name inside an extracted archive.
---@param target string
---@return string
function M.binary_name(target)
  return target:find("windows", 1, true) and "nvim_ade_server.exe" or "nvim_ade_server"
end

---Normalise the architecture names `os_uname()` reports.
---
---Linux says `x86_64`/`aarch64`; macOS reports `arm64` for the same thing, and
---older kernels report `amd64` on some distributions.
---@param machine string|nil
---@return string|nil
local function arch(machine)
  if type(machine) ~= "string" then
    return nil
  end
  local value = machine:lower()
  local aliases = {
    x86_64 = "x86_64",
    amd64 = "x86_64",
    aarch64 = "aarch64",
    arm64 = "arm64",
  }
  return aliases[value]
end

---The release target for this machine, or nil when there is no prebuilt build.
---
---`uname` is injected so tests can cover every platform on one host.
---@param uname table|nil result of `vim.uv.os_uname()`
---@return string|nil target
function M.detect(uname)
  uname = uname or vim.uv.os_uname()
  local sysname = type(uname.sysname) == "string" and uname.sysname:lower() or ""
  local machine = arch(uname.machine)
  if not machine then
    return nil
  end
  local family
  if sysname == "linux" then
    family = "linux"
    -- musl targets are not aarch64-only on paper, but the matrix builds these
    -- two combinations; anything else compiles locally.
    if machine == "arm64" then
      machine = "aarch64"
    end
  elseif sysname == "darwin" then
    family = "darwin"
  elseif sysname:find("windows", 1, true) or sysname:find("mingw", 1, true) or sysname:find("msys", 1, true) then
    family = "windows"
  else
    return nil
  end
  local by_arch = M.TARGETS[family]
  return by_arch and by_arch[machine] or nil
end

return M
