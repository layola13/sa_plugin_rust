# sa_plugin_rust

A Rust (`.rs`) front end for the SA toolchain: `sa rust build main.rs` produces
SA-ASM (`.sa`), and `sa rust build-exe main.rs` produces a native executable.

The pipeline is in-process up to SA-ASM, then hands off to the SA compiler:

```
main.rs
  -> src/lexer.zig     Rust tokens (lifetimes, raw strings, numeric suffixes, char literals)
  -> src/parser.zig    Rust AST, recursive descent, full expression precedence
  -> src/lower.zig     AST -> SA-ASM text, with src/layout.zig for type layouts
  -> src/plugin_commands.zig   writes the .sa, then spawns `sa build-exe`
```

## Status

| Area | State |
|---|---|
| Parser | 313/313 real Rust files (rosetta corpus) parse; 42 unit tests |
| Layout | struct/enum/union/tuple/array/fat-pointer layouts, natural sizes |
| Lowering | scalars, control flow, functions, calls, aggregates, `match` on enums, `?` |
| Generics | monomorphization of functions, structs and enums |
| `&str` | a real value: `[data, len]`, through bindings, branch joins, `match`, calls, struct fields, `len()`, `is_empty()` |
| Destructuring | `let (a, b) = ..`, `let S { x, y } = ..`, `let S { x, .. } = ..`, `&`/or-patterns; `match` on scalars with literals, ranges, or-patterns, bindings and guards |
| Formatting | `println!`/`print!`/`format!`/`panic!`/`assert!`/`vec!`, positional `{0}`, inline `{name}`, `{{`/`}}`, Rust-compatible float literals |
| Not yet | `Box`/`Vec`/`String` heap semantics, trait dispatch, closures, iterators, `async`, `Drop`, `s == t` for strings, format specs (`{:.2}`), `match` on aggregates, computed-float `Display` |

`sa rust check` reports the count of unsupported constructs, so coverage is
measurable rather than silent. `tests/e2e/` compiles each fixture to a *native
binary* and diffs its real stdout, because the interesting failures
(capability mismatches, use-after-move, phi conflicts, exit leaks) only appear
once the Referee runs.

## Build

```sh
zig build              # -> zig-out/lib/librust.so, zig-out/lib/sap.json, zig-out/bin/rust
zig build test         # unit tests
```

The plugin needs the `sci` checkout only for the optional in-process
`sci_bridge` module. Set `SCI_ROOT_REL=../sci` to wire it up; otherwise a stub
is used, which is sufficient because `.rs -> .sa` is in-process code and
`.sa -> exe` goes through the `sa` executable.

## Install

```sh
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa rust build-exe main.rs -o main && ./main
```

## Use

```
rust init [path]                      scaffold src/main.rs + a reference src/main.sa
rust check  [file.rs]                 parse + lower, report function count
rust build  [file.rs] [--out out.sa]  emit SA-ASM
rust build-exe [file.rs] [-o exe]     emit SA-ASM, then `sa build-exe`
rust test    [file.rs] [args...]      `sa test`
rust run     [file.rs] [args...]      `sa run`
rust skills  [--json]                 machine-readable command list
```

Flags not recognised by the plugin are forwarded to `sa` unchanged
(`--release-fast`, `--jobs`, `-g`, ...).

`--no-loc` suppresses the `#loc` source hints; they are on by default.

## Source mapping

Every generated function and statement is preceded by

```
#loc "src/main.rs":42:9
```

which is the form `sci`'s flattener already understands. It costs one line per
statement and buys DWARF `!DILocation` records, a Rust file/line on every
verifier diagnostic, and a `func_source_path` in the emitted object. The
`Lowerer` emits `SA`'s prescribed `[data, len]` fat pointer for `&str`, so a
`#loc` on a string statement still points at the Rust line, not at a
synthesised slot.

Positions come from the parser, which builds a line-offset table once per file
and records `line:col` on items and statements. A position that was never
recorded is skipped rather than emitted: `SA` rejects a zero line or column
outright.

## Design notes

Four things about SA-ASM shape the lowering, and are documented in
`docs/rust_backend_evaluation.md`:

1. **`dst = src` is a move, not a copy.** The destination register name is
   threaded into the expression so `let s = a + b` becomes `s = add a, b`.
   A Rust copy is emitted as an arithmetic identity (`b = add a, 0`).
2. **Every basic block must end in a terminator, and every exit must release its
   live registers.** The live set is snapshotted/restored around branches and
   reset to the loop-head state on back edges. A branch arm releases only what
   *it* created; anything live before the branch stays live, or a read after the
   merge is a use-after-move.
3. **`load`/`store` require an explicit `+offset`**, and `stack_alloc` slots
   must be hoisted out of loops and never released explicitly. One `+` per
   address: a layout `#def` already carries its sign, so `base+FIELD+8` folds to
   nonsense — take the field address with `ptr_add` first.
4. **A `&str` is `[data, len]`, because SA has no string-literal sugar.** Each
   context picks the form that costs no copy, since SA has no value-copy
   instruction either: a literal stays a `@const` name, a struct field stores the
   pair inline, and a binding or branch-join result owns a 16-byte box.

## Layout conventions

Generated `#def` dictionaries follow the `sa_std/core/*.sal` convention:
natural sizes and alignment, an enum as `[tag(u64 at +0) | payload(max, +8)]`,
a fat pointer as `[data | len]`, a growable one as `[data | len | cap]`. A `&str`
field is 16 bytes wide — sizing it as one word overlaps its length word with the
next field and reads back as a plausible wrong number rather than a trap.
