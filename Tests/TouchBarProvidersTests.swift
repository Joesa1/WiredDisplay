import AppKit

@main
struct ProviderTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 2000)
        let fresh = Data(#"{"agents":[{"agent":"codex","name":"Codex","status":"working","label":"Running","tool":"Bash","detail":"test","lastActive":1990}]}"#.utf8)
        let parsed = TouchBarProviderSchema.agents(fresh, now: now)!
        assert((parsed["items"] as! [[String: Any]])[0]["status"] as? String == "working")
        let stale = TouchBarProviderSchema.agents(fresh, now: Date(timeIntervalSince1970: 2200))!
        assert((stale["items"] as! [[String: Any]])[0]["status"] as? String == "stale")
        assert(TouchBarProviderSchema.agents(Data(#"{"agents":[{"agent":"codex","name":"Codex","status":"invented","lastActive":10}]}"#.utf8), now: now) == nil)
        assert(TouchBarProviderSchema.agents(Data(#"{"agents":{}}"#.utf8), now: now) == nil)
        assert(TouchBarProviderSchema.agents(fresh, now: Date(timeIntervalSince1970: 100)) == nil)
        for value in [-1.0, 101.0, Double.infinity, Double.nan] { assert(!TouchBarProviderSchema.validCommand(["action": "volume.set", "value": value])) }
        assert(!TouchBarProviderSchema.validCommand(["action": "volume.set", "value": true]))
        assert(!TouchBarProviderSchema.validCommand(["action": "volume.set", "value": "50"]))
        assert(!TouchBarProviderSchema.validCommand(["action": "shell", "value": 1]))
        assert(TouchBarProviderSchema.validCommand(["action": "volume.set", "value": 50]))
        let provider = TouchBarProviders()
        provider.configure(["appsEnabled": false, "musicEnabled": false, "controlsEnabled": false, "agentsEnabled": false, "weatherEnabled": false])
        for action in ["app.open", "music.playPause", "volume.mute", "brightness.set", "key.escape"] {
            var called = false
            provider.perform(["action": action, "id": "com.apple.finder", "value": 50]) { ok, _ in assert(!ok); called = true }
            assert(called)
        }
        provider.stop()
        provider.perform(["action": "music.playPause"]) { ok, _ in assert(!ok) }
        // Read-only enumeration uses real installed apps; no launch, playback or device changes.
        provider.configure(["appsEnabled": true, "musicEnabled": false, "controlsEnabled": false, "agentsEnabled": false, "weatherEnabled": false])
        let deadline = Date().addingTimeInterval(25)
        var apps: [[String: Any]] = []
        while Date() < deadline && apps.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            provider.snapshot { apps = $0["apps"] as? [[String: Any]] ?? [] }
        }
        assert(!apps.isEmpty, "Expected installed applications")
        assert(apps.allSatisfy { $0["id"] is String && $0["name"] is String && $0["running"] is Bool && $0["active"] is Bool })
        assert(apps.contains { ($0["icon"] as? String)?.hasPrefix("data:image/png;base64,") == true })
        provider.stop()
        print("Touch Bar provider checks passed; enumerated \(apps.count) real applications without executing controls.")
    }
}
