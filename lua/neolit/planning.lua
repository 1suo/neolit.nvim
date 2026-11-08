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

local function open_diff(root, file, selected_hunk, comparison_base, selected_line, diff_state, focus)
  local original_win = vim.api.nvim_get_current_win()
  local function restore_focus()
    if focus then return end
    if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
  end
  local path = safe_repo_path(root, file.path)
  local base_path = file.previousPath or file.path
  if not path or not safe_repo_path(root, base_path) then
    vim.notify("Refusing to open a diff path outside the repository: " .. tostring(file.path), vim.log.levels.ERROR)
    return
  end

  local win = diff_state and diff_state.preview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    local origin = diff_state and diff_state.tree_win or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(origin) then return end
    vim.api.nvim_set_current_win(origin)
    vim.cmd("rightbelow vsplit")
    win = vim.api.nvim_get_current_win()
    if diff_state then diff_state.preview_win = win end
  end

  local view = diff_state and diff_state.diff_view or "side_by_side"
  if view == "side_by_side" then
    local base_win = diff_state and diff_state.base_win
    if not base_win or not vim.api.nvim_win_is_valid(base_win) then
      -- Create the comparison pane explicitly from the preview window, then
      -- restore the working pane as the stable preview target.
      vim.api.nvim_set_current_win(win)
      vim.cmd("leftabove vsplit")
      base_win = vim.api.nvim_get_current_win()
      if diff_state then
        diff_state.base_win = base_win
        diff_state.working_win = win
      end
      vim.api.nvim_set_current_win(win)
    end

    local base_buf = diff_state and diff_state.base_buf
    if not base_buf or not vim.api.nvim_buf_is_valid(base_buf) then
      base_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(base_buf, "neolit-diff-base://" .. vim.fn.sha256(file.path):sub(1, 12))
      vim.bo[base_buf].buftype = "nofile"
      vim.bo[base_buf].bufhidden = "hide"
      vim.bo[base_buf].swapfile = false
      if diff_state then diff_state.base_buf = base_buf end
    end
    local base_result = vim.system({
      "git", "show", (comparison_base or "HEAD") .. ":" .. base_path,
    }, { cwd = root, text = true }):wait()
    local base_lines = base_result.code == 0
      and vim.split(base_result.stdout or "", "\n", { plain = true })
      or { "" }
    if base_lines[#base_lines] == "" and #base_lines > 1 then table.remove(base_lines) end

    -- Leave diff mode before replacing either window's buffer. Otherwise
    -- Neovim retains the old diff participants while the new buffers are
    -- attached, eventually hitting E96 during ordinary tree hover.
    pcall(vim.api.nvim_win_call, base_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)

    vim.bo[base_buf].modifiable = true
    vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_lines)
    vim.bo[base_buf].modifiable = false
    vim.bo[base_buf].filetype = vim.filetype.match({ filename = base_path }) or ""
    vim.api.nvim_win_set_buf(base_win, base_buf)

    local working_buf
    if vim.fn.filereadable(path) == 1 then
      local existing_buf = vim.fn.bufnr(path)
      working_buf = vim.fn.bufadd(path)
      vim.fn.bufload(working_buf)
      -- Files first encountered through hover remain real, editable buffers,
      -- but stay out of the user's ordinary listed-buffer collection.
      if existing_buf < 0 then vim.bo[working_buf].buflisted = false end
    else
      working_buf = diff_state and diff_state.deleted_buf
      if not working_buf or not vim.api.nvim_buf_is_valid(working_buf) then
        working_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(working_buf, "neolit-diff-empty://" .. vim.fn.sha256(file.path):sub(1, 12))
        vim.bo[working_buf].buftype = "nofile"
        vim.bo[working_buf].bufhidden = "hide"
        vim.bo[working_buf].swapfile = false
        if diff_state then diff_state.deleted_buf = working_buf end
      end
      vim.bo[working_buf].modifiable = true
      vim.api.nvim_buf_set_lines(working_buf, 0, -1, false, { "" })
      vim.bo[working_buf].modifiable = false
    end
    vim.api.nvim_win_set_buf(win, working_buf)
    pcall(vim.api.nvim_win_call, base_win, function() vim.cmd("diffthis") end)
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffthis") end)

    -- Keep the two actual diff windows synchronized for both scrolling and
    -- cursor movement, regardless of which side currently has focus.
    for _, diff_win in ipairs({ base_win, win }) do
      vim.wo[diff_win].wrap = vim.go.wrap
      vim.wo[diff_win].scrollbind = true
      vim.wo[diff_win].cursorbind = true
    end

    local base_line = selected_hunk and selected_hunk.oldStart or 1
    local working_line = selected_hunk and selected_hunk.newStart or (selected_line and selected_line.lineNumber or 1)
    pcall(vim.api.nvim_win_set_cursor, base_win, { math.max(1, base_line), 0 })
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, working_line), 0 })
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("syncbind") end)
    if focus then vim.api.nvim_set_current_win(win) else restore_focus() end
    return
  end

  local base_win = diff_state and diff_state.base_win
  if base_win and vim.api.nvim_win_is_valid(base_win) then
    pcall(vim.api.nvim_win_call, base_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_win_close, base_win, true)
    if diff_state then diff_state.base_win = nil end
  end

  local result = vim.system(diff_command(file, comparison_base), { cwd = root, text = true }):wait()
  local diff_lines = vim.split(result.stdout or "", "\n", { plain = true })
  if diff_lines[#diff_lines] == "" then table.remove(diff_lines) end
  if #diff_lines == 0 then diff_lines = { "(no diff available)" } end

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
  vim.wo[win].wrap = vim.go.wrap
  if focus then vim.api.nvim_set_current_win(win) else restore_focus() end

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
local function collect_affected_paths(workspace)
  local affected = {}
  local tasks_by_key = {}
  for _, task in ipairs(workspace.tasks or {}) do tasks_by_key[task.key] = task end
  for _, file in ipairs(workspace.git.changedFiles or {}) do
    affected[file.path] = true
    if file.previousPath then affected[file.previousPath] = true end
  end
  local function include_task(task_key)
    local task = tasks_by_key[task_key]
    if not task then return end
    local todo_path = task.key:match("^(.-)::")
    if todo_path then affected[todo_path] = true end
    for _, requirement in ipairs(task.resolvedRequirements or {}) do
      affected[requirement.specPath] = true
    end
  end
  for _, association in ipairs(workspace.git.associations or {}) do
    for _, task_key in ipairs(association.taskKeys or {}) do include_task(task_key) end
  end
  for _, association in ipairs(workspace.git.hunkAssociations or {}) do
    for _, task_key in ipairs(association.candidateTaskKeys or {}) do include_task(task_key) end
    for _, ref in ipairs(association.candidateRequirementRefs or {}) do
      local spec_path = ref:match("^(.-)#")
      if spec_path then affected[spec_path] = true end
    end
  end
  return affected
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

  local tasks_by_doc, tasks_by_key, requirements_by_doc, doc_kind = {}, {}, {}, {}
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
    tasks_by_key[task.key] = task
  end
  local derived = type(workspace.derived) == "table" and workspace.derived or {}
  local derived_requirements = type(derived.requirements) == "table" and derived.requirements or {}
  local derived_tasks = type(derived.tasks) == "table" and derived.tasks or {}
  local requirement_states, requirement_projections = {}, {}
  for _, item in ipairs(derived_requirements) do
    local ref = item.specPath .. "#" .. item.requirementId
    requirement_states[ref] = item.state
    requirement_projections[ref] = item
  end
  local diagnostics_by_task = {}
  for _, diagnostic in ipairs(workspace.diagnostics or {}) do
    if diagnostic.taskKey then
      diagnostics_by_task[diagnostic.taskKey] = diagnostics_by_task[diagnostic.taskKey] or {}
      table.insert(diagnostics_by_task[diagnostic.taskKey], diagnostic)
    end
  end
  local function find_changed_file(path)
    for _, file in ipairs(workspace.git.changedFiles or {}) do
      if file.path == path then return file end
    end
  end
  local function find_changed_hunk(file, hunk_index)
    if type(file) ~= "table" or type(hunk_index) ~= "number" then return nil end
    return file.hunks and file.hunks[hunk_index + 1] or nil
  end
  local function file_association_label(state)
    if state == "unplanned" then return "UNPLANNED" end
    if state == "partially-mapped" then return "PARTIAL" end
    if state == "unresolved" then return "AMBIGUOUS" end
    if state == "documentation" then return "DOC" end
    return "CANDIDATE"
  end
  local function hunk_review_summary(review)
    local candidates = {}
    for _, task_key in ipairs(review.candidateTaskKeys or {}) do
      local task = tasks_by_key[task_key]
      candidates[#candidates + 1] = task and task.text or task_key
    end
    for _, ref in ipairs(review.candidateRequirementRefs or {}) do
      candidates[#candidates + 1] = ref
    end
    local summary = tostring(review.state):upper() .. " · " .. tostring(review.reason)
    if #candidates > 0 then summary = summary .. " · candidates: " .. table.concat(candidates, "; ") end
    return summary
  end
  local function state_reason(state, projection)
    if state == "unmapped" then return "No valid SPEC requirement reference" end
    if state == "blocked" then return "Blocked by an explicit blocker" end
    if state == "planned" then return "No changed file matches this task's file hints" end
    if state == "in-progress" then
      return #(projection and projection.hunkReviews or {}) > 0
        and "Changed hunks are candidates, not proof of implementation"
        or "File hints match; no precise hunk attribution"
    end
    if state == "implemented" then return "Implementation evidence exists; verification is incomplete" end
    if state == "verified" then return "Current diff has matching passing verification evidence" end
    return "Derived from Markdown and current Git evidence"
  end

  local function requirement_state_reason(state, linked_tasks)
    if state == "unplanned" then return "No TODO task references this requirement" end
    if state == "unmapped" then return "A linked task has an unresolved SPEC reference" end
    if state == "blocked" then return "A linked task has an explicit blocker" end
    if state == "planned" then return "Linked tasks have no matching changed-file evidence" end
    if state == "in-progress" then return "Linked task paths changed; source-code hunks remain candidates, not proof" end
    if state == "implemented" then return "Implementation evidence exists; verification is incomplete" end
    if state == "verified" then return "Linked tasks and applicable criteria have current passing evidence" end
    return "Derived from linked tasks and current Git evidence"
  end

  local affected_paths = collect_affected_paths(workspace)

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
    for _, file in ipairs(node.files) do if affected_paths[file.path] then return true end end
    for _, child in pairs(node.children) do if subtree_affected(child) then return true end end
    return false
  end
  local function render_task(task, prefix, depth)
    local key = task.key
    local expanded = expanded_tasks[key] == true
    local projection = derived_tasks[key]
    local state = type(projection) == "table" and projection.state or task.state or "planned"
    local checkbox = task.checked and "[x]" or "[ ]"
    local indent = string.rep(" ", depth)
    local reviews = type(projection) == "table" and projection.hunkReviews or {}
    local changed_paths = type(projection) == "table" and projection.changedPaths or {}
    local diagnostics = diagnostics_by_task[key] or {}
    local expandable = #(task.filePaths or {}) + #(task.specReferences or {})
      + #(task.description or {}) + #(task.agentNotes or {}) + #(task.resolvedRequirements or {})
      + #(task.resolvedAcceptanceCriteria or {}) + #reviews + #changed_paths + #diagnostics > 0
    add(prefix .. indent .. (expandable and (expanded and "- " or "+ ") or "")
      .. checkbox .. " " .. state:upper() .. " " .. task.text,
      { kind = "task", key = "task:" .. key, parent_key = "file:" .. (key:match("^(.-)::") or "TODO.md"),
        task = task, projection = projection, expanded = expanded, expandable = expandable })
    if not expanded then return end
    if #(task.headingPath or {}) > 0 then
      add(prefix .. indent .. " SECTION " .. table.concat(task.headingPath, " / "),
        { kind = "task_heading", parent_key = "task:" .. key, task = task })
    end
    add(prefix .. indent .. " " .. state_reason(state, projection),
      { kind = "task_explanation", parent_key = "task:" .. key, task = task, projection = projection })
    for _, path in ipairs(task.filePaths or {}) do
      add(prefix .. indent .. " FILE " .. path,
        { kind = "planned_file", path = path, parent_key = "task:" .. key, task = task })
    end
    for _, description in ipairs(task.description or {}) do
      add(prefix .. indent .. " " .. description,
        { kind = "task_description", parent_key = "task:" .. key, task = task })
    end
    for _, note in ipairs(task.agentNotes or {}) do
      add(prefix .. indent .. " AGENT " .. note,
        { kind = "task_agent_note", parent_key = "task:" .. key, task = task })
    end
    for _, requirement in ipairs(task.resolvedRequirements or {}) do
      add(prefix .. indent .. " SPEC " .. requirement.specPath .. "#" .. requirement.id .. " " .. requirement.text,
        { kind = "task_requirement", parent_key = "task:" .. key, requirement = requirement, task = task })
    end
    for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
      local ref = criterion.specPath .. "#" .. criterion.id
      local verified = false
      for _, item in ipairs(projection and projection.acceptanceCriteria or {}) do
        if item.ref == ref then verified = item.verified == true; break end
      end
      add(prefix .. indent .. " AC " .. ref .. " " .. (verified and "VERIFIED " or "UNVERIFIED ") .. criterion.text,
        { kind = "task_acceptance", parent_key = "task:" .. key, criterion = criterion, task = task, verified = verified })
    end
    if #task.resolvedRequirements == 0 then
      for _, reference in ipairs(task.specReferences or {}) do
        add(prefix .. indent .. " SPEC? " .. reference.path .. "#" .. table.concat(reference.ids or {}, ", "),
          { kind = "task_reference", parent_key = "task:" .. key, reference = reference, task = task })
      end
    end
    for _, path in ipairs(changed_paths) do
      local file = find_changed_file(path)
      if file then
        add(prefix .. indent .. " CHANGE " .. path,
          { kind = "task_change", parent_key = "task:" .. key, file = file, task = task })
      end
    end
    for _, review in ipairs(reviews) do
      local file = find_changed_file(review.path)
      local hunk_association
      for _, item in ipairs(workspace.git.hunkAssociations or {}) do
        if item.path == review.path and item.hunkIndex == review.hunkIndex then hunk_association = item; break end
      end
      add(prefix .. indent .. " HUNK " .. review.path .. "#" .. tostring(review.hunkIndex + 1)
        .. " " .. hunk_review_summary(review),
        { kind = "task_hunk", parent_key = "task:" .. key, file = file,
          hunk = find_changed_hunk(file, review.hunkIndex), hunkIndex = review.hunkIndex,
          hunkAssociation = hunk_association, task = task })
    end
    for _, diagnostic in ipairs(diagnostics) do
      add(prefix .. indent .. " ! " .. diagnostic.message,
        { kind = "diagnostic", parent_key = "task:" .. key, diagnostic = diagnostic })
    end
  end
  local function render_file(entry, prefix, branch)
    local child_prefix = prefix .. (branch == "└" and "  " or "│ ")
    local child_depth = 1
    local path, changed = entry.path, changed_by_path[entry.path]
    local status, kind = git_status[path], doc_kind[path]
    local git_marker = status and (status.index .. status.worktree) or "  "
    local association = associations[path] or { state = "unplanned", taskKeys = {} }
    local marker = changed and (
      association.state == "unplanned" and "?"
      or association.state == "documentation" and "D"
      or "~"
    ) or ""
    local is_expanded = expanded_files[path] == true
    local file_association = associations[path]
    local file_hunks = {}
    for _, item in ipairs(workspace.git.hunkAssociations or {}) do
      if item.path == path then file_hunks[#file_hunks + 1] = item end
    end
    local has_children = (kind == "TODO" and #(tasks_by_doc[path] or {}) > 0)
      or (kind == "SPEC" and #(requirements_by_doc[path] or {}) > 0)
      or (changed ~= nil and ((file_association and #(file_association.taskKeys or {}) > 0) or #file_hunks > 0))
    add(prefix .. branch .. (has_children and (is_expanded and "-" or "+") or " ")
      .. (kind and kind ~= "README" and ("[" .. kind .. "] ") or "")
      .. entry.name
      .. (marker ~= "" and (" " .. marker) or "")
      .. (status and (" [" .. git_marker .. "]") or ""),
      { kind = changed and "file" or (kind and "planning_document" or "repository_file"),
        key = "file:" .. path, path = path, file = changed, doc_kind = kind,
        association = association, git_status = status, expanded = is_expanded, expandable = has_children,
        parent_key = path:match("^(.*)/[^/]+$") and ("dir:" .. path:match("^(.*)/[^/]+$")) or nil })
    if not is_expanded then return end
    if kind == "TODO" then
      for _, task in ipairs(tasks_by_doc[path] or {}) do render_task(task, child_prefix, child_depth) end
    elseif kind == "SPEC" then
      for _, requirement in ipairs(requirements_by_doc[path] or {}) do
        local ref = path .. "#" .. requirement.id
        local projection = requirement_projections[ref]
        local state = requirement_states[ref] or "unplanned"
        local reference_path = path
        for _, document in ipairs(workspace.specs or {}) do
          if document.path == path then reference_path = document.referencePath or path; break end
        end
        local requirement_key = "requirement:" .. ref
        local requirement_expanded = expanded_tasks[requirement_key] == true
        local linked_tasks = {}
        for _, task_key in ipairs(projection and projection.taskKeys or {}) do
          if tasks_by_key[task_key] then linked_tasks[#linked_tasks + 1] = tasks_by_key[task_key] end
        end
        local reviews = projection and projection.hunkReviews or {}
        local criteria = {}
        local verified_by_ref = {}
        for _, item in ipairs(projection and projection.acceptanceCriteria or {}) do
          verified_by_ref[item.ref] = item.verified == true
        end
        local spec_document
        for _, spec in ipairs(workspace.specs or {}) do
          if spec.path == path then spec_document = spec; break end
        end
        if spec_document then
          for _, criterion in ipairs(spec_document.acceptanceCriteria or {}) do
            if vim.tbl_contains(criterion.requirementIds or {}, requirement.id) then
              local criterion_ref = path .. "#" .. criterion.id
              criteria[#criteria + 1] = {
                ref = criterion_ref, text = criterion.text, range = criterion.range,
                specPath = path, verified = verified_by_ref[criterion_ref] == true,
              }
            end
          end
          -- The core also links an AC without explicit R-IDs when its task has
          -- exactly one requirement in this SPEC. Preserve that resolved link.
          for _, coverage in ipairs(projection and projection.acceptanceCriteria or {}) do
            local exists = false
            for _, criterion in ipairs(criteria) do
              if criterion.ref == coverage.ref then exists = true; break end
            end
            if not exists then
              local id = coverage.ref:match("#([^#]+)$")
              for _, criterion in ipairs(spec_document.acceptanceCriteria or {}) do
                if criterion.id == id then
                  criteria[#criteria + 1] = {
                    ref = coverage.ref, text = criterion.text, range = criterion.range,
                    specPath = path, verified = coverage.verified == true,
                  }
                  break
                end
              end
            end
          end
        end
        local has_details = #linked_tasks + #reviews + #criteria > 0
        add(child_prefix .. string.rep(" ", child_depth) .. (has_details and (requirement_expanded and "- " or "+ ") or "  ")
          .. requirement.id .. " " .. state:upper() .. " " .. (requirement.text or ""),
          { kind = "requirement", key = requirement_key, parent_key = "file:" .. path,
            requirement = requirement, spec_path = path, reference_path = reference_path, projection = projection,
            expanded = requirement_expanded, expandable = has_details })
        if requirement_expanded then
          if #(requirement.headingPath or {}) > 0 then
            add(child_prefix .. string.rep(" ", child_depth + 1)
              .. "SECTION " .. table.concat(requirement.headingPath, " / "),
              { kind = "requirement_heading", parent_key = requirement_key, requirement = requirement })
          end
          add(child_prefix .. string.rep(" ", child_depth + 1)
            .. requirement_state_reason(state, linked_tasks),
            { kind = "requirement_explanation", parent_key = requirement_key, requirement = requirement, projection = projection })
          for _, task in ipairs(linked_tasks) do
            local task_state = derived_tasks[task.key]
            local value = type(task_state) == "table" and task_state.state or task.state
            add(child_prefix .. string.rep(" ", child_depth + 1) .. "TASK " .. tostring(value):upper() .. " " .. task.text,
              { kind = "requirement_task", parent_key = requirement_key, task = task })
          end
          for _, criterion in ipairs(criteria) do
            add(child_prefix .. string.rep(" ", child_depth + 1)
              .. "AC " .. criterion.ref .. " " .. (criterion.verified and "VERIFIED" or "UNVERIFIED"),
              { kind = "requirement_criterion", parent_key = requirement_key, criterion = criterion })
          end
          for _, review in ipairs(reviews) do
            local file = find_changed_file(review.path)
            local hunk_association
            for _, item in ipairs(workspace.git.hunkAssociations or {}) do
              if item.path == review.path and item.hunkIndex == review.hunkIndex then hunk_association = item; break end
            end
            add(child_prefix .. string.rep(" ", child_depth + 1) .. "HUNK " .. review.path .. "#"
              .. tostring(review.hunkIndex + 1) .. " " .. hunk_review_summary(review),
              { kind = "task_hunk", parent_key = requirement_key, file = file,
                hunk = find_changed_hunk(file, review.hunkIndex), hunkIndex = review.hunkIndex,
                hunkAssociation = hunk_association, requirement = requirement })
          end
        end
      end
    end
    if changed then
      for _, task_key in ipairs(file_association and file_association.taskKeys or {}) do
        local task = tasks_by_key[task_key]
        if task then
          add(child_prefix .. " TASK " .. task.text .. " · " .. file_association_label(file_association.state),
            { kind = "task_change", key = "file-task:" .. path .. ":" .. task_key,
              parent_key = "file:" .. path, file = changed, association = file_association, task = task })
        end
      end
      for _, item in ipairs(file_hunks) do
        local names = {}
        for _, task_key in ipairs(item.candidateTaskKeys or {}) do
          local task = tasks_by_key[task_key]
          if task then names[#names + 1] = task.text end
        end
        local requirements = item.candidateRequirementRefs or {}
        local related_parts = {}
        if #names > 0 then related_parts[#related_parts + 1] = "tasks: " .. table.concat(names, ", ") end
        if #requirements > 0 then related_parts[#related_parts + 1] = "SPEC: " .. table.concat(requirements, ", ") end
        local related = #related_parts > 0 and table.concat(related_parts, " · ")
          or "no task or requirement candidate"
        add(child_prefix .. " HUNK " .. tostring(item.hunkIndex + 1) .. " "
          .. tostring(item.state):upper() .. " · " .. tostring(item.reason) .. " · " .. related,
          { kind = "task_hunk", key = "file-hunk:" .. path .. ":" .. tostring(item.hunkIndex),
            parent_key = "file:" .. path, file = changed, hunkIndex = item.hunkIndex,
            hunk = find_changed_hunk(changed, item.hunkIndex), hunkAssociation = item })
      end
    end
  end

  add("NEOLIT · " .. vim.fn.fnamemodify(root, ":t") .. " · " .. workspace.git.branch
    .. "@" .. (workspace.git.base or workspace.git.head):sub(1, 8)
    .. " · " .. (filter_mode == "affected" and "AFFECTED" or "ALL")
    .. " · f filter · ? keys", { kind = "header" })

  local function render_tree(node, prefix, parent_key)
    local entries = {}
    for name, child in pairs(node.children) do
      if filter_mode ~= "affected" or subtree_affected(child) then
        entries[#entries + 1] = { name = name, directory = true, node = child, path = child.path }
      end
    end
    for _, entry in ipairs(node.files) do
      if filter_mode ~= "affected" or affected_paths[entry.path] then
        entries[#entries + 1] = { name = entry.name, path = entry.path, directory = false, entry = entry }
      end
    end
    table.sort(entries, function(a, b)
      if a.directory ~= b.directory then return a.directory end
      return a.name:lower() < b.name:lower()
    end)
    for index, entry in ipairs(entries) do
      local last = index == #entries
      local branch = last and "└" or "├"
      local child_prefix = prefix .. (last and "  " or "│ ")
      if entry.directory then
        local expanded = expanded_dirs[entry.path] == true
        add(prefix .. branch .. (expanded and "-" or "+") .. entry.name .. "/",
          { kind = "tree_directory", key = "dir:" .. entry.path, parent_key = parent_key, path = entry.path, expanded = expanded, expandable = true })
        if expanded then render_tree(entry.node, child_prefix, "dir:" .. entry.path) end
      else
        render_file(entry.entry, prefix, branch)
      end
    end
  end
  render_tree(tree_root, "", nil)
  if filter_mode == "affected" and #(workspace.git.changedFiles or {}) == 0 then
    add("(no affected paths)", { kind = "empty" })
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
        if state == "VERIFIED" or state == "IMPLEMENTED" then
          group = "DiagnosticOk"
        elseif state == "BLOCKED" then
          group = "DiagnosticError"
        elseif state == "IN-PROGRESS" or state == "UNMAPPED" then
          group = "DiagnosticWarn"
        end
        mark(line, state, group)
      elseif row.kind == "requirement" then
        mark(line, row.requirement.id, "Identifier")
        local state = (requirement_states[row.spec_path .. "#" .. row.requirement.id] or "unmapped"):upper()
        local group = (state == "VERIFIED" or state == "IMPLEMENTED") and "DiagnosticOk"
          or (state == "IN-PROGRESS" or state == "UNMAPPED") and "DiagnosticWarn"
          or state == "BLOCKED" and "DiagnosticError" or "DiagnosticInfo"
        mark(line, state, group)
      elseif row.kind == "acceptance_criterion" or row.kind == "requirement_criterion" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns,
          row.verified and "DiagnosticOk" or "DiagnosticWarn", line - 1, 0, -1)
      elseif row.kind == "task_hunk" then
        vim.api.nvim_buf_add_highlight(buf, rich_ns, "DiagnosticWarn", line - 1, 0, -1)
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
          or association.state == "documentation" and "Special" or "DiagnosticInfo"
        local marker = association.state == "unplanned" and "?"
          or association.state == "documentation" and "D" or "~"
        mark(line, marker, group)
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

  -- Split the current window to the left: the window that was already
  -- open becomes Neolit's one-and-only right preview pane. Do not split it
  -- again or create a second preview window.
  local preview_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft 36vnew")
  local buf = vim.api.nvim_get_current_buf()
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(tree_win, 36)
  -- Keep the navigation column fixed while preview/diff windows split and
  -- resize the remaining space. The right side then owns all remaining width.
  vim.wo[tree_win].winfixwidth = true
  vim.wo[tree_win].wrap = vim.go.wrap
  vim.bo[buf].tabstop = 2
  vim.bo[buf].shiftwidth = 2
  vim.bo[buf].softtabstop = 2
  vim.bo[buf].expandtab = true
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
  local diff_state = { tree_win = tree_win, preview_win = preview_win, diff_view = cfg.diff_view or "side_by_side" }
  local filter_mode = "all"

  local function open_in_preview(relative_path, line, focus)
    local original_win = vim.api.nvim_get_current_win()
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
    local existing_buf = vim.fn.bufnr(target)
    local target_buf = vim.fn.bufadd(target)
    vim.fn.bufload(target_buf)
    -- Hover previews should not flood the user's buffer list. Preserve the
    -- listed state of buffers that were already open before Neolit previewed them.
    if existing_buf < 0 then vim.bo[target_buf].buflisted = false end
    vim.api.nvim_win_set_buf(win, target_buf)
    vim.wo[win].wrap = vim.go.wrap
    if focus then
      vim.api.nvim_set_current_win(win)
    elseif vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
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
            if expanded_files[path] == nil then expanded_files[path] = false end
            open_paths[#open_paths + 1] = path
          end
          for _, spec in ipairs(workspace.specs or {}) do
            if expanded_files[spec.path] == nil then expanded_files[spec.path] = false end
            open_paths[#open_paths + 1] = spec.path
          end
          for _, todo in ipairs(workspace.todos or {}) do
            if expanded_files[todo.path] == nil then expanded_files[todo.path] = false end
            open_paths[#open_paths + 1] = todo.path
          end
          for _, task in ipairs(workspace.tasks or {}) do
            if expanded_tasks[task.key] == nil then expanded_tasks[task.key] = false end
          end
          for _, path in ipairs(open_paths) do
            local parent = path:match("^(.*)/[^/]+$")
            while parent do
              if expanded_dirs[parent] == nil then expanded_dirs[parent] = false end
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
      if target then open_in_preview(row.path, nil, true) end
    elseif row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, workspace.git.base, nil, diff_state, true)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          open_in_preview(row.path, nil, true)
        else
          vim.notify("Repository file is no longer available: " .. row.path, vim.log.levels.WARN)
        end
      end
    elseif row.kind == "task" then
      local task = row.task
      local todo_path = task.key:match("^(.-)::")
      local todo_file = todo_path and safe_repo_path(root, todo_path)
      if todo_file then
        open_in_preview(todo_path, task.range.startLine, true)
      end
    elseif row.kind == "requirement" then
      local req = row.requirement
      local spec_path = row.spec_path
      local spec_file = spec_path and safe_repo_path(root, spec_path)
      if spec_file then
        open_in_preview(spec_path, req.range.startLine, true)
      end
    elseif row.kind == "requirement_task" then
      local todo_path = row.task.key:match("^(.-)::")
      if todo_path and safe_repo_path(root, todo_path) then
        open_in_preview(todo_path, row.task.range.startLine, true)
      end
    elseif row.kind == "task_requirement" then
      open_in_preview((row.requirement.sourcePath or row.requirement.specPath), row.requirement.range.startLine, true)
    elseif row.kind == "task_acceptance" then
      open_in_preview((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range.startLine, true)
    elseif row.kind == "requirement_criterion" then
      open_in_preview((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range.startLine, true)
    elseif row.kind == "planned_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, workspace.git.base, nil, diff_state, true)
      else
        local target = safe_repo_path(root, row.path)
        if target and vim.fn.filereadable(target) == 1 then
          open_in_preview(row.path, nil, true)
        else
          vim.notify("Planned file does not exist yet: " .. row.path, vim.log.levels.INFO)
        end
      end
    elseif row.kind == "task_change" then
      if row.file then
        open_diff(root, row.file, nil, workspace and workspace.git.base, nil, diff_state, true)
      else
        vim.notify("The linked changed file is no longer in the workspace; refresh", vim.log.levels.WARN)
      end
    elseif row.kind == "task_hunk" then
      if row.file and row.hunk then
        open_diff(root, row.file, row.hunk,
          workspace and workspace.git.base, nil, diff_state, true)
      else
        vim.notify("The linked hunk is no longer in the workspace; refresh", vim.log.levels.WARN)
      end
    elseif row.kind == "file" then
      open_diff(root, row.file, nil, workspace and workspace.git.base, nil, diff_state, true)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_diff(root, row.file, row.hunk, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, diff_state, true)
    end
  end

  local current_row
  local function preview_row(row)
    if not row then return end
    local workspace = vim.b[buf].neolit_workspace
    if row.kind == "planning_document" then
      open_in_preview(row.path, nil, false)
    elseif row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_diff(root, changed, nil, workspace.git.base, nil, diff_state, false)
      else
        open_in_preview(row.path, nil, false)
      end
    elseif row.kind == "task_change" then
      if row.file then open_diff(root, row.file, nil, workspace and workspace.git.base, nil, diff_state, false) end
    elseif row.kind == "task_hunk" then
      if row.file and row.hunk then
        open_diff(root, row.file, row.hunk, workspace and workspace.git.base, nil, diff_state, false)
      end
    elseif row.kind == "file" then
      open_diff(root, row.file, nil, workspace and workspace.git.base, nil, diff_state, false)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_diff(root, row.file, row.hunk, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, diff_state, false)
    elseif row.kind == "task" then
      local path = row.task.key:match("^(.-)::")
      if path then open_in_preview(path, row.task.range.startLine, false) end
    elseif row.kind == "requirement_task" then
      local path = row.task.key:match("^(.-)::")
      if path then open_in_preview(path, row.task.range.startLine, false) end
    elseif row.kind == "task_requirement" then
      open_in_preview((row.requirement.sourcePath or row.requirement.specPath), row.requirement.range.startLine, false)
    elseif row.kind == "task_acceptance" then
      open_in_preview((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range.startLine, false)
    elseif row.kind == "requirement_criterion" then
      open_in_preview((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range.startLine, false)
    elseif row.kind == "requirement" then
      open_in_preview(row.spec_path, row.requirement.range.startLine, false)
    elseif row.kind == "planned_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then open_diff(root, changed, nil, workspace.git.base, nil, diff_state, false)
      else open_in_preview(row.path, nil, false) end
    end
  end

  local function selected_file_target(row)
    if not row then return nil end
    if row.file and type(row.file.path) == "string" then
      return row.file.path, row.kind == "change_line" and row.lineNumber or nil
    elseif row.kind == "repository_file" or row.kind == "planning_document" or row.kind == "planned_file" then
      return row.path
    elseif row.kind == "task" then
      return row.task.key:match("^(.-)::"), row.task.range and row.task.range.startLine
    elseif row.kind == "requirement" then
      return row.spec_path, row.requirement.range and row.requirement.range.startLine
    elseif row.kind == "task_change" or row.kind == "task_hunk" then
      return row.file and row.file.path
    elseif row.kind == "requirement_task" then
      return row.task.key:match("^(.-)::"), row.task.range and row.task.range.startLine
    elseif row.kind == "task_description" or row.kind == "task_agent_note" or row.kind == "task_heading" then
      return row.task.key:match("^(.-)::")
    elseif row.kind == "task_requirement" then
      return (row.requirement.sourcePath or row.requirement.specPath), row.requirement.range and row.requirement.range.startLine
    elseif row.kind == "task_acceptance" then
      return (row.criterion.sourcePath or row.criterion.specPath), row.criterion.range and row.criterion.range.startLine
    elseif row.kind == "requirement_criterion" then
      return (row.criterion.sourcePath or row.criterion.specPath), row.criterion.range and row.criterion.range.startLine
    end
    return nil
  end
  local function open_selected_file()
    local row = current_row()
    local path, line = selected_file_target(row)
    if not path then
      vim.notify("Select a file, task, or requirement first", vim.log.levels.INFO)
      return
    end
    open_in_preview(path, line, true)
  end
  local function focus_working_diff()
    local row = current_row()
    local path = selected_file_target(row)
    if not path then
      vim.notify("Select a file or diff row first", vim.log.levels.INFO)
      return
    end
    local workspace = vim.b[buf].neolit_workspace
    local changed = row.file
    if not changed then
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == path or file.previousPath == path then changed = file; break end
      end
    end
    if changed then
      local hunk = row.hunk or (row.hunkAssociation and row.hunkAssociation.hunk)
      open_diff(root, changed, hunk, workspace and workspace.git.base,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil,
        diff_state, true)
      local win = diff_state.working_win or diff_state.preview_win
      if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    else
      open_in_preview(path, nil, true)
    end
  end


  local function copy_value(value, label)
    if type(value) ~= "string" or value == "" then
      vim.notify("Nothing to copy for this selection", vim.log.levels.INFO)
      return
    end
    local ok = pcall(vim.fn.setreg, "+", value)
    if not ok then
      vim.fn.setreg('"', value)
      vim.notify(label .. " copied to unnamed register (clipboard unavailable)", vim.log.levels.INFO)
      return
    end
    vim.notify(label .. " copied")
  end

  local function copy_source_line(path, line, label)
    if type(path) ~= "string" or type(line) ~= "number" then return false end
    local target = safe_repo_path(root, path)
    if not target or vim.fn.filereadable(target) ~= 1 then return false end
    local source = vim.fn.readfile(target)
    local value = source[line]
    if type(value) ~= "string" then return false end
    copy_value(value, label)
    return true
  end

  local function copy_selected_text()
    local row = current_row()
    if not row then return end
    if row.kind == "task" or row.kind == "requirement_task" then
      local path = row.task.key:match("^(.-)::")
      if not copy_source_line(path, row.task.range and row.task.range.startLine, "Task source") then
        copy_value(row.task.text, "Task text")
      end
    elseif row.kind == "requirement" then
      if not copy_source_line(row.spec_path, row.requirement.range and row.requirement.range.startLine, "Requirement source") then
        copy_value(row.requirement.text, "Requirement text")
      end
    elseif row.kind == "acceptance_criterion" or row.kind == "requirement_criterion" then
      if not copy_source_line((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range and row.criterion.range.startLine, "Acceptance criterion source") then
        copy_value(row.criterion.text, "Acceptance criterion")
      end
    elseif row.kind == "task_requirement" then
      if not copy_source_line((row.requirement.sourcePath or row.requirement.specPath), row.requirement.range and row.requirement.range.startLine, "Requirement source") then
        copy_value(row.requirement.text, "Requirement text")
      end
    elseif row.kind == "task_acceptance" then
      if not copy_source_line((row.criterion.sourcePath or row.criterion.specPath), row.criterion.range and row.criterion.range.startLine, "Acceptance criterion source") then
        copy_value(row.criterion.text, "Acceptance criterion")
      end
    elseif row.kind == "task_change" then
      copy_value(row.file and row.file.rawDiff or "", "File diff")
    elseif row.kind == "task_hunk" then
      local hunk = row.hunk
      local raw = row.file and row.file.rawDiff or ""
      local hunk_index = row.hunkIndex or (row.hunkAssociation and row.hunkAssociation.hunkIndex)
      if hunk and raw ~= "" and type(hunk_index) == "number" then
        local lines = vim.split(raw, "\n", { plain = true })
        local index, found, parts = 0, false, {}
        for _, line in ipairs(lines) do
          if line:match("^@@ ") then
            index = index + 1
            if found then break end
            found = index == hunk_index + 1
          end
          if found then parts[#parts + 1] = line end
        end
        if #parts > 0 then
          copy_value(table.concat(parts, "\n"), "Hunk")
        else
          vim.notify("Exact hunk patch is no longer available; refresh the workspace", vim.log.levels.WARN)
        end
      else
        vim.notify("Exact hunk patch is unavailable; refresh the workspace", vim.log.levels.WARN)
      end
    elseif row.kind == "file" and row.file then
      copy_value(row.file.rawDiff or "", "File diff")
    elseif row.kind == "task_description" or row.kind == "task_agent_note" then
      local line = vim.api.nvim_buf_get_lines(buf, vim.api.nvim_win_get_cursor(0)[1] - 1,
        vim.api.nvim_win_get_cursor(0)[1], false)[1] or ""
      copy_value(line:gsub("^%s+", ""), row.kind == "task_agent_note" and "Agent note" or "Description")
    elseif row.kind == "task_reference" then
      copy_value(row.reference.path .. "#" .. table.concat(row.reference.ids or {}, ", "), "SPEC reference")
    elseif row.kind == "diagnostic" then
      copy_value(row.diagnostic.message or tostring(row.diagnostic), "Diagnostic")
    elseif row.kind == "hunk" then
      copy_value(row.hunk and row.hunk.header or "", "Hunk header")
    else
      local line = vim.api.nvim_buf_get_lines(buf, vim.api.nvim_win_get_cursor(0)[1] - 1,
        vim.api.nvim_win_get_cursor(0)[1], false)[1] or ""
      copy_value(line:gsub("^%s+", ""), "Selected text")
    end
  end

  local function copy_selected_path()
    local row = current_row()
    if not row then return end
    local path = selected_file_target(row)
    if not path and row.kind == "tree_directory" then path = row.path end
    if not path and row.kind == "task_reference" then path = row.reference.path end
    if not path and row.kind == "diagnostic" then path = row.diagnostic.path or row.diagnostic.todoPath end
    if path then
      local line
      if row.kind == "task" or row.kind == "requirement_task" then
        line = row.task.range and row.task.range.startLine
      elseif row.kind == "requirement" then
        line = row.requirement.range and row.requirement.range.startLine
      elseif row.kind == "acceptance_criterion" or row.kind == "task_acceptance" or row.kind == "requirement_criterion" then
        line = row.criterion.range and row.criterion.range.startLine
      elseif row.kind == "task_requirement" then
        line = row.requirement.range and row.requirement.range.startLine
      end
      copy_value(path .. (line and (":" .. line) or ""), "Path")
    else
      vim.notify("This selection has no source path", vim.log.levels.INFO)
    end
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
  current_row = function()
    return vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(0)[1]]
  end

  local function archive_selected()
    local row = current_row()
    if not row then return end
    local relative, range, label, marker
    if (row.kind == "task" or row.kind == "requirement_task") and row.task then
      relative = row.task.key:match("^(.-)::")
      range = row.task.range
      label = "TODO task"
      marker = row.task.text
    elseif row.kind == "requirement" and row.requirement then
      relative = row.spec_path
      range = row.requirement.range
      label = "SPEC requirement " .. tostring(row.requirement.id)
      marker = row.requirement.id
    elseif (row.kind == "requirement_criterion" or row.kind == "task_acceptance") and row.criterion then
      relative = row.criterion.sourcePath or row.criterion.specPath
      range = row.criterion.range
      label = "SPEC acceptance criterion " .. tostring(row.criterion.id)
      marker = row.criterion.id
    else
      vim.notify("Select a TODO task or SPEC requirement to archive", vim.log.levels.INFO)
      return
    end
    if not relative then
      vim.notify("Selected planning entry has no source document", vim.log.levels.ERROR)
      return
    end
    local source = safe_repo_path(root, relative)
    local archived = relative and relative:lower():match("%.archive%.md$") ~= nil
    local destination_relative = archived
      and relative:gsub("%.archive%.md$", ".md")
      or relative:gsub("%.md$", ".archive.md")
    local destination = safe_repo_path(root, destination_relative)
    if not source or not destination or source == destination or not range then
      vim.notify("Cannot resolve a safe archive source/destination", vim.log.levels.ERROR)
      return
    end
    for _, path in ipairs({ source, destination }) do
      local loaded = vim.fn.bufnr(path)
      if loaded >= 0 and vim.bo[loaded].modified then
        vim.notify("Write the modified planning buffer before archiving", vim.log.levels.WARN)
        return
      end
    end
    local source_lines = vim.fn.readfile(source)
    local first = tonumber(range.startLine)
    local last = tonumber(range.endLine)
    if not first or not last or first < 1 or last < first or last > #source_lines then
      vim.notify("The selected Markdown range is stale; refresh the workspace", vim.log.levels.WARN)
      return
    end
    local first_line = source_lines[first] or ""
    local marker_count = 0
    for _, line in ipairs(source_lines) do
      if row.kind == "task" or row.kind == "requirement_task" then
        if line:find(marker, 1, true) and line:match("%[[ xX]%]") then marker_count = marker_count + 1 end
      elseif line:find("**" .. marker .. "**", 1, true) then
        marker_count = marker_count + 1
      end
    end
    if marker_count ~= 1 then
      vim.notify("The selected Markdown entry is ambiguous or changed; refresh before archiving", vim.log.levels.WARN)
      return
    end
    if row.kind == "task" or row.kind == "requirement_task" then
      if not first_line:find(marker, 1, true) or not first_line:match("%[[ xX]%]") then
        vim.notify("The selected TODO task changed; refresh before archiving", vim.log.levels.WARN)
        return
      end
    elseif not first_line:find("**" .. marker .. "**", 1, true) then
      vim.notify("The selected SPEC paragraph changed; refresh before archiving", vim.log.levels.WARN)
      return
    end
    local block = {}
    for line = first, last do block[#block + 1] = source_lines[line] end
    if #block == 0 then return end
    local destination_lines = vim.fn.filereadable(destination) == 1 and vim.fn.readfile(destination) or {}
    for start = 1, #destination_lines - #block + 1 do
      local same = true
      for offset = 1, #block do
        if destination_lines[start + offset - 1] ~= block[offset] then same = false; break end
      end
      if same then
        vim.notify("That exact block already exists in " .. destination_relative, vim.log.levels.WARN)
        return
      end
    end
    -- One `a` press performs the selected archive/restore action.
      return
    end
    if #destination_lines > 0 and destination_lines[#destination_lines] ~= "" then
      destination_lines[#destination_lines + 1] = ""
    end
    for _, line in ipairs(block) do destination_lines[#destination_lines + 1] = line end
    if vim.fn.writefile(destination_lines, destination) ~= 0 then
      vim.notify("Could not write " .. destination_relative, vim.log.levels.ERROR)
      return
    end
    for _ = first, last do table.remove(source_lines, first) end
    if vim.fn.writefile(source_lines, source) ~= 0 then
      vim.notify("Archive was written, but source cleanup failed; reconcile " .. relative, vim.log.levels.ERROR)
      return
    end
    for _, path in ipairs({ source, destination }) do
      local loaded = vim.fn.bufnr(path)
      if loaded >= 0 then
        pcall(vim.api.nvim_buf_call, loaded, function() vim.cmd("checktime") end)
      end
    end
    vim.notify(action .. "d " .. label .. (archived and " from " or " to ") .. destination_relative)
    refresh()
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
    elseif row.kind == "requirement" then
      expanded_tasks[row.key] = expanded
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
    if row and (row.kind == "tree_directory" or row.kind == "task" or row.kind == "requirement" or row.kind == "file" or row.kind == "planning_document") then
      toggle_node(row, true)
    end
  end
  local function collapse_node_at_cursor()
    local row = current_row()
    if not row then return end
    if row.kind == "tree_directory" or row.kind == "task" or row.kind == "requirement" or row.kind == "file" or row.kind == "planning_document" then
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
    for _, spec in ipairs(workspace.specs or {}) do
      for _, requirement in ipairs(spec.requirements or {}) do
        expanded_tasks["requirement:" .. spec.path .. "#" .. requirement.id] = expanded
      end
    end
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
        elseif row.kind == "requirement" then expanded_tasks[row.key] = mode == "open"
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
      requirement_ref = (selected_row.reference_path or selected_row.spec_path) .. "#" .. selected_requirement.id
    end

    local function list(value)
      return type(value) == "table" and value or {}
    end
    local linked_task_keys = {}
    local workspace = vim.b[buf].neolit_workspace
    if requirement_ref and type(workspace) == "table" then
      for _, task in ipairs(list(workspace.tasks)) do
        if type(task) == "table" then
          for _, requirement in ipairs(list(task.resolvedRequirements)) do
            if type(requirement) == "table" and requirement.specPath == (selected_row.reference_path or selected_row.spec_path)
              and requirement.id == selected_requirement.id then
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
          elseif candidate.kind == "task_hunk" or candidate.kind == "hunk" or candidate.kind == "change_line" then
            local association = type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation or nil
            related = vim.tbl_contains(list(association and association.candidateTaskKeys), task_key)
          elseif candidate.kind == "task_change" then
            related = candidate.task and candidate.task.key == task_key
          elseif candidate.kind == "planned_file" then
            local task = type(candidate.task) == "table" and candidate.task or nil
            related = task ~= nil and task.key == task_key
          elseif (candidate.kind == "requirement" or candidate.kind == "task_requirement") and selected_task then
            local requirement = candidate.requirement
            for _, item in ipairs(list(selected_task.resolvedRequirements)) do
              if type(item) == "table" and type(requirement) == "table"
                and item.specPath == (candidate.reference_path or requirement.specPath)
                and item.id == requirement.id then
                related = true
                break
              end
            end
          end
        elseif requirement_ref then
          if candidate.kind == "task" or candidate.kind == "requirement_task" then
            local task = type(candidate.task) == "table" and candidate.task or nil
            for _, item in ipairs(list(task and task.resolvedRequirements)) do
              if type(item) == "table" and item.specPath == (selected_row.reference_path or selected_row.spec_path)
                and item.id == selected_requirement.id then
                related = true
                break
              end
            end
          elseif candidate.kind == "file" then
            local association = type(candidate.association) == "table" and candidate.association or nil
            for _, key in ipairs(list(association and association.taskKeys)) do
              if linked_task_keys[key] then related = true; break end
            end
          elseif candidate.kind == "task_hunk" or candidate.kind == "hunk" or candidate.kind == "change_line" then
            local association = type(candidate.hunkAssociation) == "table" and candidate.hunkAssociation or nil
            related = vim.tbl_contains(list(association and association.candidateRequirementRefs), requirement_ref)
          elseif candidate.kind == "task_change" then
            if candidate.task and linked_task_keys[candidate.task.key] then
              related = true
            else
              local association = type(candidate.association) == "table" and candidate.association or nil
              for _, key in ipairs(list(association and association.taskKeys)) do
                if linked_task_keys[key] then related = true; break end
              end
            end
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
  vim.api.nvim_create_autocmd({ "FocusGained", "CursorHold", "CursorHoldI" }, {
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
  map("<CR>", selected, "Show selected diff or expand/open planning entry")
  map("e", focus_working_diff, "Edit the selected file in the working side of its diff")
  map("o", open_selected_file, "Open the selected actual file without the diff")
  map("<leader>ne", focus_working_diff, "Edit selected file in diff")
  map("<leader>no", open_selected_file, "Open selected file without diff")
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
      local affected_paths = collect_affected_paths(workspace)
      for path in pairs(affected_paths) do
        local parent = path:match("^(.*)/[^/]+$")
        while parent do expanded_dirs[parent] = true; parent = parent:match("^(.*)/[^/]+$") end
      end
    end
    rerender_at(row and row.key)
  end, "Show all repository paths / affected paths only")
  map("r", refresh, "Refresh Git-native planning workspace")
  map("D", function()
    diff_state.diff_view = diff_state.diff_view == "side_by_side" and "unified" or "side_by_side"
    local row = current_row()
    if row then preview_row(row) end
    vim.notify("Neolit diff view: " .. diff_state.diff_view)
  end, "Toggle side-by-side / unified diff preview")
  map("a", archive_selected, "Move selected TODO task or SPEC requirement to/from its archive file")
  map("x", copy_selected_text, "Copy selected task, requirement, description, or row text")
  map("y", copy_selected_path, "Copy selected repository path and source line")
  map("?", function()
    vim.notify("Tree: <CR> expand/open · za toggle · zo open · zc close · h/l expand/collapse-or-parent · zr/zm one level · zR/zM all · f affected-only · a archive/restore task or requirement · D diff view · e / <leader>ne edit working side · o / <leader>no open file · x copy text · y copy path · r refresh · q/<Esc> close", vim.log.levels.INFO)
  end, "Show Neolit tree keys")
  local function close_workspace()
    refresh_revision = refresh_revision + 1
    if refresh_job then pcall(vim.fn.jobstop, refresh_job); refresh_job = nil end
    pcall(vim.api.nvim_del_augroup_by_id, refresh_group)
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  map("q", close_workspace, "Close planning workspace")
  map("<Esc>", close_workspace, "Close planning workspace")
  refresh()
end

return M
