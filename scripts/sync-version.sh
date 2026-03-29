#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/sync-version.sh <version> [build-number]
  ./scripts/sync-version.sh --check <version> [build-number]

Examples:
  ./scripts/sync-version.sh 0.2.0
  ./scripts/sync-version.sh --check 0.2.0
  ./scripts/sync-version.sh 0.2.0 42
EOF
}

CHECK_ONLY=0

if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
    shift
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 1
fi

VERSION="$1"
BUILD_NUMBER="${2:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like 1.2.3" >&2
    exit 1
fi

if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: build number must contain only digits and dots" >&2
    exit 1
fi

extract_package_version() {
    perl -0ne 'print $1 if /\[package\]\n(?:(?!^\[).*\n)*?version = "([^"]+)"/ms' "$1"
}

extract_lock_version() {
    perl -0ne 'print $1 if /\[\[package\]\]\nname = "anovabar"\nversion = "([^"]+)"/ms' "$1"
}

extract_plist_value() {
    local file="$1"
    local key="$2"
    perl -0ne "print \$1 if /<key>\Q${key}\E<\/key>\s*<string>([^<]+)<\/string>/ms" "$file"
}

assert_equals() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" != "$actual" ]]; then
        echo "error: $label is '$actual', expected '$expected'" >&2
        exit 1
    fi
}

update_file() {
    local file="$1"
    local script="$2"
    VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" perl -0pi -e "$script" "$file"
}

if (( CHECK_ONLY )); then
    assert_equals "Cargo.toml version" \
        "$VERSION" \
        "$(extract_package_version "$ROOT_DIR/Cargo.toml")"
    assert_equals "Cargo.lock version" \
        "$VERSION" \
        "$(extract_lock_version "$ROOT_DIR/Cargo.lock")"
    assert_equals "AnovaBar short version" \
        "$VERSION" \
        "$(extract_plist_value "$ROOT_DIR/macos/AnovaBar/Resources/Info.plist" "CFBundleShortVersionString")"
    if [[ -n "$BUILD_NUMBER" ]]; then
        assert_equals "AnovaBar build number" \
            "$BUILD_NUMBER" \
            "$(extract_plist_value "$ROOT_DIR/macos/AnovaBar/Resources/Info.plist" "CFBundleVersion")"
    fi
    assert_equals "CLI short version" \
        "$VERSION" \
        "$(extract_plist_value "$ROOT_DIR/macos/anovabar-cli-Info.plist" "CFBundleShortVersionString")"
    if [[ -n "$BUILD_NUMBER" ]]; then
        assert_equals "CLI build number" \
            "$BUILD_NUMBER" \
            "$(extract_plist_value "$ROOT_DIR/macos/anovabar-cli-Info.plist" "CFBundleVersion")"
    fi
    if [[ -n "$BUILD_NUMBER" ]]; then
        echo "Versions already match $VERSION ($BUILD_NUMBER)."
    else
        echo "Release version fields already match $VERSION."
    fi
    exit 0
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$VERSION"
fi

update_file \
    "$ROOT_DIR/Cargo.toml" \
    's/(\[package\]\n(?:(?!^\[).*\n)*?version = ")[^"]+(")/$1.$ENV{VERSION}.$2/ems or die "failed to update Cargo.toml\n";'

update_file \
    "$ROOT_DIR/Cargo.lock" \
    's/(\[\[package\]\]\nname = "anovabar"\nversion = ")[^"]+(")/$1.$ENV{VERSION}.$2/ems or die "failed to update Cargo.lock\n";'

update_file \
    "$ROOT_DIR/macos/AnovaBar/Resources/Info.plist" \
    's/(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]+(<\/string>)/$1.$ENV{VERSION}.$2/ems or die "failed to update app short version\n"; s/(<key>CFBundleVersion<\/key>\s*<string>)[^<]+(<\/string>)/$1.$ENV{BUILD_NUMBER}.$2/ems or die "failed to update app build number\n";'

update_file \
    "$ROOT_DIR/macos/anovabar-cli-Info.plist" \
    's/(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]+(<\/string>)/$1.$ENV{VERSION}.$2/ems or die "failed to update CLI short version\n"; s/(<key>CFBundleVersion<\/key>\s*<string>)[^<]+(<\/string>)/$1.$ENV{BUILD_NUMBER}.$2/ems or die "failed to update CLI build number\n";'

echo "Updated release version to $VERSION ($BUILD_NUMBER)."
