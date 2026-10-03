import Foundation
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
}

private func socketAddress(_ ip: String, port: UInt16) throws -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
        throw WireError.invalid("请输入接收端显示的雷雳地址")
    }
    return address
}

private func configureSocket(_ fd: Int32, cable: CableAddress) throws {
    var yes: Int32 = 1
    var index = cable.index
    guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else {
        throw WireError.invalid("无法绑定雷雳接口")
    }
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, 4)
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, 4)
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

final class CablePeer {
    private let lock = NSLock()
    private var fd: Int32
    private var stopped = false
    private let writer = DispatchQueue(label: "wired.write", qos: .userInteractive)
    private var latestPointer: Data?
    private var pointerScheduled = false
    var onPacket: ((PacketKind, Data) throws -> Void)?
    var onClose: ((String) -> Void)?

    init(fd: Int32) { self.fd = fd }

    static func connect(ip: String, cable: CableAddress) throws -> CablePeer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.invalid("无法创建连接") }
        do {
            try configureSocket(fd, cable: cable)
            var local = try socketAddress(cable.ip, port: 0)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else {
                let code = errno
                throw WireError.invalid("无法绑定本机雷雳地址 \(cable.ip)（\(code): \(String(cString: strerror(code)))）")
            }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var remote = try socketAddress(ip, port: Wire.port)
            let result = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result != 0 {
                let code = errno
                guard code == EINPROGRESS else {
                    throw WireError.invalid("无法连接接收端 \(ip):\(Wire.port)（\(code): \(String(cString: strerror(code)))）")
                }
                var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&event, 1, 5000) > 0 else { throw WireError.invalid("连接超时，请在 iMac 点击「用作显示器」") }
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    let code = error == 0 ? errno : error
                    throw WireError.invalid("接收端没有监听 \(ip):\(Wire.port)（\(code): \(String(cString: strerror(code)))）")
                }
            }
            _ = fcntl(fd, F_SETFL, flags)
            return CablePeer(fd: fd)
        } catch { Darwin.close(fd); throw error }
    }

    func start() {
        DispatchQueue(label: "wired.read", qos: .userInteractive).async { [self] in
            var reason = "连接已断开"
            do {
                while !isStopped {
                    let header = try readExactly(4)
                    let body = try readExactly(Wire.packetLength(header))
                    guard let byte = body.first, let type = PacketKind(rawValue: byte) else {
                        throw WireError.invalid("对方应用版本不兼容")
                    }
                    try onPacket?(type, Data(body.dropFirst()))
                }
            } catch { reason = error.localizedDescription }
            stop()
            // Writer and reader finish before closing to prevent descriptor reuse races.
            writer.sync {}
            lock.lock()
            Darwin.close(fd)
            fd = -1
            lock.unlock()
            onClose?(reason)
        }
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    func send(_ type: PacketKind, _ payload: Data = Data()) {
        guard payload.count + 1 <= Wire.maximumPacket else { stop(); return }
        writer.async { [self] in writePacket(type, payload) }
    }

    func sendPointer(_ payload: Data) {
        lock.lock()
        latestPointer = payload
        let schedule = !pointerScheduled
        pointerScheduled = true
        lock.unlock()
        guard schedule else { return }
        writer.async { [self] in
            lock.lock()
            let data = latestPointer
            latestPointer = nil
            pointerScheduled = false
            lock.unlock()
            if let data { writePacket(.cursor, data) }
        }
    }

    private func writePacket(_ type: PacketKind, _ payload: Data) {
        guard !isStopped else { return }
        do { try writeAll(Wire.header(type, count: payload.count)); try writeAll(payload) }
        catch { stop() }
    }
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard !isStopped else { throw WireError.invalid("连接已停止") }
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw WireError.invalid("雷雳发送中断") }
                offset += n
            }
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw WireError.invalid("雷雳连接已断开") }
                offset += n
            }
        }
        return data
    }
}

final class CableListener {
    private let lock = NSLock()
    private var stopped = false
    let fd: Int32
    let cable: CableAddress
    var onAccept: ((CablePeer) -> Void)?

    init(cable: CableAddress) throws {
        self.cable = cable
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.invalid("无法监听雷雳接口") }
        do {
            try configureSocket(fd, cable: cable)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
            var address = try socketAddress(cable.ip, port: Wire.port)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else {
                let code = errno
                throw WireError.invalid("无法监听雷雳地址 \(cable.ip):\(Wire.port)（\(code): \(String(cString: strerror(code)))）")
            }
            guard listen(fd, 2) == 0 else {
                let code = errno
                throw WireError.invalid("端口 \(Wire.port) 无法监听（\(code): \(String(cString: strerror(code)))）")
            }
        } catch { Darwin.close(fd); throw error }
    }
    func start() {
        DispatchQueue(label: "wired.accept").async { [self] in
            defer { Darwin.close(fd) }
            while true {
                lock.lock(); let done = stopped; lock.unlock()
                if done { break }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 250) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                do {
                    try configureSocket(client, cable: cable)
                    onAccept?(CablePeer(fd: client))
                } catch { Darwin.close(client) }
            }
        }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
