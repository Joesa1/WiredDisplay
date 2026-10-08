# Integrated candidate independent review

Reviewed commit: `1b39b5e` on `codex/all-features-test`.

Disposition: PASS for local test distribution. No blocking correctness findings remain from the two PR #4 issues recorded in `all-features-pr4-001.md`. This is not a real-hardware acceptance or a recommendation to publish a stable release.

## Correctness review

- Reset calls provider command invalidation as well as changing service credentials. Provider reset, stop and configure increment the generation. Queued player actions check that generation before entering the adapter and again after permission returns, immediately before AppleScript dispatch. Command UUID ownership prevents an old completion from clearing a newer pending-command guard. Already-dispatched operating-system actions remain non-retractable; the fix does not claim otherwise.
- Each HTTP request refreshes addresses through the address provider before exact Host/port validation. The change retains Origin, cross-site, JSON, bearer-token, pairing-attempt and command allowlist guards. It does not widen acceptance to arbitrary Host values.
- Native App.swift integration adds service ownership, the explicit Touch Bar bridge action and shutdown. It does not alter display capture or connection handling. Passive reads still request no new authorization; the player action path can request authorization only after an authenticated explicit command.
- The runtime UI retains all five transport options, the version-refresh native probe, historical-version treatment, and captured-cursor semantics. Video.swift, Cable.swift, the panel catalog and product assets have no changes in the integration commit. Build changes preserve the catalog and transparent product images while adding the phone HTML and required native frameworks. Wire protocol remains 4.

## Independent checks executed

- Compiled and ran TouchBarLifecycleTests: queued revocation and successful permission return after reset/stop/reconfiguration all prevented script dispatch. The injected controls do not operate a real player or prompt for permissions.
- Ran TouchBarHTTPTests.py against its real local listener with a non-operating provider: parsing bounds, authentication, pairing limits, commands, address replacement, revoked credentials and shutdown passed.
- Extracted both existing packages using ditto; verified exact arm64/x86_64 architecture, 0.7.2 build 21 metadata and codesign --verify --deep --strict. Both packaged runtime HTML files, the panel catalog and all 25 runtime transparent PNG assets matched source bytes. Historical source photography is intentionally not part of the runtime package.
- Package SHA-256 values match dist/SHA256SUMS.txt:
  - arm64: `5da3dcd36323bb9f3061ad09297405dbbb455089dded332539a4df799f0addcb`
  - x86_64: `70c640ab499740629949023dd1c77c00ca94bdcf73f90e6abc8753f8906e742d`

## Limits and follow-up

The developer reports passing transport, lossless-demo, video-mode, provider and browser-fixture checks; this independent pass focused on the changed lifecycle/security paths and package fidelity rather than repeating the entire build. No dual-Mac/iPhone Safari/Intel runtime, real player authorization, physical hardware controls or combined Touch Bar/display performance test was performed. The documented plaintext trusted-LAN limitation, polling metadata cost and mute-capability follow-up remain. Test the three original modes and two demos with Touch Bar enabled and disabled on real devices before claiming latency or compatibility improvements.
