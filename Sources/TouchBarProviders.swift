import AppKit
import ApplicationServices
import Carbon
import CoreAudio

/// Native data and allowlisted actions. Public methods are main-queue confined.
final class TouchBarProviders {
    private var config: [String: Any] = [:]
    private var generation = 0
    private var stopped = false
    private var busy = false
    private var scanning = false
    private var commandPending = false
    private var applications: [(id: String, name: String, url: URL, icon: String)] = []
    private var cached: [String: Any] = [:]
    private var cachedAt = Date.distantPast
    private var weatherCache: [String: Any] = [:]
    private var weatherFetched = Date.distantPast
    private let worker = DispatchQueue(label: "local.wired-display.touchbar.providers", qos: .utility)
    private let hardware = TouchBarHardware()

    init() {}

    func configure(_ config: [String: Any]) {
        generation += 1
        self.config = config
        stopped = false
        cached = [:]
        weatherCache = [:]
        weatherFetched = .distantPast
        if enabled("appsEnabled") { refreshApplications() }
    }

    private func enabled(_ key: String) -> Bool { config[key] as? Bool ?? (key != "weatherEnabled") }

    func stop() {
        stopped = true
        generation += 1
        cached = [:]
    }

    func refreshApplications() {
        guard !scanning, !stopped else { return }
        scanning = true
        let version = generation
        worker.async { [weak self] in
            let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            var found: [(String, String, URL, String)] = []
            var seen = Set<String>()
            for root in roots {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { continue }
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
                    let icon = TouchBarMedia.png(NSWorkspace.shared.icon(forFile: url.path), size: 96) ?? ""
                    found.append((id, name, url, icon))
                    if found.count >= 1500 { break }
                }
            }
            let sorted = found.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                guard !self.stopped else { return }
                guard self.generation == version else {
                    if self.enabled("appsEnabled") { self.refreshApplications() }
                    return
                }
                self.applications = sorted
            }
        }
    }

    func snapshot(completion: @escaping ([String: Any]) -> Void) {
        guard !stopped else { completion([:]); return }
        if !busy {
            busy = true
            let version = generation
            let current = config
            let oldWeather = weatherCache
            let oldDate = weatherFetched
            let playerID = current["player"] as? String == "spotify" ? "com.spotify.client" : "com.apple.Music"
            let playerRunning = NSRunningApplication.runningApplications(withBundleIdentifier: playerID).contains { !$0.isTerminated }
            worker.async { [weak self] in
                var result: [String: Any] = [:]
                if current["musicEnabled"] as? Bool != false { result["music"] = TouchBarMedia.read(playerID: playerID, running: playerRunning) }
                if current["agentsEnabled"] as? Bool != false {
                    let port = current["agentPort"] as? Int ?? 3939
                    if (1024...65535).contains(port), let data = TouchBarFetch.get(URL(string: "http://127.0.0.1:\(port)/v1/state")!, limit: 262144), let state = TouchBarProviderSchema.agents(data) {
                        result["agents"] = state
                    } else { result["agents"] = ["available": false, "message": "Agent Status 桥接未连接或数据无效", "items": []] as [String: Any] }
                }
                var weather = oldWeather
                var fetched = oldDate
                if current["weatherEnabled"] as? Bool == true {
                    if Date().timeIntervalSince(oldDate) >= 600 {
                        weather = TouchBarProviderSchema.fetchWeather(current)
                        fetched = Date()
                    }
                    result["weather"] = weather
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.busy = false
                    guard !self.stopped, self.generation == version else { return }
                    self.cached = result
                    self.cachedAt = Date()
                    self.weatherCache = weather
                    self.weatherFetched = fetched
                }
            }
        }
        var state = cached
        if Date().timeIntervalSince(cachedAt) > 20 {
            for key in ["music", "agents"] { state[key] = ["available": false, "message": "状态已过期，正在重新连接", "items": []] as [String: Any] }
        }
        for key in ["music", "agents", "weather"] where state[key] == nil {
            state[key] = ["available": false, "message": enabled(key + "Enabled") ? "正在读取…" : "已关闭", "items": []] as [String: Any]
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        state["apps"] = enabled("appsEnabled") ? applications.map { ["id": $0.id, "name": $0.name, "icon": $0.icon, "running": running.contains($0.id), "active": active == $0.id] as [String: Any] } : []
        state["controls"] = enabled("controlsEnabled") ? hardware.snapshot() : ["volumeAvailable": false, "brightnessAvailable": false, "accessibility": false, "message": "已关闭"]
        completion(state)
    }

    func perform(_ command: [String: Any], completion: @escaping (Bool, String) -> Void) {
        guard !stopped, let action = command["action"] as? String, let widget = TouchBarProviderSchema.widget(for: action), enabled(widget) else { completion(false, "操作不可用或组件已关闭"); return }
        guard TouchBarProviderSchema.validCommand(command) else { completion(false, "无效的操作参数"); return }
        if action == "app.open" {
            guard let id = command["id"] as? String, let app = applications.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: app.url.path) else { completion(false, "应用不在已扫描列表中，请刷新应用"); return }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: options) { _, error in DispatchQueue.main.async { completion(error == nil, error == nil ? "已打开" : "无法打开应用") } }
        } else if action.hasPrefix("music.") {
            guard !commandPending else { completion(false, "已有播放器操作正在执行"); return }
            commandPending = true
            let version = generation
            let playerID = config["player"] as? String == "spotify" ? "com.spotify.client" : "com.apple.Music"
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: playerID).isEmpty else { commandPending = false; completion(false, "请先在 Mac 打开所选播放器"); return }
            worker.async { [weak self] in
                let allowed = DispatchQueue.main.sync { self.map { !$0.stopped && $0.generation == version } ?? false }
                let result = allowed ? TouchBarMedia.perform(action, value: command["value"] as? Double, playerID: playerID) : (false, "配置已改变")
                DispatchQueue.main.async {
                    guard let self = self else { completion(false, "服务已关闭"); return }
                    self.commandPending = false
                    guard !self.stopped, self.generation == version else { completion(false, "配置已改变"); return }
                    if result.0 { self.cached.removeValue(forKey: "music") }
                    completion(result.0, result.1)
                }
            }
        } else {
            let result = hardware.perform(action, value: command["value"] as? Double)
            completion(result.0, result.1)
        }
    }
}

/// Parsing and trust-boundary checks are pure so tests never execute controls.
enum TouchBarProviderSchema {
    static func widget(for action: String) -> String? {
        switch action {
        case "app.open": return "appsEnabled"
        case "music.playPause", "music.next", "music.previous", "music.seek": return "musicEnabled"
        case "volume.set", "volume.mute", "brightness.set", "key.escape", "key.desktop", "key.search": return "controlsEnabled"
        default: return nil
        }
    }

    static func validCommand(_ command: [String: Any]) -> Bool {
        guard let action = command["action"] as? String, widget(for: action) != nil else { return false }
        if action == "app.open" { return (command["id"] as? String).map { !$0.isEmpty && $0.count <= 512 } ?? false }
        if ["music.seek", "volume.set", "brightness.set"].contains(action) {
            guard let number = command["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let value = number.doubleValue
            return value.isFinite && value >= 0 && value <= (action == "music.seek" ? 86400 : 100)
        }
        return true
    }

    // Source: therswamhtet/agent-status-pock, BridgeClient.swift + Hub.swift, commit 1991f205.
    static func agents(_ data: Data, now: Date = Date()) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let agents = root["agents"] as? [[String: Any]], agents.count <= 100 else { return nil }
        let statuses = ["idle", "ready", "connected", "thinking", "answering", "working", "needsInput", "responseReady"]
        let activeStatuses = Set(["thinking", "answering", "working", "needsInput"])
        var items: [[String: Any]] = []
        for agent in agents {
            guard let id = agent["agent"] as? String, let name = agent["name"] as? String, let status = agent["status"] as? String, statuses.contains(status), let timestamp = agent["lastActive"] as? Double, timestamp.isFinite, timestamp >= 0, timestamp <= now.timeIntervalSince1970 + 60 else { return nil }
            let stale = timestamp > 0 && now.timeIntervalSince1970 - timestamp > 120
            let detail = [agent["label"] as? String, agent["tool"] as? String, agent["detail"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            guard !stale, activeStatuses.contains(status) else { continue }
            var item: [String: Any] = ["id": String(id.prefix(128)), "name": String(name.prefix(128)), "status": status, "detail": String(detail.prefix(1024))]
            if timestamp > 0 { item["updatedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp)) }
            items.append(item)
        }
        return ["available": true, "message": items.isEmpty ? "桥接已连接，暂无 Agent" : "来自本机 Agent Status 桥接", "items": items]
    }

    static func fetchWeather(_ config: [String: Any]) -> [String: Any] {
        let unavailable: [String: Any] = ["available": false, "message": "天气获取失败，请检查位置和网络", "attribution": "Open-Meteo"]
        guard let city = config["city"] as? String, !city.trimmingCharacters(in: .whitespaces).isEmpty, let latitude = config["latitude"] as? Double, let longitude = config["longitude"] as? Double, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return ["available": false, "message": "请先在 Mac 配置城市和经纬度"] }
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1")!
        guard let data = TouchBarFetch.get(url, limit: 262144), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let current = root["current"] as? [String: Any], let temperature = current["temperature_2m"] as? Double, temperature.isFinite, let code = current["weather_code"] as? Int else { return unavailable }
        let descriptions = [0: "晴", 1: "大部晴朗", 2: "多云", 3: "阴", 45: "雾", 48: "冻雾", 51: "小毛毛雨", 53: "毛毛雨", 55: "强毛毛雨", 56: "冻毛毛雨", 57: "强冻毛毛雨", 61: "小雨", 63: "雨", 65: "大雨", 66: "冻雨", 67: "强冻雨", 71: "小雪", 73: "雪", 75: "大雪", 77: "雪粒", 80: "小阵雨", 81: "阵雨", 82: "强阵雨", 85: "阵雪", 86: "强阵雪", 95: "雷暴", 96: "雷暴伴冰雹", 99: "强雷暴伴冰雹"]
        var result: [String: Any] = ["available": true, "message": "", "city": city, "temperature": temperature, "description": descriptions[code] ?? "未知天气", "updatedAt": ISO8601DateFormatter().string(from: Date()), "attribution": "Open-Meteo · open-meteo.com"]
        if let daily = root["daily"] as? [String: Any] {
            if let high = (daily["temperature_2m_max"] as? [Double])?.first, high.isFinite { result["high"] = high }
            if let low = (daily["temperature_2m_min"] as? [Double])?.first, low.isFinite { result["low"] = low }
        }
        return result
    }
}

/// Small bounded downloader. Never follows a redirect away from the requested endpoint.
final class TouchBarFetch: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var data = Data()
    private var accepted = false
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    init(limit: Int) { self.limit = limit }
    static func get(_ url: URL, limit: Int) -> Data? {
        let delegate = TouchBarFetch(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: url).resume()
        let finished = delegate.done.wait(timeout: .now() + 5) == .success
        session.invalidateAndCancel()
        delegate.lock.lock()
        defer { delegate.lock.unlock() }
        return finished && delegate.accepted ? delegate.data : nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        accepted = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= Int64(limit)
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if self.data.count + data.count > limit { accepted = false; dataTask.cancel() } else { self.data.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if error != nil { accepted = false }
        lock.unlock()
        done.signal()
    }
}
