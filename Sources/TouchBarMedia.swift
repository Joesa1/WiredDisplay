import AppKit
import Carbon

// AppleScript adapters deliberately target only these two application dictionaries.
enum TouchBarMedia {
    // Accessed only on the provider serial worker queue. Cache artwork by track identity.
    private static var coverKey = ""
    private static var cover: String?
    private static var coverRead = Date.distantPast
    static func permission(_ id: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) == noErr
    }

    static func execute(_ body: String, playerID: String) -> (NSAppleEventDescriptor?, String?) {
        let source = "with timeout of 3 seconds\nif application id \"\(playerID)\" is not running then error \"Player is not running\"\n tell application id \"\(playerID)\"\n\(body)\nend tell\nend timeout"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (result, error == nil ? nil : "播放器未响应、没有曲目或自动化权限未授权")
    }

    static func read(playerID: String, running: Bool) -> [String: Any] {
        guard running else { return ["available": false, "message": "请先在 Mac 打开所选播放器"] }
        guard permission(playerID, ask: false) else { return ["available": false, "permissionRequired": true, "message": "需要自动化权限：点击播放按钮发起授权，并在 Mac 确认"] }
        let spotify = playerID == "com.spotify.client"
        let source = "return {name of current track, artist of current track, album of current track, (player state is playing), player position, duration of current track}"
        let (result, error) = execute(source, playerID: playerID)
        guard error == nil, let value = result, value.numberOfItems == 6 else { return ["available": false, "message": error ?? "暂无播放信息"] }
        var state: [String: Any] = ["available": true, "message": "", "title": value.atIndex(1)?.stringValue ?? "", "artist": value.atIndex(2)?.stringValue ?? "", "album": value.atIndex(3)?.stringValue ?? "", "playing": value.atIndex(4)?.booleanValue ?? false]
        let position = value.atIndex(5)?.doubleValue ?? 0
        let duration = (value.atIndex(6)?.doubleValue ?? 0) / (spotify ? 1000 : 1)
        if position.isFinite { state["position"] = max(0, position) }
        if duration.isFinite { state["duration"] = max(0, duration) }
        let key = playerID + "|" + String(describing: state["title"]) + "|" + String(describing: state["album"]) + "|" + String(describing: state["artist"])
        if key == coverKey && Date().timeIntervalSince(coverRead) < 60 {
            state["artwork"] = cover
            return state
        }
        if spotify {
            let (artwork, _) = execute("return artwork url of current track", playerID: playerID)
            if let address = artwork?.stringValue, let url = URL(string: address), url.scheme == "https", url.host == "i.scdn.co", let data = TouchBarFetch.get(url, limit: 2_000_000), let image = NSImage(data: data) { state["artwork"] = png(image, size: 192) }
        } else {
            let (artwork, _) = execute("return raw data of artwork 1 of current track", playerID: playerID)
            if let data = artwork?.data, data.count <= 4_000_000, let image = NSImage(data: data) { state["artwork"] = png(image, size: 192) }
        }
        coverKey = key
        cover = state["artwork"] as? String
        coverRead = Date()
        return state
    }

    static func perform(_ action: String, value: Double?, playerID: String,
                        isValid: () -> Bool = { true },
                        requestPermission: (String, Bool) -> Bool = { permission($0, ask: $1) },
                        dispatch: (String, String) -> (NSAppleEventDescriptor?, String?) = { execute($0, playerID: $1) }) -> (Bool, String) {
        guard isValid() else { return (false, "配置已改变") }
        guard requestPermission(playerID, true) else { return (false, "请在系统设置 → 隐私与安全性 → 自动化中授权") }
        let body: String
        switch action {
        case "music.playPause": body = "playpause"
        case "music.next": body = "next track"
        case "music.previous": body = "previous track"
        case "music.seek":
            guard let value = value, value.isFinite, (0...86400).contains(value) else { return (false, "无效的播放位置") }
            body = "set player position to \(value)"
        default: return (false, "未知播放器操作")
        }
        guard isValid() else { return (false, "配置已改变") }
        let (_, error) = dispatch(body, playerID)
        return (error == nil, error ?? "已执行")
    }

    static func png(_ image: NSImage, size: Int) -> String? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}
