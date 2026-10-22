#!/usr/bin/env python3
"""Patch PSXRecomp's data-directory resolver for WWP's native macOS .app.

The WWP app bundle places game.toml, mods/, BIOS data and settings in
Contents/Resources while its real Mach-O executable lives in Contents/MacOS.
PSXRecomp normally anchors all sidecar data on the executable directory. This
small, guarded source patch makes the data root match the app bundle layout;
portable Windows/Linux builds and ordinary non-bundle macOS builds are
unchanged.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

MARKER = "// WWP_MACOS_APP_RESOURCES_DIR"
ANCHOR = '    // Last-ditch only (should be unreachable on a normal launch); a bare "." so'
PATCH = '''    // WWP_MACOS_APP_RESOURCES_DIR: the .app's game data is in Contents/Resources.
#if defined(__APPLE__)
    if (!exe_dir.empty() && exe_dir.filename() == "MacOS" &&
        exe_dir.parent_path().filename() == "Contents") {
        const fs::path resource_dir = exe_dir.parent_path() / "Resources";
        ec.clear();
        if (fs::is_directory(resource_dir, ec) && !ec) {
            exe_dir = resource_dir;
        }
        ec.clear();
    }
#endif
'''


def patch(path: Path) -> bool:
    if not path.is_file():
        raise RuntimeError(f"PSXRecomp runtime entry point does not exist: {path}")
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        if PATCH.strip() not in source:
            raise RuntimeError(
                f"{path} contains the WWP patch marker but its code does not match; "
                "refusing to silently accept a partial patch"
            )
        return False
    count = source.count(ANCHOR)
    if count != 1:
        raise RuntimeError(
            f"expected exactly one PSXRecomp exe_dir_from_argv insertion point "
            f"in {path}, found {count}; update this patch for the new framework"
        )
    path.write_text(source.replace(ANCHOR, PATCH + ANCHOR, 1), encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-main", required=True, type=Path)
    args = parser.parse_args()
    try:
        changed = patch(args.runtime_main)
    except (OSError, RuntimeError, UnicodeError) as exc:
        print(f"WWP macOS app data-path patch failed: {exc}", file=sys.stderr)
        return 1
    print(
        "Applied WWP macOS app data-path patch"
        if changed else "WWP macOS app data-path patch already present"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
