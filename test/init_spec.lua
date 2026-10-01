local neolit = require("neolit.init")

return {
  {
    name = "toggle opens a closed panel and closes an open one",
    run = function(t)
      local ui = require("neolit.ui")
      local calls = {}
      local real_state, real_open, real_close = ui._state, neolit.open, neolit.close
      ui._state = function() return nil end
      neolit.open = function() calls[#calls + 1] = "open" end
      neolit.close = function() calls[#calls + 1] = "close" end

      neolit.toggle()
      ui._state = function() return { frame = true } end
      neolit.toggle()
      t:eq(calls, { "open", "close" })

      ui._state, neolit.open, neolit.close = real_state, real_open, real_close
    end,
  },
}
