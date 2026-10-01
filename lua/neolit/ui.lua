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

--- Which rows render: a row is visible when no ancestor directory is folded
--- and, in plan-only mode, when it (or a descendant) carries plan state.
--- `rows` come from the shim with `directory` and `repositoryOnly` flags.
function M.visible_rows(rows, folded, plan_only)
  local marked = nil
  if plan_only then
    marked = { ["."] = true }
    for _, row in ipairs(rows) do
      local path = row_path(row)
      if path and not row.repositoryOnly then
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
      segments[#segments + 1] = { text = "[PLAN-ONLY]", group = "NeolitMuted" }
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
  if vim.api.nvim_win_is_valid(state.wins.detail) then
    local path = selected_path() or "repository"
    vim.api.nvim_win_set_option(state.wins.detail, "winbar", "%#NeolitMuted#" .. escape_statusline(path) .. "%#Normal#")
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
      state.host:request("frame", { spinner = spinner() }, function(msg)
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

function M.render(frame)
  if not state or not frame then return end
  if not vim.api.nvim_win_is_valid(state.wins.tree) then
    M.close()
    return
  end
  state.frame = frame
  state.local_error = nil
  state.cancel_requested = false

  -- The selection must stay reachable: unfold its ancestors.
  if type(frame.tree.selectedRowId) == "string" then
    local path = row_path({ id = frame.tree.selectedRowId })
    if path then
      for _, ancestor in ipairs(ancestor_paths(path)) do
        state.folded[ancestor] = nil
      end
    end
  end

  local tree_lines = {}
  local row_ids = {}
  local rows_visible = M.visible_rows(frame.tree.rows or {}, state.folded, state.plan_only)
  for index, row in ipairs(rows_visible) do
    tree_lines[#tree_lines + 1] = { segments = row.segments }
    row_ids[#row_ids + 1] = row.id
  end
  state.row_ids = row_ids
  state.rows_visible = rows_visible
  render.render_lines(vim.api, state.ns, state.bufs.tree, theme, tree_lines)

  local selected = 1
  for index, id in ipairs(row_ids) do
    if id == frame.tree.selectedRowId then selected = index break end
  end
  pcall(vim.api.nvim_win_set_cursor, state.wins.tree, { selected, 0 })

  if vim.api.nvim_buf_is_valid(state.bufs.detail) then
    render.render_lines(vim.api, state.ns, state.bufs.detail, theme, frame.detail or {})
  end
  if state.last_selected ~= frame.tree.selectedRowId then
    state.last_selected = frame.tree.selectedRowId
    if vim.api.nvim_win_is_valid(state.wins.detail) then
      pcall(vim.api.nvim_win_set_cursor, state.wins.detail, { 1, 0 })
    end
  end

  update_winbars()
  notify_panel()
  ensure_timer()
end

--------------------------------------------------------------------------
-- Windows: two honest splits
--------------------------------------------------------------------------

local function prepare_buffer(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_name(buf, "neolit://" .. name)
  return buf
end

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

local function set_up_detail_window(win, buf)
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
  scope.winbar = "repository"
end

local function editor_window_count()
  local wins = state and state.wins or {}
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == ""
      and win ~= wins.tree and win ~= wins.detail then
      count = count + 1
    end
  end
  return count
end

local function create_detail_window()
  if not state or vim.api.nvim_win_is_valid(state.wins.detail) then return end
  local tree = state.wins.tree
  if not vim.api.nvim_win_is_valid(tree) then return end
  local width = config.geometry(vim.o.columns, {
    sidebar_width = state.cfg.sidebar_width,
    detail_width = state.cfg.detail_width,
    editor_windows = editor_window_count(),
  }).detail
  if width < 12 then
    vim.notify("Not enough room for the detail split; close a window and press Tab.", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_win_call(tree, function()
    vim.cmd("rightbelow vertical " .. width .. "split")
    -- nvim_win_call restores the previous current window afterwards, so the
    -- new split must be captured here, inside the call.
    state.wins.detail = vim.api.nvim_get_current_win()
  end)
  set_up_detail_window(state.wins.detail, state.bufs.detail)
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
      and win ~= state.wins.tree and win ~= state.wins.detail then
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
  state.bufs = { tree = prepare_buffer("tree"), detail = prepare_buffer("detail") }

  local geometry = config.geometry(vim.o.columns, {
    sidebar_width = state.cfg.sidebar_width,
    detail_width = state.cfg.detail_width,
    editor_windows = editor_window_count(),
  })
  vim.cmd("topleft vertical " .. geometry.sidebar .. "split")
  state.wins = { tree = vim.api.nvim_get_current_win(), detail = -1 }
  set_up_tree_window(state.wins.tree, state.bufs.tree)

  create_detail_window()

  render.render_lines(vim.api, state.ns, state.bufs.tree, theme,
    { { text = "Starting the neolit host…", color = theme.colors.muted } })

  keys.attach(M, state.bufs.tree)
  keys.attach(M, state.bufs.detail)

  balance_editor_windows()

  -- Closing the sidebar ends the panel; closing the detail split just hides it.
  state.autocmds = {}
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.wins.tree),
    callback = function() M.close() end,
  })
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.wins.detail),
    callback = function()
      if state then state.wins.detail = -1 end
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
    plan_only = false,
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
  if cfg.persist_tasks == false then env.AUGMENT_TUI_TASKS = "0" end

  -- env is only passed when set: an empty env table is rejected by some
  -- jobstart implementations (E475) and would otherwise break every open.
  local spawn_opts = {
    cmd = { cfg.node, plugin_root .. "/host/host.mjs", "--dist", dist_root .. "/dist", unpack_table(cfg.host_args or {}) },
    cwd = directory,
  }
  if next(env) ~= nil then spawn_opts.env = env end

  local spawn_ok, spawned = pcall(hostmod.new, spawn_opts, {
    on_frame = function(frame)
      if state then M.render(frame) end
    end,
    on_progress = function(progress)
      if state and progress and progress.operation then ensure_timer() end
    end,
    on_stderr = function(text)
      if text and text:find("%S") then vim.schedule(function() vim.notify("neolit host: " .. vim.trim(text), vim.log.levels.WARN) end) end
    end,
    on_exit = function(code)
      -- Only a crash of THIS state's host tears the UI down; an exit from a
      -- previous session's shutting-down host must never close a fresh panel.
      if state and state.host == spawned and not state.closing then
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
    if not state then return end
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
  if current == state.wins.detail then return "detail" end
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
  local win = state.wins.detail
  if win == -1 or not vim.api.nvim_win_is_valid(win) then return end
  local count = vim.api.nvim_buf_line_count(state.bufs.detail)
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
  if mode == "open" then
    state.folded[path] = nil
  elseif mode == "close" then
    state.folded[path] = true
  else
    state.folded[path] = state.folded[path] and nil or true
  end
  M.render(state.frame)
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

--- Hides repository-only paths: only planned paths and their ancestors stay.
function M.toggle_plan_only()
  if not state or not state.frame then return end
  state.plan_only = not state.plan_only
  M.render(state.frame)
end

--- First non-panel window in the tab, creating one beside the sidebar if
--- the panel is alone.
local function panel_target_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.wins.tree and win ~= state.wins.detail and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  local tree = state.wins.tree
  vim.api.nvim_win_call(tree, function()
    vim.cmd("rightbelow vertical split")
  end)
  return vim.api.nvim_get_current_win()
end

--- o: open the selected file as a real buffer. Directories fold; drafted
--- new files fall through to their patch buffer.
function M.open_selected()
  if not state then return end
  local row = cursor_row()
  if not row then return end
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

function M.switch_model()
  if not state or not state.host then return end
  state.host:request("agent", {}, function(agent_message)
    if not state then return end
    if agent_message.error or not agent_message.result then
      vim.notify((agent_message.error and agent_message.error.message) or "No model runtime is active.", vim.log.levels.WARN)
      return
    end
    local roles = {
      { id = "model", label = "default" },
      { id = "draftModel", label = "draft" },
      { id = "challengeModel", label = "challenge" },
    }
    prompt_select(roles, { prompt = "Switch which model?", format_item = function(role) return role.label end }, function(role)
      if not role or not state then return end
      state.host:request("models", {}, function(models_message)
        if not state then return end
        local models = models_message.result and models_message.result.models or {}
        local source = models_message.result and models_message.result.source
        if models_message.error then models, source = {}, models_message.error.message end
        if #models > 0 then
          prompt_select(models, { prompt = role.label .. " model" }, function(model)
            if model and state then M.dispatch("configure", { [role.id] = model }, OP_LABELS.configure) end
          end)
        else
          prompt_input((source and source .. " — " or "") .. role.label .. " model id", function(model)
            if model and model ~= "" and state then M.dispatch("configure", { [role.id] = model }, OP_LABELS.configure) end
          end)
        end
      end)
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
