---
id: cursor-stream-001
scope: media / cursor display
status: in-progress
depends-on: []
---

# Send and present the captured cursor

## Objective

Complete the existing `cursor` protocol path so the receiver presents the
current ScreenCaptureKit cursor in every transmission mode.

## Contract

- Emit validated pointer updates from screen-capture metadata.
- The receiver's existing cursor rendering remains presentation-only; it must
  not inject host input.
- Preserve `showsCursor = true` and the existing video cursor behaviour.
- Codec selection, raw RGB payloads and Demo 1/2/3 compression are unchanged.
- Do not claim cursor synchronization before the receiver has acknowledged a
  rendered media frame.

## Verification

1. Add a focused wire/validation check for a cursor packet and invalid data.
2. Run existing transport and video-mode checks.
3. On real hardware, move the cursor after first-frame acknowledgement and
   confirm both cursor and moving video update on the receiver.
