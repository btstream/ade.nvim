-- lazy.nvim example: merge this into your existing blink.cmp spec.
-- Only ade_input uses this source; other filetypes keep their usual sources.
return {
  "saghen/blink.cmp",
  opts = {
    sources = {
      per_filetype = { ade_input = { "ade" } },
      providers = {
        ade = { name = "ADE", module = "ade.completion.blink" },
      },
    },
  },
}
