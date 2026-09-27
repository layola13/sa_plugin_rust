#!/bin/sh
# Parse-coverage check against the rosetta corpus.
#
# The corpus is the 313 real Rust programs under
# `sa_plugin_sla/demos/rosetta`, each with a hand-written `main.sla` reference.
# Parsing all of them is the regression gate for `src/parser.zig`.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
corpus=${1:-"$here/../sa_plugin_sla/demos/rosetta"}

if [ ! -d "$corpus" ]; then
    echo "corpus not found: $corpus" >&2
    exit 1
fi

echo "corpus: $corpus"
cd "$here"
zig build local-cli -- --help >/dev/null 2>&1 || true
exec env RUST_CHECK_ONLY=parse "$here/zig-out/bin/rust" check --corpus "$corpus"
