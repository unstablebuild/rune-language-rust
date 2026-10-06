#!/usr/bin/env bash
# Builds lldb-dap (and, on Linux, the lldb-server it launches debuggees
# through) from the LLVM source release, instead of shipping the prebuilt LLVM
# release binaries. Those need glibc 2.34 + libstdc++ 12 + libpython3.11 +
# libxml2/ncurses/libedit on Linux and macOS 14, and do not exist for macOS
# x86_64. This build:
#   - disables every optional dependency (Python, Lua, libxml2, curses,
#     libedit, lzma, zlib, zstd), so liblldb links only libc/libm/libpthread;
#   - targets macOS $MACOS_MIN_VERSION (Apple clang, system debugserver) and,
#     on Linux, glibc $GLIBC_MIN_VERSION through zig c++, which also links
#     libc++ statically so there is no libstdc++ floor either.
#
# Usage: build-lldb.sh <darwin|linux> <arm64|amd64> <install-dir>
# Installs bin/lldb-dap, lib/liblldb.* and (Linux) bin/lldb-server into
# <install-dir>. Source and build trees live in $LLDB_WORK and are reused, so
# rerunning after a failure resumes the build.
set -euo pipefail

os="${1:?usage: $0 <darwin|linux> <arm64|amd64> <install-dir>}"
arch="${2:?usage: $0 <darwin|linux> <arm64|amd64> <install-dir>}"
prefix="${3:?usage: $0 <darwin|linux> <arm64|amd64> <install-dir>}"
: "${LLVM_VERSION:?LLVM_VERSION is not set}"
: "${LLDB_WORK:?LLDB_WORK is not set}"
: "${MACOS_MIN_VERSION:?MACOS_MIN_VERSION is not set}"
: "${GLIBC_MIN_VERSION:?GLIBC_MIN_VERSION is not set}"

scripts="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$LLDB_WORK"
LLDB_WORK="$(cd "$LLDB_WORK" && pwd)"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"

for tool in cmake ninja; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: $tool not found on PATH; it is needed to build lldb-dap" >&2
		exit 1
	fi
done

case "$arch" in
arm64) llvm_arch=aarch64 ;;
amd64) llvm_arch=x86_64 ;;
*)
	echo "error: unsupported arch '$arch'" >&2
	exit 1
	;;
esac

# Only the subprojects LLDB builds from; the full source tree is ~4x larger.
src="$LLDB_WORK/llvm-project-$LLVM_VERSION.src"
if [ ! -f "$src/.extracted" ]; then
	tarball="$LLDB_WORK/llvm-project-$LLVM_VERSION.src.tar.xz"
	curl -fL -o "$tarball" \
		"https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz"
	rm -rf "$src"
	mkdir -p "$src"
	tar -xJf "$tarball" -C "$src" --strip-components=1 \
		"llvm-project-$LLVM_VERSION.src/llvm" \
		"llvm-project-$LLVM_VERSION.src/clang" \
		"llvm-project-$LLVM_VERSION.src/lldb" \
		"llvm-project-$LLVM_VERSION.src/cmake" \
		"llvm-project-$LLVM_VERSION.src/third-party"
	rm -f "$tarball"
	touch "$src/.extracted"
fi

# Configuration shared by the host-tools build and every target build: LLDB
# with the clang libraries it evaluates expressions with, and nothing optional.
common=(
	-G Ninja
	-S "$src/llvm"
	-DCMAKE_BUILD_TYPE=Release
	"-DLLVM_ENABLE_PROJECTS=clang;lldb"
	"-DLLVM_TARGETS_TO_BUILD=AArch64;X86"
	-DLLVM_ENABLE_ASSERTIONS=OFF
	-DLLVM_INCLUDE_TESTS=OFF
	-DLLVM_INCLUDE_EXAMPLES=OFF
	-DLLVM_INCLUDE_BENCHMARKS=OFF
	-DLLVM_INCLUDE_DOCS=OFF
	-DLLVM_ENABLE_BINDINGS=OFF
	-DLLVM_ENABLE_ZLIB=OFF
	-DLLVM_ENABLE_ZSTD=OFF
	-DLLVM_ENABLE_LIBXML2=OFF
	-DLLVM_ENABLE_LIBEDIT=OFF
	-DLLVM_ENABLE_LIBPFM=OFF
	-DLLVM_ENABLE_CURL=OFF
	-DLLVM_ENABLE_HTTPLIB=OFF
	-DLLVM_ENABLE_FFI=OFF
	-DCLANG_INCLUDE_TESTS=OFF
	-DCLANG_INCLUDE_DOCS=OFF
	-DCLANG_ENABLE_STATIC_ANALYZER=OFF
	-DLLDB_INCLUDE_TESTS=OFF
	-DLLDB_ENABLE_PYTHON=OFF
	-DLLDB_ENABLE_LUA=OFF
	-DLLDB_ENABLE_LIBEDIT=OFF
	-DLLDB_ENABLE_CURSES=OFF
	-DLLDB_ENABLE_LZMA=OFF
	-DLLDB_ENABLE_LIBXML2=OFF
	-DLLDB_ENABLE_FBSDVMCORE=OFF
	-DLLDB_BUILD_FRAMEWORK=OFF
	# macOS debuggees run under Apple's debugserver from Xcode or the Command
	# Line Tools, which needs no codesigning of our own. Ignored on Linux.
	-DLLDB_USE_SYSTEM_DEBUGSERVER=ON
)

# Tablegen tools run during every target build; build them once, natively.
host="$LLDB_WORK/build-$LLVM_VERSION-host"
tablegens=(llvm-tblgen llvm-min-tblgen clang-tblgen lldb-tblgen)
if [ ! -x "$host/bin/lldb-tblgen" ]; then
	cmake "${common[@]}" -B "$host"
	ninja -C "$host" "${tablegens[@]}"
fi

build="$LLDB_WORK/build-$LLVM_VERSION-$os-$arch"
target=(
	-B "$build"
	"-DCMAKE_INSTALL_PREFIX=$prefix"
	"-DLLVM_NATIVE_TOOL_DIR=$host/bin"
)
case "$os" in
darwin)
	triple="$llvm_arch-apple-darwin"
	components="lldb-dap;liblldb"
	target+=(
		"-DCMAKE_OSX_ARCHITECTURES=$([ "$arch" = arm64 ] && echo arm64 || echo x86_64)"
		"-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION"
	)
	;;
linux)
	triple="$llvm_arch-unknown-linux-gnu"
	components="lldb-dap;liblldb;lldb-server"
	export ZIG_TARGET="$llvm_arch-linux-gnu.$GLIBC_MIN_VERSION"
	target+=(
		-DCMAKE_SYSTEM_NAME=Linux
		"-DCMAKE_SYSTEM_PROCESSOR=$llvm_arch"
		"-DCMAKE_C_COMPILER=$scripts/zig-cc"
		"-DCMAKE_CXX_COMPILER=$scripts/zig-c++"
		"-DCMAKE_AR=$scripts/zig-ar"
		"-DCMAKE_RANLIB=$scripts/zig-ranlib"
		# zig emits DWARF even at -O3 (1.5GB liblldb), and its prebuilt libc++
		# carries some too, so compile without and strip at link time.
		-DCMAKE_C_FLAGS=-g0
		-DCMAKE_CXX_FLAGS=-g0
		-DCMAKE_EXE_LINKER_FLAGS=-s
		-DCMAKE_SHARED_LINKER_FLAGS=-s
		# Never let configure checks find the build host's (macOS) libraries.
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
		-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
	)
	;;
*)
	echo "error: unsupported os '$os'" >&2
	exit 1
	;;
esac
target+=(
	"-DLLVM_HOST_TRIPLE=$triple"
	"-DLLVM_DEFAULT_TARGET_TRIPLE=$triple"
	"-DLLVM_DISTRIBUTION_COMPONENTS=$components"
)

cmake "${common[@]}" "${target[@]}"
ninja -C "$build" install-distribution