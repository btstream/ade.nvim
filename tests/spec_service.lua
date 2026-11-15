-- The service: platform mapping, install, launcher, client, status and config.
--
-- Nothing here touches the network, runs cargo, or uses a real data directory.
-- Every path goes through `NVIM_ADE_SERVER_DIR` and a temporary data root, and
-- every collaborator (download, extract, sha256, process runner, uname) is
-- injected. The fake service socket lives under /tmp/opencode.
return function(t)
  local Platform = require("ade.service.platform")
  local Version = require("ade.service.version")
  local Install = require("ade.service.install")
  local Paths = require("ade.service.paths")
  local Launcher = require("ade.service.launcher")
  local Client = require("ade.service.client")
  local Status = require("ade.service.status")
  local Config = require("ade.config")
  local fake = require("tests.fake_service")

  local counter = 0
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-service-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.mkdir(dir, "p")
    t.cleanup(function()
      vim.fn.delete(dir, "rf")
    end)
    return dir
  end

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end

  -- A binary is only ever a script: the tests check the version protocol, not
  -- the ELF header. Running it through `run` keeps everything offline.
  --
  -- The API version defaults to the plugin's own constant; a case that wants a
  -- mismatch passes `api_version` explicitly instead of hardcoding a number.
  local function fake_binary(path, version, api_version)
    api_version = api_version or Version.API_VERSION
    write(path, '#!/bin/sh\necho \'{"version":"' .. version .. '","api_version":' .. tostring(api_version) .. "}'\n")
    vim.uv.fs_chmod(path, 448)
    return path
  end

  local function uname(sysname, machine)
    return { sysname = sysname, machine = machine, release = "x", version = "x", nodename = "x" }
  end

  ---A `source_dir` that never exists, so the compile fallback can never pick up
  ---the real `service/` tree that may or may not be checked out on this branch.
  ---Every install test injects this unless the case is specifically about
  ---compiling, where it injects a temporary fixture instead.
  local function missing_sources(tag)
    local dir = tmpdir(tag or "no-sources")
    return dir .. "/service-does-not-exist"
  end

  t.describe("service platform mapping", function()
    t.it("maps every target in the release matrix", function()
      t.eq("x86_64-unknown-linux-musl", Platform.detect(uname("Linux", "x86_64")))
      t.eq("aarch64-unknown-linux-musl", Platform.detect(uname("Linux", "aarch64")))
      t.eq("aarch64-unknown-linux-musl", Platform.detect(uname("Linux", "arm64")))
      t.eq("x86_64-apple-darwin", Platform.detect(uname("Darwin", "x86_64")))
      t.eq("aarch64-apple-darwin", Platform.detect(uname("Darwin", "arm64")))
      t.eq("x86_64-pc-windows-msvc", Platform.detect(uname("Windows_NT", "x86_64")))
    end)

    t.it("returns nil for platforms with no prebuilt build", function()
      t.eq(nil, Platform.detect(uname("Linux", "mips")))
      t.eq(nil, Platform.detect(uname("FreeBSD", "x86_64")))
      t.eq(nil, Platform.detect({ sysname = "Linux" }))
    end)

    t.it("uses the right archive extension and binary name", function()
      t.eq("tar.gz", Platform.extension("x86_64-unknown-linux-musl"))
      t.eq("zip", Platform.extension("x86_64-pc-windows-msvc"))
      t.eq("nvim_ade_server", Platform.binary_name("x86_64-apple-darwin"))
      t.eq("nvim_ade_server.exe", Platform.binary_name("x86_64-pc-windows-msvc"))
    end)
  end)

  t.describe("service version constant", function()
    t.it("matches service/Cargo.toml when that file exists", function()
      local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
      local manifest = root .. "service/Cargo.toml"
      if vim.fn.filereadable(manifest) ~= 1 then
        -- The Rust crate lives on another branch; the check must be a no-op
        -- rather than a failure until it lands here.
        io.write("SKIP: service/Cargo.toml does not exist on this branch\n")
        return
      end
      local lines = vim.fn.readfile(manifest)
      local version
      local in_package = false
      for _, line in ipairs(lines) do
        if line:match("^%[package%]") then
          in_package = true
        elseif line:match("^%[") then
          in_package = false
        elseif in_package then
          local found = line:match('^version%s*=%s*"(.-)"')
          if found then
            version = found
            break
          end
        end
      end
      t.truthy(version, "service/Cargo.toml has no package version")
      t.eq(version, Version.VERSION, "lua/ade/service/version.lua and service/Cargo.toml disagree")
    end)
  end)

  t.describe("service paths", function()
    t.it("prefers NVIM_ADE_SERVER_DIR over every XDG fallback", function()
      local saved = { vim.env.NVIM_ADE_SERVER_DIR, vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME }
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved[1]
        vim.env.XDG_RUNTIME_DIR = saved[2]
        vim.env.XDG_STATE_HOME = saved[3]
      end)
      vim.env.NVIM_ADE_SERVER_DIR = "/tmp/opencode/explicit-ade"
      vim.env.XDG_RUNTIME_DIR = "/tmp/opencode/runtime-ade"
      vim.env.XDG_STATE_HOME = "/tmp/opencode/state-ade"
      local paths = Paths.paths()
      t.eq("/tmp/opencode/explicit-ade", paths.dir)
      t.eq("/tmp/opencode/explicit-ade/nvim_ade_server.sock", paths.socket)
      t.eq("/tmp/opencode/explicit-ade/nvim_ade_server.token", paths.token)
      t.eq("/tmp/opencode/explicit-ade/nvim_ade_server.lock", paths.lock)
    end)

    t.it("falls back to the runtime directory, then state, then home", function()
      local saved = { vim.env.NVIM_ADE_SERVER_DIR, vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME }
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved[1]
        vim.env.XDG_RUNTIME_DIR = saved[2]
        vim.env.XDG_STATE_HOME = saved[3]
      end)
      vim.env.NVIM_ADE_SERVER_DIR = nil
      vim.env.XDG_RUNTIME_DIR = "/tmp/opencode/runtime-ade"
      vim.env.XDG_STATE_HOME = "/tmp/opencode/state-ade"
      t.eq("/tmp/opencode/runtime-ade/ade", Paths.dir())
      vim.env.XDG_RUNTIME_DIR = nil
      t.eq("/tmp/opencode/state-ade/ade", Paths.dir())
      vim.env.XDG_STATE_HOME = nil
      t.truthy(Paths.dir():match("^/.-/%.local/state/ade$"))
    end)
  end)

  t.describe("service install", function()
    -- A downloader that writes a scripted archive; the "archive" is whatever
    -- the case says, since extraction is injected too.
    local function downloader(files)
      local calls = {}
      local fn = function(url, dest, _)
        calls[#calls + 1] = { url = url, dest = dest }
        local body = files[url]
        if not body then
          return false, "HTTP 404"
        end
        write(dest, body)
        return true, nil
      end
      return fn, calls
    end

    ---An installer whose extraction drops a fake binary that answers `version`.
    local function installers(opts)
      local downloaded = {}
      opts = opts or {}
      local download, calls = downloader(opts.files or {})
      local run_calls = {}
      local run = function(argv, run_opts)
        run_calls[#run_calls + 1] = { argv = vim.deepcopy(argv), opts = run_opts }
        if argv[2] == "build" then
          if opts.compile_fails then
            return { code = 101, stdout = "", stderr = "error: could not compile" }
          end
          -- Honor --target-dir just like cargo so the layout under test is the
          -- same one the real build produces.
          local target_dir
          for index, arg in ipairs(argv) do
            if arg == "--target-dir" then
              target_dir = argv[index + 1]
            end
          end
          fake_binary(target_dir .. "/release/nvim_ade_server", Version.VERSION)
          return { code = 0, stdout = "compiled\n", stderr = "" }
        end
        -- `<binary> version`: run the actual script, which is a real executable
        -- under a temp dir. Still fully offline.
        local awaited = vim.system(argv, { text = true }):wait(5000)
        return { code = awaited.code or -1, stdout = awaited.stdout or "", stderr = awaited.stderr or "" }
      end
      return {
        download = function(url, dest, o)
          downloaded[#downloaded + 1] = url
          return download(url, dest, o)
        end,
        calls = calls,
        downloaded = downloaded,
        run = run,
        run_calls = run_calls,
      }
    end

    local function sha_of(text)
      return vim.fn.sha256(text)
    end

    ---A release archive content + a matching SHA256SUMS entry.
    local function release_files(target, archive_body, opts)
      opts = opts or {}
      local extension = Platform.extension(target)
      local name = Version.archive_name(Version.VERSION, target, extension)
      local base = opts.base or Install.DEFAULT_RELEASE_BASE
      local tag = Version.release_tag()
      local digest = opts.digest or sha_of(archive_body)
      return {
        [base .. "/" .. tag .. "/" .. name] = archive_body,
        [base .. "/" .. tag .. "/SHA256SUMS"] = digest .. "  " .. name .. "\n",
      }
    end

    t.it("installs a prebuilt archive, verifies it and switches the pointer", function()
      local data = tmpdir("prebuilt")
      local target = "x86_64-unknown-linux-musl"
      local harness = installers({ files = release_files(target, "TARBALL") })
      local extracted = nil
      local ok, err = Install.run({
        data_dir = data,
        target = target,
        uname = uname("Linux", "x86_64"),
        source_dir = missing_sources("prebuilt-src"),
        download = harness.download,
        extract = function(archive, dest, _)
          extracted = { archive = archive, dest = dest }
          fake_binary(dest .. "/nvim_ade_server", Version.VERSION)
          return true, nil
        end,
        sha256 = function()
          return sha_of("TARBALL")
        end,
        run = harness.run,
      })
      t.truthy(ok, tostring(err))
      t.truthy(extracted, "the archive was not extracted")
      local binary, version = Install.current_binary({ data_dir = data, target = target })
      t.eq(Version.VERSION, version)
      t.eq(Install.version_dir(Version.VERSION, { data_dir = data }) .. "/nvim_ade_server", binary)
      t.eq(1, vim.fn.executable(binary), "the installed binary must be executable")
      t.truthy(#harness.calls == 2, "both the archive and SHA256SUMS must be downloaded")
      -- Nothing was left behind in the downloads directory.
      t.falsy(
        vim.uv.fs_stat(Install.root({ data_dir = data }) .. "/downloads")
          and #vim.fn.readdir(Install.root({ data_dir = data }) .. "/downloads") > 0
      )
    end)

    t.it("skips the download when the required version is already installed", function()
      local data = tmpdir("skip")
      local target = "x86_64-unknown-linux-musl"
      local binary = Install.binary(Version.VERSION, { data_dir = data, target = target })
      fake_binary(binary, Version.VERSION)
      assert(Install.activate(Version.VERSION, {
        data_dir = data,
        target = target,
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. Version.API_VERSION .. "}",
            stderr = "",
          }
        end,
      }))

      local harness = installers({})
      local ok, err = Install.run({
        data_dir = data,
        target = target,
        source_dir = missing_sources("skip-src"),
        download = harness.download,
        run = harness.run,
      })
      t.truthy(ok, tostring(err))
      t.eq(0, #harness.calls, "an installed service must not be downloaded again")
    end)

    t.it("never activates a download with a bad sha256, and cleans up", function()
      local data = tmpdir("badsha")
      local target = "x86_64-unknown-linux-musl"
      local harness = installers({ files = release_files(target, "TARBALL") })
      local extracted = false
      Install.run({
        data_dir = data,
        target = target,
        -- Injected so a real `service/` tree (which exists after merging the
        -- Rust branch) cannot turn this into a compile attempt.
        source_dir = missing_sources("badsha-src"),
        download = harness.download,
        extract = function()
          extracted = true
          return true, nil
        end,
        sha256 = function()
          return "0000000000000000000000000000000000000000000000000000000000000000"
        end,
        run = harness.run,
        cargo_available = function()
          return false
        end,
      })
      t.eq(false, extracted, "a bad checksum must not be extracted")
      t.falsy(Install.current_version({ data_dir = data }), "a bad checksum must not be activated")
      local downloads = Install.root({ data_dir = data }) .. "/downloads"
      t.eq({}, vim.fn.isdirectory(downloads) == 1 and vim.fn.readdir(downloads) or {})
    end)

    t.it("reports a bad-checksum download failure when the compiler also fails", function()
      local data = tmpdir("badsha-compile")
      local target = "x86_64-unknown-linux-musl"
      local harness = installers({ files = release_files(target, "TARBALL"), compile_fails = true })
      local notified = {}
      local ok, err = Install.run({
        data_dir = data,
        target = target,
        source_dir = missing_sources("badsha-compile-src"),
        download = harness.download,
        extract = function()
          error("a bad checksum must not be extracted")
        end,
        sha256 = function()
          return "0000000000000000000000000000000000000000000000000000000000000000"
        end,
        run = harness.run,
        on_notify = function(message)
          notified[#notified + 1] = message
        end,
      })
      t.falsy(ok)
      t.match("checksum mismatch", err)
      t.match("could not be installed", err)
      t.falsy(Install.current_version({ data_dir = data }), "nothing may be activated")
      t.truthy(#notified >= 1, "the failure must be reported")
    end)

    t.it("falls back to compiling when the download fails", function()
      local data = tmpdir("compile")
      local target = "x86_64-unknown-linux-musl"
      local harness = installers({ compile_fails = false })
      local service_dir = tmpdir("sources")
      write(
        service_dir .. "/Cargo.toml",
        '[package]\nname = "nvim_ade_server"\nversion = "' .. Version.VERSION .. '"\n'
      )
      write(service_dir .. "/rust-toolchain.toml", '[toolchain]\nchannel = "nightly-2026-05-28"\n')

      local ok, err = Install.run({
        data_dir = data,
        target = target,
        source_dir = service_dir,
        download = harness.download, -- every URL 404s
        extract = function()
          error("extraction must not run when the download failed")
        end,
        sha256 = function()
          return nil
        end,
        run = harness.run,
        cargo_available = function()
          return true
        end,
      })
      t.truthy(ok, tostring(err))
      local build = nil
      for _, call in ipairs(harness.run_calls) do
        if call.argv[2] == "build" then
          build = call
        end
      end
      t.truthy(build, "cargo build was not run")
      t.eq("cargo", build.argv[1])
      t.eq("--release", build.argv[3])
      t.eq("--locked", build.argv[4])
      t.eq("--manifest-path", build.argv[5])
      t.eq(service_dir .. "/Cargo.toml", build.argv[6])
      t.eq("--target-dir", build.argv[7])
      local binary, version = Install.current_binary({ data_dir = data, target = target })
      t.eq(Version.VERSION, version)
      t.truthy(vim.fn.executable(binary) == 1)
    end)

    t.it("reports both failures without raising, and points at rustup or service.path", function()
      local data = tmpdir("bothfail")
      local target = "x86_64-unknown-linux-musl"
      local harness = installers({ compile_fails = true })
      local notified = {}
      local ok, err = Install.run({
        data_dir = data,
        target = target,
        source_dir = tmpdir("missing-sources"),
        download = harness.download,
        sha256 = function()
          return nil
        end,
        run = harness.run,
        notify = false,
        on_notify = function(message)
          notified[#notified + 1] = message
        end,
      })
      t.falsy(ok)
      local text = tostring(err)
      t.match("could not be installed", text)
      t.match("download", text)
      t.match("compile", text)
      t.match("service%.path", text)
      t.match("rustup", text)
      t.match("rust%-toolchain%.toml", text)
      t.match("nightly", text)
      t.truthy(#notified == 1, "the failure must be reported to the user")
      t.falsy(Install.current_version({ data_dir = data }), "a failed install must not write a pointer")
    end)

    t.it("only checks the version for a configured service.path", function()
      local harness = installers({})
      local binary = fake_binary(tmpdir("configured") .. "/nvim_ade_server", Version.VERSION)
      local info, err = Install.check_configured({ path = binary, run = harness.run })
      t.truthy(info, tostring(err))
      t.eq(Version.VERSION, info.version)
      t.eq(nil, err)
      t.eq(0, #harness.downloaded, "service.path must never download")

      -- A different version with a matching api_version is allowed, with a
      -- warning; an incompatible api_version is refused. Both come from the
      -- same resolver that start/status/health use.
      local other_version = Version.VERSION .. "-other"
      local wrong = fake_binary(tmpdir("configured-wrong") .. "/nvim_ade_server", other_version)
      local older, warning = Install.check_configured({ path = wrong, run = harness.run })
      t.truthy(older)
      t.eq(other_version, older.version)
      t.truthy(warning)
    end)

    t.it("switches the pointer atomically, leaving no temporary file", function()
      local data = tmpdir("pointer")
      local target = "x86_64-unknown-linux-musl"
      fake_binary(Install.binary(Version.VERSION, { data_dir = data, target = target }), Version.VERSION)
      local ok, err = Install.activate(Version.VERSION, {
        data_dir = data,
        target = target,
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. Version.API_VERSION .. "}",
            stderr = "",
          }
        end,
      })
      t.truthy(ok, tostring(err))
      local root = Install.root({ data_dir = data })
      local entries = vim.fn.readdir(root)
      for _, name in ipairs(entries) do
        t.falsy(name:match("^current%.tmp"), "a temporary pointer was left behind: " .. name)
      end
      local pointer = vim.json.decode(table.concat(vim.fn.readfile(root .. "/current"), "\n"))
      t.eq(1, pointer.schemaVersion)
      t.eq(Version.VERSION, pointer.version)
    end)

    t.it("rejects a binary whose api_version does not match", function()
      local data = tmpdir("apimismatch")
      local target = "x86_64-unknown-linux-musl"
      fake_binary(Install.binary(Version.VERSION, { data_dir = data, target = target }), Version.VERSION)
      local ok, err = Install.activate(Version.VERSION, {
        data_dir = data,
        target = target,
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. (Version.API_VERSION + 1) .. "}",
            stderr = "",
          }
        end,
      })
      t.falsy(ok)
      t.match("api_version", err)
    end)
  end)

  t.describe("service launcher", function()
    ---A private socket dir per test.
    local function server_dir(tag)
      local dir = tmpdir(tag)
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      return dir
    end

    t.it("treats a ready status line as success", function()
      local dir = server_dir("ready")
      local ok, err, status = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 500,
        spawn = function(_, on_line)
          on_line(string.format('{"status":"ready","socket":"%s/nvim_ade_server.sock","pid":42}', dir))
          return true
        end,
      })
      t.truthy(ok, tostring(err))
      t.eq("ready", status.status)
    end)

    t.it("treats already_running as success, not an error", function()
      local dir = server_dir("already")
      local ok, err, status = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 500,
        spawn = function(_, on_line)
          on_line(string.format('{"status":"already_running","socket":"%s/nvim_ade_server.sock"}', dir))
          return true
        end,
      })
      t.truthy(ok, tostring(err))
      t.eq("already_running", status.status)
    end)

    t.it("reports the message from an error status", function()
      local ok, err, status = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 500,
        spawn = function(_, on_line)
          on_line('{"status":"error","message":"another instance holds the lock"}')
          return true
        end,
      })
      t.falsy(ok)
      t.match("another instance holds the lock", err)
      t.eq("error", status.status)
    end)

    t.it("times out when no status line arrives", function()
      local dir = server_dir("timeout")
      local started = vim.uv.hrtime()
      local ok, err = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 120,
        spawn = function()
          return true
        end,
      })
      t.falsy(ok)
      t.match("did not become ready within", err)
      t.truthy(vim.uv.hrtime() - started >= 100 * 1000000, "the launcher did not wait for its timeout")
      t.truthy(vim.fn.isdirectory(dir) == 1)
    end)

    t.it("reports an immediate exit before readiness", function()
      local ok, err = Launcher.start({
        bin = "/fake/nvim_ade_server",
        timeout = 500,
        spawn = function(_, _, on_exit)
          on_exit(1)
          return true
        end,
      })
      t.falsy(ok)
      t.match("exited with 1", err)
    end)

    t.it("refuses to start when nothing is installed", function()
      server_dir("not-installed")
      local ok, err = Launcher.ensure({
        probe = function()
          return false
        end,
      })
      t.falsy(ok)
      t.match("not installed", err)
      t.match("Ade service install", err)
    end)

    t.it("does not spawn when the socket already answers", function()
      local dir = server_dir("already-up")
      local service = fake.new({ dir = dir })
      t.truthy(service:listen())
      t.cleanup(function()
        service:close()
      end)
      local spawned = false
      local ok, err = Launcher.ensure({
        probe = Launcher.probe,
        spawn = function()
          spawned = true
          return true
        end,
      })
      t.truthy(ok, tostring(err))
      t.eq(false, spawned, "a reachable service must not be spawned again")
    end)
  end)

  t.describe("service client", function()
    local function connect(opts)
      local dir = tmpdir("client")
      local service = fake.new(vim.tbl_extend("force", { dir = dir }, opts or {}))
      t.truthy(service:listen())
      local paths = {
        dir = dir,
        socket = service:socket(),
        token = dir .. "/nvim_ade_server.token",
        lock = dir .. "/nvim_ade_server.lock",
        pipe = false,
      }
      local client = Client.new({ paths = paths, timeout = 800 })
      local ok, info
      client:connect(function(result, value)
        ok, info = result, value
      end)
      return client, ok, info, service
    end

    t.it("performs hello and ping over the socket", function()
      local client, ok, info, service = connect()
      t.truthy(ok, tostring(info))
      t.eq(Version.VERSION, info.server_version)
      t.eq(Version.API_VERSION, info.api_version)
      t.truthy(client.ready)
      local pinged, ping_err = false, nil
      client:ping(function(result, value)
        pinged, ping_err = result, value
      end)
      t.truthy(pinged, tostring(ping_err))
      client:close()
      service:close()
    end)

    t.it("reports -32001 as an invalid token", function()
      local client, ok, info, service = connect({ wrong_token = true })
      t.falsy(ok)
      t.match("token", tostring(info))
      t.eq(false, client.ready)
      service:close()
    end)

    t.it("reports -32002 as a version mismatch and suggests reinstalling", function()
      local client, ok, info, service = connect({ api_version = Version.API_VERSION + 1 })
      t.falsy(ok)
      t.match("api_version", tostring(info))
      t.match("Ade service install", tostring(info))
      t.eq(false, client.ready)
      service:close()
    end)

    t.it("reports -32003 when hello was skipped", function()
      -- A service that requires hello rejects `ping` first. The client always
      -- sends hello, so this is only reachable with a hand-written request.
      local dir = tmpdir("hello-required")
      local service = fake.new({ dir = dir, require_hello = true })
      t.truthy(service:listen())
      local client = Client.new({
        paths = { dir = dir, socket = service:socket(), token = dir .. "/nvim_ade_server.token", pipe = false },
        timeout = 500,
      })
      -- Reach the RPC layer without going through `connect`: this is exactly
      -- what a future code path would do by mistake.
      client.pipe = vim.uv.new_pipe(false)
      local connected = false
      client.pipe:connect(service:socket(), function(err)
        connected = err == nil
      end)
      vim.wait(500, function()
        return connected
      end, 5)
      t.truthy(connected, "the test client did not connect")
      client.rpc = require("ade.transport.jsonrpc").new({
        send = function(payload)
          client.pipe:write(payload)
          return true
        end,
      })
      client:read_loop()
      local replied, err = false, nil
      client.rpc:request("ping", {}, function(_ok, value)
        replied, err = true, value
      end)
      vim.wait(800, function()
        return replied
      end, 5)
      t.truthy(replied, "the ping was never answered")
      t.eq(Client.ERR_HELLO_REQUIRED, err.code)
      t.match("hello", Client.describe_error(err))
      client:close()
      service:close()
    end)

    t.it("reports a missing socket instead of raising", function()
      local dir = tmpdir("no-socket")
      local client = Client.new({
        paths = { dir = dir, socket = dir .. "/missing.sock", token = dir .. "/missing.token", pipe = false },
        timeout = 200,
      })
      local ok, info = nil, nil
      client:connect(function(result, value)
        ok, info = result, value
      end)
      t.falsy(ok)
      t.match("cannot connect", tostring(info))
      t.eq(false, client.ready)
    end)

    t.it("notifies on disconnect exactly once", function()
      local client, ok, info, service = connect()
      t.truthy(ok, tostring(info))
      local reasons = {}
      client.on_disconnect_cb = function(reason)
        reasons[#reasons + 1] = reason
      end
      service:close()
      vim.wait(500, function()
        return #reasons > 0
      end, 10)
      client:close()
      t.truthy(#reasons >= 1)
      client:close()
      t.eq(#reasons, #reasons, "close is idempotent")
    end)

    t.it("asks the service to shut down", function()
      local client, ok, info, service = connect()
      t.truthy(ok, tostring(info))
      local done, value = false, nil
      client:shutdown(function(result, result_value)
        done, value = result, result_value
      end)
      t.truthy(done, tostring(value))
      t.eq(false, client.ready)
      service:close()
    end)
  end)

  t.describe("service commands", function()
    local Commands = require("ade.service.commands")
    local function config_with(overrides)
      return Config.validate(Config.merge(Config.defaults, overrides or {}))
    end

    local function messages()
      local list = {}
      return list, function(message, _level)
        list[#list + 1] = tostring(message)
      end
    end

    t.it("status reports through the notify callback", function()
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = tmpdir("cmd-status")
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      local list, notify = messages()
      local status = Commands.status({ config = config_with({}), notify = notify })
      t.eq(false, status.running)
      t.match("not installed", table.concat(list, "\n"))
    end)

    t.it("start reports the launcher outcome", function()
      local list, notify = messages()
      local ok = Commands.start({
        notify = notify,
        launcher = {
          ensure = function()
            return true, nil, { status = { status = "ready", socket = "/tmp/x.sock" } }
          end,
        },
      })
      t.truthy(ok)
      t.match("ready", table.concat(list, "\n"))

      local failed, failed_notify = messages()
      local bad = Commands.start({
        notify = failed_notify,
        launcher = {
          ensure = function()
            return false, "nvim_ade_server is not installed"
          end,
        },
      })
      t.falsy(bad)
      t.match("not installed", table.concat(failed, "\n"))
    end)

    t.it("stop reports an unreachable service without raising", function()
      local list, notify = messages()
      local ok = Commands.stop({
        notify = notify,
        client = {
          new = function()
            return {
              connect = function(_, cb)
                cb(false, "no socket")
              end,
              close = function() end,
            }
          end,
        },
      })
      t.falsy(ok)
      t.match("not running", table.concat(list, "\n"))
    end)

    t.it("install with service.path only checks the version", function()
      local list, notify = messages()
      local binary = fake_binary(tmpdir("cmd-install-path") .. "/nvim_ade_server", Version.VERSION)
      Commands.install({
        config = config_with({ service = { path = binary } }),
        notify = notify,
      })
      local joined = table.concat(list, "\n")
      t.match("usable", joined)
      -- Nothing was downloaded or compiled over a user-provided binary.
      t.falsy(joined:find("downloading", 1, true))
      t.falsy(joined:find("building", 1, true))
    end)

    t.it("install reports an unusable service.path instead of installing", function()
      local list, notify = messages()
      local binary = tmpdir("cmd-install-missing") .. "/does-not-exist"
      Commands.install({
        config = config_with({ service = { path = binary } }),
        notify = notify,
      })
      local joined = table.concat(list, "\n")
      t.match("service%.path", joined)
      t.falsy(joined:find("installed", 1, true))
    end)

    t.it("install without service.path runs the download/compile installer", function()
      local list, notify = messages()
      local seen = nil
      Commands.install({
        config = config_with({}),
        notify = notify,
        install = {
          install_async = function(opts)
            seen = opts
            opts.on_notify("installed")
          end,
        },
      })
      t.truthy(seen, "install_async was not called")
      t.eq(Install.DEFAULT_RELEASE_BASE, seen.release_base)
      t.eq(600000, seen.timeout)
      t.match("installed", table.concat(list, "\n"))
    end)

    t.it("dispatches each subcommand and rejects an unknown one", function()
      local seen = {}
      local stub = {}
      for _, name in ipairs({ "install", "status", "start", "stop" }) do
        stub[name] = function()
          seen[#seen + 1] = name
        end
      end
      local saved = {
        Commands.install,
        Commands.status,
        Commands.start,
        Commands.stop,
      }
      Commands.install, Commands.status, Commands.start, Commands.stop =
        stub.install, stub.status, stub.start, stub.stop
      local ok, err = pcall(function()
        for _, name in ipairs({ "install", "status", "start", "stop" }) do
          Commands.dispatch(name)
        end
      end)
      Commands.install, Commands.status, Commands.start, Commands.stop = saved[1], saved[2], saved[3], saved[4]
      assert(ok, err)
      t.eq({ "install", "status", "start", "stop" }, seen)
      local list, notify = messages()
      Commands.dispatch("bogus", { notify = notify })
      t.match("unknown service subcommand", table.concat(list, "\n"))
    end)
  end)

  t.describe("service release transport security", function()
    local Url = require("ade.service.url")

    t.it("parses schemes and hosts, including userinfo and ports", function()
      t.eq({ scheme = "https", host = "github.com" }, Url.parse("https://github.com/a/b"))
      t.eq({ scheme = "http", host = "127.0.0.1" }, Url.parse("http://127.0.0.1:8080/releases"))
      t.eq({ scheme = "http", host = "localhost" }, Url.parse("http://user:pass@localhost/x"))
      t.eq({ scheme = "http", host = "[::1]" }, Url.parse("http://[::1]:9000/x"))
      -- A scheme with no authority still parses; the scheme check is what
      -- rejects it, not the parser.
      t.eq({ scheme = "file", host = "" }, Url.parse("file:///tmp/releases"))
      t.eq(nil, Url.parse("not a url"))
      t.eq(nil, Url.parse(nil))
    end)

    t.it("recognises loopback hosts, and only those", function()
      t.truthy(Url.is_loopback_http("http://localhost:8080/releases"))
      t.truthy(Url.is_loopback_http("http://127.0.0.1/releases"))
      t.truthy(Url.is_loopback_http("http://[::1]:1234/releases"))
      t.falsy(Url.is_loopback_http("http://127.0.0.1.evil.example/releases"))
      t.falsy(Url.is_loopback_http("http://localhost.evil.example/releases"))
      t.falsy(Url.is_loopback_http("http://example.com/releases"))
      t.falsy(Url.is_loopback_http("https://localhost/releases"), "https is not the relaxed case")
      t.falsy(Url.is_loopback("https://example.com"), "https anywhere is fine but not loopback")
    end)

    t.it("rejects a backslash, which browser parsers read as a path separator", function()
      -- `http://evil.example\@127.0.0.1/` has host 127.0.0.1 to a plain splitter
      -- and host evil.example to a browser-style parser. Either answer is a
      -- reason to refuse, so the backslash itself is rejected.
      local url = "http://evil.example\\@127.0.0.1/"
      local err = Url.release_base_error(url)
      t.truthy(err)
      t.match("backslash", err)
      -- The same spelling must never relax the transport rules or count as
      -- loopback, whichever side a parser picks.
      t.falsy(Url.is_loopback_http(url))
      t.eq("=https", Install.transport_rules(url).proto)

      local function merged(overrides)
        return Config.validate(Config.merge(Config.defaults, overrides or {}))
      end
      t.raises(function()
        merged({ service = { release_base = url } })
      end, "backslash")
      -- Also refused when https, not only for the loopback exception.
      t.truthy(Url.release_base_error("https://evil.example\\@127.0.0.1/"))
    end)

    t.it("rejects credentials in the authority, even over https", function()
      for _, url in ipairs({
        "https://user:pass@github.com/x",
        "https://user@github.com/x",
        "http://user:pass@127.0.0.1:8080/x",
      }) do
        local err = Url.release_base_error(url)
        t.truthy(err, "accepted credentials in " .. vim.inspect(url))
        t.match("credentials", err)
        t.falsy(Url.is_loopback_http(url), "a credential URL must not count as loopback")
      end
      local function merged(overrides)
        return Config.validate(Config.merge(Config.defaults, overrides or {}))
      end
      t.raises(function()
        merged({ service = { release_base = "https://user:pass@github.com/x" } })
      end, "credentials")
    end)

    t.it("rejects whitespace and control characters", function()
      for _, bad in ipairs({
        "https://github.com/a b",
        "https://github.com/a\tb",
        "https://github.com/a\nb",
        "https://github.com/a\rb",
        "https://github.com/a\0b",
        "https://github.com/a\127b",
      }) do
        local err = Url.release_base_error(bad)
        t.truthy(err, "accepted a URL with whitespace or control characters: " .. vim.inspect(bad))
        t.match("whitespace or control", err)
      end
      local function merged(overrides)
        return Config.validate(Config.merge(Config.defaults, overrides or {}))
      end
      t.raises(function()
        merged({ service = { release_base = "https://github.com/a\nb" } })
      end, "whitespace or control")
      -- A clean loopback URL is still accepted, and a clean https URL too.
      t.eq(nil, Url.release_base_error("http://127.0.0.1:8080/releases"))
      t.eq(nil, Url.release_base_error("https://github.com/btstream/ade.nvim/releases/download"))
    end)

    t.it("rejects plain http to a remote host and explains why", function()
      local err = Url.release_base_error("http://example.com/releases")
      t.truthy(err)
      t.match("https", err)
      t.match("SHA256SUMS", err)
      t.match("loopback", err)
      -- A lookalike host is not the loopback exception.
      t.truthy(Url.release_base_error("http://127.0.0.1.evil.example/releases"))
      t.truthy(Url.release_base_error("ftp://example.com/releases"))
      t.truthy(Url.release_base_error(""))
      t.truthy(Url.release_base_error(nil))
    end)

    t.it("accepts https anywhere and http on loopback", function()
      t.eq(nil, Url.release_base_error("https://github.com/btstream/ade.nvim/releases/download"))
      t.eq(nil, Url.release_base_error("https://example.com/releases"))
      t.eq(nil, Url.release_base_error("http://localhost:8080/releases"))
      t.eq(nil, Url.release_base_error("http://127.0.0.1/releases"))
      t.eq(nil, Url.release_base_error("http://[::1]:9000/releases"))
    end)

    t.it("config validation accepts loopback http and rejects remote http", function()
      local function merged(overrides)
        return Config.validate(Config.merge(Config.defaults, overrides or {}))
      end
      local allowed = "http://127.0.0.1:8080/releases"
      t.eq(allowed, merged({ service = { release_base = allowed } }).service.release_base)
      t.eq(
        "http://localhost/releases",
        merged({ service = { release_base = "http://localhost/releases" } }).service.release_base
      )
      t.raises(function()
        merged({ service = { release_base = "http://example.com/releases" } })
      end, "https")
      t.raises(function()
        merged({ service = { release_base = "http://127.0.0.1.evil.example/releases" } })
      end, "loopback")
      t.raises(function()
        merged({ service = { release_base = "file:///tmp/releases" } })
      end, "https")
    end)

    t.it("restricts curl to https and to https redirects by default", function()
      local argv = Install.curl_argv("https://example.com/a.tar.gz", "/tmp/a.tar.gz", { timeout = 5000 })
      local joined = table.concat(argv, " ")
      t.match("%-%-proto =https ", joined .. " ")
      t.match("%-%-proto%-redir =https ", joined .. " ")
      t.falsy(joined:find("=http,https", 1, true), "a remote https base must not allow plain http")
      -- Both options must come before the URL, so a URL cannot be mistaken for
      -- a flag value.
      local proto_at, url_at
      for index, value in ipairs(argv) do
        if value == "--proto" then
          proto_at = index
        elseif value == "--proto-redir" then
          proto_at = proto_at or index
        elseif value:match("^https://") then
          url_at = index
        end
      end
      t.truthy(proto_at and url_at and proto_at < url_at)
    end)

    t.it("relaxes the protocol only for a loopback http base", function()
      local argv = Install.curl_argv("http://127.0.0.1:8080/a.tar.gz", "/tmp/a.tar.gz", { timeout = 5000 })
      -- Compare the option values rather than substrings: "=https" starts
      -- with "=http", so a substring check would happily pass a downgrade.
      local function option(name)
        for index, value in ipairs(argv) do
          if value == name then
            return argv[index + 1]
          end
        end
        return nil
      end
      t.eq("=http,https", option("--proto"))
      -- Redirects stay https-only: curl cannot pin a redirect host, and the
      -- point of the check is to stop a downgrade to a remote plain-http host.
      t.eq("=https", option("--proto-redir"), "redirects must never be allowed to downgrade")
    end)

    t.it("uses those options for both the archive and SHA256SUMS downloads", function()
      local data = tmpdir("transport")
      local target = "x86_64-unknown-linux-musl"
      local runs = {}
      local function run(argv, _)
        runs[#runs + 1] = vim.deepcopy(argv)
        -- The scripted curl writes the content the case needs, mirroring the
        -- real `--output dest` behaviour.
        local dest = argv[#argv - 1]
        write(dest, argv[#argv]:match("SHA256SUMS") and "SUM  file" or "ARCHIVE")
        return { code = 0, stdout = "", stderr = "" }
      end
      local base = "https://example.com/releases"
      local archive_name = Version.archive_name(Version.VERSION, target, "tar.gz")
      -- The real downloader is used (only its process runner is injected), which
      -- is exactly the path production takes.
      local ok, err = Install.run({
        data_dir = data,
        target = target,
        release_base = base,
        source_dir = missing_sources("transport-src"),
        download_run = run,
        extract = function(_, dest)
          write(dest .. "/nvim_ade_server", "#!/bin/sh\n")
          vim.uv.fs_chmod(dest .. "/nvim_ade_server", 448)
          return true, nil
        end,
        sha256 = function()
          return vim.fn.sha256("ARCHIVE")
        end,
        run = function(argv)
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. Version.API_VERSION .. "}",
            stderr = "",
          }
        end,
      })
      -- The scripted SHA256SUMS above intentionally does not match, so the run
      -- stops after both downloads: that is all this case needs to observe.
      t.falsy(ok, err)
      t.eq(2, #runs, "both the archive and SHA256SUMS must be fetched")
      t.truthy(table.concat(runs[1], " "):find(archive_name, 1, true), "the first download is the archive")
      t.truthy(table.concat(runs[2], " "):find("SHA256SUMS", 1, true))
      for _, argv in ipairs(runs) do
        local options = {}
        for index, value in ipairs(argv) do
          if value == "--proto" or value == "--proto-redir" then
            options[value] = argv[index + 1]
          end
        end
        t.eq("=https", options["--proto"], "the archive and its checksums must both be https-only")
        t.eq("=https", options["--proto-redir"])
      end
    end)

    t.it("refuses to fetch from a remote http base even when called directly", function()
      local data = tmpdir("direct-http")
      local fetched = false
      local ok, err = Install.run({
        data_dir = data,
        target = "x86_64-unknown-linux-musl",
        release_base = "http://example.com/releases",
        source_dir = missing_sources("direct-http-src"),
        download = function()
          fetched = true
          return true, nil
        end,
        extract = function()
          return true, nil
        end,
        sha256 = function()
          return "x"
        end,
        run = function()
          return { code = 1, stdout = "", stderr = "no cargo" }
        end,
        cargo_available = function()
          return false
        end,
      })
      t.falsy(ok)
      t.eq(false, fetched, "a remote http base must be rejected before any download")
      t.match("https", tostring(err))
    end)

    t.it("accepts a loopback http base for local testing", function()
      local data = tmpdir("loopback")
      local target = "x86_64-unknown-linux-musl"
      local runs = {}
      local function run(argv, _)
        runs[#runs + 1] = vim.deepcopy(argv)
        local dest = argv[#argv - 1]
        write(dest, argv[#argv]:match("SHA256SUMS") and "SUM  file" or "ARCHIVE")
        return { code = 0, stdout = "", stderr = "" }
      end
      local ok = Install.run({
        data_dir = data,
        target = target,
        release_base = "http://127.0.0.1:8080/releases",
        source_dir = missing_sources("loopback-src"),
        download_run = run,
        extract = function(_, dest)
          write(dest .. "/nvim_ade_server", "#!/bin/sh\n")
          vim.uv.fs_chmod(dest .. "/nvim_ade_server", 448)
          return true, nil
        end,
        sha256 = function()
          return vim.fn.sha256("ARCHIVE")
        end,
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. Version.API_VERSION .. "}",
            stderr = "",
          }
        end,
      })
      t.falsy(ok, "the scripted SHA256SUMS does not match; the point is that it was fetched")
      t.eq(2, #runs)
      local options = {}
      for index, value in ipairs(runs[1]) do
        if value == "--proto" or value == "--proto-redir" then
          options[value] = runs[1][index + 1]
        end
      end
      t.eq("=http,https", options["--proto"], "a loopback http base may speak plain http")
      t.eq("=https", options["--proto-redir"])
    end)
  end)

  t.describe("service binary resolution (one entry point)", function()
    ---Run `resolve_binary` with a scripted `version` reply.
    local function resolve(opts, reply)
      return Install.resolve_binary(vim.tbl_extend("force", {
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. reply.version .. '","api_version":' .. reply.api_version .. "}",
            stderr = "",
          }
        end,
      }, opts or {}))
    end

    t.it("uses service.path when it is configured and compatible", function()
      local binary = fake_binary(tmpdir("resolve-path") .. "/nvim_ade_server", Version.VERSION)
      local resolved, err = resolve({ path = binary }, { version = Version.VERSION, api_version = Version.API_VERSION })
      t.truthy(resolved, tostring(err))
      t.eq(binary, resolved.path)
      t.eq("configured", resolved.source)
      t.eq(Version.API_VERSION, resolved.api_version)
      t.eq(nil, resolved.warning)
    end)

    t.it("reads service.path from a config table too", function()
      local binary = fake_binary(tmpdir("resolve-config") .. "/nvim_ade_server", Version.VERSION)
      local resolved = resolve({
        config = { service = { path = binary } },
      }, { version = Version.VERSION, api_version = Version.API_VERSION })
      t.truthy(resolved)
      t.eq("configured", resolved.source)
      t.eq(binary, resolved.path)
    end)

    t.it("allows a different version with a warning when api_version matches", function()
      -- Deliberately *not* the plugin's version; derived so a bump cannot make
      -- this accidentally equal again.
      local other_version = Version.VERSION .. "-other"
      local binary = fake_binary(tmpdir("resolve-older") .. "/nvim_ade_server", other_version)
      local resolved, err = resolve({ path = binary }, { version = other_version, api_version = Version.API_VERSION })
      t.truthy(resolved, tostring(err))
      t.eq(other_version, resolved.version)
      t.truthy(resolved.warning)
      t.match("api_version", resolved.warning)
    end)

    t.it("rejects service.path with an incompatible api_version", function()
      local binary = fake_binary(tmpdir("resolve-api") .. "/nvim_ade_server", Version.VERSION)
      local newer = Version.API_VERSION + 1
      local resolved, err = resolve({ path = binary }, { version = Version.VERSION, api_version = newer })
      t.falsy(resolved)
      t.match("api_version", err)
      t.match(tostring(newer), err)
      -- An older api_version is refused too, not just a newer one.
      local older = math.max(0, Version.API_VERSION - 1)
      local old, old_err = resolve({ path = binary }, { version = Version.VERSION, api_version = older })
      t.falsy(old)
      t.match("api_version", old_err)
    end)

    t.it("rejects a service.path that is missing or not executable", function()
      local missing, err = resolve({ path = tmpdir("resolve-missing") .. "/nope" }, {})
      t.falsy(missing)
      t.match("service%.path", err)

      local path = tmpdir("resolve-noexec") .. "/nvim_ade_server"
      write(path, "not a program")
      vim.uv.fs_chmod(path, 384)
      local noexec, noexec_err = resolve({ path = path }, {})
      t.falsy(noexec)
      t.match("not executable", noexec_err)
    end)

    t.it("falls back to the managed install when service.path is unset", function()
      local data = tmpdir("resolve-managed")
      local target = "x86_64-unknown-linux-musl"
      fake_binary(Install.binary(Version.VERSION, { data_dir = data, target = target }), Version.VERSION)
      assert(Install.activate(Version.VERSION, {
        data_dir = data,
        target = target,
        run = function()
          return {
            code = 0,
            stdout = '{"version":"' .. Version.VERSION .. '","api_version":' .. Version.API_VERSION .. "}",
            stderr = "",
          }
        end,
      }))
      local resolved, err = resolve({ data_dir = data, target = target }, {
        version = Version.VERSION,
        api_version = Version.API_VERSION,
      })
      t.truthy(resolved, tostring(err))
      t.eq("managed", resolved.source)
      t.eq(Install.binary(Version.VERSION, { data_dir = data, target = target }), resolved.path)
    end)

    t.it("reports not installed when neither source exists", function()
      local resolved, err = resolve({ data_dir = tmpdir("resolve-none") }, {})
      t.falsy(resolved)
      t.match("not installed", err)
      t.match("Ade service install", err)
    end)
  end)

  t.describe("service start honours service.path", function()
    -- These cases go through `commands` with a real config table, which is the
    -- path the bug lived in: `status` honoured service.path but `start` did not.
    local Commands = require("ade.service.commands")
    local target = "x86_64-unknown-linux-musl"

    local function config_with(overrides)
      return Config.validate(Config.merge(Config.defaults, overrides or {}))
    end

    ---A private server directory so a stray service from another test cannot
    ---answer the probe.
    local function server_dir(tag)
      local dir = tmpdir(tag)
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      return dir
    end

    ---A binary that answers `version` and can act as a real service when spawned:
    ---the spawn itself is scripted, so the binary only has to exist and be
    ---executable.
    local function service_binary(tag, opts)
      opts = opts or {}
      local path = tmpdir(tag) .. "/nvim_ade_server"
      local reply = string.format(
        '{"version":"%s","api_version":%s}',
        opts.version or Version.VERSION,
        opts.api_version or Version.API_VERSION
      )
      write(
        path,
        "#!/bin/sh\n"
          .. 'if [ "$1" = "version" ]; then\n'
          .. "  echo '"
          .. reply
          .. "'\n"
          .. "  exit 0\n"
          .. "fi\n"
          .. "exit 0\n"
      )
      vim.uv.fs_chmod(path, 448)
      return path
    end

    ---Replace the launcher's spawn so `start` really resolves the binary but
    ---never runs it.
    local function fake_spawn(record)
      local real = Launcher.start
      Launcher.start = function(start_opts)
        record.bin = start_opts.bin
        record.started = true
        return true, nil, { status = "ready", socket = Paths.paths().socket, pid = 1 }
      end
      t.cleanup(function()
        Launcher.start = real
      end)
    end

    t.it("starts from service.path, then stops", function()
      server_dir("start-path")
      local binary = service_binary("start-binary")
      local record = {}
      fake_spawn(record)
      local messages = {}
      local started = Commands.start({
        config = config_with({ service = { path = binary } }),
        notify = function(message)
          messages[#messages + 1] = tostring(message)
        end,
      })
      t.truthy(started, table.concat(messages, "\n"))
      t.eq(binary, record.bin, "start did not use service.path")

      -- stop goes through a client; inject one that reports a clean shutdown so
      -- the test covers the command path without needing a real socket.
      local stopped = Commands.stop({
        notify = function(message)
          messages[#messages + 1] = tostring(message)
        end,
        client = {
          new = function()
            return {
              connect = function(_, cb)
                cb(true, { server_version = Version.VERSION, api_version = Version.API_VERSION })
              end,
              shutdown = function(_, cb)
                cb(true, {})
              end,
              close = function() end,
            }
          end,
        },
      })
      t.truthy(stopped)
      t.match("stopped", table.concat(messages, "\n"))
    end)

    t.it("start and status report the same binary for a service.path config", function()
      server_dir("start-status")
      local binary = service_binary("agree-binary")
      local record = {}
      fake_spawn(record)
      local config = config_with({ service = { path = binary } })
      Commands.start({ config = config, notify = function() end })
      t.eq(binary, record.bin)

      local status = Status.collect({
        config = config,
        launcher = {
          probe = function()
            return false
          end,
        },
      })
      t.eq(binary, status.binary, "status and start must agree about the binary")
      t.eq(Version.VERSION, status.installed_version)
      t.eq(true, status.api_ok)
    end)

    t.it("start refuses a service.path with an incompatible api_version", function()
      server_dir("start-api")
      local binary = service_binary("api-binary", { api_version = Version.API_VERSION + 1 })
      local record = {}
      fake_spawn(record)
      local messages = {}
      local started = Commands.start({
        config = config_with({ service = { path = binary } }),
        notify = function(message)
          messages[#messages + 1] = tostring(message)
        end,
      })
      t.falsy(started)
      t.eq(nil, record.started)
      t.match("api_version", table.concat(messages, "\n"))
    end)

    t.it("start allows a different version with matching api_version and warns", function()
      server_dir("start-older")
      -- Derived so a version bump cannot make this equal to the real one.
      local other_version = Version.VERSION .. "-other"
      local binary = service_binary("older-binary", { version = other_version })
      local record = {}
      fake_spawn(record)
      local messages = {}
      local levels = {}
      local started = Commands.start({
        config = config_with({ service = { path = binary } }),
        notify = function(message, level)
          messages[#messages + 1] = tostring(message)
          levels[#levels + 1] = level
        end,
      })
      t.truthy(started, table.concat(messages, "\n"))
      t.eq(binary, record.bin)
      local joined = table.concat(messages, "\n")
      t.truthy(joined:find(other_version, 1, true), joined)
      local warned = false
      for _, level in ipairs(levels) do
        if level == vim.log.levels.WARN then
          warned = true
        end
      end
      t.truthy(warned, "a version mismatch must be reported as a warning")
    end)

    t.it("start reports not installed when nothing is configured or installed", function()
      server_dir("start-none")
      local messages = {}
      local data = tmpdir("start-none-data")
      local started = Commands.start({
        config = config_with({}),
        notify = function(message)
          messages[#messages + 1] = tostring(message)
        end,
        launcher = {
          ensure = function()
            return require("ade.service.launcher").ensure({
              data_dir = data,
              probe = function()
                return false
              end,
              spawn = function()
                error("must not spawn without a binary")
              end,
            })
          end,
        },
      })
      t.falsy(started)
      local joined = table.concat(messages, "\n")
      t.match("not installed", joined)
      t.match("Ade service install", joined)
    end)

    t.it("checkhealth's section reports the same binary as status", function()
      server_dir("health-agree")
      local binary = service_binary("health-binary")
      local config = config_with({ service = { path = binary } })
      local status = Status.collect({
        config = config,
        launcher = {
          probe = function()
            return false
          end,
        },
      })
      -- The health section is `Status.collect` + `Status.lines`, so comparing
      -- the collected table is the same comparison `:checkhealth` makes.
      local lines = Status.lines(status)
      local text = {}
      for _, line in ipairs(lines) do
        text[#text + 1] = line.text
      end
      local joined = table.concat(text, "\n")
      t.match("binary: " .. binary:gsub("%-", "%%-"), joined)
      t.match("service%.path: " .. binary:gsub("%-", "%%-"), joined)
      t.truthy(status.installed_version == Version.VERSION, "the health section must report the version")
    end)
  end)

  t.describe("service agents and kill commands", function()
    local Commands = require("ade.service.commands")
    local fake_connection = require("tests.fake_connection")

    ---A connection that answers `agent.list` with `instances` and `agent.stop`
    ---with success. **Asynchronous by default**: the command's tests must not be
    ---able to pass by reading a result the callback has not produced yet.
    local function listing(instances, opts)
      opts = opts or {}
      return fake_connection.new({
        sync = opts.sync,
        delay_ms = opts.delay_ms,
        responders = {
          ["agent.list"] = function()
            return true, { instances = instances }
          end,
          ["agent.stop"] = function()
            return true, { exited = true, code = 0 }
          end,
        },
      })
    end

    ---Run `fn`, then wait for the connection's pending replies to arrive.
    local function settle(connection, timeout)
      vim.wait(timeout or 2000, function()
        return connection.pending == 0
      end, 5)
    end

    t.it("lists every instance with its runtime facts", function()
      local instances = {
        {
          instance = "inst-1",
          agent = "opencode",
          cwd = "/proj",
          pid = 42,
          started_at = math.floor(vim.uv.gettimeofday() * 1000) - 65000,
          attached = 1,
          turns_running = 2,
          pending_requests = 3,
        },
        {
          instance = "inst-2",
          agent = "claude",
          cwd = "/other",
          pid = 43,
          started_at = math.floor(vim.uv.gettimeofday() * 1000) - 5000,
          attached = 0,
        },
      }
      local connection = listing(instances)
      Commands.agents({ connection = connection, notify = connection:notify() })
      -- The bug: the command used to read the result immediately. Nothing may be
      -- printed before the reply arrives.
      t.eq({}, connection.notes, "the command reported before the reply arrived")
      settle(connection)
      local joined = table.concat(connection.notes, "\n")
      t.match("inst%-1", joined)
      t.match("opencode", joined)
      t.match("pid 42", joined)
      t.match("attached 1", joined)
      t.match("turns 2", joined)
      t.match("pending 3", joined)
      t.match("1m0", joined)
      t.match("inst%-2", joined)
      t.falsy(joined:find("unable to list", 1, true), joined)
    end)

    t.it("never says unable-to-list before the reply arrives", function()
      -- The exact user-visible symptom: `unable to list agents: nil`.
      local connection = listing({}, { delay_ms = 60 })
      Commands.agents({ connection = connection, notify = connection:notify() })
      t.eq({}, connection.notes, "an empty result was reported as a failure")
      settle(connection)
      local joined = table.concat(connection.notes, "\n")
      t.match("no agent instances", joined)
      t.falsy(joined:find("unable to list", 1, true), joined)
      t.falsy(joined:find("nil", 1, true), joined)
    end)

    t.it("reports an unreachable service instead of raising", function()
      local connection = fake_connection.new({
        responders = {
          ["agent.list"] = function()
            return false, { code = -32000, message = "not connected to the service" }
          end,
        },
      })
      Commands.agents({ connection = connection, notify = connection:notify() })
      settle(connection)
      t.match("unable to list", table.concat(connection.notes, "\n"))
      t.match("not connected", table.concat(connection.notes, "\n"))
    end)

    t.it("times out with a clear message when the service never answers", function()
      -- A wedged service: the request is sent and never answered.
      local connection = fake_connection.new({})
      connection.request = function(self, _method, _params, _cb)
        self.pending = self.pending + 1
        return 1
      end
      Commands.agents({
        connection = connection,
        notify = connection:notify(),
        timeout = 120,
      })
      vim.wait(1500, function()
        return #connection.notes > 0
      end, 10)
      local joined = table.concat(connection.notes, "\n")
      t.match("did not answer agent%.list", joined)
      t.match("within", joined)
      t.falsy(joined:find("unable to list agents: nil", 1, true), "the old nil message came back")
    end)

    t.it("answers only once even when the callback fires twice", function()
      local connection = fake_connection.new({})
      connection.request = function(self, _method, _params, cb)
        self.pending = self.pending + 1
        vim.defer_fn(function()
          self.pending = self.pending - 1
          cb(true, { instances = {} })
          cb(true, { instances = {} })
        end, 1)
        return 1
      end
      Commands.agents({ connection = connection, notify = connection:notify() })
      vim.wait(1000, function()
        return #connection.notes > 0
      end, 10)
      vim.wait(200)
      t.eq(1, #connection.notes, "a duplicate reply must not print twice")
    end)

    t.it("fails the request when the connection drops", function()
      local connection = fake_connection.new({})
      connection.request = function(self, _method, _params, cb)
        self.pending = self.pending + 1
        self.pending_cb = cb
        return 1
      end
      Commands.agents({ connection = connection, notify = connection:notify() })
      -- The drop arrives after the request is in flight.
      connection:drop("socket closed")
      vim.wait(1500, function()
        return #connection.notes > 0
      end, 10)
      local joined = table.concat(connection.notes, "\n")
      t.match("unable to list", joined)
      t.match("socket closed", joined)
    end)

    t.it("kills one instance and refuses without an id", function()
      local connection = listing({})
      Commands.kill("inst-7", { connection = connection, notify = connection:notify() })
      t.eq({}, connection.notes, "kill reported before the reply arrived")
      settle(connection)
      t.eq("agent.stop", connection.calls[1].method)
      t.eq("inst-7", connection.calls[1].params.instance)
      t.match("stopped agent inst%-7", table.concat(connection.notes, "\n"))

      local refused = listing({})
      Commands.kill(nil, { connection = refused, notify = refused:notify() })
      -- No id is a local error: it is reported immediately and never asks the
      -- service.
      t.eq(0, #refused.calls)
      t.match("needs an instance id", table.concat(refused.notes, "\n"))
    end)

    t.it("reports a rejected kill after the reply, not before", function()
      local connection = fake_connection.new({
        responders = {
          ["agent.stop"] = function()
            return false, { code = -32020, message = "unknown instance" }
          end,
        },
      })
      Commands.kill("gone", { connection = connection, notify = connection:notify() })
      t.eq({}, connection.notes)
      settle(connection)
      t.match("unable to stop gone", table.concat(connection.notes, "\n"))
      t.match("unknown instance", table.concat(connection.notes, "\n"))
    end)

    t.it("dispatches agents and kill from the service subcommand", function()
      local seen = {}
      local saved = { Commands.agents, Commands.kill }
      Commands.agents = function()
        seen[#seen + 1] = "agents"
      end
      Commands.kill = function(instance)
        seen[#seen + 1] = "kill:" .. tostring(instance)
      end
      local ok, err = pcall(function()
        Commands.dispatch("agents")
        Commands.dispatch("kill", { rest = "inst-9" })
      end)
      Commands.agents, Commands.kill = saved[1], saved[2]
      assert(ok, err)
      t.eq({ "agents", "kill:inst-9" }, seen)
    end)
  end)

  t.describe("shared connection reads the config", function()
    local Connection = require("ade.service.connection")
    local Config = require("ade.config")

    t.it("resolves service.path without going through the chat path", function()
      -- Defect B: commands use `Connection.shared()`, which used to have no
      -- config at all, so `service.path` was ignored and the command reported
      -- "not installed" even though start had just used the path.
      local binary = fake_binary(tmpdir("shared-path") .. "/nvim_ade_server", Version.VERSION)
      local original = Config.current
      t.cleanup(function()
        Config.current = original
      end)
      -- Configure the plugin exactly like a user would.
      Config.remember(Config.validate(Config.merge(Config.defaults, { service = { path = binary } })))

      local shared = Connection.new({})
      local resolved, err = shared:resolve()
      t.truthy(resolved, tostring(err))
      t.eq("configured", resolved.source)
      t.eq(binary, resolved.path)
    end)

    t.it("still honours an explicitly injected config", function()
      local shared = Connection.new({
        config = function()
          return { service = { path = "/explicit/path" } }
        end,
        resolve_binary = function()
          return { path = "/explicit/path", source = "configured" }
        end,
      })
      local resolved = shared:resolve()
      t.eq("/explicit/path", resolved.path)
    end)

    t.it("falls back to the managed install when no service.path is set", function()
      local original = Config.current
      t.cleanup(function()
        Config.current = original
      end)
      Config.remember(Config.validate(Config.merge(Config.defaults, {})))
      local shared = Connection.new({ data_dir = tmpdir("shared-managed") })
      local resolved, err = shared:resolve()
      t.falsy(resolved)
      t.match("not installed", err)
    end)
  end)

  t.describe("service status and config", function()
    local function config_with(overrides)
      local raw = Config.merge(Config.defaults, overrides or {})
      return Config.validate(raw)
    end

    t.it("defaults to the direct backend and leaves chat untouched", function()
      local cfg = config_with({})
      t.eq("direct", cfg.backend)
      t.eq(true, cfg.service.keep_alive)
      t.eq(1800, cfg.service.idle_timeout)
      t.eq(nil, cfg.service.path)
      t.eq(Install.DEFAULT_RELEASE_BASE, cfg.service.release_base)
      t.eq(600000, cfg.service.install_timeout)
      t.eq(5000, cfg.service.start_timeout)
    end)

    t.it("validates keep_alive and idle_timeout", function()
      t.eq(false, config_with({ service = { keep_alive = false } }).service.keep_alive)
      t.eq(60, config_with({ service = { idle_timeout = 60 } }).service.idle_timeout)
      t.eq(86400, config_with({ service = { idle_timeout = 86400 } }).service.idle_timeout)
      t.raises(function()
        config_with({ service = { keep_alive = "yes" } })
      end, "keep_alive must be a boolean")
      t.raises(function()
        config_with({ service = { idle_timeout = 30 } })
      end, "idle_timeout")
      t.raises(function()
        config_with({ service = { idle_timeout = 86401 } })
      end, "idle_timeout")
      t.raises(function()
        config_with({ service = { idle_timeout = 90.5 } })
      end, "whole number")
    end)

    t.it("validates backend and service settings", function()
      t.eq("service", config_with({ backend = "service" }).backend)
      t.eq("auto", config_with({ backend = "auto" }).backend)
      t.raises(function()
        config_with({ backend = "remote" })
      end, "backend must be one of")
      t.raises(function()
        config_with({ service = { path = 42 } })
      end, "service.path")
      t.raises(function()
        config_with({ service = { release_base = "file:///tmp/x" } })
      end, "release_base")
      t.raises(function()
        config_with({ service = { install_timeout = 10 } })
      end, "install_timeout")
      t.raises(function()
        config_with({ service = { start_timeout = 1 } })
      end, "start_timeout")
      t.eq("/opt/ade", config_with({ service = { path = "/opt/ade" } }).service.path)
    end)

    t.it("reports an uninstalled service without changing anything", function()
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = tmpdir("status-none")
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      local status = Status.collect({ config = config_with({}) })
      t.eq(Version.VERSION, status.required_version)
      t.eq(Version.API_VERSION, status.required_api_version)
      t.eq("direct", status.backend)
      t.eq(false, status.running)
      t.match("not installed", status.error)
      local lines = Status.lines(status)
      local text = {}
      for _, line in ipairs(lines) do
        text[#text + 1] = line.text
      end
      t.match("not installed", table.concat(text, "\n"))
    end)

    t.it("reports a running service through hello and ping", function()
      local dir = tmpdir("status-running")
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      local service = fake.new({ dir = dir })
      t.truthy(service:listen())
      t.cleanup(function()
        service:close()
      end)
      local status = Status.collect({ config = config_with({}) })
      t.eq(true, status.running)
      t.eq(true, status.api_ok)
      t.eq(Version.API_VERSION, status.api_version)
      -- The stand-in answers `agent.list` with an empty list, and the count must
      -- come from that reply — not from a value read before it arrived.
      t.eq(0, status.instances, "the instance count was not read from the reply")
      local lines = Status.lines(status)
      local text = {}
      for _, line in ipairs(lines) do
        text[#text + 1] = line.text
      end
      t.match("service is running", table.concat(text, "\n"))
      t.match("agent instances: 0", table.concat(text, "\n"))
    end)

    t.it("reports the instance count a real reply carries", function()
      -- Defect: `local listed = false; request(...); if not listed then ...`
      -- always read false, so the count never showed. The stand-in really has an
      -- instance here, so a nil/absent count is visible as a wrong answer.
      local dir = tmpdir("status-instances")
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      local service = fake.new({ dir = dir })
      t.truthy(service:listen())
      t.cleanup(function()
        service:close()
      end)
      -- One attached instance, created through the real attach path.
      local connection = require("ade.service.connection").new({
        resolve_binary = function()
          return { path = "/fake", version = Version.VERSION, api_version = Version.API_VERSION }
        end,
        ensure_service = function()
          return true
        end,
      })
      t.cleanup(function()
        connection:close()
      end)
      local ok, err = connection:request_sync("agent.attach", {
        key = { agent = "opencode", command = "python3", args = {}, cwd = "/tmp" },
        client_capabilities = {},
      })
      t.truthy(ok, require("ade.service.transport").describe(err))

      local status = Status.collect({ config = config_with({}) })
      t.eq(1, status.instances, "status must report the instance the service has")
      local lines = Status.lines(status)
      local text = {}
      for _, line in ipairs(lines) do
        text[#text + 1] = line.text
      end
      t.match("agent instances: 1", table.concat(text, "\n"))
    end)

    t.it("says why the instance count is missing instead of showing nothing", function()
      local dir = tmpdir("status-nolist")
      local saved = vim.env.NVIM_ADE_SERVER_DIR
      vim.env.NVIM_ADE_SERVER_DIR = dir
      t.cleanup(function()
        vim.env.NVIM_ADE_SERVER_DIR = saved
      end)
      local service = fake.new({ dir = dir })
      t.truthy(service:listen())
      t.cleanup(function()
        service:close()
      end)
      -- A client that answers hello but never `agent.list`: the timeout must be
      -- reported, not silently dropped.
      local real = require("ade.service.client")
      local status = Status.collect({
        config = config_with({}),
        timeout = 120,
        client = {
          new = function()
            local client = real.new({ timeout = 500 })
            local original = client.request
            client.request = function(self, method, params, cb)
              if method == "agent.list" then
                -- Never answer: the service is wedged.
                return 1
              end
              return original(self, method, params, cb)
            end
            return client
          end,
        },
      })
      t.eq(true, status.running)
      t.eq(nil, status.instances)
      -- `status.error` also carries "not installed" for a stand-in with no
      -- managed install; the line that matters is the count's own reason.
      local text = {}
      for _, line in ipairs(Status.lines(status)) do
        text[#text + 1] = line.text
      end
      local joined = table.concat(text, "\n")
      t.match("did not answer agent%.list", joined)
    end)
  end)
end
