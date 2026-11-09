--- Markdown capture and journal entry points for Neolit.
local M = {}

local function repo_root(cfg)
  if cfg.directory and cfg.directory ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(cfg.directory), ":p")
  end
  local name = vim.api.nvim_buf_get_name(0)
  local start = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  return vim.fs.root(start, { ".git" }) or vim.fn.getcwd()
end

local function target_path(root, path)
  path = vim.fn.expand(path)
  if path:sub(1, 1) ~= "/" then path = root .. "/" .. path end
  return vim.fs.normalize(path)
end

local function read_lines(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function append_under_heading(path, heading, entry)
  local lines = read_lines(path)
  local heading_line, heading_level
  for i, line in ipairs(lines) do
    if line == heading then heading_line, heading_level = i, 2; break end
  end
  if not heading_line then
    if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
    lines[#lines + 1] = heading
    heading_line = #lines
  end

  local finish = #lines
  for i = heading_line + 1, #lines do
    local hashes = lines[i]:match("^(#+)%s")
    if hashes and #hashes <= heading_level then finish = i - 1; break end
  end
  while finish > heading_line and lines[finish]:match("^%s*$") do finish = finish - 1 end

  local insert = {}
  if finish > heading_line then insert[#insert + 1] = "" end
  for _, line in ipairs(entry) do insert[#insert + 1] = line end
  for i = #lines, finish + 1, -1 do table.remove(lines, i) end
  for _, line in ipairs(insert) do lines[#lines + 1] = line end
  for i = finish + 1, #read_lines(path) do
    -- Existing trailing sections are retained below by the splice below.
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function insert_section(path, heading, entry)
  local original = read_lines(path)
  local lines = {}
  local found, level, finish = nil, 2, #original
  for i, line in ipairs(original) do
    if line == heading then found = i; break end
  end
  if not found then
    if #original > 0 and original[#original] ~= "" then original[#original + 1] = "" end
    original[#original + 1] = heading
    found = #original
  end
  for i = found + 1, #original do
    local hashes = original[i]:match("^(#+)%s")
    if hashes and #hashes <= level then finish = i - 1; break end
  end
  for i = 1, finish do lines[#lines + 1] = original[i] end
  while #lines > found and lines[#lines] == "" do table.remove(lines) end
  if #lines > found then lines[#lines + 1] = "" end
  for _, line in ipairs(entry) do lines[#lines + 1] = line end
  for i = finish + 1, #original do lines[#lines + 1] = original[i] end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function next_id(path, prefix)
  local max = 0
  for _, line in ipairs(read_lines(path)) do
    for number in line:gmatch("%*%*" .. prefix .. "%-(%d+)%*%*") do
      max = math.max(max, tonumber(number) or 0)
    end
  end
  return ("%s-%02d"):format(prefix, max + 1)
end

local function open_capture(cfg, title, target, heading, template)
  local lines = vim.split(template, "\n", { plain = true })
  vim.cmd("10new")
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_buf_set_name, buf, "neolit-capture://" .. target)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modified = true
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local marker = template:find("%%?", 1, true)
  if marker then
    local before = template:sub(1, marker - 1)
    local prefix = vim.split(before, "\n", { plain = true })
    vim.api.nvim_win_set_cursor(win, { #prefix, #prefix[#prefix] })
  end

  local function cancel()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  local function save()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local body = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #body > 0 and body[#body]:match("^%s*$") do table.remove(body) end
    if #body == 0 or (#body == 1 and body[1]:match("^%s*[-*]%s*%[ %]%s*$")) then
      vim.notify("Empty capture discarded", vim.log.levels.INFO)
      cancel()
      return
    end
    if heading then
      insert_section(target, heading, body)
    else
      local existing = read_lines(target)
      local day = "## " .. os.date("%Y-%m-%d %a")
      local found = false
      for _, line in ipairs(existing) do if line == day then found = true; break end end
      if not found then
        if #existing > 0 and existing[#existing] ~= "" then existing[#existing + 1] = "" end
        existing[#existing + 1] = day
        existing[#existing + 1] = ""
      elseif #existing > 0 and existing[#existing] ~= "" then
        existing[#existing + 1] = ""
      end
      for _, line in ipairs(body) do existing[#existing + 1] = line end
      vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
      vim.fn.writefile(existing, target)
    end
    vim.notify(title .. ": " .. target)
    cancel()
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, once = true, callback = save })
  vim.keymap.set("n", "<C-s>", function() vim.cmd("write") end, { buffer = buf, silent = true, desc = "Save capture" })
  vim.keymap.set({ "n", "i" }, "<C-c>", cancel, { buffer = buf, silent = true, desc = "Cancel capture" })
  vim.cmd("startinsert")
end

function M.open_journal(cfg)
  local path = target_path(vim.fn.expand(cfg.journal_dir or "~/Documents/memo/journal"), os.date("%Y-%m") .. ".md")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.capture_journal(cfg)
  local path = target_path(vim.fn.expand(cfg.journal_dir or "~/Documents/memo/journal"), os.date("%Y-%m") .. ".md")
  open_capture(cfg, "Journal entry saved", path, nil, "`" .. os.date("%H:%M") .. "`  %?")
end

function M.capture_task(cfg)
  local path = target_path(repo_root(cfg), cfg.todo_file or "TODO.md")
  open_capture(cfg, "Task captured", path, "## Tasks", "- [ ] %?")
end

function M.capture_requirement(cfg)
  local path = target_path(repo_root(cfg), cfg.spec_file or "SPEC.md")
  local id = next_id(path, "R")
  open_capture(cfg, "Requirement captured", path, "## Requirements", "- **" .. id .. "** %?")
end

function M.capture_criterion(cfg)
  local path = target_path(repo_root(cfg), cfg.spec_file or "SPEC.md")
  local id = next_id(path, "AC")
  open_capture(cfg, "Acceptance criterion captured", path, "## Acceptance criteria", "- **" .. id .. "** %?")
end

function M.setup(cfg)
  local commands = {
    NeolitJournal = function() M.open_journal(cfg) end,
    NeolitCaptureJournal = function() M.capture_journal(cfg) end,
    NeolitCaptureTask = function() M.capture_task(cfg) end,
    NeolitCaptureRequirement = function() M.capture_requirement(cfg) end,
    NeolitCaptureCriterion = function() M.capture_criterion(cfg) end,
  }
  for name, callback in pairs(commands) do
    vim.api.nvim_create_user_command(name, callback, { force = true, desc = "Neolit Markdown capture" })
  end
  local maps = cfg.keymaps or {}
  local actions = {
    open_journal = M.open_journal,
    capture_journal = M.capture_journal,
    capture_task = M.capture_task,
    capture_requirement = M.capture_requirement,
    capture_criterion = M.capture_criterion,
  }
  for action, callback in pairs(actions) do
    local lhs = maps[action]
    if lhs and lhs ~= false and lhs ~= "" then
      vim.keymap.set("n", lhs, function() callback(cfg) end, { silent = true, desc = "Neolit: " .. action })
    end
  end
end

return M
