import Foundation

/**
 Duet mode research archive and implementation contract.

 The full local bundle review is kept in `docs/research/duet-local-transport-analysis.md`.
 The inspected Duet bundle exposed VideoToolbox H.264/H.265 encoders and decoders,
 realtime encoding, disabled frame reordering, bitrate and keyframe controls,
 ScreenCaptureKit/IOSurface/Metal capture, color primaries/transfer-function/
 YCbCr-matrix properties, bounded queues, and dropped-frame telemetry. The bundle
 also contains classes and strings for UDP discovery/relay, TLS/mTLS handshakes,
 and Thunderbolt addresses, but static inspection cannot prove which private
 transport, packet format, chroma sampling, bit depth, or bitrate controller a
 live session selects. No Duet code, private protocol, or resource is copied here.

 This implementation therefore uses only the verified local Thunder Display
 contract: Thunderbolt Bridge TCP, hardware HEVC Main10, explicit sRGB or Display
 P3 metadata, realtime/no-reordering encoding, one capture surface, two frames in
 flight, and latest-frame presentation. It deliberately does not add UDP, mTLS,
 FEC, a new pairing format, raw RGB fallback, or a separate cursor channel.
 Duet is color-managed and lossy; it is not byte-for-byte RGB lossless.
 */
enum DuetModePolicy {
    static let frameBudget = 2
    static let captureQueueDepth = 1
    static let keyFrameInterval = 60
}
