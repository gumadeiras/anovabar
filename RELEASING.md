# Releasing AnovaBar

Version metadata is shared across the Rust crate and both macOS app bundles. Update all release version fields together with:

```bash
./scripts/sync-version.sh 0.2.0
```

If you want a separate macOS build number, pass it as the second argument:

```bash
./scripts/sync-version.sh 0.2.0 42
```

That updates:

- `Cargo.toml`
- `Cargo.lock`
- `macos/AnovaBar/Resources/Info.plist`
- `macos/anovabar-cli-Info.plist`

Before tagging a release, verify the repo state:

```bash
cargo test
swift test --package-path macos/AnovaBar
```

To build local release archives:

```bash
./scripts/package-release.sh
```

That writes:

- `dist/release/AnovaBar.app.zip`
- `dist/release/anovabar-cli-macos.zip`
- `dist/release/SHA256SUMS.txt`

Public GitHub releases are automated by `.github/workflows/release.yml` and trigger on tags like `v0.2.0`. The workflow checks that the tag matches the version files, runs the Rust and Swift tests, builds signed app bundles, notarizes them, packages the release assets, and creates or updates a draft GitHub Release.

Required GitHub Actions secrets:

- `ANOVABAR_CODESIGN_IDENTITY`: Developer ID Application certificate name, for example `Developer ID Application: Your Name (TEAMID)`
- `ANOVABAR_MACOS_CERTIFICATE_P12_BASE64`: base64-encoded `.p12` certificate export
- `ANOVABAR_MACOS_CERTIFICATE_PASSWORD`: password for the `.p12` export
- `ANOVABAR_APPLE_ID`: Apple ID used for notarization
- `ANOVABAR_APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization
- `ANOVABAR_APPLE_TEAM_ID`: Apple Developer team ID

Once the version bump commit is pushed, create the release tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```
