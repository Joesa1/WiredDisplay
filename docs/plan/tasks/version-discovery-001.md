---
id: version-discovery-001
scope: Native bridge and device compatibility presentation
status: done
depends-on: []
---

# Live version discovery from saved-device state

## objective

Keep saved handshake metadata visible as history, but let the user perform a real probe or connection after either endpoint updates. A stale protocol record must not disable connection controls.

## context

- `docs/INDEX.md`
- `docs/ui/README.md` "版本发现与连接门槛"
- `docs/architecture/protocol.md`
- `docs/operations/validation.md`

## path

- `Sources/App.swift`
- `Resources/mvp-ui-prototype.html`
- `docs/ui/README.md`
- `docs/operations/validation.md`

## verification

1. Confirm every version-refresh and connection-button caller routes to native `test` or `session` with the saved address and pairing code.
2. Confirm a cached incompatible protocol no longer disables connection or blocks probe.
3. Confirm the receiver still rejects a live mismatched `hello.version`.
4. Run `git diff --check`, `plutil -lint Info.plist`, `TransportCheck`, and HTML bridge syntax extraction.
