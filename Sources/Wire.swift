import Foundation

enum WireError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

enum PacketKind: UInt8 {
    case hello = 1, profile, configuration, video, acknowledgment, cursor, heartbeat, end, statistics, audioConfiguration, audio
}

// Length-prefix framing adapted from TargetBridge (MIT). Protocol is independent.
enum Wire {
    // Both roles use this fixed port; pairing is verified before display streaming.
    static let port: UInt16 = 54321
    static let protocolVersion = 2
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.2"
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

struct PeerIdentity: Codable {
    let id: String
    let name: String
    let model: String
    let systemVersion: String
}

struct Hello: Codable {
    let version: Int
    let code: String
    let probe: Bool?
    let appVersion: String?
    let identity: PeerIdentity?
    let address: String?
    let receiverCode: String?
    let preventDisplaySleep: Bool?

    init(version: Int, code: String, appVersion: String = Wire.appVersion, probe: Bool = false,
         identity: PeerIdentity? = nil, address: String? = nil, receiverCode: String? = nil,
         preventDisplaySleep: Bool? = nil) {
        self.version = version
        self.probe = probe
        self.code = code
        self.appVersion = appVersion
        self.identity = identity
        self.address = address
        self.receiverCode = receiverCode
        self.preventDisplaySleep = preventDisplaySleep
    }
}

struct DisplayProfile: Codable {
    let width: Int
    let height: Int
    let hiDPI: Bool
    let hevc: Bool
    let appVersion: String?
    let identity: PeerIdentity?
    let receiverCode: String?

    init(width: Int, height: Int, hiDPI: Bool, hevc: Bool, appVersion: String?,
         identity: PeerIdentity? = nil, receiverCode: String? = nil) {
        self.width = width; self.height = height; self.hiDPI = hiDPI; self.hevc = hevc
        self.appVersion = appVersion; self.identity = identity; self.receiverCode = receiverCode
    }

    var logicalWidth: Int { hiDPI ? width / 2 : width }
    var logicalHeight: Int { hiDPI ? height / 2 : height }

    func validate() throws {
        guard (640...5120).contains(width), (480...2880).contains(height),
              width % 2 == 0, height % 2 == 0 else {
            throw WireError.invalid("接收屏幕尺寸不受支持")
        }
    }
    func limited(to4K: Bool) -> DisplayProfile {
        let ratio = to4K ? min(1, min(3840.0 / Double(width), 2160.0 / Double(height))) : 1
        let limitedWidth = Int(Double(width) * ratio) / 2 * 2
        let limitedHeight = Int(Double(height) * ratio) / 2 * 2
        return DisplayProfile(width: limitedWidth, height: limitedHeight,
                              hiDPI: hiDPI, hevc: hevc, appVersion: appVersion,
                              identity: identity, receiverCode: receiverCode)
    }
}

struct StreamStatistics: Codable {
    let fps: Double
    let roundTripMilliseconds: Double
    let megabitsPerSecond: Double
    let codec: String
    let samples: [Double]
}

struct AudioConfiguration: Codable {
    let sampleRate: Double
    let channels: Int
    let bytesPerFrame: Int
    let bitsPerChannel: Int
    let interleaved: Bool
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
