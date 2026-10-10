---
id: duet-hevc-fallback-001
scope: media / encoder startup
status: in-progress
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

