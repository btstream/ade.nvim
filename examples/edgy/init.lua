-- edgy.nvim layout integration.
--
--   nvim -u examples/edgy/init.lua
--
-- Shows how edgy owns the panel position while ade.nvim owns the content.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
vim.opt.runtimepath:append(root)

-- Use the edgy.nvim installed by your plugin manager, or place it on the
-- runtimepath before starting Neovim.
local ok = pcall(require, "edgy")
if not ok then
  vim.notify("edgy.nvim is required for this example", vim.log.levels.ERROR)
  return
end

vim.opt.number = true
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"

-- The chat pair goes to the right (the configured `layout.position`); the team
-- panes go to the left edge and the board spans the bottom. Use `team = false`
-- to leave the team panes as ordinary windows instead.
local views = { right = {}, left = {}, bottom = {} }
require("ade.integrations.edgy").extend(views, {
  team = { tree = "left", members = "left", board = "bottom" },
})

require("edgy").setup({
  right = views.right,
  left = views.left,
  bottom = views.bottom,
  options = {
    right = { size = 46 },
    left = { size = 30 },
    bottom = { size = 12 },
  },
  animate = { enabled = true },
})

require("ade").setup({
  layout = { backend = "external" },
})

vim.keymap.set("n", "<leader>a", function()
  require("ade").toggle()
end, { desc = "ADE panel" })
