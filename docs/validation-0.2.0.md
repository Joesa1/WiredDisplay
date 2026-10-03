# 0.2.2 validation

## Real cable observation, 2026-10-03

Local Thunderbolt Bridge: bridge0, 10.10.10.2/24. Remote: 10.10.10.3:54321.
macOS sender: 27.2 (26B5091g). Local Network setting for the installed app was on.

Network.framework logged `path:satisfied`, interface `bridge0`, followed by
`Socket received CONNECTED event` and `state ready`. TCP setup took about 1 ms.
The remote closed after the Hello packet: 68 outbound bytes, no inbound payload.
The remote app version and current pairing code could not be independently verified.
Old receiver code rejects differing app versions without a protocol error response;
this is a possible explanation, not a confirmed diagnosis of that remote close.

Default NWPathMonitor enumerated only Wi-Fi, despite an active bridge0. The final
sender therefore binds its source endpoint directly rather than requiring bridge0
to appear in the default-route monitor's list. Wi-Fi and cellular are prohibited.

The observed transition from errno 65 to successful TCP is evidence of progress.
It does not uniquely prove the cause of every earlier failure; permissions, signing
identity, socket binding and receiver state differed across builds.

## Local checks

- TransportCheck: split headers/bodies, merged packets, oversized frame rejection,
  reconnect, and idempotent close passed.
- ReceiverCheck against the actual GUI app: wrong code, incompatible protocol,
  silent-client expiry, malformed packet, successful profile probe, probe without
  interrupting an active session, authenticated replacement, and reconnect passed.
- arm64 and x86_64 compilation and temporary-directory signature checks passed.
- Installed arm64 app UI launch and version display checked.

## Pending

Install 0.2.2 on the remote iMac, restart its receiver, and use its new pairing code.
Run Test Connection, then actual display streaming. Intel runtime, Bonjour discovery,
link-local IPs, cable hot-plug, and measured screen-to-screen latency remain unverified.
