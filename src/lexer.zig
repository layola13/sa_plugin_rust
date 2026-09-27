//! Rust lexer.
//!
//! Emits a flat, zero-copy token stream: identifiers/literals are `[]const u8`
//! slices into the original buffer, positions are byte offsets. Comments and
//! whitespace are skipped inside `next()` (no separate trivia channel, because
//! the parser never needs it: doc comments only matter for tooling).
//!
//! Ambiguities resolved here rather than in the parser:
//!   * `'` starts a lifetime or a char literal, decided by what follows.
//!   * `1..2` lexes as INT DOT2 INT (a float needs a digit after the dot).
//!   * `>>` is emitted as a single token; the parser splits it when closing
//!     nested generics, exactly like sa_plugin_sla's `expectGenericClose`.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eof,
        invalid,
        identifier,
        raw_identifier,
        lifetime,

        // Literals
        int_literal,
        float_literal,
        string_literal,
        byte_string_literal,
        raw_string_literal,
        byte_literal,
        char_literal,

        // Strict + reserved keywords
        keyword_as,
        keyword_break,
        keyword_const,
        keyword_continue,
        keyword_crate,
        keyword_else,
        keyword_enum,
        keyword_extern,
        keyword_false,
        keyword_fn,
        keyword_for,
        keyword_if,
        keyword_impl,
        keyword_in,
        keyword_let,
        keyword_loop,
        keyword_match,
        keyword_mod,
        keyword_move,
        keyword_mut,
        keyword_pub,
        keyword_ref,
        keyword_return,
        keyword_self,
        keyword_Self,
        keyword_static,
        keyword_struct,
        keyword_super,
        keyword_trait,
        keyword_true,
        keyword_type,
        keyword_unsafe,
        keyword_use,
        keyword_where,
        keyword_while,
        keyword_async,
        keyword_await,
        keyword_dyn,
        // Weak keywords (contextual; treated as identifiers when parsing paths)
        keyword_union,
        keyword_macro_rules,
        keyword_try,
        keyword_raw,
        keyword_inline,
        keyword_default,
        // Reserved-for-future (parse but never treat as identifiers)
        keyword_abstract,
        keyword_become,
        keyword_box,
        keyword_do,
        keyword_final,
        keyword_macro,
        keyword_override,
        keyword_priv,
        keyword_typeof,
        keyword_unsized,
        keyword_virtual,
        keyword_yield,

        // Punctuation
        plus,
        minus,
        asterisk,
        slash,
        percent,
        caret,
        bang,
        ampersand,
        pipe,
        ampersand_ampersand,
        pipe_pipe,
        less_less,
        greater_greater,
        plus_equal,
        minus_equal,
        asterisk_equal,
        slash_equal,
        percent_equal,
        caret_equal,
        ampersand_equal,
        pipe_equal,
        less_less_equal,
        greater_greater_equal,
        equal,
        equal_equal,
        bang_equal,
        less,
        greater,
        less_equal,
        greater_equal,
        at,
        dot,
        dot_dot,
        dot_dot_dot,
        dot_dot_equal,
        comma,
        semicolon,
        colon,
        path_separator,
        dollar,
        question,
        thin_arrow,
        fat_arrow,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        hash,
        underscore,
    };

    pub fn text(buffer: []const u8, tok: Token) []const u8 {
        return buffer[tok.loc.start..tok.loc.end];
    }
};

const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "as", .keyword_as },
    .{ "break", .keyword_break },
    .{ "const", .keyword_const },
    .{ "continue", .keyword_continue },
    .{ "crate", .keyword_crate },
    .{ "else", .keyword_else },
    .{ "enum", .keyword_enum },
    .{ "extern", .keyword_extern },
    .{ "false", .keyword_false },
    .{ "fn", .keyword_fn },
    .{ "for", .keyword_for },
    .{ "if", .keyword_if },
    .{ "impl", .keyword_impl },
    .{ "in", .keyword_in },
    .{ "let", .keyword_let },
    .{ "loop", .keyword_loop },
    .{ "match", .keyword_match },
    .{ "mod", .keyword_mod },
    .{ "move", .keyword_move },
    .{ "mut", .keyword_mut },
    .{ "pub", .keyword_pub },
    .{ "ref", .keyword_ref },
    .{ "return", .keyword_return },
    .{ "self", .keyword_self },
    .{ "Self", .keyword_Self },
    .{ "static", .keyword_static },
    .{ "struct", .keyword_struct },
    .{ "super", .keyword_super },
    .{ "trait", .keyword_trait },
    .{ "true", .keyword_true },
    .{ "type", .keyword_type },
    .{ "unsafe", .keyword_unsafe },
    .{ "use", .keyword_use },
    .{ "where", .keyword_where },
    .{ "while", .keyword_while },
    .{ "async", .keyword_async },
    .{ "await", .keyword_await },
    .{ "dyn", .keyword_dyn },
    .{ "union", .keyword_union },
    .{ "macro_rules", .keyword_macro_rules },
    .{ "try", .keyword_try },
    .{ "raw", .keyword_raw },
    .{ "inline", .keyword_inline },
    .{ "default", .keyword_default },
    .{ "abstract", .keyword_abstract },
    .{ "become", .keyword_become },
    .{ "box", .keyword_box },
    .{ "do", .keyword_do },
    .{ "final", .keyword_final },
    .{ "macro", .keyword_macro },
    .{ "override", .keyword_override },
    .{ "priv", .keyword_priv },
    .{ "typeof", .keyword_typeof },
    .{ "unsized", .keyword_unsized },
    .{ "virtual", .keyword_virtual },
    .{ "yield", .keyword_yield },
});

pub fn keywordTag(word: []const u8) ?Token.Tag {
    return keywords.get(word);
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) Lexer {
        return .{ .buffer = buffer, .index = 0 };
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        if (self.index >= self.buffer.len) return self.make(.eof, self.index, self.index);

        const start = self.index;
        const c = self.buffer[self.index];

        switch (c) {
            '0'...'9' => return self.lexNumber(),
            'b', 'r' => {
                if (self.lexPrefixWord()) |tok| return tok;
            },
            '"' => {
                self.index += 1;
                self.lexStringBody();
                return self.make(.string_literal, start, self.index);
            },
            '\'' => return self.lexQuote(),
            else => {},
        }

        if (isIdentStart(c)) {
            // `b'a'` / `b"..."` byte forms and `br"..."` byte-raw forms.
            if (c == 'b' and self.index + 1 < self.buffer.len) {
                const n = self.buffer[self.index + 1];
                if (n == '"') {
                    self.index += 2;
                    self.lexStringBody();
                    return self.make(.byte_string_literal, start, self.index);
                }
                if (n == '\'') {
                    self.index += 2;
                    _ = self.lexCharBody();
                    return self.make(.byte_literal, start, self.index);
                }
            }
            if (c == 'r' and self.index + 1 < self.buffer.len) {
                const n = self.buffer[self.index + 1];
                if (n == '"' or n == '#') {
                    if (self.lexRawString()) return self.make(.raw_string_literal, start, self.index);
                }
            }
            self.index += 1;
            while (self.index < self.buffer.len and isIdentChar(self.buffer[self.index])) self.index += 1;
            const word = self.buffer[start..self.index];
            const tag = keywordTag(word) orelse .identifier;
            return self.make(tag, start, self.index);
        }

        return self.lexPunct();
    }

    fn make(_: *Lexer, tag: Token.Tag, start: usize, end: usize) Token {
        return .{ .tag = tag, .loc = .{ .start = start, .end = end } };
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        const i = self.index + offset;
        if (i >= self.buffer.len) return null;
        return self.buffer[i];
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.index += 1;
            } else if (c == '/' and self.peekAt(1) == '/') {
                while (self.index < self.buffer.len and self.buffer[self.index] != '\n') self.index += 1;
            } else if (c == '/' and self.peekAt(1) == '*') {
                self.index += 2;
                var depth: usize = 1;
                while (self.index < self.buffer.len and depth > 0) {
                    if (self.buffer[self.index] == '/' and self.peekAt(1) == '*') {
                        depth += 1;
                        self.index += 2;
                    } else if (self.buffer[self.index] == '*' and self.peekAt(1) == '/') {
                        depth -= 1;
                        self.index += 2;
                    } else {
                        self.index += 1;
                    }
                }
            } else {
                return;
            }
        }
    }

    /// `r#ident` and `br#ident` / `br"..."` are the only places a `b`/`r` word
    /// does not start an identifier. Returns null when the word is a plain ident.
    fn lexPrefixWord(self: *Lexer) ?Token {
        const start = self.index;
        if (self.buffer[self.index] == 'r' and self.peekAt(1) == '#' and isIdentStart(self.peekAt(2) orelse 0)) {
            self.index += 2;
            while (self.index < self.buffer.len and isIdentChar(self.buffer[self.index])) self.index += 1;
            return self.make(.raw_identifier, start, self.index);
        }
        return null;
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.index;
        const base_hex = self.buffer[self.index] == '0' and
            (self.peekAt(1) == 'x' or self.peekAt(1) == 'X');

        if (base_hex) {
            self.index += 2;
            while (self.index < self.buffer.len) {
                const c = self.buffer[self.index];
                if (isHexDigit(c) or c == '_') {
                    self.index += 1;
                } else {
                    break;
                }
            }
        } else {
            while (self.index < self.buffer.len) {
                const c = self.buffer[self.index];
                if (isDigit(c) or c == '_') {
                    self.index += 1;
                } else {
                    break;
                }
            }
            // Fractional part: a `.` only continues the number if a digit follows,
            // so `1..2` lexes as INT DOTDOT INT.
            if (self.index < self.buffer.len and self.buffer[self.index] == '.' and isDigit(self.peekAt(1) orelse 0)) {
                self.index += 1;
                while (self.index < self.buffer.len) {
                    const c = self.buffer[self.index];
                    if (isDigit(c) or c == '_') {
                        self.index += 1;
                    } else {
                        break;
                    }
                }
                return self.lexNumSuffix(.float_literal, start);
            }
        }

        // Exponent.
        const exp_ch = self.index < self.buffer.len and
            ((self.buffer[self.index] == 'e' or self.buffer[self.index] == 'E') and
            !base_hex);
        if (exp_ch) {
            const save = self.index;
            self.index += 1;
            if (self.index < self.buffer.len and (self.buffer[self.index] == '+' or self.buffer[self.index] == '-')) {
                self.index += 1;
            }
            if (self.index < self.buffer.len and isDigit(self.buffer[self.index])) {
                while (self.index < self.buffer.len and (isDigit(self.buffer[self.index]) or self.buffer[self.index] == '_')) {
                    self.index += 1;
                }
                return self.lexNumSuffix(.float_literal, start);
            }
            self.index = save;
        }

        return self.lexNumSuffix(.int_literal, start);
    }

    /// Consume a type suffix such as `u8`, `i64`, `usize`, `f32`.
    fn lexNumSuffix(self: *Lexer, int_tag: Token.Tag, start: usize) Token {
        const save = self.index;
        if (self.index < self.buffer.len and isIdentStart(self.buffer[self.index])) {
            while (self.index < self.buffer.len and isIdentChar(self.buffer[self.index])) self.index += 1;
            const suffix = self.buffer[save..self.index];
            if (isNumSuffix(suffix)) return self.make(int_tag, start, self.index);
            self.index = save;
        }
        return self.make(int_tag, start, self.index);
    }

    fn lexStringBody(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == '\\') {
                self.index += 2;
                continue;
            }
            if (c == '"') {
                self.index += 1;
                return;
            }
            self.index += 1;
        }
    }

    fn lexCharBody(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == '\\') {
                self.index += 2;
                continue;
            }
            if (c == '\'') {
                self.index += 1;
                return;
            }
            self.index += 1;
        }
    }

    /// `r"..."`, `r#"..."#`, `r##"..."##`
    fn lexRawString(self: *Lexer) bool {
        const start = self.index;
        var i = self.index + 1;
        var hashes: usize = 0;
        while (i < self.buffer.len and self.buffer[i] == '#') : (hashes += 1) i += 1;
        if (i >= self.buffer.len or self.buffer[i] != '"') {
            self.index = start;
            return false;
        }
        i += 1;
        while (i < self.buffer.len) {
            if (self.buffer[i] == '"') {
                var closing: usize = 0;
                while (closing < hashes and i + 1 + closing < self.buffer.len and self.buffer[i + 1 + closing] == '#') {
                    closing += 1;
                }
                if (closing == hashes) {
                    self.index = i + 1 + hashes;
                    return true;
                }
            }
            i += 1;
        }
        self.index = self.buffer.len;
        return true;
    }

    fn lexQuote(self: *Lexer) Token {
        const start = self.index;
        // `'` followed by ident-start: lifetime unless the ident is exactly one
        // character and immediately closed by `'`.
        const n = self.peekAt(1);
        if (n != null and isIdentStart(n.?)) {
            var i = self.index + 1;
            while (i < self.buffer.len and isIdentChar(self.buffer[i])) i += 1;
            if (i < self.buffer.len and self.buffer[i] == '\'' and i == self.index + 2) {
                self.index = i + 1;
                return self.make(.char_literal, start, self.index);
            }
            self.index = i;
            return self.make(.lifetime, start, self.index);
        }
        if (n != null and (n.? == '\\' or n.? == 'x')) {
            self.index += 1;
            _ = self.lexCharBody();
            return self.make(.char_literal, start, self.index);
        }
        // `'"'`, `'{'`, `','` ... any single non-quote character is a literal,
        // and it is always three bytes wide.
        if (n != null and n.? != '\'' and n.? != 0) {
            if (self.peekAt(2) == '\'') {
                self.index += 3;
                return self.make(.char_literal, start, self.index);
            }
            // Not a literal: `'` followed by an ordinary character and something
            // other than a closing quote is a malformed lifetime.
            self.index += 1;
            return self.make(.invalid, start, self.index);
        }
        self.index += 1;
        return self.make(.invalid, start, self.index);
    }

    fn lexPunct(self: *Lexer) Token {
        const start = self.index;
        const c = self.buffer[self.index];
        const n1 = self.peekAt(1) orelse 0;
        const n2 = self.peekAt(2) orelse 0;

        if (c == '.' and n1 == '.' and n2 == '.') {
            self.index += 3;
            return self.make(.dot_dot_dot, start, self.index);
        }

        const Tag2 = struct { c0: u8, c1: u8, tag: Token.Tag };
        const two = [_]Tag2{
            .{ .c0 = '+', .c1 = '=', .tag = .plus_equal },
            .{ .c0 = '-', .c1 = '=', .tag = .minus_equal },
            .{ .c0 = '*', .c1 = '=', .tag = .asterisk_equal },
            .{ .c0 = '/', .c1 = '=', .tag = .slash_equal },
            .{ .c0 = '%', .c1 = '=', .tag = .percent_equal },
            .{ .c0 = '^', .c1 = '=', .tag = .caret_equal },
            .{ .c0 = '&', .c1 = '=', .tag = .ampersand_equal },
            .{ .c0 = '|', .c1 = '=', .tag = .pipe_equal },
            .{ .c0 = '&', .c1 = '&', .tag = .ampersand_ampersand },
            .{ .c0 = '|', .c1 = '|', .tag = .pipe_pipe },
            .{ .c0 = '<', .c1 = '<', .tag = .less_less },
            .{ .c0 = '>', .c1 = '>', .tag = .greater_greater },
            .{ .c0 = '=', .c1 = '=', .tag = .equal_equal },
            .{ .c0 = '!', .c1 = '=', .tag = .bang_equal },
            .{ .c0 = '<', .c1 = '=', .tag = .less_equal },
            .{ .c0 = '>', .c1 = '=', .tag = .greater_equal },
            .{ .c0 = ':', .c1 = ':', .tag = .path_separator },
            .{ .c0 = '.', .c1 = '.', .tag = .dot_dot },
            .{ .c0 = '-', .c1 = '>', .tag = .thin_arrow },
            .{ .c0 = '=', .c1 = '>', .tag = .fat_arrow },
        };
        for (two) |t| {
            if (c == t.c0 and n1 == t.c1) {
                self.index += 2;
                // `..=`
                if (t.tag == .dot_dot and n2 == '=') {
                    self.index += 1;
                    return self.make(.dot_dot_equal, start, self.index);
                }
                // `<<=` and `>>=`
                if ((t.tag == .less_less or t.tag == .greater_greater) and n2 == '=') {
                    self.index += 1;
                    return self.make(if (t.tag == .less_less) .less_less_equal else .greater_greater_equal, start, self.index);
                }
                return self.make(t.tag, start, self.index);
            }
        }

        if (c == '.' and n1 == '.' and n2 == '.') {
            self.index += 3;
            return self.make(.dot_dot_dot, start, self.index);
        }

        self.index += 1;
        const tag: Token.Tag = switch (c) {            '+' => .plus,
            '-' => .minus,
            '*' => .asterisk,
            '/' => .slash,
            '%' => .percent,
            '^' => .caret,
            '!' => .bang,
            '&' => .ampersand,
            '|' => .pipe,
            '=' => .equal,
            '<' => .less,
            '>' => .greater,
            '@' => .at,
            '.' => .dot,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '$' => .dollar,
            '?' => .question,
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '#' => .hash,
            '_' => .underscore,
            else => .invalid,
        };
        return self.make(tag, start, self.index);
    }
};

/// Rust numeric type suffixes that may follow a literal.
pub fn isNumSuffix(s: []const u8) bool {
    const allowed = [_][]const u8{
        "u8",   "u16",  "u32",  "u64",  "u128", "usize",
        "i8",   "i16",  "i32",  "i64",  "i128", "isize",
        "f32",  "f64",  "f16",  "f128", "bf16",
    };
    for (allowed) |a| {
        if (std.mem.eql(u8, s, a)) return true;
    }
    return false;
}

test "lexes keywords and identifiers" {
    const src = "fn main let mut x";
    var lex = Lexer.init(src);
    try std.testing.expectEqual(Token.Tag.keyword_fn, lex.next().tag);
    try std.testing.expectEqualStrings("main", Token.text(src, lex.next()));
    try std.testing.expectEqual(Token.Tag.keyword_let, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.keyword_mut, lex.next().tag);
    try std.testing.expectEqualStrings("x", Token.text(src, lex.next()));
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "distinguishes lifetime from char literal" {
    {
        const src = "'a";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.lifetime, lex.next().tag);
    }
    {
        const src = "'a'";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.char_literal, lex.next().tag);
    }
    {
        const src = "'\\n'";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.char_literal, lex.next().tag);
    }
    {
        const src = "'static";
        var lex = Lexer.init(src);
        const t = lex.next();
        try std.testing.expectEqual(Token.Tag.lifetime, t.tag);
        try std.testing.expectEqualStrings("'static", Token.text(src, t));
    }
}

test "range does not swallow the next literal" {
    const src = "0..10";
    var lex = Lexer.init(src);
    try std.testing.expectEqual(Token.Tag.int_literal, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.dot_dot, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.int_literal, lex.next().tag);
}

test "range patterns" {
    const cases = [_]struct { src: []const u8, tag: Token.Tag }{
        .{ .src = "..", .tag = .dot_dot },
        .{ .src = "...", .tag = .dot_dot_dot },
        .{ .src = "..=", .tag = .dot_dot_equal },
    };
    for (cases) |c| {
        var lex = Lexer.init(c.src);
        try std.testing.expectEqual(c.tag, lex.next().tag);
    }
}

test "numeric literals with suffix and bases" {
    {
        const src = "1_000u64";
        var lex = Lexer.init(src);
        const t = lex.next();
        try std.testing.expectEqual(Token.Tag.int_literal, t.tag);
        try std.testing.expectEqualStrings("1_000u64", Token.text(src, t));
    }
    {
        const src = "0xFFu8";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.int_literal, lex.next().tag);
    }
    {
        const src = "3.14f64";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.float_literal, lex.next().tag);
    }
    {
        const src = "1e10";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.float_literal, lex.next().tag);
    }
    {
        // A trailing dot after an integer is a field access, not a float.
        const src = "1.0";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.float_literal, lex.next().tag);
    }
    {
        const src = "0.5";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.float_literal, lex.next().tag);
    }
}

test "shift operators" {
    {
        const src = "a >> b";
        var lex = Lexer.init(src);
        _ = lex.next();
        try std.testing.expectEqual(Token.Tag.greater_greater, lex.next().tag);
    }
    {
        const src = "a >>= b";
        var lex = Lexer.init(src);
        _ = lex.next();
        try std.testing.expectEqual(Token.Tag.greater_greater_equal, lex.next().tag);
    }
    {
        const src = "a <<= b";
        var lex = Lexer.init(src);
        _ = lex.next();
        try std.testing.expectEqual(Token.Tag.less_less_equal, lex.next().tag);
    }
}

test "strings raw strings and bytes" {
    {
        const src = "\"hi\\n\"";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.string_literal, lex.next().tag);
    }
    {
        const src = "r#\"a \" b\"#";
        var lex = Lexer.init(src);
        const t = lex.next();
        try std.testing.expectEqual(Token.Tag.raw_string_literal, t.tag);
        try std.testing.expectEqualStrings("r#\"a \" b\"#", Token.text(src, t));
    }
    {
        const src = "b'x'";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.byte_literal, lex.next().tag);
    }
    {
        const src = "b\"xy\"";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.byte_string_literal, lex.next().tag);
    }
    {
        const src = "b\"a\\\"b\"";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.byte_string_literal, lex.next().tag);
    }
}

test "raw identifiers and paths" {
    {
        const src = "r#type";
        var lex = Lexer.init(src);
        const t = lex.next();
        try std.testing.expectEqual(Token.Tag.raw_identifier, t.tag);
        try std.testing.expectEqualStrings("r#type", Token.text(src, t));
    }
    {
        const src = "std::vec::Vec";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
        try std.testing.expectEqual(Token.Tag.path_separator, lex.next().tag);
        try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
        try std.testing.expectEqual(Token.Tag.path_separator, lex.next().tag);
        try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    }
}

test "skips line and nested block comments" {
    {
        const src = "a // comment\nb";
        var lex = Lexer.init(src);
        _ = lex.next();
        const t = lex.next();
        try std.testing.expectEqualStrings("b", Token.text(src, t));
    }
    {
        const src = "a /* /* nested */ */ b";
        var lex = Lexer.init(src);
        _ = lex.next();
        const t = lex.next();
        try std.testing.expectEqualStrings("b", Token.text(src, t));
    }
}

test "arrow tokens" {
    {
        const src = "-> =>";
        var lex = Lexer.init(src);
        try std.testing.expectEqual(Token.Tag.thin_arrow, lex.next().tag);
        try std.testing.expectEqual(Token.Tag.fat_arrow, lex.next().tag);
    }
}
