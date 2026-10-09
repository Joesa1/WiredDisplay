---
id: duet-mode-001
scope: media / protocol / transmission-mode UI
status: implemented
depends-on: []
---

# Duet mode: color-managed low-latency HEVC

## Objective

Add an explicitly named `Duet mode` alongside all existing transmission modes. It must use a high-quality, color-managed hardware HEVC Main10 path with bounded freshness. The receiver presents the newest decoded frame available to it; when the sender budget is full, new captures are skipped rather than queued without bound. Preserve all current modes, panel geometry, pairing, TCP transport, captured system cursor and device-specific settings.

## Context

- `docs/plan/analysis/duet-mode-001.md`
- `docs/research/duet-local-transport-analysis.md`
- `docs/architecture/media.md`
- `docs/architecture/protocol.md`
- `docs/ui/README.md`

## Path

- `Sources/Wire.swift`
- `Sources/Video.swift`
- `Resources/mvp-ui-prototype.html`
- `Tests/TransportCheck.swift`
- `Tests/VideoModesCheck.swift`
- `Tests/LosslessDemoCheck.swift` when its mode-budget assertion needs extension
- `Info.plist`
- `docs/INDEX.md`
- `docs/architecture/media.md`
- `docs/architecture/protocol.md`
- `docs/ui/README.md`
- `docs/operations/build-release.md` when the version/build changes

## Contract

- Add `TransmissionMode.duet`; its UI label is `Duet 模式 · 10-bit HEVC 色彩优先`.
- Require remote HEVC capability and use HEVC Main10/10-bit x420. Reject unsupported hardware with a clear Chinese error; no 8-bit/raw fallback.
- Preserve sRGB or Display P3 metadata, BT.709 matrix and SDR transfer function from configuration through decoding.
- Use capture `queueDepth = 1`, at most two unacknowledged frames, realtime hardware encoding, no frame reordering, a bounded target data rate and no more than one second between keyframes.
- Present only the latest decoded image. Keep ScreenCaptureKit cursor capture; do not add a separate cursor channel, receiver-to-host event injection, UDP, mTLS, FEC, a new pairing format, or a new dependency.
- Bump `Wire.protocolVersion` to `6`; incompatible peers must reject in `hello`.
- Add a source-level English documentation comment at the actual implementation point. It must link to the repository research report and accurately state what was observed versus what remains unknown.
- Increment the app version/build according to the existing release convention, consistently across source, UI and package metadata.

## UI

```text
Transmission mode [Low latency SDR / Fidelity / Lossless RGB / Demo 1 /
                   Demo 2 / Demo 3 / Duet mode: 10-bit HEVC]
Resolution        [Native panel / 4K compatible]
Hint              Color-managed, high bitrate, bounded freshness;
                  not RGB byte-for-byte lossless.
```

## Verification

1. Run `TransportCheck`, `VideoModesCheck`, `LosslessDemoCheck` and the HTML syntax/bridge check.
2. Extend tests to prove the new mode validates only with HEVC, uses two-frame budget, and exercises the Main10 encode/decode/color-tag path.
3. Build arm64 and x86_64 packages, inspect their embedded app/version/resources, then record exact commands and outcomes.
4. Verify no existing mode behavior, panel catalog or device identity assets are altered.
5. Record physical dual-Mac tests as pending unless actually run; do not claim color or latency results from a local build.

## Delivery

Do not merge an unrelated PR, push a branch, create a GitHub release or delete existing packages in this task. Commit only the reviewed implementation and documentation after independent verification.

## Implementation record

Implemented 0.7.7 build 26 / protocol 6. Added `TransmissionMode.duet`, Main10 validation and pixel format selection, a two-frame bounded freshness budget, one-frame capture queue, realtime/no-reordering hardware encoder settings, 60-frame keyframe interval, bounded 18 bpp target bitrate (280 Mbps cap), UI persistence/hint, and the source-level research archive in `Sources/DuetMode.swift`. Existing raw RGB and Demo modes remain on their prior paths. Physical dual-Mac latency, color and reconnect behavior remain pending.
