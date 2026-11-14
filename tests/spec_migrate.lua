-- Regression tests for the one-shot migration of the pre-rename paths.
--
-- The migration must never lose an installed agent or a draft, must never
-- overwrite a new directory, and must stay harmless when there is nothing to
-- move. Every case builds its own XDG roots under /tmp, so neither the shared
-- test directories nor the user's real ones are involved.
return function(t)
  local Migrate = require("ade.migrate")

  ---Point the XDG variables at a private tree and return the stdpath roots the
  ---plugin will actually use. Restored by `t.cleanup` at the end of the test.
  local function isolate(tag)
    local base = string.format("/tmp/opencode/migrate-%s-%d-%d", tag, vim.uv.os_getpid(), vim.uv.hrtime())
    local saved = {
      data = vim.env.XDG_DATA_HOME,
      state = vim.env.XDG_STATE_HOME,
      cache = vim.env.XDG_CACHE_HOME,
    }
    vim.env.XDG_DATA_HOME = base .. "/xdgdata"
    vim.env.XDG_STATE_HOME = base .. "/xdgstate"
    vim.env.XDG_CACHE_HOME = base .. "/xdgcache"
    for _, key in ipairs({ "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME" }) do
      vim.fn.mkdir(vim.env[key], "p")
    end
    t.cleanup(function()
      vim.env.XDG_DATA_HOME = saved.data
      vim.env.XDG_STATE_HOME = saved.state
      vim.env.XDG_CACHE_HOME = saved.cache
      vim.fn.delete(base, "rf")
    end)
    return {
      base = base,
      data = vim.fn.stdpath("data"),
      state = vim.fn.stdpath("state"),
      log = vim.fn.stdpath("log"),
    }
  end

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end

  local function read(path)
    return table.concat(vim.fn.readfile(path), "\n")
  end

  ---Build an old-style managed install under `<data>/acp/agents`.
  local function fake_install(data)
    local root = data .. "/acp/agents"
    local store = require("ade.manager.store").new({
      root = function()
        return root
      end,
    })
    local install = "1.2.3"
    local release = assert(store:release_dir("pi", install))
    write(release .. "/node_modules/@geohar/pi-acp/dist/index.js", "#!/usr/bin/env node\n")
    assert(store:write_receipt("pi", {
      installId = install,
      package = "@geohar/pi-acp",
      version = install,
      entry = "node_modules/@geohar/pi-acp/dist/index.js",
      runtime = "node",
    }))
    assert(store:write_pointer("pi", install))
    return root
  end

  ---Run the migration against the given roots, quietly.
  local function run(roots, opts)
    Migrate.reset()
    return Migrate.run(vim.tbl_extend("force", {
      data_dir = roots.data,
      state_dir = roots.state,
      log_dir = roots.log,
      notify = false,
    }, opts or {}))
  end

  local function status_of(results, label)
    for _, item in ipairs(results) do
      if item.label == label then
        return item.status
      end
    end
    return nil
  end

  ---Write a lease record the way the manager would.
  ---@param data string the pre-migration data root
  ---@param opts {pid?: integer, age_ms?: integer}
  local function write_lease(data, opts)
    local lock = require("ade.manager.lock")
    opts = opts or {}
    local dir = data .. "/acp/agents/.leases/pi"
    vim.fn.mkdir(dir, "p")
    assert(lock.write_json_atomic(dir .. "/lease-" .. tostring(opts.pid or 1234567) .. ".json", {
      host = lock.hostname(),
      pid = opts.pid or 1234567,
      installId = "1.2.3",
      heartbeat = lock.now() - (opts.age_ms or 0),
      startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }))
  end

  ---Write an install lock record the way `Lock:acquire` would.
  ---@param data string the pre-migration data root
  ---@param opts {pid?: integer, age_ms?: integer}
  local function write_lock(data, opts)
    local lock = require("ade.manager.lock")
    opts = opts or {}
    local dir = data .. "/acp/agents/.locks/pi"
    vim.fn.mkdir(dir, "p")
    assert(lock.write_json_atomic(dir .. "/owner.json", {
      host = lock.hostname(),
      pid = opts.pid or 1234567,
      action = "install",
      acquiredAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      heartbeat = lock.now() - (opts.age_ms or 0),
    }))
  end

  t.describe("legacy directory migration", function()
    t.it("moves the data, state and log paths in one shot", function()
      local roots = isolate("full")
      fake_install(roots.data)
      write(roots.state .. "/acp/drafts.json", '{"k":{"cwd":"/tmp","text":"hello"}}')
      write(roots.log .. "/acp.nvim.log", "old log line\n")
      t.truthy(vim.fn.isdirectory(roots.data .. "/acp/agents") == 1, "the fixture did not create the old install")

      local results = run(roots)
      t.eq("migrated", status_of(results, "data"))
      t.eq("migrated", status_of(results, "state"))
      t.eq("migrated", status_of(results, "log"))

      t.eq(0, vim.fn.isdirectory(roots.data .. "/acp"), "the old data directory must be gone")
      t.eq(0, vim.fn.isdirectory(roots.state .. "/acp"), "the old state directory must be gone")
      t.eq(0, vim.fn.filereadable(roots.log .. "/acp.nvim.log"), "the old log must be gone")
      t.eq(1, vim.fn.filereadable(roots.log .. "/ade.nvim.log"), "the log must exist under its new name")
      t.eq(1, vim.fn.isdirectory(roots.data .. "/ade/agents/pi"), "the agent tree must move as a whole")
      t.eq(1, vim.fn.filereadable(roots.state .. "/ade/drafts.json"), "the drafts must move as a whole")
    end)

    t.it("keeps an already installed agent usable through the manager", function()
      local roots = isolate("agent")
      fake_install(roots.data)
      local results = run(roots)
      t.eq("migrated", status_of(results, "data"))

      -- The receipt stores only a relative entrypoint, so the manager must find
      -- the moved release without any path rewriting.
      local Config = require("ade.config")
      local Resolve = require("ade.manager.resolve")
      local cfg = Config.validate(Config.merge(Config.defaults, {}))
      cfg.launch_origin = {}
      t.eq(roots.data .. "/ade/agents", Resolve.manager_root(cfg))

      local spec, err = Resolve.resolve(cfg, "pi", cfg.launch_origin)
      t.truthy(spec, "the migrated install must resolve: " .. tostring(err))
      t.eq("managed", spec.source)
      t.eq("1.2.3", spec.install_id)
      t.eq(roots.data .. "/ade/agents/pi/releases/1.2.3/node_modules/@geohar/pi-acp/dist/index.js", spec.args[1])
      t.eq(1, vim.fn.filereadable(spec.args[1]), "the launcher must point at a real file")
    end)

    t.it("restores a draft and repairs its cached image path", function()
      local roots = isolate("draft")
      local png = "\137PNG\r\n\26\n" .. string.rep("\0", 32)
      local old_image = roots.state .. "/acp/images/deadbeef.png"
      write(old_image, png)
      write(
        roots.state .. "/acp/drafts.json",
        vim.json.encode({
          ["/tmp\0s1"] = {
            cwd = "/tmp",
            session_id = "s1",
            text = "unsent message",
            attachments = {
              {
                kind = "image",
                label = "shot.png",
                path = old_image,
                uri = "file://" .. old_image,
                mime = "image/png",
              },
              { kind = "file", label = "a.lua", path = "/tmp/a.lua" },
            },
            saved_at = os.time(),
          },
        })
      )

      local results = run(roots)
      t.eq("migrated", status_of(results, "state"))

      -- Drafts resolve their file from stdpath("state"), which is the root both
      -- the migration and the test were given.
      local drafts = require("ade.storage.drafts")
      local got = drafts.get("/tmp", "s1")
      t.truthy(got, "the migrated draft must still be readable")
      t.eq("unsent message", got.text)
      t.eq("shot.png", got.attachments[1].label)
      t.eq(roots.state .. "/ade/images/deadbeef.png", got.attachments[1].path)
      t.eq("file://" .. roots.state .. "/ade/images/deadbeef.png", got.attachments[1].uri)
      t.eq(1, vim.fn.filereadable(got.attachments[1].path), "the repaired path must exist")
      t.eq("/tmp/a.lua", got.attachments[2].path, "non-image paths are left alone")
      drafts.clear()
    end)

    t.it("never overwrites a new directory, and keeps both copies", function()
      local roots = isolate("conflict")
      write(roots.data .. "/acp/marker-old", "old")
      write(roots.data .. "/ade/marker-new", "new")
      write(roots.log .. "/acp.nvim.log", "old log")
      write(roots.log .. "/ade.nvim.log", "new log")
      -- A live lease must not turn the actionable conflict into a deferral
      -- that would never resolve.
      write_lease(roots.data, { pid = vim.uv.os_getpid() })

      local warned = {}
      local log = require("ade.log")
      local original = log.warn
      log.warn = function(fmt, ...)
        warned[#warned + 1] = string.format(fmt, ...)
      end
      local ok, err = pcall(function()
        local results = run(roots)
        t.eq("conflict", status_of(results, "data"))
        t.eq("conflict", status_of(results, "log"))
        t.eq("absent", status_of(results, "state"))
        t.eq("old", read(roots.data .. "/acp/marker-old"), "the old copy must be untouched")
        t.eq("new", read(roots.data .. "/ade/marker-new"), "the new copy must be untouched")
        t.eq("old log", read(roots.log .. "/acp.nvim.log"))
        t.eq("new log", read(roots.log .. "/ade.nvim.log"))
      end)
      log.warn = original
      assert(ok, err)
      t.truthy(#warned >= 2, "both conflicts must be reported")
      t.match("both .*acp.* and .*ade.* exist", warned[1])
      t.match("manually", warned[1])
    end)

    t.it("reports a failed rename without raising", function()
      local roots = isolate("failure")
      write(roots.data .. "/acp/marker", "old")
      local failing = {
        fs_stat = function(path)
          return vim.uv.fs_stat(path)
        end,
        fs_rename = function()
          return nil, "EXDEV: cross-device link not permitted"
        end,
      }
      local results = run(roots, { fs = failing })
      t.eq("failed", status_of(results, "data"))
      t.truthy(vim.fn.isdirectory(roots.data .. "/acp") == 1, "the old tree stays in place")
      local found = false
      for _, item in ipairs(results) do
        if item.label == "data" then
          t.match("cross%-device", item.reason)
          found = true
        end
      end
      t.truthy(found)
    end)

    t.it("skips the data move while another instance holds a live lease", function()
      local roots = isolate("busy-lease")
      fake_install(roots.data)
      write(roots.state .. "/acp/drafts.json", '{"k":{"cwd":"/tmp","text":"hello"}}')
      -- The current process is alive, so a fresh heartbeat makes the record live.
      write_lease(roots.data, { pid = vim.uv.os_getpid() })

      local warned = {}
      local log = require("ade.log")
      local original = log.warn
      log.warn = function(fmt, ...)
        warned[#warned + 1] = string.format(fmt, ...)
      end
      local ok, err = pcall(function()
        local results = run(roots)
        t.eq("deferred", status_of(results, "data"))
        t.eq("migrated", status_of(results, "state"), "the state directory is not affected")
        t.eq(1, vim.fn.isdirectory(roots.data .. "/acp/agents/pi"), "the old install must stay where it is")
        t.eq(0, vim.fn.isdirectory(roots.data .. "/ade"), "the data directory must not be created")
        t.eq(1, vim.fn.filereadable(roots.state .. "/ade/drafts.json"), "the state move still happens")
      end)
      log.warn = original
      assert(ok, err)
      local joined = table.concat(warned, "\n")
      t.match("另一个 Neovim 仍在使用旧目录", joined)
      t.match("关闭它们后重启即可完成迁移", joined)
    end)

    t.it("skips the data move while an install lock is held", function()
      local roots = isolate("busy-lock")
      write(roots.data .. "/acp/agents/pi/current.json", '{"schemaVersion":1,"installId":"1.0.0"}')
      write_lock(roots.data, { pid = vim.uv.os_getpid() })
      local results = run(roots)
      t.eq("deferred", status_of(results, "data"))
      t.eq(1, vim.fn.isdirectory(roots.data .. "/acp/agents"), "the old tree stays in place")
    end)

    t.it("finishes the data move once the other instance is gone", function()
      local roots = isolate("lease-expired")
      fake_install(roots.data)
      write(roots.state .. "/acp/drafts.json", '{"k":{"cwd":"/tmp","text":"hello"}}')
      write_lease(roots.data, { pid = vim.uv.os_getpid() })

      local first = run(roots)
      t.eq("deferred", status_of(first, "data"))
      t.eq(1, vim.fn.isdirectory(roots.data .. "/acp/agents/pi"), "the first run must not move anything")

      -- The other instance exits: its heartbeat stops, so the record ages out
      -- exactly as the manager's own reclamation rules expect.
      write_lease(roots.data, { pid = vim.uv.os_getpid(), age_ms = 24 * 60 * 60 * 1000 })

      -- No `Migrate.reset()`: a deferred run must not be remembered as done, or
      -- the retry would never happen.
      local second = Migrate.run({
        data_dir = roots.data,
        state_dir = roots.state,
        log_dir = roots.log,
        notify = false,
      })
      t.eq("migrated", status_of(second, "data"))
      t.eq(1, vim.fn.isdirectory(roots.data .. "/ade/agents/pi"), "the install moved once the lease was stale")
      t.eq(0, vim.fn.isdirectory(roots.data .. "/acp"), "the old data directory is gone")
    end)

    t.it("runs once per process and is idempotent", function()
      local roots = isolate("once")
      write(roots.data .. "/acp/marker", "old")
      local first = run(roots)
      t.eq("migrated", status_of(first, "data"))
      -- Same process, second setup: the migration does not even look again.
      t.eq({}, Migrate.run({ data_dir = roots.data, state_dir = roots.state, log_dir = roots.log }))
      -- A later process finds nothing left to move.
      local again = run(roots)
      t.eq("absent", status_of(again, "data"))
      t.eq(1, vim.fn.isdirectory(roots.data .. "/ade"), "the migrated directory is not disturbed")
    end)
  end)
end
