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
      for _, group in pairs({ "NeolitPrimary", "NeolitError", "NeolitCursorLine" }) do
        t:ok(type(defined[group].ctermfg) == "number", group .. " carries a 256-color fallback")
      end
    end,
  },
  {
    name = "xterm256 maps palette hexes to sane terminal colors",
    run = function(t)
      t:eq(theme.xterm256("#000000"), 0, "black maps to base black")
      t:eq(theme.xterm256("#ffffff"), 15, "white maps to base white")
      t:eq(theme.xterm256("#838aa0"), 103, "blue-gray muted lands in the cube, not the gray ramp")
      t:eq(theme.xterm256("#c0caf5"), 15, "text is near white")
      t:ok(theme.xterm256("#7aa2f7") >= 16 and theme.xterm256("#7aa2f7") <= 231, "primary lands in the color cube")
      t:eq(theme.xterm256("nonsense"), nil)
    end,
  },
}
