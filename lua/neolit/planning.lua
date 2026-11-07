--- Read-only Git-native planning workspace. This is intentionally separate
--- from the legacy planned-diff panel and its controller/session protocol.
local M = {}

local function find_core(opts)
  local config = require("neolit.config")
  local cfg = config.merge(opts or {})
  local root = cfg.directory or vim.fn.getcwd()
  local plugin_root = config.plugin_root()
  local npm_root = vim.fn.system({ cfg.node, "npm", "root", "-g" }):gsub("%s+$", "")
  local neolit_dir = config.find_neolit_dir(cfg, {
    env = vim.fn.environ(),
    plugin_root = plugin_root,
    npm_root = npm_root ~= "" and npm_root or nil,
    readable = function(file) return vim.fn.filereadable(file) == 1 end,
  })
  if not neolit_dir then
    error("neolit planning core not found; build neolit (npm run build) and set neolit_dir")
  end
  return cfg, root, neolit_dir
end

local function open_diff(root, file)
  local args
  if file.status == "added" and #file.hunks == 0 then
    args = { "git", "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", file.path }
  else
    args = { "git", "diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD", "--", file.path }
  end
  local output = vim.fn.systemlist(args)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "neolit-diff://" .. file.path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #output > 0 and output or { "(no diff for " .. file.path .. ")" })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "diff"
  vim.cmd("tab split")
  vim.api.nvim_win_set_buf(0, buf)
end

local function render(root, workspace)
  local lines, rows = {}, {}
  local function add(text, row)
    lines[#lines + 1] = text
    rows[#lines] = row
  end

  add("PLANNING  " .. workspace.git.branch .. " @ " .. workspace.git.head:sub(1, 8), { kind = "header" })
  add("", nil)
  add("TASKS (" .. #workspace.tasks .. ")", nil)
  for _, task in ipairs(workspace.tasks) do
    local state = task.state == "unmapped" and "!" or (task.checked and "x" or " ")
    local todo_path = task.key:match("^(.-)::") or "TODO.md"
    add(string.format("  [%s] %s  (%s:%d)", state, task.text, todo_path, task.range.startLine), {
      kind = "task", task = task,
    })
    for _, requirement in ipairs(task.resolvedRequirements) do
      local spec_path
      for _, reference in ipairs(task.specReferences) do
        if vim.tbl_contains(reference.ids, requirement.id) then spec_path = reference.path; break end
      end
      add(string.format("      %s  %s", requirement.id, requirement.text), {
        kind = "requirement", requirement = requirement, spec_path = spec_path,
      })
    end
    for _, unresolved in ipairs(task.unresolvedReferences) do
      add("      ! unresolved " .. unresolved.path .. "#" .. table.concat(unresolved.ids, ","), { kind = "diagnostic" })
    end
  end
  if #workspace.tasks == 0 then add("  (no linked TODO tasks)", nil) end

  add("", nil)
  add("CHANGED FILES (" .. #workspace.git.changedFiles .. ")", nil)
  local associations = {}
  for _, association in ipairs(workspace.git.associations) do associations[association.path] = association end
  for _, file in ipairs(workspace.git.changedFiles) do
    local association = associations[file.path] or { state = "unplanned", taskKeys = {} }
    local marker = association.state == "unplanned" and "?" or (association.state == "partially-mapped" and "~" or "+")
    add(string.format("  %s %s", marker, file.path), { kind = "file", file = file })
  end
  if #workspace.git.changedFiles == 0 then add("  (working tree clean)", nil) end

  add("", nil)
  add("DIAGNOSTICS (" .. #workspace.diagnostics .. ")", nil)
  for _, diagnostic in ipairs(workspace.diagnostics) do
    add(string.format("  ! %s:%s %s", diagnostic.todoPath, diagnostic.line or "?", diagnostic.message), {
      kind = "diagnostic", diagnostic = diagnostic,
    })
  end

  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].neolit_rows = rows
  vim.b[buf].neolit_root = root
  return buf
end

function M.open(opts)
  opts = opts or {}
  local ok, cfg, root, neolit_dir = pcall(find_core, opts)
  if not ok then vim.notify(cfg, vim.log.levels.ERROR); return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("botright 16split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, "neolit://planning")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "neolit-planning"

  local function refresh()
    local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/workspace.js")
    local js = "const m = await import(" .. string.format("%q", url) .. "); const w = await m.loadPlanningWorkspace(process.cwd()); process.stdout.write(JSON.stringify(w));"
    local command = { cfg.node, "--input-type=module", "-e", js }
    vim.fn.jobstart(command, {
      cwd = root,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        local raw = table.concat(data or {}, "")
        if raw == "" then return end
        local decoded_ok, workspace = pcall(vim.json.decode, raw)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then return end
          if not decoded_ok then
            vim.notify("neolit: could not decode planning workspace", vim.log.levels.ERROR)
            return
          end
          render(root, workspace)
          vim.b[buf].neolit_workspace = workspace
        end)
      end,
      on_stderr = function(_, data)
        local message = table.concat(data or {}, "\n"):gsub("%s+$", "")
        if message ~= "" then vim.schedule(function() vim.notify(message, vim.log.levels.ERROR) end) end
      end,
      on_exit = function(_, code)
        if code ~= 0 then vim.schedule(function() vim.notify("neolit planning refresh failed (exit " .. code .. ")", vim.log.levels.ERROR) end) end
      end,
    })
  end

  local function selected()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    if row.kind == "task" then
      local task = row.task
      local todo_path = task.key:match("^(.-)::")
      if todo_path then
        vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. todo_path))
        vim.api.nvim_win_set_cursor(0, { task.range.startLine, 0 })
      end
    elseif row.kind == "requirement" then
      local req = row.requirement
      local spec_path = row.spec_path
      if spec_path then
        vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. spec_path))
        vim.api.nvim_win_set_cursor(0, { req.range.startLine, 0 })
      end
    elseif row.kind == "file" then
      open_diff(root, row.file)
    end
  end

  local function ask_context()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (row.kind ~= "file" and row.kind ~= "requirement" and row.kind ~= "task") then
      vim.notify("Select a task, requirement, or changed file first")
      return
    end
    local context
    if row.kind == "file" then
      local diff = vim.fn.system({ "git", "diff", "--no-ext-diff", "--no-color", "HEAD", "--", row.file.path })
      context = "Selected repository diff: " .. row.file.path .. "\n\n" .. diff
    elseif row.kind == "requirement" then
      context = "Selected SPEC requirement " .. row.requirement.id .. ": " .. row.requirement.text
    else
      context = "Selected TODO task: " .. row.task.text .. "\nSPEC references: " .. vim.inspect(row.task.resolvedRequirements)
    end
    vim.fn.setreg("+", context)
    vim.notify("Planning context copied. Paste it into the existing coding-agent conversation.")
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("<CR>", selected, "Open selected TODO, SPEC requirement, or native diff")
  map("r", refresh, "Refresh Git-native planning workspace")
  map("x", ask_context, "Copy selected planning/diff context for existing agent")
  map("q", function() pcall(vim.api.nvim_buf_delete, buf, { force = true }) end, "Close planning workspace")
  refresh()
end

return M
