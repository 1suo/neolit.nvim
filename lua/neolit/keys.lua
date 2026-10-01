--- TUI key routing: the same key set augment.tsx handles through Ink's
--- global useInput — j/k pane-aware motion, Tab pane switch, 1-9 approach
--- choice, and one key per controller operation. Identical maps are attached
--- to both focusable buffers, so the frame behaves as one plane regardless
--- of which pane is focused.

local M = {}

local unpack_table = unpack or table.unpack

M.DIGITS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

--- which-key descriptions for the panel keymaps.
M.descriptions = {
  ["j"] = "neolit: move selection / scroll detail",
  ["k"] = "neolit: move selection / scroll detail",
  ["<Down>"] = "neolit: move selection / scroll detail",
  ["<Up>"] = "neolit: move selection / scroll detail",
  ["<Tab>"] = "neolit: switch pane",
  ["<Right>"] = "neolit: switch pane",
  ["<Left>"] = "neolit: focus tree",
  ["<CR>"] = "neolit: message / regenerate this path",
  ["n"] = "neolit: new change plan",
  ["e"] = "neolit: explain selected path",
  ["d"] = "neolit: develop selected path",
  ["a"] = "neolit: apply drafted patch",
  ["c"] = "neolit: commit applied paths",
  ["l"] = "neolit: mark path locked",
  ["w"] = "neolit: mark path allowed",
  ["m"] = "neolit: switch models",
  ["o"] = "neolit: reopen selected node",
  ["s"] = "neolit: mark path changed outside the plan",
  ["q"] = "neolit: quit panel",
  ["<Esc>"] = "neolit: cancel running operation",
  ["za"] = "neolit: toggle folder under cursor",
  ["zc"] = "neolit: collapse folder under cursor",
  ["zo"] = "neolit: expand folder under cursor",
  ["H"] = "neolit: show planned paths only",
  ["o"] = "neolit: open selected file (patch buffer for new files)",
  ["p"] = "neolit: edit drafted patch; :w saves it into the plan",
}

--- Returns the key → handler table against the ui module. Pure: handlers
--- only call ui methods, so tests drive them with a recording stub.
function M.handlers(ui)
  local function motion(down)
    return function()
      if ui.pane() == "detail" then
        ui.scroll_detail(down and 1 or -1)
      else
        ui.move(down and 1 or -1)
      end
    end
  end

  local map = {
    ["j"] = motion(true),
    ["k"] = motion(false),
    ["<Down>"] = motion(true),
    ["<Up>"] = motion(false),
    ["<Tab>"] = function() ui.set_pane() end,
    ["<Right>"] = function() ui.set_pane() end,
    ["<Left>"] = function() ui.set_pane("tree") end,
    ["<CR>"] = function() ui.prompt_message() end,
    ["n"] = function() ui.prompt_objective() end,
    ["e"] = function() ui.prompt_explanation() end,
    ["d"] = function() ui.develop() end,
    ["a"] = function() ui.apply_selected() end,
    ["c"] = function() ui.commit_applied() end,
    ["l"] = function() ui.restrict("lock") end,
    ["w"] = function() ui.restrict("allow") end,
    ["m"] = function() ui.switch_model() end,
    ["o"] = function() ui.prompt_reopen() end,
    ["s"] = function() ui.prompt_stale() end,
    ["q"] = function() ui.quit() end,
    ["<Esc>"] = function() ui.cancel_op() end,
    ["za"] = function() ui.toggle_fold("toggle") end,
    ["zc"] = function() ui.toggle_fold("close") end,
    ["zo"] = function() ui.toggle_fold("open") end,
    ["H"] = function() ui.toggle_plan_only() end,
    ["o"] = function() ui.open_selected() end,
    ["p"] = function() ui.edit_patch() end,
  }
  for _, digit in ipairs(M.DIGITS) do
    local n = tonumber(digit)
    map[digit] = function() ui.choose(n) end
  end
  return map
end

function M.attach(ui, buf)
  for lhs, rhs in pairs(M.handlers(ui)) do
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = M.descriptions[lhs],
    })
  end
end

--- Global access to the panel actions under a prefix (e.g. "<leader>n"):
--- the same TUI operation keys, callable from anywhere. Motion keys (j/k,
--- arrows) stay pane-local; everything else — including 1-9, <CR>, <Tab>,
--- and <Esc> — is bound. `dispatcher(key)` decides what a key does (see
--- `require("neolit").key`), so map creation stays separate from policy.
M.global_actions = {
  ["n"] = { "prompt_objective" },
  ["e"] = { "prompt_explanation" },
  ["<CR>"] = { "prompt_message" },
  ["d"] = { "develop" },
  ["a"] = { "apply_selected" },
  ["c"] = { "commit_applied" },
  ["l"] = { "restrict", "lock" },
  ["w"] = { "restrict", "allow" },
  ["m"] = { "switch_model" },
  ["o"] = { "prompt_reopen" },
  ["s"] = { "prompt_stale" },
  ["q"] = { "quit" },
  ["<Tab>"] = { "set_pane" },
  ["<Esc>"] = { "cancel_op" },
}

local function global_action_map()
  local map = {}
  for key, action in pairs(M.global_actions) do
    map[key] = action
  end
  for _, digit in ipairs(M.DIGITS) do
    map[digit] = { "choose", tonumber(digit) }
  end
  return map
end

M.global_action_map = global_action_map

function M.bind_global(prefix, dispatcher)
  for key in pairs(global_action_map()) do
    vim.keymap.set("n", prefix .. key, function()
      dispatcher(key)
    end, {
      noremap = true,
      desc = M.descriptions[key] or ("neolit: choose approach " .. key),
    })
  end
end

return M
