local framing = require("neolit.framing")

return {
  {
    name = "returns complete lines and buffers partial tails",
    run = function(t)
      local decoder = framing.new_decoder()
      t:eq(framing.feed(decoder, '{"id":1}\n{"id"'), { '{"id":1}' })
      t:eq(framing.feed(decoder, ""), {})
    end,
  },
  {
    name = "reassembles lines split across chunks",
    run = function(t)
      local decoder = framing.new_decoder()
      t:eq(framing.feed(decoder, "abc"), {})
      t:eq(framing.feed(decoder, "def\n"), { "abcdef" })
      t:eq(decoder.buffer, "")
    end,
  },
  {
    name = "strips carriage returns",
    run = function(t)
      local decoder = framing.new_decoder()
      t:eq(framing.feed(decoder, '{"id":2}\r\n'), { '{"id":2}' })
    end,
  },
  {
    name = "keeps multiple lines from one chunk in order",
    run = function(t)
      local decoder = framing.new_decoder()
      t:eq(framing.feed(decoder, "one\ntwo\nthree"), { "one", "two" })
      t:eq(framing.feed(decoder, "\n"), { "three" })
    end,
  },
}
