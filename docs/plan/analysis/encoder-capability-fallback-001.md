# Sender encoder capability fallback

## Evidence

On 2026-10-18, one host connected to the same receiver successfully in
`lowLatency`, `fidelity`, and `duet`, then each failed before capture with
VideoToolbox status `-12908` from hardware encoder creation. The receiver
advertised HEVC decoding capability, but that fact does not establish that the
sender can create a hardware HEVC encoder.

RGB lossless and the three RGB demos do not create a VideoToolbox compression
session. They are not evidence for, and must not be modified by, this encoder
fallback.

## Required path

```text
requested lossy mode
  -> requested HEVC policy when receiver supports HEVC
  -> HEVC hardware encoder creation/configuration
       -> success: retain requested policy
       -> failure: H.264 High hardware encoder, 8-bit NV12, sRGB, lowLatency
            -> success: send a coherent lowLatency / hevc:false configuration
            -> failure: H.264 High software encoder, 8-bit NV12, sRGB, lowLatency
                 -> success: send a coherent lowLatency / hevc:false configuration
                 -> failure: report the final VideoToolbox error and end the session
```

This fallback is sender-local. It adds no handshake field, packet kind,
raw-RGB fallback, or unbounded retry loop. The final H.264 software encoder is
the platform VideoToolbox implementation, not a bundled codec dependency. A receiver without HEVC
already selects H.264 for `lowLatency`; `fidelity` and `duet` still require an
HEVC-capable receiver before their requested policy may start.

## Observability

Status and statistics must describe the effective codec and mode. A displayed
connected state is not media success: success requires configuration, more than
one video frame, and at least one receiver acknowledgment.

## Capture-start failure evidence

On 2026-10-18, after encoder fallback was added, the sender reached
`屏幕采集已启动 · 等待首帧` in both `lowLatency` and `duet`, but no frame was
accepted. The shared capture callback was reading the ScreenCaptureKit
`.status` attachment as `Int`. ScreenCaptureKit provides this attachment as an
`SCFrameStatus` value; the failed cast returned `nil`, so every screen sample
was silently discarded before pixel-format validation, encoding, pointer
forwarding, or the first-frame transition.

The callback now parses `SCFrameStatus` directly and accepts only `.complete`.
This is a shared capture gate, not an encoder-mode fallback: lossy HEVC/H.264,
RGB lossless, and Demo 1/2/3 keep their existing independent payload paths.
