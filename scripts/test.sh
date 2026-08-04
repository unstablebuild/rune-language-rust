#!/usr/bin/env bash
# Verifies properties of the built release artifacts. Run after `make`.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_rust from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release. The payload must
#      contain only the compiled extension_rust binary, the toolchain
#      binaries, the tree-sitter .so, the .scm queries, and config.yaml.
#   2. No .go source files leak into the notarization zip ($NOTARIZE_ZIP),
#      which is submitted to Apple and must contain only signed binaries.
#   3. The debugger command invokes lldb-dap by its package-local path and
#      listens on the bound address. The shared $RUNE_DATADIR/bin copy cannot
#      load liblldb (its @loader_path/../lib rpath resolves to the data dir's
#      lib/, which holds package symlinks, not dylibs) and collides with
#      rune-language-zig's lldb-dap; and lldb-dap has no connect:// scheme.
#   4. The packaged lldb-dap actually runs from the bin/ + lib/ layout.
set -euo pipefail

TAR="${TAR:-rust.tar.gz}"
NOTARIZE_ZIP="${NOTARIZE_ZIP:-rust-notarize.zip}"

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

# The notarization zip is only produced on macOS (see the Makefile's `sign`
# target). Skip the check when it's absent rather than failing the build.
if [ -f "$NOTARIZE_ZIP" ]; then
	zip_members="$(unzip -Z1 "$NOTARIZE_ZIP")"
	zip_go_files="$(printf '%s\n' "$zip_members" | grep -E '\.go$' || true)"
	if [ -n "$zip_go_files" ]; then
		echo "error: $NOTARIZE_ZIP contains .go source files:" >&2
		printf '%s\n' "$zip_go_files" >&2
		exit 1
	fi
	echo "ok: no .go files in $NOTARIZE_ZIP"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

tar -xzf "$TAR" -C "$workdir" ./config.yaml
if ! grep -qF '$RUNE_DATADIR/lib/$RUNE_PKG_ID/bin/lldb-dap --connection listen://{addr}' \
	"$workdir/config.yaml"; then
	echo "error: config.yaml must invoke lldb-dap by package-local path and listen://{addr}:" >&2
	grep -n 'command:' "$workdir/config.yaml" >&2
	exit 1
fi
echo "ok: debugger command uses the package-local lldb-dap and listen://{addr}"

# lldb-dap ships everywhere except darwin-amd64 (no official LLVM prebuilt).
# `grep -q` exits on the first match, which would SIGPIPE a feeding printf
# under pipefail, so match against a herestring rather than a pipeline.
if grep -qxF ./bin/lldb-dap <<< "$members"; then
	tar -xzf "$TAR" -C "$workdir" ./bin/lldb-dap ./lib
	if ! "$workdir/bin/lldb-dap" --help > /dev/null 2>&1; then
		echo "error: packaged lldb-dap cannot run from its package layout" >&2
		"$workdir/bin/lldb-dap" --help >&2 || true
		exit 1
	fi
	echo "ok: lldb-dap runs from the package bin/ + lib/ layout"
fi
