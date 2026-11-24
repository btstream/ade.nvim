-- The team tree (`:Ade team`): projects -> sessions -> the leader's workers.
--
-- It is the overview the member pane cannot be: every session of a project,
-- which one leads, which one has teams switched off, and what each worker is
-- doing. Data is assembled by the dashboard from the front end's session list,
-- the `team.list` snapshot and `session.teams`; this module only renders.
local Members = require("ade.ui.team.members")
local Text = require("ade.ui.team.text")
local one_line = Text.one_line
local glyph = require("ade.ui.icons").glyph

local M = {}

local function title_of(session)
  local title = type(session) == "table" and session.title or nil
  title = type(title) == "string" and one_line(title) or ""
  if title == "" then
    return nil
  end
  return title
end

local function add(lines, ids, meta, marks, line, id, info, line_marks)
  lines[#lines + 1] = line:text()
  if id then
    ids[#lines] = id
  end
  meta[#lines] = info or {}
  for _, mark in ipairs(line_marks or line:marks()) do
    marks[#marks + 1] = {
      line = #lines,
      start = mark.start,
      stop = mark.stop,
      group = mark.group,
    }
  end
end

---@param groups table[] `{cwd, sessions = { {session, switch, leader, team, workers} }}`
---@param opts {width: integer|nil, current: table|nil}
---@return string[] lines, table ids, table meta, table marks
function M.lines(groups, opts)
  opts = opts or {}
  local width = math.max(20, tonumber(opts.width) or 60)
  local lines, ids, meta, marks = {}, {}, {}, {}
  if #groups == 0 then
    add(lines, ids, meta, marks, Text.new_line():add(" 还没有会话"), "tree:empty", { kind = "tree_empty" })
    return lines, ids, meta, marks
  end
  for _, group in ipairs(groups) do
    local header = Text.new_line()
    header:add(" " .. glyph("team_tree_project") .. " ", "AdeBold")
    header:add(Text.ellipsis(group.cwd or "?", width - 4), "AdeBold")
    add(lines, ids, meta, marks, header, nil, { kind = "tree_project", cwd = group.cwd })
    for _, entry in ipairs(group.sessions or {}) do
      local session = entry.session
      local current = opts.current and opts.current.id == session.id
      local line = Text.new_line()
      line:add("  ")
      if current then
        line:add(glyph("team_tree_current") .. " ", "AdeBold")
      else
        line:add(glyph("team_tree_session") .. " ")
      end
      local title = title_of(session) or session.id
      line:add(Text.ellipsis(title, math.max(1, width - 10)), current and "AdeBold" or nil)
      if entry.leader then
        line:add("  [leader]", "AdeTeamLeader")
      elseif entry.switch and entry.switch.enabled == false then
        line:add("  [team off]", "AdeMuted")
      end
      add(lines, ids, meta, marks, line, "session:" .. tostring(session.id), {
        kind = "tree_session",
        session = session,
        cwd = group.cwd,
        switch = entry.switch,
        leader = entry.leader,
        team = entry.team,
      })
      for _, participant in ipairs(entry.workers or {}) do
        local worker = Text.new_line()
        worker:add("     ")
        worker:add(Members.state_icon(participant) .. " ")
        worker:add(Text.ellipsis(tostring(participant.name or "?"), 18), "AdeBold")
        local label = participant.label and one_line(participant.label) or ""
        if label ~= "" then
          worker:add("  " .. Text.ellipsis(label, 16), "AdeMuted")
        end
        local state = Members.state_label(participant)
        local activity = type(participant.activity) == "table" and participant.activity.text or nil
        if type(activity) == "string" and activity ~= "" then
          state = state .. " · " .. Text.ellipsis(one_line(activity), math.max(4, width - 42))
        end
        worker:add("  " .. Text.ellipsis(state, math.max(4, width - 42)), "AdeMuted")
        add(lines, ids, meta, marks, worker, "worker:" .. tostring(participant.name), {
          kind = "tree_worker",
          team = entry.team and entry.team.id,
          participant = participant,
          session = session,
        })
      end
    end
    add(lines, ids, meta, marks, Text.new_line(), nil, { kind = "tree_gap" })
  end
  return lines, ids, meta, marks
end

return M
