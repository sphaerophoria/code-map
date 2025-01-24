local StringChunker = {}

function StringChunker:init(content, max_chunk_len)
    file_chunker = {
        idx = 1,
        content = content,
        max_chunk_len = max_chunk_len,
        last_content = nil
    }
    setmetatable(file_chunker, { __index = self })
    return file_chunker
end

function StringChunker:next()
    if self.idx >= #self.content then
        return false
    end

    local chunk_end = math.min(self.idx + self.max_chunk_len - 1, #self.content)
    self.last_content = string.sub(self.content, self.idx, chunk_end)
    self.idx = self.idx + self.max_chunk_len;
    return true
end

function StringChunker:isLast()
    return self.idx >= #self.content
end

function StringChunker:data()
    return self.last_content
end

return StringChunker;
