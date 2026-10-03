import Foundation

enum WireError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

enum PacketKind: UInt8 {
    case hello = 1, profile, configuration, video, acknowledgment, cursor, heartbeat, end
}

// Length-prefix framing adapted from TargetBridge (MIT). Protocol is independent.
enum Wire {
    static let port: UInt16 = 54941
    static let maximumPacket = 16 * 1024 * 1024
    static func header(_ kind: PacketKind, count: Int) -> Data {
        var data = Data()
        append(UInt32(count + 1), to: &data)
        data.append(kind.rawValue)
        return data
    }
    static func append<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var value = number.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) throws -> T {
        guard offset >= 0, data.count >= offset + MemoryLayout<T>.size else {
            throw WireError.invalid("数据包不完整")
        }
        return data.dropFirst(offset).prefix(MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T($1) }
    }
    static func packetLength(_ header: Data) throws -> Int {
        let size = Int(try integer(header, at: 0, as: UInt32.self))
        guard (1...maximumPacket).contains(size) else { throw WireError.invalid("数据包大小无效") }
        return size
    }
    static func json<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 256 * 1024 else { throw WireError.invalid("控制消息过大") }
        return try JSONDecoder().decode(type, from: data)
    }
}

struct Hello: Codable {
    let version: Int
    let code: String
}

struct DisplayProfile: Codable {
    let width: Int
    let height: Int
    let hiDPI: Bool
    let hevc: Bool

    func validate() throws {
        guard (640...5120).contains(width), (480...2880).contains(height),
              width % 2 == 0, height % 2 == 0 else {
            throw WireError.invalid("接收屏幕尺寸不受支持")
        }
    }
    func limited(to4K: Bool) -> DisplayProfile {
        let ratio = to4K ? min(1, min(3840.0 / Double(width), 2160.0 / Double(height))) : 1
        return DisplayProfile(width: Int(Double(width) * ratio) / 2 * 2,
                              height: Int(Double(height) * ratio) / 2 * 2,
                              hiDPI: hiDPI, hevc: hevc)
    }
}

struct VideoConfiguration: Codable {
    let width: Int
    let height: Int
    let hevc: Bool
    let parameterSets: [Data]
}

struct PointerUpdate: Codable {
    let x: Double
    let y: Double
    let visible: Bool
    let hotX: Double
    let hotY: Double
    let width: Double
    let height: Double
    let png: Data?

    func validate() throws {
        guard [x, y, hotX, hotY, width, height].allSatisfy({ $0.isFinite }),
              (-2...2).contains(x), (-2...2).contains(y),
              (0...256).contains(width), (0...256).contains(height),
              (0...256).contains(hotX), (0...256).contains(hotY),
              (png?.count ?? 0) < 128 * 1024 else {
            throw WireError.invalid("鼠标消息无效")
        }
    }
}

// Reserve before encoding; release only when the receiver submits a decoded image.
// Never discard encoded reference frames to relieve network pressure.
struct FrameBudget {
    let limit: Int
    private(set) var sequence: UInt64 = 0
    private(set) var pending: [UInt64: UInt64] = [:]
    mutating func reserve(now: UInt64) -> UInt64? {
        guard pending.count < limit else { return nil }
        sequence += 1
        pending[sequence] = now
        return sequence
    }
    mutating func acknowledge(_ sequence: UInt64, now: UInt64) throws -> Double? {
        guard sequence <= self.sequence else { throw WireError.invalid("画面确认序号无效") }
        let start = pending[sequence]
        pending = pending.filter { $0.key > sequence }
        return start.map { Double(now >= $0 ? now - $0 : 0) / 1_000_000 }
    }
}
