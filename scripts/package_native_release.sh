#!/usr/bin/env bash
# Build the end-user formats around the portable release ZIP produced by
# scripts/package_release.sh. No game disc or retail BIOS is bundled.
set -euo pipefail

PLATFORM="${1:?Usage: package_native_release.sh <platform> <version>}"
VERSION="${2:?Usage: package_native_release.sh <platform> <version>}"
DIST="${GITHUB_WORKSPACE:-$(pwd)}/dist"
ZIP="$(find "$DIST" -maxdepth 1 -type f -name "wwp-*-${PLATFORM}.zip" -print -quit)"
if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo "::error::No portable ZIP found for ${PLATFORM} in ${DIST}"
  ls -la "$DIST" || true
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PORTABLE="$WORK/portable"
mkdir -p "$PORTABLE"
unzip -q "$ZIP" -d "$PORTABLE"

find_game_binary() {
  find "$1" -type f \( -name 'WormsWorldParty_Recompiled' -o -name 'WormsWorldParty_Recompiled.exe' \) -print -quit
}

case "$PLATFORM" in
  windows-x64)
    EXE="$(find_game_binary "$PORTABLE")"
    if [[ -z "$EXE" ]]; then
      echo "::error::WormsWorldParty_Recompiled.exe was not found in the portable ZIP"
      find "$PORTABLE" -maxdepth 3 -type f | head -80
      exit 1
    fi
    cp "$EXE" "$DIST/wwp-${VERSION}-windows-x64.exe"
    file "$DIST/wwp-${VERSION}-windows-x64.exe"
    ;;

  macos-arm64|macos-x64)
    APP="$WORK/Worms World Party Recompiled.app"
    CONTENTS="$APP/Contents"
    MACOS="$CONTENTS/MacOS"
    RESOURCES="$CONTENTS/Resources"
    mkdir -p "$MACOS" "$RESOURCES"
    cp -a "$PORTABLE/." "$RESOURCES/"

    GAME="$(find_game_binary "$RESOURCES")"
    if [[ -z "$GAME" || "$GAME" == *.exe ]]; then
      echo "::error::Native macOS WormsWorldParty_Recompiled binary was not found"
      find "$RESOURCES" -maxdepth 3 -type f | head -80
      exit 1
    fi
    mv "$GAME" "$MACOS/WormsWorldParty_Recompiled.real"
    chmod +x "$MACOS/WormsWorldParty_Recompiled.real"

    # The small native launcher gives Finder a real Mach-O application entry
    # point, sets the resource working directory, and applies the SDL3
    # macOS mouse workaround that was verified with this project.
    cat > "$WORK/wwp-macos-launcher.c" <<'C_SOURCE'
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX];
    uint32_t executable_size = (uint32_t)sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0) {
        fprintf(stderr, "Worms World Party Recompiled: cannot resolve app executable path\n");
        return 127;
    }

    char canonical[PATH_MAX];
    if (realpath(executable, canonical) == NULL) {
        perror("Worms World Party Recompiled: realpath");
        return 127;
    }

    char *slash = strrchr(canonical, '/');
    if (slash == NULL) {
        fprintf(stderr, "Worms World Party Recompiled: malformed app path\n");
        return 127;
    }
    *slash = '\0'; /* Contents/MacOS */

    char resources[PATH_MAX];
    if (snprintf(resources, sizeof(resources), "%s/../Resources", canonical) >= (int)sizeof(resources)) {
        fprintf(stderr, "Worms World Party Recompiled: resource path too long\n");
        return 127;
    }
    if (chdir(resources) != 0) {
        perror("Worms World Party Recompiled: cannot open bundled resources");
        return 127;
    }

    /* Keep the tested SDL3 behavior for synthetic/alternate mouse devices. */
    if (getenv("SDL_MAC_USE_GCMOUSE") == NULL) {
        setenv("SDL_MAC_USE_GCMOUSE", "0", 1);
    }

    char game_binary[PATH_MAX];
    if (snprintf(game_binary, sizeof(game_binary), "%s/WormsWorldParty_Recompiled.real", canonical) >= (int)sizeof(game_binary)) {
        fprintf(stderr, "Worms World Party Recompiled: executable path too long\n");
        return 127;
    }

    char **child_argv = calloc((size_t)argc + 3, sizeof(char *));
    if (child_argv == NULL) {
        perror("Worms World Party Recompiled: calloc");
        return 127;
    }
    child_argv[0] = game_binary;
    child_argv[1] = "--game";
    child_argv[2] = "game.toml";
    for (int i = 1; i < argc; ++i) {
        child_argv[i + 2] = argv[i];
    }
    execv(game_binary, child_argv);
    perror("Worms World Party Recompiled: execv");
    return 127;
}
C_SOURCE
    xcrun --find clang >/dev/null
    clang -O2 -Wall -Wextra -Werror "$WORK/wwp-macos-launcher.c" -o "$MACOS/WormsWorldPartyRecompiled"

    NUMERIC_VERSION="${VERSION%%[-+]*}"
    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>WormsWorldPartyRecompiled</string>
  <key>CFBundleIdentifier</key><string>com.nvdemu.wormsworldpartyrecompiled</string>
  <key>CFBundleName</key><string>Worms World Party Recompiled</string>
  <key>CFBundleDisplayName</key><string>Worms World Party Recompiled</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${NUMERIC_VERSION}</string>
  <key>CFBundleVersion</key><string>${NUMERIC_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

    # Use Developer ID + notarization only when ALL credentials exist.
    # Otherwise an ad-hoc signature still ensures the bundle isn't shipped
    # with a stale/broken signature (which can trigger the "damaged" dialog).
    SIGNING_READY=0
    if [[ -n "${APPLE_CERTIFICATE_P12_BASE64:-}" &&
          -n "${APPLE_CERTIFICATE_PASSWORD:-}" &&
          -n "${APPLE_ID:-}" &&
          -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" &&
          -n "${APPLE_TEAM_ID:-}" ]]; then
      SIGNING_READY=1
    fi

    if [[ "$SIGNING_READY" == "1" ]]; then
      KEYCHAIN="$WORK/wwp-build.keychain-db"
      KEYCHAIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
      CERT="$WORK/developer-id.p12"
      printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 -D > "$CERT"
      security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
      security set-keychain-settings -lut 21600 "$KEYCHAIN"
      security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
      security import "$CERT" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
      security list-keychains -d user -s "$KEYCHAIN"
      security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
      IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
      if [[ -z "$IDENTITY" ]]; then
        echo "::error::Apple signing secrets were set, but no Developer ID Application identity was found"
        exit 1
      fi
      codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
    else
      echo "::notice::Apple Developer ID/notarization secrets are not all configured; using a valid ad-hoc signature"
      codesign --force --deep --sign - --timestamp=none "$APP"
    fi

    codesign --verify --deep --strict --verbose=2 "$APP"
    DMG_ROOT="$WORK/dmg-root"
    mkdir -p "$DMG_ROOT"
    cp -a "$APP" "$DMG_ROOT/"
    ln -s /Applications "$DMG_ROOT/Applications"
    DMG="$DIST/wwp-${VERSION}-${PLATFORM}.dmg"
    hdiutil create -volname "Worms World Party Recompiled" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
    hdiutil verify "$DMG"

    if [[ "$SIGNING_READY" == "1" ]]; then
      # Sign and notarize the disk image too; stapling lets Gatekeeper validate
      # it offline after a successful notarization.
      codesign --force --sign "$IDENTITY" --timestamp "$DMG"
      xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
    fi
    ;;

  linux-x64)
    APPDIR="$WORK/AppDir"
    DATA="$APPDIR/opt/wormsworldparty"
    mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps" "$DATA"
    cp -a "$PORTABLE/." "$DATA/"

    GAME="$(find_game_binary "$DATA")"
    if [[ -z "$GAME" || "$GAME" == *.exe ]]; then
      echo "::error::Native Linux WormsWorldParty_Recompiled binary was not found"
      find "$DATA" -maxdepth 3 -type f | head -80
      exit 1
    fi
    mv "$GAME" "$APPDIR/usr/bin/WormsWorldParty_Recompiled"
    chmod +x "$APPDIR/usr/bin/WormsWorldParty_Recompiled"

    cat > "$APPDIR/AppRun" <<'APP_RUN'
#!/bin/sh
set -eu
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$APPDIR/opt/wormsworldparty"
exec "$APPDIR/usr/bin/WormsWorldParty_Recompiled" --game "$APPDIR/opt/wormsworldparty/game.toml" "$@"
APP_RUN
    chmod +x "$APPDIR/AppRun"
    cat > "$APPDIR/usr/share/applications/wwp.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Worms World Party Recompiled
Comment=Play Worms World Party with the PSXRecomp native port
Exec=AppRun
Icon=wwp
Categories=Game;
Terminal=false
DESKTOP
    ICON="$DATA/assets/psxrecomp.png"
    if [[ ! -f "$ICON" ]]; then
      ICON="$DATA/assets/psxrecomp.svg"
    fi
    if [[ ! -f "$ICON" ]]; then
      echo "::error::No app icon found in the portable package"
      exit 1
    fi
    cp "$ICON" "$APPDIR/usr/share/icons/hicolor/256x256/apps/wwp.${ICON##*.}"
    LINUXDEPLOY="$WORK/linuxdeploy-x86_64.AppImage"
    curl --fail --location --retry 3 --silent --show-error \
      https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage \
      --output "$LINUXDEPLOY"
    chmod +x "$LINUXDEPLOY"
    ARCH=x86_64 "$LINUXDEPLOY" --appimage-extract-and-run \
      --appdir "$APPDIR" \
      --executable "$APPDIR/usr/bin/WormsWorldParty_Recompiled" \
      --desktop-file "$APPDIR/usr/share/applications/wwp.desktop" \
      --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/wwp.${ICON##*.}" \
      --output appimage

    APPIMAGE="$(find . -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
    if [[ -z "$APPIMAGE" ]]; then
      echo "::error::linuxdeploy did not produce an AppImage"
      find "$WORK" -maxdepth 4 -type f | head -80
      exit 1
    fi
    mv "$APPIMAGE" "$DIST/wwp-${VERSION}-linux-x64.AppImage"
    chmod +x "$DIST/wwp-${VERSION}-linux-x64.AppImage"
    file "$DIST/wwp-${VERSION}-linux-x64.AppImage"
    ;;

  *)
    echo "::error::Unsupported platform: $PLATFORM"
    exit 2
    ;;
esac

echo "Native release package(s) created:"
find "$DIST" -maxdepth 1 -type f -name "wwp-*-${PLATFORM}.*" -print
