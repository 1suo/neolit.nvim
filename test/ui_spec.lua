local ui = require("neolit.ui")

local function row(id, directory, repository_only)
  return { id = id, directory = directory, repositoryOnly = repository_only, segments = {} }
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
}
