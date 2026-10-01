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

-- The standard 16-base + 6×6×6 cube + 24-gray xterm palette, as packed RGB.
local XTERM_PALETTE = nil
local function xterm_palette()
  if XTERM_PALETTE then return XTERM_PALETTE end
  local palette = {}
  local base = {
    0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
    0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
  }
  for _, rgb in ipairs(base) do palette[#palette + 1] = rgb end
  local levels = { 0, 95, 135, 175, 215, 255 }
  for r = 1, 6 do
    for g = 1, 6 do
      for b = 1, 6 do
        palette[#palette + 1] = levels[r] * 0x10000 + levels[g] * 0x100 + levels[b]
      end
    end
  end
  for gray = 8, 238, 10 do
    palette[#palette + 1] = gray * 0x10000 + gray * 0x100 + gray
  end
  XTERM_PALETTE = palette
  return palette
end

--- Nearest xterm-256 palette index for a #rrggbb color, so panels stay
--- colored when `termguicolors` is off (guifg alone is ignored then).
function M.xterm256(hex)
  local value = tonumber(hex and hex:match("^#(%x%x%x%x%x%x)$") or "", 16)
  if not value then return nil end
  local r, g, b = math.floor(value / 0x10000) % 0x100, math.floor(value / 0x100) % 0x100, value % 0x100
  local palette = xterm_palette()
  local best_index, best_distance = 0, math.huge
  for index, rgb in ipairs(palette) do
    local pr, pg, pb = math.floor(rgb / 0x10000) % 0x100, math.floor(rgb / 0x100) % 0x100, rgb % 0x100
    local dr, dg, db = r - pr, g - pg, b - pb
    local distance = dr * dr + dg * dg + db * db
    if distance < best_distance then
      best_index, best_distance = index - 1, distance
    end
  end
  return best_index
end

--- Defines all highlight groups through `api` (nvim's API table). Existing
--- user definitions win: groups are created with default=true, so a user
--- highlight set before/after setup overrides the palette.
function M.apply(api)
  api = api or vim.api
  local function spec(hex, extra)
    local attributes = { fg = hex, ctermfg = M.xterm256(hex), default = true }
    if extra then
      for key, value in pairs(extra) do attributes[key] = value end
    end
    return attributes
  end
  for name, hex in pairs(M.colors) do
    if name ~= "selected" then -- selected is a background, not a foreground
      local group = M.group_for(hex, false)
      api.nvim_set_hl(0, group, spec(hex))
      api.nvim_set_hl(0, group .. "Bold", spec(hex, { bold = true }))
    end
  end
  api.nvim_set_hl(0, "NeolitSelected", spec(M.colors.selected, { bg = M.colors.selected, ctermbg = M.xterm256(M.colors.selected) }))
  api.nvim_set_hl(0, "NeolitCursorLine", spec(M.colors.selected, { bg = M.colors.selected, ctermbg = M.xterm256(M.colors.selected) }))
end

return M
