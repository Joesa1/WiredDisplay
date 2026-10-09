# Duet Local Transport Analysis

Date: 2026-10-09

## Scope

This document is a read-only analysis of `/Applications/duet.app` version
`4.0.419`. It records observable bundle metadata, linked frameworks, imported
symbols, and embedded class/string names. It does not decrypt traffic,
decompile proprietary algorithms, modify the app, or claim behavior that was
not observable from those artifacts.

## Evidence Summary

| Area | Observed evidence | Confidence | Meaning |
| --- | --- | --- | --- |
| Thunderbolt discovery | `thunderbolt_addresses`, `thunderbolt_address=` | High | A device record can advertise dedicated Thunderbolt addresses. |
| Direct and fallback transport | `udpraw`, `udprelay`, `udprelaynotcp`, TCP socket classes, UDP discovery socket | High for supported paths; medium for selection rules | The product has more than a single TCP video path. The exact policy is private. |
| Session security | `Duet_RDPHandshakePKI`, `Duet_RDPHandshakeMTLS`, packet crypto classes | High | Pairing/session setup supports PKI and mTLS variants. |
| Video codecs | `Duet_VTH264Encoder`, `Duet_VTH265Encoder`, `Duet_VTDecoder`, FFmpeg encoder/decoder classes | High | H.264 and H.265 have native VideoToolbox paths; FFmpeg is also bundled. |
| Low-latency encoder controls | VideoToolbox imports for `RealTime`, `AllowFrameReordering`, bitrate, data rate, keyframe interval | High | The encoder can be configured as a real-time, bounded-rate stream without B-frame reordering. |
| Color metadata | VideoToolbox imports for color primaries, transfer function, YCbCr matrix | High | It propagates color metadata through the video encoder. Exact profiles and sample format are not observable. |
| Capture and presentation | ScreenCaptureKit, CGDisplayStream, IOSurface/CoreVideo, Metal | High | It supports both modern and legacy macOS capture and GPU-compatible frame surfaces. Zero-copy end-to-end cannot be proved from imports alone. |
| Input relay | Accessibility permission copy, `CGEventCreate*`, `CGEventPost`, input mouse-hook queue | High | It accepts remote input and injects mouse, keyboard, and scroll events on the host. |
| Frame control and telemetry | Frame queues, `Decode Presentation Dropped Frames`, encode/decode timing and bitrate statistics | High | It measures queue/decoder behavior and can choose freshness over presenting every old frame. Exact dropping policy is private. |
| Wireless performance helper | Privileged XPC tool runs `ifconfig awdl0 down/up` | High | This suppresses AWDL/AirDrop during an active session to improve wireless behavior. It is unrelated to Thunderbolt Bridge bandwidth. |

## Observed Architecture

```text
Discovery
  device record: Thunderbolt address + other addresses
        |
Session setup
  PKI or mTLS handshake
        |
Transport selection
  UDP direct / UDP relay / TCP fallback
        |
Capture
  ScreenCaptureKit or CGDisplayStream -> IOSurface / CVPixelBuffer
        |
Encode
  VideoToolbox H.264/H.265, realtime rate control, color metadata
        |
Decode and present
  VideoToolbox -> GPU-compatible surface -> Metal / desktop viewer

Input return path
  receiver mouse/keyboard -> protocol control packets -> CGEventPost on host
```

The diagram describes capabilities confirmed in the binary. The arrows are a
technical reconstruction, not a recovered implementation diagram.

## What the Bundle Actually Shows

### Transmission

The main executable contains `Duet_RDPConnection`, separate TCP and SSL-TCP
socket classes, a UDP discovery socket, and feature strings `udpraw`,
`udprelay`, `udprelaynotcp`, and `mtls`. It also contains `thunderbolt_addresses`
in its device JSON parser. This supports the conclusion that Thunderbolt is a
preferred local address class inside a broader multi-transport connection
system. It does not prove every Thunderbolt session uses UDP, nor reveal its
packet format.

The embedded UI has a connection-mode field labelled `UPD Direct`; this is a
UI resource/default and should not be used as a proof of a live session's
actual transport.

### Video and Color

Duet directly imports `VTCompressionSessionCreate`,
`VTCompressionSessionEncodeFrame`, `VTDecompressionSessionCreate`, and
`VTDecompressionSessionDecodeFrame`. It imports settings for:

- hardware-encoder availability;
- realtime encoding;
- frame reordering;
- average and maximum data rate;
- keyframe cadence;
- encoder profile;
- color primaries, transfer function, and YCbCr matrix.

It also contains `Duet_VTH264Encoder`, `Duet_VTH265Encoder`, and
`Duet_VTDecoder`, plus FFmpeg encoder/decoder classes. This is sufficient to
say that its practical high-quality route is compressed hardware video, not
uncompressed RGB frames sent over a generic socket.

The key distinction is color fidelity versus byte identity. A correctly
color-managed high-bitrate H.265 stream can look substantially closer to the
source than a poorly tagged 10-bit 4:2:0 stream, while using a fraction of the
raw RGB bandwidth. The bundle does not reveal whether Duet uses 4:2:0, 4:2:2,
4:4:4, 8-bit, or 10-bit for a particular Mac pair. Capability probing must
remain runtime-dependent.

### Input and Interaction

Duet requests Accessibility permission specifically to pass input from the
receiving device to the Mac. Its imports include mouse, keyboard, scroll,
event-tap, cursor-association and `CGEventPost` APIs. This is a complete
product requirement for an extended desktop: video presentation alone is not
an interactive display.

### Freshness Controls

The binary contains distinct frame queues and metrics such as encode timing,
decode timing, bitrate changes, and dropped presentation frames. That is the
right real-time principle: when the consumer falls behind, an old frame should
be discarded instead of being faithfully displayed late. Lossless full-frame
transport cannot obtain the same result merely by shrinking capture queues.

## Why This Avoids the Current RGB Bottleneck

For 8-bit BGRA, raw 4K60 is about 15.93 Gbit/s before TCP/IP framing, copies,
audio, control traffic, and display work. Raw 5K60 is about 28.31 Gbit/s. A
full-screen moving video invalidates any dirty-region strategy because almost
every frame changes across the display.

Duet's observable components instead allow it to reduce bytes before the
network using a hardware H.264/H.265 encoder, retain explicit color metadata,
limit encoder/network queues, discard stale video frames, and keep input as a
separate interactive capability. That is the relevant technical route. It is
not evidence that it offers byte-for-byte RGB losslessness at 4K/5K60.

## Recommended Thunder Display Direction

### Do not extend Demo 1/2/3

Demo 1 and Demo 3 help only when a small part of the desktop changes. Demo 2
removes the comparison pass but remains lossless full-frame compression. All
three regress to full-frame work for video. They are useful experiments, not a
general display transport architecture.

### Build one capability-negotiated hardware stream

1. Capture through ScreenCaptureKit into `CVPixelBuffer`/`IOSurface`.
2. Query the local encoder and remote decoder capabilities at connection time.
3. Prefer hardware HEVC with realtime operation, no frame reordering, bounded
   keyframe interval, bounded rate, and one bounded-freshness frame slot.
4. Carry the captured color primaries, transfer function, matrix, range, and
   sRGB/Display-P3 intent through the encoder, protocol, decoder, and Metal
   presentation path.
5. Prefer 4:4:4 only when both devices explicitly advertise hardware support;
   otherwise retain 10-bit/HDR-or-wide-gamut metadata where supported and use
   high bitrate. Never silently claim 4:4:4 on unsupported Macs.
6. Keep control/input packets on an independent high-priority path. Receiver
   input must inject on the host after explicit Accessibility authorization.
7. Make video freshness the invariant: when encoder, transport, decoder, or
   presenter lags, discard intermediate frames and keep the newest complete
   frame/keyframe path recoverable.

```text
Capture -> hardware encode -> latest video frame -> decode -> present
                 |                 |
                 |                 +-- discard stale frames
                 +-- color metadata preserved

Receiver input -> separate control path -> host event injection
```

### Product modes

| User-facing mode | Technical policy | Best use | Explicit cost |
| --- | --- | --- | --- |
| Color accurate | Hardware HEVC, color-managed, high bitrate, per-pair capability choice | Design, photo, normal desktop | Not byte-identical; 4:4:4 depends on hardware support. |
| Smooth | Hardware HEVC, lower bitrate/resolution ceiling, bounded-freshness policy | Video, scrolling, motion | More compression artifacts; a full sender budget can skip a newly captured frame. |
| RGB reference | Existing raw/lossless route, strict single-frame budget | Static inspection and screenshots | Full-screen motion is intentionally not a supported workflow. |

## What Must Be Measured Before Implementation

- encode, queue, send, receive, decode, present and input round-trip time;
- actual chroma format, bit depth, color metadata and range at both ends;
- dropped frame count and newest-frame age;
- 4K/5K static desktop, scrolling text, and full-screen video separately;
- each supported Intel and Apple-silicon capability class.

No implementation decision should be made from nominal Thunderbolt bandwidth
alone. The acceptance gate is a measured end-to-end frame age and correct
color test pattern on a real pair of Macs.

## Deliberate Limits

- The private packet layout, adaptive bitrate formula, FEC/retransmission
  behavior, codec profile selected per connection, and exact zero-copy chain
  are not recoverable from this inspection alone.
- The AWDL helper is a wireless optimization. It should not be copied into a
  Thunderbolt-only product.
- The code, protocol, and assets of Duet should not be copied. Only the
  observable architectural principles above are relevant.
