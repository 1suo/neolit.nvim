--- Frame geometry as the Neovim translation of the TUI's frameLayout()
--- (src/tui/detail.ts): fixed chrome — root padding, one header row, a
--- legend row plus its spacer, and the three-row message panel — is
--- subtracted from the editor size first; the tree and detail panes share
--- what is left and degrade to one row. Boxes are OUTER rectangles (float
--- borders included); bordered panes subtract 2 rows/cols for their window
--- content. Pure arithmetic on numbers.

local M = {}

local TREE_MIN_WIDTH = 30
local DETAIL_MIN_WIDTH = 30
local HEADER_ROWS = 1
local LEGEND_ROWS = 1
local LEGEND_SPACER_ROWS = 1
local PANEL_ROWS = 3 -- rounded border + one content line + border
local PANE_GAP_COLS = 1
local HEADER_SPACER_ROWS = 1
local MIN_PANE_ROWS = 1

--- Returns boxes { header, tree, detail, legend, panel } with row/col
--- (0-based, editor-relative), width, height, border, and focusable fields.
function M.compute(columns, rows, opts)
  opts = opts or {}
  local margin = opts.margin or 1
  local ratio = opts.tree_ratio or 0.42

  columns = math.max(columns or 80, 20)
  rows = math.max(rows or 24, 8)
  margin = math.max(0, math.min(margin, math.floor(columns / 4), math.floor(rows / 4)))

  local width = columns - 2 * margin
  local height = rows - 2 * margin

  local header = {
    row = margin,
    col = margin,
    width = width,
    height = HEADER_ROWS,
    border = "none",
    focusable = false,
  }

  local panel = {
    row = margin + height - PANEL_ROWS,
    col = margin,
    width = width,
    height = PANEL_ROWS,
    border = "rounded",
    focusable = false,
  }

  local legend = {
    row = panel.row - LEGEND_SPACER_ROWS - LEGEND_ROWS,
    col = margin,
    width = width,
    height = LEGEND_ROWS,
    border = "none",
    focusable = false,
  }

  local panes_top = header.row + HEADER_ROWS + HEADER_SPACER_ROWS
  local panes_height = math.max(MIN_PANE_ROWS, legend.row - panes_top)

  local tree_width = math.floor(width * ratio)
  tree_width = math.max(TREE_MIN_WIDTH, tree_width)
  local detail_width = width - tree_width - PANE_GAP_COLS
  if detail_width < DETAIL_MIN_WIDTH then
    detail_width = DETAIL_MIN_WIDTH
    tree_width = math.max(12, width - detail_width - PANE_GAP_COLS)
  end

  local tree = {
    row = panes_top,
    col = margin,
    width = tree_width,
    height = panes_height,
    border = "rounded",
    focusable = true,
    title = " FILES ",
  }

  local detail = {
    row = panes_top,
    col = margin + tree_width + PANE_GAP_COLS,
    width = detail_width,
    height = panes_height,
    border = "rounded",
    focusable = true,
  }

  return { header = header, tree = tree, detail = detail, legend = legend, panel = panel }
end

return M
