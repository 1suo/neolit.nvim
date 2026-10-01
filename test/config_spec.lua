local config = require("neolit.config")

local function ctx(overrides)
  local readable_paths = {}
  for _, path in ipairs(overrides and overrides.readable or {}) do
    readable_paths[path] = true
  end
  return {
    env = overrides and overrides.env or {},
    plugin_root = overrides and overrides.plugin_root or "/plugins",
    npm_root = overrides and overrides.npm_root,
    readable = function(path) return readable_paths[path] == true end,
  }
end

return {
  {
    name = "merges user options over defaults",
    run = function(t)
      local merged = config.merge({ node = "node22", no_model = true })
      t:eq(merged.node, "node22")
      t:eq(merged.no_model, true)
      t:eq(merged.persist_tasks, true, "default survives")
      t:eq(config.merge(nil).node, "node")
    end,
  },
  {
    name = "finds the neolit dir from the explicit option first",
    run = function(t)
      local context = ctx({ readable = { "/opt/neolit/dist/index.js", "/sibling/neolit/dist/index.js" }, env = { NEOLIT_DIR = "/env/neolit" } })
      local found = config.find_neolit_dir({ neolit_dir = "/opt/neolit" }, context)
      t:eq(found, "/opt/neolit")
    end,
  },
  {
    name = "falls back to env, plugin sibling, then npm root",
    run = function(t)
      local context = ctx({
        readable = { "/sibling/neolit/dist/index.js" },
        env = { NEOLIT_DIR = "/env/neolit" },
        plugin_root = "/sibling/neolit.nvim",
        npm_root = "/usr/lib/node_modules",
      })
      local found = config.find_neolit_dir({}, context)
      t:eq(found, "/sibling/neolit")

      local context_without_sibling = ctx({ env = { NEOLIT_DIR = "/env/neolit" }, plugin_root = "/sibling/neolit.nvim" })
      t:eq(select(1, config.find_neolit_dir({}, context_without_sibling)), nil, "no candidate is readable")
      local _, tried = config.find_neolit_dir({}, context_without_sibling)
      t:eq(#tried, 2, "env and sibling candidates are listed")
    end,
  },
  {
    name = "resolves the plugin root from this file's path",
    run = function(t)
      local root = config.plugin_root()
      t:ok(root and root:match("/neolit%.nvim$"), "plugin root ends with the plugin directory: " .. tostring(root))
    end,
  },
}
