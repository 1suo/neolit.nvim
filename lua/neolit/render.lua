--- Segment renderer: turns the shim's colored segment lines into buffer
--- text plus inline extmarks. The TUI composes colored <Text> runs through
--- Ink; the Neovim equivalent is one buffer line per logical line with an
--- extmark per colored run. Byte offsets, because extmark columns count
--- bytes. Pure functions over an `api` table for testability.

local M = {}

local function line_text(segments)
  local text = {}
  for _, segment in ipairs(segments) do
    text[#text + 1] = segment.text
  end
  return table.concat(text)
end

--- segment_lines: array of { segments = { { text, color, bold } } } or plain
--- { text, color, bold } lines. Sets the buffer's lines and applies one
--- extmark per colored segment in `ns`. theme supplies group_for.
function M.render_lines(api, ns, buf, theme, segment_lines)
  local texts = {}
  for _, line in ipairs(segment_lines) do
    texts[#texts + 1] = line_text(line.segments or { line })
  end
  api.nvim_buf_set_option(buf, "modifiable", true)
  api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  api.nvim_buf_set_option(buf, "modifiable", false)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for line_number, line in ipairs(segment_lines) do
    local segments = line.segments or { line }
    local column = 0
    for _, segment in ipairs(segments) do
      local group = theme.group_for(segment.color, segment.bold)
      local width = #segment.text
      if group and width > 0 then
        api.nvim_buf_set_extmark(buf, ns, line_number - 1, column, {
          end_col = column + width,
          hl_group = group,
        })
      end
      column = column + width
    end
  end
end

return M
