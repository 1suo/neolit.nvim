--- Neovim entry point for the Git-native planning companion.
local config = require("neolit.config")
local planning = require("neolit.planning")

local M = {}
local configured

function M.setup(user)
  configured = config.merge(user)
  local group = vim.api.nvim_create_augroup("Neolit", { clear = true })
  vim.api.nvim_create_user_command("Neolit", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace" })
  vim.api.nvim_create_user_command("NeolitPlan", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace" })
  vim.api.nvim_create_user_command("NeolitClose", function()
    M.close()
  end, { desc = "Close the Git-native planning workspace" })
  return configured
end

function M.open()
  if not configured then M.setup({}) end
  planning.open(configured)
end

M.plan = M.open

function M.close()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "neolit-planning" then
    vim.cmd("close")
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.config()
  return configured or config.merge(nil)
end

return M
