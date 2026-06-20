#!/usr/bin/env bash
# Verifies properties of the built release tarball ($TAR). Run after `make`.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_python from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release. The payload must
#      contain only the compiled extension_python binary, the toolchain
#      binaries, the tree-sitter .so, the .scm queries, and config.yaml.
set -euo pipefail

TAR="${TAR:-rust.tar.gz}"

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

# List archive members. Matches the build's gtar invocation (entries are
# relative to pkg/, e.g. ./bin/extension_python).
members="$(tar -tzf "$TAR")"

go_files="$(printf '%s\n' "$members" | grep -E '\.go$' || true)"
if [ -n "$go_files" ]; then
	echo "error: $TAR contains .go source files:" >&2
	printf '%s\n' "$go_files" >&2
	exit 1
fi

echo "ok: no .go files in $TAR"
