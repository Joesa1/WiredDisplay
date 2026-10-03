# WiredDisplay

A lightweight Mac-to-Mac extended display over a Thunderbolt 3 or newer cable.
One app contains both roles. The **MacBook sender** creates and captures a virtual
extended desktop. The **iMac receiver** decodes and displays the incoming video.
There is no account, subscription, audio transport, or Duet protocol compatibility.

## Downloads: 0.2.0 preview

Install **0.2.0 on both Macs**. Older receivers can close the connection silently
when the sender reports a different application version.

- [Apple silicon / arm64](https://github.com/Joesa1/WiredDisplay/releases/download/v0.2.0/WiredDisplay-arm64.zip)
- [Intel / x86_64](https://github.com/Joesa1/WiredDisplay/releases/download/v0.2.0/WiredDisplay-x86_64.zip)
- [Release and checksums](https://github.com/Joesa1/WiredDisplay/releases/tag/v0.2.0)

M-series Macs use arm64. Intel Macs use x86_64. Sender and receiver use the same app;
choose the package for the processor of the Mac where it will run.
Quit the old app, extract the ZIP, and replace the app in `/Applications`.
Launch that copy, not an older copy in Downloads. Confirm the version in the window.

## Requirements and setup

- Sender: macOS 14 or later. Receiver: macOS 12.3 or later.
- A Thunderbolt data cable, not a charging-only USB-C cable.
- Thunderbolt Bridge enabled on both Macs.
- Local Network permission for WiredDisplay on recent macOS versions.
- Screen Recording permission on the sender, required only for actual streaming.

For the fixed-address setup, configure Thunderbolt Bridge as follows:

| Setting | MacBook sender | iMac receiver |
| --- | --- | --- |
| IPv4 | Manual | Manual |
| IP address | `10.10.10.2` | `10.10.10.3` |
| Subnet mask | `255.255.255.0` | `255.255.255.0` |
| Router / DNS | Empty | Empty |

Avoid an address range already used by another network or VPN. Automatic
`169.254.x.x` addresses remain supported, but that path has not been validated in
the 0.2.0 preview. A fixed IP does not itself reduce video latency.

## First connection

1. On the iMac, click **将这台 Mac 用作显示器**. Wait for **监听中 · TCP 54321**.
2. On the MacBook, enter the receiver address and its current six-digit pairing code.
   Bonjour fills an empty address field if exactly one compatible receiver is found;
   manual entry remains available if discovery is blocked.
3. Click **测试连接** first. It checks TCP, the pairing code, and screen parameters.
   It does not request Screen Recording, create a display, or replace a running session.
4. After the test succeeds, select quality and click **扩展到这台 Mac**.
5. Allow Screen Recording when requested and reconnect. If macOS asks for a relaunch,
   quit and reopen the app.
6. Arrange the virtual display in the MacBook's **System Settings > Displays**.

The receiver stays listening after invalid clients, failed pairing, and disconnects.
A new client replaces the active session only after valid pairing. **断开** stops
both the session and listening. The visible app version identifies the installed
build; protocol version determines compatibility in 0.2.0 and later.

## Connection diagnostics

The window reports TCP path selection, TCP readiness, pairing, and screen-profile
receipt separately. **拷贝诊断** copies the attempt history without the pairing code.
**本地网络设置** opens the relevant macOS privacy settings page.

| Result | Meaning / next step |
| --- | --- |
| No Thunderbolt address | Check the physical cable and Thunderbolt Bridge configuration. |
| `localNetworkDenied` | macOS denied this app local-network access; inspect its permission. |
| TCP waiting / timeout | Inspect the recorded interface and path reason, receiver listener, and network filters. |
| TCP ready, then EOF before profile | Transport worked; check receiver version and pairing. Older versions do not send a rejection reason. |
| Pairing or protocol rejection | Correct the code or update the incompatible app. |
| Test succeeds, capture fails | Investigate Screen Recording, virtual display, or hardware codec support. |

An enabled app, Screen Recording permission, and a disabled firewall do not prove
that macOS permits outgoing local-network access. Likewise, a successful terminal
probe does not prove that the app has the same effective permissions.

The preview is ad hoc signed. macOS local-network identity tracking may be less
reliable across ad hoc rebuilds than with an Apple-issued signing identity. No
Apple-issued signing identity is available on the build machine. Do not disable
system-wide privacy or firewall protections as a workaround.

If Gatekeeper blocks first launch, use Finder's **Open** or the app-specific
**Open Anyway** action in Privacy & Security. The app is not notarized.

## Transport design

- Native Network.framework `NWConnection` and `NWListener`.
- Sender uses the Thunderbolt local endpoint, prohibits Wi-Fi/cellular, and verifies
  the actual local endpoint after connection. Link-local IPv4 hosts are interface-scoped.
- Wildcard receiver listener; accepted connections must use the current Thunderbolt
  local address before processing the application protocol.
- Bonjour `_wireddisplay._tcp` advertises address, interface, app and protocol version.
- TCP_NODELAY, interactive-video service class, bounded frame budget, hardware
  VideoToolbox encoding/decoding, and immediate native video presentation.
- Five-second deadline and eight-candidate limit for unauthenticated clients.
- Protocol-aware probes never become display sessions. Bad clients do not stop listening.

This is an independent implementation. We have not established Duet's proprietary
transport or matched its latency. TargetBridge's virtual-display declarations and
MIT notice are retained in `LICENSE-TargetBridge.txt`.

## Validation status

0.2.0 is a preview, not a confirmed end-to-end fix:

- Both architectures compile and packaged app signatures verify.
- Native arm64 transport check passes fragmented/coalesced frames, oversized packet
  rejection, disconnect/reconnect, and exactly-once close notification.
- Running app receiver checks pass wrong-code and protocol rejection, idle-client
  timeout, malformed input, probes during an active session, authenticated replacement,
  and listener survival after disconnect.
- On the connected Macs, Network.framework established TCP to `10.10.10.3:54321`
  using `bridge0` in approximately 1 ms. The old receiver then closed after Hello
  without returning a profile. This measures connection setup, **not display latency**.
- Both-Mac 0.2.0 streaming, Intel runtime, Bonjour discovery between two machines,
  automatic link-local addressing, and end-to-end latency still need validation.

See [validation notes](docs/validation-0.2.0.md).

## Build and checks

```sh
./build.sh
xcrun swiftc -swift-version 5 Sources/Cable.swift Sources/Wire.swift \
  Tests/TransportCheck.swift -o /private/tmp/wireddisplay-transport-check \
  -framework Network -framework SystemConfiguration
/private/tmp/wireddisplay-transport-check
# Start a local app receiver first; replace the address and current pairing code:
python3 Tests/ReceiverCheck.py 10.10.10.2 CURRENT_PAIRING_CODE
```

Packages and SHA-256 checksums are written to `dist/`. Signing happens in a temporary
directory outside Desktop/iCloud so File Provider metadata cannot break signing.
Set `WIRED_SIGN_IDENTITY` to an installed Apple-issued code-signing identity for a
signed development build; default is ad hoc. The bundle/signing identifier is the
same for both CPU architectures.
