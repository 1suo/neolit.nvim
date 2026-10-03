--- Host client unit tests: stdout chunk reassembly. One JSON-RPC line
--- longer than a pipe buffer arrives as unterminated fragments across
--- several on_stdout callbacks; the pending request must still resolve.
local hostmod = require("neolit.host")

local function fake_host()
  return { decoder = require("neolit.framing").new_decoder(), pending = {}, handlers = {} }
end

return {
  {
    name = "a response split across callbacks resolves its pending request",
    run = function(t)
      local host = fake_host()
      local answered = nil
      host.pending[7] = function(message) answered = message end
      local payload = vim.json.encode({ jsonrpc = "2.0", id = 7, result = { ok = true, pad = string.rep("x", 5000) } })
      -- Split mid-JSON at an arbitrary byte: two fragments, the stream's
      -- own newline arriving with the second half.
      local cut = math.floor(#payload / 2) + 37
      hostmod._on_data(host, { payload:sub(1, cut) })
      t:eq(answered, nil, "the partial fragment does not resolve the request")
      hostmod._on_data(host, { payload:sub(cut + 1), "" })
      t:ok(answered and answered.result and answered.result.ok == true, "the completed line resolves the request")
    end,
  },
  {
    name = "complete lines in one batch plus an unterminated tail",
    run = function(t)
      local host = fake_host()
      local seen = {}
      host.handlers.on_progress = function(params) seen[#seen + 1] = params.operation end
      host.pending[1] = function(message) seen[#seen + 1] = "id" .. tostring(message.id) end
      local first = vim.json.encode({ jsonrpc = "2.0", method = "neolit/progress", params = { operation = "Working" } })
      local second = vim.json.encode({ jsonrpc = "2.0", id = 1, result = nil })
      -- Batch 1: a complete line, then the start of the next (no newline).
      hostmod._on_data(host, { first, second:sub(1, 20) })
      t:eq(seen, { "Working" }, "the complete line dispatches immediately")
      -- Batch 2: the rest, newline-terminated (trailing empty element).
      hostmod._on_data(host, { second:sub(21), "" })
      t:eq(seen, { "Working", "id1" }, "the finished line dispatches once complete")
    end,
  },
}
