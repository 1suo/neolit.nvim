--- neolit.nvim configuration: defaults, merge, and neolit dist resolution.
--- Pure: every function takes its environment (env table, readable probe,
--- plugin root) as an argument so tests can drive it without Vim state.

local M = {}

M.defaults = {
  --- Path to a neolit checkout containing dist/ (built with `npm run build`).
  --- Default resolution order: this option, $NEOLIT_DIR, a `neolit` sibling
  --- directory of this plugin, then the npm global root.
  neolit_dir = nil,
  --- Node executable used to run the host shim.
  node = "node",
  --- Repository root the plan operates on; defaults to the working directory
  --- at open time.
  directory = nil,
  --- Force the no-model mode (same as AUGMENT_TUI_NO_MODEL=1 in the TUI).
  no_model = false,
  --- Persist the active task to disk and resume the newest one on open
  --- (AUGMENT_TUI_TASKS semantics; the TUI default is on).
  persist_tasks = true,
  --- Frame geometry, mirroring the TUI: one cell of root padding and a 42%
  --- tree pane.
  margin = 1,
  tree_ratio = 0.42,
  --- Test seam: { input = function(opts, cb) end, select = function(items, opts, cb) end }
  --- overriding vim.ui.input / vim.ui.select.
  hooks = nil,
  --- Extra argv appended to the host shim (advanced; tests use --stub-runtime).
  host_args = nil,
}

function M.merge(user)
  local merged = {}
  for key, value in pairs(M.defaults) do
    merged[key] = value
  end
  for key, value in pairs(user or {}) do
    merged[key] = value
  end
  return merged
end

--- Lexically normalizes a path: collapses `.` and `seg/..` pairs without
--- touching the filesystem, so sibling candidates like
--- `/x/neolit.nvim/../neolit` compare and dedupe as `/x/neolit`.
local function normalize(path)
  if not path:find("/%.%.") and not path:find("/%./") then return path end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil else parts[#parts + 1] = part end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return (path:sub(1, 1) == "/" and "/" or "") .. table.concat(parts, "/")
end

--- Returns the first candidate directory whose dist/index.js exists, or nil
--- plus the list of candidates tried. ctx: { env = table, plugin_root = path,
--- readable = function(path) -> boolean, npm_root = path|nil }.
function M.find_neolit_dir(cfg, ctx)
  local candidates = {}
  local function add(path)
    if path and path ~= "" then
      path = normalize(path)
      if not vim.tbl_contains(candidates, path) then
        candidates[#candidates + 1] = path
      end
    end
  end

  add(cfg.neolit_dir)
  add(ctx.env.NEOLIT_DIR)
  if ctx.plugin_root then
    add(ctx.plugin_root .. "/../neolit")
  end
  if ctx.npm_root then
    add(ctx.npm_root .. "/neolit")
  end

  for _, candidate in ipairs(candidates) do
    if ctx.readable(candidate .. "/dist/index.js") then
      return candidate, nil
    end
  end
  return nil, candidates
end

--- Absolute path of this plugin's root directory (the one containing lua/,
--- host/), or nil when the source path cannot be resolved. Paths are made
--- absolute and normalized because :lua sourcing and -l scripts report
--- relative source paths.
function M.plugin_root()
  local info = debug.getinfo(1, "S")
  local source = info and info.source
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return nil end
  local file = source:sub(2)                            -- <root>/lua/neolit/config.lua
  if file:sub(1, 1) ~= "/" then
    file = vim.fn.getcwd() .. "/" .. file
  end
  local module_dir = file:match("^(.*)/")               -- <root>/lua/neolit
  local lua_dir = module_dir and module_dir:match("^(.*)/") -- <root>/lua
  local root = lua_dir and lua_dir:match("^(.*)/")      -- <root>
  return root and normalize(root)
end

return M
