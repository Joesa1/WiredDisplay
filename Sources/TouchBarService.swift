import AppKit
import CoreImage
import Security
import SystemConfiguration

final class TouchBarService {
    static let defaults: [String: Any] = ["musicEnabled": true, "agentsEnabled": true, "weatherEnabled": false, "appsEnabled": true, "controlsEnabled": true, "player": "music", "agentPort": 3939, "city": "", "latitude": 0.0, "longitude": 0.0]
    private let providers = TouchBarProviders()
    private var server: TouchBarHTTPServer?
    private var port = 0
    private var addresses: [String] = []
    private var code = ""
    private var tokens = Set<String>()
    private var attempts: [Date] = []
    private var config = TouchBarService.defaults
    private var pendingCommand: UUID?
    private var generation = UUID()
    private var listenerGeneration = UUID()
    private var message = "仅在可信局域网开启；HTTP 不加密。"
    var onStatus: (([String: Any]) -> Void)?
    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "touchBarConfig"), let valid = Self.validated(saved) { config = valid }
        providers.stop()
    }
    func handle(_ body: [String: Any]) {
        if server != nil { addresses = Self.localAddresses() }
        switch body["operation"] as? String {
        case "enable": start()
        case "disable": stop()
        case "save":
            guard let proposed = body["config"] as? [String: Any], let valid = Self.validated(proposed) else { message = "配置无效：请检查位置、端口与播放器。"; publish(); return }
            config = valid; UserDefaults.standard.set(config, forKey: "touchBarConfig"); if server != nil { providers.configure(config) }; message = "配置已保存。"
        case "reset": revoke(); message = "已撤销所有手机访问，请重新配对。"
        case "refreshApps":
            if server != nil { providers.refreshApplications(); message = "正在刷新应用列表。" } else { message = "请先开启手机访问。" }
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
        case "open": if server != nil, let address = URL(string: url) { NSWorkspace.shared.open(address) }
        default: break
        }
        publish()
    }
    private var url: String { addresses.first.map { "http://\($0):\(port)" } ?? "" }
    func stop() {
        server?.stop(); server = nil; listenerGeneration = UUID(); generation = UUID(); tokens.removeAll(); code = ""; attempts.removeAll(); pendingCommand = nil
        providers.stop(); addresses = []; port = 0; message = "手机访问已关闭。"
    }
    private func start() {
        guard server == nil else { return }
        let candidate = TouchBarHTTPServer()
        let listenerID = UUID(); listenerGeneration = listenerID
        do {
            port = try candidate.start { [weak self] request, reply in
                DispatchQueue.main.async {
                    guard let self, self.listenerGeneration == listenerID else { reply(TouchBarResponse(status: 503, body: Data("{}".utf8))); return }
                    self.receive(request, reply: reply)
                }
            }
            server = candidate; addresses = Self.localAddresses(); revoke(); providers.configure(config)
            message = "手机与 Mac 连接同一局域网，扫码后输入配对码。HTTP 不加密。"
        } catch { candidate.stop(); message = "无法开启服务：\(error.localizedDescription)" }
    }
    private func revoke() { generation = UUID(); tokens.removeAll(); code = Self.pairingCode(); attempts.removeAll() }
    private static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { fatalError("Secure randomness unavailable") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func pairingCode() -> String {
        var code = ""
        while code.count < 6 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { fatalError("Secure randomness unavailable") }
            if byte < 250 { code.append(String(byte % 10)) }
        }
        return code
    }
    private func publish() {
        var status: [String: Any] = ["enabled": server != nil, "addresses": addresses.map { "http://\($0):\(port)" }, "url": url, "code": code, "config": config, "message": message]
        if !url.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data(url.utf8), forKey: "inputMessage")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)), let cg = CIContext().createCGImage(output, from: output.extent), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { status["qr"] = "data:image/png;base64," + png.base64EncodedString() }
        }
        onStatus?(status)
    }
    private func receive(_ request: TouchBarRequest, reply: @escaping (TouchBarResponse) -> Void) {
        func respond(_ status: Int, _ payload: [String: Any]) { reply(TouchBarResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))) }
        let headers = Dictionary(request.headers, uniquingKeysWith: { first, _ in first })
        let hosts = Set((addresses + ["127.0.0.1", "localhost"]).map { "\($0):\(port)" })
        guard server != nil, let host = headers["host"], hosts.contains(host), headers["origin"] == nil || headers["origin"] == "http://" + host else { respond(403, ["message": "访问来源不被允许"]); return }
        guard headers["sec-fetch-site"] != "cross-site" else { respond(403, ["message": "禁止跨站访问"]); return }
        if request.method == "GET", ["/", "/touch-bar.html"].contains(request.uri) {
            guard let path = Bundle.main.url(forResource: "touch-bar", withExtension: "html"), let page = try? Data(contentsOf: path) else { respond(503, ["message": "手机页面资源缺失"]); return }
            reply(TouchBarResponse(status: 200, contentType: "text/html; charset=utf-8", body: page)); return
        }
        var payload: [String: Any] = [:]
        if request.method == "POST" {
            guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json", let object = try? JSONSerialization.jsonObject(with: request.body), let dictionary = object as? [String: Any] else { respond(400, ["message": "需要有效 JSON 请求"]); return }
            payload = dictionary
        }
        if request.method == "POST", request.uri == "/api/pair" {
            attempts.removeAll { Date().timeIntervalSince($0) > 60 }
            guard attempts.count < 6, tokens.count < 8 else { respond(429, ["message": "配对请求过多，请稍后重试或在 Mac 重置访问"]); return }
            attempts.append(Date())
            guard payload["code"] as? String == code else { respond(401, ["message": "配对码错误"]); return }
            let token = Self.random(32); tokens.insert(token); respond(200, ["token": token]); return
        }
        guard let auth = headers["authorization"], auth.hasPrefix("Bearer "), tokens.contains(String(auth.dropFirst(7))) else { respond(401, ["message": "请重新配对"]); return }
        let current = generation
        if request.method == "GET", request.uri == "/api/state" {
            providers.snapshot { [weak self] state in
                guard let self, self.server != nil, self.generation == current else { respond(401, ["message": "访问已撤销"]); return }
                var state = state; state["config"] = self.config; state["host"] = Host.current().localizedName ?? "Mac"
                respond(200, state)
            }; return
        }
        if request.method == "POST", request.uri == "/api/command" {
            guard let action = payload["action"] as? String, let widget = Self.actions[action], config[widget] as? Bool == true else { respond(400, ["ok": false, "message": "操作未知或组件未开启"]); return }
            if ["volume.set", "brightness.set", "music.seek"].contains(action) {
                guard let number = payload["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= (action == "music.seek" ? 604800 : 100) else { respond(400, ["ok": false, "message": "数值超出范围"]); return }
            }
            if action == "app.open", (payload["id"] as? String)?.isEmpty != false { respond(400, ["ok": false, "message": "缺少应用标识"]); return }
            guard pendingCommand == nil else { respond(429, ["ok": false, "message": "上一个操作仍在执行"]); return }
            let commandID = UUID(); pendingCommand = commandID
            providers.perform(payload) { [weak self] ok, message in
                guard let self else { return }
                if self.pendingCommand == commandID { self.pendingCommand = nil }
                guard self.generation == current else { respond(401, ["ok": false, "message": "访问已撤销"]); return }
                 respond(ok ? 200 : 422, ["ok": ok, "message": message])
            }; return
        }
        respond(404, ["message": "接口不存在"])
    }
    private static let actions = ["app.open": "appsEnabled", "music.playPause": "musicEnabled", "music.next": "musicEnabled", "music.previous": "musicEnabled", "music.seek": "musicEnabled", "volume.set": "controlsEnabled", "volume.mute": "controlsEnabled", "brightness.set": "controlsEnabled", "key.escape": "controlsEnabled", "key.desktop": "controlsEnabled", "key.search": "controlsEnabled"]
    static func validated(_ input: [String: Any]) -> [String: Any]? {
        var result = defaults
        for key in ["musicEnabled", "agentsEnabled", "weatherEnabled", "appsEnabled", "controlsEnabled"] {
            guard let number = input[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }; result[key] = number.boolValue
        }
        guard let player = input["player"] as? String, ["music", "spotify"].contains(player), let port = input["agentPort"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(), port.doubleValue.rounded() == port.doubleValue, (1024...65535).contains(port.intValue), let city = input["city"] as? String, city.count <= 100,
              let latitude = input["latitude"] as? NSNumber, let longitude = input["longitude"] as? NSNumber, CFGetTypeID(latitude) != CFBooleanGetTypeID(), CFGetTypeID(longitude) != CFBooleanGetTypeID(), latitude.doubleValue.isFinite, longitude.doubleValue.isFinite, (-90...90).contains(latitude.doubleValue), (-180...180).contains(longitude.doubleValue) else { return nil }
        guard result["weatherEnabled"] as? Bool != true || !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        result["player"] = player; result["agentPort"] = port.intValue; result["city"] = city; result["latitude"] = latitude.doubleValue; result["longitude"] = longitude.doubleValue
        return result
    }
    private static func localAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return ["127.0.0.1"] }; defer { freeifaddrs(pointer) }
        let store = SCDynamicStoreCreate(nil, "TouchBar" as CFString, nil, nil)
        let primary = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }?["PrimaryInterface"] as? String
        var preferred: String?
        var addresses = Set<String>(); var cursor = pointer
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.insert(String(cString: host)); if String(cString: entry.pointee.ifa_name) == primary { preferred = String(cString: host) } }
        }
        return (preferred.map { [$0] } ?? []) + addresses.filter { $0 != preferred }.sorted() + ["127.0.0.1"]
    }
}
