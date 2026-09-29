# Rust language package

This package is for Rune maintainers only. You can install rust in Rune with the following
command from your `console`:

```
pkg install rust
```

This repo builds the Rune Rust language package (`rust.tar.gz`) and publishes it with
[`bluectl`](https://github.com/unstablebuild/blue). Releases cover macOS (`darwin`) and
Linux, each on `arm64` and `amd64`, in `staging` and `prod`.

1. **Prepare the build host.** Build macOS artifacts on macOS and Linux
   artifacts on Linux; cross-architecture builds on the same OS are supported.
   Install Go, a Rust toolchain recent enough for the pinned rust-analyzer,
   `rustup`, a C compiler, `wget`, `bluectl`, and tar (GNU `gtar` on macOS).
   Linux cross-architecture builds also need the target GNU cross-compiler
   (`aarch64-linux-gnu-gcc` or `x86_64-linux-gnu-gcc`). macOS releases need
   the configured Developer ID signing identity and a notarytool profile
   (`make notary-credentials` to set it up).
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out the intended release tag. Make sure `bluectl` can authenticate (the
   configs under `deploy/bluectl/` use your gcloud Application Default
   Credentials). Set `BLUE_PGP_KEY` and `BLUE_PGP_KEYRING` for upload; see
   `bluectl release upload -h` for their expected values.
3. **Build and check each artifact before publishing** on its OS, substituting
   `arm64` or `amd64`:

   ```sh
   make clean
   make notarize rust.tar.gz TARGET_ARCH=arm64
   make test TARGET_ARCH=arm64
   ```

4. **Publish** using the matching environment, OS, and architecture target:

   ```sh
   make dist-staging-darwin-arm64   # on macOS
   make dist-prod-darwin-amd64      # on macOS
   make dist-staging-linux-arm64    # on Linux
   make dist-prod-linux-amd64       # on Linux
   ```

   All `staging`/`prod` × `darwin`/`linux` × `arm64`/`amd64` combinations
   follow this naming pattern. Each target cleans, rebuilds, signs/notarizes
   on macOS, and uploads the tarball via `dist.sh`. The target selects the
   pinned project and per-platform release bucket from `deploy/bluectl/`;
   do not run `dist.sh` directly. Repeat the build/check for the other arch
   before its upload. The `darwin-amd64` package currently omits `lldb-dap`
   because LLVM 22 has no official macOS x86_64 prebuilt.
