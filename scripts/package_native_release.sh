#!/usr/bin/env bash
# Build the end-user formats around the portable release ZIP produced by
# scripts/package_release.sh. No game disc or retail BIOS is bundled.
set -euo pipefail

PLATFORM="${1:?Usage: package_native_release.sh <platform> <version>}"
VERSION="${2:?Usage: package_native_release.sh <platform> <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
cd "${ROOT}"
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
    ls -lh "$DIST/wwp-${VERSION}-windows-x64.exe"
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

    # Bundle every non-system dylib dependency into Contents/Frameworks.
    # A CI build can link successfully against Homebrew's SDL3, but that
    # Homebrew path does not exist on a player's Mac. Rewrite load commands so
    # Finder launches the same self-contained app without requiring Homebrew.
    python3 - "$MACOS/WormsWorldParty_Recompiled.real" "$CONTENTS/Frameworks" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

binary = Path(sys.argv[1]).resolve()
frameworks = Path(sys.argv[2])
frameworks.mkdir(parents=True, exist_ok=True)
executable_dir = binary.parent

SYSTEM_PREFIXES = (
    "/System/Library/",
    "/usr/lib/",
    "/System/iOSSupport/System/Library/",
    "/Library/Apple/System/Library/",
)
SYSTEM_NAMES = {
    "libSystem.B.dylib", "libSystem.dylib", "libc++.1.dylib", "libc++abi.dylib",
    "libobjc.A.dylib", "libdispatch.dylib", "libdyld.dylib",
}
def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout

def is_system_path(value):
    return value.startswith(SYSTEM_PREFIXES)

def rpaths_for(image):
    lines = run("otool", "-l", str(image)).splitlines()
    result = []
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for next_line in lines[i + 1:i + 5]:
                match = re.match(r"\s*path (.+) \(offset \d+\)", next_line)
                if match:
                    result.append(match.group(1))
                    break
    return result

def expand_rpath(value, image):
    if value.startswith("@loader_path/"):
        return str(image.parent / value[len("@loader_path/"):])
    if value == "@loader_path":
        return str(image.parent)
    if value.startswith("@executable_path/"):
        return str(executable_dir / value[len("@executable_path/"):])
    if value == "@executable_path":
        return str(executable_dir)
    return value

def dependencies(image):
    lines = run("otool", "-L", str(image)).splitlines()[1:]
    result = []
    for line in lines:
        match = re.match(r"\s*(.+?) \((?:compatibility|current) version ", line)
        if match:
            result.append(match.group(1))
    return result

prefixes = {Path("/opt/homebrew"), Path("/usr/local")}
try:
    brew_prefix = run("brew", "--prefix").strip()
    if brew_prefix:
        prefixes.add(Path(brew_prefix))
except (FileNotFoundError, subprocess.CalledProcessError):
    pass

search_roots = []
for prefix in sorted(prefixes, key=str):
    search_roots.append(prefix / "lib")
    opt = prefix / "opt"
    if opt.is_dir():
        for formula in opt.iterdir():
            search_roots.extend((formula / "lib", formula / "Frameworks"))

def resolve_dependency(load_name, image, rpath_stack):
    candidates = []
    if load_name.startswith("/"):
        candidates.append(Path(load_name))
    elif load_name.startswith("@loader_path/"):
        candidates.append(image.parent / load_name[len("@loader_path/"):])
    elif load_name.startswith("@executable_path/"):
        candidates.append(executable_dir / load_name[len("@executable_path/"):])
    elif load_name.startswith("@rpath/"):
        suffix = load_name[len("@rpath/"):]
        for raw_rpath in rpath_stack:
            root = Path(expand_rpath(raw_rpath, image))
            candidates.append(root / suffix)
        for root in search_roots:
            candidates.append(root / suffix)
    else:
        candidates.append(image.parent / load_name)
        for root in search_roots:
            candidates.append(root / load_name)

    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if resolved.is_file():
            return resolved
    if Path(load_name).name in SYSTEM_NAMES:
        return None
    return None

source_to_dest = {}
dest_sources = {}
edges = {}
pending = [(binary, [])]
seen = set()

while pending:
    image, inherited_rpaths = pending.pop()
    image = image.resolve()
    if image in seen:
        continue
    seen.add(image)
    current_rpaths = rpaths_for(image) + list(inherited_rpaths)
    image_edges = []
    for load_name in dependencies(image):
        if is_system_path(load_name):
            continue
        source = resolve_dependency(load_name, image, current_rpaths)
        if source is None:
            raise SystemExit(
                "ERROR: unresolved non-system macOS dependency "
                + repr(load_name) + " loaded by " + str(image)
            )
        if is_system_path(str(source)):
            continue
        source_key = source.resolve()
        if source_key not in source_to_dest:
            name = Path(load_name.rstrip("/")).name or source_key.name
            if name in dest_sources and dest_sources[name] != source_key:
                digest = hashlib.sha256(str(source_key).encode()).hexdigest()[:8]
                suffix = "".join(Path(name).suffixes)
                stem = name[:-len(suffix)] if suffix else name
                name = stem + "-" + digest + suffix
            destination = frameworks / name
            if destination.exists() and source_key not in dest_sources.values():
                digest = hashlib.sha256(str(source_key).encode()).hexdigest()[:8]
                suffix = "".join(Path(name).suffixes)
                stem = name[:-len(suffix)] if suffix else name
                name = stem + "-" + digest + suffix
                destination = frameworks / name
            shutil.copy2(source_key, destination)
            source_to_dest[source_key] = destination
            dest_sources[destination.name] = source_key
            pending.append((source_key, current_rpaths))
            print("Bundled macOS dependency:", source_key, "->", destination)
        image_edges.append((load_name, source_to_dest[source_key].name))
    edges[image] = image_edges

# Rewrite imports only after the complete dependency closure has been copied.
for image, image_edges in edges.items():
    target = binary if image == binary else source_to_dest[image]
    for old_name, bundled_name in image_edges:
        replacement = ("@rpath/" if image == binary else "@loader_path/") + bundled_name
        if old_name != replacement:
            subprocess.run(["install_name_tool", "-change", old_name, replacement, str(target)],
                           check=True)
    if image == binary:
        existing = rpaths_for(target)
        if "@executable_path/../Frameworks" not in existing:
            subprocess.run(["install_name_tool", "-add_rpath",
                            "@executable_path/../Frameworks", str(target)], check=True)
    else:
        subprocess.run(["install_name_tool", "-id",
                        "@rpath/" + target.name, str(target)], check=True)

# Verify that no dependency still points at a build-machine/Homebrew path.
for target in [binary, *source_to_dest.values()]:
    for load_name in dependencies(target):
        if load_name.startswith(("/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/")):
            raise SystemExit("ERROR: non-portable dylib reference remains: "
                             + str(target) + " -> " + load_name)
print("macOS dependency bundle verified:", len(source_to_dest), "non-system dylib(s)")
PY

    # The launcher itself is tiny and native; explicitly match the app's
    # advertised minimum OS instead of inheriting the build runner's default.

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
    MACOSX_DEPLOYMENT_TARGET=11.0 clang -O2 -Wall -Wextra -Werror "$WORK/wwp-macos-launcher.c" -o "$MACOS/WormsWorldPartyRecompiled"

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
    # Keep the real executable beside game.toml, bios/, assets/, and the
    # overlay toolchain: PSXRecomp resolves runtime payload paths relative to
    # the executable / app base path. linuxdeploy gets a copy for dependency
    # scanning while AppRun launches the co-located original.
    chmod +x "$GAME"
    cp "$GAME" "$APPDIR/usr/bin/WormsWorldParty_Recompiled"

    cat > "$APPDIR/AppRun" <<'APP_RUN'
#!/bin/sh
set -eu
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$APPDIR/opt/wormsworldparty"
exec "$APPDIR/opt/wormsworldparty/WormsWorldParty_Recompiled" --game "$APPDIR/opt/wormsworldparty/game.toml" "$@"
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

    APPIMAGE="$(find "${ROOT}" -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
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
