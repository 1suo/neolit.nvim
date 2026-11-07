--- Read-only Git-native planning workspace. This is intentionally separate
--- from the legacy planned-diff panel and its controller/session protocol.
local M = {}

local function find_core(opts)
  local config = require("neolit.config")
  local cfg = config.merge(opts or {})
  local root = vim.fn.fnamemodify(cfg.directory or vim.fn.getcwd(), ":p")
  local plugin_root = config.plugin_root()
  local npm_root = vim.fn.system({ "npm", "root", "-g" }):gsub("%s+$", "")
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

local function diff_command(file)
  if file.untracked or (file.status == "added" and #file.hunks == 0) then
    return { "git", "-c", "core.quotePath=false", "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", file.path }
  end
  local command = { "git", "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD", "--" }
  if file.previousPath then command[#command + 1] = file.previousPath end
  command[#command + 1] = file.path
  return command
end

local function normalize_diff(diff)
  return (diff or ""):gsub("\r\n", "\n"):gsub("\n+$", "")
end

local function open_diff(root, file, selected_hunk, on_line_context)
  local initial_result = vim.system(diff_command(file), { cwd = root, text = true }):wait()
  local initial_diff = initial_result.stdout or ""
  local initial_diff_identity = vim.fn.sha256(initial_diff)
  local base_path = file.previousPath or file.path
  local base_result = vim.system({ "git", "show", "HEAD:" .. base_path }, { cwd = root, text = true }):wait()
  local base_lines = vim.split(base_result.code == 0 and (base_result.stdout or "") or "", "\n", { plain = true })
  if base_lines[#base_lines] == "" then table.remove(base_lines) end
  local filetype = vim.filetype.match({ filename = file.path }) or ""

  vim.cmd("tab split")
  vim.cmd("enew")
  local base_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(base_buf, "neolit-base://" .. base_path .. "#" .. base_buf)
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_lines)
  vim.bo[base_buf].buftype = "nofile"
  vim.bo[base_buf].bufhidden = "hide"
  vim.bo[base_buf].swapfile = false
  vim.bo[base_buf].filetype = filetype
  local base_win = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local working_buf
  if vim.fn.filereadable(root .. "/" .. file.path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. file.path))
    working_buf = vim.api.nvim_get_current_buf()
  else
    working_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(working_buf, "neolit-working://" .. file.path .. "#" .. working_buf)
    vim.api.nvim_win_set_buf(0, working_buf)
    vim.bo[working_buf].buftype = "nofile"
    vim.bo[working_buf].bufhidden = "hide"
    vim.bo[working_buf].swapfile = false
    vim.bo[working_buf].filetype = filetype
  end

  local working_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(base_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(working_win)
  vim.cmd("diffthis")
  if selected_hunk then
    local target = file.status == "deleted" and selected_hunk.oldStart or selected_hunk.newStart
    vim.api.nvim_set_current_win(file.status == "deleted" and base_win or working_win)
    vim.api.nvim_win_set_cursor(0, { math.max(1, target), 0 })
  end

  if on_line_context then
    local function install_line_context(target_buf, side)
      local function send_range(first, last)
        local start_line, end_line = math.min(first, last), math.max(first, last)
        local selected = vim.api.nvim_buf_get_lines(target_buf, start_line - 1, end_line, false)
        on_line_context(file, side, { startLine = start_line, endLine = end_line },
          table.concat(selected, "\n"), initial_diff_identity, target_buf)
      end
      vim.keymap.set("n", "<leader>nx", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        send_range(line, line)
      end, { buffer = target_buf, silent = true, desc = "Ask existing agent about this line" })
      vim.keymap.set("x", "<leader>nx", function()
        local first = vim.fn.getpos("v")[2]
        local last = vim.api.nvim_win_get_cursor(0)[1]
        send_range(first, last)
      end, { buffer = target_buf, silent = true, desc = "Ask existing agent about selected lines" })
    end
    install_line_context(base_buf, "base")
    install_line_context(working_buf, "working-tree")
  end
end

local function render(buf, root, workspace)
  local lines, rows = {}, {}
  local function add(text, row)
    lines[#lines + 1] = text
    rows[#lines] = row
  end

  add("PLANNING  " .. workspace.git.branch .. " @ " .. workspace.git.head:sub(1, 8), { kind = "header" })
  add("", nil)
  local requirement_states = {}
  for _, item in ipairs(workspace.derived and workspace.derived.requirements or {}) do
    requirement_states[item.specPath .. "#" .. item.requirementId] = item.state
  end
  add("TASKS (" .. #workspace.tasks .. ")", nil)
  for _, task in ipairs(workspace.tasks) do
    local checkbox = task.checked and "[x]" or "[ ]"
    local todo_path = task.key:match("^(.-)::") or "TODO.md"
    local task_state = workspace.derived and workspace.derived.tasks[task.key]
    add(string.format("  %s %-10s %s  (%s:%d)", checkbox, task_state and task_state.state or task.state, task.text, todo_path, task.range.startLine), {
      kind = "task", task = task,
    })
    for _, requirement in ipairs(task.resolvedRequirements) do
      local spec_path = requirement.specPath
      local requirement_state = requirement_states[requirement.specPath .. "#" .. requirement.id] or "planned"
      add(string.format("      %s  %-10s %s", requirement.id, requirement_state, requirement.text), {
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
  local associations, statuses = {}, {}
  for _, association in ipairs(workspace.git.associations) do associations[association.path] = association end
  for _, status in ipairs(workspace.git.status) do statuses[status.path] = status end
  for _, file in ipairs(workspace.git.changedFiles) do
    local association = associations[file.path] or { state = "unplanned", taskKeys = {} }
    local marker = association.state == "unplanned" and "?" or (association.state == "partially-mapped" and "~" or "+")
    local status = statuses[file.path]
    local git_status = status and (status.index .. status.worktree) or "  "
    local doc_marker = file.path:match("%.md$") and "#" or " "
    add(string.format("  %s %s [%s] %s", marker, doc_marker, git_status, file.path), { kind = "file", file = file, association = association })
    for _, hunk in ipairs(file.hunks) do
      add(string.format("      @@ -%d,%d +%d,%d @@ %s", hunk.oldStart, hunk.oldLines, hunk.newStart, hunk.newLines, hunk.header), {
        kind = "hunk", file = file, hunk = hunk, association = association,
      })
    end
  end
  if #workspace.git.changedFiles == 0 then add("  (working tree clean)", nil) end

  add("", nil)
  add("DIAGNOSTICS (" .. #workspace.diagnostics .. ")", nil)
  for _, diagnostic in ipairs(workspace.diagnostics) do
    add(string.format("  ! %s:%s %s", diagnostic.todoPath, diagnostic.line or "?", diagnostic.message), {
      kind = "diagnostic", diagnostic = diagnostic,
    })
  end

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
  vim.api.nvim_buf_set_name(buf, "neolit://planning-" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
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
          render(buf, root, workspace)
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

  local function copy_packet(packet)
    local copied = pcall(vim.fn.setreg, "+", packet)
    if copied then
      vim.notify("Question and exact selection context copied. Paste into the existing agent conversation.")
    else
      vim.fn.setreg('"', packet)
      vim.notify("Clipboard unavailable; context copied to the unnamed register.")
    end
  end

  local function copy_context(context)
    vim.ui.input({ prompt = "Question about selected context: " }, function(question)
      if not question or question == "" then return end
      copy_packet("Question: " .. question .. "\n\n" .. context)
    end)
  end

  local function ask_line_context(file, side, range, selected_lines, opened_diff_identity, target_buf)
    if side == "working-tree" and vim.bo[target_buf].modified then
      vim.notify("Save the working-tree buffer before asking about its diff context.", vim.log.levels.WARN)
      return
    end
    local result = vim.system(diff_command(file), { cwd = root, text = true }):wait()
    local current_diff = result.stdout or ""
    if vim.fn.sha256(current_diff) ~= opened_diff_identity then
      vim.notify("Selected diff changed since it was opened; refresh and select it again.", vim.log.levels.WARN)
      refresh()
      return
    end
    local workspace = vim.b[buf].neolit_workspace
    local head = vim.system({ "git", "rev-parse", "--verify", "HEAD" }, { cwd = root, text = true }):wait()
    local current_head = (head.stdout or ""):gsub("%s+$", "")
    if workspace and workspace.git.head ~= current_head then
      vim.notify("Diff anchor is stale because HEAD changed; refresh and select it again.", vim.log.levels.WARN)
      refresh()
      return
    end

    local anchor_base = current_head ~= "" and current_head or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    local selected_path = side == "base" and (file.previousPath or file.path) or file.path
    local related_tasks = {}
    for _, association in ipairs(workspace and workspace.git.associations or {}) do
      if association.path == file.path then
        for _, task in ipairs(workspace.tasks or {}) do
          if vim.tbl_contains(association.taskKeys or {}, task.key) then
            local requirements = {}
            for _, requirement in ipairs(task.resolvedRequirements or {}) do
              for _, reference in ipairs(task.specReferences or {}) do
                if vim.tbl_contains(reference.ids or {}, requirement.id) then
                  requirements[#requirements + 1] = {
                    specPath = reference.path,
                    requirement = requirement,
                  }
                end
              end
            end
            related_tasks[#related_tasks + 1] = {
              todoPath = task.key:match("^(.-)::") or "",
              task = task,
              requirements = requirements,
            }
          end
        end
        break
      end
    end

    vim.ui.input({ prompt = "Question about selected lines: " }, function(question)
      if not question or question == "" then return end
      local payload = {
        question = question,
        path = selected_path,
        side = side,
        baseCommit = anchor_base,
        diffText = current_diff,
        lineRange = range,
        selectedDiffText = current_diff,
        selectedLinesText = selected_lines,
        relatedTasks = related_tasks,
      }
      local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/context.js")
      local js = "const m = await import(" .. string.format("%q", url) .. "); "
        .. "const p = JSON.parse(process.argv[1]); "
        .. "const anchor = m.createDiffAnchor({ path: p.path, side: p.side, baseCommit: p.baseCommit, diffText: p.diffText, lineRange: p.lineRange }); "
        .. "const result = m.buildDiffQuestionPacket({ question: p.question, anchor, currentBaseCommit: p.baseCommit, currentDiffText: p.diffText, selectedDiffText: p.selectedDiffText, selectedLinesText: p.selectedLinesText, relatedTasks: p.relatedTasks }); "
        .. "process.stdout.write(JSON.stringify(result));"
      local packet_result = vim.system({
        cfg.node, "--input-type=module", "-e", js, vim.json.encode(payload),
      }, { cwd = root, text = true }):wait()
      if packet_result.code ~= 0 then
        vim.notify("Could not build Neolit context packet: " .. (packet_result.stderr or ""), vim.log.levels.ERROR)
        return
      end
      local decoded_ok, packet_result_json = pcall(vim.json.decode, packet_result.stdout or "")
      if not decoded_ok or packet_result_json.status ~= "ready" then
        vim.notify("Diff context became stale; refresh and select the line again.", vim.log.levels.WARN)
        refresh()
        return
      end
      copy_packet(packet_result_json.packet)
    end)
  end

  local function selected()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    if row.kind == "task" then
      local task = row.task
      local todo_path = task.key:match("^(.-)::")
      if todo_path then
        vim.cmd("tabedit " .. vim.fn.fnameescape(root .. "/" .. todo_path))
        vim.api.nvim_win_set_cursor(0, { task.range.startLine, 0 })
      end
    elseif row.kind == "requirement" then
      local req = row.requirement
      local spec_path = row.spec_path
      if spec_path then
        vim.cmd("tabedit " .. vim.fn.fnameescape(root .. "/" .. spec_path))
        vim.api.nvim_win_set_cursor(0, { req.range.startLine, 0 })
      end
    elseif row.kind == "file" then
      open_diff(root, row.file, nil, ask_line_context)
    elseif row.kind == "hunk" then
      open_diff(root, row.file, row.hunk, ask_line_context)
    end
  end

  local function ask_context()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (row.kind ~= "file" and row.kind ~= "hunk" and row.kind ~= "requirement" and row.kind ~= "task") then
      vim.notify("Select a task, requirement, or changed file first")
      return
    end
    local context
    if row.kind == "file" or row.kind == "hunk" then
      local result = vim.system(diff_command(row.file), { cwd = root, text = true }):wait()
      local diff = result.stdout or ""
      local workspace = vim.b[buf].neolit_workspace
      local head = vim.system({ "git", "rev-parse", "--verify", "HEAD" }, { cwd = root, text = true }):wait()
      if workspace and workspace.git.head ~= (head.stdout or ""):gsub("%s+$", "") then
        vim.notify("Diff anchor is stale because HEAD changed; refresh and select it again.", vim.log.levels.WARN)
        refresh()
        return
      end
      if row.file.rawDiff and normalize_diff(diff) ~= row.file.rawDiff then
        vim.notify("Selected diff changed since the workspace was loaded; refreshing. Select it again.", vim.log.levels.WARN)
        refresh()
        return
      end
      if row.kind == "hunk" then
        local lines, capture, selected = vim.split(diff, "\n", { plain = true }), {}, false
        for _, line in ipairs(lines) do
          if line:match("^@@ ") then
            if selected then break end
            local old, new = line:match("^@@ %-(%d+)[^ ]* %+(%d+)")
            selected = tonumber(old) == row.hunk.oldStart and tonumber(new) == row.hunk.newStart
          end
          if selected then capture[#capture + 1] = line end
        end
        diff = table.concat(capture, "\n")
      end
      context = "Selected Git diff (" .. (row.kind == "hunk" and "hunk" or "file") .. "): " .. row.file.path
        .. "\nDiff side: HEAD → working tree/index"
        .. "\nBase commit: " .. tostring(workspace and workspace.git.head or "")
        .. (row.hunk and string.format("\nOld lines %d-%d; new lines %d-%d", row.hunk.oldStart, row.hunk.oldStart + row.hunk.oldLines - 1, row.hunk.newStart, row.hunk.newStart + row.hunk.newLines - 1) or "")
        .. "\n\n" .. diff
      local related = {}
      for _, task in ipairs(workspace and workspace.tasks or {}) do
        if row.association and vim.tbl_contains(row.association.taskKeys, task.key) then
          related[#related + 1] = "- TODO: " .. task.text
          for _, requirement in ipairs(task.resolvedRequirements) do
            related[#related + 1] = "  - " .. requirement.id .. ": " .. requirement.text
          end
        end
      end
      if #related > 0 then context = context .. "\n\nRelated plan:\n" .. table.concat(related, "\n") end
    elseif row.kind == "requirement" then
      context = "Selected SPEC requirement " .. row.requirement.id
        .. "\nSource: " .. tostring(row.spec_path) .. ":" .. row.requirement.range.startLine
        .. "\n\n" .. row.requirement.text
    else
      context = "Selected TODO task: " .. row.task.text
        .. "\nSource: " .. tostring(row.task.key:match("^(.-)::")) .. ":" .. row.task.range.startLine
        .. "\nSPEC references: " .. vim.inspect(row.task.specReferences)
    end
    copy_context(context)
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("<CR>", selected, "Open selected TODO, SPEC requirement, or native diff")
  map("r", refresh, "Refresh Git-native planning workspace")
  map("x", ask_context, "Copy selected planning/diff context for existing agent")
  map("q", function()
    if vim.api.nvim_get_current_buf() == buf then vim.cmd("close") end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end, "Close planning workspace")
  refresh()
end

return M
