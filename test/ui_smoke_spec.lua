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
        no_socket = true,
        host_args = { "--stub-runtime" },
      })
      handlers = keys.handlers(ui)
      -- Window-settings contract, baselined BEFORE the panel exists: the
      -- panel must never write global window options, content panes carry
      -- the user's global settings (not the tree widget's), and the tree
      -- keeps its widget options locally. Strict-scope reads only —
      -- `vim.o` reflects the focused window's locals and hides leaks.
      local global_of = function(name)
        return vim.api.nvim_get_option_value(name, { scope = "global" })
      end
      local baseline = {
        wrap = global_of("wrap"),
        scrolloff = global_of("scrolloff"),
        cursorline = global_of("cursorline"),
        winhl = global_of("winhl"),
      }
      neolit.open("add gamma line")

      wait_for(t, "singleton approach is auto-adopted", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Single viable approach adopted", 1, true) ~= nil
      end))

      local state = ui._state()
      t:ok(state, "UI state exists")
      t:eq(state.model.available, true)
      t:eq(state.model.label, "STUB")
      t:eq(#vim.api.nvim_list_tabpages(), 2, "the panel opens its own tabpage")
      t:eq(state.tab, vim.api.nvim_get_current_tabpage(), "the panel tab is focused")
      t:ok(vim.api.nvim_tabpage_is_valid(state.previous_tab), "the user's tab is untouched")
      t:ok(vim.api.nvim_win_is_valid(state.wins.tree), "sidebar window is a real split")
      t:ok(vim.api.nvim_win_is_valid(state.wins.desc), "description column is a real split")
      t:ok(state.wins.right ~= -1 and vim.api.nvim_win_is_valid(state.wins.right), "diff column exists from the start — permanent, no churn")
      local tree_text = table.concat(vim.api.nvim_buf_get_lines(state.bufs.tree, 0, -1, false), "\n")
      t:ok(tree_text:find("session%.ts", 1) ~= nil, "tree shows the repository file")
      local diff_placeholder = table.concat(vim.api.nvim_buf_get_lines(state.bufs.diff, 0, -1, false), "\n")
      t:ok(diff_placeholder:find("no drafted changes", 1, true) ~= nil, "empty diff column shows a quiet placeholder")

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

      -- Enter routes messages: an ambiguous one offers interpretations in
      -- the description dock, and the number keys pick one.
      local real_input = vim.ui.input
      vim.ui.input = function(_, callback) callback("this is ambiguous, what should change?") end
      handlers["<CR>"]()
      vim.ui.input = real_input
      wait_for(t, "ambiguous message offers interpretations", frame_matches(function(frame)
        return frame.routedOptions and #frame.routedOptions == 2
      end))
      local offered_text = table.concat(vim.api.nvim_buf_get_lines(ui._state().bufs.desc, 0, -1, false), "\n")
      t:ok(offered_text:find("Deadline cutoff", 1, true) ~= nil, "description dock renders the offered options")
      handlers["1"]()
      wait_for(t, "choosing an interpretation continues the flow", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Approaches updated", 1, true) ~= nil
          and frame.routedOptions and #frame.routedOptions == 0
      end))

      handlers.d() -- develop: refine the chosen approach into files
      wait_for(t, "refine selects the first planned child", frame_matches(function(frame)
        return frame.tree.selectedRowId == "entry:session.ts"
      end))
      local state_after_refine = ui._state()
      local detail_text = table.concat(vim.api.nvim_buf_get_lines(state_after_refine.bufs.desc, 0, -1, false), "\n")
      t:ok(detail_text:find("apply the edit", 1, true) ~= nil, "description dock explains the planned child")
      local detail_winbar = (state_after_refine.wins.desc ~= -1 and vim.api.nvim_win_is_valid(state_after_refine.wins.desc))
        and (vim.api.nvim_win_get_option(state_after_refine.wins.desc, "winbar") or "")
        or ""
      t:eq(detail_winbar, "", "no winbar title — the buffer name identifies the pane")
      local first_desc = (vim.api.nvim_buf_get_lines(state_after_refine.bufs.desc, 0, 1, false) or { "x" })[1]
      t:ok(first_desc ~= "DESCRIPTION", "the core's section label is stripped from content")

      handlers.d() -- develop: draft the file's exact patch
      wait_for(t, "patch is drafted", frame_matches(function(frame)
        return frame.panel.message and frame.panel.message:find("Draft change ready", 1, true) ~= nil
      end))
      local state_after_draft = ui._state()
      t:ok(state_after_draft.frame.changes and #state_after_draft.frame.changes.diffs == 1, "drafted diff ships as raw changes")
      t:ok(state_after_draft.frame.changes.diffs[1].text:find("%+gamma", 1) ~= nil, "raw patch text carries the change")
      local diff_buf = state_after_draft.bufs.diff
      t:ok(diff_buf and vim.api.nvim_buf_is_valid(diff_buf), "diff pane buffer exists")

      -- The composed body is a NATIVE file buffer: named after the file,
      -- the file's own filetype (LSP/treesitter attach), the drafted change
      -- marked in place — additions as DiffAdd, deletions as DiffDelete
      -- virtual lines — never +/- prefixes or hunk headers.
      wait_for(t, "merged body composes into the diff buffer", function()
        return vim.api.nvim_buf_is_valid(diff_buf) and vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)[3] == "gamma"
      end)
      local body_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)
      t:eq(body_lines, { "alpha", "beta", "gamma" }, "the body is the file's post-patch content, plain")
      t:eq(vim.api.nvim_buf_get_option(diff_buf, "filetype"), "typescript", "the composed body carries the file's own filetype")
      t:eq(vim.api.nvim_buf_get_name(diff_buf), directory .. "/session.ts", "the composed buffer is named after the real file")
      local marks = vim.api.nvim_buf_get_extmarks(diff_buf, state_after_draft.diff_ns, 0, -1, { details = true })
      local added_rows = {}
      for _, mark in ipairs(marks) do
        if mark[4] and mark[4].hl_group == "DiffAdd" then added_rows[#added_rows + 1] = mark[2] + 1 end
      end
      t:eq(added_rows, { 3 }, "exactly the added line carries a DiffAdd background")

      -- R flips to the classic unified patch: a filetype=diff scratch buffer.
      handlers.R()
      wait_for(t, "raw patch view renders", function()
        return vim.api.nvim_buf_get_option(diff_buf, "filetype") == "diff"
      end)
      local raw_text = table.concat(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false), "\n")
      t:ok(raw_text:find("@@ %-1,2 %+1,3 @@", 1) ~= nil, "raw patch shows hunk headers")
      t:eq(vim.api.nvim_buf_get_name(diff_buf), "neolit://diff", "the raw patch view is a scratch buffer")
      handlers.R() -- back to the body

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

      -- Content panes carry the USER's global window settings — never the
      -- tree widget's — and survive pane recreation; the tree keeps its
      -- widget options on its own window; no global option ever changes.
      local win_of = function(win, name)
        return vim.api.nvim_win_get_option(win, name)
      end
      for _, entry in ipairs({
        { name = "diff column", win = state_after_draft.wins.right },
        { name = "description column", win = state_after_draft.wins.desc },
      }) do
        assert(win_of(entry.win, "wrap") == baseline.wrap, entry.name .. " carries the user's global wrap")
        assert(win_of(entry.win, "cursorline") == baseline.cursorline, entry.name .. " carries the user's global cursorline")
        assert(win_of(entry.win, "scrolloff") == baseline.scrolloff, entry.name .. " carries the user's global scrolloff, not the tree's 999")
        assert(win_of(entry.win, "winhl") == baseline.winhl, entry.name .. " has no leaked winhl from the tree widget")
      end
      assert(win_of(state_after_draft.wins.tree, "wrap") == false, "the tree widget keeps nowrap")
      assert(win_of(state_after_draft.wins.tree, "scrolloff") == 999, "the tree widget keeps its centered scrolloff")
      assert(win_of(state_after_draft.wins.tree, "winhl") == "CursorLine:NeolitCursorLine", "the tree widget keeps its winhl")
      for _, name in ipairs({ "wrap", "scrolloff", "cursorline", "winhl" }) do
        assert(global_of(name) == baseline[name], "global " .. name .. " is untouched by the panel")
      end

      -- The stream sticks to its tail: rendering new lines keeps the
      -- cursor on the last one while it rides the bottom.
      local frame = vim.deepcopy(state_after_draft.frame)
      frame.session = { visible = true, lines = {} }
      ui.render(frame, true)
      local session_win = ui._state().wins.session
      assert(session_win ~= -1 and vim.api.nvim_win_is_valid(session_win), "session pane split under the description")
      assert(win_of(session_win, "scrolloff") == baseline.scrolloff and win_of(session_win, "winhl") == baseline.winhl,
        "the session pane carries the user's global settings, not the tree widget's")
      local placeholder = table.concat(vim.api.nvim_buf_get_lines(ui._state().bufs.session, 0, 1, false), "\n")
      assert(placeholder:find("waiting for the agent", 1, true), "empty stream shows the waiting placeholder")
      for i = 1, 30 do frame.session.lines[i] = { kind = "text", text = "stream line " .. i } end
      ui.render(frame, true)
      local cursor = vim.api.nvim_win_get_cursor(session_win)
      assert(cursor[1] == 30, "tail-follow keeps the cursor on the last line: " .. cursor[1])
      -- Scrolling up pauses the follow.
      vim.api.nvim_win_set_cursor(session_win, { 5, 0 })
      frame.session.lines[31] = { kind = "text", text = "stream line 31" }
      ui.render(frame, true)
      assert(vim.api.nvim_win_get_cursor(session_win)[1] == 5, "reading history pauses the follow")

      handlers.q() -- quit like the TUI
      t:ok(vim.wait(5000, function() return ui._state() == nil end), "quit closes the UI")
      t:eq(#vim.api.nvim_list_tabpages(), 1, "quit closes the panel's tabpage")
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
      neolit.setup({ directory = directory, no_socket = true, host_args = { "--stub-runtime" } })
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
  {
    name = "neolit.key drives the real panel from a closed state",
    run = function(t)
      local neolit_dir = config.find_neolit_dir({}, {
        env = vim.env,
        plugin_root = config.plugin_root(),
        readable = function(path) return vim.fn.filereadable(path) == 1 end,
      })
      if not neolit_dir then
        print("  (skipped: no neolit dist found)")
        return
      end

      local state_home = vim.fn.resolve(vim.fn.trim(vim.fn.system({ "mktemp", "-d", "/tmp/opencode/neolit-state-XXXXXX" })))
      vim.fn.setenv("XDG_STATE_HOME", state_home)
      local directory = fixture_repo()
      neolit.setup({ neolit_dir = neolit_dir, directory = directory, persist_tasks = false, no_socket = true, host_args = { "--stub-runtime" } })

      -- d on a closed panel: opens it, then develops (which errors politely
      -- with no task — the panel still opened and the action still ran).
      local notified = {}
      local real_notify = vim.notify
      vim.notify = function(text, level) notified[#notified + 1] = text end
      neolit.key("d")
      t:ok(vim.wait(10000, function() return ui._state() ~= nil end, 50), "key opened the panel")
      t:ok(vim.wait(10000, function()
        return ui._state() ~= nil and ui._state().frame ~= nil
      end, 50), "panel rendered its first frame")
      neolit.key("q")
      t:ok(vim.wait(5000, function() return ui._state() == nil end), "key quit the panel")
      vim.notify = real_notify
      t:ok(#notified >= 1, "the no-task develop surfaced as a notification")
      vim.fn.setenv("XDG_STATE_HOME", nil)
      system({ "rm", "-rf", directory, state_home })
    end,
  },
}
