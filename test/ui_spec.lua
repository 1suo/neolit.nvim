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
}
