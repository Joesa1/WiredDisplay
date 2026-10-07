---
task: version-discovery-001
review: 001
status: passed
reviewed-commits:
  - 631a4db64afe67fd7c3346385cdd10d1693f7e0d
  - 0e7f27de22b2357ce4fe221d9d5dee1513386527
---

# Version Discovery Review

## Outcome

Passed. No blocking findings.

## Scope Checks

- A saved incompatible protocol is now history-only UI. It no longer disables `toolbar-connect` or blocks `connectSelected`.
- Native bridge `version-refresh` reads the selected device's saved address and pairing code, then posts `test`; `test` populates the native fields and starts the existing no-media probe path.
- A successful probe receives `DisplayProfile`, then refreshes the device identity and installed version through `prototypeUpsertDevice`. Protocol 3 is correctly recorded as the consequence of a successful protocol-3 handshake.
- Receiver-side `hello.version == Wire.protocolVersion` validation remains before pairing, profile response, or media promotion. A live protocol-2 receiver therefore rejects the protocol-3 hello instead of relying on the cached record.
- Neither reviewed commit changes `PanelCatalog`, its bundled JSON, `panelProfile()`, or device asset mappings. The built-in-panel-only condition remains intact.

## Local Verification

- `git diff --check 250cc27..HEAD`: passed.
- `plutil -lint Info.plist`: passed.
- `TransportCheck`: passed, including fragmented/coalesced packets, 4.5K raw framing, oversize rejection, reconnect, and idempotent close.
- `VideoModesCheck`: passed, including panel geometry, external-display catalog exclusion, padded RGB, P3 tags, raw-frame bounds, and local HEVC Main10 encode/decode.
- Extracted `mvp-ui-prototype.html` and native bridge JavaScript both pass `node --check`.

## Remaining Hardware Gate

The source change cannot prove the two-Mac upgrade case locally. Follow the version-cache validation sequence in `docs/operations/validation.md`: retain a protocol-2 history record, upgrade the receiver to protocol 3, run rediscovery, then verify it refreshes; repeat against a real protocol-2 receiver and confirm receiver-side rejection.
