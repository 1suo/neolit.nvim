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
  rethink = "Rethinking selected path",
  reopen = "Reworking selected plan",
  stale = "Marking repository change",
  configure = "Updating models",
}

local INPUT_TITLES = {
  objective = "What should change?",
  explanation = "Explain what repository topic?",
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
    return vim.json.encode({ rows = frame.tree and frame.tree.rows, detail = frame.detail })
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
  return (selected_path() or "repo") .. " · message (empty = rethink)"
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
    if state.plan_only then
      segments[#segments + 1] = { text = "[RELATED]", group = "NeolitMuted" }
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
  return lines
end

--------------------------------------------------------------------------
-- Diff-pane source highlighting
--------------------------------------------------------------------------

--- Treesitter highlighting for added diff lines, done directly: each
--- consecutive added block is parsed with get_string_parser in the target
--- file's language, and its highlight captures become extmarks one column
--- in (past the leading +). No injection-engine involvement — upstream's
--- diff injections.scm is a comment-only stub, so this works everywhere a
--- parser for the source language exists.
local function language_for_path(path)
  local filetype = vim.filetype.match({ filename = path })
  return filetype and vim.treesitter.language.get_lang(filetype)
end

local function highlight_added_lines(buf, ns, changes)
  local language
  for _, change in ipairs(changes.diffs or {}) do
    if change.path and change.path ~= "" then
      language = language_for_path(change.path)
      break
    end
  end
  if not language then return end
  if not pcall(vim.treesitter.language.add, language) then return end
  local ok_query, query = pcall(vim.treesitter.query.get, language, "highlights")
  if not ok_query or not query then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local index = 1
  while index <= #lines do
    local line = lines[index]
    if line:sub(1, 1) == "+" and line:sub(1, 4) ~= "+++ " then
      local stop = index
      while stop < #lines and lines[stop + 1]:sub(1, 1) == "+" and lines[stop + 1]:sub(1, 4) ~= "+++ " do
        stop = stop + 1
      end
      local block = {}
      for row = index, stop do block[#block + 1] = lines[row]:sub(2) end
      local text = table.concat(block, "\n")
      local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, language)
      if ok_parser then
        for _, tree in ipairs(parser:parse()) do
          for id, node in query:iter_captures(tree:root(), text, 0, -1) do
            local start_row, start_col, end_row, end_col = node:range()
            for row = start_row, end_row do
              local from = row == start_row and start_col or 0
              local to = row == end_row and end_col or #(block[row + 1] or "")
              if to > from then
                pcall(vim.api.nvim_buf_set_extmark, buf, ns, index - 1 + row, from + 1, {
                  end_col = to + 1,
                  hl_group = "@" .. query.captures[id],
                })
              end
            end
          end
        end
      end
      index = stop + 1
    else
      index = index + 1
    end
  end
end

--- Display rows a set of description lines occupies at a given window
--- width: wrapped lines count once per visual row they occupy.
function M.description_rows(lines, width)
  width = math.max(8, width)
  local rows = 0
  for _, line in ipairs(lines or {}) do
    local text = type(line) == "table" and line.text or tostring(line or "")
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(text) / width))
  end
  return rows
end

--- Description dock height: content-driven (in display rows), up to half
--- the editor.
function M.description_height(display_rows)
  return math.max(3, math.min(display_rows + 1, math.floor(vim.o.lines / 2)))
end

--- Renders the description dock under the tree. No winbar title: the
--- buffer name (neolit://desc) already identifies the pane.
local function render_description(frame)
  if not vim.api.nvim_buf_is_valid(state.bufs.desc) then return end
  render.render_lines(vim.api, state.ns, state.bufs.desc, theme, frame.detail or {})
  if state.wins.desc ~= -1 and vim.api.nvim_win_is_valid(state.wins.desc) then
    local width = vim.api.nvim_win_get_width(state.wins.desc)
    pcall(vim.api.nvim_win_set_height, state.wins.desc, M.description_height(M.description_rows(frame.detail, width)))
  end
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
  local follow_tail = state.wins.right ~= -1 and vim.api.nvim_win_is_valid(state.wins.right)
    and state.right_view == "session"
    and state.bufs.session and vim.api.nvim_win_get_buf(state.wins.right) == state.bufs.session
    and vim.api.nvim_win_get_cursor(state.wins.right)[1] >= vim.api.nvim_buf_line_count(state.bufs.session) - 1
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

  -- The right panel: one window, two views (changes / session), switched by
  -- `t`. The session stream updates far more often than the tree, so each
  -- view renders on its own signature.
  if frame.session then
    local signature = vim.json.encode(frame.session.lines)
    if signature ~= state.session_signature or force then
      state.session_signature = signature
      if state.bufs.session and vim.api.nvim_buf_is_valid(state.bufs.session) then
        render.render_lines(vim.api, state.ns, state.bufs.session, theme, session_lines_pane(frame.session))
      end
    end
  end

  if frame.changes then
    local signature = vim.json.encode({ texts = vim.tbl_map(function(change) return change.text end, frame.changes.diffs or {}), summary = frame.changes.summary })
    if signature ~= state.diff_signature or force then
      state.diff_signature = signature
      if state.bufs.diff and vim.api.nvim_buf_is_valid(state.bufs.diff) then
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", true)
        vim.api.nvim_buf_set_option(state.bufs.diff, "filetype", "diff")
        vim.api.nvim_buf_set_option(state.bufs.diff, "syntax", "ON")
        vim.api.nvim_buf_set_lines(state.bufs.diff, 0, -1, false, diff_pane_lines(frame.changes))
        vim.api.nvim_buf_set_option(state.bufs.diff, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(state.bufs.diff, state.diff_ns, 0, -1)
        highlight_added_lines(state.bufs.diff, state.diff_ns, frame.changes)
        -- A new patch reads from the top; the session view's cursor is
        -- never touched here — it belongs to the tail-follow.
        if state.wins.right ~= -1 and vim.api.nvim_win_is_valid(state.wins.right)
          and vim.api.nvim_win_get_buf(state.wins.right) == state.bufs.diff then
          pcall(vim.api.nvim_win_set_cursor, state.wins.right, { 1, 0 })
        end
      end
    end
  end

  -- Auto-behavior: the pane follows whichever side has content — session
  -- lines mean an agent is actually streaming (a configured driver alone
  -- does not), drafts mean changes exist — until the user pins a view.
  local has_diffs = frame.changes and #(frame.changes.diffs or {}) > 0
  local has_session_lines = frame.session and #(frame.session.lines or {}) > 0
  if not has_diffs and has_session_lines and state.right_view ~= "session" and not state.right_view_pinned then
    state.right_view = "session"
    state.jump_tail = true
  elseif has_diffs and state.right_view == "session" and not state.right_view_pinned then
    state.right_view = "changes"
  end

  local right = state.wins.right
  if right ~= -1 and vim.api.nvim_win_is_valid(right) then
    local shown
    if state.right_view == "session" then
      shown = (state.bufs.session and vim.api.nvim_buf_is_valid(state.bufs.session)) and state.bufs.session or nil
      if shown then
        vim.api.nvim_win_set_option(right, "winbar", "")
      end
    end
    if not shown then
      shown = state.bufs.diff
      if shown and vim.api.nvim_buf_is_valid(shown) and frame.changes then
        vim.api.nvim_win_set_option(right, "winbar", diff_pane_winbar(frame.changes))
      end
    end
    if shown then pcall(vim.api.nvim_win_set_buf, right, shown) end

    -- Window options are applied after the buffer switch: switching buffers
    -- runs FileType machinery whose ordering must not come between the two.
    if state.right_view == "session" and shown == state.bufs.session then
      vim.api.nvim_win_set_option(right, "wrap", true)
      vim.api.nvim_win_set_option(right, "linebreak", true)
      if follow_tail or state.jump_tail then
        local count = vim.api.nvim_buf_line_count(state.bufs.session)
        pcall(vim.api.nvim_win_set_cursor, right, { math.max(1, count), 0 })
        state.jump_tail = nil
      end
    else
      vim.api.nvim_win_set_option(right, "wrap", false)
      vim.api.nvim_win_set_option(right, "linebreak", false)
    end
  end

  update_winbars()
  notify_panel()
  ensure_timer()
end

--------------------------------------------------------------------------
-- Windows: two honest splits
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
  scope.winfixheight = true
  scope.winfixwidth = true
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

local function editor_window_count()
  local wins = state and state.wins or {}
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == ""
      and win ~= wins.tree and win ~= wins.right then
      count = count + 1
    end
  end
  return count
end

local function right_pane_width()
  return config.geometry(vim.o.columns, {
    sidebar_width = state.cfg.sidebar_width,
    detail_width = state.cfg.detail_width,
    editor_windows = editor_window_count(),
  }).detail
end

local function create_right_window()
  if not state or vim.api.nvim_win_is_valid(state.wins.right) then return end
  local tree = state.wins.tree
  if not vim.api.nvim_win_is_valid(tree) then return end
  local width = right_pane_width()
  if width < 12 then
    vim.notify("Not enough room for the right pane; close a window and press Tab.", vim.log.levels.INFO)
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

--- Native splits steal columns from one neighbor, not evenly, so after the
--- panel windows exist the user windows are resized to a fair share of what
--- remains — the 12-column-per-window budget from geometry() is what makes
--- that share livable.
local function balance_editor_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == ""
      and win ~= state.wins.tree and win ~= state.wins.right then
      windows[#windows + 1] = win
    end
  end
  if #windows == 0 then return end
  -- Distribute the space the user windows actually occupy (separators
  -- already excluded by each window's own width).
  local remaining = 0
  for _, win in ipairs(windows) do remaining = remaining + vim.api.nvim_win_get_width(win) end
  local fair = math.floor(remaining / #windows)
  local extra = remaining - fair * #windows
  for index = #windows, 1, -1 do
    local width = fair + (index <= extra and 1 or 0)
    if width >= 1 then pcall(vim.api.nvim_win_set_width, windows[index], width) end
  end
end

local function create_windows()
  state.bufs = {
    tree = prepare_buffer("tree"),
    desc = prepare_buffer("desc"),
    diff = prepare_buffer("diff"),
    session = prepare_buffer("session"),
  }
  state.diff_ns = vim.api.nvim_create_namespace("neolit-diff-hl")

  local geometry = config.geometry(vim.o.columns, {
    sidebar_width = state.cfg.sidebar_width,
    detail_width = state.cfg.detail_width,
    editor_windows = editor_window_count(),
  })
  vim.cmd("topleft vertical " .. geometry.sidebar .. "split")
  state.wins = { tree = vim.api.nvim_get_current_win(), desc = -1, right = -1 }
  set_up_tree_window(state.wins.tree, state.bufs.tree)

  -- Right pane first (from the full-height tree), then the description dock
  -- under the tree — a split from the tree only spans the tree's extent.
  create_right_window()

  if vim.o.lines >= 20 then
    vim.api.nvim_win_call(state.wins.tree, function()
      vim.cmd("rightbelow " .. M.description_height(1) .. "split")
      state.wins.desc = vim.api.nvim_get_current_win()
    end)
    set_up_desc_window(state.wins.desc, state.bufs.desc)
    vim.api.nvim_set_current_win(state.wins.tree)
  end

  render.render_lines(vim.api, state.ns, state.bufs.tree, theme,
    { { text = "Starting the neolit host…", color = theme.colors.muted } })

  for _, buf in pairs(state.bufs) do keys.attach(M, buf) end

  balance_editor_windows()

  -- Closing the sidebar ends the panel; closing the right pane just hides it.
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
    session_visible = nil,
    diff_signature = nil,
    right_view = "changes",
    right_view_pinned = false,
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
  -- The real focus decides, so <C-w>/mouse entry into the detail window
  -- routes j/k there too; the remembered pane only covers keypresses from
  -- outside the panel entirely.
  local current = vim.api.nvim_get_current_win()
  if current == state.wins.right then return "detail" end
  if current == state.wins.tree then return "tree" end
  return state.pane
end

function M.set_pane(pane)
  if not state then return end
  state.pane = pane or (state.pane == "tree" and "detail" or "tree")
  if state.pane == "detail" then create_detail_window() end
  local target = state.wins[state.pane]
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
  local win = state.wins.right
  if win == -1 or not vim.api.nvim_win_is_valid(win) then return end
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
--- the panel is alone.
local function panel_target_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.wins.tree and win ~= state.wins.right and vim.api.nvim_win_get_config(win).relative == "" then
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

function M.prompt_explanation()
  if not state then return end
  prompt_input(INPUT_TITLES.explanation, function(value)
    if value == nil then return end
    local label = (state.frame and state.frame.hasTask) and "Explaining selected path" or "Explaining repository topic"
    M.dispatch("explain", { topic = value }, label)
  end)
end

function M.prompt_message()
  if not state then return end
  if not (state.frame and state.frame.hasTask) then
    vim.notify("No task is active. Press [N] for a change or [E] for an explanation.", vim.log.levels.WARN)
    return
  end
  prompt_input(message_title(), function(value)
    if value == nil then return end
    M.dispatch("rethink", { message = value }, OP_LABELS.rethink)
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
  if (state.frame.choices or {})[n] then
    M.dispatch("choose", { n = n }, OP_LABELS.choose)
  end
end

function M.develop() M.dispatch("develop", {}, OP_LABELS.develop) end
function M.apply_selected() M.dispatch("apply", {}, OP_LABELS.apply) end
function M.commit_applied() M.dispatch("commit", {}, OP_LABELS.commit) end
function M.restrict(mode) M.dispatch(mode, {}, OP_LABELS[mode]) end
--- t: switch the right pane between CHANGES and SESSION. Pinned until the
--- other side (dis)appears or t is pressed again.
function M.toggle_right_view()
  if not state or not state.frame then return end
  state.right_view = state.right_view == "changes" and "session" or "changes"
  state.right_view_pinned = true
  if state.right_view == "session" then state.jump_tail = true end
  M.render(state.frame, true)
end

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
