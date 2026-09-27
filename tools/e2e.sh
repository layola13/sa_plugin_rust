#!/bin/sh
# End-to-end suite: Rust source -> .sa -> native binary -> stdout.
#
# The unit tests in `zig build test` never spawn the host `sa`, so they cannot
# see the failures that actually bit during development: capability-prefix
# mismatches, use-after-move on derived pointers, phi live-set conflicts and
# memory leaks at function exit. Those only surface once the Referee runs, so
# this suite compiles and *executes* each fixture and diffs the real output.
#
# Usage:  ./tools/e2e.sh [fixture.rs ...]
# Env:    SA_E2E_KEEP=1   keep the generated binaries
#         SCI_ROOT=...    where the `sa` build lives (auto-detected otherwise)
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

# With no arguments, every fixture in the suite.
if [ "$#" -gt 0 ]; then
    fixtures=$*
else
    fixtures=$(ls tests/e2e/*.rs)
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The local CLI lowers in-process; `build-exe` then spawns the real `sa`.
if [ ! -x "zig-out/bin/rust" ]; then
    echo "e2e: building the plugin first" >&2
    zig build >/dev/null
fi

# `sa` is found through the same lookup the plugin uses.
if [ -z "${SCI_ROOT:-}" ]; then
    for candidate in ../sci "$here/../sci" "$here/../../sci"; do
        if [ -x "$candidate/zig-out/bin/sa" ]; then
            SCI_ROOT=$(cd "$candidate" && pwd)
            break
        fi
    done
fi
SCI_ROOT=${SCI_ROOT:-}
export SCI_ROOT
PATH="$here/zig-out/bin:$PATH"
export PATH

pass=0
fail=0
known=0

for fixture in $fixtures; do
    name=$(basename "$fixture" .rs)
    expected="tests/e2e/$name.expected"
    if [ ! -f "$fixture" ]; then
        echo "e2e: no such fixture: $fixture" >&2
        fail=$((fail + 1))
        continue
    fi
    if [ ! -f "$expected" ]; then
        echo "e2e: $name: no expected output at $expected" >&2
        fail=$((fail + 1))
        continue
    fi

    # A fixture may be marked as a known failure while the feature it covers is
    # still missing. It is still run, so the day it starts working the suite
    # says so, but it does not block the gate.
    known_fail=0
    if [ -f "tests/e2e/$name.known-fail" ]; then known_fail=1; fi

    if ! rust build-exe "$fixture" -o "$tmp/$name" >"$tmp/$name.log" 2>&1; then
        if [ "$known_fail" -eq 1 ]; then
            echo "e2e: known-fail $name (compile)"
            known=$((known + 1))
            continue
        fi
        echo "e2e: FAIL $name (compile)" >&2
        sed 's/^/    /' "$tmp/$name.log" >&2
        fail=$((fail + 1))
        continue
    fi

    if ! "$tmp/$name" >"$tmp/$name.out" 2>&1; then
        if [ "$known_fail" -eq 1 ]; then
            echo "e2e: known-fail $name (run)"
            known=$((known + 1))
            continue
        fi
        echo "e2e: FAIL $name (run)" >&2
        sed 's/^/    /' "$tmp/$name.out" >&2
        fail=$((fail + 1))
        continue
    fi

    if diff -u "$expected" "$tmp/$name.out" >"$tmp/$name.diff" 2>&1; then
        echo "e2e: ok   $name"
        if [ "$known_fail" -eq 1 ]; then
            echo "e2e:      note: $name is marked known-fail but now passes; drop the marker" >&2
        fi
        pass=$((pass + 1))
    elif [ "$known_fail" -eq 1 ]; then
        echo "e2e: known-fail $name (feature not implemented yet)"
        known=$((known + 1))
    else
        echo "e2e: FAIL $name (output)" >&2
        sed 's/^/    /' "$tmp/$name.diff" >&2
        fail=$((fail + 1))
    fi

    # A second build with `-g`. It is not about the output -- the debug build
    # runs the same program -- but about the *toolchain path*: the LLVM emitter
    # rejects a program containing an instruction after a terminator
    # (`InvalidOperand`), which the plain build silently tolerates. Unreachable
    # code is easy to emit by accident when a branch arm diverges, so this is
    # checked for every fixture rather than trusted.
    if ! rust build-exe "$fixture" -o "$tmp/$name.g" -g >"$tmp/$name.g.log" 2>&1; then
        echo "e2e: FAIL $name (debug build)" >&2
        sed 's/^/    /' "$tmp/$name.g.log" >&2
        fail=$((fail + 1))
    elif ! "$tmp/$name.g" >"$tmp/$name.g.out" 2>&1; then
        echo "e2e: FAIL $name (debug run)" >&2
        sed 's/^/    /' "$tmp/$name.g.out" >&2
        fail=$((fail + 1))
    fi

    if [ -n "${SA_E2E_KEEP:-}" ]; then
        mkdir -p "$here/zig-out/e2e"
        cp "$tmp/$name" "$here/zig-out/e2e/$name" 2>/dev/null || true
        cp "$tmp/$name.g" "$here/zig-out/e2e/$name.g" 2>/dev/null || true
        cp "$fixture" "$here/zig-out/e2e/$name.rs" 2>/dev/null || true
    fi
done

echo "e2e: $pass passed, $known known-fail, $fail failed"
[ "$fail" -eq 0 ]
