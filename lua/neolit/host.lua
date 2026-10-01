--- Host client: spawns the Node shim (host/host.mjs) and speaks
--- newline-delimited JSON-RPC 2.0 over its stdio, the same framing augmentd
--- uses. Requests are matched by id; `neolit/frame` and `neolit/progress`
--- notifications are pushed to handlers. Never blocks: model operations can
--- run for minutes, so every call is asynchronous.

local framing = require("neolit.framing")

local M = {}

local function strip(message)
  return message:gsub("[\r\n]", " ")
end

function M.new(opts, handlers)
  local self = {
    chan = nil,
    dead = false,
    pending = {},
    next_id = 1,
    decoder = framing.new_decoder(),
    handlers = handlers,
  }

  self.chan = vim.fn.jobstart(opts.cmd, {
    cwd = opts.cwd,
    env = opts.env,
    stdout_buffered = false,
    on_stdout = function(_, data) M._on_data(self, data) end,
    on_stderr = function(_, data)
      if handlers.on_stderr then handlers.on_stderr(table.concat(data, "")) end
    end,
    on_exit = function(_, code)
      self.dead = true
      if handlers.on_exit then handlers.on_exit(code) end
    end,
  })
  if self.chan <= 0 then
    error("neolit: could not start host process (node not on PATH?)")
  end

  function self:request(method, params, callback)
    if self.dead then
      if callback then
        callback({ error = { message = "neolit host is not running." } })
      end
      return
    end
    local id = self.next_id
    self.next_id = id + 1
    self.pending[id] = callback or function() end
    local message = { jsonrpc = "2.0", id = id, method = method, params = params or {} }
    vim.fn.chansend(self.chan, strip(vim.json.encode(message)) .. "\n")
  end

  function self:shutdown()
    if self.dead then return end
    self:request("shutdown", {}, nil)
    vim.defer_fn(function()
      if not self.dead then vim.fn.jobstop(self.chan) end
    end, 250)
  end

  return self
end

-- nvim job callbacks deliver stdout already split into complete lines with
-- the newline stripped (and a trailing "" per batch), so each non-empty
-- entry is fed through the decoder as one terminated line. The decoder
-- stays the single framing authority and still handles embedded newlines.
function M._on_data(self, data)
  for _, chunk in ipairs(data) do
    if chunk ~= "" then
      local lines = framing.feed(self.decoder, chunk .. "\n")
      for _, line in ipairs(lines) do
        M._consume_line(self, line)
      end
    end
  end
end

function M._consume_line(self, line)
  if not line:find("%S") then return end
  -- luanil maps JSON null to Lua nil instead of vim.NIL userdata, so
  -- nullable frame fields (panel.operation, selectedRowId, …) behave.
  local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(message) == "table" then
    M._dispatch(self, message)
  end
end

function M._dispatch(self, message)
  if message.id ~= nil and self.pending[message.id] then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    callback(message)
    return
  end
  if message.method == "neolit/frame" and self.handlers.on_frame then
    self.handlers.on_frame(message.params)
  elseif message.method == "neolit/progress" and self.handlers.on_progress then
    self.handlers.on_progress(message.params)
  end
end

return M
