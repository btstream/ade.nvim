-- Team Changed Files: the files pane, its Agents integration and file opening.
--
-- The data module (`ade.app.team_files`) is stubbed here: this spec is about the
-- pane layout, the group cache/guards and the keyboard/mouse actions.
local TeamUI = require("ade.ui.team")
local Files = require("ade.ui.team.files")
local config = require("ade.config")

return function(t)
  local counter = 0

  ---@param tag string
  ---@return string
  local function tmpdir(tag)
    counter = counter + 1
    local dir = string.format("/tmp/opencode/ade-team-files-%s-%d-%d", tag, vim.uv.os_getpid(), counter)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p", 448)
    return dir
  end

  ---@param over table|nil
  ---@return table
  local function cfg(over)
    return config.validate(config.merge(config.defaults, over or {}), over)
  end

  ---@param columns integer
  ---@param lines integer|nil
  local function screen(t, columns, lines)
    local old_columns, old_lines = vim.o.columns, vim.o.lines
    vim.o.columns = columns
    vim.o.lines = lines or 40
    t.cleanup(function()
      vim.o.columns = old_columns
      vim.o.lines = old_lines
      pcall(vim.cmd, "wincmd =")
    end)
  end

  local function wait(cond, label)
    if not vim.wait(5000, cond, 20) then
      error("timed out: " .. tostring(label), 2)
    end
  end

  ---@param entry table
  ---@return table
  local function participant(entry)
    return vim.tbl_deep_extend("force", {
      role = "worker",
      state = "working",
      task = "T1",
      queued = 0,
      turns = { task = 0, total = 0 },
      state_since = os.time() * 1000 - 1000,
    }, entry)
  end

  ---A fake team service module: only the surface the dashboard reads.
  ---@param opts table
  ---@return table
  local function fake_team(opts)
    local state = { rows = opts.rows, inbox = {}, workflows_list = {} }
    local team = {
      inbox = state.inbox,
      workflows_list = state.workflows_list,
      controls = {},
      bound = {},
    }
    function team:list_rows()
      return state.rows
    end
    function team:resolve_cwd()
      return state.rows[1] and state.rows[1].cwd or opts.cwd
    end
    function team:is_stale(id)
      local row = self:team(id)
      return row ~= nil and row.stale == true
    end
    function team:is_suspended(id)
      local row = self:team(id)
      return row ~= nil and row.state == "suspended"
    end
    function team:team(id)
      for _, row in ipairs(state.rows) do
        if row.id == id then
          return row
        end
      end
    end
    function team:participant(id, name)
      local row = self:team(id)
      for _, entry in ipairs(row and row.participants or {}) do
        if entry.name == name then
          return entry
        end
      end
    end
    function team:team_for_cwd(cwd)
      for _, row in ipairs(state.rows) do
        if row.cwd == cwd then
          return row
        end
      end
    end
    function team:control(id, name, body)
      self.controls[#self.controls + 1] = { id, name, body }
    end
    function team:board()
      return nil
    end
    function team:session_teams()
      return nil
    end
    function team:query_session_teams(_, _, _, cb)
      if cb then
        cb(false)
      end
    end
    return team
  end

  ---Install a stub `ade.app.team_files`; scans resolve on the main loop.
  ---@param t table
  ---@param files table<string, table[]>
  ---@param bases table<string, string>
  ---@return table stub
  local function stub_data(t, files, bases)
    local stub = {
      scans = {},
      reads = {},
      files = files,
      bases = bases or {},
      manual = false,
      manual_reads = false,
      errors = {},
      throws = {},
      waiting = {},
      read_waiting = {},
    }
    local previous = package.loaded["ade.app.team_files"]
    package.loaded["ade.app.team_files"] = {
      scan = function(worktree, cb)
        stub.scans[#stub.scans + 1] = vim.deepcopy(worktree)
        local answer = vim.deepcopy(stub.files[worktree.path] or {})
        local err = stub.errors[worktree.path]
        if stub.throws[worktree.path] then
          error(stub.throws[worktree.path])
        end
        if stub.manual then
          stub.waiting[#stub.waiting + 1] = {
            worktree = vim.deepcopy(worktree),
            cb = cb,
            answer = answer,
            err = err,
          }
        else
          vim.schedule(function()
            cb(err, answer)
          end)
        end
      end,
      read_base = function(worktree, path, cb)
        stub.reads[#stub.reads + 1] = { worktree = vim.deepcopy(worktree), path = path }
        local content = stub.bases[worktree.path .. "/" .. path]
        local function answer(err, value)
          cb(err, value)
        end
        if stub.manual_reads then
          stub.read_waiting[#stub.read_waiting + 1] = {
            worktree = vim.deepcopy(worktree),
            path = path,
            cb = cb,
            content = content,
          }
        else
          vim.schedule(function()
            if content == nil then
              answer("not in base", nil)
            else
              answer(nil, content)
            end
          end)
        end
      end,
    }
    t.cleanup(function()
      package.loaded["ade.app.team_files"] = previous
    end)
    return stub
  end

  ---@return table
  local function base_team_rows(dir)
    local t1 = {
      id = "t1",
      cwd = dir,
      state = "active",
      workflow_name = "dev",
      participants = {
        { name = "leader", role = "leader", state = "idle", task = "_", queued = 0, turns = {} },
        { name = "human", role = "human", state = "idle", task = "_", queued = 0, turns = {} },
        participant({ name = "w1", worktree = { path = dir .. "/wt/w1", branch = "ade/t1/w1", base = "abc" } }),
        participant({ name = "w2", worktree = { path = dir .. "/wt/w2", branch = "ade/t1/w2" } }),
        participant({ name = "w3" }),
        participant({ name = "w4", state = "exited", worktree = { path = dir .. "/wt/w4", branch = "ade/t1/w4" } }),
      },
      inbox = {},
      limits = { turns_total = 0, max_turns_total = 200 },
      stages = {},
    }
    return { t1 }
  end

  local function make_ui(t, settings, rows, notices)
    local team = fake_team({ rows = rows, cwd = rows[1].cwd })
    local UI = TeamUI.new({
      team = team,
      config = function()
        return settings
      end,
      notify = function(message)
        if notices then
          notices[#notices + 1] = tostring(message)
        end
      end,
    })
    t.cleanup(function()
      pcall(UI.close, UI)
      pcall(UI.files.stop_timer, UI.files)
    end)
    return UI, team
  end

  ---@param UI table
  ---@param pane string
  ---@return string
  local function text(UI, pane)
    local buf = UI.layout:buf(pane)
    if not buf then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  ---@param UI table
  ---@param pane string
  ---@param id string
  ---@return integer|nil
  local function line_of(UI, pane, id)
    for line, current in pairs(UI.layout.ids[pane] or {}) do
      if current == id then
        return line
      end
    end
  end

  ---@param UI table
  ---@param pane string
  ---@param predicate fun(info: table): boolean
  ---@return integer|nil
  local function line_where(UI, pane, predicate)
    for line, info in pairs(UI.layout.meta[pane] or {}) do
      if predicate(info) then
        return line
      end
    end
  end

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  t.describe("team files pane", function()
    t.it("docks right on a narrow editor and renders per-worker groups", function()
      screen(t, 80, 40)
      local dir = tmpdir("dock")
      local rows = base_team_rows(dir)
      write(dir .. "/wt/w1/src/a.lua", { "hello" })
      write(dir .. "/wt/w1/src/old.lua", { "gone" })
      write(dir .. "/wt/w4/doc.md", { "exited" })
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = {
          { status = "M", path = "src/a.lua" },
          { status = "D", path = "src/old.lua" },
          { status = "R", path = "src/b.lua", old_path = "src/a2.lua" },
        },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = { { status = "A", path = "doc.md" } },
      })
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      local win = UI.layout:win("files")
      t.truthy(win, "the files pane did not open")
      t.eq("", vim.api.nvim_win_get_config(win).relative, "narrow editors still dock the files pane")
      t.eq(vim.o.columns, vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win))
      t.eq("ade_team_files", vim.bo[UI.layout:buf("files")].filetype)
      t.eq(Files.REFRESH_MS, UI.files.timer ~= nil and Files.REFRESH_MS or nil, "the refresh timer runs while open")

      wait(function()
        local body = text(UI, "files")
        return body:find("src/a.lua", 1, true) ~= nil and body:find("doc.md", 1, true) ~= nil
      end, "the worker groups")
      local body = text(UI, "files")
      t.match("w1", body)
      t.match("wt ade/t1/w1", body)
      t.match("· 3", body, "w1's file count")
      t.match("没有改动", body, "w2 is clean")
      t.match("共享 cwd", body)
      t.match("无法归属", body)
      t.match("w4", body)
      t.match("doc.md", body, "an exited worker's worktree is still readable")
      t.truthy(#stub.scans >= 3, "each worktree is scanned once")
    end)

    t.it("honours an explicit float position for files", function()
      screen(t, 80, 40)
      local dir = tmpdir("float")
      local rows = base_team_rows(dir)
      stub_data(t, { [dir .. "/wt/w1"] = {}, [dir .. "/wt/w2"] = {}, [dir .. "/wt/w4"] = {} })
      local settings = cfg({ teams = { layout = { panes = { files = { position = "float" } } } } })
      local UI = make_ui(t, settings, rows)
      t.eq(true, UI:open("files"))
      t.truthy(vim.api.nvim_win_get_config(UI.layout:win("files")).relative ~= "", "an explicit float floats")
    end)

    t.it("uses the external backend's plain split and edgy gets its view", function()
      screen(t, 100, 40)
      local dir = tmpdir("external")
      local rows = base_team_rows(dir)
      stub_data(t, { [dir .. "/wt/w1"] = {}, [dir .. "/wt/w2"] = {}, [dir .. "/wt/w4"] = {} })
      local settings = cfg({ layout = { backend = "external" } })
      local UI = make_ui(t, settings, rows)
      -- The warning about unregistered edgy views is covered by spec_edgy_views.
      local edgy = require("ade.integrations.edgy")
      local checked = edgy._team_checked
      edgy._team_checked = true
      t.cleanup(function()
        edgy._team_checked = checked
      end)
      t.eq(true, UI:open("files"))
      local win = UI.layout:win("files")
      t.eq("", vim.api.nvim_win_get_config(win).relative, "no narrow float fallback under external")
      t.eq(false, vim.wo[win].winfixwidth, "the layout manager sizes the pane")
      local views = edgy.views()
      t.eq("ade_team_files", views.files.ft)
    end)

    t.it("opens a worker's group with f from the Agents pane, including its wt row", function()
      screen(t, 200, 50)
      local dir = tmpdir("agents-f")
      local rows = base_team_rows(dir)
      write(dir .. "/wt/w1/src/a.lua", { "hello" })
      stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      local UI, team = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("members"))
      wait(function()
        return line_of(UI, "members", "t1|w1") ~= nil
      end, "the w1 member row")

      -- Collapse w1 in the files pane first, so `f` has to expand it again.
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of(UI, "members", "t1|w1"), 0 })
      UI:handle_key("f")
      local files_win = UI.layout:win("files")
      t.truthy(files_win, "f opens the files pane")
      wait(function()
        return line_of(UI, "files", "file:w1\0src/a.lua") ~= nil
      end, "the w1 files")
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file_group:w1"), 0 })
      UI:handle_key("cr")
      t.eq(nil, line_of(UI, "files", "file:" .. "w1" .. "\0src/a.lua"), "Enter collapses the group")

      -- `f` on a worker's primary row expands and focuses its group.
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of(UI, "members", "t1|w1"), 0 })
      UI:handle_key("f")
      t.truthy(line_of(UI, "files", "file:w1\0src/a.lua"), "f expands the worker group")
      t.eq("file_group:w1", UI.layout.ids.files[vim.api.nvim_win_get_cursor(UI.layout:win("files"))[1]])

      -- The existing wt detail row of a worker does the same.
      local wt_line = line_where(UI, "members", function(info)
        return info.kind == "participant_detail" and info.name == "w1"
      end)
      t.truthy(wt_line, "the worker has a detail row")
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { wt_line, 0 })
      UI:handle_key("f")
      t.eq("file_group:w1", UI.layout.ids.files[vim.api.nvim_win_get_cursor(UI.layout:win("files"))[1]])

      -- `f` on the team row opens the pane for every worker.
      local team_line = line_of(UI, "members", "team:t1")
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { team_line, 0 })
      UI:handle_key("f")
      t.truthy(UI.layout:win("files"))
      t.eq(0, #team.controls, "f must not touch a worker's turn")
    end)

    t.it("opens files by exact worktree path, reuses the buffer and reads deleted files from base", function()
      screen(t, 200, 50)
      local dir = tmpdir("open")
      local rows = base_team_rows(dir)
      write(dir .. "/wt/w1/src/a.lua", { "hello", "world" })
      write(dir .. "/wt/w2/src/a.lua", { "different worktree" })
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = {
          { status = "M", path = "src/a.lua" },
          { status = "D", path = "src/gone.lua" },
        },
        [dir .. "/wt/w2"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w4"] = {},
      }, { [dir .. "/wt/w1/src/gone.lua"] = "old line\n" })
      local UI = make_ui(t, cfg(), rows)
      local cwd_before = vim.fn.getcwd()
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:w1\0src/a.lua") ~= nil and line_of(UI, "files", "file:w2\0src/a.lua") ~= nil
      end, "both file rows")

      local files_win = UI.layout:win("files")
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w1\0src/a.lua"), 0 })
      UI:handle_key("cr")
      local abs = dir .. "/wt/w1/src/a.lua"
      t.eq(abs, vim.api.nvim_buf_get_name(0), "opened with the worktree's absolute path")
      t.eq({ "hello", "world" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      t.truthy(UI.layout:win("files"), "the files pane stays open")
      t.eq(cwd_before, vim.fn.getcwd(), "opening a file never changes the cwd")
      local first_buf = vim.api.nvim_get_current_buf()

      -- Opening it again reuses the same ordinary buffer.
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w1\0src/a.lua"), 0 })
      UI:handle_key("cr")
      t.eq(first_buf, vim.api.nvim_get_current_buf(), "the same buffer is reused")

      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w2\0src/a.lua"), 0 })
      UI:handle_key("cr")
      t.eq(dir .. "/wt/w2/src/a.lua", vim.api.nvim_buf_get_name(0))
      t.eq({ "different worktree" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      t.truthy(first_buf ~= vim.api.nvim_get_current_buf(), "same relative path uses a separate buffer")

      -- A deleted file opens its read-only base version.
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w1\0src/gone.lua"), 0 })
      UI:handle_key("cr")
      wait(function()
        return vim.api.nvim_buf_get_name(0):find("ade-base://", 1, true) ~= nil
      end, "the base buffer")
      t.eq({ "old line" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      t.eq(true, vim.bo.readonly)
      t.eq(false, vim.bo.modifiable)
      t.truthy(#stub.reads >= 1, "read_base was asked for the deleted file")
      t.truthy(UI.layout:win("files"), "the pane is still open after the base version")
    end)

    t.it("refreshes with r, keeps group state, follows ]t and closes with q", function()
      screen(t, 200, 50)
      local dir = tmpdir("keys")
      local rows = base_team_rows(dir)
      local other = {
        id = "t2",
        cwd = dir .. "/other",
        state = "active",
        workflow_name = "dev",
        participants = { participant({ name = "w9", worktree = { path = dir .. "/wt/w9", branch = "ade/t2/w9" } }) },
        inbox = {},
        limits = { turns_total = 0, max_turns_total = 200 },
        stages = {},
      }
      rows[2] = other
      write(dir .. "/wt/w1/src/a.lua", { "hello" })
      write(dir .. "/wt/w9/src/nine.lua", { "nine" })
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
        [dir .. "/wt/w9"] = { { status = "A", path = "src/nine.lua" } },
      })
      local UI, team = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:w1\0src/a.lua") ~= nil
      end, "the initial scan")
      local scans = #stub.scans

      -- Collapse w1, then refresh: the collapse survives.
      local files_win = UI.layout:win("files")
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file_group:w1"), 0 })
      UI:handle_key("cr")
      t.eq(nil, line_of(UI, "files", "file:w1\0src/a.lua"))
      UI:handle_key("r")
      wait(function()
        return #stub.scans > scans
      end, "the explicit refresh scan")
      t.eq(nil, line_of(UI, "files", "file:w1\0src/a.lua"), "collapse survives a refresh")
      t.eq(
        "file_group:w1",
        UI.layout.ids.files[vim.api.nvim_win_get_cursor(files_win)[1]],
        "selection survives a refresh"
      )
      t.eq(0, #team.controls, "r in the files pane refreshes instead of resuming a worker")

      -- ]t switches the Agents selection, and the files pane follows it.
      UI:handle_key("]t")
      wait(function()
        local body = text(UI, "files")
        return body:find("nine.lua", 1, true) ~= nil
      end, "the second team's files")
      t.match("w9", text(UI, "files"))
      t.eq(nil, line_of(UI, "files", "file:w1\0src/a.lua"), "the old team's rows are gone")

      -- q closes the files pane only.
      t.eq(true, UI:open("members"))
      vim.api.nvim_set_current_win(UI.layout:win("files"))
      UI:handle_key("q")
      t.eq(nil, UI.layout:win("files"))
      t.truthy(UI.layout:win("members"), "members stays open")
      t.eq(nil, UI.files.timer, "the refresh timer stops with the pane")
    end)

    t.it("drops a scan that arrives after the team changed", function()
      screen(t, 200, 50)
      local dir = tmpdir("stale")
      local rows = base_team_rows(dir)
      rows[2] = {
        id = "t2",
        cwd = dir .. "/other",
        state = "active",
        workflow_name = "dev",
        participants = { participant({ name = "w9", worktree = { path = dir .. "/wt/w9", branch = "ade/t2/w9" } }) },
        inbox = {},
        limits = { turns_total = 0, max_turns_total = 200 },
        stages = {},
      }
      local stub = stub_data(t, {})
      stub.manual = true
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return #stub.waiting > 0
      end, "the first scan request")
      local first = stub.waiting[1]
      local before_switch = #stub.waiting

      -- Switch teams before the slow answer arrives.
      UI:handle_key("]t")
      wait(function()
        return #stub.waiting > before_switch
      end, "the second team's scan request")
      local second = stub.waiting[#stub.waiting]
      t.eq(dir .. "/wt/w9", second.worktree.path)

      first.cb(nil, { { status = "M", path = "stale.txt" } })
      second.cb(nil, { { status = "A", path = "fresh.txt" } })
      wait(function()
        return text(UI, "files"):find("fresh.txt", 1, true) ~= nil
      end, "the fresh answer")
      t.falsy(text(UI, "files"):find("stale.txt", 1, true), "the stale answer was dropped")
    end)

    t.it("shows a failed scan and re-reads a group whose worktree changed", function()
      screen(t, 200, 50)
      local dir = tmpdir("rework")
      local rows = base_team_rows(dir)
      local old_path = dir .. "/wt/w1"
      local new_path = dir .. "/wt/w1b"
      write(old_path .. "/src/a.lua", { "hello" })
      write(new_path .. "/src/b.lua", { "new" })
      local stub = stub_data(t, {
        [old_path] = { { status = "M", path = "src/a.lua" } },
        [new_path] = { { status = "A", path = "src/b.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      stub.errors[dir .. "/wt/w2"] = "git status failed"
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return text(UI, "files"):find("git status failed", 1, true) ~= nil
      end, "the scan error")
      local body = text(UI, "files")
      t.match("读取失败", body)
      t.match("src/a.lua", body, "another group keeps its files")
      t.match("没有改动", body, "the empty group is still shown")

      -- The worker moved to another worktree: the old rows must not survive.
      rows[1].participants[3].worktree.path = new_path
      UI:refresh()
      wait(function()
        return text(UI, "files"):find("src/b.lua", 1, true) ~= nil
      end, "the new worktree scan")
      body = text(UI, "files")
      local new_line = line_of(UI, "files", "file:w1\0src/b.lua")
      t.eq(new_path, UI.layout.meta.files[new_line].worktree.path, "the new worktree identity")
      t.falsy(body:find("src/a.lua", 1, true), "the old worktree's files are gone")
    end)

    t.it("keeps one scan per group in flight and coalesces explicit refreshes", function()
      screen(t, 200, 50)
      local dir = tmpdir("flight")
      local rows = base_team_rows(dir)
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      stub.manual = true
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return #stub.waiting >= 3
      end, "the initial scans")
      local initial, scans = #stub.waiting, #stub.scans

      -- The low-frequency timer must not replace a slow scan.
      UI.files:refresh(false)
      t.eq(scans, #stub.scans, "a timer tick leaves a pending scan alone")
      for _, group in pairs(UI.files.groups) do
        t.falsy(group.queued, "the timer must not queue a follow-up")
      end

      -- Repeated `r` presses only queue one follow-up per group.
      UI.files:refresh(true)
      UI.files:refresh(true)
      t.eq(scans, #stub.scans, "no second request while the first is still running")
      for _, group in pairs(UI.files.groups) do
        if group.scannable then
          t.eq(true, group.queued, "the explicit refresh is coalesced")
        end
      end

      for index = 1, initial do
        local answer = stub.waiting[index]
        answer.cb(answer.err, answer.answer)
      end
      wait(function()
        return #stub.waiting == initial + 3
      end, "one follow-up scan per group")
      t.eq(scans + 3, #stub.scans, "exactly one follow-up, not one per r press")
      for index = initial + 1, #stub.waiting do
        local answer = stub.waiting[index]
        answer.cb(answer.err, answer.answer)
      end
      wait(function()
        return UI.files.groups.w1.status == "ready"
      end, "the follow-up answer")
    end)

    t.it("clears pending when a scan raises and retries on the next refresh", function()
      screen(t, 200, 50)
      local dir = tmpdir("throw")
      local rows = base_team_rows(dir)
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      stub.throws[dir .. "/wt/w1"] = "git exploded"
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return text(UI, "files"):find("git exploded", 1, true) ~= nil
      end, "the scan failure")
      local group = UI.files.groups.w1
      t.eq("error", group.status)
      t.falsy(group.pending, "a raised scan must not stay pending")
      local before = #stub.scans
      UI.files:refresh(true)
      wait(function()
        return #stub.scans > before
      end, "the retry")
      t.eq("error", group.status)
      t.falsy(group.pending)
    end)

    t.it("clears pending when a scan never answers", function()
      screen(t, 200, 50)
      local dir = tmpdir("watchdog")
      local rows = base_team_rows(dir)
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      stub.manual = true
      local timeout = Files.REQUEST_TIMEOUT_MS
      Files.REQUEST_TIMEOUT_MS = 30
      t.cleanup(function()
        Files.REQUEST_TIMEOUT_MS = timeout
      end)
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return text(UI, "files"):find("读取超时", 1, true) ~= nil
      end, "the stalled scan to time out")
      t.falsy(UI.files.groups.w1.pending, "a timeout clears pending")
      t.eq("error", UI.files.groups.w1.status)
    end)

    t.it("keeps a worker named shared apart from the shared-cwd group", function()
      screen(t, 200, 50)
      local dir = tmpdir("shared-key")
      local rows = base_team_rows(dir)
      rows[1].participants[#rows[1].participants + 1] = participant({
        name = "shared",
        worktree = { path = dir .. "/wt/shared", branch = "ade/t1/shared" },
      })
      write(dir .. "/wt/shared/x.txt", { "x" })
      stub_data(t, {
        [dir .. "/wt/w1"] = {},
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
        [dir .. "/wt/shared"] = { { status = "M", path = "x.txt" } },
      })
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:shared\0x.txt") ~= nil
      end, "the real worker's group")
      t.truthy(line_of(UI, "files", "file_group:shared"), "the worker shared has its own group")
      t.truthy(line_of(UI, "files", "file_group:@shared"), "the shared-cwd group is separate")

      t.eq(true, UI:open("members"))
      wait(function()
        return line_of(UI, "members", "t1|shared") ~= nil and line_of(UI, "members", "t1|w3") ~= nil
      end, "both member rows")
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of(UI, "members", "t1|shared"), 0 })
      UI:handle_key("f")
      t.eq(
        "file_group:shared",
        UI.layout.ids.files[vim.api.nvim_win_get_cursor(UI.layout:win("files"))[1]],
        "f follows the real worker named shared"
      )
      vim.api.nvim_set_current_win(UI.layout:win("members"))
      vim.api.nvim_win_set_cursor(UI.layout:win("members"), { line_of(UI, "members", "t1|w3"), 0 })
      UI:handle_key("f")
      t.eq(
        "file_group:@shared",
        UI.layout.ids.files[vim.api.nvim_win_get_cursor(UI.layout:win("files"))[1]],
        "a cwd-only worker still lands on the shared group"
      )
    end)

    t.it("opens odd paths and never fabricates an empty buffer for a vanished file", function()
      screen(t, 200, 50)
      local dir = tmpdir("odd")
      local rows = base_team_rows(dir)
      local odd = "src/odd\nname.lua"
      local odd_abs = dir .. "/wt/w1/" .. odd
      local ghost_abs = dir .. "/wt/w1/src/ghost.lua"
      vim.fn.mkdir(vim.fs.dirname(odd_abs), "p")
      vim.fn.writefile({ "odd" }, odd_abs)
      t.eq(1, vim.fn.filereadable(odd_abs), "the newline file exists")
      local notices = {}
      stub_data(t, {
        [dir .. "/wt/w1"] = {
          { status = "M", path = odd },
          { status = "M", path = "src/ghost.lua" },
        },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      local UI = make_ui(t, cfg(), rows, notices)
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:w1\0" .. odd) ~= nil
      end, "the odd file row")

      local files_win = UI.layout:win("files")
      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w1\0" .. odd), 0 })
      UI:handle_key("cr")
      t.eq(odd_abs, vim.api.nvim_buf_get_name(0), "a newline in the path is not Ex syntax")
      t.eq({ "odd" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))

      vim.api.nvim_set_current_win(files_win)
      vim.api.nvim_win_set_cursor(files_win, { line_of(UI, "files", "file:w1\0src/ghost.lua"), 0 })
      UI:handle_key("cr")
      t.eq(files_win, vim.api.nvim_get_current_win(), "a vanished file does not steal focus")
      t.eq(-1, vim.fn.bufnr(ghost_abs), "a vanished file gets no empty buffer")
      t.truthy(#notices > 0 and notices[#notices]:find("不存在", 1, true), "the person is told why")
    end)

    t.it("drops a base answer after a newer open, a team switch or closing the pane", function()
      screen(t, 200, 50)
      local dir = tmpdir("base-guard")
      local rows = base_team_rows(dir)
      rows[2] = {
        id = "t2",
        cwd = dir .. "/other",
        state = "active",
        workflow_name = "dev",
        participants = { participant({ name = "w9", worktree = { path = dir .. "/wt/w9", branch = "ade/t2/w9" } }) },
        inbox = {},
        limits = { turns_total = 0, max_turns_total = 200 },
        stages = {},
      }
      write(dir .. "/wt/w1/src/a.lua", { "a" })
      local stub = stub_data(t, {
        [dir .. "/wt/w1"] = {
          { status = "M", path = "src/a.lua" },
          { status = "D", path = "src/gone.lua" },
        },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
        [dir .. "/wt/w9"] = {},
      })
      stub.manual_reads = true
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:w1\0src/gone.lua") ~= nil
      end, "the deleted file row")

      local function select_file(path)
        local win = UI.layout:win("files")
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { line_of(UI, "files", "file:w1\0" .. path), 0 })
        UI:handle_key("cr")
      end
      local function base_buffers()
        local found = 0
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find("ade-base://", 1, true) then
            found = found + 1
          end
        end
        return found
      end

      -- A newer ordinary open owns the focus.
      select_file("src/gone.lua")
      local first = stub.read_waiting[#stub.read_waiting]
      select_file("src/a.lua")
      local opened = vim.api.nvim_buf_get_name(0)
      t.eq(dir .. "/wt/w1/src/a.lua", opened)
      first.cb(nil, "base")
      vim.wait(50)
      t.eq(opened, vim.api.nvim_buf_get_name(0), "the older base answer must not take over")
      t.eq(0, base_buffers())

      -- Switching teams invalidates the open.
      select_file("src/gone.lua")
      local second = stub.read_waiting[#stub.read_waiting]
      vim.api.nvim_set_current_win(UI.layout:win("files"))
      UI:handle_key("]t")
      second.cb(nil, "base")
      vim.wait(50)
      t.eq(0, base_buffers(), "a team switch drops the pending base answer")

      -- Closing the pane invalidates it too.
      vim.api.nvim_set_current_win(UI.layout:win("files"))
      UI:handle_key("[t")
      wait(function()
        return line_of(UI, "files", "file:w1\0src/gone.lua") ~= nil
      end, "the first team again")
      select_file("src/gone.lua")
      local third = stub.read_waiting[#stub.read_waiting]
      vim.api.nvim_set_current_win(UI.layout:win("files"))
      UI:handle_key("q")
      t.eq(nil, UI.layout:win("files"))
      third.cb(nil, "base")
      vim.wait(50)
      t.eq(0, base_buffers(), "closing the pane drops the pending base answer")
    end)

    t.it("acts on the clicked row and keeps the pane open", function()
      screen(t, 200, 50)
      local dir = tmpdir("mouse")
      local rows = base_team_rows(dir)
      write(dir .. "/wt/w1/src/a.lua", { "hello" })
      stub_data(t, {
        [dir .. "/wt/w1"] = { { status = "M", path = "src/a.lua" } },
        [dir .. "/wt/w2"] = {},
        [dir .. "/wt/w4"] = {},
      })
      local UI = make_ui(t, cfg(), rows)
      t.eq(true, UI:open("files"))
      wait(function()
        return line_of(UI, "files", "file:w1\0src/a.lua") ~= nil
      end, "the file row")
      local files_win = UI.layout:win("files")
      local mapping = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(UI.layout:buf("files"), "n")) do
        if map.lhs == "<LeftMouse>" then
          mapping = true
        end
      end
      t.truthy(mapping, "the files pane maps a click")

      UI:handle_mouse({ winid = files_win, line = line_of(UI, "files", "file:w1\0src/a.lua"), column = 1 })
      t.eq(dir .. "/wt/w1/src/a.lua", vim.api.nvim_buf_get_name(0))
      t.truthy(UI.layout:win("files"), "a click keeps the pane open")
    end)

    t.it("dispatches :Ade team files", function()
      local ade = require("ade")
      local original = ade.open_team
      local got
      ade.open_team = function(kind)
        got = kind
        return true
      end
      t.cleanup(function()
        ade.open_team = original
      end)
      vim.cmd("Ade team files")
      t.eq("files", got)
    end)
  end)
end
