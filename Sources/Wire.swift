import Foundation
import Compression

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
    static let protocolVersion = 5
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.7.5"
    static let maximumPacket = 64 * 1024 * 1024
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
    static func validateProtocol(_ version: Int) throws {
        guard version == protocolVersion else {
            throw WireError.invalid("协议版本不兼容，请更新两台 Mac")
        }
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
    var wideGamut: Bool = false

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
        var result = DisplayProfile(width: limitedWidth, height: limitedHeight,
                              hiDPI: hiDPI, hevc: hevc, appVersion: appVersion,
                              identity: identity, receiverCode: receiverCode)
        result.wideGamut = wideGamut
        return result
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
    var mode: TransmissionMode = .lowLatency
    var colorSpace: StreamColorSpace = .sRGB

    func validate() throws {
        try DisplayProfile(width: width, height: height, hiDPI: false, hevc: hevc, appVersion: nil).validate()
        guard mode != .fidelity || hevc,
              mode != .lowLatency || colorSpace == .sRGB,
              !mode.isRGB || (!hevc && parameterSets.isEmpty) else {
            throw WireError.invalid("Invalid video mode configuration")
        }
    }
}

enum TransmissionMode: String, Codable, CaseIterable {
    case lowLatency, fidelity, lossless, demo1, demo2, demo3

    var isDemo: Bool { self == .demo1 || self == .demo2 || self == .demo3 }
    var isRGB: Bool { self == .lossless || isDemo }
    var usesLosslessRegions: Bool { self == .demo1 || self == .demo3 }
    var frameLimit: Int {
        switch self {
        case .lossless, .demo3: return 1
        case .demo1, .demo2: return 2
        case .lowLatency, .fidelity: return 3
        }
    }

    func bitrate(width: Int, height: Int) -> Int {
        min(self == .fidelity ? 300_000_000 : 150_000_000,
            max(40_000_000, width * height * (self == .fidelity ? 20 : 10)))
    }
}

enum StreamColorSpace: String, Codable { case sRGB, displayP3 }

struct PanelCatalog: Decodable {
    struct Pixels: Decodable { let width: Int; let height: Int }
    struct Panel: Decodable { let models: [String]; let nativePixels: Pixels }
    let profiles: [Panel]

    func nativePixels(model: String, builtIn: Bool) -> Pixels? {
        builtIn ? profiles.first { $0.models.contains(model) }?.nativePixels : nil
    }
}

// Packed BGRA rows have no padding on the wire; the sequence is big-endian.
enum RawFrame {
    static func byteCount(width: Int, height: Int) throws -> Int {
        try DisplayProfile(width: width, height: height, hiDPI: false, hevc: false, appVersion: nil).validate()
        return 8 + width * height * 4
    }
}

// Demo frames preserve BGRA bytes; only their wire representation changes.
enum LosslessDemoFrame {
    static let headerSize = 37

    static func encode(_ raw: Data, previous: Data?, width: Int, height: Int, regions: Bool) throws -> Data {
        let count = try RawFrame.byteCount(width: width, height: height)
        guard raw.count == count, previous == nil || previous!.count == count else {
            throw WireError.invalid("Invalid demo source size")
        }
        let sequence = try Wire.integer(raw, at: 0, as: UInt64.self)
        var base: UInt64 = 0
        var x = 0, y = 0, w = width, h = height
        if regions, let previous {
            base = try Wire.integer(previous, at: 0, as: UInt64.self)
            guard base > 0, sequence > base else { throw WireError.invalid("Invalid demo source ancestry") }
            var minX = width, minY = height, maxX = -1, maxY = -1
            // ponytail: one bounding rectangle scans the frame; use tiles only if measured savings justify it.
            raw.withUnsafeBytes { current in previous.withUnsafeBytes { old in
                for row in 0..<height {
                    let offset = 8 + row * width * 4
                    let a = current.baseAddress!.advanced(by: offset), b = old.baseAddress!.advanced(by: offset)
                    if memcmp(a, b, width * 4) == 0 { continue }
                    minY = min(minY, row); maxY = row
                    var left = 0, right = width - 1
                    while left < width && memcmp(a.advanced(by: left * 4), b.advanced(by: left * 4), 4) == 0 { left += 1 }
                    while right > left && memcmp(a.advanced(by: right * 4), b.advanced(by: right * 4), 4) == 0 { right -= 1 }
                    minX = min(minX, left); maxX = max(maxX, right)
                }
            } }
            if maxY < 0 { x = 0; y = 0; w = 0; h = 0 }
            else { x = minX; y = minY; w = maxX - minX + 1; h = maxY - minY + 1 }
            if w == width && h == height { base = 0 }
        }
        guard sequence > 0 else { throw WireError.invalid("Invalid demo sequence") }
        var pixels = Data(count: w * h * 4)
        if !pixels.isEmpty {
            pixels.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { src in
                for row in 0..<h {
                    memcpy(dst.baseAddress!.advanced(by: row * w * 4),
                        src.baseAddress!.advanced(by: 8 + ((y + row) * width + x) * 4), w * 4)
                }
            } }
        }
        let expanded = pixels.count
        var compressed = Data(count: expanded)
        let size = expanded == 0 ? 0 : compressed.withUnsafeMutableBytes { dst in pixels.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expanded,
                src.bindMemory(to: UInt8.self).baseAddress!, expanded, nil, COMPRESSION_LZ4)
        } }
        let useCompression = size > 0 && size < expanded
        if useCompression { compressed.count = size; pixels = compressed }
        var packet = Data()
        Wire.append(sequence, to: &packet); Wire.append(base, to: &packet)
        packet.append(useCompression ? 1 : 0)
        for value in [x, y, w, h, expanded] { Wire.append(UInt32(value), to: &packet) }
        packet.append(pixels)
        return packet
    }

    // A nil result deliberately means a full keyframe: the stream metadata cannot be trusted.
    static func systemDirtyUnion(_ rects: [CGRect]?, width: Int, height: Int) -> CGRect? {
        guard let rects, !rects.isEmpty else { return nil }
        var union: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for rect in rects {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.size.width.isFinite, rect.size.height.isFinite,
                  rect.size.width > 0, rect.size.height > 0 else { return nil }
            let right = rect.origin.x + rect.size.width, bottom = rect.origin.y + rect.size.height
            guard right.isFinite, bottom.isFinite else { return nil }
            let lowX = max(0, min(Double(width), rect.origin.x))
            let lowY = max(0, min(Double(height), rect.origin.y))
            let highX = max(0, min(Double(width), right))
            let highY = max(0, min(Double(height), bottom))
            let minX = Int(floor(lowX)), minY = Int(floor(lowY))
            let maxX = Int(ceil(highX)), maxY = Int(ceil(highY))
            guard minX < maxX, minY < maxY else { return nil }
            if let value = union {
                union = (min(value.minX, minX), min(value.minY, minY), max(value.maxX, maxX), max(value.maxY, maxY))
            } else {
                union = (minX, minY, maxX, maxY)
            }
        }
        guard let union else { return nil }
        return CGRect(origin: CGPoint(x: Double(union.minX), y: Double(union.minY)),
                      size: CGSize(width: Double(union.maxX - union.minX), height: Double(union.maxY - union.minY)))
    }

    static func encode(_ raw: Data, previous: Data?, width: Int, height: Int,
                       systemDirtyRects: [CGRect]?) throws -> Data {
        guard let rect = systemDirtyUnion(systemDirtyRects, width: width, height: height),
              let previous else {
            return try encode(raw, previous: nil, width: width, height: height, regions: false)
        }
        let count = try RawFrame.byteCount(width: width, height: height)
        guard raw.count == count, previous.count == count else { throw WireError.invalid("Invalid demo source size") }
        let sequence = try Wire.integer(raw, at: 0, as: UInt64.self)
        let base = try Wire.integer(previous, at: 0, as: UInt64.self)
        guard sequence > base, base > 0 else { throw WireError.invalid("Invalid demo source ancestry") }
        let x = Int(rect.origin.x), y = Int(rect.origin.y)
        let w = Int(rect.size.width), h = Int(rect.size.height)
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else {
            return try encode(raw, previous: nil, width: width, height: height, regions: false)
        }
        var pixels = Data(count: w * h * 4)
        pixels.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { src in
            for row in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: row * w * 4),
                       src.baseAddress!.advanced(by: 8 + ((y + row) * width + x) * 4), w * 4)
            }
        } }
        let expanded = pixels.count
        var compressed = Data(count: expanded)
        let size = compressed.withUnsafeMutableBytes { dst in pixels.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expanded,
                                      src.bindMemory(to: UInt8.self).baseAddress!, expanded, nil, COMPRESSION_LZ4)
        } }
        let useCompression = size > 0 && size < expanded
        if useCompression { compressed.count = size; pixels = compressed }
        var packet = Data()
        Wire.append(sequence, to: &packet); Wire.append(base, to: &packet)
        packet.append(useCompression ? 1 : 0)
        for value in [x, y, w, h, expanded] { Wire.append(UInt32(value), to: &packet) }
        packet.append(pixels)
        return packet
    }

    static func decode(_ packet: Data, previous: Data?, width: Int, height: Int, regions: Bool) throws -> Data {
        let count = try RawFrame.byteCount(width: width, height: height)
        guard packet.count >= headerSize, packet.count < Wire.maximumPacket,
              previous == nil || previous!.count == count else { throw WireError.invalid("Invalid demo frame size") }
        let sequence = try Wire.integer(packet, at: 0, as: UInt64.self)
        let base = try Wire.integer(packet, at: 8, as: UInt64.self)
        let compression = try Wire.integer(packet, at: 16, as: UInt8.self)
        let x = Int(try Wire.integer(packet, at: 17, as: UInt32.self))
        let y = Int(try Wire.integer(packet, at: 21, as: UInt32.self))
        let w = Int(try Wire.integer(packet, at: 25, as: UInt32.self))
        let h = Int(try Wire.integer(packet, at: 29, as: UInt32.self))
        let expanded = Int(try Wire.integer(packet, at: 33, as: UInt32.self))
        let prior = try previous.map { try Wire.integer($0, at: 0, as: UInt64.self) } ?? 0
        guard sequence > prior, x <= width, y <= height, w <= width - x, h <= height - y,
              expanded == w * h * 4, compression <= 1 else { throw WireError.invalid("Invalid demo region") }
        if base == 0 {
            guard x == 0, y == 0, w == width, h == height else { throw WireError.invalid("Incomplete demo keyframe") }
        } else {
            guard regions, previous != nil, base == prior,
                  (w > 0 && h > 0) || (x == 0 && y == 0 && w == 0 && h == 0) else {
                throw WireError.invalid("Invalid demo ancestry")
            }
        }
        let payload = Data(packet.dropFirst(headerSize))
        var pixels: Data
        if compression == 0 {
            guard payload.count == expanded else { throw WireError.invalid("Invalid raw demo payload") }
            pixels = payload
        } else {
            guard expanded > 0, !payload.isEmpty, payload.count < expanded else { throw WireError.invalid("Invalid compressed demo payload") }
            // One extra byte detects an over-expanding stream, even when its claimed size is valid.
            pixels = Data(count: expanded + 1)
            try pixels.withUnsafeMutableBytes { dst in try payload.withUnsafeBytes { src in
                var stream = compression_stream(dst_ptr: dst.bindMemory(to: UInt8.self).baseAddress!, dst_size: expanded + 1,
                    src_ptr: src.bindMemory(to: UInt8.self).baseAddress!, src_size: payload.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK else {
                    throw WireError.invalid("Cannot create LZ4 decoder")
                }
                defer { compression_stream_destroy(&stream) }
                stream.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!; stream.dst_size = expanded + 1
                stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!; stream.src_size = payload.count
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END, stream.src_size == 0, stream.dst_size == 1 else {
                    throw WireError.invalid("Invalid LZ4 output size or stream")
                }
            } }
            pixels.count = expanded
        }
        // Data COW ensures previously submitted images/baselines cannot be mutated by later deltas.
        var result = base == 0 ? Data(count: count) : previous!
        var bigSequence = sequence.bigEndian
        result.withUnsafeMutableBytes { dst in
            _ = withUnsafeBytes(of: &bigSequence) { memcpy(dst.baseAddress!, $0.baseAddress!, 8) }
            if expanded > 0 { pixels.withUnsafeBytes { src in
                for row in 0..<h {
                    memcpy(dst.baseAddress!.advanced(by: 8 + ((y + row) * width + x) * 4),
                        src.baseAddress!.advanced(by: row * w * 4), w * 4)
                }
            } }
        }
        return result
    }
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
