local layout = require("neolit.layout")

return {
  {
    name = "spends the viewport like the TUI frame budget",
    run = function(t)
      local boxes = layout.compute(100, 40, { margin = 1, tree_ratio = 0.42 })
      t:eq(boxes.header, { row = 1, col = 1, width = 98, height = 1, border = "none", focusable = false })
      t:eq(boxes.panel, { row = 36, col = 1, width = 98, height = 3, border = "rounded", focusable = false })
      t:eq(boxes.legend.row, 34)
      t:eq(boxes.tree.row, 3)
      t:eq(boxes.tree.height, 31, "panes fill the space between header and legend")
      t:eq(boxes.detail.height, 31)
      t:eq(boxes.tree.width, 41, "42% of the content width")
      t:eq(boxes.detail.col, 43, "tree plus one gap column")
      t:eq(boxes.detail.width, 56)
    end,
  },
  {
    name = "keeps the detail pane at minimum width before the tree",
    run = function(t)
      local boxes = layout.compute(80, 40, { margin = 1, tree_ratio = 0.42 })
      t:eq(boxes.tree.width, 32, "42% of the content width")
      t:eq(boxes.detail.width, 45, "detail takes the remainder")
      local squeezed = layout.compute(60, 40, { margin = 1, tree_ratio = 0.9 })
      t:eq(squeezed.detail.width, 30, "detail keeps its floor")
      t:eq(squeezed.tree.width, 27, "tree shrinks to fit")
    end,
  },
  {
    name = "degrades panes to one row instead of overflowing",
    run = function(t)
      local boxes = layout.compute(100, 10, {})
      t:eq(boxes.tree.height, 1)
      t:eq(boxes.detail.height, 1)
      t:ok(boxes.panel.height >= 3, "panel chrome survives")
    end,
  },
  {
    name = "only the two panes are focusable",
    run = function(t)
      local boxes = layout.compute(120, 40, {})
      t:eq(boxes.tree.focusable, true)
      t:eq(boxes.detail.focusable, true)
      t:eq(boxes.header.focusable, false)
      t:eq(boxes.legend.focusable, false)
      t:eq(boxes.panel.focusable, false)
    end,
  },
}
