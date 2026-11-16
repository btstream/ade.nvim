-- Isolate every XDG directory a test can write: data holds agent installs,
-- state holds drafts and the log, cache holds image previews. Without the
-- state/cache overrides the suite clears the user's real drafts.json and
-- rewrites their log.
local isolated = string.format("/tmp/opencode/ade-test-%d", vim.uv.os_getpid())
vim.env.XDG_DATA_HOME = isolated .. "/data"
vim.env.XDG_STATE_HOME = isolated .. "/state"
vim.env.XDG_CACHE_HOME = isolated .. "/cache"
for _, dir in ipairs({ vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME }) do
  vim.fn.mkdir(dir, "p")
end

vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))

-- Optional test dependency: use a locally installed snacks.nvim when present so
-- the snacks-backed session browser is exercised instead of only the fallback.
-- Optional test dependency: edgy.nvim, for the layout integration tests.
local edgy_candidates = {
  vim.fn.expand("~/.local/share/nvim/lazy/edgy.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/deps/start/edgy.nvim"),
}
for _, dir in ipairs(edgy_candidates) do
  if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/edgy") == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end

local candidates = {
  vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/deps/start/snacks.nvim"),
}
local env_dir = os.getenv("ACP_TEST_SNACKS")
if env_dir and env_dir ~= "" then
  table.insert(candidates, 1, env_dir)
end

for _, dir in ipairs(candidates) do
  if dir and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/snacks") == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"

---------------------------------------------------------------------------
-- Optional service backend for the integration scripts.
--
-- Every integration script calls `ade.setup()`, so injecting the backend here
-- runs the *same* script against either transport:
--
--   ADE_TEST_BACKEND=service ADE_TEST_SERVICE_BIN=/path/to/nvim_ade_server \
--     nvim --headless -u tests/minimal_init.lua -l tests/integration.lua
--
-- The service directory and its token live under the isolated tree, so no test
-- can reach the user's real one. `keep_alive = false` keeps the scripts'
-- existing "the agent is gone afterwards" assumptions intact.
local backend = os.getenv("ADE_TEST_BACKEND")
local service_opts
if backend == "service" or backend == "auto" then
  local service_bin = os.getenv("ADE_TEST_SERVICE_BIN")
  if service_bin == nil or service_bin == "" then
    io.write("ADE_TEST_BACKEND=" .. backend .. " needs ADE_TEST_SERVICE_BIN\n")
    vim.cmd("cq 1")
  end
  local service_dir = isolated .. "/service"
  vim.fn.mkdir(service_dir, "p", 448)
  vim.env.NVIM_ADE_SERVER_DIR = service_dir
  vim.env.ADE_TEST_SERVICE_BIN = service_bin
  vim.env.ADE_TEST_BACKEND = backend
  service_opts = {
    backend = backend,
    service = {
      path = service_bin,
      keep_alive = false,
      -- The scripts finish in seconds; a service that lingers would keep the
      -- test run alive on a slow machine.
      idle_timeout = 60,
    },
  }
else
  -- No explicit test backend: keep the suite deterministic on the direct
  -- backend. The default `backend = "auto"` is covered by its own spec; here it
  -- would probe for a service in every setup and emit the one-off fallback
  -- notice into unrelated assertions.
  service_opts = { backend = "direct" }
end

-- Wrap `setup` once, in every module instance the scripts may require. The
-- plugin API and the controller both expose `setup`, and scripts use either.
local function wrap(module)
  if type(module) ~= "table" or type(module.setup) ~= "function" or module.__service_wrapped then
    return
  end
  local original = module.setup
  module.setup = function(opts, action)
    local merged = vim.tbl_deep_extend("force", {}, service_opts, opts or {})
    return original(merged, action)
  end
  module.__service_wrapped = true
end
wrap(require("ade"))
wrap(require("ade.controller"))

if backend == "service" or backend == "auto" then
  -- Stop the service before Neovim exits so a test run leaves no process
  -- behind. `:Ade service stop` is the documented path; a failure here is only
  -- logged, because it must not turn a passing run into a failing one.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(function()
        require("ade.service.commands").stop({ notify = function() end })
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- Test-isolation cleanup (kept as its own final section so concurrent edits to
-- the backend wiring above merge cleanly).
--
-- Every test process owns exactly one tree named after its pid. Delete that
-- tree on the way out; never touch a sibling's. A SIGKILL cannot run this, but
-- the path is per-pid, so a later process that recycles the pid deletes it at
-- its own exit.
--
-- `VimLeave`, not `VimLeavePre`: the plugin and the harness still log while the
-- pre-leave hooks run, and removing the log directory under them would print a
-- spurious "unable to write log file" warning.
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    local pid = vim.uv.os_getpid()
    local own = string.format("/tmp/opencode/ade-test-%d", pid)
    if isolated == own then
      pcall(vim.fn.delete, own, "rf")
    end
    -- Individual specs also build `/tmp/opencode/ade-*` trees keyed by this
    -- pid (wiring, s1b, manager, service, ...). Remove only names carrying this
    -- pid as a whole token; fixed names such as `ade-inline-guard` and every
    -- other process's directory are left alone.
    for _, pattern in ipairs({
      string.format("/tmp/opencode/ade-*-%d-*", pid),
      string.format("/tmp/opencode/ade-*-%d", pid),
      string.format("/tmp/opencode/ade-*-%d.json", pid),
      string.format("/tmp/opencode/ade-*-%d.log", pid),
    }) do
      for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
        pcall(vim.fn.delete, path, "rf")
      end
    end
  end,
})
