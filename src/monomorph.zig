//! Generic instantiation planning for the Rust backend.
//!
//! Rust generics are erased at the SA-ASM level: `fn sum<T>(p: T, q: T)` has
//! exactly one body, so the body must be lowered once per concrete type
//! argument. This module owns the *planning* half of that: it decides which
//! `(template, type arguments)` pairs exist and mangles a name for each.
//!
//! The substitution is deliberately **not** an AST rewrite. Cloning a whole
//! `ast.Node` tree per instance would duplicate every variant of the union for
//! a mapping that is only ever consulted by name. Instead the body AST is
//! shared and the lowerer is told which type parameter stands for which concrete
//! type while it lowers an instance, so `T` resolves through `typeFor` exactly
//! like a spelled-out type would. Field offsets, alignment and `#def` emission
//! then follow from the real layout instead of a guess.
//!
//! Supported today: generic **functions**. A generic `struct`/`enum` is left
//! alone -- its type parameters stay opaque, which the lowerer already treats as
//! pointer-like, so nothing regresses, it just gains no precision.

const std = @import("std");
const ast = @import("ast.zig");

pub const Error = error{
    /// A generic function recursed into more instances than the planner allows.
    /// Reported rather than looping forever on a self-instantiating signature.
    InstanceLimitExceeded,
    OutOfMemory,
};

/// Hard cap on distinct instances. A monomorphising compiler that hits this is
/// looking at unbounded recursion, which is a compile error in Rust too.
pub const max_instances: usize = 256;

pub const Instance = struct {
    /// Name of the generic function this instance came from.
    template: []const u8,
    /// Unique emitted name, e.g. `sum__Pair`.
    mangle: []const u8,
    /// Type parameter name -> concrete type node.
    subst: std.StringHashMapUnmanaged(*ast.Node) = .empty,
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    /// `name|Arg1_Arg2` -> mangle, so a second call site reuses the instance.
    by_key: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Every mangled name handed out, so two different type arguments can never
    /// collide onto one symbol.
    taken_mangles: std.StringHashMapUnmanaged(void) = .empty,
    /// Instances in discovery order; each is emitted once, at the end.
    instances: std.ArrayList(Instance) = undefined,

    pub fn init(allocator: std.mem.Allocator) Planner {
        return .{ .allocator = allocator, .instances = .init(allocator) };
    }

    pub fn deinit(self: *Planner) void {
        for (self.instances.items) |*inst| {
            inst.subst.deinit(self.allocator);
            self.allocator.free(inst.mangle);
        }
        self.instances.deinit();
        self.by_key.deinit(self.allocator);
        self.taken_mangles.deinit(self.allocator);
    }

    /// Record a new instance, or return the mangle of the existing one.
    ///
    /// `type_args` must be in the same order as the template's type parameters.
    pub fn intern(
        self: *Planner,
        template: []const u8,
        type_args: []const ?*ast.Node,
    ) Error![]const u8 {
        var key_buf: std.ArrayList(u8) = .init(self.allocator);
        defer key_buf.deinit();
        try key_buf.appendSlice(template);
        try key_buf.append('|');
        for (type_args) |maybe| {
            if (maybe) |t| try key_buf.appendSlice(tyKey(t));
            try key_buf.append('_');
        }

        if (self.by_key.get(key_buf.items)) |existing| return existing;
        // The map keeps the key, so it needs its own copy: `key_buf` is freed
        // on return and a dangling key would make every later hash read freed
        // memory.
        const key = try self.allocator.dupe(u8, key_buf.items);
        errdefer self.allocator.free(key);


        if (self.instances.items.len >= max_instances) return Error.InstanceLimitExceeded;

        // `sum__Pair_i32`: only the type name is kept, so the mangled name stays
        // a valid SA identifier and two different types never collide silently.
        var mangle: std.ArrayList(u8) = .init(self.allocator);
        errdefer mangle.deinit();
        try mangle.appendSlice(template);
        try mangle.appendSlice("__");
        for (type_args, 0..) |maybe, i| {
            if (i > 0) try mangle.append('_');
            if (maybe) |t| {
                for (tyKey(t)) |c| {
                    if (!std.ascii.isAlphanumeric(c)) continue;
                    try mangle.append(if (std.ascii.isUpper(c)) c else std.ascii.toUpper(c));
                }
            } else {
                try mangle.appendSlice("Any");
            }
        }
        // Distinct type arguments can flatten to the same text: `Vec<i32>` and a
        // type actually named `VecI32` both want `VECI32`. Sharing a name would
        // silently merge two unrelated instances, so a taken name gets a
        // deterministic numeric suffix.
        var owned = try self.allocator.dupe(u8, mangle.items);
        var bump: usize = 2;
        while (self.taken_mangles.contains(owned)) {
            self.allocator.free(owned);
            owned = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ mangle.items, bump });
            bump += 1;
        }
        try self.taken_mangles.put(self.allocator, owned, {});

        try self.instances.append(.{
            .template = template,
            .mangle = owned,
            .subst = .empty,
        });
        try self.by_key.put(self.allocator, key, owned);
        return owned;
    }

    pub fn find(self: *Planner, mangle: []const u8) ?*Instance {
        for (self.instances.items) |*inst| {
            if (std.mem.eql(u8, inst.mangle, mangle)) return inst;
        }
        return null;
    }

    /// A stable, printable identity for a type node, used in keys and names.
    pub fn tyKey(node: *ast.Node) []const u8 {
        return switch (node.*) {
            .ty_path => |tp| {
                if (tp.segments.len == 0) return "?";
                return tp.segments[tp.segments.len - 1].name;
            },
            .paren_expr => |pe| tyKey(pe.inner),
            .ty_ref => |r| tyKey(r.inner),
            .ty_tuple => return "tuple",
            .ty_array => return "array",
            .ty_slice => return "slice",
            else => @tagName(node.*),
        };
    }
};

/// The non-lifetime type parameters of a generic declaration, in order.
pub fn typeParamNames(g: ast.Generics, allocator: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .init(allocator);
    errdefer out.deinit();
    for (g.params) |p| {
        if (p.kind == .lifetime) continue;
        try out.append(p.name);
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// type-level instantiation
// ---------------------------------------------------------------------------

/// Rebuild `node` with every type parameter in `subst` replaced by its concrete
/// type. Nodes that mention no parameter are shared rather than copied, so the
/// common case allocates nothing.
///
/// Handles the type forms that can appear in a field or parameter position.
/// Anything else is returned unchanged, which keeps an unhandled form opaque
/// rather than wrong.
pub fn substituteType(
    node: *ast.Node,
    subst: *const std.StringHashMapUnmanaged(*ast.Node),
    allocator: std.mem.Allocator,
) Error!*ast.Node {
    if (subst.count() == 0) return node;
    switch (ast.unparen(node).*) {
        .ty_path => |tp| {
            if (tp.segments.len != 1) return node;
            if (subst.get(tp.segments[0].name)) |concrete| return concrete;
            return node;
        },
        .ty_ref => |r| {
            const inner = try substituteType(r.inner, subst, allocator);
            if (inner == r.inner) return node;
            return try allocNode(allocator, .{ .ty_ref = .{
                .inner = inner,
                .lifetime = r.lifetime,
                .is_mut = r.is_mut,
            } });
        },
        .ty_ptr => |p| {
            const inner = try substituteType(p.inner, subst, allocator);
            if (inner == p.inner) return node;
            return try allocNode(allocator, .{ .ty_ptr = .{
                .inner = inner,
                .is_mut = p.is_mut,
                .is_const = p.is_const,
            } });
        },
        .ty_array => |a| {
            const elem = try substituteType(a.elem, subst, allocator);
            if (elem == a.elem) return node;
            return try allocNode(allocator, .{ .ty_array = .{ .elem = elem, .len = a.len } });
        },
        .ty_slice => |sl| {
            const elem = try substituteType(sl.elem, subst, allocator);
            if (elem == sl.elem) return node;
            return try allocNode(allocator, .{ .ty_slice = .{ .elem = elem } });
        },
        .ty_tuple => |t| {
            if (t.is_unit) return node;
            var changed = false;
            const out = try allocator.alloc(*ast.Node, t.elems.len);
            for (t.elems, 0..) |e, i| {
                out[i] = try substituteType(e, subst, allocator);
                if (out[i] != e) changed = true;
            }
            if (!changed) return node;
            return try allocNode(allocator, .{ .ty_tuple = .{ .elems = out } });
        },
        else => return node,
    }
}

fn allocNode(allocator: std.mem.Allocator, value: ast.Node) Error!*ast.Node {
    const n = try allocator.create(ast.Node);
    n.* = value;
    return n;
}

/// Build the `struct_item` for one concrete instantiation of a generic struct.
///
/// Only the name and the field types change, so the variant tables and bodies
/// are shared with the template rather than deep-copied.
pub fn instantiateStruct(
    allocator: std.mem.Allocator,
    mangle: []const u8,
    template: ast.StructItem,
    subst: *const std.StringHashMapUnmanaged(*ast.Node),
) Error!*ast.Node {
    const fields = try allocator.alloc(ast.FieldDef, template.fields.len);
    for (template.fields, 0..) |f, i| {
        fields[i] = .{
            .name = f.name,
            .ty = try substituteType(f.ty, subst, allocator),
            .vis = f.vis,
            .attrs = f.attrs,
        };
    }
    return allocNode(allocator, .{ .struct_item = .{
        .name = mangle,
        .fields = fields,
        .is_tuple = template.is_tuple,
        .is_unit = template.is_unit,
        .vis = template.vis,
        .attrs = template.attrs,
    } });
}

/// Same idea for an enum: the tag is unchanged, only variant payload types move.
pub fn instantiateEnum(
    allocator: std.mem.Allocator,
    mangle: []const u8,
    template: ast.EnumItem,
    subst: *const std.StringHashMapUnmanaged(*ast.Node),
) Error!*ast.Node {
    const variants = try allocator.alloc(ast.Variant, template.variants.len);
    for (template.variants, 0..) |v, i| {
        var nv = v;
        nv.name = v.name;
        switch (v.kind) {
            .unit => {},
            .tuple => |fs| {
                const out = try allocator.alloc(ast.FieldDef, fs.len);
                for (fs, 0..) |f, k| {
                    out[k] = .{
                        .name = f.name,
                        .ty = try substituteType(f.ty, subst, allocator),
                        .vis = f.vis,
                        .attrs = f.attrs,
                    };
                }
                nv.kind = .{ .tuple = out };
            },
            .fields => |fs| {
                const out = try allocator.alloc(ast.FieldDef, fs.len);
                for (fs, 0..) |f, k| {
                    out[k] = .{
                        .name = f.name,
                        .ty = try substituteType(f.ty, subst, allocator),
                        .vis = f.vis,
                        .attrs = f.attrs,
                    };
                }
                nv.kind = .{ .fields = out };
            },
        }
        variants[i] = nv;
    }
    return allocNode(allocator, .{ .enum_item = .{
        .name = mangle,
        .variants = variants,
        .vis = template.vis,
        .attrs = template.attrs,
    } });
}
