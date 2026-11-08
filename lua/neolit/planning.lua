--- Read-only Git-native planning workspace backed by the shared TypeScript core.
local M = {}

local function find_core(opts)
  local config = require("neolit.config")
  local cfg = config.merge(opts or {})
  local root = vim.fn.fnamemodify(cfg.directory or vim.fn.getcwd(), ":p")
  local plugin_root = config.plugin_root()
  local env = vim.fn.environ()
  local npm_root
  if not cfg.neolit_dir and not env.NEOLIT_DIR and not (plugin_root and vim.fn.isdirectory(plugin_root .. "/../neolit") == 1) then
    npm_root = vim.fn.system({ "npm", "root", "-g" }):gsub("%s+$", "")
  end
  local neolit_dir = config.find_neolit_dir(cfg, {
    env = env,
    plugin_root = plugin_root,
    npm_root = npm_root ~= "" and npm_root or nil,
    readable = function(file) return vim.fn.filereadable(file) == 1 end,
  })
  if not neolit_dir then
    error("neolit planning core not found; build neolit (npm run build) and set neolit_dir")
  end
  return cfg, root, neolit_dir
end

local function diff_command(file, base)
  if file.untracked or (file.status == "added" and #file.hunks == 0) then
    return { "git", "-c", "core.quotePath=false", "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", file.path }
  end
  local command = { "git", "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color", "--find-renames", base or "HEAD", "--" }
  if file.previousPath then command[#command + 1] = file.previousPath end
  command[#command + 1] = file.path
  return command
end

local function safe_repo_path(root, relative)
  if type(relative) ~= "string" or relative == "" or relative:sub(1, 1) == "/" or relative:sub(1, 1) == "\\" or relative:match("^%a:") then
    return nil
  end
  for segment in relative:gmatch("[^/]+") do
    if segment == ".." or segment == "." then return nil end
  end
  local root_path = vim.fn.resolve(vim.fn.fnamemodify(root, ":p"))
  local absolute = vim.fn.fnamemodify(root_path .. "/" .. relative, ":p")
  local resolved = vim.fn.resolve(absolute)
  if resolved ~= root_path and resolved:sub(1, #root_path + 1) ~= root_path .. "/" then
    return nil
  end
  return absolute
end

local function normalize_diff(diff)
  return (diff or ""):gsub("\r\n", "\n"):gsub("\n+$", "")
end

local function open_diff(root, file, selected_hunk, on_line_context, comparison_base, selected_line)
  -- Git paths are repository-relative, but a changed path may itself be a
  -- symlink. Never let native editor navigation follow it outside the
  -- selected worktree (the shared core applies the same boundary).
  local working_path = safe_repo_path(root, file.path)
  local base_path = file.previousPath or file.path
  if not working_path or not safe_repo_path(root, base_path) then
    vim.notify("Refusing to open a diff path outside the repository: " .. tostring(file.path), vim.log.levels.ERROR)
    return
  end

  local initial_result = vim.system(diff_command(file, comparison_base), { cwd = root, text = true }):wait()
  local initial_diff = initial_result.stdout or ""
  local initial_diff_identity = vim.fn.sha256(initial_diff)
  local base_result = vim.system({ "git", "show", (comparison_base or "HEAD") .. ":" .. base_path }, { cwd = root, text = true }):wait()
  local base_lines = vim.split(base_result.code == 0 and (base_result.stdout or "") or "", "\n", { plain = true })
  if base_lines[#base_lines] == "" then table.remove(base_lines) end
  local filetype = vim.filetype.match({ filename = file.path }) or ""

  vim.cmd("rightbelow vsplit")
  vim.cmd("enew")
  local base_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(base_buf, "neolit-base://" .. base_path .. "#" .. base_buf)
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_lines)
  vim.bo[base_buf].buftype = "nofile"
  vim.bo[base_buf].bufhidden = "hide"
  vim.bo[base_buf].swapfile = false
  vim.bo[base_buf].filetype = filetype
  local base_win = vim.api.nvim_get_current_win()

  vim.cmd("rightbelow vsplit")
  local working_buf
  if vim.fn.filereadable(working_path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(working_path))
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
  if selected_line then
    local target_win = selected_line.side == "base" and base_win or working_win
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(0, { math.max(1, selected_line.lineNumber), 0 })
  end

  if on_line_context then
    local function install_line_context(target_buf, side)
      local function send_range(first, last)
        local start_line, end_line = math.min(first, last), math.max(first, last)
        local selected = vim.api.nvim_buf_get_lines(target_buf, start_line - 1, end_line, false)
        on_line_context(file, side, { startLine = start_line, endLine = end_line },
          table.concat(selected, "\n"), initial_diff_identity, target_buf, selected_hunk)
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

local function render(buf, root, workspace, expanded_files, expanded_dirs)
  local lines, rows = {}, {}
  expanded_files = expanded_files or {}
  expanded_dirs = expanded_dirs or {}
  local function add(text, row)
    lines[#lines + 1] = text
    rows[#lines] = row
  end

  add("PLANNING  " .. workspace.git.branch .. " @ " .. (workspace.git.base or workspace.git.head):sub(1, 8), { kind = "header" })
  add("", nil)
  local requirement_states = {}
  for _, item in ipairs(workspace.derived and workspace.derived.requirements or {}) do
    requirement_states[item.specPath .. "#" .. item.requirementId] = item.state
  end
  add("REPOSITORY  " .. vim.fn.fnamemodify(root, ":t") .. "  (" .. #(workspace.git.repositoryFiles or {}) .. ")", nil)
  local tree_root = { children = {}, files = {} }
  local git_status = {}
  for _, status in ipairs(workspace.git.status or {}) do git_status[status.path] = status end
  for _, file in ipairs(workspace.git.changedFiles or {}) do
    git_status[file.path] = git_status[file.path] or { index = " ", worktree = "M" }
    if file.previousPath then git_status[file.previousPath] = git_status[file.previousPath] or { index = "R", worktree = " " } end
  end
  for _, path in ipairs(workspace.git.repositoryFiles or {}) do
    local node = tree_root
    local parts = vim.split(path, "/", { plain = true })
    for index = 1, #parts - 1 do
      local name = parts[index]
      node.children[name] = node.children[name] or { children = {}, files = {}, path = table.concat(parts, "/", 1, index) }
      node = node.children[name]
    end
    node.files[#node.files + 1] = { name = parts[#parts], path = path }
  end
  local function render_tree(node, ancestors, depth)
    local entries = {}
    for name, child in pairs(node.children) do entries[#entries + 1] = { name = name, directory = true, node = child, path = child.path } end
    for _, file in ipairs(node.files) do entries[#entries + 1] = { name = file.name, path = file.path, directory = false } end
    table.sort(entries, function(a, b)
      if a.directory ~= b.directory then return a.directory end
      return a.name:lower() < b.name:lower()
    end)
    for index, entry in ipairs(entries) do
      local last = index == #entries
      local branch = last and "└── " or "├── "
      local indent = ancestors or ""
      if entry.directory then
        local expanded = expanded_dirs[entry.path] ~= false
        add("  " .. indent .. branch .. (expanded and "▾ " or "▸ ") .. entry.name .. "/", {
          kind = "tree_directory", path = entry.path, expanded = expanded,
        })
        if expanded then render_tree(entry.node, indent .. (last and "    " or "│   "), depth + 1) end
      else
        local status = git_status[entry.path]
        local marker = status and (status.index .. status.worktree) or "  "
        local changed = status ~= nil
        local icon = changed and "● " or "  "
        add("  " .. indent .. branch .. icon .. entry.name .. (changed and ("  [" .. marker .. "]") or ""), {
          kind = "repository_file", path = entry.path, changed = changed,
        })
      end
    end
  end
  render_tree(tree_root, "", 0)
  add("", nil)
  add("DIFF TREE (" .. #workspace.git.changedFiles .. " files)", nil)
  local associations, statuses, hunk_associations = {}, {}, {}
  for _, association in ipairs(workspace.git.associations) do associations[association.path] = association end
  for _, association in ipairs(workspace.git.hunkAssociations or {}) do
    hunk_associations[association.path .. "#" .. association.hunkIndex] = association
  end
  for _, status in ipairs(workspace.git.status) do statuses[status.path] = status end
  for _, file in ipairs(workspace.git.changedFiles) do
    local association = associations[file.path] or { state = "unplanned", taskKeys = {} }
    local marker = association.state == "unplanned" and "?" or (association.state == "partially-mapped" and "~" or "+")
    local status = statuses[file.path]
    local git_status = status and (status.index .. status.worktree) or "  "
    local doc_marker = file.path:match("%.md$") and "#" or " "
    local is_expanded = expanded_files[file.path] == true
    local file_key = "file:" .. file.path
    add(string.format("  %s %s [%s] %s %s", marker, doc_marker, git_status, is_expanded and "▾" or "▸", file.path), { kind = "file", key = file_key, file = file, association = association, expanded = is_expanded })
    if is_expanded then
    for hunk_index, hunk in ipairs(file.hunks) do
      local hunk_association = hunk_associations[file.path .. "#" .. (hunk_index - 1)]
      local hunk_marker = not hunk_association and "?" or (
        hunk_association.state == "unresolved" and "~" or (
          hunk_association.state == "documentation" and "#" or (
          hunk_association.state == "attributed" and "=" or "?"
        )
        )
      )
      local candidate_labels = {}
      for _, task_key in ipairs(hunk_association and hunk_association.candidateTaskKeys or {}) do
        for _, task in ipairs(workspace.tasks or {}) do
          if task.key == task_key then candidate_labels[#candidate_labels + 1] = "task: " .. (task.key:match("^(.-)::") or "TODO") .. ":" .. task.range.startLine end
        end
      end
      for _, reference in ipairs(hunk_association and hunk_association.candidateRequirementRefs or {}) do
        candidate_labels[#candidate_labels + 1] = "requirement: " .. reference
      end
      local candidate_label = #candidate_labels > 0 and (" [" .. table.concat(candidate_labels, "; ") .. "]") or ""
      add(string.format("    %s @@ -%d,%d +%d,%d @@ %s%s", hunk_marker, hunk.oldStart, hunk.oldLines, hunk.newStart, hunk.newLines, hunk.header, candidate_label), {
        kind = "hunk", key = file_key .. ":hunk:" .. hunk_index, file = file, hunk = hunk, association = association, hunkAssociation = hunk_association,
      })
      if hunk.changes and #hunk.changes > 0 then
        for change_index, change in ipairs(hunk.changes) do
          local prefix = change.kind == "added" and "+" or "-"
          local side = change.kind == "added" and "working-tree" or "base"
          add(string.format("      %s %d  %s", prefix, change.lineNumber, change.text), {
            kind = "change_line", key = file_key .. ":hunk:" .. hunk_index .. ":change:" .. change_index,
            file = file, hunk = hunk, hunkAssociation = hunk_association,
            lineNumber = change.lineNumber, lineText = change.text, side = side,
          })
        end
      else
        for line_index, changed_text in ipairs(hunk.addedLines or {}) do
          local line_number = hunk.addedLineNumbers and hunk.addedLineNumbers[line_index]
            or (hunk.newStart + line_index - 1)
          add(string.format("      + %d  %s", line_number, changed_text), {
            kind = "change_line", key = file_key .. ":hunk:" .. hunk_index .. ":add:" .. line_index,
            file = file, hunk = hunk, hunkAssociation = hunk_association,
            lineNumber = line_number, lineText = changed_text, side = "working-tree",
          })
        end
        for line_index, changed_text in ipairs(hunk.removedLines or {}) do
          local line_number = hunk.removedLineNumbers and hunk.removedLineNumbers[line_index]
            or (hunk.oldStart + line_index - 1)
          add(string.format("      - %d  %s", line_number, changed_text), {
            kind = "change_line", key = file_key .. ":hunk:" .. hunk_index .. ":remove:" .. line_index,
            file = file, hunk = hunk, hunkAssociation = hunk_association,
            lineNumber = line_number, lineText = changed_text, side = "base",
          })
        end
      end
    end
    end
  end
  if #workspace.git.changedFiles == 0 then add("  (working tree clean)", nil) end

  add("TASKS (" .. #workspace.tasks .. ")", nil)
  for _, task in ipairs(workspace.tasks) do
    local checkbox = task.checked and "[x]" or "[ ]"
    local todo_path = task.key:match("^(.-)::") or "TODO.md"
    local task_state = workspace.derived and workspace.derived.tasks[task.key]
    add(string.format("  %s %-10s %s  (%s:%d)", checkbox, task_state and task_state.state or task.state, task.text, todo_path, task.range.startLine), {
      kind = "task", task = task,
    })
    for _, file_path in ipairs(task.filePaths or {}) do
      add("      FILE  " .. file_path, {
        kind = "planned_file", path = file_path, task = task,
      })
    end
    for _, requirement in ipairs(task.resolvedRequirements) do
      local spec_path = requirement.specPath
      local requirement_state = requirement_states[requirement.specPath .. "#" .. requirement.id] or "planned"
      add(string.format("      %s  %-10s", requirement.id, requirement_state), {
        kind = "requirement", requirement = requirement, spec_path = spec_path,
      })
    end
    for _, unresolved in ipairs(task.unresolvedReferences) do
      add("      ! unresolved " .. unresolved.path .. "#" .. table.concat(unresolved.ids, ","), { kind = "diagnostic" })
    end
  end
  if #workspace.tasks == 0 then add("  (no linked TODO tasks)", nil) end

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
  vim.cmd("topleft 34vnew")
  vim.api.nvim_win_set_buf(0, buf)
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(tree_win, 34)
  vim.api.nvim_buf_set_name(buf, "neolit://planning-" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "neolit-planning"

  local refresh_job
  local refresh_revision = 0
  local expanded_files = {}
  local expanded_dirs = {}
  local function refresh()
    refresh_revision = refresh_revision + 1
    local revision = refresh_revision
    if refresh_job then pcall(vim.fn.jobstop, refresh_job) end
    local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/workspace.js")
    local comparison_base = vim.json.encode(cfg.comparison_base or "HEAD")
    local js = "import { execFileSync } from \"node:child_process\"; "
      .. "const m = await import(" .. string.format("%q", url) .. "); "
      .. "const w = await m.loadPlanningWorkspace(process.cwd(), { comparisonBase: " .. comparison_base .. " }); "
      .. "w.git.repositoryFiles = execFileSync(\"git\", [\"ls-files\", \"--cached\", \"--others\", \"--exclude-standard\", \"-z\"], { cwd: process.cwd(), encoding: \"utf8\" }).split(\"\\0\").filter(Boolean).sort(); "
      .. "w.git.diff = ''; "
      .. "for (const f of w.git.changedFiles) for (const h of f.hunks) { "
      .. "delete h.changes; delete h.addedLines; delete h.removedLines; "
      .. "delete h.addedLineNumbers; delete h.removedLineNumbers; } "
      .. "process.stdout.write(JSON.stringify(w));"
    local command = { cfg.node, "--input-type=module", "-e", js }
    refresh_job = vim.fn.jobstart(command, {
      cwd = root,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        local raw = table.concat(data or {}, "")
        if raw == "" then return end
        local decoded_ok, workspace = pcall(vim.json.decode, raw)
        vim.schedule(function()
          if revision ~= refresh_revision or not vim.api.nvim_buf_is_valid(buf) then return end
          if not decoded_ok then
            vim.notify("neolit: could not decode planning workspace", vim.log.levels.ERROR)
            return
          end
          for _, file in ipairs(workspace.git.changedFiles or {}) do
            if expanded_files[file.path] == nil then expanded_files[file.path] = false end
          end
          render(buf, root, workspace, expanded_files, expanded_dirs)
          vim.b[buf].neolit_workspace = workspace
        end)
      end,
      on_stderr = function(_, data)
        local message = table.concat(data or {}, "\n"):gsub("%s+$", "")
        if message ~= "" then
          vim.schedule(function()
            if revision == refresh_revision then vim.notify(message, vim.log.levels.ERROR) end
          end)
        end
      end,
      on_exit = function(job, code)
        if refresh_job == job then refresh_job = nil end
        if code ~= 0 then
          vim.schedule(function()
            if revision == refresh_revision then
              vim.notify("neolit planning refresh failed (exit " .. code .. ")", vim.log.levels.ERROR)
            end
          end)
        end
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
      local packet = "Question: " .. question .. "\n\n" .. context
      local max_chars = 16000
      local marker = "\n...[planning context truncated]"
      if vim.fn.strchars(packet) > max_chars then
        packet = vim.fn.strcharpart(packet, 0, max_chars - vim.fn.strchars(marker)) .. marker
      end
      copy_packet(packet)
    end)
  end

  local function ask_line_context(file, side, range, selected_lines, opened_diff_identity, target_buf, selected_hunk)
    if side == "working-tree" and vim.bo[target_buf].modified then
      vim.notify("Save the working-tree buffer before asking about its diff context.", vim.log.levels.WARN)
      return
    end
    local workspace = vim.b[buf].neolit_workspace
    local base = workspace and workspace.git.base or "HEAD"
    local result = vim.system(diff_command(file, base), { cwd = root, text = true }):wait()
    local current_diff = result.stdout or ""
    if vim.fn.sha256(current_diff) ~= opened_diff_identity then
      vim.notify("Selected diff changed since it was opened; refresh and select it again.", vim.log.levels.WARN)
      refresh()
      return
    end
    local head = vim.system({ "git", "rev-parse", "--verify", "--end-of-options", (cfg.comparison_base or "HEAD") .. "^{commit}" }, { cwd = root, text = true }):wait()
    local current_base = (head.stdout or ""):gsub("%s+$", "")
    if workspace and workspace.git.base ~= current_base then
      vim.notify("Diff anchor is stale because the comparison base changed; refresh and select it again.", vim.log.levels.WARN)
      refresh()
      return
    end

    local anchor_base = current_base ~= "" and current_base or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    local selected_path = side == "base" and (file.previousPath or file.path) or file.path
    local related_tasks = {}
    local related_requirements = {}
    local candidate_keys
    local candidate_requirement_refs
    if selected_hunk then
      for _, association in ipairs(workspace and workspace.git.hunkAssociations or {}) do
        if association.path == file.path
          and association.hunk.oldStart == selected_hunk.oldStart
          and association.hunk.oldLines == selected_hunk.oldLines
          and association.hunk.newStart == selected_hunk.newStart
          and association.hunk.newLines == selected_hunk.newLines then
          candidate_keys = association.candidateTaskKeys
          candidate_requirement_refs = association.candidateRequirementRefs
          break
        end
      end
    end
    if not candidate_keys then
      for _, association in ipairs(workspace and workspace.git.associations or {}) do
        if association.path == file.path then candidate_keys = association.taskKeys; break end
      end
    end
    for _, task in ipairs(workspace and workspace.tasks or {}) do
      if vim.tbl_contains(candidate_keys or {}, task.key) then
            local requirements = {}
            for _, requirement in ipairs(task.resolvedRequirements or {}) do
              for _, reference in ipairs(task.specReferences or {}) do
                if reference.path == requirement.specPath and vim.tbl_contains(reference.ids or {}, requirement.id) then
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

    for _, reference in ipairs(candidate_requirement_refs or {}) do
      local spec_path, requirement_id = reference:match("^(.-)#([^#]+)$")
      for _, spec in ipairs(workspace and workspace.specs or {}) do
        if spec.path == spec_path then
          for _, requirement in ipairs(spec.requirements or {}) do
            if requirement.id == requirement_id then
              related_requirements[#related_requirements + 1] = { specPath = spec_path, requirement = requirement }
            end
          end
        end
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
        relatedRequirements = related_requirements,
      }
      local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/context.js")
      local js = "const m = await import(" .. string.format("%q", url) .. "); "
        .. "const p = JSON.parse(process.argv[1]); "
        .. "const anchor = m.createDiffAnchor({ path: p.path, side: p.side, baseCommit: p.baseCommit, diffText: p.diffText, lineRange: p.lineRange }); "
        .. "const result = m.buildDiffQuestionPacket({ question: p.question, anchor, currentBaseCommit: p.baseCommit, currentDiffText: p.diffText, selectedDiffText: p.selectedDiffText, selectedLinesText: p.selectedLinesText, relatedTasks: p.relatedTasks, relatedRequirements: p.relatedRequirements }); "
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
    local workspace = vim.b[buf].neolit_workspace
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    if row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, ask_line_context, workspace.git.base)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(target))
        else
          vim.notify("Repository file is no longer available: " .. row.path, vim.log.levels.WARN)
        end
      end
    elseif row.kind == "task" then
      local task = row.task
      local todo_path = task.key:match("^(.-)::")
      local todo_file = todo_path and safe_repo_path(root, todo_path)
      if todo_file then
        vim.cmd("tabedit " .. vim.fn.fnameescape(todo_file))
        vim.api.nvim_win_set_cursor(0, { task.range.startLine, 0 })
      end
    elseif row.kind == "requirement" then
      local req = row.requirement
      local spec_path = row.spec_path
      local spec_file = spec_path and safe_repo_path(root, spec_path)
      if spec_file then
        vim.cmd("tabedit " .. vim.fn.fnameescape(spec_file))
        vim.api.nvim_win_set_cursor(0, { req.range.startLine, 0 })
      end
    elseif row.kind == "planned_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, ask_line_context, workspace.git.base)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          vim.cmd("tabedit " .. vim.fn.fnameescape(target))
        else
          vim.notify("Planned file does not exist yet: " .. row.path, vim.log.levels.INFO)
        end
      end
    elseif row.kind == "file" then
      open_diff(root, row.file, nil, ask_line_context, workspace and workspace.git.base)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_diff(root, row.file, row.hunk, ask_line_context, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil)
    end
  end

  local function show_details()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    local details = {}
    local function put(value)
      if value == nil or value == "" then return end
      for _, line in ipairs(vim.split(tostring(value), "\n", { plain = true })) do
        details[#details + 1] = line
      end
    end
    if row.kind == "file" then
      put("CHANGED FILE")
      put(row.file.path)
      put("Git status: " .. tostring(row.file.status or "changed"))
      put("Mapping: " .. tostring(row.association and row.association.state or "unplanned"))
      put("Previous path: " .. tostring(row.file.previousPath or "—"))
      put("Candidate tasks:")
      for _, key in ipairs(row.association and row.association.taskKeys or {}) do
        for _, task in ipairs(vim.b[buf].neolit_workspace.tasks or {}) do
          if task.key == key then put("  " .. task.text .. " (" .. (key:match("^(.-)::") or "TODO") .. ":" .. task.range.startLine .. ")") end
        end
      end
    elseif row.kind == "hunk" then
      put("DIFF HUNK")
      put(row.file.path)
      put(string.format("Base lines %d-%d; working-tree lines %d-%d",
        row.hunk.oldStart, row.hunk.oldStart + math.max(0, row.hunk.oldLines - 1),
        row.hunk.newStart, row.hunk.newStart + math.max(0, row.hunk.newLines - 1)))
      put("Mapping: " .. tostring(row.hunkAssociation and row.hunkAssociation.state or "unmapped"))
      put("Candidate tasks:")
      for _, key in ipairs(row.hunkAssociation and row.hunkAssociation.candidateTaskKeys or {}) do
        for _, task in ipairs(vim.b[buf].neolit_workspace.tasks or {}) do
          if task.key == key then put("  " .. task.text .. " (" .. (key:match("^(.-)::") or "TODO") .. ":" .. task.range.startLine .. ")") end
        end
      end
      put("Candidate requirements:")
      for _, reference in ipairs(row.hunkAssociation and row.hunkAssociation.candidateRequirementRefs or {}) do put("  " .. reference) end
      put("Changed lines:")
      if row.hunk.changes and #row.hunk.changes > 0 then
        for _, change in ipairs(row.hunk.changes) do
          put((change.kind == "added" and "+ " or "- ") .. change.lineNumber .. " " .. change.text)
        end
      else
        for _, line in ipairs(row.hunk.addedLines or {}) do put("+ " .. line) end
        for _, line in ipairs(row.hunk.removedLines or {}) do put("- " .. line) end
      end
    elseif row.kind == "change_line" then
      put("CHANGED LINE")
      put(row.file.path .. ":" .. row.lineNumber .. " (" .. row.side .. ")")
      put(row.lineText)
      put("Hunk: " .. row.hunk.oldStart .. " → " .. row.hunk.newStart)
    elseif row.kind == "task" or row.kind == "planned_file" then
      local task = row.task
      put("TODO TASK")
      put(task.text)
      put("Source: " .. (task.key:match("^(.-)::") or "TODO") .. ":" .. task.range.startLine)
      local derived_tasks = (vim.b[buf].neolit_workspace.derived or {}).tasks or {}
      put("State: " .. tostring((derived_tasks[task.key] or {}).state or task.state))
      put("Description:")
      put(table.concat(task.description or {}, "\n"))
      put("File hints:")
      for _, path in ipairs(task.filePaths or {}) do put("  " .. path) end
      put("SPEC references:")
      for _, reference in ipairs(task.specReferences or {}) do put("  " .. reference.path .. "#" .. table.concat(reference.ids or {}, ", ")) end
      put("Resolved requirements:")
      for _, requirement in ipairs(task.resolvedRequirements or {}) do
        put("  " .. requirement.specPath .. "#" .. requirement.id .. " " .. requirement.text)
      end
      put("Resolved acceptance criteria:")
      for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
        put("  " .. criterion.specPath .. "#" .. criterion.id .. " " .. criterion.text)
      end
      put("Unresolved references:")
      for _, reference in ipairs(task.unresolvedReferences or {}) do
        put("  " .. reference.path .. "#" .. table.concat(reference.ids or {}, ", "))
      end
    elseif row.kind == "requirement" then
      put("SPEC REQUIREMENT")
      put(row.requirement.id .. " — " .. row.requirement.text)
      put("Source: " .. row.spec_path .. ":" .. row.requirement.range.startLine)
      local derived_requirements = (vim.b[buf].neolit_workspace.derived or {}).requirements or {}
      for _, item in ipairs(derived_requirements) do
        if item.specPath == row.spec_path and item.requirementId == row.requirement.id then
          put("State: " .. item.state)
          break
        end
      end
      put("Acceptance criteria:")
      local linked_criteria = {}
      for _, spec in ipairs(vim.b[buf].neolit_workspace.specs or {}) do
        if spec.path == row.spec_path then
          for _, criterion in ipairs(spec.acceptanceCriteria or {}) do
            if vim.tbl_contains(criterion.requirementIds or {}, row.requirement.id) then
              linked_criteria[criterion.id] = criterion
            end
          end
        end
      end
      for _, task in ipairs(vim.b[buf].neolit_workspace.tasks or {}) do
        local task_links_requirement = false
        for _, requirement in ipairs(task.resolvedRequirements or {}) do
          if requirement.specPath == row.spec_path and requirement.id == row.requirement.id then
            task_links_requirement = true
            break
          end
        end
        if task_links_requirement then
          for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
            if criterion.specPath == row.spec_path then linked_criteria[criterion.id] = criterion end
          end
        end
      end
      local ordered_criteria = vim.tbl_values(linked_criteria)
      table.sort(ordered_criteria, function(left, right)
        return left.range.startLine < right.range.startLine
      end)
      for _, criterion in ipairs(ordered_criteria) do
        put("  " .. criterion.id .. " " .. criterion.text)
      end
      put("Linked TODO tasks:")
      for _, task in ipairs(vim.b[buf].neolit_workspace.tasks or {}) do
        local linked = false
        for _, requirement in ipairs(task.resolvedRequirements or {}) do
          if requirement.specPath == row.spec_path and requirement.id == row.requirement.id then
            linked = true
            break
          end
        end
        if linked then
          local task_state = ((vim.b[buf].neolit_workspace.derived or {}).tasks or {})[task.key]
          put("  " .. task.text .. " [" .. tostring(task_state and task_state.state or task.state) .. "]")
          put("    " .. (task.key:match("^(.-)::") or "TODO") .. ":" .. task.range.startLine)
        end
      end
    elseif row.kind == "diagnostic" then
      put("DOCUMENTATION DIAGNOSTIC")
      put(row.diagnostic and row.diagnostic.message or "Unresolved reference")
      if row.diagnostic then put(row.diagnostic.todoPath .. ":" .. tostring(row.diagnostic.line or "?")) end
    else
      return
    end
    local width = math.max(1, math.min(110, vim.o.columns - 4))
    local height = math.max(1, math.min(math.max(8, #details), vim.o.lines - 6))
    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, details)
    vim.bo[detail_buf].buftype = "nofile"
    vim.bo[detail_buf].bufhidden = "wipe"
    vim.bo[detail_buf].swapfile = false
    vim.bo[detail_buf].filetype = "markdown"
    vim.bo[detail_buf].modifiable = false
    local detail_win = vim.api.nvim_open_win(detail_buf, true, {
      relative = "editor", style = "minimal", border = "rounded",
      width = width, height = height,
      row = math.max(1, math.floor((vim.o.lines - height) / 2)),
      col = math.max(1, math.floor((vim.o.columns - width) / 2)),
      title = " Neolit details ", title_pos = "center",
    })
    vim.wo[detail_win].wrap = true
    vim.wo[detail_win].linebreak = true
    vim.keymap.set("n", "q", function() if vim.api.nvim_win_is_valid(detail_win) then vim.api.nvim_win_close(detail_win, true) end end,
      { buffer = detail_buf, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", function() if vim.api.nvim_win_is_valid(detail_win) then vim.api.nvim_win_close(detail_win, true) end end,
      { buffer = detail_buf, silent = true, nowait = true })
  end

  local function ask_context()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (row.kind ~= "tree_directory" and row.kind ~= "repository_file" and row.kind ~= "file" and row.kind ~= "hunk" and row.kind ~= "change_line" and row.kind ~= "requirement" and row.kind ~= "task" and row.kind ~= "planned_file") then
      vim.notify("Select a task, requirement, planned file, or changed file first")
      return
    end
    if row.kind == "tree_directory" then
      local files = {}
      for _, path in ipairs(vim.b[buf].neolit_workspace.git.repositoryFiles or {}) do
        if path:sub(1, #row.path + 1) == row.path .. "/" then files[#files + 1] = path end
      end
      copy_context("Selected repository folder: " .. row.path .. "\\nFiles beneath this folder:\\n" .. table.concat(files, "\\n"))
      return
    elseif row.kind == "repository_file" then
      local file = row.path
      local status = nil
      for _, entry in ipairs(vim.b[buf].neolit_workspace.git.status or {}) do if entry.path == file then status = entry; break end end
      local changed_file
      for _, candidate in ipairs(vim.b[buf].neolit_workspace.git.changedFiles or {}) do if candidate.path == file then changed_file = candidate; break end end
      if changed_file then
        row = { kind = "file", file = changed_file, association = nil }
      else
        copy_context("Selected repository file: " .. file .. "\\nGit status: " .. (status and (status.index .. status.worktree) or "unchanged") .. "\\nAsk the agent to inspect this file in the working tree.")
        return
      end
    end
    if row.kind == "file" or row.kind == "hunk" or row.kind == "change_line" then
      local workspace = vim.b[buf].neolit_workspace
      local base = workspace and workspace.git.base or "HEAD"
      local result = vim.system(diff_command(row.file, base), { cwd = root, text = true }):wait()
      local full_diff = result.stdout or ""
      local head = vim.system({ "git", "rev-parse", "--verify", "--end-of-options", (cfg.comparison_base or "HEAD") .. "^{commit}" }, { cwd = root, text = true }):wait()
      local current_base = (head.stdout or ""):gsub("%s+$", "")
      if workspace and workspace.git.base ~= current_base then
        vim.notify("Diff anchor is stale because the comparison base changed; refresh and select it again.", vim.log.levels.WARN)
        refresh()
        return
      end
      if row.file.rawDiff and normalize_diff(full_diff) ~= row.file.rawDiff then
        vim.notify("Selected diff changed since the workspace was loaded; refreshing. Select it again.", vim.log.levels.WARN)
        refresh()
        return
      end
      local selected_diff = full_diff
      if row.kind == "hunk" or row.kind == "change_line" then
        local lines, capture, selected = vim.split(full_diff, "\n", { plain = true }), {}, false
        for _, line in ipairs(lines) do
          if line:match("^@@ ") then
            if selected then break end
            local old, old_count, new, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            selected = tonumber(old) == row.hunk.oldStart
              and (old_count == "" and 1 or tonumber(old_count)) == row.hunk.oldLines
              and tonumber(new) == row.hunk.newStart
              and (new_count == "" and 1 or tonumber(new_count)) == row.hunk.newLines
          end
          if selected then capture[#capture + 1] = line end
        end
        selected_diff = table.concat(capture, "\n")
        if selected_diff == "" then
          vim.notify("Selected hunk is no longer present; refresh and select it again.", vim.log.levels.WARN)
          refresh()
          return
        end
      end
      local related_tasks = {}
      local related_requirements = {}
      for _, task in ipairs(workspace and workspace.tasks or {}) do
        local candidate_keys = (row.kind == "hunk" or row.kind == "change_line") and row.hunkAssociation and row.hunkAssociation.candidateTaskKeys or (row.association and row.association.taskKeys or {})
        if vim.tbl_contains(candidate_keys, task.key) then
          local requirements = {}
          for _, requirement in ipairs(task.resolvedRequirements or {}) do
            for _, reference in ipairs(task.specReferences or {}) do
              if reference.path == requirement.specPath and vim.tbl_contains(reference.ids or {}, requirement.id) then
                requirements[#requirements + 1] = { specPath = reference.path, requirement = requirement }
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
      if (row.kind == "hunk" or row.kind == "change_line") and row.hunkAssociation then
        for _, reference in ipairs(row.hunkAssociation.candidateRequirementRefs or {}) do
          local spec_path, requirement_id = reference:match("^(.-)#([^#]+)$")
          for _, spec in ipairs(workspace and workspace.specs or {}) do
            if spec.path == spec_path then
              for _, requirement in ipairs(spec.requirements or {}) do
                if requirement.id == requirement_id then
                  related_requirements[#related_requirements + 1] = { specPath = spec_path, requirement = requirement }
                end
              end
            end
          end
        end
      end
      vim.ui.input({ prompt = "Question about selected diff: " }, function(question)
        if not question or question == "" then return end
        local payload = {
          question = question,
          path = row.file.path,
          side = row.kind == "change_line" and row.side or "working-tree",
          baseCommit = current_base ~= "" and current_base or "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
          diffText = full_diff,
          selectedDiffText = selected_diff,
          hunk = row.kind == "hunk" and row.hunk or nil,
          selectedLinesText = row.kind == "change_line" and row.lineText or nil,
          lineRange = row.kind == "change_line" and { startLine = row.lineNumber, endLine = row.lineNumber } or nil,
          relatedTasks = related_tasks,
          relatedRequirements = related_requirements,
        }
        local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/context.js")
        local js = "const m = await import(" .. string.format("%q", url) .. "); "
          .. "const p = JSON.parse(process.argv[1]); "
          .. "const anchor = m.createDiffAnchor({ path: p.path, side: p.side, baseCommit: p.baseCommit, diffText: p.diffText, hunk: p.hunk, lineRange: p.lineRange }); "
          .. "const result = m.buildDiffQuestionPacket({ question: p.question, anchor, currentBaseCommit: p.baseCommit, currentDiffText: p.diffText, selectedDiffText: p.selectedDiffText, selectedLinesText: p.selectedLinesText, relatedTasks: p.relatedTasks, relatedRequirements: p.relatedRequirements }); "
          .. "process.stdout.write(JSON.stringify(result));"
        local packet_result = vim.system({
          cfg.node, "--input-type=module", "-e", js, vim.json.encode(payload),
        }, { cwd = root, text = true }):wait()
        if packet_result.code ~= 0 then
          vim.notify("Could not build Neolit context packet: " .. (packet_result.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local decoded_ok, packet = pcall(vim.json.decode, packet_result.stdout or "")
        if not decoded_ok or packet.status ~= "ready" then
          vim.notify("Diff context became stale; refresh and select it again.", vim.log.levels.WARN)
          refresh()
          return
        end
        copy_packet(packet.packet)
      end)
      return
    end

    local context_lines = {}
    local function add_context(value)
      if value and value ~= "" then context_lines[#context_lines + 1] = value end
    end
    local documentation_seen = {}
    local function add_task_context(task)
      add_context("TODO task: " .. task.text)
      add_context("Source: " .. tostring(task.key:match("^(.-)::")) .. ":" .. task.range.startLine)
      if #(task.description or {}) > 0 then
        add_context("Description:\n" .. table.concat(task.description, "\n"))
      end
      for _, path in ipairs(task.filePaths or {}) do add_context("File hint: " .. path) end
      for _, requirement in ipairs(task.resolvedRequirements or {}) do
        add_context("SPEC requirement " .. requirement.specPath .. "#" .. requirement.id .. ": " .. requirement.text)
      end
      for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
        add_context("Acceptance criterion " .. criterion.specPath .. "#" .. criterion.id .. ": " .. criterion.text)
      end
      for _, unresolved in ipairs(task.unresolvedReferences or {}) do
        add_context("Unresolved SPEC reference: " .. unresolved.path .. "#" .. table.concat(unresolved.ids or {}, ", "))
      end

      local workspace = vim.b[buf].neolit_workspace
      local payload = vim.json.encode({
        task = task,
        readmes = workspace and workspace.readmeContents or {},
        maxReadmeChars = 4000,
      })
      local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/context.js")
      local js = "const m = await import(" .. string.format("%q", url) .. "); "
        .. "const p = JSON.parse(process.argv[1]); "
        .. "process.stdout.write(JSON.stringify(m.selectTaskDocumentationContext(p)));"
      local result = vim.system({
        cfg.node, "--input-type=module", "-e", js, payload,
      }, { cwd = root, text = true }):wait()
      if result.code == 0 then
        local ok, docs = pcall(vim.json.decode, result.stdout or "")
        if ok then
          for _, current in ipairs(docs.currentBehavior or {}) do
            if not documentation_seen[current.readmePath] then
              documentation_seen[current.readmePath] = true
              add_context("Current shipped behavior — " .. current.readmePath .. ":\n" .. current.content)
            end
          end
          for _, diagnostic in ipairs(docs.diagnostics or {}) do
            add_context("Documentation context diagnostic: " .. diagnostic)
          end
        else
          add_context("README context unavailable: could not decode the planning context result.")
        end
      else
        add_context("README context unavailable: " .. (result.stderr or "planning context helper failed"))
      end
    end
    if row.kind == "planned_file" then
      add_context("Selected planned file: " .. row.path)
      add_task_context(row.task)
    elseif row.kind == "requirement" then
      add_context("Selected SPEC requirement " .. row.spec_path .. "#" .. row.requirement.id)
      add_context("Source: " .. row.spec_path .. ":" .. row.requirement.range.startLine)
      add_context(row.requirement.text)
      local workspace = vim.b[buf].neolit_workspace
      for _, task in ipairs(workspace.tasks or {}) do
        local linked = false
        for _, reference in ipairs(task.specReferences or {}) do
          if reference.path == row.spec_path and vim.tbl_contains(reference.ids or {}, row.requirement.id) then
            linked = true
            break
          end
        end
        if linked then
          add_context("")
          add_task_context(task)
        end
      end
    else
      add_context("Selected planning task")
      add_task_context(row.task)
    end
    copy_context(table.concat(context_lines, "\n"))
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  local function rerender_at(key)
    local workspace = vim.b[buf].neolit_workspace
    if not workspace then return end
    render(buf, root, workspace, expanded_files, expanded_dirs)
    if key then
      for line, row in pairs(vim.b[buf].neolit_rows or {}) do
        if row and row.key == key then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          return
        end
      end
    end
  end
  local function toggle_file()
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    if row.kind == "tree_directory" then
      expanded_dirs[row.path] = not (row.expanded ~= false)
      rerender_at()
      return
    end
    local file = row.file
    if row.kind == "hunk" then file = row.file end
    if not file then return end
    expanded_files[file.path] = not (expanded_files[file.path] ~= false)
    rerender_at("file:" .. file.path)
  end
  local function set_all_expanded(expanded)
    local workspace = vim.b[buf].neolit_workspace
    if not workspace then return end
    for _, file in ipairs(workspace.git.changedFiles or {}) do expanded_files[file.path] = expanded end
    rerender_at()
  end
  local related_ns = vim.api.nvim_create_namespace("neolit-related-" .. buf)
  local function highlight_related()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, related_ns, 0, -1)
    local rows = vim.b[buf].neolit_rows or {}
    local cursor = vim.api.nvim_win_get_cursor(0)
    local selected_row = rows[cursor[1]]
    if not selected_row or (selected_row.kind ~= "task" and selected_row.kind ~= "requirement") then return end
    local task_key = selected_row.kind == "task" and selected_row.task.key or nil
    local requirement_ref = selected_row.kind == "requirement"
      and (selected_row.spec_path .. "#" .. selected_row.requirement.id) or nil
    local linked_task_keys = {}
    if requirement_ref then
      for _, task in ipairs(vim.b[buf].neolit_workspace.tasks or {}) do
        for _, reference in ipairs(task.specReferences or {}) do
          if reference.path == selected_row.spec_path and vim.tbl_contains(reference.ids or {}, selected_row.requirement.id) then
            linked_task_keys[task.key] = true
          end
        end
      end
    end
    for line, candidate in pairs(rows) do
      local related = false
      if task_key then
        if candidate.kind == "file" then
          related = vim.tbl_contains(type(candidate.association) == "table" and candidate.association.taskKeys or {}, task_key)
        elseif candidate.kind == "hunk" or candidate.kind == "change_line" then
          related = vim.tbl_contains(type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation.candidateTaskKeys or {}, task_key)
        elseif candidate.kind == "planned_file" then
          related = type(candidate.task) == "table" and candidate.task.key == task_key
        elseif candidate.kind == "requirement" then
          for _, reference in ipairs(type(selected_row.task) == "table" and selected_row.task.specReferences or {}) do
            if reference.path == candidate.spec_path and vim.tbl_contains(reference.ids or {}, candidate.requirement.id) then
              related = true
              break
            end
          end
        end
      elseif requirement_ref then
        if candidate.kind == "task" then
          for _, reference in ipairs(type(candidate.task) == "table" and candidate.task.specReferences or {}) do
            if reference.path == selected_row.spec_path and vim.tbl_contains(reference.ids or {}, selected_row.requirement.id) then
              related = true
              break
            end
          end
        elseif candidate.kind == "file" then
          for _, key in ipairs(type(candidate.association) == "table" and candidate.association.taskKeys or {}) do
            if linked_task_keys[key] then related = true; break end
          end
        elseif candidate.kind == "hunk" or candidate.kind == "change_line" then
          related = vim.tbl_contains(type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation.candidateRequirementRefs or {}, requirement_ref)
        end
      end
      if related then
        vim.api.nvim_buf_add_highlight(buf, related_ns, "IncSearch", line - 1, 0, -1)
      end
    end
  end
  local refresh_group = vim.api.nvim_create_augroup("NeolitPlanning" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = refresh_group,
    buffer = buf,
    callback = highlight_related,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = refresh_group,
    callback = function(event)
      local name = vim.api.nvim_buf_get_name(event.buf)
      if name ~= "" and name:sub(1, #root + 1) == root .. "/" then refresh() end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = refresh_group,
    callback = refresh,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = refresh_group,
    buffer = buf,
    once = true,
    callback = function()
      refresh_revision = refresh_revision + 1
      if refresh_job then pcall(vim.fn.jobstop, refresh_job); refresh_job = nil end
      pcall(vim.api.nvim_del_augroup_by_id, refresh_group)
    end,
  })
  map("<CR>", selected, "Open selected diff, TODO, or SPEC requirement")
  map("za", toggle_file, "Expand/collapse selected diff file")
  map("zR", function() set_all_expanded(true) end, "Expand all diff files")
  map("zM", function() set_all_expanded(false) end, "Collapse all diff files")
  map("r", refresh, "Refresh Git-native planning workspace")
  map("x", ask_context, "Ask about selected diff/task and copy context for existing agent")
  map("K", show_details, "Show selected file, hunk, task, or requirement details")
  map("q", function()
    refresh_revision = refresh_revision + 1
    if refresh_job then pcall(vim.fn.jobstop, refresh_job); refresh_job = nil end
    pcall(vim.api.nvim_del_augroup_by_id, refresh_group)
    if vim.api.nvim_get_current_buf() == buf then vim.cmd("close") end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end, "Close planning workspace")
  refresh()
end

return M
