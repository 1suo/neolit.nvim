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
    name = "system palette links groups to semantic colorscheme targets",
    run = function(t)
      local defined = {}
      local api = {
        nvim_set_hl = function(_, group, spec) defined[group] = spec end,
        nvim_get_hl = function(_, opts)
          local canned = {
            Special = { fg = 16777215, ctermfg = 15 },
            Comment = { fg = 8421504, ctermfg = 59 },
            Normal = { fg = 0, ctermfg = 0 },
          }
          return canned[opts.name]
        end,
      }
      theme.apply(api, { palette = "system" })
      t:eq(defined.NeolitPrimary.link, "Special")
      t:eq(defined.NeolitMuted.link, "Comment")
      t:eq(defined.NeolitCursorLine.link, "Visual", "selected row follows the theme's selection color")
      -- Bold variants cannot be links; they copy resolved colors + bold.
      t:eq(defined.NeolitPrimaryBold.fg, 16777215)
      t:eq(defined.NeolitPrimaryBold.ctermfg, 15)
      t:eq(defined.NeolitPrimaryBold.bold, true)
    end,
  },
  {
    name = "tui palette keeps exact hexes with xterm fallbacks",
    run = function(t)
      local defined = {}
      local api = {
        nvim_set_hl = function(_, group, spec) defined[group] = spec end,
        nvim_get_hl = function() return nil end,
      }
      theme.apply(api, { palette = "tui" })
      for _, name in ipairs({ "primary", "secondary", "accent", "success", "warning", "error", "muted", "text" }) do
        local group = theme.group_for(theme.colors[name], false)
        t:eq(defined[group].fg, theme.colors[name])
        t:ok(type(defined[group].ctermfg) == "number", group .. " carries a 256-color fallback")
        t:eq(defined[group .. "Bold"].bold, true)
      end
      t:eq(defined.NeolitCursorLine.ctermbg, theme.xterm256(theme.colors.selected))
    end,
  },
  {
    name = "xterm256 maps palette hexes to sane terminal colors",
    run = function(t)
      t:eq(theme.xterm256("#000000"), 0, "black maps to base black")
      t:eq(theme.xterm256("#ffffff"), 15, "white maps to base white")
      t:eq(theme.xterm256("#838aa0"), 103, "blue-gray muted lands in the cube, not the gray ramp")
      t:eq(theme.xterm256("#c0caf5"), 153, "bluish text white lands in the cube")
      t:ok(theme.xterm256("#7aa2f7") >= 16 and theme.xterm256("#7aa2f7") <= 231, "primary lands in the color cube")
      t:eq(theme.xterm256("nonsense"), nil)
    end,
  },
}
