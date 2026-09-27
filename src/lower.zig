//! Rust -> SA-ASM lowering.
//!
//! SA-ASM has no aggregate syntax and no structured control flow, so every
//! construct is lowered by hand here:
//!
//!   * `struct`/`enum` become `#def` offset dictionaries plus `alloc`/`load`/
//!     `store`; an aggregate value is a `ptr` to its heap block.
//!   * `if`/`match` become `br` chains; every arm ends in `jmp L_MERGE_n`.
//!   * `while`/`for` become `L_COND_n` / `L_BODY_n` / `L_END_n` triples.
//!   * an `if` used as a value allocates its destination *before* the branch,
//!     which is what the Referee needs to keep the two arms reconcilable.
//!
//! Ownership follows SA's five-symbol model. A live set tracks every register
//! that still needs an explicit release, and every exit path (branch arm, loop
//! exit, `return`, fall-through) drains it via `releaseAll`. That is the single
//! most important invariant in this file.
//!
//! Naming follows the SA reference compiler so output is diff-comparable with
//! `sa_plugin_sla`: `tmp_N` for temporaries, `L_THEN_N`/`L_ELSE_N`/`L_MERGE_N`
//! for branches, `L_COND_N`/`L_BODY_N`/`L_END_N` for loops.

const std = @import("std");
const ast = @import("ast.zig");
const layout = @import("layout.zig");
const monomorph = @import("monomorph.zig");

pub const Error = error{
    /// A construct the lowering does not implement (yet).
    Unsupported,
    /// No `main` (or configured entry point) in the program.
    MissingEntry,
    /// An aggregate was used where a scalar is required, or vice versa.
    TypeError,
    /// A name could not be resolved.
    UnknownName,
    /// The two arms of a branch produced different live sets, which would make
    /// the phi-join disagree. Reported rather than silently preferring one arm.
    BranchArmLiveSetMismatch,
    OutOfMemory,
};

pub const Options = struct {
    /// Emit `@test` wrappers for `#[test]` functions.
    emit_tests: bool = true,
    /// Name of the program entry point.
    entry: []const u8 = "main",
    /// Emit a comment header naming the upstream source.
    emit_header: bool = true,
    /// Emit `#loc "file":line:col` hints so the SA compiler can attribute every
    /// instruction back to the Rust source it came from.
    ///
    /// Costs one line per statement and buys DWARF `!DILocation` records plus a
    /// Rust file/line in every trap the Referee reports, which is the difference
    /// between "something is wrong" and a jump straight to the statement.
    emit_source_map: bool = true,
    /// The Rust file the program came from, named in every `#loc` hint.
    source_name: []const u8 = "main.rs",
};

pub const Result = struct {
    /// The `.sa` program text.
    sa: []const u8,
    function_count: usize,
    def_count: usize,
    /// Constructs the lowering refused, for coverage reporting.
    unsupported: usize = 0,
    /// The distinct reasons behind `unsupported`, so the caller can tell the
    /// user *what* was dropped instead of only how much.
    ///
    /// The slice is owned by the caller and must be released with `deinit`; the
    /// strings themselves are compile-time literals. It cannot point into the
    /// Lowerer's scratch arena, which is gone by the time `lower` returns.
    unsupported_notes: []const []const u8 = &.{},

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.sa);
        allocator.free(self.unsupported_notes);
    }
};

/// The size of a Rust `&str` in this representation.
///
/// SA has no string literal sugar, so a `&str` is the fat pointer `sci`'s own
/// requirements prescribe (item 9): a 16-byte block holding the data address at
/// `+0` and the byte length at `+8`. One register, one owner, so it composes
/// with the rest of the affine discipline instead of needing a side table.
pub const STR_BOX_SIZE = 16;

/// Offset of the data pointer inside a `&str` box.
pub const STR_DATA_OFF = 0;
/// Offset of the byte length inside a `&str` box.
pub const STR_LEN_OFF = 8;

/// How a `&str` value is laid out. Set on `Value.str_form`; null means "not a
/// string".
///
/// SA has no string-literal sugar, so a `&str` is the fat pointer `sci`'s own
/// requirements prescribe (item 9): `[data, len]`. Because SA also has no
/// value-copy instruction, the *same* string cannot be duplicated, so each
/// context that needs a string picks the form that costs no copy.
pub const StrForm = enum {
    /// `reg` is the name of an inline `@const`; the text is compile-time known
    /// and costs no instruction. Usable wherever the text is only *read* at
    /// compile time: a format hole, a `len()` that folds, an aggregate field.
    const_text,
    /// The `[data, len]` pair is stored at `reg`, which is an address rather
    /// than a register. This is a struct field: the aggregate owns the 16 bytes,
    /// so nothing is allocated and nothing can leak.
    at_addr,
    /// `reg` is a pointer to a 16-byte box holding the pair. This is a binding
    /// or a branch-join result: one register, one owner, released with `!`.
    boxed,
};

/// A lowered value: an SA register plus enough type information to know how to
/// load, store, release and pass it.
pub const Value = struct {
    /// SA register name, or an immediate literal for `.immediate` values.
    reg: []const u8,
    /// Rust type when known. Aggregates are held behind a pointer.
    ty: ?*ast.Node = null,
    kind: Kind = .scalar,
    /// True when `reg` holds a borrowed pointer: released with `!`, never moved.
    borrowed: bool = false,
    /// True when `reg` is a compile-time constant/address, so it owns nothing.
    immediate: bool = false,
    /// True when `reg` addresses memory (`load`/`store`) rather than being a
    /// plain register. Only meaningful for places.
    is_memory: bool = false,
    /// Set when this value is a `&str`; see `StrForm` for what `reg` then means.
    str_form: ?StrForm = null,

    pub const Kind = enum { scalar, aggregate, unit };

    pub fn unitValue() Value {
        return .{ .reg = "", .kind = .unit };
    }
};

// ---------------------------------------------------------------------------
// symbol tables
// ---------------------------------------------------------------------------

const FnSig = struct {
    /// Mangled SA name: `max`, `Point_area`, `fib_i32`.
    sa_name: []const u8,
    rust_name: []const u8,
    params: []const ast.Param,
    ret: ?*ast.Node,
    body: ?*ast.Node,
    is_test: bool = false,
    /// Set for `extern` declarations with no Rust body.
    is_extern: bool = false,
    abi: ?[]const u8 = null,
    /// The receiver's Rust type for a method. A `self` parameter carries no
    /// type node of its own, so without this `self.n = ...` cannot resolve the
    /// field's layout and degenerates into rebinding the `self` register.
    self_type: ?*ast.Node = null,
    /// Where the Rust item starts, for the `#loc` hint on the `@fn` line.
    pos: ast.SrcPos = .{},
};

const TypeDef = struct {
    name: []const u8,
    node: *ast.Node,
};

const LoopCtx = struct {
    break_label: []const u8,
    continue_label: []const u8,
    /// Register receiving a `break value`.
    result_reg: ?[]const u8 = null,
};

pub const Lowerer = struct {
    /// Scratch allocator for every label, temporary name and layout key.
    /// `ArenaAllocator.allocator()` returns a pointer to the arena itself, so
    /// the arena must be owned by the caller of `init` and outlive the Lowerer.
    allocator: std.mem.Allocator,
    /// Arena for ASTs re-parsed from macro argument text. Owned by the Lowerer
    /// because those nodes stay referenced long after the parse returns; a
    /// per-call arena would be a use-after-free that silently lowers the
    /// argument to a zero constant.
    scratch_arena: std.heap.ArenaAllocator,
    options: Options,
    /// Generic functions, keyed by Rust name, awaiting instantiation.
    templates: std.StringHashMapUnmanaged(ast.FnItem) = .empty,
    /// Generic structs and enums. Kept out of `types` so no layout is ever
    /// computed for an uninstantiated template.
    generic_types: std.StringHashMapUnmanaged(TypeDef) = .empty,
    /// Instances of the generic types above.
    type_planner: monomorph.Planner = undefined,
    /// Planner owning the discovered `(template, type args)` instances.
    planner: monomorph.Planner = undefined,
    /// Rust name -> the SA register it currently denotes.
    ///
    /// A nested `let` that shadows an outer binding must not overwrite the
    /// outer value: SA registers are flat, so the inner binding gets a fresh
    /// register and the outer name keeps meaning what it meant. The map is
    /// saved and restored around a block, which is what makes shadowing local.
    shadow: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// `@const` name -> byte length, filled in by `stringConst`.
    const_lengths: std.StringHashMapUnmanaged(usize) = .empty,
    /// Binding name -> whether the register holds a `&str` fat-pointer box.
    /// The type alone is not enough: an untyped binding (`let s = if c {..}`) has
    /// no `ty` to consult, and a string read as an integer is a silent
    /// miscompile rather than a diagnostic.
    str_regs: std.StringHashMapUnmanaged(void) = .empty,
    /// Register -> the source text of the float literal it holds, when it is one.
    ///
    /// `sa_std`'s `sa_fmt_f64` is a *fixed-precision* formatter: it prints `0.5`
    /// as `0.50` and rounds to `1` at precision 0, while Rust's `{}` is
    /// shortest-round-trip. A literal's exact text is known here, so it is printed
    /// directly and the formatter is never asked to guess.
    float_lits: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// An already-allocated result block handed to a nested `if` in an
    /// `else if` chain, so the chain allocates once instead of once per link.
    inherited_alloc: ?[]const u8 = null,
    /// The enclosing `if`'s keep-set, handed down the same way.
    ///
    /// A nested `if` must release its `else` arm's condition like any other arm,
    /// but that condition is already live when the nested call starts, so a keep
    /// set taken from its own entry would preserve it. The chain therefore shares
    /// one keep-set, and every arm of every link agrees at the merge.
    inherited_outer: ?[][]const u8 = null,
    /// The next expression is a block's tail value, so it must produce a
    /// result rather than a side effect. `match` reads this because nothing
    /// else marks it: a value-position `match` has to allocate a block for its
    /// arms to write into, exactly as a value-position `if` does.
    value_pos: bool = false,
    /// Type-parameter -> concrete type for the instance being lowered.
    active_subst: std.StringHashMapUnmanaged(*ast.Node) = .empty,
    /// Parameters this function only borrows. They stay owned by the caller, so
    /// no exit path may release them.
    borrowed_params: std.ArrayList([]const u8) = undefined,
    out: std.ArrayList(u8) = undefined,
    tmp: usize = 0,
    label: usize = 0,
    /// Registers still requiring an explicit release at the next exit.
    live: std.ArrayList([]const u8) = undefined,
    /// Rust type of each in-scope variable, keyed by SA register name.
    var_types: std.StringHashMapUnmanaged(*ast.Node) = .empty,
    loops: std.ArrayList(LoopCtx) = undefined,
    /// `self` receiver register of the function being lowered.
    self_reg: ?[]const u8 = null,
    current_impl: ?[]const u8 = null,
    /// The `impl` receiver type currently being collected, if any. A `self`
    /// parameter has no type node of its own, so a method body like
    /// `self.n = self.n + 1` needs this to resolve the field's layout.
    im_self_ty: ?*ast.Node = null,
    /// Set when the function being lowered returns `Result`.
    returns_fallible: bool = false,
    /// Body has been fully lowered (so a trailing `return` is implicit).
    fn_done: bool = false,
    unsupported: usize = 0,
    /// Distinct reasons for `unsupported`, in first-seen order.
    unsupported_notes: std.ArrayList([]const u8) = undefined,
    /// String literals already emitted as `@const`, mapped to their name.
    consts: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The last emitted `#loc`, so consecutive statements on one line do not each
    /// repeat it. Reset per function.
    last_loc_line: u32 = 0,
    last_loc_col: u32 = 0,
    /// Scratch buffer reused by `escapeForSa`.
    escape_buf: std.ArrayList(u8) = undefined,
    /// Set while lowering a `let` initialiser: the *first* temporary created
    /// takes this name, so `let x = a + b` becomes `x = add a, b` with no
    /// throw-away intermediate. SA's `dst = src` is a move, so introducing an
    /// intermediate would consume the operand and force an explicit release.
    pending_dest: ?[]const u8 = null,
    dest_taken: bool = false,
    const_counter: usize = 0,

    /// A synthetic `ty_path` per type name, so the layout engine can be asked
    /// about a type by name without inventing a node on every query.
    type_nodes: std.StringHashMapUnmanaged(*ast.Node) = .empty,
    /// `const NAME = <integer literal>`; uses are inlined as immediates.
    int_consts: std.StringHashMapUnmanaged(i64) = .empty,
    functions: std.ArrayList(FnSig) = undefined,
    types: std.StringHashMapUnmanaged(TypeDef) = .empty,
    /// `#def` lines for the header, in dependency-friendly order.
    defs: std.ArrayList(u8) = undefined,
    def_names: std.StringHashMapUnmanaged(void) = .empty,
    engine: layout.Engine = undefined,

    pub fn lower(
        allocator: std.mem.Allocator,
        program: *ast.Node,
        options: Options,
    ) Error!Result {
        // One arena for the whole lowering: every `allocPrint` label, temporary
        // name and `#def` key comes from here.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var self = Lowerer.init(arena.allocator(), allocator, options);
        // `toOwnedSlice` transfers the buffer and leaves the list empty, so a
        // plain `defer` is safe on both the success and the error path.
        defer self.deinit();
        self.engine = layout.Engine.init(arena.allocator(), resolveType, &self);
        defer self.engine.deinit();

        try self.collect(program);
        // Materialise a `ty_path` node for every named type before any layout is
        // computed, so `layoutOfName` and `typeFor` agree on identity.
        {
            var names: std.ArrayList([]const u8) = .init(self.allocator);
            defer names.deinit();
            var it = self.types.iterator();
            while (it.next()) |entry| try names.append(entry.key_ptr.*);
            for (names.items) |n| _ = try self.typeFor(n);
        }
        // Bodies are lowered into a separate buffer. A generic struct instance
        // is only discovered while a body is being lowered, so the `#def` header
        // cannot be flushed first without losing that instance's layout.
        for (self.functions.items) |f| try self.emitFunction(f);
        // Monomorphised bodies come last: an instance may itself call another
        // generic function, which appends further instances.
        try self.emitInstances();

        // Now that every instance is known, emit the complete layout header and
        // put it in front of the bodies.
        try self.emitAllLayoutDefs();
        var header: std.ArrayList(u8) = .init(allocator);
        defer header.deinit();
        try self.emitImports(&header);
        if (self.defs.items.len > 0) {
            try header.appendSlice(self.defs.items);
            try header.append('\n');
        }
        try self.out.insertSlice(0, header.items);
        if (options.emit_tests) {
            for (self.functions.items) |f| {
                if (f.is_test) try self.emitTestWrapper(f);
            }
        }
        const function_count = self.functions.items.len;
        const def_count = self.def_names.count();
        const sa_text = try self.out.toOwnedSlice();
        return .{
            .sa = sa_text,
            .function_count = function_count,
            .def_count = def_count,
            .unsupported = self.unsupported,
            .unsupported_notes = try self.ownedNotes(allocator),
        };
    }

    fn init(scratch: std.mem.Allocator, out_allocator: std.mem.Allocator, options: Options) Lowerer {
        return .{
            .allocator = scratch,
            .scratch_arena = std.heap.ArenaAllocator.init(out_allocator),
            .options = options,
            .planner = monomorph.Planner.init(scratch),
            .type_planner = monomorph.Planner.init(scratch),
            .borrowed_params = .init(scratch),
            .str_regs = .empty,
            .float_lits = .empty,
            .shadow = .empty,
            .const_lengths = .empty,
            .unsupported_notes = .init(scratch),

            .out = .init(out_allocator),
            .live = .init(scratch),
            .loops = .init(scratch),
            .consts = .empty,
            .escape_buf = .init(scratch),
            .functions = .init(scratch),
            .types = .empty,
            .defs = .init(scratch),
            .def_names = .empty,
        };
    }

    /// Copy the note list onto the caller's allocator.
    fn ownedNotes(self: *Lowerer, allocator: std.mem.Allocator) Error![]const []const u8 {
        if (self.unsupported_notes.items.len == 0) return &.{};
        const out = try allocator.alloc([]const u8, self.unsupported_notes.items.len);
        @memcpy(out, self.unsupported_notes.items);
        return out;
    }

    /// A `const` item's value, if it folds to an integer.
    fn constValue(self: *Lowerer, name: []const u8) ?Value {
        const n = self.int_consts.get(name) orelse return null;
        const text = std.fmt.allocPrint(self.allocator, "{d}", .{n}) catch return null;
        return .{ .reg = text, .immediate = true };
    }

    fn deinit(self: *Lowerer) void {
        self.borrowed_params.deinit();
        self.str_regs.deinit(self.allocator);
        self.float_lits.deinit(self.allocator);
        self.shadow.deinit(self.allocator);
        self.const_lengths.deinit(self.allocator);
        self.unsupported_notes.deinit();
        self.unsupported_notes.deinit();
        self.planner.deinit();
        self.type_planner.deinit();
        self.generic_types.deinit(self.allocator);
        self.templates.deinit(self.allocator);
        self.active_subst.deinit(self.allocator);
        self.scratch_arena.deinit();
        self.int_consts.deinit(self.allocator);
        self.type_nodes.deinit(self.allocator);
        self.out.deinit();
        self.live.deinit();
        self.loops.deinit();
        self.consts.deinit(self.allocator);
        self.escape_buf.deinit();
        self.functions.deinit();
        self.types.deinit(self.allocator);
        self.defs.deinit();
        self.def_names.deinit(self.allocator);
        self.var_types.deinit(self.allocator);
    }

    fn resolveType(ctx: *anyopaque, name: []const u8) ?*ast.Node {
        const self: *Lowerer = @ptrCast(@alignCast(ctx));
        const td = self.types.get(name) orelse return null;
        return td.node;
    }

    // -- emit primitives ----------------------------------------------------

    fn w(self: *Lowerer, comptime fmt: []const u8, args: anytype) Error!void {
        self.out.writer().print(fmt, args) catch return error.OutOfMemory;
    }

    fn line(self: *Lowerer, comptime fmt: []const u8, args: anytype) Error!void {
        self.out.writer().print("    " ++ fmt ++ "\n", args) catch return error.OutOfMemory;
    }

    fn blank(self: *Lowerer) Error!void {
        try self.w("\n", .{});
    }

    fn nextTmp(self: *Lowerer) Error![]const u8 {
        if (self.pending_dest) |d| {
            if (!self.dest_taken) {
                self.dest_taken = true;
                return d;
            }
        }
        self.tmp += 1;
        return std.fmt.allocPrint(self.allocator, "tmp_{d}", .{self.tmp});
    }

    /// Run a control-flow construct with the `let` destination hint suspended.
    ///
    /// `pending_dest` names the register a `let` wants its initialiser to write
    /// into. Control flow must not consume it: `if`/`while`/`for` allocate their
    /// *own* destination (an `alloc`ed cell for a value-position `if`, a
    /// `stack_alloc` slot for a `for`), and would otherwise bind that allocation
    /// to the `let` name. The result would be `v = alloc 8` followed by
    /// `v = load v+0` -- a self-move the Referee rejects, or worse, a silently
    /// wrong value.
    const DestScope = struct {
        dest: ?[]const u8,
        taken: bool,
    };

    fn suspendDest(self: *Lowerer) DestScope {
        const g = DestScope{ .dest = self.pending_dest, .taken = self.dest_taken };
        self.pending_dest = null;
        self.dest_taken = false;
        return g;
    }

    fn resumeDest(self: *Lowerer, g: DestScope) void {
        self.pending_dest = g.dest;
        self.dest_taken = g.taken;
    }

    /// Turn a memory-shaped value into a register value by loading it.
    fn materialize(self: *Lowerer, v: Value) Error!Value {
        if (v.reg.len == 0) return v;
        // A `&str` never narrows to one word: `load addr+0` would yield the data
        // address and throw the length away, which is what made a string printed
        // as a pointer value. Every form is normalised to a box here.
        if (try self.isStrValue(v)) return self.strAsBox(v);
        if (!v.is_memory or v.immediate) return v;
        if (try self.isAggregate(v.ty)) return v;
        const t = try self.nextTmp();
        try self.emitLoad(t, v.reg, v.ty);
        try self.track(t);
        return .{ .reg = t, .ty = v.ty };
    }

    /// True when this value is a Rust string, so it must be read as a
    /// `[data, len]` fat pointer rather than as a scalar.
    fn isStrValue(self: *Lowerer, v: Value) Error!bool {
        if (v.str_form != null) return true;
        if (self.str_regs.contains(v.reg)) return true;
        if (try self.nominalOf(v.ty)) |n| return std.mem.eql(u8, n, "str");
        return false;
    }

    fn markStrReg(self: *Lowerer, reg: []const u8) Error!void {
        if (reg.len == 0) return;
        // The same register is marked twice on the literal path: once by the box
        // it is written into, once by the `let` that binds it.
        if (self.str_regs.contains(reg)) return;
        try self.str_regs.put(self.allocator, reg, {});
    }

    /// Build a `&str` fat pointer for `bytes`: a 16-byte block holding the data
    /// address and the byte length.
    ///
    /// This is the two-step form `sci/docs/requirements.md` (item 9) prescribes,
    /// because SA has no string-literal sugar. It is used where a string has to
    /// *be* a value -- a binding, a call argument, a branch-join result -- and
    /// deliberately not where a copy would be needed, because SA has no
    /// value-copy instruction either.
    fn strBox(self: *Lowerer, bytes: []const u8) Error!Value {
        return self.strBoxFromConst(try self.stringConst(bytes), bytes.len);
    }

    /// Box an already-interned string constant.
    fn strBoxFromConst(self: *Lowerer, name: []const u8, len: usize) Error!Value {
        // `nextTmp` hands back the enclosing `let`'s register when there is one,
        // so `let s = "x";` allocates the box straight into `s`.
        const box = try self.nextTmp();
        try self.line("{s} = alloc {d}", .{ box, STR_BOX_SIZE });
        try self.track(box);
        try self.markStrReg(box);
        try self.line("store {s}+{d}, &{s} as ptr", .{ box, STR_DATA_OFF, name });
        try self.line("store {s}+{d}, {d} as i64", .{ box, STR_LEN_OFF, len });
        return .{ .reg = box, .ty = try self.typeFor("str"), .str_form = .boxed };
    }

    /// A string literal whose text is still known at compile time.
    ///
    /// Costs no instruction: the "register" is the name of an inline `@const`,
    /// which is only meaningful as an address. A consumer that needs a real
    /// register calls `strAsBox`.
    fn strText(self: *Lowerer, bytes: []const u8) Error!Value {
        return .{
            .reg = try self.stringConst(bytes),
            .borrowed = true,
            .immediate = true,
            .str_form = .const_text,
        };
    }

    /// Normalise any string form to a box, which is the only form a register
    /// value can hold.
    fn strAsBox(self: *Lowerer, v: Value) Error!Value {
        switch (v.str_form orelse return v) {
            // The `@const` is already emitted, so the box reuses its name and
            // length rather than interning the *name* as if it were the text.
            .boxed => return v,
            .const_text => return self.strBoxFromConst(v.reg, self.constLenOf(v.reg) orelse 0),
            .at_addr => {
                // The pair already sits in memory at `v.reg`; read it back out so
                // the value owns a box like any other. The original is left alone:
                // it belongs to the aggregate that holds it.
                const data = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as ptr", .{ data, v.reg, STR_DATA_OFF });
                try self.track(data);
                const len = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as i64", .{ len, v.reg, STR_LEN_OFF });
                try self.track(len);
                const box = try self.nextTmp();
                try self.line("{s} = alloc {d}", .{ box, STR_BOX_SIZE });
                try self.track(box);
                try self.markStrReg(box);
                try self.line("store {s}+{d}, {s} as ptr", .{ box, STR_DATA_OFF, data });
                try self.line("store {s}+{d}, {s} as i64", .{ box, STR_LEN_OFF, len });
                // LIFO: the two loads borrow the field, the box is derived from
                // them, so release in reverse creation order.
                try self.releaseReg(len);
                try self.releaseReg(data);
                return .{ .reg = box, .ty = v.ty, .str_form = .boxed };
            },
        }
    }

    /// Write the `[data, len]` pair a string value denotes at address `dst`.
    ///
    /// Every form is written as two words, because a one-word store would leave
    /// the length undefined for whoever reads the destination back. A `const_text`
    /// value needs no temporary at all, which is why a struct field costs nothing.
    fn emitStrInto(self: *Lowerer, dst: []const u8, v: Value) Error!void {
        switch (v.str_form orelse .const_text) {
            .const_text => {
                try self.line("store {s}+{d}, &{s} as ptr", .{ dst, STR_DATA_OFF, v.reg });
                try self.line("store {s}+{d}, {d} as i64", .{ dst, STR_LEN_OFF, self.constLenOf(v.reg) orelse 0 });
            },
            .at_addr => {
                const data = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as ptr", .{ data, v.reg, STR_DATA_OFF });
                try self.track(data);
                const len = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as i64", .{ len, v.reg, STR_LEN_OFF });
                try self.track(len);
                try self.line("store {s}+{d}, {s} as ptr", .{ dst, STR_DATA_OFF, data });
                try self.line("store {s}+{d}, {s} as i64", .{ dst, STR_LEN_OFF, len });
                try self.releaseReg(data);
                try self.releaseReg(len);
            },
            .boxed => {
                // SA cannot duplicate an owned block, so the words are copied and
                // the source keeps its box. For an immutable `&str` that alias is
                // sound: nothing can write through it, and the source is released
                // only at its own scope exit.
                const data = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as ptr", .{ data, v.reg, STR_DATA_OFF });
                try self.track(data);
                const len = try self.nextTmp();
                try self.line("{s} = load {s}+{d} as i64", .{ len, v.reg, STR_LEN_OFF });
                try self.track(len);
                try self.line("store {s}+{d}, {s} as ptr", .{ dst, STR_DATA_OFF, data });
                try self.line("store {s}+{d}, {s} as i64", .{ dst, STR_LEN_OFF, len });
                try self.releaseReg(data);
                try self.releaseReg(len);
            },
        }
    }

    /// Store one aggregate field, routing a `&str` through the two-word form.
    fn emitFieldStore(self: *Lowerer, base: []const u8, off: []const u8, v: Value, width: []const u8) Error!void {
        if (try self.isStrValue(v)) {
            // The field address is taken first, because `base+Tag_label+0` does
            // not survive SA's address parser: a layout `#def` offset already
            // carries its own sign (`Tag_label = +0`), and folding that with the
            // extra `+0` produced `0+0`. One `+` per address is the rule.
            const addr = try self.nextTmp();
            try self.line("{s} = ptr_add {s}, {s}", .{ addr, base, off });
            try self.track(addr);
            try self.emitStrInto(addr, v);
            // The field address borrows `base`, so it goes before `base` does.
            try self.releaseReg(addr);
            return;
        }
        const at = try std.fmt.allocPrint(self.allocator, "{s}+{s}", .{ base, off });
        try self.line("store {s}, {s} as {s}", .{ at, v.reg, width });
        if (!v.immediate) self.untrack(v.reg);
    }

    /// `dst = load addr+0 as T`. The explicit `+0` is required: SA's address
    /// parser splits on the first `+` and rejects a bare register.
    fn emitLoad(self: *Lowerer, dst: []const u8, addr: []const u8, ty: ?*ast.Node) Error!void {
        try self.line("{s} = load {s}+0 as {s}", .{ dst, addr, try self.loadWidth(ty) });
    }

    /// Emit a non-consuming copy of `src` into `dst`.
    ///
    /// `dst = src` would move `src` in SA, so a Rust copy is expressed as an
    /// arithmetic identity. This mirrors the reference compiler, which emits
    /// `tmp = add n, 0` rather than a bare register copy.
    fn emitCopy(self: *Lowerer, dst: []const u8, src: []const u8, ty: ?*ast.Node) Error!void {
        if (std.mem.eql(u8, dst, src)) return;
        // A `bool` is `i1` and a pointer is not an integer: `add` would be
        // ill-typed or would corrupt the pointer, so re-derive through memory
        // instead of pretending arithmetic works.
        const s = self.scalarOf(ty);
        if (s == .bool) {
            const slot = try self.nextTmp();
            try self.line("{s} = stack_alloc 8", .{slot});
            try self.track(slot);
            try self.line("store {s}+0, {s} as i1", .{ slot, src });
            try self.emitLoad(dst, slot, ty);
            try self.releaseReg(slot);
            return;
        }
        if (ty != null and self.scalarOf(ty) == null) {
            // Unknown nominal type: assume pointer-shaped and copy via memory.
            const slot = try self.nextTmp();
            try self.line("{s} = stack_alloc 8", .{slot});
            try self.track(slot);
            try self.line("store {s}+0, {s} as ptr", .{ slot, src });
            try self.emitLoad(dst, slot, ty);
            try self.releaseReg(slot);
            return;
        }
        const op: []const u8 = if (self.floatOf(ty)) "fadd" else "add";
        try self.line("{s} = {s} {s}, 0", .{ dst, op, src });
    }

    fn nextLabel(self: *Lowerer, comptime prefix: []const u8) Error![]const u8 {
        self.label += 1;
        return std.fmt.allocPrint(self.allocator, "L_" ++ prefix ++ "_{d}", .{self.label});
    }

    // -- live set -----------------------------------------------------------

    fn track(self: *Lowerer, reg: []const u8) Error!void {
        if (reg.len == 0) return;
        for (self.live.items) |r| {
            if (std.mem.eql(u8, r, reg)) return;
        }
        try self.live.append(reg);
    }

    fn untrack(self: *Lowerer, reg: []const u8) void {
        var i: usize = 0;
        while (i < self.live.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.live.items[i], reg)) {
                _ = self.live.orderedRemove(i);
                return;
            }
        }
    }

    fn isLive(self: *const Lowerer, reg: []const u8) bool {
        for (self.live.items) |r| {
            if (std.mem.eql(u8, r, reg)) return true;
        }
        return false;
    }

    /// Copy the live set so a branch can restore it for each arm.
    ///
    /// `releaseAll` drains the set, so the second arm would otherwise start from
    /// an empty set and the phi-join at the merge label would see disagreeing
    /// live states.
    fn snapshotLive(self: *Lowerer) Error![][]const u8 {
        return try self.allocator.dupe([]const u8, self.live.items);
    }

    fn restoreLive(self: *Lowerer, snapshot: []const []const u8) Error!void {
        // An allocation failure here would leave a wrong live set, and a wrong
        // live set miscompiles silently; propagate instead of swallowing.
        self.live.clearRetainingCapacity();
        try self.live.appendSlice(snapshot);
    }

    /// The live set a branch arm must leave behind: the registers that were live
    /// *before* the branch, plus the result block the arm fills in.
    ///
    /// The distinction is load-bearing. Releasing "everything except the result
    /// block" also releases the enclosing scope's variables, which are then read
    /// after the merge: `let a = ..; let b = if a > 0 {..} else {..}; use(a)`
    /// freed `a` at the end of the first arm and trapped with `UseAfterMove`.
    /// An arm owns only what it created, so that is all it releases.
    fn armKeep(self: *Lowerer, outer: []const []const u8, dst: ?[]const u8) Error![][]const u8 {
        var keep: std.ArrayList([]const u8) = .init(self.allocator);
        errdefer keep.deinit();
        try keep.appendSlice(outer);
        if (dst) |d| try keep.append(d);
        return keep.toOwnedSlice();
    }

    /// Release every tracked register that is *not* in `keep`, by name.
    ///
    /// This is deliberately name-based rather than index-based: `untrack` uses
    /// `orderedRemove`, which shifts the list and invalidates any index captured
    /// earlier. An index-based "release everything created inside the loop" would
    /// therefore release the wrong set as soon as a `let` inside the body
    /// untracked a temporary -- silently miscompiling, not trapping.
    fn releaseAllExceptSet(self: *Lowerer, keep: []const []const u8) Error!void {
        // Newest first. A derived pointer (`tmp = ptr_add base, off`) borrows
        // from `base`, so releasing `base` first would leave the derived
        // register dangling and the Referee reports `UseAfterMove`.
        var i: usize = self.live.items.len;
        while (i > 0) {
            i -= 1;
            const reg = self.live.items[i];
            var keep_it = false;
            for (keep) |k| {
                if (std.mem.eql(u8, k, reg)) keep_it = true;
            }
            if (keep_it) continue;
            try self.line("!{s}", .{reg});
            _ = self.live.orderedRemove(i);
        }
    }

    /// True when both live sets hold exactly the same register names.
    fn liveSetsEqual(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a) |reg| {
            var found = false;
            for (b) |other| {
                if (std.mem.eql(u8, reg, other)) found = true;
            }
            if (!found) return false;
        }
        return true;
    }

    /// Release a single tracked register with `!`.
    ///
    /// Only needed when a value is *moved into a destination* (an aggregate
    /// rebind) -- plain reads leave the register live for the scope exit to
    /// drain, exactly like the SA reference compiler.
    fn releaseReg(self: *Lowerer, reg: []const u8) Error!void {
        if (reg.len == 0) return;
        if (!self.isLive(reg)) return;
        try self.line("!{s}", .{reg});
        self.untrack(reg);
    }

    /// Emit `!reg` for every tracked register except `keep`, then clear the set.
    /// Release everything except `extra`.
    fn releaseAllKeeping(self: *Lowerer, extra: []const []const u8) Error!void {
        return self.releaseAll(extra);
    }

    /// Build the `Pair<i32>` style type node for a generic struct literal.
    fn structArgsType(
        self: *Lowerer,
        name: []const u8,
        tpl: TypeDef,
        se: ast.StructExpr,
    ) Error!?*ast.Node {
        const si: ?ast.StructItem = switch (tpl.node.*) {
            .struct_item => |x| x,
            else => null,
        };
        const s = si orelse return null;
        const params = try monomorph.typeParamNames(s.generics, self.allocator);
        if (params.len == 0) return null;

        var subst: std.StringHashMapUnmanaged(*ast.Node) = .empty;
        defer subst.deinit(self.allocator);
        for (s.fields) |f| {
            for (se.fields) |given| {
                if (!std.mem.eql(u8, f.name, given.name)) continue;
                const actual = try self.inferTypeOf(given.value) orelse continue;
                try self.bindTypeParams(f.ty, actual, params, &subst);
            }
        }
        if (subst.count() == 0) return null;

        const args = try self.allocator.alloc(ast.GenericArg, params.len);
        for (params, 0..) |pname, i| args[i] = .{ .ty = subst.get(pname) orelse return null };
        const segs = try self.allocator.alloc(ast.PathSegment, 1);
        segs[0] = .{ .name = name, .args = args };
        const n = try self.allocator.create(ast.Node);
        n.* = .{ .ty_path = .{ .segments = segs } };
        return n;
    }

    /// The name a struct literal actually builds.
    ///
    /// For a generic struct the field initialisers pin the type arguments down
    /// (`Pair { a: 1 }` is `Pair<i32>`), so the literal has to be resolved to an
    /// instance before any layout is looked up. A non-generic struct, or one
    /// whose arguments cannot be inferred, resolves to its own name.
    fn concreteTypeName(self: *Lowerer, s: ast.StructExpr) Error!?[]const u8 {
        const name = pathLeaf(s.path);
        if (self.types.get(name) != null) return name;
        const tpl = self.generic_types.get(name) orelse return name;
        _ = self.inferStructArgs(name, tpl, s) catch null;
        // `nominalOf` maps `Pair<i32>` onto the interned instance name, and
        // interning it here means the layout is available.
        return try self.nominalOf(self.structArgsType(name, tpl, s) catch null);
    }

    /// The literal's own type, keeping the generic arguments visible.
    ///
    /// The value's type is stored in `var_types`, and a later call site needs to
    /// read `Pair<i32>` -- not `Pair__I32` -- to match it against a declared
    /// `Pair<T>` and bind that function's `T`.
    fn literalTypeNode(self: *Lowerer, s: ast.StructExpr) Error!?*ast.Node {
        const name = pathLeaf(s.path);
        if (self.types.get(name) != null) return self.typeFor(name);
        const tpl = self.generic_types.get(name) orelse return self.typeFor(name);
        if (try self.structArgsType(name, tpl, s)) |n| return n;
        return self.typeFor(name);
    }

    /// Infer a generic struct's type arguments from the field initialisers of a
    /// struct literal, and return the concrete instance name.
    ///
    /// Returns null when the arguments cannot be pinned down, which leaves the
    /// type uninstantiated and therefore pointer-like rather than wrong.
    fn inferStructArgs(
        self: *Lowerer,
        name: []const u8,
        tpl: TypeDef,
        se: ast.StructExpr,
    ) Error!?[]const u8 {
        const template: ?ast.StructItem = switch (tpl.node.*) {
            .struct_item => |si| si,
            else => null,
        };
        const si = template orelse return null;
        const params = try monomorph.typeParamNames(si.generics, self.allocator);
        if (params.len == 0) return null;

        var subst: std.StringHashMapUnmanaged(*ast.Node) = .empty;
        defer subst.deinit(self.allocator);
        for (si.fields) |f| {
            for (se.fields) |given| {
                if (!std.mem.eql(u8, f.name, given.name)) continue;
                const actual = try self.inferTypeOf(given.value) orelse continue;
                try self.bindTypeParams(f.ty, actual, params, &subst);
            }
        }
        if (subst.count() == 0) return null;

        // Re-emit the bound arguments in declaration order so the mangled name
        // does not depend on which field was seen first.
        const args = try self.allocator.alloc(ast.GenericArg, params.len);
        for (params, 0..) |pname, i| {
            args[i] = .{ .ty = subst.get(pname) orelse return null };
        }
        return self.resolveTypeInstance(name, args);
    }

    /// Bind this function's type parameters by matching a declared parameter
    /// type against the type actually passed.
    ///
    /// Two shapes matter: a bare parameter (`x: T`) and a parameter naming a
    /// generic type (`x: Pair<T>`), where the concrete argument arrives as
    /// `Pair<i32>` and the binding comes from the argument list.
    fn bindFromTypes(
        self: *Lowerer,
        declared: *ast.Node,
        actual: *ast.Node,
        params: []const []const u8,
        out: *std.ArrayList(?*ast.Node),
    ) Error!void {
        const d = ast.unparen(declared);
        switch (d.*) {
            .ty_path => |dp| {
                if (dp.segments.len == 0) return;
                const dseg = dp.segments[dp.segments.len - 1];
                for (params, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, dseg.name)) {
                        if (out.items[k] == null) out.items[k] = ast.unparen(actual);
                        return;
                    }
                }
                if (dseg.args.len == 0) return;
                const a = ast.unparen(actual);
                if (a.* != .ty_path) return;
                const aseg = a.ty_path.segments;
                if (aseg.len == 0) return;
                const aseg_tail = aseg[aseg.len - 1];
                if (aseg_tail.args.len != dseg.args.len) return;
                for (dseg.args, aseg_tail.args) |da, aa| {
                    if (da != .ty or aa != .ty) continue;
                    try self.bindFromTypes(da.ty, aa.ty, params, out);
                }
            },
            .ty_ref => |r| try self.bindFromTypes(r.inner, actual, params, out),
            .ty_ptr => |p| try self.bindFromTypes(p.inner, actual, params, out),
            .ty_array => |a| try self.bindFromTypes(a.elem, actual, params, out),
            .ty_slice => |sl| try self.bindFromTypes(sl.elem, actual, params, out),
            else => {},
        }
    }

    /// Bind the type parameters named in `params` that appear in `declared` to
    /// the corresponding parts of `actual`.
    fn bindTypeParams(
        self: *Lowerer,
        declared: *ast.Node,
        actual: *ast.Node,
        params: []const []const u8,
        subst: *std.StringHashMapUnmanaged(*ast.Node),
    ) Error!void {
        const d = ast.unparen(declared);
        switch (d.*) {
            .ty_path => |tp| {
                if (tp.segments.len != 1) return;
                const pname = tp.segments[0].name;
                for (params) |pn| {
                    if (std.mem.eql(u8, pn, pname)) {
                        try subst.put(self.allocator, pname, actual);
                        return;
                    }
                }
            },
            .ty_ref => |r| try self.bindTypeParams(r.inner, actual, params, subst),
            .ty_ptr => |p| try self.bindTypeParams(p.inner, actual, params, subst),
            .ty_array => |a| try self.bindTypeParams(a.elem, actual, params, subst),
            .ty_slice => |sl| try self.bindTypeParams(sl.elem, actual, params, subst),
            else => {},
        }
    }

    /// Resolve a type use that carries generic arguments (`Pair<i32>`) to the
    /// concrete instance name, building the instance on first use.
    ///
    /// Returns `name` unchanged for a non-generic type or a bare generic name
    /// with no arguments: an uninstantiated template has no layout, and
    /// treating it as pointer-like is the conservative answer.
    fn resolveTypeInstance(
        self: *Lowerer,
        name: []const u8,
        args: []const ast.GenericArg,
    ) Error!?[]const u8 {
        if (self.generic_types.count() == 0) return name;
        if (self.types.get(name) != null) return name;
        const tpl = self.generic_types.get(name) orelse return name;

        var type_args: std.ArrayList(?*ast.Node) = .init(self.allocator);
        defer type_args.deinit();
        for (args) |ga| switch (ga) {
            .ty => |t| try type_args.append(t),
            else => try type_args.append(null),
        };

        const mangle = self.type_planner.intern(name, type_args.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InstanceLimitExceeded => return null,
        };

        // Only build the struct once; a second use reuses the registered one.
        if (self.types.get(mangle) == null) {
            const params = try monomorph.typeParamNames(tpl.node.*.struct_item.generics, self.allocator);
            var subst: std.StringHashMapUnmanaged(*ast.Node) = .empty;
            defer subst.deinit(self.allocator);
            for (params, 0..) |pname, i| {
                if (i >= type_args.items.len) break;
                if (type_args.items[i]) |t| try subst.put(self.allocator, pname, t);
            }
            const built = switch (tpl.node.*) {
                .struct_item => |si| monomorph.instantiateStruct(self.allocator, mangle, si, &subst) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InstanceLimitExceeded => return error.Unsupported,
                },
                .enum_item => |ei| monomorph.instantiateEnum(self.allocator, mangle, ei, &subst) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InstanceLimitExceeded => return error.Unsupported,
                },
                else => return name,
            };
            try self.types.put(self.allocator, mangle, .{ .name = mangle, .node = built });
        }
        _ = try self.typeFor(mangle);
        return mangle;
    }

    /// Release every live register except `keep`, newest first.
    fn releaseAll(self: *Lowerer, keep: []const []const u8) Error!void {
        return self.releaseAllExceptSet(keep);
    }

    // -- names --------------------------------------------------------------

    /// Rust name of a path expression's last segment.
    fn pathLeaf(segments: []const ast.PathSegment) []const u8 {
        if (segments.len == 0) return "";
        return segments[segments.len - 1].name;
    }

    /// Map a type node through the active substitution.
    ///
    /// Inside a monomorphised instance a type parameter (`T`) stands for the
    /// concrete type it was instantiated with. Every ABI and layout decision has
    /// to see the *concrete* type, otherwise the callee contract and the call
    /// site disagree about whether a value is a pointer.
    fn resolveTy(self: *Lowerer, ty: ?*ast.Node) Error!?*ast.Node {
        const t = ty orelse return null;
        if (self.active_subst.count() == 0) return t;
        switch (ast.unparen(t).*) {
            .ty_path => |tp| {
                if (tp.segments.len == 0) return t;
                const last = tp.segments[tp.segments.len - 1];
                // `T` on its own.
                if (self.active_subst.get(last.name)) |concrete| return concrete;
                // A parameter nested in a generic type's arguments, `Pair<T>`.
                // Substituting only the leaf would miss this entirely, and the
                // instance would then be built with `T` still unresolved.
                if (last.args.len == 0) return t;
                var changed = false;
                const args = try self.allocator.alloc(ast.GenericArg, last.args.len);
                for (last.args, 0..) |ga, i| {
                    args[i] = ga;
                    if (ga != .ty) continue;
                    const sub = try self.resolveTy(ga.ty);
                    if (sub) |sn| {
                        if (!std.mem.eql(u8, monomorph.Planner.tyKey(sn), monomorph.Planner.tyKey(ga.ty))) {
                            args[i] = .{ .ty = sn };
                            changed = true;
                        }
                    }
                }
                if (!changed) return t;
                const segs = try self.allocator.alloc(ast.PathSegment, tp.segments.len);
                @memcpy(segs, tp.segments);
                segs[segs.len - 1] = .{ .name = last.name, .args = args };
                const n = try self.allocator.create(ast.Node);
                n.* = .{ .ty_path = .{ .segments = segs, .leading_colon = tp.leading_colon } };
                return n;
            },
            .ty_ref => |r| {
                const inner = try self.resolveTy(r.inner);
                if (inner == null or std.mem.eql(u8, monomorph.Planner.tyKey(inner.?), monomorph.Planner.tyKey(r.inner))) return t;
                const n = try self.allocator.create(ast.Node);
                n.* = .{ .ty_ref = .{ .inner = inner.?, .lifetime = r.lifetime, .is_mut = r.is_mut } };
                return n;
            },
            .ty_ptr => |p| {
                const inner = try self.resolveTy(p.inner);
                if (inner == null or std.mem.eql(u8, monomorph.Planner.tyKey(inner.?), monomorph.Planner.tyKey(p.inner))) return t;
                const n = try self.allocator.create(ast.Node);
                n.* = .{ .ty_ptr = .{ .inner = inner.?, .is_mut = p.is_mut, .is_const = p.is_const } };
                return n;
            },
            else => return t,
        }
    }

    /// Nominal name of a value's underlying type: refs peeled and the active
    /// substitution applied. This is what maps a value to a layout, so a
    /// borrowed generic parameter (`p: &T`) still finds `T`'s concrete layout.
    fn nominalOf(self: *Lowerer, ty: ?*ast.Node) Error!?[]const u8 {
        const t = (try self.resolveTy(peelRef(ty orelse return null))) orelse return null;
        const name = nominalName(t) orelse return null;
        if (self.generic_types.count() == 0) return name;
        // `Pair<i32>` names a concrete instance, not the template. Resolving it
        // here means the layout, the aggregate test and every field offset all
        // agree on one name.
        switch (ast.unparen(t).*) {
            .ty_path => |tp| {
                if (tp.segments.len == 0) return name;
                const last = tp.segments[tp.segments.len - 1];
                if (last.args.len == 0) return name;
                return self.resolveTypeInstance(name, last.args) catch null;
            },
            else => return name,
        }
    }

    fn nominalName(ty: ?*ast.Node) ?[]const u8 {
        if (ty) |x| return ast.typeName(x);
        return null;
    }

    fn layoutOfName(self: *Lowerer, name: []const u8) ?layout.Layout {
        // Inside a monomorphised instance a type parameter stands for its
        // concrete type, so `T.a` gets the real field offset instead of a guess.
        if (self.active_subst.count() > 0) {
            if (self.active_subst.get(name)) |concrete| {
                const target = monomorph.Planner.tyKey(concrete);
                if (std.mem.eql(u8, target, name)) return null;
                return self.layoutOfName(target);
            }
        }
        const node = self.type_nodes.get(name) orelse return null;
        return self.engine.layoutOf(name, node) catch null;
    }

    /// How a parameter crosses the function boundary.
    ///
    /// The callee signature and the call site must agree exactly: the Referee
    /// rejects a `^` prefix at the call site when the callee contract does not
    /// declare it (`CapabilityMismatch`). The two sides therefore never decide
    /// independently -- both go through this function, keyed on the *declared*
    /// parameter type only.
    ///
    /// An opaque type (a generic parameter, an unresolved alias, `Self`) is passed
    /// by plain reference: the callee does not know the layout, so it cannot
    /// legally consume the value, and a `^` would both break the contract and
    /// steal the caller's binding.
    pub const ParamCap = enum { plain, borrow, move };

    pub fn paramCapFor(self: *Lowerer, p: ast.Param) Error!ParamCap {
        // The receiver follows the same rule the signature declares, so the call
        // site and the callee contract cannot disagree about it.
        if (p.is_self) return switch (p.self_kind) {
            .by_value => .move,
            else => .borrow,
        };
        if (paramIsBorrow(p) or paramIsRef(p)) return .borrow;
        // `fn f(x: &T)` states the borrow in the type, not the pattern.
        if (p.ty) |t| {
            switch (ast.unparen(t).*) {
                .ty_ref => return .borrow,
                else => {},
            }
        }
        if (try self.isAggregate(p.ty)) return .move;
        return .plain;
    }

    /// True when the type name has no layout we can see: a generic parameter,
    /// an unresolved alias or `Self`. Builtin scalars are *not* opaque -- they
    /// resolve through `scalarFromName` rather than the layout registry.
    fn isOpaqueName(self: *Lowerer, name: []const u8) bool {
        if (layout.scalarFromName(name) != null) return false;
        if (std.mem.eql(u8, name, "str")) return false;
        if (std.mem.eql(u8, name, "bool")) return false;
        return self.layoutOfName(name) == null;
    }

    /// True when the parameter is represented by a pointer: either a known
    /// aggregate or an opaque type whose layout only the caller knows.
    fn paramIsPtrLike(self: *Lowerer, p: ast.Param) Error!bool {
        if (p.is_self) return true;
        const ty = (try self.resolveTy(p.ty)) orelse return false;
        if (try self.isAggregate(ty)) return true;
        const name = nominalName(ty) orelse return false;
        return self.isOpaqueName(name);
    }

    /// True when a value of this Rust type is represented by a pointer.
    fn isAggregate(self: *Lowerer, raw: ?*ast.Node) Error!bool {
        const ty = try self.resolveTy(raw);
        const name = try self.nominalOf(ty) orelse {
            if (ty) |x| {
                const t = ast.unparen(x);
                return switch (t.*) {
                    .ty_tuple, .ty_array, .ty_slice => true,
                    else => false,
                };
            }
            return false;
        };
        if (layout.scalarFromName(name) != null) return false;
        if (std.mem.eql(u8, name, "str")) return false;
        const l = self.layoutOfName(name) orelse return false;
        return l.shape.isAggregate();
    }

    fn scalarOf(_: *Lowerer, ty: ?*ast.Node) ?layout.Scalar {
        const name = nominalName(ty) orelse return null;
        return layout.scalarFromName(name);
    }

    /// The SA primitive name used in a signature for `ty`.
    fn saTypeName(self: *Lowerer, raw: ?*ast.Node) Error![]const u8 {
        const ty = try self.resolveTy(raw);
        if (ty) |x| {
            const s = self.scalarOf(x);
            if (s) |sc| return sc.saName();
            if (try self.isAggregate(x)) return "ptr";
            // References, raw pointers and unknown nominal types are one word.
            return "ptr";
        }
        return "void";
    }

    /// The `as T` width used by `load`/`store` for `ty`.
    fn loadWidth(self: *Lowerer, ty: ?*ast.Node) Error![]const u8 {
        if (ty) |x| {
            if (try self.isAggregate(x)) return "ptr";
            if (self.scalarOf(x)) |s| return s.saName();
        }
        return "i64";
    }

    fn unsignedOf(self: *Lowerer, ty: ?*ast.Node) bool {
        if (ty) |x| {
            if (self.scalarOf(x)) |s| return s.isUnsigned();
        }
        return false;
    }

    fn floatOf(self: *Lowerer, ty: ?*ast.Node) bool {
        if (ty) |x| {
            if (self.scalarOf(x)) |s| return s.isFloat();
        }
        return false;
    }

    // -- #def emission ------------------------------------------------------

    fn defOnce(self: *Lowerer, comptime fmt: []const u8, args: anytype) Error!void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        if (self.def_names.contains(text)) return;
        self.def_names.put(self.allocator, text, {}) catch return error.OutOfMemory;
        self.defs.writer().print("#def {s}\n", .{text}) catch return error.OutOfMemory;
    }

    fn emitLayoutDefs(self: *Lowerer, name: []const u8) Error!void {
        const l = (self.layoutOfName(name) orelse return);
        switch (l.shape) {
            .scalar, .opaque_handle => try self.defOnce("{s}_SIZE = {d}", .{ name, @max(l.size, 1) }),
            .fat_ptr, .growable_ptr => {
                try self.defOnce("{s}_SIZE = {d}", .{ name, l.size });
                try self.defOnce("{s}_data = +0", .{name});
                try self.defOnce("{s}_len = +8", .{name});
                if (l.shape == .growable_ptr) try self.defOnce("{s}_cap = +16", .{name});
            },
            .tagged_union => {
                try self.defOnce("{s}_SIZE = {d}", .{ name, l.size });
                try self.defOnce("{s}_tag = +0", .{name});
                for (l.variants) |v| {
                    try self.defOnce("{s}_{s} = {d}", .{ name, v.name, v.tag });
                    for (v.fields) |f| {
                        try self.defOnce("{s}_{s}_{s} = +{d}", .{ name, v.name, f.name, f.offset });
                    }
                }
            },
            .union_ => {
                try self.defOnce("{s}_SIZE = {d}", .{ name, l.size });
                for (l.fields) |f| try self.defOnce("{s}_{s} = +0", .{ name, f.name });
            },
            .record => {
                try self.defOnce("{s}_SIZE = {d}", .{ name, @max(l.size, 1) });
                for (l.fields) |f| {
                    try self.defOnce("{s}_{s} = +{d}", .{ name, f.name, f.offset });
                }
            },
        }
    }

    fn emitAllLayoutDefs(self: *Lowerer) Error!void {
        var it = self.types.iterator();
        while (it.next()) |entry| try self.emitLayoutDefs(entry.key_ptr.*);
    }

    /// Write the preamble into `out`, which is the header buffer rather than the
    /// body buffer: imports have to precede every function.
    fn emitImports(self: *Lowerer, out: *std.ArrayList(u8)) Error!void {
        if (self.options.emit_header) {
            try out.appendSlice("// Generated by sa_plugin_rust. Do not edit.\n");
        }
        try out.appendSlice("@import \"sa_std/io/print.sai\"\n");
        try out.appendSlice("@import \"sa_std/fmt.sai\"\n");
        try out.append('\n');
    }

    // -- collection ---------------------------------------------------------

    fn collect(self: *Lowerer, node: *ast.Node) Error!void {
        switch (node.*) {
            .program => |p| for (p.items) |it| try self.collect(it),
            .struct_item => |s| {
                if (s.generics.arity() > 0) {
                    try self.generic_types.put(self.allocator, s.name, .{ .name = s.name, .node = node });
                    return;
                }
                try self.types.put(self.allocator, s.name, .{ .name = s.name, .node = node });
            },
            .enum_item => |e| {
                if (e.generics.arity() > 0) {
                    try self.generic_types.put(self.allocator, e.name, .{ .name = e.name, .node = node });
                    return;
                }
                try self.types.put(self.allocator, e.name, .{ .name = e.name, .node = node });
            },
            .union_item => |u| try self.types.put(self.allocator, u.name, .{ .name = u.name, .node = node }),
            .type_alias => |ta| try self.types.put(self.allocator, ta.name, .{ .name = ta.name, .node = node }),
            .const_item => |ci| {
                if (ci.value) |v| {
                    if (layout.constIntOf(v)) |n| {
                        try self.int_consts.put(self.allocator, ci.name, n);
                    }
                }
            },
            .fn_item => |f| {
                // A generic body is lowered once per concrete instantiation, so
                // it is registered as a template and emitted on demand.
                if (f.generics.arity() > 0) {
                    if (self.current_impl == null)
                        try self.templates.put(self.allocator, f.name, f);
                    return;
                }
                const sa_name = if (self.current_impl) |owner|
                    std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, f.name }) catch return error.OutOfMemory
                else
                    f.name;
                try self.functions.append(.{
                    .sa_name = sa_name,
                    .rust_name = f.name,
                    .params = f.params,
                    .ret = f.ret,
                    .body = f.body,
                    .is_test = ast.hasAttr(f.attrs, "test"),
                    .is_extern = f.abi != null and f.body == null,
                    .abi = f.abi,
                    .self_type = if (self.current_impl != null) self.im_self_ty else null,
                    .pos = f.pos,
                });
            },
            .impl_item => |im| {
                const self_name = ast.typeName(im.self_ty) orelse "Self";
                const owner = if (self.current_impl) |outer|
                    std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ outer, self_name }) catch return error.OutOfMemory
                else
                    self_name;
                self.current_impl = owner;
                self.im_self_ty = im.self_ty;
                for (im.items) |it| try self.collect(it);
                self.current_impl = null;
            },
            .mod_item => |m| {
                if (m.items) |items| for (items) |it| try self.collect(it);
            },
            .extern_block => |eb| for (eb.items) |it| try self.collect(it),
            else => {},
        }
    }

    fn findFn(self: *Lowerer, name: []const u8) ?*const FnSig {
        for (self.functions.items) |*f| {
            if (std.mem.eql(u8, f.rust_name, name)) return f;
            if (std.mem.eql(u8, f.sa_name, name)) return f;
        }
        return null;
    }

    // -- function emission --------------------------------------------------

    /// Record a construct the lowering refused.
    ///
    /// Every one of these sites used to bump a bare counter and emit a zero,
    /// which is the worst failure mode for a compiler: the program builds and
    /// runs, and is quietly wrong. The reason is kept so the CLI can name it.
    fn note(self: *Lowerer, reason: []const u8) void {
        self.unsupported += 1;
        for (self.unsupported_notes.items) |existing| {
            if (std.mem.eql(u8, existing, reason)) return;
        }
        self.unsupported_notes.append(reason) catch {};
    }

    /// Record the refusal of `node`, naming its shape for the diagnostic.
    fn noteNode(self: *Lowerer, node: *ast.Node) void {
        self.note(nodeKind(node));
    }

    /// Emit a `#loc "file":line:col` hint, or nothing when the position is
    /// unknown or hints are switched off.
    ///
    /// SA attaches the hint to the *next* instruction, and rejects a zero line or
    /// column outright (`InvalidLocHint`), so a position that was never recorded
    /// is skipped rather than emitted as `0:0`. Repeated hints on the same line
    /// are collapsed: one statement can lower to a dozen instructions, and a hint
    /// per instruction would triple the output for no extra information.
    fn emitLoc(self: *Lowerer, pos: ast.SrcPos) Error!void {
        if (!self.options.emit_source_map) return;
        if (pos.line == 0 or pos.col == 0) return;
        if (pos.line == self.last_loc_line and pos.col == self.last_loc_col) return;
        self.last_loc_line = pos.line;
        self.last_loc_col = pos.col;
        try self.w("#loc \"{s}\":{d}:{d}\n", .{ self.options.source_name, pos.line, pos.col });
    }

    fn emitFunction(self: *Lowerer, f: FnSig) Error!void {
        if (f.is_extern) {
            // A `#loc` before a declaration is read as that declaration's
            // `upstream_loc`, so it goes ahead of the signature, not the body.
            try self.emitLoc(f.pos);
            // Foreign functions are `@extern` declarations, no body.
            try self.w("@extern {s}(", .{f.sa_name});
            for (f.params, 0..) |p, i| {
                if (i > 0) try self.w(", ", .{});
                const cap: []const u8 = if (paramIsBorrow(p)) "&" else if (paramIsRef(p)) "&" else "";
                try self.w("{s}{s}: {s}", .{ cap, paramName(p), try self.saTypeName(p.ty) });
            }
            try self.w(")", .{});
            if (f.ret) |r| try self.w(" -> {s}", .{try self.saTypeName(r)});
            try self.w("\n\n", .{});
            return;
        }
        const body = f.body orelse return;

        // Signature. The hint goes first so the `@fn` line itself is attributed.
        try self.emitLoc(f.pos);
        try self.w("@{s}(", .{f.sa_name});
        for (f.params, 0..) |p, i| {
            if (i > 0) try self.w(", ", .{});
            if (p.is_self) {
                // `&self` / `&mut self` borrow; `self` moves the block in.
                const cap: []const u8 = if (p.self_kind == .by_value) "^" else "&";
                try self.w("{s}self: ptr", .{cap});
            } else {
                const cap: []const u8 = switch (try self.paramCapFor(p)) {
                    .move => "^",
                    .borrow => "&",
                    .plain => "",
                };
                const ty: []const u8 = if (try self.paramIsPtrLike(p)) "ptr" else try self.saTypeName(p.ty);
                try self.w("{s}{s}: {s}", .{ cap, paramName(p), ty });
            }
        }
        try self.w(")", .{});
        if (f.ret) |r| {
            const agg = try self.isAggregate(r);
            const cap: []const u8 = if (agg) "^" else "";
            try self.w(" -> {s}{s}", .{ cap, if (agg) "ptr" else try self.saTypeName(r) });
        }
        try self.w(":\n", .{});
        try self.w("L_ENTRY:\n", .{});

        // The live set is per function.
        self.live.clearRetainingCapacity();
        // A hint belongs to the function it precedes, so the dedup starts over.
        self.last_loc_line = 0;
        self.last_loc_col = 0;
        // Parameters enter the live set, except borrowed ones: a `&T` argument
        // stays owned by the caller, so releasing it here would consume a value
        // this function never owned.
        self.borrowed_params.clearRetainingCapacity();
        for (f.params) |p| {
            const name = if (p.is_self) "self" else paramName(p);
            try self.track(name);
            const borrowed_param = if (p.is_self)
                p.self_kind != .by_value
            else
                try self.paramCapFor(p) == .borrow;
            if (borrowed_param) try self.borrowed_params.append(name);
            // A `self` parameter carries no type node, so fall back to the
            // receiver type of the enclosing `impl`. Without it `self.n = ...`
            // cannot resolve the field and rebinds the `self` register instead
            // of storing into the struct.
            if (p.ty) |t| {
                try self.var_types.put(self.allocator, name, t);
            } else if (p.is_self) {
                if (f.self_type) |st| try self.var_types.put(self.allocator, name, st);
            }
        }
        if (f.params.len > 0 and f.params[0].is_self) self.self_reg = "self";

        self.returns_fallible = f.ret != null and blk: {
            const n = try self.nominalOf(f.ret.?) orelse break :blk false;
            break :blk std.mem.eql(u8, n, "Result");
        };
        self.fn_done = false;

        try self.lowerBlockStmts(body.block_expr.stmts, body.block_expr.value);

        if (!self.fn_done) {
            try self.releaseAll(self.borrowed_params.items);
            try self.line("return", .{});
        }
        self.self_reg = null;
        self.var_types.clearRetainingCapacity();
        try self.blank();
    }

    fn emitTestWrapper(self: *Lowerer, f: FnSig) Error!void {
        try self.w("@test \"{s}\"():\n", .{f.rust_name});
        self.label += 1;
        try self.w("L_TEST_ENTRY_{d}:\n", .{self.label});
        try self.line("call @{s}()", .{f.sa_name});
        try self.line("return", .{});
        try self.blank();
    }

    // -- blocks and statements ---------------------------------------------

    fn lowerBlockStmts(self: *Lowerer, stmts: []const *ast.Node, value: ?*ast.Node) Error!void {
        // A nested block may be a `let` initialiser; it must not inherit the
        // enclosing binding's destination register.
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        // Shadowing is block-scoped: the names a block rebinds stop meaning
        // anything once it ends, so the enclosing names are restored.
        const saved_shadow = self.shadow;
        self.shadow = .empty;
        defer self.shadow = saved_shadow;
        for (stmts) |s| {
            // A `return`/`break`/`continue` already emitted its terminator.
            if (self.fn_done) return;
            try self.lowerStmt(s);
        }
        if (!self.fn_done) {
            if (value) |v| {
                self.value_pos = true;
                defer self.value_pos = false;
                const val = try self.lowerExpr(v);
                try self.emitReturnFrom(val);
            } else if (self.returns_fallible) {
                try self.releaseAll(self.borrowed_params.items);
                try self.line("return 0", .{});
                self.fn_done = true;
            }
        }
    }

    fn lowerStmt(self: *Lowerer, node: *ast.Node) Error!void {
        // A hint is emitted before the statement's first instruction, never before
        // a label: SA reads a hint as belonging to the next *instruction*, and a
        // label in between would leave it pending for an unrelated line.
        if (!self.fn_done) try self.emitLoc(stmtPos(node));
        switch (node.*) {
            .empty_stmt => {},
            .expr_stmt => |es| {
                const v = try self.lowerExpr(es.expr);
                if (v.reg.len > 0) self.untrack(v.reg);
            },
            .let_stmt => |ls| try self.lowerLet(ls),
            .item_stmt => {}, // nested items are hoisted during `collect`
            else => {
                const v = try self.lowerExpr(node);
                if (v.reg.len > 0) self.untrack(v.reg);
            },
        }
    }

    fn lowerLet(self: *Lowerer, ls: ast.LetStmt) Error!void {
        // `let` of a non-identifier pattern is destructuring; only the
        // identifier case is lowered directly.
        const name: []const u8 = switch (ls.pat.*) {
            .pat_ident => |pi| blk: {
                if (pi.sub != null) break :blk "";
                break :blk pi.name;
            },
            else => "",
        };
        const source = ls.init orelse return;
        if (name.len == 0) return self.lowerLetDestructure(ls);

        // A `let` that shadows an outer binding of the same name gets its own
        // register. Assigning to the shared one would destroy the outer value,
        // and the outer name would read the inner one after the block.
        const bound_name = try self.freshBinding(name);

        // Let the expression write straight into the binding when it can.
        const saved_dest = self.pending_dest;
        const saved_taken = self.dest_taken;
        self.pending_dest = bound_name;
        self.dest_taken = false;
        // The initialiser is in value position: a `match` or `if` there has to
        // produce something to bind. Without this it lowered as a statement, left
        // no value, and `let x = match n { .. };` emitted a bare `x = `.
        self.value_pos = true;
        defer self.value_pos = false;
        var val = try self.lowerExpr(source);
        // A `&str` binding has to *be* a value, so a literal becomes a box here --
        // while the destination is still on offer, so the box lands in the binding
        // instead of a temporary that would then have to be moved.
        if (try self.isStrValue(val)) val = try self.strAsBox(val);
        self.pending_dest = saved_dest;
        self.dest_taken = saved_taken;

        const var_ty = ls.ty orelse val.ty orelse (try self.inferTypeOf(source));

        if (try self.isAggregate(var_ty)) {
            // The expression already produced a heap block; bind it by move.
            if (!std.mem.eql(u8, val.reg, bound_name)) try self.rename(val.reg, bound_name);
            try self.track(bound_name);
            if (var_ty) |vt| try self.var_types.put(self.allocator, bound_name, vt);
            return;
        }

        // A `&str` box is a heap block that cannot be duplicated, so the binding
        // *takes* the box: `dst = src` is a move in SA, which is exactly the
        // ownership transfer Rust's `let` performs. (Re-pointing the live set
        // instead would leave later uses naming a register that was never
        // emitted -- the same trap `bindPatternFields` documents.)
        if (try self.isStrValue(val)) {
            if (!std.mem.eql(u8, val.reg, bound_name)) {
                try self.line("{s} = {s}", .{ bound_name, val.reg });
                self.untrack(val.reg);
            }
            try self.markStrReg(bound_name);
            try self.track(bound_name);
            if (var_ty) |vt| try self.var_types.put(self.allocator, bound_name, vt);
            return;
        }

        if (val.is_memory and !try self.isAggregate(var_ty)) {
            try self.emitLoad(bound_name, val.reg, var_ty);
            try self.track(bound_name);
        } else if (std.mem.eql(u8, bound_name, val.reg)) {
            try self.track(bound_name);
        } else if (val.immediate) {
            try self.line("{s} = {s}", .{ bound_name, val.reg });
            try self.track(bound_name);
        } else if (self.isLive(val.reg)) {
            // The source is a live variable: copy without consuming it.
            try self.emitCopy(bound_name, val.reg, var_ty);
            try self.track(bound_name);
        } else {
            // The source is a temporary produced for this initialiser.
            try self.line("{s} = {s}", .{ bound_name, val.reg });
            self.untrack(val.reg);
            try self.track(bound_name);
        }
        if (var_ty) |vt| try self.var_types.put(self.allocator, bound_name, vt);
    }

    /// `let <pattern> = <expr>;` where the pattern is not a plain identifier.
    ///
    /// The aggregate is already a heap block, so destructuring is just a matter of
    /// loading each field out of it into a binding of its own -- the same shape as
    /// the reference compiler's `12_destructuring` output. Nothing is copied: each
    /// bound field becomes a fresh register, and the block is released by the
    /// scope exit like any other local.
    fn lowerLetDestructure(self: *Lowerer, ls: ast.LetStmt) Error!void {
        const source = ls.init.?;
        // Whether the aggregate belongs to this statement or to an enclosing
        // binding decides who releases it. `let (a, b) = (2, 5);` allocates a
        // fresh block that dies here; `let P { x, .. } = p;` only reads `p`, which
        // the scope exit still has to release. Releasing the wrong one is either a
        // leak or a use-after-free, so it is decided from the live set rather than
        // guessed from the shape of the initialiser.
        const before = try self.snapshotLive();
        const place = try self.lowerPlace(source);
        const owned_here = !containsReg(before, place.reg);
        if (!try self.bindPattern(ls.pat, place)) {
            self.note("destructuring `let`");
            return;
        }
        // Every field address was released as it was used, so this block no longer
        // has anything borrowing it.
        if (owned_here and place.reg.len != 0) try self.releaseReg(place.reg);
    }

    /// Bind every name in `pat` out of the aggregate addressed by `place`.
    ///
    /// Returns false when the pattern needs a construct this does not model, so
    /// the caller reports it instead of binding half of it and looking complete.
    fn bindPattern(self: *Lowerer, pat: *ast.Node, place: Value) Error!bool {
        switch (ast.unparen(pat).*) {
            .pat_ident => |pi| {
                if (pi.sub != null) return false;
                const name = pi.name;
                if (name.len == 0) return true; // `_`
                const t = try self.nextTmp();
                try self.emitLoad(t, place.reg, place.ty);
                try self.track(t);
                // The name is re-pointed at the loaded register rather than the
                // load being named directly, because `freshBinding` may have to
                // rename it when it shadows an outer binding of the same name.
                if (try self.isStrValue(.{ .reg = t, .ty = place.ty })) try self.markStrReg(t);
                if (place.ty) |vt| try self.var_types.put(self.allocator, t, vt);
                if (!std.mem.eql(u8, name, t)) try self.shadow.put(self.allocator, name, t);
                return true;
            },
            .pat_tuple => |pt| {
                // A tuple pattern is positional: element `i` lives at `+i*8`.
                for (pt.elems, 0..) |sub, i| {
                    if (sub.* == .pat_rest) continue;
                    if (!try self.bindPositional(sub, place, @intCast(i * 8), self.tupleElemType(place.ty, i))) return false;
                }
                return true;
            },
            .pat_tuple_struct => |pts| {
                const name = if (pts.path.len == 0) "" else pts.path[pts.path.len - 1].name;
                return self.bindPositionalFields(pts.elems, place, name);
            },
            .pat_struct => |ps| {
                const name = if (ps.path.len == 0) "" else ps.path[ps.path.len - 1].name;
                return self.bindNamedFields(ps.fields, place, name);
            },
            .pat_ref => |pr| {
                // `let &x = place;` binds the value behind the pointer, which is
                // the place itself -- no instruction needed.
                return self.bindPattern(pr.pat, place);
            },
            .pat_wild, .pat_rest => return true,
            .pat_or => |po| {
                // Every alternative of an or-pattern binds the same names, so the
                // first is both sufficient and what the reference does. The rest
                // are only checked for agreement.
                if (po.alts.len == 0) return true;
                for (po.alts[1..]) |alt| {
                    if (!sameBoundNames(po.alts[0], alt)) return false;
                }
                return self.bindPattern(po.alts[0], place);
            },
            else => return false,
        }
    }

    /// Bind one element at a byte offset inside the aggregate at `place`.
    fn bindPositional(self: *Lowerer, sub: *ast.Node, place: Value, offset: i64, ty: ?*ast.Node) Error!bool {
        const addr = try self.nextTmp();
        try self.line("{s} = ptr_add {s}, {d}", .{ addr, place.reg, offset });
        try self.track(addr);
        const ok = try self.bindPattern(sub, .{ .reg = addr, .ty = ty, .borrowed = true });
        // LIFO: the address borrows the block, so it goes before the block does.
        try self.releaseReg(addr);
        return ok;
    }

    /// Positional binding against a tuple struct's layout.
    fn bindPositionalFields(self: *Lowerer, elems: []const *ast.Node, place: Value, name: []const u8) Error!bool {
        const l = self.layoutOfName(name) orelse return false;
        for (elems, 0..) |sub, i| {
            if (i >= l.fields.len) break;
            if (sub.* == .pat_rest) continue;
            if (!try self.bindPositional(sub, place, l.fields[i].offset, l.fields[i].ty)) return false;
        }
        return true;
    }

    /// Named binding (`S { a, b: c }`) against a struct layout.
    fn bindNamedFields(self: *Lowerer, fields: []const ast.PatField, place: Value, name: []const u8) Error!bool {
        const l = self.layoutOfName(name) orelse return false;
        for (fields) |f| {
            const field = l.fieldByName(f.name) orelse continue;
            const sub = f.pat orelse continue;
            if (sub.* == .pat_rest) continue;
            if (!try self.bindPositional(sub, place, field.offset, field.ty)) return false;
        }
        return true;
    }

    /// Element type `index` of a tuple type, if the type is known.
    fn tupleElemType(_: *Lowerer, ty: ?*ast.Node, index: usize) ?*ast.Node {
        const t = peelRef(ty orelse return null);
        const tup = switch (t.*) {
            .ty_tuple => |x| x,
            else => return null,
        };
        if (index >= tup.elems.len) return null;
        return tup.elems[index];
    }

    /// Decide which register a `let` binds.
    ///
    /// If the name is already bound in an enclosing scope, the new binding gets
    /// a fresh register and `shadow` records the mapping, so the outer binding
    /// survives and still means what it meant.
    fn freshBinding(self: *Lowerer, name: []const u8) Error![]const u8 {
        const shadowed = self.var_types.contains(name) or self.isLive(name);
        if (!shadowed) return name;
        var n: usize = 1;
        while (true) : (n += 1) {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ name, n });
            if (!self.var_types.contains(candidate) and !self.isLive(candidate)) {
                try self.shadow.put(self.allocator, name, candidate);
                return candidate;
            }
        }
    }

    /// The register a Rust name currently denotes.
    fn regOf(self: *Lowerer, name: []const u8) []const u8 {
        return self.shadow.get(name) orelse name;
    }

    /// Re-point a tracked register at a new name (used when a value is bound).
    fn rename(self: *Lowerer, from: []const u8, to: []const u8) Error!void {
        if (std.mem.eql(u8, from, to)) return;
        for (self.live.items, 0..) |r, i| {
            if (std.mem.eql(u8, r, from)) self.live.items[i] = to;
        }
    }

    fn emitReturnFrom(self: *Lowerer, raw: Value) Error!void {
        if (self.fn_done) return;
        const val = try self.materialize(raw);
        if (val.reg.len == 0 or val.kind == .unit) {
            try self.releaseAll(self.borrowed_params.items);
            try self.line("return", .{});
        } else {
            try self.releaseAllKeeping(&.{val.reg});
            try self.line("return {s}", .{val.reg});
        }
        self.fn_done = true;
    }

    // -- expressions --------------------------------------------------------

    fn lowerExpr(self: *Lowerer, node: *ast.Node) Error!Value {
        switch (node.*) {
            .literal => |l| return self.lowerLiteral(l),
            .paren_expr => |pe| return self.lowerExpr(pe.inner),
            .path_expr => |pe| return self.lowerPath(pe),
            .unary_expr => |u| return self.lowerUnary(u),
            .binary_expr => |b| return self.lowerBinary(b),
            .assign_expr => |a| return self.lowerAssign(a),
            .assign_op_expr => |a| return self.lowerAssignOp(a),
            .call_expr => |c| return self.lowerCall(c),
            .field_expr => |f| return self.lowerField(f),
            .method_call_expr => |mc| return self.lowerMethodCall(mc),
            .index_expr => |ix| return self.lowerIndex(ix),
            .block_expr => |b| {
                try self.lowerBlockStmts(b.stmts, b.value);
                return Value.unitValue();
            },
            .if_expr => |i| return self.lowerIf(i),
            .while_expr => |wh| return self.lowerWhile(wh),
            .for_expr => |fe| return self.lowerFor(fe),
            .loop_expr => |lp| return self.lowerLoop(lp),
            .return_expr => |r| {
                const v = if (r.value) |x| try self.lowerExpr(x) else Value.unitValue();
                try self.emitReturnFrom(v);
                return Value.unitValue();
            },
            .break_expr => |b| {
                if (b.value) |x| {
                    const v = try self.lowerExpr(x);
                    if (self.loops.items.len > 0) {
                        const top = &self.loops.items[self.loops.items.len - 1];
                        if (top.result_reg) |dst| {
                            try self.emitStoreInto(dst, v, false);
                        }
                    }
                }
                if (self.loops.items.len > 0) {
                    const top = self.loops.items[self.loops.items.len - 1];
                    try self.releaseAll(self.borrowed_params.items);
                    try self.line("jmp {s}", .{top.break_label});
                }
                return Value.unitValue();
            },
            .continue_expr => {
                if (self.loops.items.len > 0) {
                    const top = self.loops.items[self.loops.items.len - 1];
                    try self.releaseAll(self.borrowed_params.items);
                    try self.line("jmp {s}", .{top.continue_label});
                }
                return Value.unitValue();
            },
            .struct_expr => |s| return self.lowerStructLiteral(s),
            .tuple_expr => |t| return self.lowerTuple(t),
            .array_expr => |a| return self.lowerArray(a),
            .cast_expr => |c| return self.lowerCast(c),
            .borrow_expr => |b| return self.lowerBorrow(b),
            .deref_expr => |d| return self.lowerDeref(d),
            .match_expr => |m| return self.lowerMatch(m),
            .macro_expr => |m| return self.lowerMacro(m.path, m.args, m.brace_args),
            .underscore_expr => return Value.unitValue(),
            .try_expr => return self.lowerTry(node),
            else => {
                self.noteNode(node);
                const t = try self.nextTmp();
                try self.line("{s} = 0", .{t});
                try self.track(t);
                return .{ .reg = t, .ty = null };
            },
        }
    }

    fn lowerLiteral(self: *Lowerer, l: ast.Literal) Error!Value {
        switch (l) {
            .int => |iv| {
                // Emitted as its own text rather than through `i64`. A value above
                // `i64::MAX` is still a legal `u64` immediate, and routing it
                // through a signed register turned `u64::MAX` into `-1` -- or, once
                // that was caught, folded the argument to `0`. Only a literal too
                // large for `u64` at all is reported.
                const text = (try layout.intLiteralText(self.allocator, iv.digits, iv.base)) orelse {
                    self.note("an integer literal that does not fit in 64 bits");
                    return self.zeroValue();
                };
                return .{
                    .reg = text,
                    .ty = try self.typeFor(if (iv.suffix.len > 0) iv.suffix else "i32"),
                    .immediate = true,
                };
            },
            .float => |fv| {
                // Rust rejects a float literal outside `f64`'s range at compile
                // time. Emitting the text unchecked let `1e400` through as
                // whatever the backend made of it -- an infinity, silently.
                const v = std.fmt.parseFloat(f64, fv.digits) catch {
                    self.note("a float literal that is not a number");
                    return self.zeroValue();
                };
                if (std.math.isInf(v)) {
                    self.note("a float literal out of range for f64");
                    return self.zeroValue();
                }
                // The literal's own text is the shortest round-trip form, so keep
                // it: the formatter in `sa_std` cannot reproduce it.
                if (try rustFloatText(self.allocator, fv.digits)) |text| {
                    try self.float_lits.put(self.allocator, fv.digits, text);
                }
                return .{ .reg = fv.digits, .ty = try self.typeFor("f64"), .immediate = true };
            },
            .bool_ => |b| {
                return .{ .reg = if (b) "1" else "0", .ty = try self.typeFor("bool"), .immediate = true };
            },
            .char_ => |c| {
                return .{
                    .reg = try std.fmt.allocPrint(self.allocator, "{d}", .{c}),
                    .ty = try self.typeFor("char"),
                    .immediate = true,
                };
            },
            .str => |s| {
                // Stays a `@const` name: a literal's text is known at compile
                // time, so it only becomes a box where a register is required.
                return self.strText(s.bytes);
            },
            .byte => |b| {
                return .{ .reg = try std.fmt.allocPrint(self.allocator, "{d}", .{b}), .immediate = true };
            },
            .byte_str => |s| {
                // A byte string is a `&[u8; N]`, not a `&str`: it stays a bare
                // `@const` address until slice support can describe its length.
                return .{ .reg = try self.stringConst(s), .borrowed = true, .immediate = true };
            },
        }
    }

    /// Emit (or reuse) an inline `@const` string and return its name.
    ///
    /// SA allows `@const` inside a function body, which is what lets the
    /// lowering keep every string local to the function that needs it.
    fn stringConst(self: *Lowerer, bytes: []const u8) Error![]const u8 {
        if (self.consts.get(bytes)) |existing| return existing;
        self.const_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "RUSTC_STR_{d}", .{self.const_counter}) catch
            return error.OutOfMemory;
        try escapeForSa(self.allocator, bytes, &self.escape_buf);
        self.out.writer().print(
            "    @const {s} = utf8:\"{s}\"\n",
            .{ name, self.escape_buf.items },
        ) catch return error.OutOfMemory;
        // The key has to be owned. Callers hand in slices into transient buffers
        // -- the format scanner's accumulator is freed with the macro call -- and
        // a map key that outlives its buffer then reads freed memory, which
        // collides with an unrelated string at the next insert and aborts the
        // whole compilation.
        const key = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        self.consts.put(self.allocator, key, name) catch return error.OutOfMemory;
        self.const_lengths.put(self.allocator, name, bytes.len) catch return error.OutOfMemory;
        return name;
    }



    fn lowerPath(self: *Lowerer, pe: ast.PathExpr) Error!Value {
        const leaf = pathLeaf(pe.segments);
        const reg = self.regOf(leaf);
        if (self.var_types.get(reg)) |t| {
            return .{ .reg = reg, .ty = t };
        }
        if (std.mem.eql(u8, leaf, "self") and self.self_reg != null) {
            return .{ .reg = self.self_reg.?, .ty = null, .borrowed = true };
        }
        // A live register whose Rust type could not be inferred is still a
        // valid reference. Without this branch the lookup falls through to
        // `zeroValue`, silently compiling `println!("{}", v)` into a literal 0.
        if (self.isLive(reg)) return .{ .reg = reg, .ty = null };
        // A bare constant (`const MAX: usize = 10;`) is inlined.
        if (self.constValue(leaf)) |v| return v;
        // A unit variant is written as a bare path (`Shape::Empty`), so it never
        // reaches the call path. It still has to produce a real tagged value.
        if (try self.lowerVariantConstruct(leaf, &.{})) |v| return v;
        self.note("reference to an unknown name");
        return self.zeroValue();
    }

    fn zeroValue(self: *Lowerer) Error!Value {
        const t = try self.nextTmp();
        try self.line("{s} = 0", .{t});
        try self.track(t);
        return .{ .reg = t };
    }

    fn lowerUnary(self: *Lowerer, u: ast.UnaryExpr) Error!Value {
        switch (u.op) {
            .neg => {
                const v = try self.lowerExpr(u.expr);
                const t = try self.nextTmp();
                try self.line("{s} = neg {s}", .{ t, v.reg });
                try self.track(t);
                return .{ .reg = t, .ty = v.ty };
            },
            .not => {
                const v = try self.lowerExpr(u.expr);
                const t = try self.nextTmp();
                try self.line("{s} = not {s}", .{ t, v.reg });
                try self.track(t);
                return .{ .reg = t, .ty = v.ty };
            },
            .deref => return self.lowerDeref(.{ .inner = u.expr }),
        }
    }

    fn lowerBinary(self: *Lowerer, b: ast.BinaryExpr) Error!Value {
        if (b.op.isShortCircuit()) {
            // `a && b` / `a || b` become branches; the result is materialised
            // into a destination allocated *before* the branch.
            const dst = try self.nextTmp();
            try self.line("{s} = alloc 8", .{dst});
            try self.track(dst);
            const lhs = try self.lowerExpr(b.lhs);
            const short = if (b.op == .bool_and)
                try self.nextLabel("AND_RHS")
            else
                try self.nextLabel("OR_RHS");
            const merge = try self.nextLabel("MERGE");
            const lhs_target: []const u8 = if (b.op == .bool_and) short else merge;
            const rhs_target: []const u8 = if (b.op == .bool_and) merge else short;
            const branch_live = try self.snapshotLive();
            try self.line("br {s} -> {s}, {s}", .{ lhs.reg, lhs_target, rhs_target });
            try self.restoreLive(branch_live);
            try self.w("{s}:\n", .{short});
            const rhs = try self.lowerExpr(b.rhs);
            try self.emitStoreInto(dst, rhs, true);
            try self.releaseAllKeeping(&.{dst});
            try self.line("jmp {s}", .{merge});
            try self.restoreLive(branch_live);
            try self.w("{s}:\n", .{merge});
            if (b.op == .bool_and) {
                try self.line("store {s}+0, 0 as i1", .{dst});
            }
            return .{ .reg = dst, .ty = try self.typeFor("bool"), .is_memory = true };
        }

        const lhs = try self.materialize(try self.lowerExpr(b.lhs));
        const rhs = try self.materialize(try self.lowerExpr(b.rhs));
        const ty = lhs.ty orelse rhs.ty;
        const op = self.selectOp(b.op, ty);
        const t = try self.nextTmp();
        try self.line("{s} = {s} {s}, {s}", .{ t, op, lhs.reg, rhs.reg });
        try self.track(t);
        return .{ .reg = t, .ty = ty };
    }

    /// Pick the SA mnemonic, switching to the float and unsigned variants.
    fn selectOp(self: *Lowerer, op: ast.BinaryOp, ty: ?*ast.Node) []const u8 {
        if (self.floatOf(ty)) {
            return switch (op) {
                .add => "fadd",
                .sub => "fsub",
                .mul => "fmul",
                .div => "fdiv",
                .eq => "fcmp_eq",
                .ne => "fcmp_ne",
                .lt => "fcmp_lt",
                .le => "fcmp_le",
                .gt => "fcmp_gt",
                .ge => "fcmp_ge",
                else => op.toSla(),
            };
        }
        if (op.isUnsigned()) {
            return switch (op) {
                .div => "udiv",
                .rem => "urem",
                else => op.toSla(),
            };
        }
        return op.toSla();
    }

    fn lowerAssign(self: *Lowerer, a: ast.AssignExpr) Error!Value {
        const place = try self.lowerPlace(a.lhs);
        const val = try self.lowerExpr(a.rhs);
        try self.emitStoreInto(place.reg, val, place.is_memory);
        if (!val.immediate) self.untrack(val.reg);
        return Value.unitValue();
    }

    fn lowerAssignOp(self: *Lowerer, a: ast.AssignOpExpr) Error!Value {
        const place = try self.lowerPlace(a.lhs);
        const rhs = try self.lowerExpr(a.rhs);
        const op = self.selectOp(a.op, place.ty);
        const t = try self.nextTmp();
        try self.line("{s} = {s} {s}, {s}", .{ t, op, place.reg, rhs.reg });
        try self.track(t);
        const stored: Value = .{ .reg = t, .ty = place.ty };
        try self.emitStoreInto(place.reg, stored, place.is_memory);
        return Value.unitValue();
    }

    /// Lower an expression to a writable location (an lvalue).
    fn lowerPlace(self: *Lowerer, node: *ast.Node) Error!Value {
        switch (node.*) {
            .path_expr => |pe| {
                const reg = self.regOf(pathLeaf(pe.segments));
                if (self.var_types.get(reg)) |t| return .{ .reg = reg, .ty = t };
                return .{ .reg = reg, .ty = null };
            },
            .paren_expr => |pe| return self.lowerPlace(pe.inner),
            .field_expr => |f| {
                // A field of an aggregate variable is addressed as `base+off`.
                const base = try self.lowerPlace(f.base);
                const owner = try self.nominalOf(base.ty) orelse return base;
                const l = self.layoutOfName(owner) orelse return base;
                const field = l.fieldByName(f.name) orelse return base;
                const t = try self.nextTmp();
                try self.line("{s} = ptr_add {s}, {d}", .{ t, base.reg, field.offset });
                try self.track(t);
                return .{ .reg = t, .ty = field.ty, .borrowed = true, .is_memory = true };
            },
            .deref_expr => |d| {
                const inner = try self.lowerExpr(d.inner);
                return .{ .reg = inner.reg, .ty = null, .borrowed = true, .is_memory = true };
            },
            .index_expr => |ix| {
                const base = try self.lowerPlace(ix.base);
                const idx = try self.lowerExpr(ix.index);
                const l = self.slicedElemLayout(base.ty);
                const t = try self.nextTmp();
                try self.line("{s} = ptr_add {s}, {s}", .{ t, base.reg, idx.reg });
                try self.track(t);
                return .{ .reg = t, .ty = l, .borrowed = true, .is_memory = true };
            },
            else => return self.lowerExpr(node),
        }
    }

    fn slicedElemLayout(_: *Lowerer, ty: ?*ast.Node) ?*ast.Node {
        if (ty) |x| {
            const t = ast.unparen(x);
            switch (t.*) {
                .ty_array => |a| return a.elem,
                .ty_slice => |s| return s.elem,
                else => {},
            }
            if (ast.typeName(x)) |n| {
                if (std.mem.eql(u8, n, "Vec") or std.mem.eql(u8, n, "String")) {
                    const segs = switch (t.*) {
                        .ty_path => |p| p.segments,
                        else => return null,
                    };
                    if (segs.len > 0 and segs[segs.len - 1].args.len > 0) {
                        for (segs[segs.len - 1].args) |arg| {
                        if (arg == .ty) return arg.ty;
                    }
                    }
                }
            }
        }
        return null;
    }

    /// Write `val` into the place `dst`.
    ///
    /// A memory destination gets `store`; a register destination gets `=`,
    /// which SA treats as a *move*, so the source is untracked rather than
    /// released. An aggregate destination is a rebind of the same heap block.
    fn emitStoreInto(self: *Lowerer, dst: []const u8, val: Value, dst_is_memory: bool) Error!void {
        if (val.kind == .unit or val.reg.len == 0) return;
        if (try self.isAggregate(val.ty)) {
            // Moving an aggregate: rebind the destination to the same block.
            try self.rename(val.reg, dst);
            return;
        }
        if (dst_is_memory) {
            // A `&str` occupies two words, so it cannot go through the single-word
            // `store` below: a lone `store dst+0, box as ptr` would leave the
            // length undefined and the merge would read whatever was there.
            if (try self.isStrValue(val)) {
                try self.emitStrInto(dst, val);
                return;
            }
            try self.line("store {s}+0, {s} as {s}", .{ dst, val.reg, try self.loadWidth(val.ty) });
            return;
        }
        try self.line("{s} = {s}", .{ dst, val.reg });
        if (!val.immediate) self.untrack(val.reg);
    }


    /// Best-effort Rust type of an expression, used to infer a generic
    /// function's type arguments from its call site. Returns null when the type
    /// genuinely cannot be seen yet; the instance is then left with an opaque
    /// parameter, which is the same conservative answer as before.
    /// The explicit `::<T>` arguments attached to the last path segment.
    fn pathTurbofish(segs: []const ast.PathSegment) []const ast.GenericArg {
        if (segs.len == 0) return &.{};
        return segs[segs.len - 1].args;
    }

    /// Emit a call to a monomorphised instance.
    ///
    /// The capability prefixes have to match the instance's own signature, so
    /// the instance's substitution is installed while the arguments are
    /// rendered and restored afterwards.
    fn emitInstanceCall(
        self: *Lowerer,
        mangle: []const u8,
        template: ast.FnItem,
        args: []const ast.CallArg,
    ) Error!Value {
        const inst = self.planner.find(mangle);
        const saved = self.active_subst;
        if (inst) |i| self.active_subst = i.subst;
        defer self.active_subst = saved;

        const sig: FnSig = .{
            .sa_name = mangle,
            .rust_name = inst.?.template,
            .params = template.params,
            .ret = template.ret,
            .body = template.body,
            .is_test = false,
            .is_extern = false,
            .abi = null,
        };
        return self.emitDirectCall(&sig, args);
    }

    fn inferArgType(self: *Lowerer, e: *ast.Node) Error!?*ast.Node {
        // Resolving through `active_subst` is what makes a nested generic
        // collapse onto the outer instance: inside `twice::<Pair>`, the argument
        // `x: T` is `Pair`, so `addup(x)` interns `addup__PAIR` instead of a
        // useless `addup__T` that could never be resolved.
        if (try self.inferArgTypeRaw(e)) |t| return try self.resolveTy(peelRef(t));
        return null;
    }

    fn inferArgTypeRaw(self: *Lowerer, e: *ast.Node) Error!?*ast.Node {
        return switch (ast.unparen(e).*) {
            .path_expr => |pe| blk: {
                const leaf = pathLeaf(pe.segments);
                if (self.var_types.get(leaf)) |t| break :blk t;
                break :blk try self.typeFor(leaf);
            },
            .struct_expr => |se| try self.typeFor(pathLeaf(se.path)),
            .call_expr => |ce| blk: {
                const callee = switch (ce.callee.*) {
                    .path_expr => |pe| pe,
                    else => break :blk null,
                };
                const sig = self.findFn(pathLeaf(callee.segments)) orelse break :blk null;
                break :blk sig.ret;
            },
            .borrow_expr => |r| try self.inferArgType(r.inner),
            .cast_expr => |ce| try self.inferArgType(ce.expr),
            .literal => |l| switch (l) {
                .int => |il| try self.typeFor(if (il.suffix.len > 0) il.suffix else "i64"),
                .float => try self.typeFor("f64"),
                .bool_ => try self.typeFor("bool"),
                .str, .byte_str => try self.typeFor("str"),
                else => null,
            },
            else => null,
        };
    }

    /// Resolve a call to a generic function to a concrete instance.
    ///
    /// Explicit turbofish wins; otherwise each type parameter is bound from the
    /// argument at the matching parameter position. Returns the mangled name.
    fn resolveInstance(
        self: *Lowerer,
        template_name: []const u8,
        template: ast.FnItem,
        turbofish: []const ast.GenericArg,
        args: []const ast.CallArg,
    ) Error![]const u8 {
        const params = try monomorph.typeParamNames(template.generics, self.allocator);
        var args_list: std.ArrayList(?*ast.Node) = .init(self.allocator);
        defer args_list.deinit();
        try args_list.appendNTimes(null, params.len);

        // Explicit turbofish: `sum::<Pair>(..)`.
        var explicit: usize = 0;
        for (turbofish) |ga| {
            if (ga == .lifetime) continue;
            if (explicit >= args_list.items.len) break;
            args_list.items[explicit] = switch (ga) {
                .ty => |t| t,
                .const_value => |c| c,
                else => null,
            };
            explicit += 1;
        }

        // Inferred: bind `T` from the argument in the same position.
        var subst: std.StringHashMapUnmanaged(*ast.Node) = .empty;
        errdefer subst.deinit(self.allocator);
        for (template.params, 0..) |p, i| {
            if (i >= args.len) break;
            const declared = p.ty orelse continue;
            const actual = try self.inferArgType(args[i].expr) orelse continue;
            // `x: T` binds T directly; `x: Pair<T>` binds it through the struct's
            // own argument list, so `Pair<i32>` at the call site pins `T = i32`.
            try self.bindFromTypes(declared, actual, params, &args_list);
        }
        for (params, 0..) |name, i| {
            const t = args_list.items[i] orelse continue;
            try subst.put(self.allocator, name, t);
        }

        const mangle = self.planner.intern(template_name, args_list.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InstanceLimitExceeded => return error.Unsupported,
        };
        if (self.planner.find(mangle)) |inst| {
            if (inst.subst.count() == 0) {
                inst.subst = subst;
                return mangle;
            }
            subst.deinit(self.allocator);
        } else subst.deinit(self.allocator);
        return mangle;
    }

    /// Emit one function per discovered instance. Runs after the ordinary
    /// functions so an instance body can itself call another generic function.
    fn emitInstances(self: *Lowerer) Error!void {
        // `instances` grows while emitting, so iterate by index.
        var i: usize = 0;
        while (i < self.planner.instances.items.len) : (i += 1) {
            // Re-read through the index: emitting an instance can append further
            // instances and reallocate the list.
            const mangle = self.planner.instances.items[i].mangle;
            const inst = self.planner.find(mangle) orelse continue;
            const template = self.templates.get(inst.template) orelse continue;
            const saved_subst = self.active_subst;
            const saved_vars = self.var_types;
            const saved_live = self.live;
            const saved_loops = self.loops;
            // A private copy, so the planner's map is never aliased by
            // `active_subst` and can keep being mutated while this body lowers.
            const subst_copy = try inst.subst.clone(self.allocator);
            self.active_subst = subst_copy;
            // A fresh binding scope: the instance body must not see the
            // caller's locals.
            self.var_types = .empty;
            self.live = .init(self.allocator);
            self.loops = .init(self.allocator);
            defer {
                self.active_subst.deinit(self.allocator);
                self.active_subst = saved_subst;
                self.var_types = saved_vars;
                self.live = saved_live;
                self.loops = saved_loops;
            }
            try self.emitFunction(.{
                .sa_name = inst.mangle,
                .rust_name = inst.template,
                .params = template.params,
                .ret = template.ret,
                .body = template.body,
                .is_test = false,
                .is_extern = false,
                .abi = null,
            });
        }
    }

    fn lowerCall(self: *Lowerer, c: ast.CallExpr) Error!Value {
        // Builtin macros are reached through `path!(..)` and handled there.
        const callee = switch (c.callee.*) {
            .path_expr => |pe| pe,
            else => {
                const f = try self.lowerExpr(c.callee);
                return self.emitIndirectCall(f, c.args);
            },
        };
        const leaf = pathLeaf(callee.segments);

        if (self.findFn(leaf)) |sig| {
            return self.emitDirectCall(sig, c.args);
        }
        // A generic function is lowered once per concrete instantiation; the
        // call is redirected to that instance's mangled name.
        if (self.templates.get(leaf)) |template| {
            const mangle = try self.resolveInstance(leaf, template, pathTurbofish(callee.segments), c.args);
            return self.emitInstanceCall(mangle, template, c.args);
        }
        // A tuple-struct construction is a call to a type name.
        if (self.types.get(leaf) != null) {
            return self.lowerTupleStruct(leaf, c.args);
        }
        // `Shape::Circle(4)` constructs an enum variant.
        if (try self.lowerVariantConstruct(leaf, c.args)) |v| return v;
        self.note("call to an unknown function");
        return self.zeroValue();
    }

    /// The enum that declares a variant with this name, if any.
    fn enumOwningVariant(self: *Lowerer, vname: []const u8) ?struct { name: []const u8, l: layout.Layout } {
        var it = self.types.iterator();
        while (it.next()) |entry| {
            const l = self.layoutOfName(entry.key_ptr.*) orelse continue;
            if (l.shape != .tagged_union) continue;
            if (l.variantByName(vname) != null) return .{ .name = entry.key_ptr.*, .l = l };
        }
        return null;
    }

    /// Build an enum value: allocate the block, store the tag, store the payload.
    ///
    /// Without this `Shape::Circle(4)` matched no known function and folded to a
    /// zero, so every later `match` on it silently took the wrong arm.
    fn lowerVariantConstruct(
        self: *Lowerer,
        vname: []const u8,
        args: []const ast.CallArg,
    ) Error!?Value {
        const owner = self.enumOwningVariant(vname) orelse return null;
        const vl = owner.l.variantByName(vname).?;
        const tag_def = try self.defNameFor(owner.name, vname);
        try self.emitLayoutDefFor(owner.name);

        const block = try self.nextTmp();
        try self.line("{s} = alloc {s}_SIZE", .{ block, owner.name });
        try self.track(block);
        const tag_off = try self.defNameFor(owner.name, "tag");
        try self.line("store {s}+{s}, {s} as u64", .{ block, tag_off, tag_def });

        for (args, 0..) |a, i| {
            if (i >= vl.fields.len) break;
            const off = try self.defNameFor(owner.name, try std.fmt.allocPrint(
                self.allocator,
                "{s}_{s}",
                .{ vname, vl.fields[i].name },
            ));
            const v = try self.lowerExpr(a.expr);
            try self.emitFieldStore(block, off, v, try self.loadWidth(vl.fields[i].ty));
        }
        return Value{ .reg = block, .ty = try self.typeFor(owner.name), .is_memory = true };
    }

    fn emitDirectCall(self: *Lowerer, sig: *const FnSig, args: []const ast.CallArg) Error!Value {
        var argv: std.ArrayList([]const u8) = .init(self.allocator);
        defer argv.deinit();
        var arg_vals: std.ArrayList(Value) = .init(self.allocator);
        defer arg_vals.deinit();

        for (args) |a| {
            const v = try self.materialize(try self.lowerExpr(a.expr));
            try arg_vals.append(v);
            try argv.append(try self.argText(v, sig, arg_vals.items.len - 1));
        }
        // Scalars are read (they stay live until the scope exit); aggregates
        // are moved in with `^`, which does consume them.
        for (arg_vals.items, 0..) |v, i| {
            if (v.reg.len == 0) continue;
            if (i < sig.params.len and try self.paramCapFor(sig.params[i]) == .move and !v.immediate)
                self.untrack(v.reg);
        }

        const ret_agg = try self.isAggregate(sig.ret);
        const t = try self.nextTmp();
        if (sig.ret == null) {
            try self.line("call @{s}({s})", .{ sig.sa_name, try std.mem.join(self.allocator, ", ", argv.items) });
            return Value.unitValue();
        }
        try self.line("{s} = call @{s}({s})", .{ t, sig.sa_name, try std.mem.join(self.allocator, ", ", argv.items) });
        try self.track(t);
        _ = ret_agg;
        return .{ .reg = t, .ty = sig.ret };
    }

    /// Render one call argument, consuming aggregates with `^`.
    fn argText(self: *Lowerer, v: Value, sig: *const FnSig, index: usize) Error![]const u8 {
        if (v.immediate and !v.borrowed) return v.reg;
        if (v.borrowed) return try std.fmt.allocPrint(self.allocator, "&{s}", .{v.reg});
        if (index < sig.params.len) {
            switch (try self.paramCapFor(sig.params[index])) {
                .move => return try std.fmt.allocPrint(self.allocator, "^{s}", .{v.reg}),
                .borrow => return try std.fmt.allocPrint(self.allocator, "&{s}", .{v.reg}),
                .plain => {},
            }
        }
        return v.reg;
    }

    fn emitIndirectCall(self: *Lowerer, callee: Value, args: []const ast.CallArg) Error!Value {
        var argv: std.ArrayList([]const u8) = .init(self.allocator);
        defer argv.deinit();
        for (args) |a| {
            const v = try self.lowerExpr(a.expr);
            try argv.append(v.reg);
        }
        const t = try self.nextTmp();
        try self.line("{s} = call_indirect {s}({s})", .{ t, callee.reg, try std.mem.join(self.allocator, ", ", argv.items) });
        try self.track(t);
        return .{ .reg = t };
    }

    fn lowerField(self: *Lowerer, f: ast.FieldExpr) Error!Value {
        // Method call syntax.
        if (f.name.len == 0) return self.zeroValue();
        if (self.findFn(f.name)) |sig| {
            if (self.findFn(f.name).?.body != null or sig.params.len > 0) {
                return self.emitMethodCall(f, sig);
            }
        }
        const wrapper = try self.allocator.create(ast.Node);
        wrapper.* = .{ .field_expr = f };
        const place = try self.lowerPlace(wrapper);
        if (try self.isAggregate(place.ty)) {
            return .{ .reg = place.reg, .ty = place.ty, .borrowed = true };
        }
        // A `&str` field holds the fat pointer inline, so the whole value is the
        // address: narrowing it with `load addr+0` would keep the data pointer and
        // lose the length sitting next to it.
        if (try self.isStrValue(place)) {
            return .{ .reg = place.reg, .ty = place.ty, .borrowed = true, .is_memory = true, .str_form = .at_addr };
        }
        const t = try self.nextTmp();
        try self.emitLoad(t, place.reg, place.ty);
        try self.track(t);
        return .{ .reg = t, .ty = place.ty };
    }

    /// `recv.method(args)` becomes `call @Owner_method(recv, args)`.
    ///
    /// The receiver is prepended to the argument list so the callee contract's
    /// `self` parameter lines up with argument 0, and the capability prefix
    /// comes from the same `paramCapFor` the signature used.
    fn lowerMethodCall(self: *Lowerer, mc: ast.MethodCallExpr) Error!Value {
        const recv_ty = try self.inferTypeOf(mc.receiver);
        const owner = try self.nominalOf(recv_ty) orelse {
            self.note("method call on a receiver with no known type");
            return self.zeroValue();
        };
        // `&str` has no user impls, so its methods are not in the function table.
        // They read the value's own fat pointer, which is why they are answered
        // here rather than by synthesising a `@str_len` body.
        if (std.mem.eql(u8, owner, "str") and mc.args.len == 0) {
            if (std.mem.eql(u8, mc.method, "len")) return self.strLen(mc.receiver);
            if (std.mem.eql(u8, mc.method, "is_empty")) return self.strIsEmpty(mc.receiver);
        }
        const name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, mc.method });
        const sig = self.findFn(name) orelse {
            self.note("unknown method");
            return self.zeroValue();
        };
        var argv: std.ArrayList(ast.CallArg) = .init(self.allocator);
        defer argv.deinit();
        try argv.append(.{ .expr = mc.receiver });
        try argv.appendSlice(mc.args);
        return self.emitDirectCall(sig, argv.items);
    }

    /// `s.len()` reads the length out of the `&str`'s fat pointer.
    fn strLen(self: *Lowerer, recv: *ast.Node) Error!Value {
        const v = try self.lowerExpr(recv);
        // A literal's length is a compile-time constant.
        if (v.str_form == .const_text) {
            return .{
                .reg = try std.fmt.allocPrint(self.allocator, "{d}", .{self.constLenOf(v.reg) orelse 0}),
                .ty = try self.typeFor("usize"),
                .immediate = true,
            };
        }
        // A box register and an inline field address are both "the address the
        // two words live at", so `v.reg` is the fat pointer either way.
        const src = v.reg;
        const l = try self.nextTmp();
        try self.line("{s} = load {s}+{d} as i64", .{ l, src, STR_LEN_OFF });
        try self.track(l);
        return .{ .reg = l, .ty = try self.typeFor("usize"), .str_form = null };
    }

    /// `s.is_empty()` is `len() == 0`.
    fn strIsEmpty(self: *Lowerer, recv: *ast.Node) Error!Value {
        const v = try self.lowerExpr(recv);
        if (v.str_form == .const_text) {
            const empty = (self.constLenOf(v.reg) orelse 0) == 0;
            return .{
                .reg = if (empty) "1" else "0",
                .ty = try self.typeFor("bool"),
                .immediate = true,
            };
        }
        const src = v.reg;
        const l = try self.nextTmp();
        try self.line("{s} = load {s}+{d} as i64", .{ l, src, STR_LEN_OFF });
        try self.track(l);
        const e = try self.nextTmp();
        try self.line("{s} = eq {s}, 0", .{ e, l });
        try self.releaseReg(l);
        try self.track(e);
        return .{ .reg = e, .ty = try self.typeFor("bool"), .str_form = null };
    }

    /// `recv.method(args)` becomes `call @Recv_method(recv, args)`.
    fn emitMethodCall(self: *Lowerer, f: ast.FieldExpr, sig: *const FnSig) Error!Value {
        const recv_ty = try self.inferTypeOf(f.base);
        const owner = nominalName(recv_ty) orelse "Self";
        const recv = try self.lowerExpr(f.base);
        const method = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, f.name });

        var argv: std.ArrayList([]const u8) = .init(self.allocator);
        defer argv.deinit();
        if (try self.isAggregate(recv_ty)) {
            try argv.append(try std.fmt.allocPrint(self.allocator, "&{s}", .{recv.reg}));
        } else {
            try argv.append(recv.reg);
        }

        // Explicit arguments are lowered by `lowerMethodCall`, which has the
        // call site; `field_expr` alone only carries the receiver.
        const t = try self.nextTmp();
        if (sig.ret == null) {
            try self.line("call @{s}({s})", .{ method, try std.mem.join(self.allocator, ", ", argv.items) });
            return Value.unitValue();
        }
        try self.line("{s} = call @{s}({s})", .{ t, method, try std.mem.join(self.allocator, ", ", argv.items) });
        try self.track(t);
        return .{ .reg = t, .ty = sig.ret };
    }

    fn lowerIndex(self: *Lowerer, ix: ast.IndexExpr) Error!Value {
        const base_ty = try self.inferTypeOf(ix.base);
        const base = try self.lowerPlace(ix.base);
        const idx = try self.lowerExpr(ix.index);
        const elem_ty = self.slicedElemLayout(base_ty);
        const t = try self.nextTmp();
        try self.line("{s} = ptr_add {s}, {s}", .{ t, base.reg, idx.reg });
        if (!idx.immediate) self.untrack(idx.reg);
        try self.track(t);
        if (elem_ty != null and try self.isAggregate(elem_ty)) {
            return .{ .reg = t, .ty = elem_ty, .borrowed = true };
        }
        const v = try self.nextTmp();
        try self.line("{s} = load {s} as {s}", .{ v, t, try self.loadWidth(elem_ty) });
        self.untrack(t);
        try self.track(v);
        return .{ .reg = v, .ty = elem_ty };
    }

    fn lowerCast(self: *Lowerer, c: ast.CastExpr) Error!Value {
        const v = try self.lowerExpr(c.expr);
        const from = self.scalarOf(v.ty);
        const to = self.scalarOf(c.ty);
        const op = castOp(from, to) orelse {
            if (!v.immediate) self.untrack(v.reg);
            return .{ .reg = v.reg, .ty = c.ty, .immediate = v.immediate };
        };
        const t = try self.nextTmp();
        try self.line("{s} = {s} {s} as {s}", .{ t, op, v.reg, to.?.saName() });
        try self.track(t);
        return .{ .reg = t, .ty = c.ty };
    }

    fn lowerBorrow(self: *Lowerer, b: ast.BorrowExpr) Error!Value {
        const place = try self.lowerPlace(b.inner);
        return .{ .reg = place.reg, .ty = try self.inferTypeOf(b.inner), .borrowed = true };
    }

    fn lowerDeref(self: *Lowerer, d: ast.DerefExpr) Error!Value {
        const inner = try self.lowerExpr(d.inner);
        if (try self.isAggregate(inner.ty)) {
            return .{ .reg = inner.reg, .ty = inner.ty, .borrowed = true };
        }
        const t = try self.nextTmp();
        try self.line("{s} = load {s} as {s}", .{ t, inner.reg, "i64" });
        try self.track(t);
        return .{ .reg = t };
    }

    fn lowerTupleStruct(self: *Lowerer, name: []const u8, args: []const ast.CallArg) Error!Value {
        const l = self.layoutOfName(name) orelse return self.zeroValue();
        const t = try self.nextTmp();
        try self.line("{s} = alloc {s}_SIZE", .{ t, name });
        try self.track(t);
        try self.emitLayoutDefFor(name);
        for (args, 0..) |a, i| {
            if (i >= l.fields.len) break;
            const f = l.fields[i];
            const v = try self.lowerExpr(a.expr);
            try self.line("store {s}+{s}_{s}, {s} as {s}", .{
                t, name, f.name, v.reg, try self.loadWidth(f.ty),
            });
            if (!v.immediate) self.untrack(v.reg);
        }
        return .{ .reg = t, .ty = try self.typeFor(name), .borrowed = false };
    }

    /// A stable `ty_path` node naming `name`, so repeated queries share one
    /// pointer and the layout engine's cache stays effective.
    fn typeFor(self: *Lowerer, name: []const u8) Error!?*ast.Node {
        if (self.active_subst.count() > 0) {
            if (self.active_subst.get(name)) |concrete| return concrete;
        }
        if (self.type_nodes.get(name)) |existing| return existing;
        // Primitives are types too, even though they have no `struct_item`
        // backing them: their layout comes straight from `scalarFromName`.
        if (self.types.get(name) == null and layout.scalarFromName(name) == null) return null;
        const segs = try self.allocator.alloc(ast.PathSegment, 1);
        segs[0] = .{ .name = name };
        const node = try self.allocator.create(ast.Node);
        node.* = .{ .ty_path = .{ .segments = segs } };
        try self.type_nodes.put(self.allocator, name, node);
        return node;
    }

    fn emitLayoutDefFor(self: *Lowerer, name: []const u8) Error!void {
        try self.defOnce("{s}_SIZE = {d}", .{ name, @max((self.layoutOfName(name) orelse return).size, 1) });
    }

    fn lowerStructLiteral(self: *Lowerer, s: ast.StructExpr) Error!Value {
        const name = (try self.concreteTypeName(s)) orelse pathLeaf(s.path);
        const l = self.layoutOfName(name) orelse return self.zeroValue();
        const t = try self.nextTmp();
        try self.emitLayoutDefFor(name);
        try self.line("{s} = alloc {s}_SIZE", .{ t, name });
        try self.track(t);
        for (s.fields) |f| {
            const field = l.fieldByName(f.name) orelse continue;
            const v = try self.lowerExpr(f.value);
            const off = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, field.name });
            try self.emitFieldStore(t, off, v, try self.loadWidth(field.ty));
        }
        return .{ .reg = t, .ty = try self.literalTypeNode(s) };
    }

    fn lowerTuple(self: *Lowerer, t: ast.TupleExpr) Error!Value {
        if (t.elems.len == 0) return Value.unitValue();
        const dest = try self.nextTmp();
        try self.line("{s} = alloc {d}", .{ dest, t.elems.len * 8 });
        try self.track(dest);
        for (t.elems, 0..) |e, i| {
            const v = try self.lowerExpr(e);
            const off = try std.fmt.allocPrint(self.allocator, "{d}", .{i * 8});
            try self.emitFieldStore(dest, off, v, try self.loadWidth(v.ty));
        }
        return .{ .reg = dest, .ty = null };
    }

    fn lowerArray(self: *Lowerer, a: ast.ArrayExpr) Error!Value {
        if (a.elems.len == 0) {
            const dest = try self.nextTmp();
            try self.line("{s} = alloc 8", .{dest});
            try self.track(dest);
            return .{ .reg = dest };
        }
        const dest = try self.nextTmp();
        try self.line("{s} = alloc {d}", .{ dest, a.elems.len * 8 });
        try self.track(dest);
        for (a.elems, 0..) |e, i| {
            const v = try self.lowerExpr(e);
            const off = try std.fmt.allocPrint(self.allocator, "{d}", .{i * 8});
            try self.emitFieldStore(dest, off, v, try self.loadWidth(v.ty));
        }
        return .{ .reg = dest };
    }

    // -- control flow -------------------------------------------------------

    fn lowerIf(self: *Lowerer, i: ast.IfExpr) Error!Value {
        // A block handed down by an enclosing `else if` chain. This is *not*
        // `pending_dest`: that names a binding the caller still has to copy out
        // of, whereas this block is already allocated and already the result.
        const inherited_dest = self.inherited_alloc;
        self.inherited_alloc = null;
        const inherited_outer = self.inherited_outer;
        self.inherited_outer = null;
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        // Taken before the branch allocates anything, so it names exactly the
        // registers that outlive the `if`. Each arm releases the difference.
        const outer_live = if (inherited_outer) |o| o else try self.snapshotLive();
        const is_value = i.else_expr != null;
        // Resolved before the block is allocated: a `&str` result needs a
        // two-word slot, and the size has to be right before either arm stores
        // into it.
        const res_ty = if (is_value) try self.inferTypeOf(i.then_block) else null;
        const res_is_str = res_ty != null and try self.nominalOf(res_ty) != null and
            std.mem.eql(u8, (try self.nominalOf(res_ty)).?, "str");
        const slot_size: usize = if (res_is_str) STR_BOX_SIZE else 8;
        // A pending destination is reused rather than allocated. This is how an
        // `else if` chain stays flat: the nested branch writes into the same
        // block instead of allocating a second one and copying a pointer into
        // the first.
        const dst: ?[]const u8 = if (inherited_dest) |d| d else if (is_value) try self.nextTmp() else null;
        // Allocated before the branch so both arms write the same slot. An
        // inherited destination was already allocated by the `if` that handed it
        // down, so re-emitting the `alloc` would redefine the register.
        if (dst) |d| {
            if (inherited_dest == null) try self.line("{s} = alloc {d}", .{ d, slot_size });
            try self.track(d);
            if (res_is_str) try self.markStrReg(d);
        }
        const cond = try self.lowerExpr(i.conds[i.conds.len - 1].value.?);
        const then_label = try self.nextLabel("THEN");
        const else_label = try self.nextLabel("ELSE");
        const merge = try self.nextLabel("MERGE");
        const branch_live = try self.snapshotLive();
        try self.line("br {s} -> {s}, {s}", .{ cond.reg, then_label, else_label });

        try self.restoreLive(branch_live);
        try self.w("{s}:\n", .{then_label});
        try self.lowerArm(i.then_block, dst);
        const then_keep = try self.armKeep(outer_live, dst);
        // An arm that diverged already ended its own block with `panic`/`return`,
        // so it needs no `jmp` -- and no releases either. Emitting `!` after a
        // terminator leaves unreachable instructions behind, which is what made
        // `sa build-exe -g` fail with `InvalidOperand`. The live set is still put
        // back into the merge shape, because the phi-join has to see the same set
        // from both arms; that part is bookkeeping, not code.
        const then_reachable = !self.fn_done;
        if (then_reachable) {
            try self.releaseAll(then_keep);
        } else {
            try self.restoreLive(then_keep);
        }
        // What survives an arm is what the merge label sees; both arms must
        // agree, and neither may re-release what the arms already released.
        const then_merge_live = try self.snapshotLive();
        if (then_reachable) try self.line("jmp {s}", .{merge});

        try self.restoreLive(branch_live);
        try self.w("{s}:\n", .{else_label});
        var else_is_nested = false;
        if (i.else_expr) |e| {
            const un = ast.unparen(e);
            // `else if` with a destination to fill: hand the destination down so
            // the nested branch reuses the block instead of allocating one.
            if (dst != null and un.* == .if_expr and !self.dest_taken) {
                else_is_nested = true;
                const saved_alloc = self.inherited_alloc;
                const saved_outer = self.inherited_outer;
                self.inherited_alloc = dst;
                self.inherited_outer = outer_live;
                defer {
                    self.inherited_alloc = saved_alloc;
                    self.inherited_outer = saved_outer;
                }
                _ = try self.lowerIf(un.if_expr);
            } else {
                try self.lowerArm(e, dst);
            }
        }
        // A nested branch already released the shared block's contents; only the
        // non-nested form has to clean up its own temporaries here.
        const else_reachable = !self.fn_done;
        if (!else_is_nested) {
            const else_keep = try self.armKeep(outer_live, dst);
            if (else_reachable) {
                try self.releaseAll(else_keep);
            } else {
                // Same as the `then` arm: a diverged arm is already terminated, so
                // its cleanup would be unreachable code.
                try self.restoreLive(else_keep);
            }
        }
        const else_merge_live = try self.snapshotLive();
        if (else_reachable) try self.line("jmp {s}", .{merge});

        try self.restoreLive(else_merge_live);
        try self.w("{s}:\n", .{merge});
        // Both arms must present the same live set at the phi-join. Silently
        // preferring one arm's set is exactly the failure mode that miscompiles
        // without trapping, so report it as a hard lowering error instead.
        if ((then_reachable or else_reachable) and !liveSetsEqual(then_merge_live, else_merge_live)) {
            return error.BranchArmLiveSetMismatch;
        }
        // A diverging arm has already ended its block, so the *function* is only
        // finished when every arm diverged. Leaving the flag set otherwise made a
        // value-position `if` whose `else` panics fall off the end of the merge
        // with no terminator (`FallthroughForbidden`) -- the caller wanted to emit
        // its `return` there and was told the function was already done.
        if (then_reachable or else_reachable) self.fn_done = false;
        if (dst) |d| {
            if (res_is_str) {
                // The slot already *is* the fat pointer, so the merge hands the
                // same register on as the value. Reading it back as a scalar --
                // which is what a plain `load` would do -- would yield the data
                // address and lose the length.
                return .{ .reg = d, .ty = res_ty, .str_form = .boxed };
            }
            return .{
                .reg = d,
                .ty = res_ty,
                .is_memory = true,
            };
        }
        return Value.unitValue();
    }

    /// Lower a block as a branch arm, storing into `dst` when it has a value.
    fn lowerArm(self: *Lowerer, block: *ast.Node, dst: ?[]const u8) Error!void {
        const blk = switch (block.*) {
            .block_expr => |b| b,
            else => {
                const v = try self.lowerExpr(block);
                if (dst) |d| try self.emitStoreInto(d, v, true);
                return;
            },
        };
        for (blk.stmts) |s| {
            if (self.fn_done) return;
            try self.lowerStmt(s);
        }
        if (blk.value) |v| {
            const val = try self.lowerExpr(v);
            if (dst) |d| try self.emitStoreInto(d, val, true);
        }
    }

    fn lowerWhile(self: *Lowerer, wh: ast.WhileExpr) Error!Value {
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        const cond_label = try self.nextLabel("COND");
        const body_label = try self.nextLabel("BODY");
        const end_label = try self.nextLabel("END");
        try self.loops.append(.{ .break_label = end_label, .continue_label = cond_label });

        // The condition is re-evaluated on every iteration, so its registers
        // are created inside L_COND and released on both edges: the back edge
        // must present the same live set as L_COND's entry, or the Referee
        // reports a phi conflict.
        try self.w("{s}:\n", .{cond_label});
        // Name-based, not index-based: `untrack` inside the body shifts the
        // list, so a captured index would point at the wrong register.
        const loop_entry = try self.snapshotLive();
        const cond = try self.lowerExpr(wh.cond);
        try self.line("br {s} -> {s}, {s}", .{ cond.reg, body_label, end_label });

        try self.w("{s}:\n", .{body_label});
        const blk = wh.body.block_expr;
        for (blk.stmts) |s| {
            if (self.fn_done) break;
            try self.lowerStmt(s);
        }
        if (!self.fn_done) {
            // Restore exactly the live set L_COND was entered with: everything
            // created by the condition and by the body goes, nothing else.
            try self.releaseAllExceptSet(loop_entry);
            try self.line("jmp {s}", .{cond_label});
        }

        try self.w("{s}:\n", .{end_label});
        _ = self.loops.pop();
        return Value.unitValue();
    }

    fn lowerLoop(self: *Lowerer, l: ast.LoopExpr) Error!Value {
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        const body_label = try self.nextLabel("BODY");
        const end_label = try self.nextLabel("END");
        try self.loops.append(.{ .break_label = end_label, .continue_label = body_label });
        try self.w("{s}:\n", .{body_label});
        const blk = l.body.block_expr;
        for (blk.stmts) |s| {
            if (self.fn_done) break;
            try self.lowerStmt(s);
        }
        if (blk.value) |v| {
            const val = try self.lowerExpr(v);
            if (self.loops.items.len > 0) {
                if (self.loops.items[self.loops.items.len - 1].result_reg) |dst| {
                    try self.emitStoreInto(dst, val, false);
                }
            }
        }
        if (!self.fn_done) {
            try self.releaseAll(self.borrowed_params.items);
            try self.line("jmp {s}", .{body_label});
        }
        try self.w("{s}:\n", .{end_label});
        _ = self.loops.pop();
        return Value.unitValue();
    }

    /// `for pat in a..b { .. }` lowers to a counted `while`.
    ///
    /// The induction variable lives in a `stack_alloc` slot hoisted *before*
    /// the loop: allocating inside the body would trip the Referee's
    /// `PhiStateConflict`, because the slot would be live in the body but not
    /// at the loop head.
    fn lowerFor(self: *Lowerer, fe: ast.ForExpr) Error!Value {
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        const range = switch (fe.iter.*) {
            .range_expr => |r| r,
            else => {
                self.note("`for` over a non-range iterable");
                return Value.unitValue();
            },
        };
        const bound_name = if (fe.pat.* == .pat_ident) fe.pat.pat_ident.name else "i";

        const slot = try self.nextTmp();
        try self.line("{s} = stack_alloc 8", .{slot});
        try self.track(slot);
        // Snapshot after the slot is tracked: the slot is part of the loop's
        // entry live set and must survive the back edge.
        const loop_entry = try self.snapshotLive();

        var start_text: []const u8 = "0";
        if (range.start) |s| {
            const v = try self.lowerExpr(s);
            start_text = v.reg;
            if (!v.immediate) self.untrack(v.reg);
        }
        try self.line("store {s}+0, {s} as i64", .{ slot, start_text });

        const cond_label = try self.nextLabel("COND");
        const body_label = try self.nextLabel("BODY");
        const end_label = try self.nextLabel("END");
        try self.loops.append(.{ .break_label = end_label, .continue_label = cond_label });

        try self.w("{s}:\n", .{cond_label});
        const idx = try self.nextTmp();
        try self.line("{s} = load {s}+0 as i64", .{ idx, slot });
        try self.track(idx);

        var cond_reg: []const u8 = "1";
        if (range.end) |e| {
            const ev = try self.lowerExpr(e);
            const cmp = try self.nextTmp();
            const op: []const u8 = if (range.limits == .closed) "sle" else "slt";
            try self.line("{s} = {s} {s}, {s}", .{ cmp, op, idx, ev.reg });
            if (!ev.immediate) self.untrack(ev.reg);
            try self.track(cmp);
            cond_reg = cmp;
        }
        try self.line("br {s} -> {s}, {s}", .{ cond_reg, body_label, end_label });

        try self.w("{s}:\n", .{body_label});
        try self.line("{s} = load {s}+0 as i64", .{ bound_name, slot });
        try self.track(bound_name);
        if (try self.typeFor("i32")) |i32t| try self.var_types.put(self.allocator, bound_name, i32t);
        const blk = fe.body.block_expr;
        for (blk.stmts) |s| {
            if (self.fn_done) break;
            try self.lowerStmt(s);
        }
        if (!self.fn_done) {
            const next = try self.nextTmp();
            try self.line("{s} = add {s}, 1", .{ next, bound_name });
            try self.line("store {s}+0, {s} as i64", .{ slot, next });
            // Restore the live set L_COND was entered with: the hoisted slot and
            // anything declared before the loop survive, the rest does not.
            try self.releaseAllExceptSet(loop_entry);
            try self.line("jmp {s}", .{cond_label});
        }

        try self.w("{s}:\n", .{end_label});
        _ = self.loops.pop();
        // A `stack_alloc` slot is reclaimed at function exit and must never be
        // released explicitly, so it is only dropped from the live set.
        self.untrack(slot);
        return Value.unitValue();
    }
    fn lowerMatch(self: *Lowerer, m: ast.MatchExpr) Error!Value {
        const dest = self.suspendDest();
        defer self.resumeDest(dest);
        // Taken before the scrutinee and the dispatch chain allocate anything, so
        // it names exactly the registers that outlive the `match`.
        const outer_live = try self.snapshotLive();
        const scrut = try self.lowerExpr(m.scrutinee);
        const owner = try self.nominalOf(scrut.ty);
        const l = if (owner) |o| self.layoutOfName(o) else null;
        if (l == null or l.?.shape != .tagged_union) {
            // Not an enum: a `match` on a scalar still has a real lowering, and
            // silently keeping only the first arm discarded every other arm's side
            // effects while the program still looked like it compiled.
            // Read the flag first: `lowerMatchScalar` consumes it.
            const needs_value = self.value_pos;
            if (try self.lowerMatchScalar(m, scrut, outer_live)) |v| return v;
            // A statement-position `match` can degrade to a placeholder: `()` is an
            // honest value for a statement. In value position there is no honest
            // placeholder -- a stub returning nothing under a signature that
            // promises a value reaches the backend as "return type does not match
            // operand type of return inst", which says nothing about the cause.
            if (needs_value) return error.Unsupported;
            self.note("`match` on a non-enum value");
            return Value.unitValue();
        }
        const enum_name = owner.?;
        const tag_off: []const u8 = try self.defNameFor(enum_name, "tag");
        const tag = try self.nextTmp();
        try self.line("{s} = load {s}+{s} as u64", .{ tag, scrut.reg, tag_off });
        try self.track(tag);

        const merge = try self.nextLabel("MERGE");
        // A value-position `match` needs a block its arms can write into,
        // allocated before the dispatch so every arm targets the same slot.
        const want_value = self.value_pos;
        self.value_pos = false;
        // A `&str` result needs a two-word slot, sized before the first arm
        // stores into it.
        const res_ty: ?*ast.Node = if (want_value) blk: {
            for (m.arms) |arm| {
                if (try self.inferTypeOf(arm.body)) |t| break :blk t;
            }
            break :blk null;
        } else null;
        const res_is_str = res_ty != null and try self.nominalOf(res_ty) != null and
            std.mem.eql(u8, (try self.nominalOf(res_ty)).?, "str");
        const slot_size: usize = if (res_is_str) STR_BOX_SIZE else 8;
        const dst: ?[]const u8 = if (want_value) try self.nextTmp() else null;
        if (dst) |d| {
            try self.line("{s} = alloc {d}", .{ d, slot_size });
            try self.track(d);
            if (res_is_str) try self.markStrReg(d);
        }
        for (m.arms, 0..) |arm, i| {
            const arm_label = try self.nextLabel("CASE");
            const next_label = try self.nextLabel("CASE");
            const cond = try self.nextTmp();
            const name = patternVariantName(arm.pat);
            if (name) |vname| {
                const vt = try self.defNameFor(enum_name, vname);
                try self.line("{s} = eq {s}, {s}", .{ cond, tag, vt });
            } else {
                try self.line("{s} = 1", .{cond});
            }
            try self.track(cond);
            // The `br` opens two paths, and the live set is a single mutable
            // list. The arm's releases would otherwise still be visible to the
            // fall-through path, so both paths start from the same snapshot.
            const dispatch_live = try self.snapshotLive();
            // The `br` already ends this block. Emitting a release and a `jmp`
            // after it produced unreachable instructions that the Referee
            // rejected as a block without a terminator.
            try self.line("br {s} -> {s}, {s}", .{ cond, arm_label, next_label });

            try self.restoreLive(dispatch_live);
            try self.w("{s}:\n", .{arm_label});
            // Bind the variant's fields into the arm's pattern variables.
            try self.bindPatternFields(arm.pat, scrut.reg, enum_name, vnameFromPattern(arm.pat));
            try self.lowerArm(arm.body, dst);
            // One keep-set for the whole arm: everything live before the `match`,
            // *and* the result block the merge still has to read out of. Two
            // separate releases let the second one consume the block. Keeping the
            // outer set is what lets a variable be read after the `match`.
            const arm_keep = try self.armKeep(outer_live, dst);
            // A diverging arm (`panic!`/`return`) is already terminated; emitting
            // its releases would leave unreachable instructions after the
            // terminator, which `sa build-exe -g` rejects with `InvalidOperand`.
            // The live set is still restored to the merge shape, because that part
            // is bookkeeping rather than code.
            const arm_reachable = !self.fn_done;
            if (arm_reachable) {
                try self.releaseAll(arm_keep);
            } else {
                try self.restoreLive(arm_keep);
            }
            if (arm_reachable) try self.line("jmp {s}", .{merge});

            try self.restoreLive(dispatch_live);
            try self.w("{s}:\n", .{next_label});
            // Later arms still need the scrutinee, so only the dispatch
            // condition is consumed on this path.
            var keep: std.ArrayList([]const u8) = .init(self.allocator);
            defer keep.deinit();
            for (dispatch_live) |r| {
                if (!std.mem.eql(u8, r, cond)) try keep.append(r);
            }
            try self.releaseAll(keep.items);
            _ = i;
        }

        // No arm matched: SA's `MissingVariant` trap.
        try self.releaseAll(outer_live);
        if (!self.fn_done) try self.line("panic(106)", .{});
        try self.w("{s}:\n", .{merge});
        if (dst) |d| {
            if (res_is_str) return .{ .reg = d, .ty = res_ty, .str_form = .boxed };
            return .{ .reg = d, .ty = res_ty, .is_memory = true };
        }
        return Value.unitValue();
    }


    /// `match` on a scalar: an if/else-if chain over the arms' patterns.
    ///
    /// The enum path dispatches on a tag with one `eq` per variant; a scalar needs
    /// a *test* per arm instead, but the generated shape is the same chain, so the
    /// two paths share one live-set protocol rather than growing a second.
    /// Only one arm is reachable per branch, so the chain is linear -- which is all
    /// `SA_LIMITATIONS.md` item 1 leaves us with until `br_table` exists.
    ///
    /// Returns the arm's value, or null when the scrutinee or a pattern needs a
    /// construct this does not model, so the caller reports it instead of guessing.
    fn lowerMatchScalar(
        self: *Lowerer,
        m: ast.MatchExpr,
        scrut: Value,
        outer_live: []const []const u8,
    ) Error!?Value {
        // A pattern test needs a single value to compare. A non-enum *aggregate*
        // has none, so structural matching is not modelled.
        if (try self.isAggregate(scrut.ty)) return null;

        // `match x { }` is uninhabited: it can never produce a value and must not
        // fall through. Handled before the result block is allocated, because a
        // block nothing can write is a read of undefined memory at the merge.
        if (m.arms.len == 0) {
            try self.releaseAll(outer_live);
            if (!self.fn_done) try self.line("panic(106)", .{});
            self.fn_done = true;
            // Uninhabited, so there is no value to hand back. In value position
            // that is a hard refusal rather than a placeholder.
            return if (self.value_pos) error.Unsupported else Value.unitValue();
        }

        // Checked before anything at all is emitted. Allocating the result block
        // first and then refusing left that block live and unreleased, so a refused
        // `match` turned into a `MemoryLeak` instead of a diagnostic.
        for (m.arms) |arm| {
            if (!self.patternIsTestable(arm.pat)) return null;
        }

        // A value-position `match` needs a block its arms write into, exactly as a
        // value-position `if` does. Without it the function ended in `ret void`
        // while its signature promised a value, which the backend rejected.
        const want_value = self.value_pos;
        self.value_pos = false;
        const res_ty: ?*ast.Node = if (want_value) blk: {
            for (m.arms) |arm| {
                if (try self.inferTypeOf(arm.body)) |t| break :blk t;
            }
            break :blk null;
        } else null;
        const res_is_str = res_ty != null and try self.nominalOf(res_ty) != null and
            std.mem.eql(u8, (try self.nominalOf(res_ty)).?, "str");
        const slot_size: usize = if (res_is_str) STR_BOX_SIZE else 8;
        const dst: ?[]const u8 = if (want_value) try self.nextTmp() else null;
        if (dst) |d| {
            try self.line("{s} = alloc {d}", .{ d, slot_size });
            try self.track(d);
            if (res_is_str) try self.markStrReg(d);
        }

        const merge = try self.nextLabel("MERGE");
        var has_catch_all = false;
        for (m.arms) |arm| {
            // A guarded arm is not a fall-through even when its pattern is `_`:
            // the guard can still fail, so the chain has to test it.
            if (arm.guard == null and patternIsCatchAll(arm.pat)) has_catch_all = true;
        }

        for (m.arms) |arm| {
            const arm_label = try self.nextLabel("CASE");
            const next_label = try self.nextLabel("CASE");
            // A guarded arm binds its pattern before the `br`, so the guard can
            // refer to those names. Those registers are the arm's to release.
            var hoisted: std.ArrayList([]const u8) = .init(self.allocator);
            defer hoisted.deinit();
            const cond = try self.emitArmTest(arm, scrut, &hoisted);
            // The `br` opens two paths and the live set is one mutable list, so
            // both paths start from the same snapshot.
            const dispatch_live = try self.snapshotLive();
            try self.line("br {s} -> {s}, {s}", .{ cond, arm_label, next_label });

            try self.restoreLive(dispatch_live);
            try self.w("{s}:\n", .{arm_label});
            // A pattern with no guard was not bound yet; the hoisted one already is.
            if (hoisted.items.len == 0) try self.bindMatchPattern(arm.pat, scrut, null);
            try self.lowerArm(arm.body, dst);
            // A diverging arm is already terminated: restoring the live set is
            // bookkeeping, whereas emitting the releases would be unreachable code
            // after the terminator, which `sa build-exe -g` rejects.
            const arm_reachable = !self.fn_done;
            const arm_keep = try self.armKeep(outer_live, dst);
            var arm_keep_all: std.ArrayList([]const u8) = .init(self.allocator);
            defer arm_keep_all.deinit();
            try arm_keep_all.appendSlice(arm_keep);
            try arm_keep_all.appendSlice(hoisted.items);
            if (arm_reachable) {
                try self.releaseAll(arm_keep_all.items);
            } else {
                try self.restoreLive(arm_keep_all.items);
            }
            if (arm_reachable) try self.line("jmp {s}", .{merge});

            try self.restoreLive(dispatch_live);
            try self.w("{s}:\n", .{next_label});
            // Later arms still need the scrutinee, so only the test register and
            // this arm's hoisted bindings are consumed on the fall-through path.
            var keep: std.ArrayList([]const u8) = .init(self.allocator);
            defer keep.deinit();
            for (dispatch_live) |r| {
                if (std.mem.eql(u8, r, cond)) continue;
                if (containsReg(hoisted.items, r)) continue;
                try keep.append(r);
            }
            try self.releaseAll(keep.items);
        }

        // No arm matched and none could: `SA`'s `MissingVariant` trap. With a
        // catch-all the chain always lands in an arm, so the merge is reachable
        // without it.
        if (!has_catch_all) {
            try self.releaseAll(outer_live);
            if (!self.fn_done) try self.line("panic(106)", .{});
        }
        // The result block has to survive into the merge: the merge reads out of
        // it. Dropping it here left the block live-but-unreleased, which the
        // Referee reports as `MemoryLeak` at the function exit. Whoever takes the
        // value next (`let` moving a `&str` box) untracks it in turn.
        const merge_live = try self.armKeep(outer_live, dst);
        try self.restoreLive(merge_live);
        try self.w("{s}:\n", .{merge});
        if (dst) |d| {
            if (res_is_str) {
                return .{ .reg = d, .ty = res_ty, .str_form = .boxed };
            }
            return .{ .reg = d, .ty = res_ty, .is_memory = true };
        }
        return Value.unitValue();
    }

    /// The test for one arm: its pattern, conjoined with its guard when it has one.
    ///
    /// A guard is part of the arm, not decoration -- `x if x > LIMIT` matches only
    /// the values that also pass the predicate. Ignoring it made such an arm catch
    /// everything, and every later arm dead.
    ///
    /// The guard is evaluated in the *dispatch* block, before the `br`, so the
    /// pattern's bindings have to exist by then. For a scalar scrutinee that is
    /// just a copy of the scrutinee, so the binding is hoisted; `hoisted` receives
    /// the registers so the arm can keep them live and the fall-through path can
    /// release them.
    fn emitArmTest(
        self: *Lowerer,
        arm: ast.MatchArm,
        scrut: Value,
        hoisted: *std.ArrayList([]const u8),
    ) Error![]const u8 {
        // Every arm was checked testable before the chain was emitted, so this
        // cannot be null in practice. Handled as an error rather than
        // `unreachable` so a future divergence between the predicate and the
        // emitter is a diagnostic instead of a panic.
        const pat_test = (try self.emitPatternTest(arm.pat, scrut)) orelse return error.Unsupported;
        const guard_node = arm.guard orelse return pat_test;
        if (!patTestBinds(arm.pat)) return pat_test;
        try self.bindMatchPattern(arm.pat, scrut, hoisted);
        const g = (try self.lowerExpr(guard_node)).reg;
        if (std.mem.eql(u8, pat_test, "1")) return g;
        const t = try self.nextTmp();
        try self.line("{s} = and {s}, {s}", .{ t, pat_test, g });
        try self.track(t);
        try self.releaseReg(g);
        return t;
    }

    /// True when a pattern has a single-register test against a scalar.
    ///
    /// Deliberately conservative. A pattern that fails this check makes the whole
    /// `match` unsupported rather than silently matching everything, which is the
    /// difference between a diagnostic and a program that answers wrongly: a
    /// string literal pattern has no single-register form, and treating it as a
    /// catch-all made `match s { "a" => 1, "b" => 2, _ => 0 }` answer 1 for every
    /// input while looking perfectly compiled.
    fn patternIsTestable(self: *Lowerer, pat: *ast.Node) bool {
        switch (ast.unparen(pat).*) {
            .pat_wild, .pat_rest, .pat_ident, .pat_path => return true,
            .pat_ref => |pr| return self.patternIsTestable(pr.pat),
            .pat_literal => |pl| return switch (pl.literal) {
                .int, .bool_, .char_ => true,
                else => false,
            },
            .pat_range => |pr| {
                // Each endpoint has to fold to a constant; an endpoint naming
                // something the lowering cannot see would silently narrow the
                // range to nothing.
                if (pr.start) |x| if (!self.patLiteralIsConstant(x)) return false;
                if (pr.end) |x| if (!self.patLiteralIsConstant(x)) return false;
                return true;
            },
            .pat_or => |po| {
                if (po.alts.len == 0) return false;
                for (po.alts) |a| {
                    if (!self.patternIsTestable(a)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// True when a range endpoint is a constant this lowering can see.
    fn patLiteralIsConstant(self: *Lowerer, node: *ast.Node) bool {
        const name: ?[]const u8 = switch (ast.unparen(node).*) {
            .pat_literal => |pl| return switch (pl.literal) {
                .int, .bool_, .char_ => true,
                else => false,
            },
            .literal => |l| return switch (l) {
                .int, .bool_, .char_ => true,
                else => false,
            },
            .pat_path => |pp| if (pp.segments.len == 0) null else pp.segments[pp.segments.len - 1].name,
            .path_expr => |pe| pathLeaf(pe.segments),
            else => null,
        };
        const n = name orelse return false;
        return self.int_consts.contains(n) or self.consts.contains(n);
    }

    /// Emit the test for one match arm and return the register holding it.
    ///
    /// A catch-all arm is not tested: it is the fall-through target, which is what
    /// makes the chain terminate.
    ///
    /// Null means the pattern has no test, and the caller must refuse the whole
    /// `match`. Falling back to "always true" here is the silent-miscompile shape
    /// this path exists to remove: a string literal pattern has no single-register
    /// form, so `match s { "a" => .., "b" => .. }` answered 1 for *every* input and
    /// never said so.
    fn emitPatternTest(self: *Lowerer, pat: *ast.Node, scrut: Value) Error!?[]const u8 {
        if (!self.patternIsTestable(pat)) return null;
        const t = try self.nextTmp();
        if (!try self.emitPatternTestInto(t, pat, scrut)) {
            self.untrack(t);
            return null;
        }
        return t;
    }

    /// Fill `dst` with the result of testing `pat` against `scrut`.
    ///
    /// Returns false when the pattern cannot be tested; `dst` is then untouched.
    fn emitPatternTestInto(self: *Lowerer, dst: []const u8, pat: *ast.Node, scrut: Value) Error!bool {
        switch (ast.unparen(pat).*) {
            .pat_wild, .pat_rest, .pat_ident => {
                // A binding arm matches anything; the name is bound by the caller.
                try self.line("{s} = 1", .{dst});
                try self.track(dst);
                return true;
            },
            .pat_path => {
                // A unit variant or a `const` used as a pattern: one equality.
                const operand = try self.patPathOperand(pat);
                if (operand) |o| {
                    try self.line("{s} = eq {s}, {s}", .{ dst, scrut.reg, o });
                    try self.track(dst);
                    return true;
                }
                try self.line("{s} = 1", .{dst});
                try self.track(dst);
                return true;
            },
            .pat_ref => |pr| return self.emitPatternTestInto(dst, pr.pat, scrut),
            .pat_literal => |pl| {
                const lit = (try self.lowerPatLiteral(pl.literal)) orelse return false;
                try self.line("{s} = eq {s}, {s}", .{ dst, scrut.reg, lit });
                try self.track(dst);
                return true;
            },
            .pat_range => |pr| {
                const lo = if (pr.start) |s| try self.lowerPatLiteralExpr(s) else null;
                const hi = if (pr.end) |e| try self.lowerPatLiteralExpr(e) else null;
                if (lo == null and hi == null) return false;
                try self.line("{s} = 1", .{ dst });
                try self.track(dst);
                // A signed comparison on an unsigned value is wrong above
                // `MAX_INT`, and silently so: `1..=5` on a `u32` holding
                // 3_000_000_000 answered "not in range".
                const unsigned = self.unsignedOf(scrut.ty);
                if (lo) |l| {
                    const op: []const u8 = switch (unsigned) {
                        true => if (pr.inclusive_start) "uge" else "ugt",
                        false => if (pr.inclusive_start) "sge" else "sgt",
                    };
                    const t = try self.nextTmp();
                    try self.line("{s} = {s} {s}, {s}", .{ t, op, scrut.reg, l });
                    try self.track(t);
                    try self.line("{s} = and {s}, {s}", .{ dst, dst, t });
                    try self.releaseReg(t);
                }
                if (hi) |h| {
                    const op: []const u8 = switch (unsigned) {
                        true => if (pr.inclusive_end) "ule" else "ult",
                        false => if (pr.inclusive_end) "sle" else "slt",
                    };
                    const t = try self.nextTmp();
                    try self.line("{s} = {s} {s}, {s}", .{ t, op, scrut.reg, h });
                    try self.track(t);
                    try self.line("{s} = and {s}, {s}", .{ dst, dst, t });
                    try self.releaseReg(t);
                }
                return true;
            },
            .pat_or => |po| {
                if (po.alts.len == 0) return false;
                if (!try self.emitPatternTestInto(dst, po.alts[0], scrut)) return false;
                for (po.alts[1..]) |alt| {
                    const t = try self.nextTmp();
                    if (!try self.emitPatternTestInto(t, alt, scrut)) {
                        self.untrack(t);
                        return false;
                    }
                    try self.line("{s} = or {s}, {s}", .{ dst, t, dst });
                    try self.releaseReg(t);
                }
                return true;
            },
            else => return false,
        }
    }

    /// The comparison operand for a path pattern, when one is known statically.
    ///
    /// A unit enum variant becomes its tag, a `const` its value; anything else has
    /// no single-register form here.
    fn patPathOperand(self: *Lowerer, pat: *ast.Node) Error!?[]const u8 {
        const t = ast.unparen(pat);
        const segs = switch (t.*) {
            .pat_path => |pp| pp.segments,
            .path_expr => |pe| pe.segments,
            else => return null,
        };
        if (segs.len == 0) return null;
        const leaf = segs[segs.len - 1].name;
        const v = self.constValue(leaf) orelse return null;
        return v.reg;
    }

    /// Bind the names a match-arm pattern introduces.
    ///
    /// A scalar pattern can only bind the whole scrutinee; anything structural
    /// needs a `match` over an aggregate, which is not modelled here. Registers
    /// created are appended to `out` when the caller has to account for them.
    fn bindMatchPattern(
        self: *Lowerer,
        pat: *ast.Node,
        scrut: Value,
        out: ?*std.ArrayList([]const u8),
    ) Error!void {
        const t = ast.unparen(pat);
        switch (t.*) {
            .pat_ident => |pi| {
                if (pi.sub != null or pi.name.len == 0) return;
                const reg = try self.nextTmp();
                if (scrut.is_memory) {
                    try self.emitLoad(reg, scrut.reg, scrut.ty);
                } else {
                    // The scrutinee is a scalar register, not an address. Loading
                    // from it read whatever happened to sit at `n+0`, so `x => ...`
                    // produced a value unrelated to `n`.
                    try self.emitCopy(reg, scrut.reg, scrut.ty);
                }
                try self.track(reg);
                if (try self.isStrValue(.{ .reg = reg, .ty = scrut.ty })) try self.markStrReg(reg);
                if (scrut.ty) |vt| try self.var_types.put(self.allocator, reg, vt);
                try self.shadow.put(self.allocator, pi.name, reg);
                if (out) |o| try o.append(reg);
            },
            .pat_ref => |pr| try self.bindMatchPattern(pr.pat, scrut, out),
            .pat_or => |po| {
                if (po.alts.len > 0) try self.bindMatchPattern(po.alts[0], scrut, out);
            },
            else => {},
        }
    }

    /// Lower a pattern literal to an SA operand, or null when it has no
    /// single-register form.
    ///
    /// Integers go out as their *source text*, not as a round-tripped `i64`:
    /// `u64::MAX` does not fit an `i64`, and printing it as one turned
    /// `18446744073709551615` into `-1` -- a pattern that matched the wrong values
    /// without a word. `SA` accepts a full-width decimal immediate.
    fn lowerPatLiteral(self: *Lowerer, l: ast.Literal) Error!?[]const u8 {
        return switch (l) {
            .int => |iv| try layout.intLiteralText(self.allocator, iv.digits, iv.base),
            .bool_ => |b| if (b) "1" else "0",
            .char_ => |c| try std.fmt.allocPrint(self.allocator, "{d}", .{c}),
            else => null,
        };
    }

    /// Lower a range endpoint, which is a pattern rather than a literal node.
    fn lowerPatLiteralExpr(self: *Lowerer, node: *ast.Node) Error!?[]const u8 {
        const t = ast.unparen(node);
        const l = switch (t.*) {
            .literal => |x| x,
            .pat_literal => |x| x.literal,
            // A bare identifier that names an integer `const` inlines.
            .path_expr => |pe| {
                const v = self.constValue(pathLeaf(pe.segments)) orelse return null;
                return v.reg;
            },
            .pat_path => |pp| {
                if (pp.segments.len == 0) return null;
                const v = self.constValue(pp.segments[pp.segments.len - 1].name) orelse return null;
                return v.reg;
            },
            else => return null,
        };
        return self.lowerPatLiteral(l);
    }

    fn vnameFromPattern(p: *ast.Node) ?[]const u8 {
        return patternVariantName(p);
    }

    /// Load the fields bound by an enum pattern into fresh registers.
    fn bindPatternFields(
        self: *Lowerer,
        pat: *ast.Node,
        scrut_reg: []const u8,
        enum_name: []const u8,
        vname: ?[]const u8,
    ) Error!void {
        const variant = vname orelse return;
        const elems: []const *ast.Node = switch (pat.*) {
            .pat_tuple_struct => |ts| ts.elems,
            else => return,
        };
        const l = self.layoutOfName(enum_name) orelse return;
        const vl = l.variantByName(variant) orelse return;
        for (elems, 0..) |sub, i| {
            if (i >= vl.fields.len) break;
            if (sub.* != .pat_ident) continue;
            const name = sub.pat_ident.name;
            const off = try self.defNameFor(enum_name, try std.fmt.allocPrint(
                self.allocator,
                "{s}_{s}",
                .{ variant, vl.fields[i].name },
            ));
            const t = try self.nextTmp();
            try self.line("{s} = load {s}+{s} as {s}", .{ t, scrut_reg, off, try self.loadWidth(vl.fields[i].ty) });
            try self.track(t);
            // The payload lives in a temporary, so the pattern variable has to
            // *refer* to that temporary. Renaming the live-set entry instead
            // left the arm body referencing a register that was never emitted,
            // and every use folded to a zero.
            try self.shadow.put(self.allocator, name, t);
            try self.var_types.put(self.allocator, t, vl.fields[i].ty);
        }
    }

    fn defNameFor(self: *Lowerer, owner: []const u8, suffix: []const u8) Error![]const u8 {
        const text = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, suffix }) catch
            return error.OutOfMemory;
        if (!self.def_names.contains(text)) {
            // The layout pass runs before bodies, so this is normally a no-op;
            // it stays as a safety net for lazily discovered aggregates.
            self.emitLayoutDefsForced(owner) catch {};
        }
        return text;
    }

    fn emitLayoutDefsForced(self: *Lowerer, name: []const u8) Error!void {
        // Re-emit: `defOnce` de-duplicates, so this is cheap and idempotent.
        try self.emitLayoutDefs(name);
    }

    // -- `?` ----------------------------------------------------------------

    /// `expr?` on a fallible call unwraps the status code.
    fn lowerTry(self: *Lowerer, node: *ast.Node) Error!Value {
        const inner = try self.lowerExpr(node.try_expr.inner);
        const t = try self.nextTmp();
        try self.line("{s} = ? {s}", .{ t, inner.reg });
        try self.track(t);
        return .{ .reg = t, .ty = inner.ty };
    }

    // -- macros -------------------------------------------------------------

    fn lowerMacro(self: *Lowerer, path: []const u8, args: []const u8, brace: bool) Error!Value {
        if (std.mem.eql(u8, path, "println")) return self.emitPrint(args, true);
        if (std.mem.eql(u8, path, "print")) return self.emitPrint(args, false);
        if (std.mem.eql(u8, path, "panic")) {
            try self.line("panic(103)", .{});
            self.fn_done = true;
            return Value.unitValue();
        }
        if (std.mem.eql(u8, path, "unreachable") or std.mem.eql(u8, path, "todo")) {
            try self.line("panic(102)", .{});
            self.fn_done = true;
            return Value.unitValue();
        }
        if (std.mem.eql(u8, path, "vec")) {
            const elems = try self.parseBraceElems(args, brace);
            return self.lowerArray(.{ .elems = elems });
        }
        if (std.mem.eql(u8, path, "format")) return self.emitFormat(args);
        if (std.mem.eql(u8, path, "assert") or std.mem.eql(u8, path, "debug_assert")) {
            try self.emitAssert(args);
            return Value.unitValue();
        }
        self.note("unknown macro");
        return Value.unitValue();
    }

    /// `println!("..", args)` -> fmt + `sa_print_bytes`.
    ///
    /// The string is split on `{}`/`{0}`-style holes; each hole is formatted
    /// through `sa_fmt_*` and appended. With no holes the literal is emitted
    /// as a single `@const`, which is the common case in the rosetta corpus.
    fn emitPrint(self: *Lowerer, args: []const u8, newline: bool) Error!Value {
        var parts: std.ArrayList([]const u8) = .init(self.allocator);
        defer parts.deinit();
        try self.splitArgs(args, &parts);
        if (parts.items.len == 0) return Value.unitValue();

        const fmt_text = trimQuotes(parts.items[0]);
        const arg_texts = parts.items[1..];

        var arg_values: std.ArrayList(Value) = .init(self.allocator);
        defer arg_values.deinit();
        for (arg_texts) |t| {
            const v = try self.lowerExprText(t);
            try arg_values.append(v);
        }
        // Arguments are read, not consumed: they stay live for the scope exit.
        //
        // The format string is scanned rather than split on `{`, because the
        // text between one hole and the next is a literal in its own right.
        // Splitting instead printed everything after a hole -- including the
        // *next* placeholder -- as literal text, so `println!("{},{}", a, b)`
        // emitted `,{},` between the two values.
        var arg_index: usize = 0;
        var lit: std.ArrayList(u8) = .init(self.allocator);
        defer lit.deinit();
        var i: usize = 0;
        while (i < fmt_text.len) {
            if (fmt_text[i] == '{') {
                // `{{` is a literal brace, not a hole.
                if (i + 1 < fmt_text.len and fmt_text[i + 1] == '{') {
                    try lit.append('{');
                    i += 2;
                    continue;
                }
                const close = std.mem.indexOfScalarPos(u8, fmt_text, i, '}') orelse {
                    try lit.appendSlice(fmt_text[i..]);
                    break;
                };
                try self.flushLiteral(&lit);
                try self.emitHole(fmt_text[i + 1 .. close], &arg_values, &arg_index);
                i = close + 1;
                continue;
            }
            if (fmt_text[i] == '}' and i + 1 < fmt_text.len and fmt_text[i + 1] == '}') {
                try lit.append('}');
                i += 2;
                continue;
            }
            try lit.append(fmt_text[i]);
            i += 1;
        }
        try self.flushLiteral(&lit);
        if (arg_index < arg_values.items.len)
            self.note("more arguments than format holes");
        if (newline) try self.printLiteral("\n");
        return Value.unitValue();
    }

    /// Emit one `{...}` hole of a format string.
    ///
    /// `inner` is the text between the braces. Rust has four spellings, and all
    /// four appear in real code:
    ///
    ///   `{}`      the next positional argument
    ///   `{0}`     a positional argument by index (may repeat)
    ///   `{name}`  an *inline capture* of a local or field (Rust 2021)
    ///   `{n:>4}`  any of the above plus a format spec
    ///
    /// A spec is not implemented -- `sa_fmt_*` has no width/precision/alignment
    /// parameters -- but it is reported rather than dropped, so the user is not
    /// told the output is verified when it is only approximately formatted.
    fn emitHole(
        self: *Lowerer,
        inner: []const u8,
        arg_values: *std.ArrayList(Value),
        arg_index: *usize,
    ) Error!void {
        const colon = std.mem.indexOfScalar(u8, inner, ':');
        const name = std.mem.trim(u8, inner[0 .. colon orelse inner.len], " ");
        if (colon != null) self.note("format spec in a `{}` hole");

        if (name.len == 0) {
            if (arg_index.* < arg_values.items.len) {
                try self.printValue(arg_values.items[arg_index.*]);
                arg_index.* += 1;
            } else {
                self.note("more format holes than arguments");
            }
            return;
        }
        if (isAllDigits(name)) {
            const n = std.fmt.parseInt(usize, name, 10) catch {
                self.note("a format hole index that is not a number");
                return;
            };
            if (n < arg_values.items.len) {
                try self.printValue(arg_values.items[n]);
            } else {
                self.note("a format hole index past the last argument");
            }
            return;
        }
        // `{name}` / `{expr}`: lowered here, at the hole, so the value is read at
        // the point the format string reaches it.
        try self.printValue(try self.lowerExprText(name));
    }

    /// Emit the accumulated literal text, if any, and reset the buffer.
    ///
    /// Adjacent literal runs are merged so `a{}b` does not emit two separate
    /// `@const` string definitions.
    fn flushLiteral(self: *Lowerer, lit: *std.ArrayList(u8)) Error!void {
        if (lit.items.len == 0) return;
        try self.printLiteral(lit.items);
        lit.clearRetainingCapacity();
    }

    fn printLiteral(self: *Lowerer, text: []const u8) Error!void {
        if (text.len == 0) return;
        const name = try self.stringConst(text);
        try self.line("call @sa_print_bytes(&{s}, {d})", .{ name, text.len });
    }

    /// The byte length of an inline string constant, recorded when emitted.
    fn constLenOf(self: *Lowerer, name: []const u8) ?usize {
        return self.const_lengths.get(name);
    }

    fn printValue(self: *Lowerer, raw: Value) Error!void {
        // A compile-time constant is printed straight from its `@const`, before
        // `materialize` gets the chance to box it: `println!("{}", "hi")` is one
        // instruction, and boxing it just to read the length back would be three
        // more plus an allocation.
        if (raw.str_form == .const_text) {
            try self.line("call @sa_print_bytes(&{s}, {d})", .{ raw.reg, self.constLenOf(raw.reg) orelse 0 });
            return;
        }
        const v = self.materialize(raw) catch return;
        if (v.reg.len == 0) return;

        // A string is printed as bytes, not formatted as an integer. Its length
        // lives in the fat pointer, so every form reaches the same call: a literal
        // folds to its constant, a binding and a field read their own pair back.
        if (try self.isStrValue(v)) {
            if (v.str_form == .const_text) {
                try self.line("call @sa_print_bytes(&{s}, {d})", .{ v.reg, self.constLenOf(v.reg) orelse 0 });
                return;
            }
            const data = try self.nextTmp();
            try self.line("{s} = load {s}+{d} as ptr", .{ data, v.reg, STR_DATA_OFF });
            try self.track(data);
            const len = try self.nextTmp();
            try self.line("{s} = load {s}+{d} as i64", .{ len, v.reg, STR_LEN_OFF });
            try self.track(len);
            try self.line("call @sa_print_bytes(&{s}, {s})", .{ data, len });
            // LIFO: the two loads borrow the string, so they are released first.
            try self.releaseReg(data);
            try self.releaseReg(len);
            return;
        }
        // A float that came from a literal is printed as its own text, because
        // `sa_fmt_f64` is fixed-precision: it renders `0.5` as `0.50` and rounds
        // to `1` at precision 0, where Rust's `{}` gives the shortest form that
        // round-trips.
        if (self.floatOf(v.ty)) {
            if (self.float_lits.get(v.reg)) |text| {
                const name = try self.stringConst(text);
                try self.line("call @sa_print_bytes(&{s}, {d})", .{ name, text.len });
                return;
            }
            // A computed float has no compile-time text, and the formatter will
            // not match Rust's `Display`. Said out loud rather than left to be
            // discovered in a diff.
            self.note("a computed float prints with fixed precision, not Rust's `Display`");
        }

        const ty = v.ty;
        const is_f = self.floatOf(ty);
        const is_u = self.unsignedOf(ty) and !is_f;
        const fmt_fn: []const u8 = if (is_f)
            "sa_fmt_f64"
        else if (is_u)
            "sa_fmt_u64"
        else if (ty != null and self.scalarOf(ty) == .bool)
            "sa_fmt_bool"
        else
            "sa_fmt_i64";
        const buf = try self.nextTmp();
        if (is_f) {
            try self.line("{s} = call @{s}({s}, 2)", .{ buf, fmt_fn, v.reg });
        } else if (std.mem.eql(u8, fmt_fn, "sa_fmt_bool")) {
            try self.line("{s} = call @{s}({s})", .{ buf, fmt_fn, v.reg });
        } else {
            try self.line("{s} = call @{s}({s}, 10)", .{ buf, fmt_fn, v.reg });
        }
        try self.track(buf);
        const data = try self.nextTmp();
        try self.line("{s} = call @sa_fmt_buffer_data({s})", .{ data, buf });
        try self.track(data);
        const len = try self.nextTmp();
        try self.line("{s} = call @sa_fmt_buffer_len({s})", .{ len, buf });
        try self.track(len);
        try self.line("call @sa_print_bytes(&{s}, {s})", .{ data, len });
        try self.releaseReg(data);
        try self.releaseReg(len);
        // `sa_fmt_buffer_free` takes the buffer by move.
        try self.line("call @sa_fmt_buffer_free(^{s})", .{buf});
        self.untrack(buf);
    }

    /// `format!("..", args)` materialises the string into a fresh buffer.
    fn emitFormat(self: *Lowerer, args: []const u8) Error!Value {
        var parts: std.ArrayList([]const u8) = .init(self.allocator);
        defer parts.deinit();
        try self.splitArgs(args, &parts);
        if (parts.items.len == 0) return Value.unitValue();
        const fmt_text = trimQuotes(parts.items[0]);
        var arg_values: std.ArrayList(Value) = .init(self.allocator);
        defer arg_values.deinit();
        for (parts.items[1..]) |t| {
            const v = try self.lowerExprText(t);
            try arg_values.append(v);
        }
        // Arguments are read, not consumed: they stay live for the scope exit.
        var arg_index: usize = 0;
        var it = std.mem.splitScalar(u8, fmt_text, '{');
        var first = true;
        while (it.next()) |piece| {
            if (std.mem.startsWith(u8, piece, "}")) {
                if (piece.len > 1) try self.printLiteral(piece[1..]);
                if (arg_index < arg_values.items.len) {
                    try self.printValue(arg_values.items[arg_index]);
                    arg_index += 1;
                }
                continue;
            }
            if (!first and piece.len > 0) try self.printLiteral(piece);
            first = false;
        }
        return Value.unitValue();
    }

    fn emitAssert(self: *Lowerer, args: []const u8) Error!void {
        var parts: std.ArrayList([]const u8) = .init(self.allocator);
        defer parts.deinit();
        try self.splitArgs(args, &parts);
        if (parts.items.len == 0) return;
        const v = try self.lowerExprText(parts.items[0]);
        const ok = try self.nextTmp();
        try self.line("{s} = ne {s}, 0", .{ ok, v.reg });
        try self.track(ok);
        const bad = try self.nextLabel("ASSERT");
        const done = try self.nextLabel("ASSERT_OK");
        try self.line("br {s} -> {s}, {s}", .{ ok, done, bad });
        self.untrack(ok);
        try self.w("{s}:\n", .{bad});
        try self.line("panic(103)", .{});
        try self.w("{s}:\n", .{done});
    }



    /// Split a macro argument list on top-level commas.
    fn splitArgs(_: *Lowerer, text: []const u8, out: *std.ArrayList([]const u8)) Error!void {
        var depth: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => {
                    if (depth > 0) depth -= 1;
                },
                '"' => {
                    // Skip a string literal.
                    i += 1;
                    while (i < text.len and text[i] != '"') {
                        if (text[i] == '\\') i += 1;
                        i += 1;
                    }
                },
                ',' => {
                    if (depth == 0) {
                        try out.append(std.mem.trim(u8, text[start..i], " \t\n"));
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        const tail = std.mem.trim(u8, text[start..], " \t\n");
        if (tail.len > 0 or out.items.len == 0) try out.append(tail);
    }


    /// Lower a macro argument given as raw text by re-parsing it as an
    /// expression. This keeps macro handling in the parser out of the AST.
    ///
    /// The re-parsed nodes are allocated from `scratch_arena`, which is owned by
    /// the Lowerer and outlives the returned `Value`. A per-call arena would be
    /// freed on return while the AST still points into it, so the lowering
    /// would read freed memory and silently emit a zero constant instead of the
    /// argument (`println!("{}", v)` printing `0`).
    fn lowerExprText(self: *Lowerer, text: []const u8) Error!Value {
        // `println!("{}", "hi")` is a hole whose text is a compile-time
        // constant, so it is passed as a bare `@const` address: one instruction
        // instead of allocating a box and reading it straight back.
        if (isQuotedLiteral(text)) return self.strText(trimQuotes(text));
        const Parser = @import("parser.zig");
        var p = Parser.Parser.init(self.scratch_arena.allocator(), text);
        const node = p.parseExpr() catch {
            self.note("unparsable macro argument");
            return self.zeroValue();
        };
        return self.lowerExpr(node);
    }

    /// Parse the element list of a `vec![..]`-style macro.
    fn parseBraceElems(self: *Lowerer, args: []const u8, brace: bool) Error![]const *ast.Node {
        const Parser = @import("parser.zig");
        _ = brace;
        // `scratch_arena` for the same reason as `lowerExprText`: the returned
        // nodes must outlive this call.
        var p = Parser.Parser.init(self.scratch_arena.allocator(), args);
        var out: std.ArrayList(*ast.Node) = .init(self.allocator);
        while (true) {
            const e = p.parseExpr() catch break;
            try out.append(e);
            if (!p.eatComma()) break;
        }
        return out.toOwnedSlice();
    }

    // -- type inference helper ---------------------------------------------

    /// A deliberately small type inference: enough to pick load widths and
    /// decide aggregate-vs-scalar for the constructs we lower.
    fn inferTypeOf(self: *Lowerer, node: *ast.Node) Error!?*ast.Node {
        switch (node.*) {
            .paren_expr => |pe| return self.inferTypeOf(pe.inner),
            // A block's type is its tail expression's type. Without this an arm
            // like `{ "pos" }` inferred nothing, so a value-position `if` lost
            // the fact that it produced a string and printed an integer.
            .block_expr => |b| {
                const tail = b.value orelse return null;
                return self.inferTypeOf(tail);
            },
            .path_expr => |pe| {
                const leaf = pathLeaf(pe.segments);
                if (self.var_types.get(leaf)) |t| return t;
                if (self.types.get(leaf) != null) return try self.typeFor(leaf);
                if (self.findFn(leaf)) |f| return f.ret;
                return null;
            },
            .literal => |l| return switch (l) {
                // Rust's literal defaults: `1` is `i32`, `1.0` is `f64`.
                .int => |iv| if (iv.suffix.len > 0)
                    try self.typeFor(iv.suffix)
                else
                    try self.typeFor("i32"),
                .float => try self.typeFor("f64"),
                .bool_ => try self.typeFor("bool"),
                .char_ => try self.typeFor("char"),
                .str => try self.typeFor("str"),
                .byte => try self.typeFor("u8"),
                .byte_str => try self.typeFor("u8"),
            },
            .field_expr => |f| {
                const base = try self.inferTypeOf(f.base);
                const owner = try self.nominalOf(base) orelse return null;
                const l = self.layoutOfName(owner) orelse return null;
                const field = l.fieldByName(f.name) orelse return null;
                return field.ty;
            },
            .struct_expr => |se| {
                const name = pathLeaf(se.path);
                // A generic struct literal is the main place Rust infers type
                // arguments: `Pair { a: 1, b: 2 }` fixes `T = i32`. The result
                // keeps the template name *and* its arguments (`Pair<i32>`) so a
                // later call site can still match it against a declared
                // `Pair<T>`; `nominalOf` turns it into the instance for layout.
                if (self.generic_types.get(name)) |tpl| {
                    if (try self.structArgsType(name, tpl, se)) |n| return n;
                }
                return self.typeFor(name);
            },
            .index_expr => |ix| return self.slicedElemLayout(try self.inferTypeOf(ix.base)),
            .call_expr => |c| {
                if (c.callee.* == .path_expr) {
                    const leaf = pathLeaf(c.callee.path_expr.segments);
                    if (self.findFn(leaf)) |f| return f.ret;
                }
                return null;
            },
            .unary_expr => |u| {
                if (u.op == .deref) return null;
                return self.inferTypeOf(u.expr);
            },
            .binary_expr => |b| {
                if (b.op.isShortCircuit()) return try self.typeFor("bool");
                return (try self.inferTypeOf(b.lhs)) orelse try self.inferTypeOf(b.rhs);
            },
            .cast_expr => |c| return c.ty,
            .deref_expr, .borrow_expr => return null,
            else => return null,
        }
    }
};

/// Parameter name text from a pattern (identifier or `_`).
fn paramName(p: ast.Param) []const u8 {
    return switch (p.pat.*) {
        .pat_ident => |pi| pi.name,
        .pat_wild => "_",
        else => "arg",
    };
}

/// The recorded source position of a statement, or an unknown position.
///
/// Only the three statement forms that carry one are listed; everything else
/// lowers to a hint-free sequence, which is better than a wrong line number.
fn stmtPos(node: *ast.Node) ast.SrcPos {
    return switch (ast.unparen(node).*) {
        .let_stmt => |ls| ls.pos,
        .expr_stmt => |es| es.pos,
        .item_stmt => |is| is.pos,
        else => .{},
    };
}

fn containsReg(set: []const []const u8, reg: []const u8) bool {
    for (set) |r| {
        if (std.mem.eql(u8, r, reg)) return true;
    }
    return false;
}

/// True when a match arm matches every remaining value, so the dispatch chain
/// can fall through to it instead of testing for it.
fn patternIsCatchAll(pat: *ast.Node) bool {
    switch (ast.unparen(pat).*) {
        .pat_wild, .pat_rest => return true,
        // A bare name binds without narrowing, so it is a catch-all too.
        .pat_ident => |pi| return pi.sub == null,
        .pat_ref => |pr| return patternIsCatchAll(pr.pat),
        else => return false,
    }
}

/// True when two or-pattern alternatives bind exactly the same names.
///
/// They must, or binding only the first would silently drop a binding. A name is
/// reported by the registers it resolves to, since an alternative may reach the
/// same name through different pattern shapes.
fn sameBoundNames(a: *ast.Node, b: *ast.Node) bool {
    var names: std.ArrayList([]const u8) = .init(std.heap.page_allocator);
    defer names.deinit();
    collectBoundNames(a, &names);
    var others: std.ArrayList([]const u8) = .init(std.heap.page_allocator);
    defer others.deinit();
    collectBoundNames(b, &others);
    if (names.items.len != others.items.len) return false;
    outer: for (names.items) |n| {
        for (others.items) |o| {
            if (std.mem.eql(u8, n, o)) continue :outer;
        }
        return false;
    }
    return true;
}

fn collectBoundNames(pat: *ast.Node, out: *std.ArrayList([]const u8)) void {
    switch (pat.*) {
        .pat_ident => |pi| {
            if (pi.sub == null and pi.name.len > 0) out.append(pi.name) catch {};
        },
        .pat_tuple => |t| for (t.elems) |e| collectBoundNames(e, out),
        .pat_tuple_struct => |t| for (t.elems) |e| collectBoundNames(e, out),
        .pat_struct => |s| for (s.fields) |f| {
            if (f.pat) |p| collectBoundNames(p, out);
        },
        .pat_ref => |r| collectBoundNames(r.pat, out),
        .pat_box => |b| collectBoundNames(b.pat, out),
        .pat_or => |o| for (o.alts) |a| collectBoundNames(a, out),
        else => {},
    }
}

/// A readable name for an AST node's shape, for the "unsupported" diagnostic.
pub fn nodeKind(node: *ast.Node) []const u8 {
    return switch (ast.unparen(node).*) {
        .closure_expr => "closure",
        .match_expr => "`match`",
        .loop_expr => "`loop`",
        .while_expr => "`while`",
        .for_expr => "`for`",
        .if_expr => "`if`",
        .block_expr => "block",
        .index_expr => "indexing",
        .field_expr => "field access",
        .method_call_expr => "method call",
        .call_expr => "call",
        .struct_expr => "struct literal",
        .tuple_expr => "tuple",
        .return_expr => "`return`",
        else => @tagName(ast.unparen(node).*),
    };
}

/// Strip `&` / `&mut` from a type node, recursively.
fn peelRef(ty: *ast.Node) *ast.Node {
    const t = ast.unparen(ty);
    return switch (t.*) {
        .ty_ref => |r| peelRef(r.inner),
        else => t,
    };
}

fn paramIsBorrow(p: ast.Param) bool {
    return switch (p.pat.*) {
        .pat_ident => |pi| pi.by_ref,
        else => false,
    };
}

fn paramIsRef(p: ast.Param) bool {
    return switch (p.pat.*) {
        .pat_ref => true,
        else => false,
    };
}

fn patternVariantName(p: *ast.Node) ?[]const u8 {
    return switch (p.*) {
        .pat_tuple_struct => |ts| if (ts.path.len > 0) ts.path[ts.path.len - 1].name else null,
        .pat_path => |pp| if (pp.segments.len > 0) pp.segments[pp.segments.len - 1].name else null,
        else => null,
    };
}

fn castOp(from: ?layout.Scalar, to: ?layout.Scalar) ?[]const u8 {
    const f = from orelse return null;
    const t = to orelse return null;
    if (f.isFloat() and !t.isFloat()) {
        return if (t.isUnsigned()) "fptoui" else "fptosi";
    }
    if (!f.isFloat() and t.isFloat()) {
        return if (f.isUnsigned()) "uitofp" else "sitofp";
    }
    if (f.isFloat() and t.isFloat()) {
        if (f.slotSize() > t.slotSize()) return "fptrunc";
        if (f.slotSize() < t.slotSize()) return "fpext";
        return null;
    }
    if (t.slotSize() < f.slotSize()) return "trunc";
    if (t.slotSize() > f.slotSize()) {
        return if (f.isUnsigned() or f == .bool or f == .char) "zext" else "sext";
    }
    if (f != t) return "bitcast";
    return null;
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return text[1 .. text.len - 1];
    }
    return text;
}

/// True when macro-argument text is exactly one string literal with no escapes.
///
/// An escaped literal is left to the parser so the escape is decoded once, in
/// one place, rather than here and again in `escapeForSa`.
fn isQuotedLiteral(text: []const u8) bool {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return false;
    return std.mem.indexOfScalar(u8, text[1 .. text.len - 1], '\\') == null;
}

fn isAllDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Escape bytes into an SA `utf8:"..."` literal body.
///
/// `out` is reused across calls: escaping a format string that needs no
/// escaping is extremely common, so allocating each time would be wasteful.
pub fn escapeForSa(_: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(c),
        }
    }
}

/// True when a pattern introduces a name, which a guard may then refer to.
fn patTestBinds(pat: *ast.Node) bool {
    switch (ast.unparen(pat).*) {
        .pat_ident => |pi| return pi.sub == null and pi.name.len > 0,
        .pat_ref => |pr| return patTestBinds(pr.pat),
        .pat_or => |po| return po.alts.len > 0 and patTestBinds(po.alts[0]),
        else => return false,
    }
}

/// Rust's `Display` for a plain float literal, derived from its source text.
///
/// `sa_std`'s `sa_fmt_f64` is fixed-precision, so the only way to match Rust is
/// to keep the text: Rust drops a fractional part that is entirely zero, so
/// `1.0` prints as `1` and `2.50` as `2.5`.
///
/// Returns null for an exponent form (`1e3` is `1000` in Rust). Expanding one
/// correctly is a parser of its own, so those keep the formatter and are reported
/// rather than guessed at.
fn rustFloatText(allocator: std.mem.Allocator, digits: []const u8) !?[]const u8 {
    if (std.mem.indexOfAny(u8, digits, "eE") != null) return null;
    const dot = std.mem.indexOfScalar(u8, digits, '.') orelse return digits;
    const int_part = digits[0..dot];
    const frac = digits[dot + 1 ..];
    if (int_part.len == 0 and frac.len == 0) return null;
    var end = frac.len;
    while (end > 0 and frac[end - 1] == '0') end -= 1;
    if (end == 0) return int_part;
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ int_part, frac[0..end] });
}
