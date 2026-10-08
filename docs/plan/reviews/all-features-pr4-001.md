# PR #4 independent source review

Reviewed head: `d20853d7da40cd17d38ba6888855a2a6a264af5b` (`origin/codex/mobile-touch-bar`).

Disposition: changes requested before including the feature in the integrated candidate.

## Findings

### P2: Revocation does not invalidate queued player actions

Locations at reviewed head: `Sources/TouchBarService.swift:62`, `Sources/TouchBarProviders.swift:141-143`, `Sources/TouchBarMedia.swift:53-64`.

Reset changes the service generation and tokens, but a player command already queued behind a snapshot/application scan checks a different provider generation. Reset does not change that generation, so the queued action can still execute after the UI reports that all phone access is revoked. Returning HTTP 401 after execution does not prevent the effect. A related path exists when Stop or configuration change happens while `AEDeterminePermissionToAutomateTarget(..., true)` waits for user consent: validity is checked before entering that wait, but never after it, so subsequently accepting the permission dialog can execute an obsolete action.

Minimal fix: invalidate pending provider commands on reset, and pass a generation-based validity check through the media action path. Check it immediately after permission returns and before sending AppleScript. Preserve pending-command ownership so callbacks from old commands cannot clear a newer command's guard. Already-dispatched OS actions are not retractable; do not claim cancellation of those.

Required regression: queue a player command behind a deterministic worker barrier, revoke, release the barrier, and assert no action dispatch. Separately simulate a pending permission result, stop/reconfigure/revoke, return successful permission, and assert no AppleScript dispatch. Use injected closures or a narrowly factored pure lifecycle gate so tests do not request permissions or control a real player.

### P2: Host allowlist remains stale after a network address change

Locations at reviewed head: `Sources/TouchBarService.swift:26`, `Sources/TouchBarService.swift:58`, `Sources/TouchBarService.swift:88-89`.

The listener accepts connections on all interfaces, but permitted Host addresses are captured at enable and refreshed only when the user performs a native Touch Bar UI operation. If DHCP or a network switch changes the Mac address while service stays enabled, an otherwise valid request to the new address is rejected with HTTP 403 until the Mac UI is manually refreshed. A new phone opening the correct new IP therefore cannot pair despite the listener being alive.

Minimal fix: refresh actual local addresses before validating Host (or on network changes), preserving exact host/port matching and existing Origin and Sec-Fetch-Site checks. Do not accept arbitrary Host values as a workaround.

Required regression: simulate an address provider changing between requests, assert the new local Host becomes accepted and an unrelated attacker Host still receives 403. Existing token, origin, malformed HTTP and revocation checks must continue passing.

## Source assessment

- HTTP parser bounds headers to 8 KiB and bodies to 4 KiB; rejects duplicate headers, transfer encoding, expect, malformed length, unsupported methods and extra buffered payload. Listener caps concurrent clients and times them out. No reverse proxy or persistent-request parsing is used, reducing request-smuggling exposure.
- Exact local Host/port validation plus Origin checks, JSON-only POSTs, bearer authentication and no CORS support cover ordinary browser CSRF/DNS-rebinding paths. Transport is deliberately plaintext HTTP and the product explicitly says trusted LAN only; this is a documented limitation, not a claim of confidentiality.
- Six-digit pairing is generated with secure rejection sampling; tokens use secure random bytes. Pairing attempts and token count are bounded. Reset invalidates future authenticated requests correctly; the queued-action defect above is a distinct lifecycle gap.
- Passive music reads check automation authorization with `ask: false`; hardware polling uses `AXIsProcessTrusted()` without prompting. Explicit music commands can ask for automation permission. No shell command or arbitrary AppleScript endpoint is exposed.
- App launch resolves a scanned bundle identifier to its saved application URL. Weather and agent fetches use bounded responses, bounded timeouts, no redirects and no configured proxy. Provider generations prevent stale snapshot results after configuration changes.
- Native app owns the service, and `applicationWillTerminate` stops it. Listener start synchronously blocks main execution for at most five seconds; this may briefly interrupt UI responsiveness if startup is slow, but no additional blocker was established.
- Phone rendering uses textContent and validated image data URLs, with bounded polling/backoff, hidden-document pause and no automatic action retries. Full app metadata/icons are resent every poll and can create avoidable CPU/network work with large app collections; measure during combined streaming tests before adding caching infrastructure.
- Mute availability currently falls back to volume availability in the phone UI even though these CoreAudio properties may differ. This should be treated as a device compatibility follow-up: expose a separate mute capability instead of inferring it from volume if affected hardware is encountered.
- PR #4 introduces no changes to panel geometry, panel catalog, capture resolution, video encoding or display transport protocol. Integration still needs to preserve the separate branch changes in App.swift, runtime HTML and version metadata.

## Verification limits

This pass inspected the exact PR head using `git show`, including native ownership/bridge, HTTP server/service, media/hardware/providers, phone runtime, and existing test sources. It did not modify source, run real phone/player controls, trigger permission dialogs or claim physical-device testing. Existing HTTP tests use a non-operating provider harness and do not cover either lifecycle issue above; browser tests use routed fixtures and do not exercise the native receiver.
