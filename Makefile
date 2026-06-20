SRC=tree-sitter-rust rune
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=rust.tar.gz
NOTARIZE_ZIP=rust-notarize.zip
GTAR=gtar
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

# Pinned prebuilt toolchain versions (downloaded per target os/arch). No Rust
# toolchain is bundled; rustup provisions it on first run, confined to
# $RUNE_DATADIR/lib/$RUNE_PKG_ID via config.yaml gui.env (RUSTUP_HOME/CARGO_HOME).
RUST_ANALYZER_VERSION=2026-06-15
# lldb-dap is extracted from the official prebuilt LLVM release. macOS x86_64
# prebuilts stopped at LLVM 19, so darwin-amd64 lldb-dap is intentionally NOT
# staged here (see toolchain target); arm64 macOS + both linux arches are.
LLVM_VERSION=22.1.8

HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

CROSS=$(filter-out $(HOST_ARCH),$(TARGET_ARCH))
CGO_ENABLED=$(if $(CROSS),0,1)

GNU_TRIPLE_amd64=x86_64-linux-gnu
GNU_TRIPLE_arm64=aarch64-linux-gnu
CC=$(if $(CROSS),$(GNU_TRIPLE_$(TARGET_ARCH))-gcc,gcc)

# Rust target-triple naming for rust-analyzer / rustup-init assets.
RUST_ARCH_amd64=x86_64
RUST_ARCH_arm64=aarch64
RUST_ARCH=$(RUST_ARCH_$(TARGET_ARCH))
RUST_OS_darwin=apple-darwin
RUST_OS_linux=unknown-linux-gnu
RUST_OS=$(RUST_OS_$(TARGET_OS))
RUST_TRIPLE=$(RUST_ARCH)-$(RUST_OS)

# LLVM release asset naming (different per OS).
LLVM_ARCH_amd64_linux=X64
LLVM_ARCH_arm64_linux=ARM64
LLVM_ARCH_arm64_darwin=ARM64
LLVM_OSNAME_darwin=macOS
LLVM_OSNAME_linux=Linux
LLVM_ASSET=LLVM-$(LLVM_VERSION)-$(LLVM_OSNAME_$(TARGET_OS))-$(LLVM_ARCH_$(TARGET_ARCH)_$(TARGET_OS)).tar.xz

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

.PHONY: $(DIST_TARGETS) clean sign notarize notary-credentials toolchain test
default: $(TAR)

# Stage prebuilt rustup-init + rust-analyzer into pkg/bin and extract lldb-dap
# (+ its lldb/LLVM shared libs) from the prebuilt LLVM release into pkg/bin +
# pkg/lib, for the target os/arch.
toolchain:
	@mkdir -p pkg/bin pkg/lib
	# rustup-init (single static binary; the extension runs it on first launch).
	wget -O pkg/bin/rustup-init https://static.rust-lang.org/rustup/dist/$(RUST_TRIPLE)/rustup-init
	chmod +x pkg/bin/rustup-init
	# rust-analyzer (gzip-compressed single binary).
	wget -O ra.gz https://github.com/rust-lang/rust-analyzer/releases/download/$(RUST_ANALYZER_VERSION)/rust-analyzer-$(RUST_TRIPLE).gz
	gunzip -c ra.gz > pkg/bin/rust-analyzer
	chmod +x pkg/bin/rust-analyzer
	rm -f ra.gz
	# lldb-dap: extract only bin/lldb-dap + the liblldb/libLLVM shared libs it
	# links from the ~1.5GB prebuilt LLVM tarball. macOS-amd64 has no official
	# prebuilt (LLVM>19), so it is skipped; Track D handles the runtime fallback.
	# NOTE: verify the exact extracted lib set + rpath fixups on the build host
	# (TODO RUNE-257 Track D / M3); paths below match the LLVM-<ver>-* layout.
	@if [ "$(TARGET_OS)-$(TARGET_ARCH)" = "darwin-amd64" ]; then \
		echo "skip lldb-dap: no official macOS-amd64 LLVM $(LLVM_VERSION) prebuilt"; \
	else \
		wget -O llvm.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/$(LLVM_ASSET); \
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
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/bin/lldb-dap'; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/liblldb.*dylib' 2>/dev/null || true; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/liblldb.so*'   2>/dev/null || true; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/libLLVM.so*'   2>/dev/null || true; \
		cp llvm-extract/bin/lldb-dap pkg/bin/lldb-dap; \
		cp -a llvm-extract/lib/liblldb.*dylib pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/liblldb.so* pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/libLLVM.so* pkg/lib/ 2>/dev/null || true; \
		chmod +x pkg/bin/lldb-dap; \
		rm -rf llvm.tar.xz llvm-extract; \
	fi

$(LIB): $(SRC) toolchain
	@mkdir -p pkg/bin pkg/lib
ifeq ($(HOST_OS),darwin)
	cd tree-sitter-rust && cc -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64
else
	cd tree-sitter-rust && $(CC) -o parser.so -I./src src/*.c -Os -shared -fPIC
endif
	cp tree-sitter-rust/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-rust/queries/highlights.scm tree-sitter-rust/queries/tags.scm pkg/lib
	cp nvim-treesitter/queries/rust/indents.scm pkg/lib
	cp nvim-treesitter/queries/rust/locals.scm pkg/lib
	cp nvim-treesitter/queries/rust/folds.scm pkg/lib
	cd rune && CGO_ENABLED=$(CGO_ENABLED) GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) go build -o $(PWD)/pkg/bin/extension_rust ./cmd/extension_rust
	cp config.yaml pkg

ifeq ($(UNAME),Darwin)
sign: $(LIB)
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/rustup-init
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/rust-analyzer
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/extension_rust
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/lib/tree-sitter.so
	# lldb-dap + liblldb are absent for darwin-amd64 (no prebuilt LLVM); sign the
	# dylib before the binary so the binary's rpath ref stays valid.
	@for f in pkg/lib/liblldb*.dylib pkg/bin/lldb-dap; do \
		[ -f "$$f" ] && codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$f" || true; \
	done

$(NOTARIZE_ZIP): sign
	zip $(NOTARIZE_ZIP) pkg/bin/rustup-init pkg/bin/rust-analyzer pkg/bin/extension_rust pkg/lib/tree-sitter.so
	@for f in pkg/bin/lldb-dap pkg/lib/liblldb*.dylib; do \
		[ -f "$$f" ] && zip $(NOTARIZE_ZIP) "$$f" || true; \
	done

notarize: $(NOTARIZE_ZIP)
	xcrun notarytool submit $(NOTARIZE_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
else
sign: $(LIB)
	@echo "Skipping codesign (not on macOS)"

notarize: sign
	@echo "Skipping notarization (not on macOS)"
endif

$(TAR): $(LIB) sign
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Verify release-tarball properties (no .go source leaks, etc).
test: $(TAR)
	TAR=$(TAR) ./scripts/test.sh

$(DIST_TARGETS): dist-%:
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) notarize $(TAR) TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf pkg/
	rm -rf llvm.tar.xz llvm-extract ra.gz
