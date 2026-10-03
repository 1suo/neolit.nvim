--- Lua test harness. Run with:
---   nvim --clean -l test/run.lua
--- Discovers test/*_spec.lua files; each returns { { name = string, run = function(t) } }.
--- `t` provides t:eq(got, want, message) and t:ok(value, message). Exits 1 on
--- any failure and prints one line per failing expectation.

local function here()
  local info = debug.getinfo(1, "S")
  return info.source:sub(2):match("^(.*)/")
end

local base = here()
vim.opt.runtimepath:prepend(base .. "/..")
-- Treesitter parsers install to the site dir, which --clean's minimal
-- runtimepath excludes; the diff-highlighting tests need them.
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")

local spec_files = {
  "config_spec",
  "theme_spec",
  "framing_spec",
  "host_spec",
  "keys_spec",
  "ui_spec",
  "init_spec",
  "ui_smoke_spec",
}

local passed, failed = 0, 0
local failures = {}

local function eq(got, want, message)
  if type(got) ~= type(want) then
    error((message or "values differ") .. string.format(": type %s vs %s", type(got), type(want)), 2)
  elseif type(got) == "table" then
    for key, value in pairs(want) do
      eq(got[key], value, (message or "tables differ") .. "." .. tostring(key))
    end
    for key in pairs(got) do
      if want[key] == nil then
        error((message or "tables differ") .. "." .. tostring(key) .. ": unexpected key", 2)
      end
    end
  elseif got ~= want then
    error((message or "values differ") .. string.format(": %s vs %s", vim.inspect(got), vim.inspect(want)), 2)
  end
end

for _, spec_name in ipairs(spec_files) do
  local chunk, load_error = loadfile(base .. "/" .. spec_name .. ".lua")
  if not chunk then
    failed = failed + 1
    failures[#failures + 1] = spec_name .. ": " .. tostring(load_error)
  else
    local tests = chunk()
    for _, test in ipairs(tests) do
      local t = {}
      function t:eq(got, want, message)
        eq(got, want, message)
      end
      function t:ok(value, message)
        if not value then error(message or "expected truthy", 2) end
      end
      local ok, error_message = pcall(test.run, t)
      if ok then
        passed = passed + 1
        print(string.format("ok   %s · %s", spec_name, test.name))
      else
        failed = failed + 1
        failures[#failures + 1] = string.format("%s · %s\n    %s", spec_name, test.name, tostring(error_message))
        print(string.format("FAIL %s · %s", spec_name, test.name))
      end
    end
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))
if #failures > 0 then
  print("\nfailures:")
  for _, failure in ipairs(failures) do
    print("  " .. failure)
  end
  vim.cmd("cquit 1")
end
