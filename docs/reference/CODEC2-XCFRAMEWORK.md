# Codec2 XCFramework — M17-1 spike result (OQ-2)

**Task:** M17-1. **Gates:** OQ-2, and through it M17-4 (M17 stream mode).
**Spike run:** 2026-08-09, macOS 26.5.1 (arm64), Xcode 26.6, SDKs 26.5.
**Script:** [`scripts/build-codec2-xcframework.sh`](../../scripts/build-codec2-xcframework.sh)

---

## Verdict on OQ-2

**Yes — it works. All three slices build, link, and run as dynamic frameworks.**
M17-4 is unblocked on the codec side.

Codec2 builds cleanly as a dynamic (`MH_DYLIB`) Mach-O for iOS device, iOS
simulator, and macOS, assembles into a valid `Codec2.xcframework`, and satisfies
LP-4: nothing is statically linked, and the LGPL-2.1 `COPYING` text ships inside
every slice and at the XCFramework root.

The build needed **no patches to codec2 source**. Two packaging fixes were
needed on top of what upstream's CMake produces, both handled inside our script
(details in [Workarounds](#workarounds)).

The verification is empirical, not assumed. The script compiles, links and
*runs* a program against the macOS slice on every invocation, confirming that
`codec2_create(CODEC2_MODE_3200)` succeeds and reports
`bits_per_frame = 64`, `samples_per_frame = 160` — i.e. 8 bytes per 20 ms frame,
which is exactly the 2 × 64-bit = 16-byte payload an M17 stream packet carries.
FR-2.4 is satisfiable with this artefact.

Residual risk is low and is confined to the two device-only checks nobody can
perform on a build machine — see [Residual risk](#residual-risk).

---

## What was pinned

| | |
|---|---|
| Upstream | `https://github.com/drowe67/codec2.git` |
| Ref | tag `1.2.0` |
| Commit | `06d4c11e699b0351765f10398abb4f663a984f36` (2023-07-20) |
| Licence | LGPL-2.1 (`COPYING`, 502 lines) |

`1.2.0` is the only release tag in the repository; `main` was at
`310777b1c6f1af0bc7c72f5b32f80f6fd9136962` on the spike date, roughly two and a
half years ahead of the tag. The tag was chosen for reproducibility. The script
records the expected commit SHA and **aborts** if the tag ever resolves to
something else, so an upstream tag move becomes a loud failure rather than a
silent change to what we ship.

Build tooling: `cmake` 4.4.2 (installed via `brew install cmake`; it is not
present by default). The generator is `Unix Makefiles` — deliberately, so the
script has no dependency on `ninja`.

---

## Build steps

```sh
brew install cmake                       # not installed by default
scripts/build-codec2-xcframework.sh      # ~4 min from a cold clone
```

Everything is configurable by environment variable (`CODEC2_REF`, `WORK_DIR`,
`OUTPUT_DIR`, `IOS_DEPLOYMENT_TARGET`, …); run with `--help` for the full list.
By default the scratch tree lands in `.build/codec2-xcframework/` and the
product in `Codec2.xcframework/` at the repo root — both already covered by
`.gitignore` (`.build/` and `*.xcframework`). **The built framework is never
committed.**

The script is idempotent: the codec2 checkout is reused and re-pinned each run,
CMake build trees are incremental, and the assembled bundles plus the final
XCFramework are deleted and rebuilt so a stale slice cannot survive. `--clean`
discards the build trees entirely.

### What it does per slice

Only the `codec2` CMake target is built — not the demo executables (`c2enc`,
`c2dec`, `freedv_rx`, …), which are irrelevant here and carry host-only
assumptions.

| Slice | `CMAKE_SYSTEM_NAME` | `CMAKE_OSX_SYSROOT` | `CMAKE_OSX_ARCHITECTURES` | Deployment target |
|---|---|---|---|---|
| iOS device | `iOS` | `iphoneos` | `arm64` | 16.0 |
| iOS simulator | `iOS` | `iphonesimulator` | `arm64;x86_64` | 16.0 |
| macOS | *(unset — native)* | `macosx` | `arm64;x86_64` | 13.0 |

Deployment targets match `Package.swift` (`.iOS(.v16)`, `.macOS(.v13)`).
`-DBUILD_SHARED_LIBS=ON` is the load-bearing flag for LP-4; it happens to be
codec2's default, but the script sets it explicitly and then *verifies* the
result rather than trusting it.

### The cross-compilation problem, and why it was not a problem

This was flagged as the most likely failure mode, and it is worth recording that
it resolved itself.

codec2 generates several `.c` files at build time using a host tool,
`generate_codebook`. Its `src/CMakeLists.txt` already handles cross-compilation:
when `CMAKE_CROSSCOMPILING` is true it spawns a nested `ExternalProject` called
`codec2_native` that builds `generate_codebook` for the host and imports it via
`IMPORTED_LOCATION`. **No host-build plumbing was needed in our script.** The
nested native build ran automatically for both iOS slices and produced a working
host-arm64 `generate_codebook`.

The one thing that *must* be right: setting `CMAKE_OSX_SYSROOT=iphoneos` alone
does **not** make `CMAKE_CROSSCOMPILING` true. `CMAKE_SYSTEM_NAME=iOS` is what
flips it. Without that, codec2 would build `generate_codebook` for iOS and then
try to execute it on the host, which cannot work. The script sets
`CMAKE_SYSTEM_NAME` for the iOS slices and deliberately omits it for macOS,
where the build is native and the tool is built for free.

---

## Workarounds

Neither of these touches upstream source. Both are applied to the *copied*
headers as the framework is assembled, and both are asserted in the script so a
regression fails the build.

### 1. `codec2.h` includes `<codec2/version.h>` with angle brackets

`version.h` is generated into `<build>/codec2/version.h`, and `codec2.h`
includes it as `#include <codec2/version.h>`. That assumes an installed
`-I…/include` layout and does **not** resolve through framework header lookup —
`#include <Codec2/codec2.h>` fails to compile out of the box:

```
error: 'codec2/version.h' file not found with <angled> include; use "quotes" instead
```

Fix: the script copies `version.h` to `Headers/codec2/version.h` and rewrites
that single include in the copied `Headers/codec2.h` to the quoted form
`#include "codec2/version.h"`, which clang resolves relative to the including
header's own directory. It then greps the assembled headers to confirm no
angled form survived.

### 2. `fsk.h` needs headers upstream does not export

`CODEC2_PUBLIC_HEADERS` omits `kiss_fftr.h` and `kiss_fft.h`, but the exported
`fsk.h` does `#include "kiss_fftr.h"`, which in turn includes `kiss_fft.h`.
Without them the framework's module map does not compile. The script ships both
alongside the declared public headers. This is an upstream packaging gap, not
something we caused; it costs us two extra headers and nothing else.

### 3. `CMAKE_OSX_DEPLOYMENT_TARGET` must be set explicitly

codec2's top-level `CMakeLists.txt` caches `CMAKE_OSX_DEPLOYMENT_TARGET` at
`"10.9"` *before* `cmake_minimum_required`, with a comment explaining that the
placement is deliberate. Passing `-DCMAKE_OSX_DEPLOYMENT_TARGET` on the command
line overrides it correctly, but omitting it would silently produce a 10.9
target. The script always passes it.

---

## Resulting framework layout

```
Codec2.xcframework/                       7.6 MB total
├── Info.plist                            XFWK, format 1.0, 3 libraries
├── COPYING                               LGPL-2.1 (LP-4)
├── LICENCE-NOTICE.txt                    source URL + commit + LP-4 note
├── ios-arm64/                            1.5 MB
│   └── Codec2.framework/                 flat (iOS) layout
│       ├── Codec2                        MH_DYLIB, arm64, platform IOS, minos 16.0
│       ├── Headers/                       12 public + 2 kiss + codec2/version.h
│       ├── Modules/module.modulemap
│       ├── Info.plist                    FMWK, MinimumOSVersion 16.0
│       ├── COPYING
│       └── _CodeSignature/
├── ios-arm64_x86_64-simulator/           3.0 MB
│   └── Codec2.framework/                 flat layout, platform IOSSIMULATOR
└── macos-arm64_x86_64/                   3.0 MB
    └── Codec2.framework/                 versioned (macOS) layout
        ├── Versions/A/{Codec2,Headers,Modules,Resources}
        ├── Versions/Current -> A
        └── Codec2, Headers, Modules, Resources -> Versions/Current/…
```

iOS slices use the flat bundle layout (versioned bundles are rejected on iOS);
macOS uses the versioned layout, which it needs to codesign and notarise
cleanly. Install names:

| Slice | `LC_ID_DYLIB` |
|---|---|
| iOS device, iOS simulator | `@rpath/Codec2.framework/Codec2` |
| macOS | `@rpath/Codec2.framework/Versions/A/Codec2` |

The module map lists headers explicitly — codec2 has no umbrella header:

```
framework module Codec2 {
    header "codec2.h"
    …
    header "codec2/version.h"
    export *
}
```

Each framework is ad-hoc signed (`codesign --force --sign -`) because
`install_name_tool` invalidates the linker's signature. `codesign --verify`
reports *valid on disk* and *satisfies its Designated Requirement* for all
slices. The app's own build re-signs with the real identity on embed.

### Verification performed

Every run of the script asserts, and fails on:

- `file` reports *dynamically linked shared library* for each slice's output
- `otool -hv` reports filetype `DYLIB` for each slice in the finished XCFramework
- `COPYING` is present in every slice bundle (LP-4 hard gate)
- `otool -D` shows the expected `@rpath` install name
- `lipo -archs` shows the expected architectures
- a C program compiles, links and **runs** against the macOS slice
- the module map compiles under `-fmodules` (proves Swift/clang import works)

Confirmed platform metadata via `otool -l`: iOS device `platform 2, minos 16.0`;
simulator `platform 7, minos 16.0`; both against SDK 26.5.

---

## How the app target embeds and signs it

**Update (M17-4, 2026-08-11): no C shim target was needed.** The plan
anticipated one, but the module map the script generates imports straight into
Swift — `import Codec2`, call `codec2_create` and friends directly — so
`M17Kit/Codec2VoiceCodec.swift` binds to the framework with no intervening C
target. The `-fmodules` check the script already performs is exactly the thing
that predicted this would work.

How the SwiftPM side is wired, and why it is conditional: the XCFramework is
never committed, but CI checks out a bare tree and runs `swift build && swift
test`, and a `binaryTarget` naming a path that does not exist is a hard
manifest error. So `Package.swift` probes for `Codec2.xcframework` and adds the
binary target, the `M17Kit` dependency and a `CODEC2` compilation condition
only when it is present. M17-4's stream sequencing is written against
`RadioCore.VoiceCodec` so the framing, frame numbering and payload split are
tested either way; only `Codec2VoiceCodec` and its tests are conditional.

⚠️ SwiftPM caches the evaluated manifest against its *contents*, not against
the filesystem this probe reads, so **run `swift package reset` after building
or deleting the framework** — otherwise the next build can fail with `local
binary target 'Codec2' … does not contain a binary artifact`. A fresh checkout
has no cache and is unaffected.

The app target that ships it must still:

1. Add `Codec2.xcframework` under **Frameworks, Libraries, and Embedded
   Content** with **Embed & Sign**. Not *Do Not Embed* — that would break the
   dynamic-linking requirement, and not embedding leaves nothing to load at
   runtime.
2. Leave `Runpath Search Paths` (`LD_RUNPATH_SEARCH_PATHS`) at the Xcode
   defaults: `@executable_path/Frameworks` for macOS and
   `@executable_path/Frameworks` / `@loader_path/Frameworks` for iOS. The
   `@rpath` install names resolve from these; no custom rpath is needed.
3. Not enable `Link Frameworks Automatically` bitcode-era workarounds or add
   `-force_load`/`-all_load` for this framework — anything that pulls codec2
   objects into the app binary would violate LP-4.
4. Ship the licence. `COPYING` travels inside the framework bundle
   automatically, which satisfies the distribution obligation, but the app
   should also surface an acknowledgements screen naming Codec2, its LGPL-2.1
   licence, and the upstream URL and commit (both recorded in
   `LICENCE-NOTICE.txt`).

**LGPL-2.1 relinking.** Dynamic linking plus published source location and
version is what LP-4 relies on. `LICENCE-NOTICE.txt` inside the XCFramework
records the exact upstream URL, ref, and commit, and this build script is
itself in the repository, so a recipient can rebuild a replacement
`Codec2.framework` and drop it in. Note that on iOS, App Store code signing
means a user cannot substitute the framework in a distributed app; this is the
well-known LGPL-on-iOS tension. It is a licensing judgement for the maintainer,
not a technical blocker, and it is unchanged by anything in this spike — but it
should be a conscious decision before shipping to the App Store, and it is the
one item here that is worth a second look. Distributing the corresponding
source and the build script is the mitigation available to us.

---

## Residual risk

Low overall. In rough order of importance:

1. **No on-device load test.** The iOS slices were built and statically
   verified, but nothing has loaded `Codec2.framework` on a real iPhone or in
   the simulator, because there is no app target yet (Phase 4, blocked on OQ-3
   and OQ-4). The macOS slice *was* linked and run, which exercises the same
   code paths, so the risk is that of embedding and signing rather than of the
   library itself. First real test comes with M17-4 or APP-1.
2. **App Store validation is unproven.** Related to the above: no archive has
   been submitted, so `MinimumOSVersion`, bundle identifier and the embedded
   licence file have not been through App Store validation. Nothing in the
   layout is unusual, but it is untested.
3. **Size.** ~1.5 MB per architecture, ~4.5 MB of Mach-O across the three
   slices. That is the *entire* codec2 library — the FreeDV modems, OFDM,
   LDPC code tables, FSK — when M17 needs only the 3200 bps vocoder. Because
   the library is dynamic, the linker cannot dead-strip the unused parts. If
   app size becomes a concern, the fix is to build a reduced source list rather
   than to link statically, which LP-4 forbids. Not a blocker; noted so it is
   not a surprise later.
4. **Pinned to a 2023 release.** `1.2.0` is roughly two and a half years behind
   `main`. That is the right call for a reproducible spike, but the version
   should be revisited before shipping — upstream may have fixes worth taking,
   and the commit-pin assertion in the script makes the upgrade a deliberate,
   reviewable act.
5. **cmake is an extra build dependency.** Not present by default on a clean
   Mac and not vendored. Any CI job that builds the framework needs
   `brew install cmake`. Note that unit tests do not need the framework at all,
   so ordinary CI is unaffected.
6. **Upstream packaging gaps could shift.** The two header workarounds are
   pinned to `1.2.0`'s specific layout. The script asserts on both, so a future
   version bump that changes them fails loudly rather than producing a
   framework that will not import.

---

## Recommendation

Confirm OQ-2 as **resolved: yes**. M17-4 may proceed on the codec dependency.
Before App Store submission, revisit item 4 (version) and the LGPL relinking
note above.
