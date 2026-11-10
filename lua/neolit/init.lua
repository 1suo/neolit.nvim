--- Neovim entry point for the Git-native planning companion.
local config = require("neolit.config")
local planning = require("neolit.planning")
local capture = require("neolit.capture")

local M = {}
local configured

function M.setup(user)
  configured = config.merge(user)
  capture.setup(configured)
  local open_key = configured.keymaps and configured.keymaps.open_workspace
  if open_key and open_key ~= false and open_key ~= "" then
    vim.keymap.set("n", open_key, M.open, { silent = true, desc = "Neolit: open_workspace" })
  end
  local maps = configured.keymaps or {}
  local function global_map(action, callback)
    local lhs = maps[action]
    if lhs and lhs ~= false and lhs ~= "" then
      vim.keymap.set("n", lhs, callback, { silent = true, desc = "Neolit: " .. action })
    end
  end
  local function require_codecompanion(command, label)
    if vim.fn.exists(":" .. command) ~= 2 then
      vim.notify("CodeCompanion.nvim is required for " .. label, vim.log.levels.ERROR)
      return false
    end
    return true
  end
  global_map("chat_open", function()
    if not require_codecompanion("CodeCompanionChat", "chat") then return end
    local adapter = (configured.codecompanion and configured.codecompanion.adapter) or "opencode"
    if type(adapter) ~= "string" or not adapter:match("^[%w_%-]+$") then
      vim.notify("Invalid CodeCompanion adapter name", vim.log.levels.ERROR)
      return
    end
    if not (configured.layout and configured.layout.chat == "current") then
      for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].filetype == "neolit-planning" then
          local target = vim.b[candidate].neolit_preview_win or vim.b[candidate].neolit_tree_win
          if target and vim.api.nvim_win_is_valid(target) then vim.api.nvim_set_current_win(target) end
          break
        end
      end
    end
    vim.cmd("CodeCompanionChat adapter=" .. adapter)
  end)
  global_map("agent_changes", function()
    if not require_codecompanion("CodeCompanionChat", "agent changes") then return end
    if not (configured.layout and configured.layout.chat == "current") then
      for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].filetype == "neolit-planning" then
          local target = vim.b[candidate].neolit_preview_win or vim.b[candidate].neolit_tree_win
          if target and vim.api.nvim_win_is_valid(target) then vim.api.nvim_set_current_win(target) end
          break
        end
      end
    end
    vim.cmd("CodeCompanionChat Changes")
  end)
  global_map("review_changes", function()
    if require_codecompanion("CodeCompanionCodeReview", "code review") then vim.cmd("CodeCompanionCodeReview") end
  end)
  global_map("chat_file", function() planning.chat_file(configured) end)
  vim.api.nvim_create_user_command("NeolitChat", function()
    if not require_codecompanion("CodeCompanionChat", "chat") then return end
    local adapter = (configured.codecompanion and configured.codecompanion.adapter) or "opencode"
    vim.cmd("CodeCompanionChat adapter=" .. adapter)
  end, { desc = "Open CodeCompanion chat", force = true })
  vim.api.nvim_create_user_command("NeolitAgentChanges", function()
    if require_codecompanion("CodeCompanionChat", "agent changes") then vim.cmd("CodeCompanionChat Changes") end
  end, { desc = "Open CodeCompanion agent changes", force = true })
  vim.api.nvim_create_user_command("NeolitReview", function()
    if require_codecompanion("CodeCompanionCodeReview", "code review") then vim.cmd("CodeCompanionCodeReview") end
  end, { desc = "Review CodeCompanion changes", force = true })
  vim.api.nvim_create_user_command("NeolitChatFile", function() planning.chat_file(configured) end,
    { desc = "Add current file as a quoted Markdown link to CodeCompanion", force = true })
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
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "neolit-planning" then
      local tree = vim.b[buf].neolit_tree_win
      if tree and vim.api.nvim_win_is_valid(tree) then
        pcall(vim.api.nvim_win_close, tree, true)
      else
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_buf(win) == buf then
              pcall(vim.api.nvim_win_close, win, true)
              break
            end
          end
        end
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return
    end
  end
end

function M.config()
  return configured or config.merge(nil)
end

return M
