local ui = require("neolit.ui")

local function row(id, directory, repository_only)
  return { id = id, directory = directory, repositoryOnly = repository_only, segments = {} }
end

local function marked_row(id, directory)
  return { id = id, directory = directory, repositoryOnly = true, marked = true, segments = {} }
end

local rows = {
  row("entry:.", true, false),
  row("entry:src", true, false),
  row("entry:src/a.ts", false, false),
  row("entry:src/b.ts", false, true),
  row("entry:test", true, true),
  row("entry:test/c.test.ts", false, true),
  row("entry:README.md", false, true),
}

return {
  {
    name = "folding a directory hides its descendants, the folder stays",
    run = function(t)
      local visible = ui.visible_rows(rows, { src = true }, false)
      local ids = {}
      for index, r in ipairs(visible) do ids[index] = r.id end
      t:eq(ids, { "entry:.", "entry:src", "entry:test", "entry:test/c.test.ts", "entry:README.md" })
    end,
  },
  {
    name = "folding the root leaves only the root row",
    run = function(t)
      local visible = ui.visible_rows(rows, { ["."] = true }, false)
      t:eq(#visible, 1)
      t:eq(visible[1].id, "entry:.")
    end,
  },
  {
    name = "plan-only keeps planned paths and their ancestors",
    run = function(t)
      local visible = ui.visible_rows(rows, {}, true)
      local ids = {}
      for index, r in ipairs(visible) do ids[index] = r.id end
      t:eq(ids, { "entry:.", "entry:src", "entry:src/a.ts" })
    end,
  },
  {
    name = "fold and plan-only combine",
    run = function(t)
      local visible = ui.visible_rows(rows, { src = true }, true)
      local ids = {}
      for index, r in ipairs(visible) do ids[index] = r.id end
      t:eq(ids, { "entry:.", "entry:src" })
    end,
  },
  {
    name = "untouched folders fold by default; touched ones and ancestors stay open",
    run = function(t)
      -- src/a.ts is planned: src and the root stay open; test/ is untouched.
      local folded = ui.default_folded(rows)
      t:eq(folded["src"], nil, "planned ancestor stays open")
      t:eq(folded["."], nil, "root stays open")
      t:eq(folded["test"], true, "untouched folder folds by default")
      t:eq(folded["README.md"], nil, "files never fold")
      -- With no plan at all, every folder except the root folds.
      local barren = {
        row("entry:.", true, false),
        row("entry:src", true, true),
        row("entry:src/a.ts", false, true),
      }
      local barren_folded = ui.default_folded(barren)
      t:eq(barren_folded["src"], true)
      t:eq(barren_folded["."], nil)
    end,
  },
  {
    name = "frames_differ ignores identical content and catches changes",
    run = function(t)
      local frame = { tree = { rows = { { id = "entry:." } } }, detail = { { text = "x" } } }
      local same = { tree = { rows = { { id = "entry:." } } }, detail = { { text = "x" } } }
      t:ok(not ui.frames_differ(frame, same), "identical frames skip re-render")
      t:ok(not ui.frames_differ(nil, nil), "two empty frames are equal")
      local moved = { tree = { rows = { { id = "entry:." }, { id = "entry:src" } } }, detail = { { text = "x" } } }
      t:ok(ui.frames_differ(frame, moved), "row changes re-render")
      local new_detail = { tree = frame.tree, detail = { { text = "y" } } }
      t:ok(ui.frames_differ(frame, new_detail), "detail changes re-render")
      t:ok(ui.frames_differ(frame, nil), "a first frame renders")
    end,
  },
  {
    name = "related-only keeps restriction marks with their ancestors",
    run = function(t)
      local marked_rows = {
        row("entry:.", true, false),
        row("entry:src", true, false),
        row("entry:src/a.ts", false, false),
        row("entry:vendor", true, true),
        marked_row("entry:vendor/locked.ts", false),
        row("entry:other", true, true),
        row("entry:other/x.ts", false, true),
      }
      local visible = ui.visible_rows(marked_rows, {}, true)
      local ids = {}
      for index, r in ipairs(visible) do ids[index] = r.id end
      t:eq(ids, { "entry:.", "entry:src", "entry:src/a.ts", "entry:vendor", "entry:vendor/locked.ts" })

      local folded = ui.default_folded(marked_rows)
      t:eq(folded["vendor"], nil, "a marked descendant keeps its folder open")
      t:eq(folded["other"], true, "untouched folders still fold")
    end,
  },
  {
    name = "spinner glyph replacement targets the first braille frame only",
    run = function(t)
      t:eq(ui.replace_first_spinner("├─ ⠋ src/ 78%", "⠙"), "├─ ⠙ src/ 78%")
      t:eq(ui.replace_first_spinner("◆ repo/", "⠙"), "◆ repo/", "no glyph, no change")
      t:eq(ui.replace_first_spinner("⠸ deep ⠋ nesting", "⠹"), "⠹ deep ⠋ nesting", "only the first glyph moves")
    end,
  },
  {
    name = "fold levels: zm folds the shallowest open level, zr opens the shallowest folded one",
    run = function(t)
      -- Default state: test/ folded; root and src/ open (src is planned).
      local effective = ui.default_folded(rows)
      local more = ui.fold_level_targets(rows, effective, "more")
      t:eq(more.fold, { ["."] = true }, "first zm folds the root level")
      t:eq(next(more.open), nil)

      local reduce = ui.fold_level_targets(rows, effective, "reduce")
      t:eq(reduce.open, { test = true }, "zr opens the folded level")
      t:eq(next(reduce.fold), nil)

      -- With the root folded, every deeper directory is hidden, so zm has
      -- nothing more to fold and zr reopens the root.
      local root_folded = { ["."] = true }
      local more_empty = ui.fold_level_targets(rows, root_folded, "more")
      t:eq(next(more_empty.fold), nil, "zm has nothing deeper to fold")
      local reopen = ui.fold_level_targets(rows, root_folded, "reduce")
      t:eq(reopen.open, { ["."] = true }, "zr reopens the root")
    end,
  },
}
