-- Semantic highlight groups.
--
-- Everything here is static: each group links to one of Neovim's own groups, so
-- the panel looks like any other buffer and follows the colorscheme without this
-- module inspecting colours at runtime.
--
-- Content groups (`AdeBold`, `AdeH1`, ...) link to the treesitter `@markup.*`
-- captures on purpose. A bold word, a heading or a quote therefore renders the
-- same in the transcript as it does in an ordinary Markdown buffer, including
-- under themes that only define the generic captures.
--
-- Two ways to customise, both of which win over these defaults:
--
--   * `ui.highlights` in `setup()` — a table of group -> definition
--   * `vim.api.nvim_set_hl(0, "AdeUser", { fg = "#ff0000" })` at any time
--
-- The defaults are applied with `default = true` (`:hi-default`), which never
-- replaces a group that already exists.
local M = {}

M.groups = {
  AdeNormal = { link = "Normal" },
  AdeMuted = { link = "Comment" },
  AdeBorder = { link = "FloatBorder" },
  AdeTitle = { link = "Title" },

  -- Toolbar. The panel maps `WinBar` to `AdeToolbar`, so a region that only
  -- sets a foreground still paints the bar's background: the bar reads as one
  -- strip, and only the glyph colour changes between states.
  AdeToolbar = { link = "StatusLine" },
  -- Only a foreground: the background is inherited from `AdeToolbar` via the
  -- `%$...$` markup, so there is nothing to set here.
  AdeToolbarAccent = { fg = "fg" },
  -- Modes are badges, told apart by their background.
  AdeToolbarModePlan = { fg = "#212121", bg = "#ffcb6b" },
  AdeToolbarModeBuild = { fg = "#212121", bg = "#c792ea" },
  -- Statuses are plain glyphs. Idle is just the bar's own text colour: no
  -- emphasis means no special colour, and it is readable by construction.
  -- (`Comment` would be tempting but is tuned for prose on `Normal`.) The other
  -- states take their theme diagnostic colour.
  AdeToolbarIdle = { link = "StatusLine" },
  AdeToolbarRunning = { link = "DiagnosticInfo" },
  AdeToolbarWaiting = { link = "DiagnosticWarn" },
  AdeToolbarCancelling = { link = "DiagnosticError" },

  AdeUser = { link = "Function" },
  AdeUserChip = { link = "Visual" },
  AdeInputImage = { fg = "#292929", bg = "#ffcc80", bold = true },

  -- Inline editing. The prompt is a modal-looking float; pending hunks take the
  -- warning colour and the current one the info colour.
  AdeInlinePrompt = { link = "NormalFloat" },
  AdeInlineBorder = { link = "FloatBorder" },
  AdeInlineTitle = { link = "FloatTitle" },
  AdeInlineBanner = { link = "Comment" },
  -- Shared diff roles. Card rows paint these as a background; the review links
  -- its hunk and bar groups to them, so one override reaches every diff surface.
  -- They follow the theme's own diff colours on purpose: the plugin does no
  -- colour maths at runtime.
  AdeDiffAdd = { link = "DiffAdd" },
  AdeDiffDelete = { link = "DiffDelete" },
  AdeDiffModify = { link = "DiffChange" },
  -- Side-by-side review. The columns are padded scratch buffers, not Vim
  -- diff windows, so these are the only surfaces a review paints.
  AdeReviewNormal = { link = "Normal" },
  -- Filler rows: a hatch in a fixed subdued grey, visible on themes whose
  -- `DiffDelete` sets no foreground.
  AdeReviewFiller = { fg = "#5c6370" },
  AdeReviewGutter = { link = "LineNr" },
  AdeReviewGutterCur = { link = "CursorLineNr" },
  AdeReviewFold = { link = "Folded" },
  AdeReviewFoldCol = { link = "FoldColumn" },
  AdeReviewEob = { link = "Normal" },
  AdeReviewSep = { link = "WinSeparator" },
  -- The cursor row, mirrored into every column by `cursorbind`. The background
  -- is copied from `CursorLine` without its underline (see `define_review`).
  AdeReviewCursorLine = { link = "CursorLine" },
  -- Pane headers: a badge saying which side this is, its label and, on the
  -- result column, the decision count.
  AdeReviewBadgeOriginal = { link = "Comment" },
  AdeReviewBadgeResult = { link = "DiagnosticInfo" },
  AdeReviewBadgeProposal = { link = "DiagnosticOk" },
  AdeReviewPath = { link = "Comment" },
  AdeReviewVersion = { link = "NonText" },
  -- Row surfaces. No foreground: syntax colours remain in charge of the text.
  -- The original column shows what goes away, the proposal what comes in, the
  -- result what is still undecided. Backgrounds are copied from the theme's
  -- diff groups in `define_review`.
  AdeReviewAdd = { link = "AdeDiffAdd" },
  AdeReviewDelete = { link = "AdeDiffDelete" },
  AdeReviewPending = { link = "AdeDiffModify" },
  -- Characters that changed inside a paired row.
  AdeReviewAddText = { link = "DiffText" },
  AdeReviewDeleteText = { link = "DiffText" },
  -- A side that lost the decision: the replaced original or the dropped
  -- proposal. A foreground, so it overrides syntax colours.
  AdeReviewDimmed = { link = "Comment" },
  -- The one-cell state bar beside every row of a hunk, in every column.
  AdeReviewStatePending = { link = "DiagnosticWarn" },
  AdeReviewStateCurrent = { link = "DiagnosticInfo" },
  AdeReviewStateAccepted = { link = "AdeInlineAccepted" },
  AdeReviewStateRejected = { link = "AdeInlineRejected" },
  -- Key hints after the hunk under the cursor.
  AdeReviewHint = { link = "Comment" },
  AdeInlineAccepted = { link = "DiagnosticOk" },
  AdeInlineRejected = { link = "ErrorMsg" },
  AdeAssistant = { link = "Normal" },
  -- The block header is split in two so the glyph and the label can be coloured
  -- independently: the icon marks who is speaking, the title names the turn.
  -- Both default to the speaker's own colour, which keeps the header reading as
  -- one unit until someone deliberately splits them.
  AdeUserIcon = { link = "AdeUser" },
  AdeUserTitle = { link = "AdeUserIcon" },
  AdeAssistantIcon = { link = "Keyword" },
  AdeAssistantTitle = { link = "Keyword" },
  -- Thoughts are quiet reasoning text; there is no standard capture for them.
  AdeThought = { link = "@markup.raw" },
  -- Tool headers label a call, they are not the content, so they stay quiet.
  AdeToolTitle = { link = "Comment" },
  AdeToolTag = { link = "Comment" },

  -- There is deliberately no `AdeToolBody` group: card body text must inherit
  -- whatever is behind it so the card's own background shows through.
  --
  -- Both surfaces come from theme groups rather than a colour blended at
  -- runtime. `CursorLine` is the raised one, `NormalFloat` the sunken one, so a
  -- code block inside a card still reads as a separate region.
  AdeCardBg = { link = "CursorLine" },
  AdeCodeBlockBg = { link = "NormalFloat" },
  -- Diffs inside a tool card. The line colour is the diff background itself, so
  -- a change reads like it does in a review window; the sign gets its own group
  -- because some themes only colour the background.
  AdeDiffAddSign = { link = "DiffAdd" },
  AdeDiffRemoveSign = { link = "DiffDelete" },
  AdeDiffHunk = { link = "@label" },
  AdeDiffMeta = { link = "Comment" },
  AdeDiffFile = { link = "Title" },
  -- Same captures a Markdown buffer uses for a fenced block's info string and
  -- for table borders, so both look identical to a `.md` file.
  AdeCodeLang = { link = "@label" },

  AdeTableHead = { link = "@markup.heading" },
  -- The frame is chrome, not content: one quiet grey group for every border
  -- character. `@punctuation.special` would be the Markdown-parity choice, but
  -- themes colour it as an accent (orange under gruvbox), which turns a table
  -- into a neon grid.
  AdeTableBorder = { link = "NonText" },

  AdeToolRunning = { link = "DiagnosticWarn" },
  AdeToolSuccess = { link = "DiagnosticOk" },
  AdeToolError = { link = "DiagnosticError" },
  AdeToolCancelled = { link = "Comment" },

  -- Content shares the treesitter captures used by a Markdown buffer, except
  -- inline code: `@markup.raw` is a warm accent there, which reads as emphasis
  -- in prose. `String` keeps inline code distinguishable from running text
  -- without shouting.
  AdeMdCode = { link = "String" },
  AdeBold = { link = "@markup.strong" },
  AdeItalic = { link = "@markup.italic" },
  AdeStrike = { link = "@markup.strikethrough" },
  AdeMdLink = { link = "@markup.link" },
  -- One per level, so a theme that distinguishes headings keeps doing so. When
  -- it defines only `@markup.heading`, the numbered captures fall back to it —
  -- the same chain a Markdown buffer follows.
  AdeH1 = { link = "@markup.heading.1" },
  AdeH2 = { link = "@markup.heading.2" },
  AdeH3 = { link = "@markup.heading.3" },
  AdeH4 = { link = "@markup.heading.4" },
  AdeQuote = { link = "@markup.quote" },
  AdeLink = { link = "@markup.link" },

  AdePlan = { link = "DiagnosticInfo" },
  AdePlanDone = { link = "DiagnosticOk" },
  AdePlanPending = { link = "Comment" },
  AdeNotice = { link = "DiagnosticInfo" },
  AdeNoticeWarn = { link = "DiagnosticWarn" },
  AdeNoticeError = { link = "DiagnosticError" },
  AdePermission = { link = "DiagnosticWarn" },
  AdeChild = { link = "Comment" },
  AdeSeparator = { link = "NonText" },
  AdeStreaming = { link = "DiagnosticInfo" },

  -- Pickers the plugin draws itself (`ui.picker = "internal"` and the
  -- `:Ade sessions` window). The window chrome is mapped through `winhighlight`,
  -- so a float can be styled apart from other floating windows without
  -- touching the theme's `NormalFloat`/`FloatBorder` groups.
  AdePickerNormal = { link = "NormalFloat" },
  AdePickerBorder = { link = "FloatBorder" },
  AdePickerTitle = { link = "FloatTitle" },
  -- The cursor row. Links to the generic selection group so a picker looks like
  -- every other selection by default, but can be styled on its own.
  AdePickerSelection = { link = "AdeSelection" },
  -- The label of a row. Links to `Normal` rather than to a surface group: inside
  -- a picker float `winhighlight` already remaps `Normal` to `AdePickerNormal`,
  -- while in a snacks list it stays the list's own background.
  AdePickerItem = { link = "Normal" },
  -- Characters matched by the filter query.
  AdePickerMatch = { link = "Search" },
  -- The active row's marker: the session arrow and the check on the current
  -- option.
  AdePickerCurrent = { link = "StatusLine" },
  -- The active row's label. Emphasis only, with no background of its own, so a
  -- snacks row does not turn into a statusline strip.
  AdePickerCurrentItem = { link = "AdeTitle" },
  -- Row descriptions and timestamps, drawn at the end of the line.
  AdePickerDescription = { link = "Comment" },
  AdePickerMeta = { link = "Comment" },
  -- "no match" / "no matching sessions".
  AdePickerEmpty = { link = "Comment" },
  -- The rule above the footer of the session browser.
  AdePickerSeparator = { link = "NonText" },
  -- The filter prompt and the text typed into it.
  AdePickerPrompt = { link = "AdeToolbarAccent" },
  -- Footer hints and transient status ("deleting...", "deleted").
  AdePickerFooter = { link = "Comment" },

  -- Generic selection groups. The pickers link to these by default; the
  -- transcript and panels use them directly.
  AdeSelection = { link = "Visual" },
  AdePinned = { link = "StatusLine" },
}

---Groups supplied through `ui.highlights`. Applied after the defaults and
---replacing them, because naming a group there is an explicit choice.
---@type table<string, table>
local overrides = {}

local augroup = nil

---Define a group unless something already defined it.
---
---Built-in groups use `default` so a user value set with `nvim_set_hl` before
---`setup` survives.
---@param name string
---@param spec table
---@return boolean
local function set_hl(name, spec)
  -- `default` belongs *in* the spec: `nvim_set_hl` takes three parameters, and
  -- a fourth is silently ignored when the call is wrapped in `pcall`.
  return pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", spec, { default = true }))
end

---@param name string
---@param spec table
local function force_hl(name, spec)
  pcall(vim.api.nvim_set_hl, 0, name, spec)
end

---Names overridden by the last `setup`. They are redefined from scratch on the
---next apply so removing an override falls back to the built-in spec instead of
---keeping a stale colour.
local forced = {}

---Give the review row groups the theme's diff background.
---
---Only the background is copied, so the theme's diff foreground or underline
---never replaces syntax colours. That is a read, never a blend: the colour is
---still the theme's, and `ColorScheme` repeats the copy. A theme without a
---diff background falls back to a link.
local function define_review()
  for _, kind in ipairs({
    { "AdeReviewAdd", "DiffAdd" },
    { "AdeReviewDelete", "DiffDelete" },
    { "AdeReviewPending", "DiffChange" },
    { "AdeReviewAddText", "DiffText" },
    { "AdeReviewDeleteText", "DiffText" },
    { "AdeReviewCursorLine", "CursorLine" },
  }) do
    local group, source = kind[1], kind[2]
    local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
    if ok and type(def) == "table" and def.bg then
      force_hl(group, { bg = def.bg })
    else
      force_hl(group, { link = source })
    end
  end
end

---Define every group. Safe to call again after a colorscheme change.
---
---Every group is a literal spec or a link; nothing is computed from the current
---theme. That keeps overrides predictable: setting one role group reaches every
---surface linked to it, and a review always resolves to the same definitions.
local function apply()
  for _, name in ipairs(forced) do
    force_hl(name, {})
  end
  for name, spec in pairs(M.groups) do
    set_hl(name, spec)
  end
  define_review()
  -- The previous overrides were cleared above, which makes `default` skip them;
  -- put their built-in spec back before applying the current overrides.
  for _, name in ipairs(forced) do
    if M.groups[name] then
      force_hl(name, M.groups[name])
    end
  end
  for name, spec in pairs(overrides) do
    force_hl(name, spec)
  end
  forced = vim.tbl_keys(overrides)
end

M.apply = apply

---Apply highlights.
---
---A colorscheme load clears every user group, so the definitions are re-applied
---on ColorScheme. Without this the whole panel loses its colours when the user
---switches theme after setup.
---@param config table<string, table>|nil group name -> `nvim_set_hl` definition
function M.setup(config)
  overrides = type(config) == "table" and config or {}
  apply()

  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("AdeHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      apply()
    end,
  })
end

---------------------------------------------------------------------------
-- Picker groups
---------------------------------------------------------------------------

---Group names used by the plugin's own pickers.
---
---Kept here so the picker modules and their tests share one source of truth
---instead of repeating string literals.
M.picker = {
  normal = "AdePickerNormal",
  border = "AdePickerBorder",
  title = "AdePickerTitle",
  selection = "AdePickerSelection",
  item = "AdePickerItem",
  match = "AdePickerMatch",
  current = "AdePickerCurrent",
  current_item = "AdePickerCurrentItem",
  description = "AdePickerDescription",
  meta = "AdePickerMeta",
  empty = "AdePickerEmpty",
  separator = "AdePickerSeparator",
  prompt = "AdePickerPrompt",
  footer = "AdePickerFooter",
}

---`winhighlight` string that maps a picker float's chrome onto the
---`AdePicker*` groups.
---
---`style = "minimal"` installs its own `Normal:NormalFloat,FloatBorder:...`
---mapping, so this must be assigned *after* the window is created.
---@return string
function M.picker_winhl()
  return table.concat({
    "Normal:" .. M.picker.normal,
    "NormalNC:" .. M.picker.normal,
    "FloatBorder:" .. M.picker.border,
    "FloatTitle:" .. M.picker.title,
  }, ",")
end

---Resolve a status to a highlight group.
---@param status string|nil
---@return string
function M.tool_status(status)
  if status == "completed" then
    return "AdeToolSuccess"
  elseif status == "failed" then
    return "AdeToolError"
  elseif status == "in_progress" or status == "pending" then
    return "AdeToolRunning"
  elseif status == "cancelled" then
    return "AdeToolCancelled"
  end
  return "AdeMuted"
end

return M
