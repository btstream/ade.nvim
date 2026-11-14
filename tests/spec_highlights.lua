return function(t)
  local highlights = require("ade.ui.highlights")

  local function defined(name)
    local hl = vim.api.nvim_get_hl(0, { name = name })
    return hl ~= nil and next(hl) ~= nil
  end

  t.describe("highlights", function()
    t.it("defines every semantic group", function()
      highlights.setup()
      for name in pairs(highlights.groups) do
        t.truthy(defined(name), name .. " was not defined")
      end
    end)

    t.it("survives a colorscheme change", function()
      highlights.setup()
      t.truthy(defined("AdeUser"), "not defined after setup")

      -- Loading any colorscheme clears user groups; the ColorScheme autocmd
      -- must put them back.
      vim.cmd("silent! colorscheme default")
      vim.cmd("doautocmd ColorScheme")

      for _, name in ipairs({ "AdeUser", "AdeAssistant", "AdeToolbar", "AdeToolTitle" }) do
        t.truthy(defined(name), name .. " lost after a colorscheme change")
      end
    end)

    t.it("re-applies after several colorscheme switches", function()
      highlights.setup()
      for _, scheme in ipairs({ "default", "blue", "default" }) do
        vim.cmd("silent! colorscheme " .. scheme)
        vim.cmd("doautocmd ColorScheme")
        t.truthy(defined("AdeUser"), "lost after switching to " .. scheme)
      end
    end)

    -- Surfaces are links to theme groups, not colours blended at runtime, so
    -- the check is that the link resolves to a background distinct from
    -- `Normal` under whatever theme is active.
    t.it("puts cards and code blocks on distinct theme surfaces", function()
      vim.cmd("hi clear")
      vim.cmd("syntax reset")
      highlights.setup()

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
      end
      local normal = bg("Normal")
      local card = bg("AdeCardBg")
      local code = bg("AdeCodeBlockBg")

      t.truthy(card, "the card surface has no background")
      t.truthy(code, "the code block surface has no background")
      t.truthy(card ~= normal, "the card blends into Normal")
      t.truthy(code ~= normal, "the code block blends into Normal")
      t.truthy(card ~= code, "the card and the code block look the same")
      -- Inline code deliberately has no surface: a background per word is noisy
      -- in prose and would break up a card.
      t.eq(nil, bg("AdeMdCode"), "inline code should not paint a background")
    end)

    t.it("links content groups to the same captures a markdown buffer uses", function()
      -- A bold word or a heading must look the same in the transcript as in a
      -- Markdown file: reuse the treesitter captures instead of inventing
      -- parallel colours.
      local expected = {
        AdeBold = "@markup.strong",
        AdeItalic = "@markup.italic",
        AdeStrike = "@markup.strikethrough",
        AdeMdCode = "String",
        AdeMdLink = "@markup.link",
        AdeH1 = "@markup.heading.1",
        AdeH2 = "@markup.heading.2",
        AdeH3 = "@markup.heading.3",
        AdeH4 = "@markup.heading.4",
        AdeQuote = "@markup.quote",
      }
      for name, target in pairs(expected) do
        t.eq(target, highlights.groups[name].link, name .. " should link to " .. target)
      end
      -- Review row groups declare the shared diff role as their fallback (the
      -- effective background is copied from the theme at apply time, without
      -- the theme's foreground or underline).
      t.eq("AdeDiffAdd", highlights.groups["AdeReviewAdd"].link)
      t.eq("AdeDiffDelete", highlights.groups["AdeReviewDelete"].link)
      t.eq("AdeDiffModify", highlights.groups["AdeReviewPending"].link)
      t.eq("DiffText", highlights.groups["AdeReviewAddText"].link)
      t.eq("DiffText", highlights.groups["AdeReviewDeleteText"].link)
    end)

    t.it("respects a user override made before setup", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AdeUser", { fg = "#ff0000" })
      vim.api.nvim_set_hl(0, "AdeBold", { fg = "#00ff00" })
      highlights.setup()

      t.eq(0xff0000, vim.api.nvim_get_hl(0, { name = "AdeUser" }).fg, "AdeUser was overwritten")
      t.eq(0x00ff00, vim.api.nvim_get_hl(0, { name = "AdeBold" }).fg, "AdeBold was overwritten")
    end)

    t.it("respects a user override made after setup", function()
      vim.cmd("hi clear")
      highlights.setup()
      vim.api.nvim_set_hl(0, "AdeThought", { fg = "#123456" })

      -- A colorscheme load re-applies every group; the user's value must survive.
      vim.cmd("doautocmd ColorScheme")
      t.eq(0x123456, vim.api.nvim_get_hl(0, { name = "AdeThought" }).fg, "AdeThought was overwritten")
    end)

    t.it("respects a user override of a derived group", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AdeCardBg", { bg = "#123456" })
      vim.api.nvim_set_hl(0, "AdeToolbarModePlan", { fg = "#abcdef", bg = "#111111" })
      vim.api.nvim_set_hl(0, "AdeToolbarIdle", { fg = "#999999" })
      highlights.setup()

      t.eq(0x123456, vim.api.nvim_get_hl(0, { name = "AdeCardBg" }).bg, "derived surface was overwritten")
      local badge = vim.api.nvim_get_hl(0, { name = "AdeToolbarModePlan" })
      t.eq(0xabcdef, badge.fg, "badge foreground was overwritten")
      t.eq(0x111111, badge.bg, "badge background was overwritten")
      t.eq(0x999999, vim.api.nvim_get_hl(0, { name = "AdeToolbarIdle" }).fg, "status glyph was overwritten")
    end)

    t.it("still defines groups the user left alone", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AdeUser", { fg = "#ff0000" })
      highlights.setup()
      -- A group next to the overridden one must still get its default.
      t.truthy(defined("AdeAssistant"), "a non-overridden group was not defined")
      t.truthy(defined("AdeToolbarModePlan"), "a derived group was not defined")
    end)

    t.it("gives each block header glyph and title their own group", function()
      -- The four groups exist so an icon and its label can be coloured apart.
      -- What each one points at is a styling choice, so only their existence is
      -- asserted here; how the blocks use them is covered in spec_markdown.
      for _, name in ipairs({ "AdeUserIcon", "AdeUserTitle", "AdeAssistantIcon", "AdeAssistantTitle" }) do
        t.truthy(highlights.groups[name], name .. " is not in the group table")
        t.truthy(defined(name), name .. " was not defined")
      end
    end)

    t.it("does not give card body text a background of its own", function()
      highlights.setup()
      -- No `AdeToolBody` group exists on purpose; body text inherits the card.
      t.eq(nil, highlights.groups["AdeToolBody"], "card body must not define a group")
    end)

    t.it("links the diff roles and review surfaces without computing colours", function()
      -- A diff inside a card has to read like a diff in a review window, so the
      -- line colours come from the theme rather than a blended colour.
      local expected = {
        AdeDiffAdd = "DiffAdd",
        AdeDiffDelete = "DiffDelete",
        AdeDiffModify = "DiffChange",
        AdeDiffAddSign = "DiffAdd",
        AdeDiffRemoveSign = "DiffDelete",
        AdeDiffHunk = "@label",
        AdeDiffMeta = "Comment",
        AdeDiffFile = "Title",
      }
      for name, target in pairs(expected) do
        t.eq(target, highlights.groups[name].link, name .. " should link to " .. target)
      end
      -- Review row groups declare the shared diff role as their fallback (the
      -- effective background is copied from the theme at apply time, without
      -- the theme's foreground or underline).
      t.eq("AdeDiffAdd", highlights.groups["AdeReviewAdd"].link)
      t.eq("AdeDiffDelete", highlights.groups["AdeReviewDelete"].link)
      t.eq("AdeDiffModify", highlights.groups["AdeReviewPending"].link)
      t.eq("DiffText", highlights.groups["AdeReviewAddText"].link)
      t.eq("DiffText", highlights.groups["AdeReviewDeleteText"].link)
    end)

    t.it("applies groups passed through the config", function()
      vim.cmd("hi clear")
      highlights.setup({ AdeUser = { fg = "#abcdef" }, AdeToolbarModePlan = { fg = "#111111", bg = "#222222" } })

      t.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "AdeUser" }).fg, "configured group was not applied")
      local badge = vim.api.nvim_get_hl(0, { name = "AdeToolbarModePlan" })
      t.eq(0x222222, badge.bg, "configured badge background was not applied")
      -- Groups not mentioned in the config keep their defaults.
      t.truthy(defined("AdeAssistant"), "an unconfigured group lost its default")
    end)

    t.it("re-applies configured groups after a colorscheme change", function()
      vim.cmd("hi clear")
      highlights.setup({ AdeUser = { fg = "#abcdef" } })
      vim.cmd("silent! colorscheme default")
      vim.cmd("doautocmd ColorScheme")

      t.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "AdeUser" }).fg, "configured colour lost on colorscheme change")
    end)

    t.it("lets a configured group replace a built-in one", function()
      vim.cmd("hi clear")
      highlights.setup({ AdeCardBg = { bg = "#101010" } })
      -- The definition wins over the link the default table would install.
      t.eq(0x101010, vim.api.nvim_get_hl(0, { name = "AdeCardBg", link = false }).bg)
    end)

    t.it("does not stack autocmds on repeated setup", function()
      highlights.setup()
      highlights.setup()
      highlights.setup()
      local count = 0
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "ColorScheme" })) do
        if autocmd.group_name == "AdeHighlights" then
          count = count + 1
        end
      end
      t.eq(1, count, "ColorScheme handler registered more than once")
    end)
  end)
end
