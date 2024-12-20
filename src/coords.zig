pub const TextPosition = struct {
    line: u32, // 0 indexed
    col: u32, // 0 indexed
};

pub const TextRange = struct {
    start: TextPosition,
    end: TextPosition,

    pub fn contains(self: TextRange, pos: TextPosition) bool {
        if (pos.line < self.start.line or pos.line > self.end.line) {
            return false;
        }

        if (pos.line == self.start.line and pos.line == self.end.line) {
            return pos.col >= self.start.col and pos.col <= self.end.col;
        }

        if (pos.line == self.start.line) {
            return pos.col >= self.start.col;
        }

        if (pos.line == self.end.line) {
            return pos.col <= self.end.col;
        }

        return true;
    }
};
