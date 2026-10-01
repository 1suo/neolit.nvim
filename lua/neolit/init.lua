--- neolit.nvim public seam: setup, :Neolit / :NeolitClose commands, open
--- with an optional objective (the TUI's `augment <objective>` argument).

local config = require("neolit.config")
local theme = require("neolit.theme")
local ui = require("neolit.ui")

local M = {}

local configured = nil

function M.setup(user)
  configured = config.merge(user)
  theme.apply()

  local group = vim.api.nvim_create_augroup("Neolit", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() ui.close() end })
  vim.api.nvim_create_user_command("Neolit", function(options)
    local objective = options.args ~= "" and options.args or nil
    M.open(objective)
  end, { nargs = "?", desc = "Open the neolit planned-diff panel" })
  vim.api.nvim_create_user_command("NeolitClose", function() ui.close() end, { desc = "Close the neolit planned-diff panel" })

  return configured
end

function M.open(objective)
  if not configured then M.setup({}) end
  local opts = configured
  if objective then
    opts = vim.tbl_extend("force", configured, { objective = objective })
  end
  ui.open(opts)
end

function M.close()
  ui.close()
end

--- Effective configuration, mostly for tests and :NeolitStatus-style introspection.
function M.config()
  return configured or config.merge(nil)
end

return M
