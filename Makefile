SRC=tree-sitter-rust nvim-treesitter rune
PKG_STAMP=.pkg.stamp
TOOLCHAIN_STAMP=.toolchain.$(TARGET_OS)-$(TARGET_ARCH).stamp
TAR=rust.tar.gz
UNAME=$(shell uname)
GTAR=$(if $(filter Darwin,$(UNAME)),gtar,tar)
TAR_WILDCARDS=$(if $(filter Darwin,$(UNAME)),,--wildcards)

# Pinned prebuilt toolchain versions (downloaded per target os/arch). No Rust
# toolchain is bundled; rustup provisions it on first run, confined to
# $RUNE_DATADIR/lib/$RUNE_PKG_ID via config.yaml gui.env (RUSTUP_HOME/CARGO_HOME).
# rust-analyzer is NOT downloaded: it is built from the rust-analyzer submodule
# (pinned to an upstream release tag) with patches/*.patch applied, because the
# upstream prebuilts lack fixes we depend on. This means the build host needs a
# cargo/rustc >= the submodule's rust-version, plus the target std via
# `rustup target add`.
# lldb-dap is extracted from the official prebuilt LLVM release. macOS x86_64
# prebuilts stopped at LLVM 19, so darwin-amd64 lldb-dap is intentionally NOT
# staged here (see toolchain target); arm64 macOS + both linux arches are.
LLVM_VERSION=22.1.8

# Oldest supported platforms (docs.rune.build Prerequisites). Toolchains default
# to the build host's versions, which silently raises the floor; scripts/test.sh
# enforces both.
MACOS_MIN_VERSION=13.3
GLIBC_MIN_VERSION=2.28

PLATFORMS=darwin-arm64 darwin-amd64 linux-arm64 linux-amd64

HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

ifeq ($(filter $(TARGET_OS)-$(TARGET_ARCH),$(PLATFORMS)),)
$(error unsupported target '$(TARGET_OS)-$(TARGET_ARCH)'; supported: $(PLATFORMS))
endif
# macOS packages need the Apple toolchain (clang -arch, ld64). Linux packages
# build on any host: their C code goes through zig cc (see below).
ifeq ($(TARGET_OS)-$(HOST_OS),darwin-linux)
$(error darwin packages must be built on macOS)
endif

# Rust target-triple naming for rust-analyzer / rustup-init assets.
RUST_ARCH_amd64=x86_64
RUST_ARCH_arm64=aarch64
RUST_ARCH=$(RUST_ARCH_$(TARGET_ARCH))
RUST_OS_darwin=apple-darwin
RUST_OS_linux=unknown-linux-gnu
RUST_TRIPLE=$(RUST_ARCH)-$(RUST_OS_$(TARGET_OS))

# Linux targets compile and link C through zig cc pinned to the glibc floor, so
# the result loads on any supported distro regardless of the build host. macOS
# targets use the host clang; cargo passes -arch for the other macOS arch.
ZIG_CC=$(CURDIR)/scripts/zig-cc
ZIG_TARGET=$(RUST_ARCH)-linux-gnu.$(GLIBC_MIN_VERSION)
RUST_TRIPLE_ENV=$(shell echo $(RUST_TRIPLE) | tr 'a-z-' 'A-Z_')
CARGO_ENV_linux=ZIG_TARGET=$(ZIG_TARGET) CARGO_TARGET_$(RUST_TRIPLE_ENV)_LINKER=$(ZIG_CC) CC_$(subst -,_,$(RUST_TRIPLE))=$(ZIG_CC)
CARGO_ENV=$(CARGO_ENV_$(TARGET_OS))

# The tree-sitter parser: one universal bundle for both macOS arches.
PARSER_CC_darwin=cc -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)
PARSER_CC_linux=ZIG_TARGET=$(ZIG_TARGET) $(ZIG_CC) -shared -fPIC

RA_PATCHES=$(wildcard patches/*.patch)

# LLVM release asset naming (different per OS).
LLVM_ARCH_amd64_linux=X64
LLVM_ARCH_arm64_linux=ARM64
LLVM_ARCH_arm64_darwin=ARM64
LLVM_OSNAME_darwin=macOS
LLVM_OSNAME_linux=Linux
LLVM_ASSET=LLVM-$(LLVM_VERSION)-$(LLVM_OSNAME_$(TARGET_OS))-$(LLVM_ARCH_$(TARGET_ARCH)_$(TARGET_OS)).tar.xz

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

# Built packages awaiting upload, one per platform: release/rust-<os>-<arch>.tar.gz.
# `clean` keeps them, since it runs between the builds of release-all.
RELEASE_DIR=release

DIST_TARGETS := $(foreach env,prod staging,$(PLATFORMS:%=dist-$(env)-%))
DIST_ALL_TARGETS := dist-prod-all dist-staging-all
RELEASE_TARGETS := $(PLATFORMS:%=release-%)

.PHONY: $(DIST_TARGETS) $(DIST_ALL_TARGETS) $(RELEASE_TARGETS) release-all \
	check-release-tag clean toolchain test pkg
default: $(TAR)

pkg: $(PKG_STAMP)

toolchain: $(TOOLCHAIN_STAMP)

# Stage prebuilt rustup-init into pkg/bin, build our patched rust-analyzer, and
# extract lldb-dap (+ its lldb/LLVM shared libs) from the prebuilt LLVM release
# into pkg/bin + pkg/lib, for the target os/arch.
$(TOOLCHAIN_STAMP): Makefile $(RA_PATCHES)
	@mkdir -p pkg/bin pkg/lib
	# rustup-init (single static binary; the extension runs it on first launch).
	wget -O pkg/bin/rustup-init https://static.rust-lang.org/rustup/dist/$(RUST_TRIPLE)/rustup-init
	chmod +x pkg/bin/rustup-init
	# rust-analyzer: built from the submodule (pinned to an upstream release tag)
	# with patches/*.patch applied. Patches are applied in place and skipped when
	# already present, so repeated builds reuse the cargo target dir. Use minimal
	# context for the reverse check: extra local edits near a patched hunk must
	# not cause an already-applied patch to be applied a second time.
	git submodule update --init rust-analyzer
	@cd rust-analyzer && for p in $(CURDIR)/$(RA_PATCHES); do \
		if git apply --reverse --check -C0 "$$p" >/dev/null 2>&1; then \
			echo "already applied: $$p"; \
		else \
			echo "applying: $$p"; \
			git apply "$$p"; \
		fi; \
	done
	rustup target add $(RUST_TRIPLE)
	cd rust-analyzer && $(CARGO_ENV) cargo build --release --target $(RUST_TRIPLE) -p rust-analyzer --bin rust-analyzer
	cp rust-analyzer/target/$(RUST_TRIPLE)/release/rust-analyzer pkg/bin/rust-analyzer
	chmod +x pkg/bin/rust-analyzer
	# lldb-dap: extract only bin/lldb-dap + the liblldb/libLLVM shared libs it
	# links from the ~1.5GB prebuilt LLVM tarball. macOS-amd64 has no official
	# prebuilt (LLVM>19), so it is skipped; Track D handles the runtime fallback.
	@if [ "$(TARGET_OS)-$(TARGET_ARCH)" = "darwin-amd64" ]; then \
		echo "skip lldb-dap: no official macOS-amd64 LLVM $(LLVM_VERSION) prebuilt"; \
	else \
		wget -O llvm.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/$(LLVM_ASSET); \
		rm -rf llvm-extract; \
		mkdir -p llvm-extract; \
		: "Extract only lldb-dap + the lldb/LLVM shared libs it links. Verified"; \
		: "on macOS arm64 (LLVM 22.1.8): lldb-dap needs ONLY @rpath/liblldb.<ver>.dylib,"; \
		: "its rpath is @loader_path/../lib (== our bin/+lib/ layout, no fixup), and"; \
		: "liblldb is self-contained (no separate libLLVM runtime dylib). Match only"; \
		: "the runtime shared objects (liblldb.* / libLLVM.so*); never the build-time"; \
		: "static .a archives, which lldb-dap does not load and which would bloat the"; \
		: "package by hundreds of MB."; \
		: "lldb-dap must extract (fail the build if absent); the lib patterns are"; \
		: "OS-specific, so run each in its own tar tolerant of a no-match (tar errors"; \
		: "when a pattern matches nothing)."; \
		tar -xJf llvm.tar.xz $(TAR_WILDCARDS) -C llvm-extract --strip-components=1 '*/bin/lldb-dap'; \
		if [ "$(TARGET_OS)" = "darwin" ]; then \
			tar -xJf llvm.tar.xz $(TAR_WILDCARDS) -C llvm-extract --strip-components=1 '*/lib/liblldb.*dylib' 2>/dev/null || true; \
		else \
			tar -xJf llvm.tar.xz $(TAR_WILDCARDS) -C llvm-extract --strip-components=1 '*/lib/liblldb.so*' 2>/dev/null || true; \
			tar -xJf llvm.tar.xz $(TAR_WILDCARDS) -C llvm-extract --strip-components=1 '*/lib/libLLVM.so*' 2>/dev/null || true; \
		fi; \
		cp llvm-extract/bin/lldb-dap pkg/bin/lldb-dap; \
		cp -a llvm-extract/lib/liblldb.*dylib pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/liblldb.so* pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/libLLVM.so* pkg/lib/ 2>/dev/null || true; \
		chmod +x pkg/bin/lldb-dap; \
		rm -rf llvm.tar.xz llvm-extract; \
	fi
	@touch $(TOOLCHAIN_STAMP)

# No Developer ID signing or notarization: Rune downloads packages without the
# quarantine attribute, so Gatekeeper never assesses them, and the linkers
# already ad-hoc sign arm64 output (the prebuilt downloads come signed).
# extension_rust is cgo-free, so one go build covers every target.
$(PKG_STAMP): $(SRC) config.yaml Makefile $(TOOLCHAIN_STAMP)
	@mkdir -p pkg/bin pkg/lib
	cd tree-sitter-rust && $(PARSER_CC_$(TARGET_OS)) -o parser.so -I./src src/*.c -Os
	cp tree-sitter-rust/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-rust/queries/highlights.scm tree-sitter-rust/queries/tags.scm pkg/lib
	cp nvim-treesitter/queries/rust/indents.scm pkg/lib
	cp nvim-treesitter/queries/rust/locals.scm pkg/lib
	cp nvim-treesitter/queries/rust/folds.scm pkg/lib
	cd rune && CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) \
		go build -o $(CURDIR)/pkg/bin/extension_rust ./cmd/extension_rust
	cp config.yaml pkg
	@touch $(PKG_STAMP)

$(TAR): $(PKG_STAMP)
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Verify release-tarball properties (no .go source leaks, binaries built for the
# target os/arch and within the OS floors, etc).
test: $(TAR)
	TAR=$(TAR) TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) \
		GLIBC_MIN_VERSION=$(GLIBC_MIN_VERSION) MACOS_MIN_VERSION=$(MACOS_MIN_VERSION) \
		./scripts/test.sh

# release-<os>-<arch>: clean build + test of one platform's package, moved to
# $(RELEASE_DIR)/rust-<os>-<arch>.tar.gz. Uploads nothing.
$(RELEASE_TARGETS): release-%:
	$(MAKE) clean
	$(MAKE) test TARGET_OS=$(word 1,$(subst -, ,$*)) TARGET_ARCH=$(word 2,$(subst -, ,$*))
	@mkdir -p $(RELEASE_DIR)
	mv $(TAR) $(RELEASE_DIR)/rust-$*.tar.gz

# Builds every platform's package (darwin needs a macOS host).
release-all:
	$(foreach p,$(PLATFORMS),$(MAKE) release-$(p) &&) true

# $(call upload,<env>,<os>-<arch>): upload a package built by release-<os>-<arch>
# to the bluectl project and bucket pinned by deploy/bluectl/<env>/<os>-<arch>.
upload = BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$(1)/$(2) \
	BLUE_TARGET_OS=$(word 1,$(subst -, ,$(2))) BLUE_TARGET_ARCH=$(word 2,$(subst -, ,$(2))) \
	BLUE_RELEASE_TAR=$(RELEASE_DIR)/rust-$(2).tar.gz ./dist.sh

# dist-<env>-<os>-<arch>: build, test, and upload one platform's package.
# Pattern stem is <env>-<os>-<arch>, e.g. "prod-darwin-arm64".
$(DIST_TARGETS): dist-%: check-release-tag
	$(MAKE) release-$(patsubst $(word 1,$(subst -, ,$*))-%,%,$*)
	$(call upload,$(word 1,$(subst -, ,$*)),$(patsubst $(word 1,$(subst -, ,$*))-%,%,$*))

# dist-<env>-all: build and test all four packages, then upload them, so a
# failed build publishes nothing.
$(DIST_ALL_TARGETS): dist-%-all: check-release-tag
	$(MAKE) release-all
	$(foreach p,$(PLATFORMS),$(call upload,$*,$(p)) &&) true

check-release-tag:
	@./check-release-tag.sh

clean:
	rm -rf $(TAR)
	rm -rf $(PKG_STAMP) .toolchain.*.stamp
	rm -rf pkg/
	rm -rf llvm.tar.xz llvm-extract
	rm -f tree-sitter-rust/parser.so