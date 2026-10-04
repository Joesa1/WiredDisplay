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
                precondition(Darwin.send(fd, raw.baseAddress, raw.count, 0) == raw.count)
            }
        }
        let payload = try Wire.json(Hello(version: Wire.protocolVersion, code: "123456", probe: true))
        let identity = PeerIdentity(id: "check-mac", name: "Check Mac", model: "MacBookPro", systemVersion: "macOS test")
        let paired = Hello(version: Wire.protocolVersion, code: "123456", identity: identity,
                           address: "10.10.10.2", receiverCode: "654321")
        let decodedPair = try Wire.decode(Hello.self, Wire.json(paired))
        precondition(decodedPair.identity?.id == "check-mac" && decodedPair.receiverCode == "654321")
        let profile = DisplayProfile(width: 2560, height: 1440, hiDPI: false, hevc: true,
                                     appVersion: Wire.appVersion, identity: identity, receiverCode: "654321")
        let decodedProfile = try Wire.decode(DisplayProfile.self, Wire.json(profile))
        precondition(decodedProfile.identity?.name == "Check Mac" && decodedProfile.receiverCode == "654321")
        let frame = Wire.header(.hello, count: payload.count) + payload
        let fd = client()
        // Exercise split headers and bodies, then two frames in one TCP write.
        for byte in frame { write(fd, Data([byte])) }
        precondition(received.wait(timeout: .now() + 3) == .success)
        write(fd, frame + frame)
        for _ in 0..<2 { precondition(received.wait(timeout: .now() + 3) == .success) }
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
        print("PASS: fragmented/coalesced frames, oversized frame rejection, reconnect, idempotent close")
    }
}
