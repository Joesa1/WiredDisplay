---
id: encoder-capability-fallback-001
scope: media / encoder startup
status: in-progress
depends-on: [duet-hevc-fallback-001]
---

# Sender lossy encoder capability fallback

## Objective

Make every lossy sender mode report a coherent, bounded result when the peer
can decode HEVC but this host cannot create a hardware HEVC encoder. Preserve
the requested HEVC policy when available.

## Contract

- `fidelity` and `duet` retry ordinary 8-bit HEVC once without the
  hardware-only VideoToolbox requirement. The effective configuration becomes
  `lowLatency`, sRGB, `hevc: true`, and three HEVC parameter sets.
- A protocol 6 Duet session may carry only that explicit `lowLatency` HEVC
  fallback. It must not be rejected merely because the requested mode was Duet.
- `lowLatency` may then retry H.264 High hardware and one non-hardware-only
  H.264 VideoToolbox attempt. Its configuration must report `hevc: false` with
  two parameter sets and its actual codec in statistics.
- If the bounded attempt sequence is exhausted, report its final true error;
  do not label H.264 as Duet.
- Lossless RGB and Demo 1/2/3 code paths are unchanged.
- No raw video fallback, bundled codec dependency or new UI control. The
  non-hardware VideoToolbox retry is bounded and local to encoder startup.

## Verification

1. Unit-check the fallback decision and resulting wire configuration for all
   three lossy modes.
2. Run the focused video-mode and transport checks.
3. Run a local sender/receiver capture check for all seven modes. Require a
   configuration, at least two video frames, and an acknowledgment; record a
   concrete platform limitation rather than treating a connected socket as pass.
4. Build and inspect arm64 and x86_64 archives after the checks pass.

Media acceptance is distinct from TCP/pairing acceptance. The UI must remain in
the starting state until the first receiver acknowledgment, then expose the
effective codec/mode. A connection or pairing message is not proof of a frame.

The currently rendered receiver is the sole source of a connection target.
The native bridge must receive that receiver's address and pairing code from
the connection control itself; it must not re-resolve a selected device through
another WebKit storage view or fall back to the first saved device.

## Files

- `Sources/Video.swift`
- `Tests/VideoModesCheck.swift`
- `docs/architecture/media.md`
- `docs/plan/analysis/encoder-capability-fallback-001.md`
- `docs/plan/tasks/encoder-capability-fallback-001.md`
