//! Rust AST.
//!
//! House style (shared with sa_plugin_sla): a single tagged `union(enum)` for
//! every node, arena-allocated by the parser, `*Node` for recursion, immutable
//! slices for children (never `ArrayList`), and `&.{}` instead of `null` for
//! empty collections so builders can use `.{}`.

const std = @import("std");

/// A 1-based source position, attached to the nodes a `#loc` hint is emitted
/// for (items and statements). 0 means "not recorded", which the lowerer treats
/// as "emit no hint" rather than guessing.
pub const SrcPos = struct {
    line: u32 = 0,
    col: u32 = 0,
};

pub const Node = union(enum) {
    program: Program,

    // ---- items ----
    fn_item: FnItem,
    struct_item: StructItem,
    enum_item: EnumItem,
    union_item: UnionItem,
    trait_item: TraitItem,
    impl_item: ImplItem,
    mod_item: ModItem,
    use_item: UseItem,
    type_alias: TypeAlias,
    const_item: ConstItem,
    static_item: StaticItem,
    macro_call_item: MacroCall,
    extern_block: ExternBlock,

    // ---- statements ----
    let_stmt: LetStmt,
    expr_stmt: ExprStmt,
    item_stmt: ItemStmt,
    empty_stmt: EmptyStmt,

    // ---- types ----
    ty_never: TyNever,
    ty_infer: TyInfer,
    ty_path: TyPath,
    ty_ref: TyRef,
    ty_ptr: TyPtr,
    ty_tuple: TyTuple,
    ty_array: TyArray,
    ty_slice: TySlice,
    ty_fn_ptr: TyFnPtr,
    ty_impl_trait: TyImplTrait,
    ty_dyn_trait: TyDynTrait,

    // ---- patterns ----
    pat_wild: PatWild,
    pat_rest: PatRest,
    pat_ident: PatIdent,
    pat_literal: PatLiteral,
    pat_path: PatPath,
    pat_tuple_struct: PatTupleStruct,
    pat_tuple: PatTuple,
    pat_struct: PatStruct,
    pat_ref: PatRef,
    pat_or: PatOr,
    pat_range: PatRange,
    pat_slice: PatSlice,
    pat_box: PatBox,

    // ---- expressions ----
    literal: Literal,
    path_expr: PathExpr,
    paren_expr: ParenExpr,
    unary_expr: UnaryExpr,
    borrow_expr: BorrowExpr,
    deref_expr: DerefExpr,
    binary_expr: BinaryExpr,
    assign_expr: AssignExpr,
    assign_op_expr: AssignOpExpr,
    call_expr: CallExpr,
    method_call_expr: MethodCallExpr,
    field_expr: FieldExpr,
    index_expr: IndexExpr,
    array_expr: ArrayExpr,
    repeat_expr: RepeatExpr,
    tuple_expr: TupleExpr,
    struct_expr: StructExpr,
    cast_expr: CastExpr,
    block_expr: BlockExpr,
    if_expr: IfExpr,
    match_expr: MatchExpr,
    loop_expr: LoopExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,
    break_expr: BreakExpr,
    continue_expr: ContinueExpr,
    return_expr: ReturnExpr,
    closure_expr: ClosureExpr,
    range_expr: RangeExpr,
    macro_expr: MacroExpr,
    try_expr: TryExpr,
    unsafe_expr: UnsafeExpr,
    async_expr: AsyncExpr,
    await_expr: AwaitExpr,
    underscore_expr: UnderscoreExpr,
};

// ---------------------------------------------------------------------------
// program
// ---------------------------------------------------------------------------

pub const Program = struct {
    items: []const *Node,
    file: []const u8 = "",
};

// ---------------------------------------------------------------------------
// visibility / attributes
// ---------------------------------------------------------------------------

pub const Vis = union(enum) {
    inherited,
    public,
    crate,
    restricted: []const u8,
};

pub const Attr = struct {
    path: []const u8,
    /// Raw token text inside the `( ... )`, empty for `#[path]`.
    args: []const u8 = "",
    inner: bool = false,
};

/// `#[derive(Debug, Clone)]` -> ["Debug", "Clone"]
pub fn deriveList(allocator: std.mem.Allocator, attrs: []const Attr) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .init(allocator);
    errdefer out.deinit();
    for (attrs) |a| {
        if (!std.mem.eql(u8, a.path, "derive")) continue;
        var it = std.mem.splitScalar(u8, a.args, ',');
        while (it.next()) |piece| {
            const name = std.mem.trim(u8, piece, " \t\n");
            if (name.len == 0) continue;
            try out.append(name);
        }
    }
    return try out.toOwnedSlice();
}

pub fn hasAttr(attrs: []const Attr, name: []const u8) bool {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.path, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// items
// ---------------------------------------------------------------------------

pub const FnItem = struct {
    name: []const u8,
    generics: Generics = .{},
    params: []const Param = &.{},
    ret: ?*Node = null,
    body: ?*Node = null,
    vis: Vis = .inherited,
    is_unsafe: bool = false,
    is_const: bool = false,
    is_async: bool = false,
    is_variadic: bool = false,
    abi: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    /// Where the item starts, for the `#loc` hint on its `@fn` line.
    pos: SrcPos = .{},
    where_clauses: []const WhereClause = &.{},
};

pub const Param = struct {
    pat: *Node,
    ty: ?*Node = null,
    is_self: bool = false,
    self_kind: SelfKind = .none,
    attrs: []const Attr = &.{},
};

pub const SelfKind = enum {
    none,
    /// `self`
    by_value,
    /// `&self`
    by_ref,
    /// `&mut self`
    by_ref_mut,
    /// `self: Box<Self>`
    boxed,
};

pub const FieldDef = struct {
    name: []const u8,
    ty: *Node,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
};

pub const StructItem = struct {
    name: []const u8,
    generics: Generics = .{},
    fields: []const FieldDef = &.{},
    /// Tuple structs store positional fields in `fields` with generated names.
    is_tuple: bool = false,
    is_unit: bool = false,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
    where_clauses: []const WhereClause = &.{},
};

pub const Variant = struct {
    name: []const u8,
    kind: VariantKind,
    attrs: []const Attr = &.{},
    /// Discriminant expression for explicit `A = 3`.
    discriminant: ?*Node = null,

    pub const VariantKind = union(enum) {
        unit,
        tuple: []const FieldDef,
        fields: []const FieldDef,
    };
};

pub const EnumItem = struct {
    name: []const u8,
    generics: Generics = .{},
    variants: []const Variant = &.{},
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
    where_clauses: []const WhereClause = &.{},
};

pub const UnionItem = struct {
    name: []const u8,
    generics: Generics = .{},
    fields: []const FieldDef = &.{},
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
};

pub const TraitItem = struct {
    name: []const u8,
    generics: Generics = .{},
    items: []const *Node = &.{},
    supertraits: []const *Node = &.{},
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
    where_clauses: []const WhereClause = &.{},
};

pub const ImplItem = struct {
    generics: Generics = .{},
    self_ty: *Node,
    trait_path: ?*Node = null,
    items: []const *Node = &.{},
    attrs: []const Attr = &.{},
    where_clauses: []const WhereClause = &.{},
    /// True for `impl Trait for Type` (used to pick operator impls).
    is_trait_impl: bool = false,
};

pub const ModItem = struct {
    name: []const u8,
    /// Null when the body lives in `path`.
    items: ?[]const *Node = null,
    path: ?[]const u8 = null,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
};

pub const UseItem = struct {
    tree: UseTree,
    vis: Vis = .inherited,
};

pub const UseTree = struct {
    /// Leading `::` or `crate` / `self` / `super` qualifier.
    prefix: []const []const u8 = &.{},
    /// Final segment name, empty for glob imports.
    leaf: []const u8 = "",
    /// `{ a, b::c }` group.
    children: []const UseTree = &.{},
    is_glob: bool = false,
    alias: ?[]const u8 = null,
};

pub const TypeAlias = struct {
    name: []const u8,
    generics: Generics = .{},
    ty: *Node,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
    where_clauses: []const WhereClause = &.{},
};

pub const ConstItem = struct {
    name: []const u8,
    ty: ?*Node = null,
    value: ?*Node = null,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
};

pub const StaticItem = struct {
    name: []const u8,
    ty: ?*Node = null,
    value: ?*Node = null,
    is_mut: bool = false,
    vis: Vis = .inherited,
    attrs: []const Attr = &.{},
};

pub const MacroCall = struct {
    /// Path text without the `!`, e.g. `println`, `vec`, `my_crate::mac`.
    path: []const u8,
    /// Raw token text inside the parens/brackets, un-unescaped.
    args: []const u8 = "",
    /// `name { .. }` brace form.
    brace_args: bool = false,
    is_item: bool = true,
};

pub const ExternBlock = struct {
    abi: ?[]const u8 = null,
    items: []const *Node = &.{},
};

// ---------------------------------------------------------------------------
// generics
// ---------------------------------------------------------------------------

pub const Generics = struct {
    params: []const GenericParam = &.{},

    pub fn names(self: Generics, allocator: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .init(allocator);
        errdefer out.deinit();
        for (self.params) |p| {
            if (p.kind == .lifetime) continue;
            try out.append(p.name);
        }
        return try out.toOwnedSlice();
    }

    pub fn arity(self: Generics) usize {
        var n: usize = 0;
        for (self.params) |p| {
            switch (p.kind) {
                .type_param, .const_param => n += 1,
                .lifetime => {},
            }
        }
        return n;
    }
};

pub const GenericParamKind = enum { type_param, lifetime, const_param };

pub const GenericParam = struct {
    name: []const u8,
    kind: GenericParamKind = .type_param,
    default: ?*Node = null,
    bounds: []const *Node = &.{},
};

pub const WherePredicate = struct {
    /// Left side type for `T: Bound`, null for `for<'a> T: Bound`.
    ty: ?*Node = null,
    bounds: []const *Node = &.{},
    lifetimes: []const []const u8 = &.{},
};

pub const WhereClause = struct {
    predicates: []const WherePredicate,
};

// ---------------------------------------------------------------------------
// types
// ---------------------------------------------------------------------------

pub const TyNever = struct {};

pub const TyInfer = struct {};

pub const PathSegment = struct {
    name: []const u8,
    args: []const GenericArg = &.{},
};

pub const GenericArg = union(enum) {
    /// A concrete type, e.g. `Vec<T>`'s `T`.
    ty: *Node,
    /// A lifetime argument such as `'a` (kept for diagnostics only).
    lifetime: []const u8,
    /// A const generic argument such as `3`.
    const_value: *Node,
    /// An inferred argument `_`.
    infer,
};

pub const TyPath = struct {
    segments: []const PathSegment,
    /// Leading `::` for absolute paths.
    leading_colon: bool = false,
};

pub const TyRef = struct {
    inner: *Node,
    lifetime: ?[]const u8 = null,
    is_mut: bool = false,
};

pub const TyPtr = struct {
    inner: *Node,
    is_mut: bool = true,
    is_const: bool = false,
};

pub const TyTuple = struct {
    elems: []const *Node,
    /// `()` unit tuple.
    is_unit: bool = false,
};

pub const TyArray = struct {
    elem: *Node,
    len: ?*Node = null,
};

pub const TySlice = struct {
    elem: *Node,
};

pub const TyFnPtr = struct {
    params: []const *Node = &.{},
    ret: ?*Node = null,
    is_unsafe: bool = false,
    is_variadic: bool = false,
    abi: ?[]const u8 = null,
};

pub const TyImplTrait = struct {
    bounds: []const *Node,
};

pub const TyDynTrait = struct {
    bounds: []const *Node,
};

/// Strip one level of parentheses; useful before structural type comparisons.
pub fn unparen(node: *Node) *Node {
    var cur = node;
    while (cur.* == .paren_expr) cur = cur.paren_expr.inner;
    return cur;
}

pub fn typeName(ty: *Node) ?[]const u8 {
    const t = unparen(ty);
    return switch (t.*) {
        .ty_path => |p| if (p.segments.len == 0) null else p.segments[p.segments.len - 1].name,
        else => null,
    };
}

pub fn pathName(ty: *Node) ?[]const u8 {
    return typeName(ty);
}

/// Full dotted text of a path type, e.g. `std::vec::Vec`.
pub fn pathText(allocator: std.mem.Allocator, ty: *Node) ?[]const u8 {
    const t = unparen(ty);
    switch (t.*) {
        .ty_path => |p| {
            var out: std.ArrayList(u8) = .init(allocator);
            if (p.leading_colon) out.appendSlice("::") catch return null;
            for (p.segments, 0..) |seg, i| {
                if (i > 0) out.appendSlice("::") catch return null;
                out.appendSlice(seg.name) catch return null;
            }
            return out.toOwnedSlice() catch null;
        },
        else => return null,
    }
}

pub fn isPrimitiveName(name: []const u8) bool {
    const names = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128", "isize",
        "u8",   "u16",  "u32",  "u64",  "u128", "usize",
        "f32",  "f64",  "f16",  "f128", "bool", "char",
        "str",  "()",   "!",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// patterns
// ---------------------------------------------------------------------------

pub const PatWild = struct {};

pub const PatRest = struct {};

pub const PatIdent = struct {
    name: []const u8,
    by_ref: bool = false,
    is_mut: bool = false,
    sub: ?*Node = null,
};

pub const PatLiteral = struct {
    literal: Literal,
};

pub const PatPath = struct {
    segments: []const PathSegment,
    leading_colon: bool = false,
};

pub const PatTupleStruct = struct {
    path: []const PathSegment,
    elems: []const *Node,
    leading_colon: bool = false,
};

pub const PatTuple = struct {
    elems: []const *Node,
};

pub const PatField = struct {
    name: []const u8,
    pat: ?*Node = null,
};

pub const PatStruct = struct {
    path: []const PathSegment,
    fields: []const PatField,
    /// `S { .. }` trailing rest.
    has_rest: bool = false,
    leading_colon: bool = false,
};

pub const PatRef = struct {
    pat: *Node,
    is_mut: bool = false,
};

pub const PatOr = struct {
    alts: []const *Node,
};

pub const PatRange = struct {
    start: ?*Node,
    end: ?*Node,
    inclusive_start: bool = false,
    inclusive_end: bool = false,
};

pub const PatSlice = struct {
    elems: []const *Node,
    /// Index of the `..` element, or null when absent.
    rest_at: ?usize = null,
};

pub const PatBox = struct {
    pat: *Node,
};

// ---------------------------------------------------------------------------
// statements
// ---------------------------------------------------------------------------

pub const LetStmt = struct {
    pat: *Node,
    ty: ?*Node = null,
    init: ?*Node = null,
    /// `let ... else { ... }`
    else_block: ?*Node = null,
    /// Where the statement starts, for a `#loc` hint.
    pos: SrcPos = .{},
};

pub const ExprStmt = struct {
    expr: *Node,
    has_semi: bool = false,
    /// Where the statement starts, for a `#loc` hint.
    pos: SrcPos = .{},
};

pub const ItemStmt = struct {
    item: *Node,
    /// Where the statement starts, for a `#loc` hint.
    pos: SrcPos = .{},
};

pub const EmptyStmt = struct {};

// ---------------------------------------------------------------------------
// expressions
// ---------------------------------------------------------------------------

pub const Literal = union(enum) {
    int: IntLit,
    float: FloatLit,
    bool_: bool,
    char_: u32,
    str: StrLit,
    byte: u8,
    byte_str: []const u8,
};

pub const IntLit = struct {
    /// Digit text with `_` separators removed.
    digits: []const u8,
    base: IntBase = .dec,
    /// Type suffix such as `i64`; empty when absent.
    suffix: []const u8 = "",
};

pub const IntBase = enum { dec, hex, oct, bin };

pub const FloatLit = struct {
    digits: []const u8,
    suffix: []const u8 = "",
};

pub const StrLit = struct {
    /// Decoded UTF-8 bytes, escapes resolved.
    bytes: []const u8,
};

pub const ParenExpr = struct {
    inner: *Node,
};

pub const PathExpr = struct {
    segments: []const PathSegment,
    leading_colon: bool = false,
    /// `Self` / `self` resolve to the enclosing impl or type.
    is_self_type: bool = false,
};

pub const UnaryOp = enum { neg, not, deref };

pub const UnaryExpr = struct {
    op: UnaryOp,
    expr: *Node,
};

pub const BorrowExpr = struct {
    inner: *Node,
    is_mut: bool = false,
    /// `&raw const x` / `&raw mut x`
    is_raw: bool = false,
};

pub const DerefExpr = struct {
    inner: *Node,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    bool_and,
    bool_or,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    pub fn toSla(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "sdiv",
            .rem => "srem",
            .bit_and => "and",
            .bit_or => "or",
            .bit_xor => "xor",
            .shl => "shl",
            .shr => "ashr",
            .bool_and => "eq",
            .bool_or => "ne",
            .eq => "eq",
            .ne => "ne",
            .lt => "slt",
            .le => "sle",
            .gt => "sgt",
            .ge => "sge",
        };
    }

    /// `&&`/`||` short-circuit and are lowered as branches, not instructions.
    pub fn isShortCircuit(self: BinaryOp) bool {
        return self == .bool_and or self == .bool_or;
    }

    /// `&`,`|`,`^`,`<<`,`>>` are unsigned.
    pub fn isUnsigned(self: BinaryOp) bool {
        return switch (self) {
            .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
            else => false,
        };
    }

    /// `==`/`!=` work on floats too.
    pub fn isFloatCapable(self: BinaryOp) bool {
        return switch (self) {
            .add, .sub, .mul, .div, .rem, .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Node,
    rhs: *Node,
};

pub const AssignExpr = struct {
    lhs: *Node,
    rhs: *Node,
};

pub const AssignOpExpr = struct {
    op: BinaryOp,
    lhs: *Node,
    rhs: *Node,
};

pub const CallArg = struct {
    name: ?[]const u8 = null,
    expr: *Node,
};

pub const CallExpr = struct {
    callee: *Node,
    args: []const CallArg = &.{},
};

pub const MethodCallExpr = struct {
    receiver: *Node,
    method: []const u8,
    /// Explicit turbofish `::<T>`, resolved during monomorphization.
    turbofish: []const GenericArg = &.{},
    args: []const CallArg = &.{},
    is_await: bool = false,
};

pub const FieldExpr = struct {
    base: *Node,
    /// Empty for tuple-index `.0`.
    name: []const u8,
    index: ?usize = null,
    is_auto_deref: bool = false,
};

pub const IndexExpr = struct {
    base: *Node,
    index: *Node,
};

pub const ArrayExpr = struct {
    elems: []const *Node,
};

pub const RepeatExpr = struct {
    elem: *Node,
    len: *Node,
};

pub const TupleExpr = struct {
    elems: []const *Node,
};

pub const StructExprField = struct {
    name: []const u8,
    /// Index for tuple-struct positional initialisers.
    index: ?usize = null,
    value: *Node,
    /// `S { base.field, .. }` functional-update shorthand.
    is_base_ref: bool = false,
};

pub const StructExpr = struct {
    path: []const PathSegment,
    fields: []const StructExprField = &.{},
    has_rest: bool = false,
    leading_colon: bool = false,
};

pub const CastExpr = struct {
    expr: *Node,
    ty: *Node,
};

pub const BlockExpr = struct {
    stmts: []const *Node,
    /// Trailing expression without a semicolon, if any.
    value: ?*Node = null,
    /// `'label: { .. }`
    label: ?[]const u8 = null,
    is_unsafe: bool = false,
};

pub const IfLet = struct {
    pat: *Node,
    /// Null for a plain condition.
    value: ?*Node = null,
    ty: ?*Node = null,
};

pub const IfExpr = struct {
    /// One or more conditions; more than one means a let-chain.
    conds: []const IfLet,
    then_block: *Node,
    else_expr: ?*Node = null,
};

pub const MatchArm = struct {
    pat: *Node,
    guard: ?*Node = null,
    body: *Node,
    has_comma: bool = false,
};

pub const MatchExpr = struct {
    scrutinee: *Node,
    arms: []const MatchArm,
};

pub const LoopExpr = struct {
    body: *Node,
    label: ?[]const u8 = null,
};

pub const WhileExpr = struct {
    cond: *Node,
    body: *Node,
    label: ?[]const u8 = null,
};

pub const ForExpr = struct {
    pat: *Node,
    iter: *Node,
    body: *Node,
    label: ?[]const u8 = null,
};

pub const BreakExpr = struct {
    value: ?*Node = null,
    label: ?[]const u8 = null,
};

pub const ContinueExpr = struct {
    label: ?[]const u8 = null,
};

pub const ReturnExpr = struct {
    value: ?*Node = null,
};

pub const ClosureParam = struct {
    pat: *Node,
    ty: ?*Node = null,
};

pub const ClosureExpr = struct {
    params: []const ClosureParam,
    ret: ?*Node = null,
    body: *Node,
    is_move: bool = false,
    /// True for `|| -> T { .. }` whose return type must be inferred.
    ret_inferred: bool = false,
};

pub const RangeLimits = enum { half_open, closed, from, to, full };

pub const RangeExpr = struct {
    start: ?*Node = null,
    end: ?*Node = null,
    limits: RangeLimits = .half_open,
};

pub const MacroExpr = struct {
    path: []const u8,
    args: []const u8 = "",
    brace_args: bool = false,
    has_semi: bool = false,
};

pub const TryExpr = struct {
    inner: *Node,
};

pub const UnsafeExpr = struct {
    block: *Node,
};

pub const AsyncExpr = struct {
    block: *Node,
    is_move: bool = false,
};

pub const AwaitExpr = struct {
    inner: *Node,
};

pub const UnderscoreExpr = struct {};

// ---------------------------------------------------------------------------
// traversal helpers
// ---------------------------------------------------------------------------

pub const Visitor = struct {
    /// Return false to stop descending into `node`.
    pre: *const fn (node: *Node, user: ?*anyopaque) bool,
    post: ?*const fn (node: *Node, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,
};

pub fn visit(node: *Node, v: Visitor) void {
    if (!v.pre(node, v.user)) return;
    switch (node.*) {
        .program => |p| for (p.items) |it| visit(it, v),
        .fn_item => |f| {
            for (f.generics.params) |g| {
                if (g.default) |d| visit(d, v);
            }
            for (f.where_clauses) |w| {
                for (w.predicates) |pred| {
                    if (pred.ty) |t| visit(t, v);
                    for (pred.bounds) |b| visit(b, v);
                }
            }
            for (f.params) |p| {
                visit(p.pat, v);
                if (p.ty) |t| visit(t, v);
            }
            if (f.ret) |r| visit(r, v);
            if (f.body) |b| visit(b, v);
        },
        .struct_item => |s| {
            for (s.fields) |fd| visit(fd.ty, v);
        },
        .enum_item => |e| {
            for (e.variants) |var_|
                switch (var_.kind) {
                    .unit => {},
                    .tuple, .fields => |fs| for (fs) |fd| visit(fd.ty, v),
                };
        },
        .union_item => |u| for (u.fields) |fd| visit(fd.ty, v),
        .trait_item => |t| for (t.items) |it| visit(it, v),
        .impl_item => |im| {
            visit(im.self_ty, v);
            if (im.trait_path) |tp| visit(tp, v);
            for (im.items) |it| visit(it, v);
        },
        .mod_item => |m| {
            if (m.items) |items| for (items) |it| visit(it, v);
        },
        .type_alias => |ta| visit(ta.ty, v),
        .const_item => |c| {
            if (c.ty) |t| visit(t, v);
            if (c.value) |val| visit(val, v);
        },
        .static_item => |s| {
            if (s.ty) |t| visit(t, v);
            if (s.value) |val| visit(val, v);
        },
        .let_stmt => |l| {
            visit(l.pat, v);
            if (l.ty) |t| visit(t, v);
            if (l.init) |i| visit(i, v);
            if (l.else_block) |eb| visit(eb, v);
        },
        .expr_stmt => |e| visit(e.expr, v),
        .item_stmt => |e| visit(e.item, v),
        .block_expr => |b| {
            for (b.stmts) |s| visit(s, v);
            if (b.value) |val| visit(val, v);
        },
        .if_expr => |i| {
            for (i.conds) |c| {
                visit(c.pat, v);
                if (c.value) |val| visit(val, v);
                if (c.ty) |t| visit(t, v);
            }
            visit(i.then_block, v);
            if (i.else_expr) |e| visit(e, v);
        },
        .match_expr => |m| {
            visit(m.scrutinee, v);
            for (m.arms) |a| {
                visit(a.pat, v);
                if (a.guard) |g| visit(g, v);
                visit(a.body, v);
            }
        },
        .loop_expr => |l| visit(l.body, v),
        .while_expr => |w| {
            visit(w.cond, v);
            visit(w.body, v);
        },
        .for_expr => |fe| {
            visit(fe.pat, v);
            visit(fe.iter, v);
            visit(fe.body, v);
        },
        .break_expr => |b| if (b.value) |val| visit(val, v),
        .return_expr => |r| if (r.value) |val| visit(val, v),
        .closure_expr => |c| {
            for (c.params) |p| {
                visit(p.pat, v);
                if (p.ty) |t| visit(t, v);
            }
            if (c.ret) |r| visit(r, v);
            visit(c.body, v);
        },
        .range_expr => |r| {
            if (r.start) |s| visit(s, v);
            if (r.end) |e| visit(e, v);
        },
        .binary_expr => |b| {
            visit(b.lhs, v);
            visit(b.rhs, v);
        },
        .assign_expr => |a| {
            visit(a.lhs, v);
            visit(a.rhs, v);
        },
        .assign_op_expr => |a| {
            visit(a.lhs, v);
            visit(a.rhs, v);
        },
        .unary_expr => |u| visit(u.expr, v),
        .borrow_expr => |b| visit(b.inner, v),
        .deref_expr => |d| visit(d.inner, v),
        .try_expr => |t| visit(t.inner, v),
        .unsafe_expr => |u| visit(u.block, v),
        .async_expr => |a| visit(a.block, v),
        .await_expr => |a| visit(a.inner, v),
        .paren_expr => |p| visit(p.inner, v),
        .cast_expr => |c| {
            visit(c.expr, v);
            visit(c.ty, v);
        },
        .call_expr => |c| {
            visit(c.callee, v);
            for (c.args) |a| visit(a.expr, v);
        },
        .method_call_expr => |m| {
            visit(m.receiver, v);
            for (m.args) |a| visit(a.expr, v);
        },
        .field_expr => |f| visit(f.base, v),
        .index_expr => |ix| {
            visit(ix.base, v);
            visit(ix.index, v);
        },
        .array_expr => |a| for (a.elems) |e| visit(e, v),
        .repeat_expr => |r| {
            visit(r.elem, v);
            visit(r.len, v);
        },
        .tuple_expr => |t| for (t.elems) |e| visit(e, v),
        .struct_expr => |s| for (s.fields) |fd| visit(fd.value, v),
        .ty_ref => |t| visit(t.inner, v),
        .ty_ptr => |t| visit(t.inner, v),
        .ty_tuple => |t| for (t.elems) |e| visit(e, v),
        .ty_array => |a| {
            visit(a.elem, v);
            if (a.len) |l| visit(l, v);
        },
        .ty_slice => |s| visit(s.elem, v),
        .ty_fn_ptr => |f| {
            for (f.params) |p| visit(p, v);
            if (f.ret) |r| visit(r, v);
        },
        .ty_impl_trait => |t| for (t.bounds) |b| visit(b, v),
        .ty_dyn_trait => |t| for (t.bounds) |b| visit(b, v),
        .pat_tuple => |p| for (p.elems) |e| visit(e, v),
        .pat_tuple_struct => |p| for (p.elems) |e| visit(e, v),
        .pat_slice => |p| for (p.elems) |e| visit(e, v),
        .pat_or => |p| for (p.alts) |e| visit(e, v),
        .pat_ref => |p| visit(p.pat, v),
        .pat_box => |p| visit(p.pat, v),
        .pat_range => |r| {
            if (r.start) |s| visit(s, v);
            if (r.end) |e| visit(e, v);
        },
        .pat_struct => |p| for (p.fields) |fd| {
            if (fd.pat) |pv| visit(pv, v);
        },
        .pat_ident => |p| {
            if (p.sub) |s| visit(s, v);
        },
        else => {},
    }
    if (v.post) |pst| pst(node, v.user);
}

test "pathText renders dotted paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // std::vec::Vec
    const segs = try a.alloc(PathSegment, 3);
    segs[0] = .{ .name = "std" };
    segs[1] = .{ .name = "vec" };
    segs[2] = .{ .name = "Vec" };
    const ty = try a.create(Node);
    ty.* = .{ .ty_path = .{ .segments = segs } };
    try std.testing.expectEqualStrings("std::vec::Vec", pathText(a, ty).?);
}

test "typeName takes the last segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = try a.alloc(PathSegment, 2);
    segs[0] = .{ .name = "core" };
    segs[1] = .{ .name = "option" };
    const ty = try a.create(Node);
    ty.* = .{ .ty_path = .{ .segments = segs } };
    try std.testing.expectEqualStrings("option", typeName(ty).?);
}

test "unparen strips nesting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try a.create(Node);
    inner.* = .{ .ty_never = .{} };
    const mid = try a.create(Node);
    mid.* = .{ .paren_expr = .{ .inner = inner } };
    const outer = try a.create(Node);
    outer.* = .{ .paren_expr = .{ .inner = mid } };
    try std.testing.expectEqual(inner, unparen(outer));
}

test "deriveList extracts trait names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attrs = try a.alloc(Attr, 2);
    attrs[0] = .{ .path = "inline" };
    attrs[1] = .{ .path = "derive", .args = "Debug, Clone" };
    const out = try deriveList(a, attrs);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("Debug", out[0]);
    try std.testing.expectEqualStrings("Clone", out[1]);
}
