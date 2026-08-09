#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# build-codec2-xcframework.sh — build Codec2 as a *dynamic* XCFramework.
#
# WHY THIS SCRIPT EXISTS
#   Codec2 (https://github.com/drowe67/codec2) is LGPL-2.1. Design requirement
#   LP-4 permits us to ship it only as a *dynamically linked* framework, with
#   its licence text included — never statically linked into the app binary.
#   This script produces exactly that: Codec2.xcframework containing dynamic
#   Mach-O frameworks for three slices, each carrying codec2's COPYING file.
#
#   See docs/reference/CODEC2-XCFRAMEWORK.md for the OQ-2 spike result.
#
# SLICES PRODUCED
#   ios-arm64                     iOS device      (arm64,  min iOS 16.0)
#   ios-arm64_x86_64-simulator    iOS simulator   (arm64 + x86_64, min iOS 16.0)
#   macos-arm64_x86_64            macOS           (arm64 + x86_64, min macOS 13.0)
#
# USAGE
#   scripts/build-codec2-xcframework.sh [--clean] [--source-only] [-h|--help]
#
#     --clean        remove the build tree and any previous output first
#     --source-only  fetch and pin the codec2 checkout, then stop
#     -h, --help     print this usage and exit
#
# ENVIRONMENT (all optional; defaults in parentheses)
#   CODEC2_REPO      git URL to clone      (https://github.com/drowe67/codec2.git)
#   CODEC2_REF       tag/branch to check out                            (1.2.0)
#   CODEC2_COMMIT    expected commit SHA; the script aborts on mismatch.
#                    Set to "" to skip the pin check (not recommended).
#   CODEC2_SRC_DIR   existing codec2 checkout to use instead of cloning
#   WORK_DIR         scratch build tree      ($REPO_ROOT/.build/codec2-xcframework)
#   OUTPUT_DIR       where Codec2.xcframework is written          ($REPO_ROOT)
#   IOS_DEPLOYMENT_TARGET                                                (16.0)
#   MACOS_DEPLOYMENT_TARGET                                              (13.0)
#   FRAMEWORK_NAME                                                     (Codec2)
#   BUNDLE_ID        framework CFBundleIdentifier      (org.drowe67.codec2)
#   JOBS             parallel compile jobs                    (sysctl hw.ncpu)
#
# REQUIREMENTS
#   cmake (>= 3.13; `brew install cmake`), Xcode command line tools
#   (xcodebuild, xcrun, lipo, otool, install_name_tool, codesign), git.
#
# IDEMPOTENCE
#   Safe to re-run. The codec2 checkout is reused and re-pinned to CODEC2_REF;
#   per-slice CMake build trees are reused (incremental); the assembled
#   .framework bundles and the final .xcframework are deleted and rebuilt so
#   that stale slices can never survive into the output.
#
# NOTE ON CROSS-COMPILATION (the interesting part)
#   codec2 generates several .c files at build time with a host tool,
#   `generate_codebook`. When CMAKE_CROSSCOMPILING is true — which is what
#   setting CMAKE_SYSTEM_NAME=iOS does — codec2's own src/CMakeLists.txt spawns
#   a nested ExternalProject ("codec2_native") that builds generate_codebook for
#   the host and imports it. This works out of the box, so no host-build
#   plumbing is needed here; but the nested build is why the iOS configures
#   MUST set CMAKE_SYSTEM_NAME. Setting only CMAKE_OSX_SYSROOT would leave
#   CMAKE_CROSSCOMPILING false and codec2 would try to run an iOS-targeted
#   generate_codebook on the host, which cannot execute.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CODEC2_REPO="${CODEC2_REPO:-https://github.com/drowe67/codec2.git}"
CODEC2_REF="${CODEC2_REF:-1.2.0}"
# The commit 1.2.0 resolved to when this spike was run (2026-08-09). Tags can be
# moved; this pin makes that visible instead of silent.
CODEC2_COMMIT="${CODEC2_COMMIT-06d4c11e699b0351765f10398abb4f663a984f36}"
CODEC2_VERSION="1.2.0"

WORK_DIR="${WORK_DIR:-${REPO_ROOT}/.build/codec2-xcframework}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}}"
CODEC2_SRC_DIR="${CODEC2_SRC_DIR:-${WORK_DIR}/codec2-src}"

IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"

FRAMEWORK_NAME="${FRAMEWORK_NAME:-Codec2}"
BUNDLE_ID="${BUNDLE_ID:-org.drowe67.codec2}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

XCFRAMEWORK_PATH="${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"

# codec2's declared public headers (src/CMakeLists.txt CODEC2_PUBLIC_HEADERS),
# all of which live in <src>/src/ as flat files.
PUBLIC_HEADERS=(
    codec2.h
    codec2_fdmdv.h
    codec2_cohpsk.h
    codec2_fm.h
    codec2_ofdm.h
    fsk.h
    codec2_fifo.h
    comp.h
    modem_stats.h
    freedv_api.h
    reliable_text.h
    codec2_math.h
)

# Upstream packaging gap: fsk.h does `#include "kiss_fftr.h"`, and kiss_fftr.h
# does `#include "kiss_fft.h"`, but neither is in CODEC2_PUBLIC_HEADERS. Without
# them the framework's module map does not compile. Ship them alongside.
EXTRA_HEADERS=(
    kiss_fftr.h
    kiss_fft.h
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\033[1;32m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    # Print the comment block at the top of this file as the usage text:
    # everything from line 3 up to (but not including) the first `set -euo`.
    awk 'NR>=3 && /^set -euo/ {exit} NR>=3 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found in PATH. $2"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

DO_CLEAN=0
SOURCE_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)       DO_CLEAN=1 ;;
        --source-only) SOURCE_ONLY=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight"
require_tool git   "Install the Xcode command line tools."
require_tool cmake "Install it with: brew install cmake"
require_tool xcodebuild       "Install Xcode."
require_tool xcrun            "Install the Xcode command line tools."
require_tool lipo             "Install the Xcode command line tools."
require_tool otool            "Install the Xcode command line tools."
require_tool install_name_tool "Install the Xcode command line tools."
require_tool codesign         "Install the Xcode command line tools."

step "cmake     $(cmake --version | head -1 | awk '{print $3}')"
step "xcodebuild $(xcodebuild -version | head -1 | awk '{print $2}')"
step "iphoneos SDK        $(xcrun --show-sdk-version --sdk iphoneos)"
step "iphonesimulator SDK $(xcrun --show-sdk-version --sdk iphonesimulator)"
step "macosx SDK          $(xcrun --show-sdk-version --sdk macosx)"
step "targets: iOS ${IOS_DEPLOYMENT_TARGET}, macOS ${MACOS_DEPLOYMENT_TARGET}"

if [[ ${DO_CLEAN} -eq 1 ]]; then
    log "Cleaning"
    step "rm -rf ${WORK_DIR}/build ${WORK_DIR}/frameworks"
    rm -rf "${WORK_DIR}/build" "${WORK_DIR}/frameworks"
    step "rm -rf ${XCFRAMEWORK_PATH}"
    rm -rf "${XCFRAMEWORK_PATH}"
fi

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# 1. Fetch and pin the codec2 source
# ---------------------------------------------------------------------------

log "Source: codec2 @ ${CODEC2_REF}"

if [[ ! -d "${CODEC2_SRC_DIR}/.git" ]]; then
    step "cloning ${CODEC2_REPO} -> ${CODEC2_SRC_DIR}"
    git clone --quiet "${CODEC2_REPO}" "${CODEC2_SRC_DIR}"
else
    step "reusing existing checkout at ${CODEC2_SRC_DIR}"
fi

# Re-pin every run so a stale working tree cannot silently change what we ship.
git -C "${CODEC2_SRC_DIR}" fetch --quiet --tags origin
git -C "${CODEC2_SRC_DIR}" checkout --quiet --force "${CODEC2_REF}"
git -C "${CODEC2_SRC_DIR}" clean -qfdx -e build_ios -e build_iossim -e build_macos

RESOLVED_COMMIT="$(git -C "${CODEC2_SRC_DIR}" rev-parse HEAD)"
step "HEAD = ${RESOLVED_COMMIT}"

if [[ -n "${CODEC2_COMMIT}" && "${RESOLVED_COMMIT}" != "${CODEC2_COMMIT}" ]]; then
    die "codec2 ${CODEC2_REF} resolved to ${RESOLVED_COMMIT}, expected ${CODEC2_COMMIT}.
     The upstream tag moved, or CODEC2_REF was overridden. Review the change,
     then update CODEC2_COMMIT in this script (and the reference doc)."
fi

LICENCE_FILE="${CODEC2_SRC_DIR}/COPYING"
[[ -f "${LICENCE_FILE}" ]] || die "codec2 COPYING not found at ${LICENCE_FILE} — LP-4 requires shipping it."
step "licence: ${LICENCE_FILE} ($(wc -l < "${LICENCE_FILE}" | tr -d ' ') lines)"

if [[ ${SOURCE_ONLY} -eq 1 ]]; then
    log "--source-only: stopping after source fetch."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Build one dynamic libcodec2.dylib per slice
# ---------------------------------------------------------------------------
#
# build_slice <slice-id> <cmake-system-name|native> <sysroot> <archs> <deploy-target>
#
# Only the `codec2` library target is built. codec2's top-level CMakeLists also
# defines demo executables (c2enc, c2dec, freedv_rx, ...) that are irrelevant
# here and would drag in host-only assumptions on the iOS slices.
build_slice() {
    local slice="$1" system_name="$2" sysroot="$3" archs="$4" deploy="$5"
    local build_dir="${WORK_DIR}/build/${slice}"

    log "Building slice '${slice}' (${archs}, sysroot ${sysroot}, min ${deploy})"
    mkdir -p "${build_dir}"

    local -a cmake_args=(
        -G "Unix Makefiles"
        -S "${CODEC2_SRC_DIR}"
        -B "${build_dir}"
        -DCMAKE_BUILD_TYPE=Release
        # LP-4: dynamic, never static. This is the load-bearing flag.
        -DBUILD_SHARED_LIBS=ON
        -DUNITTEST=OFF
        -DLPCNET=OFF
        -DCMAKE_OSX_SYSROOT="${sysroot}"
        -DCMAKE_OSX_ARCHITECTURES="${archs}"
        # codec2's CMakeLists caches CMAKE_OSX_DEPLOYMENT_TARGET at "10.9"
        # before cmake_minimum_required, so it must be overridden explicitly.
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${deploy}"
        -DCMAKE_C_VISIBILITY_PRESET=default
        # Placeholder install name; corrected per-slice once the binary has
        # been renamed into the framework bundle (see install_framework_id).
        -DCMAKE_INSTALL_NAME_DIR="@rpath"
        -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON
    )

    # Setting CMAKE_SYSTEM_NAME is what flips CMAKE_CROSSCOMPILING on, which in
    # turn makes codec2 build its own host `generate_codebook`. See the note in
    # the header. macOS builds are native and must NOT set it.
    if [[ "${system_name}" != "native" ]]; then
        cmake_args+=(-DCMAKE_SYSTEM_NAME="${system_name}")
    fi

    step "cmake configure"
    cmake "${cmake_args[@]}" > "${build_dir}/configure.log" 2>&1 \
        || { warn "configure failed; last 40 lines:"; tail -40 "${build_dir}/configure.log" >&2; die "cmake configure failed for slice '${slice}'"; }

    step "cmake --build --target codec2 -j ${JOBS}"
    cmake --build "${build_dir}" --target codec2 -j "${JOBS}" > "${build_dir}/build.log" 2>&1 \
        || { warn "build failed; last 40 lines:"; tail -40 "${build_dir}/build.log" >&2; die "cmake build failed for slice '${slice}'"; }

    local dylib="${build_dir}/src/libcodec2.dylib"
    [[ -f "${dylib}" ]] || die "expected ${dylib} after building slice '${slice}'"

    # LP-4 assurance: prove it is a dylib, not a static archive.
    if ! file -b "${dylib}" | grep -q "dynamically linked shared library"; then
        die "slice '${slice}' did not produce a dynamic library:
     $(file -b "${dylib}")"
    fi
    step "verified dynamic: $(file -b "${dylib}" | head -1)"
    step "arches: $(lipo -archs "${dylib}")"
}

# ---------------------------------------------------------------------------
# 3. Assemble a .framework bundle around each dylib
# ---------------------------------------------------------------------------

# write_module_map <path>
# Explicit header list — codec2 has no umbrella header.
write_module_map() {
    local out="$1"
    {
        echo "framework module ${FRAMEWORK_NAME} {"
        local h
        for h in "${PUBLIC_HEADERS[@]}" "${EXTRA_HEADERS[@]}"; do
            echo "    header \"${h}\""
        done
        echo "    header \"codec2/version.h\""
        echo "    export *"
        echo "}"
    } > "${out}"
}

# copy_headers <build-dir> <dest-headers-dir>
copy_headers() {
    local build_dir="$1" dest="$2" h
    mkdir -p "${dest}" "${dest}/codec2"
    for h in "${PUBLIC_HEADERS[@]}" "${EXTRA_HEADERS[@]}"; do
        cp "${CODEC2_SRC_DIR}/src/${h}" "${dest}/${h}"
    done
    # version.h is generated into <build>/codec2/version.h. codec2.h includes it
    # as <codec2/version.h>, which assumes an installed -I.../include layout and
    # does NOT resolve through framework header lookup. Rewrite that one include
    # in the *copied* header to a quoted form, which clang resolves relative to
    # the including header's directory (Headers/codec2/version.h). Upstream
    # source is untouched; this is a packaging fix, recorded in
    # docs/reference/CODEC2-XCFRAMEWORK.md.
    cp "${build_dir}/codec2/version.h" "${dest}/codec2/version.h"
    /usr/bin/sed -i '' 's|#include <codec2/version\.h>|#include "codec2/version.h"|' "${dest}/codec2.h"
    if grep -q '#include <codec2/version\.h>' "${dest}"/*.h; then
        die "an angled <codec2/version.h> include survived in the framework headers"
    fi
}

# write_info_plist <path> <platform: iPhoneOS|iPhoneSimulator|MacOSX>
write_info_plist() {
    local out="$1" platform="$2"
    local min_key min_val
    case "${platform}" in
        MacOSX) min_key="LSMinimumSystemVersion"; min_val="${MACOS_DEPLOYMENT_TARGET}" ;;
        *)      min_key="MinimumOSVersion";       min_val="${IOS_DEPLOYMENT_TARGET}" ;;
    esac
    cat > "${out}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${CODEC2_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${CODEC2_VERSION}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${platform}</string>
	</array>
	<key>NSHumanReadableCopyright</key>
	<string>Codec2 is Copyright (C) David Rowe and contributors, licensed LGPL-2.1. See COPYING.</string>
	<key>${min_key}</key>
	<string>${min_val}</string>
</dict>
</plist>
PLIST
}

# assemble_framework <slice-id> <layout: flat|versioned> <platform>
#
# flat      — iOS/iOS-simulator layout: binary, Headers/, Modules/, Info.plist
#             all at the bundle root. Required on iOS; versioned bundles are
#             rejected there.
# versioned — macOS layout: Versions/A/... with Current + top-level symlinks.
#             Required for a macOS framework to codesign and notarise cleanly.
assemble_framework() {
    local slice="$1" layout="$2" platform="$3"
    local build_dir="${WORK_DIR}/build/${slice}"
    local fw="${WORK_DIR}/frameworks/${slice}/${FRAMEWORK_NAME}.framework"
    local dylib="${build_dir}/src/libcodec2.dylib"

    log "Assembling ${FRAMEWORK_NAME}.framework for slice '${slice}' (${layout})"
    rm -rf "${fw}"
    mkdir -p "${fw}"

    local root install_name
    if [[ "${layout}" == "versioned" ]]; then
        root="${fw}/Versions/A"
        mkdir -p "${root}/Resources"
        install_name="@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
    else
        root="${fw}"
        install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    fi

    # Follow the symlink: libcodec2.dylib -> libcodec2.1.2.dylib.
    cp -L "${dylib}" "${root}/${FRAMEWORK_NAME}"
    chmod u+w "${root}/${FRAMEWORK_NAME}"

    copy_headers "${build_dir}" "${root}/Headers"
    mkdir -p "${root}/Modules"
    write_module_map "${root}/Modules/module.modulemap"

    # LP-4: the LGPL-2.1 licence text ships inside the bundle.
    if [[ "${layout}" == "versioned" ]]; then
        write_info_plist "${root}/Resources/Info.plist" "${platform}"
        cp "${LICENCE_FILE}" "${root}/Resources/COPYING"
        ln -sfn A "${fw}/Versions/Current"
        ln -sfn "Versions/Current/${FRAMEWORK_NAME}" "${fw}/${FRAMEWORK_NAME}"
        ln -sfn Versions/Current/Headers   "${fw}/Headers"
        ln -sfn Versions/Current/Modules   "${fw}/Modules"
        ln -sfn Versions/Current/Resources "${fw}/Resources"
    else
        write_info_plist "${root}/Info.plist" "${platform}"
        cp "${LICENCE_FILE}" "${root}/COPYING"
    fi

    # Set the install name so the framework can be embedded under an app's
    # Frameworks/ directory and resolved via @rpath at load time.
    install_name_tool -id "${install_name}" "${root}/${FRAMEWORK_NAME}"
    # install_name_tool invalidates the linker's ad-hoc signature; restore one.
    # The app's build will re-sign with the real identity when embedding.
    codesign --force --sign - --timestamp=none "${fw}" >/dev/null 2>&1 \
        || warn "ad-hoc codesign of ${slice} framework failed (non-fatal; the app re-signs on embed)"

    step "install name: $(otool -D "${root}/${FRAMEWORK_NAME}" | tail -1)"
    step "mach header:  $(otool -hv "${root}/${FRAMEWORK_NAME}" | sed -n '4p' | awk '{print $2, $6}')"
    step "arches:       $(lipo -archs "${root}/${FRAMEWORK_NAME}")"
}

# ---------------------------------------------------------------------------
# Build all three slices
# ---------------------------------------------------------------------------

build_slice ios-device    iOS   iphoneos        "arm64"         "${IOS_DEPLOYMENT_TARGET}"
build_slice ios-simulator iOS   iphonesimulator "arm64;x86_64"  "${IOS_DEPLOYMENT_TARGET}"
build_slice macos         native macosx         "arm64;x86_64"  "${MACOS_DEPLOYMENT_TARGET}"

assemble_framework ios-device    flat      iPhoneOS
assemble_framework ios-simulator flat      iPhoneSimulator
assemble_framework macos         versioned MacOSX

# ---------------------------------------------------------------------------
# 4. Combine into the XCFramework
# ---------------------------------------------------------------------------

log "Creating ${XCFRAMEWORK_PATH}"
rm -rf "${XCFRAMEWORK_PATH}"
xcodebuild -create-xcframework \
    -framework "${WORK_DIR}/frameworks/ios-device/${FRAMEWORK_NAME}.framework" \
    -framework "${WORK_DIR}/frameworks/ios-simulator/${FRAMEWORK_NAME}.framework" \
    -framework "${WORK_DIR}/frameworks/macos/${FRAMEWORK_NAME}.framework" \
    -output "${XCFRAMEWORK_PATH}"

# LP-4: also place the licence at the top of the XCFramework, so the obligation
# travels with the artefact even before it is embedded in an app bundle.
cp "${LICENCE_FILE}" "${XCFRAMEWORK_PATH}/COPYING"
cat > "${XCFRAMEWORK_PATH}/LICENCE-NOTICE.txt" <<NOTICE
This XCFramework contains Codec2 ${CODEC2_VERSION}
  source:  ${CODEC2_REPO}
  ref:     ${CODEC2_REF}
  commit:  ${RESOLVED_COMMIT}

Codec2 is Copyright (C) David Rowe and contributors and is licensed under the
GNU Lesser General Public License version 2.1; the full text is in COPYING,
which is also present inside each slice's framework bundle.

Per design requirement LP-4, Codec2 is linked *dynamically* only. It must not
be statically linked into an application binary. The unmodified codec2 source
for this exact commit is obtainable from the URL above.
NOTICE

# ---------------------------------------------------------------------------
# 5. Verify the result
# ---------------------------------------------------------------------------

log "Verification"
for slice_dir in "${XCFRAMEWORK_PATH}"/*/; do
    [[ -d "${slice_dir}" ]] || continue
    slice="$(basename "${slice_dir}")"
    bin="${slice_dir}${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    [[ -f "${bin}" ]] || die "missing binary for slice ${slice}"
    step "${slice}"
    printf '       file:  %s\n' "$(file -b "${bin}" | head -1)"
    printf '       type:  %s\n' "$(otool -hv "${bin}" | sed -n '4p' | awk '{print $5}')"
    printf '       id:    %s\n' "$(otool -D "${bin}" | tail -1)"
    printf '       archs: %s\n' "$(lipo -archs "${bin}")"
    # LP-4 hard gate: refuse to hand back an archive masquerading as a framework.
    otool -hv "${bin}" | grep -q "DYLIB" || die "slice ${slice} is not a DYLIB — LP-4 violation"
    [[ -f "${slice_dir}${FRAMEWORK_NAME}.framework/COPYING" || \
       -f "${slice_dir}${FRAMEWORK_NAME}.framework/Versions/A/Resources/COPYING" ]] \
        || die "slice ${slice} is missing COPYING — LP-4 violation"
done

# Smoke test: the macOS slice is the only one that can run on the build host.
# Compiling, linking and *running* against it proves the framework is actually
# consumable — headers resolve, the module map is well formed, @rpath resolves,
# and codec2 3200 (the mode M17 stream mode needs, FR-2.4) initialises.
log "Smoke test (macOS slice)"
SMOKE_DIR="${WORK_DIR}/smoke"
rm -rf "${SMOKE_DIR}"; mkdir -p "${SMOKE_DIR}"
MACOS_SLICE="${XCFRAMEWORK_PATH}/macos-arm64_x86_64"

cat > "${SMOKE_DIR}/smoke.c" <<'SMOKE'
#include <Codec2/codec2.h>
#include <stdio.h>
int main(void) {
    struct CODEC2 *c = codec2_create(CODEC2_MODE_3200);
    if (!c) { fprintf(stderr, "codec2_create(3200) failed\n"); return 1; }
    int bits = codec2_bits_per_frame(c);
    int samples = codec2_samples_per_frame(c);
    codec2_destroy(c);
    printf("codec2 3200: bits_per_frame=%d samples_per_frame=%d\n", bits, samples);
    /* M17 stream mode carries 2 x 3200 frames = 2 x 64 bits = 16 bytes. */
    return (bits == 64 && samples == 160) ? 0 : 2;
}
SMOKE

HOST_ARCH="$(uname -m)"
step "clang -arch ${HOST_ARCH} -framework ${FRAMEWORK_NAME}"
clang -arch "${HOST_ARCH}" -mmacosx-version-min="${MACOS_DEPLOYMENT_TARGET}" \
    -F "${MACOS_SLICE}" -framework "${FRAMEWORK_NAME}" \
    -Wl,-rpath,"${MACOS_SLICE}" \
    "${SMOKE_DIR}/smoke.c" -o "${SMOKE_DIR}/smoke" \
    || die "smoke test failed to compile/link against ${FRAMEWORK_NAME}.framework"

step "modules check (-fmodules)"
clang -arch "${HOST_ARCH}" -mmacosx-version-min="${MACOS_DEPLOYMENT_TARGET}" \
    -fsyntax-only -fmodules -fmodules-cache-path="${SMOKE_DIR}/modcache" \
    -F "${MACOS_SLICE}" "${SMOKE_DIR}/smoke.c" \
    || die "framework module map does not compile — Swift/clang import would fail"

step "dynamic link confirmed: $(otool -L "${SMOKE_DIR}/smoke" | awk 'NR==2 {print $1}')"
step "run: $("${SMOKE_DIR}/smoke")"

log "Done: ${XCFRAMEWORK_PATH}"
step "codec2 ${CODEC2_VERSION} @ ${RESOLVED_COMMIT}"
step "embed it in the app target as 'Embed & Sign' (see docs/reference/CODEC2-XCFRAMEWORK.md)"
