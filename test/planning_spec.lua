local config = require("neolit.config")
local planning = require("neolit.planning")

local function run(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. " failed: " .. (result.stderr or ""))
  return result.stdout or ""
end

local function fixture()
  local directory = vim.fn.trim(vim.fn.system({ "mktemp", "-d", "/tmp/neolit-plan-XXXXXX" }))
  assert(directory ~= "", "mktemp failed")
  run({ "git", "init", "-q" }, directory)
  run({ "git", "config", "user.email", "test@example.com" }, directory)
  run({ "git", "config", "user.name", "Neolit planning test" }, directory)
  vim.fn.mkdir(directory .. "/src", "p")
  vim.fn.writefile({ "# Fixture", "", "[Feature](src/README.md)" }, directory .. "/README.md")
  vim.fn.writefile({ "# Feature", "", "[SPEC](SPEC.md) [TODO](TODO.md)" }, directory .. "/src/README.md")
  vim.fn.writefile({
    "# Feature",
    "## Requirements",
    "- **R-01** Change the exported value.",
    "## Acceptance criteria",
    "- **AC-01** R-01 exports the new value.",
  }, directory .. "/src/SPEC.md")
  vim.fn.writefile({
    "# Feature tasks",
    "- [ ] Change the value",
    "  - SPEC: `SPEC.md#R-01`",
    "  - File: `sample.ts`",
  }, directory .. "/src/TODO.md")
  vim.fn.writefile({ "export const value = 1;", "export const next = 2;" }, directory .. "/sample.ts")
  run({ "git", "add", "." }, directory)
  run({ "git", "commit", "-qm", "fixture" }, directory)
  vim.fn.writefile({ "export const value = 1;", "export const next = 3;" }, directory .. "/sample.ts")
  return directory
end

local function find_mapping(mode, lhs, buffer)
  for _, mapping in ipairs(vim.keymap.get(mode, lhs, { buffer = buffer })) do
    if mapping.callback then return mapping.callback end
  end
  error("mapping not found: " .. lhs)
end

return {
  {
    name = "copies an exact selected diff line with a stale-checked base anchor",
    run = function(t)
      local neolit_dir = config.find_neolit_dir({}, {
        env = vim.env,
        plugin_root = config.plugin_root(),
        readable = function(path) return vim.fn.filereadable(path) == 1 end,
      })
      if not neolit_dir then
        print("  (skipped: no neolit dist found; set NEOLIT_DIR)")
        return
      end

      local directory = fixture()
      local original_input = vim.ui.input
      local original_tab_count = #vim.api.nvim_list_tabpages()
      local panel_buf
      local ok, failure = pcall(function()
        planning.open({ directory = directory, neolit_dir = neolit_dir })
        panel_buf = vim.api.nvim_get_current_buf()
        t:ok(vim.wait(15000, function()
          return vim.api.nvim_buf_is_valid(panel_buf) and vim.b[panel_buf].neolit_rows ~= nil
        end, 50), "planning workspace loads")

        local file_row
        for row, item in pairs(vim.b[panel_buf].neolit_rows) do
          if item and item.kind == "file" and item.file.path == "sample.ts" then
            file_row = row
            break
          end
        end
        t:ok(file_row ~= nil, "changed file is visible")
        local panel_text = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
        t:ok(panel_text:find("implemented", 1, true) ~= nil, "derived task state is displayed")
        t:ok(panel_text:find("AC-01", 1, true) == nil, "acceptance criteria remain in the SPEC rather than duplicated in the compact list")
        vim.api.nvim_win_set_cursor(0, { file_row, 0 })
        find_mapping("n", "<CR>", panel_buf)()

        local working_buf = vim.api.nvim_get_current_buf()
        t:ok(vim.api.nvim_buf_is_valid(working_buf), "native working-tree diff buffer opens")
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        local packet
        local prompt_count = 0
        vim.ui.input = function(_, callback)
          prompt_count = prompt_count + 1
          callback("Why did this line change?")
        end
        local ask_line = find_mapping("n", "<leader>nx", working_buf)
        ask_line()
        packet = vim.fn.getreg("+") .. "\n" .. vim.fn.getreg('"')

        t:ok(packet:find("Why did this line change?", 1, true) ~= nil, "question is included")
        t:ok(packet:find("sample.ts lines 2-2", 1, true) ~= nil, "exact path and line range are included")
        t:ok(packet:find("Diff side: working-tree", 1, true) ~= nil, "diff side is explicit")
        t:ok(packet:find("Base commit:", 1, true) ~= nil, "base commit is explicit")
        t:ok(packet:find("Diff identity (sha256):", 1, true) ~= nil, "diff identity is explicit")
        t:ok(packet:find("export const next = 3;", 1, true) ~= nil, "selected source line is included")
        t:ok(packet:find("+export const next = 3;", 1, true) ~= nil, "current Git diff is included")
        t:ok(packet:find("Related plan:", 1, true) ~= nil, "linked plan context is included")
        t:ok(packet:find("Change the value", 1, true) ~= nil, "related TODO task is included")
        t:ok(packet:find("src/SPEC.md#R-01", 1, true) ~= nil, "linked SPEC requirement is included")

        local prior_identity = vim.b[panel_buf].neolit_workspace.git.diffIdentity
        vim.fn.writefile({ "export const value = 1;", "export const next = 4;" }, directory .. "/sample.ts")
        ask_line()
        t:eq(prompt_count, 1, "a changed diff is rejected before asking or copying context")
        t:ok(vim.wait(10000, function()
          local workspace = vim.b[panel_buf].neolit_workspace
          return workspace and workspace.git.diffIdentity ~= prior_identity
        end, 50), "stale context refreshes the planning workspace")

        local before_save_identity = vim.b[panel_buf].neolit_workspace.git.diffIdentity
        vim.api.nvim_buf_set_lines(working_buf, 1, 2, false, { "export const next = 5;" })
        vim.cmd("write")
        t:ok(vim.wait(10000, function()
          local workspace = vim.b[panel_buf].neolit_workspace
          return workspace and workspace.git.diffIdentity ~= before_save_identity
        end, 50), "saving a repository file refreshes the planning workspace")
      end)
      vim.ui.input = original_input
      while #vim.api.nvim_list_tabpages() > original_tab_count do
        pcall(vim.cmd, "tabclose!")
      end
      if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
        pcall(vim.api.nvim_set_current_buf, panel_buf)
        local has_close, close_workspace = pcall(find_mapping, "n", "q", panel_buf)
        if has_close then pcall(close_workspace) else pcall(vim.api.nvim_buf_delete, panel_buf, { force = true }) end
      end
      vim.fn.delete(directory, "rf")
      if not ok then error(failure) end
    end,
  },
};
