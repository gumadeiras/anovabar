<p align="center">
  <img src="assets/anovabar.png" alt="AnovaBar logo" width="320">
</p>

# AnovaBar

Bluetooth control for Anova cookers, with a macOS menu bar app and a Rust CLI.

## What It Does

- Scan and connect to supported Anova cookers
- Read temperature, timer, and live state
- Start, stop, and update cooks over BLE
- Drive everything from the menu bar or the terminal

## Supported Today

- Mini / Gen 3
- Original Precision Cooker

## Quick Start

Build the macOS app:

```bash
./macos/build-menubar-app.sh
open dist/AnovaBar.app
```

Run the CLI:

```bash
cargo run -- --help
```

## Project Layout

- `macos/AnovaBar`: native menu bar app
- `src`: Rust library and CLI
- `assets/anovabar.png`: logo used in this README
- `assets/anovabar.pdf`: source artwork

Sous vide, but make it tiny and fast.
