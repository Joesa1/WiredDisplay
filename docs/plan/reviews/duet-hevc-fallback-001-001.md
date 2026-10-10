---
id: duet-hevc-fallback-001-001
task: duet-hevc-fallback-001
commit: 11529d531d69e2e18c8600b8e0cb4f186542e99d
status: blocked
---

# Duet HEVC fallback independent review

## Findings

### P1 blocking: fallback capture configuration keeps the original Duet queue policy

- Design: `docs/architecture/media.md`, "Duet 的 Main10 硬件编码器创建或配置失败时" and "Duet Main10 编码器创建/配置失败" require the effective mode to become `lowLatency`, including its 8-bit NV12 / sRGB capture session.
- Code: `Sources/Video.swift:434-438` correctly changes `self.mode` to `.lowLatency`, resets sRGB and the frame budget. But `Sources/Video.swift:456` reads the shadowing `start(... mode:)` parameter, not `self.mode`, when setting `SCStreamConfiguration.queueDepth`. A failed Duet start therefore retains `DuetModePolicy.captureQueueDepth` (1) rather than the ordinary low-latency capture depth (3).
- Effect: the resulting capture session is a mixed Duet/low-latency state. The frame budget, pixel format, color space and transmitted `VideoConfiguration` use the effective mode, but the capture queue still uses the failed Duet policy. This violates the required coherent ordinary HEVC `lowLatency` fallback.
- Required fix: build `SCStreamConfiguration` from `self.mode` (or a local effective-mode value) consistently, then add an assertion that a Duet fallback selects the ordinary low-latency queue policy as well as NV12/sRGB and the `VideoConfiguration` mode.

## Verified behavior

- `Sources/Video.swift:430-439` only enters the retry branch from `.duet`; a second ordinary-HEVC failure is thrown directly, so there is one retry and non-Duet failures are not swallowed.
- `Sources/Video.swift:475-511` keeps a failed temporary compression session local and invalidates it with `defer`; only a prepared session is assigned to `encoder`. Normal `stop()` still invalidates the assigned encoder.
- `Sources/Video.swift:457-458`, `521`, and `618-620` read the effective instance state, so the fallback otherwise requests NV12/sRGB, validates NV12 input, and sends an 8-bit HEVC/sRGB/`lowLatency` `VideoConfiguration`.

## Commands run

- `git diff 11529d5^ 11529d5 --check`: PASS.
- `xcrun swiftc -swift-version 5 -import-objc-header Sources/VirtualDisplay.h Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Sources/Video.swift Tests/VideoModesCheck.swift -o /private/tmp/thunder-duet-hevc-review-video-modes-check ... && /private/tmp/thunder-duet-hevc-review-video-modes-check`: PASS. Existing macOS deprecation warnings only.
- `xcrun swiftc -swift-version 5 Sources/Cable.swift Sources/DuetMode.swift Sources/Wire.swift Tests/TransportCheck.swift -o /private/tmp/thunder-duet-hevc-review-transport-check -framework Network -framework SystemConfiguration && /private/tmp/thunder-duet-hevc-review-transport-check`: PASS.

## Verdict

Blocked. The source has the intended single ordinary-HEVC retry and cleanup behavior, but the fallback does not fully materialize the required `lowLatency` capture configuration.
