#!/usr/bin/env bash
# Verifies properties of the built release tarball. Run via `make test`.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_rust from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release. The payload must
#      contain only the compiled extension_rust binary, the toolchain
#      binaries, the tree-sitter .so, the .scm queries, and config.yaml.
#   2. The debugger command invokes lldb-dap by its package-local path and
#      listens on the bound address. The shared $RUNE_DATADIR/bin copy cannot
#      load liblldb (its @loader_path/../lib rpath resolves to the data dir's
#      lib/, which holds package symlinks, not dylibs) and collides with
#      rune-language-zig's lldb-dap; and lldb-dap has no connect:// scheme.
#   3. The packaged lldb-dap actually runs from the bin/ + lib/ layout, when
#      the host can execute the target's binaries. On Linux, lldb-server ships
#      next to it: liblldb launches debuggees through lib/../bin/lldb-server.
#   4. Every native binary is built for $TARGET_OS/$TARGET_ARCH and loads on
#      the oldest supported OS ($GLIBC_MIN_VERSION, macOS $MACOS_MIN_VERSION).
#      One host builds all four packages, so this also catches a package
#      about to be uploaded to the wrong platform's bucket.
#   5. Every native binary links only libraries the OS always provides (glibc
#      and libgcc_s; /usr/lib and system frameworks) or liblldb, so nothing
#      depends on an optional package such as libpython or libxml2, or on a
#      library from the build host such as Homebrew's.
#   6. macOS targets: Rune.app can load the package. Every Mach-O file is
#      signed by the $TEAM_ID Developer ID, and tree-sitter.so loads into a
#      process signed like Rune.app (scripts/macos-signing.sh check).
set -euo pipefail

TAR="${TAR:-rust.tar.gz}"
: "${TARGET_OS:?TARGET_OS is not set; run 'make test'}"
: "${TARGET_ARCH:?TARGET_ARCH is not set; run 'make test'}"
: "${GLIBC_MIN_VERSION:?GLIBC_MIN_VERSION is not set; run 'make test'}"
: "${MACOS_MIN_VERSION:?MACOS_MIN_VERSION is not set; run 'make test'}"
if [ "$TARGET_OS" = darwin ]; then
	: "${TEAM_ID:?TEAM_ID is not set; run 'make test'}"
	: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is not set; run 'make test'}"
fi

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

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
tar -xzf "$TAR" -C "$workdir"

if ! grep -qF '$RUNE_DATADIR/lib/$RUNE_PKG_ID/bin/lldb-dap --connection listen://{addr}' \
	"$workdir/config.yaml"; then
	echo "error: config.yaml must invoke lldb-dap by package-local path and listen://{addr}:" >&2
	grep -n 'command:' "$workdir/config.yaml" >&2
	exit 1
fi
echo "ok: debugger command uses the package-local lldb-dap and listen://{addr}"

for f in bin/lldb-dap $([ "$TARGET_OS" = linux ] && echo bin/lldb-server); do
	if [ ! -x "$workdir/$f" ]; then
		echo "error: $TAR is missing $f" >&2
		exit 1
	fi
done

# lldb-dap can only be run when the host matches the target (Linux packages
# are cross-built on macOS).
host_os="$(uname | tr '[:upper:]' '[:lower:]')"
host_arch="$(uname -m | sed -e 's/^x86_64$/amd64/' -e 's/^aarch64$/arm64/')"
if [ "$host_os-$host_arch" = "$TARGET_OS-$TARGET_ARCH" ]; then
	if ! "$workdir/bin/lldb-dap" --help > /dev/null 2>&1; then
		echo "error: packaged lldb-dap cannot run from its package layout" >&2
		"$workdir/bin/lldb-dap" --help >&2 || true
		exit 1
	fi
	echo "ok: lldb-dap runs from the package bin/ + lib/ layout"
fi

# Guard 4: target os/arch and OS floors.

# version_gt A B: true when dotted version A is newer than B.
version_gt() {
	[ "$1" != "$2" ] &&
		[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

case "$TARGET_OS-$TARGET_ARCH" in
linux-amd64) want="ELF*x86-64" ;;
linux-arm64) want="ELF*aarch64" ;;
darwin-amd64) want="Mach-O*x86_64" ;;
darwin-arm64) want="Mach-O*arm64" ;;
*)
	echo "error: unsupported target $TARGET_OS-$TARGET_ARCH" >&2
	exit 1
	;;
esac

binaries=0
failed=0
while IFS= read -r -d '' f; do
	desc="$(file -b "$f")"
	case "$desc" in
	ELF* | Mach-O*) ;;
	*) continue ;;
	esac
	binaries=$((binaries + 1))
	name="${f#"$workdir"/}"
	# shellcheck disable=SC2254 # $want is a glob on purpose.
	case "$desc" in
	$want*) ;;
	*)
		echo "error: $name is not a $TARGET_OS-$TARGET_ARCH binary: $desc" >&2
		failed=1
		continue
		;;
	esac
	if [ "$TARGET_OS" = linux ]; then
		need="$(objdump -T "$f" 2>/dev/null |
			sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' |
			sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
		if [ -n "$need" ] && version_gt "$need" "$GLIBC_MIN_VERSION"; then
			echo "error: $name requires GLIBC_$need; the floor is $GLIBC_MIN_VERSION" >&2
			failed=1
		fi
		deps="$(objdump -p "$f" | awk '$1 == "NEEDED" { print $2 }')"
	else
		# Minimum macOS of every architecture slice, from LC_BUILD_VERSION
		# (minos) or the older LC_VERSION_MIN_MACOSX (version).
		mins="$(otool -arch all -l "$f" | awk '
			$1 == "cmd" { build = ($2 == "LC_BUILD_VERSION"); legacy = ($2 == "LC_VERSION_MIN_MACOSX"); next }
			build && $1 == "minos" { print $2 }
			legacy && $1 == "version" { print $2; legacy = 0 }')"
		if [ -z "$mins" ]; then
			echo "error: $name has no minimum macOS version" >&2
			failed=1
		fi
		for min in $mins; do
			if version_gt "$min" "$MACOS_MIN_VERSION"; then
				echo "error: $name requires macOS $min; the floor is $MACOS_MIN_VERSION" >&2
				failed=1
			fi
		done
		# otool -L prints the file name, and per-slice headers ending in ':'.
		deps="$(otool -arch all -L "$f" | awk 'NR > 1 && $NF !~ /:$/ { print $1 }')"
	fi
	for dep in $deps; do
		case "$dep" in
		libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | \
			libutil.so.1 | libgcc_s.so.1 | ld-linux-*.so.* | liblldb.so.*) ;;
		/usr/lib/* | /System/Library/* | @rpath/liblldb.*) ;;
		*)
			echo "error: $name links $dep, which the OS does not always provide" >&2
			failed=1
			;;
		esac
	done
done < <(find "$workdir" -type f -print0)

if [ "$binaries" -eq 0 ]; then
	echo "error: $TAR contains no native binaries" >&2
	exit 1
fi
if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "ok: $binaries binaries are $TARGET_OS-$TARGET_ARCH, within the OS floors (glibc $GLIBC_MIN_VERSION, macOS $MACOS_MIN_VERSION), and link only system libraries"

# Guard 6.
if [ "$TARGET_OS" = darwin ]; then
	"$(dirname "$0")/macos-signing.sh" check "$workdir" tree_sitter_rust
fi
