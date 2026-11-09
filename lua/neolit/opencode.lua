-- OpenCode HTTP transport for an existing session.
local M = {}

local function encode_path(value)
  return (tostring(value):gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function request(opts, method, path, body, callback)
  if vim.fn.executable("curl") ~= 1 then
    callback(nil, "curl is required for the OpenCode HTTP adapter")
    return
  end

  local base = (opts.url or "http://127.0.0.1:4096"):gsub("/+$", "")
  local url = base .. path
  local command = {
    "curl", "--silent", "--show-error",
    "--request", method,
    "--header", "Accept: application/json",
    "--write-out", "\\n%{http_code}",
  }
  if body ~= nil then
    command[#command + 1] = "--header"
    command[#command + 1] = "Content-Type: application/json"
    command[#command + 1] = "--data-binary"
    command[#command + 1] = "@-"
  end
  command[#command + 1] = url

  local ok, process = pcall(vim.system, command, {
    stdin = body and vim.json.encode(body) or nil,
    text = true,
  }, function(result)
    local output = result.stdout or ""
    local payload, status = output:match("^(.*)\\n(%d%d%d)\\s*$")
    if not status then
      callback(nil, result.stderr ~= "" and result.stderr or "Invalid OpenCode server response")
      return
    end
    status = tonumber(status)
    if result.code ~= 0 or status < 200 or status >= 300 then
      local detail = payload
      local decoded_ok, decoded = pcall(vim.json.decode, payload)
      if decoded_ok and type(decoded) == "table" then
        detail = decoded.message or decoded.error or payload
      end
      callback(nil, ("OpenCode HTTP %d: %s"):format(status, tostring(detail)))
      return
    end
    if payload == "" then
      callback({}, nil)
      return
    end
    local decoded_ok, decoded = pcall(vim.json.decode, payload)
    if not decoded_ok then
      callback(nil, "Could not decode OpenCode response: " .. tostring(decoded))
      return
    end
    callback(decoded, nil)
  end)
  if not ok then callback(nil, process); return end
end

local function session_path(session_id, directory, suffix)
  return "/session/" .. encode_path(session_id) .. (suffix or "") .. "?directory=" .. encode_path(directory)
end

function M.send(opts, input)
  local directory = vim.fn.fnamemodify(input.worktree, ":p")
  local session_id = input.session_id
  if type(session_id) ~= "string" or session_id == "" then
    input.on_error("No OpenCode session ID is bound")
    return
  end

  request(opts, "GET", session_path(session_id, directory), nil, function(session, err)
    if err then input.on_error(err); return end
    if type(session) ~= "table" or session.id ~= session_id then
      input.on_error("OpenCode session was not found in this worktree")
      return
    end
    local session_directory = session.location and session.location.directory
    if session_directory then
      local expected = vim.fn.resolve(directory)
      local actual = vim.fn.resolve(session_directory)
      if expected ~= actual then
        input.on_error("Bound OpenCode session belongs to a different worktree: " .. session_directory)
        return
      end
    end

    request(opts, "POST", session_path(session_id, directory, "/message"), {
      parts = { { type = "text", text = input.message } },
    }, function(response, send_err)
      if send_err then input.on_error(send_err); return end
      local parts = response and response.parts or {}
      local chunks = {}
      for _, part in ipairs(parts) do
        if part.type == "text" and type(part.text) == "string" then
          chunks[#chunks + 1] = part.text
        end
      end
      if #chunks == 0 then
        input.on_error("OpenCode returned no assistant text")
        return
      end
      input.on_chunk(table.concat(chunks, "\\n"))
      input.on_done()
    end)
  end)
end

return M
