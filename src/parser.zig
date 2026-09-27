//! Rust parser: hand-written recursive descent over `lexer.Lexer`.
//!
//! Conventions shared with sa_plugin_sla:
//!   * explicit `error{...}` set, not `anyerror`;
//!   * an `Options` struct for parse-time switches;
//!   * `last_expected` plus `last_token` are the only diagnostic state, and
//!     `printDiagnostic` reconstructs the message from them;
//!   * all nodes are arena-allocated by the caller and children are immutable
//!     slices.
//!
//! Generic-close handling mirrors sa_plugin_sla: a `greater_greater` token is
//! split in place (by rewriting its `loc.start`) when it turns out to close
//! two nested argument lists, so `Vec<Vec<u8>>` parses without a DFA.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

pub const ParserError = error{
    SyntaxError,
    UnexpectedToken,
    UnexpectedInfixToken,
    UnexpectedTrailingToken,
    InvalidLiteral,
    ExpectedDeclaration,
    ExpectedExpression,
    ExpectedType,
    ExpectedPattern,
    InvalidMacroArgs,
    UnterminatedBlockComment,
    OutOfMemory,
};

const Tag = lexer.Token.Tag;

/// Byte offset at which each line of `source` begins.
fn buildLineTable(allocator: std.mem.Allocator, source: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .init(allocator);
    errdefer out.deinit();
    try out.append(0);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') try out.append(i + 1);
    }
    return out.toOwnedSlice();
}

pub const Parser = struct {
    pub const Options = struct {
        /// Parse function bodies. Disabling it gives a fast `check` mode.
        parse_function_bodies: bool = true,
        /// Record `#[test]` functions so the driver can emit `@test` headers.
        collect_tests: bool = true,
    };

    allocator: std.mem.Allocator,
    source: []const u8,
    lex: lexer.Lexer,
    tok: lexer.Token,
    /// Peeked token used for turbofish (`::<T>`) disambiguation.
    peeked: ?lexer.Token = null,
    last_expected: ?[]const u8 = null,
    last_token: lexer.Token = .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 } },
    options: Options = .{},
    /// Depth counter mirroring Rust's "struct literals are not allowed in an
    /// `if`/`while` condition, a `match` scrutinee or a `for` iterator"
    /// restriction, which is what disambiguates `match x { .. }` from `x { .. }`.
    no_struct_literal: u32 = 0,
    /// Depth counter for type position, where `<T>` after a path is generic
    /// arguments rather than a comparison operator.
    type_context: u32 = 0,
    /// Byte offset where each line begins, so a token offset becomes a line number
    /// by binary search instead of a rescan of the source.
    ///
    /// Eager, because positions are now recorded for every statement: a linear
    /// scan per statement would make parsing quadratic in the file length, which
    /// the 313-file corpus regression would feel immediately.
    line_starts: []const usize = &.{},

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return initWithOptions(allocator, source, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, source: []const u8, options: Options) Parser {
        var p = Parser{
            .allocator = allocator,
            .source = source,
            .lex = lexer.Lexer.init(source),
            .tok = undefined,
            .options = options,
        };
        p.line_starts = buildLineTable(allocator, source) catch &.{};
        p.tok = p.lex.next();
        return p;
    }

    /// 1-based source position of the current token.
    fn curPos(p: *Parser) ast.SrcPos {
        return p.srcPos(p.tok.loc.start);
    }

    /// 1-based source position of a byte offset, for a token consumed earlier in
    /// the same statement.
    fn srcPos(p: *const Parser, offset: usize) ast.SrcPos {
        const c = p.lineCol(offset);
        return .{ .line = c.line, .col = c.col };
    }

    // -- primitives ---------------------------------------------------------

    fn advance(p: *Parser) void {
        if (p.peeked) |pk| {
            p.tok = pk;
            p.peeked = null;
            return;
        }
        p.tok = p.lex.next();
    }

    /// One-token lookahead. The buffer *consumes* from `p.lex`, keeping the
    /// invariant "`p.lex` is positioned just after `p.tok`"; restoring `p.lex`
    /// here would desynchronise the stream on the next `advance()`.
    fn peekTok(p: *Parser) lexer.Token {
        if (p.peeked) |pk| return pk;
        const next_tok = p.lex.next();
        p.peeked = next_tok;
        return next_tok;
    }

    fn peek(p: *Parser) Tag {
        return p.peekTok().tag;
    }

    fn cur(p: *Parser) Tag {
        return p.tok.tag;
    }

    fn is(p: *Parser, tag: Tag) bool {
        return p.tok.tag == tag;
    }

    fn eat(p: *Parser, tag: Tag) bool {
        if (p.tok.tag != tag) return false;
        p.advance();
        return true;
    }

    fn expect(p: *Parser, tag: Tag) ParserError!void {
        if (p.tok.tag != tag) {
            p.last_expected = @tagName(tag);
            p.last_token = p.tok;
            return error.UnexpectedToken;
        }
        p.advance();
    }

    /// `ident` or a raw identifier `r#ident` (normalised to `ident`).
    fn expectIdent(p: *Parser) ParserError![]const u8 {
        switch (p.tok.tag) {
            .identifier => {
                const name = p.source[p.tok.loc.start..p.tok.loc.end];
                p.advance();
                return name;
            },
            .raw_identifier => {
                const raw = p.source[p.tok.loc.start..p.tok.loc.end];
                p.advance();
                return raw[2..];
            },
            .underscore => {
                p.advance();
                return "_";
            },
            // Contextual keywords are valid identifiers in most positions.
            .keyword_union, .keyword_macro_rules, .keyword_try, .keyword_box,
            .keyword_macro, .keyword_yield, .keyword_final, .keyword_override,
            .keyword_priv, .keyword_abstract, .keyword_become, .keyword_do,
            .keyword_typeof, .keyword_virtual, .keyword_unsized,
            .keyword_raw, .keyword_inline, .keyword_default,
            .keyword_self, .keyword_Self, .keyword_crate, .keyword_super,
            => {
                const name = p.source[p.tok.loc.start..p.tok.loc.end];
                p.advance();
                return name;
            },
            else => {
                p.last_expected = "identifier";
                p.last_token = p.tok;
                return error.UnexpectedToken;
            },
        }
    }

    fn at(p: *Parser, tag: Tag) bool {
        return p.tok.tag == tag;
    }

    fn atIdent(p: *Parser) bool {
        return switch (p.tok.tag) {
            .identifier, .raw_identifier => true,
            else => false,
        };
    }

    /// Like `atIdent`, but also accepts the path roots `self`/`Self`/`crate`/
    /// `super`, which appear as their own keywords.
    fn atPathStart(p: *Parser) bool {
        return p.atIdent() or switch (p.tok.tag) {
            .keyword_self, .keyword_Self, .keyword_crate, .keyword_super => true,
            else => false,
        };
    }

    /// Contextual keywords double as ordinary identifiers, so `let raw = ..`,
    /// `fn f(default: i32)` and `Foo { union: 1 }` are all valid.
    pub fn isSoftKeyword(tag: Tag) bool {
        return switch (tag) {
            .keyword_union, .keyword_macro_rules, .keyword_try, .keyword_box,
            .keyword_macro, .keyword_yield, .keyword_final, .keyword_override,
            .keyword_priv, .keyword_abstract, .keyword_become, .keyword_do,
            .keyword_typeof, .keyword_virtual, .keyword_unsized,
            .keyword_raw, .keyword_inline, .keyword_default,
            .keyword_self, .keyword_Self, .keyword_crate, .keyword_super,
            => true,
            else => false,
        };
    }

    /// True where a name (not a keyword) is syntactically required.
    fn atName(p: *Parser) bool {
        return p.atIdent() or isSoftKeyword(p.tok.tag);
    }

    /// Text of the current token.
    fn text(p: *Parser) []const u8 {
        return p.source[p.tok.loc.start..p.tok.loc.end];
    }

    /// Consume a `,` if present. Used by the lowering to re-drive the parser
    /// over raw macro argument text.
    pub fn eatComma(p: *Parser) bool {
        return p.eat(.comma);
    }

    /// Byte offset -> 1-based line/column, for `#loc` hints and diagnostics.
    ///
    /// Linear in the number of lines rather than in the file length, because the
    /// table is built once per parse and this is now called once per statement.
    pub fn lineCol(p: *const Parser, offset: usize) struct { line: u32, col: u32 } {
        const end = @min(offset, p.source.len);
        const table = p.line_starts;
        if (table.len == 0) return .{ .line = 1, .col = @intCast(end + 1) };
        var lo: usize = 0;
        var hi: usize = table.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (table[mid] <= end) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = @intCast(end - table[lo] + 1) };
    }

    pub fn printDiagnostic(p: *const Parser, stderr: std.io.AnyWriter, file: []const u8, err: anyerror) !void {
        const pos = p.lineCol(p.last_token.loc.start);
        try stderr.print(
            "Rust Syntax Error: {s} at {s}:{d}:{d} (found {s}, expected {s})\n",
            .{
                @errorName(err),
                file,
                pos.line,
                pos.col,
                tokenName(p.last_token.tag),
                p.last_expected orelse "a valid token",
            },
        );
    }

    fn tokenName(tag: Tag) []const u8 {
        return switch (tag) {
            .eof => "end of file",
            .identifier => "identifier",
            .int_literal => "integer literal",
            .float_literal => "float literal",
            .string_literal => "string literal",
            .char_literal => "char literal",
            .lifetime => "lifetime",
            .r_brace => "'}'",
            .r_paren => "')'",
            .r_bracket => "']'",
            .semicolon => "';'",
            .comma => "','",
            .equal => "'='",
            else => @tagName(tag),
        };
    }

    // -- allocation helpers -------------------------------------------------

    fn node(p: *Parser, value: ast.Node) ParserError!*ast.Node {
        const n = try p.allocator.create(ast.Node);
        n.* = value;
        return n;
    }

    fn owned(p: *Parser, comptime T: type, items: []const T) ParserError![]const T {
        return try p.allocator.dupe(T, items);
    }

    // ======================================================================
    // program
    // ======================================================================

    pub fn parseProgram(p: *Parser) ParserError!*ast.Node {
        var items: std.ArrayList(*ast.Node) = .init(p.allocator);
        errdefer items.deinit();

        while (!p.is(.eof)) {
            // Progress is measured on the lexer index, not the current token:
            // a file that contains only `#![feature(..)]` consumes tokens
            // without ever producing an item.
            const before = p.lex.index;
            const item = try p.parseItem();
            if (item) |it| try items.append(it);
            // `parseItem` can decline a token it does not own; refusing to make
            // progress here would spin forever, so surface it as a syntax error.
            if (p.lex.index == before) {
                p.last_expected = "an item";
                p.last_token = p.tok;
                return error.UnexpectedToken;
            }
        }
        return p.node(.{ .program = .{ .items = try items.toOwnedSlice() } });
    }

    // ======================================================================
    // attributes & visibility
    // ======================================================================

    fn parseInnerAttrs(p: *Parser) ParserError![]const ast.Attr {
        var out: std.ArrayList(ast.Attr) = .init(p.allocator);
        while (p.is(.hash)) {
            if (p.peek() != .bang) break;
            p.advance();
            p.advance(); // '#'
            const a = try p.parseAttrBody(true);
            try out.append(a);
        }
        return out.toOwnedSlice();
    }

    fn parseOuterAttrs(p: *Parser) ParserError![]const ast.Attr {
        var out: std.ArrayList(ast.Attr) = .init(p.allocator);
        while (p.is(.hash)) {
            p.advance();
            const a = try p.parseAttrBody(false);
            try out.append(a);
        }
        return out.toOwnedSlice();
    }

    fn parseAttrBody(p: *Parser, inner: bool) ParserError!ast.Attr {
        _ = try p.expect(.l_bracket);
        // `#[path = "x"]` and `#[derive(..)]` / `#[foo(..)]`
        const path = try p.parseAttrPath();
        var args: []const u8 = "";
        if (p.is(.equal)) {
            p.advance();
            args = p.text();
            p.advance();
        } else if (p.is(.l_paren)) {
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_paren, .r_paren);
            args = p.source[start..close];
        }
        _ = try p.expect(.r_bracket);
        return .{ .path = path, .args = args, .inner = inner };
    }

    fn parseAttrPath(p: *Parser) ParserError![]const u8 {
        var out: std.ArrayList(u8) = .init(p.allocator);
        errdefer out.deinit();
        out.appendSlice(try p.expectIdent()) catch return error.OutOfMemory;
        while (p.is(.path_separator)) {
            p.advance();
            if (p.is(.colon)) break; // `::` split
            out.appendSlice("::") catch return error.OutOfMemory;
            out.appendSlice(try p.expectIdent()) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }

    /// Consume a bracketed group. Returns the byte offset of the *closing*
    /// delimiter, so callers slicing raw text get the exact group body instead
    /// of everything up to the next token.
    fn skipBalanced(p: *Parser, open: Tag, close: Tag) ParserError!usize {
        var depth: usize = 0;
        while (!p.is(.eof)) {
            const t = p.cur();
            if (t == open) depth += 1;
            if (t == close) {
                depth -= 1;
                const close_start = p.tok.loc.start;
                p.advance();
                if (depth == 0) return close_start;
                continue;
            }
            p.advance();
        }
        p.last_expected = @tagName(close);
        p.last_token = p.tok;
        return error.UnexpectedToken;
    }

    fn parseVis(p: *Parser) ParserError!ast.Vis {
        if (!p.is(.keyword_pub)) return .inherited;
        p.advance();
        if (p.is(.l_paren)) {
            p.advance();
            if (p.eat(.keyword_crate)) {
                _ = p.eat(.comma);
                _ = try p.expect(.r_paren);
                return .crate;
            }
            if (p.eat(.keyword_in)) {
                const path = try p.parseSimplePath();
                _ = p.eat(.comma);
                _ = try p.expect(.r_paren);
                return .{ .restricted = path };
            }
            _ = try p.expect(.r_paren);
            return .public;
        }
        return .public;
    }

    /// `a::b::c` path text, used by `pub(in path)`.
    fn parseSimplePath(p: *Parser) ParserError![]const u8 {
        var out: std.ArrayList(u8) = .init(p.allocator);
        errdefer out.deinit();
        if (p.eat(.path_separator)) try out.appendSlice("::");
        while (true) {
            try out.appendSlice(try p.expectIdent());
            if (!p.is(.path_separator)) break;
            p.advance();
            if (p.is(.colon)) break;
            try out.appendSlice("::");
        }
        return out.toOwnedSlice();
    }

    // ======================================================================
    // items
    // ======================================================================

    pub fn parseItem(p: *Parser) ParserError!?*ast.Node {
        const inner_attrs = try p.parseInnerAttrs();
        const outer_attrs = try p.parseOuterAttrs();
        var attrs: std.ArrayList(ast.Attr) = .init(p.allocator);
        for (outer_attrs) |a| try attrs.append(a);
        for (inner_attrs) |a| try attrs.append(a);
        const attr_slice = try attrs.toOwnedSlice();
        return p.parseItemWithAttrs(attr_slice);
    }

    fn parseItemWithAttrs(p: *Parser, attrs: []const ast.Attr) ParserError!?*ast.Node {
        if (p.is(.semicolon)) {
            p.advance();
            return p.node(.{ .empty_stmt = .{} });
        }
        const vis = try p.parseVis();
        const item_attrs = attrs;

        switch (p.cur()) {
            .keyword_fn => return p.parseFnItem(vis, item_attrs),
            .keyword_struct => return p.parseStructItem(vis, item_attrs),
            .keyword_enum => return p.parseEnumItem(vis, item_attrs),
            .keyword_union => return p.parseUnionItem(vis, item_attrs),
            .keyword_trait => return p.parseTraitItem(vis, item_attrs),
            .keyword_impl => return p.parseImplItem(item_attrs),
            .keyword_mod => return p.parseModItem(vis, item_attrs),
            .keyword_use => return p.parseUseItem(vis),
            .keyword_type => return p.parseTypeAlias(vis, item_attrs),
            .keyword_const => {
                // `const fn` is a function; every other `const` is an item.
                if (p.peek() == .keyword_fn) {
                    p.advance();
                    return p.parseFnRest(vis, item_attrs, .{ .is_const = true });
                }
                return p.parseConstItem(vis, item_attrs);
            },
            .keyword_static => return p.parseStaticItem(vis, item_attrs),
            .keyword_extern => return p.parseExternOrCrate(vis, item_attrs),
            .keyword_default => {
                // `default impl ..` and `default fn ..` (specialization).
                p.advance();
                if (p.is(.keyword_impl)) return p.parseImplItem(attrs);
                if (p.is(.keyword_fn) or p.is(.keyword_unsafe) or p.is(.keyword_const) or p.is(.keyword_async)) {
                    return p.parseFnItem(vis, attrs);
                }
                p.last_expected = "impl or fn";
                p.last_token = p.tok;
                return error.UnexpectedToken;
            },
            .keyword_unsafe, .keyword_async => {
                // `async`/`unsafe`/`const` prefixes may stack in any order:
                // `async unsafe fn`, `unsafe impl`, `const fn`, `unsafe trait`.
                var flags: FnFlags = .{};
                var saw_modifier = false;
                while (true) {
                    if (p.eat(.keyword_async)) {
                        flags.is_async = true;
                        saw_modifier = true;
                        continue;
                    }
                    if (p.eat(.keyword_unsafe)) {
                        flags.is_unsafe = true;
                        saw_modifier = true;
                        continue;
                    }
                    if (p.eat(.keyword_const)) {
                        flags.is_const = true;
                        saw_modifier = true;
                        continue;
                    }
                    break;
                }
                if (!saw_modifier) {
                    p.last_expected = "an item keyword";
                    return error.UnexpectedToken;
                }
                switch (p.cur()) {
                    .keyword_fn => return p.parseFnRest(vis, item_attrs, flags),
                    .keyword_impl => return p.parseImplItem(item_attrs),
                    .keyword_trait => {
                        p.advance();
                        return p.parseTraitRest(vis, item_attrs);
                    },
                    .keyword_mod => return p.parseModItem(vis, item_attrs),
                    .keyword_extern => return p.parseExternOrCrate(vis, item_attrs),
                    else => {
                        p.last_expected = "an item keyword";
                        return error.UnexpectedToken;
                    },
                }
            },
            .keyword_macro_rules, .identifier => {
                // A path followed by `!` is a macro invocation item.
                if (p.isMacroCallAhead()) {
                    return p.parseMacroItem();
                }
                // An `ident` at item position can only be a macro invocation.
                return null;
            },
            else => {
                p.last_expected = "an item";
                p.last_token = p.tok;
                return error.ExpectedDeclaration;
            },
        }
    }

    /// True when the token stream at the cursor is `path ! (`.
    fn isMacroCallAhead(p: *Parser) bool {
        var lex = p.lex;
        var tok = p.tok;
        if (tok.tag == .keyword_macro_rules) return true;
        if (tok.tag != .identifier and tok.tag != .keyword_crate and tok.tag != .keyword_self and tok.tag != .keyword_Self and tok.tag != .keyword_super) return false;
        while (true) {
            tok = lex.next();
            if (tok.tag == .bang) {
                const n = lex.next();
                return n.tag == .l_paren or n.tag == .l_bracket or n.tag == .l_brace;
            }
            if (tok.tag == .path_separator) continue;
            if (tok.tag == .identifier or tok.tag == .raw_identifier) continue;
            if (tok.tag == .keyword_crate or tok.tag == .keyword_self or tok.tag == .keyword_Self or tok.tag == .keyword_super) continue;
            return false;
        }
    }

    fn parseMacroItem(p: *Parser) ParserError!?*ast.Node {
        const path = try p.parseMacroPath();
        _ = try p.expect(.bang);
        // `macro_rules! name { body }` has no delimiter right after the bang.
        if (std.mem.eql(u8, path, "macro_rules") and !isDelimiter(p.cur())) {
            return p.parseMacroRulesTail();
        }
        return p.finishMacroItem(path);
    }

    fn isDelimiter(tag: Tag) bool {
        return tag == .l_paren or tag == .l_bracket or tag == .l_brace;
    }

    /// Capture `name { tokens }` verbatim; macro bodies are expanded later.
    fn parseMacroRulesTail(p: *Parser) ParserError!*ast.Node {
        const start = p.tok.loc.start;
        if (p.atIdent()) _ = try p.expectIdent() else _ = p.eat(.underscore);
        if (p.is(.l_paren)) _ = p.skipBalanced(.l_paren, .r_paren) catch {};
        const close = try p.skipBalanced(.l_brace, .r_brace);
        const args = p.source[start..close];
        return p.node(.{ .macro_call_item = .{
            .path = "macro_rules",
            .args = args,
            .brace_args = true,
            .is_item = true,
        } });
    }

    fn parseMacroPath(p: *Parser) ParserError![]const u8 {
        var out: std.ArrayList(u8) = .init(p.allocator);
        errdefer out.deinit();
        out.appendSlice(try p.expectIdent()) catch return error.OutOfMemory;
        while (p.is(.path_separator)) {
            p.advance();
            if (p.is(.colon)) break;
            out.appendSlice("::") catch return error.OutOfMemory;
            out.appendSlice(try p.expectIdent()) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }

    fn finishMacroItem(p: *Parser, path: []const u8) ParserError!*ast.Node {
        var args: []const u8 = "";
        var brace = false;
        if (p.is(.l_paren)) {
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_paren, .r_paren);
            args = p.source[start..close];
        } else if (p.is(.l_bracket)) {
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_bracket, .r_bracket);
            args = p.source[start..close];
        } else if (p.is(.l_brace)) {
            brace = true;
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_brace, .r_brace);
            args = p.source[start..close];
        } else {
            p.last_expected = "(, [ or {";
            p.last_token = p.tok;
            return error.InvalidMacroArgs;
        }
        return p.node(.{ .macro_call_item = .{
            .path = path,
            .args = args,
            .brace_args = brace,
            .is_item = true,
        } });
    }

    // -- fn ----------------------------------------------------------------

    fn parseFnItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        return p.parseFnRest(vis, attrs, .{});
    }

    const FnFlags = struct {
        is_unsafe: bool = false,
        is_async: bool = false,
        is_const: bool = false,
        abi: ?[]const u8 = null,
    };

    fn parseFnRest(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr, flags: FnFlags) ParserError!*ast.Node {
        // Captured before the modifiers, so a `pub const fn` points at the `pub`
        // -- the line a reader would jump to -- rather than at the `fn` keyword.
        const item_pos = p.curPos();
        var is_const = flags.is_const;
        var is_unsafe = flags.is_unsafe;
        var is_async = flags.is_async;
        // `const` / `async` / `unsafe` may appear in any order before `fn`.
        while (true) {
            if (p.eat(.keyword_const)) {
                is_const = true;
                continue;
            }
            if (p.is(.keyword_async) and p.peek() == .keyword_fn) {
                p.advance();
                is_async = true;
                continue;
            }
            if (p.is(.keyword_unsafe) and p.peek() == .keyword_fn) {
                p.advance();
                is_unsafe = true;
                continue;
            }
            if (p.is(.keyword_extern) and (p.peek() == .string_literal or p.peek() == .keyword_fn)) {
                p.advance();
                if (p.is(.string_literal)) {
                    const abi = p.text();
                    p.advance();
                    return p.parseFnRest(vis, attrs, .{
                        .is_unsafe = is_unsafe,
                        .is_async = is_async,
                        .is_const = is_const,
                        .abi = abi[1 .. abi.len - 1],
                    });
                }
                return p.parseFnRest(vis, attrs, .{
                    .is_unsafe = is_unsafe,
                    .is_async = is_async,
                    .is_const = is_const,
                    .abi = "C",
                });
            }
            break;
        }
        _ = try p.expect(.keyword_fn);

        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();

        _ = try p.expect(.l_paren);
        const params = try p.parseParamList();
        _ = try p.expect(.r_paren);

        var ret: ?*ast.Node = null;
        if (p.eat(.thin_arrow)) {
            ret = try p.parseType();
        }

        const where_clauses = try p.parseWhereClauses();

        var body: ?*ast.Node = null;
        if (p.is(.l_brace)) {
            if (p.options.parse_function_bodies) {
                body = try p.parseBlock();
            } else {
                _ = try p.skipBalanced(.l_brace, .r_brace);
            }
        } else {
            _ = try p.expect(.semicolon);
        }

        return p.node(.{ .fn_item = .{
            .name = name,
            .generics = generics,
            .params = params,
            .ret = ret,
            .body = body,
            .vis = vis,
            .is_unsafe = is_unsafe,
            .is_const = is_const,
            .is_async = is_async,
            .abi = flags.abi,
            .attrs = attrs,
            .pos = item_pos,
            .where_clauses = where_clauses,
        } });
    }

    fn parseParamList(p: *Parser) ParserError![]const ast.Param {
        var out: std.ArrayList(ast.Param) = .init(p.allocator);
        errdefer out.deinit();
        while (!p.is(.r_paren) and !p.is(.eof)) {
            const attrs = try p.parseOuterAttrs();

            // `self`, `&self`, `&mut self`, `mut self`, `self: Type`
            if (try p.tryParseSelfParam(attrs)) |param| {
                try out.append(param);
            } else {
                const pat = try p.parsePatternNoAlt();
                var ty: ?*ast.Node = null;
                if (p.eat(.colon)) ty = try p.parseType();
                if (p.is(.dot_dot_dot)) {
                    p.advance();
                    // C-variadic `...`
                    try out.append(.{ .pat = pat, .ty = ty, .attrs = attrs });
                    break;
                }
                try out.append(.{ .pat = pat, .ty = ty, .attrs = attrs });
            }
            if (!p.eat(.comma)) break;
        }
        return out.toOwnedSlice();
    }

    fn tryParseSelfParam(p: *Parser, attrs: []const ast.Attr) ParserError!?ast.Param {
        var is_ref = false;
        var is_mut = false;
        const save_tok = p.tok;
        const save_lex = p.lex;
        const save_peeked = p.peeked;

        if (p.eat(.ampersand)) {
            is_ref = true;
            if (p.is(.lifetime)) p.advance();
            is_mut = p.eat(.keyword_mut);
        } else if (p.is(.keyword_mut)) {
            p.advance();
            is_mut = true;
        }

        if (p.is(.keyword_self)) {
            p.advance();
            const self_pat = try makeIdentPat(p, "self", false, is_mut, null);
            const kind: ast.SelfKind = if (is_ref)
                (if (is_mut) .by_ref_mut else .by_ref)
            else
                (if (is_mut) .boxed else .by_value);
            return ast.Param{ .pat = self_pat, .ty = null, .is_self = true, .self_kind = kind, .attrs = attrs };
        }

        // Restore: the `&`/`mut` did not belong to a self parameter.
        p.tok = save_tok;
        p.lex = save_lex;
        p.peeked = save_peeked;
        return null;
    }

    // -- generics ----------------------------------------------------------

    fn parseGenerics(p: *Parser) ParserError!ast.Generics {
        _ = try p.expect(.less);
        var params: std.ArrayList(ast.GenericParam) = .init(p.allocator);
        errdefer params.deinit();

        while (!p.atGenericClose()) {
            if (p.is(.eof)) {
                p.last_expected = ">";
                return error.UnexpectedToken;
            }
            if (p.is(.lifetime)) {
                // `'a` is a single token; the name is the text after the quote.
                const name = p.text()[1..];
                p.advance();
                var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
                if (p.eat(.colon)) {
                    while (true) {
                        try bounds.append(try p.parseTraitBoundNode());
                        if (!p.eat(.plus)) break;
                    }
                }
                try params.append(.{
                    .name = name,
                    .kind = .lifetime,
                    .bounds = try bounds.toOwnedSlice(),
                });
            } else if (p.eat(.keyword_const)) {
                const name = try p.expectIdent();
                _ = try p.expect(.colon);
                _ = try p.parseType();
                var def: ?*ast.Node = null;
                if (p.eat(.equal)) def = try p.parseType();
                try params.append(.{ .name = name, .kind = .const_param, .default = def });
            } else {
                const name = try p.expectIdent();
                var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
                if (p.eat(.colon)) {
                    while (true) {
                        try bounds.append(try p.parseTraitBoundNode());
                        if (!p.eat(.plus)) break;
                    }
                }
                var def: ?*ast.Node = null;
                if (p.eat(.equal)) def = try p.parseType();
                try params.append(.{
                    .name = name,
                    .kind = .type_param,
                    .default = def,
                    .bounds = try bounds.toOwnedSlice(),
                });
            }
            if (!p.eat(.comma)) break;
        }
        try p.expectGenericClose();
        return .{ .params = try params.toOwnedSlice() };
    }

    fn atGenericClose(p: *Parser) bool {
        return switch (p.cur()) {
            .greater, .greater_greater, .greater_greater_equal => true,
            else => false,
        };
    }

    /// Close one generic level, splitting `>>` / `>=` / `>>=` in place.
    fn expectGenericClose(p: *Parser) ParserError!void {
        switch (p.cur()) {
            .greater => p.advance(),
            .greater_greater, .greater_greater_equal => {
                // Split in place: leave the trailing `>` (or `>=`) for the
                // enclosing level. Both the tag and the lexer position must be
                // rewritten, otherwise the next `advance()` re-reads `>>`.
                const was_eq = p.tok.tag == .greater_greater_equal;
                p.tok.tag = if (was_eq) .greater_equal else .greater;
                p.tok.loc.start += 1;
                p.lex.index = p.tok.loc.start + 1;
                p.peeked = null;
            },
            else => {
                p.last_expected = ">";
                p.last_token = p.tok;
                return error.UnexpectedToken;
            },
        }
    }

    fn parseTraitBoundNode(p: *Parser) ParserError!*ast.Node {
        if (p.eat(.question)) {
            return p.node(.{ .ty_never = .{} });
        }
        if (p.eat(.keyword_for)) {
            // Higher-ranked bound `for<'a> Fn(..)`: skip the binder list.
            _ = try p.expect(.less);
            while (!p.atGenericClose() and !p.is(.eof)) p.advance();
            try p.expectGenericClose();
        }
        if (p.is(.lifetime)) p.advance();
        if (p.eat(.keyword_dyn)) {
            var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
            try bounds.append(try p.parseTraitBoundNode());
            while (p.eat(.plus)) {
                try bounds.append(try p.parseTraitBoundNode());
            }
            return p.node(.{ .ty_dyn_trait = .{ .bounds = try bounds.toOwnedSlice() } });
        }
        const ty = try p.parseTypePathOnly();
        // `Fn(A, B) -> C`
        if (p.is(.l_paren)) {
            p.advance();
            var params: std.ArrayList(*ast.Node) = .init(p.allocator);
            while (!p.is(.r_paren) and !p.is(.eof)) {
                try params.append(try p.parseType());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_paren);
            var ret: ?*ast.Node = null;
            if (p.eat(.thin_arrow)) ret = try p.parseType();
            return p.node(.{ .ty_fn_ptr = .{
                .params = try params.toOwnedSlice(),
                .ret = ret,
            } });
        }
        return ty;
    }

    fn parseWhereClauses(p: *Parser) ParserError![]const ast.WhereClause {
        if (!p.is(.keyword_where)) return &.{};
        p.advance();
        var clauses: std.ArrayList(ast.WhereClause) = .init(p.allocator);
        while (true) {
            var preds: std.ArrayList(ast.WherePredicate) = .init(p.allocator);
            if (p.eat(.keyword_for)) {
                _ = try p.expect(.less);
                while (!p.atGenericClose() and !p.is(.eof)) p.advance();
                try p.expectGenericClose();
            }
            const lhs = try p.parseType();
            _ = try p.expect(.colon);
            var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
            while (true) {
                try bounds.append(try p.parseTraitBoundNode());
                if (!p.eat(.plus)) break;
            }
            try preds.append(.{ .ty = lhs, .bounds = try bounds.toOwnedSlice() });
            try clauses.append(.{ .predicates = try preds.toOwnedSlice() });
            if (!p.eat(.comma)) break;
            if (p.is(.l_brace) or p.is(.semicolon) or p.is(.equal)) break;
        }
        return clauses.toOwnedSlice();
    }

    // -- struct / enum / union --------------------------------------------

    fn parseStructItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_struct);
        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        const where_clauses = try p.parseWhereClauses();

        if (p.eat(.semicolon)) {
            return p.node(.{ .struct_item = .{
                .name = name,
                .generics = generics,
                .is_unit = true,
                .vis = vis,
                .attrs = attrs,
                .where_clauses = where_clauses,
            } });
        }

        if (p.is(.l_paren)) {
            p.advance();
            const fields = try p.parseTupleFields();
            _ = try p.expect(.r_paren);
            const w2 = try p.parseWhereClauses();
            _ = try p.expect(.semicolon);
            return p.node(.{ .struct_item = .{
                .name = name,
                .generics = generics,
                .fields = fields,
                .is_tuple = true,
                .vis = vis,
                .attrs = attrs,
                .where_clauses = w2,
            } });
        }

        _ = try p.expect(.l_brace);
        const fields = try p.parseNamedFields();
        _ = try p.expect(.r_brace);
        return p.node(.{ .struct_item = .{
            .name = name,
            .generics = generics,
            .fields = fields,
            .vis = vis,
            .attrs = attrs,
            .where_clauses = where_clauses,
        } });
    }

    fn parseUnionItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_union);
        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        _ = try p.parseWhereClauses();
        var fields: []const ast.FieldDef = &.{};
        if (p.is(.l_brace)) {
            p.advance();
            fields = try p.parseNamedFields();
            _ = try p.expect(.r_brace);
        } else {
            _ = try p.expect(.semicolon);
        }
        return p.node(.{ .union_item = .{
            .name = name,
            .generics = generics,
            .fields = fields,
            .vis = vis,
            .attrs = attrs,
        } });
    }

    fn parseNamedFields(p: *Parser) ParserError![]const ast.FieldDef {
        var out: std.ArrayList(ast.FieldDef) = .init(p.allocator);
        errdefer out.deinit();
        while (!p.is(.r_brace) and !p.is(.eof)) {
            const attrs = try p.parseOuterAttrs();
            const vis = try p.parseVis();
            const name = try p.expectIdent();
            _ = try p.expect(.colon);
            const ty = try p.parseType();
            try out.append(.{ .name = name, .ty = ty, .vis = vis, .attrs = attrs });
            if (!p.eat(.comma)) break;
        }
        return out.toOwnedSlice();
    }

    fn parseTupleFields(p: *Parser) ParserError![]const ast.FieldDef {
        var out: std.ArrayList(ast.FieldDef) = .init(p.allocator);
        errdefer out.deinit();
        while (!p.is(.r_paren) and !p.is(.eof)) {
            const attrs = try p.parseOuterAttrs();
            const vis = try p.parseVis();
            const ty = try p.parseType();
            try out.append(.{
                .name = try std.fmt.allocPrint(p.allocator, "{d}", .{out.items.len}),
                .ty = ty,
                .vis = vis,
                .attrs = attrs,
            });
            if (!p.eat(.comma)) break;
        }
        return out.toOwnedSlice();
    }

    fn parseEnumItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_enum);
        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        const where_clauses = try p.parseWhereClauses();
        _ = try p.expect(.l_brace);

        var variants: std.ArrayList(ast.Variant) = .init(p.allocator);
        errdefer variants.deinit();
        while (!p.is(.r_brace) and !p.is(.eof)) {
            const vattrs = try p.parseOuterAttrs();
            const vname = try p.expectIdent();
            var kind: ast.Variant.VariantKind = .unit;
            if (p.is(.l_paren)) {
                p.advance();
                kind = .{ .tuple = try p.parseTupleFields() };
                _ = try p.expect(.r_paren);
            } else if (p.is(.l_brace)) {
                p.advance();
                kind = .{ .fields = try p.parseNamedFields() };
                _ = try p.expect(.r_brace);
            }
            var disc: ?*ast.Node = null;
            if (p.eat(.equal)) disc = try p.parseExpr();
            try variants.append(.{ .name = vname, .kind = kind, .attrs = vattrs, .discriminant = disc });
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_brace);
        return p.node(.{ .enum_item = .{
            .name = name,
            .generics = generics,
            .variants = try variants.toOwnedSlice(),
            .vis = vis,
            .attrs = attrs,
            .where_clauses = where_clauses,
        } });
    }

    // -- trait / impl -------------------------------------------------------

    fn parseTraitItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_trait);
        return p.parseTraitRest(vis, attrs);
    }

    fn parseTraitItemAfterUnsafe(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        return p.parseTraitRest(vis, attrs);
    }

    fn parseTraitRest(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        var supertraits: std.ArrayList(*ast.Node) = .init(p.allocator);
        if (p.eat(.colon)) {
            while (true) {
                try supertraits.append(try p.parseTraitBoundNode());
                if (!p.eat(.plus)) break;
            }
        }
        const where_clauses = try p.parseWhereClauses();
        _ = try p.expect(.l_brace);
        const items = try p.parseAssocItems();
        _ = try p.expect(.r_brace);
        return p.node(.{ .trait_item = .{
            .name = name,
            .generics = generics,
            .items = items,
            .supertraits = try supertraits.toOwnedSlice(),
            .vis = vis,
            .attrs = attrs,
            .where_clauses = where_clauses,
        } });
    }

    /// Parse `impl` blocks: `impl T`, `impl Trait for T`, `impl<T> ... for T`.
    fn parseImplItem(p: *Parser, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_impl);
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        // `impl !Send for T {}` — a negative impl; the trait is negated and has
        // no body, but its shape is still useful to the trait solver.
        if (p.eat(.bang)) {
            const negated = try p.parseType();
            _ = try p.expect(.keyword_for);
            const self_ty = try p.parseType();
            _ = try p.parseWhereClauses();
            _ = try p.expect(.l_brace);
            const items = try p.parseAssocItems();
            _ = try p.expect(.r_brace);
            return p.node(.{ .impl_item = .{
                .generics = generics,
                .self_ty = self_ty,
                .trait_path = negated,
                .items = items,
                .attrs = attrs,
                .is_trait_impl = true,
            } });
        }

        // Parse the first type, then decide whether it is the trait or the self type.
        const first = try p.parseType();
        if (p.is(.keyword_for) and p.peek() != .l_brace) {
            p.advance();
            const self_ty = try p.parseType();
            const where_clauses = try p.parseWhereClauses();
            _ = try p.expect(.l_brace);
            const items = try p.parseAssocItems();
            _ = try p.expect(.r_brace);
            return p.node(.{ .impl_item = .{
                .generics = generics,
                .self_ty = self_ty,
                .trait_path = first,
                .items = items,
                .attrs = attrs,
                .where_clauses = where_clauses,
                .is_trait_impl = true,
            } });
        }
        const where_clauses = try p.parseWhereClauses();
        _ = try p.expect(.l_brace);
        const items = try p.parseAssocItems();
        _ = try p.expect(.r_brace);
        return p.node(.{ .impl_item = .{
            .generics = generics,
            .self_ty = first,
            .trait_path = null,
            .items = items,
            .attrs = attrs,
            .where_clauses = where_clauses,
        } });
    }

    /// Items inside `impl` / `trait` bodies: fns, consts, types only.
    fn parseAssocItems(p: *Parser) ParserError![]const *ast.Node {
        var out: std.ArrayList(*ast.Node) = .init(p.allocator);
        errdefer out.deinit();
        while (!p.is(.r_brace) and !p.is(.eof)) {
            const attrs = try p.parseOuterAttrs();
            const vis = try p.parseVis();
            switch (p.cur()) {
                .keyword_fn, .keyword_const, .keyword_type, .keyword_unsafe,
                .keyword_async, .keyword_extern, .identifier, .raw_identifier,
                .keyword_union, .keyword_raw, .keyword_default,
                => {
                    const item = try p.parseAssocItem(vis, attrs);
                    try out.append(item);
                },
                .keyword_macro_rules => {
                    const item = try p.parseMacroItem();
                    try out.append(item.?);
                },
                else => {
                    // A macro invocation such as `type!(..)` inside an impl.
                    if (p.isMacroCallAhead()) {
                        const item = try p.parseMacroItem();
                        try out.append(item.?);
                        continue;
                    }
                    p.last_expected = "an associated item";
                    return error.UnexpectedToken;
                },
            }
        }
        return out.toOwnedSlice();
    }

    fn parseAssocItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        if (p.is(.keyword_default) and p.peek() == .keyword_fn) {
            p.advance();
            return p.parseFnItem(vis, attrs);
        }
        if (p.is(.keyword_const) and p.peek() == .underscore) {
            // `const _: T = ..;` in array repeat expressions.
            p.advance();
            p.advance();
            const ty = try p.parseType();
            _ = try p.expect(.equal);
            const value = try p.parseExpr();
            _ = try p.expect(.semicolon);
            return p.node(.{ .const_item = .{ .name = "_", .ty = ty, .value = value, .vis = vis } });
        }
        _ = p.eat(.underscore);
        switch (p.cur()) {
            .keyword_type => return p.parseTypeAlias(vis, attrs),
            .keyword_const => return p.parseConstItem(vis, attrs),
            .keyword_fn, .keyword_unsafe, .keyword_async, .keyword_extern => {
                return p.parseFnItem(vis, attrs);
            },
            else => {
                p.last_expected = "an associated item";
                return error.UnexpectedToken;
            },
        }
    }

    // -- mod / use ----------------------------------------------------------

    fn parseModItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_mod);
        const name = try p.expectIdent();
        if (p.eat(.semicolon)) {
            return p.node(.{ .mod_item = .{ .name = name, .vis = vis, .attrs = attrs } });
        }
        _ = try p.expect(.l_brace);
        if (p.is(.keyword_inline)) {
            p.advance();
            if (p.eat(.keyword_mod)) _ = try p.expect(.keyword_mod);
        }
        var items: std.ArrayList(*ast.Node) = .init(p.allocator);
        errdefer items.deinit();
        while (!p.is(.r_brace) and !p.is(.eof)) {
            const before = p.lex.index;
            if (try p.parseItem()) |it| try items.append(it);
            if (p.lex.index == before) {
                p.last_expected = "an item";
                p.last_token = p.tok;
                return error.UnexpectedToken;
            }
        }
        _ = try p.expect(.r_brace);
        return p.node(.{ .mod_item = .{
            .name = name,
            .items = try items.toOwnedSlice(),
            .vis = vis,
            .attrs = attrs,
        } });
    }

    fn parseUseItem(p: *Parser, vis: ast.Vis) ParserError!*ast.Node {
        _ = try p.expect(.keyword_use);
        const tree = try p.parseUseTree();
        _ = try p.expect(.semicolon);
        return p.node(.{ .use_item = .{ .tree = tree, .vis = vis } });
    }

    fn parseUseTree(p: *Parser) ParserError!ast.UseTree {
        var prefix: std.ArrayList([]const u8) = .init(p.allocator);
        errdefer prefix.deinit();

        _ = p.eat(.path_separator);

        if (p.is(.keyword_crate) or p.is(.keyword_self) or p.is(.keyword_super)) {
            try prefix.append(p.text());
            p.advance();
        }

        // Leading `a::b::` segments, stopping before `{` or `*` or `as`.
        while (true) {
            // A `::` here continues a path started by `self::`/`crate::`/...
            if (p.is(.path_separator)) {
                p.advance();
                if (p.is(.asterisk) or p.is(.l_brace)) break;
            }
            if (!p.atPathStart()) break;
            const name = try p.expectIdent();
            if (p.is(.path_separator)) {
                if (p.peek() == .l_brace or p.peek() == .asterisk) {
                    // `a::b::{..}` or `a::b::*`
                    try prefix.append(name);
                    p.advance(); // '::'
                    break;
                }
                try prefix.append(name);
                p.advance();
                continue;
            }
            // Leaf identifier.
            var alias: ?[]const u8 = null;
            if (p.is(.keyword_as)) {
                p.advance();
                _ = p.eat(.underscore);
                alias = try p.expectIdent();
            }
            return .{
                .prefix = try prefix.toOwnedSlice(),
                .leaf = name,
                .alias = alias,
            };
        }

        if (p.is(.asterisk)) {
            p.advance();
            return .{ .prefix = try prefix.toOwnedSlice(), .is_glob = true };
        }

        if (p.is(.l_brace)) {
            p.advance();
            var children: std.ArrayList(ast.UseTree) = .init(p.allocator);
            errdefer children.deinit();
            while (!p.is(.r_brace) and !p.is(.eof)) {
                try children.append(try p.parseUseTree());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_brace);
            return .{ .prefix = try prefix.toOwnedSlice(), .children = try children.toOwnedSlice() };
        }

        return .{ .prefix = try prefix.toOwnedSlice() };
    }

    // -- type alias / const / static / extern -------------------------------

    fn parseTypeAlias(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_type);
        const name = try p.expectIdent();
        var generics: ast.Generics = .{};
        if (p.is(.less)) generics = try p.parseGenerics();
        const where_clauses = try p.parseWhereClauses();
        // `type Item<'a>;` declares an associated type with no definition.
        if (p.eat(.semicolon)) {
            return p.node(.{ .type_alias = .{
                .name = name,
                .generics = generics,
                .ty = try p.node(.{ .ty_never = .{} }),
                .vis = vis,
                .attrs = attrs,
                .where_clauses = where_clauses,
            } });
        }
        _ = try p.expect(.equal);
        const ty = try p.parseType();
        _ = try p.expect(.semicolon);
        return p.node(.{ .type_alias = .{
            .name = name,
            .generics = generics,
            .ty = ty,
            .vis = vis,
            .attrs = attrs,
            .where_clauses = where_clauses,
        } });
    }

    fn parseConstItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_const);
        const name = try p.expectIdent();
        var ty: ?*ast.Node = null;
        if (p.eat(.colon)) ty = try p.parseType();
        var value: ?*ast.Node = null;
        if (p.eat(.equal)) value = try p.parseExpr();
        _ = try p.expect(.semicolon);
        return p.node(.{ .const_item = .{
            .name = name,
            .ty = ty,
            .value = value,
            .vis = vis,
            .attrs = attrs,
        } });
    }

    fn parseStaticItem(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        _ = try p.expect(.keyword_static);
        var is_mut = false;
        if (p.eat(.keyword_mut)) is_mut = true;
        const name = try p.expectIdent();
        var ty: ?*ast.Node = null;
        if (p.eat(.colon)) ty = try p.parseType();
        var value: ?*ast.Node = null;
        if (p.eat(.equal)) value = try p.parseExpr();
        _ = try p.expect(.semicolon);
        return p.node(.{ .static_item = .{
            .name = name,
            .ty = ty,
            .value = value,
            .is_mut = is_mut,
            .vis = vis,
            .attrs = attrs,
        } });
    }

    /// Non-consuming lookahead of the token following the current one. Unlike
    /// `peek()` this never fills the peek buffer, so the parser stays usable.
    fn nextAfterIs(p: *Parser, tag: Tag) bool {
        if (p.peeked != null) return false;
        var lex = p.lex;
        return lex.next().tag == tag;
    }

    /// Distinguish `extern "C" { .. }` from `extern "C" fn ..;` by looking at
    /// the token after the ABI string.
    fn isExternBlockAhead(p: *Parser) bool {
        if (p.peeked != null) return false;
        var lex = p.lex;
        const abi = lex.next();
        if (abi.tag != .string_literal) return false;
        return lex.next().tag == .l_brace;
    }

    fn parseExternOrCrate(p: *Parser, vis: ast.Vis, attrs: []const ast.Attr) ParserError!*ast.Node {
        if (p.is(.keyword_extern) and p.nextAfterIs(.keyword_crate)) {
            p.advance();
            p.advance();
            const name = try p.expectIdent();
            var rename: ?[]const u8 = null;
            if (p.is(.keyword_as)) {
                p.advance();
                _ = p.eat(.underscore);
                rename = try p.expectIdent();
            }
            _ = try p.expect(.semicolon);
            return p.node(.{ .use_item = .{
                .tree = .{ .prefix = try p.allocator.dupe([]const u8, &.{"crate"}), .leaf = name, .alias = rename },
                .vis = vis,
            } });
        }
        if (p.is(.keyword_extern) and p.nextAfterIs(.string_literal) and p.isExternBlockAhead()) {
            p.advance();
            const abi_text = p.text();
            const abi = abi_text[1 .. abi_text.len - 1];
            p.advance();
            if (p.is(.keyword_crate)) p.advance();
            _ = try p.expect(.l_brace);
            var items: std.ArrayList(*ast.Node) = .init(p.allocator);
            errdefer items.deinit();
            while (!p.is(.r_brace) and !p.is(.eof)) {
                const before = p.lex.index;
                if (try p.parseItem()) |it| try items.append(it);
                if (p.lex.index == before) {
                    p.last_expected = "an item";
                    p.last_token = p.tok;
                    return error.UnexpectedToken;
                }
            }
            _ = try p.expect(.r_brace);
            return p.node(.{ .extern_block = .{ .abi = abi, .items = try items.toOwnedSlice() } });
        }
        return p.parseFnItem(vis, attrs);
    }

    // ======================================================================
    // types
    // ======================================================================

    pub fn parseType(p: *Parser) ParserError!*ast.Node {
        return p.parseTypeImpl(true);
    }

    /// Type syntax without binding a `+` trait-bound list.
    fn parseTypePathOnly(p: *Parser) ParserError!*ast.Node {
        p.type_context += 1;
        defer p.type_context -= 1;
        return p.parseTypeImpl(false);
    }

    fn parseTypeImpl(p: *Parser, allow_bounds: bool) ParserError!*ast.Node {
        if (p.eat(.bang)) return p.node(.{ .ty_never = .{} });
        if (p.eat(.underscore)) return p.node(.{ .ty_infer = .{} });

        if (p.eat(.ampersand)) {
            var lifetime: ?[]const u8 = null;
            if (p.is(.lifetime)) {
                lifetime = p.text();
                p.advance();
            }
            const is_mut = p.eat(.keyword_mut);
            const inner = try p.parseTypeImpl(allow_bounds);
            return p.node(.{ .ty_ref = .{ .inner = inner, .lifetime = lifetime, .is_mut = is_mut } });
        }
        if (p.eat(.asterisk)) {
            if (p.is(.keyword_const) or p.is(.keyword_mut)) {
                const is_const = p.is(.keyword_const);
                p.advance();
                const inner = try p.parseTypeImpl(allow_bounds);
                return p.node(.{ .ty_ptr = .{ .inner = inner, .is_mut = !is_const, .is_const = is_const } });
            }
            const inner = try p.parseTypeImpl(allow_bounds);
            return p.node(.{ .ty_ptr = .{ .inner = inner, .is_mut = true } });
        }
        if (p.is(.keyword_dyn)) {
            p.advance();
            var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
            if (!p.is(.l_brace) and !p.is(.semicolon) and !p.is(.comma) and !p.is(.r_paren)) {
                while (true) {
                    try bounds.append(try p.parseTraitBoundNode());
                    if (!p.eat(.plus)) break;
                }
            }
            return p.node(.{ .ty_dyn_trait = .{ .bounds = try bounds.toOwnedSlice() } });
        }
        if (p.is(.keyword_impl) and p.peek() == .keyword_trait) {
            p.advance();
            p.advance();
            var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
            while (true) {
                try bounds.append(try p.parseTraitBoundNode());
                if (!p.eat(.plus)) break;
            }
            return p.node(.{ .ty_impl_trait = .{ .bounds = try bounds.toOwnedSlice() } });
        }
        if (p.is(.keyword_for)) return p.parseTraitBoundNode();

        if (p.is(.l_paren)) {
            p.advance();
            if (p.eat(.r_paren)) {
                return p.node(.{ .ty_tuple = .{ .elems = &.{}, .is_unit = true } });
            }
            const first = try p.parseType();
            if (p.eat(.comma)) {
                var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
                try elems.append(first);
                while (!p.is(.r_paren) and !p.is(.eof)) {
                    try elems.append(try p.parseType());
                    if (!p.eat(.comma)) break;
                }
                _ = try p.expect(.r_paren);
                return p.node(.{ .ty_tuple = .{ .elems = try elems.toOwnedSlice() } });
            }
            _ = try p.expect(.r_paren);
            const wrapped = try p.node(.{ .paren_expr = .{ .inner = first } });
            return p.node(.{ .ty_tuple = .{ .elems = try p.owned(*ast.Node, &.{wrapped}) } });
        }

        if (p.is(.l_bracket)) {
            p.advance();
            const elem = try p.parseType();
            if (p.eat(.semicolon)) {
                const len = try p.parseExpr();
                _ = try p.expect(.r_bracket);
                return p.node(.{ .ty_array = .{ .elem = elem, .len = len } });
            }
            _ = try p.expect(.r_bracket);
            return p.node(.{ .ty_slice = .{ .elem = elem } });
        }

        if (p.is(.keyword_fn) or
            (p.is(.keyword_unsafe) and p.peek() == .keyword_fn) or
            (p.is(.keyword_extern) and (p.peek() == .keyword_fn or p.peek() == .string_literal)))
        {
            var is_unsafe = false;
            var abi: ?[]const u8 = null;
            while (true) {
                if (p.eat(.keyword_unsafe)) {
                    is_unsafe = true;
                    continue;
                }
                if (p.is(.keyword_extern) and p.peek() == .string_literal) {
                    p.advance();
                    const t = p.text();
                    abi = t[1 .. t.len - 1];
                    p.advance();
                    continue;
                }
                break;
            }
            _ = try p.expect(.keyword_fn);
            _ = try p.expect(.l_paren);
            var params: std.ArrayList(*ast.Node) = .init(p.allocator);
            errdefer params.deinit();
            var variadic = false;
            while (!p.is(.r_paren) and !p.is(.eof)) {
                if (p.eat(.dot_dot_dot)) {
                    variadic = true;
                    break;
                }
                // Skip a parameter name and keep the type.
                if (p.atIdent() and p.peek() == .colon) {
                    p.advance();
                    p.advance();
                }
                try params.append(try p.parseType());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_paren);
            var ret: ?*ast.Node = null;
            if (p.eat(.thin_arrow)) ret = try p.parseType();
            return p.node(.{ .ty_fn_ptr = .{
                .params = try params.toOwnedSlice(),
                .ret = ret,
                .is_unsafe = is_unsafe,
                .is_variadic = variadic,
                .abi = abi,
            } });
        }

        if (p.is(.keyword_impl)) {
            p.advance();
            var bounds: std.ArrayList(*ast.Node) = .init(p.allocator);
            while (true) {
                try bounds.append(try p.parseTraitBoundNode());
                if (!p.eat(.plus)) break;
            }
            return p.node(.{ .ty_impl_trait = .{ .bounds = try bounds.toOwnedSlice() } });
        }

        if (p.is(.lifetime)) p.advance();
        if (p.is(.keyword_for)) p.advance();

        // Path type: `a::B::<T>`
        const leading = p.eat(.path_separator);
        p.type_context += 1;
        const segments = try p.parsePathSegments();
        p.type_context -= 1;
        if (segments.len == 0) {
            p.last_expected = "a type";
            p.last_token = p.tok;
            return error.ExpectedType;
        }

        if (allow_bounds and p.is(.plus)) {
            // `dyn`-less bound syntax only appears in trait position; ignore.
            while (p.eat(.plus)) _ = try p.parseTypePathOnly();
        }
        if (allow_bounds and p.is(.keyword_const)) {
            p.advance();
        }

        return p.node(.{ .ty_path = .{ .segments = segments, .leading_colon = leading } });
    }

    /// Parse `a::b::C`, honouring both `<T>` type arguments and `::<T>`
    /// turbofish in either position.
    fn parsePathSegments(p: *Parser) ParserError![]const ast.PathSegment {
        var segs: std.ArrayList(ast.PathSegment) = .init(p.allocator);
        errdefer segs.deinit();
        if (p.eat(.path_separator)) {
            // A leading `::` is handled by the caller; nothing to consume here.
        }
        while (true) {
            // A `::` continues the path with the next segment.
            if (p.is(.path_separator)) {
                p.advance();
                continue;
            }
            // Leading `<T>` with no name in front of it (rare, invalid in Rust
            // expressions but tolerated so diagnostics point at the real error).
            if (p.eat(.less)) {
                const args = try p.parseGenericArgList();
                try segs.append(.{ .name = "_turbofish", .args = args });
                continue;
            }
            const name = try p.expectIdent();
            try segs.append(.{ .name = name });

            // `::<T>` turbofish: a `::` immediately followed by `<`.
            if (p.is(.path_separator) and p.peek() == .less) {
                p.advance();
                const args = try p.parseGenericArgList();
                const last = &segs.items[segs.items.len - 1];
                if (last.args.len == 0) {
                    last.args = args;
                } else {
                    var merged: std.ArrayList(ast.GenericArg) = .init(p.allocator);
                    for (last.args) |e| try merged.append(e);
                    for (args) |e| try merged.append(e);
                    last.args = try merged.toOwnedSlice();
                }
                if (p.is(.path_separator)) continue;
                break;
            }

            // `<T>` type arguments. In expression position a bare `<` after a
            // path is a comparison (`if a < b { .. }`), so only `::<T>` counts.
            if (p.is(.less) and p.type_context > 0) {
                const args = try p.parseGenericArgList();
                segs.items[segs.items.len - 1].args = args;
                if (p.is(.path_separator)) continue;
                break;
            }

            if (!p.is(.path_separator)) break;
            p.advance();
            // A trailing `::` before `{`/`*`/`,` ends the path (use-tree syntax).
            if (p.is(.asterisk) or p.is(.l_brace) or p.is(.comma)) {
                segs.items[segs.items.len - 1].name = "";
                break;
            }
        }
        return segs.toOwnedSlice();
    }

    fn parseGenericArgList(p: *Parser) ParserError![]const ast.GenericArg {
        _ = try p.expect(.less);
        var args: std.ArrayList(ast.GenericArg) = .init(p.allocator);
        errdefer args.deinit();
        while (!p.atGenericClose() and !p.is(.eof)) {
            try args.append(try p.parseGenericArg());
            if (!p.eat(.comma)) break;
        }
        try p.expectGenericClose();
        return args.toOwnedSlice();
    }

    fn parseGenericArg(p: *Parser) ParserError!ast.GenericArg {
        // Associated type binding `Item = T` inside a generic argument list.
        if (p.atName() and p.peek() == .equal) {
            const assoc = try p.expectIdent();
            p.advance(); // '='
            const value = try p.parseType();
            const segs = try p.owned(ast.PathSegment, &.{.{ .name = assoc }});
            const ty = try p.node(.{ .ty_path = .{ .segments = segs } });
            // An associated binding is modelled as a one-bound impl trait whose
            // bound is the concrete type; the lowering resolves it by name.
            _ = ty;
            return .{ .ty = value };
        }
        if (p.is(.lifetime)) {
            // `'a` is one token; reading the text after `eat` would skip it.
            const t = p.text();
            p.advance();
            return .{ .lifetime = t };
        }
        if (p.is(.int_literal) or p.is(.float_literal) or p.is(.char_literal) or
            p.is(.string_literal) or p.is(.keyword_true) or p.is(.keyword_false) or
            p.is(.bang) or p.is(.minus))
        {
            return .{ .const_value = try p.parseExpr() };
        }
        if (p.eat(.underscore)) return .infer;
        if (p.is(.l_brace)) {
            // Const generic block `{ N + 1 }`
            return .{ .const_value = try p.parseBlock() };
        }
        return .{ .ty = try p.parseType() };
    }

    // ======================================================================
    // patterns
    // ======================================================================

    pub fn parsePattern(p: *Parser) ParserError!*ast.Node {
        return p.parsePatternImpl(true);
    }

    /// Patterns below an `|` alternative (used by `while let`, `if let`).
    fn parsePatternNoAlt(p: *Parser) ParserError!*ast.Node {
        return p.parsePatternImpl(false);
    }

    fn parsePatternImpl(p: *Parser, allow_or: bool) ParserError!*ast.Node {
        _ = p.parseOuterAttrs() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };

        if (allow_or) {
            var alts: std.ArrayList(*ast.Node) = .init(p.allocator);
            errdefer alts.deinit();
            try alts.append(try p.parsePatternPrimary());
            while (p.is(.pipe)) {
                p.advance();
                try alts.append(try p.parsePatternPrimary());
            }
            if (alts.items.len == 1) return alts.items[0];
            return p.node(.{ .pat_or = .{ .alts = try alts.toOwnedSlice() } });
        }
        return p.parsePatternPrimary();
    }

    fn parsePatternPrimary(p: *Parser) ParserError!*ast.Node {
        // `box pat`
        if (p.is(.keyword_box)) {
            p.advance();
            return p.node(.{ .pat_box = .{ .pat = try p.parsePatternPrimary() } });
        }
        // `&pat` / `&mut pat`
        if (p.is(.ampersand)) {
            p.advance();
            const is_mut = p.eat(.keyword_mut);
            return p.node(.{ .pat_ref = .{ .pat = try p.parsePatternPrimary(), .is_mut = is_mut } });
        }
        if (p.is(.dot_dot_dot)) {
            p.advance();
            return p.node(.{ .pat_rest = .{} });
        }
        if (p.eat(.underscore)) {
            return p.node(.{ .pat_wild = .{} });
        }
        // `ref` / `ref mut`
        if (p.is(.keyword_ref)) {
            p.advance();
            const is_mut = p.eat(.keyword_mut);
            const name = try p.expectIdent();
            var sub: ?*ast.Node = null;
            if (p.eat(.at)) sub = try p.parsePatternPrimary();
            return p.node(.{ .pat_ident = .{
                .name = name,
                .by_ref = true,
                .is_mut = is_mut,
                .sub = sub,
            } });
        }
        if (p.is(.keyword_mut)) {
            p.advance();
            const name = try p.expectIdent();
            var sub: ?*ast.Node = null;
            if (p.eat(.at)) sub = try p.parsePatternPrimary();
            return p.node(.{ .pat_ident = .{ .name = name, .is_mut = true, .sub = sub } });
        }

        // Literal patterns, possibly the bound of a range pattern.
        switch (p.cur()) {
            .int_literal, .float_literal, .string_literal, .raw_string_literal,
            .byte_literal, .byte_string_literal, .keyword_true, .keyword_false,
            .char_literal,
            => return p.parseLiteralOrRangePattern(),
            .minus => {
                p.advance();
                const inner = try p.parseLiteralOrRangePattern();
                // Switched on the node's tag rather than reaching into
                // `pat_literal` directly: `-2..=-1` parses as a *range*, and
                // reading the literal field of that union was a panic on every
                // negative range endpoint.
                switch (inner.*) {
                    .pat_literal => |pl| switch (pl.literal) {
                        .int => |iv| {
                            const digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{iv.digits});
                            return p.node(.{ .pat_literal = .{ .literal = .{ .int = .{
                                .digits = digits,
                                .base = iv.base,
                                .suffix = iv.suffix,
                            } } } });
                        },
                        .float => |fv| {
                            const digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{fv.digits});
                            return p.node(.{ .pat_literal = .{ .literal = .{ .float = .{
                                .digits = digits,
                                .suffix = fv.suffix,
                            } } } });
                        },
                        else => {},
                    },
                    // The minus belongs to the range's *start*, so the range is
                    // rebuilt around a negated first bound.
                    .pat_range => |pr| {
                        const negated = try p.negatePatLiteral(pr.start);
                        return p.node(.{ .pat_range = .{
                            .start = negated orelse pr.start,
                            .end = pr.end,
                            .inclusive_start = pr.inclusive_start,
                            .inclusive_end = pr.inclusive_end,
                        } });
                    },
                    else => {},
                }
                return inner;
            },
            else => {},
        }

        // Range patterns `1..=5`, `..=5`, `1..`
        if (p.is(.dot_dot) or p.is(.dot_dot_equal)) {
            const inclusive = p.is(.dot_dot_equal);
            p.advance();
            var end: ?*ast.Node = null;
            if (!p.atIdent() and !p.is(.r_brace) and !p.is(.comma) and !p.is(.pipe) and !p.is(.fat_arrow) and !p.is(.r_paren)) {
                end = try p.parseLiteralOrPathAtom();
            }
            return p.node(.{ .pat_range = .{
                .start = null,
                .end = end,
                .inclusive_end = inclusive,
            } });
        }

        // Tuple / paren patterns
        if (p.is(.l_paren)) {
            p.advance();
            if (p.eat(.r_paren)) {
                return p.node(.{ .pat_tuple = .{ .elems = &.{} } });
            }
            var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
            errdefer elems.deinit();
            while (!p.is(.r_paren) and !p.is(.eof)) {
                try elems.append(try p.parsePatternNoAlt());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_paren);
            if (elems.items.len == 1) {
                return p.node(.{ .pat_tuple = .{ .elems = try elems.toOwnedSlice() } });
            }
            return p.node(.{ .pat_tuple = .{ .elems = try elems.toOwnedSlice() } });
        }

        // Slice patterns `[a, b, .., c]`
        if (p.is(.l_bracket)) {
            p.advance();
            var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
            errdefer elems.deinit();
            var rest_at: ?usize = null;
            while (!p.is(.r_bracket) and !p.is(.eof)) {
                if (p.is(.dot_dot)) {
                    p.advance();
                    rest_at = elems.items.len;
                    // `..name` binds the remaining tail as one subslice. No
                    // lookahead is needed: a name after `..` is always a binding.
                    if (p.atName()) {
                        const tail = try p.expectIdent();
                        try elems.append(try makeIdentPat(p, tail, false, false, null));
                    } else if (!p.eat(.comma)) {
                        break;
                    }
                    continue;
                }
                try elems.append(try p.parsePatternNoAlt());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.r_bracket);
            return p.node(.{ .pat_slice = .{
                .elems = try elems.toOwnedSlice(),
                .rest_at = rest_at,
            } });
        }

        // `Path { .. }` struct pattern vs `Path(..)` tuple-struct pattern
        if (p.atName() or p.is(.colon) or p.is(.path_separator)) {
            const leading = p.eat(.path_separator);
            const segments = try p.parsePathSegments();

            if (p.is(.l_paren)) {
                p.advance();
                var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
                errdefer elems.deinit();
                while (!p.is(.r_paren) and !p.is(.eof)) {
                    try elems.append(try p.parsePatternNoAlt());
                    if (!p.eat(.comma)) break;
                }
                _ = try p.expect(.r_paren);
                return p.node(.{ .pat_tuple_struct = .{
                    .path = segments,
                    .elems = try elems.toOwnedSlice(),
                    .leading_colon = leading,
                } });
            }
            if (p.is(.l_brace)) {
                p.advance();
                var fields: std.ArrayList(ast.PatField) = .init(p.allocator);
                errdefer fields.deinit();
                var has_rest = false;
                while (!p.is(.r_brace) and !p.is(.eof)) {
                    if (p.is(.dot_dot)) {
                        p.advance();
                        has_rest = true;
                        _ = p.eat(.comma);
                        continue;
                    }
                    if (p.is(.int_literal)) {
                        // Tuple-struct pattern with numeric field names.
                        const idx_text = p.text();
                        p.advance();
                        var sub: ?*ast.Node = null;
                        if (p.eat(.colon)) sub = try p.parsePatternNoAlt();
                        try fields.append(.{ .name = idx_text, .pat = sub });
                        if (!p.eat(.comma)) break;
                        continue;
                    }
                    const fname = try p.expectIdent();
                    var sub: ?*ast.Node = null;
                    if (p.eat(.colon)) {
                        sub = try p.parsePatternNoAlt();
                    } else {
                        sub = try makeIdentPat(p, fname, false, false, null);
                    }
                    try fields.append(.{ .name = fname, .pat = sub });
                    if (!p.eat(.comma)) break;
                }
                _ = try p.expect(.r_brace);
                return p.node(.{ .pat_struct = .{
                    .path = segments,
                    .fields = try fields.toOwnedSlice(),
                    .has_rest = has_rest,
                    .leading_colon = leading,
                } });
            }

            // `1..=5` where the lower bound is an identifier/const path.
            if (p.is(.dot_dot) or p.is(.dot_dot_equal)) {
                const inclusive = p.is(.dot_dot_equal);
                p.advance();
                var end: ?*ast.Node = null;
                if (!p.is(.fat_arrow) and !p.is(.comma) and !p.is(.pipe) and !p.is(.r_brace)) {
                    end = try p.parseLiteralOrPathAtom();
                }
                const start_node = try p.node(.{ .pat_path = .{ .segments = segments, .leading_colon = leading } });
                return p.node(.{ .pat_range = .{
                    .start = start_node,
                    .end = end,
                    .inclusive_end = inclusive,
                } });
            }

            // A bare name is a binding, except when it follows the Rust naming
            // convention for a unit variant or unit struct (`None => ..`).
            // Name resolution is not available here, so CamelCase is the signal.
            if (segments.len == 1 and
                isBindingName(segments[0].name) and
                !looksLikeUnitVariant(segments[0].name) and
                isNameStartOfBinding(p))
            {
                // `whole @ subpattern` and `rest @ ..`
                if (p.eat(.at)) {
                    return makeIdentPat(p, segments[0].name, false, false, try p.parsePatternNoAlt());
                }
                return makeIdentPat(p, segments[0].name, false, false, null);
            }
            return p.node(.{ .pat_path = .{ .segments = segments, .leading_colon = leading } });
        }

        p.last_expected = "a pattern";
        p.last_token = p.tok;
        return error.ExpectedPattern;
    }

    /// Distinguishes `Some(x)` style from a bare binding: a following token that
    /// cannot continue an expression means the identifier is a binding.
    fn isNameStartOfBinding(p: *Parser) bool {
        return switch (p.cur()) {
            .comma, .r_paren, .r_brace, .r_bracket, .fat_arrow, .pipe, .equal,
            .semicolon, .eof, .at, .colon, .keyword_if, .keyword_in => true,
            else => false,
        };
    }

    fn makeIdentPat(
    p: *Parser,
    name: []const u8,
    by_ref: bool,
    is_mut: bool,
    sub: ?*ast.Node,
) ParserError!*ast.Node {
        return p.node(.{ .pat_ident = .{
            .name = name,
            .by_ref = by_ref,
            .is_mut = is_mut,
            .sub = sub,
        } });
    }

    fn isBindingName(name: []const u8) bool {
        if (name.len == 0) return false;
        return lexer.isIdentStart(name[0]);
    }

    /// `None`, `Ok`, `Ordering::Less`-style names start uppercase; Rust's
    /// convention is that locals never do, so this separates bindings from unit
    /// variants without a name-resolution pass.
    fn looksLikeUnitVariant(name: []const u8) bool {
        return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
    }

    /// Literal-or-path atom used as a range bound.
    fn parseLiteralOrPathAtom(p: *Parser) ParserError!*ast.Node {
        // A range's upper bound may be negative (`-2..=-1`), and that minus is a
        // unary operator, not part of the literal token.
        if (p.is(.minus)) {
            p.advance();
            return (try p.negatePatLiteral(try p.parseLiteralOrPathAtom())) orelse unreachable;
        }
        if (p.atName()) {
            const segments = try p.parsePathSegments();
            return p.node(.{ .pat_path = .{ .segments = segments } });
        }
        return p.parseLiteralPattern();
    }

    /// Negate a pattern literal, leaving anything else untouched.
    fn negatePatLiteral(p: *Parser, node_opt: ?*ast.Node) ParserError!?*ast.Node {
        const pat = node_opt orelse return null;
        if (pat.* != .pat_literal) return pat;
        const literal: ast.Literal = switch (pat.pat_literal.literal) {
            .int => |iv| .{ .int = .{
                .digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{iv.digits}),
                .base = iv.base,
                .suffix = iv.suffix,
            } },
            .float => |fv| .{ .float = .{
                .digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{fv.digits}),
                .suffix = fv.suffix,
            } },
            else => return pat,
        };
        return p.node(.{ .pat_literal = .{ .literal = literal } });
    }

    fn parseLiteralPattern(p: *Parser) ParserError!*ast.Node {
        const lit = try p.parseLiteral();
        return p.node(.{ .pat_literal = .{ .literal = lit } });
    }

    /// `1..=5`, `1..`, `'a'..='z'`
    fn parseLiteralOrRangePattern(p: *Parser) ParserError!*ast.Node {
        const start = try p.parseLiteralPattern();
        if (!p.is(.dot_dot) and !p.is(.dot_dot_equal)) return start;
        const inclusive = p.is(.dot_dot_equal);
        p.advance();
        var end: ?*ast.Node = null;
        if (!p.atPatternRangeEnd()) {
            end = try p.parseLiteralOrPathAtom();
        }
        return p.node(.{ .pat_range = .{
            .start = start,
            .end = end,
            // `..=` is inclusive at *both* ends; Rust has no half-open range, so
            // one flag decides both. Leaving the start exclusive made `1..=5`
            // reject 1 itself.
            .inclusive_start = inclusive,
            .inclusive_end = inclusive,
        } });
    }

    /// Tokens that terminate a range-pattern bound.
    fn atPatternRangeEnd(p: *Parser) bool {
        return switch (p.cur()) {
            .fat_arrow, .comma, .pipe, .r_brace, .r_paren, .r_bracket,
            .semicolon, .eof, .keyword_if,
            => true,
            else => false,
        };
    }

    // ======================================================================
    // literals
    // ======================================================================

    fn parseLiteral(p: *Parser) ParserError!ast.Literal {
        const raw = p.text();
        switch (p.cur()) {
            .int_literal => {
                p.advance();
                var digits = raw;
                var base: ast.IntBase = .dec;
                if (raw.len > 1 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
                    base = .hex;
                    digits = raw[2..];
                } else if (raw.len > 1 and raw[0] == '0' and (raw[1] == 'b' or raw[1] == 'B')) {
                    base = .bin;
                    digits = raw[2..];
                } else if (raw.len > 1 and raw[0] == '0' and (raw[1] == 'o' or raw[1] == 'O')) {
                    base = .oct;
                    digits = raw[2..];
                }
                const split = splitNumSuffix(digits);
                // Arena-allocated: the buffer must outlive this scope, so it is
                // deliberately not deinitialised here.
                var clean: std.ArrayList(u8) = .init(p.allocator);
                for (split.digits) |c| {
                    if (c != '_') try clean.append(c);
                }
                return .{ .int = .{ .digits = clean.items, .base = base, .suffix = split.suffix } };
            },
            .float_literal => {
                p.advance();
                const digits = raw;
                const split = splitNumSuffix(digits);
                // Arena-allocated: see the integer branch above.
                var clean: std.ArrayList(u8) = .init(p.allocator);
                for (split.digits) |c| {
                    if (c != '_') try clean.append(c);
                }
                return .{ .float = .{ .digits = clean.items, .suffix = split.suffix } };
            },
            .string_literal => {
                p.advance();
                const bytes = try unescape(p.allocator, raw[1 .. raw.len - 1]);
                return .{ .str = .{ .bytes = bytes } };
            },
            .raw_string_literal => {
                p.advance();
                var start: usize = 0;
                while (start < raw.len and raw[start] != '"') start += 1;
                var end = raw.len;
                while (end > start and raw[end - 1] == '#') end -= 1;
                if (end > start and raw[end - 1] == '"') end -= 1;
                const body = if (start < end) raw[start..end] else "";
                return .{ .str = .{ .bytes = body } };
            },
            .char_literal => {
                p.advance();
                const body = raw[1 .. raw.len - 1];
                return .{ .char_ = try parseCharCodepoint(body) };
            },
            .byte_literal => {
                p.advance();
                const body = raw[2 .. raw.len - 1];
                return .{ .byte = @truncate(try parseCharCodepoint(body)) };
            },
            .byte_string_literal => {
                p.advance();
                return .{ .byte_str = raw[2 .. raw.len - 2] };
            },
            .keyword_true => {
                p.advance();
                return .{ .bool_ = true };
            },
            .keyword_false => {
                p.advance();
                return .{ .bool_ = false };
            },
            else => {
                p.last_expected = "a literal";
                return error.InvalidLiteral;
            },
        }
    }

    /// Split a numeric literal into its digits and its type suffix.
    ///
    /// Only a trailing run of letters/underscores can be a suffix, and it only
    /// counts when it names a Rust numeric type -- so `10` stays `10` instead of
    /// being read as digits `1` plus suffix `0`.
    const NumSplit = struct { digits: []const u8, suffix: []const u8 };

    fn splitNumSuffix(literal: []const u8) NumSplit {
        var start = literal.len;
        while (start > 0) {
            const c = literal[start - 1];
            const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
            if (!is_alpha) break;
            start -= 1;
        }
        if (start == literal.len or start == 0) return .{ .digits = literal, .suffix = "" };
        const candidate = literal[start..];
        if (!lexer.isNumSuffix(candidate)) return .{ .digits = literal, .suffix = "" };
        return .{ .digits = literal[0..start], .suffix = candidate };
    }

    fn parseCharCodepoint(body: []const u8) ParserError!u32 {
        if (body.len == 0) return 0;
        if (body[0] != '\\') return @intCast(body[0]);
        if (body.len < 2) return 0;
        return switch (body[1]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            'x' => blk: {
                var v: u32 = 0;
                var i: usize = 2;
                while (i < body.len and i < 4) : (i += 1) {
                    v = v * 16 + (std.fmt.charToDigit(body[i], 16) catch 0);
                }
                break :blk v;
            },
            'u' => blk: {
                // \u{XXXX}
                var i: usize = 2;
                if (i < body.len and body[i] == '{') i += 1;
                var v: u32 = 0;
                while (i < body.len and body[i] != '}') : (i += 1) {
                    v = v * 16 + (std.fmt.charToDigit(body[i], 16) catch 0);
                }
                break :blk v;
            },
            else => body[1],
        };
    }

    /// Resolve Rust string escapes into raw bytes.
    pub fn unescape(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
        var out: std.ArrayList(u8) = .init(allocator);
        errdefer out.deinit();
        var i: usize = 0;
        while (i < body.len) {
            const c = body[i];
            if (c != '\\') {
                try out.append(c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= body.len) break;
            const e = body[i];
            i += 1;
            switch (e) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '0' => try out.append(0),
                '\\' => try out.append('\\'),
                '\'' => try out.append('\''),
                '"' => try out.append('"'),
                'x' => {
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < 2 and i < body.len) : (k += 1) {
                        v = v * 16 + (std.fmt.charToDigit(body[i], 16) catch 0);
                        i += 1;
                    }
                    try out.append(@truncate(v));
                },
                'u' => {
                    if (i < body.len and body[i] == '{') i += 1;
                    var v: u32 = 0;
                    while (i < body.len and body[i] != '}') : (i += 1) {
                        v = v * 16 + (std.fmt.charToDigit(body[i], 16) catch 0);
                    }
                    if (i < body.len and body[i] == '}') i += 1;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(v), &buf) catch 0;
                    try out.appendSlice(buf[0..n]);
                },
                '\n' => {
                    // Line continuation: swallow leading whitespace.
                    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) i += 1;
                },
                else => try out.append(e),
            }
        }
        return out.toOwnedSlice();
    }

    // ======================================================================
    // statements & blocks
    // ======================================================================

    pub fn parseBlock(p: *Parser) ParserError!*ast.Node {
        return p.parseBlockInner(null, false);
    }

    fn parseBlockInner(p: *Parser, label: ?[]const u8, is_unsafe: bool) ParserError!*ast.Node {
        _ = try p.expect(.l_brace);
        var stmts: std.ArrayList(*ast.Node) = .init(p.allocator);
        errdefer stmts.deinit();
        var value: ?*ast.Node = null;

        while (!p.is(.r_brace) and !p.is(.eof)) {
            // Captured before anything in this statement is consumed: afterwards
            // the cursor has moved past the statement, and every position would
            // point at whatever follows it.
            const stmt_start = p.tok.loc.start;
            if (p.is(.semicolon)) {
                p.advance();
                continue;
            }
            if (p.isItemAhead()) {
                const item = try p.parseItem();
                if (item) |it| {
                    try stmts.append(try p.node(.{ .item_stmt = .{
                        .item = it,
                        .pos = p.srcPos(stmt_start),
                    } }));
                }
                continue;
            }
            if (p.is(.keyword_let)) {
                const let_stmt = try p.parseLetStmt();
                try stmts.append(let_stmt);
                continue;
            }
            if (p.is(.hash) and p.peek() == .l_bracket) {
                // `#[cfg(..)] let x = ..;` or `#[cfg(..)] { .. }`
                _ = try p.parseOuterAttrs();
                continue;
            }
            // A block tail expression is the value when it is not `;`-terminated.
            const stmt_expr = try p.parseExpr();
            if (p.eat(.semicolon)) {
                try stmts.append(try p.node(.{ .expr_stmt = .{
                    .expr = stmt_expr,
                    .has_semi = true,
                    .pos = p.srcPos(stmt_start),
                } }));
                continue;
            }
            // A macro invocation swallows its own `;`, so it is always a
            // statement, never a block's tail value.
            if (p.is(.r_brace) and !(stmt_expr.* == .macro_expr and stmt_expr.macro_expr.has_semi)) {
                value = stmt_expr;
                break;
            }
            try stmts.append(try p.node(.{ .expr_stmt = .{
                .expr = stmt_expr,
                .has_semi = false,
                .pos = p.srcPos(stmt_start),
            } }));
        }
        _ = try p.expect(.r_brace);
        return p.node(.{ .block_expr = .{
            .stmts = try stmts.toOwnedSlice(),
            .value = value,
            .label = label,
            .is_unsafe = is_unsafe,
        } });
    }

    fn parseLetStmt(p: *Parser) ParserError!*ast.Node {
        // Captured before the `let` token is consumed, so it names the statement
        // rather than its first sub-expression.
        const start = p.tok.loc.start;
        _ = try p.expect(.keyword_let);
        const pat = try p.parsePattern();
        var ty: ?*ast.Node = null;
        if (p.eat(.colon)) ty = try p.parseType();
        var init_expr: ?*ast.Node = null;
        if (p.eat(.equal)) init_expr = try p.parseExpr();
        var else_block: ?*ast.Node = null;
        if (p.is(.keyword_else)) {
            p.advance();
            else_block = try p.parseBlock();
        }
        _ = try p.expect(.semicolon);
        return p.node(.{ .let_stmt = .{
            .pat = pat,
            .ty = ty,
            .init = init_expr,
            .else_block = else_block,
            .pos = p.srcPos(start),
        } });
    }

    /// True when the cursor is at an item keyword rather than an expression.
    fn isItemAhead(p: *Parser) bool {
        return switch (p.cur()) {
            .keyword_fn, .keyword_struct, .keyword_enum, .keyword_trait,
            .keyword_impl, .keyword_mod, .keyword_use, .keyword_extern,
            .keyword_static, .keyword_macro_rules,
            => true,
            .keyword_type => p.peek() != .colon,
            .keyword_const => p.peek() != .l_brace,
            .keyword_pub => true,
            .keyword_unsafe => switch (p.peek()) {
                .keyword_fn, .keyword_impl, .keyword_trait, .keyword_mod, .keyword_extern => true,
                else => false,
            },
            .keyword_union => p.peek() == .identifier or p.peek() == .keyword_union,
            else => false,
        };
    }

    // ======================================================================
    // expressions
    // ======================================================================

    pub fn parseExpr(p: *Parser) ParserError!*ast.Node {
        return p.parseAssign();
    }

    fn parseAssign(p: *Parser) ParserError!*ast.Node {
        const lhs = try p.parseRange();

        switch (p.cur()) {
            .equal => {
                p.advance();
                const rhs = try p.parseAssign();
                return p.node(.{ .assign_expr = .{ .lhs = lhs, .rhs = rhs } });
            },
            .plus_equal => return p.finishAssignOp(.add, lhs),
            .minus_equal => return p.finishAssignOp(.sub, lhs),
            .asterisk_equal => return p.finishAssignOp(.mul, lhs),
            .slash_equal => return p.finishAssignOp(.div, lhs),
            .percent_equal => return p.finishAssignOp(.rem, lhs),
            .caret_equal => return p.finishAssignOp(.bit_xor, lhs),
            .ampersand_equal => return p.finishAssignOp(.bit_and, lhs),
            .pipe_equal => return p.finishAssignOp(.bit_or, lhs),
            .less_less_equal => return p.finishAssignOp(.shl, lhs),
            .greater_greater_equal => return p.finishAssignOp(.shr, lhs),
            else => {},
        }
        return lhs;
    }

    fn finishAssignOp(p: *Parser, op: ast.BinaryOp, lhs: *ast.Node) ParserError!*ast.Node {
        p.advance();
        const rhs = try p.parseAssign();
        return p.node(.{ .assign_op_expr = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }

    fn parseRange(p: *Parser) ParserError!*ast.Node {
        // Prefix ranges: `..a`, `..=a`, `..`
        if (p.is(.dot_dot) or p.is(.dot_dot_equal)) {
            const inclusive = p.is(.dot_dot_equal);
            p.advance();
            var end: ?*ast.Node = null;
            if (!p.isRangeOperandEnd()) {
                end = try p.parseBinary(0);
            }
            return p.node(.{ .range_expr = .{
                .start = null,
                .end = end,
                .limits = if (inclusive) .closed else .half_open,
            } });
        }
        const lhs = try p.parseBinary(0);
        if (p.is(.dot_dot) or p.is(.dot_dot_equal)) {
            const inclusive = p.is(.dot_dot_equal);
            p.advance();
            var end: ?*ast.Node = null;
            if (!p.isRangeOperandEnd() and !p.is(.fat_arrow)) {
                end = try p.parseBinary(0);
            }
            return p.node(.{ .range_expr = .{
                .start = lhs,
                .end = end,
                .limits = if (inclusive) .closed else .half_open,
            } });
        }
        return lhs;
    }

    /// Tokens that terminate a range operand without being consumed by it.
    fn isRangeOperandEnd(p: *Parser) bool {
        return switch (p.cur()) {
            .comma, .r_paren, .r_bracket, .r_brace, .semicolon, .l_brace,
            .fat_arrow, .eof, .equal, .keyword_in, .keyword_if, .keyword_while,
            => true,
            else => false,
        };
    }

    const Prec = struct {
        op: ast.BinaryOp,
        level: u8,
        /// `&&`/`||` short-circuit.
        short_circuit: bool = false,
    };

    /// Binary precedence, loosest first. Mirrors the Rust reference table.
    fn binPrec(p: *Parser) ?Prec {
        return switch (p.cur()) {
            .pipe_pipe => Prec{ .op = .bool_or, .level = 1, .short_circuit = true },
            .ampersand_ampersand => Prec{ .op = .bool_and, .level = 2, .short_circuit = true },
            .equal_equal => Prec{ .op = .eq, .level = 3 },
            .bang_equal => Prec{ .op = .ne, .level = 3 },
            .less => Prec{ .op = .lt, .level = 4 },
            .less_equal => Prec{ .op = .le, .level = 4 },
            .greater => Prec{ .op = .gt, .level = 4 },
            .greater_equal => Prec{ .op = .ge, .level = 4 },
            .pipe => Prec{ .op = .bit_or, .level = 5 },
            .caret => Prec{ .op = .bit_xor, .level = 6 },
            .ampersand => Prec{ .op = .bit_and, .level = 7 },
            .less_less => Prec{ .op = .shl, .level = 8 },
            .greater_greater => Prec{ .op = .shr, .level = 8 },
            .plus => Prec{ .op = .add, .level = 9 },
            .minus => Prec{ .op = .sub, .level = 9 },
            .asterisk => Prec{ .op = .mul, .level = 10 },
            .slash => Prec{ .op = .div, .level = 10 },
            .percent => Prec{ .op = .rem, .level = 10 },
            else => null,
        };
    }

    fn parseBinary(p: *Parser, min_level: u8) ParserError!*ast.Node {
        var lhs = try p.parseCast();
        while (true) {
            const prec = p.binPrec() orelse break;
            if (prec.level < min_level) break;
            p.advance();
            const rhs = try p.parseBinary(prec.level + 1);
            lhs = try p.node(.{ .binary_expr = .{ .op = prec.op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseCast(p: *Parser) ParserError!*ast.Node {
        var expr = try p.parseUnary();
        while (p.is(.keyword_as)) {
            p.advance();
            const ty = try p.parseTypeNoFn();
            expr = try p.node(.{ .cast_expr = .{ .expr = expr, .ty = ty } });
        }
        return expr;
    }

    /// `as T` where T must not swallow a `+`/`->`.
    fn parseTypeNoFn(p: *Parser) ParserError!*ast.Node {
        return p.parseTypeImpl(false);
    }

    fn parseUnary(p: *Parser) ParserError!*ast.Node {
        switch (p.cur()) {
            .minus => {
                p.advance();
                const inner = try p.parseUnary();
                // Fold `-<literal>` so `-1` becomes a literal in the AST.
                switch (inner.*) {
                    .literal => |lit| switch (lit) {
                        .int => |iv| {
                            const digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{iv.digits});
                            return p.node(.{ .literal = .{ .int = .{
                                .digits = digits,
                                .base = iv.base,
                                .suffix = iv.suffix,
                            } } });
                        },
                        .float => |fv| {
                            const digits = try std.fmt.allocPrint(p.allocator, "-{s}", .{fv.digits});
                            return p.node(.{ .literal = .{ .float = .{
                                .digits = digits,
                                .suffix = fv.suffix,
                            } } });
                        },
                        else => {},
                    },
                    else => {},
                }
                return p.node(.{ .unary_expr = .{ .op = .neg, .expr = inner } });
            },
            .bang => {
                p.advance();
                const inner = try p.parseUnary();
                return p.node(.{ .unary_expr = .{ .op = .not, .expr = inner } });
            },
            .asterisk => {
                p.advance();
                const inner = try p.parseUnary();
                return p.node(.{ .deref_expr = .{ .inner = inner } });
            },
            .ampersand => {
                p.advance();
                var is_raw = false;
                if (p.is(.keyword_raw)) {
                    p.advance();
                    is_raw = true;
                }
                _ = p.eat(.keyword_mut);
                _ = p.eat(.keyword_const);
                const inner = try p.parseUnary();
                return p.node(.{ .borrow_expr = .{
                    .inner = inner,
                    .is_mut = false,
                    .is_raw = is_raw,
                } });
            },
            .ampersand_ampersand => {
                p.advance();
                if (p.is(.keyword_mut)) p.advance();
                const inner = try p.parseUnary();
                return p.node(.{ .borrow_expr = .{
                    .inner = inner,
                    .is_mut = true,
                    .is_raw = false,
                } });
            },
            else => return p.parsePostfix(),
        }
    }

    fn parsePostfix(p: *Parser) ParserError!*ast.Node {
        var expr = try p.parsePrimary();

        while (true) {
            switch (p.cur()) {
                .dot => {
                    p.advance();
                    if (p.is(.int_literal)) {
                        const idx = std.fmt.parseInt(usize, p.text(), 10) catch 0;
                        p.advance();
                        expr = try p.node(.{ .field_expr = .{
                            .base = expr,
                            .name = "",
                            .index = idx,
                        } });
                        continue;
                    }
                    if (p.is(.keyword_await)) {
                        p.advance();
                        expr = try p.node(.{ .await_expr = .{ .inner = expr } });
                        continue;
                    }
                    const name = try p.expectIdent();
                    // A method call is `recv.m(..)`; generic arguments require
                    // the explicit `::<..>`, so a bare `<` after a field name is
                    // a comparison (`if a.b < c.d`).
                    var turbofish: []const ast.GenericArg = &.{};
                    if (p.is(.path_separator) and p.peek() == .less) {
                        p.advance();
                        turbofish = try p.parseTurbofish();
                    }
                    if (p.is(.l_paren)) {
                        const args = try p.parseCallArgs();
                        expr = try p.node(.{ .method_call_expr = .{
                            .receiver = expr,
                            .method = name,
                            .turbofish = turbofish,
                            .args = args,
                        } });
                        continue;
                    }
                    if (turbofish.len > 0) {
                        // `a.b::<T>` with no call: keep it as a path segment.
                        const segs = try p.owned(ast.PathSegment, &.{
                            .{ .name = name, .args = turbofish },
                        });
                        expr = try p.node(.{ .path_expr = .{ .segments = segs } });
                        continue;
                    }
                    expr = try p.node(.{ .field_expr = .{ .base = expr, .name = name } });
                },
                .question => {
                    p.advance();
                    expr = try p.node(.{ .try_expr = .{ .inner = expr } });
                },
                .l_paren => {
                    const args = try p.parseCallArgs();
                    expr = try p.node(.{ .call_expr = .{ .callee = expr, .args = args } });
                },
                .l_bracket => {
                    p.advance();
                    const index = try p.parseExpr();
                    _ = try p.expect(.r_bracket);
                    expr = try p.node(.{ .index_expr = .{ .base = expr, .index = index } });
                },
                .l_brace => {
                    // `Foo { a: 1 }` is a struct literal only right after a path.
                    if (p.no_struct_literal == 0 and expr.* == .path_expr) {
                        expr = try p.parseStructLiteral(expr);
                        continue;
                    }
                    break;
                },
                else => break,
            }
        }
        return expr;
    }

    /// `<T, U>` turbofish argument list, used after `.` in method calls.
    fn parseTurbofish(p: *Parser) ParserError![]const ast.GenericArg {
        return p.parseGenericArgList();
    }

    fn parseCallArgs(p: *Parser) ParserError![]const ast.CallArg {
        _ = try p.expect(.l_paren);
        var args: std.ArrayList(ast.CallArg) = .init(p.allocator);
        errdefer args.deinit();
        while (!p.is(.r_paren) and !p.is(.eof)) {
            var name: ?[]const u8 = null;
            if (p.atName() and p.peek() == .colon and p.tok.loc.end + 1 < p.source.len) {
                // `f(name: value)` — but not `x ? a: b`; the lookahead below
                // requires the value to start an expression.
                const after = p.peekTokAfterColon();
                if (after != .eof) {
                    name = p.text();
                    p.advance();
                    p.advance();
                }
            }
            try args.append(.{ .name = name, .expr = try p.parseExpr() });
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_paren);
        return args.toOwnedSlice();
    }

    /// Peek the token after an `ident :` pair, without consuming anything.
    fn peekTokAfterColon(p: *Parser) Tag {
        var lex = p.lex;
        const first = lex.next();
        if (first.tag != .colon) return .eof;
        return lex.next().tag;
    }

    fn parsePrimary(p: *Parser) ParserError!*ast.Node {
        switch (p.cur()) {
            .int_literal, .float_literal, .string_literal, .raw_string_literal,
            .char_literal, .byte_literal, .byte_string_literal,
            .keyword_true, .keyword_false,
            => {
                const lit = try p.parseLiteral();
                return p.node(.{ .literal = lit });
            },
            .underscore => {
                p.advance();
                return p.node(.{ .underscore_expr = .{} });
            },
            .keyword_if => return p.parseIfExpr(),
            .keyword_match => return p.parseMatchExpr(),
            .keyword_loop => return p.parseLoopExpr(null),
            .keyword_while => return p.parseWhileExpr(null),
            .keyword_for => return p.parseForExpr(null),
            .keyword_unsafe => {
                p.advance();
                if (p.is(.l_brace)) {
                    return p.parseBlockInner(null, true);
                }
                // `unsafe fn` in expression position (function pointer coercion).
                return p.parsePrimary();
            },
            .keyword_async => {
                p.advance();
                var is_move = false;
                if (p.eat(.keyword_move)) is_move = true;
                if (p.is(.l_brace)) {
                    return p.parseBlockInner(null, false);
                }
                return p.parsePrimary();
            },
            .keyword_const => {
                p.advance();
                if (p.is(.l_brace)) return p.parseBlockInner(null, false);
                return p.parsePrimary();
            },
            .keyword_try => {
                // `try { .. }` is a try block; a bare `try` is an identifier.
                if (p.nextAfterIs(.l_brace)) {
                    p.advance();
                    return p.parseBlockInner(null, false);
                }
                return p.parsePrimary();
            },
            .l_brace => return p.parseBlock(),
            .l_paren => {
                p.advance();
                if (p.eat(.r_paren)) {
                    return p.node(.{ .tuple_expr = .{ .elems = &.{} } });
                }
                const first = try p.parseExpr();
                if (p.eat(.comma)) {
                    var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
                    errdefer elems.deinit();
                    try elems.append(first);
                    while (!p.is(.r_paren) and !p.is(.eof)) {
                        try elems.append(try p.parseExpr());
                        if (!p.eat(.comma)) break;
                    }
                    _ = try p.expect(.r_paren);
                    return p.node(.{ .tuple_expr = .{ .elems = try elems.toOwnedSlice() } });
                }
                _ = try p.expect(.r_paren);
                return p.node(.{ .paren_expr = .{ .inner = first } });
            },
            .l_bracket => return p.parseArrayOrRepeat(),
            .pipe, .pipe_pipe => return p.parseClosureExpr(),
            .keyword_return => {
                p.advance();
                var value: ?*ast.Node = null;
                if (!p.is(.semicolon) and !p.is(.r_brace) and !p.is(.r_paren) and !p.is(.comma) and !p.is(.eof)) {
                    value = try p.parseExpr();
                }
                return p.node(.{ .return_expr = .{ .value = value } });
            },
            .keyword_break => {
                p.advance();
                var label: ?[]const u8 = null;
                if (p.is(.lifetime)) {
                    label = p.text();
                    p.advance();
                }
                var value: ?*ast.Node = null;
                if (!p.is(.semicolon) and !p.is(.r_brace) and !p.is(.r_paren) and !p.is(.comma) and !p.is(.eof)) {
                    value = try p.parseExpr();
                }
                return p.node(.{ .break_expr = .{ .value = value, .label = label } });
            },
            .keyword_continue => {
                p.advance();
                var label: ?[]const u8 = null;
                if (p.is(.lifetime)) {
                    label = p.text();
                    p.advance();
                }
                return p.node(.{ .continue_expr = .{ .label = label } });
            },
            .lifetime => {
                // Labelled block or loop.
                const label_text = p.text();
                p.advance();
                const label = label_text[1..];
                _ = try p.expect(.colon);
                return p.parseLabelledBody(label);
            },
            .keyword_move => {
                p.advance();
                if (p.is(.pipe) or p.is(.pipe_pipe)) return p.parseClosureExprAfterMove(true);
                return p.parsePrimary();
            },
            .dot_dot, .dot_dot_equal => return p.parseRange(),
            .colon => {
                // Leading `::` path expression.
                p.advance();
                const segments = try p.parsePathSegments();
                return p.makePathExpr(segments, true);
            },
            .identifier, .raw_identifier, .keyword_crate, .keyword_self,
            .keyword_Self, .keyword_super,
            => {
                if (p.isMacroCallAhead()) {
                    return p.parseMacroExpr();
                }
                const segments = try p.parsePathSegments();
                return p.makePathExpr(segments, false);
            },
            .keyword_union, .keyword_macro_rules, .keyword_box,
            .keyword_macro, .keyword_yield, .keyword_final, .keyword_override,
            .keyword_priv, .keyword_abstract, .keyword_become, .keyword_do,
            .keyword_typeof, .keyword_virtual, .keyword_unsized,
            .keyword_raw, .keyword_inline, .keyword_default,
            => {
                // Contextual keywords used as function or path names.
                const segments = try p.parsePathSegments();
                return p.makePathExpr(segments, false);
            },
            else => {
                p.last_expected = "an expression";
                p.last_token = p.tok;
                return error.ExpectedExpression;
            },
        }
    }

    /// `Path { field: value, .. }` — the `{` is the current token.
    fn parseStructLiteral(p: *Parser, path_node: *ast.Node) ParserError!*ast.Node {
        const pe = path_node.path_expr;
        _ = try p.expect(.l_brace);
        var fields: std.ArrayList(ast.StructExprField) = .init(p.allocator);
        errdefer fields.deinit();
        var has_rest = false;
        while (!p.is(.r_brace) and !p.is(.eof)) {
            if (p.is(.dot_dot)) {
                p.advance();
                has_rest = true;
                _ = p.eat(.comma);
                continue;
            }
            if (p.is(.int_literal)) {
                // Positional tuple-struct field: `Foo { 0: a }`
                const idx_text = p.text();
                const idx = std.fmt.parseInt(usize, idx_text, 10) catch 0;
                p.advance();
                _ = try p.expect(.colon);
                try fields.append(.{
                    .name = idx_text,
                    .index = idx,
                    .value = try p.parseExpr(),
                });
            } else {
                const name = try p.expectIdent();
                if (p.eat(.colon)) {
                    try fields.append(.{ .name = name, .value = try p.parseExpr() });
                } else {
                    // Shorthand `Foo { x }` means `Foo { x: x }`.
                    const segs = try p.owned(ast.PathSegment, &.{.{ .name = name }});
                    const value = try p.node(.{ .path_expr = .{ .segments = segs } });
                    try fields.append(.{ .name = name, .value = value });
                }
            }
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.r_brace);
        return p.node(.{ .struct_expr = .{
            .path = pe.segments,
            .fields = try fields.toOwnedSlice(),
            .has_rest = has_rest,
            .leading_colon = pe.leading_colon,
        } });
    }

    fn makePathExpr(p: *Parser, segments: []const ast.PathSegment, leading: bool) ParserError!*ast.Node {
        var is_self_type = false;
        if (segments.len == 1) {
            const n = segments[0].name;
            if (std.mem.eql(u8, n, "Self") or std.mem.eql(u8, n, "self")) is_self_type = true;
        }
        return p.node(.{ .path_expr = .{
            .segments = segments,
            .leading_colon = leading,
            .is_self_type = is_self_type,
        } });
    }

    fn parseArrayOrRepeat(p: *Parser) ParserError!*ast.Node {
        _ = try p.expect(.l_bracket);
        if (p.eat(.r_bracket)) {
            return p.node(.{ .array_expr = .{ .elems = &.{} } });
        }
        const first = try p.parseExpr();
        if (p.eat(.semicolon)) {
            const len = try p.parseExpr();
            _ = try p.expect(.r_bracket);
            return p.node(.{ .repeat_expr = .{ .elem = first, .len = len } });
        }
        if (p.eat(.r_bracket)) {
            return p.node(.{ .array_expr = .{ .elems = try p.owned(*ast.Node, &.{first}) } });
        }
        var elems: std.ArrayList(*ast.Node) = .init(p.allocator);
        errdefer elems.deinit();
        try elems.append(first);
        while (p.eat(.comma)) {
            if (p.is(.r_bracket)) break; // trailing comma
            try elems.append(try p.parseExpr());
        }
        _ = try p.expect(.r_bracket);
        return p.node(.{ .array_expr = .{ .elems = try elems.toOwnedSlice() } });
    }

    fn parseLabelledBody(p: *Parser, label: []const u8) ParserError!*ast.Node {
        switch (p.cur()) {
            .keyword_loop => return p.parseLoopExpr(label),
            .keyword_while => return p.parseWhileExpr(label),
            .keyword_for => return p.parseForExpr(label),
            .l_brace => return p.parseBlockInner(label, false),
            else => {
                p.last_expected = "a loop or block after a label";
                return error.UnexpectedToken;
            },
        }
    }

    fn parseIfExpr(p: *Parser) ParserError!*ast.Node {
        _ = try p.expect(.keyword_if);
        var conds: std.ArrayList(ast.IfLet) = .init(p.allocator);
        errdefer conds.deinit();

        // A `{` after the condition opens the body, never a struct literal.
        p.no_struct_literal += 1;
        // First condition (may be `let pat = expr`).
        if (p.is(.keyword_let)) {
            p.advance();
            const pat = try p.parsePatternNoAlt();
            _ = try p.expect(.equal);
            const value = try p.parseBinary(3);
            try conds.append(.{ .pat = pat, .value = value });
        } else {
            const value = try p.parseBinary(3);
            try conds.append(.{ .pat = try makeIdentPat(p, "__if_cond", false, false, null), .value = value });
        }

        // Let-chains: `if let Some(x) = y && cond { .. }`
        while (p.is(.ampersand_ampersand)) {
            p.advance();
            if (p.is(.keyword_let)) {
                p.advance();
                const pat = try p.parsePatternNoAlt();
                _ = try p.expect(.equal);
                const value = try p.parseBinary(3);
                try conds.append(.{ .pat = pat, .value = value });
            } else {
                const value = try p.parseBinary(3);
                try conds.append(.{ .pat = try makeIdentPat(p, "__if_cond", false, false, null), .value = value });
            }
        }

        p.no_struct_literal -= 1;
        const then_block = try p.parseBlock();
        var else_expr: ?*ast.Node = null;
        if (p.eat(.keyword_else)) {
            if (p.is(.keyword_if)) {
                else_expr = try p.parseIfExpr();
            } else {
                else_expr = try p.parseBlock();
            }
        }
        return p.node(.{ .if_expr = .{
            .conds = try conds.toOwnedSlice(),
            .then_block = then_block,
            .else_expr = else_expr,
        } });
    }

    fn parseMatchExpr(p: *Parser) ParserError!*ast.Node {
        _ = try p.expect(.keyword_match);
        // `match x { .. }` must not read `x { .. }` as a struct literal.
        p.no_struct_literal += 1;
        const scrutinee = try p.parseBinary(0);
        p.no_struct_literal -= 1;
        _ = try p.expect(.l_brace);
        var arms: std.ArrayList(ast.MatchArm) = .init(p.allocator);
        errdefer arms.deinit();
        while (!p.is(.r_brace) and !p.is(.eof)) {
            _ = try p.parseOuterAttrs();
            const pat = try p.parsePattern();
            var guard: ?*ast.Node = null;
            if (p.eat(.keyword_if)) guard = try p.parseExpr();
            _ = try p.expect(.fat_arrow);
            const body = try p.parseExpr();
            const has_comma = p.eat(.comma);
            try arms.append(.{ .pat = pat, .guard = guard, .body = body, .has_comma = has_comma });
            if (!has_comma and !p.is(.r_brace)) {
                // A block-bodied arm may omit the comma.
                if (!p.eat(.comma)) continue;
            }
        }
        _ = try p.expect(.r_brace);
        return p.node(.{ .match_expr = .{
            .scrutinee = scrutinee,
            .arms = try arms.toOwnedSlice(),
        } });
    }

    fn parseLoopExpr(p: *Parser, label: ?[]const u8) ParserError!*ast.Node {
        _ = try p.expect(.keyword_loop);
        const body = try p.parseBlock();
        return p.node(.{ .loop_expr = .{ .body = body, .label = label } });
    }

    fn parseWhileExpr(p: *Parser, label: ?[]const u8) ParserError!*ast.Node {
        _ = try p.expect(.keyword_while);
        var cond: *ast.Node = undefined;
        if (p.is(.keyword_let)) {
            p.advance();
            const pat = try p.parsePatternNoAlt();
            _ = try p.expect(.equal);
            p.no_struct_literal += 1;
            const value = try p.parseBinary(0);
            p.no_struct_literal -= 1;
            cond = try p.node(.{ .if_expr = .{
                .conds = try p.owned(ast.IfLet, &.{.{ .pat = pat, .value = value }}),
                .then_block = try p.node(.{ .block_expr = .{
                    .stmts = &.{},
                    .value = try p.node(.{ .literal = .{ .bool_ = true } }),
                } }),
                .else_expr = try p.node(.{ .block_expr = .{
                    .stmts = &.{},
                    .value = try p.node(.{ .literal = .{ .bool_ = false } }),
                } }),
            } });
        } else {
            p.no_struct_literal += 1;
            cond = try p.parseBinary(0);
            p.no_struct_literal -= 1;
        }
        const body = try p.parseBlock();
        return p.node(.{ .while_expr = .{ .cond = cond, .body = body, .label = label } });
    }

    fn parseForExpr(p: *Parser, label: ?[]const u8) ParserError!*ast.Node {
        _ = try p.expect(.keyword_for);
        const pat = try p.parsePatternNoAlt();
        _ = try p.expect(.keyword_in);
        // A full expression, but the following `{` is the body, not a literal.
        p.no_struct_literal += 1;
        const iter = try p.parseExpr();
        p.no_struct_literal -= 1;
        const body = try p.parseBlock();
        return p.node(.{ .for_expr = .{
            .pat = pat,
            .iter = iter,
            .body = body,
            .label = label,
        } });
    }

    // -- closures -----------------------------------------------------------

    fn parseClosureExpr(p: *Parser) ParserError!*ast.Node {
        return p.parseClosureExprAfterMove(false);
    }

    fn parseClosureExprAfterMove(p: *Parser, is_move: bool) ParserError!*ast.Node {
        var params: std.ArrayList(ast.ClosureParam) = .init(p.allocator);
        errdefer params.deinit();

        if (p.eat(.pipe_pipe)) {
            // no params
        } else {
            _ = try p.expect(.pipe);
            while (!p.is(.pipe) and !p.is(.eof)) {
                const pat = try p.parsePatternNoAlt();
                var ty: ?*ast.Node = null;
                if (p.eat(.colon)) ty = try p.parseType();
                try params.append(.{ .pat = pat, .ty = ty });
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.pipe);
        }

        var ret: ?*ast.Node = null;
        var ret_inferred = false;
        if (p.eat(.thin_arrow)) {
            if (p.is(.l_brace)) {
                ret_inferred = true;
            } else {
                ret = try p.parseType();
            }
        }

        // `|x| expr` and `|x| { stmts }` are both legal bodies.
        const body = if (p.is(.l_brace))
            try p.parseBlock()
        else blk: {
            const value = try p.parseExpr();
            break :blk try p.node(.{ .block_expr = .{ .stmts = &.{}, .value = value } });
        };
        return p.node(.{ .closure_expr = .{
            .params = try params.toOwnedSlice(),
            .ret = ret,
            .body = body,
            .is_move = is_move,
            .ret_inferred = ret_inferred,
        } });
    }

    // -- macro expressions --------------------------------------------------

    fn parseMacroExpr(p: *Parser) ParserError!*ast.Node {
        const path = try p.parseMacroPath();
        _ = try p.expect(.bang);
        const m = try p.parseMacroArgsAndSemi();
        return p.node(.{ .macro_expr = .{
            .path = path,
            .args = m.args,
            .brace_args = m.brace,
            .has_semi = m.has_semi,
        } });
    }

    const MacroArgs = struct {
        args: []const u8,
        brace: bool,
        has_semi: bool,
    };

    fn parseMacroArgsAndSemi(p: *Parser) ParserError!MacroArgs {
        var args: []const u8 = "";
        var brace = false;
        // `skipBalanced` reports the offset of the *closing* delimiter, so the
        // captured text is exactly the argument body -- capturing up to the next
        // token would swallow the `)`, the `;` and any trailing whitespace.
        if (p.is(.l_paren)) {
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_paren, .r_paren);
            args = p.source[start..close];
        } else if (p.is(.l_bracket)) {
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_bracket, .r_bracket);
            args = p.source[start..close];
        } else if (p.is(.l_brace)) {
            brace = true;
            const start = p.tok.loc.end;
            const close = try p.skipBalanced(.l_brace, .r_brace);
            args = p.source[start..close];
        } else {
            p.last_expected = "(, [ or {";
            p.last_token = p.tok;
            return error.InvalidMacroArgs;
        }
        // Look at, but do not consume, the `;`: the enclosing `let`/block
        // statement owns it and still expects to see it.
        const has_semi = p.is(.semicolon);
        return .{ .args = args, .brace = brace, .has_semi = has_semi };
    }
};

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

/// Owns the arena that backs a parsed program, so the AST stays valid for the
/// lifetime of the fixture.
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    prog: *ast.Node,

    fn init(backing: std.mem.Allocator, src: []const u8) ParserError!Fixture {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        var p = Parser.init(arena.allocator(), src);
        const prog = try p.parseProgram();
        return .{ .arena = arena, .prog = prog };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};

fn parseFixture(backing: std.mem.Allocator, src: []const u8) ParserError!Fixture {
    return Fixture.init(backing, src);
}

test "parses hello world" {
    const src =
        \\fn main() {
        \\    let x = 1;
        \\    println!("{}", x);
        \\}
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.prog.program.items.len);
    try testing.expect(fx.prog.program.items[0].* == .fn_item);
    try testing.expectEqualStrings("main", fx.prog.program.items[0].fn_item.name);
}

test "parses nested generics" {
    const src = "fn f(v: Vec<Vec<u8>>) {}";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const f = fx.prog.program.items[0].fn_item;
    try testing.expectEqual(@as(usize, 1), f.params.len);
    const ty = f.params[0].ty.?;
    try testing.expectEqualStrings("Vec", ast.typeName(ty).?);
    const inner = ty.ty_path.segments[0].args[0].ty;
    try testing.expectEqualStrings("Vec", ast.typeName(inner).?);
}

test "parses turbofish" {
    const src = "fn main() { let v = Vec::<i32>::new(); }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const body = fx.prog.program.items[0].fn_item.body.?;
    const let_stmt = body.block_expr.stmts[0].let_stmt;
    const call = let_stmt.init.?;
    // `Vec::<i32>::new` is a call whose callee path carries the turbofish args.
    try testing.expect(call.* == .call_expr);
    const segs = call.call_expr.callee.path_expr.segments;
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqualStrings("Vec", segs[0].name);
    try testing.expectEqualStrings("i32", segs[0].args[0].ty.ty_path.segments[0].name);
    try testing.expectEqualStrings("new", segs[1].name);
}

test "parses struct enum and impl" {
    const src =
        \\pub struct Point { pub x: i32, y: f64 }
        \\enum Color { Red, Green, Blue(i32) }
        \\impl Point {
        \\    pub fn new(x: i32) -> Point { Point { x, y: 0.0 } }
        \\}
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 3), fx.prog.program.items.len);
    try testing.expect(fx.prog.program.items[0].* == .struct_item);
    try testing.expectEqualStrings("x", fx.prog.program.items[0].struct_item.fields[0].name);
    try testing.expect(fx.prog.program.items[1].* == .enum_item);
    try testing.expectEqual(@as(usize, 3), fx.prog.program.items[1].enum_item.variants.len);
    try testing.expect(fx.prog.program.items[2].* == .impl_item);
}

test "parses self parameters" {
    const cases = [_]struct { src: []const u8, kind: ast.SelfKind }{
        .{ .src = "fn a(self) {}", .kind = .by_value },
        .{ .src = "fn a(&self) {}", .kind = .by_ref },
        .{ .src = "fn a(&mut self) {}", .kind = .by_ref_mut },
    };
    for (cases) |c| {
        var fx = try parseFixture(testing.allocator, c.src);
        defer fx.deinit();
        const f = fx.prog.program.items[0].fn_item;
        try testing.expectEqual(c.kind, f.params[0].self_kind);
        try testing.expect(f.params[0].is_self);
    }
}

test "parses binary precedence" {
    const src = "fn main() { let x = 1 + 2 * 3; }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const e = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts[0].let_stmt.init.?;
    // 1 + (2 * 3)
    try testing.expectEqual(ast.BinaryOp.add, e.binary_expr.op);
    try testing.expectEqual(ast.BinaryOp.mul, e.binary_expr.rhs.binary_expr.op);
}

test "parses range and slice and index" {
    const cases = [_][]const u8{
        "fn main() { let r = 0..10; }",
        "fn main() { let r = ..=10; }",
        "fn main() { let r = 0..=10; }",
        "fn main() { let a = [1, 2, 3]; }",
        "fn main() { let s = &a[1..2]; }",
        "fn main() { let v = a[i]; }",
        "fn main() { let r = [0; 8]; }",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        try testing.expect(fx.prog.program.items[0].* == .fn_item);
    }
}

test "parses match arms" {
    const src =
        \\fn f(x: Option<i32>) -> i32 {
        \\    match x {
        \\        Some(v) => v,
        \\        None => 0,
        \\    }
        \\}
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const m = fx.prog.program.items[0].fn_item.body.?.block_expr.value.?;
    try testing.expect(m.* == .match_expr);
    try testing.expectEqual(@as(usize, 2), m.match_expr.arms.len);
    // `Some(v)` binds a tuple-struct variant; a bare `None` is a unit variant,
    // which the parser represents as a path pattern.
    try testing.expect(m.match_expr.arms[0].pat.* == .pat_tuple_struct);
    try testing.expect(m.match_expr.arms[1].pat.* == .pat_path);
    try testing.expectEqualStrings("None", m.match_expr.arms[1].pat.pat_path.segments[0].name);
}

test "parses patterns" {
    const cases = [_][]const u8{
        "fn f() { match x { (a, b) => {}, } }",
        "fn f() { match x { Some(_) => {}, None => {}, } }",
        "fn f() { match x { 1 | 2 => {}, } }",
        "fn f() { match x { 1..=5 => {}, } }",
        "fn f() { match x { S { x, y } => {}, } }",
        "fn f() { match x { ref mut v @ Some(_) => {}, } }",
        "fn f() { match x { [a, b, ..] => {}, } }",
        "fn f() { match x { &Some(v) => {}, } }",
        "fn f() { let S { a, b } = s; }",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        try testing.expect(fx.prog.program.items[0].* == .fn_item);
    }
}

test "parses closures" {
    const cases = [_][]const u8{
        "fn main() { let f = |x| x + 1; }",
        "fn main() { let f = |x: i32| -> i32 { x }; }",
        "fn main() { let f = move || 1; }",
        "fn main() { let f = || {}; }",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        const e = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts[0].let_stmt.init.?;
        try testing.expect(e.* == .closure_expr);
    }
}

test "parses generics and where clauses" {
    const src =
        \\fn max<T: PartialOrd>(a: T, b: T) -> T where T: Copy { a }
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const f = fx.prog.program.items[0].fn_item;
    try testing.expectEqual(@as(usize, 1), f.generics.params.len);
    try testing.expectEqualStrings("T", f.generics.params[0].name);
    try testing.expectEqual(@as(usize, 1), f.where_clauses.len);
}

test "parses traits and trait impls" {
    const src =
        \\trait Shape { fn area(&self) -> f64; }
        \\struct Sq(f64);
        \\impl Shape for Sq { fn area(&self) -> f64 { self.0 * self.0 } }
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expect(fx.prog.program.items[0].* == .trait_item);
    try testing.expect(fx.prog.program.items[1].struct_item.is_tuple);
    try testing.expect(fx.prog.program.items[2].impl_item.is_trait_impl);
}

test "parses let else and let chains" {
    const cases = [_][]const u8{
        "fn f() { let Some(x) = y else { return; }; }",
        "fn f() { if let Some(x) = y { } }",
        "fn f() { if let Some(x) = y && x > 0 { } }",
        "fn f() { while let Some(x) = it.next() { } }",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        try testing.expect(fx.prog.program.items[0].* == .fn_item);
    }
}

test "parses use items" {
    const cases = [_][]const u8{
        "use std::vec::Vec;",
        "use std::io;",
        "use std::io::*;",
        "use std::collections::{HashMap, HashSet};",
        "use foo as bar;",
        "pub use self::inner::*;",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        try testing.expect(fx.prog.program.items[0].* == .use_item);
    }
}

test "parses attributes and derives" {
    const src =
        \\#[derive(Debug, Clone)]
        \\#[inline]
        \\pub fn f() -> i32 { 0 }
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const f = fx.prog.program.items[0].fn_item;
    try testing.expectEqual(@as(usize, 2), f.attrs.len);
    try testing.expectEqualStrings("derive", f.attrs[0].path);
    try testing.expectEqualStrings("inline", f.attrs[1].path);
}

test "parses labelled loops" {
    const src =
        \\fn main() {
        \\    'outer: for i in 0..10 {
        \\        'inner: while true {
        \\            break 'outer;
        \\        }
        \\    }
        \\}
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const body = fx.prog.program.items[0].fn_item.body.?;
    // A trailing loop with no `;` is the block's value expression, not a
    // statement, exactly as in Rust.
    const for_expr = body.block_expr.value.?;
    try testing.expect(for_expr.* == .for_expr);
    // Labels are stored without the leading lifetime quote.
    try testing.expectEqualStrings("outer", for_expr.for_expr.label.?);
}

test "parses lifetimes in types" {
    const cases = [_][]const u8{
        "fn f<'a>(x: &'a str) {}",
        "fn f(x: &'static str) {}",
        "fn f(x: &mut [u8]) {}",
        "fn f(x: *const u8) {}",
        "fn f(x: *mut u8) {}",
    };
    for (cases) |src| {
        var fx = try parseFixture(testing.allocator, src);
        defer fx.deinit();
        try testing.expect(fx.prog.program.items[0].* == .fn_item);
    }
}

test "parses extern and const static" {
    const src =
        \\extern "C" { fn abs(x: i32) -> i32; }
        \\const MAX: usize = 10;
        \\static mut COUNTER: i32 = 0;
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expect(fx.prog.program.items[0].* == .extern_block);
    try testing.expect(fx.prog.program.items[1].* == .const_item);
    try testing.expect(fx.prog.program.items[2].* == .static_item);
    try testing.expect(fx.prog.program.items[2].static_item.is_mut);
}

test "parses casts and unary" {
    const src = "fn main() { let x = y as u8 as i32; let z = -x; let w = !flag; let v = *p; }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const stmts = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts;
    // `as` is left-associative: `(y as u8) as i32`.
    try testing.expect(stmts[0].let_stmt.init.?.* == .cast_expr);
    try testing.expectEqualStrings("i32", ast.typeName(stmts[0].let_stmt.init.?.cast_expr.ty).?);
    // `-x` keeps the unary form; only `-<literal>` folds into a literal.
    try testing.expect(stmts[1].let_stmt.init.?.* == .unary_expr);
    try testing.expectEqual(ast.UnaryOp.neg, stmts[1].let_stmt.init.?.unary_expr.op);
    try testing.expect(stmts[2].let_stmt.init.?.* == .unary_expr);
    try testing.expectEqual(ast.UnaryOp.not, stmts[2].let_stmt.init.?.unary_expr.op);
    try testing.expect(stmts[3].let_stmt.init.?.* == .deref_expr);
}

test "parses macro items and exprs" {
    const src =
        \\macro_rules! shout { () => {} }
        \\fn main() { println!("hi"); vec![1, 2]; }
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expect(fx.prog.program.items[0].* == .macro_call_item);
    const body = fx.prog.program.items[1].fn_item.body.?;
    try testing.expect(body.block_expr.stmts[0].expr_stmt.expr.* == .macro_expr);
    try testing.expect(body.block_expr.stmts[1].expr_stmt.expr.* == .macro_expr);
}

test "parses unit struct tuple struct and const generics" {
    const src =
        \\struct Unit;
        \\struct Tup(i32, String);
        \\struct Arr<const N: usize> { data: [u8; N] }
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expect(fx.prog.program.items[0].struct_item.is_unit);
    try testing.expect(fx.prog.program.items[1].struct_item.is_tuple);
    try testing.expectEqual(ast.GenericParamKind.const_param, fx.prog.program.items[2].struct_item.generics.params[0].kind);
}

test "diagnostic reports line and column" {
    const src =
        \\fn main() {
        \\    let x = ;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), src);
    // Any syntax error is acceptable; what matters is that the failure is
    // reported at the offending line rather than at end of file.
    if (p.parseProgram()) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    const pos = Parser.lineCol(&p, p.last_token.loc.start);
    try testing.expectEqual(@as(u32, 2), pos.line);
}

test "parses shift and compound assignment" {
    const src = "fn main() { a <<= 2; b >>= 1; c += 3; d &= 4; }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const stmts = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts;
    try testing.expect(stmts[0].expr_stmt.expr.* == .assign_op_expr);
    try testing.expectEqual(ast.BinaryOp.shl, stmts[0].expr_stmt.expr.assign_op_expr.op);
    try testing.expectEqual(ast.BinaryOp.shr, stmts[1].expr_stmt.expr.assign_op_expr.op);
    try testing.expectEqual(ast.BinaryOp.add, stmts[2].expr_stmt.expr.assign_op_expr.op);
    try testing.expectEqual(ast.BinaryOp.bit_and, stmts[3].expr_stmt.expr.assign_op_expr.op);
}

test "parses string escapes" {
    const src = "fn main() { let s = \"a\\nb\\u{1F600}\"; }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const lit = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts[0].let_stmt.init.?.literal;
    try testing.expectEqualStrings("a\nb\xF0\x9F\x98\x80", lit.str.bytes);
}

test "parses async unsafe and nested modules" {
    const src =
        \\mod outer { pub mod inner { pub fn f() {} } }
        \\async unsafe fn g() {}
    ;
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    try testing.expect(fx.prog.program.items[0].* == .mod_item);
    const g = fx.prog.program.items[1].fn_item;
    try testing.expect(g.is_async);
    try testing.expect(g.is_unsafe);
}

test "parses question mark operator chain" {
    const src = "fn f() -> Result<i32, E> { let v = compute()?; Ok(v) }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    const e = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts[0].let_stmt.init.?;
    try testing.expect(e.* == .try_expr);
    try testing.expect(e.try_expr.inner.* == .call_expr);
}

test "parses deref and method chain" {
    const src = "fn main() { let v = data.lock().unwrap().clone(); }";
    var fx = try parseFixture(testing.allocator, src);
    defer fx.deinit();
    var e = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts[0].let_stmt.init.?;
    var depth: usize = 0;
    while (e.* == .method_call_expr) : (depth += 1) e = e.method_call_expr.receiver;
    try testing.expectEqual(@as(usize, 3), depth);
    try testing.expect(e.* == .path_expr);
}

test "a negative range endpoint parses on both sides" {
    // Regression: the `.minus` branch read `pat_literal` out of whatever
    // `parseLiteralOrRangePattern` returned, so `-2..=-1` -- which is a *range* --
    // panicked on the union field. The upper bound had no handling at all, so any
    // negative range was a syntax error. Negative bounds are everywhere in real
    // code (`-10..=10`).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, "fn f(n: i32) -> i32 { match n { -2..=-1 => 1, _ => 0 } }");
    const prog = try p.parseProgram();
    const body = prog.program.items[0].fn_item.body.?.block_expr;
    const m = body.value.?.match_expr;
    const range = m.arms[0].pat.pat_range;
    try std.testing.expectEqualStrings("-2", range.start.?.pat_literal.literal.int.digits);
    try std.testing.expectEqualStrings("-1", range.end.?.pat_literal.literal.int.digits);
    try std.testing.expect(range.inclusive_start);
    try std.testing.expect(range.inclusive_end);
}

test "an exclusive range is exclusive at both ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, "fn f(n: i32) -> i32 { match n { 1..5 => 1, _ => 0 } }");
    const prog = try p.parseProgram();
    const body = prog.program.items[0].fn_item.body.?.block_expr;
    const range = body.value.?.match_expr.arms[0].pat.pat_range;
    try std.testing.expect(!range.inclusive_start);
    try std.testing.expect(!range.inclusive_end);
}
