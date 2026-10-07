# Touch Bar local control panel

Status: approved implementation scope, 2026-10-07. User approved the mobile visual design and requested implementation and a PR; no additional design approval is required.

## Ownership and lifecycle

AppDelegate owns TouchBarService independently of display streaming. Service is disabled by default. Explicitly enabling starts a local HTTP listener; stop/quit closes it and invalidates credentials. Native preferences persist widget configuration, never invented state. Only trusted local networks are supported by this HTTP release; pairing authenticates but does not encrypt traffic. No cloud relay, arbitrary shell commands, file access routes, or automatic agent configuration installation.

The approved prototype is docs/ui/mobile-touch-bar.html. Runtime mobile page is Resources/touch-bar.html and must retain its black landscape layout. Desktop entry goes immediately after configuration checks under Tools. Actual data replaces all demo cards; absent/unsupported/denied/stale states must be visible.

```text
Tools                         Touch Bar
  Configuration checks       [Enable LAN access] [Refresh]
  Touch Bar                   LAN address [Copy] [Open] [QR]
                              Pairing code [Reset access]
                              Music [enabled] [Music / Spotify]
                              Agents [enabled] [local bridge port]
                              Weather [enabled] [city] [latitude / longitude]
                              Apps [enabled] [refresh installed apps]
                              Controls [enabled] [permission guidance]

Mobile browser -> HTTP pair / state / command -> TouchBarService -> TouchBarProviders
AppDelegate <-> native WK bridge <-> desktop settings (configuration only on Mac)
TouchBarProviders -> NSWorkspace / AppleScript / CoreAudio / brightness capability
                  -> Agent Status bridge on loopback only / Open-Meteo HTTPS
```

## API contract

HTTP serves only bundled mobile page at / and /touch-bar.html. No general directory serving. Read-only health may be public. POST /api/pair accepts JSON {code:string}, applies bounded attempts and returns {token:string}. All /api/state and /api/command requests require Authorization: Bearer <random token>. Pair code uses secure randomness, is displayed only in native desktop UI, and is never embedded in public HTML. Revocation invalidates every existing token. QR encodes only the LAN page URL. Pair tokens may persist in browser localStorage for reconnect but stop/restart requires new pairing.

Validate Host against selected local listener address (and loopback for preview), reject untrusted Origin; do not enable wildcard CORS. Body/request sizes, concurrency, pending command count and timeouts must be bounded. GET cannot execute commands. Mobile receives snapshot via serialized polling every 1 second, backs off on failure, pauses when hidden, and re-fetches on visibility. No overlapping state requests. One-second polling is an explicit first-version simplification, not a claim of event streaming. Do not replay commands after reconnection.

GET /api/state returns JSON with:
- host: string; config: object below; apps: [{id,name,icon,running,active}] (icon is PNG data URL, id is local registered app identifier, not arbitrary path).
- music: {available:bool,message:string,title?:string,artist?:string,album?:string,artwork?:string,playing?:bool,position?:number,duration?:number}.
- agents: {available:bool,message:string,items:[{id,name,status,detail,updatedAt?}]}.
- weather: {available:bool,message:string,city?:string,temperature?:number,description?:string,high?:number,low?:number,updatedAt?:string,attribution?:string}.
- controls: {volume?:number,muted?:bool,brightness?:number,volumeAvailable:bool,brightnessAvailable:bool,accessibility:bool,message:string}.

POST /api/command accepts {action:string,id?:string,value?:number}; returns {ok:bool,message:string}, non-2xx for failure. Allowlist: app.open(id), music.playPause, music.next, music.previous, music.seek(value seconds), volume.set(value 0...100), volume.mute, brightness.set(value 0...100), key.escape, key.desktop, key.search. Revalidate widget enable state server-side and value ranges. Disabled/unsupported actions fail visibly.

Persistent config keys: musicEnabled=true, agentsEnabled=true, weatherEnabled=false, appsEnabled=true, controlsEnabled=true, player="music" (music|spotify), agentPort=3939, city="", latitude=0, longitude=0. Weather enable requires explicit nonempty location, valid finite coordinates. Initial location is not Shanghai or any invented user location. Widgets can be switched independently, including all off. Browser settings cannot enable privileged services.

## Swift boundary

TouchBarProviders in Sources/TouchBarProviders.swift (and optional supporting TouchBar*.swift files owned by provider task):
- init()
- configure(_ config: [String: Any])
- snapshot(completion: @escaping ([String: Any]) -> Void)
- perform(_ command: [String: Any], completion: @escaping (Bool, String) -> Void)
- refreshApplications()
- stop()
All public entries and completion callbacks run on main queue; slow scripts, scanning, URL fetches must not block main queue. Provider snapshot contains apps/music/agents/weather/controls; service adds host/config. Cache expensive work, invalidate stale data, and drop old config generations. No permission prompts in passive polling. User-selected media commands may trigger Automation permission. Local native setup may explicitly request permission if implemented.

TouchBarService owns HTTP transport, configuration validation, pairing, snapshot caching and JSON serialization; callbacks and native configuration must marshal to main queue. It integrates with AppDelegate via new `touchBar` WK action, native status callback `window.ThunderTouchBar.receive(payload)`. JS posts {action:"touchBar",operation:"status"|"enable"|"disable"|"save"|"reset"|"refreshApps"|"copy"|"open",config?:object}. Native status shape: {enabled,addresses:[string],url,code,qr?:PNGDataURL,config,message}. No token returned through public state. Native QR uses CoreImage. Local preview should use listener LAN URL or supported loopback URL.

## Providers and honest limits

Applications: enumerate /Applications, /System/Applications and ~/Applications, nested app folders without descending into .app internals; use NSWorkspace icons/runningApplications. Refresh on demand and bounded schedule; opening only previously enumerated apps. Not a guarantee of finding apps on unmounted external disks.

Music: explicit Music/Spotify AppleScript adapters, real metadata, album and available cover art. No unsupported global Now Playing claim. Avoid launching player merely by polling; handle missing player/denied Automation. Never interpolate user-supplied script text. Artwork fetch (Spotify) must be bounded and HTTPS. Music artwork through scripting if possible; explicit unavailable fallback otherwise.

Agents: inspect and implement the actual schema of therswamhtet/agent-status-pock local bridge. Fetch only 127.0.0.1 at validated port, no redirected arbitrary URL. Show disconnected/stale rather than generated status. Do not run remote installers or modify users' hooks. Provide setup link and clear dependency explanation in desktop settings.

Weather: use Open-Meteo current/daily HTTPS from native side, with attribution, ten-minute caching and explicit failure/stale timestamps. Apple WeatherKit requires Apple Developer setup/signing or REST credentials and is not in this first implementation. Do not scrape Apple Weather app data.

Volume: CoreAudio default output device, query property existence/settable; handle devices without volume/mute support honestly. Brightness: built-in display supported capability only (implementation may dynamically load DisplayServices with no public compatibility promise); no DDC promise for external displays. Shortcut injection requires Accessibility; passive polling only checks status. Never represent unsupported slider value as zero.

## Verification gates

Compile/package arm64 and x86_64 with existing deployment target. Retain current display transport checks. HTTP integration checks must verify pair success/failure/rate limit, auth, revocation, host/origin rejection, malformed/oversized payloads, unknown commands and shutdown. Provider tests cover schema adaptation, invalid values, disabled widgets and stale responses without executing destructive controls. Browser checks cover initial pairing, real-state rendering, unauthorized reconnect, action feedback, all widgets off, safe text rendering, mobile landscape layouts and desktop navigation. Record actual local tests separately from real iPhone/Intel/display hardware checks.
