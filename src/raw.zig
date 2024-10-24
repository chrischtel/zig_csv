const CsvReadError = @import("common.zig").CsvReadError;
const ParserLimitOpts = @import("common.zig").ParserLimitOpts;
const assert = @import("std").debug.assert;

/// Iterates over the fields of a CSV row
pub const RowIterator = struct {
    _row: *const Row,
    _pos: usize = 0,
    _opts: ParserLimitOpts,

    /// Gets the next field from the CSV iterator
    pub fn next(self: *RowIterator) ?[]const u8 {
        if (self._pos > self._row._data.len) {
            return null;
        }

        var in_quote = false;
        var cur_index = self._pos;

        const MAX_ITER = self._opts.max_iter;
        var index: usize = 0;
        while (index < MAX_ITER and cur_index < self._row._data.len) {
            const cur = self._row._data[cur_index];
            defer {
                index += 1;
                cur_index += 1;
            }

            if (cur_index == self._pos and cur == '"') {
                in_quote = true;
            } else if (cur == '"') {
                if (cur_index + 1 < self._row._data.len and self._row._data[cur_index + 1] == '"') {
                    continue;
                } else {
                    in_quote = false;
                }
            } else if (cur == ',') {
                if (in_quote) continue;
                defer self._pos = cur_index + 1;
                return self._row._data[self._pos..cur_index];
            }
        }

        assert(index < MAX_ITER);
        assert(!in_quote);

        defer self._pos = self._row._data.len + 1;
        return self._row._data[self._pos..];
    }
};

/// Iterates over columns in a single CSV row
/// Does not deserialize or unescape fields
/// Simply returns them as-is
pub const Row = struct {
    _data: []const u8,
    _opts: ParserLimitOpts,

    pub fn iter(self: *const Row) RowIterator {
        return .{ ._row = self, ._opts = self._opts };
    }
};

test "raw csvfield iterator" {
    const testing = @import("std").testing;

    const f1 = [_][]const u8{ "a", "b", "c", "d" };
    const f2 = [_][]const u8{ "a", "\"b\"", "\"\"", "\"d\"\"q\"" };
    const f3 = [_][]const u8{ "", "", "", "" };
    const f4 = [_][]const u8{ "\",,\"", "" };

    const tests = [_]struct {
        input: []const u8,
        fields: []const []const u8,
    }{
        .{
            .input = "a,b,c,d",
            .fields = &f1,
        },
        .{
            .input = "a,\"b\",\"\",\"d\"\"q\"",
            .fields = &f2,
        },
        .{
            .input = ",,,",
            .fields = &f3,
        },
        .{
            .input = "\",,\",",
            .fields = &f4,
        },
    };

    for (tests) |t| {
        const row = Row{ ._data = t.input, ._opts = .{} };
        var iterator = row.iter();
        var fi: usize = 0;
        while (iterator.next()) |it| {
            defer fi += 1;
            try testing.expectEqualStrings(t.fields[fi], it);
        }
        try testing.expectEqual(t.fields.len, fi);
    }
}

/// Iterates over rows in a CSV file
/// Does not unescape or deserialize rows
/// Simply returns content as-is
pub const Parser = struct {
    _text: []const u8,
    _pos: usize = 0,
    _opts: ParserLimitOpts,
    err: ?CsvReadError = null,

    /// Initializes a row iterator
    pub fn init(text: []const u8, opts: ParserLimitOpts) Parser {
        return Parser{
            ._text = text,
            ._pos = 0,
            ._opts = opts,
            .err = null,
        };
    }

    /// Gets a pointer to the next row
    /// Also validates that the row is correct
    pub fn next(self: *Parser) ?Row {
        if (self._pos >= self._text.len) {
            return null;
        }

        var in_quote = false;
        var last: u8 = ',';
        var cur_index = self._pos;

        var index: usize = 0;
        while (cur_index < self._text.len and index < self._opts.max_iter) {
            const cur = self._text[cur_index];
            defer {
                index += 1;
                cur_index += 1;
                last = cur;
            }

            if (!in_quote and last == ',' and cur == '"') {
                in_quote = true;
            } else if (cur == '"') {
                if (!in_quote) {
                    self.err = CsvReadError.UnexpectedQuote;
                    return null;
                } else if (cur_index + 1 < self._text.len) {
                    const nxt = self._text[cur_index + 1];
                    if (nxt == '"') {
                        cur_index += 1;
                        continue;
                    } else if (nxt == ',' or nxt == '\r' or nxt == '\n') {
                        in_quote = false;
                        continue;
                    } else {
                        self.err = CsvReadError.QuotePrematurelyTerminated;
                        return null;
                    }
                } else {
                    in_quote = false;
                }
            } else if (cur == '\r') {
                if (in_quote) continue;
                if (cur_index + 1 < self._text.len) {
                    const nxt = self._text[cur_index + 1];
                    if (nxt == '\n') {
                        defer self._pos = cur_index + 2;
                        return Row{
                            ._data = self._text[self._pos .. cur_index + 1],
                            ._opts = self._opts,
                        };
                    } else {
                        self.err = CsvReadError.InvalidLineEnding;
                        return null;
                    }
                } else {
                    self.err = CsvReadError.InvalidLineEnding;
                    return null;
                }
            } else if (cur == '\n') {
                if (in_quote) continue;
                defer self._pos = cur_index + 1;
                assert(cur_index + 1 <= self._text.len);
                return Row{
                    ._data = self._text[self._pos .. cur_index + 1],
                    ._opts = self._opts,
                };
            }
        }

        if (index >= self._opts.max_iter) {
            self.err = CsvReadError.InternalLimitReached;
            return null;
        }

        if (in_quote) {
            self.err = CsvReadError.UnexpectedEndOfFile;
            return null;
        }

        defer self._pos = self._text.len;
        assert(self._pos < self._text.len);

        return Row{
            ._data = self._text[self._pos..],
            ._opts = self._opts,
        };
    }
};

/// Initializes a new raw parser
pub fn init(text: []const u8, opts: ParserLimitOpts) Parser {
    return Parser.init(text, opts);
}

test "row iterator" {
    const testing = @import("std").testing;

    const tests = [_]struct {
        input: []const u8,
        count: usize,
        err: ?CsvReadError = null,
    }{
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\r\n",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\n",
            .count = 3,
        },
        .{
            .input = "\",,\",",
            .count = 1,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh",
            ,
            .count = 2,
        },
        .{
            .input =
            \\abc,"def",
            \\abc"def""geh",
            ,
            .count = 1,
            .err = CsvReadError.UnexpectedQuote,
        },
        .{
            .input =
            \\abc,"def",
            \\"def"geh",
            ,
            .count = 1,
            .err = CsvReadError.QuotePrematurelyTerminated,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh,
            ,
            .count = 1,
            .err = CsvReadError.UnexpectedEndOfFile,
        },
        .{
            .input = "abc,serkj\r",
            .count = 0,
            .err = CsvReadError.InvalidLineEnding,
        },
        .{
            .input = "abc,serkj\r1232,232",
            .count = 0,
            .err = CsvReadError.InvalidLineEnding,
        },
    };

    for (tests) |testCase| {
        var iterator = Parser.init(testCase.input, .{});
        var cnt: usize = 0;
        while (iterator.next()) |_| {
            cnt += 1;
        }

        try testing.expectEqual(testCase.err, iterator.err);
        try testing.expectEqual(testCase.count, cnt);
    }
}

test "row and field iterator" {
    const testing = @import("std").testing;

    const input =
        \\userid,name,age
        \\1,"Jonny",23
        \\2,Jack,32
    ;

    const fieldCount = 9;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |row| {
        var iter = row.iter();
        while (iter.next()) |_| {
            cnt += 1;
        }
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf, at 63" {
    const testing = @import("std").testing;

    const input =
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
        ",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
        ",012345678901234567890123456789012345678901234567890123456789\r\n,";

    const fieldCount = 17;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |r| {
        var it = r.iter();
        while (it.next()) |_| {
            cnt += 1;
        }
    }

    try testing.expectEqual(fieldCount, cnt);
}

test "crlf,\" at 63" {
    const testing = @import("std").testing;

    const input =
        ",012345,,8901234,678901,34567890123456,890123456789012345678,,,\r\n" ++
        "\"\",,012345678901234567890123456789012345678901234567890123456789\r\n" ++
        ",012345678901234567890123456789012345678901234567890123456789\r\n,";

    const fieldCount = 17;

    var parser = Parser.init(input, .{});
    var cnt: usize = 0;
    while (parser.next()) |r| {
        var it = r.iter();
        while (it.next()) |_| {
            cnt += 1;
        }
    }

    try testing.expectEqual(fieldCount, cnt);
}
