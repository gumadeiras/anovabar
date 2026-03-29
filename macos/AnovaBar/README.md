# AnovaBar

`AnovaBar` is a macOS menu bar app for controlling supported Anova cookers over Bluetooth Low Energy.

## Scope

- Native `MenuBarExtra` app for macOS
- Scans for nearby supported Anova cookers
- Connects, syncs the clock when supported, and reads live state
- Lets you set temperature, change units, start, and stop a cook
- Built separately from the Rust CLI so Bluetooth privacy permissions live in the app process that talks to CoreBluetooth

Supported in the app today:

- Nano
- Mini / Gen 3
- Original Precision Cooker

## Build

From the repo root:

```bash
./macos/build-menubar-app.sh
```

That creates:

```text
dist/AnovaBar.app
```

## Run

```bash
open dist/AnovaBar.app
```

If macOS prompts for Bluetooth pairing or access, allow it. Supported cookers may disconnect if pairing is rejected.
