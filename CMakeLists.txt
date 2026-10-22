cmake_minimum_required(VERSION 3.20)
set(PSXRECOMP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/psxrecomp" CACHE PATH
    "Path to psxrecomp")
if(NOT EXISTS "${PSXRECOMP_ROOT}/runtime/runtime.cmake")
    message(FATAL_ERROR
        "PSXRecomp runtime is missing: ${PSXRECOMP_ROOT}/runtime/runtime.cmake\n"
        "This project expects the psxrecomp framework checkout at ${PSXRECOMP_ROOT}.\n"
        "Run: git submodule update --init --recursive\n"
        "If psxrecomp/ is not a submodule, set -DPSXRECOMP_ROOT=<path-to-psxrecomp>.")
endif()

project(WormsWorldPartyRecomp LANGUAGES C CXX)

# This title ships framework builtin mods and exposes them in its launcher.
# Force the Mods view on even in an existing build directory whose cache still
# records recomp-ui's former default (OFF); otherwise the packages can be
# present in the release while the player has no Mods page to configure them.
set(RECOMP_UI_ENABLE_MODS ON CACHE BOOL
    "Enable WWP's schema-driven PSXRecomp Mods launcher view" FORCE)

# --- Product surfaces required by this game --------------------------------
# Scaffold prompts / flags fill these. Without recomp-ui, PSX_RECOMP_UI is OFF.
# The wizard (WIZARD_CMAKE_BLOCK / ENABLE_SETUP_WIZARD) is the first-run disc
# picker; releases are compiled from the committed generated/ C, so it never
# needs to generate or rebuild anything on a player's machine.
# recomp-ui submodule present (PSX_RECOMP_UI defaults ON).
if(EXISTS "${PSXRECOMP_ROOT}/lib/recomp-net/CMakeLists.txt")
    set(PSX_NETPLAY ON CACHE BOOL
        "Link recomp-net delay-sync (opt-in; needs recomp-net)" FORCE)
endif()
set(PSX_SETUP_WIZARD ON CACHE BOOL
    "Advertise first-run setup wizard + Generate & rebuild in recomp-ui" FORCE)

# Add a project-owned, guarded Nightly updater action to the shared launcher.
# The patch mutates only this checkout's recomp-ui submodule for the build.
if(NOT EMSCRIPTEN AND NOT ANDROID)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    execute_process(
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/apply_wwp_updater_patch.py"
                --ui-root "${CMAKE_CURRENT_SOURCE_DIR}/recomp-ui"
        RESULT_VARIABLE WWP_UPDATER_PATCH_RESULT
    )
    if(NOT WWP_UPDATER_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not apply the Worms World Party Nightly updater launcher patch.")
    endif()
endif()

# The macOS app bundles runtime data in Contents/Resources but keeps the real
# executable in Contents/MacOS. PSXRecomp otherwise scans <exe-dir>/mods and
# leaves the pre-boot Mods list empty. Patch the pinned runtime's data-root
# resolver before its source is added to the target. The script fails closed if
# the expected upstream insertion point changes, so CI cannot silently ship
# another app whose Mods provider points at the wrong directory.
if(APPLE AND NOT EMSCRIPTEN AND NOT ANDROID)
    execute_process(
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/apply_wwp_macos_bundle_paths_patch.py"
                --runtime-main "${PSXRECOMP_ROOT}/runtime/src/main.cpp"
        RESULT_VARIABLE WWP_MACOS_PATH_PATCH_RESULT
    )
    if(NOT WWP_MACOS_PATH_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not apply the Worms World Party macOS app data-path patch.")
    endif()
endif()

include("${PSXRECOMP_ROOT}/runtime/runtime.cmake")

# This project's own mod catalog. The FRAMEWORK stages it after its builtin
# psx.* packages into <exe-dir>/mods/bundled. WWP overrides three upstream
# manifests here so advanced/legacy builtins are visible in the Mods page;
# plugin implementations remain framework-owned. Never copy catalog files by
# hand: framework catalog staging validates this declaration at build time.
set(PSX_PRELOADED_MODS "${CMAKE_CURRENT_SOURCE_DIR}/mods/preloaded")
if(NOT IS_DIRECTORY "${PSX_PRELOADED_MODS}")
    set(PSX_PRELOADED_MODS "NONE")
endif()

psxrecomp_add_game_runtime(psx-runtime
    PRELOADED_MODS_DIR "${PSX_PRELOADED_MODS}"
    ENABLE_NETPLAY_IF_PRESENT
    NETPLAY_LOBBY_URL "ws://netplay.retcomm.net:8765"
    ENABLE_SETUP_WIZARD
    WINDOW_TITLE "WormsWorldParty Recompiled"
    DEFAULT_GAME_CONFIG_PATH "game.toml"
    MAX_PLAYERS 4
    LAUNCHER_BOXART "${CMAKE_CURRENT_SOURCE_DIR}/launcher_assets/img/boxart.tga"
    APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/psxrecomp.ico"
    # Committed game C (psxrecomp_cli.py generate; git add generated). Release
    # CI configures with -DPSXRECOMP_REQUIRE_GAME_C=ON so a checkout without
    # it fails instead of building a setup host.
    GEN_MARKER "generated/SLUS_014.48_dispatch.c"
    GEN_FULL_GLOB "generated/SLUS_014.48_full_*.c"
    CODEGEN_SETUP_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/codegen_setup.c"
)

# Stage runtime configs next to the exe for direct build/ launches. Only copy
# files that exist — never fail POST_BUILD when game_options.toml is absent.
foreach(_PSX_RUNTIME_CONFIG game.toml game_options.toml)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_PSX_RUNTIME_CONFIG}")
        add_custom_command(TARGET psx-runtime POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${CMAKE_CURRENT_SOURCE_DIR}/${_PSX_RUNTIME_CONFIG}"
                "$<TARGET_FILE_DIR:psx-runtime>/${_PSX_RUNTIME_CONFIG}"
            COMMENT "Staging ${_PSX_RUNTIME_CONFIG}"
            VERBATIM)
    endif()
endforeach()

# Bundle the Nightly updater helper beside the runtime data. The release ZIP
# packager stages this directory into Windows installs and macOS app resources.
add_custom_command(TARGET psx-runtime POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:psx-runtime>/update"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/tools/in_app_updater.py"
        "$<TARGET_FILE_DIR:psx-runtime>/update/updater.py"
    COMMENT "Staging Worms World Party Nightly updater"
    VERBATIM
)
