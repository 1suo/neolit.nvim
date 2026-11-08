--- Configuration and local-core resolution for the Git-native planning host.
local M = {}

M.defaults = {
  neolit_dir = nil,
  node = "node",
  directory = nil,
  comparison_base = "HEAD",
}

function M.merge(user)
  local merged = {}
  for key, value in pairs(M.defaults) do merged[key] = value end
  for key, value in pairs(user or {}) do merged[key] = value end
  return merged
end

local function normalize(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif not absolute then
        parts[#parts + 1] = part
      end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  local result = table.concat(parts, "/")
  if absolute then result = "/" .. result end
  return result == "" and (absolute and "/" or ".") or result
end

function M.find_neolit_dir(cfg, ctx)
  local candidates, seen = {}, {}
  local function add(path)
    if type(path) == "string" and path ~= "" then
      path = normalize(path)
      if not seen[path] then
        seen[path] = true
        candidates[#candidates + 1] = path
      end
    end
  end

  add(cfg.neolit_dir)
  add(ctx.env.NEOLIT_DIR)
  if ctx.plugin_root then add(ctx.plugin_root .. "/../neolit") end
  if ctx.npm_root then add(ctx.npm_root .. "/neolit") end

  for _, candidate in ipairs(candidates) do
    if ctx.readable(candidate .. "/dist/index.js")
      and ctx.readable(candidate .. "/dist/planning/workspace.js") then
      return candidate
    end
  end
  return nil, candidates
end

function M.plugin_root()
  local info = debug.getinfo(1, "S")
  local source = info and info.source
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return nil end
  local file = source:sub(2)
  if file:sub(1, 1) ~= "/" then file = vim.fn.getcwd() .. "/" .. file end
  local module_dir = file:match("^(.*)/")
  local lua_dir = module_dir and module_dir:match("^(.*)/")
  local root = lua_dir and lua_dir:match("^(.*)/")
  return root and normalize(root)
end

return M
