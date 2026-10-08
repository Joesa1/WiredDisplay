---
id: lossless-demo3-001
scope: media / protocol / workbench
status: done
depends-on: []
---

# Demo 3: system dirty-rect lossless RGB

## Objective

Implement Demo 3 on the `0.7.2` integrated candidate baseline. It uses `ScreenCaptureKit` dirty rectangles, native LZ4 and exact BGRA8 reconstruction; it keeps at most one frame in flight and one capture surface queued. Preserve the existing color-space attachment path and captured system cursor.

## Context

- `docs/INDEX.md`
- `docs/architecture/media.md`
- `docs/architecture/protocol.md`
- `docs/architecture/transport.md`
- `docs/plan/analysis/lossless-demo3-001.md`

## Path

- `Sources/Wire.swift`
- `Sources/Video.swift`
- `Sources/App.swift` only if native mode presentation requires it
- `Resources/mvp-ui-prototype.html`
- `Tests/LosslessDemoCheck.swift`
- `Tests/VideoModesCheck.swift`
- `Info.plist`
- `docs/architecture/media.md`
- `docs/architecture/protocol.md`
- `docs/operations/build-release.md`
- `README.md`

## Contract

- Add `demo3`; the UI name is `Demo 3 · 系统变化区域`.
- Reuse `LosslessDemoFrame`; it may accept an explicit system-derived rectangle so the sender never scans BGRA pixels in Demo 3.
- Convert an array of valid pixel `CGRect` values to one clamped union. A missing, empty or invalid attachment sends a full keyframe.
- Preserve exact BGRA bytes and existing `StreamColorSpace` tags. Do not add an independent cursor channel or a lossy fallback.
- Demo 3 must use one frame budget slot and `SCStreamConfiguration.queueDepth = 1`. Existing modes keep their current budgets and queue depth.
- Raise `Wire.protocolVersion` to 5 and app version/build to `0.7.3 (22)`. Do not silently interoperate with protocol 4.

## Verification

- Extend runnable checks for a system-supplied rectangle, missing/empty rectangle full-frame fallback, exact reconstruction, invalid rectangle rejection and Demo 3 one-frame budget.
- Run `TransportCheck`, `LosslessDemoCheck`, `VideoModesCheck`, HTML syntax check, arm64 build, x86_64 build, package/signature/version validation.
- Record physical dual-Mac comparison as pending; do not claim a latency win from local checks.

## Implementation evidence

Implemented `0.7.3` build `22` / protocol `5`. Demo 3 reads `SCStreamFrameInfoDirtyRects`, uses the clamped union in the existing LZ4 BGRA packet, and falls back to a full keyframe for missing, empty or invalid metadata. It keeps one frame in flight and uses capture `queueDepth = 1`. `LosslessDemoCheck`, `VideoModesCheck`, `TransportCheck`, HTML script syntax, plist validation, arm64/x86_64 package metadata, extracted architecture and strict signature verification passed locally. Physical ScreenCaptureKit capture, dual-Mac behavior and Intel runtime remain pending.
