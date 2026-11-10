--- Read-only Git-native planning workspace backed by the shared TypeScript core.
local M = {}

local function bind_key(buf, cfg, action, default, callback, opts)
  local lhs = cfg and cfg.keymaps and cfg.keymaps[action]
  if type(lhs) ~= "string" or lhs == "" then return end
  local options = vim.tbl_extend("force", { buffer = buf, silent = true, desc = "Neolit: " .. action }, opts or {})
  vim.keymap.set("n", lhs, callback, options)
end

local safe_repo_path

local function add_codecompanion_file_reference(root, relative)
  local target = type(relative) == "string" and safe_repo_path(root, relative) or nil
  if not target or vim.fn.filereadable(target) ~= 1 then
    vim.notify("Select an existing file first", vim.log.levels.INFO)
    return
  end
  local name = vim.fn.fnamemodify(target, ":t"):gsub("%[", "\\["):gsub("%]", "\\]")
  local escaped_target = target:gsub('"', '\\"')
  local link = "[" .. name .. ']("' .. escaped_target .. '")'
  vim.fn.setreg('"', link)
  pcall(vim.fn.setreg, "+", link)
  vim.notify("File reference yanked: " .. relative, vim.log.levels.INFO)
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

local function find_core(opts)
  local config = require("neolit.config")
  local cfg = config.merge(opts or {})
  local root = vim.fn.fnamemodify(cfg.directory or vim.fn.getcwd(), ":p")
  local plugin_root = config.plugin_root()
  local env = vim.fn.environ()
  local readable = function(file) return vim.fn.filereadable(file) == 1 end
  -- Prefer the plugin-local or sibling core without spawning npm on every open.
  local neolit_dir = config.find_neolit_dir(cfg, {
    env = env, plugin_root = plugin_root, readable = readable,
  })
  if not neolit_dir then
    local npm_root = vim.fn.system({ "npm", "root", "-g" }):gsub("%s+$", "")
    neolit_dir = config.find_neolit_dir(cfg, {
      env = env, plugin_root = plugin_root,
      npm_root = npm_root ~= "" and npm_root or nil,
      readable = readable,
    })
  end
  if not neolit_dir then
    error("Neolit core dependency is missing; run `npm install` in the neolit.nvim plugin directory")
  end
  return cfg, root, neolit_dir
end

local function canonical_worktree(root)
  local result = vim.system({ "git", "-C", root, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if result.code ~= 0 then
    error("Could not resolve Git worktree root: " .. (result.stderr or "git rev-parse failed"))
  end
  local worktree = vim.trim(result.stdout or "")
  if worktree == "" then error("Git returned an empty worktree root") end
  return vim.fn.resolve(vim.fn.fnamemodify(worktree, ":p")):gsub("/+$", "")
end

function M.worktree_root(opts)
  local ok, _, root = pcall(find_core, opts or {})
  if not ok then return nil, _ end
  return canonical_worktree(root)
end

function M.chat_file(opts)
  local ok, _, root = pcall(find_core, opts or {})
  if not ok then
    vim.notify(tostring(_), vim.log.levels.ERROR)
    return
  end
  root = canonical_worktree(root)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    vim.notify("Current buffer has no file path", vim.log.levels.INFO)
    return
  end
  local absolute = vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
  if absolute:sub(1, #root + 1) ~= root .. "/" then
    vim.notify("Current file is outside the Neolit worktree", vim.log.levels.WARN)
    return
  end
  add_codecompanion_file_reference(root, absolute:sub(#root + 2))
end

safe_repo_path = function(root, relative)
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

local function extract_diff_hunk(diff, wanted_index)
  if type(diff) ~= "string" or type(wanted_index) ~= "number" then return nil end
  local result, index, collecting = {}, -1, false
  for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
    if line:match("^@@ ") then
      index = index + 1
      if collecting then break end
      collecting = index == wanted_index
    end
    if collecting then result[#result + 1] = line end
  end
  return #result > 0 and table.concat(result, "\n") or nil
end

local function set_source_language(buf, path)
  local filetype = vim.filetype.match({ filename = path }) or ""
  if filetype ~= "" and vim.bo[buf].filetype ~= filetype then
    vim.bo[buf].filetype = filetype
  end
  -- bufload() does not reliably replay the FileType event for buffers
  -- materialized through bufadd(). Give normal FileType-based LSP configs
  -- their usual attachment opportunity when this real file buffer is previewed.
  if filetype ~= "" and vim.api.nvim_buf_is_loaded(buf) then
    local clients = vim.lsp and vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = buf }) or {}
    if #clients == 0 and not vim.b[buf].neolit_filetype_event then
      vim.b[buf].neolit_filetype_event = true
      pcall(vim.api.nvim_exec_autocmds, "FileType", {
        buffer = buf, modeline = false,
      })
    end
  end
  if filetype ~= "" and vim.treesitter and vim.treesitter.start then
    pcall(vim.treesitter.start, buf, filetype)
  end
  return filetype
end

local function render_planning_semantics(buf, workspace, relative_path)
  if not vim.api.nvim_buf_is_valid(buf) or type(workspace) ~= "table" then return end
  local ns = vim.api.nvim_create_namespace("neolit-planning-source-" .. buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local task_states, requirement_states = {}, {}
  for _, item in ipairs((workspace.derived and workspace.derived.tasks) or {}) do
    if item.taskKey then task_states[item.taskKey] = item end
  end
  for _, item in ipairs((workspace.derived and workspace.derived.requirements) or {}) do
    if item.specPath and item.requirementId then
      requirement_states[item.specPath .. "#" .. item.requirementId] = item
    end
  end
  local function decorate(line, label, group)
    local row = tonumber(line) and tonumber(line) - 1 or -1
    if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then return end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
      virt_text = { { "  · " .. label, group or "DiagnosticInfo" } },
      virt_text_pos = "eol",
      priority = 120,
    })
  end
  for _, task in ipairs(workspace.tasks or {}) do
    local path = task.key and task.key:match("^(.-)::")
    if path == relative_path and task.range and task.range.startLine then
      local projection = task_states[task.key]
      local state = projection and projection.state or task.state or "planned"
      local linked = #(task.resolvedRequirements or {})
      local changed = #(projection and projection.changedPaths or {})
      local group = state == "verified" and "DiagnosticOk"
        or state == "blocked" and "DiagnosticError"
        or (state == "in-progress" or state == "unmapped") and "DiagnosticWarn"
        or "DiagnosticInfo"
      local detail = state:upper() .. " · " .. linked .. " SPEC"
      if changed > 0 then detail = detail .. " · " .. changed .. " changed files" end
      decorate(task.range.startLine, detail, group)
    end
  end
  for _, spec in ipairs(workspace.specs or {}) do
    if spec.path == relative_path then
      for _, requirement in ipairs(spec.requirements or {}) do
        local ref = spec.path .. "#" .. requirement.id
        local projection = requirement_states[ref]
        local state = projection and projection.state or "unplanned"
        local linked = 0
        for _, task in ipairs(workspace.tasks or {}) do
          for _, item in ipairs(task.resolvedRequirements or {}) do
            if item.specPath == spec.path and item.id == requirement.id then linked = linked + 1; break end
          end
        end
        local group = state == "verified" and "DiagnosticOk"
          or state == "blocked" and "DiagnosticError"
          or (state == "in-progress" or state == "unmapped") and "DiagnosticWarn"
          or "DiagnosticInfo"
        decorate(requirement.range and requirement.range.startLine,
          state:upper() .. " · " .. linked .. " linked tasks", group)
        for _, criterion in ipairs(spec.acceptanceCriteria or {}) do
          local applies = vim.tbl_contains(criterion.requirementIds or {}, requirement.id)
          if applies then
            local covered, verified = 0, 0
            local criterion_ref = spec.path .. "#" .. criterion.id
            for _, task in ipairs(workspace.tasks or {}) do
              for _, item in ipairs(task.resolvedAcceptanceCriteria or {}) do
                if item.specPath == spec.path and item.id == criterion.id then
                  covered = covered + 1
                  local task_projection = task_states[task.key]
                  for _, evidence in ipairs((task_projection and task_projection.acceptanceCriteria) or {}) do
                    if evidence.ref == criterion_ref and evidence.verified then verified = verified + 1 end
                  end
                end
              end
            end
            decorate(criterion.range and criterion.range.startLine,
              (verified > 0 and "VERIFIED" or covered > 0 and "LINKED" or "UNCOVERED"),
              verified > 0 and "DiagnosticOk" or covered > 0 and "DiagnosticInfo" or "DiagnosticWarn")
          end
        end
      end
    end
  end
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
  for _, todo in ipairs(workspace.todos or {}) do
    -- Archived TODO copies are ordinary repository files, never active plans.
    if not todo.path:lower():match("%.archive%.md$") then doc_kind[todo.path] = "TODO" end
  end
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
    local reviews = cfg.change_view == "hunks" and type(projection) == "table" and projection.hunkReviews or {}
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
    -- Planning-document identity already explains its role; don't add a
    -- second, overlapping association marker. Keep mapping markers for code.
    local marker = changed and not kind and (
      association.state == "unplanned" and "?"
      or "~"
    ) or ""
    local is_expanded = expanded_files[path] == true
    local file_association = associations[path]
    local file_hunks = {}
    for _, item in ipairs(workspace.git.hunkAssociations or {}) do
      if item.path == path then file_hunks[#file_hunks + 1] = item end
    end
    local cc_review = workspace.codecompanionReview
    local cc_diff = cc_review and cc_review.diffs and cc_review.diffs[path]
    -- TODO/SPEC contents are presented in their source buffers, not duplicated
    -- as a second navigation tree. Only changed code files expand to evidence.
    local has_hunk_children = cfg.change_view == "codecompanion" and cc_diff and #cc_diff.hunks > 0
      or cfg.change_view == "hunks" and #file_hunks > 0
    local has_children = changed ~= nil
      and ((file_association and #(file_association.taskKeys or {}) > 0) or has_hunk_children)
    add(prefix .. branch .. (has_children and (is_expanded and "-" or "+") or " ")
      .. entry.name
      .. (marker ~= "" and (" " .. marker) or "")
      .. (status and (" [" .. git_marker .. "]") or ""),
      { kind = changed and "file" or (kind and "planning_document" or "repository_file"),
        key = "file:" .. path, path = path, file = changed, doc_kind = kind,
        association = association, git_status = status, expanded = is_expanded, expandable = has_children,
        parent_key = path:match("^(.*)/[^/]+$") and ("dir:" .. path:match("^(.*)/[^/]+$")) or nil })
    if not is_expanded then return end
    if changed then
      for _, task_key in ipairs(file_association and file_association.taskKeys or {}) do
        local task = tasks_by_key[task_key]
        if task then
          add(child_prefix .. " TASK " .. task.text .. " · " .. file_association_label(file_association.state),
            { kind = "task_change", key = "file-task:" .. path .. ":" .. task_key,
              parent_key = "file:" .. path, file = changed, association = file_association, task = task })
        end
      end
      if cfg.change_view == "codecompanion" and cc_diff then
        for entry_index, entry in ipairs(cc_review.entries or {}) do
          if entry.kind == "hunk" and entry.path == path then
            local first_hunk = entry.hunks and entry.hunks[1]
            local hunk = first_hunk and cc_diff.hunks[first_hunk] or nil
            local candidate_tasks, candidate_requirements = {}, {}
            local task_seen, requirement_seen = {}, {}
            for _, cc_index in ipairs(entry.hunks or {}) do
              local cc_hunk = cc_diff.hunks[cc_index]
              local cc_first = cc_hunk and math.max(cc_hunk.to_start or 1, 1) or nil
              local cc_last = cc_hunk and math.max(cc_first, cc_first + (cc_hunk.to_count or 0) - 1) or nil
              for _, association in ipairs(file_hunks) do
                local old_hunk = find_changed_hunk(changed, association.hunkIndex)
                local old_first = old_hunk and tonumber(old_hunk.newStart)
                local old_last = old_first and (old_first + math.max(tonumber(old_hunk.newLines) or 1, 1) - 1) or nil
                if cc_first and old_first and old_first <= cc_last and cc_first <= old_last then
                  for _, key in ipairs(association.candidateTaskKeys or {}) do
                    if not task_seen[key] then task_seen[key] = true; candidate_tasks[#candidate_tasks + 1] = key end
                  end
                  for _, ref in ipairs(association.candidateRequirementRefs or {}) do
                    if not requirement_seen[ref] then requirement_seen[ref] = true; candidate_requirements[#candidate_requirements + 1] = ref end
                  end
                end
              end
            end
            local mapped = { candidateTaskKeys = candidate_tasks, candidateRequirementRefs = candidate_requirements }
            local summary = cc_review.lines and cc_review.lines[entry_index] or "CodeCompanion review hunk"
            add(child_prefix .. " HUNK " .. summary,
              { kind = "task_hunk", key = "file-cch:" .. path .. ":" .. tostring(entry_index),
                parent_key = "file:" .. path, file = changed, hunkIndex = first_hunk and first_hunk - 1,
                hunk = hunk, ccHunkIndex = first_hunk, ccReviewEntry = entry, hunkAssociation = mapped })
          end
        end
      elseif cfg.change_view == "hunks" then
        for _, item in ipairs(file_hunks) do
          local task_count = #(item.candidateTaskKeys or {})
          local requirement_count = #(item.candidateRequirementRefs or {})
          local related = task_count .. " task · " .. requirement_count .. " req"
          add(child_prefix .. " HUNK " .. tostring(item.hunkIndex + 1) .. " "
            .. tostring(item.state):upper() .. " · " .. related,
            { kind = "task_hunk", key = "file-hunk:" .. path .. ":" .. tostring(item.hunkIndex),
              parent_key = "file:" .. path, file = changed, hunkIndex = item.hunkIndex,
              hunk = find_changed_hunk(changed, item.hunkIndex), hunkAssociation = item })
        end
      end
    end
  end

  local requirement_count, unplanned_count = 0, 0
  for _, spec in ipairs(workspace.specs or {}) do
    requirement_count = requirement_count + #(spec.requirements or {})
  end
  for _, file in ipairs(workspace.git.changedFiles or {}) do
    local association = associations[file.path]
    if not association or association.state == "unplanned" then unplanned_count = unplanned_count + 1 end
  end
  add("NEOLIT · " .. vim.fn.fnamemodify(root, ":t") .. " · " .. workspace.git.branch
    .. "@" .. (workspace.git.base or workspace.git.head):sub(1, 8)
    .. " · " .. #((workspace.tasks) or {}) .. "T/" .. requirement_count .. "R/"
    .. #((workspace.git.changedFiles) or {}) .. "Δ/" .. unplanned_count .. "?"
    .. " · " .. (filter_mode == "affected" and "AFFECTED" or "ALL")
    .. " · f filter · v view · ? keys", { kind = "header" })

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
        local association = row.association or {}
        if not row.doc_kind then
          local group = association.state == "unplanned" and "DiagnosticWarn" or "DiagnosticInfo"
          mark(line, association.state == "unplanned" and "?" or "~", group)
        end
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

  -- Restore a tree buffer even when the configured file/diff target replaced
  -- its window; this keeps the navigator recoverable without another instance.
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].filetype == "neolit-planning" then
      local restored = false
      for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
          if vim.api.nvim_win_get_buf(win) == candidate then
            vim.api.nvim_set_current_tabpage(tabpage)
            vim.api.nvim_set_current_win(win)
            restored = true
            break
          end
        end
        if restored then break end
      end
      if not restored then
        local tree = vim.b[candidate].neolit_tree_win
        if tree and vim.api.nvim_win_is_valid(tree) then
          vim.api.nvim_set_current_win(tree)
          vim.api.nvim_win_set_buf(tree, candidate)
        else
          vim.api.nvim_set_current_buf(candidate)
        end
      end
      return
    end
  end
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

  -- The tree may occupy the current window or a dedicated left column.
  -- File/diff previews use the existing right-hand window unless configured
  -- to replace the tree/current window.
  local original_win = vim.api.nvim_get_current_win()
  local tree_win, preview_win
  if (cfg.layout and cfg.layout.tree) == "current" then
    tree_win = original_win
    preview_win = nil
    vim.cmd("hide enew")
  else
    preview_win = original_win
    vim.cmd("topleft 36vnew")
    tree_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(tree_win, math.max(20, tonumber(cfg.layout and cfg.layout.width) or 36))
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].neolit_tree_win = tree_win
  if preview_win then vim.b[buf].neolit_preview_win = preview_win end
  -- Keep the navigation column fixed while preview/diff windows split and
  -- resize the remaining space. The right side then owns all remaining width.
  vim.wo[tree_win].winfixwidth = (cfg.layout and cfg.layout.tree) ~= "current"
  vim.wo[tree_win].cursorbind = false
  vim.wo[tree_win].scrollbind = false
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
  local view_state = { tree_win = tree_win, preview_win = preview_win }
  local context_chunks, context_keys = {}, {}
  local composed_expanded, scope_expanded = {}, {}
  local composed_view_buf, context_view_buf
  local filter_mode = "all"
  local codecompanion_review_diffs
  local codecompanion_review_loaded = false
  local codecompanion_preview_cache = {}
  local last_preview_key
  local last_cursor_line

  local function build_codecompanion_review()
    if not package.loaded["codecompanion"] and vim.fn.exists(":CodeCompanionCodeReview") ~= 2 then
      return nil
    end
    local ok, baseline = pcall(require, "codecompanion.interactions.code_review.baseline")
    if not ok or not baseline.get(root) then return nil end
    local loaded, checklist = pcall(require, "codecompanion.interactions.code_review.checklist")
    if not loaded then return nil end
    local built_ok, built = pcall(checklist.build, { root = root })
    if not built_ok or type(built) ~= "table" then return nil end
    return built
  end

  local function ensure_codecompanion_review(workspace)
    if cfg.change_view ~= "codecompanion" then return false end
    if codecompanion_review_loaded then return false end
    codecompanion_review_loaded = true
    local built = build_codecompanion_review()
    if not built then return false end
    codecompanion_review_diffs = built.diffs or {}
    workspace.codecompanionReview = built
    local changed_paths = {}
    for _, file in ipairs(workspace.git.changedFiles or {}) do changed_paths[file.path] = true end
    workspace.git.changedFiles = workspace.git.changedFiles or {}
    for path, diff in pairs(codecompanion_review_diffs) do
      if not changed_paths[path] then
        local file = { path = path, hunks = {} }
        for _, hunk in ipairs(diff.hunks or {}) do
          file.hunks[#file.hunks + 1] = {
            oldStart = hunk.from_start, oldLines = hunk.from_count,
            newStart = hunk.to_start, newLines = hunk.to_count,
          }
        end
        workspace.git.changedFiles[#workspace.git.changedFiles + 1] = file
      end
    end
    return true
  end

  local function clear_codecompanion_previews()
    for _, cached in pairs(codecompanion_preview_cache) do
      if cached.bufnr and vim.api.nvim_buf_is_valid(cached.bufnr) then
        pcall(vim.api.nvim_buf_delete, cached.bufnr, { force = true })
      end
    end
    codecompanion_preview_cache = {}
  end

  local function open_in_preview(relative_path, line, focus)
    local original_win = vim.api.nvim_get_current_win()
    local file_path = safe_repo_path(root, relative_path)
    if not file_path or vim.fn.filereadable(file_path) ~= 1 then
      vim.notify("File is no longer available: " .. tostring(relative_path), vim.log.levels.WARN)
      return
    end
    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) then return end
    -- Tree and preview are distinct, permanent window roles. Never fall back
    -- to the tree window: doing so replaces the navigator with a source file.
    local placement = (cfg.layout and cfg.layout.file) or "right"
    local win = placement == "tree" and tree or placement == "current" and vim.api.nvim_get_current_win() or view_state.preview_win
    if placement == "right" and (not win or not vim.api.nvim_win_is_valid(win) or win == tree) then
      vim.api.nvim_set_current_win(tree)
      vim.cmd("rightbelow vsplit")
      win = vim.api.nvim_get_current_win()
      view_state.preview_win = win
      vim.b[buf].neolit_preview_win = win
    end
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    if placement == "right" and (win == tree or vim.api.nvim_win_get_buf(tree) ~= buf) then
      vim.notify("Neolit window roles are inconsistent; close and reopen :Neolit", vim.log.levels.ERROR)
      return
    end
    vim.wo[win].cursorbind = false
    vim.wo[win].scrollbind = false
    local existing_buf = vim.fn.bufnr(file_path)
    local target_buf = vim.fn.bufadd(file_path)
    vim.fn.bufload(target_buf)
    if not vim.b[target_buf].neolit_language_initialized then
      set_source_language(target_buf, relative_path)
      vim.b[target_buf].neolit_language_initialized = true
    end
    if vim.b[target_buf].neolit_semantics_revision ~= refresh_revision then
      render_planning_semantics(target_buf, vim.b[buf].neolit_workspace, relative_path)
      vim.b[target_buf].neolit_semantics_revision = refresh_revision
    end
    -- Hover previews should not flood the user's buffer list. Preserve the
    -- listed state of buffers that were already open before Neolit previewed them.
    if existing_buf < 0 then vim.bo[target_buf].buflisted = false end
    -- Preview windows frequently replace a modified source buffer. A normal
    -- nvim_win_set_buf() raises E37 when that buffer is no longer shown in any
    -- window; :hide preserves it without forcing a write or discarding edits.
    if vim.api.nvim_win_get_buf(win) ~= target_buf then
      vim.api.nvim_win_call(win, function()
        vim.cmd("hide buffer " .. target_buf)
      end)
    end
    vim.wo[win].wrap = vim.go.wrap
    if focus then
      vim.api.nvim_set_current_win(win)
    elseif vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    if line then
      local cursor = vim.api.nvim_win_get_cursor(win)
      if cursor[1] ~= math.max(1, line) then
        vim.api.nvim_win_set_cursor(win, { math.max(1, line), 0 })
      end
    end
  end
  local function open_codecompanion_diff(file, file_diff, hunk_index, focus)
    local original_win = vim.api.nvim_get_current_win()
    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) then return end
    local target = (cfg.layout and cfg.layout.diff) or "right"
    local win = target == "tree" and tree or target == "current" and vim.api.nvim_get_current_win() or view_state.preview_win
    if target == "right" and (not win or not vim.api.nvim_win_is_valid(win) or win == tree) then
      vim.api.nvim_set_current_win(tree)
      vim.cmd("rightbelow vsplit")
      win = vim.api.nvim_get_current_win()
      view_state.preview_win = win
      vim.b[buf].neolit_preview_win = win
    end
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    if target == "right" and (win == tree or vim.api.nvim_win_get_buf(tree) ~= buf) then
      vim.notify("Neolit window roles are inconsistent; close and reopen :Neolit", vim.log.levels.ERROR)
      return
    end
    local cached = codecompanion_preview_cache[file.path]
    local preview
    if cached and cached.diff == file_diff and vim.api.nvim_buf_is_valid(cached.bufnr) then
      preview = cached.bufnr
    else
      if cached and cached.bufnr and vim.api.nvim_buf_is_valid(cached.bufnr) then
        pcall(vim.api.nvim_buf_delete, cached.bufnr, { force = true })
      end
      preview = vim.api.nvim_create_buf(false, true)
      vim.bo[preview].buftype = "nofile"
      vim.bo[preview].bufhidden = "wipe"
      vim.bo[preview].swapfile = false
      vim.bo[preview].modifiable = true
      vim.api.nvim_buf_set_lines(preview, 0, -1, false, #file_diff.merged.lines > 0 and file_diff.merged.lines or { "" })
      vim.bo[preview].modifiable = false
      vim.bo[preview].filetype = file_diff.ft or vim.filetype.match({ filename = file.path }) or "text"
      vim.api.nvim_buf_set_name(preview, "neolit://review/" .. file.path:gsub("[/\\\\]", "_") .. "-" .. preview)
      local ns = vim.api.nvim_create_namespace("neolit-codecompanion-diff-" .. preview)
      local ui_ok, diff_ui = pcall(require, "codecompanion.diff.ui")
      if ui_ok then pcall(diff_ui.apply_highlights, file_diff, { bufnr = preview, ns = ns }) end
      codecompanion_preview_cache[file.path] = { diff = file_diff, bufnr = preview }
    end
    vim.wo[win].cursorbind = false
    vim.wo[win].scrollbind = false
    if vim.api.nvim_win_get_buf(win) ~= preview then
      vim.api.nvim_win_call(win, function()
        vim.cmd("hide buffer " .. preview)
      end)
    end
    vim.wo[win].wrap = vim.go.wrap
    if hunk_index and file_diff.hunks[hunk_index] then
      vim.api.nvim_win_set_cursor(win, { math.max(1, file_diff.hunks[hunk_index].pos[1] + 1), 0 })
    end
    if focus then
      vim.api.nvim_set_current_win(win)
    elseif vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
  end

  local function open_change_source(file, selected_hunk, selected_line, focus, codecompanion_hunk_index)
    if type(file) ~= "table" or type(file.path) ~= "string" then return end
    local workspace = vim.b[buf].neolit_workspace
    local review = workspace and workspace.codecompanionReview
    local file_diff = review and review.diffs and review.diffs[file.path]
    if file_diff then
      local index = codecompanion_hunk_index
      if not index and selected_hunk then
        for i, hunk in ipairs(file_diff.hunks or {}) do
          local start = hunk.to_start or 1
          local finish = start + math.max(hunk.to_count or 0, 1) - 1
          local line = selected_hunk.newStart or selected_hunk.newLine or selected_hunk.line
          if line and line >= start and line <= finish then index = i; break end
        end
      end
      return open_codecompanion_diff(file, file_diff, index, focus)
    end
    local line
    if selected_line and selected_line.side == "+" then
      line = selected_line.lineNumber
    elseif selected_hunk then
      line = selected_hunk.newStart
    end
    local target = safe_repo_path(root, file.path)
    if not target or vim.fn.filereadable(target) ~= 1 then
      vim.notify("This change has no working-tree source file; use CodeCompanion review baseline or refresh", vim.log.levels.INFO)
      return
    end
    open_in_preview(file.path, line, focus)
  end

  local function refresh()
    refresh_revision = refresh_revision + 1
    local revision = refresh_revision
    if refresh_job then pcall(vim.fn.jobstop, refresh_job) end
    local url = vim.uri_from_fname(neolit_dir .. "/dist/planning/workspace.js")
    local comparison_base = vim.json.encode(cfg.comparison_base or "HEAD")
    local spec_path = vim.json.encode(cfg.spec_file or "SPEC.md")
    local todo_path = vim.json.encode(cfg.todo_file or "TODO.md")
    local js = "import { execFileSync } from \"node:child_process\"; "
      .. "const m = await import(" .. string.format("%q", url) .. "); "
      .. "const w = await m.loadPlanningWorkspace(process.cwd(), { comparisonBase: " .. comparison_base
      .. ", specPaths: [" .. spec_path .. "], todoPaths: [" .. todo_path .. "] }); "
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
          last_preview_key = nil
          last_cursor_line = nil
          clear_codecompanion_previews()
          codecompanion_review_diffs = nil
          codecompanion_review_loaded = false
          workspace.codecompanionReview = nil
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
    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) or vim.api.nvim_win_get_buf(tree) ~= buf then return end
    local row = vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(tree)[1]]
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
        open_change_source(changed, nil, nil, true)
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
        open_change_source(changed, nil, nil, true)
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
        open_change_source(row.file, nil, nil, true)
      else
        vim.notify("The linked changed file is no longer in the workspace; refresh", vim.log.levels.WARN)
      end
    elseif row.kind == "task_hunk" then
      if row.file and row.hunk then
        open_change_source(row.file, row.hunk, nil, true, row.ccHunkIndex)
      else
        vim.notify("The linked hunk is no longer in the workspace; refresh", vim.log.levels.WARN)
      end
    elseif row.kind == "file" then
      open_change_source(row.file, nil, nil, true)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_change_source(row.file, row.hunk,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, true)
    end
  end

  local current_row
  local selected_file_target
  local function preview_row(row)
    if not row then return end
    local path, line = selected_file_target(row)
    local preview_key = table.concat({
      tostring(row.kind), tostring(path or ""), tostring(line or ""),
      tostring(row.hunkIndex or row.ccHunkIndex or ""),
    }, ":")
    if preview_key == last_preview_key then return end
    last_preview_key = preview_key
    local workspace = vim.b[buf].neolit_workspace
    if row.kind == "planning_document" then
      open_in_preview(row.path, nil, false)
    elseif row.kind == "repository_file" then
      local changed
      for _, file in ipairs(workspace and workspace.git.changedFiles or {}) do
        if file.path == row.path or file.previousPath == row.path then changed = file; break end
      end
      if changed then
        open_change_source(changed, nil, nil, false)
      else
        open_in_preview(row.path, nil, false)
      end
    elseif row.kind == "task_change" then
      if row.file then open_change_source(row.file, nil, nil, false) end
    elseif row.kind == "task_hunk" then
      if row.file and row.hunk then
        open_change_source(row.file, row.hunk, nil, false, row.ccHunkIndex)
      end
    elseif row.kind == "file" then
      open_change_source(row.file, nil, nil, false)
    elseif row.kind == "hunk" or row.kind == "change_line" then
      open_change_source(row.file, row.hunk,
        row.kind == "change_line" and { side = row.side, lineNumber = row.lineNumber } or nil, false)
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
      if changed then open_change_source(changed, nil, nil, false)
      else open_in_preview(row.path, nil, false) end
    end
  end

  selected_file_target = function(row)
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
  local function copy_value(value, label)
    if type(value) ~= "string" or value == "" then
      vim.notify("Nothing to copy for this selection", vim.log.levels.INFO)
      return
    end
    vim.fn.setreg('"', value)
    local ok = pcall(vim.fn.setreg, "+", value)
    if not ok then
      vim.notify(label .. " yanked to unnamed register (clipboard unavailable)", vim.log.levels.INFO)
      return
    end
    vim.notify(label .. " yanked")
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

  local function copy_selected_context()
    local row = current_row()
    if not row then return end
    local path = selected_file_target(row) or row.path
      or (row.reference and row.reference.path)
      or (row.requirement and row.requirement.specPath)
      or (row.criterion and row.criterion.specPath)
    if type(path) ~= "string" or path == "" then
      vim.notify("This selection has no source path", vim.log.levels.INFO)
      return
    end
    local name = vim.fn.fnamemodify(path, ":t"):gsub("%[", "\\["):gsub("%]", "\\]")
    local link = "[" .. name .. ']("' .. path:gsub('"', '\\"') .. '")'
    local value = link
    local file = row.file
    local fence = string.rep(string.char(96), 3)
    if row.kind == "task_hunk" and file then
      local patch = not row.ccReviewEntry and extract_diff_hunk(file.rawDiff or "", row.hunkIndex) or nil
      local wanted_start = row.hunk and (row.hunk.newStart or row.hunk.to_start)
      if row.ccReviewEntry then
        local review = (vim.b[buf].neolit_workspace or {}).codecompanionReview
        local review_diff = review and review.diffs and review.diffs[path]
        local cc_index = row.ccReviewEntry.hunks and row.ccReviewEntry.hunks[1]
        local cc_hunk = review_diff and cc_index and review_diff.hunks[cc_index]
        wanted_start = cc_hunk and cc_hunk.to_start or wanted_start
      end
      if not patch and wanted_start then
        local collecting, parts = false, {}
        for _, line in ipairs(vim.split(file.rawDiff or "", "\n", { plain = true })) do
          local start = tonumber(line:match("^@@ %-%d+,?%d* %+(%d+)"))
          if start then
            if collecting then break end
            collecting = start == tonumber(wanted_start)
          end
          if collecting then parts[#parts + 1] = line end
        end
        if #parts > 0 then patch = table.concat(parts, "\n") end
      end
      if patch then value = link .. "\n\n" .. fence .. "diff\n" .. patch .. "\n" .. fence
      else
        vim.notify("Exact hunk patch is unavailable; refresh the workspace", vim.log.levels.WARN)
        return
      end
    elseif (row.kind == "file" or row.kind == "task_change" or row.kind == "changed_file") and file and file.rawDiff and file.rawDiff ~= "" then
      value = link .. "\n\n" .. fence .. "diff\n" .. file.rawDiff:gsub("\n$", "") .. "\n" .. fence
    elseif row.kind == "task" then
      value = link .. ":" .. tostring(row.task.range and row.task.range.startLine or 1)
        .. "\n" .. row.task.text
    elseif row.kind == "requirement" or row.kind == "task_requirement" then
      local requirement = row.requirement
      value = link .. ":" .. tostring(requirement.range and requirement.range.startLine or 1)
        .. "\n" .. requirement.id .. " " .. requirement.text
    elseif row.kind == "task_acceptance" or row.kind == "requirement_criterion" then
      local criterion = row.criterion
      value = link .. ":" .. tostring(criterion.range and criterion.range.startLine or 1)
        .. "\n" .. criterion.id .. " " .. criterion.text
    end
    copy_value(value, "Context")
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


  local function open_composed_view(mode, scope_path, selected_key)
    local workspace = vim.b[buf].neolit_workspace
    if type(workspace) ~= "table" then return end
    local lines, rows = {}, {}
    local function add(value, row)
      lines[#lines + 1] = value
      rows[#lines] = row
    end
    local task_states, requirement_states = {}, {}
    for key, projection in pairs((workspace.derived and workspace.derived.tasks) or {}) do
      task_states[key] = projection
    end
    for _, projection in ipairs((workspace.derived and workspace.derived.requirements) or {}) do
      requirement_states[projection.specPath .. "#" .. projection.requirementId] = projection
    end
    local function task_path(task)
      return task.key and task.key:match("^(.-)::") or nil
    end
    local function task_state(task)
      local projection = task_states[task.key]
      return projection and projection.state or task.state or "planned", projection
    end
    local function requirement_tasks(spec_path, requirement_id)
      local result = {}
      for _, task in ipairs(workspace.tasks or {}) do
        for _, requirement in ipairs(task.resolvedRequirements or {}) do
          if requirement.specPath == spec_path and requirement.id == requirement_id then
            result[#result + 1] = task
            break
          end
        end
      end
      return result
    end
    local function state_mark(state)
      return tostring(state or "unmapped"):upper()
    end
    local function is_expanded(key)
      return composed_expanded[key] == true
    end
    local function source_row(kind, path, range, text, extra)
      local row = {
        kind = kind, path = path,
        line = range and range.startLine or 1,
        first = range and range.startLine or 1,
        last = range and range.endLine or (range and range.startLine or 1),
        text = text,
      }
      for key, value in pairs(extra or {}) do row[key] = value end
      return row
    end
    local function context_key(row)
      if not row then return nil end
      if row.kind == "changed_file" then return "diff:" .. row.path end
      if row.kind == "task_hunk" then
        return "hunk:" .. row.path .. ":" .. tostring(row.hunkIndex)
      end
      if row.path and row.first then
        return row.path .. ":" .. row.kind .. ":" .. tostring(row.first) .. ":"
          .. tostring(row.last) .. (row.kind == "task_detail" and (":" .. tostring(row.text)) or "")
      end
    end
    local scoped_task_count, scoped_requirement_count = 0, 0
    if mode == "requirements" then
      local included_tasks, included_specs = {}, {}
      if not scope_path then
        for _, spec in ipairs(workspace.specs or {}) do included_specs[spec.path] = true end
      else
        for _, spec in ipairs(workspace.specs or {}) do
          if spec.path == scope_path then included_specs[spec.path] = true end
        end
        if not included_specs[scope_path] then
          for _, task in ipairs(workspace.tasks or {}) do
            if task_path(task) == scope_path then
              for _, requirement in ipairs(task.resolvedRequirements or {}) do included_specs[requirement.specPath] = true end
            end
          end
        end
      end
      for _, spec in ipairs(workspace.specs or {}) do
        if included_specs[spec.path] then
          scoped_requirement_count = scoped_requirement_count + #(spec.requirements or {})
          for _, requirement in ipairs(spec.requirements or {}) do
            for _, task in ipairs(requirement_tasks(spec.path, requirement.id)) do included_tasks[task.key] = true end
          end
        end
      end
      for _ in pairs(included_tasks) do scoped_task_count = scoped_task_count + 1 end
    else
      local included_requirements = {}
      for _, task in ipairs(workspace.tasks or {}) do
        local include = not scope_path or task_path(task) == scope_path
        if scope_path and not include then
          for _, requirement in ipairs(task.resolvedRequirements or {}) do
            if requirement.specPath == scope_path then include = true; break end
          end
        end
        if include then
          scoped_task_count = scoped_task_count + 1
          for _, requirement in ipairs(task.resolvedRequirements or {}) do
            included_requirements[requirement.specPath .. "#" .. requirement.id] = true
          end
        end
      end
      for _ in pairs(included_requirements) do scoped_requirement_count = scoped_requirement_count + 1 end
    end
    add("NEOLIT · " .. (mode == "tasks" and "TASKS" or "REQUIREMENTS")
      .. (scope_path and (" · " .. vim.fn.fnamemodify(scope_path, ":t")) or "")
      .. " · " .. scoped_requirement_count .. " req · " .. scoped_task_count .. " tasks"
      .. " · ctx " .. #context_chunks .. " · za details · <leader>np review · <leader>na add · <leader>n- remove · <leader>ny copy · <leader>nc clear · <leader>nm chat",
      { kind = "header" })

    if mode == "requirements" then
      local scoped_specs = {}
      if scope_path then
        for _, spec in ipairs(workspace.specs or {}) do
          if spec.path == scope_path then scoped_specs[spec.path] = true end
        end
        if not scoped_specs[scope_path] then
          for _, task in ipairs(workspace.tasks or {}) do
            if task_path(task) == scope_path then
              for _, requirement in ipairs(task.resolvedRequirements or {}) do
                scoped_specs[requirement.specPath] = true
              end
            end
          end
        end
      end
      for _, spec in ipairs(workspace.specs or {}) do
        if not scope_path or scoped_specs[spec.path] then
          add(spec.path, { kind = "document", path = spec.path, line = 1 })
          for _, requirement in ipairs(spec.requirements or {}) do
            local ref = spec.path .. "#" .. requirement.id
            local projection = requirement_states[ref]
            local linked = requirement_tasks(spec.path, requirement.id)
            local state = projection and projection.state or "unplanned"
            local criterion_count = 0
            for _, criterion in ipairs(spec.acceptanceCriteria or {}) do
              if vim.tbl_contains(criterion.requirementIds or {}, requirement.id) then criterion_count = criterion_count + 1 end
            end
            local marker = is_expanded("req:" .. ref) and "-" or "+"
            add("  " .. marker .. " " .. requirement.id .. " [" .. state_mark(state) .. "] "
              .. requirement.text .. " · " .. #linked .. " tasks · " .. criterion_count .. " AC",
              source_row("requirement", spec.path, requirement.range, requirement.text,
                { requirement = requirement, state = state, ref = ref, key = "req:" .. ref,
                  expanded = is_expanded("req:" .. ref) }))
            if is_expanded("req:" .. ref) then
              if #linked == 0 then
                add("    (no linked tasks)", { kind = "empty" })
              else
                for _, task in ipairs(linked) do
                  local task_state_value, task_projection = task_state(task)
                  local todo = task_path(task)
                  local task_key = "task:" .. task.key
                  local changed = #(task_projection and task_projection.changedPaths or {})
                  local task_criteria = 0
                  for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
                    local linked = criterion.specPath == spec.path
                      and vim.tbl_contains(criterion.requirementIds or {}, requirement.id)
                    if not linked and criterion.specPath == spec.path and #(criterion.requirementIds or {}) == 0
                      and #(task.resolvedRequirements or {}) == 1 then
                      local only = task.resolvedRequirements[1]
                      linked = only.specPath == spec.path and only.id == requirement.id
                    end
                    if linked then task_criteria = task_criteria + 1 end
                  end
                  local marker_task = is_expanded(task_key) and "-" or "+"
                  add("    " .. marker_task .. " " .. (task.checked and "[x] " or "[ ] ")
                    .. "[" .. state_mark(task_state_value) .. "] " .. task.text
                    .. " · " .. task_criteria .. " AC · " .. changed .. " files",
                    source_row("task", todo, task.range, task.text,
                      { task = task, state = task_state_value, projection = task_projection,
                        key = task_key, expanded = is_expanded(task_key) }))
                  if is_expanded(task_key) then
                    for _, detail in ipairs(task.description or {}) do
                      add("      " .. detail, source_row("task_detail", todo, task.range, detail, { task = task }))
                    end
                    for _, note in ipairs(task.agentNotes or {}) do
                      add("      AGENT · " .. note, source_row("task_detail", todo, task.range, note, { task = task }))
                    end
                    for _, changed_path in ipairs((task_projection and task_projection.changedPaths) or {}) do
                      add("      + " .. changed_path, { kind = "changed_file", path = changed_path, line = 1 })
                    end
                  end
                end
              end
              for _, criterion in ipairs(spec.acceptanceCriteria or {}) do
                if vim.tbl_contains(criterion.requirementIds or {}, requirement.id) then
                  local covered, verified = false, false
                  for _, task in ipairs(linked) do
                    for _, item in ipairs(task.resolvedAcceptanceCriteria or {}) do
                      if item.specPath == spec.path and item.id == criterion.id then covered = true end
                    end
                    local projection = task_states[task.key]
                    for _, evidence in ipairs((projection and projection.acceptanceCriteria) or {}) do
                      if evidence.ref == (spec.path .. "#" .. criterion.id) and evidence.verified then verified = true end
                    end
                  end
                  local label = verified and "VERIFIED" or covered and "LINKED" or "UNCOVERED"
                  add("    AC " .. criterion.id .. " [" .. label .. "] " .. criterion.text,
                    source_row("criterion", spec.path, criterion.range, criterion.text,
                      { criterion = criterion, verified = verified }))
                end
              end
            end
          end
        end
      end
    else
      local previous_path
      for _, task in ipairs(workspace.tasks or {}) do
        local todo = task_path(task)
        local included = not scope_path or todo == scope_path
        if scope_path and not included then
          for _, requirement in ipairs(task.resolvedRequirements or {}) do
            if requirement.specPath == scope_path then included = true; break end
          end
        end
        if included then
          if todo ~= previous_path then
            previous_path = todo
            add(todo or "TODO", { kind = "document", path = todo, line = 1 })
          end
          local state, projection = task_state(task)
          local task_key = "task:" .. task.key
          local linked_count = #(task.resolvedRequirements or {})
          local criterion_count = #(task.resolvedAcceptanceCriteria or {})
          local changed_count = #(projection and projection.changedPaths or {})
          add("  " .. (is_expanded(task_key) and "-" or "+") .. " "
            .. (task.checked and "[x] " or "[ ] ") .. "[" .. state_mark(state) .. "] " .. task.text
            .. " · " .. linked_count .. " SPEC · " .. criterion_count .. " AC · " .. changed_count .. " files",
            source_row("task", todo, task.range, task.text,
              { task = task, state = state, projection = projection,
                key = task_key, expanded = is_expanded(task_key) }))
          if is_expanded(task_key) then
            for _, requirement in ipairs(task.resolvedRequirements or {}) do
              add("    SPEC " .. requirement.id .. " · " .. requirement.text,
                source_row("requirement", requirement.sourcePath or requirement.specPath,
                  requirement.range, requirement.text, { requirement = requirement }))
            end
            for _, criterion in ipairs(task.resolvedAcceptanceCriteria or {}) do
              local ref = criterion.specPath .. "#" .. criterion.id
              local verified = false
              for _, evidence in ipairs((projection and projection.acceptanceCriteria) or {}) do
                if evidence.ref == ref and evidence.verified then verified = true; break end
              end
              add("    AC " .. criterion.id .. " [" .. (verified and "VERIFIED" or "UNVERIFIED") .. "] " .. criterion.text,
                source_row("criterion", criterion.sourcePath or criterion.specPath,
                  criterion.range, criterion.text, { criterion = criterion, verified = verified }))
            end
            for _, detail in ipairs(task.description or {}) do
              add("    " .. detail, source_row("task_detail", todo, task.range, detail, { task = task }))
            end
            for _, note in ipairs(task.agentNotes or {}) do
              add("    AGENT · " .. note, source_row("task_detail", todo, task.range, note, { task = task }))
            end
            for _, changed_path in ipairs((projection and projection.changedPaths) or {}) do
              add("    + " .. changed_path, { kind = "changed_file", path = changed_path, line = 1 })
            end
          end
        end
      end
    end
    if #lines == 1 then add("  (no matching planning entries)", { kind = "empty" }) end

    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) then return end
    local win = view_state.preview_win
    if not win or not vim.api.nvim_win_is_valid(win) or win == tree
      or vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(tree)
      vim.cmd("rightbelow vsplit")
      win = vim.api.nvim_get_current_win()
      view_state.preview_win = win
    end
    if win == tree or vim.api.nvim_win_get_buf(tree) ~= buf then
      vim.notify("Neolit window roles are inconsistent; close and reopen :Neolit", vim.log.levels.ERROR)
      return
    end
    local view_buf = composed_view_buf
    if not view_buf or not vim.api.nvim_buf_is_valid(view_buf) then
      view_buf = vim.api.nvim_create_buf(false, true)
      composed_view_buf = view_buf
      vim.bo[view_buf].buftype = "nofile"
      vim.bo[view_buf].bufhidden = "hide"
      vim.bo[view_buf].swapfile = false
      vim.bo[view_buf].buflisted = false
      vim.bo[view_buf].filetype = "neolit-view"
    end
    vim.bo[view_buf].modifiable = true
    vim.api.nvim_buf_set_lines(view_buf, 0, -1, false, lines)
    vim.bo[view_buf].modifiable = false
    vim.api.nvim_win_set_buf(win, view_buf)
    vim.wo[win].wrap = vim.go.wrap
    vim.wo[win].cursorline = true
    local ns = vim.api.nvim_create_namespace("neolit-composed-view-" .. view_buf)
    vim.api.nvim_buf_clear_namespace(view_buf, ns, 0, -1)
    for line, row in pairs(rows) do
      if row.kind == "header" or row.kind == "document" then
        vim.api.nvim_buf_add_highlight(view_buf, ns, "Title", line - 1, 0, -1)
      elseif row.kind == "requirement" then
        vim.api.nvim_buf_add_highlight(view_buf, ns,
          row.state == "verified" and "DiagnosticOk" or row.state == "blocked" and "DiagnosticError" or "Identifier",
          line - 1, 0, -1)
      elseif row.kind == "task" then
        local group = "Normal"
        if row.state == "verified" or row.state == "implemented" then group = "DiagnosticOk"
        elseif row.state == "blocked" then group = "DiagnosticError"
        elseif row.state == "in-progress" or row.state == "unmapped" then group = "DiagnosticWarn" end
        vim.api.nvim_buf_add_highlight(view_buf, ns, group, line - 1, 0, -1)
      elseif row.kind == "criterion" then
        vim.api.nvim_buf_add_highlight(view_buf, ns, row.verified and "DiagnosticOk" or "DiagnosticWarn", line - 1, 0, -1)
      elseif row.kind == "changed_file" then
        vim.api.nvim_buf_add_highlight(view_buf, ns, "Directory", line - 1, 0, -1)
      end
    end
    local function selected_view_row()
      return rows[vim.api.nvim_win_get_cursor(win)[1]]
    end
    local function navigate()
      local row = selected_view_row()
      if not row then return end
      if row.kind == "task_hunk" then
        local changed = row.file
        if changed then open_change_source(changed, row.hunk, nil, true) end
      elseif row.kind == "changed_file" then
        local target = safe_repo_path(root, row.path)
        local loaded = target and vim.fn.bufnr(target) or -1
        if loaded >= 0 and vim.bo[loaded].modified then
          vim.notify("Write the modified buffer before adding its diff to context", vim.log.levels.WARN)
          return
        end
        local changed
        for _, file in ipairs(workspace.git.changedFiles or {}) do
          if file.path == row.path or file.previousPath == row.path then changed = file; break end
        end
        if changed then open_change_source(changed, nil, nil, true)
        else
          local target = safe_repo_path(root, row.path)
          if target and vim.fn.filereadable(target) == 1 then open_in_preview(row.path, row.line, true) end
        end
      elseif row.path and row.kind ~= "empty" and row.kind ~= "header" then
        open_in_preview(row.path, row.line, true)
      end
    end
    local function copy_chunk()
      local row = selected_view_row()
      if not row then return end
      if row.kind == "task_hunk" then
        local hunk = extract_diff_hunk(row.file and row.file.rawDiff or "", row.hunkIndex)
        if hunk then copy_value(hunk, "Diff hunk")
        else vim.notify("Exact hunk patch is unavailable; refresh the workspace", vim.log.levels.WARN) end
        return
      end
      if not row.path or not row.first then return end
      local target = safe_repo_path(root, row.path)
      if not target or vim.fn.filereadable(target) ~= 1 then
        vim.notify("Source chunk is no longer available; refresh the workspace", vim.log.levels.WARN)
        return
      end
      if row.kind == "task_detail" then
        copy_value(row.text or "", "Task detail")
        return
      end
      local source_lines = vim.fn.readfile(target)
      local chunk = {}
      for index = row.first, math.min(row.last or row.first, #source_lines) do
        chunk[#chunk + 1] = source_lines[index]
      end
      copy_value(table.concat(chunk, "\n"), row.kind == "task" and "TODO task" or "Planning chunk")
    end
    local context_ns = vim.api.nvim_create_namespace("neolit-context-selection-" .. view_buf)
    local function update_context_header()
      if not vim.api.nvim_buf_is_valid(view_buf) then return end
      local header = vim.api.nvim_buf_get_lines(view_buf, 0, 1, false)[1] or ""
      header = header:gsub("ctx %d+", "ctx " .. #context_chunks)
      vim.bo[view_buf].modifiable = true
      vim.api.nvim_buf_set_lines(view_buf, 0, 1, false, { header })
      vim.bo[view_buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(view_buf, context_ns, 0, -1)
      for line, row in pairs(rows) do
        if context_keys[context_key(row)] then
          pcall(vim.api.nvim_buf_set_extmark, view_buf, context_ns, line - 1, 0, {
            virt_text = { { "● ", "DiagnosticOk" } },
            virt_text_pos = "inline",
            priority = 150,
          })
        end
      end
    end
    local function append_context()
      local row = selected_view_row()
      if not row then return end
      local label, content, key, expected_source, expected_diff
      if row.kind == "changed_file" then
        local target = safe_repo_path(root, row.path)
        local loaded = target and vim.fn.bufnr(target) or -1
        if loaded >= 0 and vim.bo[loaded].modified then
          vim.notify("Write the modified buffer before adding its diff to context", vim.log.levels.WARN)
          return
        end
        local changed
        for _, file in ipairs(workspace.git.changedFiles or {}) do
          if file.path == row.path or file.previousPath == row.path then changed = file; break end
        end
        if not changed or not changed.rawDiff or changed.rawDiff == "" then
          vim.notify("No current diff is available for this file", vim.log.levels.INFO)
          return
        end
        label, content = row.path, changed.rawDiff
        expected_diff = changed.rawDiff
        key = "diff:" .. row.path
      elseif row.kind == "file_hint" then
        if not safe_repo_path(root, row.path) then
          vim.notify("Unsafe repository path; cannot add it to context", vim.log.levels.WARN)
          return
        end
        label, content = row.path, row.path
        key = "path:" .. row.path
      elseif row.kind == "task_hunk" then
        local target = safe_repo_path(root, row.path)
        local loaded = target and vim.fn.bufnr(target) or -1
        if loaded >= 0 and vim.bo[loaded].modified then
          vim.notify("Write the modified buffer before adding its hunk to context", vim.log.levels.WARN)
          return
        end
        local changed = row.file
        if not changed then
          for _, file in ipairs(workspace.git.changedFiles or {}) do
            if file.path == row.path or file.previousPath == row.path then changed = file; break end
          end
        end
        if not changed or not changed.rawDiff then
          vim.notify("No current diff is available for this hunk", vim.log.levels.WARN)
          return
        end
        local hunk = extract_diff_hunk(changed.rawDiff, row.hunkIndex)
        if not hunk then
          vim.notify("Exact hunk patch is unavailable; refresh the workspace", vim.log.levels.WARN)
          return
        end
        label = row.path .. " · hunk " .. tostring(row.hunkIndex + 1)
        content, expected_diff = hunk, changed.rawDiff
        key = context_key(row)
      elseif row.path and row.first then
        local target = safe_repo_path(root, row.path)
        if not target or vim.fn.filereadable(target) ~= 1 then
          vim.notify("Source chunk is no longer available; refresh the workspace", vim.log.levels.WARN)
          return
        end
        local loaded = vim.fn.bufnr(target)
        if loaded >= 0 and vim.bo[loaded].modified then
          vim.notify("Write the modified planning buffer before adding its chunk to context", vim.log.levels.WARN)
          return
        end
        local source_lines = vim.fn.readfile(target)
        local chunk = {}
        for index = row.first, math.min(row.last or row.first, #source_lines) do
          chunk[#chunk + 1] = source_lines[index]
        end
        expected_source = table.concat(chunk, "\n")
        if row.kind == "task_detail" then
          content = row.text or ""
          label = row.path .. ":" .. tostring(row.line) .. " (detail)"
        else
          content = expected_source
          label = row.path .. ":" .. tostring(row.first)
        end
        key = context_key(row)
      else
        vim.notify("Select a requirement, task, criterion, detail, or changed file", vim.log.levels.INFO)
        return
      end
      if context_keys[key] then
        vim.notify("Chunk is already in the context", vim.log.levels.INFO)
        return
      end
      context_keys[key] = true
      context_chunks[#context_chunks + 1] = {
        key = key, label = label, content = content, path = row.path,
        first = row.first, last = row.last, kind = row.kind,
        expected_source = expected_source, expected_diff = expected_diff,
      }
      update_context_header()
      vim.notify("Added context chunk (" .. #context_chunks .. ")")
    end
    local function remove_context()
      local key = context_key(selected_view_row())
      if not key or not context_keys[key] then
        vim.notify("Selected chunk is not in the context", vim.log.levels.INFO)
        return
      end
      for index, item in ipairs(context_chunks) do
        if item.key == key then table.remove(context_chunks, index); break end
      end
      context_keys[key] = nil
      update_context_header()
      vim.notify("Removed context chunk (" .. #context_chunks .. " remaining)")
    end
    local function compose_context()
      if #context_chunks == 0 then
        vim.notify("Context is empty", vim.log.levels.INFO)
        return nil
      end
      local current = vim.b[buf].neolit_workspace or workspace
      local output = {}
      for _, item in ipairs(context_chunks) do
        if item.expected_diff then
          local target = safe_repo_path(root, item.path)
          local loaded = target and vim.fn.bufnr(target) or -1
          if loaded >= 0 and vim.bo[loaded].modified then
            vim.notify("Context is stale: write the modified buffer before copying", vim.log.levels.WARN)
            return
          end
          local changed
          for _, file in ipairs(current.git.changedFiles or {}) do
            if file.path == item.path or file.previousPath == item.path then changed = file; break end
          end
          if not changed then
            vim.notify("Context is stale: " .. item.path .. " is no longer changed; refresh and re-add it", vim.log.levels.WARN)
            return
          end
          local result = vim.system(diff_command(changed, current.git.base), { cwd = root, text = true }):wait()
          if result.code > 1 or normalize_diff(result.stdout or "") ~= normalize_diff(item.expected_diff) then
            vim.notify("Context is stale: diff changed for " .. item.path .. "; refresh and re-add it", vim.log.levels.WARN)
            return
          end
        elseif item.expected_source then
          local target = safe_repo_path(root, item.path)
          if not target or vim.fn.filereadable(target) ~= 1 then
            vim.notify("Context is stale: source disappeared at " .. item.path, vim.log.levels.WARN)
            return
          end
          local loaded = vim.fn.bufnr(target)
          if loaded >= 0 and vim.bo[loaded].modified then
            vim.notify("Context is stale: write the modified buffer before copying", vim.log.levels.WARN)
            return
          end
          local source_lines = vim.fn.readfile(target)
          local chunk = {}
          for index = item.first, math.min(item.last or item.first, #source_lines) do
            chunk[#chunk + 1] = source_lines[index]
          end
          if table.concat(chunk, "\n") ~= item.expected_source then
            vim.notify("Context is stale: source changed at " .. item.path .. "; refresh and re-add it", vim.log.levels.WARN)
            return
          end
        end
        output[#output + 1] = item.label .. "\n" .. item.content
      end
      return table.concat(output, "\n\n")
    end
    local function copy_context()
      local output = compose_context()
      if output then copy_value(output, "Composed context") end
    end
    local function add_context_to_codecompanion()
      local context = compose_context()
      if context then copy_value(context, "Composed context") end
    end
    local function open_codecompanion_chat()
      if vim.fn.exists(":CodeCompanionChat") ~= 2 then
        vim.notify("CodeCompanion.nvim is required for Neolit chat", vim.log.levels.ERROR)
        return
      end
      local adapter = (cfg.codecompanion and cfg.codecompanion.adapter) or "opencode"
      if type(adapter) ~= "string" or not adapter:match("^[%w_%-]+$") then
        vim.notify("Invalid CodeCompanion adapter name", vim.log.levels.ERROR)
        return
      end
      vim.cmd("lcd " .. vim.fn.fnameescape(root))
      local ok, err = pcall(vim.cmd, "CodeCompanionChat adapter=" .. adapter)
      if not ok then vim.notify("Could not open CodeCompanion chat: " .. tostring(err), vim.log.levels.ERROR) end
    end
    local function clear_context()
      context_chunks, context_keys = {}, {}
      update_context_header()
      vim.notify("Context cleared")
    end
    local function open_context_view(return_to)
      local packet_lines, packet_rows = {}, {}
      local function packet_add(line, row)
        packet_lines[#packet_lines + 1] = line
        packet_rows[#packet_lines] = row
      end
      packet_add("NEOLIT · CONTEXT · " .. #context_chunks
        .. " chunks · <leader>ny copy · <leader>n- remove · <leader>nc clear · q back", { kind = "header" })
      for index, item in ipairs(context_chunks) do
        local line_count = item.content and (#item.content > 0 and select(2, item.content:gsub("\n", "")) + 1 or 0) or 0
        local first_line = item.content and (item.content:match("([^\n]+)") or "") or ""
        first_line = first_line:gsub("^%s+", ""):gsub("%s+$", "")
        if #first_line > 88 then first_line = first_line:sub(1, 85) .. "..." end
        packet_add(string.format("  %d · %s · %d lines · %d bytes",
          index, item.label, line_count, #(item.content or "")), { index = index, kind = "chunk" })
        if first_line ~= "" then
          packet_add("      " .. first_line, { kind = "excerpt", index = index })
        end
      end
      if #context_chunks == 0 then packet_add("  (context is empty)", { kind = "empty" }) end
      local packet_buf = context_view_buf
      if not packet_buf or not vim.api.nvim_buf_is_valid(packet_buf) then
        packet_buf = vim.api.nvim_create_buf(false, true)
        context_view_buf = packet_buf
        vim.bo[packet_buf].buftype = "nofile"
        vim.bo[packet_buf].bufhidden = "hide"
        vim.bo[packet_buf].swapfile = false
        vim.bo[packet_buf].buflisted = false
        vim.bo[packet_buf].filetype = "neolit-context"
      end
      vim.bo[packet_buf].modifiable = true
      vim.api.nvim_buf_set_lines(packet_buf, 0, -1, false, packet_lines)
      vim.bo[packet_buf].modifiable = false
      vim.api.nvim_win_set_buf(win, packet_buf)
      vim.wo[win].wrap = vim.go.wrap
      local packet_ns = vim.api.nvim_create_namespace("neolit-context-view-" .. packet_buf)
      vim.api.nvim_buf_clear_namespace(packet_buf, packet_ns, 0, -1)
      for line, row in pairs(packet_rows) do
        if row.kind == "header" then
          vim.api.nvim_buf_add_highlight(packet_buf, packet_ns, "Title", line - 1, 0, -1)
        elseif row.kind == "chunk" then
          vim.api.nvim_buf_add_highlight(packet_buf, packet_ns, "Identifier", line - 1, 0, -1)
        elseif row.kind == "excerpt" then
          vim.api.nvim_buf_add_highlight(packet_buf, packet_ns, "Comment", line - 1, 0, -1)
        end
      end
      local function selected_packet_row()
        return packet_rows[vim.api.nvim_win_get_cursor(win)[1]]
      end
      local function remove_packet_item()
        local row = selected_packet_row()
        if not row or not row.index then return end
        local item = table.remove(context_chunks, row.index)
        if item then context_keys[item.key] = nil end
        open_context_view()
      end
      bind_key(packet_buf, cfg, "context_copy", "<leader>ny", copy_context)
      bind_key(packet_buf, cfg, "context_remove", "<leader>nd", remove_packet_item)
      bind_key(packet_buf, cfg, "context_clear", "<leader>nc", function()
        clear_context()
        open_context_view()
      end)
      bind_key(packet_buf, cfg, "view_back", "<leader>nq", function()
        if return_to then return_to() else open_composed_view(mode, scope_path) end
      end)
      bind_key(packet_buf, cfg, "view_help", "?", function()
        vim.notify("Context: <leader>ny copy · <leader>n- remove · <leader>nc clear · q back", vim.log.levels.INFO)
      end)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
    bind_key(view_buf, cfg, "open_source", "<leader>no", navigate)
    bind_key(view_buf, cfg, "tree_fold_toggle", "za", function()
      local row = selected_view_row()
      if not row or (row.kind ~= "task" and row.kind ~= "requirement") or not row.key then return end
      composed_expanded[row.key] = not composed_expanded[row.key]
      open_composed_view(mode, scope_path, row.key)
    end)
    bind_key(view_buf, cfg, "view_help", "<leader>n?", function()
      vim.notify("Workspace: za expand/collapse · <leader>ns task scope · <leader>np review · o source · <leader>na add · <leader>n- remove · <leader>ny copy · <leader>nc clear · <leader>nx copy · <leader>nl path · <leader>nv switch · <leader>nm chat · <leader>nM send context to chat · <leader>nq back", vim.log.levels.INFO)
    end)
    bind_key(view_buf, cfg, "copy_source", "<leader>nx", copy_chunk)
    bind_key(view_buf, cfg, "context_add", "<leader>na", append_context)
    bind_key(view_buf, cfg, "context_remove", "<leader>nd", remove_context)
    local function open_task_scope(task, selected_key)
      local projection = task_states[task.key] or {}
      local scope_lines, scope_rows = {}, {}
      local function scope_add(value, row)
        scope_lines[#scope_lines + 1] = value
        scope_rows[#scope_lines] = row or { kind = "section" }
      end
      local state = projection.state or task.state or "planned"
      local requirements = task.resolvedRequirements or {}
      local criteria = task.resolvedAcceptanceCriteria or {}
      local hints = task.filePaths or {}
      local changed_paths = projection.changedPaths or {}
      local hunk_reviews = projection.hunkReviews or {}
      local diagnostics = {}
      for _, diagnostic in ipairs(workspace.diagnostics or {}) do
        if diagnostic.taskKey == task.key then diagnostics[#diagnostics + 1] = diagnostic end
      end
      local changed_set = {}
      for _, path in ipairs(changed_paths) do changed_set[path] = true end
      for _, review in ipairs(hunk_reviews) do changed_set[review.path] = true end
      local other_changes = {}
      for _, file in ipairs(workspace.git.changedFiles or {}) do
        if not changed_set[file.path] then other_changes[#other_changes + 1] = file end
      end
      scope_add("NEOLIT · TASK SCOPE · OBSERVED · za expand · o open · <leader>nx copy · <leader>na add context · <leader>n- remove context · <leader>nq back · ?",
        { kind = "header" })
      scope_add("[" .. state_mark(state) .. "] " .. task.text,
        source_row("task", task_path(task), task.range, task.text, { task = task }))
      scope_add(#requirements .. " SPEC · " .. #criteria .. " AC · " .. #hints
        .. " hints · " .. #changed_paths .. " changed · " .. #hunk_reviews
        .. " hunks · " .. #other_changes .. " other · " .. #diagnostics .. " issues",
        { kind = "summary" })
      scope_add("STATE · " .. state_reason(state, projection), { kind = "summary" })

      local function scope_section(key, label, items)
        if #items == 0 and key ~= "hints" then return end
        local expanded = scope_expanded[task.key .. ":" .. key] == true
        scope_add((expanded and "  ﹀ " or "  ﹥ ") .. label .. " · " .. #items,
          { kind = "section", key = "scope-section:" .. key, section_key = key })
        if expanded then
          if #items == 0 then
            scope_add("      (none)", { kind = "empty" })
          else
            for _, item in ipairs(items) do scope_add("    " .. item.text, item.row) end
          end
        end
      end
      local intent_items, note_items, requirement_items, criterion_items = {}, {}, {}, {}
      local hint_items, change_items, hunk_items, other_items = {}, {}, {}, {}
      local diagnostic_items, unresolved_items = {}, {}
      for _, detail in ipairs(task.description or {}) do
        intent_items[#intent_items + 1] = {
          text = detail,
          row = source_row("task_detail", task_path(task), task.range, detail, { task = task }),
        }
      end
      for _, note in ipairs(task.agentNotes or {}) do
        note_items[#note_items + 1] = {
          text = note,
          row = source_row("task_detail", task_path(task), task.range, note, { task = task }),
        }
      end
      for _, requirement in ipairs(requirements) do
        requirement_items[#requirement_items + 1] = {
          text = requirement.id .. " · " .. requirement.text,
          row = source_row("requirement", requirement.sourcePath or requirement.specPath,
            requirement.range, requirement.text, { requirement = requirement }),
        }
      end
      for _, criterion in ipairs(criteria) do
        local ref = criterion.specPath .. "#" .. criterion.id
        local verified = false
        for _, evidence in ipairs(projection.acceptanceCriteria or {}) do
          if evidence.ref == ref and evidence.verified then verified = true; break end
        end
        criterion_items[#criterion_items + 1] = {
          text = criterion.id .. " [" .. (verified and "VERIFIED" or "UNVERIFIED") .. "] " .. criterion.text,
          row = source_row("criterion", criterion.sourcePath or criterion.specPath,
            criterion.range, criterion.text, { criterion = criterion, verified = verified }),
        }
      end
      for _, path in ipairs(hints) do
        hint_items[#hint_items + 1] = {
          text = path,
          row = { kind = "file_hint", path = path, line = 1, first = 1, last = 1 },
        }
      end
      for _, path in ipairs(changed_paths) do
        change_items[#change_items + 1] = {
          text = "+ " .. path,
          row = { kind = "changed_file", path = path, line = 1 },
        }
      end
      for _, review in ipairs(hunk_reviews) do
        local file
        for _, candidate in ipairs(workspace.git.changedFiles or {}) do
          if candidate.path == review.path then file = candidate; break end
        end
        local association
        for _, candidate in ipairs(workspace.git.hunkAssociations or {}) do
          if candidate.path == review.path and candidate.hunkIndex == review.hunkIndex then
            association = candidate
            break
          end
        end
        hunk_items[#hunk_items + 1] = {
          text = review.path .. "#" .. tostring(review.hunkIndex + 1)
            .. " [" .. tostring(review.state):upper() .. "] · " .. tostring(review.reason),
          row = { kind = "task_hunk", path = review.path, line = 1, file = file,
            hunkIndex = review.hunkIndex, hunk = find_changed_hunk(file, review.hunkIndex),
            hunkAssociation = association },
        }
      end
      for _, file in ipairs(other_changes) do
        other_items[#other_items + 1] = {
          text = "? " .. file.path,
          row = { kind = "changed_file", path = file.path, line = 1 },
        }
      end
      for _, diagnostic in ipairs(diagnostics) do
        diagnostic_items[#diagnostic_items + 1] = {
          text = "! " .. diagnostic.message,
          row = { kind = "empty" },
        }
      end
      for _, reference in ipairs(task.unresolvedReferences or {}) do
        unresolved_items[#unresolved_items + 1] = {
          text = reference.path .. " · " .. table.concat(reference.ids or {}, ", "),
          row = { kind = "empty" },
        }
      end
      scope_section("intent", "INTENT", intent_items)
      scope_section("notes", "AGENT NOTES", note_items)
      scope_section("requirements", "REQUIREMENTS", requirement_items)
      scope_section("criteria", "ACCEPTANCE", criterion_items)
      scope_section("hints", "FILE HINTS · relevance only", hint_items)
      scope_section("changes", "OBSERVED CHANGES", change_items)
      if cfg.change_view == "hunks" then
        scope_section("hunks", "HUNK EVIDENCE", hunk_items)
      end
      scope_section("other", "OTHER CHANGED PATHS", other_items)
      scope_section("diagnostics", "DIAGNOSTICS", diagnostic_items)
      scope_section("unresolved", "UNRESOLVED REFERENCES", unresolved_items)
      scope_add("Hints are not permission limits; unrelated changes remain visible.", { kind = "footnote" })

      rows = scope_rows
      vim.bo[view_buf].modifiable = true
      vim.api.nvim_buf_set_lines(view_buf, 0, -1, false, scope_lines)
      vim.bo[view_buf].modifiable = false
      vim.api.nvim_buf_clear_namespace(view_buf, ns, 0, -1)
      for line, row in pairs(scope_rows) do
        if row.kind == "header" then
          vim.api.nvim_buf_add_highlight(view_buf, ns, "Title", line - 1, 0, -1)
        elseif row.kind == "section" then
          vim.api.nvim_buf_add_highlight(view_buf, ns, "Special", line - 1, 0, -1)
        elseif row.kind == "task_hunk" then
          vim.api.nvim_buf_add_highlight(view_buf, ns, "DiagnosticWarn", line - 1, 0, -1)
        elseif row.kind == "changed_file" then
          vim.api.nvim_buf_add_highlight(view_buf, ns, "Directory", line - 1, 0, -1)
        elseif row.kind == "footnote" or row.kind == "empty" then
          vim.api.nvim_buf_add_highlight(view_buf, ns, "Comment", line - 1, 0, -1)
        end
      end
      bind_key(view_buf, cfg, "open_source", "<CR>", navigate)
      bind_key(view_buf, cfg, "copy_source", "<leader>nx", copy_chunk)
      bind_key(view_buf, cfg, "context_add", "<leader>na", append_context)
      bind_key(view_buf, cfg, "chat_context", "<leader>nM", add_context_to_codecompanion)
      bind_key(view_buf, cfg, "context_remove", "<leader>nd", remove_context)
      bind_key(view_buf, cfg, "tree_fold_toggle", "za", function()
        local row = selected_view_row()
        if not row or row.kind ~= "section" or not row.section_key then return end
        local key = task.key .. ":" .. row.section_key
        scope_expanded[key] = not scope_expanded[key]
        open_task_scope(task, row.key)
      end)
      bind_key(view_buf, cfg, "view_back", "<leader>nq", function()
        open_composed_view(mode, scope_path, "task:" .. task.key)
      end)
      bind_key(view_buf, cfg, "view_help", "<leader>n?", function()
        vim.notify("Task scope: za expand/collapse section · <leader>no source/diff · <leader>nx copy · <leader>nq back", vim.log.levels.INFO)
      end)
      vim.api.nvim_set_current_win(win)
      local selected_line = 1
      if selected_key then
        for line, row in pairs(scope_rows) do
          if row and row.key == selected_key then selected_line = line; break end
        end
      end
      vim.api.nvim_win_set_cursor(win, { selected_line, 0 })
    end

    bind_key(view_buf, cfg, "task_scope", "<leader>ns", function()
      local row = selected_view_row()
      if row and row.kind == "task" and row.task then open_task_scope(row.task) end
    end)
    bind_key(view_buf, cfg, "chat_file", "<leader>nF", function()
      local row = selected_view_row()
      local relative = row and (row.path or (row.task and row.task.key:match("^(.-)::"))
        or (row.requirement and (row.requirement.sourcePath or row.requirement.specPath)))
      add_codecompanion_file_reference(root, relative)
    end)
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitChatFile", function()
      local row = selected_view_row()
      local relative = row and (row.path or (row.task and row.task.key:match("^(.-)::"))
        or (row.requirement and (row.requirement.sourcePath or row.requirement.specPath)))
      add_codecompanion_file_reference(root, relative)
    end, { desc = "Add selected file as a quoted Markdown link to CodeCompanion", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitContextAdd", append_context, { desc = "Add selected Neolit item to context", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitContextRemove", remove_context, { desc = "Remove selected Neolit item from context", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitContextCopy", copy_context, { desc = "Copy composed Neolit context", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitContextClear", clear_context, { desc = "Clear composed Neolit context", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitContextReview", function() open_context_view() end, { desc = "Review composed Neolit context", force = true })
    vim.api.nvim_buf_create_user_command(view_buf, "NeolitChatContext", add_context_to_codecompanion, { desc = "Add composed Neolit context to CodeCompanion", force = true })
    bind_key(view_buf, cfg, "context_copy", "<leader>ny", copy_context)
    bind_key(view_buf, cfg, "context_clear", "<leader>nc", clear_context)
    bind_key(view_buf, cfg, "context_review", "<leader>np", open_context_view)
    bind_key(view_buf, cfg, "chat_context", "<leader>nM", add_context_to_codecompanion)
    bind_key(view_buf, cfg, "copy_path", "<leader>nl", function()
      local row = selected_view_row()
      if row and row.path then copy_value(row.path .. (row.line and (":" .. row.line) or ""), "Source path") end
    end)
    bind_key(view_buf, cfg, "switch_projection", "<leader>nv", function()
      open_composed_view(mode == "requirements" and "tasks" or "requirements", scope_path)
    end)
    update_context_header()
    bind_key(view_buf, cfg, "view_back", "<leader>nq", function()
      if vim.api.nvim_win_is_valid(view_state.tree_win) then vim.api.nvim_set_current_win(view_state.tree_win) end
    end)
    vim.api.nvim_set_current_win(win)
    local selected_line = 1
    if selected_key then
      for line, row in pairs(rows) do
        if row and row.key == selected_key then selected_line = line; break end
      end
    end
    vim.api.nvim_win_set_cursor(win, { selected_line, 0 })
  end

  local function map(_, fn, desc, action)
    local key = action or desc
    local resolved = cfg.keymaps and cfg.keymaps[key]
    if type(resolved) ~= "string" or resolved == "" then return end
    vim.keymap.set("n", resolved, fn, {
      buffer = buf, silent = true, nowait = false, desc = "Neolit: " .. key,
    })
  end
  rerender_at = function(key)
    local workspace = vim.b[buf].neolit_workspace
    if not workspace then return end
    render(buf, root, workspace, expanded_files, expanded_dirs, expanded_tasks, filter_mode)
    if key then
      for line, row in pairs(vim.b[buf].neolit_rows or {}) do
        if row and row.key == key then
          local tree = view_state.tree_win
          if tree and vim.api.nvim_win_is_valid(tree) then vim.api.nvim_win_set_cursor(tree, { line, 0 }) end
          return
        end
      end
    end
  end
  current_row = function()
    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) or vim.api.nvim_win_get_buf(tree) ~= buf then return nil end
    return vim.b[buf].neolit_rows and vim.b[buf].neolit_rows[vim.api.nvim_win_get_cursor(tree)[1]]
  end

  local function delete_selected()
    local row = current_row()
    if not row then return end
    local relative, range, label, marker, kind
    if (row.kind == "task" or row.kind == "requirement_task") and row.task then
      relative = row.task.key:match("^(.-)::"); range = row.task.range; label = "TODO task"; marker = row.task.text; kind = "task"
    elseif row.kind == "requirement" and row.requirement then
      relative = row.spec_path; range = row.requirement.range; label = "SPEC requirement " .. tostring(row.requirement.id); marker = row.requirement.id; kind = "spec"
    elseif (row.kind == "requirement_criterion" or row.kind == "task_acceptance") and row.criterion then
      relative = row.criterion.sourcePath or row.criterion.specPath; range = row.criterion.range
      label = "SPEC acceptance criterion " .. tostring(row.criterion.id); marker = row.criterion.id; kind = "spec"
    else
      vim.notify("Select a TODO task, SPEC requirement, or acceptance criterion", vim.log.levels.INFO)
      return
    end
    local source = safe_repo_path(root, relative)
    if not source or not range then
      vim.notify("Cannot resolve a safe source range", vim.log.levels.ERROR)
      return
    end
    local loaded = vim.fn.bufnr(source)
    if loaded >= 0 and vim.bo[loaded].modified then
      vim.notify("Write the modified planning buffer before deleting this entry", vim.log.levels.WARN)
      return
    end
    local source_lines = vim.fn.readfile(source)
    local first, last = tonumber(range.startLine), tonumber(range.endLine)
    if not first or not last or first < 1 or last < first or last > #source_lines then
      vim.notify("The selected Markdown range is stale; refresh the workspace", vim.log.levels.WARN)
      return
    end
    local count = 0
    for _, line in ipairs(source_lines) do
      if kind == "task" then
        if line:find(marker, 1, true) and line:match("%[[ xX]%]") then count = count + 1 end
      elseif line:find("**" .. marker .. "**", 1, true) then
        count = count + 1
      end
    end
    local first_line = source_lines[first] or ""
    local valid = kind == "task"
      and first_line:find(marker, 1, true) and first_line:match("%[[ xX]%]")
      or kind ~= "task" and first_line:find("**" .. marker .. "**", 1, true)
    if count ~= 1 or not valid then
      vim.notify("The selected Markdown entry changed or is ambiguous; refresh before deleting", vim.log.levels.WARN)
      return
    end
    for _ = first, last do table.remove(source_lines, first) end
    if vim.fn.writefile(source_lines, source) ~= 0 then
      vim.notify("Could not update " .. relative, vim.log.levels.ERROR)
      return
    end
    if loaded >= 0 then pcall(vim.api.nvim_buf_call, loaded, function() vim.cmd("checktime") end) end
    vim.notify("Deleted " .. label .. " from " .. relative)
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
      local path = row.path or (row.file and row.file.path)
      if expanded and row.kind == "file" then
        local workspace = vim.b[buf].neolit_workspace
        if workspace and ensure_codecompanion_review(workspace) then
          expanded_files[path] = true
          rerender_at(row.key)
          return
        end
      end
      expanded_files[path] = expanded
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
        local tree = view_state.tree_win
        if tree and vim.api.nvim_win_is_valid(tree) then vim.api.nvim_win_set_cursor(tree, { line, 0 }) end
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
    local tree = view_state.tree_win
    if not tree or not vim.api.nvim_win_is_valid(tree) or vim.api.nvim_win_get_buf(tree) ~= buf then return end
    local cursor = vim.api.nvim_win_get_cursor(tree)
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
  -- Hover previews reuse the single right-hand preview window. Enter promotes
  -- that preview by focusing it; it must not require a separate open-file chord.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = refresh_group,
    buffer = buf,
    callback = function()
      -- CursorMoved fires for every window displaying this buffer. Only the
      -- designated navigator window drives previews; horizontal cursor motion
      -- within the same row does not rebuild highlights or touch preview buffers.
      if not vim.api.nvim_win_is_valid(view_state.tree_win)
        or vim.api.nvim_get_current_win() ~= view_state.tree_win
        or vim.api.nvim_win_get_buf(view_state.tree_win) ~= buf then return end
      local line = vim.api.nvim_win_get_cursor(view_state.tree_win)[1]
      if line == last_cursor_line then return end
      last_cursor_line = line
      highlight_related()
      preview_row(current_row())
    end,
  })
  -- Keep Neovim's native K (LSP hover/man-page lookup) available. If an older
  -- Neolit buffer-local mapping survived a reload, remove only that local map.
  pcall(vim.keymap.del, "n", "K", { buffer = buf })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = refresh_group,
    callback = function(event)
      local name = vim.api.nvim_buf_get_name(event.buf)
      if name ~= "" and name:sub(1, #root + 1) == root .. "/" then refresh() end
    end,
  })
  -- Workspace refresh is explicit (or follows a planning/source file write).
  -- Do not run a full Node/Git scan on idle or focus changes.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = refresh_group,
    buffer = buf,
    once = true,
    callback = function()
      refresh_revision = refresh_revision + 1
      if refresh_job then pcall(vim.fn.jobstop, refresh_job); refresh_job = nil end
      clear_codecompanion_previews()
      codecompanion_review_diffs = nil
      codecompanion_review_loaded = false
      pcall(vim.api.nvim_del_augroup_by_id, refresh_group)
    end,
  })
  local function create_action_command(name, callback, description)
    vim.api.nvim_buf_create_user_command(buf, name, callback, { desc = description, force = true })
  end
  create_action_command("NeolitCompose", function()
    local row = current_row()
    local mode = row and row.doc_kind == "TODO" and "tasks" or "requirements"
    open_composed_view(mode, row and row.doc_kind and row.path or nil)
  end, "Open composed task/requirement view")
  create_action_command("NeolitOpen", selected, "Open selected tree entry")
  create_action_command("NeolitOpenFile", open_selected_file, "Open selected source file")
  create_action_command("NeolitFilter", function()
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
  end, "Toggle affected-only filter")
  create_action_command("NeolitRefresh", refresh, "Refresh planning and Git data")
  create_action_command("NeolitDelete", delete_selected, "Delete selected planning entry")
  create_action_command("NeolitCopyText", copy_selected_text, "Copy selected text")
  create_action_command("NeolitCopyPath", copy_selected_path, "Copy selected path")
  create_action_command("NeolitYankContext", copy_selected_context, "Yank formatted context for the selected entry")
  create_action_command("NeolitToggle", toggle_node_at_cursor, "Toggle selected tree node")
  create_action_command("NeolitAgentChanges", function()
    if vim.fn.exists(":CodeCompanionChat") ~= 2 then
      vim.notify("CodeCompanion.nvim is required", vim.log.levels.ERROR)
      return
    end
    local target = (cfg.layout and cfg.layout.chat) == "current" and vim.api.nvim_get_current_win()
      or (view_state.preview_win and vim.api.nvim_win_is_valid(view_state.preview_win) and view_state.preview_win)
      or view_state.tree_win
    if target and vim.api.nvim_win_is_valid(target) then vim.api.nvim_set_current_win(target) end
    vim.cmd("CodeCompanionChat Changes")
  end, "Open CodeCompanion agent changes")
  create_action_command("NeolitReview", function()
    if vim.fn.exists(":CodeCompanionCodeReview") == 2 then vim.cmd("CodeCompanionCodeReview")
    else vim.notify("CodeCompanion.nvim Code Review is required", vim.log.levels.ERROR) end
  end, "Review CodeCompanion changes")
  map("<leader>nv", function()
    local row = current_row()
    local mode = row and row.doc_kind == "TODO" and "tasks" or "requirements"
    open_composed_view(mode, row and row.doc_kind and row.path or nil)
  end, "tree_composed", "tree_composed")
  map("<leader>n<CR>", selected, "tree_open_selected", "tree_open_selected")
  local function add_file_link_to_chat()
    local row = current_row()
    local relative = selected_file_target(row)
      or (row and row.path)
      or (row and row.reference and row.reference.path)
    add_codecompanion_file_reference(root, relative)
  end
  vim.api.nvim_buf_create_user_command(buf, "NeolitChatFile", add_file_link_to_chat, { desc = "Yank selected file as a quoted Markdown link" })
  vim.api.nvim_buf_create_user_command(buf, "NeolitChat", function()
    if vim.fn.exists(":CodeCompanionChat") ~= 2 then
      vim.notify("CodeCompanion.nvim is required", vim.log.levels.ERROR)
      return
    end
    local chat_target = (cfg.layout and cfg.layout.chat) or "right"
    local chat_win = chat_target == "current" and vim.api.nvim_get_current_win()
      or (view_state.preview_win and vim.api.nvim_win_is_valid(view_state.preview_win) and view_state.preview_win)
      or view_state.tree_win
    if chat_win and vim.api.nvim_win_is_valid(chat_win) then
      vim.api.nvim_set_current_win(chat_win)
      vim.cmd("lcd " .. vim.fn.fnameescape(root))
    end
    vim.cmd("CodeCompanionChat adapter=" .. ((cfg.codecompanion and cfg.codecompanion.adapter) or "opencode"))
  end, { desc = "Open CodeCompanion chat for this repository" })
  map("o", open_selected_file, "tree_open_file", "tree_open_file")
  map("F", toggle_node_at_cursor, "tree_toggle", "tree_toggle")
  map("l", expand_node_at_cursor, "tree_expand_node", "tree_expand_node")
  map("h", collapse_node_at_cursor, "tree_collapse_node", "tree_collapse_node")
  map("za", toggle_node_at_cursor, "tree_fold_toggle", "tree_fold_toggle")
  map("zc", function() toggle_node(current_row(), false) end, "tree_fold_close", "tree_fold_close")
  map("zo", function() toggle_node(current_row(), true) end, "tree_fold_open", "tree_fold_open")
  map("zr", function() set_fold_level("open") end, "tree_expand_level", "tree_expand_level")
  map("zm", function() set_fold_level("close") end, "tree_collapse_level", "tree_collapse_level")
  map("zR", function()
    set_all_expanded(true)
    for _, task in ipairs((vim.b[buf].neolit_workspace or {}).tasks or {}) do expanded_tasks[task.key] = true end
    rerender_at()
  end, "tree_expand_all", "tree_expand_all")
  map("zM", function()
    set_all_expanded(false)
    for _, task in ipairs((vim.b[buf].neolit_workspace or {}).tasks or {}) do expanded_tasks[task.key] = false end
    rerender_at()
  end, "tree_collapse_all", "tree_collapse_all")
  map("<leader>nf", function() vim.cmd("NeolitFilter") end, "affected_filter", "affected_filter")
  map("<leader>nr", refresh, "refresh", "refresh")
  map("<leader>nD", delete_selected, "delete_entry", "delete_entry")
  map("<leader>nx", copy_selected_text, "copy_text", "copy_text")
  map("<leader>nl", copy_selected_path, "copy_path", "copy_path")
  map("<leader>nY", copy_selected_context, "context_yank", "context_yank")
  map("?", function()
    vim.notify("Tree: <CR> open/expand · o open file · F toggle · h/l collapse/expand · za/zo/zc fold · zr/zm one level · zR/zM all · <leader>nv composed view · <leader>ns task scope in composed view · <leader>nf affected-only · <leader>nD delete · <leader>nx copy text · <leader>nl path · <leader>nY yank context · <leader>nr refresh · <leader>nm chat · <leader>ne review · <leader>nC agent changes · <leader>nF file link · q close · ? help", vim.log.levels.INFO)
  end, "tree_help", "tree_help")
  local function close_workspace()
    refresh_revision = refresh_revision + 1
    if refresh_job then pcall(vim.fn.jobstop, refresh_job); refresh_job = nil end
    clear_codecompanion_previews()
    codecompanion_review_diffs = nil
    codecompanion_review_loaded = false
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
  map("q", close_workspace, "close_workspace", "close_workspace")
  
  refresh()
end

return M
