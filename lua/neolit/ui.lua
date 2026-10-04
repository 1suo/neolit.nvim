--- The Neovim panel: a left sidebar split holding the planned tree and a
--- detail split for DESCRIPTION/CHANGES — real editor windows, no floating
--- chrome. Status, revision, model, and the busy spinner live in the
--- sidebar's winbar (native); messages and errors go through vim.notify.
--- The controller, model runtime, apply/commit transactions, and the pane
--- view model all stay in the host shim; this module renders frames and
--- routes keys.

local config = require("neolit.config")
local theme = require("neolit.theme")
local hostmod = require("neolit.host")
local render = require("neolit.render")
local keys = require("neolit.keys")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local OP_LABELS = {
  start = "Starting plan",
  develop = "Developing selected path",
  apply = "Applying drafted changes",
  commit = "Committing applied changes",
  lock = "Applying restriction",
  allow = "Applying restriction",
  choose = "Using selected approach",
  message = "Sending message",
  rethink = "Rethinking selected path",
  reopen = "Reworking selected plan",
  stale = "Marking repository change",
  configure = "Updating models",
}

local INPUT_TITLES = {
  objective = "What should change?",
  reopen = "Reason for reopening selected node",
  stale = "Changed repository path",
}

local state = nil

local unpack_table = unpack or table.unpack

local function spinner()
  return SPINNER_FRAMES[((state and state.spinner_i or 1) - 1) % #SPINNER_FRAMES + 1]
end

local function busy_now()
  return state ~= nil and (state.pending ~= nil or (state.frame and state.frame.panel and state.frame.panel.busy))
end

local function selected_path()
  if not state or not state.frame then return nil end
  local row_id = state.frame.tree.selectedRowId
  if type(row_id) == "string" and row_id:sub(1, 6) == "entry:" then
    local path = row_id:sub(7)
    return path ~= "." and path or nil
  end
  return nil
end

--------------------------------------------------------------------------
-- Tree folding and hiding (pure row filtering)
--------------------------------------------------------------------------

local function row_path(row)
  return type(row.id) == "string" and row.id:sub(1, 6) == "entry:" and row.id:sub(7) or nil
end

local function ancestor_paths(path)
  local ancestors = {}
  if path == "." then return ancestors end
  ancestors[#ancestors + 1] = "."
  local current = path
  while true do
    local parent = current:match("^(.*)/")
    if not parent then break end
    current = parent == "" and "." or parent
    if current == "." then break end
    ancestors[#ancestors + 1] = current
  end
  return ancestors
end

--- Default fold set for a fresh frame: every directory that neither carries
--- plan state nor is an ancestor of a planned path. Touched folders and
--- their ancestors stay open.
function M.default_folded(rows)
  local open = { ["."] = true }
  for _, row in ipairs(rows) do
    local path = row_path(row)
    if path and (not row.repositoryOnly or row.marked) then
      open[path] = true
      for _, ancestor in ipairs(ancestor_paths(path)) do
        open[ancestor] = true
      end
    end
  end
  local folded = {}
  for _, row in ipairs(rows) do
    local path = row_path(row)
    if path and row.directory and not open[path] then
      folded[path] = true
    end
  end
  return folded
end

--- zm/zr level targets: `more` (zm) folds every directory at the shallowest
--- still-open level; `reduce` (zr) opens every directory at the shallowest
--- folded level — deeper folded directories are invisible until their
--- ancestors open, so each press peels one level. Pure.
function M.fold_level_targets(rows, effective, mode)
  local depth_of = function(path)
    if path == "." then return 0 end
    return select(2, path:gsub("/", "")) + 1
  end
  local candidates = {}
  for _, row in ipairs(rows) do
    local path = row_path(row)
    if path and row.directory then
      local ancestors_open = true
      for _, ancestor in ipairs(ancestor_paths(path)) do
        if effective[ancestor] then ancestors_open = false break end
      end
      if ancestors_open then
        candidates[#candidates + 1] = { path = path, folded = effective[path] ~= nil, depth = depth_of(path) }
      end
    end
  end
  local min_open, min_folded = nil, nil
  for _, candidate in ipairs(candidates) do
    if candidate.folded then
      if not min_folded or candidate.depth < min_folded then min_folded = candidate.depth end
    else
      if not min_open or candidate.depth < min_open then min_open = candidate.depth end
    end
  end
  local targets = { fold = {}, open = {} }
  for _, candidate in ipairs(candidates) do
    if mode == "more" and not candidate.folded and candidate.depth == min_open then
      targets.fold[candidate.path] = true
    elseif mode == "reduce" and candidate.folded and candidate.depth == min_folded then
      targets.open[candidate.path] = true
    end
  end
  return targets
end

--- True when two frames' rendered content differs. During a busy operation
--- the spinner poll fires every 120ms; identical frames must not re-render
--- buffers or touch cursors, or the editor drowns and input feels blocked.
function M.frames_differ(a, b)
  local function signature(frame)
    if not frame then return "" end
    return vim.json.encode({ rows = frame.tree and frame.tree.rows, detail = frame.detail, routedOptions = frame.routedOptions })
  end
  return signature(a) ~= signature(b)
end

--- Which rows render: a row is visible when no ancestor directory is folded
--- and, in plan-only mode, when it (or a descendant) carries plan state.
--- `rows` come from the shim with `directory` and `repositoryOnly` flags.
function M.visible_rows(rows, folded, plan_only)
  local marked = nil
  if plan_only then
    marked = { ["."] = true }
    for _, row in ipairs(rows) do
      local path = row_path(row)
      if path and (not row.repositoryOnly or row.marked) then
        marked[path] = true
        for _, ancestor in ipairs(ancestor_paths(path)) do
          marked[ancestor] = true
        end
      end
    end
  end
  local visible = {}
  for _, row in ipairs(rows) do
    local path = row_path(row)
    local hidden = false
    if path then
      for _, ancestor in ipairs(ancestor_paths(path)) do
        if folded[ancestor] then hidden = true break end
      end
      if marked ~= nil and not marked[path] then hidden = true end
    end
    if not hidden then visible[#visible + 1] = row end
  end
  return visible
end

--- The effective fold set for the live panel: the plan-aware default,
--- minus directories the user explicitly opened, plus explicit folds.
--- Lives up here because M.render calls it.
local function effective_folded(rows)
  local folded = M.default_folded(rows)
  for path in pairs(state.explicit_open or {}) do
    folded[path] = nil
  end
  for path in pairs(state.folded or {}) do
    folded[path] = true
  end
  return folded
end

local function message_title()
  return (selected_path() or "repo") .. " · message (task, question, or note; empty = rethink)"
end

--------------------------------------------------------------------------
-- Winbar (native chrome) and notifications
--------------------------------------------------------------------------

local function escape_statusline(text)
  return text:gsub("%%", "%%%%")
end

--- Chips from the shim's header, as a statusline-format string.
local function winbar_text()
  local segments = {}
  if busy_now() then
    local label = state.cancel_requested and "Cancelling…" or (
      (state.frame and state.frame.panel and state.frame.panel.operation)
      or (state.pending and state.pending.label) or "Working"
    )
    segments[#segments + 1] = { text = spinner() .. " " .. label .. "…", group = "NeolitWarningBold" }
  else
    local frame = state.frame
    local error_text = state.local_error or (frame and frame.panel and frame.panel.error)
    for _, chip in ipairs(frame and frame.header and frame.header.left or {}) do
      local group = chip.text == "[IDLE]" and "NeolitMuted" or nil
      if error_text and chip.text:find("^%[") then group = "NeolitError" end
      segments[#segments + 1] = {
        text = chip.text,
        group = group or theme.group_for(chip.color, chip.bold),
      }
    end
    -- The related filter belongs to the tree this winbar titles: a quiet
    -- suffix while it hides unrelated paths, from either toggle (the host's
    -- plan-only filter or the controller's related-only view).
    if state.plan_only or (frame and frame.relatedOnly) then
      segments[#segments + 1] = { text = "· related", group = "NeolitMuted" }
    end
  end
  local parts = {}
  for _, segment in ipairs(segments) do
    local prefix = segment.group and ("%#" .. segment.group .. "#") or ""
    parts[#parts + 1] = prefix .. escape_statusline(segment.text)
  end
  parts[#parts + 1] = "%#Normal#"
  return table.concat(parts, " ")
end

local function update_winbars()
  if not state then return end
  if vim.api.nvim_win_is_valid(state.wins.tree) then
    vim.api.nvim_win_set_option(state.wins.tree, "winbar", winbar_text())
  end
end

--- Panel messages become notifications — once per distinct text, only when
--- idle (the winbar carries the live state while an operation runs).
local function notify_panel()
  if not state or busy_now() then return end
  local frame = state.frame
  local error_text = state.local_error or (frame and frame.panel and frame.panel.error)
  local text = error_text and ("✗ " .. error_text) or (frame and frame.panel and frame.panel.message)
  if text and text ~= "" and text ~= state.last_notice then
    state.last_notice = text
    vim.notify(text, error_text and vim.log.levels.ERROR or vim.log.levels.INFO)
  end
end

--- Replaces the earliest spinner glyph in a tree line (all frames are
--- single-width, 3-byte braille, so columns and extmarks stay put).
function M.replace_first_spinner(line, glyph)
  local best_start, best_length
  for _, frame in ipairs(SPINNER_FRAMES) do
    local start = string.find(line, frame, 1, true)
    if start and (not best_start or start < best_start) then
      best_start = start
      best_length = #frame
    end
  end
  if not best_start then return line end
  return string.sub(line, 1, best_start - 1) .. glyph .. string.sub(line, best_start + best_length)
end

--- Row indices whose rendered indicator is a spinner glyph — the target of
--- the busy animation, recomputed on every content render.
local function record_live_rows(tree_lines)
  local indices = {}
  for index, line in ipairs(tree_lines) do
    for _, segment in ipairs(line.segments or {}) do
      if vim.tbl_contains(SPINNER_FRAMES, segment.text) then
        indices[#indices + 1] = index
        break
      end
    end
  end
  return indices
end

--- Animates the live rows' spinner glyph in place: one small line edit per
--- tick, never a full re-render (which once froze the whole editor).
function M.animate_live_rows()
  if not state or not state.live_line_indices then return end
  local buf = state.bufs.tree
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  for _, line_number in ipairs(state.live_line_indices) do
    local line = vim.api.nvim_buf_get_lines(buf, line_number - 1, line_number, false)[1]
    if line then
      local updated = M.replace_first_spinner(line, spinner())
      if updated ~= line then
        vim.api.nvim_buf_set_lines(buf, line_number - 1, line_number, false, { updated })
      end
    end
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

local function ensure_timer()
  if not state or state.timer then return end
  local uv = vim.uv or vim.loop
  state.timer = uv.new_timer()
  state.timer:start(120, 120, vim.schedule_wrap(function()
    if not state then return end
    if not vim.api.nvim_win_is_valid(state.wins.tree) then
      M.close()
      return
    end
    if not busy_now() then
      if state.timer then state.timer:stop() end
      state.timer = nil
      state.cancel_requested = false
      update_winbars()
      notify_panel()
      return
    end
    state.spinner_i = state.spinner_i + 1
    update_winbars()
    M.animate_live_rows()
    if not state.frame_in_flight and state.host and not state.host.dead then
      state.frame_in_flight = true
      -- No spinner parameter: identical frames skip re-rendering, which
      -- keeps the event loop free while an operation runs. The winbar
      -- spinner animates locally.
      state.host:request("frame", {}, function(msg)
        if not state then return end
        state.frame_in_flight = false
        if msg.result then M.render(msg.result) end
      end)
    end
  end))
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

--- Session-stream line colors, mirroring the TUI's SESSION_COLORS.
local SESSION_KIND_COLOR = {
  step = "muted",
  text = "text",
  tool = "accent",
  error = "error",
}

local function prepare_buffer(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_name(buf, "neolit://" .. name)
  return buf
end

local function session_lines_pane(session)
  local lines = {}
  for _, line in ipairs(session and session.lines or {}) do
    local role = SESSION_KIND_COLOR[line.kind] or "text"
    lines[#lines + 1] = { text = line.text, color = theme.colors[role] }
  end
  if #lines == 0 then
    lines[1] = { text = "waiting for the agent…", color = theme.colors.muted }
  end
  return lines
end

--------------------------------------------------------------------------
-- Diff-pane source highlighting
--------------------------------------------------------------------------

--- OpenCode-style diff rendering layered over the buffer's NATIVE diff
--- highlighting: the filetype's own syntax (runtime `syntax/diff.vim`, or
--- treesitter with its injections once the diff parser is installed) colors
--- file headers, hunk markers, and added/removed lines with the active
--- colorscheme's diff groups; on top of that, full-width red/green
--- backgrounds (DiffAdd/DiffDelete, hl_eol) plus the source language's
--- syntax inside added AND deleted blocks. Everything resolves through
--- semantic highlight groups, so the pane follows the colorscheme — nothing
--- is hard-coded.
local function language_for_path(path)
  local filetype = vim.filetype.match({ filename = path })
  return filetype and vim.treesitter.language.get_lang(filetype), filetype
end

local function highlight_block(buf, ns, language, start_line, lines, marker)
  if not language then return end
  local text = table.concat(lines, "\n")
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, language)
  if not ok_parser then return end
  local ok_query, query = pcall(vim.treesitter.query.get, language, "highlights")
  if not ok_query or not query then return end
  for _, tree in ipairs(parser:parse()) do
    for id, node in query:iter_captures(tree:root(), text, 0, -1) do
      local start_row, start_col, end_row, end_col = node:range()
      for row = start_row, end_row do
        local from = row == start_row and start_col or 0
        local to = row == end_row and end_col or #(lines[row + 1] or "")
        if to > from then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + row - 1, from + #marker, {
            end_col = to + #marker,
            hl_group = "@" .. query.captures[id],
            priority = 100,
          })
        end
      end
    end
  end
end

function M.highlight_diff_source(buf, ns, changes)
  -- Native diff coloring (filetype=diff) stays on: headers, hunk markers,
  -- and context lines follow the colorscheme through its own diff groups.
  -- The extmarks below only layer the full-width semantic backgrounds and
  -- the source-language syntax on the +/- blocks.
  local language, filetype
  for _, change in ipairs(changes.diffs or {}) do
    if change.path and change.path ~= "" then
      language, filetype = language_for_path(change.path)
      break
    end
  end
  local parser_ready = false
  if language then
    parser_ready = pcall(vim.treesitter.language.add, language)
    if not parser_ready then
      if not M._missing_parsers then M._missing_parsers = {} end
      if not M._missing_parsers[language] then
        M._missing_parsers[language] = true
        vim.notify(string.format("neolit: no treesitter parser for %s — :TSInstall %s to highlight diffs", filetype or language, language), vim.log.levels.WARN)
      end
    end
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local index = 1
  while index <= #lines do
    local line = lines[index]
    local marker = line:sub(1, 1)
    if (marker == "+" or marker == "-") and line:sub(1, 4) ~= "+++ " and line:sub(1, 4) ~= "--- " then
      local sign = marker
      local stop = index
      while stop < #lines do
        local next_marker = lines[stop + 1]:sub(1, 1)
        if next_marker == sign and lines[stop + 1]:sub(1, 4) ~= "+++ " and lines[stop + 1]:sub(1, 4) ~= "--- " then
          stop = stop + 1
        else
          break
        end
      end
      -- Background first (full width, low priority), syntax on top.
      for row = index, stop do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, {
          end_col = #lines[row],
          hl_group = sign == "+" and "DiffAdd" or "DiffDelete",
          hl_eol = true,
          priority = 90,
        })
      end
      local block = {}
      for row = index, stop do block[#block + 1] = lines[row]:sub(2) end
      if parser_ready then
        highlight_block(buf, ns, language, index, block, sign)
      end
      index = stop + 1
    else
      index = index + 1
    end
  end
end

-- Window factories are defined in the window section below; render drives
-- them, so they are forward-declared here.
local create_right_window, create_desc_window, create_session_window
local close_panel_window, panel_geometry

--- Renders the description column (detail content plus any offered route
--- interpretations). No winbar title: the buffer name (neolit://desc)
--- already identifies the pane.
local function render_description(frame)
  if not vim.api.nvim_buf_is_valid(state.bufs.desc) then return end
  local lines = vim.list_extend({}, frame.detail or {})
  for index, option in ipairs(frame.routedOptions or {}) do
    lines[#lines + 1] = {
      segments = {
        { text = string.format("[%d] ", index), color = theme.colors.primary, bold = true },
        { text = option.label .. " — " .. option.description },
      },
    }
  end
  render.render_lines(vim.api, state.ns, state.bufs.desc, theme, lines)
end

local function diff_pane_lines(changes)
  local texts = {}
  for _, change in ipairs(changes.diffs or {}) do
    texts[#texts + 1] = change.text:gsub("\n$", "")
  end
  local joined = table.concat(texts, "\n\n")
  local lines = vim.split(joined, "\n")
  if lines[1] == "" then lines = {} end
  return lines
end

local function diff_pane_winbar(changes)
  -- Data only, no title: the buffer name identifies the pane.
  local parts = {}
  if changes.summary ~= "" then parts[#parts + 1] = changes.summary end
  if changes.merged then parts[#parts + 1] = "merged into file body" end
  if changes.applied > 0 then parts[#parts + 1] = string.format("✓ %d/%d applied", changes.applied, #changes.diffs) end
  if #parts == 0 then return "" end
  return "%#NeolitMuted#" .. table.concat(parts, " · ") .. "%#Normal#"
end

function M.render(frame, force)
  if not state or not frame then return end
  if not vim.api.nvim_win_is_valid(state.wins.tree) then
    M.close()
    return
  end
  -- Stick-to-bottom, measured BEFORE new content lands: while the cursor
  -- rides the last line of the stream it stays there; scrolling up to read
  -- pauses the follow. A fresh batch from an empty stream follows too.
  local follow_tail = state.wins.session ~= -1 and vim.api.nvim_win_is_valid(state.wins.session)
    and state.bufs.session
    and vim.api.nvim_win_get_buf(state.wins.session) == state.bufs.session
    and vim.api.nvim_win_get_cursor(state.wins.session)[1] >= vim.api.nvim_buf_line_count(state.bufs.session) - 1
  state.frame = frame
  state.local_error = nil
  state.cancel_requested = false

  -- The selection must stay reachable: unfold its ancestors.
  if type(frame.tree.selectedRowId) == "string" then
    local path = row_path({ id = frame.tree.selectedRowId })
    if path then
      for _, ancestor in ipairs(ancestor_paths(path)) do
        state.folded[ancestor] = nil
        state.explicit_open[ancestor] = true
      end
    end
  end

  -- Unchanged frames skip all buffer and cursor work: the busy poll fires
  -- every 120ms and re-rendering thousands of extmarks per tick freezes
  -- input. Fold/plan-only changes pass force = true.
  local content_changed = M.frames_differ(state.rendered_frame, frame)
  if content_changed or force then
    state.rendered_frame = frame
    local tree_lines = {}
    local row_ids = {}
    local rows_visible = M.visible_rows(frame.tree.rows or {}, effective_folded(frame.tree.rows or {}), state.plan_only)
    for index, row in ipairs(rows_visible) do
      tree_lines[#tree_lines + 1] = { segments = row.segments }
      row_ids[#row_ids + 1] = row.id
    end
    state.row_ids = row_ids
    state.rows_visible = rows_visible
    state.live_line_indices = record_live_rows(tree_lines)
    render.render_lines(vim.api, state.ns, state.bufs.tree, theme, tree_lines)

    if state.last_selected ~= frame.tree.selectedRowId then
      state.last_selected = frame.tree.selectedRowId
      local selected = 1
      for index, id in ipairs(row_ids) do
        if id == frame.tree.selectedRowId then selected = index break end
      end
      pcall(vim.api.nvim_win_set_cursor, state.wins.tree, { selected, 0 })
    end

    render_description(frame)
  end

  -- The diff column is PERMANENT: it shows the drafted patches (the file's
  -- body when the merged view expands them, or a repository-only file's
  -- preview) or a quiet placeholder when none exist. Windows never appear or
  -- disappear with content — only the session pane (under the description)
  -- does, while an agent is actually streaming.
  local has_diffs = frame.changes and #(frame.changes.diffs or {}) > 0
  local preview = frame.filePreview
  create_right_window()
  create_desc_window()
  if not has_diffs and preview and preview.lines and #preview.lines > 0 then
    -- A repository-only file: the diff column is the content column, with
    -- the file's own syntax where nvim can detect it from the path.
    local signature = "preview:" .. vim.json.encode({ path = preview.path, lines = preview.lines })
    if signature ~= state.diff_signature or force then
      state.diff_signature = signature
      if state.bufs.diff and vim.api.nvim_buf_is_valid(state.bufs.diff) then
        local ok, ft = pcall(vim.filetype.match, { filename = preview.path })
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", true)
        vim.api.nvim_buf_set_option(state.bufs.diff, "filetype", ok and ft or "")
        vim.api.nvim_buf_set_lines(state.bufs.diff, 0, -1, false, preview.lines)
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(state.bufs.diff, state.diff_ns, 0, -1)
        if state.wins.right ~= -1 and vim.api.nvim_win_is_valid(state.wins.right) then
          pcall(vim.api.nvim_win_set_cursor, state.wins.right, { 1, 0 })
        end
      end
    end
  elseif not has_diffs and state.diff_signature ~= "none" then
    state.diff_signature = "none"
    if state.bufs.diff and vim.api.nvim_buf_is_valid(state.bufs.diff) then
      vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", true)
      vim.api.nvim_buf_set_option(state.bufs.diff, "filetype", "")
      vim.api.nvim_buf_set_lines(state.bufs.diff, 0, -1, false, { "no drafted changes yet — [D] develop drafts files; [A] applies" })
      vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", false)
      vim.api.nvim_buf_clear_namespace(state.bufs.diff, state.diff_ns, 0, -1)
    end
  end

  -- The session pane under the description: present whenever a tool session
  -- is configured and not hidden with V — a quiet "waiting for the agent…"
  -- placeholder when nothing has streamed yet, exactly like the TUI's pane.
  local session_wanted = frame.session and frame.session.visible
  if session_wanted then
    create_session_window()
  elseif state.wins.session ~= -1 then
    close_panel_window("session")
  end

  -- The session stream updates far more often than the tree, so it renders
  -- on its own signature.
  if frame.session then
    local signature = vim.json.encode(frame.session.lines)
    if signature ~= state.session_signature or force then
      state.session_signature = signature
      if state.bufs.session and vim.api.nvim_buf_is_valid(state.bufs.session) then
        render.render_lines(vim.api, state.ns, state.bufs.session, theme, session_lines_pane(frame.session))
      end
    end
  end

  -- Only real diffs render here; without drafts the placeholder above owns
  -- the buffer and the signature stays "none".
  if has_diffs and frame.changes then
    local signature = vim.json.encode({ texts = vim.tbl_map(function(change) return change.text end, frame.changes.diffs or {}), summary = frame.changes.summary })
    if signature ~= state.diff_signature or force then
      state.diff_signature = signature
      if state.bufs.diff and vim.api.nvim_buf_is_valid(state.bufs.diff) then
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", true)
        vim.api.nvim_buf_set_option(state.bufs.diff, "filetype", "diff")
        vim.api.nvim_buf_set_lines(state.bufs.diff, 0, -1, false, diff_pane_lines(frame.changes))
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(state.bufs.diff, state.diff_ns, 0, -1)
        M.highlight_diff_source(state.bufs.diff, state.diff_ns, frame.changes)
        -- A new patch reads from the top; the session view's cursor is
        -- never touched here — it belongs to the tail-follow.
        if state.wins.right ~= -1 and vim.api.nvim_win_is_valid(state.wins.right)
          and vim.api.nvim_win_get_buf(state.wins.right) == state.bufs.diff then
          pcall(vim.api.nvim_win_set_cursor, state.wins.right, { 1, 0 })
        end
      end
    end
  end

  -- Auto-behavior and window wiring: the diff column shows the diff buffer
  -- with its summary winbar; the session pane follows its own tail.
  local right = state.wins.right
  if right ~= -1 and vim.api.nvim_win_is_valid(right) then
    local shown = state.bufs.diff
    if shown and vim.api.nvim_buf_is_valid(shown) and frame.changes then
      local preview = frame.filePreview
      if not has_diffs and preview and preview.lines and #preview.lines > 0 then
        local note = preview.truncated and string.format(" · … %d more lines", preview.totalLines - #preview.lines) or ""
        vim.api.nvim_win_set_option(right, "winbar", "%#NeolitMuted#" .. preview.path .. " · preview" .. note .. "%#Normal#")
      else
        vim.api.nvim_win_set_option(right, "winbar", diff_pane_winbar(frame.changes))
      end
    end
    if shown then pcall(vim.api.nvim_win_set_buf, right, shown) end
    vim.api.nvim_win_set_option(right, "wrap", false)
    vim.api.nvim_win_set_option(right, "linebreak", false)
  end

  local session = state.wins.session
  if session ~= -1 and vim.api.nvim_win_is_valid(session) and state.bufs.session
    and vim.api.nvim_buf_is_valid(state.bufs.session) then
    pcall(vim.api.nvim_win_set_buf, session, state.bufs.session)
    if follow_tail or state.jump_tail then
      local count = vim.api.nvim_buf_line_count(state.bufs.session)
      pcall(vim.api.nvim_win_set_cursor, session, { math.max(1, count), 0 })
      state.jump_tail = nil
    end
  end

  update_winbars()
  notify_panel()
  ensure_timer()
end

--------------------------------------------------------------------------
-- Windows: the full-takeover panel columns
--------------------------------------------------------------------------

local function set_up_tree_window(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  local scope = vim.wo[win]
  scope.number = false
  scope.relativenumber = false
  scope.signcolumn = "no"
  scope.foldcolumn = "0"
  scope.wrap = false
  scope.cursorline = true
  scope.winhl = "CursorLine:NeolitCursorLine"
  scope.scrolloff = 999
  scope.winfixwidth = true
  scope.list = false
  scope.winbar = "NEOLIT"
end

local function set_up_desc_window(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  local scope = vim.wo[win]
  scope.number = false
  scope.relativenumber = false
  scope.signcolumn = "no"
  scope.foldcolumn = "0"
  scope.wrap = true
  scope.scrolloff = 0
  scope.winfixwidth = true
  scope.list = false
end

local function set_up_session_window(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  local scope = vim.wo[win]
  scope.number = false
  scope.relativenumber = false
  scope.signcolumn = "no"
  scope.foldcolumn = "0"
  scope.wrap = true
  scope.linebreak = true
  scope.scrolloff = 0
  scope.winfixheight = true
  scope.list = false
end

local function set_up_right_window(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  local scope = vim.wo[win]
  scope.number = false
  scope.relativenumber = false
  scope.signcolumn = "no"
  scope.foldcolumn = "0"
  scope.wrap = false
  scope.scrolloff = 1
  scope.winfixwidth = true
  scope.list = false
end

--- The panel takes the whole editor: the user's windows are captured and
--- closed once the first panel window exists (closing the last window first
--- would exit the editor), and Q reopens their buffers afterwards.
local function capture_saved_windows()
  local current = vim.api.nvim_get_current_win()
  local saved = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      saved[#saved + 1] = {
        win = win,
        buf = vim.api.nvim_win_get_buf(win),
        cursor = vim.api.nvim_win_get_cursor(win),
        focused = win == current,
      }
    end
  end
  return saved
end

local function close_saved_windows(saved)
  for _, entry in ipairs(saved) do
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
end

--- Reopens the buffers the takeover closed, as an even split of the space
--- the panel leaves behind, restoring each cursor and the original focus.
local function restore_saved_windows(saved)
  local focused
  for index, entry in ipairs(saved) do
    if vim.api.nvim_buf_is_valid(entry.buf) then
      pcall(vim.cmd, index == 1 and "vsplit" or "vertical split")
      local win = vim.api.nvim_get_current_win()
      pcall(vim.api.nvim_win_set_buf, win, entry.buf)
      pcall(vim.api.nvim_win_set_cursor, win, entry.cursor or { 1, 0 })
      if entry.focused then focused = win end
    end
  end
  if focused then pcall(vim.api.nvim_set_current_win, focused) end
end

panel_geometry = function()
  return config.geometry(vim.o.columns, {
    sidebar_width = state.cfg.sidebar_width,
    detail_width = state.cfg.detail_width,
  })
end

--- The diff column: a full-height window beside the tree, present while
--- drafted patches exist.
create_right_window = function()
  if not state or vim.api.nvim_win_is_valid(state.wins.right) then return end
  local tree = state.wins.tree
  if not vim.api.nvim_win_is_valid(tree) then return end
  local width = panel_geometry().detail
  if width < 12 then
    vim.notify("Not enough room for the diff column.", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_win_call(tree, function()
    vim.cmd("rightbelow vertical " .. width .. "split")
    -- nvim_win_call restores the previous current window afterwards, so the
    -- new split must be captured here, inside the call.
    state.wins.right = vim.api.nvim_get_current_win()
  end)
  set_up_right_window(state.wins.right, state.bufs.diff)
  vim.api.nvim_set_current_win(state.wins.tree)
end

--- The description column: the rightmost full-height window, always
--- present. Its width is set once at creation — never churned by frames.
create_desc_window = function()
  if not state or vim.api.nvim_win_is_valid(state.wins.desc) then return end
  local anchor = state.wins.right
  if anchor == -1 or not vim.api.nvim_win_is_valid(anchor) then anchor = state.wins.tree end
  if not vim.api.nvim_win_is_valid(anchor) then return end
  vim.api.nvim_win_call(anchor, function()
    vim.cmd("rightbelow vertical split")
    state.wins.desc = vim.api.nvim_get_current_win()
  end)
  set_up_desc_window(state.wins.desc, state.bufs.desc)
  if vim.api.nvim_win_is_valid(state.wins.tree) then
    local rest = math.max(24, vim.o.columns - vim.api.nvim_win_get_width(state.wins.tree) - 2)
    pcall(vim.api.nvim_win_set_width, state.wins.desc, math.max(24, rest - panel_geometry().detail))
  end
  vim.api.nvim_set_current_win(state.wins.tree)
end

--- The bounded session pane under the description column.
create_session_window = function()
  if not state or vim.api.nvim_win_is_valid(state.wins.session) then return end
  local desc = state.wins.desc
  if not (desc ~= -1) or not vim.api.nvim_win_is_valid(desc) then return end
  local desc_height = vim.api.nvim_win_get_height(desc)
  local height = math.min(12, math.max(3, math.floor(desc_height * 0.35)))
  vim.api.nvim_win_call(desc, function()
    vim.cmd("rightbelow " .. height .. "split")
    state.wins.session = vim.api.nvim_get_current_win()
  end)
  set_up_session_window(state.wins.session, state.bufs.session)
  -- A fresh pane starts at the tail; afterwards the cursor decides.
  state.jump_tail = true
  vim.api.nvim_set_current_win(state.wins.tree)
end

close_panel_window = function(which)
  local win = state and state.wins[which]
  if win and win ~= -1 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if state then state.wins[which] = -1 end
end

local function create_windows()
  state.bufs = {
    tree = prepare_buffer("tree"),
    desc = prepare_buffer("desc"),
    diff = prepare_buffer("diff"),
    session = prepare_buffer("session"),
  }
  state.diff_ns = vim.api.nvim_create_namespace("neolit-diff-hl")

  local geometry = panel_geometry()
  -- Full takeover: remember the user's windows, then close them once the
  -- tree exists — the panel columns fill the editor, and Q restores them.
  state.saved_windows = capture_saved_windows()
  vim.cmd("topleft vertical " .. geometry.sidebar .. "split")
  state.wins = { tree = vim.api.nvim_get_current_win(), desc = -1, right = -1, session = -1 }
  set_up_tree_window(state.wins.tree, state.bufs.tree)
  close_saved_windows(state.saved_windows)

  -- Tree | diff column | description column; the session pane splits under
  -- the description while a session runs.
  create_right_window()
  create_desc_window()

  render.render_lines(vim.api, state.ns, state.bufs.tree, theme,
    { { text = "Starting the neolit host…", color = theme.colors.muted } })

  for _, buf in pairs(state.bufs) do keys.attach(M, buf) end

  -- Closing the sidebar ends the panel; closing the diff column just hides
  -- it (Tab recreates it).
  state.autocmds = {}
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.wins.tree),
    callback = function() M.close() end,
  })
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.wins.right),
    callback = function()
      if state then state.wins.right = -1 end
    end,
  })
end

--------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------

local function npm_root()
  local result = vim.fn.system({ "npm", "root", "-g" })
  if vim.v.shell_error == 0 and type(result) == "string" then
    return vim.trim(result)
  end
  return nil
end

function M.open(opts)
  if state then
    if vim.api.nvim_win_is_valid(state.wins.tree) then vim.api.nvim_set_current_win(state.wins.tree) end
    return
  end
  local cfg = config.merge(opts)
  theme.apply(vim.api, { palette = cfg.palette })

  local plugin_root = config.plugin_root()
  local dist_root, tried = config.find_neolit_dir(cfg, {
    env = vim.env,
    plugin_root = plugin_root,
    readable = function(path) return vim.fn.filereadable(path) == 1 end,
    npm_root = npm_root(),
  })
  if not dist_root then
    vim.notify(
      "neolit: could not find the neolit package (dist/index.js). Tried: " .. table.concat(tried or {}, ", ")
      .. ". Set `neolit_dir` to a neolit checkout with dist/ built (npm run build).",
      vim.log.levels.ERROR
    )
    return
  end

  state = {
    cfg = cfg,
    pane = "tree",
    spinner_i = 1,
    row_ids = {},
    last_notice = nil,
    folded = {},
    explicit_open = {},
    plan_only = false,
    model_catalog = nil,
    session_signature = nil,
    diff_signature = nil,
    ns = vim.api.nvim_create_namespace("neolit"),
  }

  local geometry_ok = pcall(create_windows)
  if not geometry_ok then
    state = nil
    vim.notify("neolit: could not create the panel windows.", vim.log.levels.ERROR)
    return
  end

  local directory = cfg.directory or vim.fn.getcwd()
  state.directory = directory
  local env = {}
  if cfg.no_model then env.AUGMENT_TUI_NO_MODEL = "1" end
  if cfg.no_socket then env.AUGMENT_TUI_NO_SOCKET = "1" end
  if cfg.persist_tasks == false then env.AUGMENT_TUI_TASKS = "0" end

  -- env is only passed when set: an empty env table is rejected by some
  -- jobstart implementations (E475) and would otherwise break every open.
  local spawn_opts = {
    cmd = { cfg.node, plugin_root .. "/host/host.mjs", "--dist", dist_root .. "/dist", unpack_table(cfg.host_args or {}) },
    cwd = directory,
  }
  if next(env) ~= nil then spawn_opts.env = env end

  local spawn_ok, spawned = pcall(hostmod.new, spawn_opts, {
    on_frame = function(frame, host)
      -- Route by owner: a previous session's shutting-down host still pushes
      -- frames, and they must never paint (or close) a newer panel.
      if state and state.host == host then M.render(frame) end
    end,
    on_progress = function(progress, host)
      if state and state.host == host and progress and progress.operation then ensure_timer() end
    end,
    on_stderr = function(text, host)
      if state and state.host == host and text and text:find("%S") then vim.schedule(function() vim.notify("neolit host: " .. vim.trim(text), vim.log.levels.WARN) end) end
    end,
    on_exit = function(code, host)
      -- Only a crash of THIS state's host tears the UI down; an exit from a
      -- previous session's shutting-down host must never close a fresh panel.
      if state and state.host == host and not state.closing then
        M.close()
        vim.notify("neolit host exited unexpectedly (code " .. code .. ").", vim.log.levels.WARN)
      end
    end,
  })
  if not spawn_ok then
    M.close()
    vim.notify("neolit: could not start the host shim: " .. tostring(spawned), vim.log.levels.ERROR)
    return
  end
  state.host = spawned

  state.host:request("initialize", { directory = directory }, function(msg)
    -- A previous panel's late responses must never initialize this one.
    if not state or state.host ~= spawned then return end
    if msg.error then
      vim.notify("neolit: host failed to initialize: " .. (msg.error.message or "unknown error"), vim.log.levels.ERROR)
      M.close()
      return
    end
    state.model = msg.result.model
    M.render(msg.result.frame)
    if vim.api.nvim_win_is_valid(state.wins.tree) then vim.api.nvim_set_current_win(state.wins.tree) end
    if cfg.objective then M.dispatch("start", { objective = cfg.objective }, OP_LABELS.start) end
    if cfg.on_ready then
      local callback = cfg.on_ready
      cfg.on_ready = nil
      vim.schedule(callback)
    end
  end)
end

function M.close()
  if not state then return end
  local current = state
  state = nil
  current.closing = true
  if current.timer then current.timer:stop() end
  for _, id in ipairs(current.autocmds or {}) do pcall(vim.api.nvim_del_autocmd, id) end
  -- Restore the takeover's captured buffers BEFORE the last panel window
  -- closes: closing the final window of the tab would exit the editor.
  if current.saved_windows and #current.saved_windows > 0 then
    local ok = pcall(restore_saved_windows, current.saved_windows)
    if not ok then
      pcall(vim.cmd, "vsplit")
    end
  end
  for _, win in pairs(current.wins) do
    if win ~= -1 then pcall(vim.api.nvim_win_close, win, true) end
  end
  for _, buf in pairs(current.bufs) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  if current.host then current.host:shutdown() end
end

--------------------------------------------------------------------------
-- Operations (the TUI key set)
--------------------------------------------------------------------------

function M.dispatch(method, params, label)
  if not state or not state.host then return end
  if label then
    state.pending = { label = label }
    state.cancel_requested = false
  end
  ensure_timer()
  update_winbars()
  state.host:request(method, params or {}, function(msg)
    if not state then return end
    state.pending = nil
    if msg.error then
      state.local_error = msg.error.message or "host error"
      update_winbars()
      notify_panel()
    else
      M.render(msg.result and msg.result.frame or msg.result)
    end
  end)
end

function M.pane()
  if not state then return "tree" end
  -- The real focus decides, so <C-w>/mouse entry into a detail-side window
  -- routes j/k there too; the remembered pane only covers keypresses from
  -- outside the panel entirely.
  local current = vim.api.nvim_get_current_win()
  if current == state.wins.right or current == state.wins.desc or current == state.wins.session then return "detail" end
  if current == state.wins.tree then return "tree" end
  return state.pane
end

function M.set_pane(pane)
  if not state then return end
  state.pane = pane or (state.pane == "tree" and "detail" or "tree")
  if state.pane == "detail" then
    -- Recreate whichever detail-side windows the user closed with :q.
    create_right_window()
    create_desc_window()
  end
  local target = state.pane == "detail" and (state.wins.desc ~= -1 and state.wins.desc or state.wins.right) or state.wins.tree
  if target and target ~= -1 and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
  end
end

function M.move(delta)
  if not state or not state.host then return end
  local win = state.wins.tree
  if not vim.api.nvim_win_is_valid(win) or #state.row_ids == 0 then return end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local next_line = math.max(1, math.min(#state.row_ids, cursor[1] + delta))
  pcall(vim.api.nvim_win_set_cursor, win, { next_line, 0 })
  local row_id = state.row_ids[next_line]
  local current = state.frame and state.frame.tree and state.frame.tree.selectedRowId
  if row_id and row_id ~= current then
    state.host:request("select", { rowId = row_id }, function(msg)
      if state and msg.result then M.render(msg.result) end
    end)
  end
end

function M.scroll_detail(delta)
  if not state then return end
  -- Scroll whichever detail-side window holds focus; the description column
  -- is the fallback when the tree (or nothing) is focused.
  local candidates = { vim.api.nvim_get_current_win(), state.wins.right, state.wins.desc, state.wins.session }
  local win
  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= -1 and vim.api.nvim_win_is_valid(candidate)
      and candidate ~= state.wins.tree then
      win = candidate
      break
    end
  end
  if not win then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local count = vim.api.nvim_buf_line_count(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local next_line = math.max(1, math.min(count, cursor[1] + delta))
  pcall(vim.api.nvim_win_set_cursor, win, { next_line, 0 })
end

--------------------------------------------------------------------------
-- Folding, hiding, and opening selected paths as real buffers
--------------------------------------------------------------------------

local function cursor_row()
  if not state then return nil end
  local win = state.wins.tree
  if not vim.api.nvim_win_is_valid(win) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(win)
  return (state.rows_visible or {})[cursor[1]]
end

--- mode: "toggle" | "open" | "close" on the directory row under the cursor.
function M.toggle_fold(mode)
  if not state or not state.frame then return end
  local row = cursor_row()
  if not row or not row.directory then return end
  local path = row.id:sub(7)
  local folded = effective_folded(state.frame.tree.rows or {})
  if mode == "open" then
    state.explicit_open[path] = true
    state.folded[path] = nil
  elseif mode == "close" then
    state.explicit_open[path] = nil
    state.folded[path] = true
  elseif folded[path] then
    state.explicit_open[path] = true
    state.folded[path] = nil
  else
    state.explicit_open[path] = nil
    state.folded[path] = true
  end
  M.render(state.frame, true)
  local win = state.wins.tree
  if vim.api.nvim_win_is_valid(win) then
    for index, id in ipairs(state.row_ids) do
      if id == row.id then
        pcall(vim.api.nvim_win_set_cursor, win, { index, 0 })
        break
      end
    end
  end
end

--- zm/zr/zM/zR: fold by level rather than by directory.
function M.fold_level(mode)
  if not state or not state.frame then return end
  local rows = state.frame.tree.rows or {}
  if mode == "all-open" then
    for _, row in ipairs(rows) do
      local path = row_path(row)
      if path and row.directory then
        state.explicit_open[path] = true
        state.folded[path] = nil
      end
    end
  elseif mode == "all-closed" then
    for _, row in ipairs(rows) do
      local path = row_path(row)
      if path and row.directory then
        state.folded[path] = true
        state.explicit_open[path] = nil
      end
    end
  else
    local targets = M.fold_level_targets(rows, effective_folded(rows), mode)
    for path in pairs(targets.fold) do
      state.folded[path] = true
      state.explicit_open[path] = nil
    end
    for path in pairs(targets.open) do
      state.folded[path] = nil
      state.explicit_open[path] = true
    end
  end
  M.render(state.frame, true)
end

--- Hides repository-only paths: only planned paths and their ancestors stay.
function M.toggle_plan_only()
  if not state or not state.frame then return end
  state.plan_only = not state.plan_only
  M.render(state.frame, true)
end

--- First non-panel window in the tab, creating one beside the sidebar if
--- the panel is alone (the takeover closed the user's windows; `o` brings
--- one back on demand).
local function panel_target_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.wins.tree and win ~= state.wins.right and win ~= state.wins.desc
      and win ~= state.wins.session and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  local tree = state.wins.tree
  vim.api.nvim_win_call(tree, function()
    vim.cmd("rightbelow vertical split")
  end)
  return vim.api.nvim_get_current_win()
end

--- o: open the selected file as a real buffer. Directories fold (but not
--- the root — use za/zm for that); drafted new files fall through to their
--- patch buffer.
function M.open_selected()
  if not state then return end
  local row = cursor_row()
  if not row then return end
  if row.id == "entry:." then return end
  if row.directory then return M.toggle_fold("toggle") end
  local path = row.id:sub(7)
  local absolute = state.directory .. "/" .. path
  if vim.fn.filereadable(absolute) == 1 then
    local target = panel_target_window()
    local buf = vim.fn.bufadd(absolute)
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(target, buf)
    vim.api.nvim_set_current_win(target)
    return
  end
  if state.frame and state.frame.patch then return M.edit_patch() end
  vim.notify(path .. " is not in the working tree yet; press D to draft it first.", vim.log.levels.INFO)
end

--- p: edit the selected path's drafted patch as a diff buffer. Writing the
--- buffer sends patch/set back into the plan.
function M.edit_patch()
  if not state or not state.host then return end
  local patch = state.frame and state.frame.patch
  if not patch then
    vim.notify("No drafted patch on the selected path. Press D to develop it first.", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "neolit://patch/" .. (patch.path ~= "" and patch.path or patch.diffId))
  local lines = vim.split(patch.text:gsub("\n$", ""), "\n")
  if lines[1] == "" then lines = {} end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "filetype", "diff")
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if not state or not state.host then return end
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      state.host:request("patch_set", { diffId = patch.diffId, patch = text }, function(msg)
        if not state then return end
        if msg.error then
          vim.api.nvim_buf_set_option(buf, "modified", true)
          vim.notify("patch/set failed: " .. msg.error.message, vim.log.levels.ERROR)
          return
        end
        vim.api.nvim_buf_set_option(buf, "modified", false)
        vim.notify("Patch saved into the plan.", vim.log.levels.INFO)
        M.render(msg.result and msg.result.frame or msg.result)
      end)
    end,
  })
  local target = panel_target_window()
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
end

local function prompt_input(title, callback)
  local hook = state and state.cfg.hooks and state.cfg.hooks.input
  if hook then return hook({ prompt = title }, callback) end
  vim.ui.input({ prompt = title .. " › " }, callback)
end

local function prompt_select(items, options, callback)
  local hook = state and state.cfg.hooks and state.cfg.hooks.select
  if hook then return hook(items, options, callback) end
  vim.ui.select(items, options, callback)
end

function M.prompt_objective()
  if not state then return end
  prompt_input(INPUT_TITLES.objective, function(value)
    if value == nil then return end
    M.dispatch("start", { objective = value }, OP_LABELS.start)
  end)
end

function M.prompt_message()
  if not state then return end
  if not (state.frame and state.frame.hasTask) then
    vim.notify("No task is active. Press [N] to send the first message.", vim.log.levels.WARN)
    return
  end
  prompt_input(message_title(), function(value)
    if value == nil then return end
    M.dispatch("message", { text = value }, OP_LABELS.message)
  end)
end

function M.prompt_reopen()
  if not state then return end
  prompt_input(INPUT_TITLES.reopen, function(value)
    if value == nil then return end
    M.dispatch("reopen", { reason = value }, OP_LABELS.reopen)
  end)
end

function M.prompt_stale()
  if not state then return end
  prompt_input(INPUT_TITLES.stale, function(value)
    if value == nil then return end
    M.dispatch("stale", { path = value }, OP_LABELS.stale)
  end)
end

function M.choose(n)
  if not state or not state.frame then return end
  -- Routed interpretations outrank approach candidates while open, exactly
  -- like the TUI's number keys.
  if (state.frame.routedOptions or {})[n] or (state.frame.choices or {})[n] then
    M.dispatch("choose", { n = n }, OP_LABELS.choose)
  end
end

function M.develop() M.dispatch("develop", {}, OP_LABELS.develop) end
function M.apply_selected() M.dispatch("apply", {}, OP_LABELS.apply) end
function M.commit_applied() M.dispatch("commit", {}, OP_LABELS.commit) end
function M.restrict(mode) M.dispatch(mode, {}, OP_LABELS[mode]) end
--- ?: a floating cheat-sheet of the panel keys, straight from the keymap
--- descriptions so it can never drift. Any of ?, q, or <Esc> closes it.
function M.show_keys()
  if not state then return end
  if state.wins.keys and vim.api.nvim_win_is_valid(state.wins.keys) then
    pcall(vim.api.nvim_win_close, state.wins.keys, true)
    return
  end
  local entries = {}
  for lhs, desc in pairs(require("neolit.keys").descriptions) do
    entries[#entries + 1] = { lhs = lhs, desc = desc:gsub("^neolit: ", "") }
  end
  table.sort(entries, function(left, right) return left.lhs < right.lhs end)
  local lines = {}
  local width = 0
  for _, entry in ipairs(entries) do
    local line = string.format("%-8s %s", entry.lhs, entry.desc)
    lines[#lines + 1] = { segments = {
      { text = string.format("%-8s", entry.lhs), color = theme.colors.primary, bold = true },
      { text = entry.desc, color = theme.colors.text },
    } }
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(buf, "neolit://keys")
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - (width + 4)) / 2)
  state.bufs.keys = buf
  state.wins.keys = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, row),
    col = math.max(0, col),
    width = math.min(width + 2, vim.o.columns - 4),
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 60,
  })
  render.render_lines(vim.api, state.ns, buf, theme, lines)
  for _, key in ipairs({ "?", "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      pcall(vim.api.nvim_win_close, state.wins.keys, true)
      state.wins.keys = nil
      if vim.api.nvim_win_is_valid(state.wins.tree) then vim.api.nvim_set_current_win(state.wins.tree) end
    end, { buffer = buf, nowait = true, silent = true })
  end
end

function M.session_toggle() M.dispatch("session_toggle", {}, "Toggling session stream") end

function M.switch_model()
  if not state or not state.host then return end
  state.host:request("agent", {}, function(agent_message)
    if not state then return end
    if agent_message.error or not agent_message.result then
      vim.notify((agent_message.error and agent_message.error.message) or "No model runtime is active.", vim.log.levels.WARN)
      return
    end

    local function pick_model(role)
      local catalog = state.model_catalog
      if not catalog or #catalog.models == 0 then
        prompt_input((catalog and catalog.source and catalog.source .. " — " or "") .. role.label .. " model id", function(model)
          if model and model ~= "" and state then M.dispatch("configure", { [role.id] = model }, OP_LABELS.configure) end
        end)
        return
      end

      -- Group the catalog by provider so the picker is two short steps
      -- instead of one flat wall of prefixed ids.
      local by_provider = {}
      for _, model in ipairs(catalog.models) do
        local provider = model:match("^([^/]+)/") or "(no provider)"
        by_provider[provider] = by_provider[provider] or {}
        by_provider[provider][#by_provider[provider] + 1] = model
      end
      local current_provider = role.current and role.current:match("^([^/]+)/")
      if role.current and current_provider and not vim.tbl_contains(by_provider[current_provider] or {}, role.current) then
        local list = by_provider[current_provider] or {}
        list[#list + 1] = role.current
        by_provider[current_provider] = list
      end
      local providers = {}
      for provider in pairs(by_provider) do providers[#providers + 1] = provider end
      table.sort(providers, function(left, right)
        if left == current_provider then return true end
        if right == current_provider then return false end
        return left < right
      end)

      prompt_select(providers, {
        prompt = role.label .. " model · provider",
        format_item = function(provider)
          local mark = provider == current_provider and " ●" or ""
          return string.format("%s (%d)%s", provider, #by_provider[provider], mark)
        end,
      }, function(provider)
        if not provider or not state then return end
        local models = by_provider[provider]
        table.sort(models)
        prompt_select(models, {
          prompt = role.label .. " model",
          format_item = function(model)
            return model .. (model == role.current and "  ● current" or "")
          end,
        }, function(model)
          if model and state then M.dispatch("configure", { [role.id] = model }, OP_LABELS.configure) end
        end)
      end)
    end

    local function pick_role()
      if not state then return end
      local current = (state.frame and state.frame.models) or {}
      local roles = {
        { id = "model", label = "default", current = current.model },
        { id = "draftModel", label = "draft", current = current.draftModel },
        { id = "challengeModel", label = "challenge", current = current.challengeModel },
      }
      prompt_select(roles, {
        prompt = "Switch which model?",
        format_item = function(role)
          return string.format("%-10s %s", role.label, role.current or "(backend default)")
        end,
      }, function(role)
        if not role or not state then return end
        pick_model(role)
      end)
    end

    if state.model_catalog and os.time() - state.model_catalog.at < 300 then
      return pick_role()
    end
    vim.notify("Loading model catalog…", vim.log.levels.INFO)
    state.host:request("models", {}, function(models_message)
      if not state then return end
      local models, source = {}, nil
      if models_message.result then
        models = models_message.result.models or {}
        source = models_message.result.source
      elseif models_message.error then
        source = models_message.error.message
      end
      state.model_catalog = { models = models, source = source, at = os.time() }
      pick_role()
    end)
  end)
end

function M.cancel_op()
  if not state or not state.host then return end
  if busy_now() then
    state.cancel_requested = true
    state.host:request("cancel", {}, function() end)
    update_winbars()
  end
end

function M.quit()
  if not state then return end
  if busy_now() and state.host then pcall(function() state.host:request("cancel", {}, function() end) end) end
  M.close()
end

--- Test accessor for the live UI state (frame, windows, pending operation).
function M._state()
  return state
end

M.labels = OP_LABELS
M.input_titles = INPUT_TITLES

return M
