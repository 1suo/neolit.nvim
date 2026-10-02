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
  --- Serve no agent socket (AUGMENT_TUI_NO_SOCKET=1). Without this the
  --- panel serves `$XDG_RUNTIME_DIR/neolit/augment-nvim.sock` — its own
  --- address, so a running TUI never starves it — and external agents can
  --- attach with `augmentd --mcp --connect`.
  no_socket = false,
  --- Persist the active task to disk and resume the newest one on open
  --- (AUGMENT_TUI_TASKS semantics; the TUI default is on).
  persist_tasks = true,
  --- Panel geometry: sidebar width in columns, detail split width
  --- (nil = 45% of the editor, clamped to 40–90).
  sidebar_width = 42,
  detail_width = nil,
  --- Palette for the panel: "system" links every color to the active
  --- colorscheme's semantic groups; "tui" uses the terminal TUI's exact
  --- hexes (with an xterm-256 fallback for termguicolors=off).
  palette = "system",
  --- Global prefix (e.g. "<leader>n") binding the TUI operation keys
  --- (n e <CR> 1-9 d a c l w m o s q <Tab> <Esc>) from any buffer. Motion
  --- keys stay pane-local. nil disables global maps.
  keymap_prefix = nil,
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

--- Panel window widths for an editor `columns` cells wide with
--- `editor_windows` user windows already open. The panel reserves a minimum
--- of 12 columns per existing window, so opening it never squeezes a user
--- window to a sliver; detail is 0 when nothing fits.
function M.geometry(columns, cfg)
  cfg = cfg or {}
  local editor_windows = math.max(1, cfg.editor_windows or 1)
  local sidebar = cfg.sidebar_width or M.defaults.sidebar_width
  sidebar = math.max(20, math.min(sidebar, math.floor(columns / 2)))
  local requested = cfg.detail_width or math.floor(columns * 0.45)
  local available = columns - sidebar - 12 * editor_windows
  local detail = math.max(0, math.min(requested, 90, available))
  return { sidebar = sidebar, detail = detail }
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
