-- The participant transcript builder (W0g).
--
-- A worker is rendered by the ordinary chat over a display-only session: the
-- reducer still owns the watched session, while this module groups its blocks
-- into turns, renders bus traffic as messages, and keeps the role card
-- collapsed. There is no separate watch window or composer any more: the team
-- router points the single `ade_chat`/`ade_input` pair at this display session.
local M = {}

local function unescape(text)
  return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&"))
end

local function one_line(text)
  return (tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+$", ""))
end

---The first `<bus ...>` tag in a prompt.
---@param text string
---@return {from: string|nil, kind: string|nil, task: string|nil, body: string, at: integer}|nil
local function parse_bus(text)
  local from, kind, task = text:match('<bus from="([^"]*)" kind="([^"]*)" task="([^"]*)"')
  if not from then
    from, kind = text:match('<bus from="([^"]*)" kind="([^"]*)"')
  end
  if not from then
    return nil
  end
  local body = text:match("^.-<bus[^>]*>(.-)</bus>") or ""
  return { from = from, kind = kind, task = task, body = unescape(body), at = text:find("<bus", 1, true) or 1 }
end

---Split a first prompt into its role card and its initial bus message.
---@param text string
---@return string|nil role, string message
local function split_role(text)
  local bus_at = text:find("<bus", 1, true)
  if not bus_at then
    -- Only a bus prompt can carry a role-card prefix; an ordinary prompt that
    -- happens to start with "You are" is a normal message.
    return nil, text
  end
  local before = text:sub(1, bus_at - 1)
  if before:find("You are ", 1, true) or before:find("<team_role>", 1, true) then
    return before, text:sub(bus_at)
  end
  return nil, text
end

---The tool's most descriptive name/title.
---@param block table
---@return string
local function typesafe_title(block)
  local value = block.tool_name or block.name or block.title or ""
  if type(value) ~= "string" then
    return ""
  end
  return value:lower()
end

---A tool card becomes a message line when it is an ade-team tool.
---@param block table
---@return {title: string, text: string}|nil
local function bus_tool(block)
  return require("ade.ui.team.tools").describe(block)
end

---A display-only session for Chat: the source blocks grouped into turns.
---@param source table
local function block_signature(block)
  return table.concat({
    tostring(block.id or ""),
    tostring(block.kind or ""),
    tostring(block.status or ""),
    tostring(#(block.text or "")),
    tostring(block._revision or ""),
    tostring(block.title or ""),
    tostring(#(type(block.raw_input) == "table" and vim.inspect(block.raw_input) or "")),
    block.archived and "1" or "0",
    block.toggled and "t" or "-",
  }, "\1")
end

---@param opts {collapsed: table<integer, boolean>, expanded: table<string, boolean>,
---  turn_times: table<string, {started_at: integer|nil, ended_at: integer|nil}>|nil,
---  supplement: table|nil, version: integer|nil, on_toggle: (fun(block: table)|nil),
---  cache: table|nil, use_cache: boolean|nil}
---@return table session
local function build_session(source, opts)
  local display = {
    id = source.id,
    cwd = source.cwd,
    blocks = {},
    version = (opts.version or 0) + 1,
    tracked = false,
    historical = true,
    trimmed = source.trimmed,
  }
  function display:toggle(block)
    block.toggled = true
    block.expanded = not block.expanded
    if opts.on_toggle then
      opts.on_toggle(block)
    end
  end
  function display:finish_turn() end

  local blocks = display.blocks
  local next_id = 0
  local function add(block, id)
    if id then
      block.id = id
    elseif not block.id then
      next_id = next_id + 1
      block.id = "watch-" .. next_id
    end
    blocks[#blocks + 1] = block
    return block
  end

  if opts.title then
    add({
      kind = "system",
      text = " watching " .. tostring(opts.title) .. " (read-only)",
      id = "watch-title",
    })
  end

  local supplement = opts.supplement
  if supplement then
    add({
      kind = "system",
      text = "会话过长，只显示观察开始之后的内容",
      id = "watch-banner",
    })
    for index, message in ipairs(type(supplement.messages) == "table" and supplement.messages or {}) do
      local task = message.task
      local title = string.format(
        "%s %s %s%s",
        tostring(message.from or "?"),
        require("ade.ui.icons").glyph("team_send"),
        tostring(message.kind or "message"),
        task and task ~= "_" and (" " .. task) or ""
      )
      add({
        kind = "message",
        title = title,
        text = tostring(message.body or ""),
        id = "watch-message-" .. index,
      })
    end
    local turns = type(supplement.turns) == "table" and supplement.turns or {}
    for index = math.max(1, #turns - 2), #turns do
      local turn = turns[index]
      if type(turn) == "table" and type(turn.text) == "string" and turn.text ~= "" then
        add({
          kind = "agent",
          text = turn.text,
          id = "watch-turn-text-" .. index,
        })
      end
    end
  end

  -- First pass: turn groups. A user block is a prompt and opens a turn.
  local groups = {}
  local current = nil
  for _, block in ipairs(source.blocks or {}) do
    if block.kind == "user" then
      current = { prompt = block, body = {} }
      groups[#groups + 1] = current
    elseif current then
      current.body[#current.body + 1] = block
    else
      add(block)
    end
  end

  for turn_index, group in ipairs(groups) do
    local prompt = group.prompt
    local bus = parse_bus(prompt.text or "")
    local body_sig = {}
    for body_index, block in ipairs(group.body) do
      body_sig[body_index] = block_signature(block)
    end
    local timing_sig = opts.turn_times and opts.turn_times[prompt.id] or {}
    local signature = table.concat({
      tostring(turn_index),
      tostring(prompt.id),
      tostring(#(prompt.text or "")),
      tostring(timing_sig.started_at or ""),
      tostring(timing_sig.ended_at or ""),
      opts.collapsed[turn_index] and "1" or "0",
      opts.expanded["watch-role-" .. turn_index] and "1" or "0",
      table.concat(body_sig, "\2"),
    }, "\1")
    if opts.cache and opts.use_cache and opts.cache[prompt.id] and opts.cache[prompt.id].sig == signature then
      for _, cached in ipairs(opts.cache[prompt.id].blocks) do
        blocks[#blocks + 1] = cached
      end
    else
      local turn_start = #blocks + 1
      local origin = (type(prompt.bus) == "table" and prompt.bus.origin) or (bus and "bus") or "prompt"
      local timing = opts.turn_times and opts.turn_times[prompt.id] or nil
      local started = timing and timing.started_at or nil
      local ended = timing and timing.ended_at or nil
      local label
      if bus and bus.from == "human" and opts.target then
        label = string.format("human %s %s", require("ade.ui.icons").glyph("team_send"), tostring(opts.target))
      elseif bus then
        label = string.format(
          "%s %s %s%s",
          bus.from or "?",
          require("ade.ui.icons").glyph("team_send"),
          bus.kind or "message",
          bus.task and bus.task ~= "" and (" " .. bus.task) or ""
        )
      else
        label = origin
      end
      local tools = 0
      for _, block in ipairs(group.body) do
        if block.kind == "tool" then
          tools = tools + 1
        end
      end
      local parts = { string.format("── turn %d", turn_index), origin, label }
      if tools > 0 then
        parts[#parts + 1] = string.format("%d tool%s", tools, tools == 1 and "" or "s")
      end
      if started and ended and ended >= started then
        parts[#parts + 1] = string.format("%.1fs", (ended - started) / 1000)
      end
      local collapsed = opts.collapsed[turn_index] == true
      if collapsed then
        parts[#parts + 1] = "(collapsed)"
      end
      add({
        kind = "system",
        text = table.concat(parts, " · "),
        id = "watch-turn-" .. turn_index,
      })

      local text = prompt.text or ""
      -- The role card belongs to the first bus prompt only.
      local role, message = nil, text
      if turn_index == 1 and bus then
        role, message = split_role(text)
      end
      if role then
        local role_id = "watch-role-" .. turn_index
        add({
          kind = "message",
          title = "role card",
          text = role,
          collapsible = true,
          expanded = opts.expanded[role_id] == true,
          display_text = "",
          id = role_id,
        }, role_id)
      end
      local bus_message = parse_bus(message)
      add({
        kind = "message",
        title = label,
        text = bus_message and bus_message.body or unescape(message),
        id = "watch-prompt-" .. turn_index,
      }, "watch-prompt-" .. turn_index)

      if not collapsed then
        for body_index, block in ipairs(group.body) do
          local message_block = bus_tool(block)
          if message_block then
            add({
              kind = "message",
              title = message_block.title ~= "" and message_block.title or "bus",
              text = message_block.text,
              id = "watch-bus-" .. tostring(block.id or body_index) .. "-" .. body_index,
            }, "watch-bus-" .. tostring(block.id or body_index) .. "-" .. body_index)
          else
            add(block)
          end
        end
      end
      if opts.cache then
        local cached = {}
        for index = turn_start, #blocks do
          cached[#cached + 1] = blocks[index]
        end
        opts.cache[prompt.id] = { sig = signature, blocks = cached }
      end
    end
  end

  return display
end
M.build_session = build_session
M.parse_bus = parse_bus
M.split_role = split_role
M.bus_tool = bus_tool

return M
