# Worms World Party Recompiled

A native recompiled version of **Worms World Party (PlayStation, US / SLUS-01448)** built with [PSXRecomp](https://github.com/mstan/psxrecomp).

## Downloads

Open **[Releases](https://github.com/NVDEMU/WormsWorldPartyRecomp/releases/latest)** and choose the asset for your operating system:

| Asset | Platform | Notes |
|---|---|---|
| `wwp-<version>-windows-x64.zip` | Windows 10/11, x64 | Recommended Windows download. Contains the executable and the runtime files it needs. |
| `wwp-<version>-windows-x64.exe` | Windows, x64 | The executable by itself; it still needs the matching ZIP's runtime files beside it. |
| `wwp-<version>-macos-arm64.dmg` | Apple Silicon Mac | Contains a `.app` bundle. |
| `wwp-<version>-macos-x64.dmg` | Intel Mac | Contains a `.app` bundle. |
| `wwp-<version>-linux-x64.AppImage` | Linux, x86-64 | Make executable, then launch it. |
| `wwp-<version>-<platform>.zip` | Any supported build target | Portable runtime package and supporting data. |

The game executable and runtime are provided; **the retail game disc and retail PlayStation BIOS are not**. Select your legally obtained disc image in the first-run launcher, or pass its CUE path with `--disc`. The bundled OpenBIOS backend is included.

### In-app Nightly updater

Windows and macOS Nightly builds include **Check for Updates** in the launcher dashboard. The updater checks the official `NVDEMU/WormsWorldPartyRecomp` Nightly release, asks before downloading, verifies the matching platform ZIP against its SHA-256 checksum, and waits for the game to close before installing. It preserves player saves, settings, disc/BIOS selections, controller mappings, and mod-enable state.

The first version with the updater must be installed manually from Releases. Later Nightly builds can be installed from the launcher. Linux AppImage updates remain manual for now: download the newest AppImage from [Releases](https://github.com/NVDEMU/WormsWorldPartyRecomp/releases).

If a Mac installation is Developer ID-signed, the updater will refuse to rewrite that sealed app; install the new DMG instead. Current builds are ad-hoc signed unless the optional Apple signing/notarization secrets are configured.

### macOS Gatekeeper

The release workflow verifies the app's code signature after packaging so the bundle is not shipped with a stale or invalid signature. For completely seamless Gatekeeper approval, configure the Apple Developer ID and notarization secrets listed under [macOS release signing](#macos-release-signing). Apple requires a Developer ID signature and notarization for the normal trusted-distribution path. Without those credentials the workflow uses an ad-hoc signature, which can still result in an “unidentified developer” warning on a downloaded app. See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/) and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

If macOS reports that the app is **damaged**, first re-download the DMG from this repository's Releases page and make sure the download completed. For a build you trust, you can remove the quarantine flag from the installed app in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Worms World Party Recompiled.app"
```

This command changes macOS's downloaded-file security metadata; only use it for a copy you trust. It is not a substitute for Developer ID signing and notarization.

## Build from source

### Requirements

- Git with submodule support
- Python 3
- CMake and Ninja
- A working C/C++ compiler toolchain (Xcode Command Line Tools on macOS, GCC/Clang on Linux, or MSYS2 MinGW-w64 on Windows)
- SDL development support and Vulkan headers plus `glslc`/shaderc for the Vulkan-enabled build
- A legally obtained Worms World Party PS1 disc image in CUE/BIN or another format supported by the runtime

### 1. Clone the repository and submodules

```sh
git clone --recurse-submodules https://github.com/NVDEMU/WormsWorldPartyRecomp.git
cd WormsWorldPartyRecomp
git submodule update --init --recursive
```

### 2. Install build tools

**macOS** (Apple Silicon and Intel; requires Xcode Command Line Tools):

```sh
xcode-select --install
brew install cmake ninja pkg-config sdl3 vulkan-headers shaderc molten-vk
```

**Ubuntu/Debian Linux:**

```sh
sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build pkg-config \
  libsdl2-dev libgl1-mesa-dev libx11-dev libxext-dev libxrandr-dev \
  libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxkbcommon-dev \
  libasound2-dev libpulse-dev libudev-dev libvulkan-dev glslc unzip
```

The build fetches its pinned SDL3 source when SDL3 development packages are unavailable.

**Windows:** Install [MSYS2](https://www.msys2.org/), open the **MINGW64** shell, then install the project dependencies:

```sh
pacman -Syu
pacman -S --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-ninja mingw-w64-x86_64-SDL2 mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-vulkan-headers mingw-w64-x86_64-shaderc curl zip unzip
```

### 3. Build the PSXRecomp emitters

Run from the repository root:

```sh
unset PSXRECOMP_TOOLCHAIN_DIR TOOLCHAIN_DIR BPE_TOOLCHAIN_DIR RETCOMM_TOOLCHAIN_DIR
bash psxrecomp/tools/ci/build_emitters.sh
```

### 4. Generate the game code (developer setup)

Generation requires your own disc image. For example on macOS/Linux:

```sh
DISC="/absolute/path/to/Worms World Party (USA).cue"
RETCOMM_TOOLCHAIN_MIN_VERSION=999.0.0 \
  python3 psxrecomp/psxrecomp_cli.py generate \
    --config game.toml \
    --project-root . \
    --disc "$DISC" \
    --no-toolchain-download
```

Use the actual path to your CUE file. Keep the disc image and any retail BIOS dump out of Git and out of release assets. The generated game C and its stamp files are project build inputs; regenerate them when the framework or game configuration changes.

### 5. Configure and compile

```sh
cmake -S . -B build-release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-release --target psx-runtime
```

The native executable is written to:

- macOS/Linux: `build-release/WormsWorldParty_Recompiled`
- Windows: `build-release/WormsWorldParty_Recompiled.exe`

If you use a different build directory, replace `build-release` in the paths above.

### 6. Run

From the repository root, open the launcher with your own game configuration:

```sh
./build-release/WormsWorldParty_Recompiled --game "$PWD/game.toml"
```

You can supply a disc directly:

```sh
./build-release/WormsWorldParty_Recompiled \
  --game "$PWD/game.toml" \
  --disc "/absolute/path/to/Worms World Party (USA).cue"
```

On macOS, this SDL3 environment setting is also applied by the packaged app because it avoids a mouse-input problem encountered on some setups:

```sh
SDL_MAC_USE_GCMOUSE=0 ./build-release/WormsWorldParty_Recompiled --game "$PWD/game.toml"
```

## GitHub Release packaging

The `.github/workflows/release.yml` workflow builds Windows x64, Linux x64, macOS Apple Silicon, and macOS Intel. Alongside the portable ZIP it creates the Windows executable, a macOS DMG containing a real `.app` bundle (plus an app ZIP used by the updater), and the Linux AppImage. Nightly releases include SHA-256 files and a channel/commit manifest consumed by the Windows/macOS updater. The macOS launcher sets its working directory to the app's bundled resources, bundles its non-system dylib dependencies, and preserves the tested SDL3 input workaround. The workflow runs `codesign --verify --deep --strict` after signing the app.

To enable trusted macOS distribution without the unidentified-developer warning, configure these repository Actions secrets:

- `APPLE_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application certificate and private key in a `.p12` file
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password
- `APPLE_TEAM_ID`: Apple Developer Team ID

When all five are configured, the workflow signs with Developer ID, submits the DMG for notarization, staples the ticket, and validates it. Otherwise it ad-hoc-signs and verifies the app, but macOS may still show a Gatekeeper warning because the bundle is not notarized.

## Project completeness

GitHub Actions can only build from files committed to the repository. The current `main` branch must include the generated game's `CMakeLists.txt`, `game.toml`, `codegen_setup.c`, and generated game C/stamp files before a fresh checkout can build a release. The title-specific `scripts/package_release.sh` wrapper is included in this repository. Do not commit the game disc image or a retail BIOS dump.

## Credits and licensing

- [PSXRecomp](https://github.com/mstan/psxrecomp) — PlayStation static recompilation framework
- [recomp-ui](https://github.com/RetroPortingToolKit/recomp-ui) — launcher/UI integration
- See the framework and bundled dependency notices included in each portable release for their respective licenses.
