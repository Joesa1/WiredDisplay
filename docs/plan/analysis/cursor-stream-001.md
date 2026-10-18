# Cursor stream completion

## Evidence

The receiver implements `VideoSurface.setPointer(_:)`, and `CablePeer` defines
the `cursor` packet. The sender does not create `PointerUpdate` values or send
cursor packets. Therefore a receiver cannot display an independent cursor even
though the status log claims that it is synchronized.

ScreenCaptureKit's captured cursor remains enabled and is not replaced. The
cursor stream provides a separate current pointer state for cases where the
captured image does not visibly contain one. It is orthogonal to HEVC, H.264,
RGB lossless, and all demo payload formats.

## Required path

```text
ScreenCaptureKit screen sample
  -> SCStreamFrameInfo cursor metadata
  -> PointerUpdate packet, bounded by current capture samples
  -> ReceiveSession validates packet
  -> VideoSurface.setPointer
  -> latest rendered image
```

No input injection, remote control, extra network transport, cursor image
encoding, or protocol version change is permitted.
