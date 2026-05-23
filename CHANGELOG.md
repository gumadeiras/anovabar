# Changelog

## Unreleased

### Changes

- Added a lean Homebrew source archive that preserves the CLI app icon while excluding menu bar app, docs, and branding assets from Homebrew downloads.
- Updated release automation to the current checkout action and documented the local release wrapper.

## 0.1.4 - 2026-03-30

### Changes

- Added README trademark notice and refreshed branding assets.

## 0.1.3 - 2026-03-29

### Changes

- Switched the release workflow to macOS 15.

## 0.1.2 - 2026-03-29

### Changes

- Allowed unsigned GitHub releases when Apple signing secrets are unavailable.

## 0.1.1 - 2026-03-29

Initial release.

### Features

- Added Bluetooth control for Anova Nano, Mini / Gen 3, and original Precision Cooker devices.
- Added a Rust CLI for scanning, connecting, reading cooker state, and starting, stopping, or updating cooks.
- Added a macOS menu bar app with device selection, cook controls, saved names, debug diagnostics, status display, and app icons.
- Added setpoint validation and device-specific metadata for Mini cookers.
- Added automated macOS release workflow and installer support.

### Fixes

- Fixed original Precision Cooker discovery false positives, stop actions, completion command handling, menu bar label rendering, and connection response parsing.
- Fixed Mini CLI start and stop confirmation.
