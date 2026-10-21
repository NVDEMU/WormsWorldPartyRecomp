#!/usr/bin/env bash
# Thin wrapper around PSXRecomp's shared bundled-release packager.
# Ships the compiled game and runtime data; never a disc image or retail BIOS.
#
# Usage:
#   scripts/package_release.sh <build-dir> <artifact-tag> [recompiler-build-dir]
#
# Writes: dist/wwp-<version>-<artifact-tag>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-}"
ARTIFACT_TAG="${2:-}"
RECOMPILER_BUILD="${3:-build-recompiler}"

if [[ -z "${BUILD_DIR}" || -z "${ARTIFACT_TAG}" ]]; then
  echo "usage: $0 <build-dir> <artifact-tag> [recompiler-build-dir]" >&2
  exit 2
fi

PACKAGER="${ROOT}/psxrecomp/tools/package_game_release.sh"
if [[ ! -f "${PACKAGER}" ]]; then
  echo "error: missing ${PACKAGER}; update the psxrecomp submodule to a bundled-release version" >&2
  exit 1
fi
chmod +x "${PACKAGER}" 2>/dev/null || true

EXTRA=()
# Provenance lets the updater compare this installed build with the Nightly
# commit. It is generated in the build directory and never committed.
case "${BUILD_DIR}" in
  /*) BUILD_ROOT="${BUILD_DIR}" ;;
  *)  BUILD_ROOT="${ROOT}/${BUILD_DIR}" ;;
esac
COMMIT_ID="${GITHUB_SHA:-$(git -C "${ROOT}" rev-parse HEAD)}"
BUILD_VERSION="${RELEASE_VERSION:-local}"
printf '{\\n  "repository": "NVDEMU/WormsWorldPartyRecomp",\\n  "commit": "%s",\\n  "version": "%s",\\n  "platform": "%s"\\n}\\n' \
  "${COMMIT_ID}" "${BUILD_VERSION}" "${ARTIFACT_TAG}" > "${BUILD_ROOT}/BUILD_PROVENANCE.json"

# Bundle trusted CA roots next to updater.py because portable Python may not
# know the host OS's CA search path. HTTPS validation stays enabled on all OSes.
mkdir -p "${BUILD_ROOT}/update"
curl --fail --location --retry 3 --silent --show-error \
  --output "${BUILD_ROOT}/update/cacert.pem" \
  https://curl.se/ca/cacert.pem
if ! grep -q 'BEGIN CERTIFICATE' "${BUILD_ROOT}/update/cacert.pem"; then
  echo "error: updater CA bundle download is empty or invalid" >&2
  exit 1
fi
EXTRA+=(--runtime-file BUILD_PROVENANCE.json --runtime-dir update)
# CI does not have the player's game disc, so it cannot compile the optional
# runtime overlay cache. The committed static AOT shard is linked into the
# executable; overlay_toolchain/ handles remaining overlays at runtime.
if [[ -n "${PSX_OVERLAY_CACHE_ROOT:-}" ]]; then
  EXTRA+=(--overlay-cache-root "${PSX_OVERLAY_CACHE_ROOT}")
else
  EXTRA+=(--ship-without-overlay-cache-because \
    "CI has no game disc: the committed static AOT shard is linked and overlay_toolchain/ compiles other overlays from the player's own disc")
fi

for _doc in DISC.md; do
  if [[ -f "${ROOT}/${_doc}" ]]; then
    EXTRA+=(--doc "${_doc}")
  fi
done

cd "${ROOT}"
exec bash "${PACKAGER}" \
  --root "${ROOT}" \
  --build-dir "${BUILD_DIR}" \
  --artifact "${ARTIFACT_TAG}" \
  --zip-prefix wwp \
  --exe-name WormsWorldParty_Recompiled \
  --display-name "Worms World Party Recompiled" \
  --recompiler-build "${RECOMPILER_BUILD}" \
  --version-env RELEASE_VERSION \
  --disc-hint "Worms World Party (USA) PlayStation disc" \
  "${EXTRA[@]}"
