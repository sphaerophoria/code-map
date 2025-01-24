--package.path = './?.lua;' .. package.path
--
--local StringChunker = require("StringChunker")
--local string_chunker = StringChunker:init("the quick brown fox jumped over the lazy dog", 5)
--vim.print(2 ^ 32)
--
--while string_chunker:next() do
--    vim.print('"' .. string_chunker:data() .. '"')
--end


local s = "asdf"
vim.print(s:byte(2))
