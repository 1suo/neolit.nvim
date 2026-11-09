--- Neovim entry point for the Git-native planning companion.
local config = require("neolit.config")
local planning = require("neolit.planning")

local M = {}
local configured

function M.setup(user)
  configured = config.merge(user)
  local open_key = configured.keymaps and configured.keymaps.open_workspace
  if open_key and open_key ~= false and open_key ~= "" then
    vim.keymap.set("n", open_key, M.open, { silent = true, desc = "Neolit: open_workspace" })
  end
  vim.api.nvim_create_user_command("Neolit", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace", force = true })
  vim.api.nvim_create_user_command("NeolitPlan", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace", force = true })
  vim.api.nvim_create_user_command("NeolitClose", function()
    M.close()
  end, { desc = "Close the Git-native planning workspace", force = true })
  return configured
end

function M.open()
  if not configured then M.setup({}) end
  planning.open(configured)
end

M.plan = M.open

function M.close()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neolit-planning" then
        vim.api.nvim_win_close(win, true)
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        return
      end
    end
  end
end

function M.config()
  return configured or config.merge(nil)
end

return M
