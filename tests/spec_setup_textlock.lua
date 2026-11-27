-- `ade.setup()` under textlock: lazy.nvim's `keys` handler loads the plugin
-- inside an `<expr>` mapping, where creating the panel buffers fails with E565.
-- The configuration must survive and be applied once the lock is gone, never
-- replaced by the defaults when the first command runs.
return function(t)
  local ade = require("ade")
  local controller = require("ade.controller")

  local function feed_expr(fn)
    local lhs = "<F35>"
    local errors = {}
    vim.keymap.set("n", lhs, function()
      local ok, err = pcall(fn)
      if not ok then
        errors[#errors + 1] = tostring(err)
      end
      return ""
    end, { expr = true })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
    pcall(vim.keymap.del, "n", lhs)
    return errors
  end

  t.describe("setup under textlock", function()
    t.it("does not fail inside an <expr> mapping and applies the options later", function()
      local errors = feed_expr(function()
        ade.setup({ backend = "direct", ui = { session_picker = "internal" }, log = { level = "error" } })
      end)
      t.eq(0, #errors, table.concat(errors, "\n"))
      vim.wait(1000, function()
        local cfg = controller.state().config
        return cfg ~= nil and cfg.log.level == "error"
      end, 10)
      local cfg = controller.state().config
      t.truthy(cfg, "setup was never applied")
      t.eq("error", cfg.log.level)
      t.eq("internal", cfg.ui.session_picker)
    end)

    t.it("applies the deferred options, not the defaults, when a command runs first", function()
      local errors = feed_expr(function()
        ade.setup({ backend = "direct", log = { level = "info" } })
      end)
      t.eq(0, #errors, table.concat(errors, "\n"))
      -- Before the scheduled apply runs, an API call must use the user's options.
      ade.status()
      t.eq("info", controller.state().config.log.level)
      -- The scheduled apply must not run setup a second time with stale options.
      ade.setup({ backend = "direct", log = { level = "warn" } })
      vim.wait(200)
      t.eq("warn", controller.state().config.log.level)
    end)
  end)
end
