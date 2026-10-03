local keys = require("neolit.keys")

local function stub_ui()
  local calls = {}
  local ui = {}
  ui.pane = function() return ui.pane_value or "tree" end
  for _, name in ipairs({
    "set_pane", "move", "scroll_detail", "prompt_message", "prompt_objective", "prompt_explanation",
    "develop", "apply_selected", "commit_applied", "restrict", "switch_model", "prompt_reopen",
    "prompt_stale", "quit", "cancel_op", "choose", "toggle_fold", "toggle_plan_only",
    "open_selected", "edit_patch", "fold_level", "session_toggle", "toggle_right_view", "show_keys",
  }) do
    ui[name] = function(...) calls[#calls + 1] = { name = name, args = { ... } } end
  end
  return ui, calls
end

return {
  {
    name = "carries the full TUI key set",
    run = function(t)
      local handlers = keys.handlers(stub_ui())
      for _, key in ipairs({
        "j", "k", "<Down>", "<Up>", "<Tab>", "<Right>", "<Left>", "<CR>",
        "n", "e", "d", "a", "c", "l", "w", "m", "o", "O", "p", "s", "q", "<Esc>", "t", "?",
        "za", "zc", "zo", "zr", "zR", "zm", "zM", "H", "F", "V", "p",
      }) do
        t:ok(handlers[key], "key " .. key .. " is routed")
      end
      for n = 1, 9 do
        t:ok(handlers[tostring(n)], "digit " .. n .. " is routed")
      end
    end,
  },
  {
    name = "j and k move the tree selection in the tree pane",
    run = function(t)
      local ui, calls = stub_ui()
      local handlers = keys.handlers(ui)
      handlers.j()
      handlers.k()
      t:eq(calls[1], { name = "move", args = { 1 } })
      t:eq(calls[2], { name = "move", args = { -1 } })
    end,
  },
  {
    name = "j and k scroll the detail pane when it is focused",
    run = function(t)
      local ui, calls = stub_ui()
      local handlers = keys.handlers(ui)
      ui.pane_value = "detail"
      handlers.j()
      handlers.k()
      t:eq(calls[1], { name = "scroll_detail", args = { 1 } })
      t:eq(calls[2], { name = "scroll_detail", args = { -1 } })
    end,
  },
  {
    name = "digits route to choose(n)",
    run = function(t)
      local ui, calls = stub_ui()
      local handlers = keys.handlers(ui)
      handlers["1"]()
      handlers["3"]()
      t:eq(calls[1], { name = "choose", args = { 1 } })
      t:eq(calls[2], { name = "choose", args = { 3 } })
    end,
  },
  {
    name = "restriction keys carry their polarity",
    run = function(t)
      local ui, calls = stub_ui()
      local handlers = keys.handlers(ui)
      handlers.l()
      handlers.w()
      t:eq(calls[1], { name = "restrict", args = { "lock" } })
      t:eq(calls[2], { name = "restrict", args = { "allow" } })
    end,
  },
  {
    name = "global action map covers every TUI operation key",
    run = function(t)
      local map = keys.global_action_map()
      for _, key in ipairs({
        "n", "e", "<CR>", "d", "a", "c", "l", "w", "m", "o", "O", "p", "s", "q", "<Tab>", "<Esc>",
        "1", "2", "3", "4", "5", "6", "7", "8", "9",
      }) do
        t:ok(map[key], "global action for " .. key)
      end
      for _, key in ipairs({ "j", "k", "za", "zc", "zo", "zr", "zR", "zm", "zM", "H" }) do
        t:eq(map[key], nil, "motion and fold keys stay pane-local: " .. key)
      end
      t:eq(map.l, { "restrict", "lock" })
      t:eq(map["3"], { "choose", 3 })
      t:eq(map.o, { "open_selected" }, "global o matches the panel's open-file")
      t:eq(map.O, { "prompt_reopen" }, "global O matches the panel's reopen")
      t:eq(map.p, { "edit_patch" })
      t:eq(map.j, nil, "motion keys stay pane-local")
    end,
  },
  {
    name = "bind_global routes every prefix map through the dispatcher",
    run = function(t)
      local captured = {}
      local original = vim.keymap.set
      local function restore() vim.keymap.set = original end
      vim.keymap.set = function(_, lhs, rhs, opts)
        captured[lhs] = { rhs = rhs, opts = opts }
      end
      local dispatched = {}
      local ok, err = pcall(keys.bind_global, "<leader>n", function(key) dispatched[#dispatched + 1] = key end)
      restore()
      t:ok(ok, err)
      local expected = keys.global_action_map()
      local count = 0
      for lhs, binding in pairs(captured) do
        count = count + 1
        local key = lhs:sub(#"<leader>n" + 1)
        t:ok(expected[key], "map " .. lhs .. " matches a TUI key")
        t:ok(binding.opts and binding.opts.desc, "map " .. lhs .. " carries a desc")
        binding.rhs()
      end
      t:eq(count, vim.tbl_count(expected), "one map per TUI key")
      table.sort(dispatched)
      t:eq(#dispatched, count, "each map dispatches its key")
    end,
  },
  {
    name = "neolit.key runs the action and opens a closed panel first",
    run = function(t)
      local neolit = require("neolit.init")
      local ui = require("neolit.ui")
      local opened = false
      local acted = false
      -- Stub the panel: open records and runs on_ready; develop records.
      local real_open, real_state, real_develop = neolit.open, ui._state, ui.develop
      neolit.open = function(objective, on_ready)
        opened = true
        if on_ready then on_ready() end
      end
      ui._state = function() return nil end
      ui.develop = function() acted = true end
      local ok, err = pcall(function() neolit.key("d") end)
      t:ok(ok, err)
      t:ok(opened, "key on a closed panel opens it first")
      t:ok(acted, "the action runs after open")

      neolit.open = function() opened = "reopened" end
      ui._state = function() return { frame = true } end
      neolit.key("q")
      t:ok(opened ~= "reopened", "quit on a closed panel never opens it")
      t:eq(pcall(neolit.key, "j"), true, "unknown keys are ignored")

      neolit.open, ui._state, ui.develop = real_open, real_state, real_develop
    end,
  },
}
