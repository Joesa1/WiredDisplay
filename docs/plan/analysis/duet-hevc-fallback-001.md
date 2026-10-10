# Duet Main10 encoder fallback

## Scope

`ScreenSender` owns the sender-side VideoToolbox compression session. The
request concerns only its startup path after pairing and display-profile
exchange have succeeded. TCP setup, pairing, virtual-display creation and
receiver listening are out of scope.

## Integration path

```text
AppDelegate
  -> ScreenSender.start(profile, mode: .duet)
  -> ScreenSender.createEncoder(profile)
  -> VideoToolbox Main10 session/configuration
       -> failure: retry ordinary HEVC once
       -> failure: surface original error
  -> ScreenCaptureKit capture format
  -> VideoConfiguration
  -> HardwareDecoder
```

The fallback must change the effective mode before capture configuration and
before the first `VideoConfiguration` packet. Keeping `.duet` on the wire
would make the receiver require 10-bit output for an 8-bit HEVC stream.

## Delivery boundary

One task changes the shared `ScreenSender` startup path and its focused
source-level verification. No new capability negotiation, transport behavior,
user setting, dependency, or UI control is needed.

