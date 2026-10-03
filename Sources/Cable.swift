import Foundation
import Network
import Darwin
import SystemConfiguration

struct CableAddress {
    let name: String
    let ip: String
    let index: UInt32

    static func current() -> CableAddress? {
        // Use the configured Thunderbolt Bridge service, never the default route.
        var bridges = Set<String>()
        if let prefs = SCPreferencesCreate(nil, "WiredDisplay" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                      name.hasPrefix("bridge") else { continue }
                let label = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "")
                let serviceName = SCNetworkServiceGetName(service) as String? ?? ""
                if label.localizedCaseInsensitiveContains("Thunderbolt") ||
                    serviceName.localizedCaseInsensitiveContains("Thunderbolt") ||
                    label.contains("雷雳") || label.contains("雷電") {
                    bridges.insert(name)
                }
            }
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            let name = String(cString: entry.ifa_name)
            guard bridges.contains(name), let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return CableAddress(name: name, ip: String(cString: host), index: if_nametoindex(name))
            }
        }
        return nil
    }

    var description: String { "\(name) \(ip) (#\(index))" }
}

// Network.framework owns socket lifetime, TCP framing reads and path changes.
// A required local endpoint pins the source address to the Thunderbolt bridge.
final class CablePeer {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "wired.network", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var readyReported = false
    private var deadline: DispatchWorkItem?
    private var latestPointer: Data?
    private var pointerScheduled = false
    private let cable: CableAddress
    var onPacket: ((PacketKind, Data) throws -> Void)?
    var onClose: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onState: ((String) -> Void)?

    init(connection: NWConnection, cable: CableAddress) {
        self.connection = connection
        self.cable = cable
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = false
        return parameters
    }

    static func connect(ip: String, cable: CableAddress) throws -> CablePeer {
        guard let address = IPv4Address(ip), address != .any,
              ip != cable.ip else { throw WireError.invalid("请输入另一台 Mac 的雷雳 IPv4 地址") }
        let parameters = parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(cable.ip), port: .any)
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular]
        let host = ip.hasPrefix("169.254.") ? "\(ip)%\(cable.name)" : ip
        return CablePeer(connection: NWConnection(host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: Wire.port)!, using: parameters), cable: cable)
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let cancelled = stopped
        lock.unlock()
        guard !cancelled else { return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isStopped else { return }
            switch state {
            case .preparing: self.onState?("正在选择雷雳路径 · \(self.cable.description)")
            case .waiting(let error):
                self.onState?(self.failure(error))
            case .ready:
                guard !self.readyReported else { return }
                self.readyReported = true
                self.deadline?.cancel()
                // Verify the actual endpoint, not just the UI's configured address.
                guard case .hostPort(let host, _) = self.connection.currentPath?.localEndpoint,
                      String(describing: host).split(separator: "%").first.map(String.init) == self.cable.ip else {
                    self.finish("已拒绝非指定雷雳地址的连接")
                    return
                }
                self.onState?("TCP 已连接 · \(self.connection.currentPath?.localEndpoint?.debugDescription ?? "?") → \(self.connection.endpoint)")
                self.onReady?()
                self.onReady = nil
                self.readHeader()
            case .failed(let error): self.finish(self.failure(error))
            case .cancelled: self.finish("连接已取消")
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish("TCP 建立超时。\(self.pathDetail)；请检查接收端监听与本地网络权限。")
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + 12, execute: deadline)
        connection.start(queue: queue)
    }

    private var pathDetail: String {
        guard let path = connection.currentPath else { return "尚无可用网络路径" }
        return "路径=\(path.status)，原因=\(path.unsatisfiedReason)，接口=\(path.availableInterfaces.map(\.name).joined(separator: ","))"
    }
    private func failure(_ error: NWError) -> String {
        let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
        return "TCP 未建立：\(error)。\(pathDetail)" + (denied
            ? "。系统拒绝本地网络访问，请在系统设置 → 隐私与安全性 → 本地网络允许 WiredDisplay。"
            : "。若终端可连接而本应用失败，请检查本地网络权限。")
    }

    func stop() { queue.async { [self] in finish("连接已断开") } }

    private func finish(_ reason: String) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onReady = nil; onState = nil; onPacket = nil; onClose = nil
    }

    func send(_ type: PacketKind, _ payload: Data = Data(), completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard !isStopped else { return }
            guard payload.count + 1 <= Wire.maximumPacket else { finish("数据包过大"); return }
            var packet = Wire.header(type, count: payload.count)
            packet.append(payload)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish("TCP 发送失败：\(error)") }
                else { completion?() }
            })
        }
    }

    func sendPointer(_ payload: Data) {
        lock.lock()
        latestPointer = payload
        let schedule = !pointerScheduled
        pointerScheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.async { [self] in flushPointer() }
    }
    private func flushPointer() {
        lock.lock()
        let payload = latestPointer
        latestPointer = nil
        if payload == nil { pointerScheduled = false }
        lock.unlock()
        guard let payload else { return }
        send(.cursor, payload) { [weak self] in self?.flushPointer() }
    }

    private func readHeader() {
        readExactly(4) { [weak self] header in
            guard let self else { return }
            do {
                let count = try Wire.packetLength(header)
                self.readExactly(count) { [weak self] body in
                    guard let self else { return }
                    do {
                        guard let byte = body.first, let kind = PacketKind(rawValue: byte) else {
                            throw WireError.invalid("无法识别对方的数据包")
                        }
                        try self.onPacket?(kind, Data(body.dropFirst()))
                        if !self.isStopped { self.readHeader() }
                    } catch { self.finish(error.localizedDescription) }
                }
            } catch { self.finish(error.localizedDescription) }
        }
    }
    private func readExactly(_ count: Int, completion: @escaping (Data) -> Void) {
        guard !isStopped else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self, !self.isStopped else { return }
            if let data, data.count == count { completion(data) }
            else if let error { self.finish("TCP 接收失败：\(error)") }
            else if complete { self.finish("对方关闭了 TCP 连接") }
            else { self.finish("TCP 数据包不完整") }
        }
    }
}

final class CableListener {
    private let listener: NWListener
    private let cable: CableAddress
    private let queue = DispatchQueue(label: "wired.listen")
    var onAccept: ((CablePeer) -> Void)?
    var onState: ((String, Bool) -> Void)?

    init(cable: CableAddress, port: UInt16 = Wire.port) throws {
        self.cable = cable
        // A wildcard listener survives local address changes. Each accepted connection
        // is checked against the current Thunderbolt address before protocol processing.
        listener = try NWListener(using: CablePeer.parameters(), on: NWEndpoint.Port(rawValue: port)!)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("监听中 · TCP \(self?.listener.port?.rawValue ?? Wire.port)", true)
            case .failed(let error): self?.onState?("监听失败：\(error)", false)
            case .waiting(let error): self?.onState?("等待监听：\(error)", false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.onAccept?(CablePeer(connection: connection, cable: CableAddress.current() ?? self.cable))
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "WiredDisplay",
            type: "_wireddisplay._tcp", txtRecord: NWTXTRecord(["protocol": String(Wire.protocolVersion),
                "version": Wire.appVersion, "ip": cable.ip, "interface": cable.name]))
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    deinit { listener.cancel() }
}

final class CableDiscovery {
    private let queue = DispatchQueue(label: "wired.discovery")
    private var browser: NWBrowser?
    var onReceivers: (([String]) -> Void)?

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_wireddisplay._tcp", domain: nil),
                                using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let addresses = results.compactMap { result -> String? in
                guard case .bonjour(let record) = result.metadata,
                      record["protocol"] == String(Wire.protocolVersion) else { return nil }
                return record["ip"]
            }
            DispatchQueue.main.async { self?.onReceivers?(Array(Set(addresses)).sorted()) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }
    func stop() { browser?.cancel() }
}
