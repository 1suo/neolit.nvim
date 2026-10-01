--- Full-stack smoke test: the real host shim (with its deterministic stub
--- model runtime) against the real UI module, inside a throwaway git
--- fixture. Exercises the exact TUI flow: start → auto-adopt singleton →
--- develop (refine) → develop (draft) → apply → commit → quit. Skipped with
--- a visible note when the neolit dist cannot be found.

local neolit = require("neolit")
local config = require("neolit.config")
local keys = require("neolit.keys")
local ui = require("neolit.ui")

local function system(args)
  local output = vim.fn.system(args)
  assert(vim.v.shell_error == 0, "command failed: " .. table.concat(args, " ") .. "\n" .. output)
  return output
end

local function fixture_repo()
  vim.fn.mkdir("/tmp/opencode", "p")
  local directory = vim.fn.resolve(vim.fn.trim(vim.fn.system({ "mktemp", "-d", "/tmp/opencode/neolit-smoke-XXXXXX" })))
  assert(vim.v.shell_error == 0, "mktemp failed")
  vim.fn.mkdir(directory, "p")
  system({ "git", "-C", directory, "init", "-q" })
  system({ "git", "-C", directory, "config", "user.email", "t@example.com" })
  system({ "git", "-C", directory, "config", "user.name", "test" })
  vim.fn.writefile({ "alpha", "beta" }, directory .. "/session.ts")
  system({ "git", "-C", directory, "add", "session.ts" })
  system({ "git", "-C", directory, "commit", "-q", "-m", "init" })
  return directory
end

local function frame_matches(predicate)
  return function()
    local state = ui._state()
    return state ~= nil and state.frame ~= nil and predicate(state.frame)
  end
end

local function wait_for(t, label, predicate)
  t:ok(vim.wait(15000, predicate, 50), label)
end

local handlers

return {
  {
    name = "drives start → adopt → develop → draft → apply → commit through the shim",
    run = function(t)
      local neolit_dir = config.find_neolit_dir({}, {
        env = vim.env,
        plugin_root = config.plugin_root(),
        readable = function(path) return vim.fn.filereadable(path) == 1 end,
      })
      if not neolit_dir then
        print("  (skipped: no neolit dist found; set NEOLIT_DIR or place neolit beside this plugin)")
        return
      end

      local directory = fixture_repo()
      neolit.setup({
        neolit_dir = neolit_dir,
        directory = directory,
        persist_tasks = false,
        host_args = { "--stub-runtime" },
      })
      handlers = keys.handlers(ui)
      neolit.open("add gamma line")

      wait_for(t, "singleton approach is auto-adopted", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Single viable approach adopted", 1, true) ~= nil
      end))

      local state = ui._state()
      t:ok(state, "UI state exists")
      t:eq(state.model.available, true)
      t:eq(state.model.label, "STUB")
      t:ok(vim.api.nvim_win_is_valid(state.wins.tree), "sidebar window is a real split")
      t:ok(vim.api.nvim_win_is_valid(state.wins.detail), "detail window is a real split")
      local tree_text = table.concat(vim.api.nvim_buf_get_lines(state.bufs.tree, 0, -1, false), "\n")
      t:ok(tree_text:find("session%.ts", 1) ~= nil, "tree shows the repository file")

      -- The winbar carries chips only when idle; while an operation runs it
      -- shows the spinner instead, so wait for the idle form.
      wait_for(t, "winbar carries the status chips", function()
        local s = ui._state()
        return s and vim.api.nvim_win_is_valid(s.wins.tree)
          and (vim.api.nvim_win_get_option(s.wins.tree, "winbar") or ""):find("NEOLIT", 1, true) ~= nil
      end)
      wait_for(t, "winbar carries the plan status", function()
        local s = ui._state()
        return s and vim.api.nvim_win_is_valid(s.wins.tree)
          and (vim.api.nvim_win_get_option(s.wins.tree, "winbar") or ""):find("COLLAPSED", 1, true) ~= nil
      end)

      handlers.d() -- develop: refine the chosen approach into files
      wait_for(t, "refine selects the first planned child", frame_matches(function(frame)
        return frame.tree.selectedRowId == "entry:session.ts"
      end))
      local state_after_refine = ui._state()
      local detail_text = table.concat(vim.api.nvim_buf_get_lines(state_after_refine.bufs.detail, 0, -1, false), "\n")
      t:ok(detail_text:find("apply the edit", 1, true) ~= nil, "detail explains the planned child")
      local detail_winbar = vim.api.nvim_win_get_option(state_after_refine.wins.detail, "winbar") or ""
      t:ok(detail_winbar:find("session%.ts", 1) ~= nil, "detail winbar carries the selected path")

      handlers.d() -- develop: draft the file's exact patch
      wait_for(t, "patch is drafted", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Draft change ready", 1, true) ~= nil
      end))
      local state_after_draft = ui._state()
      local detail_with_patch = table.concat(vim.api.nvim_buf_get_lines(state_after_draft.bufs.detail, 0, -1, false), "\n")
      t:ok(detail_with_patch:find("%+gamma", 1) ~= nil, "detail shows the exact patch")

      handlers.a() -- apply to the working tree
      wait_for(t, "patch is applied", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Applied 1 drafted change", 1, true) ~= nil
      end))
      local content = table.concat(vim.fn.readfile(directory .. "/session.ts"), "\n")
      t:eq(content, "alpha\nbeta\ngamma", "working tree gained the drafted line")

      handlers.c() -- commit only the session-applied paths
      wait_for(t, "commit lands", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Committed 1 applied path", 1, true) ~= nil
      end))
      local subject = vim.trim(vim.fn.system({ "git", "-C", directory, "log", "-1", "--format=%s" }))
      t:eq(subject, "augment: add gamma line")
      local status = vim.trim(vim.fn.system({ "git", "-C", directory, "status", "--porcelain" }))
      t:eq(status, "", "nothing is left dirty")

      handlers.q() -- quit like the TUI
      t:ok(vim.wait(5000, function() return ui._state() == nil end), "quit closes the UI")
      system({ "rm", "-rf", directory })
    end,
  },
  {
    name = "opens with default options (no env overrides reach the host job)",
    run = function(t)
      if not vim.env.NEOLIT_DIR and not config.find_neolit_dir({}, {
        env = vim.env,
        plugin_root = config.plugin_root(),
        readable = function(path) return vim.fn.filereadable(path) == 1 end,
      }) then
        print("  (skipped: no neolit dist found)")
        return
      end

      -- Isolate the shim's state store so default task persistence cannot
      -- resume or rewrite anything real.
      local state_home = vim.fn.resolve(vim.fn.trim(vim.fn.system({ "mktemp", "-d", "/tmp/opencode/neolit-state-XXXXXX" })))
      vim.fn.setenv("XDG_STATE_HOME", state_home)

      local directory = fixture_repo()
      neolit.setup({ directory = directory, host_args = { "--stub-runtime" } })
      neolit.open()
      t:ok(vim.wait(10000, function()
        local s = ui._state()
        return s ~= nil and s.frame ~= nil
      end, 50), "initial frame renders without env overrides (jobstart E475 regression)")

      ui.quit()
      t:ok(vim.wait(5000, function() return ui._state() == nil end), "quit closes the UI")
      vim.fn.setenv("XDG_STATE_HOME", nil)
      system({ "rm", "-rf", directory, state_home })
    end,
  },
}
