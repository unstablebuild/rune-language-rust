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
   (a Linux host can build only the Linux packages). Install Go, a Rust
   toolchain recent enough for the pinned rust-analyzer, `rustup`, `zig`,
   `wget`, `bluectl`, and tar (GNU `gtar` on macOS). Packages are not signed
   with a Developer ID or notarized: Rune downloads them without the quarantine
   attribute, so Gatekeeper never assesses them.
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
   them. `dist-<env>-<os>-<arch>` builds, tests, and uploads one. The target
   selects the pinned project and per-platform release bucket from
   `deploy/bluectl/`; do not run `dist.sh` directly.

   To build without uploading, run `make release-all` or
   `make release-<os>-<arch>`; packages land in
   `release/rust-<os>-<arch>.tar.gz`. The `darwin-amd64` package omits
   `lldb-dap` because LLVM 22 has no official macOS x86_64 prebuilt.
