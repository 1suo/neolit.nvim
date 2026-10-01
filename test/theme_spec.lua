local theme = require("neolit.theme")

return {
  {
    name = "maps TUI palette hexes to highlight groups",
    run = function(t)
      t:eq(theme.group_for(theme.colors.primary, false), "NeolitPrimary")
      t:eq(theme.group_for(theme.colors.primary, true), "NeolitPrimaryBold")
      t:eq(theme.group_for(theme.colors.error, true), "NeolitErrorBold")
      t:eq(theme.group_for(nil, false), nil, "no color means default foreground")
      t:ok(theme.group_for("#aabbcc", false), "unknown hexes still map to a deterministic group")
    end,
  },
  {
    name = "every palette color has a plain and bold group defined by apply()",
    run = function(t)
      local defined = {}
      local api = {
        nvim_set_hl = function(_, group, spec)
          defined[group] = spec
        end,
      }
      theme.apply(api)
      for name, hex in pairs(theme.colors) do
        if name ~= "selected" then
          local plain = theme.group_for(hex, false)
          local bold = theme.group_for(hex, true)
          t:ok(defined[plain], plain .. " defined")
          t:ok(defined[bold], bold .. " defined")
          t:eq(defined[plain].fg, hex)
          t:eq(defined[bold].bold, true)
        end
      end
      t:eq(defined.NeolitCursorLine.bg, theme.colors.selected)
    end,
  },
}
