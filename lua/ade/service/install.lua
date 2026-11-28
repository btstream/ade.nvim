-- Install, update and select the nvim_ade_server binary.
--
-- The install is deliberately the same shape as the managed agent install in
-- `lua/ade/manager/`: a version directory plus an atomically replaced pointer.
--
--   <data>/ade/service/current           {"schemaVersion":1,"version":"..."}
--   <data>/ade/service/<version>/nvim_ade_server
--   <data>/ade/service/downloads/…       archives and SHA256SUMS, one run only
--   <data>/ade/service/build/            cargo target-dir for the fallback
--
-- Two entry points:
--
--   * `M.run(opts)` — synchronous, for a plugin-manager `build` hook;
--   * `M.install_async(opts)` — the `:Ade service install` command.
--
-- Every collaborator is injectable (`download`, `extract`, `sha256`, `run`,
-- `uname`), so the tests never touch the network or run cargo. Both public
-- functions return false instead of raising: a failed install must leave the
-- plugin working in direct mode.
local log = require("ade.log")
local Paths = require("ade.service.paths")
local Platform = require("ade.service.platform")
local Version = require("ade.service.version")

local M = {}

local SCHEMA_VERSION = 1

---Current schema of the `current` pointer, kept in one place for the tests.
M.SCHEMA_VERSION = SCHEMA_VERSION

---Default release host. Overridable with `service.release_base`.
M.DEFAULT_RELEASE_BASE = "https://github.com/btstream/ade.nvim/releases/download"

---The service installation root.
---@param opts {data_dir?: string}|nil
---@return string
function M.root(opts)
  local data = (opts and opts.data_dir) or vim.fn.stdpath("data")
  return data .. "/ade/service"
end

---The version directory for `version`.
---@param version string
---@param opts {data_dir?: string}|nil
---@return string
function M.version_dir(version, opts)
  return M.root(opts) .. "/" .. version
end

---The binary inside a version directory.
---@param version string
---@param opts {data_dir?: string, target?: string}|nil
---@return string
function M.binary(version, opts)
  opts = opts or {}
  local target = opts.target or Platform.detect() or "x86_64-unknown-linux-musl"
  local name = Platform.binary_name(target)
  return M.version_dir(version, opts) .. "/" .. name
end

---@param path string
---@return table|nil
local function read_json(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  if not text or text == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

---Write JSON through a sibling temp file and rename it into place.
---
---Renaming within one directory is atomic, which is what keeps a crash from
---leaving a half-written pointer behind.
---@param path string
---@param value table
---@return boolean ok
---@return string|nil err
function M.write_json_atomic(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, "unable to encode " .. path
  end
  local tmp = path .. ".tmp-" .. tostring(vim.uv.hrtime())
  local fh, err = io.open(tmp, "wb")
  if not fh then
    return false, "unable to write " .. tmp .. ": " .. tostring(err)
  end
  local written = fh:write(encoded)
  fh:close()
  if not written then
    os.remove(tmp)
    return false, "unable to write " .. tmp
  end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false, "unable to replace " .. path .. ": " .. tostring(rename_err)
  end
  return true
end

---The version the `current` pointer selects, or nil.
---@param opts {data_dir?: string}|nil
---@return string|nil
function M.current_version(opts)
  local value = read_json(M.root(opts) .. "/current")
  if not value or value.schemaVersion ~= SCHEMA_VERSION then
    return nil
  end
  if type(value.version) ~= "string" or value.version == "" then
    return nil
  end
  return value.version
end

---The binary the `current` pointer selects, or nil when nothing is installed.
---@param opts {data_dir?: string, target?: string}|nil
---@return string|nil path
---@return string|nil version
function M.current_binary(opts)
  local version = M.current_version(opts)
  if not version then
    return nil, nil
  end
  local path = M.binary(version, opts)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, version
  end
  return path, version
end

---Run `<bin> version` and parse the one-line JSON contract reply.
---
---The probe is also the only check needed for `service.path`: a user-built
---binary is trusted if it answers with the version the plugin expects.
---@param argv string[]
---@param opts {timeout?: integer, run?: function}|nil
---@return table|nil info
---@return string|nil err
function M.probe_version(argv, opts)
  opts = opts or {}
  local run = opts.run
    or function(cmd, run_opts)
      local ok, result = pcall(vim.system, cmd, run_opts)
      if not ok then
        return { code = -1, stdout = "", stderr = tostring(result) }
      end
      local awaited = result:wait(run_opts and run_opts.timeout or 5000)
      return { code = awaited.code or -1, stdout = awaited.stdout or "", stderr = awaited.stderr or "" }
    end
  local result = run(argv, { text = true, timeout = opts.timeout or 5000 })
  if type(result) ~= "table" then
    return nil, "version probe returned no result"
  end
  if result.code ~= 0 then
    local tail = vim.trim((result.stderr ~= "" and result.stderr or result.stdout) or "")
    if #tail > 300 then
      tail = tail:sub(-300)
    end
    return nil,
      string.format(
        "%s exited with %s%s",
        table.concat(argv, " "),
        tostring(result.code),
        tail ~= "" and ": " .. tail or ""
      )
  end
  local line = (result.stdout or ""):match("([^\n]+)")
  if not line then
    return nil, "version probe printed nothing"
  end
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then
    return nil, "version probe did not print JSON: " .. line:sub(1, 120)
  end
  if type(decoded.version) ~= "string" or type(decoded.api_version) ~= "number" then
    return nil, "version reply is missing version or api_version"
  end
  return decoded
end

---Check one binary against the required version and API version.
---@param path string
---@param opts {run?: function, timeout?: integer}|nil
---@return boolean ok
---@return string|nil err
function M.verify_binary(path, opts)
  local info, err = M.probe_version({ path, "version" }, opts)
  if not info then
    return false, err
  end
  if info.version ~= Version.VERSION then
    return false, string.format("expected service version %s, got %s", Version.VERSION, tostring(info.version))
  end
  if info.api_version ~= Version.API_VERSION then
    return false, string.format("expected api_version %d, got %s", Version.API_VERSION, tostring(info.api_version))
  end
  return true, nil
end

---Resolve the configured `service.path`, verifying it runs and matches.
---
---Thin wrapper over `resolve_binary` kept for the install command's version
---probe: same rules, same entry point, so `service.path` is never interpreted
---two different ways.
---@param opts {path: string, run?: function, timeout?: integer}
---@return table|nil info `{version, api_version}`
---@return string|nil warning_or_err
function M.check_configured(opts)
  local resolved, err = M.resolve_binary({ path = opts.path, run = opts.run, timeout = opts.timeout })
  if not resolved then
    return nil, err
  end
  return { version = resolved.version, api_version = resolved.api_version }, resolved.warning
end

---Resolve the binary to run, from one place.
---
---Sources, in order:
---
---  1. `service.path` (or `opts.path`): a user-built binary. It must run and
---     speak the same `api_version`; a different `version` is allowed with a
---     warning, because the wire protocol is what actually has to match.
---  2. the managed install's `current` pointer.
---
---A missing install is an explicit "not installed" error, never a silent
---fallback: the caller decides whether to suggest `:Ade service install` or
---fall back to the direct backend.
---
---This is the only place that answers "which binary runs". Status, start,
---health and (from S1) the backend connection all call it, so they cannot
---disagree about whether `service.path` is in effect.
---@param opts {path?: string, config?: table, data_dir?: string, target?: string,
---  run?: function, timeout?: integer, probe?: boolean}|nil
---@return table|nil resolved `{path, source, version, api_version, warning}`
---@return string|nil err
function M.resolve_binary(opts)
  opts = opts or {}
  local configured = opts.path
  if configured == nil and type(opts.config) == "table" and type(opts.config.service) == "table" then
    configured = opts.config.service.path
  end

  if type(configured) == "string" and configured ~= "" then
    local expanded = vim.fs.normalize(vim.fn.expand(configured))
    local stat = vim.uv.fs_stat(expanded)
    if not stat or stat.type ~= "file" then
      return nil, "service.path does not exist or is not a file: " .. expanded
    end
    if vim.fn.executable(expanded) ~= 1 then
      return nil, "service.path is not executable: " .. expanded
    end
    local info, err = M.probe_version({ expanded, "version" }, opts)
    if not info then
      return nil, "service.path is not runnable: " .. tostring(err)
    end
    if info.api_version ~= Version.API_VERSION then
      return nil,
        string.format(
          "service.path speaks api_version %s, but this plugin needs %d; rebuild it against the current service",
          tostring(info.api_version),
          Version.API_VERSION
        )
    end
    local warning
    if info.version ~= Version.VERSION then
      warning = string.format(
        "service.path is version %s, but the plugin was written for %s; api_version %d matches, so it will be used",
        tostring(info.version),
        Version.VERSION,
        Version.API_VERSION
      )
    end
    return {
      path = expanded,
      source = "configured",
      configured_path = configured,
      version = info.version,
      api_version = info.api_version,
      warning = warning,
    },
      nil
  end

  local binary, pointer_version = M.current_binary({ data_dir = opts.data_dir, target = opts.target })
  if not binary then
    if pointer_version then
      return nil, "the installed service binary is missing; run :Ade service install"
    end
    return nil, "nvim_ade_server is not installed; run :Ade service install (or set service.path to a built binary)"
  end
  if vim.fn.executable(binary) ~= 1 then
    return nil, "the service binary is not executable: " .. binary
  end

  local resolved = { path = binary, source = "managed", version = pointer_version, api_version = nil }
  if opts.probe ~= false then
    -- A managed install was verified when it was written, but a hand-edited
    -- tree or a partially removed release would only fail later, mid-turn.
    local info, err = M.probe_version({ binary, "version" }, opts)
    if not info then
      return nil, "the installed service does not run: " .. tostring(err)
    end
    if info.api_version ~= Version.API_VERSION then
      return nil,
        string.format(
          "the installed service speaks api_version %s, but this plugin needs %d; run :Ade service install",
          tostring(info.api_version),
          Version.API_VERSION
        )
    end
    resolved.version = info.version
    resolved.api_version = info.api_version
    if pointer_version and info.version ~= pointer_version then
      resolved.warning = string.format(
        "the installed service reports version %s but the pointer says %s",
        tostring(info.version),
        tostring(pointer_version)
      )
    end
  end
  return resolved, nil
end

---Parse a SHA256SUMS file and return the digest for one file name.
---@param text string
---@param name string
---@return string|nil digest
function M.digest_for(text, name)
  for line in (text or ""):gmatch("[^\n]+") do
    -- "sha  name" or "sha *name" (binary marker); names may contain spaces.
    local digest, rest = line:match("^(%x+)%s+%*?(.+)$")
    if digest and #digest == 64 and rest == name then
      return digest:lower()
    end
  end
  return nil
end

---The expected sha256 of a file on disk, lowercase.
---@param path string
---@return string|nil
function M.sha256_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  if type(data) ~= "string" then
    return nil
  end
  local ok, digest = pcall(vim.fn.sha256, data)
  if not ok or type(digest) ~= "string" then
    return nil
  end
  return digest:lower()
end

---@param path string
---@return boolean
local function executable(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return false
  end
  return vim.fn.executable(path) == 1 or stat.mode % 128 >= 64
end

---Point `current` at a fully verified version directory.
---
---The new directory must already contain a binary that answers `version`
---correctly; the pointer is then replaced atomically, so a concurrent reader
---sees either the old or the new install and never a partial one.
---@param version string
---@param opts {data_dir?: string, target?: string, run?: function}
---@return boolean ok
---@return string|nil err
function M.activate(version, opts)
  opts = opts or {}
  local binary = M.binary(version, opts)
  if not executable(binary) then
    return false, "the service binary is missing or not executable: " .. binary
  end
  local ok, err = M.verify_binary(binary, opts)
  if not ok then
    return false, err
  end
  local root = M.root(opts)
  local made, mkdir_err = pcall(vim.fn.mkdir, root, "p")
  if not made then
    return false, "unable to create " .. root .. ": " .. tostring(mkdir_err)
  end
  local written, write_err = M.write_json_atomic(root .. "/current", {
    schemaVersion = SCHEMA_VERSION,
    version = version,
    activatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
  if not written then
    return false, write_err
  end
  return true
end

---@param message string
---@param opts table|nil
local function progress(opts, message)
  if opts and type(opts.on_progress) == "function" then
    pcall(opts.on_progress, message)
  else
    log.info("service: %s", message)
  end
end

---The transport restrictions for one download URL.
---
---`SHA256SUMS` and the archive come from the same host, so the checksum only
---proves anything when the transport cannot be rewritten in flight. https
---everywhere; plain http only for a loopback host, where there is no network to
---attack and a local test server is handy.
---
---Redirects are stricter on purpose: curl cannot restrict a redirect target by
---host, so `--proto-redir` allows https only. A loopback http base may still
---redirect to https, which is the useful case; redirecting to another plain
---http host is exactly what the https requirement exists to prevent.
---@param url string
---@return {proto: string, proto_redir: string}
function M.transport_rules(url)
  if require("ade.service.url").is_loopback_http(url) then
    return { proto = "=http,https", proto_redir = "=https" }
  end
  return { proto = "=https", proto_redir = "=https" }
end

---Build the curl argv for one download.
---
---Exported so tests can assert the transport restrictions without running
---anything.
---@param url string
---@param dest string
---@param opts {timeout: integer}
---@return string[]
function M.curl_argv(url, dest, opts)
  local rules = M.transport_rules(url)
  return {
    "curl",
    "--fail",
    "--location",
    "--silent",
    "--show-error",
    "--proto",
    rules.proto,
    "--proto-redir",
    rules.proto_redir,
    "--max-redirs",
    "5",
    "--retry",
    "2",
    "--connect-timeout",
    "20",
    "--max-time",
    tostring(math.max(1, math.floor(opts.timeout / 1000))),
    "--output",
    dest,
    url,
  }
end

---Default downloader: `curl` in argv form, never a shell string.
---
---`opts.run` is injectable so tests can inspect the argv without touching the
---network.
---@param url string
---@param dest string
---@param opts {timeout: integer, run?: function}
---@return boolean ok
---@return string|nil err
local function curl(url, dest, opts)
  local argv = M.curl_argv(url, dest, opts)
  local result
  if type(opts.run) == "function" then
    result = opts.run(argv, { text = true, timeout = opts.timeout })
  else
    local ok, proc = pcall(vim.system, argv, { text = true })
    if not ok then
      return false, "unable to run curl: " .. tostring(proc)
    end
    local awaited = proc:wait(opts.timeout)
    result = { code = awaited.code or -1, stdout = awaited.stdout or "", stderr = awaited.stderr or "" }
  end
  if type(result) ~= "table" then
    return false, "curl returned no result"
  end
  if result.code ~= 0 then
    local reason = vim.trim((result.stderr or ""):sub(-300))
    return false, string.format("curl exited with %s%s", tostring(result.code), reason ~= "" and ": " .. reason or "")
  end
  return true, nil
end

---Default extractor: `tar`/`unzip` into a directory, argv form.
---@param archive string
---@param dest string
---@param opts {timeout: integer}
---@return boolean ok
---@return string|nil err
local function extract(archive, dest, opts)
  local ok_mkdir, mkdir_err = pcall(vim.fn.mkdir, dest, "p")
  if not ok_mkdir then
    return false, "unable to create " .. dest .. ": " .. tostring(mkdir_err)
  end
  local argv
  if archive:sub(-4) == ".zip" then
    argv = { "unzip", "-o", "-q", archive, "-d", dest }
  else
    argv = { "tar", "-xzf", archive, "-C", dest }
  end
  local ok, result = pcall(vim.system, argv, { text = true })
  if not ok then
    return false, "unable to run " .. argv[1] .. ": " .. tostring(result)
  end
  local awaited = result:wait(opts.timeout)
  if awaited.code ~= 0 then
    local reason = vim.trim((awaited.stderr or ""):sub(-300))
    return false,
      string.format("%s exited with %s%s", argv[1], tostring(awaited.code), reason ~= "" and ": " .. reason or "")
  end
  return true, nil
end

---Find the binary inside an extracted archive.
---
---Archives are built with the binary at the top level, but a handful of
---`tar`/`zip` invocations add a wrapping directory, so the search is bounded
---and shallow instead of assuming a layout.
---@param dir string
---@param target string
---@return string|nil path
local function find_binary(dir, target)
  local name = Platform.binary_name(target)
  local direct = dir .. "/" .. name
  if executable(direct) then
    return direct
  end
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local entry, kind = vim.uv.fs_scandir_next(handle)
    if not entry then
      break
    end
    if kind == "directory" then
      local nested = dir .. "/" .. entry .. "/" .. name
      if executable(nested) then
        return nested
      end
    end
  end
  return nil
end

---@param path string
local function remove_quietly(path)
  pcall(vim.fn.delete, path, "rf")
end

---Install one already-verified directory into place and activate it.
---@param staged string directory containing the binary
---@param version string
---@param target string
---@param opts table
---@return boolean ok
---@return string|nil err
local function commit(staged, version, target, opts)
  local found = find_binary(staged, target)
  if not found then
    return false, "the archive did not contain " .. Platform.binary_name(target)
  end
  local dest = M.version_dir(version, opts)
  remove_quietly(dest)
  local made, mkdir_err = pcall(vim.fn.mkdir, dest, "p")
  if not made then
    return false, "unable to create " .. dest .. ": " .. tostring(mkdir_err)
  end
  local name = Platform.binary_name(target)
  local final = dest .. "/" .. name
  local copied, copy_err = vim.uv.fs_copyfile(found, final)
  if not copied then
    return false, "unable to install the service binary: " .. tostring(copy_err)
  end
  pcall(vim.uv.fs_chmod, final, 448) -- 0700
  local ok, err = M.activate(version, { data_dir = opts.data_dir, target = target, run = opts.run })
  if not ok then
    remove_quietly(dest)
    return false, err
  end
  return true
end

---Try the prebuilt release: download the archive and its checksums, verify,
---extract, then commit. Any failure is reported, never raised.
---@param opts table
---@return boolean ok
---@return string|nil err
local function install_prebuilt(opts)
  local target = opts.target
  if not target then
    return false, "this platform has no prebuilt service build"
  end
  local root = M.root(opts)
  local work = root .. "/downloads/" .. tostring(vim.uv.hrtime())
  local made, mkdir_err = pcall(vim.fn.mkdir, work, "p")
  if not made then
    return false, "unable to create " .. work .. ": " .. tostring(mkdir_err)
  end
  local base = (opts.release_base or M.DEFAULT_RELEASE_BASE):gsub("/+$", "")
  -- Defence in depth: `config.validate` rejects a non-loopback http base, but
  -- `M.run` is also called directly by install hooks and tests, so the check is
  -- repeated where the URL is about to be fetched.
  local Url = require("ade.service.url")
  local base_err = Url.release_base_error(base)
  if base_err then
    return false, base_err
  end
  local extension = Platform.extension(target)
  local archive_name = Version.archive_name(Version.VERSION, target, extension)
  local url = string.format("%s/%s/%s", base, Version.release_tag(), archive_name)
  local sums_url = string.format("%s/%s/SHA256SUMS", base, Version.release_tag())
  local archive = work .. "/" .. archive_name
  local sums = work .. "/SHA256SUMS"

  progress(opts, "downloading " .. url)
  local download_opts = { timeout = opts.timeout, run = opts.download_run }
  local ok, err = opts.download(url, archive, download_opts)
  if not ok then
    remove_quietly(work)
    return false, "download failed: " .. tostring(err)
  end
  ok, err = opts.download(sums_url, sums, download_opts)
  if not ok then
    remove_quietly(work)
    return false, "checksum download failed: " .. tostring(err)
  end

  local fh = io.open(sums, "rb")
  local sums_text = fh and fh:read("*a") or ""
  if fh then
    fh:close()
  end
  local expected = M.digest_for(sums_text, archive_name)
  if not expected then
    remove_quietly(work)
    return false, "SHA256SUMS has no entry for " .. archive_name
  end
  local actual = opts.sha256(archive)
  if actual ~= expected then
    remove_quietly(work)
    return false,
      string.format("checksum mismatch for %s (expected %s, got %s)", archive_name, expected, tostring(actual))
  end

  local staged = work .. "/unpacked"
  progress(opts, "extracting " .. archive_name)
  ok, err = opts.extract(archive, staged, { timeout = opts.timeout })
  if not ok then
    remove_quietly(work)
    return false, "extraction failed: " .. tostring(err)
  end
  local committed, commit_err = commit(staged, Version.VERSION, target, opts)
  remove_quietly(work)
  if not committed then
    return false, commit_err
  end
  return true, nil
end

---Compile the service from `service/` with cargo.
---
---The nightly channel is selected by `service/rust-toolchain.toml`, so a
---rustup-managed cargo uses it automatically. A plain cargo that does not honour
---that file simply builds with whatever it has; the version probe afterwards
---decides whether the result is usable, so a wrong build is rejected rather
---than installed silently.
---@param opts table
---@return boolean ok
---@return string|nil err
local function install_compiled(opts)
  local service_dir = opts.source_dir
  local manifest = service_dir .. "/Cargo.toml"
  if vim.fn.filereadable(manifest) ~= 1 then
    return false, "the service sources are missing: " .. manifest
  end
  if opts.cargo_available and not opts.cargo_available() then
    return false, "cargo was not found on PATH"
  end
  local target = opts.target or Platform.detect() or "unknown"
  local target_dir = M.root(opts) .. "/build"
  local argv = {
    opts.cargo or "cargo",
    "build",
    "--release",
    "--locked",
    "--manifest-path",
    manifest,
    "--target-dir",
    target_dir,
  }
  progress(opts, "building the service with cargo (nightly selected by service/rust-toolchain.toml)")
  local result = opts.run(argv, { cwd = service_dir, timeout = opts.timeout })
  if type(result) ~= "table" or result.code ~= 0 then
    local tail = type(result) == "table" and vim.trim((result.stderr or result.stdout or ""):sub(-800)) or ""
    return false, "cargo build failed" .. (tail ~= "" and ": " .. tail or "")
  end
  local built = target_dir .. "/release/" .. Platform.binary_name(target)
  if not executable(built) then
    return false, "cargo build finished but produced no binary at " .. built
  end
  local version_dir = M.version_dir(Version.VERSION, opts)
  remove_quietly(version_dir)
  local made, mkdir_err = pcall(vim.fn.mkdir, version_dir, "p")
  if not made then
    return false, "unable to create " .. version_dir .. ": " .. tostring(mkdir_err)
  end
  local final = version_dir .. "/" .. Platform.binary_name(target)
  local copied, copy_err = vim.uv.fs_copyfile(built, final)
  if not copied then
    return false, "unable to copy the built service: " .. tostring(copy_err)
  end
  pcall(vim.uv.fs_chmod, final, 448)
  local activated, activate_err =
    M.activate(Version.VERSION, { data_dir = opts.data_dir, target = target, run = opts.run })
  if not activated then
    remove_quietly(version_dir)
    return false, activate_err
  end
  return true, nil
end

---Human-readable recovery advice printed when both paths fail.
---@param prebuilt_err string|nil
---@param compiled_err string|nil
---@return string[]
function M.failure_hint(prebuilt_err, compiled_err)
  return {
    "ade.nvim: the nvim_ade_server service could not be installed.",
    "  download: " .. tostring(prebuilt_err),
    "  compile:  " .. tostring(compiled_err),
    '  The plugin keeps working with backend = "direct".',
    "  To finish the install:",
    "    * keep rustup installed so `cargo` honours service/rust-toolchain.toml",
    "      (it installs nightly automatically if missing), then rerun",
    "      `:Ade service install`;",
    "    * or build the service yourself and set `service.path` to the binary;",
    "    * or download a prebuilt archive from",
    "      " .. M.DEFAULT_RELEASE_BASE .. "/" .. Version.release_tag(),
  }
end

---Collect the collaborators, replacing missing ones with the real defaults.
---@param opts table|nil
---@return table
local function with_defaults(opts)
  opts = vim.tbl_deep_extend("force", {
    timeout = 10 * 60 * 1000,
    release_base = M.DEFAULT_RELEASE_BASE,
    cargo = "cargo",
  }, opts or {})
  ---Run one process and wait for it, with a hard timeout.
  local function system_run(argv, run_opts)
    local ok, result = pcall(vim.system, argv, vim.tbl_extend("force", { text = true }, run_opts or {}))
    if not ok then
      return { code = -1, stdout = "", stderr = tostring(result) }
    end
    local awaited = result:wait(run_opts and run_opts.timeout or 300000)
    return { code = awaited.code or -1, stdout = awaited.stdout or "", stderr = awaited.stderr or "" }
  end
  opts.download = opts.download or curl
  opts.extract = opts.extract or extract
  opts.sha256 = opts.sha256 or M.sha256_file
  opts.run = opts.run or system_run
  -- The real curl runs through `download`, and its argv is what the transport
  -- restrictions live in; tests replace this to inspect that argv.
  opts.download_run = opts.download_run or system_run
  if opts.target == nil then
    opts.target = Platform.detect(opts.uname)
  end
  -- `source_dir` is the injected spelling of the plugin's `service/` tree.
  -- Tests must never depend on whether the real crate is checked out on this
  -- branch: they inject a temporary or non-existent directory instead.
  if opts.source_dir == nil then
    opts.source_dir = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h"))
      .. "/service"
  end
  if opts.cargo_available == nil then
    opts.cargo_available = function()
      return vim.fn.executable(opts.cargo) == 1
    end
  end
  return opts
end

---Install the service: skip when present, else prebuilt, else compile.
---
---Concurrency is left to the plugin manager: `run()` is a build hook that runs
---while the plugin is being updated, and the atomic pointer makes a rerun
---harmless. Returns false instead of raising on every failure, because an
---install failure must not break the plugin.
---@param opts {data_dir?: string, release_base?: string, timeout?: integer,
---  target?: string|nil, uname?: table, path?: string, download?: function,
---  extract?: function, sha256?: function, run?: function, cargo?: string,
---  cargo_available?: function, source_dir?: string,
---  on_progress?: fun(message: string)}|nil
---@return boolean ok
---@return string|nil err
function M.run(opts)
  opts = with_defaults(opts)
  progress(opts, "checking for nvim_ade_server " .. Version.VERSION)

  -- A configured `service.path` is the user's own build: the only useful check
  -- is that it runs and speaks a compatible api_version. Nothing is downloaded
  -- or compiled over it.
  local configured = opts.path
  if configured == nil and type(opts.config) == "table" and type(opts.config.service) == "table" then
    configured = opts.config.service.path
  end
  if type(configured) == "string" and configured ~= "" then
    local resolved, err = M.resolve_binary({ path = configured, run = opts.run, timeout = opts.timeout })
    if not resolved then
      local hint = "ade.nvim: " .. tostring(err)
      log.warn("%s", hint)
      if type(opts.on_notify) == "function" then
        pcall(opts.on_notify, hint)
      end
      return false, hint
    end
    if resolved.warning then
      log.warn("%s", resolved.warning)
      if type(opts.on_notify) == "function" then
        pcall(opts.on_notify, resolved.warning)
      end
    end
    progress(opts, "service.path is usable: " .. resolved.path)
    return true, nil
  end

  local installed, version = M.current_binary({ data_dir = opts.data_dir, target = opts.target })
  if installed then
    local ok = M.verify_binary(installed, opts)
    if ok then
      progress(opts, "service " .. tostring(version) .. " is already installed: " .. installed)
      return true, nil
    end
    progress(opts, "the installed service does not match; reinstalling")
  end

  local prebuilt_ok, prebuilt_err = install_prebuilt(opts)
  if prebuilt_ok then
    progress(opts, "installed the prebuilt service " .. Version.VERSION)
    return true, nil
  end
  progress(opts, "prebuilt install unavailable: " .. tostring(prebuilt_err))

  local compiled_ok, compiled_err = install_compiled(opts)
  if compiled_ok then
    progress(opts, "installed the compiled service " .. Version.VERSION)
    return true, nil
  end

  local hint = table.concat(M.failure_hint(prebuilt_err, compiled_err), "\n")
  log.warn("%s", hint)
  if type(opts.on_notify) == "function" then
    pcall(opts.on_notify, hint)
  end
  return false, hint
end

---`:Ade service install`: install in the background and report progress.
---
---`vim.system` already runs asynchronously; this wrapper only keeps the editor
---responsive while the prompt is shown and reports the outcome as a
---notification, matching the other `:Ade` commands.
---@param opts table|nil
function M.install_async(opts)
  opts = with_defaults(opts)
  local notify = opts.on_notify or function(message)
    vim.notify(message, vim.log.levels.INFO)
  end
  opts.on_progress = function(message)
    vim.schedule(function()
      log.info("service: %s", message)
    end)
  end
  vim.schedule(function()
    local ok, err = M.run(opts)
    if ok then
      notify("ade.nvim: nvim_ade_server " .. Version.VERSION .. " installed")
    else
      notify(tostring(err))
    end
  end)
end

return M
