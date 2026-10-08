# Independent review: lossless-demo3-001

- Reviewed commit: `73559a5add3592362b3fe6fb53d90129681ac9ba`
- Review date: 2026-10-08
- Verdict: **BLOCKED**

## Findings

### P1 blocking: skipped captures invalidate the Demo 3 delta baseline

`ScreenSender.stream(_:didOutputSampleBuffer:of:)` reserves its one-frame budget before reading and transmitting the frame. When the receiver has not acknowledged that frame, subsequent ScreenCaptureKit samples return at `Sources/Video.swift:504`; they are intentionally skipped. The next sample accepted after an ACK then uses only that sample's `SCStreamFrameInfoDirtyRects` at `Sources/Video.swift:507-510`, while `sendRaw` applies the rectangle against `previousRaw` at `Sources/Video.swift:529-540`.

`SCStreamFrameInfoDirtyRects` describes the difference from the immediately preceding captured surface, not the last surface this sender transmitted. Therefore a change that occurred in any skipped sample and remains unchanged in the next accepted sample is omitted from the delta. The receiver applies the new delta to an older baseline and renders stale or corrupted pixels. `queueDepth = 1` limits capture buffering but does not prove that no completed samples will be skipped while waiting for the network/display ACK.

The existing Demo 1 avoids this because it compares the current packed BGRA frame with the last transmitted packed frame. Demo 3 deliberately removes that scan, so it must set a `needsKeyframe` flag whenever a Demo 3 sample is skipped and transmit the next accepted sample as a full keyframe. Alternatively it needs a conservatively accumulated damage history that remains valid across every skipped sample. Do not merge or package Demo 3 before one of those mechanisms and a regression test exist.

### P2 non-blocking: protocol compatibility is implemented but not covered by the required transport test

`Wire.protocolVersion` is correctly raised to `5`, Bonjour publishes it, and receiver authentication rejects a different `Hello.version`. The project protocol checklist nevertheless requires a `TransportCheck` codec/error-boundary addition for any protocol change. `Tests/TransportCheck.swift` uses `Wire.protocolVersion` for both sides and never asserts rejection of protocol `4`, nor does it cover the Demo 3 configuration value. Add a direct old-version rejection and a protocol-5 `demo3` configuration case.

### P3 non-blocking: whitespace check fails

`git diff --check 73559a5^ 73559a5` reports a blank trailing line at EOF in `docs/plan/analysis/lossless-demo3-001.md:37`.

## Verified behavior

- The macOS SDK defines `SCStreamFrameInfoDirtyRects` as an array of `NSValue` wrapped pixel `CGRect` values. The cast and pixel-coordinate assumption at `Sources/Video.swift:507-508` are valid.
- `systemDirtyUnion` rejects missing, empty, non-finite, zero-area and wholly out-of-bounds rectangles, and clamps valid partly out-of-bounds rectangles before unioning. Those cases fall back to a full keyframe.
- Demo 3 uses the existing exact BGRA payload and the same `StreamColorSpace` tags as RGB lossless modes. `HardwareDecoder` attaches `Display P3` or sRGB metadata after reconstruction. Existing low-latency and fidelity pixel-format/VideoToolbox paths are unchanged.
- `demo3` has one `FrameBudget` slot and `SCStreamConfiguration.queueDepth = 1`; Demo 1 and Demo 2 retain two budget slots and other modes retain their prior capture queue depth.
- `VideoConfiguration` transports `demo3`, the UI includes it, and protocol 4 peers are rejected at hello rather than silently decoding an unknown mode.

## Commands run

- `xcrun swiftc ... Sources/Wire.swift Tests/LosslessDemoCheck.swift ... && /private/tmp/thunder-lossless-demo3-check`: PASS.
- `xcrun swiftc ... Sources/Cable.swift Sources/Wire.swift Sources/Video.swift Tests/VideoModesCheck.swift ... && /private/tmp/thunder-demo3-video-modes-check`: PASS, including padded BGRA, RGB reconstruction, P3 metadata and local Main10 encode/decode. Existing macOS deprecation warnings remain outside this commit.
- `xcrun swiftc ... Sources/Cable.swift Sources/Wire.swift Tests/TransportCheck.swift ... && /private/tmp/thunder-demo3-transport-check`: PASS.
- Inline prototype JavaScript parsed through `new Function`; all six mode values are present.
- `plutil -lint Info.plist`: PASS.
- `build.sh`: built arm64 and x86_64 archives. Extracted archives contain the declared `0.7.3 (22)` and the expected architecture; `codesign --verify --deep --strict` passed for both extracted apps.

## Remaining gate

After the P1 correction, run an actual `ScreenCaptureKit` capture with altered content while deliberately withholding an ACK for at least one capture interval, then verify the following delta reconstructs exactly. Physical dual-Mac latency and fidelity remain acceptance work, not proof supplied by local checks.

## Second review: `1e2af588972c30f2b53994f5e4b3ea707ea0e2c7`

- Review date: 2026-10-08
- Verdict: **PASS for the Demo 3 test PR.** The first-round P1 is resolved. Physical dual-Mac validation remains required before presenting a latency result.

### P1 resolution: keyframe state now preserves delta ancestry

When the one-frame `FrameBudget` rejects a sample, `Sources/Video.swift:507-510` increments the existing skip counter and sets `demo3NeedsKeyframe`. On the next successful reservation, `Sources/Video.swift:514-516` passes `nil` rather than a dirty-rect attachment. `LosslessDemoFrame.encode(_:previous:width:height:systemDirtyRects:)` interprets that as a complete keyframe with base sequence `0`; it cannot apply a successor dirty rectangle to a stale `previousRaw` baseline.

The flag is cleared only after `sendRaw` returns at `Sources/Video.swift:517-521`; an encoding failure leaves it set while the failure callback tears the session down. Sender `start` resets both `previousRaw` and the flag before accepting capture, and `stop` resets both after capture stops. These transitions remove stale ancestry across retry and session teardown.

`LosslessDemoCheck` now reconstructs an update containing changes outside an imagined successor dirty rectangle by encoding it with no dirty metadata. It asserts base `0` and exact output, covering the fallback required after a skipped capture. A real `ScreenSender`/ScreenCaptureKit withheld-ACK capture still requires screen-recording permission and dual-Mac execution.

### P2 non-blocking: protocol test coverage now meets the source-level contract

`Wire.validateProtocol` is used by the receiver hello path. `TransportCheck` now rejects protocol `4`, accepts protocol `5`, validates a `demo3` RGB configuration and round-trips it through JSON. This is source-level coverage of the explicit rejection policy; it is not a replacement for a real old-app peer handshake.

### Second-round commands run

- `LosslessDemoCheck`: PASS.
- `TransportCheck`: PASS, including protocol-4 rejection and Demo 3 configuration round trip.
- `VideoModesCheck`: PASS, including padded BGRA reconstruction, P3 attachment preservation and local Main10 hardware encode/decode. Existing macOS deprecation warnings are unrelated to this commit.
- Prototype inline JavaScript parse and six transmission-mode values: PASS.
- `git diff --check 1e2af58^ 1e2af58` and `plutil -lint Info.plist`: PASS.
