# WiredDisplay

WiredDisplay turns one Mac into a wired extended display for another Mac over a direct
Thunderbolt 3 or newer cable. The app contains both roles:

- **Receiver**: normally run this on the iMac. It creates the virtual display and shows
  the incoming video.
- **Sender**: normally run this on the MacBook. It captures the extended desktop and
  sends it to the iMac.

Install the same app on both Macs. There is no separate receiver application and no
account, subscription, wireless transport, audio path, or plugin.

## Downloads

Choose the package that matches the Mac where it will run:

- [Apple silicon / arm64](https://github.com/Joesa1/WiredDisplay/releases/latest/download/WiredDisplay-arm64.zip)
- [Intel / x86_64](https://github.com/Joesa1/WiredDisplay/releases/latest/download/WiredDisplay-x86_64.zip)

The arm64 package is for M1/M2/M3/M4 Macs. The x86_64 package is for Intel Macs. If the
two Macs use different processor families, download one package for each Mac.

## Requirements

- Two Macs connected with a Thunderbolt 3 or newer data cable.
- **Thunderbolt Bridge** enabled on both Macs, with an IPv4 address assigned.
- macOS 14 or later on the sender, because ScreenCaptureKit is used for desktop capture.
- macOS 12.3 or later on the receiver.
- Screen Recording permission for WiredDisplay on the sender.

## Quick start

1. Connect the cable and wait for **Thunderbolt Bridge** to show an address in Network
   settings on both Macs.
2. Launch WiredDisplay on the iMac, click **Start receiver**, and note its cable address
   and six digit pairing code.
3. Launch WiredDisplay on the MacBook, enter the iMac address and pairing code, select
   **Native** or **4K cap**, then click **Send display**.
4. Grant Screen Recording permission when macOS requests it, then relaunch WiredDisplay
   if macOS asks.
5. The iMac opens the received display full screen. Arrange the display in **System
   Settings > Displays** on the MacBook.

The first connection can take a few seconds while macOS creates the virtual display.
Keep the cable connected while the session is active. Click **Disconnect** in either
window to stop the session.

## First launch on macOS

The release is ad hoc signed because it is distributed outside the Mac App Store. If
macOS blocks the first launch, Control click `WiredDisplay.app`, choose **Open**, and
confirm. The same action is available in **System Settings > Privacy & Security > Open
Anyway**.

## Design

The implementation is independent of Duet's closed protocol. It uses the same classes of
latency-sensitive techniques observed in the local Duet binary: a direct Thunderbolt
network path, VideoToolbox hardware codecs, no frame reordering, a bounded frame queue,
immediate presentation, and a coalesced cursor channel. The receiver uses the native
`AVSampleBufferDisplayLayer` path instead of passing decoded frames through SDL.

The virtual display declarations and license retained from TargetBridge are included in
`LICENSE-TargetBridge.txt`.

## Build from source

```sh
./build.sh
```

The script produces two signed packages:

- `dist/WiredDisplay-arm64.zip`
- `dist/WiredDisplay-x86_64.zip`

The local Command Line Tools do not ship an x86_64 Swift compatibility archive. The build
therefore disables autolinking for that optional compatibility library; the application
source still compiles for both architectures.

## Current limits

This release has been compile checked, signed, and launch checked locally. A real two Mac
Thunderbolt session is still required to measure latency and confirm behavior on each
specific iMac panel. Audio and wireless transport are intentionally out of scope.
