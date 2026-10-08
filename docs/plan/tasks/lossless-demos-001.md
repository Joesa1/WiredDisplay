---
id: lossless-demos-001
status: in-progress
---

# Lossless comparison modes

## Approved behavior

Add two experimental transmission modes alongside the existing three modes. Keep the cursor captured in video in every mode. Preserve panel-native geometry, BGRA8 pixels and color-space tagging. No independent pointer channel or lossy fallback.

- Demo 1: bounded transmission pipelining, native LZ4 lossless compression, and changed-region updates.
- Demo 2: the same bounded pipelining and LZ4 strategy, with full-frame updates only.
- Retain the original lossless mode as the comparison baseline.
- Start with at most two frames in flight for the demos, versus one for the baseline. Do not accumulate unbounded old frames. This is an experiment, not a promise of lower latency.
- Use system Compression APIs; send raw bytes when compression does not reduce payload size. Preserve exact pixels on reconstruction.
- Demo 1 must preserve all changes across skipped capture frames. Comparing against the last transmitted image is an acceptable simple implementation; do not rely on unaccumulated per-capture dirty rectangles. First frame and reset use a full frame. Use a full frame when the changed bounding rectangle covers the screen; otherwise compress that rectangle only. Compare compression against the same raw rectangle, avoiding a second full-frame compression pass. This is not a globally minimum-payload selection.
- Validate dimensions, lengths, decompression limits, frame ancestry and region bounds before allocation/copy. Reject corrupt deltas rather than displaying stale pixels.
- Keep protocol compatibility explicit; experimental modes must not be sent to receivers lacking support. Update version/build and relevant protocol documentation consistently.

## UI

```text
Transmission mode [Low latency SDR / Fidelity / Lossless RGB /
                   Demo 1: lossless regions / Demo 2: lossless full frames]
Resolution        [Native panel / 4K compatible]
```

Both demos use identical buffering and compression so region updates are the comparison variable. Report the active demo in existing codec statistics. Document that bandwidth, frame rate and latency are measured, not guaranteed.

## Verification

Independent review plus arm64/x86_64 builds. Runnable checks must exercise real codecs and reconstruct identical pixels for initial frames, small edits, skipped captures, cursor-shaped changes, unchanged frames, full-screen changes and padded rows. Include malformed/truncated payloads, incorrect ancestry and decompression-size rejection. Existing panel geometry and transport checks must pass. Record dual-Mac validation as pending for the user.

## Delivery

Create a new PR targeting the current three-mode branch, with a dependency note for PR #3. Provide local arm64 and x86_64 packages for comparison. Do not merge or publish a release.

## Implementation evidence

Implemented 0.7.1 build 20 / protocol 4. LosslessDemoCheck, VideoModesCheck, TransportCheck, HTML syntax, and both architecture build/signature/package-version checks passed locally on 2026-10-08. Independent review is pending. Dual-Mac demo comparisons remain pending for the user. Both demos preserve captured system cursor, panel sizing and BGRA/P3 handling; no source catalog/assets changed.
