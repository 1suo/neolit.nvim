--- Newline-delimited JSON framing, the transport convention augmentd uses.
--- Pure string handling: `feed` returns every complete line carried by the
--- chunk and keeps the partial tail buffered.

local M = {}

function M.new_decoder()
  return { buffer = "" }
end

--- Appends a chunk and returns the complete lines it terminated. Carriage
--- returns are stripped so the shim also works over CRLF pipes.
function M.feed(decoder, chunk)
  decoder.buffer = decoder.buffer .. chunk
  local lines = {}
  local start = 1
  while true do
    local newline = string.find(decoder.buffer, "\n", start, true)
    if not newline then break end
    local line = string.sub(decoder.buffer, start, newline - 1)
    line = line:gsub("\r$", "")
    lines[#lines + 1] = line
    start = newline + 1
  end
  decoder.buffer = string.sub(decoder.buffer, start)
  return lines
end

return M
