--- The Neovim frame: a grid of editor-relative floats laid out like the
--- TUI frame (header, FILES tree pane, detail pane, legend, message panel).
--- One operational plane: identical buffer-local keys on the two focusable
--- panes (the analog of Ink's global useInput), chrome that cannot receive
--- focus, and Tab switching pane focus programmatically. The controller,
--- model runtime, apply/commit transactions, and the pane view model all
--- live in the host shim; this module renders frames and routes keys.

local config = require("neolit.config")
local theme = require("neolit.theme")
local layout = require("neolit.layout")
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

local function message_title()
  return (selected_path() or "repo") .. " · message (empty = rethink)"
end

--------------------------------------------------------------------------
-- Panel and spinner
--------------------------------------------------------------------------

local function panel_winhl(group)
  pcall(vim.api.nvim_win_set_option, state.wins.panel, "winhl", "FloatBorder:" .. group)
end

local function render_panel()
  if not state then return end
  local frame = state.frame
  local line, color, border = "", theme.colors.muted, "NeolitFloatBorder"
  if busy_now() then
    if state.cancel_requested then
      line, color, border = "Cancelling the running operation…", theme.colors.warning, "NeolitWarning"
    else
      local operation = (frame and frame.panel and frame.panel.operation) or (state.pending and state.pending.label) or "Working"
      line, color, border = spinner() .. " " .. operation .. "…", theme.colors.warning, "NeolitWarning"
    end
  else
    local error_text = state.local_error or (frame and frame.panel and frame.panel.error)
    if error_text and error_text ~= "" then
      line, color, border = error_text, theme.colors.error, "NeolitError"
    elseif frame and frame.panel then
      line = frame.panel.message or ""
    end
  end
  render.render_lines(vim.api, state.ns, state.bufs.panel, theme, { { text = line, color = color } })
  panel_winhl(border)
end

local function ensure_timer()
  if not state or state.timer then return end
  local uv = vim.uv or vim.loop
  state.timer = uv.new_timer()
  state.timer:start(120, 120, vim.schedule_wrap(function()
    if not state then return end
    if not busy_now() then
      if state.timer then state.timer:stop() end
      state.timer = nil
      state.cancel_requested = false
      render_panel()
      return
    end
    state.spinner_i = state.spinner_i + 1
    render_panel()
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

local function chips_to_segments(chips, joiner)
  local segments = {}
  for index, chip in ipairs(chips or {}) do
    if index > 1 then segments[#segments + 1] = { text = joiner } end
    segments[#segments + 1] = { text = chip.text, color = chip.color, bold = chip.bold }
  end
  return segments
end

local function render_header(header)
  local joiner = "  "
  local left = chips_to_segments(header and header.left, joiner)
  local right = chips_to_segments(header and header.right, joiner)
  local left_text = vim.fn.join(vim.tbl_map(function(segment) return segment.text end, left), joiner)
  local right_text = vim.fn.join(vim.tbl_map(function(segment) return segment.text end, right), joiner)
  local width = state.boxes.header.width
  local left_width = vim.fn.strdisplaywidth(left_text)
  local right_width = vim.fn.strdisplaywidth(right_text)
  local segments
  if left_width + right_width + 1 <= width then
    local padding = width - left_width - right_width
    local all = {}
    for _, segment in ipairs(left) do all[#all + 1] = segment end
    all[#all + 1] = { text = string.rep(" ", padding) }
    for _, segment in ipairs(right) do all[#all + 1] = segment end
    segments = all
  else
    segments = left
  end
  render.render_lines(vim.api, state.ns, state.bufs.header, theme, { { segments = segments } })
end

function M.render(frame)
  if not state or not frame then return end
  state.frame = frame
  state.local_error = nil
  state.cancel_requested = false

  render_header(frame.header)

  local tree_lines = {}
  local row_ids = {}
  for index, row in ipairs(frame.tree.rows or {}) do
    tree_lines[index] = { segments = row.segments }
    row_ids[index] = row.id
  end
  state.row_ids = row_ids
  render.render_lines(vim.api, state.ns, state.bufs.tree, theme, tree_lines)

  local selected = 1
  for index, id in ipairs(row_ids) do
    if id == frame.tree.selectedRowId then selected = index break end
  end
  if vim.api.nvim_win_is_valid(state.wins.tree) then
    pcall(vim.api.nvim_win_set_cursor, state.wins.tree, { selected, 0 })
  end

  render.render_lines(vim.api, state.ns, state.bufs.detail, theme, frame.detail or {})
  if state.last_selected ~= frame.tree.selectedRowId then
    state.last_selected = frame.tree.selectedRowId
    if vim.api.nvim_win_is_valid(state.wins.detail) then
      pcall(vim.api.nvim_win_set_cursor, state.wins.detail, { 1, 0 })
    end
  end

  render_panel()
  ensure_timer()
end

--------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------

local function open_box(box, buf, enter)
  local bordered = box.border ~= "none"
  local options = {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = math.max(1, box.width - (bordered and 2 or 0)),
    height = math.max(1, box.height - (bordered and 2 or 0)),
    focusable = box.focusable ~= false,
    style = "minimal",
    zindex = 50,
    noautocmd = true,
  }
  if bordered then
    options.border = box.border
    if box.title then
      options.title = box.title
      options.title_pos = "left"
    end
  end
  return vim.api.nvim_open_win(buf, enter or false, options)
end

local function legend_segments()
  local primary, muted = theme.colors.primary, theme.colors.muted
  local function key(text, color) return { { text = "[" .. text .. "]", color = color, bold = true }, { text = " ", color = color } } end
  local parts = {
    key("Enter", primary), { text = "prompt/regenerate · ", color = primary },
    key("1-7", primary), { text = "choose approach · ", color = primary },
    key("D", primary), { text = "develop · ", color = primary },
    key("A", primary), { text = "apply · ", color = primary },
    key("C", primary), { text = "commit · ", color = primary },
    key("L", primary), { text = "lock · ", color = primary },
    key("W", primary), { text = "allow · ", color = primary },
    key("M", primary), { text = "models · ", color = primary },
    key("E", primary), { text = "explain · ", color = primary },
    key("N", primary), { text = "new · ", color = primary },
    key("Tab", muted), { text = "pane · ", color = muted },
    key("Q", muted), { text = "quit", color = muted },
  }
  local segments = {}
  for _, part in ipairs(parts) do
    for _, segment in ipairs(part) do segments[#segments + 1] = segment end
  end
  return segments
end

local function create_windows()
  local api = vim.api
  state.boxes = layout.compute(vim.o.columns, vim.o.lines, { margin = state.cfg.margin, tree_ratio = state.cfg.tree_ratio })
  state.bufs = {}
  state.wins = {}
  for name, box in pairs(state.boxes) do
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(buf, "buftype", "nofile")
    api.nvim_buf_set_option(buf, "filetype", "neolit-" .. name)
    api.nvim_buf_set_option(buf, "swapfile", false)
    state.bufs[name] = buf
    state.wins[name] = open_box(box, buf, false)
  end

  local tree_window, detail_window = state.wins.tree, state.wins.detail
  api.nvim_win_set_option(tree_window, "cursorline", true)
  api.nvim_win_set_option(tree_window, "wrap", false)
  api.nvim_win_set_option(tree_window, "scrolloff", 999)
  api.nvim_win_set_option(detail_window, "wrap", true)
  api.nvim_win_set_option(detail_window, "scrolloff", 0)

  render.render_lines(api, state.ns, state.bufs.legend, theme, { { segments = legend_segments() } })
  render.render_lines(api, state.ns, state.bufs.header, theme,
    { { segments = { { text = "NEOLIT", color = theme.colors.primary, bold = true } } } })
  render.render_lines(api, state.ns, state.bufs.tree, theme,
    { { text = "Starting the neolit host…", color = theme.colors.muted } })
  render.render_lines(api, state.ns, state.bufs.panel, theme,
    { { text = "…", color = theme.colors.muted } })

  keys.attach(M, state.bufs.tree)
  keys.attach(M, state.bufs.detail)
end

function M.relayout()
  if not state then return end
  state.boxes = layout.compute(vim.o.columns, vim.o.lines, { margin = state.cfg.margin, tree_ratio = state.cfg.tree_ratio })
  for name, box in pairs(state.boxes) do
    local win = state.wins[name]
    if win and vim.api.nvim_win_is_valid(win) then
      local bordered = box.border ~= "none"
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row = box.row,
        col = box.col,
        width = math.max(1, box.width - (bordered and 2 or 0)),
        height = math.max(1, box.height - (bordered and 2 or 0)),
        border = box.border ~= "none" and box.border or nil,
      })
    end
  end
  if state.frame then M.render(state.frame) end
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
  theme.apply()

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
    frame = nil,
    pending = nil,
    local_error = nil,
    cancel_requested = false,
    closing = false,
    ns = vim.api.nvim_create_namespace("neolit"),
  }
  create_windows()

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
        local was_state = state
        state = nil
        for _, win in pairs(was_state.wins) do pcall(vim.api.nvim_win_close, win, true) end
        for _, buf in pairs(was_state.bufs) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
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
  end)
end

function M.close()
  if not state then return end
  local current = state
  state = nil
  current.closing = true
  if current.timer then current.timer:stop() end
  for _, win in pairs(current.wins) do pcall(vim.api.nvim_win_close, win, true) end
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
  state.host:request(method, params or {}, function(msg)
    if not state then return end
    state.pending = nil
    if msg.error then
      state.local_error = msg.error.message or "host error"
      render_panel()
    else
      M.render(msg.result and msg.result.frame or msg.result)
    end
  end)
end

function M.pane()
  return state and state.pane or "tree"
end

function M.set_pane(pane)
  if not state then return end
  state.pane = pane or (state.pane == "tree" and "detail" or "tree")
  local active = state.pane == "tree"
  pcall(vim.api.nvim_win_set_option, state.wins.tree, "winhl",
    "CursorLine:NeolitCursorLine,FloatBorder:" .. (active and "NeolitFloatBorderActive" or "NeolitFloatBorder")
    .. ",FloatTitle:" .. (active and "NeolitPrimary" or "NeolitMuted"))
  pcall(vim.api.nvim_win_set_option, state.wins.detail, "winhl",
    "FloatBorder:" .. (active and "NeolitFloatBorder" or "NeolitFloatBorderActive"))
  local target = state.wins[state.pane]
  if target and vim.api.nvim_win_is_valid(target) then pcall(vim.api.nvim_set_current_win, target) end
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
  if not vim.api.nvim_win_is_valid(win) then return end
  local count = vim.api.nvim_buf_line_count(state.bufs.detail)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local next_line = math.max(1, math.min(count, cursor[1] + delta))
  pcall(vim.api.nvim_win_set_cursor, win, { next_line, 0 })
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
    state.local_error = "No task is active. Press [N] for a change or [E] for an explanation."
    render_panel()
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
      state.local_error = (agent_message.error and agent_message.error.message) or "No model runtime is active."
      render_panel()
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
    render_panel()
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
