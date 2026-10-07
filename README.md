# Rust language package

This package is for Rune maintainers only. You can install rust in Rune with the following
command from your `console`:

```
pkg install rust
```

This repo builds the Rune Rust language package (`rust.tar.gz`) and publishes it with
[`bluectl`](https://github.com/unstablebuild/blue). Releases cover macOS (`darwin`) and
Linux, each on `arm64` and `amd64`, in `staging` and `prod`.

1. **Prepare the build host.** A Mac builds all four packages: macOS ones with
   the Xcode command line tools, Linux ones with `zig cc` pinned to glibc 2.28
   (a Linux host can build only the Linux packages, so `release-all` and
   `dist-<env>-all` fail there). Install Go, a Rust toolchain recent enough for
   the pinned rust-analyzer, `rustup`, `zig`, `cmake`, `ninja`, `wget`,
   `bluectl`, and tar (GNU `gtar` on macOS).

   macOS packages are signed with the Unstable Build Developer ID, so the Mac
   needs the "Developer ID Application: Unstable Build, LLC. (YYZRWD888J)"
   identity in its keychain. The signature is required, not optional: Rune
   runs with library validation, so it only loads a `tree-sitter.so` signed by
   its own team. `make test` fails a macOS package unless every Mach-O file is
   signed by that team and `tree-sitter.so` loads into a process signed like
   Rune.app (`scripts/macos-signing.sh`, shared by every language repo).
   Packages are not notarized: Rune installs them without the quarantine
   attribute, so Gatekeeper never assesses them.

   `lldb-dap` (and `lldb-server` on Linux) is built from the LLVM source
   release by `scripts/build-lldb.sh`, with no Python, libxml2, curses or
   libedit, so it runs on the same OS floors as the rest of the package. The
   first build of each platform takes 10-20 minutes and needs about 10 GB under
   `lldb/`; later builds reuse it until `LLVM_VERSION` changes. `make clean`
   keeps it, `make clean-lldb` removes it.
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out the intended release tag; the `dist-*` targets refuse a dirty or
   untagged tree. Make sure `bluectl` can authenticate (the configs under
   `deploy/bluectl/` use your gcloud Application Default Credentials). Set
   `BLUE_PGP_KEY` and `BLUE_PGP_KEYRING` for upload; see
   `bluectl release upload -h` for their expected values.
3. **Publish** every platform, or a single one:

   ```sh
   make dist-prod-all                 # all four packages
   make dist-staging-linux-arm64      # one package
   ```

   `dist-<env>-all` builds and tests all four packages before uploading any of
   them. `dist-<env>-<os>-<arch>` does the same for one package and uploads
   it. The target selects the pinned project and per-platform release bucket
   from `deploy/bluectl/`; do not run `dist.sh` directly.

   To build without uploading, run `make release-all` or
   `make release-<os>-<arch>`; packages land in
   `release/rust-<os>-<arch>.tar.gz`.
