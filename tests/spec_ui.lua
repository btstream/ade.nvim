return function(t)
  local Chat = require("ade.ui.chat")
  local Input = require("ade.ui.input")
  local config = require("ade.config")
  local state = require("ade.session.state")

  local function cfg(over)
    return config.validate(config.merge(config.defaults, over or {}))
  end

  t.describe("ui", function()
    t.it("renders a session into the transcript buffer", function()
      local c = cfg()
      local chat = Chat.new({ config = c })
      local s = state.new("s", "/tmp")
      s:add_local_user("hi there")
      s:append({ id = "a", kind = "agent", text = "hello back" })
      chat:set_session(s)
      local lines = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      local joined = table.concat(lines, "\n")
      t.match("hi there", joined)
      t.match("hello back", joined)
    end)

    t.it("is read-only and named ade_chat", function()
      local chat = Chat.new({ config = cfg() })
      t.eq("ade_chat", vim.bo[chat.buf].filetype)
      t.falsy(vim.bo[chat.buf].modifiable)
      t.eq("nofile", vim.bo[chat.buf].buftype)
    end)

    t.it("reuses cached blocks when nothing changed", function()
      local chat = Chat.new({ config = cfg() })
      local s = state.new("s", "/tmp")
      s:append({ id = "a", kind = "agent", text = "one" })
      chat:set_session(s)
      local cache = chat.cache["a"]
      chat:render()
      t.eq(cache, chat.cache["a"])
    end)

    t.it("toggles a tool block", function()
      local chat = Chat.new({ config = cfg() })
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "tool", title = "Run", status = "completed", detail = "line1\nline2" })
      chat:set_session(s)
      local before = #vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      s.blocks[1].expanded = true
      chat:render()
      local after = #vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      t.truthy(after > before, "expanding should add lines")
    end)

    t.it("exposes the transcript as plain text", function()
      local chat = Chat.new({ config = cfg() })
      local s = state.new("s", "/tmp")
      s:add_local_user("copy me")
      chat:set_session(s)
      t.match("copy me", chat:transcript())
    end)

    t.it("re-renders a tool card when its command arrives later", function()
      local chat = Chat.new({ config = cfg() })
      local s = state.new("s", "/tmp")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        title = "Run Command",
        status = "completed",
        expanded = true,
        detail = "output",
      })
      chat:set_session(s)
      local first = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n")
      t.falsy(first:find("$ ", 1, true), "there is no command yet")

      -- A later update supplies the structured command; without it in the
      -- render signature the cached card would never show it.
      s.blocks[1].raw_input = { command = "ls -la" }
      s:touch(s.blocks[1], false)
      chat:render()
      local second = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n")
      t.truthy(second:find("$ ls -la", 1, true), "the command did not reach the card: " .. second)
    end)

    t.it("keeps drafts isolated per session", function()
      local input = Input.new({ config = cfg() })
      input:switch_session("a")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "draft a" })
      input:switch_session("b")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "draft b" })
      input:switch_session("a")
      t.eq("draft a", input:text())
      input:switch_session("b")
      t.eq("draft b", input:text())
    end)

    t.it("recalls bounded user history with the default insert-mode keys", function()
      local c = cfg({ ui = { input_history_limit = 2 } })
      local input = Input.new({ config = c })
      local s = state.new("history", "/tmp")
      s:add_local_user("outside the limit")
      s:add_local_user("older")
      s:add_local_user("newest\nsecond line")
      s:append({ id = "agent", kind = "agent", text = "reply" })
      s:add_local_user("generated instructions", nil, { display_text = "inline: edit", generated_prompt = true })
      s:user_chunk("echoed instructions", "inline")
      vim.api.nvim_set_current_buf(input.buf)
      require("ade.ui.keymaps").attach("input", input.buf, c.keymaps.input, {
        on_history_prev = function()
          return input:recall(1, s.blocks)
        end,
        on_history_next = function()
          return input:recall(-1, s.blocks)
        end,
      })
      local function keys(keys_)
        vim.api.nvim_feedkeys(vim.keycode(keys_), "x", false)
        return input:text()
      end
      t.eq("newest\nsecond line", keys("i<Up><Esc>"))
      t.eq("older", keys("i<C-p><Up><Esc>"))
      t.eq("newest\nsecond line", keys("i<C-n><Esc>"))
      t.eq("", keys("i<Down><Esc>"))
      t.eq("newest\nsecond line!", keys("i<Up>!<Up><Esc>"))
      t.eq(1, vim.api.nvim_win_get_cursor(0)[1], "Up falls back to the original cursor motion")
      t.eq("newest\nsecond line", keys("u"), "undo removes the edit without undoing the recall")
      input:destroy()
    end)

    t.it("lets existing composer bindings keep their keys when adding history defaults", function()
      local keymaps = require("ade.ui.keymaps")
      local enabled = cfg({ keymaps = { input = { pick_model = { i = "<C-p>" } } } })
      local claims = keymaps.claims("input", enabled.keymaps.input)
      local prev = vim.fn.keytrans(vim.keycode("<C-p>"))
      t.eq("pick_model", claims["i\0" .. prev].action)
      t.eq("history_prev", claims["n\0" .. prev].action)
      t.eq({ "<Up>" }, enabled.keymaps.input.history_prev.i)
      local disabled = cfg({
        ui = { input_history_limit = 0 },
        keymaps = { input = { pick_model = { i = "<C-p>" }, history_prev = "<C-p>" } },
      })
      t.eq(false, disabled.keymaps.input.history_prev)
      t.eq(false, disabled.keymaps.input.history_next)
      local ok, err = pcall(cfg, { keymaps = { input = { pick_model = { i = "<C-p>" }, history_prev = "<C-p>" } } })
      t.falsy(ok)
      t.match("both use", err)
    end)

    t.it("protects drafts and attachments and resets history at session changes", function()
      local input = Input.new({ config = cfg() })
      local blocks = { { kind = "user", text = "old message" } }
      input:switch_session("a")
      input.attachments = { { kind = "file", path = "a" } }
      t.falsy(input:recall(1, blocks))
      input:clear()
      t.truthy(input:recall(1, blocks))
      input:switch_session("b")
      input:switch_session("a")
      t.eq("", input:text(), "an unedited recall should not become a draft")
      t.truthy(input:recall(1, blocks))
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "edited" })
      t.falsy(input:recall(-1, blocks))
      input:switch_session("b")
      input:switch_session("a")
      t.eq("edited", input:text())
      input:clear()
      input.config.ui.input_history_limit = 0
      t.falsy(input:recall(1, blocks))
      input:destroy()
    end)

    t.it("adds and deduplicates attachments", function()
      local input = Input.new({ config = cfg() })
      input:switch_session("s")
      t.truthy(input:add_attachment({ kind = "file", label = "a.lua", path = "/tmp/a.lua" }))
      t.falsy(input:add_attachment({ kind = "file", label = "a.lua", path = "/tmp/a.lua" }))
      t.eq(1, #input.attachments)
    end)

    t.it("clears the composer after submit", function()
      local submitted
      local input = Input.new({
        config = cfg(),
        on_submit = function(text)
          submitted = text
        end,
      })
      input:switch_session("s")
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "hello" })
      input:submit()
      t.eq("hello", submitted)
    end)

    t.it("ignores empty submissions", function()
      local count = 0
      local input = Input.new({
        config = cfg(),
        on_submit = function()
          count = count + 1
        end,
      })
      input:switch_session("s")
      input:submit()
      t.eq(0, count)
    end)
  end)
end
