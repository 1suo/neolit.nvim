--- Theme: the same Tokyo-Night-flavored palette the TUI ships in
--- dist/tui/detail.js, mapped onto Neovim highlight groups. The host sends
--- TUI hex colors per segment; `group_for` translates them. Pure except for
--- `apply`, which defines the groups through the passed-in `vim`-like table.

local M = {}

M.colors = {
  primary = "#7aa2f7",
  secondary = "#bb9af7",
  accent = "#2ac3de",
  success = "#9ece6a",
  warning = "#e0af68",
  error = "#f7768e",
  muted = "#838aa0",
  text = "#c0caf5",
  border = "#414868",
  border_active = "#7aa2f7",
  selected = "#24283b",
}

local by_hex = {}
do
  -- primary and border_active share #7aa2f7: the first name in this order
  -- wins so group naming stays deterministic.
  local order = { "primary", "secondary", "accent", "success", "warning", "error", "muted", "text", "border", "border_active", "selected" }
  for _, name in ipairs(order) do
    local hex = M.colors[name]
    if hex and by_hex[hex] == nil then by_hex[hex] = name end
  end
end

--- Hex color (or nil) plus bold flag to a highlight group name, or nil for
--- default foreground text.
function M.group_for(hex, bold)
  local name = by_hex[hex]
  if not name then
    name = hex and hex:lower():gsub("#", "hex_") or nil
    if not name then return nil end
  end
  local group = "Neolit" .. name:gsub("^%l", string.upper):gsub("_%l", string.upper):gsub("_", "")
  return bold and (group .. "Bold") or group
end

--- Defines all highlight groups through `api` (nvim's API table). Existing
--- user definitions win: groups are created with default=true, so a user
--- highlight set before/after setup overrides the palette.
function M.apply(api)
  api = api or vim.api
  for name, hex in pairs(M.colors) do
    if name ~= "selected" then -- selected is a background, not a foreground
      local group = M.group_for(hex, false)
      api.nvim_set_hl(0, group, { fg = hex, default = true })
      api.nvim_set_hl(0, group .. "Bold", { fg = hex, bold = true, default = true })
    end
  end
  api.nvim_set_hl(0, "NeolitSelected", { bg = M.colors.selected, default = true })
  api.nvim_set_hl(0, "NeolitCursorLine", { bg = M.colors.selected, default = true })
end

return M
