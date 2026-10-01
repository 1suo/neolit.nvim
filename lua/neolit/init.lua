--- neolit.nvim public seam: setup, :Neolit / :NeolitClose commands, open
--- with an optional objective (the TUI's `augment <objective>` argument).

local config = require("neolit.config")
local theme = require("neolit.theme")
local ui = require("neolit.ui")
local keys = require("neolit.keys")

local M = {}

local configured = nil

local unpack_table = unpack or table.unpack

local function ensure_open(fn)
  if ui._state() then return fn() end
  M.open(nil, fn)
end

--- Acts as if `key` (a TUI operation key: n e <CR> d a c l w m o s q <Tab>
--- <Esc> 1-9) was pressed on the panel, opening the panel first when it is
--- closed. Unknown keys are ignored; quitting a closed panel is a no-op.
function M.key(key)
  local action = keys.global_action_map()[key]
  if not action then return end
  if action[1] == "quit" and not ui._state() then return end
  ensure_open(function()
    ui[action[1]](unpack_table(action, 2))
  end)
end

function M.setup(user)
  configured = config.merge(user)
  theme.apply(vim.api, { palette = configured.palette })

  local group = vim.api.nvim_create_augroup("Neolit", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() ui.close() end })
  vim.api.nvim_create_user_command("Neolit", function(options)
    local objective = options.args ~= "" and options.args or nil
    M.open(objective)
  end, { nargs = "?", desc = "Open the neolit planned-diff panel" })
  vim.api.nvim_create_user_command("NeolitClose", function() ui.close() end, { desc = "Close the neolit planned-diff panel" })

  if configured.keymap_prefix then
    keys.bind_global(configured.keymap_prefix, M.key)
  end

  return configured
end

function M.open(objective, on_ready)
  if not configured then M.setup({}) end
  local opts = configured
  local extras = {}
  if objective then extras.objective = objective end
  if on_ready then extras.on_ready = on_ready end
  if next(extras) ~= nil then
    opts = vim.tbl_extend("force", configured, extras)
  end
  ui.open(opts)
end

function M.close()
  ui.close()
end

--- Opens the panel when closed, closes it when open (nvim-tree style).
function M.toggle()
  if ui._state() then
    return M.close()
  end
  return M.open()
end

--- Effective configuration, mostly for tests and :NeolitStatus-style introspection.
function M.config()
  return configured or config.merge(nil)
end

return M
