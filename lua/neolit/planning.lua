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

local function open_diff(root, file, selected_hunk, on_line_context, comparison_base, selected_line, diff_state)
  local path = safe_repo_path(root, file.path)
  local base_path = file.previousPath or file.path
  if not path or not safe_repo_path(root, base_path) then
    vim.notify("Refusing to open a diff path outside the repository: " .. tostring(file.path), vim.log.levels.ERROR)
    return
  end

  -- The right side is a single preview surface. Render the unified diff in
  -- that buffer instead of creating a second split for a side-by-side diff.
  local result = vim.system(diff_command(file, comparison_base), { cwd = root, text = true }):wait()
  local diff_lines = vim.split(result.stdout or "", "\n", { plain = true })
  if diff_lines[#diff_lines] == "" then table.remove(diff_lines) end
  if #diff_lines == 0 then diff_lines = { "(no diff available)" } end

  local win = diff_state and diff_state.preview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    local origin = diff_state and diff_state.tree_win or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(origin) then return end
    vim.api.nvim_set_current_win(origin)
    vim.cmd("rightbelow vsplit")
    win = vim.api.nvim_get_current_win()
    if diff_state then diff_state.preview_win = win end
  end

  local preview_buf = diff_state and diff_state.preview_buf
  if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(preview_buf, "neolit-diff-preview://" .. vim.fn.sha256(file.path):sub(1, 12))
    vim.bo[preview_buf].buftype = "nofile"
    vim.bo[preview_buf].bufhidden = "hide"
    vim.bo[preview_buf].swapfile = false
    vim.bo[preview_buf].filetype = "diff"
    if diff_state then diff_state.preview_buf = preview_buf end
  end
  vim.bo[preview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, diff_lines)
  vim.bo[preview_buf].modifiable = false
  vim.api.nvim_win_set_buf(win, preview_buf)
  vim.api.nvim_set_current_win(win)

  local target_line = 1
  if selected_hunk then
    for index, line in ipairs(diff_lines) do
      if line:match("^@@ ") then
        local old, old_count, new, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if tonumber(old) == selected_hunk.oldStart
          and (old_count == "" and 1 or tonumber(old_count)) == selected_hunk.oldLines
          and tonumber(new) == selected_hunk.newStart
          and (new_count == "" and 1 or tonumber(new_count)) == selected_hunk.newLines then
          target_line = index
          break
        end
      end
    end
  elseif selected_line then
    for index, line in ipairs(diff_lines) do
      if line:match("^@@ ") then target_line = index; break end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
end

local function render(buf, root, workspace, expanded_files, expanded_dirs, expanded_tasks, filter_mode_value)
  local lines, rows = {}, {}
  expanded_files, expanded_dirs, expanded_tasks = expanded_files or {}, expanded_dirs or {}, expanded_tasks or {}
  local function add(text, row)
    lines[#lines + 1] = text
    rows[#lines] = row
  end
  local filter_mode = filter_mode_value or "all"
  local changed_by_path, git_status, associations, hunk_associations = {}, {}, {}, {}
  for _, status in ipairs(workspace.git.status or {}) do git_status[status.path] = status end
  for _, file in ipairs(workspace.git.changedFiles or {}) do
    changed_by_path[file.path] = file
    git_status[file.path] = git_status[file.path] or { index = " ", worktree = "M" }
    if file.previousPath then git_status[file.previousPath] = git_status[file.previousPath] or { index = "R", worktree = " " } end
  end
  for _, association in ipairs(workspace.git.associations or {}) do associations[association.path] = association end
  for _, association in ipairs(workspace.git.hunkAssociations or {}) do hunk_associations[association.path .. "#" .. association.hunkIndex] = association end

  local tasks_by_doc, requirements_by_doc, doc_kind = {}, {}, {}
  for _, path in ipairs(workspace.readmes or {}) do doc_kind[path] = "README" end
  for _, spec in ipairs(workspace.specs or {}) do
    doc_kind[spec.path] = "SPEC"
    requirements_by_doc[spec.path] = spec.requirements or {}
  end
  for _, todo in ipairs(workspace.todos or {}) do doc_kind[todo.path] = "TODO" end
  for _, task in ipairs(workspace.tasks or {}) do
    local path = task.key:match("^(.-)::") or "TODO.md"
    tasks_by_doc[path] = tasks_by_doc[path] or {}
    tasks_by_doc[path][#tasks_by_doc[path] + 1] = task
  end
  local derived = type(workspace.derived) == "table" and workspace.derived or {}
  local derived_requirements = type(derived.requirements) == "table" and derived.requirements or {}
  local derived_tasks = type(derived.tasks) == "table" and derived.tasks or {}
  local requirement_states = {}
  for _, item in ipairs(derived_requirements) do
    requirement_states[item.specPath .. "#" .. item.requirementId] = item.state
  end

  local tree_root = { children = {}, files = {} }
  local seen_paths = {}
  local function insert_path(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or (path == ".." or path:sub(1, 3) == "../" or path:find("/../", 1, true) or path:sub(-3) == "/..") or seen_paths[path] then return end
    seen_paths[path] = true
    local node, parts = tree_root, vim.split(path, "/", { plain = true })
    for index = 1, #parts - 1 do
      local name = parts[index]
      node.children[name] = node.children[name] or { children = {}, files = {}, path = table.concat(parts, "/", 1, index) }
      node = node.children[name]
    end
    node.files[#node.files + 1] = { name = parts[#parts], path = path }
  end
  for _, path in ipairs(workspace.git.repositoryFiles or {}) do insert_path(path) end
  for _, path in ipairs(workspace.readmes or {}) do insert_path(path) end
  for _, spec in ipairs(workspace.specs or {}) do insert_path(spec.path) end
  for _, todo in ipairs(workspace.todos or {}) do insert_path(todo.path) end
  for _, file in ipairs(workspace.git.changedFiles or {}) do insert_path(file.path); if file.previousPath then insert_path(file.previousPath) end end

  local function subtree_affected(node)
    for _, file in ipairs(node.files) do if changed_by_path[file.path] then return true end end
    for _, child in pairs(node.children) do if subtree_affected(child) then return true end end
    return false
  end
  local function render_task(task, prefix, depth)
    local key = task.key
    local expanded = expanded_tasks[key] == true
    local task_state = derived_tasks[key]
    local state = type(task_state) == "table" and task_state.state or task.state or "planned"
    local checkbox = task.checked and "[x]" or "[ ]"
    local indent = string.rep("  ", depth)
    local expandable = #(task.filePaths or {}) + #(task.specReferences or {}) + #(task.description or {}) + #(task.unresolvedReferences or {}) > 0
    add(prefix .. indent .. (expandable and (expanded and "▾ " or "▸ ") or "• ") .. checkbox .. "  " .. state:upper() .. "  " .. task.text,
      { kind = "task", key = "task:" .. key, parent_key = "file:" .. (key:match("^(.-)::") or "TODO.md"), task = task, expanded = expanded,
        expandable = expandable })
    if not expanded then return end
    for _, path in ipairs(task.filePaths or {}) do
      add(prefix .. indent .. "   ↳  " .. path, { kind = "planned_file", path = path, parent_key = "task:" .. key, task = task })
    end
    for _, description in ipairs(task.description or {}) do
      add(prefix .. indent .. "   " .. description, { kind = "task_description", parent_key = "task:" .. key, task = task })
    end
    for _, reference in ipairs(task.specReferences or {}) do
      add(prefix .. indent .. "   §  " .. reference.path .. "  #" .. table.concat(reference.ids or {}, ", "),
        { kind = "task_reference", parent_key = "task:" .. key, reference = reference, task = task })
    end
    for _, unresolved in ipairs(task.unresolvedReferences or {}) do
      add(prefix .. indent .. "   !  unresolved " .. unresolved.path .. "#" .. table.concat(unresolved.ids or {}, ", "),
        { kind = "diagnostic", parent_key = "task:" .. key, diagnostic = unresolved })
    end
  end
  local function render_file(entry, prefix, branch)
    local child_prefix = prefix .. (branch == "└── " and "    " or "│   ")
    local path, changed = entry.path, changed_by_path[entry.path]
    local status, kind = git_status[path], doc_kind[path]
    local git_marker = status and (status.index .. status.worktree) or "  "
    local association = associations[path] or { state = "unplanned", taskKeys = {} }
    local marker = changed and (association.state == "unplanned" and "?" or (association.state == "partially-mapped" and "~" or "✓")) or " "
    local doc_summary = ""
    if kind == "TODO" then
      doc_summary = string.format("  · %d tasks", #(tasks_by_doc[path] or {}))
    elseif kind == "SPEC" then
      doc_summary = string.format("  · %d requirements", #(requirements_by_doc[path] or {}))
    elseif kind == "README" then
      for _, item in ipairs(workspace.readmeContents or {}) do
        if item.path == path then
          local heading = item.content:match("^%s*#%s+([^\r\n]+)")
          if heading then doc_summary = "  · " .. heading end
          break
        end
      end
    end
    local is_expanded = expanded_files[path] == true
    local has_children = changed ~= nil or (kind == "TODO" and #(tasks_by_doc[path] or {}) > 0)
      or (kind == "SPEC" and #(requirements_by_doc[path] or {}) > 0)
    add(prefix .. branch .. (has_children and (is_expanded and "▾ " or "▸ ") or "  ")
      .. (kind and ("[" .. kind .. "] ") or "") .. marker .. " " .. entry.name
      .. doc_summary .. (status and ("  [" .. git_marker .. "]") or ""),
      { kind = changed and "file" or (kind and "planning_document" or "repository_file"),
        key = "file:" .. path, path = path, file = changed, doc_kind = kind,
        association = association, git_status = status, expanded = is_expanded, expandable = has_children,
        parent_key = path:match("^(.*)/[^/]+$") and ("dir:" .. path:match("^(.*)/[^/]+$")) or nil })
    if not is_expanded then return end
    if kind == "TODO" then
      for _, task in ipairs(tasks_by_doc[path] or {}) do render_task(task, child_prefix, 0) end
    elseif kind == "SPEC" then
      for _, requirement in ipairs(requirements_by_doc[path] or {}) do
        local state = requirement_states[path .. "#" .. requirement.id] or "unmapped"
        local requirement_key = "requirement:" .. path .. "#" .. requirement.id
        add(child_prefix .. "§  " .. requirement.id .. "  " .. state:upper() .. "  " .. (requirement.text or ""),
          { kind = "requirement", key = requirement_key, parent_key = "file:" .. path,
            requirement = requirement, spec_path = path })
        for _, criterion in ipairs((function()
          for _, spec in ipairs(workspace.specs or {}) do
            if spec.path == path then
              local matches = {}
              for _, item in ipairs(spec.acceptanceCriteria or {}) do
                if vim.tbl_contains(item.requirementIds or {}, requirement.id) then matches[#matches + 1] = item end
              end
              return matches
            end
          end
          return {}
        end)()) do
          add(child_prefix .. "   ✓ " .. criterion.id .. "  " .. criterion.text,
            { kind = "acceptance_criterion", parent_key = requirement_key, criterion = criterion, spec_path = path })
        end
      end
    end
    if changed then
      for hunk_index, hunk in ipairs(changed.hunks or {}) do
        local hunk_association = hunk_associations[path .. "#" .. (hunk_index - 1)]
        local hunk_state = hunk_association and hunk_association.state or "unmapped"
        local hunk_key = "file:" .. path .. ":hunk:" .. hunk_index
        add(child_prefix .. (hunk_state == "attributed" and "✓" or hunk_state == "documentation" and "§" or "?")
          .. "  @@ -" .. hunk.oldStart .. "," .. hunk.oldLines .. " +" .. hunk.newStart .. "," .. hunk.newLines .. " @@ " .. (hunk.header or ""),
          { kind = "hunk", key = hunk_key, parent_key = "file:" .. path, file = changed, hunk = hunk,
            association = association, hunkAssociation = hunk_association })
        for change_index, change in ipairs(hunk.changes or {}) do
          add(child_prefix .. "   " .. (change.kind == "added" and "+" or "−") .. " " .. change.lineNumber .. "  " .. change.text,
            { kind = "change_line", key = hunk_key .. ":change:" .. change_index, parent_key = hunk_key,
              file = changed, hunk = hunk, hunkAssociation = hunk_association,
              lineNumber = change.lineNumber, lineText = change.text,
              side = change.kind == "added" and "working-tree" or "base" })
        end
      end
    end
  end

  add("NEOLIT  " .. vim.fn.fnamemodify(root, ":t") .. "  " .. workspace.git.branch
    .. " @ " .. (workspace.git.base or workspace.git.head):sub(1, 8)
    .. "   " .. (filter_mode == "affected" and "AFFECTED PATHS" or "ALL PATHS")
    .. "   [f filter] [? keys]", { kind = "header" })

  local function render_tree(node, ancestors, depth, parent_key)
    local entries = {}
    for name, child in pairs(node.children) do
      if filter_mode ~= "affected" or subtree_affected(child) then
        entries[#entries + 1] = { name = name, directory = true, node = child, path = child.path }
      end
    end
    for _, entry in ipairs(node.files) do
      if filter_mode ~= "affected" or changed_by_path[entry.path] then
        entries[#entries + 1] = { name = entry.name, path = entry.path, directory = false, entry = entry }
      end
    end
    table.sort(entries, function(a, b)
      if a.directory ~= b.directory then return a.directory end
      return a.name:lower() < b.name:lower()
    end)
    for index, entry in ipairs(entries) do
      local last = index == #entries
      local branch = last and "└── " or "├── "
      if entry.directory then
        local expanded = expanded_dirs[entry.path] == true
        add(ancestors .. branch .. (expanded and "▾ " or "▸ ") .. entry.name .. "/",
          { kind = "tree_directory", key = "dir:" .. entry.path, parent_key = parent_key, path = entry.path, expanded = expanded, expandable = true })
        if expanded then render_tree(entry.node, ancestors .. (last and "    " or "│   "), depth + 1, "dir:" .. entry.path) end
      else
        render_file(entry.entry, ancestors, branch)
      end
    end
  end
  render_tree(tree_root, "", 0, nil)
  if filter_mode == "affected" and #(workspace.git.changedFiles or {}) == 0 then
    add("└── (no affected paths)", { kind = "empty" })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local rich_ns = vim.api.nvim_create_namespace("neolit-tree-rich-" .. buf)
  vim.api.nvim_buf_clear_namespace(buf, rich_ns, 0, -1)
  local function mark(line, needle, group, occurrence)
    local text = lines[line]
    local from, to = nil, nil
    local offset = 1
    for _ = 1, occurrence or 1 do
      from, to = text:find(needle, offset, true)
      if not from then return end
      offset = to + 1
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, rich_ns, line - 1, from - 1, {
      end_col = to, hl_group = group, priority = 110,
    })
  end
  for line, row in pairs(rows) do
    if row then
      if row.kind == "header" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns, "Title", line - 1, 0, -1)
      elseif row.kind == "tree_directory" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns, "Directory", line - 1, 0, -1)
      elseif row.kind == "planning_document" then
        mark(line, "[" .. tostring(row.doc_kind) .. "]", "Special")
        if row.doc_kind == "TODO" then mark(line, "tasks", "Comment")
        elseif row.doc_kind == "SPEC" then mark(line, "requirements", "Comment") end
      elseif row.kind == "task" then
        mark(line, row.task.checked and "[x]" or "[ ]", row.task.checked and "DiagnosticOk" or "Comment")
        local task_state = derived_tasks[row.task.key]
        local state = (type(task_state) == "table" and task_state.state or row.task.state or "planned"):upper()
        local group = "DiagnosticInfo"
        if state:find("COMPLETE", 1, true) or state == "DONE" or state == "SATISFIED" then
          group = "DiagnosticOk"
        elseif state:find("BLOCK", 1, true) then
          group = "DiagnosticError"
        elseif state:find("PARTIAL", 1, true) or state:find("PROGRESS", 1, true) then
          group = "DiagnosticWarn"
        end
        mark(line, state, group)
      elseif row.kind == "requirement" then
        mark(line, row.requirement.id, "Identifier")
        local state = (requirement_states[row.spec_path .. "#" .. row.requirement.id] or "unmapped"):upper()
        mark(line, state, state == "SATISFIED" and "DiagnosticOk" or state == "PARTIAL" and "DiagnosticWarn" or "DiagnosticInfo")
      elseif row.kind == "acceptance_criterion" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns, "DiagnosticOk", line - 1, 0, -1)
      elseif row.kind == "repository_file" then
        local git = row.git_status
        if git then
          local code = "[" .. tostring(git.index or " ") .. tostring(git.worktree or " ") .. "]"
          local git_group = (git.index == "A" or git.worktree == "A" or git.index == "?" or git.worktree == "?") and "DiffAdd"
            or (git.index == "D" or git.worktree == "D") and "DiffDelete"
            or (git.index ~= " " or git.worktree ~= " ") and "DiffChange" or "Comment"
          mark(line, code, git_group)
        end
      elseif row.kind == "file" then
        if row.doc_kind then mark(line, "[" .. row.doc_kind .. "]", "Special") end
        local association = row.association or {}
        local group = association.state == "unplanned" and "DiagnosticWarn"
          or association.state == "partially-mapped" and "DiagnosticInfo" or "DiagnosticOk"
        mark(line, association.state == "unplanned" and "?" or association.state == "partially-mapped" and "~" or "✓", group)
        local git = row.git_status
        if git then
          local code = "[" .. tostring(git.index or " ") .. tostring(git.worktree or " ") .. "]"
          local git_group = (git.index == "A" or git.worktree == "A" or git.index == "?" or git.worktree == "?") and "DiffAdd"
            or (git.index == "D" or git.worktree == "D") and "DiffDelete"
            or (git.index ~= " " or git.worktree ~= " ") and "DiffChange" or "Comment"
          mark(line, code, git_group)
        end
      elseif row.kind == "hunk" then
        mark(line, "@@", "DiagnosticWarn")
      elseif row.kind == "diagnostic" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns, "DiagnosticWarn", line - 1, 0, -1)
      end
    end
  end
  vim.b[buf].neolit_rows = rows
  vim.b[buf].neolit_root = root
  return buf
end

function M.open(opts)
  opts = opts or {}

  -- The workspace is a singleton per Neovim instance. Reopening :Neolit
  -- should reveal the existing tree, not create another tree in the layout.
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      local existing = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(existing)
        and vim.api.nvim_buf_get_option(existing, "filetype") == "neolit-planning" then
        vim.api.nvim_set_current_tabpage(tabpage)
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end

  local ok, cfg, root, neolit_dir = pcall(find_core, opts)
  if not ok then vim.notify(cfg, vim.log.levels.ERROR); return end

  -- :vnew creates the tree buffer itself; do not leave an extra scratch
  -- buffer behind by creating one before the split.
  vim.cmd("topleft 34vnew")
  local buf = vim.api.nvim_get_current_buf()
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(tree_win, 34)
  vim.wo[tree_win].wrap = false
  -- Keep one permanent right-hand preview in this tab. Every document and
  -- ordinary file replaces its buffer; diffs temporarily use this same pane.
  vim.api.nvim_set_current_win(tree_win)
  vim.cmd("rightbelow vsplit")
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, "neolit://planning-" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "neolit-planning"

  local refresh_job
  local refresh_revision = 0
  local expanded_files = {}
  local expanded_dirs = {}
  local expanded_tasks = {}
  local diff_state = { tree_win = tree_win, preview_win = preview_win }
  local filter_mode = "all"

  local function open_in_preview(relative_path, line)
    local target = safe_repo_path(root, relative_path)
    if not target or vim.fn.filereadable(target) ~= 1 then
      vim.notify("File is no longer available: " .. tostring(relative_path), vim.log.levels.WARN)
      return
    end
    local win = diff_state.preview_win
    if not win or not vim.api.nvim_win_is_valid(win) then
      win = diff_state.tree_win
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      vim.api.nvim_set_current_win(win)
      vim.cmd("rightbelow vsplit")
      win = vim.api.nvim_get_current_win()
      diff_state.preview_win = win
    end
    local base_win = diff_state.base_win
    if base_win and vim.api.nvim_win_is_valid(base_win) then
      pcall(vim.api.nvim_win_call, base_win, function() vim.cmd("diffoff") end)
      pcall(vim.api.nvim_win_close, base_win, true)
      diff_state.base_win = nil
      diff_state.working_win = nil
    end
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
    local target_buf = vim.fn.bufadd(target)
    vim.fn.bufload(target_buf)
    vim.api.nvim_win_set_buf(win, target_buf)
    vim.api.nvim_set_current_win(win)
    if line then
      vim.api.nvim_win_set_cursor(win, { math.max(1, line), 0 })
    end
  end
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
          local open_paths = {}
          for _, file in ipairs(workspace.git.changedFiles or {}) do
            if expanded_files[file.path] == nil then expanded_files[file.path] = false end
            open_paths[#open_paths + 1] = file.path
          end
          for _, path in ipairs(workspace.readmes or {}) do
            if expanded_files[path] == nil then expanded_files[path] = true end
            open_paths[#open_paths + 1] = path
          end
          for _, spec in ipairs(workspace.specs or {}) do
            if expanded_files[spec.path] == nil then expanded_files[spec.path] = true end
            open_paths[#open_paths + 1] = spec.path
          end
          for _, todo in ipairs(workspace.todos or {}) do
            if expanded_files[todo.path] == nil then expanded_files[todo.path] = true end
            open_paths[#open_paths + 1] = todo.path
          end
          for _, task in ipairs(workspace.tasks or {}) do
            if expanded_tasks[task.key] == nil then expanded_tasks[task.key] = true end
          end
          for _, path in ipairs(open_paths) do
            local parent = path:match("^(.*)/[^/]+$")
            while parent do
              if expanded_dirs[parent] == nil then expanded_dirs[parent] = true end
              parent = parent:match("^(.*)/[^/]+$")
            end
          end
          render(buf, root, workspace, expanded_files, expanded_dirs, expanded_tasks, filter_mode)
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

  local rerender_at

  local function selected()
    local workspace = vim.b[buf].neolit_workspace
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    if row.kind == "tree_directory" then
      expanded_dirs[row.path] = true
      rerender_at(row.key)
    elseif row.kind == "planning_document" then
      if row.expandable and not row.expanded then
        expanded_files[row.path] = true
        rerender_at(row.key)
        return
      end
      local target = safe_repo_path(root, row.path)
      if target then open_in_preview(row.path) end
    elseif row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, ask_line_context, workspace.git.base, nil, diff_state)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          open_in_preview(row.path)
        else
          vim.notify("Repository file is no longer available: " .. row.path, vim.log.levels.WARN)
        end
      end
    elseif row.kind == "task" then
      if not row.expanded then
        expanded_tasks[row.task.key] = true
        rerender_at(row.key)
        return
      end
      local task = row.task
      local todo_path = task.key:match("^(.-)::")
      local todo_file = todo_path and safe_repo_path(root, todo_path)
      if todo_file then
        open_in_preview(todo_path, task.range.startLine)
      end
    elseif row.kind == "requirement" then
      local req = row.requirement
      local spec_path = row.spec_path
      local spec_file = spec_path and safe_repo_path(root, spec_path)
      if spec_file then
        open_in_preview(spec_path, req.range.startLine)
      end
    elseif row.kind == "planned_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, ask_line_context, workspace.git.base, nil, diff_state)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          open_in_preview(row.path)
        else
          vim.notify("Planned file does not exist yet: " .. row.path, vim.log.levels.INFO)
        end
      end
    elseif row.kind == "file" then
      if row.expandable and not row.expanded then
        expanded_files[row.path] = true
        rerender_at(row.key)
        return
      end
      open_diff(root, row.file, nil, ask_line_context, workspace and workspace.git.base, nil, diff_state)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_diff(root, row.file, row.hunk, ask_line_context, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, diff_state)
    end
  end

  local function preview_row(row)
    if not row then return end
    local workspace = vim.b[buf].neolit_workspace
    if row.kind == "planning_document" then
      open_in_preview(row.path)
    elseif row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, ask_line_context, workspace.git.base, nil, diff_state)
      else
        open_in_preview(row.path)
      end
    elseif row.kind == "file" then
      open_diff(root, row.file, nil, ask_line_context, workspace and workspace.git.base, nil, diff_state)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_diff(root, row.file, row.hunk, ask_line_context, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, diff_state)
    elseif row.kind == "task" then
      local path = row.task.key:match("^(.-)::")
      if path then open_in_preview(path, row.task.range.startLine) end
    elseif row.kind == "requirement" then
      open_in_preview(row.spec_path, row.requirement.range.startLine)
    elseif row.kind == "planned_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then open_diff(root, changed, nil, ask_line_context, workspace.git.base, nil, diff_state)
      else open_in_preview(row.path) end
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
    if row.kind == "planning_document" then
      local workspace = vim.b[buf].neolit_workspace
      put(row.doc_kind .. " DOCUMENT")
      put(row.path)
      if row.doc_kind == "TODO" then
        local count = 0
        for _, task in ipairs(workspace.tasks or {}) do
          if task.key:match("^(.-)::") == row.path then count = count + 1 end
        end
        put("Tasks: " .. count)
      elseif row.doc_kind == "SPEC" then
        for _, spec in ipairs(workspace.specs or {}) do
          if spec.path == row.path then put("Requirements: " .. #(spec.requirements or {})); break end
        end
      elseif row.doc_kind == "README" then
        for _, item in ipairs(workspace.readmeContents or {}) do
          if item.path == row.path then put("Characters: " .. #item.content); break end
        end
      end
    elseif row.kind == "file" then
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
    if not row or (row.kind ~= "tree_directory" and row.kind ~= "repository_file" and row.kind ~= "planning_document" and row.kind ~= "file" and row.kind ~= "hunk" and row.kind ~= "change_line" and row.kind ~= "requirement" and row.kind ~= "task" and row.kind ~= "planned_file") then
      vim.notify("Select a task, requirement, planned file, or changed file first")
      return
    end
    if row.kind == "planning_document" then
      copy_context("Selected " .. tostring(row.doc_kind) .. " document: " .. row.path .. "\nAsk about this document and inspect its current contents in the working tree.")
      return
    elseif row.kind == "tree_directory" then
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
  rerender_at = function(key)
    local workspace = vim.b[buf].neolit_workspace
    if not workspace then return end
    render(buf, root, workspace, expanded_files, expanded_dirs, expanded_tasks, filter_mode)
    if key then
      for line, row in pairs(vim.b[buf].neolit_rows or {}) do
        if row and row.key == key then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          return
        end
      end
    end
  end
  local function current_row()
    return vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function toggle_node(row, expanded)
    if not row then return end
    if expanded == nil then expanded = not row.expanded end
    if row.kind == "tree_directory" then
      expanded_dirs[row.path] = expanded
      rerender_at(row.key)
    elseif row.kind == "task" then
      expanded_tasks[row.task.key] = expanded
      rerender_at(row.key)
    elseif row.kind == "file" or row.kind == "planning_document" then
      expanded_files[row.path or (row.file and row.file.path)] = expanded
      rerender_at(row.key)
    elseif row.kind == "hunk" then
      return
    end
  end
  local function toggle_node_at_cursor()
    toggle_node(current_row())
  end
  local function expand_node_at_cursor()
    local row = current_row()
    if row and (row.kind == "tree_directory" or row.kind == "task" or row.kind == "file" or row.kind == "planning_document") then
      toggle_node(row, true)
    end
  end
  local function collapse_node_at_cursor()
    local row = current_row()
    if not row then return end
    if row.kind == "tree_directory" or row.kind == "task" or row.kind == "file" or row.kind == "planning_document" then
      if row.expanded then
        toggle_node(row, false)
        return
      end
    end
    local parent_key = row.parent_key
    if not parent_key then return end
    for line, parent in pairs(vim.b[buf].neolit_rows or {}) do
      if parent and parent.key == parent_key then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        return
      end
    end
  end
  local function set_all_expanded(expanded)
    local workspace = vim.b[buf].neolit_workspace
    if not workspace then return end
    for _, path in ipairs(workspace.git.repositoryFiles or {}) do
      local parent = path:match("^(.*)/[^/]+$")
      while parent do
        expanded_dirs[parent] = expanded
        parent = parent:match("^(.*)/[^/]+$")
      end
      expanded_files[path] = expanded
    end
    for _, file in ipairs(workspace.git.changedFiles or {}) do
      expanded_files[file.path] = expanded
      local parent = file.path:match("^(.*)/[^/]+$")
      while parent do expanded_dirs[parent] = expanded; parent = parent:match("^(.*)/[^/]+$") end
    end
    for _, path in ipairs(workspace.readmes or {}) do expanded_files[path] = expanded end
    for _, spec in ipairs(workspace.specs or {}) do expanded_files[spec.path] = expanded end
    for _, todo in ipairs(workspace.todos or {}) do expanded_files[todo.path] = expanded end
    for _, task in ipairs(workspace.tasks or {}) do expanded_tasks[task.key] = expanded end
    rerender_at()
  end
  local function set_fold_level(mode)
    local rows = vim.b[buf].neolit_rows or {}
    local by_key, candidates = {}, {}
    for _, row in pairs(rows) do if row and row.key then by_key[row.key] = row end end
    local function depth(row)
      local value, parent_key, seen = 0, row.parent_key, {}
      while parent_key and not seen[parent_key] do
        seen[parent_key] = true
        local parent = by_key[parent_key]
        if not parent then break end
        value = value + 1
        parent_key = parent.parent_key
      end
      return value
    end
    for _, row in pairs(rows) do
      if row and row.expandable then
        local ancestors_open, parent_key, seen = true, row.parent_key, {}
        while parent_key and not seen[parent_key] do
          seen[parent_key] = true
          local parent = by_key[parent_key]
          if not parent then break end
          if parent.expandable and not parent.expanded then ancestors_open = false; break end
          parent_key = parent.parent_key
        end
        if ancestors_open then
          candidates[#candidates + 1] = { row = row, depth = depth(row), expanded = row.expanded == true }
        end
      end
    end
    local target_depth
    for _, item in ipairs(candidates) do
      local eligible = mode == "open" and not item.expanded or mode == "close" and item.expanded
      if eligible and (not target_depth or item.depth < target_depth) then target_depth = item.depth end
    end
    if not target_depth then return end
    local first_key
    for _, item in ipairs(candidates) do
      if item.depth == target_depth and ((mode == "open" and not item.expanded) or (mode == "close" and item.expanded)) then
        local row = item.row
        if row.kind == "tree_directory" then expanded_dirs[row.path] = mode == "open"
        elseif row.kind == "task" then expanded_tasks[row.task.key] = mode == "open"
        else expanded_files[row.path or (row.file and row.file.path)] = mode == "open" end
        first_key = first_key or row.key
      end
    end
    rerender_at(first_key)
  end
  local related_ns = vim.api.nvim_create_namespace("neolit-related-" .. buf)
  local function highlight_related()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, related_ns, 0, -1)
    local rows = vim.b[buf].neolit_rows
    if type(rows) ~= "table" then return end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local selected_row = rows[cursor[1]]
    if type(selected_row) ~= "table"
      or (selected_row.kind ~= "task" and selected_row.kind ~= "requirement") then return end

    local selected_task = type(selected_row.task) == "table" and selected_row.task or nil
    local selected_requirement = type(selected_row.requirement) == "table" and selected_row.requirement or nil
    local task_key = selected_row.kind == "task" and selected_task and selected_task.key or nil
    local requirement_ref
    if selected_row.kind == "requirement" and type(selected_row.spec_path) == "string"
      and selected_requirement and type(selected_requirement.id) == "string" then
      requirement_ref = selected_row.spec_path .. "#" .. selected_requirement.id
    end

    local function list(value)
      return type(value) == "table" and value or {}
    end
    local linked_task_keys = {}
    local workspace = vim.b[buf].neolit_workspace
    if requirement_ref and type(workspace) == "table" then
      for _, task in ipairs(list(workspace.tasks)) do
        if type(task) == "table" then
          for _, reference in ipairs(list(task.specReferences)) do
            if type(reference) == "table" and reference.path == selected_row.spec_path
              and vim.tbl_contains(list(reference.ids), selected_requirement.id) then
              if type(task.key) == "string" then linked_task_keys[task.key] = true end
            end
          end
        end
      end
    end

    for line, candidate in pairs(rows) do
      if type(candidate) == "table" then
        local related = false
        if task_key then
          if candidate.kind == "file" then
            local association = type(candidate.association) == "table" and candidate.association or nil
            related = vim.tbl_contains(list(association and association.taskKeys), task_key)
          elseif candidate.kind == "hunk" or candidate.kind == "change_line" then
            local association = type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation or nil
            related = vim.tbl_contains(list(association and association.candidateTaskKeys), task_key)
          elseif candidate.kind == "planned_file" then
            local task = type(candidate.task) == "table" and candidate.task or nil
            related = task ~= nil and task.key == task_key
          elseif candidate.kind == "requirement" and selected_task then
            for _, reference in ipairs(list(selected_task.specReferences)) do
              if type(reference) == "table" and type(candidate.requirement) == "table"
                and reference.path == candidate.spec_path
                and vim.tbl_contains(list(reference.ids), candidate.requirement.id) then
                related = true
                break
              end
            end
          end
        elseif requirement_ref then
          if candidate.kind == "task" then
            local task = type(candidate.task) == "table" and candidate.task or nil
            for _, reference in ipairs(list(task and task.specReferences)) do
              if type(reference) == "table" and reference.path == selected_row.spec_path
                and vim.tbl_contains(list(reference.ids), selected_requirement.id) then
                related = true
                break
              end
            end
          elseif candidate.kind == "file" then
            local association = type(candidate.association) == "table" and candidate.association or nil
            for _, key in ipairs(list(association and association.taskKeys)) do
              if linked_task_keys[key] then related = true; break end
            end
          elseif candidate.kind == "hunk" or candidate.kind == "change_line" then
            local association = type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation or nil
            related = vim.tbl_contains(list(association and association.candidateRequirementRefs), requirement_ref)
          end
        end
        if related then
          vim.api.nvim_buf_add_highlight(buf, related_ns, "IncSearch", line - 1, 0, -1)
        end
      end
    end
  end
  local refresh_group = vim.api.nvim_create_augroup("NeolitPlanning" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = refresh_group,
    buffer = buf,
    callback = function()
      highlight_related()
      preview_row(current_row())
    end,
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
  map("za", toggle_node_at_cursor, "Toggle selected folder, document, task, or diff file")
  map("l", expand_node_at_cursor, "Expand selected folder, task, or diff file")
  map("h", collapse_node_at_cursor, "Collapse selected node or move to parent")
  map("zc", function() toggle_node(current_row(), false) end, "Close selected tree node")
  map("zo", function() toggle_node(current_row(), true) end, "Open selected tree node")
  map("F", toggle_node_at_cursor, "Toggle selected tree node")
  map("zr", function() set_fold_level("open") end, "Open one visible tree level")
  map("zm", function() set_fold_level("close") end, "Close one visible tree level")
  map("zR", function()
    set_all_expanded(true)
    for _, task in ipairs((vim.b[buf].neolit_workspace or {}).tasks or {}) do expanded_tasks[task.key] = true end
    rerender_at()
  end, "Expand all folders, documents, tasks, and diffs")
  map("zM", function()
    set_all_expanded(false)
    for _, task in ipairs((vim.b[buf].neolit_workspace or {}).tasks or {}) do expanded_tasks[task.key] = false end
    rerender_at()
  end, "Collapse all folders, documents, tasks, and diffs")
  map("f", function()
    local row = current_row()
    filter_mode = filter_mode == "all" and "affected" or "all"
    if filter_mode == "affected" then
      local workspace = vim.b[buf].neolit_workspace or {}
      for _, file in ipairs(workspace.git and workspace.git.changedFiles or {}) do
        local parent = file.path:match("^(.*)/[^/]+$")
        while parent do expanded_dirs[parent] = true; parent = parent:match("^(.*)/[^/]+$") end
      end
    end
    rerender_at(row and row.key)
  end, "Show all repository paths / affected paths only")
  map("r", refresh, "Refresh Git-native planning workspace")
  map("x", ask_context, "Ask about selected diff/task and copy context for existing agent")
  map("K", show_details, "Show selected file, hunk, task, or requirement details")
  map("?", function()
    vim.notify("Tree: <CR> expand/open · za toggle · zo open · zc close · h/l expand/collapse-or-parent · zr/zm one level · zR/zM all · f affected-only · x context · K details · r refresh · q close", vim.log.levels.INFO)
  end, "Show Neolit tree keys")
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
