#!/usr/bin/env python3
"""Add the Worms World Party Nightly updater action to the pinned recomp-ui launcher.

The shared UI stays a submodule. This guarded, idempotent patch adds only a
project-owned updater button/helper; it does not alter the rest of the launcher.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

SOURCE = Path("src/common/backends/imgui/launcher_imgui.cpp")
INCLUDE_ANCHOR = '#include "launcher_sdlcompat.h"   // pulls the right SDL header + event shim'
DRAW_ANCHOR = "void draw_dashboard(LauncherModel* m, const LauncherTheme& th, int logical_w) {"
END_ANCHOR = "\n}\n\n// Trim a path from the LEFT"
HELPER_MARKER = "WWP_NIGHTLY_UPDATER_HELPER"
BUTTON_MARKER = "WWP_NIGHTLY_UPDATER_BUTTON"
INCLUDE_MARKER = "WWP_NIGHTLY_UPDATER_PLATFORM_HEADERS"

INCLUDES = r'''
// WWP_NIGHTLY_UPDATER_PLATFORM_HEADERS
#if defined(_WIN32)
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  #include <windows.h>
#else
  #include <sys/types.h>
  #include <unistd.h>
#endif
'''

HELPER = r'''
// WWP_NIGHTLY_UPDATER_HELPER
#if defined(_WIN32) || defined(__APPLE__)
static std::string s_wwp_update_status;

static bool launch_wwp_nightly_updater(std::string* error) {
    const char* base_raw = SDL_GetBasePath();
    if (!base_raw || !base_raw[0]) {
        if (error) *error = "Could not locate the installed application folder.";
        return false;
    }
    const std::filesystem::path base = std::filesystem::path(base_raw).lexically_normal();
#if defined(_WIN32)
    const std::filesystem::path python = base / "overlay_toolchain" / "python" / "python.exe";
    const std::filesystem::path script = base / "update" / "updater.py";
#elif defined(__APPLE__)
    const std::filesystem::path resources = (base / ".." / "Resources").lexically_normal();
    const std::filesystem::path python = resources / "overlay_toolchain" / "python" / "bin" / "python3";
    const std::filesystem::path script = resources / "update" / "updater.py";
#endif
    if (!std::filesystem::is_regular_file(python) ||
        !std::filesystem::is_regular_file(script)) {
        if (error) *error =
            "The updater helper is missing from this installation. Download the newest Nightly manually.";
        return false;
    }

#if defined(_WIN32)
    const std::wstring python_w = python.wstring();
    const std::wstring script_w = script.wstring();
    const std::wstring base_w = base.wstring();
    std::wstring command = L"\"" + python_w + L"\" \"" + script_w +
        L"\" --install-root \"" + base_w + L"\" --parent-pid " +
        std::to_wstring(GetCurrentProcessId());
    std::vector<wchar_t> command_buffer(command.begin(), command.end());
    command_buffer.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, command_buffer.data(), nullptr, nullptr, FALSE,
                        DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
                        nullptr, base_w.c_str(), &startup, &process)) {
        if (error) *error = "Windows could not start the updater helper.";
        return false;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
#elif defined(__APPLE__)
    const std::string python_s = python.string();
    const std::string script_s = script.string();
    const std::string base_s = base.string();
    const std::string parent_pid = std::to_string(static_cast<long long>(getpid()));
    const pid_t child = fork();
    if (child < 0) {
        if (error) *error = "Could not start the updater helper.";
        return false;
    }
    if (child == 0) {
        (void)setsid();
        execl(python_s.c_str(), python_s.c_str(), script_s.c_str(),
              "--install-root", base_s.c_str(),
              "--parent-pid", parent_pid.c_str(),
              static_cast<char*>(nullptr));
        _exit(127);
    }
    return true;
#endif
}
#endif
'''

BUTTON = r'''
    // WWP_NIGHTLY_UPDATER_BUTTON
#if defined(_WIN32) || defined(__APPLE__)
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextColored(col(th.accent2), "Worms World Party Recompiled Updates");
    ImGui::TextWrapped("Check the official NVDEMU Nightly release. The updater verifies SHA-256 before installing and preserves saves and settings.");
    if (ImGui::Button("Check for Updates", ImVec2(px(220.0f), px(34.0f)))) {
        std::string error;
        if (launch_wwp_nightly_updater(&error)) {
            s_wwp_update_status =
                "Updater opened. Follow its prompts; close the game when it asks to install.";
        } else {
            s_wwp_update_status = error;
        }
    }
    if (!s_wwp_update_status.empty()) {
        ImGui::TextWrapped("%s", s_wwp_update_status.c_str());
    }
#else
    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextColored(col(th.accent2), "Worms World Party Recompiled Updates");
    ImGui::TextWrapped("Linux updates are installed by downloading the newest AppImage from GitHub Releases.");
#endif
'''


def fail(message: str, code: int = 2) -> int:
    print(message, file=sys.stderr)
    return code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ui-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    path = args.ui_root / SOURCE
    if not path.is_file():
        return fail(f"Required recomp-ui launcher source is missing: {path}")
    text = path.read_text(encoding="utf-8")

    if HELPER_MARKER in text:
        required = (BUTTON_MARKER, INCLUDE_MARKER, 'ImGui::Button("Check for Updates"')
        missing = [marker for marker in required if marker not in text]
        if missing:
            return fail("Updater launcher patch is incomplete; missing: " + ", ".join(missing), 3)
        print("Worms World Party updater launcher patch is already applied.")
        return 0

    if args.check:
        return fail("Worms World Party updater launcher patch has not been applied.", 1)

    for anchor, label in ((INCLUDE_ANCHOR, "header"),
                          (DRAW_ANCHOR, "dashboard"),
                          (END_ANCHOR, "dashboard end")):
        count = text.count(anchor)
        if count != 1:
            return fail(f"Pinned recomp-ui {label} anchor changed (expected 1 match, found {count}).")

    text = text.replace(INCLUDE_ANCHOR, INCLUDE_ANCHOR + "\n" + INCLUDES, 1)
    text = text.replace(DRAW_ANCHOR, HELPER + "\n" + DRAW_ANCHOR, 1)
    text = text.replace(END_ANCHOR, "\n" + BUTTON + END_ANCHOR, 1)
    if (HELPER_MARKER not in text or BUTTON_MARKER not in text or
            INCLUDE_MARKER not in text or text.count('ImGui::Button("Check for Updates"') != 1):
        return fail("Updater launcher patch failed its post-write checks.", 4)

    path.write_text(text, encoding="utf-8")
    print("Applied the Worms World Party Nightly updater button.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
