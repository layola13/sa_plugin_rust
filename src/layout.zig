//! Memory layout computation for Rust types, expressed in SA-ASM `#def` terms.
//!
//! SA has no aggregate syntax: a `struct` is a set of `#def` constants
//! (`SIZE` plus one offset per field) plus `alloc`/`load`/`store`. SA's
//! convention, taken from `sa_std/core/*.sal` and the rosetta demos, is:
//!
//!   * primitives are 8-byte slots unless their natural size is smaller;
//!   * every field is 8-byte aligned, so offsets are `+0, +8, +16, ...`;
//!   * an enum is `[tag(u64 at +0) | payload(max variant payload, +8)]`;
//!   * a fat pointer is `[data(8) | len(8)]`, a growable one `[data | len | cap]`.
//!
//! Keeping the layout in one place means `lower.zig` never has to reason about
//! sizes, and the emitted `#def` block is a pure function of the type set.

const std = @import("std");
const ast = @import("ast.zig");

/// Explicit byte values: `@intFromEnum` is the alignment size, so the tags
/// must not be the enum's ordinals.
pub const Alignment = enum(u8) {
    a1 = 1,
    a2 = 2,
    a4 = 4,
    a8 = 8,

    pub fn bytes(self: Alignment) u64 {
        return @intFromEnum(self);
    }
};

/// The stricter of two alignments.
pub fn stricter(a: Alignment, b: Alignment) Alignment {
    return if (a.bytes() >= b.bytes()) a else b;
}

pub const Scalar = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    f32,
    f64,
    bool,
    char,
    /// `str` and `String`: a `[ptr, len]` pair.
    str,
    /// `()` — zero sized.
    unit,
    /// A raw pointer.
    ptr,
    /// `!` — never used as a value.
    never,

    /// The SA primitive name used in signatures (`i32`, `ptr`, ...).
    pub fn saName(self: Scalar) []const u8 {
        return switch (self) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .i128 => "i64",
            .isize => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .u128 => "u64",
            .usize => "u64",
            .f32 => "f32",
            .f64 => "f64",
            .bool => "i1",
            .char => "u32",
            .str => "ptr",
            .unit => "void",
            .ptr => "ptr",
            .never => "void",
        };
    }

    pub fn isUnsigned(self: Scalar) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .u128, .usize, .bool, .char => true,
            else => false,
        };
    }

    pub fn isFloat(self: Scalar) bool {
        return self == .f32 or self == .f64;
    }

    /// Natural size in bytes. The generated `#def` layout uses natural sizes
    /// and natural alignment, matching what the SA reference compiler emits
    /// (three `u8` fields occupy `alloc 3`, not `alloc 24`).
    pub fn slotSize(self: Scalar) u64 {
        return switch (self) {
            .i8, .u8, .bool => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32, .char => 4,
            .i64, .u64, .f64, .isize, .usize, .i128, .u128, .ptr => 8,
            .str => 16,
            .unit, .never => 0,
        };
    }

    pub fn alignment(self: Scalar) Alignment {
        return switch (self) {
            .i8, .u8, .bool => .a1,
            .i16, .u16 => .a2,
            .i32, .u32, .f32, .char => .a4,
            else => .a8,
        };
    }
};

pub fn scalarFromName(name: []const u8) ?Scalar {
    const table = .{
        .{ "i8", Scalar.i8 },
        .{ "i16", Scalar.i16 },
        .{ "i32", Scalar.i32 },
        .{ "i64", Scalar.i64 },
        .{ "i128", Scalar.i128 },
        .{ "isize", Scalar.isize },
        .{ "u8", Scalar.u8 },
        .{ "u16", Scalar.u16 },
        .{ "u32", Scalar.u32 },
        .{ "u64", Scalar.u64 },
        .{ "u128", Scalar.u128 },
        .{ "usize", Scalar.usize },
        .{ "f32", Scalar.f32 },
        .{ "f64", Scalar.f64 },
        .{ "bool", Scalar.bool },
        .{ "char", Scalar.char },
        .{ "str", Scalar.str },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// How a Rust aggregate maps onto SA memory.
pub const Shape = enum {
    /// A single 8-byte cell.
    scalar,
    /// `[tag | payload]`, the SA enum representation.
    tagged_union,
    /// All fields overlap at offset 0.
    union_,
    /// A plain sequence of fields.
    record,
    /// `[data_ptr, len]`.
    fat_ptr,
    /// `[data_ptr, len, cap]`.
    growable_ptr,
    /// An opaque user type: a `ptr`-sized handle to heap storage.
    opaque_handle,

    pub fn isAggregate(self: Shape) bool {
        return switch (self) {
            .scalar, .opaque_handle => false,
            else => true,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    offset: i64,
    size: u64,
    ty: *ast.Node,
    /// Tuple-struct / tuple index for positional aggregates.
    index: usize = 0,
};

pub const VariantLayout = struct {
    name: []const u8,
    tag: u64,
    fields: []const Field = &.{},
    /// Payload size reserved for this variant.
    payload: u64 = 0,
    discriminant: ?i64 = null,
};

pub const Layout = struct {
    /// Emitted type name, after monomorphization (e.g. `Point_i32`).
    name: []const u8,
    size: u64 = 0,
    alignment: Alignment = .a8,
    shape: Shape = .scalar,
    fields: []const Field = &.{},
    variants: []const VariantLayout = &.{},
    /// Set for `str`/`String`/`Vec<T>`/`&[T]`: element size and count.
    elem: ?*ast.Node = null,
    elem_size: u64 = 0,
    /// The Rust type this layout was computed from, for diagnostics.
    ty: ?*ast.Node = null,

    pub fn fieldByName(self: Layout, name: []const u8) ?Field {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn variantByName(self: Layout, name: []const u8) ?VariantLayout {
        for (self.variants) |v| {
            if (std.mem.eql(u8, v.name, name)) return v;
        }
        return null;
    }

    /// The single SA primitive this type lowers to, if any.
    pub fn scalar(self: Layout) ?Scalar {
        if (self.shape == .scalar) {
            if (self.ty) |t| {
                if (ast.typeName(t)) |n| {
                    if (scalarFromName(n)) |s| return s;
                }
            }
        }
        return null;
    }
};

fn alignUp(value: u64, alignment: Alignment) u64 {
    const a = alignment.bytes();
    if (a <= 1) return value;
    const rem = value % a;
    if (rem == 0) return value;
    return value + (a - rem);
}

/// The layout engine.
///
/// It is fed a *name resolver* callback so that monomorphized type names
/// (`Point<i32>` -> `Point_i32`) and user-defined aggregates can be found
/// without this file knowing about the monomorphizer.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Look up a user-defined type by its (already monomorphized) Rust name.
    lookup: *const fn (ctx: *anyopaque, name: []const u8) ?*ast.Node,
    ctx: *anyopaque,
    cache: std.StringHashMapUnmanaged(Layout) = .empty,
    /// Names of types currently being laid out, to break recursive layouts by
    /// falling back to an opaque pointer-sized handle.
    in_progress: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        lookup: *const fn (ctx: *anyopaque, name: []const u8) ?*ast.Node,
        ctx: *anyopaque,
    ) Engine {
        return .{
            .allocator = allocator,
            .lookup = lookup,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.cache.deinit(self.allocator);
        self.in_progress.deinit(self.allocator);
    }

    /// Compute (and memoise) the layout of `ty` under the emitted name `name`.
    pub fn layoutOf(self: *Engine, name: []const u8, ty: *ast.Node) LayoutError!Layout {
        if (self.cache.get(name)) |cached| return cached;
        if (self.in_progress.contains(name)) {
            // Recursive type (e.g. `struct Node { next: *mut Node }` expressed
            // by value). Represent the cycle as an opaque handle.
            return .{
                .name = name,
                .size = 8,
                .alignment = .a8,
                .shape = .opaque_handle,
                .ty = ty,
            };
        }
        try self.in_progress.put(self.allocator, name, {});
        defer _ = self.in_progress.remove(name);

        const result = try self.compute(name, ty);
        try self.cache.put(self.allocator, name, result);
        return result;
    }

    fn compute(self: *Engine, name: []const u8, ty: *ast.Node) LayoutError!Layout {
        const t = ast.unparen(ty);
        switch (t.*) {
            .ty_path => |p| {
                const last = p.segments[p.segments.len - 1].name;
                if (scalarFromName(last)) |s| {
                    if (s == .str) {
                        return .{
                            .name = name,
                            .size = 16,
                            .alignment = .a8,
                            .shape = .fat_ptr,
                            .ty = ty,
                        };
                    }
                    return .{
                        .name = name,
                        .size = s.slotSize(),
                        .alignment = s.alignment(),
                        .shape = .scalar,
                        .ty = ty,
                    };
                }
                // Standard-library shapes with a fixed representation.
                if (std.mem.eql(u8, last, "String")) {
                    return .{ .name = name, .size = 16, .alignment = .a8, .shape = .fat_ptr, .ty = ty };
                }
                if (std.mem.eql(u8, last, "Vec") or std.mem.eql(u8, last, "VecDeque")) {
                    const elem = if (p.segments[p.segments.len - 1].args.len > 0)
                        p.segments[p.segments.len - 1].args[0].ty
                    else
                        null;
                    return .{
                        .name = name,
                        .size = 24,
                        .alignment = .a8,
                        .shape = .growable_ptr,
                        .elem = elem,
                        .ty = ty,
                    };
                }
                if (std.mem.eql(u8, last, "Box") or std.mem.eql(u8, last, "Rc") or
                    std.mem.eql(u8, last, "Arc") or std.mem.eql(u8, last, "HashMap") or
                    std.mem.eql(u8, last, "HashSet") or std.mem.eql(u8, last, "BTreeMap") or
                    std.mem.eql(u8, last, "BTreeSet") or std.mem.eql(u8, last, "RefCell") or
                    std.mem.eql(u8, last, "Cell") or std.mem.eql(u8, last, "Mutex") or
                    std.mem.eql(u8, last, "RwLock"))
                {
                    return .{ .name = name, .size = 8, .shape = .opaque_handle, .ty = ty };
                }
                if (std.mem.eql(u8, last, "Option") or std.mem.eql(u8, last, "Result")) {
                    // Mapped onto `sa_std/core/option.sal` / `result.sal`.
                    return .{
                        .name = name,
                        .size = 16,
                        .alignment = .a8,
                        .shape = .tagged_union,
                        .ty = ty,
                    };
                }
                // A user-defined aggregate, if the resolver knows it.
                if (self.lookup(self.ctx, last)) |def| {
                    return self.layoutAggregate(name, def, ty);
                }
                // Unknown nominal type: treat it as an opaque handle.
                return .{ .name = name, .size = 8, .shape = .opaque_handle, .ty = ty };
            },
            .ty_ref => |r| {
                // A reference is one word *unless* it points at something that is
                // itself a fat pointer. `&str`, `&[T]` and `&dyn Trait` are
                // `[data, len]`, so the reference is two words. Decided from the
                // referent's shape rather than its size: a `[i32; 4]` and an `i128`
                // are also 16 bytes, and `&` of either is a single pointer.
                const inner = ast.unparen(r.inner);
                const fat = switch (inner.*) {
                    .ty_slice, .ty_dyn_trait => true,
                    .ty_path => |p| blk: {
                        const leaf = if (p.segments.len == 0) "" else p.segments[p.segments.len - 1].name;
                        break :blk std.mem.eql(u8, leaf, "str");
                    },
                    else => false,
                };
                if (fat) {
                    return .{ .name = name, .size = 16, .alignment = .a8, .shape = .fat_ptr, .ty = ty };
                }
                return .{ .name = name, .size = 8, .alignment = .a8, .shape = .scalar, .ty = ty };
            },
            .ty_ptr => {
                // Raw pointers are always one word.
                return .{ .name = name, .size = 8, .alignment = .a8, .shape = .scalar, .ty = ty };
            },
            .ty_slice => return .{ .name = name, .size = 16, .alignment = .a8, .shape = .fat_ptr, .ty = ty },
            .ty_array => |arr| {
                const elem_layout = try self.layoutOf(try self.childName(name, "e"), arr.elem);
                const count: u64 = if (arr.len) |len_expr| @intCast(@max(constIntOf(len_expr) orelse 0, 0)) else 0;
                return .{
                    .name = name,
                    .size = @max(elem_layout.size * count, 8),
                    .shape = .record,
                    .elem = arr.elem,
                    .elem_size = elem_layout.size,
                    .ty = ty,
                };
            },
            .ty_tuple => |tp| {
                if (tp.is_unit or tp.elems.len == 0) {
                    return .{ .name = name, .size = 0, .shape = .record, .ty = ty };
                }
                return self.layoutTuple(name, tp.elems, ty);
            },
            .ty_fn_ptr => return .{ .name = name, .size = 8, .shape = .scalar, .ty = ty },
            .ty_never => return .{ .name = name, .size = 0, .shape = .scalar, .ty = ty },
            .ty_infer => return .{ .name = name, .size = 8, .shape = .scalar, .ty = ty },
            .ty_dyn_trait => return .{ .name = name, .size = 16, .shape = .fat_ptr, .ty = ty },
            .ty_impl_trait => {
                if (self.lookup(self.ctx, name)) |def| return self.layoutAggregate(name, def, ty);
                return .{ .name = name, .size = 8, .shape = .opaque_handle, .ty = ty };
            },
            .paren_expr => |pe| return self.layoutOf(name, pe.inner),
            .literal => return .{ .name = name, .size = 8, .shape = .scalar, .ty = ty },
            else => return .{ .name = name, .size = 8, .shape = .opaque_handle, .ty = ty },
        }
    }

    fn layoutAggregate(self: *Engine, name: []const u8, def: *ast.Node, ty: *ast.Node) LayoutError!Layout {
        switch (def.*) {
            .struct_item => |s| {
                if (s.is_unit) {
                    return .{ .name = name, .size = 0, .shape = .record, .ty = ty };
                }
                var field_tys: []const *ast.Node = undefined;
                _ = &field_tys;
                return self.layoutFields(name, s.fields, ty);
            },
            .enum_item => |e| return self.layoutEnum(name, e, ty),
            .union_item => |u| return self.layoutUnion(name, u.fields, ty),
            .type_alias => |ta| return self.layoutOf(name, ta.ty),
            else => return .{ .name = name, .size = 8, .shape = .opaque_handle, .ty = ty },
        }
    }

    fn layoutFields(
        self: *Engine,
        name: []const u8,
        fields: []const ast.FieldDef,
        ty: ?*ast.Node,
    ) LayoutError!Layout {
        var out: std.ArrayList(Field) = .init(self.allocator);
        defer out.deinit();
        var offset: u64 = 0;
        var struct_align: Alignment = .a1;
        for (fields, 0..) |f, i| {
            const field_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, f.name });
            const fl = try self.layoutOf(field_name, f.ty);
            struct_align = stricter(struct_align, fl.alignment);
            offset = alignUp(offset, fl.alignment);
            try out.append(.{
                .name = f.name,
                .offset = @intCast(offset),
                .size = @max(fl.size, 1),
                .ty = f.ty,
                .index = i,
            });
            offset += @max(fl.size, 1);
        }
        return .{
            .name = name,
            .size = alignUp(offset, struct_align),
            .alignment = struct_align,
            .shape = .record,
            .fields = try out.toOwnedSlice(),
            .ty = ty,
        };
    }

    fn layoutTuple(self: *Engine, name: []const u8, elems: []const *ast.Node, ty: ?*ast.Node) LayoutError!Layout {
        var defs: std.ArrayList(ast.FieldDef) = .init(self.allocator);
        defer defs.deinit();
        for (elems, 0..) |e, i| {
            try defs.append(.{
                .name = try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
                .ty = e,
            });
        }
        return self.layoutFields(name, defs.items, ty);
    }

    fn layoutUnion(self: *Engine, name: []const u8, fields: []const ast.FieldDef, ty: ?*ast.Node) LayoutError!Layout {
        const laid = try self.layoutFields(name, fields, ty);
        var max_size: u64 = 8;
        for (laid.fields) |f| max_size = @max(max_size, f.size);
        // All members start at offset 0 in a union.
        var shifted: std.ArrayList(Field) = .init(self.allocator);
        defer shifted.deinit();
        for (laid.fields) |f| {
            try shifted.append(.{ .name = f.name, .offset = 0, .size = f.size, .ty = f.ty, .index = f.index });
        }
        return .{
            .name = name,
            .size = max_size,
            .shape = .union_,
            .fields = try shifted.toOwnedSlice(),
            .ty = ty,
        };
    }

    fn layoutEnum(self: *Engine, name: []const u8, e: ast.EnumItem, ty: ?*ast.Node) LayoutError!Layout {
        // Tag occupies the first cell; every variant payload is reserved at +8.
        var variants: std.ArrayList(VariantLayout) = .init(self.allocator);
        defer variants.deinit();
        var max_payload: u64 = 0;
        var next_tag: u64 = 0;

        for (e.variants) |v| {
            var disc: ?i64 = null;
            if (v.discriminant) |dexpr| {
                if (constIntOf(dexpr)) |d| {
                    disc = d;
                    next_tag = @intCast(@as(u64, @bitCast(d)));
                }
            }
            const tag = next_tag;
            next_tag += 1;

            var fields: std.ArrayList(Field) = .init(self.allocator);
            var payload: u64 = 0;
            const field_defs: []const ast.FieldDef = switch (v.kind) {
                .unit => &.{},
                .tuple, .fields => |fs| fs,
            };
            if (field_defs.len > 0) {
                const vname = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, v.name });
                const laid = try self.layoutFields(vname, field_defs, null);
                for (laid.fields) |f| {
                    try fields.append(.{ .name = f.name, .offset = f.offset + 8, .size = f.size, .ty = f.ty, .index = f.index });
                    payload = @max(payload, f.size + 8);
                }
            }
            max_payload = @max(max_payload, payload);
            try variants.append(.{
                .name = v.name,
                .tag = tag,
                .fields = try fields.toOwnedSlice(),
                .payload = payload,
                .discriminant = disc,
            });
        }

        return .{
            .name = name,
            .size = 8 + @max(max_payload, 8),
            .alignment = .a8,
            .shape = .tagged_union,
            .variants = try variants.toOwnedSlice(),
            .ty = ty,
        };
    }

    fn childName(self: *Engine, parent: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ parent, suffix });
    }
};

/// Best-effort constant folding of a literal-only expression.
pub fn constIntOf(node: *ast.Node) ?i64 {
    switch (node.*) {
        .literal => |l| switch (l) {
            .int => |iv| return parseIntLiteral(iv.digits, iv.base),
            .bool_ => |b| return @intFromBool(b),
            .char_ => |c| return @intCast(c),
            else => return null,
        },
        .paren_expr => |pe| return constIntOf(pe.inner),
        .unary_expr => |u| {
            const inner = constIntOf(u.expr) orelse return null;
            return switch (u.op) {
                .neg => -inner,
                .not => ~inner,
                .deref => null,
            };
        },
        .binary_expr => |b| {
            const l = constIntOf(b.lhs) orelse return null;
            const r = constIntOf(b.rhs) orelse return null;
            return switch (b.op) {
                .add => l +% r,
                .sub => l -% r,
                .mul => l *% r,
                .div => if (r == 0) null else @divTrunc(l, r),
                .rem => if (r == 0) null else @rem(l, r),
                .bit_and => l & r,
                .bit_or => l | r,
                .bit_xor => l ^ r,
                .shl => if (r >= 0 and r < 64) l << @intCast(r) else null,
                .shr => if (r >= 0 and r < 64) l >> @intCast(r) else null,
                .bool_and => @intFromBool(l != 0 and r != 0),
                .bool_or => @intFromBool(l != 0 or r != 0),
                else => null,
            };
        },
        .cast_expr => |c| return constIntOf(c.expr),
        .index_expr => |ix| {
            const base = constIntOf(ix.base) orelse return null;
            const idx = constIntOf(ix.index) orelse return null;
            return @bitCast(@as(u64, @bitCast(base)) +% @as(u64, @intCast(idx)) * 8);
        },
        else => return null,
    }
}

/// Parse an integer literal, including the leading `-` the parser folds in.
///
/// The sign has to be handled here: the parser turns `-1` into a literal whose
/// digits are `"-1"`, so a parser that only accepts digits returns null and the
/// caller substitutes 0. That turned every negative constant in a program into
/// a silent zero.
/// A parsed integer literal, kept as an unsigned magnitude plus a sign.
///
/// The magnitude is a `u64` rather than an `i64` on purpose: `u64::MAX` fits a
/// `u64` but not an `i64`, and bitcasting the accumulator turned it into `-1` --
/// a wrong answer with no diagnostic. `SA` accepts a full-width decimal
/// immediate, so the value can be emitted as text.
pub const IntValue = struct {
    magnitude: u64,
    negative: bool,
};

/// Parse an integer literal into its magnitude and sign.
///
/// Checked: an accumulation that leaves `u64` returns null rather than wrapping,
/// so a literal that is too large to be represented is reported instead of
/// silently becoming some other number.
pub fn parseIntValue(digits: []const u8, base: ast.IntBase) ?IntValue {
    const radix: u8 = switch (base) {
        .dec => 10,
        .hex => 16,
        .oct => 8,
        .bin => 2,
    };
    const negative = digits.len > 0 and digits[0] == '-';
    const body = if (negative) digits[1..] else digits;
    var acc: u64 = 0;
    for (body) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return null;
        acc = std.math.add(u64, std.math.mul(u64, acc, radix) catch return null, d) catch return null;
    }
    return .{ .magnitude = acc, .negative = negative };
}

/// The literal's text in SA's decimal syntax, or null when it does not fit a
/// `u64`. This is what a pattern or a `let` should emit: going through `i64`
/// would rewrite `18446744073709551615` as `-1`.
pub fn intLiteralText(allocator: std.mem.Allocator, digits: []const u8, base: ast.IntBase) !?[]const u8 {
    const v = parseIntValue(digits, base) orelse return null;
    if (v.negative) return try std.fmt.allocPrint(allocator, "-{d}", .{v.magnitude});
    return try std.fmt.allocPrint(allocator, "{d}", .{v.magnitude});
}

pub fn parseIntLiteral(digits: []const u8, base: ast.IntBase) ?i64 {
    const v = parseIntValue(digits, base) orelse return null;
    if (!v.negative) {
        // Only a value that fits a signed register can be printed as one.
        if (v.magnitude > std.math.maxInt(i64)) return null;
        return @intCast(v.magnitude);
    }
    if (v.magnitude > @as(u64, 1) << 63) return null;
    // Two's-complement negate, so `i64::MIN` (magnitude exactly 2^63) works
    // instead of overflowing the cast.
    return @bitCast(~v.magnitude +% 1);
}

pub const LayoutError = error{
    RecursiveType,
    OutOfMemory,
};

/// `ty_path` for a single named segment.
fn pathSeg(allocator: std.mem.Allocator, name: []const u8) ![]const ast.PathSegment {
    const segs = try allocator.alloc(ast.PathSegment, 1);
    segs[0] = .{ .name = name };
    return segs;
}

test "scalar layouts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const noLookup = struct {
        fn f(_: *anyopaque, _: []const u8) ?*ast.Node {
            return null;
        }
    }.f;
    var e = Engine.init(a, noLookup, undefined);
    defer e.deinit();

    const i32ty = try a.create(ast.Node);
    i32ty.* = .{ .ty_path = .{ .segments = try pathSeg(a, "i32") } };
    const l = try e.layoutOf("t", i32ty);
    try std.testing.expectEqual(Shape.scalar, l.shape);
    try std.testing.expectEqual(@as(u64, 4), l.size);
    try std.testing.expectEqual(Alignment.a4, l.alignment);
    try std.testing.expectEqualStrings("i32", l.scalar().?.saName());
}

test "record layout uses natural sizes and alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const noLookup = struct {
        fn f(_: *anyopaque, _: []const u8) ?*ast.Node {
            return null;
        }
    }.f;
    var e = Engine.init(a, noLookup, undefined);
    defer e.deinit();

    const i32ty = try a.create(ast.Node);
    i32ty.* = .{ .ty_path = .{ .segments = try pathSeg(a, "i32") } };
    const f64ty = try a.create(ast.Node);
    f64ty.* = .{ .ty_path = .{ .segments = try pathSeg(a, "f64") } };

    const fields = try a.alloc(ast.FieldDef, 3);
    fields[0] = .{ .name = "x", .ty = i32ty };
    fields[1] = .{ .name = "y", .ty = f64ty };
    fields[2] = .{ .name = "flag", .ty = i32ty };

    const tuple_elems = try a.alloc(*ast.Node, 3);
    tuple_elems[0] = i32ty;
    tuple_elems[1] = f64ty;
    tuple_elems[2] = i32ty;
    const tp = try a.create(ast.Node);
    tp.* = .{ .ty_tuple = .{ .elems = tuple_elems } };

    // (i32, f64, i32): 4 + 4 pad + 8 + 4 pad -> aligned to 8 => 24 bytes.
    const l = try e.layoutOf("T", tp);
    try std.testing.expectEqual(Shape.record, l.shape);
    try std.testing.expectEqual(@as(u64, 24), l.size);
    try std.testing.expectEqual(@as(i64, 0), l.fields[0].offset);
    try std.testing.expectEqual(@as(i64, 8), l.fields[1].offset);
    try std.testing.expectEqual(@as(i64, 16), l.fields[2].offset);
    try std.testing.expectEqual(Alignment.a8, l.alignment);
}

test "a &str field reserves two words, a &scalar one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const strty = try a.create(ast.Node);
    strty.* = .{ .ty_path = .{ .segments = try pathSeg(a, "str") } };
    const str_ref = try a.create(ast.Node);
    str_ref.* = .{ .ty_ref = .{ .inner = strty } };
    const i32ty = try a.create(ast.Node);
    i32ty.* = .{ .ty_path = .{ .segments = try pathSeg(a, "i32") } };
    const i32_ref = try a.create(ast.Node);
    i32_ref.* = .{ .ty_ref = .{ .inner = i32ty } };

    const fields = try a.alloc(ast.FieldDef, 2);
    fields[0] = .{ .name = "label", .ty = str_ref };
    fields[1] = .{ .name = "rank", .ty = i32ty };
    const si = try a.create(ast.Node);
    si.* = .{ .struct_item = .{ .name = "Tag", .fields = fields } };

    // The resolver answers for `Tag` only, so a bare name is opaque unless the
    // struct is found -- which is what makes the offsets below meaningful. The
    // struct node rides along in the engine's context pointer.
    const tag_def: *ast.Node = si;
    const Lookup = struct {
        fn f(ctx: *anyopaque, name: []const u8) ?*ast.Node {
            if (std.mem.eql(u8, name, "Tag")) return @ptrCast(@alignCast(ctx));
            return null;
        }
    };
    var e = Engine.init(a, Lookup.f, tag_def);
    defer e.deinit();

    // `&str` is `[data, len]`, so a field of that type is 16 bytes wide. Sizing it
    // as one word put the length on top of whatever field came next, and reading
    // `t.label.len()` then returned the neighbouring field's value -- a plausible
    // number rather than a trap, which is the worst kind of miscompile.
    const ls = try e.layoutOf("S", str_ref);
    try std.testing.expectEqual(@as(u64, 16), ls.size);
    try std.testing.expectEqual(Shape.fat_ptr, ls.shape);

    // A reference to a scalar is still one word.
    const li = try e.layoutOf("I", i32_ref);
    try std.testing.expectEqual(@as(u64, 8), li.size);

    const tag_ref = try a.create(ast.Node);
    tag_ref.* = .{ .ty_path = .{ .segments = try pathSeg(a, "Tag") } };
    const lt = try e.layoutOf("Tag", tag_ref);
    try std.testing.expectEqual(@as(u64, 24), lt.size);
    try std.testing.expectEqual(@as(i64, 0), lt.fields[0].offset);
    try std.testing.expectEqual(@as(i64, 16), lt.fields[1].offset);
}

test "const int folding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try a.create(ast.Node);
    one.* = .{ .literal = .{ .int = .{ .digits = "2" } } };
    const two = try a.create(ast.Node);
    two.* = .{ .literal = .{ .int = .{ .digits = "3" } } };
    const add = try a.create(ast.Node);
    add.* = .{ .binary_expr = .{ .op = .add, .lhs = one, .rhs = two } };
    const mul = try a.create(ast.Node);
    mul.* = .{ .binary_expr = .{ .op = .mul, .lhs = add, .rhs = two } };
    try std.testing.expectEqual(@as(i64, 15), constIntOf(mul).?);
}

test "negative integer literals keep their sign" {
    // Regression: the leading `-` was rejected as a non-digit, so every negative
    // constant folded to 0.
    try std.testing.expectEqual(@as(?i64, -1), parseIntLiteral("-1", .dec));
    try std.testing.expectEqual(@as(?i64, -42), parseIntLiteral("-42", .dec));
    try std.testing.expectEqual(@as(?i64, -255), parseIntLiteral("-ff", .hex));
    try std.testing.expectEqual(@as(?i64, 7), parseIntLiteral("7", .dec));
    try std.testing.expectEqual(@as(?i64, 0), parseIntLiteral("-0", .dec));
}

test "an integer literal is not wrapped when it leaves u64" {
    // Regression: the accumulator wrapped (`acc *% radix`), then the result was
    // bitcast to `i64`, so `u64::MAX` became `-1`. A pattern built from it
    // compared against the exact opposite value, silently.
    try std.testing.expectEqual(@as(?i64, null), parseIntLiteral("18446744073709551616", .dec));
    try std.testing.expectEqual(@as(?i64, null), parseIntLiteral("18446744073709551615", .dec));
    // `i64::MIN` has magnitude exactly 2^63 and must survive the negate.
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), parseIntLiteral("-9223372036854775808", .dec));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseIntLiteral("9223372036854775807", .dec));
}

test "a full-width literal keeps its text" {
    // `SA` accepts a full-width decimal immediate, so the text is what must be
    // emitted: routing it through `i64` would print `-1`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = (try intLiteralText(a, "18446744073709551615", .dec)).?;
    try std.testing.expectEqualStrings("18446744073709551615", text);
    const neg = (try intLiteralText(a, "-9223372036854775808", .dec)).?;
    try std.testing.expectEqualStrings("-9223372036854775808", neg);
    // Beyond `u64` there is nothing to emit.
    try std.testing.expectEqual(@as(?[]const u8, null), try intLiteralText(a, "18446744073709551616", .dec));
}
