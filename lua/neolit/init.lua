--- Neovim entry point for the Git-native planning companion.
local config = require("neolit.config")
local planning = require("neolit.planning")

local M = {}
local configured

function M.setup(user)
  configured = config.merge(user)
  vim.api.nvim_create_user_command("Neolit", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace", force = true })
  vim.api.nvim_create_user_command("NeolitPlan", function()
    M.open()
  end, { desc = "Open the Git-native planning workspace", force = true })
  vim.api.nvim_create_user_command("NeolitClose", function()
    M.close()
  end, { desc = "Close the Git-native planning workspace", force = true })
  vim.api.nvim_create_user_command("NeolitAgentBind", function(args)
    local session_id = args.fargs[1]
    if not session_id then
      vim.notify("Usage: :NeolitAgentBind <session-id> [label]", vim.log.levels.ERROR)
      return
    end
    local root, root_err = planning.worktree_root(configured)
    if not root then vim.notify("Cannot resolve Neolit worktree: " .. tostring(root_err), vim.log.levels.ERROR); return end
    local ok, err = planning.bind_agent_session(root, session_id, table.concat(args.fargs, " ", 2))
    if not ok then vim.notify("Could not bind agent session: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.notify("Bound agent session " .. session_id .. " to " .. vim.fn.fnamemodify(root, ":p"))
  end, { nargs = "+", desc = "Bind an existing agent session to this worktree", force = true })
  vim.api.nvim_create_user_command("NeolitAgentUnbind", function()
    local root = configured.directory or vim.fn.getcwd()
    local ok, err = planning.unbind_agent_session(root)
    if not ok then vim.notify("Could not unbind agent session: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.notify("Unbound agent session for " .. vim.fn.fnamemodify(root, ":p"))
  end, { desc = "Remove this worktree's agent session binding", force = true })
  vim.api.nvim_create_user_command("NeolitAgentSession", function()
    local root = configured.directory or vim.fn.getcwd()
    local session = planning.agent_session(root)
    vim.notify(session and ("Agent session: " .. session.label .. " [" .. session.id .. "]") or "No agent session bound to this worktree")
  end, { desc = "Show the agent session bound to this worktree", force = true })
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
