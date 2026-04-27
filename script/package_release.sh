#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="Codex Usage"
EXECUTABLE_NAME="CodexUsageMonitor"
BUNDLE_ID="${BUNDLE_ID:-dev.idea-space.CodexUsageMonitor}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET="$DIST_DIR/AppIcon.iconset"
ICON_ICNS="$APP_RESOURCES/AppIcon.icns"

VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGNING_MODE="signed"
NOTARIZE="yes"
ARCH="${ARCH:-universal}"

usage() {
  cat <<USAGE
usage: $0 --version <version> [options]

Build and package a Developer ID release for direct distribution.

Required for formal release:
  --version <version>             CFBundleShortVersionString, for example 1.0.0
  --build <build>                 CFBundleVersion, defaults to the version
  --sign-identity <identity>      Developer ID Application signing identity
  --notary-profile <profile>      notarytool keychain profile name

Options:
  --bundle-id <bundle-id>         Override bundle id, defaults to $BUNDLE_ID
  --arch <arch>                   universal, arm64, x86_64, or host; defaults to universal
  --no-notarize                   Sign only; explicit non-notarized build
  --unsigned                      Build an unsigned local test package
  -h, --help                      Show this help

Environment variables can also provide VERSION, BUILD_NUMBER, SIGN_IDENTITY,
NOTARY_PROFILE, BUNDLE_ID, and ARCH.

Example:
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \\
  NOTARY_PROFILE="codex-usage-notary" \\
  $0 --version 1.0.0 --build 1
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

while (($#)); do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || fail "--build requires a value"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || fail "--sign-identity requires a value"
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || fail "--notary-profile requires a value"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || fail "--bundle-id requires a value"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || fail "--arch requires a value"
      ARCH="$2"
      shift 2
      ;;
    --no-notarize)
      NOTARIZE="no"
      shift
      ;;
    --unsigned)
      SIGNING_MODE="unsigned"
      NOTARIZE="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n "$VERSION" ]] || fail "missing --version"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "--version must be numeric, for example 1.0.0"

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$VERSION"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "--build must be numeric, for example 1 or 1.0.0"

case "$ARCH" in
  universal|arm64|x86_64|host)
    ;;
  *)
    fail "--arch must be universal, arm64, x86_64, or host"
    ;;
esac

if [[ "$SIGNING_MODE" == "signed" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] || fail "missing --sign-identity or SIGN_IDENTITY"
  if [[ "$NOTARIZE" == "yes" ]]; then
    [[ -n "$NOTARY_PROFILE" ]] || fail "missing --notary-profile or NOTARY_PROFILE"
  fi
fi

require_command swift
require_command xcrun
[[ -x /usr/bin/iconutil ]] || fail "missing /usr/bin/iconutil"
[[ -x /usr/bin/codesign ]] || fail "missing /usr/bin/codesign"
[[ -x /usr/bin/ditto ]] || fail "missing /usr/bin/ditto"
[[ -x /usr/bin/lipo ]] || fail "missing /usr/bin/lipo"
[[ -x /usr/bin/xattr ]] || fail "missing /usr/bin/xattr"
[[ -x /usr/sbin/spctl ]] || fail "missing /usr/sbin/spctl"
[[ -f "$ROOT_DIR/script/generate_app_icon.swift" ]] || fail "missing script/generate_app_icon.swift"

ARCHIVE_BASENAME="${APP_DISPLAY_NAME// /-}-$VERSION"
FINAL_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-$ARCH.zip"
NOTARY_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-notary.zip"

build_host_binary() {
  echo "Building release binary for host architecture..." >&2
  swift build -c release --manifest-cache local >&2
  local bin_path
  bin_path="$(swift build -c release --manifest-cache local --show-bin-path)"
  local binary="$bin_path/$EXECUTABLE_NAME"
  [[ -x "$binary" ]] || fail "release binary not found: $binary"
  printf '%s\n' "$binary"
}

build_arch_binary() {
  local arch="$1"
  local triple="$arch-apple-macosx$MIN_SYSTEM_VERSION"

  echo "Building release binary for $arch..." >&2
  swift build -c release --triple "$triple" --manifest-cache local >&2

  local bin_path
  bin_path="$(swift build -c release --triple "$triple" --manifest-cache local --show-bin-path)"
  local binary="$bin_path/$EXECUTABLE_NAME"
  [[ -x "$binary" ]] || fail "release binary not found: $binary"
  printf '%s\n' "$binary"
}

case "$ARCH" in
  universal)
    ARM_BINARY="$(build_arch_binary arm64)"
    X86_BINARY="$(build_arch_binary x86_64)"
    ;;
  arm64|x86_64)
    BUILD_BINARY="$(build_arch_binary "$ARCH")"
    ;;
  host)
    BUILD_BINARY="$(build_host_binary)"
    ;;
esac

echo "Assembling app bundle..."
rm -rf "$DIST_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

case "$ARCH" in
  universal)
    /usr/bin/lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$APP_BINARY"
    ;;
  arm64|x86_64|host)
    cp "$BUILD_BINARY" "$APP_BINARY"
    ;;
esac

chmod +x "$APP_BINARY"

swift "$ROOT_DIR/script/generate_app_icon.swift" "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
rm -rf "$ICONSET"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "signed" ]]; then
  echo "Signing app bundle..."
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

  if [[ "$NOTARIZE" == "yes" ]]; then
    echo "Submitting app for notarization..."
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"
    /usr/sbin/spctl --assess --type execute --verbose "$APP_BUNDLE"
    rm -f "$NOTARY_ARCHIVE"
  else
    echo "Skipping notarization because --no-notarize was provided."
  fi
else
  echo "Skipping signing and notarization because --unsigned was provided."
fi

echo "Creating distribution archive..."
rm -f "$FINAL_ARCHIVE"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$FINAL_ARCHIVE"

echo "Release package ready:"
echo "  app: $APP_BUNDLE"
echo "  zip: $FINAL_ARCHIVE"
