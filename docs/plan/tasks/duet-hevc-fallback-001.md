---
id: duet-hevc-fallback-001
scope: media / encoder startup
status: done
depends-on: []
---

# Duet Main10 to ordinary HEVC fallback

## Objective

When a `.duet` sender session cannot create or configure its Main10 hardware
encoder, retry once as ordinary hardware HEVC. The retry must produce a
coherent 8-bit `lowLatency` / sRGB media session. If that retry fails, expose
the actual VideoToolbox error and fail the connection.

## Context

- `docs/architecture/media.md`
- `docs/architecture/protocol.md`
- `docs/plan/analysis/duet-hevc-fallback-001.md`

## Path

- `Sources/Video.swift`
- `Tests/VideoModesCheck.swift`
- `docs/architecture/media.md`
- `docs/plan/analysis/duet-hevc-fallback-001.md`
- `docs/plan/tasks/duet-hevc-fallback-001.md`

## Contract

- Attempt the selected Duet Main10 path first.
- On its VideoToolbox create or configuration failure, retry ordinary hardware
  HEVC exactly once for this session.
- The fallback effective mode is `lowLatency`, with 8-bit NV12 and sRGB;
  `VideoConfiguration` must report that mode.
- Do not silently fall back to H.264, software encoding, raw RGB, or another
  connection/handshake path.
- If ordinary HEVC fails, preserve and report its true VideoToolbox status.

## Verification

1. Add a focused runnable check for the fallback decision: Duet Main10 failure
   selects 8-bit HEVC/sRGB/`lowLatency`; a normal failure has no fallback.
2. Run `Tests/VideoModesCheck.swift` using the documented compiler command.
3. Run `Tests/TransportCheck.swift` using the documented compiler command.
4. Run `./build.sh` when the local signing/build toolchain permits it; record a
   concrete failure if it does not.

## Implementation evidence

`ScreenSender` retries only a failed `.duet` Main10 encoder startup as 8-bit
HEVC `lowLatency` / sRGB, and disposes of a partially configured session before
the retry. `VideoModesCheck` verifies the fallback decision and its effective
configuration; verification results are recorded with the implementation
commit. Independent review and merge still control the `done` transition.

Verification on 2026-10-18:

- `xcrun swiftc -swift-version 5 -import-objc-header Sources/VirtualDisplay.h Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Sources/Video.swift Tests/VideoModesCheck.swift -o /private/tmp/thunder-duet-hevc-video-modes-check ... && /private/tmp/thunder-duet-hevc-video-modes-check`: PASS (existing macOS API deprecation warnings only).
- `xcrun swiftc -swift-version 5 Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Tests/TransportCheck.swift -o /private/tmp/thunder-duet-hevc-transport-check -framework Network -framework SystemConfiguration && /private/tmp/thunder-duet-hevc-transport-check`: PASS.
- `./build.sh`: PASS; arm64 and x86_64 packages, SHA-256 manifest, and ad-hoc signature verification produced.

Capture callback verification:

- Fixed `Sources/Video.swift` to parse the ScreenCaptureKit status attachment
  as `SCFrameStatus` rather than `Int`; the previous cast discarded every
  screen sample and left the session waiting for its first frame.
- `VideoModesCheck`: PASS after the capture-status fix (existing macOS API
  deprecation warnings only).

