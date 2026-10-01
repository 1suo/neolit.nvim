--- Theme: maps the TUI's per-segment palette roles onto Neovit highlight
--- groups. Two palettes:
---   system (default) — groups link to semantic colorscheme groups
---     (Special, Directory, diffAdded, Comment, …), so the panel follows the
---     user's theme in truecolor and 256-color alike.
---   tui — the exact Tokyo-Night-flavored hexes the terminal TUI ships,
---     plus a nearest-xterm-256 ctermfg fallback for termguicolors=off.
--- Bold variants cannot be links (Neovim limitation), so in system mode
--- they copy the resolved target colors once at apply time; plain groups
--- stay links and adapt to colorscheme changes live.

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

--- Where each palette role points in system mode. CursorLine follows Visual
--- (the theme's own selection color) because the tree's selected row IS a
--- selection.
M.semantic_links = {
  primary = "Special",
  secondary = "Type",
  accent = "Directory",
  success = "diffAdded",
  warning = "WarningMsg",
  error = "ErrorMsg",
  muted = "Comment",
  text = "Normal",
  border = "WinSeparator",
  border_active = "WinSeparator",
  selected = "Visual",
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

--- Follows highlight links to the first group with direct attributes.
local function resolve(api, name)
  for _ = 1, 8 do
    local ok, attributes = pcall(api.nvim_get_hl, 0, { name = name })
    if not ok or type(attributes) ~= "table" then return nil end
    if attributes.link and type(attributes.link) == "string" then
      name = attributes.link
    else
      return attributes
    end
  end
  return nil
end

local function define(api, group, spec)
  local attributes = { default = true }
  for key, value in pairs(spec) do attributes[key] = value end
  api.nvim_set_hl(0, group, attributes)
end

--- Defines all Neolit* groups. Existing user definitions win (default=true).
function M.apply(api, opts)
  api = api or vim.api
  opts = opts or {}
  local palette = opts.palette or "system"

  if palette == "tui" then
    for name, hex in pairs(M.colors) do
      local group = M.group_for(hex, false)
      if name == "selected" then
        define(api, group, { bg = hex, ctermbg = M.xterm256(hex) })
        define(api, "NeolitCursorLine", { bg = hex, ctermbg = M.xterm256(hex) })
      else
        define(api, group, { fg = hex, ctermfg = M.xterm256(hex) })
        define(api, group .. "Bold", { fg = hex, ctermfg = M.xterm256(hex), bold = true })
      end
    end
    return
  end

  for role, target in pairs(M.semantic_links) do
    -- border and border_active date from the float-grid chrome; no frame
    -- segment carries them, and border_active shares primary's hex (and
    -- thus its group name), so defining it would clobber NeolitPrimary.
    if role ~= "border" and role ~= "border_active" then
      local group = M.group_for(M.colors[role], false)
      if role == "selected" then
        define(api, group, { link = target })
        define(api, "NeolitCursorLine", { link = target })
      else
        define(api, group, { link = target })
        -- Bold variants cannot be links; copy the resolved colors once.
        local attributes = resolve(api, target)
        if attributes and (attributes.fg or attributes.ctermfg) then
          define(api, group .. "Bold", {
            fg = attributes.fg,
            ctermfg = attributes.ctermfg,
            bold = true,
          })
        else
          define(api, group .. "Bold", { bold = true })
        end
      end
    end
  end
end

return M
