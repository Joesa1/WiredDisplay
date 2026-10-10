---
id: duet-hevc-fallback-001-001
task: duet-hevc-fallback-001
commit: da42d52fca340a84aa27d2aeb4fb7bdb133549b8
status: passed
---

# Duet HEVC fallback independent review

## Initial findings

### P1 blocking: fallback capture configuration keeps the original Duet queue policy

- Design: `docs/architecture/media.md`, "Duet 的 Main10 硬件编码器创建或配置失败时" and "Duet Main10 编码器创建/配置失败" require the effective mode to become `lowLatency`, including its 8-bit NV12 / sRGB capture session.
- Code: `Sources/Video.swift:434-438` correctly changes `self.mode` to `.lowLatency`, resets sRGB and the frame budget. But `Sources/Video.swift:456` reads the shadowing `start(... mode:)` parameter, not `self.mode`, when setting `SCStreamConfiguration.queueDepth`. A failed Duet start therefore retains `DuetModePolicy.captureQueueDepth` (1) rather than the ordinary low-latency capture depth (3).
- Effect: the resulting capture session is a mixed Duet/low-latency state. The frame budget, pixel format, color space and transmitted `VideoConfiguration` use the effective mode, but the capture queue still uses the failed Duet policy. This violates the required coherent ordinary HEVC `lowLatency` fallback.
- Required fix: build `SCStreamConfiguration` from `self.mode` (or a local effective-mode value) consistently, then add an assertion that a Duet fallback selects the ordinary low-latency queue policy as well as NV12/sRGB and the `VideoConfiguration` mode.

## Re-review

The blocking finding is resolved by `da42d52`.

- Code: `Sources/Video.swift:55-57` centralizes the existing capture-depth policy, and `Sources/Video.swift:460` now derives `SCStreamConfiguration.queueDepth` from `self.mode`. After Main10 configuration failure, `Sources/Video.swift:437-442` changes that effective mode to `.lowLatency`; the resulting capture configuration now uses depth 3, 8-bit NV12 and sRGB.
- Test: `Tests/VideoModesCheck.swift:37-45` asserts the Duet fallback mode, 8-bit NV12 `VideoConfiguration`, sRGB, low-latency depth 3, preserved Duet depth 1, and no fallback for ordinary modes.
- No new blocking issue was found. The retry remains limited to a failed `.duet` encoder startup. An ordinary HEVC failure propagates its own VideoToolbox status; H.264, software, RGB and handshake fallbacks are absent. The temporary unsuccessful compression session is invalidated before the retry, while the prepared retry session remains owned by normal `stop()` cleanup.

## Verified behavior from initial review

- `Sources/Video.swift:430-439` only enters the retry branch from `.duet`; a second ordinary-HEVC failure is thrown directly, so there is one retry and non-Duet failures are not swallowed.
- `Sources/Video.swift:475-511` keeps a failed temporary compression session local and invalidates it with `defer`; only a prepared session is assigned to `encoder`. Normal `stop()` still invalidates the assigned encoder.
- `Sources/Video.swift:457-458`, `521`, and `618-620` read the effective instance state, so the fallback otherwise requests NV12/sRGB, validates NV12 input, and sends an 8-bit HEVC/sRGB/`lowLatency` `VideoConfiguration`.

## Commands run

- `git diff 11529d5^ 11529d5 --check`: PASS.
- `xcrun swiftc -swift-version 5 -import-objc-header Sources/VirtualDisplay.h Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Sources/Video.swift Tests/VideoModesCheck.swift -o /private/tmp/thunder-duet-hevc-review-video-modes-check ... && /private/tmp/thunder-duet-hevc-review-video-modes-check`: PASS. Existing macOS deprecation warnings only.
- `xcrun swiftc -swift-version 5 Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Tests/TransportCheck.swift -o /private/tmp/thunder-duet-hevc-review-transport-check -framework Network -framework SystemConfiguration && /private/tmp/thunder-duet-hevc-review-transport-check`: PASS.
- `git diff da42d52^ da42d52 --check` and `git diff --check 11529d5 da42d52`: PASS.
- `xcrun swiftc -swift-version 5 -import-objc-header Sources/VirtualDisplay.h Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Sources/Video.swift Tests/VideoModesCheck.swift -o /private/tmp/thunder-duet-hevc-rereview-video-modes-check ... && /private/tmp/thunder-duet-hevc-rereview-video-modes-check`: PASS. Existing macOS deprecation warnings only.
- `xcrun swiftc -swift-version 5 Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Tests/TransportCheck.swift -o /private/tmp/thunder-duet-hevc-rereview-transport-check -framework Network -framework SystemConfiguration && /private/tmp/thunder-duet-hevc-rereview-transport-check`: PASS.
- `./build.sh`: PASS; generated arm64 and x86_64 archives and `SHA256SUMS.txt`. The arm64 archive was independently extracted and `codesign --verify --deep --strict` passed.

## Verdict

Pass. The original capture-depth defect is corrected and the effective fallback session is coherent 8-bit NV12 / sRGB / `lowLatency` HEVC.
