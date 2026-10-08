import Foundation
import Network
import Darwin

@main enum TransportCheck {
    static func main() throws {
        let queue = DispatchQueue(label: "transport.check")
        let listener = try NWListener(using: CablePeer.parameters(), on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let loopback = CableAddress(name: "lo0", ip: "127.0.0.1", index: if_nametoindex("lo0"))
        let received = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        var peers: [CablePeer] = []
        var packets = 0
        listener.newConnectionHandler = { connection in
            let peer = CablePeer(connection: connection, cable: loopback)
            peers.append(peer)
            peer.onPacket = { kind, data in
                if kind == .video {
                    precondition(data.count == 8 + 4480 * 2520 * 4)
                    precondition(data.first == 91 && data.last == 91)
                    received.signal()
                    return
                }
                precondition(kind == .hello)
                let hello = try Wire.decode(Hello.self, data)
                precondition(hello.code == "123456" && hello.probe == true)
                packets += 1
                received.signal()
            }
            peer.onClose = { _ in closed.signal() }
            peer.start()
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
        let port = listener.port!.rawValue

        func client() -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            precondition(result == 0)
            return fd
        }
        func write(_ fd: Int32, _ data: Data) {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    precondition(sent > 0)
                    offset += sent
                }
            }
        }
        let payload = try Wire.json(Hello(version: Wire.protocolVersion, code: "123456", probe: true))
        try Wire.validateProtocol(Wire.protocolVersion)
        rejects { try Wire.validateProtocol(4) }
        let identity = PeerIdentity(id: "check-mac", name: "Check Mac", model: "MacBookPro", systemVersion: "macOS test")
        let paired = Hello(version: Wire.protocolVersion, code: "123456", identity: identity,
                           address: "10.10.10.2", receiverCode: "654321")
        let decodedPair = try Wire.decode(Hello.self, Wire.json(paired))
        precondition(decodedPair.identity?.id == "check-mac" && decodedPair.receiverCode == "654321")
        let profile = DisplayProfile(width: 2560, height: 1440, hiDPI: false, hevc: true,
                                     appVersion: Wire.appVersion, identity: identity, receiverCode: "654321")
        let decodedProfile = try Wire.decode(DisplayProfile.self, Wire.json(profile))
        precondition(decodedProfile.identity?.name == "Check Mac" && decodedProfile.receiverCode == "654321")
        let demo3 = VideoConfiguration(width: 2560, height: 1440, hevc: false, parameterSets: [],
                                       mode: .demo3, colorSpace: .displayP3)
        try demo3.validate()
        let decodedDemo3 = try Wire.decode(VideoConfiguration.self, Wire.json(demo3))
        precondition(decodedDemo3.mode == .demo3)
        let frame = Wire.header(.hello, count: payload.count) + payload
        let fd = client()
        // Exercise split headers and bodies, then two frames in one TCP write.
        for byte in frame { write(fd, Data([byte])) }
        precondition(received.wait(timeout: .now() + 3) == .success)
        write(fd, frame + frame)
        for _ in 0..<2 { precondition(received.wait(timeout: .now() + 3) == .success) }
        // A native 4.5K BGRA frame exceeds the old 16 MiB framing limit.
        let raw = Data(repeating: 91, count: 8 + 4480 * 2520 * 4)
        write(fd, Wire.header(.video, count: raw.count) + raw)
        precondition(received.wait(timeout: .now() + 10) == .success)
        Darwin.close(fd)
        precondition(closed.wait(timeout: .now() + 3) == .success)
        let bad = client()
        write(bad, Data([255, 255, 255, 255]))
        precondition(closed.wait(timeout: .now() + 3) == .success)
        Darwin.close(bad)
        let again = client()
        write(again, frame)
        precondition(received.wait(timeout: .now() + 3) == .success)
        Darwin.close(again)
        precondition(closed.wait(timeout: .now() + 3) == .success)
        precondition(packets == 4)
        for peer in peers { peer.stop(); peer.stop() }
        precondition(closed.wait(timeout: .now() + 0.2) == .timedOut)
        listener.cancel()
        print("PASS: fragmented/coalesced frames, 4.5K raw framing, oversized frame rejection, reconnect, idempotent close")
    }

    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }
}
