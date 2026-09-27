//! Cross-layer tests: parser -> lowering -> expected SA-ASM shape.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const layout = @import("layout.zig");
const lower = @import("lower.zig");
const host_paths = @import("host_paths.zig");

const testing = std.testing;

/// Owns the arena backing a parsed program.
///
/// The arena is heap-allocated because `ArenaAllocator.allocator()` hands out a
/// pointer to the arena itself: keeping it in a by-value struct field would
/// leave the parser holding a pointer into the (already-returned) stack frame.
const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    prog: *ast.Node,

    fn init(src: []const u8) !Fixture {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer {
            arena.deinit();
            testing.allocator.destroy(arena);
        }
        var p = parser.Parser.init(arena.allocator(), src);
        const prog = try p.parseProgram();
        return .{ .arena = arena, .prog = prog };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }
};

/// Lower `src` into a caller-owned buffer. The `Lowerer` frees its own
/// scratch space, so the returned text has to be copied out.
fn lowerSource(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    return lowerSourceWithOptions(allocator, src, .{});
}

fn lowerSourceWithOptions(
    allocator: std.mem.Allocator,
    src: []const u8,
    options: lower.Options,
) ![]const u8 {
    var fx = try Fixture.init(src);
    defer fx.deinit();
    const res = try lower.Lowerer.lower(allocator, fx.prog, options);
    defer res.deinit(allocator);
    return try allocator.dupe(u8, res.sa);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("--- generated ---\n{s}\n--- missing: {s}\n", .{ haystack, needle });
        return error.TestExpectedEqual;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("--- generated ---\n{s}\n--- unexpected: {s}\n", .{ haystack, needle });
        return error.TestUnexpectedResult;
    }
}

test "hello world lowers to a print call" {
    const sa = try lowerSource(testing.allocator, "fn main() { println!(\"hi\"); }");
    defer testing.allocator.free(sa);
    try expectContains(sa, "@main():");
    try expectContains(sa, "L_ENTRY:");
    try expectContains(sa, "call @sa_print_bytes(&RUSTC_STR_1, 2)");
    try expectContains(sa, "return");
    try expectAbsent(sa, "alloc 0");
}

test "integer literals and arithmetic" {
    const sa = try lowerSource(testing.allocator, "fn main() { let s = 2 + 3; }");
    defer testing.allocator.free(sa);
    // The destination register is used directly, avoiding a move of the operand.
    try expectContains(sa, "s = add 2, 3");
    try expectAbsent(sa, "tmp_0");
}

test "function signature and call" {
    const sa = try lowerSource(testing.allocator, 
        \\fn add(a: i32, b: i32) -> i32 { a + b }
        \\fn main() { let r = add(2, 3); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@add(a: i32, b: i32) -> i32:");
    try expectContains(sa, "call @add(2, 3)");
}

test "struct layout and construction" {
    const sa = try lowerSource(testing.allocator, 
        \\struct Point { x: i32, y: f64 }
        \\fn main() { let p = Point { x: 1, y: 2.0 }; }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "#def Point_SIZE = 16");
    try expectContains(sa, "#def Point_x = +0");
    try expectContains(sa, "#def Point_y = +8");
    try expectContains(sa, "alloc Point_SIZE");
    try expectContains(sa, "store p+Point_x, 1 as i32");
    try expectContains(sa, "store p+Point_y, 2.0 as f64");
}

test "enum layout uses a tag plus payload" {
    const sa = try lowerSource(testing.allocator, 
        \\enum Msg { Quit, Move { x: i32, y: i32 } }
        \\fn main() {}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "#def Msg_tag = +0");
    try expectContains(sa, "#def Msg_Quit = 0");
    try expectContains(sa, "#def Msg_Move = 1");
    try expectContains(sa, "#def Msg_Move_x = +8");
}

test "if else as a value allocates its destination before the branch" {
    const sa = try lowerSource(testing.allocator, "fn main() { let v = if 1 > 0 { 10 } else { 20 }; }");
    defer testing.allocator.free(sa);
    const alloc_at = std.mem.indexOf(u8, sa, "alloc 8").?;
    const br_at = std.mem.indexOf(u8, sa, "br ").?;
    try testing.expect(alloc_at < br_at);
    try expectContains(sa, "jmp L_MERGE_");
}

test "while loop restores the live set on the back edge" {
    const sa = try lowerSource(testing.allocator, 
        \\fn main() {
        \\    let mut n = 0;
        \\    while n < 3 { n = n + 1; }
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "L_COND_");
    try expectContains(sa, "L_BODY_");
    try expectContains(sa, "L_END_");
    // The condition register is released before jumping back to the head.
    try expectContains(sa, "jmp L_COND_");
}

test "for loop hoists its induction slot out of the loop" {
    const sa = try lowerSource(testing.allocator, "fn main() { for i in 0..3 { } }");
    defer testing.allocator.free(sa);
    const slot_at = std.mem.indexOf(u8, sa, "stack_alloc 8").?;
    const cond_at = std.mem.indexOf(u8, sa, "L_COND_").?;
    try testing.expect(slot_at < cond_at);
    // A stack_alloc may never be released explicitly.
    try expectAbsent(sa, "!tmp_0");
}

test "both arms of every branch terminate" {
    // The Referee reconciles a phi-join from the two arms of a `br`, so each arm
    // must reach a terminator rather than fall into the next block. This is the
    // invariant the lowering's `releaseAll` + `jmp L_MERGE_n` pattern exists to
    // maintain.
    const src =
        \\fn f(a: i32) -> i32 { if a > 0 { a } else { 0 } }
        \\fn main() { let _x = f(1); }
    ;
    const sa = try lowerSource(testing.allocator, src);
    defer testing.allocator.free(sa);

    var branches: usize = 0;
    var merges: usize = 0;
    var it = std.mem.splitScalar(u8, sa, '\n');
    var arm: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "br ")) branches += 1;
        if (std.mem.indexOf(u8, line, "L_MERGE_") != null and
            std.mem.startsWith(u8, line, "jmp ")) merges += 1;
        if (std.mem.startsWith(u8, line, "jmp ") or std.mem.startsWith(u8, line, "return")) arm += 1;
    }
    // One `if/else` in value position: one `br`, two arms converging on a merge.
    try testing.expectEqual(@as(usize, 1), branches);
    try testing.expectEqual(@as(usize, 2), merges);
    try testing.expect(arm >= 2);
}

test "unsupported constructs are counted and named, not silently dropped" {
    var fx = try Fixture.init("fn main() { let c = some_async_thing().await; }");
    defer fx.deinit();
    const res = try lower.Lowerer.lower(testing.allocator, fx.prog, .{});
    defer res.deinit(testing.allocator);
    try testing.expect(res.unsupported > 0);
    // The reason has to reach the user, otherwise the count says nothing about
    // what was silently replaced.
    try testing.expect(res.unsupported_notes.len > 0);
}

test "a fully supported program reports no unsupported constructs" {
    const sa = try lowerSource(testing.allocator, "fn main() { let a = 1 + 2; }");
    defer testing.allocator.free(sa);
    var fx = try Fixture.init("fn main() { let a = 1 + 2; }");
    defer fx.deinit();
    const res = try lower.Lowerer.lower(testing.allocator, fx.prog, .{});
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), res.unsupported);
    try testing.expectEqual(@as(usize, 0), res.unsupported_notes.len);
}

test "layout engine reports natural sizes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noLookup = struct {
        fn f(_: *anyopaque, _: []const u8) ?*ast.Node {
            return null;
        }
    }.f;
    var e = layout.Engine.init(a, noLookup, undefined);
    defer e.deinit();

    const segs = try a.alloc(ast.PathSegment, 1);
    segs[0] = .{ .name = "u8" };
    const u8ty = try a.create(ast.Node);
    u8ty.* = .{ .ty_path = .{ .segments = segs } };
    const l = try e.layoutOf("t", u8ty);
    try testing.expectEqual(@as(u64, 1), l.size);
    try testing.expectEqual(layout.Alignment.a1, l.alignment);
}

test "parser reports the offending line" {
    const src =
        \\fn main() {
        \\    let x = ;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), src);
    if (p.parseProgram()) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    const pos = parser.Parser.lineCol(&p, p.last_token.loc.start);
    try testing.expectEqual(@as(u32, 2), pos.line);
}

test "macro argument referring to an if-bound variable is not folded to zero" {
    // Regression: `lowerPath` resolved names only through `var_types`, and the
    // `if` result left no type entry behind. The lookup therefore fell through
    // to `zeroValue` and the program silently printed `0` instead of `20`.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let a = 10;
        \\    let b = 20;
        \\    let v = if a > b { a } else { b };
        \\    println!("{}", v);
        \\}
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "tmp_3 = 0");
    try expectContains(sa, "v = load");
}

test "macro arguments are not lowered through freed memory" {
    // Regression: `lowerExprText` re-parsed each macro argument into a
    // per-call arena that was freed before the node was lowered, so the
    // lowering read freed memory. The arena is now owned by the Lowerer.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let n = 7; println!("n={}", n); }
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, " = 0\n");
}

test "value-position if does not steal the enclosing let destination" {
    // Regression: `pending_dest` leaked into control-flow lowering, so the `if`
    // allocated its result into `v` and then re-bound `v` with a load of `v`.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let a = 10;
        \\    let b = 20;
        \\    let v = if a > b { a } else { b };
        \\}
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "v = alloc 8");
    try expectAbsent(sa, "v = load v+0");
}

test "branch arms leave the same live set at the merge point" {
    // One arm binds an extra variable. Rust's block scoping means the binding
    // cannot outlive the arm, so `lowerArm` has to release it before the
    // terminator; that is exactly what keeps the two arms' live sets equal and
    // lets the Referee reconcile the phi-join. `BranchArmLiveSetMismatch` is the
    // assertion that this invariant keeps holding.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let y = if 1 > 0 { let q = 5; q } else { 0 }; }
    );
    defer testing.allocator.free(sa);
    const then_at = std.mem.indexOf(u8, sa, "L_THEN_").?;
    const else_at = std.mem.indexOf(u8, sa, "L_ELSE_").?;
    const merge_at = std.mem.indexOf(u8, sa, "L_MERGE_").?;
    try testing.expect(then_at < else_at and else_at < merge_at);
    // Every temporary defined in an arm is released before the arm terminates.
    try expectAbsent(sa, "jmp L_MERGE_\n    \n");
    try expectContains(sa, "jmp L_MERGE_");
    // `q` is a block-local binding, so it must not survive into the merge block.
    const merge_block = sa[merge_at..];
    try expectAbsent(merge_block, "i32 = ");
}

test "a let inside a loop body does not corrupt the live set" {
    // Index-based release was wrong because `untrack` uses `orderedRemove`,
    // which shifts the tail of the list. The release is now name-based.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let mut n = 0;
        \\    while n < 3 { let t = n * n; n = t + 1; }
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "L_COND_");
    try expectAbsent(sa, "PhiStateConflict");
}

// -- monomorphization ------------------------------------------------------

test "a generic function is instantiated per concrete type argument" {
    // Regression: the body was lowered once with `T` opaque, so both `p.a` and
    // `p.b` read offset 0 and the program printed 14 instead of 21.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn sum<T>(p: T, q: T) -> i32 { p.a + p.b + q.a + q.b }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    let q = Pair { a: 3, b: 4 };
        \\    println!("{}", sum(p, q));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@sum__PAIR");
    // The instance body must use the real field offsets, not a constant 0.
    try expectContains(sa, "ptr_add p, 0");
    try expectContains(sa, "ptr_add p, 4");
}

test "an explicit turbofish selects the instance" {
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn first<T>(p: &T) -> i32 { p.a }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", first::<Pair>(&p));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@first__PAIR(&p: ptr)");
    try expectContains(sa, "ptr_add p, 0");
}

test "one template called with two types yields two instances" {
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn ident<T>(x: T) -> T { x }
        \\fn main() {
        \\    println!("{}", ident(7));
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", ident(p));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@ident__I64");
    try expectContains(sa, "@ident__PAIR");
    // A scalar instantiation keeps a scalar ABI rather than degrading to ptr.
    try expectContains(sa, "@ident__I64(x: i64) -> i64");
}

test "the same instantiation from two call sites is emitted once" {
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn addup<T>(p: &T) -> i32 { p.a + p.b }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    let q = Pair { a: 3, b: 4 };
        \\    println!("{}", addup(&p));
        \\    println!("{}", addup(&q));
        \\}
    );
    defer testing.allocator.free(sa);
    // Two call sites, one definition.
    var defs: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, sa, at, "\n@addup__PAIR")) |i| : (at = i + 1) defs += 1;
    try testing.expectEqual(@as(usize, 1), defs);
    var calls: usize = 0;
    at = 0;
    while (std.mem.indexOfPos(u8, sa, at, "call @addup__PAIR(")) |i| : (at = i + 1) calls += 1;
    try testing.expectEqual(@as(usize, 2), calls);
}

test "a nested generic collapses onto the enclosing instance" {
    // `addup` is only ever reached through `twice::<Pair>`, so it must resolve
    // to `addup__PAIR` and never to an unresolvable `addup__T`.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn addup<T>(p: &T) -> i32 { p.a + p.b }
        \\fn twice<T>(x: &T) -> i32 { addup(x) + addup(x) }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", twice(&p));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@twice__PAIR");
    try expectContains(sa, "call @addup__PAIR(&x)");
    try expectAbsent(sa, "@addup__T");
}

test "a borrowed parameter is released after the pointer derived from it" {
    // Regression: `!p` before `!tmp` left the derived `ptr_add` register
    // dangling and the Referee reported `UseAfterMove`.
    const sa = try lowerSource(testing.allocator,
        \\struct P { a: i32, b: i32 }
        \\fn f(p: &P) -> i32 { p.a + p.b }
    );
    defer testing.allocator.free(sa);
    const derived = std.mem.indexOf(u8, sa, "ptr_add p, 0").?;
    const base = std.mem.indexOf(u8, sa, "!p").?;
    try testing.expect(derived < base);
}

// -- calling convention -----------------------------------------------------

test "an opaque parameter keeps callee and call site in agreement" {
    // Regression: the callee emitted `p: ptr` because `T` has no layout, while
    // the call site emitted `^p` because the argument did. The Referee rejected
    // the mismatch with `CapabilityMismatch`.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\fn opaque<T>(p: T) -> i32 { 1 }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", opaque(p));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "call @opaque__PAIR(");
}

test "a &T annotation is a borrow, not a move" {
    const sa = try lowerSource(testing.allocator,
        \\struct P { a: i32 }
        \\fn f(p: &P) -> i32 { p.a }
        \\fn g(p: &mut P) -> i32 { p.a }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@f(&p: ptr)");
    try expectContains(sa, "@g(&p: ptr)");
}

test "releasing a live set is newest first" {
    const sa = try lowerSource(testing.allocator,
        \\struct P { a: i32, b: i32 }
        \\fn f(p: &P) -> i32 { let x = p.a; let y = p.b; x + y }
    );
    defer testing.allocator.free(sa);
    const body = sa[std.mem.indexOf(u8, sa, "@f(").?..];
    const first_release = std.mem.indexOf(u8, body, "\n    !").?;
    // The first release must be a temporary, never the borrowed base pointer.
    try expectAbsent(body[first_release..][0..8], "!p");
}

test "two different type arguments never share a mangled name" {
    // `Pair` and `PAIR` both flatten to the mangle `PAIR`. Merging them would
    // silently substitute one type for the other.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair { a: i32, b: i32 }
        \\struct PAIR { a: i32 }
        \\fn f<T>(x: T) -> i32 { 1 }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    let q = PAIR { a: 5 };
        \\    println!("{} {}", f(p), f(q));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "@f__PAIR(");
    try expectContains(sa, "@f__PAIR_2(");
}

// -- generic types ----------------------------------------------------------

test "a generic struct is instantiated per inferred type argument" {
    // The field initialisers pin `T` down, so `Pair { a: 1, b: 2 }` is
    // `Pair<i32>` (8 bytes) and `Pair { a: 1.5, b: 2.5 }` is `Pair<f64>` (16).
    const sa = try lowerSource(testing.allocator,
        \\struct Pair<T> { a: T, b: T }
        \\fn sum_pair<T>(p: Pair<T>) -> T { p.a + p.b }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", sum_pair(p));
        \\    let r = Pair { a: 1.5, b: 2.5 };
        \\    println!("{}", sum_pair(r));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "#def Pair__I32_SIZE = 8");
    try expectContains(sa, "#def Pair__F64_SIZE = 16");
    try expectContains(sa, "#def Pair__F64_b = +8");
    try expectContains(sa, "@sum_pair__I32(^p: ptr) -> i32");
    try expectContains(sa, "@sum_pair__F64(^p: ptr) -> f64");
    // No instance is built with the parameter left unresolved.
    try expectAbsent(sa, "Pair__T");
}

test "a type parameter nested in generic arguments is substituted" {
    // Regression: substitution only looked at a bare `T`, so `Pair<T>` inside a
    // parameter position kept `T` unresolved and the instance body read the
    // opaque `Pair__T` offsets (0 and 8) instead of `Pair__I32` (0 and 4).
    const sa = try lowerSource(testing.allocator,
        \\struct Pair<T> { a: T, b: T }
        \\fn sum_pair<T>(p: Pair<T>) -> T { p.a + p.b }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", sum_pair(p));
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "ptr_add p, 0");
    try expectContains(sa, "ptr_add p, 4");
    try expectAbsent(sa, "ptr_add p, 8");
}

test "a generic type with no inferable arguments stays uninstantiated" {
    // Nothing pins `T`, so no instance may be invented.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair<T> { a: T, b: T }
        \\fn opaque(p: Pair<i32>) -> i32 { p.a }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "Pair__I32_SIZE = 8");
}

test "the layout header precedes every function body" {
    // A generic instance is only discovered while a body is lowered, so the
    // `#def` block is assembled afterwards and spliced in front.
    const sa = try lowerSource(testing.allocator,
        \\struct Pair<T> { a: T, b: T }
        \\fn main() {
        \\    let p = Pair { a: 1, b: 2 };
        \\    println!("{}", p.a + p.b);
        \\}
    );
    defer testing.allocator.free(sa);
    const def = std.mem.indexOf(u8, sa, "#def Pair__I32_SIZE").?;
    const fn_start = std.mem.indexOf(u8, sa, "@main(").?;
    const import = std.mem.indexOf(u8, sa, "@import").?;
    try testing.expect(import < def);
    try testing.expect(def < fn_start);
}

// -- host process -----------------------------------------------------------

test "the resolved sa executable is always caller-owned" {
    // Regression: the resolver returned a bare `"sa"` literal on the fallback
    // path and an allocation otherwise, so the caller could neither free it
    // nor know whether it had to. That is a leak on one path and a
    // free-of-a-literal on the other.
    const sa = host_paths.resolveSaExecutable(testing.allocator);
    defer testing.allocator.free(sa);
    try testing.expect(sa.len > 0);
    try testing.expect(std.mem.endsWith(u8, sa, "sa"));
}

// -- regressions found by the e2e suite -------------------------------------
//
// These four were invisible to `zig build test`: they only misbehave once the
// host `sa` runs the program. `tools/e2e.sh` is the gate that catches them.

test "an else-if chain allocates its result block once" {
    // Regression: the nested branch allocated a second block and copied the
    // first one's *pointer* into it, so the merge read a pointer as an integer.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { if n > 0 { 1 } else if n < 0 { -1 } else { 0 } }
    );
    defer testing.allocator.free(sa);
    // Exactly one allocation for the whole chain.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sa, "alloc 8"));
    // The nested branch writes into the shared block.
    try expectContains(sa, "L_THEN_4:");
    // The old lowering copied the inner block's *pointer* into the outer one.
    try expectAbsent(sa, "0, tmp_");
}

test "an else-if chain does not trip the arm live-set check" {
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { if n > 0 { 1 } else if n < 0 { -1 } else { 0 } }
        \\fn main() { }
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "tmp_2 = alloc");
}

test "every placeholder in a format string consumes one argument" {
    // Regression: the format string was split on `{`, so the text after a hole
    // was printed as a literal -- including the *next* placeholder.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { println!("{},{}", 1, 2); }
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, ",{},");
    try expectContains(sa, "sa_fmt_i64(1, 10)");
    try expectContains(sa, "sa_fmt_i64(2, 10)");
}

test "a bound string literal is printed as its bytes" {
    // Regression: the name of the `@const` was fed to `sa_fmt_i64`, so the
    // program printed a pointer value instead of the text. A `&str` is now a
    // `[data, len]` box, so the text is read back out of the binding's own box.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let s = "hi"; println!("{}", s); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "s = alloc 16");
    try expectContains(sa, "store s+0, &RUSTC_STR_1 as ptr");
    try expectContains(sa, "store s+8, 2 as i64");
    try expectContains(sa, "load s+0 as ptr");
    try expectContains(sa, "load s+8 as i64");
    try expectAbsent(sa, "s = RUSTC_STR_1");
    // The text must not be routed through the integer formatter.
    try expectAbsent(sa, "sa_fmt_i64(s");
}

test "a string literal printed inline needs no box" {
    // A `println!` hole whose text is a compile-time constant is printed from
    // the `@const` address, so the common case stays one instruction.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { println!("{}", "hi"); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "sa_print_bytes(&RUSTC_STR_1, 2)");
    try expectAbsent(sa, "alloc 16");
}

test "an inline format argument is captured from the enclosing scope" {
    // Rust 2021 `{name}` captures a local with no positional argument. Treating
    // the hole as positional left it with nothing to print, so the program
    // silently emitted only the literal text around it.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let a = 7; println!("v={a}"); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "sa_fmt_i64(a, 10)");
    // The literal prefix still precedes the captured value.
    try expectContains(sa, "utf8:\"v=\"");
}

test "a diverging branch arm emits nothing after its terminator" {
    // Regression: an arm that ended in `panic!` still had its registers released
    // afterwards, leaving unreachable instructions behind the terminator. The
    // Referee tolerated them but `sa build-exe -g` rejected the whole program with
    // `InvalidOperand`, so debug builds of any `if` with a panicking arm failed.
    const sa = try lowerSource(testing.allocator,
        \\fn boom(n: i32) -> i32 { if n > 0 { 1 } else { panic!("neg") } }
        \\fn main() { println!("{}", boom(0)); }
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "panic(103)\n    !");
    // The non-diverging arm still cleans up, and the merge is still terminated.
    try expectContains(sa, "jmp L_MERGE_");
    try expectContains(sa, "return ");
}

test "a value-position if whose arm panics still returns" {
    // `fn_done` used to mean both "this block ended" and "the function ended", so
    // the merge of an `if` with a panicking arm fell off the end with no
    // terminator at all (`FallthroughForbidden`).
    const sa = try lowerSource(testing.allocator,
        \\fn boom(n: i32) -> i32 { if n > 0 { 1 } else { panic!("neg") } }
    );
    defer testing.allocator.free(sa);
    // The merge is reached from the surviving arm, so it must carry the return.
    const merge = std.mem.indexOf(u8, sa, "L_MERGE_").?;
    const tail = sa[merge..];
    try expectContains(tail, "return ");
}

test "source positions are recorded for items and statements" {
    // `#loc` is only worth emitting if the line numbers are right, and the AST is
    // the only place that knows them.
    var fx = try Fixture.init(
        \\fn main() {
        \\    let a = 1;
        \\    println!("{}", a);
        \\}
    );
    defer fx.deinit();
    const prog = fx.prog.program;
    try testing.expectEqual(@as(u32, 1), prog.items[0].fn_item.pos.line);
    const stmts = prog.items[0].fn_item.body.?.block_expr.stmts;
    try testing.expectEqual(@as(u32, 2), stmts[0].let_stmt.pos.line);
    try testing.expectEqual(@as(u32, 3), stmts[1].expr_stmt.pos.line);
}

test "each function and statement emits a #loc hint" {
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let a = 1;
        \\    println!("{}", a);
        \\}
    );
    defer testing.allocator.free(sa);
    // The `@fn` line carries the item's position...
    try expectContains(sa, "#loc \"main.rs\":1:1\n@main():");
    // ...and each statement carries its own.
    try expectContains(sa, "#loc \"main.rs\":2:5\n");
    try expectContains(sa, "#loc \"main.rs\":3:5\n");
}

test "a zero position emits no hint rather than an invalid one" {
    // SA rejects `#loc` with a zero line or column outright (`InvalidLocHint`),
    // so an unrecorded position must be skipped rather than emitted as `0:0`.
    const sa = try lowerSourceWithOptions(testing.allocator,
        \\fn main() { println!("hi"); }
        ,
        .{ .emit_source_map = false },
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "#loc");
}

test "a tuple let destructures into its elements" {
    // Regression: a non-identifier `let` pattern was dropped with a note, so the
    // names it introduces did not exist and every use of them read a different
    // register. The shape now matches the reference compiler's
    // `12_destructuring` output: one load per element out of the tuple block.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let (a, b) = (2, 5); println!("{}", a + b); }
    );
    defer testing.allocator.free(sa);
    // Both elements are read, at their own offsets -- not just the first.
    try expectContains(sa, "ptr_add ");
    try expectContains(sa, ", 0\n");
    try expectContains(sa, ", 8\n");
    try testing.expectEqual(@as(usize, 2), countMatches(sa, "load tmp_"));
    // The tuple is owned by the statement, so it is released here -- after both
    // elements have been loaded, and before the sum is computed.
    const release = std.mem.indexOf(u8, sa, "!tmp_1\n").?;
    const sum = std.mem.indexOf(u8, sa, " = add ").?;
    try testing.expect(release < sum);
}

test "a struct let pattern binds fields and honours the rest marker" {
    const sa = try lowerSource(testing.allocator,
        \\struct Q { a: i32, b: i32, c: i32 }
        \\fn main() {
        \\    let q = Q { a: 3, b: 4, c: 5 };
        \\    let Q { a, c, .. } = q;
        \\    println!("{} {}", a, c);
        \\}
    );
    defer testing.allocator.free(sa);
    // `a` at +0 and `c` at +8 are read; `b` at +4 is skipped, which is what `..`
    // means. Reading all three would be the pattern being ignored.
    try expectContains(sa, "ptr_add q, 0\n");
    try expectContains(sa, "ptr_add q, 8\n");
    try expectAbsent(sa, "ptr_add q, 4\n");
    // `q` is still owned by its own binding, so destructuring must not free it.
    try testing.expectEqual(@as(usize, 1), countMatches(sa, "!q\n"));
}

test "a match on a scalar tests every arm instead of the first" {
    // Regression: a non-enum scrutinee kept only the first arm, so every other
    // arm's side effects were discarded while the program still looked compiled.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { match n { 0 => 10, 1 => 20, _ => 30 } }
        \\fn main() { println!("{}", f(1)); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "eq n, 0");
    try expectContains(sa, "eq n, 1");
    // Three arms, each dispatching on its own test.
    try testing.expectEqual(@as(usize, 3), countBranches(sa));
    // Each arm stores its result into the shared block the merge reads back, so
    // the value really is produced and not just the first arm's.
    try testing.expectEqual(@as(usize, 3), countMatches(sa, "store tmp_1+0, "));
    try expectContains(sa, "load ");
}

test "a match arm guard is part of the test" {
    // Regression: the guard was dropped, which made the guarded arm match
    // everything and every arm after it dead.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { match n { x if x > 10 => 1, _ => 0 } }
    );
    defer testing.allocator.free(sa);
    // The pattern test and the guard are conjoined rather than either replacing
    // the other.
    try expectContains(sa, "and ");
}

test "a match on a scalar binds the whole scrutinee, not memory at its address" {
    // Regression: the binding arm emitted `load n+0`, reading whatever happened to
    // sit at that address rather than the scrutinee's value.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { match n { x => x * 2 } }
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "load n+0");
    try expectContains(sa, "mul ");
}

test "a range on an unsigned scrutinee compares unsigned" {
    // Regression: `sge`/`sle` were used whatever the scrutinee's type, so `1..=5`
    // on a `u32` holding 3_000_000_000 answered "not in range" without a word.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: u32) -> i32 { match n { 1..=5 => 1, _ => 0 } }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "uge ");
    try expectContains(sa, "ule ");
    try expectAbsent(sa, "sge ");
    try expectAbsent(sa, "sle ");
}

test "a pattern with no test refuses the match instead of matching everything" {
    // Regression: a string literal pattern has no single-register form, and the
    // fallback was "always true" -- so `match s { "a" => 1, "b" => 2, _ => 0 }`
    // answered 1 for every input and never said the construct was dropped.
    const src =
        \\fn g(s: &str) -> i32 { match s { "a" => 1, "b" => 2, _ => 0 } }
        \\fn main() { println!("{}", g("b")); }
    ;
    var fx = try Fixture.init(src);
    defer fx.deinit();
    try testing.expectError(
        error.Unsupported,
        lower.Lowerer.lower(testing.allocator, fx.prog, .{}),
    );
}

test "an uninhabited match emits the panic and nothing else" {
    // `match n { }` can never produce a value. The chain used to fall out of the
    // panic into a merge label that loaded the result block -- a block nothing can
    // write, so the merge read undefined memory.
    const sa = try lowerSource(testing.allocator,
        \\fn noarms(n: i32) { match n { }; }
        \\fn main() { noarms(1); }
    );
    defer testing.allocator.free(sa);
    const start = std.mem.indexOf(u8, sa, "@noarms").?;
    const end = std.mem.indexOfPos(u8, sa, start, "@main").?;
    const body = sa[start..end];
    try expectContains(body, "panic(106)");
    // No result block and no merge: there is nothing to read back.
    try expectAbsent(body, "alloc");
    try expectAbsent(body, "MERGE");
    try expectAbsent(body, "load ");
}

test "a float literal prints as its own text, not at fixed precision" {
    // `sa_std`'s `sa_fmt_f64` is fixed-precision: it renders `0.5` as `0.50` and
    // rounds to `1` at precision 0, where Rust's `{}` is shortest-round-trip. A
    // literal's exact text is known, so it is printed directly.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { println!("{} {} {} {}", 0.5, 1.5, 1.0, 100.25); }
    );
    defer testing.allocator.free(sa);
    // `1.0` prints as `1`: Rust drops a fractional part that is entirely zero.
    try expectContains(sa, "utf8:\"0.5\"");
    try expectContains(sa, "utf8:\"1\"");
    try expectContains(sa, "utf8:\"100.25\"");
    // The fixed-precision formatter is not used for a literal.
    try expectAbsent(sa, "sa_fmt_f64(0.5");
}

test "a float literal out of f64 range is reported" {
    // Rust rejects `1e400` at compile time. Emitting the text unchecked let it
    // through as whatever the backend made of it -- an infinity, silently.
    const res = try lowerResult(testing.allocator,
        \\fn big() -> f64 { let x = 1e400; x }
        \\fn main() { println!("{}", big()); }
    );
    defer res.deinit(testing.allocator);
    try testing.expect(res.unsupported > 0);
    try expectAbsent(res.sa, "1e400");
}

test "a repeated format string does not abort the compilation" {
    // Regression: `stringConst` used the caller's slice as a map key, and the
    // format scanner's accumulator is freed with the macro call. The key then
    // dangled, and the next insert read freed memory, collided with an unrelated
    // string and aborted the whole compilation in `putAssumeCapacityNoClobber`.
    // Two `println!`s with the same text is the minimal trigger: the second lookup
    // walks a key whose backing buffer is gone.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    println!("same");
        \\    println!("same");
        \\    println!("{}", 1);
        \\    println!("same");
        \\}
    );
    defer testing.allocator.free(sa);
    // The constant is interned once and referenced by every use.
    try testing.expectEqual(@as(usize, 1), countMatches(sa, "utf8:\"same\""));
    try testing.expectEqual(@as(usize, 3), countMatches(sa, "sa_print_bytes(&RUSTC_STR_1, 4)"));
}

test "a statement that spans lines is attributed to its first line" {
    // Regression: the position was captured *after* the expression was parsed, so
    // a `println!` whose arguments wrapped was attributed to the line after it.
    var fx = try Fixture.init(
        \\fn main() {
        \\    let a = 1;
        \\    println!("{} {}",
        \\             a,
        \\             a + 1);
        \\}
    );
    defer fx.deinit();
    const stmts = fx.prog.program.items[0].fn_item.body.?.block_expr.stmts;
    try testing.expectEqual(@as(usize, 2), stmts.len);
    // Line 3 is `println!("{} {}",`; the closing paren is on line 5.
    try testing.expectEqual(@as(u32, 3), stmts[1].expr_stmt.pos.line);
}

test "a value-position match releases its result block exactly once" {
    // Regression: `restoreLive` was called without the result block before the
    // merge, so the block was live but never released and the function exit
    // reported `MemoryLeak`.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { match n { 0 => 10, _ => 20 } }
        \\fn main() { println!("{}", f(1)); }
    );
    defer testing.allocator.free(sa);
    const start = std.mem.indexOf(u8, sa, "@f(n: i32)").?;
    const end = std.mem.indexOfPos(u8, sa, start, "@main").?;
    const body = sa[start..end];
    // The block's register name is read off its own `alloc` line, so the
    // assertion does not depend on how many temporaries came before it.
    const alloc_at = std.mem.indexOf(u8, body, "= alloc ").?;
    const line_start = std.mem.lastIndexOfScalar(u8, body[0..alloc_at], '\n').? + 1;
    const name = std.mem.trim(u8, body[line_start..alloc_at], " \t");
    try testing.expect(name.len > 0);
    // Exactly one release, and it is the block's.
    const release = try std.fmt.allocPrint(testing.allocator, "!{s}\n", .{name});
    defer testing.allocator.free(release);
    try testing.expectEqual(@as(usize, 1), countMatches(body, release));
}

test "a refused match allocates nothing" {
    // Regression: the testability check ran *after* the result block was
    // allocated, so refusing a `match` left that block live and unreleased --
    // a `MemoryLeak` at the function exit instead of the diagnostic the refusal
    // was supposed to produce.
    const sa = try lowerSource(testing.allocator,
        \\fn g(s: &str) { match s { "a" => 1, _ => 0 }; }
        \\fn main() { g("b"); println!("ok"); }
    );
    defer testing.allocator.free(sa);
    // The refused function body is empty: no block was allocated for it.
    const body = std.mem.indexOf(u8, sa, "@g(&s: ptr)").?;
    const rest = sa[body..];
    const end = std.mem.indexOf(u8, rest, "@main").?;
    try expectAbsent(rest[0..end], "alloc");
}

test "a statement-position match on an unsupported scrutinee degrades to unit" {
    // `()` is an honest value for a statement, so this stays a note rather than an
    // error. In value position there is no honest placeholder, and a stub that
    // returns nothing under a valued signature surfaces as a backend type error
    // that says nothing about the cause.
    const res = try lowerResult(testing.allocator,
        \\fn g(s: &str) { match s { "a" => 1, _ => 0 }; }
        \\fn main() { g("b"); }
    );
    defer res.deinit(testing.allocator);
    try testing.expect(res.unsupported > 0);
}

test "a let initialiser is in value position" {
    // Regression: `value_pos` was only set for a block's tail expression, so
    // `let x = match n { .. };` lowered the match as a statement, produced nothing,
    // and emitted a bare `x = ` that the flattener rejected.
    const sa = try lowerSource(testing.allocator,
        \\fn f(n: i32) -> i32 { let x = match n { 0 => 10, _ => 20 }; x }
    );
    defer testing.allocator.free(sa);
    // The match stores into a block the merge reads back, so `x` has a value.
    try expectContains(sa, "alloc 8");
    try expectContains(sa, "load ");
    try expectAbsent(sa, "\n    x = \n");
}

test "a branch arm does not release a variable the merge still needs" {
    // Regression: an arm released "everything except the result block", which
    // included the enclosing scope's variables. Reading one after the branch then
    // trapped with UseAfterMove, so any `let b = if c {..} else {..};` followed
    // by a use of an earlier variable was rejected by the Referee.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let a = 5;
        \\    let b = if a > 0 { 1 } else { 2 };
        \\    println!("{} {}", a, b);
        \\}
    );
    defer testing.allocator.free(sa);
    // `a` is released exactly once, at the function exit -- not per arm.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, sa, "!a");
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count - 1);
}

test "a &str parameter and return value keep both words" {
    const sa = try lowerSource(testing.allocator,
        \\fn f(s: &str) -> &str { if s.len() > 1 { "long" } else { "s" } }
        \\fn main() { let a = "hi"; println!("{}", f(a)); }
    );
    defer testing.allocator.free(sa);
    // A `&str` crosses the boundary as one `ptr` parameter.
    try expectContains(sa, "@f(&s: ptr)");
    try expectContains(sa, "-> ptr");
    // The join result is a two-word slot, so the callee returns a real fat pointer.
    try expectContains(sa, "alloc 16");
    // The caller reads the returned pair back out.
    try expectContains(sa, "as ptr");
}

test "str len folds on a literal and reads a binding" {
    const sa = try lowerSource(testing.allocator,
        \\fn main() { println!("{}", "abc".len()); }
    );
    defer testing.allocator.free(sa);
    // A compile-time length needs no load at all.
    try expectAbsent(sa, "load");
    try expectContains(sa, "sa_fmt_u64(3, 10)");
}

test "a nested let does not overwrite the binding it shadows" {
    // Regression: SA registers are flat, so `let x = 2` inside a block rebound
    // the outer `x` and the code after the block read the inner value.
    const sa = try lowerSource(testing.allocator,
        \\fn main() {
        \\    let x = 1;
        \\    { let x = 2; }
        \\    println!("{}", x);
        \\}
    );
    defer testing.allocator.free(sa);
    // The inner binding gets its own register.
    try expectContains(sa, "x__1 = 2");
    try expectAbsent(sa, "\n    x = 2");
}

test "an enum variant construction stores the tag and the payload" {
    // Regression: `Shape::Circle(4)` matched no known function and folded to a
    // zero, so every later `match` on it silently took the wrong arm.
    const sa = try lowerSource(testing.allocator,
        \\enum Shape { Circle(i32), Rect(i32, i32), Empty }
        \\fn main() {
        \\    let c = Shape::Circle(4);
        \\    let e = Shape::Empty;
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "c = alloc Shape_SIZE");
    try expectContains(sa, "store c+Shape_tag, Shape_Circle as u64");
    try expectContains(sa, "store c+Shape_Circle_0, 4 as i32");
    // A unit variant is a bare path, not a call, so it needs its own path.
    try expectContains(sa, "store e+Shape_tag, Shape_Empty as u64");
}

test "a match arm binds a tuple variant payload" {
    // Regression: the payload was loaded into a temporary but the pattern
    // variable was only renamed in the live set, so the arm body referenced a
    // register that was never emitted and every use folded to a zero.
    const sa = try lowerSource(testing.allocator,
        \\enum Shape { Circle(i32), Empty }
        \\fn area(s: &Shape) -> i32 {
        \\    match s { Shape::Circle(r) => 3 * r, Shape::Empty => 0 }
        \\}
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "as i32");
    try expectAbsent(sa, "3 * r");
}

test "a value-position match shares one result block across every arm" {
    // Regression: a `br` opens two control-flow paths but the live set is a
    // single mutable list, so the first arm's releases were still visible to
    // the fall-through path. The scrutinee was consumed there and every later
    // arm referenced a register that was no longer in scope.
    const sa = try lowerSource(testing.allocator,
        \\enum Shape { Circle(i32), Rect(i32, i32), Empty }
        \\fn area(s: &Shape) -> i32 {
        \\    match s {
        \\        Shape::Circle(r) => 3 * r,
        \\        Shape::Rect(w, h) => w * h,
        \\        Shape::Empty => 0,
        \\    }
        \\}
    );
    defer testing.allocator.free(sa);
    // One block for the whole dispatch, and every arm writes into it.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sa, "alloc 8"));
    try expectContains(sa, "Shape_Rect_0");
    try expectContains(sa, "Shape_Rect_1");
    try expectContains(sa, "panic(106)");
}

test "a method body resolves the receiver's field layout" {
    // Regression: a `self` parameter carries no type node, so `self.n = ...`
    // could not resolve the field and degenerated into rebinding the `self`
    // register, which the Referee rejected as a redefinition of a live register.
    const sa = try lowerSource(testing.allocator,
        \\struct Counter { n: i32 }
        \\impl Counter {
        \\    fn bump(&mut self) { self.n = self.n + 1; }
        \\}
    );
    defer testing.allocator.free(sa);
    try expectAbsent(sa, "\n    self = ");
    // The field is addressed relative to the receiver, not rebound onto it.
    try expectContains(sa, "ptr_add self, ");
    try expectContains(sa, "store ");
}

test "a method call passes the receiver as argument zero" {
    // The callee contract declares `self` first, so the call site has to prepend
    // the receiver or every argument would be shifted by one.
    const sa = try lowerSource(testing.allocator,
        \\struct Counter { n: i32 }
        \\impl Counter {
        \\    fn get(&self) -> i32 { self.n }
        \\}
        \\fn main() { let c = Counter { n: 1 }; println!("{}", c.get()); }
    );
    defer testing.allocator.free(sa);
    try expectContains(sa, "call @Counter_get(&c)");
}

test "a string returned by a value-position if keeps its length" {
    // Regression: a `&str` produced by a branch join had nowhere to record its
    // byte length, so the merge read the data address as an integer and the
    // program printed a pointer value. The join slot is now the fat pointer.
    const sa = try lowerSource(testing.allocator,
        \\fn main() { let y = if 1 > 0 { "positive" } else { "n" }; println!("{}", y); }
    );
    defer testing.allocator.free(sa);
    // One two-word slot, allocated before the branch and handed to the binding.
    try expectContains(sa, "= alloc 16");
    // Each arm carries its *own* length, which is the whole point of a fat
    // pointer: a compile-time name could not have done this.
    try expectContains(sa, "&RUSTC_STR_1 as ptr");
    try expectContains(sa, "+8, 8 as i64");
    try expectContains(sa, "&RUSTC_STR_2 as ptr");
    try expectContains(sa, "+8, 1 as i64");
    // The binding reuses the slot as a move, so no `load` narrows it to a word.
    try expectAbsent(sa, "as ptr\n    y");
}


/// How many `br` instructions the generated program has, i.e. how many
/// dispatch decisions a chain of arms actually makes.
fn countBranches(sa: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, sa, "\n    br ");
    while (it.next()) |_| n += 1;
    return n - 1;
}

/// How many times `needle` occurs in `haystack`, as whole occurrences of the
/// needle rather than overlapping ones.
fn countMatches(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

/// Lower `src` and hand back the full result, for tests that inspect the
/// diagnostics rather than the generated text.
fn lowerResult(allocator: std.mem.Allocator, src: []const u8) !lower.Result {
    var fx = try Fixture.init(src);
    defer fx.deinit();
    return lower.Lowerer.lower(allocator, fx.prog, .{});
}
