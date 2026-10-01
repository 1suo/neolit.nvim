--- TUI key routing: the same key set augment.tsx handles through Ink's
--- global useInput — j/k pane-aware motion, Tab pane switch, 1-9 approach
--- choice, and one key per controller operation. Identical maps are attached
--- to both focusable buffers, so the frame behaves as one plane regardless
--- of which pane is focused.

local M = {}

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

return M
