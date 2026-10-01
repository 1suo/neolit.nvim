local keys = require("neolit.keys")

local function stub_ui()
  local calls = {}
  local ui = {}
  ui.pane = function() return ui.pane_value or "tree" end
  for _, name in ipairs({
    "set_pane", "move", "scroll_detail", "prompt_message", "prompt_objective", "prompt_explanation",
    "develop", "apply_selected", "commit_applied", "restrict", "switch_model", "prompt_reopen",
    "prompt_stale", "quit", "cancel_op", "choose",
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
        "n", "e", "d", "a", "c", "l", "w", "m", "o", "s", "q", "<Esc>",
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
}
